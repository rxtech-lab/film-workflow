import Foundation

struct AzureSSMLBuilder {
    static func build(from project: NarrativeProject) -> String {
        let speakersById = Dictionary(uniqueKeysWithValues: project.speakers.map { ($0.id, $0) })
        let fallbackVoice = project.speakers.first?.voice ?? "en-US-JennyNeural"
        let rootLang = locale(fromVoiceName: fallbackVoice) ?? "en-US"

        var lines: [String] = []
        lines.append("<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xmlns:mstts='https://www.w3.org/2001/mstts' xml:lang='\(rootLang)'>")

        for paragraph in project.paragraphs {
            let content = paragraph.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }

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

            lines.append("  <voice name='\(xmlEscape(voiceName))'>\(inner)</voice>")
        }

        lines.append("</speak>")
        return lines.joined(separator: "\n")
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

struct NarrativePromptBuilder {
    static func build(from project: NarrativeProject) -> String {
        var lines: [String] = []

        let voicedSpeakers = Array(project.speakers.prefix(2))
        if voicedSpeakers.count >= 2 {
            let a = voicedSpeakers[0].displayName
            let b = voicedSpeakers[1].displayName
            lines.append("Synthesize speech for the following conversation between \(a) and \(b).")
        } else {
            lines.append("Synthesize speech for the following narration.")
        }

        let scene = project.sceneDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !scene.isEmpty {
            lines.append("")
            lines.append("Scene: \(scene)")
        }

        let notes = project.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            lines.append("")
            lines.append("Notes: \(notes)")
        }

        let context = project.context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty {
            lines.append("")
            lines.append("Context: \(context)")
        }

        lines.append("")

        let speakersById = Dictionary(uniqueKeysWithValues: project.speakers.map { ($0.id, $0) })

        for paragraph in project.paragraphs {
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
