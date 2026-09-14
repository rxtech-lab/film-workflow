import Foundation
import Testing
@testable import VideoEditorCore

@Suite("Caption burn-in options")
struct CaptionOptionsTests {
    /// A resolver that carries translations keeps the transcript under "" as
    /// well, so a clip can ask for it by name whatever `text` happens to be.
    private let cue = TextCue(start: 0.5, end: 2, text: "Hello, world.", translations: [
        "": "Hello, world.",
        "zh-Hans": "你好，世界。",
        "de": "",
    ])

    @Test("A caption draws each language it names, on its own line")
    func stacksLanguages() {
        #expect(CaptionOptions().text(for: cue) == "Hello, world.")
        #expect(CaptionOptions(languages: ["zh-Hans"]).text(for: cue) == "你好，世界。")
        #expect(CaptionOptions(languages: ["", "zh-Hans"]).text(for: cue) == "Hello, world.\n你好，世界。")
        #expect(CaptionOptions(languages: ["zh-Hans", ""]).text(for: cue) == "你好，世界。\nHello, world.")
    }

    @Test("A language the project has not translated falls back without repeating a line")
    func fallsBackToTheTranscript() {
        #expect(CaptionOptions(languages: ["de"]).text(for: cue) == "Hello, world.")
        // Original + an untranslated language would otherwise print twice.
        #expect(CaptionOptions(languages: ["", "de"]).text(for: cue) == "Hello, world.")
        #expect(CaptionOptions(languages: ["", "de", "zh-Hans"]).text(for: cue) == "Hello, world.\n你好，世界。")
    }

    @Test("Repeats and an empty choice cannot reach the drawing code")
    func normalizesLanguages() {
        #expect(CaptionOptions(languages: ["zh-Hans", "zh-Hans", ""]).languages == ["zh-Hans", ""])
        #expect(CaptionOptions(languages: []).languages == [""])
    }

    @Test("Stripping punctuation keeps words, digits and structural colons")
    func stripsPunctuation() {
        let spoken = TextCue(start: 0, end: 1, text: "Alice: it's ready — 3 files, right?",
                             translations: ["zh-Hans": "爱丽丝：好了，三个文件。"])
        let options = CaptionOptions(languages: ["", "zh-Hans"], stripsPunctuation: true)
        #expect(options.text(for: spoken) == "Alice: it s ready 3 files right\n爱丽丝：好了 三个文件")
        #expect(CaptionOptions(stripsPunctuation: true).text(for: cue) == "Hello world")
    }

    @Test("The clip's choices apply to cues shifted onto the timeline")
    func appliesToTimelineCues() {
        var clip = Clip(source: ClipSource(id: "caption", kind: .captions, displayName: "C"), start: 10, duration: 5)
        clip.captions = CaptionOptions(languages: ["", "zh-Hans"])
        let cues = clip.captionCues([cue])
        #expect(cues.count == 1)
        #expect(cues[0].start == 10.5)
        #expect(cues[0].end == 12)
        #expect(cues[0].text == "Hello, world.\n你好，世界。")
        // Subtitle tracks and sidecar files keep the untouched transcript.
        #expect(clip.timelineCues([cue]).map(\.text) == ["Hello, world."])

        // The viewer asks per frame and must agree with what is burned in.
        #expect(clip.captionText(at: 11, in: [cue]) == "Hello, world.\n你好，世界。")
        #expect(clip.captionText(at: 10.4, in: [cue]).isEmpty)
        #expect(clip.captionText(at: 12, in: [cue]).isEmpty)
    }

    @Test("Clips saved before these options existed still draw the transcript")
    func decodesOlderClips() throws {
        let clip = Clip(source: ClipSource(id: "caption", kind: .captions, displayName: "C"), start: 0, duration: 1)
        #expect(clip.captions == .transcript)
        let json = try JSONEncoder().encode(clip)
        // A clip that says nothing about captions leaves the key out entirely,
        // so saved timelines keep the bytes they already had.
        let fields = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        #expect(fields?["captions"] == nil)
        #expect(try JSONDecoder().decode(Clip.self, from: json).captions == .transcript)

        var chosen = clip
        chosen.captions = CaptionOptions(languages: ["fr"], stripsPunctuation: true)
        let decoded = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(chosen))
        #expect(decoded.captions == chosen.captions)
        #expect(decoded == chosen)
    }

    @Test("Cues encoded before translations rode along still decode")
    func decodesOlderCues() throws {
        let json = Data(#"{"start":1,"end":2,"text":"Hello"}"#.utf8)
        let decoded = try JSONDecoder().decode(TextCue.self, from: json)
        #expect(decoded.translations.isEmpty)
        #expect(CaptionOptions(languages: ["zh-Hans"]).text(for: decoded) == "Hello")
    }
}
