import Foundation

nonisolated struct AzureSSMLBuilder {
    static func build(speakers: [NarrativeSpeaker], paragraphs: [NarrativeParagraph]) -> String {
        let rootLang = rootLanguage(speakers: speakers)
        let voiceLines = paragraphs.compactMap { voiceLine(for: $0, speakers: speakers) }
        return wrapSpeak(voiceLines.map { $0.ssml }, lang: rootLang)
    }

    /// Splits the project into one or more self-contained `<speak>` documents so that no single
    /// request exceeds Azure's real-time synthesis limit (~10 minutes of audio per request, which
    /// surfaces as an empty-body HTTP 400 for long text). Each paragraph is kept whole and assigned
    /// to a batch greedily by estimated spoken-character count; the resulting audio chunks are meant
    /// to be stitched back together in order.
    ///
    /// `maxCharacters` is deliberately small: dense languages like Chinese speak ~4 chars/second, so
    /// 1,200 chars is ≈5 minutes of audio — well under the cap, and small enough that each request
    /// transfers quickly. Smaller requests matter a lot on slow/long-haul links (e.g. reaching an
    /// `eastus` resource from Asia), where a single large synthesis tends to stall and time out.
    static func buildBatches(
        speakers: [NarrativeSpeaker],
        paragraphs: [NarrativeParagraph],
        maxCharacters: Int = 1200
    ) -> [String] {
        let rootLang = rootLanguage(speakers: speakers)
        let rendered = paragraphs.compactMap { voiceLine(for: $0, speakers: speakers) }
        guard !rendered.isEmpty else { return [] }

        var batches: [[String]] = []
        var current: [String] = []
        var currentCount = 0

        for line in rendered {
            // Start a new batch when adding this paragraph would exceed the budget, unless the
            // current batch is empty (a single oversized paragraph still has to go somewhere).
            if !current.isEmpty, currentCount + line.spokenCount > maxCharacters {
                batches.append(current)
                current = []
                currentCount = 0
            }
            current.append(line.ssml)
            currentCount += line.spokenCount
        }
        if !current.isEmpty { batches.append(current) }

        return batches.map { wrapSpeak($0, lang: rootLang) }
    }

    private struct VoiceLine {
        let ssml: String
        /// Number of plain-text characters that will be spoken — used to size batches.
        let spokenCount: Int
    }

    private static func rootLanguage(speakers: [NarrativeSpeaker]) -> String {
        let fallbackVoice = speakers.first?.voice ?? "en-US-JennyNeural"
        return locale(fromVoiceName: fallbackVoice) ?? "en-US"
    }

    private static func wrapSpeak(_ voiceLines: [String], lang: String) -> String {
        var lines: [String] = []
        lines.append("<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xmlns:mstts='https://www.w3.org/2001/mstts' xml:lang='\(lang)'>")
        lines.append(contentsOf: voiceLines)
        lines.append("</speak>")
        return lines.joined(separator: "\n")
    }

    private static func voiceLine(for paragraph: NarrativeParagraph, speakers: [NarrativeSpeaker]) -> VoiceLine? {
        let content = paragraph.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }

        let speakersById = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0) })
        let fallbackVoice = speakers.first?.voice ?? "en-US-JennyNeural"
        let speaker = speakersById[paragraph.speakerId]
        let voiceName = speaker?.voice ?? fallbackVoice

        let innerBody = renderSegments(ShortcodeExpander.expandForAzure(content))
        let emotion = paragraph.emotion.trimmingCharacters(in: .whitespacesAndNewlines)

        var inner = innerBody
        if !emotion.isEmpty {
            inner = wrapExpressAs(inner, style: emotion, speaker: speaker)
        }
        if let speaker = speaker, speaker.hasAzureProsody {
            inner = wrapProsody(inner, speaker: speaker)
        }

        let ssml = "  <voice name='\(xmlEscape(voiceName))'>\(inner)</voice>"
        return VoiceLine(ssml: ssml, spokenCount: content.count)
    }

    private static func renderSegments(_ segments: [AzureSegment]) -> String {
        var out = ""
        for seg in segments {
            switch seg {
            case .text(let s): out += xmlEscape(s)
            case .ssml(let s): out += s
            }
        }
        return out
    }

    private static func wrapExpressAs(_ body: String, style: String, speaker: NarrativeSpeaker?) -> String {
        var attrs = "style='\(xmlEscape(style))'"
        if let speaker = speaker {
            let degree = speaker.azureStyleDegree
            if abs(degree - 1.0) > 0.0001 {
                attrs += " styledegree='\(formatDouble(degree))'"
            }
            if !speaker.azureRole.isEmpty {
                attrs += " role='\(xmlEscape(speaker.azureRole))'"
            }
        }
        return "<mstts:express-as \(attrs)>\(body)</mstts:express-as>"
    }

    private static func wrapProsody(_ body: String, speaker: NarrativeSpeaker) -> String {
        var attrs: [String] = []
        if !speaker.azurePitch.isEmpty { attrs.append("pitch='\(xmlEscape(speaker.azurePitch))'") }
        if !speaker.azureRate.isEmpty { attrs.append("rate='\(xmlEscape(speaker.azureRate))'") }
        if !speaker.azureVolume.isEmpty { attrs.append("volume='\(xmlEscape(speaker.azureVolume))'") }
        guard !attrs.isEmpty else { return body }
        return "<prosody \(attrs.joined(separator: " "))>\(body)</prosody>"
    }

    private static func formatDouble(_ value: Double) -> String {
        if value == value.rounded() { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }

    /// Azure voice names follow `{lang}-{REGION}-{VoiceName}Neural` (e.g. `zh-CN-XiaochenNeural`).
    /// Return the leading `lang-REGION` portion so the `<speak xml:lang>` root can match the voice.
    private static func locale(fromVoiceName voiceName: String) -> String? {
        let parts = voiceName.split(separator: "-")
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])-\(parts[1])"
    }

    private static func xmlEscape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        return out
    }
}

nonisolated struct NarrativePromptBuilder {
    static func build(
        speakers: [NarrativeSpeaker],
        paragraphs: [NarrativeParagraph],
        scene rawScene: String,
        notes rawNotes: String,
        context rawContext: String
    ) -> String {
        var lines: [String] = []

        let voicedSpeakers = Array(speakers.prefix(2))
        if voicedSpeakers.count >= 2 {
            let a = voicedSpeakers[0].displayName
            let b = voicedSpeakers[1].displayName
            lines.append("Synthesize speech for the following conversation between \(a) and \(b).")
        } else {
            lines.append("Synthesize speech for the following narration.")
        }

        let scene = rawScene.trimmingCharacters(in: .whitespacesAndNewlines)
        if !scene.isEmpty {
            lines.append("")
            lines.append("Scene: \(scene)")
        }

        let notes = rawNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            lines.append("")
            lines.append("Notes: \(notes)")
        }

        let context = rawContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty {
            lines.append("")
            lines.append("Context: \(context)")
        }

        lines.append("")

        let speakersById = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0) })

        for paragraph in paragraphs {
            let speakerName = speakersById[paragraph.speakerId]?.displayName ?? "Narrator"
            let rawContent = paragraph.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawContent.isEmpty else { continue }

            let content = ShortcodeExpander.expandForGemini(rawContent)
            let emotion = paragraph.emotion.trimmingCharacters(in: .whitespacesAndNewlines)
            if emotion.isEmpty {
                lines.append("\(speakerName): \(content)")
            } else {
                lines.append("\(speakerName): [\(emotion)] \(content)")
            }
        }

        return lines.joined(separator: "\n")
    }
}

/// Builds the human-readable transcript/SSML preview shown before generation.
///
/// `@concurrent` forces this onto the global executor (see `AzureTTSClient.generate` for why this is
/// required under Swift 6.2 / SE-0461). Building the preview for a long transcript is O(text length)
/// and was previously done synchronously inside the sheet's view body, which froze the UI the moment
/// the user tapped "Generate". Callers pass `Sendable` snapshots and `await` the result off-main.
nonisolated enum NarrativePreviewBuilder {
    @concurrent
    static func build(
        provider: NarrativeProvider,
        speakers: [NarrativeSpeaker],
        paragraphs: [NarrativeParagraph],
        scene: String,
        notes: String,
        context: String
    ) async -> String {
        switch provider {
        case .azure:
            return AzureSSMLBuilder.build(speakers: speakers, paragraphs: paragraphs)
        case .gemini:
            return NarrativePromptBuilder.build(
                speakers: speakers,
                paragraphs: paragraphs,
                scene: scene,
                notes: notes,
                context: context
            )
        }
    }
}
