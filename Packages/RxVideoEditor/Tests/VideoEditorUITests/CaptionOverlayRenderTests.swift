import AppKit
import SwiftUI
import VideoEditorCore
import XCTest
@testable import VideoEditorUI

/// The live preview paints captions itself instead of going through the
/// compositor, so a picture layer drawn after them — or a track order that
/// buries the overlay — makes the burned-in text vanish from the viewer while
/// every export still carries it. These tests render the real preview view and
/// read the pixels back, which is the only way that failure shows up.
final class CaptionOverlayRenderTests: XCTestCase {
    private let canvas = CGSize(width: 320, height: 180)

    @MainActor
    func testCaptionDrawsOverAPictureClip() throws {
        let render = try renderPreview(video: .picture, captionsAbove: true)
        XCTAssertEqual(render.color(atX: 0.5, y: 0.5).nearest, .red, "The picture clip must fill the frame")
        XCTAssertEqual(render.color(atX: 0.5, y: 0.9).nearest, .white,
                       "The caption must be drawn over the picture, not under it")
    }

    /// A Remotion clip previews as a hosted surface the package knows nothing
    /// about, mounted and unmounted as the playhead moves. It is the case the
    /// editor actually shows for generated footage, and the one where a caption
    /// disappearing behind the picture was reported.
    @MainActor
    func testCaptionDrawsOverALivePreviewSurface() throws {
        let render = try renderPreview(video: .live, captionsAbove: true)
        XCTAssertEqual(render.color(atX: 0.5, y: 0.5).nearest, .red, "The live surface must fill the frame")
        XCTAssertEqual(render.color(atX: 0.5, y: 0.9).nearest, .white,
                       "The caption must be drawn over the live surface, not under it")
    }

    /// The mirror image: an overlay lane moved below a video lane is a
    /// deliberate edit, and the preview has to show that too. Without it a
    /// test that only checks "caption on top" would pass on a preview that
    /// ignores track order entirely.
    @MainActor
    func testCaptionUnderAPictureClipIsHidden() throws {
        let render = try renderPreview(video: .picture, captionsAbove: false)
        XCTAssertEqual(render.color(atX: 0.5, y: 0.9).nearest, .red,
                       "A caption below a full-frame picture clip stays hidden")
    }

    /// Captions made for a narration land wherever that narration plays, which
    /// is rarely the head of the sequence, while their cues stay on the audio's
    /// own clock starting at zero. Drawing those cues without shifting them by
    /// the clip's start puts every caption in the wrong place — and, for a clip
    /// far enough along, off the end of the film, where the viewer shows
    /// nothing at all.
    @MainActor
    func testCaptionsPlacedLaterInTheSequenceDrawAtTheirClip() throws {
        let cues = [TextCue(start: 0, end: 5, text: "CAPTION")]
        let inside = try renderPreview(video: .picture, captionsAbove: true,
                                       captionStart: 5, captionDuration: 5, cues: cues, seek: 6)
        XCTAssertEqual(inside.color(atX: 0.5, y: 0.5).nearest, .red, "The picture clip must fill the frame")
        XCTAssertEqual(inside.color(atX: 0.5, y: 0.9).nearest, .white,
                       "A cue on the source clock must be drawn where its clip sits on the timeline")

        let before = try renderPreview(video: .picture, captionsAbove: true,
                                       captionStart: 5, captionDuration: 5, cues: cues, seek: 2)
        XCTAssertEqual(before.color(atX: 0.5, y: 0.9).nearest, .red,
                       "Nothing may be drawn before the caption clip starts")
    }

    /// A narration trimmed on the timeline hands its in point to the captions
    /// made from it, so the words heard and the words drawn stay together. The
    /// cues before that in point belong to audio the clip no longer plays.
    @MainActor
    func testTrimmedCaptionsFollowTheirInPoint() throws {
        let cues = [TextCue(start: 0, end: 2, text: "TRIMMED AWAY"),
                    TextCue(start: 2, end: 5, text: "CAPTION")]
        let render = try renderPreview(video: .picture, captionsAbove: true,
                                       captionStart: 5, captionDuration: 3, captionInPoint: 2,
                                       cues: cues, seek: 6)
        XCTAssertEqual(render.color(atX: 0.5, y: 0.9).nearest, .white,
                       "The cue at the clip's in point must be drawn at the clip's start")
    }

    /// What the picture layer under the captions is made of.
    private enum VideoLayer {
        /// A still on a video track: the compositor's `.still` layer.
        case picture
        /// A Remotion clip: an app-supplied surface hosted inside the preview.
        case live
    }

    // MARK: - Rendering

    @MainActor
    private func renderPreview(video kind: VideoLayer, captionsAbove: Bool,
                               captionStart: TimeInterval = 0, captionDuration: TimeInterval = 5,
                               captionInPoint: TimeInterval = 0,
                               cues: [TextCue] = [TextCue(start: 0, end: 5, text: "CAPTION")],
                               seek: TimeInterval = 0,
                               file: StaticString = #filePath, line: UInt = #line) throws -> Render {
        let directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                    appropriateFor: FileManager.default.temporaryDirectory, create: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let picture = directory.appendingPathComponent("red.png")
        try Self.png(color: .red, size: canvas, at: picture)

        var captionClip = Clip(source: ClipSource(id: "caption", kind: .captions, displayName: "Captions"),
                               start: captionStart, duration: captionDuration, inPoint: captionInPoint)
        // An opaque box and white text keep the assertion about layering
        // rather than about how the text renderer antialiases glyphs.
        captionClip.text = TextStyle(fontSize: 0.18, colorHex: "#FFFFFF", backgroundHex: "#FFFFFF",
                                     backgroundOpacity: 1, verticalPosition: 0.9)
        let source = kind == .picture
            ? ClipSource(id: "picture", kind: .image, displayName: "Picture")
            : ClipSource(id: "live", kind: .remotion, displayName: "Composition")
        let overlay = Track(kind: .overlay, name: "T1", clips: [captionClip])
        // The picture runs under the whole of the captions, whenever they sit,
        // so a missing caption reads as "the video showed through" rather than
        // as an empty frame.
        let video = Track(kind: .video, name: "V1",
                          clips: [Clip(source: source, start: 0, duration: max(5, captionClip.end))])
        let timeline = Timeline(width: Int(canvas.width), height: Int(canvas.height),
                                tracks: captionsAbove ? [overlay, video] : [video, overlay])

        let transport = TimelinePlayerController()
        let controller = TimelinePreviewController(transport: transport)
        addTeardownBlock { @MainActor in controller.unload(); transport.unload() }
        controller.load(timeline, resolver: FixturePreviewResolver(sources: [
            "picture": .media(.file(picture, naturalDuration: nil, naturalSize: canvas)),
            "live": .live(LivePreviewDescriptor(url: URL(fileURLWithPath: "/dev/null"), fps: 30, frames: 150,
                                                width: Int(canvas.width), height: Int(canvas.height))),
            "caption": .media(.captions(cues)),
        ]))
        try wait(for: { !controller.isLoading }, description: "preview sources resolve")
        XCTAssertNil(controller.lastError, file: file, line: line)

        let view = TimelineLayeredPreviewView(controller: controller) { playback in
            AnyView(StubLiveSurface(playback: playback))
        }
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        transport.seek(to: seek)
        // The layers the preview draws only exist once SwiftUI has run a
        // layout pass for a window that believes it is on screen. Only the
        // clips covering this moment mount, which is the point of seeking.
        try wait(for: { controller.layers.filter { $0.clip.range.contains(seek) }.allSatisfy { $0.mounted && $0.active } },
                 description: "layers mount at \(seek)s")
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        guard let layer = host.layer,
              let context = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw XCTSkip("This machine cannot back a layer-hosted window")
        }
        // Core Graphics starts at the bottom left and the layer tree at the top
        // left, so the frame comes out upside down without this flip.
        context.translateBy(x: 0, y: canvas.height)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        guard let image = context.makeImage() else { throw XCTSkip("The preview produced no frame") }
        let render = Render(bitmap: NSBitmapImageRep(cgImage: image))
        attach(render, name: captionsAbove ? "Captions above the picture" : "Captions below the picture")
        return render
    }

    /// The preview is driven by async resolution, so every step waits for the
    /// state it needs rather than sleeping for a guessed interval.
    @MainActor
    private func wait(for condition: @escaping @MainActor () -> Bool, description: String,
                      file: StaticString = #filePath, line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(description)", file: file, line: line) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Keeps the frame a failure was read from, so a broken layer order is
    /// visible in the test report instead of being a colour mismatch.
    private func attach(_ render: Render, name: String) {
        guard let data = render.bitmap.representation(using: .png, properties: [:]) else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func png(color: NSColor, size: CGSize, at url: URL) throws {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        guard let data = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }

    /// One rendered preview frame, sampled in canvas-relative coordinates
    /// (y grows downward, like the caption style's vertical position).
    private struct Render {
        let bitmap: NSBitmapImageRep

        func color(atX x: Double, y: Double) -> NSColor {
            let px = min(bitmap.pixelsWide - 1, max(0, Int(Double(bitmap.pixelsWide) * x)))
            let py = min(bitmap.pixelsHigh - 1, max(0, Int(Double(bitmap.pixelsHigh) * y)))
            return bitmap.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB) ?? .clear
        }
    }
}

private enum SampledColor: String {
    case red, white, other
}

private extension NSColor {
    /// Which fixture colour a sampled pixel reads as; anything else fails the
    /// assertion with the raw components in the message.
    var nearest: SampledColor {
        if redComponent > 0.6, greenComponent < 0.4, blueComponent < 0.4 { return .red }
        if redComponent > 0.6, greenComponent > 0.6, blueComponent > 0.6 { return .white }
        return .other
    }
}

extension SampledColor: CustomStringConvertible {
    var description: String { rawValue }
}

/// Stands in for the app's Remotion web view: an opaque surface that reports
/// itself ready, which is what makes the preview show it at full opacity.
private struct StubLiveSurface: View {
    let playback: LivePreviewPlayback

    var body: some View {
        Color.red.onAppear { playback.received(type: "ready") }
    }
}

/// Serves already-resolved sources, the way the app's document resolver does
/// once a film's media is on disk.
@MainActor
private final class FixturePreviewResolver: TimelinePreviewResolver {
    private let sources: [String: TimelinePreviewSource]

    init(sources: [String: TimelinePreviewSource]) { self.sources = sources }

    func preview(_ source: ClipSource) async throws -> TimelinePreviewSource {
        guard let match = sources[source.id] else { throw MediaResolverError.missing(source) }
        return match
    }

    func renderedPreview(_ source: ClipSource, progress: @escaping @MainActor (String) -> Void) async throws -> ResolvedMedia {
        throw MediaResolverError.missing(source)
    }

    func release() {}
}
