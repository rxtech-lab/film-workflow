import AVFoundation
import Foundation
import SwiftData
import Testing
import VideoEditorCore

@testable import film_workflow

/// Caption clips on a timeline reaching a render three ways: burned in with
/// a chosen language, as tx3g tracks, or as files beside the movie.
@Suite("Sequence caption export", .serialized)
@MainActor
struct SequenceCaptionExportTests {
    private struct Film {
        let root: URL
        let document: ProjectDocument
        let context: ModelContext
        let caption: CaptionProject
        let sequence: SequenceProject
    }

    /// A caption project of three segments (two translated to zh-Hans, one
    /// using a glossary term) on an overlay clip that starts at 1 s and skips
    /// the first half second of the transcript.
    private func makeFilm() throws -> Film {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SequenceCaptionExport-\(UUID().uuidString)")
        let document = try ProjectDocument.create(at: root.appendingPathComponent("Test.rxfilmstudio"))
        let context = document.container.mainContext

        let caption = CaptionProject(name: "Talk")
        caption.languageHint = "en"
        caption.audioDurationMs = 4000
        caption.terms = [CaptionTerm(text: "RxLab", translations: ["zh-Hans": "睿析"])]
        context.insert(caption)
        let rows: [(Int, Int, String, String?)] = [(0, 1000, "Hello {{RxLab}}", "你好 {{RxLab}}"), (1000, 3000, "World", "世界"), (3000, 4000, "Untranslated", nil)]
        for (index, row) in rows.enumerated() {
            let segment = CaptionSegment(orderIndex: index, startMs: row.0, endMs: row.1, text: row.2)
            segment.project = caption
            context.insert(segment)
        }
        caption.ensureVersioned()
        for (segment, row) in zip(caption.orderedSegments, rows) {
            if let translation = row.3 { segment.setTranslation(translation, language: "zh-Hans") }
        }
        caption.refreshTranslationSummary()

        let sequence = SequenceProject(name: "Cut")
        var timeline = Timeline(width: 320, height: 180, fps: 30)
        let overlay = try #require(timeline.tracks.first { $0.kind == .overlay })
        try TimelineEditor.insert(&timeline, clip: Clip(source: caption.clipSource, start: 1, duration: 3, inPoint: 0.5, sourceDuration: 4,
                                                        text: TextStyle(fontSize: 0.1, alignment: .leading)), on: overlay.id)
        sequence.timeline = timeline
        context.insert(sequence)
        try context.save()
        return Film(root: root, document: document, context: context, caption: caption, sequence: sequence)
    }

    private func close(_ film: Film) async {
        await film.document.close()
        try? FileManager.default.removeItem(at: film.root)
    }

    @Test("The resolver serves the original, a translation, or both, with glossary terms rendered")
    func resolverLanguages() async throws {
        let film = try makeFilm()
        defer { Task { await close(film) } }
        func texts(_ selection: CaptionTextSelection) async throws -> [String] {
            let resolver = DocumentMediaResolver(document: film.document, width: 320, height: 180, fps: 30, captionText: selection)
            guard case .captions(let cues) = try await resolver.resolve(film.caption.clipSource) else { return [] }
            return cues.map(\.text)
        }
        #expect(try await texts(.original) == ["Hello RxLab", "World", "Untranslated"])
        #expect(try await texts(.translation("zh-Hans")) == ["你好 睿析", "世界", "Untranslated"])
        #expect(try await texts(.bilingual("zh-Hans")) == ["Hello RxLab\n你好 睿析", "World\n世界", "Untranslated"])
        #expect(try await texts(.translation("fr")) == ["Hello RxLab", "World", "Untranslated"])
    }

    @Test("Caption tracks and the sidecar transcript sit on the timeline clock")
    func timelineTiming() async throws {
        let film = try makeFilm()
        defer { Task { await close(film) } }
        #expect(SequenceCaptionSources.hasCaptions(in: film.sequence))
        #expect(SequenceCaptionSources.availableLanguages(in: film.sequence, context: film.context) == ["", "zh-Hans"])
        #expect(SequenceCaptionSources.effectiveStyle(in: film.sequence).alignment == .leading)

        let tracks = try await SequenceCaptionSources.captionTracks(in: film.sequence, document: film.document, languages: ["", "zh-Hans"])
        #expect(tracks.map(\.languageCode) == ["en", "zh-Hans"])
        #expect(tracks[0].cues.map(\.start) == [1, 1.5, 3.5])
        #expect(tracks[0].cues.map(\.end) == [1.5, 3.5, 4])
        #expect(tracks[1].cues.map(\.text) == ["你好 睿析", "世界", "Untranslated"])

        let snapshot = try #require(SequenceCaptionSources.sidecarSnapshot(in: film.sequence, context: film.context))
        #expect(snapshot.segments.map(\.startMs) == [1000, 1500, 3500])
        #expect(snapshot.segments.map(\.endMs) == [1500, 3500, 4000])
        #expect(snapshot.segments.map(\.text) == ["Hello RxLab", "World", "Untranslated"])
        #expect(snapshot.segments[0].translations["zh-Hans"] == "你好 睿析")
        #expect(snapshot.sourceLanguage == "en")
        #expect(snapshot.availableTranslations == ["zh-Hans"])
        #expect(snapshot.projectName == "Cut")
    }

    @Test("Sidecar files are named after the movie and the language")
    func sidecarNames() {
        #expect(SequenceCaptionSources.sidecarFilename(movieStem: "Cut", languageCode: "", sourceLanguage: "en", format: .srt) == "Cut.en.srt")
        #expect(SequenceCaptionSources.sidecarFilename(movieStem: "Cut 2", languageCode: "", sourceLanguage: "", format: .srt) == "Cut 2.original.srt")
        #expect(SequenceCaptionSources.sidecarFilename(movieStem: "v003", languageCode: "zh-Hans", sourceLanguage: "en", format: .vtt) == "v003.zh-Hans.vtt")
    }

    @Test("A folder render writes one caption file per language beside the movie")
    func sidecarToFolder() async throws {
        let film = try makeFilm()
        defer { Task { await close(film) } }
        let output = try await SequenceRenderService.render(
            sequence: film.sequence, document: film.document,
            options: .init(video: .h264, audio: nil, captions: .sidecar),
            captions: CaptionRenderRequest(trackLanguages: ["", "zh-Hans", "fr"], sidecarFormat: .srt),
            destination: .folder(film.root)
        ) { _ in }
        #expect(output.url.lastPathComponent == "Cut.mp4")
        #expect(output.captionFiles.map(\.lastPathComponent) == ["Cut.en.srt", "Cut.zh-Hans.srt"])
        let english = try String(contentsOf: output.captionFiles[0], encoding: .utf8)
        #expect(english.contains("Hello RxLab"))
        #expect(english.contains("00:00:01,000 --> 00:00:01,500"))
        let chinese = try String(contentsOf: output.captionFiles[1], encoding: .utf8)
        #expect(chinese.contains("你好 睿析"))
        #expect(!chinese.contains("Hello"))
    }

    @Test("A film render records its caption files and deletes them with the version")
    func sidecarInFilm() async throws {
        let film = try makeFilm()
        defer { Task { await close(film) } }
        let output = try await SequenceRenderService.render(
            sequence: film.sequence, document: film.document,
            options: .init(video: .h264, audio: nil, captions: .sidecar),
            captions: CaptionRenderRequest(trackLanguages: ["", "zh-Hans"], sidecarFormat: .vtt),
            destination: .film
        ) { _ in }
        guard case .version(let render) = output else { Issue.record("expected a version"); return }
        #expect(render.captionFilePaths.count == 2)
        #expect(render.captionFileURLs.map(\.lastPathComponent) == ["v001.en.vtt", "v001.zh-Hans.vtt"])
        #expect(render.captionFileURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let exported = film.root.appendingPathComponent("Cut-v1.mp4")
        try SequenceRenderService.export(render, to: exported)
        #expect(FileManager.default.fileExists(atPath: film.root.appendingPathComponent("Cut-v1.zh-Hans.vtt").path))
        let files = render.captionFileURLs
        SequenceRenderService.delete(render, context: film.context)
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test("An embedded render carries one subtitle track per language and leaves no temporary file")
    func embedded() async throws {
        let film = try makeFilm()
        defer { Task { await close(film) } }
        var progress: [SequenceRenderProgress] = []
        let output = try await SequenceRenderService.render(
            sequence: film.sequence, document: film.document,
            options: .init(video: .h264, audio: nil, container: .mov, captions: .embedded),
            captions: CaptionRenderRequest(trackLanguages: ["", "zh-Hans"]),
            destination: .folder(film.root)
        ) { progress.append($0) }
        #expect(progress.contains(.embeddingCaptions))
        #expect(progress.last == .finalizing)
        #expect(output.url.lastPathComponent == "Cut.mov")
        #expect(output.captionFiles.isEmpty)
        let asset = AVURLAsset(url: output.url)
        let subtitles = try await asset.loadTracks(withMediaType: .subtitle)
        #expect(subtitles.count == 2)
        var tags: [String?] = []
        for track in subtitles { tags.append(try await track.load(.extendedLanguageTag)) }
        #expect(tags == ["en", "zh-Hans"])
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: film.root.path).filter { $0.hasPrefix(".Cut") }
        #expect(leftovers.isEmpty)
    }

    @Test("Without caption clips the delivery is ignored")
    func noCaptions() async throws {
        let film = try makeFilm()
        defer { Task { await close(film) } }
        var timeline = film.sequence.timeline
        TimelineEditor.remove(&timeline, clipIDs: Set(timeline.allClips.map(\.id)))
        film.sequence.timeline = timeline
        let output = try await SequenceRenderService.render(
            sequence: film.sequence, document: film.document,
            options: .init(video: .h264, audio: nil, captions: .sidecar),
            destination: .folder(film.root)
        ) { _ in }
        #expect(output.captionFiles.isEmpty)
    }

    @Test("MCP caption arguments are validated against the timeline")
    func mcpArguments() throws {
        let film = try makeFilm()
        defer { Task { await close(film) } }
        var options = TimelineExporter.Options()
        let request = try MCPSequenceHandlers.captionRequest(
            ["captions": "sidecar", "caption_languages": ["zh-Hans", ""], "caption_bilingual": true, "caption_sidecar_format": "vtt"],
            options: &options, sequence: film.sequence, context: film.context
        )
        #expect(options.captions == .sidecar)
        #expect(request.trackLanguages == ["zh-Hans", ""])
        #expect(request.burnInLanguage == "zh-Hans")
        #expect(request.burnInBilingual)
        #expect(request.sidecarFormat == .vtt)

        #expect(throws: MCPToolError.self) {
            _ = try MCPSequenceHandlers.captionRequest(["captions": "burn"], options: &options, sequence: film.sequence, context: film.context)
        }
        #expect(throws: MCPToolError.self) {
            _ = try MCPSequenceHandlers.captionRequest(["caption_languages": ["fr"]], options: &options, sequence: film.sequence, context: film.context)
        }
        #expect(throws: MCPToolError.self) {
            _ = try MCPSequenceHandlers.captionRequest(["caption_sidecar_format": "json"], options: &options, sequence: film.sequence, context: film.context)
        }
    }

    @Test("Caption requests decode with defaults and narrow to what a film offers")
    func requestCodec() throws {
        let legacy = try JSONDecoder().decode(CaptionRenderRequest.self, from: Data("{}".utf8))
        #expect(legacy == CaptionRenderRequest())
        let request = CaptionRenderRequest(burnInLanguage: "fr", burnInBilingual: true, trackLanguages: ["fr", "de"], sidecarFormat: .json)
        let data = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(CaptionRenderRequest.self, from: data) == request)
        let narrowed = request.narrowed(to: ["", "de"])
        #expect(narrowed.burnInLanguage == "")
        #expect(narrowed.trackLanguages == ["de"])
        #expect(narrowed.sidecarFormat == .srt)
        #expect(request.narrowed(to: [""]).trackLanguages == [""])
        #expect(CaptionRenderRequest(burnInLanguage: "de", burnInBilingual: true).burnInSelection == .bilingual("de"))
        #expect(CaptionRenderRequest(burnInLanguage: "de").burnInSelection == .translation("de"))
        #expect(CaptionRenderRequest().burnInSelection == .original)
    }
}
