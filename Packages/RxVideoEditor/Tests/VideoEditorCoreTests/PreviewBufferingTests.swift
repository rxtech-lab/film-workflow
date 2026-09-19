import Foundation
import Testing
@testable import VideoEditorCore

@MainActor private final class CaptionsResolver: TimelinePreviewResolver {
    func preview(_ source: ClipSource) async throws -> TimelinePreviewSource { .media(.captions([])) }
    func renderedPreview(_ source: ClipSource, progress: @escaping @MainActor (String) -> Void) async throws -> ResolvedMedia { .captions([]) }
    func release() {}
}

@Suite("Preview buffering") @MainActor
struct PreviewBufferingTests {
    private func settle(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(predicate(), "Preview did not settle")
    }

    private func fixture() -> Timeline {
        let source = ClipSource(id: "caption:fixture", kind: .captions, displayName: "Fixture")
        return Timeline(width: 320, height: 180, fps: 30,
                        tracks: [Track(kind: .caption, name: "Captions", clips: [Clip(source: source, start: 0, duration: 4, sourceDuration: 4)])])
    }

    /// Buffering is cleared only by synchronize(), which does not run while the
    /// surface is hidden. A load that begins off screen must therefore never
    /// claim it, or the spinner stays up for good.
    @Test func loadingWhileHiddenNeverLatchesBuffering() async throws {
        let transport = TimelinePlayerController()
        let controller = TimelinePreviewController(transport: transport)
        defer { controller.unload() }
        controller.load(fixture(), resolver: CaptionsResolver())
        try await settle { !controller.isLoading }
        #expect(!transport.isBuffering)
    }

    /// The order SwiftUI picks for a sibling swap can be appear-then-disappear,
    /// which used to leave the controller hidden and buffering forever.
    @Test func goingHiddenAfterAppearingReleasesBuffering() async throws {
        let transport = TimelinePlayerController()
        let controller = TimelinePreviewController(transport: transport)
        defer { controller.unload() }
        controller.setVisible(true)
        controller.load(fixture(), resolver: CaptionsResolver())
        try await settle { !controller.isLoading }
        controller.setVisible(false)
        #expect(!transport.isBuffering)
    }
}
