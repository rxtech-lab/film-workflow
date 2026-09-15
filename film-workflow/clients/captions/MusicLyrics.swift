import Foundation
import SwiftData
import VideoEditorCore

/// Music uses the caption editor's versioned cues and translations. The link
/// belongs to a take, so editing one recording never changes another's lyrics.
@MainActor
enum MusicLyrics {
    struct Target: Identifiable, Hashable {
        let id: String
        let title: String
    }

    /// The film's recordings, named by `CaptionAudioSource` so the lyrics menu
    /// and the caption menus never disagree about what is on offer.
    static func targets(music: [GeneratedMusic], imported: [ImportedAsset]) -> [Target] {
        CaptionAudioSource.entries(music: music, imported: imported).map {
            Target(id: $0.id, title: $0.title)
        }
    }

    static func project(for sourceID: String, context: ModelContext) throws -> CaptionProject? {
        try context.fetch(FetchDescriptor<CaptionProject>(predicate: #Predicate { $0.lyricsSourceID == sourceID })).first
    }

    /// Detach the lyrics without breaking caption clips or deleting their
    /// text, versions, translations, or the recording's audio file.
    static func remove(from sourceID: String, context: ModelContext) throws {
        guard let lyrics = try project(for: sourceID, context: context) else { return }
        let updatedAt = lyrics.updatedAt
        lyrics.lyricsSourceID = nil
        lyrics.updatedAt = Date()
        do { try context.save() }
        catch {
            lyrics.lyricsSourceID = sourceID
            lyrics.updatedAt = updatedAt
            throw error
        }
    }

    static func suggestedText(for sourceID: String, context: ModelContext) -> String {
        guard let (prefix, id) = DocumentMediaResolver.parse(sourceID), prefix == .music,
              let take = try? context.fetch(FetchDescriptor<GeneratedMusic>(predicate: #Predicate { $0.id == id })).first
        else { return "" }
        // The generated take's text is authoritative; the music setup may have
        // changed since this recording was generated.
        return take.lyricsText ?? ""
    }

    static func prepare(for sourceID: String, context: ModelContext) async throws -> CaptionProject {
        if let existing = try project(for: sourceID, context: context) { return existing }
        guard let audio = CaptionAudioSource.resolve(sourceID, context: context) else { throw LyricsError.missingAudio }
        let url = audio.url
        guard FileManager.default.fileExists(atPath: url.path) else { throw LyricsError.missingAudio }
        let duration = audio.knownDuration > 0 ? audio.knownDuration : (await MediaDurationCache.duration(of: url) ?? 0)
        guard duration.isFinite, duration > 0, duration < Double(Int.max / 1000) else { throw LyricsError.duration }
        // Awaiting media metadata can let a second menu action finish first.
        if let existing = try project(for: sourceID, context: context) { return existing }
        let storage = ProjectStorage.forContainer(context.container)
        let relative = storage.relativePath(for: url)
        let path = try relative ?? storage.importAudio(from: url)
        let lyrics = CaptionProject(name: String(localized: "\(audio.title) — Lyrics"))
        lyrics.lyricsSourceID = sourceID
        lyrics.audioFilePath = path
        lyrics.ownsAudioFile = relative == nil
        lyrics.audioDurationMs = Int((duration * 1000).rounded())
        lyrics.groupID = audio.groupID
        context.insert(lyrics)
        try context.save()
        return lyrics
    }

    /// Copy only the visible caption version. Original captions and older lyric
    /// versions remain available; translations and word timings travel with it.
    static func merge(_ captions: CaptionProject, into lyrics: CaptionProject, context: ModelContext) throws {
        guard captions !== lyrics else { return }
        let rows = captions.orderedSegments
        guard !rows.isEmpty else { throw LyricsError.emptyCaptions }
        lyrics.ensureVersioned()
        var version = captions.activeVersion ?? CaptionTranscriptVersion(languageCode: captions.sourceLanguageCode)
        version.id = UUID()
        version.number = lyrics.nextVersionNumber
        version.createdAt = Date()
        version.segmentCount = rows.count
        version.note = String(localized: "Lyrics from \(captions.name)")
        for (index, row) in rows.enumerated() {
            let copy = CaptionSegment(orderIndex: index, startMs: row.startMs, endMs: row.endMs, text: row.text,
                                      speakerId: row.speakerId, providerSpeakerNumber: row.providerSpeakerNumber,
                                      locale: row.locale, confidence: row.confidence,
                                      isEstimatedTiming: row.isEstimatedTiming, words: row.words)
            copy.isUserEdited = row.isUserEdited
            copy.translations = row.translations
            copy.versionID = version.id
            context.insert(copy)
            copy.project = lyrics
        }
        lyrics.versions.append(version)
        lyrics.activeVersionID = version.id
        lyrics.languageHint = captions.sourceLanguageCode
        lyrics.speakers = captions.speakers
        lyrics.terms = captions.terms
        lyrics.captionStyleData = captions.captionStyleData
        lyrics.displayedTranslationLanguage = captions.displayedTranslationLanguage
        lyrics.refreshTranslationSummary()
        lyrics.updatedAt = Date()
        try context.save()
    }

    /// Draft timings are explicitly estimated. The retimer replaces them with
    /// boundaries recorded while listening to the actual song.
    static func addLines(_ text: String, language: String, to project: CaptionProject, context: ModelContext) throws {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw LyricsError.emptyCaptions }
        guard project.activeSegments.isEmpty else { throw LyricsError.existingLyrics }
        guard project.audioDurationMs >= lines.count else { throw LyricsError.duration }
        let language = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard language.isEmpty || language.range(of: "^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$", options: .regularExpression) != nil
        else { throw LyricsError.language }
        let version = CaptionTranscriptVersion(number: project.nextVersionNumber, languageCode: language,
                                               alignmentQuality: CaptionAlignmentQuality.estimated.rawValue,
                                               segmentCount: lines.count,
                                               warning: String(localized: "These lyric timings are estimated. Use the retimer while listening to the music."))
        for (index, text) in lines.enumerated() {
            let row = CaptionSegment(orderIndex: index, startMs: project.audioDurationMs * index / lines.count,
                                     endMs: project.audioDurationMs * (index + 1) / lines.count, text: text,
                                     locale: language, isEstimatedTiming: true)
            row.versionID = version.id
            context.insert(row)
            row.project = project
        }
        project.versions.append(version)
        project.activeVersionID = version.id
        project.languageHint = language
        project.updatedAt = Date()
        try context.save()
    }

    static func tracks(for project: CaptionProject) -> [MarketplaceLyricTrack] {
        let resolver = CaptionTermResolver(terms: project.usableTerms)
        let rows = project.orderedSegments
        guard !rows.isEmpty else { return [] }
        let language = project.sourceLanguageCode.isEmpty ? "und" : project.sourceLanguageCode
        let original = MarketplaceLyricTrack(language: language, cues: rows.map {
            .init(start: Double($0.startMs) / 1000, end: Double($0.endMs) / 1000,
                  text: resolver.render($0.text, language: project.sourceLanguageCode))
        })
        let languages = Set(rows.flatMap { $0.translatedLanguages }).sorted().filter { $0 != language }
        return [original] + languages.map { code in
            MarketplaceLyricTrack(language: code, cues: rows.compactMap { row in
                guard let text = row.translationMap(resolvedBy: resolver)[code] else { return nil }
                return .init(start: Double(row.startMs) / 1000, end: Double(row.endMs) / 1000, text: text)
            })
        }
    }

    static func tracks(forAudioURL url: URL, context: ModelContext) throws -> [MarketplaceLyricTrack] {
        let projects = try context.fetch(FetchDescriptor<CaptionProject>(predicate: #Predicate { $0.lyricsSourceID != nil }))
        let imports = try context.fetch(FetchDescriptor<ImportedAsset>())
        guard let lyrics = projects.first(where: { project in
            if project.audioURL.standardizedFileURL == url.standardizedFileURL { return true }
            // Referenced audio has a private copy for the caption player. A
            // marketplace draft still starts from the original imported file.
            guard let sourceID = project.lyricsSourceID, let (prefix, id) = DocumentMediaResolver.parse(sourceID), prefix == .imported
            else { return false }
            return imports.first { $0.id == id }?.resolveURL()?.standardizedFileURL == url.standardizedFileURL
        }) else { return [] }
        return tracks(for: lyrics)
    }

    enum LyricsError: LocalizedError {
        case missingAudio, duration, emptyCaptions, existingLyrics, language
        var errorDescription: String? {
            switch self {
            case .missingAudio: String(localized: "The music file is unavailable. Restore or import it before editing lyrics.")
            case .duration: String(localized: "The music duration could not be read.")
            case .emptyCaptions: String(localized: "Add at least one lyric line or choose captions with text.")
            case .existingLyrics: String(localized: "This music already has lyrics. Edit them in the caption view.")
            case .language: String(localized: "Use a language code such as en or zh-Hans, or leave the language empty.")
            }
        }
    }
}
