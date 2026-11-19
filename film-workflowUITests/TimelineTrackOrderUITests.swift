import AppKit
import XCTest

final class TimelineTrackOrderUITests: XCTestCase {
    @MainActor
    func testDragReorderUndoCancelAndPersistence() throws {
        let (app, window) = try launchFixture()
        let overlay = header(1, in: app), video = header(2, in: app)
        XCTAssertTrue(overlay.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertLessThan(overlay.frame.minY, video.frame.minY)
        assertCenterColor(.blue, in: app)

        video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
        XCTAssertLessThan(video.frame.minY, overlay.frame.minY)
        assertCenterColor(.red, in: app)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertLessThan(overlay.frame.minY, video.frame.minY)
        assertCenterColor(.blue, in: app)
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertLessThan(video.frame.minY, overlay.frame.minY)
        assertCenterColor(.red, in: app)

        // A horizontal departure cancels, and a mute-button click remains a click.
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
                .withOffset(CGVector(dx: 160, dy: 0)))
        XCTAssertLessThan(video.frame.minY, overlay.frame.minY)
        let mute = app.buttons["timeline.track.mute.00000000-0000-0000-0000-000000000002"]
        mute.click()
        XCTAssertLessThan(video.frame.minY, overlay.frame.minY)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertLessThan(video.frame.minY, overlay.frame.minY)

        // Move a lower audio row upward and back down across multiple rows.
        let audio = header(4, in: app)
        audio.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
        XCTAssertLessThan(audio.frame.minY, video.frame.minY)
        let audio1 = header(3, in: app)
        audio.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: audio1.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertGreaterThan(audio.frame.minY, audio1.frame.minY)
        assertCenterColor(.red, in: app)
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "Reordered timeline tracks"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.terminate()
        app.launch()
        XCTAssertTrue(window.waitForExistence(timeout: 30))
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        XCTAssertLessThan(video.frame.minY, overlay.frame.minY)
        XCTAssertGreaterThan(audio.frame.minY, audio1.frame.minY)
    }

    @MainActor
    func testFilterShowsMultipleTrackTypesWithoutChangingPlayback() throws {
        let (app, _) = try launchFixture()
        let overlay = header(1, in: app), video = header(2, in: app)
        let audio1 = header(3, in: app), audio2 = header(4, in: app)
        XCTAssertTrue(overlay.waitForExistence(timeout: 10), app.debugDescription)
        assertCenterColor(.blue, in: app)

        let filter = app.buttons["timeline.filter"]
        let apply = app.buttons["timeline.filter.apply"]
        filter.click()
        let overlayType = app.checkBoxes["timeline.filter.type.overlay"]
        XCTAssertTrue(overlayType.waitForExistence(timeout: 5), app.debugDescription)
        overlayType.click()
        app.checkBoxes["timeline.filter.type.caption"].click()
        app.checkBoxes["timeline.filter.type.zoom"].click()
        apply.click()

        XCTAssertTrue(overlay.waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(video.exists)
        XCTAssertTrue(audio1.exists)
        XCTAssertTrue(audio2.exists)
        XCTAssertLessThan(video.frame.minY, audio1.frame.minY)
        XCTAssertLessThan(audio1.frame.minY, audio2.frame.minY)
        assertCenterColor(.blue, in: app)

        filter.click()
        let videoType = app.checkBoxes["timeline.filter.type.video"]
        XCTAssertTrue(videoType.waitForExistence(timeout: 5), app.debugDescription)
        videoType.click()
        app.checkBoxes["timeline.filter.type.audio"].click()
        apply.click()

        let empty = app.staticTexts["No tracks match the filter"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(video.exists)
        XCTAssertFalse(audio1.exists)
        XCTAssertFalse(audio2.exists)
        assertCenterColor(.blue, in: app)

        filter.click()
        let showAll = app.buttons["timeline.filter.show-all"]
        XCTAssertTrue(showAll.waitForExistence(timeout: 5), app.debugDescription)
        showAll.click()
        apply.click()

        XCTAssertTrue(overlay.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertLessThan(overlay.frame.minY, video.frame.minY)
        assertCenterColor(.blue, in: app)
    }

    @MainActor
    func testFilterCompositionTimelineByElementType() throws {
        let (app, window) = try launchFixture()
        let card = window.descendants(matching: .any).matching(identifier: "library.item.00000000-0000-0000-0000-000000000005").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "The fixture composition card should appear in the library")
        card.doubleClick()

        let headers = window.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.track.drag."))
        let heading = headers.matching(NSPredicate(format: "label BEGINSWITH %@", "Reorder Heading")).firstMatch
        let badge = headers.matching(NSPredicate(format: "label BEGINSWITH %@", "Reorder Badge")).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "The composition timeline should show the renamed div")
        XCTAssertTrue(badge.exists)
        let timecode = window.staticTexts["composition.timecode"]
        XCTAssertTrue(timecode.exists)
        let originalTime = (timecode.value as? String) ?? timecode.label
        XCTAssertEqual(originalTime, "00:00:00:00")

        let filter = app.buttons["timeline.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5), window.debugDescription.split(separator: "\n")
            .filter { $0.contains("timeline") || $0.contains("Filter") }.joined(separator: "\n"))
        let clear = app.buttons["timeline.filter.clear-all"]
        let apply = app.buttons["timeline.filter.apply"]
        filter.click()
        let div = app.checkBoxes["timeline.filter.type.div"]
        XCTAssertTrue(div.waitForExistence(timeout: 5), "The sheet should list div as a type")
        XCTAssertTrue(app.checkBoxes["timeline.filter.type.span"].exists)
        clear.click()
        div.click()
        apply.click()
        XCTAssertTrue(badge.waitForNonExistence(timeout: 5))
        XCTAssertTrue(heading.exists)
        XCTAssertEqual((timecode.value as? String) ?? timecode.label, originalTime)

        filter.click()
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.click()
        app.sheets.buttons["Cancel"].click()
        XCTAssertTrue(apply.waitForNonExistence(timeout: 5))
        XCTAssertTrue(heading.exists)
        XCTAssertFalse(badge.exists)

        filter.click()
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.click()
        apply.click()
        let reset = app.buttons["Show All Tracks"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        XCTAssertFalse(heading.exists)
        reset.click()
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        XCTAssertTrue(heading.exists)
    }

    @MainActor
    private func launchFixture() throws -> (XCUIApplication, XCUIElement) {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TrackOrderUITests-\(UUID())")
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
        return (app, window)
    }

    @MainActor
    private func header(_ number: Int, in app: XCUIApplication) -> XCUIElement {
        let id = String(format: "timeline.track.drag.00000000-0000-0000-0000-%012d", number)
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
