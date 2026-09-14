import AppKit
import XCTest

final class RemotionFootageUITests: XCTestCase {
    private let remotionID = "00000000-0000-0000-0000-000000000001"
    private let videoID = "00000000-0000-0000-0000-000000000002"
    private let liveID = "00000000-0000-0000-0000-000000000003"

    @MainActor
    private func launchFilm() throws -> XCUIApplication {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RemotionFootageUITests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-skipStartupAuth", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-NSQuitAlwaysKeepsWindows", "NO", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["RXFILM_REMOTION_UI_TEST_ROOT"] = root.path
        addTeardownBlock { @MainActor in
            app.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        app.launch()
        let grid = element("library.grid", in: app)
        XCTAssertTrue(grid.waitForExistence(timeout: 60),
                      (try? String(contentsOf: root.appendingPathComponent("fixture-error.txt"), encoding: .utf8)) ?? app.debugDescription)
        app.activate()
        app.windows["Remotion UI Test"].click()
        return app
    }

    @MainActor
    func testRemotionFootagePreviewsLikeVideo() throws {
        let app = try launchFilm()
        // The same controls must play a normal video, a saved Remotion movie,
        // and a composition that has not been rendered yet.
        for (name, id, first, last) in [
            ("Reference Video", videoID, NSColor.red, NSColor.blue),
            ("Remotion Versions", remotionID, NSColor.magenta, NSColor.cyan),
            ("Live Remotion", liveID, NSColor.magenta, NSColor.cyan),
        ] {
            select(name: name, id: id, in: app)
            let play = app.buttons["viewer.play"]
            XCTAssertTrue(play.waitForExistence(timeout: 10), "\(name) must expose video playback controls")
            XCTAssertFalse(element("viewer.transport", in: app).staticTexts["Still"].exists)
            goToStart(in: app)
            let stage = element("viewer.stage", in: app)
            assertColor(first, in: stage)
            play.click()
            let advanced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.seconds(in: app) >= 2.2
            }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [advanced], timeout: 10), .completed, "\(name) should advance while playing")
            play.click()
            assertColor(last, in: stage)
            let stopped = seconds(in: app)
            // Use a real frame step to verify the paused transport stays interactive.
            app.buttons["viewer.previous-frame"].click()
            XCTAssertLessThan(seconds(in: app), stopped)
            attach(app, name: "\(name) playback")
        }
    }

    @MainActor
    func testRemotionVersionPanelsListAndPreviewEveryRender() throws {
        let app = try launchFilm()
        select(name: "Remotion Versions", id: remotionID, in: app)
        let toggle = app.buttons["toggle-footage-browser"]
        if toggle.value as? String == "Collapsed" { toggle.click() }
        let versions = element("footage.versions", in: app)
        XCTAssertTrue(versions.waitForExistence(timeout: 5))
        let expectedColors = [NSColor.red, NSColor.green, NSColor.magenta]
        for version in [3, 2, 1] {
            let id = String(format: "00000000-0000-0000-0000-%012d", version + 10)
            let cell = element("footage.cell.\(id)", in: app)
            for _ in 0..<5 where !cell.isHittable { versions.scroll(byDeltaX: 0, deltaY: -100) }
            XCTAssertTrue(cell.isHittable, "The footage panel must include v\(version)")
            XCTAssertTrue(cell.staticTexts["v\(version)"].exists)
            // A click within the filmstrip selects the version and seeks into
            // its movie. It must not preview the latest composition for all rows.
            let strip = element("filmstrip.\(id).row.0", in: app)
            strip.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()
            element("viewer.timecode", in: app).hover()
            assertColor(expectedColors[version - 1], in: element("viewer.stage", in: app))
            XCTAssertTrue(app.buttons["viewer.play"].exists)
        }
        attach(app, name: "All three footage versions")

        let card = element("library.item.\(remotionID)", in: app)
        card.rightClick()
        app.menuItems["Versions (3)"].hover()
        let showAll = app.menuItems["Show All Versions…"]
        XCTAssertTrue(showAll.waitForExistence(timeout: 5)); showAll.click()
        let list = element("remotion.versions.list", in: app)
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        for version in [3, 2, 1] {
            let row = element("remotion.version.\(version)", in: app)
            XCTAssertTrue(row.exists, "Show All Versions must include v\(version)")
            row.click()
            let selection = element("remotion.versions.selection", in: app)
            XCTAssertTrue(((selection.value as? String) ?? selection.label).hasPrefix("v\(version) ·"))
            let preview = element("remotion.versions.player", in: app)
            assertColor(expectedColors[version - 1], in: preview)
        }
        attach(app, name: "Remotion version history and movie preview")
        app.sheets.buttons["Done"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func select(name: String, id: String, in app: XCUIApplication) {
        app.activate()
        let filter = app.textFields["Filter"]
        filter.click(); filter.typeKey("a", modifierFlags: .command); filter.typeText(name)
        let card = element("library.item.\(id)", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.click()
        let timecode = element("viewer.timecode", in: app)
        XCTAssertTrue(timecode.waitForExistence(timeout: 10), app.debugDescription)
        timecode.hover()
    }

    @MainActor
    private func goToStart(in app: XCUIApplication) {
        element("viewer.tools", in: app).click()
        app.menuItems["Go to Start"].click()
    }

    @MainActor
    private func seconds(in app: XCUIApplication) -> Double {
        let timecode = element("viewer.timecode", in: app)
        let parts = ((timecode.value as? String) ?? timecode.label).split(separator: ":").compactMap { Double($0) }
        guard parts.count == 4 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2] + parts[3] / 10
    }

    @MainActor
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    private func assertColor(_ expected: NSColor, in element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let expected = expected.usingColorSpace(.deviceRGB)!
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard element.exists,
                  let image = element.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let actual = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else { return false }
            return abs(actual.redComponent - expected.redComponent) < 0.2
                && abs(actual.greenComponent - expected.greenComponent) < 0.2
                && abs(actual.blueComponent - expected.blueComponent) < 0.2
        }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [matches], timeout: 10), .completed,
                       "The visible movie frame must match the selected version and playback time", file: file, line: line)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
