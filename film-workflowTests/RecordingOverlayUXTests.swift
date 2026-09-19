import AppKit
import Testing
import RxPet
@testable import film_workflow

@MainActor @Suite("Recording selection and overlay chrome", .serialized)
struct RecordingOverlayUXTests {
    @Test func unselectedDisplaysDimHardEnoughToRead() {
        #expect(RecordingSelectionStyle.displayShade(selected: true) == 0)
        #expect(RecordingSelectionStyle.displayShade(selected: false) >= 0.5)
        #expect(RecordingSelectionStyle.displayOutlineAlpha(selected: true) > RecordingSelectionStyle.displayOutlineAlpha(selected: false))
    }

    @Test func startControlStaysLitWhileAdjustingAnArea() {
        let setup = RecordingSetup.shared
        defer { setup.endAreaDrag() }
        setup.pending = RecordingSettings()
        setup.pending.sourceKind = .display
        // Nothing is presented, so canStart is false no matter what the area is.
        #expect(!setup.canStart)
        #expect(!setup.startControlEnabled)
        setup.beginAreaDrag(displayID: "1")
        #expect(setup.isAdjustingArea)
        // The button keeps its colour mid-drag even though starting is refused.
        #expect(setup.startControlEnabled)
        #expect(!setup.canStart)
    }

    @Test func anAbandonedDragGoesBackToPickingADisplay() {
        let setup = RecordingSetup.shared
        setup.pending = RecordingSettings()
        setup.pending.sourceKind = .display
        setup.pending.sourceID = "1"
        setup.beginAreaDrag(displayID: "1")
        // A drag too small to record, as a jittery click would produce.
        setup.updateAreaDrag(CGRect(x: 10, y: 10, width: 1, height: 1))
        #expect(setup.pending.sourceKind == .area)
        setup.endAreaDrag()
        #expect(!setup.isAdjustingArea)
        #expect(setup.pending.sourceKind == .display)
        #expect(setup.pending.area == .zero)
    }

    @Test func frontmostPicksTheTopWindowAndHonoursTheLimit() {
        func row(_ id: UInt32, layer: Int = 0, width: CGFloat = 800) -> [String: Any] {
            [kCGWindowNumber as String: id,
             kCGWindowLayer as String: layer,
             kCGWindowAlpha as String: 1.0,
             kCGWindowBounds as String: CGRect(x: 0, y: 0, width: width, height: 600).dictionaryRepresentation]
        }
        // Front to back, as the window server returns them.
        let rows = [row(9, layer: 25), row(1), row(2), row(3)]
        #expect(RecordingWindowOrder.frontmost(in: rows)?.id == 1)
        #expect(RecordingWindowOrder.frontmost(in: rows, excluding: [1])?.id == 2)
        #expect(RecordingWindowOrder.frontmost(in: rows, limitedTo: ["2", "3"])?.id == 2)
        #expect(RecordingWindowOrder.frontmost(in: rows, limitedTo: ["404"]) == nil)
        // Menu-bar layer and hairline windows are never targets.
        #expect(RecordingWindowOrder.frontmost(in: [row(9, layer: 25), row(8, width: 1)]) == nil)
    }

    @Test func controlsSitUnderThePetAndFlipAtTheScreenEdge() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 250, height: 54)
        let middle = CGRect(x: 600, y: 400, width: 210, height: 130)
        let below = RecordingControlsGeometry.frame(size: size, pet: middle, visibleFrame: visible)
        #expect(below.maxY == middle.minY - 4)
        #expect(visible.contains(below))
        let low = CGRect(x: 600, y: 10, width: 210, height: 130)
        let above = RecordingControlsGeometry.frame(size: size, pet: low, visibleFrame: visible)
        #expect(above.minY == low.maxY + 4)
        #expect(visible.contains(above))
        // Hard against a corner it is clamped, never pushed off screen.
        let corner = CGRect(x: 1430, y: 880, width: 210, height: 130)
        #expect(visible.contains(RecordingControlsGeometry.frame(size: size, pet: corner, visibleFrame: visible)))
    }

    @Test func theBarHugsTheTopEdgeAndClipsToItsScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let window = CGRect(x: 100, y: 200, width: 600, height: 400)
        let bar = RecordingBorderGeometry.topBar(for: window, height: 5, within: screen)
        #expect(bar == CGRect(x: 100, y: 595, width: 600, height: 5))
        #expect(bar.maxY == window.maxY)
        // A window hanging off the side keeps only the visible run.
        let straddling = CGRect(x: 1200, y: 200, width: 600, height: 400)
        #expect(RecordingBorderGeometry.topBar(for: straddling, height: 5, within: screen).width == 240)
        // Entirely on another display, nothing to draw.
        #expect(RecordingBorderGeometry.topBar(for: CGRect(x: 2000, y: 200, width: 600, height: 400), height: 5, within: screen).isEmpty)
    }

    @Test func recordingChromeIsExcludedFromCaptureAndFromRecordedInput() {
        let sources = RecordingSources.shared
        let controls = RecordingControlsOverlay()
        let borders = RecordingBorderIndicators()
        defer { controls.dismiss(); borders.dismiss() }
        let target = RecordingPetTarget(id: "display-1", name: "Display", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        controls.prepare()
        borders.prepare(targets: [target])
        let controlsID = try! #require(controls.windowID)
        let borderIDs = borders.windowIDs
        #expect(!borderIDs.isEmpty)
        // Neither may appear in the video.
        #expect(sources.excludedWindowIDs.contains(controlsID))
        #expect(borderIDs.isSubset(of: sources.excludedWindowIDs))
        // The controls are chrome: their own clicks are not the user's actions.
        #expect(sources.excludedInputWindowIDs.contains(controlsID))
        #expect(!sources.passThroughWindowIDs.contains(controlsID))
        // The bar is click-through, so what happens under it still counts.
        #expect(borderIDs.isSubset(of: sources.passThroughWindowIDs))
    }

    @Test func dismissingTheChromeGivesBackEveryRegistration() {
        let sources = RecordingSources.shared
        let controls = RecordingControlsOverlay()
        let borders = RecordingBorderIndicators()
        let target = RecordingPetTarget(id: "display-2", name: "Display", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        controls.prepare()
        borders.prepare(targets: [target])
        let ids = borders.windowIDs.union([controls.windowID].compactMap { $0 })
        controls.dismiss(); borders.dismiss()
        #expect(sources.excludedWindowIDs.isDisjoint(with: ids))
        #expect(sources.excludedInputWindowIDs.isDisjoint(with: ids))
        #expect(sources.passThroughWindowIDs.isDisjoint(with: ids))
    }
}
