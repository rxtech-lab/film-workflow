import Foundation
import SwiftData

/// The single entry point for producing captions, shared by the UI and MCP.
///
/// Mirrors `NarrativeGenerationService`: a `@MainActor enum` that snapshots what
/// it needs, hands the heavy work to `@concurrent` code, then writes results
/// back on the main actor.
@MainActor
enum CaptionTranscriptionService {

    /// Transcribes a project's audio into a **new transcript version**, which
    /// becomes the active one. Earlier versions and their translations are kept.
    /// Returns the number of segments written.
    @discardableResult
    static func transcribe(
        project: CaptionProject,
        context: ModelContext,
        config: AppConfig,
        onProgress: (@MainActor @Sendable (CaptionProgress) -> Void)? = nil
    ) async throws -> Int {
        guard project.hasAudio else {
            throw CaptionTranscriberError.unsupportedAudio("No audio has been chosen yet.")
        }
        let audioURL = project.audioURL
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw CaptionTranscriberError.unsupportedAudio(
                "The audio file is missing: \(project.audioFilePath)"
            )
        }

        let settings = CaptionSettings.shared
        let provider = project.providerOverride ?? settings.defaultProvider

        onProgress?(.preparing(detail: "Reading audio"))
        let durationMs = try await resolveDuration(project: project, url: audioURL)

        let request = CaptionTranscribeRequest(
            audioURL: audioURL,
            mimeType: AudioProbe.mimeType(for: audioURL),
            sizeBytes: AudioProbe.fileSizeBytes(of: audioURL),
            durationMs: durationMs,
            languageHint: project.languageHint,
            maxSpeakers: project.maxSpeakers,
            diarizationEnabled: project.diarizationEnabled && provider.supportsDiarization,
            wordTimestampsEnabled: project.wordTimestampsEnabled
        )

        let (transcript, usedProvider, warning) = try await transcribeWithTimingFallback(
            primary: provider,
            fallback: settings.timingFallbackProvider,
            request: request,
            config: config,
            options: options(for: provider, config: config, settings: settings, project: project),
            settings: settings,
            project: project,
            onProgress: onProgress
        )

        onProgress?(.buildingCues)
        let built = await CaptionCueBuilder.sentenceCues(
            from: transcript,
            maxRunes: cueBuildingLimit(settings: settings)
        )
        guard !built.isEmpty else { throw CaptionTranscriberError.noSpeechFound }

        let cues = await refineSplits(
            built,
            settings: settings,
            project: project,
            config: config,
            onProgress: onProgress
        )
        guard !cues.isEmpty else { throw CaptionTranscriberError.noSpeechFound }

        syncSpeakers(of: project, from: transcript)
        writeSegments(of: project, with: cues, context: context, provider: usedProvider)

        project.audioDurationMs = max(transcript.durationMs, durationMs)
        project.lastTranscribedAt = Date()
        project.lastProviderName = usedProvider.rawValue
        project.alignmentQualityEnum = .none
        project.alignmentMatchRatio = 0
        project.warning = warning ?? providerCaveat(usedProvider, transcript: transcript)
        project.updatedAt = Date()

        try context.save()
        return cues.count
    }

    /// Produces captions for a narration: **timings from the speech service,
    /// text from the author's script**.
    ///
    /// The transcription hypothesis is used purely as a clock. It's aligned
    /// against the shortcode-stripped paragraph text, the timings are transferred
    /// onto the reference tokens, and the hypothesis is then thrown away — so a
    /// mis-heard word never reaches the caption. Speakers come from the
    /// narrative's own speaker list, so diarization is neither used nor needed.
    ///
    /// Returns the number of captions written.
    @discardableResult
    static func alignNarrative(
        project: CaptionProject,
        context: ModelContext,
        config: AppConfig,
        onProgress: (@MainActor @Sendable (CaptionProgress) -> Void)? = nil
    ) async throws -> Int {
        guard project.hasAudio else {
            throw CaptionTranscriberError.unsupportedAudio("No audio has been chosen yet.")
        }
        guard !project.referenceUnits.isEmpty else {
            throw CaptionTranscriberError.unsupportedAudio(
                "This narration has no script text to align against."
            )
        }
        let audioURL = project.audioURL
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw CaptionTranscriberError.unsupportedAudio(
                "The narration audio is missing: \(project.audioFilePath)"
            )
        }

        let settings = CaptionSettings.shared
        let provider = project.providerOverride ?? settings.narrativeProvider

        onProgress?(.preparing(detail: "Reading audio"))
        let durationMs = try await resolveDuration(project: project, url: audioURL)

        let request = CaptionTranscribeRequest(
            audioURL: audioURL,
            mimeType: AudioProbe.mimeType(for: audioURL),
            sizeBytes: AudioProbe.fileSizeBytes(of: audioURL),
            durationMs: durationMs,
            languageHint: project.languageHint,
            maxSpeakers: 2,
            // Speakers are already known from the script.
            diarizationEnabled: false,
            wordTimestampsEnabled: true
        )

        let (transcript, usedProvider, providerWarning) = try await transcribeWithTimingFallback(
            primary: provider,
            fallback: settings.timingFallbackProvider,
            request: request,
            config: config,
            options: options(for: provider, config: config, settings: settings, project: project),
            settings: settings,
            project: project,
            onProgress: onProgress
        )

        // Snapshot into Sendable values before crossing to the aligner.
        let units = project.orderedReferenceUnits
        let referenceTokens = CaptionTokenizer.tokenizeReference(units)
        let timings = transcript.allWords
        let hypothesisTokens = CaptionTokenizer.tokenizeHypothesis(timings)
        let audioDuration = max(transcript.durationMs, durationMs)
        let maxRunes = cueBuildingLimit(settings: settings)
        let minConfidence = settings.narrativeAlignmentMinConfidence

        onProgress?(.aligning(fraction: 0))
        let result = await CaptionAligner.align(
            reference: referenceTokens,
            hypothesis: hypothesisTokens,
            hypothesisTimings: timings,
            audioDurationMs: audioDuration,
            minConfidence: minConfidence,
            onProgress: { fraction in onProgress?(.aligning(fraction: fraction)) }
        )
        try Task.checkCancellation()

        onProgress?(.buildingCues)
        let built = CaptionAligner.cues(
            from: result,
            maxRunes: maxRunes,
            audioDurationMs: audioDuration
        )
        guard !built.isEmpty else { throw CaptionTranscriberError.noSpeechFound }

        let cues = await refineSplits(
            built,
            settings: settings,
            project: project,
            config: config,
            onProgress: onProgress
        )
        guard !cues.isEmpty else { throw CaptionTranscriberError.noSpeechFound }

        writeSegments(
            of: project,
            with: cues,
            context: context,
            provider: usedProvider,
            alignmentQuality: result.quality,
            alignmentMatchRatio: result.matchRatio,
            note: "Aligned to script"
        )

        project.audioDurationMs = audioDuration
        project.lastTranscribedAt = Date()
        project.lastProviderName = usedProvider.rawValue
        project.alignmentQualityEnum = result.quality
        project.alignmentMatchRatio = result.matchRatio
        project.warning = narrativeWarning(
            quality: result.quality,
            matchRatio: result.matchRatio,
            provider: usedProvider,
            hasWordTimings: transcript.hasWordTimings,
            providerWarning: providerWarning
        )
        project.updatedAt = Date()

        try context.save()
        return cues.count
    }

    /// Finds or creates the caption project for a narration, then aligns it.
    ///
    /// Reuses an existing project when one is already linked, so re-generating
    /// captions doesn't leave orphans piling up in the Caption tab.
    @discardableResult
    static func captionProject(
        for generated: GeneratedNarrative,
        narrative: NarrativeProject,
        context: ModelContext,
        config: AppConfig,
        onProgress: (@MainActor @Sendable (CaptionProgress) -> Void)? = nil
    ) async throws -> CaptionProject {
        let project: CaptionProject
        if let existingID = generated.captionProjectID,
           let existing = try? context.fetch(
                FetchDescriptor<CaptionProject>(
                    predicate: #Predicate { $0.projectUUID == existingID }
                )
           ).first {
            project = existing
        } else {
            project = CaptionProject(name: "\(narrative.name) captions")
            context.insert(project)
        }

        project.audioFilePath = generated.audioFilePath
        // Reference the narration's file in place; never copy a large audio file.
        project.ownsAudioFile = false
        project.sourceKindEnum = .generatedNarrative
        project.sourceNarrativeID = generated.captionSourceID
        project.sourceNarrativeName = narrative.name
        project.audioDurationMs = 0
        project.diarizationEnabled = false
        project.languageHint = CaptionSettings.shared.defaultLanguageHint

        if !narrative.captionProviderOverride.isEmpty {
            project.provider = narrative.captionProviderOverride
        }

        // Speakers first, then units — units resolve speaker ids against them.
        project.speakers = CaptionReferenceBuilder.speakers(for: narrative)
        project.referenceUnits = CaptionReferenceBuilder.units(for: narrative, project: project)

        guard !project.referenceUnits.isEmpty else {
            throw CaptionTranscriberError.unsupportedAudio(
                "This narrative has no spoken text to align against."
            )
        }

        try await alignNarrative(
            project: project,
            context: context,
            config: config,
            onProgress: onProgress
        )
        return project
    }

    /// Explains a degraded alignment in terms the user can act on.
    nonisolated static func narrativeWarning(
        quality: CaptionAlignmentQuality,
        matchRatio: Double,
        provider: CaptionProvider,
        hasWordTimings: Bool,
        providerWarning: String?
    ) -> String {
        var parts: [String] = []
        if let providerWarning, !providerWarning.isEmpty {
            parts.append(providerWarning)
        }

        switch quality {
        case .wordAligned, .none:
            break
        case .sentenceAnchored:
            parts.append(
                "Only \(Int(matchRatio * 100))% of your script matched what "
                + "\(provider.displayName) heard, so timings are aligned per sentence rather than "
                + "per word."
            )
        case .estimated:
            if !hasWordTimings {
                parts.append(
                    "\(provider.displayName) returned no word timings, so caption times are "
                    + "estimated from text length. Azure or on-device Whisper give real timings."
                )
            } else {
                parts.append(
                    "Your script and the audio didn't match closely enough to align "
                    + "(\(Int(matchRatio * 100))%), so caption times are estimated from text length."
                )
            }
        }
        return parts.joined(separator: " ")
    }

    // MARK: - AI splitting

    /// Cue length limit handed to the builder.
    ///
    /// In AI mode the character split must *not* run first — the model can only
    /// pick a good break point if it sees the whole sentence. A generous ceiling
    /// still applies so a minutes-long unpunctuated run can't produce a cue too
    /// big for the model to read.
    static func cueBuildingLimit(settings: CaptionSettings) -> Int {
        switch settings.splitMode {
        case .characterLimit:
            return settings.maxCueRunes
        case .ai:
            return CaptionAISplitter.rawCueCeiling(maxRunes: settings.maxCueRunes)
        }
    }

    /// Runs the AI splitter over freshly built cues when the user asked for it.
    ///
    /// Never throws. Splitting is a refinement on top of captions that already
    /// exist and are usable; an unconfigured engine, a network failure or a
    /// cancelled task all fall back to the character split rather than losing a
    /// transcription that may have taken minutes.
    static func refineSplits(
        _ cues: [CaptionCue],
        settings: CaptionSettings,
        project: CaptionProject,
        config: AppConfig,
        onProgress: (@MainActor @Sendable (CaptionProgress) -> Void)?
    ) async -> [CaptionCue] {
        guard settings.splitMode == .ai else { return cues }

        let maxRunes = settings.maxCueRunes
        let engine: any CaptionAIEngine
        do {
            let backend = try AgentBackendAvailability.shared.resolved(
                preferred: settings.aiBackend,
                config: config,
                for: .cueRefinement
            )
            engine = try CaptionAIEngineFactory.make(backend: backend, config: config)
        } catch {
            return characterSplitFallback(cues, maxRunes: maxRunes)
        }

        let terms = project.usableTerms
        let languageHint = project.languageHint
        let label = engine.modelLabel

        return await CaptionAISplitter.refine(
            cues: cues,
            maxRunes: maxRunes,
            terms: terms,
            languageHint: languageHint,
            engine: engine,
            onProgress: { done, total in
                Task { @MainActor in
                    onProgress?(.reviewingWithAI(engine: label, done: done, total: total))
                }
            }
        )
    }

    /// The captions the character-limit mode would have produced, applied after
    /// the fact to cues built with the AI ceiling.
    nonisolated static func characterSplitFallback(
        _ cues: [CaptionCue],
        maxRunes: Int
    ) -> [CaptionCue] {
        cues.flatMap { CaptionAISplitter.characterSplit($0, maxRunes: maxRunes) }
    }

    // MARK: - Provider selection

    static func options(
        for provider: CaptionProvider,
        config: AppConfig,
        settings: CaptionSettings,
        project: CaptionProject? = nil
    ) -> CaptionProviderOptions {
        let hint = termsHint(for: project, settings: settings)

        switch provider {
        case .whisperLocal:
            // A per-project model wins over the app-wide choice.
            let override = project?.whisperVariantOverride ?? ""
            return CaptionProviderOptions(
                model: override.isEmpty ? settings.whisperVariant : override,
                termsHint: hint
            )
        case .openAI:
            return CaptionProviderOptions(
                model: config.openAITranscriptionModel,
                termsHint: hint
            )
        case .gemini:
            return CaptionProviderOptions(
                model: config.geminiTranscriptionModel,
                termsHint: hint
            )
        case .azure:
            // Azure takes a phrase list as a separate request field rather than
            // a prompt; not wired up yet.
            return CaptionProviderOptions()
        }
    }

    /// The project glossary as a provider spelling hint.
    ///
    /// Capped because these ride in the prompt: a runaway glossary would eat the
    /// provider's own context and start degrading the transcription it is
    /// supposed to improve.
    static func termsHint(for project: CaptionProject?, settings: CaptionSettings) -> String {
        guard settings.termsBiasTranscription, let project else { return "" }
        let terms = project.usableTerms.map(\.text)
        guard !terms.isEmpty else { return "" }

        var out: [String] = []
        var length = 0
        for term in terms {
            let cost = term.count + 2
            if length + cost > 800 { break }
            out.append(term)
            length += cost
        }
        return out.joined(separator: ", ")
    }

    /// Runs the primary provider and, if its timings can't be trusted, retries
    /// on the fallback.
    ///
    /// Port of `debate-bot/internal/server/transcribe_task.go`
    /// `transcribeWithTimingFallback`. This exists because generative
    /// transcription (Gemini) returns fluent text with timestamps that can jump
    /// backwards; publishing that makes every later caption point at unrelated
    /// audio.
    static func transcribeWithTimingFallback(
        primary: CaptionProvider,
        fallback: CaptionProvider?,
        request: CaptionTranscribeRequest,
        config: AppConfig,
        options: CaptionProviderOptions,
        settings: CaptionSettings,
        project: CaptionProject? = nil,
        onProgress: (@MainActor @Sendable (CaptionProgress) -> Void)?
    ) async throws -> (CaptionTranscript, CaptionProvider, String?) {
        let transcript = try await CaptionTranscriberFactory.transcribe(
            provider: primary,
            request: request,
            config: config,
            options: options,
            onProgress: onProgress
        )

        do {
            try CaptionTranscriptValidator.validateTiming(transcript)
            return (transcript, primary, nil)
        } catch let timingError {
            guard let fallback, fallback != primary else {
                // No usable fallback. Rather than refusing to produce anything,
                // repair the timings and say so — the user can fix them in the
                // retimer, which beats an error and an empty editor.
                let repaired = repairTiming(transcript)
                return (
                    repaired,
                    primary,
                    "\(primary.displayName) returned inconsistent timings, so they were adjusted "
                        + "automatically. Check them in the editor. (\(timingError.localizedDescription))"
                )
            }

            onProgress?(.preparing(detail: "Retrying with \(fallback.displayName) for timings"))
            let fallbackTranscript = try await CaptionTranscriberFactory.transcribe(
                provider: fallback,
                request: request,
                config: config,
                options: self.options(for: fallback, config: config, settings: settings, project: project),
                onProgress: onProgress
            )
            try CaptionTranscriptValidator.validateTiming(fallbackTranscript)
            return (
                fallbackTranscript,
                fallback,
                "\(primary.displayName) returned inconsistent timings, so \(fallback.displayName) "
                    + "was used instead."
            )
        }
    }

    /// Forces monotonic, in-bounds timings. Last resort when no fallback
    /// provider is configured. Pure, so it needn't be main-actor bound.
    nonisolated static func repairTiming(_ transcript: CaptionTranscript) -> CaptionTranscript {
        var phrases = transcript.phrases.sorted { $0.offsetMs < $1.offsetMs }
        let duration = max(transcript.durationMs, 1)
        var cursor = 0

        for index in phrases.indices {
            var phrase = phrases[index]
            phrase.offsetMs = max(phrase.offsetMs, cursor)
            if phrase.offsetMs >= duration { phrase.offsetMs = max(duration - 1, 0) }
            if phrase.durationMs <= 0 { phrase.durationMs = 1 }
            if phrase.offsetMs + phrase.durationMs > duration {
                phrase.durationMs = max(duration - phrase.offsetMs, 1)
            }
            cursor = phrase.offsetMs
            phrases[index] = phrase
        }

        var repaired = transcript
        repaired.phrases = phrases
        return repaired
    }

    /// Non-fatal caveats worth surfacing about the provider that ran.
    nonisolated static func providerCaveat(
        _ provider: CaptionProvider,
        transcript: CaptionTranscript
    ) -> String {
        if !provider.supportsDiarization {
            return "\(provider.displayName) doesn't separate speakers, so every caption is "
                + "unassigned. Use the editor to assign speakers."
        }
        if provider.supportsWordTimings, !transcript.hasWordTimings {
            return "\(provider.displayName) returned no word timings, so word-level export will "
                + "be approximated."
        }
        return ""
    }

    // MARK: - Writing results

    /// Writes a transcription run as a **new version**, leaving earlier versions
    /// and their translations in place.
    ///
    /// Deliberately additive where this used to delete: re-transcribing is now
    /// "record another take", so a user who re-runs with a different provider can
    /// compare the two and switch back to the one they had already hand-edited.
    /// Old rows stay on `project.segments` but out of `activeSegments`, so
    /// nothing that reads the transcript sees them.
    @discardableResult
    static func writeSegments(
        of project: CaptionProject,
        with cues: [CaptionCue],
        context: ModelContext,
        provider: CaptionProvider,
        alignmentQuality: CaptionAlignmentQuality = .none,
        alignmentMatchRatio: Double = 0,
        note: String = ""
    ) -> CaptionTranscriptVersion {
        project.ensureVersioned()

        // Capture the outgoing take before switching — `activeSegments` follows
        // `activeVersionID`, so reading it after the switch would return nothing.
        let previousSegments = project.activeSegments

        // The hint is what we asked for; `cue.locale` is what the provider
        // actually heard. Prefer the explicit hint, fall back to detection, so a
        // version always carries a language even on an auto-detect project.
        let detected = cues.first { !$0.locale.isEmpty }?.locale ?? ""
        let version = CaptionTranscriptVersion(
            number: project.nextVersionNumber,
            languageCode: project.languageHint.isEmpty ? detected : project.languageHint,
            provider: provider.rawValue,
            sourceKind: project.sourceKind,
            alignmentQuality: alignmentQuality.rawValue,
            alignmentMatchRatio: alignmentMatchRatio,
            segmentCount: cues.count,
            note: note
        )
        project.versions.append(version)
        project.activeVersionID = version.id

        for (index, cue) in cues.enumerated() {
            let speakerId = cue.speakerId
                ?? project.speakers.first { $0.providerSpeakerNumber == cue.speaker }?.id

            let segment = CaptionSegment(
                orderIndex: index,
                startMs: cue.startMs,
                endMs: cue.endMs,
                text: cue.text,
                speakerId: speakerId,
                providerSpeakerNumber: cue.speaker,
                locale: cue.locale,
                confidence: cue.confidence,
                isEstimatedTiming: cue.isEstimatedTiming,
                words: cue.words
            )
            segment.versionID = version.id
            segment.project = project
            context.insert(segment)
        }

        inheritTranslations(into: project, from: previousSegments)
        project.refreshTranslationSummary()
        return project.activeVersion ?? version
    }

    /// Copies translations forward onto captions that came out word-for-word
    /// identical to the previous take.
    ///
    /// Re-transcribing the same audio usually changes a handful of lines, so
    /// starting from zero would mean re-translating nine hundred captions to fix
    /// three. Matching is on `CaptionTranslation.fingerprint` — normalized and
    /// punctuation-blind — and the fingerprint is carried across unchanged, so a
    /// later edit to the new caption still flags the inherited translation stale.
    ///
    /// Ambiguity is resolved by consuming matches in order: a phrase repeated
    /// five times in the audio hands its five translations to the five new
    /// captions that match it, rather than giving them all the first one.
    private static func inheritTranslations(
        into project: CaptionProject,
        from previousSegments: [CaptionSegment]
    ) {
        guard previousSegments.contains(where: { !$0.translations.isEmpty }) else { return }

        var pool: [String: [[CaptionTranslation]]] = [:]
        for segment in previousSegments.sorted(by: { $0.startMs < $1.startMs })
        where !segment.translations.isEmpty {
            pool[CaptionTranslation.fingerprint(of: segment.text), default: []]
                .append(segment.translations)
        }

        for segment in project.orderedSegments {
            let key = CaptionTranslation.fingerprint(of: segment.text)
            guard var bucket = pool[key], !bucket.isEmpty else { continue }
            segment.translations = bucket.removeFirst()
            pool[key] = bucket
        }
    }

    /// Deletes a version and every caption in it.
    ///
    /// Segments are only reachable through the project relationship, so dropping
    /// the version record alone would orphan them inside `project.segments`
    /// forever. Refuses on the last remaining version — a project with captions
    /// but no version would read as legacy and show every take at once.
    @discardableResult
    static func deleteVersion(
        _ versionID: UUID,
        from project: CaptionProject,
        context: ModelContext
    ) -> Bool {
        guard project.versions.count > 1,
              project.versions.contains(where: { $0.id == versionID })
        else { return false }

        // Detached from the relationship as well as deleted: SwiftData only
        // prunes the array on save, and everything here reads `project.segments`
        // synchronously right afterwards.
        let doomed = project.segments.filter { $0.versionID == versionID }
        project.segments = project.segments.filter { $0.versionID != versionID }
        for segment in doomed {
            context.delete(segment)
        }
        project.versions.removeAll { $0.id == versionID }

        if project.activeVersionID == versionID {
            project.activeVersionID = project.orderedVersions.first?.id
            project.refreshTranslationSummary()
        }
        project.updatedAt = Date()
        return true
    }

    /// Switches which take the editor and every export see.
    @discardableResult
    static func activateVersion(_ versionID: UUID, in project: CaptionProject) -> Bool {
        guard project.versions.contains(where: { $0.id == versionID }) else { return false }
        project.activeVersionID = versionID
        project.refreshTranslationSummary()
        project.updatedAt = Date()
        return true
    }

    /// Adds a `CaptionSpeaker` for every diarization id the provider used,
    /// preserving labels the user already edited.
    static func syncSpeakers(of project: CaptionProject, from transcript: CaptionTranscript) {
        let numbers = transcript.speakerNumbers.filter { $0 > 0 }

        // Undiarized output: one unnamed speaker is friendlier than none, since
        // the editor's speaker picker then has something to assign.
        guard !numbers.isEmpty else {
            if project.speakers.isEmpty {
                project.speakers = [CaptionSpeaker(label: "Speaker 1", providerSpeakerNumber: 0)]
            }
            return
        }

        var speakers = project.speakers
        for number in numbers where !speakers.contains(where: { $0.providerSpeakerNumber == number }) {
            speakers.append(CaptionSpeaker(
                label: "Speaker \(number)",
                providerSpeakerNumber: number,
                colorIndex: speakers.count
            ))
        }
        project.speakers = speakers
    }

    // MARK: - Duration

    static func resolveDuration(project: CaptionProject, url: URL) async throws -> Int {
        if project.audioDurationMs > 0 { return project.audioDurationMs }
        let ms = try await AudioProbe.durationMs(of: url)
        project.audioDurationMs = ms
        return ms
    }
}
