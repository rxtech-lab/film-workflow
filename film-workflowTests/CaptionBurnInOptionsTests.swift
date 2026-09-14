import Foundation
import SwiftData
import Testing
import VideoEditorCore

@testable import film_workflow

/// Per-clip caption choices — which languages a caption draws and whether it
/// drops punctuation — reaching the viewer and a burn-in render. The render
/// sheet and the clip inspector both edit these, so what the viewer shows is
/// what a render draws.
@Suite("Caption burn-in options", .serialized)
@MainActor
struct CaptionBurnInOptionsTests {
    private struct Film {
        let root: URL
        let document: ProjectDocument
        let caption: CaptionProject
        let sequence: SequenceProject
    }

    /// Two segments, both translated to zh-Hans, on a caption clip that starts
    /// at 1 s.
    private func makeFilm() throws -> Film {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CaptionBurnIn-\(UUID().uuidString)")
        let document = try ProjectDocument.create(at: root.appendingPathComponent("Test.rxfilmstudio"))
        let context = document.container.mainContext

        let caption = CaptionProject(name: "Talk")
        caption.languageHint = "en"
        caption.audioDurationMs = 2000
        context.insert(caption)
        let rows: [(Int, Int, String, String)] = [(0, 1000, "Hello, world.", "你好，世界。"), (1000, 2000, "Ready?", "好了吗？")]
        for (index, row) in rows.enumerated() {
            let segment = CaptionSegment(orderIndex: index, startMs: row.0, endMs: row.1, text: row.2)
            segment.project = caption
            context.insert(segment)
        }
        caption.ensureVersioned()
        for (segment, row) in zip(caption.orderedSegments, rows) { segment.setTranslation(row.3, language: "zh-Hans") }
        caption.refreshTranslationSummary()

        let sequence = SequenceProject(name: "Cut")
        var timeline = Timeline(width: 320, height: 180, fps: 30)
        let overlay = try #require(timeline.tracks.first { $0.kind == .caption })
        try TimelineEditor.insert(&timeline, clip: Clip(source: caption.clipSource, start: 1, duration: 2, sourceDuration: 2), on: overlay.id)
        sequence.timeline = timeline
        context.insert(sequence)
        try context.save()
        return Film(root: root, document: document, caption: caption, sequence: sequence)
    }

    private func close(_ film: Film) async {
        await film.document.close()
        try? FileManager.default.removeItem(at: film.root)
    }

    private func cues(_ film: Film) async throws -> [TextCue] {
        let resolver = DocumentMediaResolver(document: film.document, width: 320, height: 180, fps: 30)
        guard case .captions(let cues) = try await resolver.resolve(film.caption.clipSource) else { return [] }
        return cues
    }

    @Test("Every translation rides along on the cue, so a clip can pick one")
    func cuesCarryTranslations() async throws {
        let film = try makeFilm()
        defer { Task { await close(film) } }
        let cues = try await cues(film)
        #expect(cues.map(\.text) == ["Hello, world.", "Ready?"])
        #expect(cues[0].translations["zh-Hans"] == "你好，世界。")
        #expect(cues[0].translations[""] == "Hello, world.")
    }

    @Test("A caption clip draws the languages it was given, on the timeline clock")
    func clipDrawsChosenLanguages() async throws {
        let film = try makeFilm()
        defer { Task { await close(film) } }
        let cues = try await cues(film)
        var clip = try #require(film.sequence.timeline.allClips.first { $0.source.kind == .captions })

        #expect(clip.captionCues(cues).map(\.text) == ["Hello, world.", "Ready?"])

        clip.captions = CaptionOptions(languages: ["zh-Hans"])
        #expect(clip.captionCues(cues).map(\.text) == ["你好，世界。", "好了吗？"])

        clip.captions = CaptionOptions(languages: ["", "zh-Hans"])
        let bilingual = clip.captionCues(cues)
        #expect(bilingual.map(\.text) == ["Hello, world.\n你好，世界。", "Ready?\n好了吗？"])
        #expect(bilingual[0].start == 1)
        #expect(bilingual[0].end == 2)

        clip.captions = CaptionOptions(languages: ["", "zh-Hans"], stripsPunctuation: true)
        #expect(clip.captionCues(cues).map(\.text) == ["Hello world\n你好 世界", "Ready\n好了吗"])
    }

    /// Burn-in and a sidecar file written with the same option have to read
    /// alike, and they are stripped by two different implementations.
    @Test("The drawn strip rule matches the caption exporter's")
    func strippingMatchesTheExporter() {
        for sample in ["Hello, world.", "Alice: it's ready — 3 files, right?", "你好，世界。", "好了吗？ 是的！",
                       "…", "Mixed 中文 and English, 100%!"] {
            #expect(CaptionPunctuation.strip(sample) == CaptionText.stripPunctuation(sample))
        }
    }

    @Test("A render that names a burn-in language overrides the clips but keeps their punctuation")
    func renderOverridesLanguages() throws {
        let film = try makeFilm()
        defer { Task { await close(film) } }
        var timeline = film.sequence.timeline
        let clipID = try #require(timeline.allClips.first { $0.source.kind == .captions }?.id)
        try TimelineEditor.update(&timeline, clipID: clipID) {
            $0.captions = CaptionOptions(languages: ["zh-Hans"], stripsPunctuation: true)
        }

        // Nothing named: the clip keeps what the inspector set.
        #expect(CaptionRenderRequest().burnInLanguages == [""])

        let request = CaptionRenderRequest(burnInLanguage: "zh-Hans", burnInBilingual: true)
        #expect(request.burnInLanguages == ["", "zh-Hans"])
        let overridden = SequenceCaptionSources.timeline(timeline, burningIn: request.burnInLanguages)
        let clip = try #require(overridden.clip(id: clipID))
        #expect(clip.captions.languages == ["", "zh-Hans"])
        #expect(clip.captions.stripsPunctuation)
    }

    @Test("The render sheet reads back the languages the clips agree on")
    func effectiveLanguages() throws {
        let film = try makeFilm()
        defer { Task { await close(film) } }
        #expect(SequenceCaptionSources.effectiveBurnInLanguages(in: film.sequence) == [""])

        var timeline = film.sequence.timeline
        let clipID = try #require(timeline.allClips.first { $0.source.kind == .captions }?.id)
        try TimelineEditor.update(&timeline, clipID: clipID) { $0.captions = CaptionOptions(languages: ["", "zh-Hans"]) }
        let overlay = try #require(timeline.tracks.first { $0.kind == .caption }?.id)
        try TimelineEditor.insert(&timeline, clip: Clip(source: film.caption.clipSource, start: 4, duration: 2, sourceDuration: 2), on: overlay)
        film.sequence.timeline = timeline

        // One clip on the transcript and one bilingual: no single answer.
        #expect(SequenceCaptionSources.effectiveBurnInLanguages(in: film.sequence) == nil)
    }
}
