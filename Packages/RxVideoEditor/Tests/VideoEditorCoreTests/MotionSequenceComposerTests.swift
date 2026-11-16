import CoreGraphics
import Foundation
import Testing
import VideoEffectsCore

@testable import VideoEditorCore

struct MotionSequenceComposerTests {
    let videoURL = URL(fileURLWithPath: "/media/shot.mov")
    let imageURL = URL(fileURLWithPath: "/media/poster.png")
    let musicURL = URL(fileURLWithPath: "/media/music.m4a")

    func timeline(_ tracks: [Track], transitions: [TransitionInstance] = []) -> Timeline {
        Timeline(width: 1920, height: 1080, fps: 30, tracks: tracks, transitions: transitions)
    }

    var sources: MotionSequenceSources {
        MotionSequenceSources(
            media: [
                "video:1": .file(videoURL, naturalDuration: 10, naturalSize: CGSize(width: 1280, height: 720)),
                "image:1": .file(imageURL, naturalDuration: nil, naturalSize: nil),
                "music:1": .file(musicURL, naturalDuration: 60, naturalSize: nil),
                "caption:1": .captions([TextCue(start: 0, end: 2, text: "Hello")]),
            ],
            naturalSizes: [videoURL: CGSize(width: 1280, height: 720), imageURL: CGSize(width: 800, height: 800)],
            durations: [videoURL: 10, musicURL: 60],
            reversedAudio: [videoURL: URL(fileURLWithPath: "/cache/shot-reversed.m4a")],
            nested: ["remotion:1": MotionNestedProject(publicDirectory: URL(fileURLWithPath: "/projects/intro/public"),
                                                       files: ["src/Root.tsx": "export const RemotionRoot = () => null;",
                                                               "src/Composition.tsx": "export const MyComposition = () => null;"])])
    }

    func source(_ id: String, _ kind: SourceKind) -> ClipSource { ClipSource(id: id, kind: kind, displayName: id) }

    @Test func videoClipsBecomeTrimmedRetimedMediaInSequences() throws {
        let clip = Clip(source: source("video:1", .video), start: 2, duration: 3, inPoint: 1, playbackRate: 2, volume: 0.5)
        let film = try MotionSequenceComposer.compose(timeline([Track(kind: .video, name: "V1", clips: [clip])]), sources: sources)
        let tsx = try #require(film.files[MotionSequenceComposition.entry])
        #expect(film.durationInFrames == 150)
        #expect(tsx.contains(#"<Sequence from={60} durationInFrames={90} layout="none"><Layer fx={[]} opacity={1.0}>"#))
        #expect(tsx.contains(#"<OffthreadVideo src="/media/shot.mov" trimBefore={30.0} playbackRate={2.0} volume={0.5}"#))
        #expect(tsx.contains("place(1280.0, 720.0, [\"fit\", 1.0, 0.0, 0.0])"))
        #expect(film.processor.isEmpty)
    }

    @Test func previewLeavesFileAudioToAVFoundation() throws {
        let video = Clip(source: source("video:1", .video), start: 0, duration: 2)
        let music = Clip(source: source("music:1", .audio), start: 0, duration: 2)
        let film = try MotionSequenceComposer.compose(timeline([
            Track(kind: .video, name: "V1", clips: [video]), Track(kind: .audio, name: "A1", clips: [music]),
        ]), sources: sources, options: .preview)
        let tsx = try #require(film.files[MotionSequenceComposition.entry])
        #expect(tsx.contains(" muted style="))
        #expect(!tsx.contains("<Audio src="))
    }

    @Test func reversedClipsPlayBackwardsWithReversedSound() throws {
        let clip = Clip(source: source("video:1", .video), start: 0, duration: 2, inPoint: 1, isReversed: true)
        let film = try MotionSequenceComposer.compose(timeline([Track(kind: .video, name: "V1", clips: [clip])]), sources: sources)
        let tsx = try #require(film.files[MotionSequenceComposition.entry])
        #expect(tsx.contains("trimBefore={30.0} durationInFrames={60.0} playbackRate={1.0} reverse muted"))
        // Reversed copy of a 10 s file: the clip's source range 1…3 s mirrors to 7…9 s.
        #expect(tsx.contains(#"<Audio src="/cache/shot-reversed.m4a" trimBefore={210.0}"#))
    }

    @Test func remotionClipsNestTheirProjectWithItsOwnAssets() throws {
        let clip = Clip(source: source("remotion:1", .remotion), start: 1, duration: 4)
        let film = try MotionSequenceComposer.compose(timeline([Track(kind: .overlay, name: "O1", clips: [clip])]), sources: sources)
        let tsx = try #require(film.files[MotionSequenceComposition.entry])
        #expect(film.files["remotion/0/src/Root.tsx"] != nil)
        #expect(tsx.contains(#"import * as N0Root from "./remotion/0/src/Root";"#))
        #expect(tsx.contains(#"dir: "/projects/intro/public""#))
        #expect(tsx.contains("<Nested n={0}"))
    }

    @Test func effectsAndCaptionsAreDrawnByTheProcessor() throws {
        var still = Clip(source: source("image:1", .image), start: 0, duration: 2)
        still.effects = [EffectInstance(definitionID: "rx.saturation", parameters: ["amount": .number(0)])]
        let caption = Clip(source: source("caption:1", .captions), start: 0, duration: 2)
        let film = try MotionSequenceComposer.compose(timeline([
            Track(kind: .caption, name: "C1", clips: [caption]), Track(kind: .video, name: "V1", clips: [still]),
        ]), sources: sources)
        let tsx = try #require(film.files[MotionSequenceComposition.entry])
        #expect(!film.processor.isEmpty)
        #expect(tsx.contains("<Processed k="))
        #expect(tsx.contains("style={FULL}"))

        let pixel = try #require(CGImage.solid(width: 4, height: 4))
        let keys = film.processor.jobs.keys.sorted()
        film.processor.register()
        defer { film.processor.unregister() }
        for key in keys {
            let image = MotionSequenceProcessor.process(pixel, key: key, time: 0.5, pixelWidth: 192, pixelHeight: 108)
            #expect(image?.width == 192)
            #expect(image?.height == 108)
        }
        // Outside every cue a caption draws nothing.
        let captionKey = try #require(film.processor.jobs.first { if case .captions = $0.value { return true }; return false }?.key)
        #expect(MotionSequenceProcessor.process(pixel, key: captionKey, time: 5, pixelWidth: 192, pixelHeight: 108) == nil)
    }

    @Test func missingMediaFailsExportsButDrawsSlatesInPreview() throws {
        let clip = Clip(source: source("video:missing", .video), start: 0, duration: 1)
        let line = timeline([Track(kind: .video, name: "V1", clips: [clip])])
        #expect(throws: MediaResolverError.self) { try MotionSequenceComposer.compose(line, sources: sources) }
        let preview = try MotionSequenceComposer.compose(line, sources: sources, options: .preview)
        #expect(preview.placeholders.map(\.id) == ["video:missing"])
    }

    @Test func dissolveBetweenClipsWidensBothWindows() throws {
        let a = Clip(source: source("video:1", .video), start: 0, duration: 2, inPoint: 2)
        let b = Clip(source: source("video:1", .video), start: 2, duration: 2, inPoint: 2)
        let transition = TransitionInstance(definitionID: "rx.cross-dissolve", attachment: .between(outgoing: a.id, incoming: b.id), duration: 1)
        let line = timeline([Track(kind: .video, name: "V1", clips: [a, b])], transitions: [transition])
        let tsx = try #require(try MotionSequenceComposer.compose(line, sources: sources).files[MotionSequenceComposition.entry])
        // Outgoing plays 0…2.5 s, incoming 1.5…4 s.
        #expect(tsx.contains(#"<Sequence from={0} durationInFrames={75} layout="none"><Layer fx={[{k: "dissolve", role: "out", a: 45, b: 75"#))
        #expect(tsx.contains(#"<Sequence from={45} durationInFrames={75} layout="none"><Layer fx={[{k: "dissolve", role: "in", a: 0, b: 30"#))
    }

    @Test func installedTransitionsDrawAsADissolve() throws {
        let a = Clip(source: source("video:1", .video), start: 0, duration: 2)
        let transition = TransitionInstance(definitionID: "market.page-curl", attachment: .start(a.id))
        let line = timeline([Track(kind: .video, name: "V1", clips: [a])], transitions: [transition])
        #expect(MotionSequenceComposer.approximations(line).count == 1)
        #expect(MotionSequenceComposer.approximations(timeline([Track(kind: .video, name: "V1", clips: [a])])).isEmpty)
        let tsx = try #require(try MotionSequenceComposer.compose(line, sources: sources, options: .preview).files[MotionSequenceComposition.entry])
        #expect(tsx.contains(#"{k: "dissolve", role: "edgeIn""#))
    }

    @Test func sourceTimeInvertsToTimelineTime() {
        let clip = Clip(source: source("video:1", .video), start: 4, duration: 2, inPoint: 1, playbackRate: 2)
        #expect(MotionSequenceProcessor.timelineTime(ofSource: clip.sourceTime(at: 5), in: clip) == 5)
        var reversed = clip
        reversed.isReversed = true
        #expect(MotionSequenceProcessor.timelineTime(ofSource: reversed.sourceTime(at: 5.5), in: reversed) == 5.5)
    }
}

private extension CGImage {
    static func solid(width: Int, height: Int) -> CGImage? {
        let bytes = Data(repeating: 200, count: width * height * 4)
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
