import Foundation
import SwiftData

nonisolated enum CaptionLanguage {
    static let commonCodes = [
        "ar", "bn", "cs", "da", "de", "el", "en", "es", "fa", "fi", "fr", "he", "hi", "hu",
        "id", "it", "ja", "ko", "ms", "nl", "no", "pl", "pt", "pt-BR", "ro", "ru", "sv",
        "ta", "th", "tr", "uk", "ur", "vi", "zh-Hans", "zh-Hant"
    ]

    static func normalized(_ language: String) throws -> String {
        let code = language.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
        if code.isEmpty || code.lowercased() == "und" { return "" }
        guard code.range(of: "^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$", options: .regularExpression) != nil else {
            throw LanguageError.invalidCode
        }
        return code.split(separator: "-").enumerated().map { index, part in
            if index == 0 { return part.lowercased() }
            if part.count == 4 { return part.lowercased().capitalized }
            if part.count == 2 { return part.uppercased() }
            return part.lowercased()
        }.joined(separator: "-")
    }

    enum LanguageError: LocalizedError {
        case invalidCode
        var errorDescription: String? { String(localized: "Use a language code such as en or zh-Hans.") }
    }

    /// Change the text's recorded language, independently of the hint used by
    /// future transcription runs. Other versions and translations stay intact.
    @MainActor
    static func setOriginal(_ language: String, for project: CaptionProject, context: ModelContext) throws {
        let code = try normalized(language)
        let oldVersions = project.versions
        let oldActiveID = project.activeVersionID
        let oldHint = project.languageHint
        let oldUpdatedAt = project.updatedAt
        let oldDisplayedLanguage = project.displayedTranslationLanguage
        let rows = project.activeSegments.map { (segment: $0, locale: $0.locale, versionID: $0.versionID) }
        project.ensureVersioned()
        if let index = project.versions.firstIndex(where: { $0.id == project.activeVersionID }) {
            // Explicitly unspecified must not fall back to an old recognizer hint.
            project.versions[index].languageCode = code.isEmpty ? "und" : code
        } else {
            project.languageHint = code
        }
        for row in rows { row.segment.locale = code }
        project.updatedAt = Date()
        do { try context.save() }
        catch {
            project.versions = oldVersions
            project.activeVersionID = oldActiveID
            project.languageHint = oldHint
            project.updatedAt = oldUpdatedAt
            project.displayedTranslationLanguage = oldDisplayedLanguage
            for row in rows {
                row.segment.locale = row.locale
                row.segment.versionID = row.versionID
            }
            throw error
        }
    }
}
