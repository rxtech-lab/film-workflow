import Foundation
import WhisperKit

/// Owns the loaded WhisperKit pipeline.
///
/// An `actor` rather than the repo's usual `nonisolated struct` + `@concurrent
/// static` shape because this genuinely has expensive mutable state: a loaded
/// model holds 100 MB–1.6 GB and takes 10–60 s to initialize, so it must be
/// cached across runs. The actor also serializes transcriptions for free, which
/// is what we want — two concurrent large-model decodes would thrash memory.
actor WhisperKitEngine {
    static let shared = WhisperKitEngine()

    private var pipe: WhisperKit?
    private var loadedVariant: String?

    private init() {}

    var currentVariant: String? { loadedVariant }

    var isLoaded: Bool { pipe != nil }

    /// Whether the loaded model can produce word timings.
    ///
    /// Not every converted variant can: DTW alignment needs
    /// `alignment_heads_weights` baked into the model. Callers must check this
    /// and degrade to segment-only rather than silently emitting empty word
    /// arrays.
    var supportsWordTimestamps: Bool {
        pipe?.textDecoder.supportsWordTimestamps ?? false
    }

    /// Loads `variant` if it isn't already loaded.
    ///
    /// Never downloads: `download: false` means a missing model raises instead
    /// of silently pulling 1.6 GB over someone's cellular connection. Model
    /// acquisition is an explicit, visible action in Settings.
    func ensureLoaded(
        variant: String,
        onProgress: (@MainActor @Sendable (CaptionProgress) -> Void)? = nil
    ) async throws {
        let trimmed = variant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CaptionTranscriberError.notConfigured(
                .whisperLocal,
                hint: "Choose and download a Whisper model in Settings › Captions."
            )
        }
        if pipe != nil, loadedVariant == trimmed { return }

        // The folder has to be resolved and handed over explicitly. With
        // `download: false` and no `modelFolder`, WhisperKit leaves its own
        // `modelFolder` nil and `loadModels()` fails with "Model folder is not
        // set." — `downloadBase` alone is only ever used as a *download*
        // destination, never searched for an existing model.
        guard let folder = WhisperModelStore.folderURL(for: trimmed),
              WhisperModelStore.isInstalled(variant: trimmed)
        else {
            throw CaptionTranscriberError.modelNotInstalled(trimmed)
        }

        if let onProgress {
            await MainActor.run { onProgress(.loadingModel(name: trimmed)) }
        }

        // Drop the old pipe first so two models are never resident at once.
        pipe = nil
        loadedVariant = nil

        let config = WhisperKitConfig(
            model: trimmed,
            downloadBase: FileStorage.whisperModelsDir,
            modelFolder: folder.path,
            // The Core ML models ship without tokenizer files, so the tokenizer
            // is fetched separately on first load. Point that cache at our own
            // folder instead of the Hub default, so "Delete" and the on-disk
            // size in Settings account for everything.
            tokenizerFolder: FileStorage.whisperModelsDir,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        do {
            pipe = try await WhisperKit(config)
            loadedVariant = trimmed
        } catch {
            pipe = nil
            loadedVariant = nil
            throw error
        }
    }

    func transcribe(
        request: CaptionTranscribeRequest,
        variant: String,
        termsHint: String = "",
        onProgress: (@MainActor @Sendable (CaptionProgress) -> Void)?
    ) async throws -> CaptionTranscript {
        try await ensureLoaded(variant: variant, onProgress: onProgress)
        guard let pipe else {
            throw CaptionTranscriberError.modelNotInstalled(variant)
        }

        // WhisperKit's own loader converts to 16 kHz mono Float32 internally, so
        // hand it the path. Only pre-convert when AVAudioFile can't open the
        // file at all (Opus-in-Ogg, some WebM).
        var audioURL = request.audioURL
        var temporaryURL: URL?
        if await !AudioProbe.isReadableByAVAudioFile(audioURL) {
            if let onProgress {
                await MainActor.run { onProgress(.preparing(detail: "Converting audio")) }
            }
            let converted = try await AudioConversion.toWhisperWAV(audioURL)
            audioURL = converted
            temporaryURL = converted
        }
        defer {
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        }

        let wantsWords = request.wordTimestampsEnabled && pipe.textDecoder.supportsWordTimestamps
        let durationSeconds = Double(request.durationMs) / 1000

        // These thresholds are load-bearing, not tuning: without them Whisper
        // hallucinates long runs of repeated text over music and silence, and a
        // 1-hour file with gaps produces garbage cues.
        // The project's glossary as decoder conditioning. Whisper treats prompt
        // tokens as "text that preceded this audio", which is enough to bias it
        // toward a known spelling. Capped hard: the prompt shares the decoder's
        // 448-token window with the transcript itself, and a long one measurably
        // degrades output.
        let promptTokens: [Int]? = {
            let hint = termsHint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hint.isEmpty, let tokenizer = pipe.tokenizer else { return nil }
            let encoded = tokenizer.encode(text: " \(hint)")
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            guard !encoded.isEmpty else { return nil }
            return Array(encoded.prefix(120))
        }()

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: request.languageHint.isEmpty
                ? nil
                : String(request.languageHint.prefix(2)).lowercased(),
            temperatureFallbackCount: 3,
            detectLanguage: request.languageHint.isEmpty,
            wordTimestamps: wantsWords,
            promptTokens: promptTokens,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6,
            chunkingStrategy: .vad
        )

        let results = try await pipe.transcribe(
            audioPath: audioURL.path,
            decodeOptions: options,
            callback: { progress in
                // Returning false aborts the decode — this is how cancellation
                // reaches into WhisperKit.
                if Task.isCancelled { return false }
                if let onProgress {
                    // seekTime is the position in the audio, which is a far more
                    // honest progress signal than token counts.
                    let fraction: Double? = durationSeconds > 0
                        ? min(max(Double(progress.timings.inputAudioSeconds) / durationSeconds, 0), 1)
                        : nil
                    Task { @MainActor in
                        onProgress(.transcribing(chunk: 1, totalChunks: 1, fraction: fraction))
                    }
                }
                return nil
            }
        )

        try Task.checkCancellation()

        var phrases: [CaptionPhrase] = []
        for result in results {
            for segment in result.segments {
                let text = segment.text
                    .replacingOccurrences(
                        of: "<\\|[^|]*\\|>", with: "", options: .regularExpression
                    )
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                let startMs = Int((segment.start * 1000).rounded())
                let endMs = Int((segment.end * 1000).rounded())
                guard endMs > startMs else { continue }

                let words: [CaptionWordTiming] = (segment.words ?? []).compactMap { word in
                    let wordText = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !wordText.isEmpty else { return nil }
                    let wordStart = Int((word.start * 1000).rounded())
                    let wordEnd = Int((word.end * 1000).rounded())
                    guard wordEnd > wordStart else { return nil }
                    return CaptionWordTiming(
                        text: wordText,
                        offsetMs: wordStart,
                        durationMs: wordEnd - wordStart,
                        confidence: Double(word.probability)
                    )
                }

                phrases.append(CaptionPhrase(
                    // Whisper has no diarization; everything is speaker 0 and
                    // gets assigned by hand in the editor.
                    speaker: 0,
                    offsetMs: startMs,
                    durationMs: endMs - startMs,
                    text: text,
                    locale: result.language,
                    words: words
                ))
            }
        }

        guard !phrases.isEmpty else { throw CaptionTranscriberError.noSpeechFound }
        phrases.sort { $0.offsetMs < $1.offsetMs }

        if !CaptionSettingsSnapshot.keepModelLoaded {
            unload()
        }

        return CaptionTranscript(
            durationMs: max(request.durationMs, phrases.map(\.endMs).max() ?? 0),
            phrases: phrases,
            providerName: CaptionProvider.whisperLocal.rawValue,
            detectedLanguage: results.first?.language ?? ""
        )
    }

    func unload() {
        pipe = nil
        loadedVariant = nil
    }
}

/// Lets the non-main-actor engine read a couple of user preferences without
/// hopping to the main actor mid-decode.
nonisolated struct CaptionSettingsSnapshot {
    static var keepModelLoaded: Bool {
        // Defaults to true; `CaptionSettings` writes this key.
        UserDefaults.standard.object(forKey: "caption.keepWhisperModelLoaded") as? Bool ?? true
    }
}

/// Thin adapter so local transcription satisfies the same protocol as the HTTP
/// providers; all real work lives in the actor.
nonisolated struct WhisperCaptionClient: CaptionTranscriberClient {
    static let provider = CaptionProvider.whisperLocal

    static func transcribe(
        request: CaptionTranscribeRequest,
        config: AppConfig,
        options: CaptionProviderOptions,
        onProgress: (@MainActor @Sendable (CaptionProgress) -> Void)?
    ) async throws -> CaptionTranscript {
        let variant = options.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await WhisperKitEngine.shared.transcribe(
            request: request,
            variant: variant,
            termsHint: options.termsHint,
            onProgress: onProgress
        )
    }
}
