import Foundation
import SwiftData

/// Progress reported while generating narration audio. Azure synthesis is split into batches
/// (see `AzureTTSClient`), so the UI can show how many chunks have been synthesized and when the
/// chunks are being stitched into the final file.
enum NarrativeGenerationProgress: Sendable {
    /// `completed` chunks have finished synthesizing; `inFlight` are currently being generated in
    /// parallel (up to the concurrency cap). `total` is the chunk count for the whole transcript.
    case synthesizing(completed: Int, total: Int, inFlight: Int)
    case stitching
}

/// Shared narrative generation flow used by `NarrativeTabView` and the MCP server.
@MainActor
enum NarrativeGenerationService {
    /// Runs TTS, persists the audio, and inserts a `GeneratedNarrative` into the supplied
    /// model context. Returns the inserted record (already linked to the project).
    ///
    /// `onProgress`, when supplied, is called on the main actor as synthesis advances — currently
    /// only the Azure provider reports progress (it batches long text); Gemini runs in one shot.
    @discardableResult
    static func generate(
        project: NarrativeProject,
        context: ModelContext,
        config: AppConfig,
        onProgress: (@MainActor (NarrativeGenerationProgress) -> Void)? = nil
    ) async throws -> GeneratedNarrative {
        let summary = speakerSummary(for: project)

        switch project.providerEnum {
        case .gemini:
            let transcript = NarrativePromptBuilder.build(
                speakers: project.speakers,
                paragraphs: project.paragraphs,
                scene: project.sceneDescription,
                notes: project.notes,
                context: project.context
            )
            let response = try await GeminiTTSClient.generate(
                transcript: transcript,
                speakers: project.speakers,
                apiKey: config.googleAIKey
            )
            // Write the (potentially large) audio off the main actor so the UI doesn't freeze.
            let audioData = response.audioData
            let relativePath = try await Task.detached {
                try FileStorage.saveAudio(audioData, extension: "wav")
            }.value
            let generated = GeneratedNarrative(
                audioFilePath: relativePath,
                transcriptText: transcript,
                project: project,
                providerName: project.providerEnum.displayName,
                speakerSummary: summary
            )
            context.insert(generated)
            project.updatedAt = Date()
            return generated

        case .azure:
            try await validateAzureVoices(project)
            // Snapshot the main-actor SwiftData model into Sendable values *before* handing work to
            // the off-main TTS client, so SSML building, network, and stitching never touch the UI.
            let speakers = project.speakers
            let paragraphs = project.paragraphs
            let response = try await AzureTTSClient.generate(
                speakers: speakers,
                paragraphs: paragraphs,
                apiKey: config.azureSpeechKey,
                endpoint: config.azureSpeechEndpoint,
                format: project.azureOutputFormatEnum,
                onProgress: onProgress
            )
            // Write the (potentially large) audio off the main actor so the UI doesn't freeze.
            let audioData = response.audioData
            let fileExtension = response.fileExtension
            let relativePath = try await Task.detached {
                try FileStorage.saveAudio(audioData, extension: fileExtension)
            }.value
            let generated = GeneratedNarrative(
                audioFilePath: relativePath,
                transcriptText: response.ssml,
                project: project,
                providerName: project.providerEnum.displayName,
                speakerSummary: summary
            )
            context.insert(generated)
            project.updatedAt = Date()
            return generated
        }
    }

    /// Guards against the most common Azure TTS failure: a `<voice name>` that does not
    /// exist in the account's region. The real-time `/cognitiveservices/v1` endpoint
    /// rejects an unknown voice with an **empty-body HTTP 400** (no detail at all), so we
    /// check the speakers' voices against the live voice list first and fail with a
    /// message that names the offending voice and suggests close matches.
    ///
    /// Only enforced when the voice list is actually available — if it can't be loaded
    /// (offline, missing credentials) we fall through and let Azure do the validating.
    private static func validateAzureVoices(_ project: NarrativeProject) async throws {
        let store = AzureVoiceStore.shared
        await store.fetchIfNeeded()
        guard !store.voices.isEmpty else { return }

        // The SSML builder sends `speaker.voice` as the `<voice name>`, so validate that.
        let used = Set(project.speakers.map { $0.voice }.filter { !$0.isEmpty })
        let missing = used.filter { store.voice(forShortName: $0) == nil }.sorted()
        guard !missing.isEmpty else { return }

        let allNames = store.voices.map { $0.shortName }
        let details = missing.map { name -> String in
            let suggestions = suggestVoices(for: name, from: allNames)
            return suggestions.isEmpty
                ? "• \(name) — not available in this region"
                : "• \(name) — not found; did you mean \(suggestions.joined(separator: ", "))?"
        }
        throw AzureTTSError.detailedHTTPError(
            "These speaker voices aren't available in your Azure region, so synthesis would "
            + "fail with an empty HTTP 400:\n"
            + details.joined(separator: "\n")
            + "\nOpen the speaker's settings and pick a voice from the list."
        )
    }

    /// Suggest real voices that look like the (invalid) `name` — same given-name, e.g.
    /// "zh-CN-Xiaochen:DragonHDFlashLatestNeural" → "zh-CN-Xiaochen:DragonHDLatestNeural".
    private static func suggestVoices(for name: String, from all: [String], limit: Int = 4) -> [String] {
        let segments = name.split(separator: "-")
        let localePrefix = segments.count >= 2 ? "\(segments[0])-\(segments[1])-".lowercased() : ""
        var base = name.lowercased()
        if !localePrefix.isEmpty, base.hasPrefix(localePrefix) {
            base = String(base.dropFirst(localePrefix.count))
        }
        if let colon = base.firstIndex(of: ":") { base = String(base[..<colon]) }
        base = base.replacingOccurrences(of: "neural", with: "")
        guard base.count >= 2 else { return [] }

        let matches = all.filter { $0.lowercased().contains(base) && $0.lowercased() != name.lowercased() }
        return Array(matches.prefix(limit))
    }

    static func speakerSummary(for project: NarrativeProject) -> String {
        project.speakers
            .map { speaker -> String in
                let voiceName: String
                switch project.providerEnum {
                case .azure: voiceName = speaker.azureVoice
                case .gemini: voiceName = speaker.geminiVoice.isEmpty ? speaker.voice : speaker.geminiVoice
                }
                return voiceName.isEmpty ? speaker.displayName : "\(speaker.displayName) \(voiceName)"
            }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
