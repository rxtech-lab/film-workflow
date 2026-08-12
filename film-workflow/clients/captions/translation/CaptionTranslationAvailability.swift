import Foundation
import Translation

/// Which languages Apple's translation engine can actually produce here.
///
/// Mirrors `AgentBackendAvailability` and `WhisperModelStore`: an observable
/// main-actor singleton the UI reads directly, refreshed on demand rather than
/// at launch. `LanguageAvailability` is an async query, and there is no reason
/// to pay for it before someone opens a language picker.
@MainActor
@Observable
final class CaptionTranslationAvailability {
    static let shared = CaptionTranslationAvailability()

    /// Every language the system can translate into, sorted by localized name.
    private(set) var supportedTargets: [String] = []
    private(set) var hasLoaded = false

    private init() {}

    func refreshIfNeeded() async {
        guard !hasLoaded else { return }
        await refresh()
    }

    func refresh() async {
        let languages = await LanguageAvailability().supportedLanguages
        var codes: Set<String> = []
        for language in languages {
            guard let code = language.languageCode?.identifier else { continue }
            // Prefer the fully-qualified identifier when there is a script or
            // region — "zh-Hans" and "zh-Hant" are different files to a reader.
            codes.insert(language.maximalIdentifier.isEmpty ? code : Self.normalize(language))
        }
        supportedTargets = codes.sorted { Self.displayName($0) < Self.displayName($1) }
        hasLoaded = true
    }

    /// Whether Apple can translate this pair right now, and whether it would
    /// need a download first.
    ///
    /// Returns nil when the source language is unknown: `status(from:to:)` needs
    /// a concrete pair, and the sample-text overload would have us invent text
    /// to probe with. An unknown source is not an error — the session detects it
    /// at translation time — so the caller just skips the pre-flight check.
    func status(from source: String, to target: String) async -> LanguageAvailability.Status? {
        guard !target.isEmpty, !source.isEmpty else { return nil }
        return await LanguageAvailability().status(
            from: Locale.Language(identifier: source),
            to: Locale.Language(identifier: target)
        )
    }

    /// Localized name of a BCP-47 code, falling back to the code itself.
    ///
    /// `nonisolated static` so every view, exporter and MCP summary can name a
    /// language without touching the singleton or hopping actors.
    nonisolated static func displayName(_ code: String) -> String {
        guard !code.isEmpty else { return "" }
        return Locale.current.localizedString(forIdentifier: code) ?? code
    }

    /// The shortest identifier that still distinguishes the language, e.g.
    /// "en", but "zh-Hans" rather than "zh".
    private nonisolated static func normalize(_ language: Locale.Language) -> String {
        guard let code = language.languageCode?.identifier else { return "" }
        if let script = language.script?.identifier, !script.isEmpty {
            return "\(code)-\(script)"
        }
        return code
    }
}
