import XCTest

/// The track fixture's sequence previews through MotionSwift: the stage compiles the generated
/// film, follows the transport and reports each rendered frame in its accessibility label, which
/// works without screen-capture permission.
final class MotionSequencePreviewUITests: XCTestCase {
    @MainActor
    func testSequencePreviewRendersAndFollowsTheTransport() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MotionPreviewUITests-\(UUID())")
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

        let stage = app.descendants(matching: .any).matching(identifier: "sequence.motionStage").firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 15), app.debugDescription)
        let rendered = NSPredicate { _, _ in stage.label.hasPrefix("Rendered frame") }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: rendered, object: nil)], timeout: 30), .completed,
                       "Preview never rendered: \(stage.label)")
        let first = stage.label

        // Step forward one frame: the stage follows the transport to a new frame.
        let next = app.buttons["sequence.viewer.next-frame"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.click()
        let moved = NSPredicate { _, _ in
            stage.label.hasPrefix("Rendered frame") && stage.label != first
        }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)], timeout: 15), .completed,
                       "Preview stayed on \(stage.label)")
    }
}
