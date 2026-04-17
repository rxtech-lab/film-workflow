import Foundation

enum ShortcodeSegment: Hashable {
    case text(String)
    case shortcode(name: String, args: [String], wrapped: String?)
}

enum AzureSegment: Hashable {
    case text(String)
    case ssml(String)
}

enum ShortcodeCategory: String, CaseIterable, Hashable {
    case pauses = "Pauses & silence"
    case emotion = "Emotion & delivery"
    case emphasis = "Emphasis"
    case sayAs = "Say-as & pronunciation"
    case language = "Language & markers"

    var sortOrder: Int {
        switch self {
        case .pauses: return 0
        case .emotion: return 1
        case .emphasis: return 2
        case .sayAs: return 3
        case .language: return 4
        }
    }
}

struct ShortcodeDefinition: Identifiable, Hashable {
    let id: String
    let displayName: String
    let insertTemplate: String
    let descriptionText: String
    let providers: Set<NarrativeProvider>
    let wrapsSelection: Bool
    let iconName: String
    let category: ShortcodeCategory
    let shortcodeName: String
}

struct ShortcodeSchema: Hashable {
    struct ArgField: Hashable {
        let label: String
        let placeholder: String
        let suggestions: [String]
    }
    struct WrappedField: Hashable {
        let label: String
        let placeholder: String
    }

    let name: String
    let displayName: String
    let iconName: String
    let args: [ArgField]
    let wrappedField: WrappedField?
}

struct TokenMatch: Hashable {
    let range: NSRange
    let raw: String
    let name: String
    let args: [String]
    let wrapped: String?
}

struct ShortcodeExpander {
    static let catalog: [ShortcodeDefinition] = [
        .init(id: "pause", displayName: "Pause",
              insertTemplate: "{{pause}}",
              descriptionText: "Medium natural pause. Works for both providers.",
              providers: [.azure, .gemini], wrapsSelection: false,
              iconName: "pause.fill", category: .pauses, shortcodeName: "pause"),
        .init(id: "break-short", displayName: "Break — short (250 ms)",
              insertTemplate: "{{break:250ms}}",
              descriptionText: "Silent break of 250 ms.",
              providers: [.azure, .gemini], wrapsSelection: false,
              iconName: "pause", category: .pauses, shortcodeName: "break"),
        .init(id: "break-medium", displayName: "Break — medium (500 ms)",
              insertTemplate: "{{break:500ms}}",
              descriptionText: "Silent break of 500 ms.",
              providers: [.azure, .gemini], wrapsSelection: false,
              iconName: "pause", category: .pauses, shortcodeName: "break"),
        .init(id: "break-long", displayName: "Break — long (1s)",
              insertTemplate: "{{break:1000ms}}",
              descriptionText: "Silent break of one second.",
              providers: [.azure, .gemini], wrapsSelection: false,
              iconName: "pause", category: .pauses, shortcodeName: "break"),
        .init(id: "break-strength", displayName: "Break — strong",
              insertTemplate: "{{break:strong}}",
              descriptionText: "Strength-based break (weak/medium/strong/x-strong).",
              providers: [.azure], wrapsSelection: false,
              iconName: "pause", category: .pauses, shortcodeName: "break"),
        .init(id: "breath", displayName: "Breath",
              insertTemplate: "{{breath}}",
              descriptionText: "Short breath cue (Gemini: [breathes]).",
              providers: [.gemini], wrapsSelection: false,
              iconName: "wind", category: .pauses, shortcodeName: "breath"),
        .init(id: "silence", displayName: "Silence — leading",
              insertTemplate: "{{silence:leading:300ms}}",
              descriptionText: "Insert mstts:silence at leading/tailing/boundary.",
              providers: [.azure], wrapsSelection: false,
              iconName: "speaker.slash", category: .pauses, shortcodeName: "silence"),

        .init(id: "emphasis-strong", displayName: "Emphasis — strong",
              insertTemplate: "{{emphasis:strong|text}}",
              descriptionText: "Stress the wrapped word(s). Azure only.",
              providers: [.azure], wrapsSelection: true,
              iconName: "exclamationmark.circle", category: .emphasis, shortcodeName: "emphasis"),
        .init(id: "emphasis-moderate", displayName: "Emphasis — moderate",
              insertTemplate: "{{emphasis:moderate|text}}",
              descriptionText: "Light stress on the wrapped word(s).",
              providers: [.azure], wrapsSelection: true,
              iconName: "exclamationmark.circle", category: .emphasis, shortcodeName: "emphasis"),

        .init(id: "spell", displayName: "Spell out",
              insertTemplate: "{{spell|W3C}}",
              descriptionText: "Read letter by letter. Maps to say-as interpret-as='spell-out'.",
              providers: [.azure], wrapsSelection: true,
              iconName: "textformat.abc", category: .sayAs, shortcodeName: "spell"),
        .init(id: "say-date", displayName: "Say as — date",
              insertTemplate: "{{say:date:mdy|10/15/2024}}",
              descriptionText: "say-as interpret-as='date' with a format hint.",
              providers: [.azure], wrapsSelection: true,
              iconName: "calendar", category: .sayAs, shortcodeName: "say"),
        .init(id: "say-number", displayName: "Say as — number",
              insertTemplate: "{{say:cardinal|1234}}",
              descriptionText: "say-as interpret-as='cardinal'.",
              providers: [.azure], wrapsSelection: true,
              iconName: "number", category: .sayAs, shortcodeName: "say"),
        .init(id: "say-telephone", displayName: "Say as — telephone",
              insertTemplate: "{{say:telephone|555-0199}}",
              descriptionText: "say-as interpret-as='telephone'.",
              providers: [.azure], wrapsSelection: true,
              iconName: "phone", category: .sayAs, shortcodeName: "say"),
        .init(id: "phoneme", displayName: "Phoneme (IPA)",
              insertTemplate: "{{phoneme:ipa:təˈmeɪtoʊ|tomato}}",
              descriptionText: "Explicit pronunciation using IPA.",
              providers: [.azure], wrapsSelection: true,
              iconName: "waveform", category: .sayAs, shortcodeName: "phoneme"),
        .init(id: "sub", displayName: "Substitute (read as)",
              insertTemplate: "{{sub:World Wide Web Consortium|W3C}}",
              descriptionText: "Speak the alias in place of the written text.",
              providers: [.azure], wrapsSelection: true,
              iconName: "arrow.2.squarepath", category: .sayAs, shortcodeName: "sub"),

        .init(id: "lang", displayName: "Language switch",
              insertTemplate: "{{lang:de-DE|Guten Tag}}",
              descriptionText: "Temporary language override (multilingual voices).",
              providers: [.azure], wrapsSelection: true,
              iconName: "globe", category: .language, shortcodeName: "lang"),
        .init(id: "bookmark", displayName: "Bookmark",
              insertTemplate: "{{bookmark:scene1}}",
              descriptionText: "Named marker in the audio stream.",
              providers: [.azure], wrapsSelection: false,
              iconName: "bookmark", category: .language, shortcodeName: "bookmark"),

        .init(id: "whispers", displayName: "Whisper",
              insertTemplate: "{{whispers|text}}",
              descriptionText: "Whispered delivery (Gemini).",
              providers: [.gemini], wrapsSelection: true,
              iconName: "waveform.badge.mic", category: .emotion, shortcodeName: "whispers"),
        .init(id: "excited", displayName: "Excited tone",
              insertTemplate: "{{excited|text}}",
              descriptionText: "[excited] delivery. Gemini natural-language cue.",
              providers: [.gemini], wrapsSelection: true,
              iconName: "sparkles", category: .emotion, shortcodeName: "excited"),
        .init(id: "sad", displayName: "Sad tone",
              insertTemplate: "{{sad|text}}",
              descriptionText: "[sad] delivery. Gemini natural-language cue.",
              providers: [.gemini], wrapsSelection: true,
              iconName: "cloud.rain", category: .emotion, shortcodeName: "sad"),
        .init(id: "laughs", displayName: "Laugh",
              insertTemplate: "{{laughs}}",
              descriptionText: "[laughs] cue (Gemini).",
              providers: [.gemini], wrapsSelection: false,
              iconName: "face.smiling", category: .emotion, shortcodeName: "laughs"),
        .init(id: "sighs", displayName: "Sigh",
              insertTemplate: "{{sighs}}",
              descriptionText: "[sighs] cue (Gemini).",
              providers: [.gemini], wrapsSelection: false,
              iconName: "wind.snow", category: .emotion, shortcodeName: "sighs"),
        .init(id: "gasps", displayName: "Gasp",
              insertTemplate: "{{gasps}}",
              descriptionText: "[gasps] cue (Gemini).",
              providers: [.gemini], wrapsSelection: false,
              iconName: "exclamationmark.bubble", category: .emotion, shortcodeName: "gasps"),
    ]

    static func catalog(for provider: NarrativeProvider) -> [ShortcodeDefinition] {
        catalog.filter { $0.providers.contains(provider) }
    }

    static func catalogGrouped(for provider: NarrativeProvider) -> [(category: ShortcodeCategory, items: [ShortcodeDefinition])] {
        let filtered = catalog(for: provider)
        let grouped = Dictionary(grouping: filtered, by: { $0.category })
        return grouped
            .map { (category: $0.key, items: $0.value) }
            .sorted { $0.category.sortOrder < $1.category.sortOrder }
    }

    /// Unique shortcode schemas (deduped by schema name) for a provider, grouped by category.
    /// Used by the edit form's dropdown so users can switch an existing token to a different shortcode.
    static func uniqueSchemasGrouped(for provider: NarrativeProvider) -> [(category: ShortcodeCategory, items: [ShortcodeSchema])] {
        let definitions = catalog(for: provider)
        var seen = Set<String>()
        var byCategory: [ShortcodeCategory: [ShortcodeSchema]] = [:]
        for definition in definitions {
            if seen.contains(definition.shortcodeName) { continue }
            seen.insert(definition.shortcodeName)
            byCategory[definition.category, default: []].append(schema(forName: definition.shortcodeName))
        }
        return byCategory
            .map { (category: $0.key, items: $0.value) }
            .sorted { $0.category.sortOrder < $1.category.sortOrder }
    }

    // MARK: - Schemas (edit forms)

    static let schemas: [String: ShortcodeSchema] = [
        "pause": ShortcodeSchema(name: "pause", displayName: "Pause",
                                 iconName: "pause.fill", args: [], wrappedField: nil),
        "break": ShortcodeSchema(
            name: "break", displayName: "Break",
            iconName: "pause",
            args: [
                .init(label: "Duration or strength",
                      placeholder: "500ms",
                      suggestions: ["250ms", "500ms", "1000ms", "2000ms", "weak", "medium", "strong", "x-strong"])
            ],
            wrappedField: nil),
        "breath": ShortcodeSchema(name: "breath", displayName: "Breath",
                                  iconName: "wind", args: [], wrappedField: nil),
        "silence": ShortcodeSchema(
            name: "silence", displayName: "Silence",
            iconName: "speaker.slash",
            args: [
                .init(label: "Type", placeholder: "leading",
                      suggestions: ["leading", "leading-exact", "tailing", "tailing-exact", "sentenceboundary", "comma-exact"]),
                .init(label: "Value", placeholder: "300ms",
                      suggestions: ["100ms", "300ms", "500ms", "1000ms"]),
            ],
            wrappedField: nil),
        "emphasis": ShortcodeSchema(
            name: "emphasis", displayName: "Emphasis",
            iconName: "exclamationmark.circle",
            args: [
                .init(label: "Level", placeholder: "strong",
                      suggestions: ["reduced", "moderate", "strong"])
            ],
            wrappedField: .init(label: "Text", placeholder: "word")),
        "spell": ShortcodeSchema(
            name: "spell", displayName: "Spell out",
            iconName: "textformat.abc", args: [],
            wrappedField: .init(label: "Text", placeholder: "W3C")),
        "say": ShortcodeSchema(
            name: "say", displayName: "Say as",
            iconName: "text.redaction",
            args: [
                .init(label: "Interpret as", placeholder: "cardinal",
                      suggestions: ["characters", "spell-out", "cardinal", "ordinal", "date", "time", "telephone", "currency", "address"]),
                .init(label: "Format (optional)", placeholder: "mdy",
                      suggestions: ["", "mdy", "dmy", "ymd", "hms12", "hms24"]),
            ],
            wrappedField: .init(label: "Text", placeholder: "value")),
        "phoneme": ShortcodeSchema(
            name: "phoneme", displayName: "Phoneme",
            iconName: "waveform",
            args: [
                .init(label: "Alphabet", placeholder: "ipa",
                      suggestions: ["ipa", "sapi", "ups", "x-sampa"]),
                .init(label: "Phonemes", placeholder: "təˈmeɪtoʊ", suggestions: []),
            ],
            wrappedField: .init(label: "Written text", placeholder: "tomato")),
        "sub": ShortcodeSchema(
            name: "sub", displayName: "Substitute",
            iconName: "arrow.2.squarepath",
            args: [.init(label: "Alias (spoken)", placeholder: "World Wide Web Consortium", suggestions: [])],
            wrappedField: .init(label: "Written text", placeholder: "W3C")),
        "lang": ShortcodeSchema(
            name: "lang", displayName: "Language",
            iconName: "globe",
            args: [.init(label: "Locale", placeholder: "de-DE",
                         suggestions: ["en-US", "en-GB", "de-DE", "fr-FR", "es-ES", "it-IT", "ja-JP", "zh-CN", "zh-TW", "ko-KR"])],
            wrappedField: .init(label: "Text", placeholder: "Guten Tag")),
        "bookmark": ShortcodeSchema(
            name: "bookmark", displayName: "Bookmark",
            iconName: "bookmark",
            args: [.init(label: "Mark name", placeholder: "scene1", suggestions: [])],
            wrappedField: nil),
        "whispers": ShortcodeSchema(
            name: "whispers", displayName: "Whisper",
            iconName: "waveform.badge.mic", args: [],
            wrappedField: .init(label: "Text", placeholder: "secret")),
        "excited": ShortcodeSchema(
            name: "excited", displayName: "Excited",
            iconName: "sparkles", args: [],
            wrappedField: .init(label: "Text", placeholder: "great news")),
        "sad": ShortcodeSchema(
            name: "sad", displayName: "Sad",
            iconName: "cloud.rain", args: [],
            wrappedField: .init(label: "Text", placeholder: "bad news")),
        "laughs": ShortcodeSchema(name: "laughs", displayName: "Laugh",
                                  iconName: "face.smiling", args: [], wrappedField: nil),
        "sighs": ShortcodeSchema(name: "sighs", displayName: "Sigh",
                                 iconName: "wind.snow", args: [], wrappedField: nil),
        "gasps": ShortcodeSchema(name: "gasps", displayName: "Gasp",
                                 iconName: "exclamationmark.bubble", args: [], wrappedField: nil),
    ]

    static func schema(forName name: String) -> ShortcodeSchema {
        schemas[name] ?? ShortcodeSchema(
            name: name, displayName: name, iconName: "tag",
            args: [], wrappedField: .init(label: "Text", placeholder: "")
        )
    }

    // MARK: - Parsing

    static func parse(_ text: String) -> [ShortcodeSegment] {
        let ns = text as NSString
        var segments: [ShortcodeSegment] = []
        var cursor = 0
        for match in tokenMatches(in: text) {
            if match.range.location > cursor {
                let before = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                if !before.isEmpty { segments.append(.text(before)) }
            }
            segments.append(.shortcode(name: match.name, args: match.args, wrapped: match.wrapped))
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            let trailing = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            if !trailing.isEmpty { segments.append(.text(trailing)) }
        }
        return segments
    }

    static func tokenMatches(in text: String) -> [TokenMatch] {
        guard let regex = try? NSRegularExpression(pattern: "\\{\\{([^{}]+)\\}\\}") else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, range: range).map { match in
            let inner = ns.substring(with: match.range(at: 1))
            let (name, args, wrapped) = splitShortcode(inner)
            let raw = ns.substring(with: match.range)
            return TokenMatch(range: match.range, raw: raw, name: name, args: args, wrapped: wrapped)
        }
    }

    private static func splitShortcode(_ inner: String) -> (String, [String], String?) {
        let pipeParts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let head = pipeParts[0]
        let wrapped = pipeParts.count > 1 ? pipeParts[1] : nil
        let headParts = head.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let name = headParts.first ?? ""
        let args = Array(headParts.dropFirst())
        return (name.trimmingCharacters(in: .whitespaces), args, wrapped)
    }

    static func serialize(name: String, args: [String], wrapped: String?) -> String {
        var trimmedArgs = args
        while let last = trimmedArgs.last, last.isEmpty { trimmedArgs.removeLast() }

        var head = name
        for arg in trimmedArgs { head += ":\(arg)" }

        if let wrapped = wrapped {
            return "{{\(head)|\(wrapped)}}"
        }
        return "{{\(head)}}"
    }

    static func chipSummary(name: String, args: [String], wrapped: String?) -> String {
        let schema = schema(forName: name)
        var parts: [String] = []
        for arg in args where !arg.isEmpty { parts.append(arg) }
        if let wrapped = wrapped, !wrapped.isEmpty {
            parts.append("“\(wrapped.truncatedMiddle(max: 16))”")
        }
        if parts.isEmpty { return schema.displayName }
        return schema.displayName + " · " + parts.joined(separator: " ")
    }

    // MARK: - Azure expansion

    static func expandForAzure(_ text: String) -> [AzureSegment] {
        let segments = parse(text)
        var out: [AzureSegment] = []
        for segment in segments {
            switch segment {
            case .text(let s):
                out.append(.text(s))
            case .shortcode(let name, let args, let wrapped):
                out.append(contentsOf: azureSegments(name: name, args: args, wrapped: wrapped))
            }
        }
        return out
    }

    private static func azureSegments(name: String, args: [String], wrapped: String?) -> [AzureSegment] {
        switch name {
        case "break":
            if let first = args.first, !first.isEmpty {
                if first.hasSuffix("ms") || first.hasSuffix("s") {
                    return [.ssml("<break time=\"\(first)\"/>")]
                } else {
                    return [.ssml("<break strength=\"\(first)\"/>")]
                }
            }
            return [.ssml("<break/>")]

        case "pause":
            return [.ssml("<break time=\"500ms\"/>")]

        case "breath", "laughs", "sighs", "gasps":
            return [.ssml("<break time=\"300ms\"/>")]

        case "silence":
            let type = args.first.map(azureSilenceType) ?? "Leading"
            let value = args.count > 1 ? args[1] : "300ms"
            return [.ssml("<mstts:silence type=\"\(type)\" value=\"\(value)\"/>")]

        case "emphasis":
            let level = args.first ?? "moderate"
            let body = xmlEscape(wrapped ?? "")
            return [.ssml("<emphasis level=\"\(level)\">\(body)</emphasis>")]

        case "spell":
            let body = xmlEscape(wrapped ?? "")
            return [.ssml("<say-as interpret-as=\"spell-out\">\(body)</say-as>")]

        case "say":
            let interpret = args.first ?? "cardinal"
            let format = args.count > 1 ? args[1] : nil
            let body = xmlEscape(wrapped ?? "")
            if let format = format, !format.isEmpty {
                return [.ssml("<say-as interpret-as=\"\(interpret)\" format=\"\(format)\">\(body)</say-as>")]
            }
            return [.ssml("<say-as interpret-as=\"\(interpret)\">\(body)</say-as>")]

        case "phoneme":
            let alphabet = args.first ?? "ipa"
            let ph = args.count > 1 ? args[1] : ""
            let body = xmlEscape(wrapped ?? "")
            return [.ssml("<phoneme alphabet=\"\(alphabet)\" ph=\"\(xmlEscape(ph))\">\(body)</phoneme>")]

        case "sub":
            let alias = args.first ?? ""
            let body = xmlEscape(wrapped ?? "")
            return [.ssml("<sub alias=\"\(xmlEscape(alias))\">\(body)</sub>")]

        case "lang":
            let locale = args.first ?? "en-US"
            let body = xmlEscape(wrapped ?? "")
            return [.ssml("<lang xml:lang=\"\(locale)\">\(body)</lang>")]

        case "bookmark":
            let mark = args.first ?? ""
            return [.ssml("<bookmark mark=\"\(xmlEscape(mark))\"/>")]

        case "whispers", "excited", "sad":
            if let wrapped = wrapped { return [.text(wrapped)] }
            return []

        default:
            if let wrapped = wrapped { return [.text(wrapped)] }
            return []
        }
    }

    private static func azureSilenceType(_ raw: String) -> String {
        switch raw.lowercased() {
        case "leading": return "Leading"
        case "leading-exact": return "Leading-exact"
        case "tailing": return "Tailing"
        case "tailing-exact": return "Tailing-exact"
        case "sentenceboundary": return "Sentenceboundary"
        case "comma-exact": return "Comma-exact"
        default: return raw
        }
    }

    // MARK: - Gemini expansion

    static func expandForGemini(_ text: String) -> String {
        let segments = parse(text)
        var out = ""
        for segment in segments {
            switch segment {
            case .text(let s):
                out += s
            case .shortcode(let name, let args, let wrapped):
                out += geminiString(name: name, args: args, wrapped: wrapped)
            }
        }
        return out
    }

    private static func geminiString(name: String, args: [String], wrapped: String?) -> String {
        switch name {
        case "pause", "break":
            let arg = args.first ?? ""
            if arg == "strong" || arg == "x-strong" { return "[long pause]" }
            return "[pause]"
        case "breath": return "[breathes]"
        case "laughs": return "[laughs]"
        case "sighs": return "[sighs]"
        case "gasps": return "[gasps]"
        case "whispers": return "[whispering] " + (wrapped ?? "")
        case "excited": return "[excited] " + (wrapped ?? "")
        case "sad": return "[sad] " + (wrapped ?? "")
        case "silence", "bookmark":
            return ""
        case "emphasis", "spell", "say", "phoneme", "sub", "lang":
            return wrapped ?? ""
        default:
            return wrapped ?? ""
        }
    }

    // MARK: - Helpers

    static func xmlEscape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        return out
    }
}

private extension String {
    func truncatedMiddle(max: Int) -> String {
        guard count > max else { return self }
        let head = prefix(max / 2)
        let tail = suffix(max / 2)
        return "\(head)…\(tail)"
    }
}
