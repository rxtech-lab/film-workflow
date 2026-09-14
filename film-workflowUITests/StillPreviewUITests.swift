import AppKit
import XCTest

/// Clicking a still has to preview it. Its card is mostly filmstrip, and a
/// still is the one kind of footage with no frames to seek into, so a click
/// there used to be swallowed — leaving the viewer wherever it had wandered to
/// while the still stayed selected, until the user selected something else and
/// came back.
final class StillPreviewUITests: XCTestCase {
    private let narrationID = "00000000-0000-0000-0000-0000000000C1"
    private let imageID = "00000000-0000-0000-0000-0000000000C3"
    private let narrationClipID = "00000000-0000-0000-0000-0000000000C5"
    /// The colour the fixture fills the still with.
    private let stillColor = NSColor(srgbRed: 0.2, green: 0.45, blue: 0.85, alpha: 1)

    /// The reported flow. The viewer moves off the still on its own — here by
    /// selecting a clip, which is what putting the sequence back on screen
    /// means — while the still stays selected in the library. Clicking it has
    /// to bring it back; it used to take a detour through another item.
    @MainActor
    func testClickingTheStillPreviewsItWhileItIsAlreadySelected() throws {
        let app = try launchFilm()
        selectTheStill(in: app)
        assertStillIsOnScreen(in: app)

        let clip = element("timeline.clip.name.\(narrationClipID)", in: app)
        XCTAssertTrue(clip.waitForExistence(timeout: 15), app.debugDescription)
        clip.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 20, dy: 12)).click()
        XCTAssertTrue(element("viewer.transport", in: app).waitForNonExistence(timeout: 10),
                      "Selecting a clip shows the sequence.\n\(app.debugDescription)")

        selectTheStill(in: app)
        assertStillIsOnScreen(in: app)
    }

    /// The same demand from the other direction: the viewer is on a take the
    /// pointer is skimming, and the still it is sent to has no frames of its
    /// own to replace it with.
    @MainActor
    func testSelectingTheStillPreviewsItAfterSkimmingATake() throws {
        let app = try launchFilm()
        skimTheTake(in: app)
        selectTheStill(in: app)
        assertStillIsOnScreen(in: app)
    }

    // MARK: - Steps

    /// Rests the pointer on the narration take's frames — the top of its card —
    /// which previews it in the viewer the way a pass over any playable
    /// footage does.
    @MainActor
    private func skimTheTake(in app: XCUIApplication) {
        let card = element("library.item.\(narrationID)", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 15), app.debugDescription)
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).hover()
        XCTAssertTrue(app.buttons["viewer.play"].waitForExistence(timeout: 10),
                      "Skimming a take must preview it.\n\(app.debugDescription)")
    }

    /// Clicks the still's frames, where most of its card is and where a click
    /// naturally lands, rather than its name.
    @MainActor
    private func selectTheStill(in app: XCUIApplication) {
        let card = element("library.item.\(imageID)", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 10), app.debugDescription)
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).click()
    }

    @MainActor
    private func assertStillIsOnScreen(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        // SwiftUI hands its text to the accessibility tree as a value, not a label.
        let transport = element("viewer.transport", in: app)
        let still = transport.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", "Still", "Still")).firstMatch
        XCTAssertTrue(still.waitForExistence(timeout: 10),
                      "The viewer must switch to the selected still.\n\(app.debugDescription)", file: file, line: line)
        XCTAssertFalse(app.buttons["viewer.play"].exists,
                       "A still has no transport to play", file: file, line: line)
        assertColor(stillColor, in: element("viewer.stage", in: app), file: file, line: line)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Still previewed after skimming a take"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    // MARK: - Helpers

    @MainActor
    private func launchFilm() throws -> XCUIApplication {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StillPreviewUITests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-skipStartupAuth", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-NSQuitAlwaysKeepsWindows", "NO", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["RXFILM_STILL_UI_TEST_ROOT"] = root.path
        addTeardownBlock { @MainActor in app.terminate(); try? FileManager.default.removeItem(at: root) }
        app.launch()
        let window = app.windows["Still Preview UI Test"]
        XCTAssertTrue(window.waitForExistence(timeout: 30),
                      (try? String(contentsOf: root.appendingPathComponent("fixture-error.txt"), encoding: .utf8)) ?? app.debugDescription)
        window.click()
        return app
    }

    @MainActor
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// What the stage actually draws, rather than what the header claims.
    @MainActor
    private func assertColor(_ expected: NSColor, in element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let expected = expected.usingColorSpace(.sRGB)!
        nonisolated(unsafe) var sampled: NSColor?
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard element.exists,
                  let image = element.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let actual = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB) else { return false }
            sampled = actual
            return abs(actual.redComponent - expected.redComponent) < 0.2
                && abs(actual.greenComponent - expected.greenComponent) < 0.2
                && abs(actual.blueComponent - expected.blueComponent) < 0.2
        }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [matches], timeout: 10), .completed,
                       """
                       The viewer must show the still itself, not the take it was skimming. \
                       Centre of the stage: \(sampled.map { "\($0.redComponent), \($0.greenComponent), \($0.blueComponent)" } ?? "no pixels")
                       """, file: file, line: line)
    }
}
