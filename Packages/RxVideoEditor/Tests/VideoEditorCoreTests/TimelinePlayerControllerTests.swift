import Testing

@testable import VideoEditorCore

@Suite("Timeline playback cursor")
@MainActor
struct TimelinePlayerControllerTests {
    @Test("An empty timeline allows seeking and stepping beyond its content")
    func seekBeyondContent() async {
        let controller = TimelinePlayerController()
        controller.seek(to: 120)
        await Task.yield()
        #expect(controller.currentTime == 120)
        #expect(controller.duration == 0)

        controller.step(frames: 1)
        #expect(abs(controller.currentTime - (120 + 1.0 / 30)) < 0.000001)
        controller.seek(to: -10)
        #expect(controller.currentTime == 0)
    }

    @Test("Repeated seeks retain the latest editing position")
    func repeatedSeeks() async {
        let controller = TimelinePlayerController()
        for time in 0...100 { controller.seek(to: Double(time)) }
        await Task.yield()
        #expect(controller.currentTime == 100)
        controller.unload()
        #expect(controller.currentTime == 0)
    }
}
