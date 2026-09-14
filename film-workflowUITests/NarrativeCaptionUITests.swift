import AppKit
import XCTest

/// "Create Captions" on a narration clip: the captions have to appear over the
/// narration *and* preview, which they only do when the caption project behind
/// them has reached the store the viewer's resolver reads.
final class NarrativeCaptionUITests: XCTestCase {
    private let narrationClipID = "00000000-0000-0000-0000-0000000000A1"
    private let captionClipTitle = "Story captions"

    @MainActor
    func testContextMenuCreatesCaptionsThatPreview() throws {
        let (app, window) = try launchFilm()
        let narration = clip(narrationClipID, in: app)
        XCTAssertTrue(narration.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(clips(in: app).count, 1, "The fixture starts with the narration alone")

        rightClick(narration)
        let create = app.menuItems["Create Captions"]
        XCTAssertTrue(create.waitForExistence(timeout: 5),
                      "A narration clip must offer to create its captions.\n\(app.debugDescription)")
        create.click()

        // The captions land on the overlay lane, above the narration they read.
        let captions = captionClip(in: app)
        XCTAssertTrue(captions.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(clips(in: app).count, 2)
        XCTAssertLessThan(captions.frame.minY, narration.frame.minY)

        // And the viewer builds with them: a caption project that exists only
        // as a pending insert resolves as missing media and raises an alert.
        assertNoAlert(in: app, "Creating captions must not fail the sequence preview")
        attach(window, name: "Captions created from the narration clip")

        // What the preview read was really written: the project is still in
        // the film's library after the app is killed, not only in the context
        // the editor happened to be holding.
        app.terminate()
        app.launch()
        XCTAssertTrue(window.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons[captionClipTitle].waitForExistence(timeout: 15),
                      "The caption project must outlive the session that created it.\n\(app.debugDescription)")
    }

    /// The second run of the menu item: the caption project already exists, so
    /// the item offers to put it back on the timeline rather than create it.
    @MainActor
    func testContextMenuAddsExistingCaptionsBackToTheTimeline() throws {
        let (app, _) = try launchFilm()
        let narration = clip(narrationClipID, in: app)
        XCTAssertTrue(narration.waitForExistence(timeout: 15), app.debugDescription)
        rightClick(narration)
        app.menuItems["Create Captions"].click()
        let captions = captionClip(in: app)
        XCTAssertTrue(captions.waitForExistence(timeout: 15), app.debugDescription)

        // Take them off the timeline again, leaving the project in the library.
        point(in: captions).click()
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(captionClip(in: app).waitForNonExistence(timeout: 10), app.debugDescription)

        rightClick(narration)
        let add = app.menuItems["Add Captions to Timeline"]
        XCTAssertTrue(add.waitForExistence(timeout: 5),
                      "Captions that already exist are added back, not created again.\n\(app.debugDescription)")
        add.click()
        XCTAssertTrue(captionClip(in: app).waitForExistence(timeout: 15), app.debugDescription)
        assertNoAlert(in: app, "Re-adding captions must not fail the sequence preview")
    }

    /// Add Track offers caption lanes, and a sequence can hold several.
    @MainActor
    func testAddTrackMenuStacksCaptionLanes() throws {
        let (app, _) = try launchFilm()
        XCTAssertTrue(header("C1", in: app).waitForExistence(timeout: 15),
                      "A new sequence starts with a caption lane.\n\(app.debugDescription)")

        for name in ["C2", "C3"] {
            element("timeline.add-track", in: app).click()
            let item = app.menuItems["Caption Track"]
            XCTAssertTrue(item.waitForExistence(timeout: 5),
                          "Add Track must offer a caption lane.\n\(app.debugDescription)")
            item.click()
            XCTAssertTrue(header(name, in: app).waitForExistence(timeout: 10), app.debugDescription)
        }

        // They stack over the picture, the newest on top.
        for (upper, lower) in [("C3", "C2"), ("C2", "C1"), ("C1", "V1")] {
            XCTAssertLessThan(header(upper, in: app).frame.minY, header(lower, in: app).frame.minY,
                              "\(upper) must sit above \(lower)")
        }

        // Captions made from the narration go onto one of them.
        rightClick(clip(narrationClipID, in: app))
        app.menuItems["Create Captions"].click()
        XCTAssertTrue(captionClip(in: app).waitForExistence(timeout: 15), app.debugDescription)
        assertNoAlert(in: app, "A sequence with several caption lanes must still preview")
    }

    // MARK: - Helpers

    @MainActor
    private func launchFilm() throws -> (XCUIApplication, XCUIElement) {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NarrativeCaptionUITests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-skipStartupAuth", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-NSQuitAlwaysKeepsWindows", "NO", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["RXFILM_CAPTION_UI_TEST_ROOT"] = root.path
        addTeardownBlock { @MainActor in app.terminate(); try? FileManager.default.removeItem(at: root) }
        app.launch()
        let window = app.windows["Caption UI Test"]
        XCTAssertTrue(window.waitForExistence(timeout: 30),
                      (try? String(contentsOf: root.appendingPathComponent("fixture-error.txt"), encoding: .utf8)) ?? app.debugDescription)
        window.click()
        return (app, window)
    }

    /// A clip whose lane holds nothing else reports that lane's bounds, whose
    /// centre is empty track. Aim just inside the clip's leading edge instead.
    @MainActor
    private func point(in element: XCUIElement) -> XCUICoordinate {
        element.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 20, dy: 12))
    }

    @MainActor
    private func rightClick(_ element: XCUIElement) {
        point(in: element).rightClick()
    }

    /// A track header, by the name shown in the lane's gutter.
    @MainActor
    private func header(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Reorder \(name)")).firstMatch
    }

    @MainActor
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    private func clip(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "timeline.clip.name.\(id)").firstMatch
    }

    @MainActor
    private func clips(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.clip.name."))
    }

    @MainActor
    private func captionClip(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND (value == %@ OR label == %@)",
                                  "timeline.clip.name.", captionClipTitle, captionClipTitle))
            .firstMatch
    }

    /// Every failure in this flow reaches the user as an alert, so one check
    /// covers the preview, the composition build and the caption creation.
    @MainActor
    private func assertNoAlert(in app: XCUIApplication, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let alert = app.sheets.firstMatch
        XCTAssertFalse(alert.waitForExistence(timeout: 8), "\(message): \(text(of: alert))", file: file, line: line)
        let dialog = app.dialogs.firstMatch
        XCTAssertFalse(dialog.exists, "\(message): \(text(of: dialog))", file: file, line: line)
    }

    /// What an alert says, for the failure message: SwiftUI's text carries it
    /// as the element's value rather than its label.
    @MainActor
    private func text(of element: XCUIElement) -> [String] {
        guard element.exists else { return [] }
        return element.staticTexts.allElementsBoundByIndex.map { ($0.value as? String) ?? $0.label }
    }

    @MainActor
    private func attach(_ element: XCUIElement, name: String) {
        let screenshot = XCTAttachment(screenshot: element.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
