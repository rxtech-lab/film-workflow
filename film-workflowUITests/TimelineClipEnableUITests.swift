import AppKit
import XCTest

/// The fixture stacks a blue overlay clip over a red video clip, so whatever
/// the viewer shows names what is being rendered: blue while the overlay
/// renders, red once it is taken out.
final class TimelineClipEnableUITests: XCTestCase {
    @MainActor
    func testDisablingAClipAndATrackTakesThemOutOfThePreview() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipEnableUITests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-skipStartupAuth", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-NSQuitAlwaysKeepsWindows", "NO", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["RXFILM_TRACK_UI_TEST_ROOT"] = root.path
        addTeardownBlock { @MainActor in app.terminate(); try? FileManager.default.removeItem(at: root) }
        app.launch()
        let window = app.windows["Track Order UI Test"]
        XCTAssertTrue(window.waitForExistence(timeout: 30),
                      (try? String(contentsOf: root.appendingPathComponent("fixture-error.txt"), encoding: .utf8)) ?? app.debugDescription)
        window.click()

        let overlayClip = clip(11, in: app)
        XCTAssertTrue(overlayClip.waitForExistence(timeout: 10), app.debugDescription)
        assertCenterColor(.blue, in: app)

        // The clip: select it and press V, the timeline's enable shortcut.
        overlayClip.click()
        app.typeKey("v", modifierFlags: [])
        assertCenterColor(.red, in: app)
        app.typeKey("v", modifierFlags: [])
        assertCenterColor(.blue, in: app)

        // Undo restores the switch along with everything else on the timeline.
        app.typeKey("z", modifierFlags: .command)
        assertCenterColor(.red, in: app)
        app.typeKey("z", modifierFlags: [.command, .shift])
        assertCenterColor(.blue, in: app)

        // The lane: the header's eye takes the whole overlay track out.
        let eye = app.buttons["timeline.track.enabled.00000000-0000-0000-0000-000000000001"]
        XCTAssertTrue(eye.waitForExistence(timeout: 10), app.debugDescription)
        eye.click()
        assertCenterColor(.red, in: app)
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "Disabled overlay track"; screenshot.lifetime = .keepAlways; add(screenshot)
        eye.click()
        assertCenterColor(.blue, in: app)

        // Both switches are saved with the film.
        eye.click()
        overlayClip.click()
        app.typeKey("v", modifierFlags: [])
        assertCenterColor(.red, in: app)
        app.terminate()
        app.launch()
        XCTAssertTrue(window.waitForExistence(timeout: 30))
        XCTAssertTrue(clip(11, in: app).waitForExistence(timeout: 10))
        assertCenterColor(.red, in: app)
    }

    @MainActor
    private func clip(_ number: Int, in app: XCUIApplication) -> XCUIElement {
        let id = String(format: "timeline.clip.name.00000000-0000-0000-0000-%012d", number)
        return app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    private func assertCenterColor(_ expected: NSColor, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let stage = app.descendants(matching: .any).matching(identifier: "sequence.viewer.stage").firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 10), "Sequence preview is missing from accessibility.\n\(app.debugDescription)", file: file, line: line)
        let rgb = expected.usingColorSpace(.deviceRGB)!
        var lastColor: NSColor?
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard stage.exists, let image = stage.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else { return false }
            lastColor = color
            return abs(color.redComponent - rgb.redComponent) < 0.2
                && abs(color.greenComponent - rgb.greenComponent) < 0.2
                && abs(color.blueComponent - rgb.blueComponent) < 0.2
        }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [matches], timeout: 10), .completed,
                       "Expected \(rgb), last preview center was \(String(describing: lastColor))", file: file, line: line)
    }
}
