import XCTest

/// Exercises the actual inspector tab and modal sheet with 2,000 active cues,
/// 2,000 inactive cues, word timings, translations and 66 minutes of audio.
final class CaptionPerformanceUITests: XCTestCase {
    private let projectID = "00000000-0000-0000-0000-00000000CA00"
    private let firstID = "00000000-0000-0000-0000-00000000CA01"
    private let responseBudget: TimeInterval = 5

    @MainActor
    func testCaptionTabOpeningPerformance() throws {
        let app = try launchFilm()
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart]
        measure(metrics: [XCTClockMetric()], options: options) {
            let tab = element("inspector.tab.captions", in: app)
            XCTAssertTrue(tab.waitForExistence(timeout: 10))
            startMeasuring()
            let started = Date()
            tab.click()
            XCTAssertTrue(element("caption-editor-text.\(firstID)", in: app).waitForExistence(timeout: responseBudget))
            let elapsed = Date().timeIntervalSince(started)
            stopMeasuring()
            record("caption-tab", seconds: elapsed)
            XCTAssertLessThan(elapsed, responseBudget, "Opening the caption tab must not freeze with 2,000 captions")
            let count = text(element("caption-editor-count", in: app))
            XCTAssertTrue(count.contains("2,000") || count.contains("2000"))
            element("inspector.tab.settings", in: app).click()
            XCTAssertTrue(element("caption-editor-retime", in: app).waitForNonExistence(timeout: responseBudget))
        }
    }

    @MainActor
    func testRetimeSheetOpeningPerformance() throws {
        let app = try launchFilm()
        openCaptions(in: app)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart]
        measure(metrics: [XCTClockMetric()], options: options) {
            startMeasuring()
            let started = Date()
            element("caption-editor-retime", in: app).click()
            XCTAssertTrue(element("caption-retime-text.\(firstID)", in: app).waitForExistence(timeout: responseBudget))
            let elapsed = Date().timeIntervalSince(started)
            stopMeasuring()
            record("retime-sheet", seconds: elapsed)
            XCTAssertLessThan(elapsed, responseBudget, "Opening the retimer must not rescan the transcript for each row")
            XCTAssertTrue(element("caption-retime-set-boundary", in: app).isEnabled)
            XCTAssertFalse(element("caption-retime-save", in: app).isEnabled)
            element("caption-retime-cancel", in: app).click()
            XCTAssertTrue(element("caption-retime-cancel", in: app).waitForNonExistence(timeout: responseBudget))
        }
    }

    @MainActor
    func testRetimePlaybackEditingCancelAndSaveStayResponsive() throws {
        let app = try launchFilm()
        openCaptions(in: app)
        openRetimer(in: app)
        let playhead = element("caption-retime-playhead", in: app)
        let initialTime = text(playhead)
        element("caption-retime-play", in: app).click()
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.text(playhead) != initialTime
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: responseBudget), .completed,
                       "Playback must advance with the long transcript on screen")

        // The second press advances to caption 2, exercising focus and scroll
        // while the audio clock is also invalidating the transport controls.
        let started = Date()
        element("caption-retime-set-boundary", in: app).click()
        element("caption-retime-set-boundary", in: app).click()
        XCTAssertTrue(text(element("caption-retime-position", in: app)).hasPrefix("2 /"))
        XCTAssertTrue(element("caption-retime-save", in: app).isEnabled)
        record("retime-two-boundaries-during-playback", seconds: Date().timeIntervalSince(started))
        XCTAssertLessThan(Date().timeIntervalSince(started), responseBudget)
        element("caption-retime-cancel", in: app).click()
        XCTAssertTrue(element("caption-retime-cancel", in: app).waitForNonExistence(timeout: responseBudget))

        openRetimer(in: app)
        XCTAssertFalse(element("caption-retime-save", in: app).isEnabled, "Cancel must discard the draft")
        element("caption-retime-forward", in: app).click()
        element("caption-retime-set-boundary", in: app).click()
        XCTAssertTrue(element("caption-retime-save", in: app).isEnabled)
        let saveStarted = Date()
        element("caption-retime-save", in: app).click()
        XCTAssertTrue(element("caption-retime-cancel", in: app).waitForNonExistence(timeout: responseBudget))
        record("retime-save", seconds: Date().timeIntervalSince(saveStarted))
        XCTAssertLessThan(Date().timeIntervalSince(saveStarted), responseBudget)

        openRetimer(in: app)
        XCTAssertFalse(element("caption-retime-save", in: app).isEnabled)
        element("caption-retime-cancel", in: app).click()
    }

    @MainActor
    func testRetimeScrollingPreservesSelectionUntilCaptionClick() throws {
        let app = try launchFilm()
        openCaptions(in: app)
        openRetimer(in: app)
        let position = element("caption-retime-position", in: app)
        let playhead = element("caption-retime-playhead", in: app)
        let initialPosition = text(position)
        let initialTime = text(playhead)
        let list = app.scrollViews["caption-retime-list"]
        list.scroll(byDeltaX: 0, deltaY: -300)
        XCTAssertEqual(text(position), initialPosition, "Scrolling must not select another caption")
        XCTAssertEqual(text(playhead), initialTime, "Scrolling must not seek the audio")
        XCTAssertFalse(element("caption-retime-save", in: app).isEnabled)

        let visible = try XCTUnwrap(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "caption-retime-text."))
            .allElementsBoundByIndex.first { row in
                row.identifier != "caption-retime-text.\(firstID)" && list.frame.contains(row.frame) && row.isHittable
            })
        let number = text(visible).split(separator: ":")[0].replacingOccurrences(of: "Caption ", with: "")
        visible.click()
        XCTAssertEqual(text(position), "\(number) / 2000", "Clicking a caption must select it")
        let selected = text(position)
        list.scroll(byDeltaX: 0, deltaY: 200)
        XCTAssertEqual(text(position), selected)
        element("caption-retime-cancel", in: app).click()
    }

    @MainActor
    func testLongCaptionPreviewScrollingPerformance() throws {
        let app = try launchFilm()
        let preview = app.scrollViews["footage.versions"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        let rowID = "filmstrip.00000000-0000-0000-0000-00000000CB00.row."
        let firstRow = app.descendants(matching: .any).matching(identifier: rowID + "0").firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        let initialFrame = firstRow.frame
        let started = Date()
        preview.scroll(byDeltaX: 0, deltaY: -400)
        let elapsed = Date().timeIntervalSince(started)
        record("caption-preview-scroll", seconds: elapsed)
        XCTAssertLessThan(elapsed, responseBudget)
        XCTAssertTrue(!firstRow.exists || firstRow.frame != initialFrame, "The preview must actually scroll")

        let visible = try XCTUnwrap(app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", rowID)).allElementsBoundByIndex
            .first { preview.frame.contains($0.frame) && $0.isHittable })
        let timecode = app.staticTexts["viewer.timecode"]
        let initialTime = text(timecode)
        let skimStarted = Date()
        visible.scroll(byDeltaX: 80, deltaY: 0)
        record("caption-preview-scrub", seconds: Date().timeIntervalSince(skimStarted))
        XCTAssertLessThan(Date().timeIntervalSince(skimStarted), responseBudget)
        XCTAssertNotEqual(text(timecode), initialTime, "Horizontal scrolling must update the caption preview")
    }

    @MainActor
    private func launchFilm() throws -> XCUIApplication {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CaptionPerformanceUITests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-skipStartupAuth", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-SUEnableAutomaticChecks", "NO", "-SUHasLaunchedBefore", "YES",
                               "-NSQuitAlwaysKeepsWindows", "NO", "-ApplePersistenceIgnoreState", "YES", "-inspector.tab", "settings"]
        app.launchEnvironment["RXFILM_CAPTION_PERFORMANCE_UI_TEST_ROOT"] = root.path
        addTeardownBlock { @MainActor in
            app.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        app.launch()
        let window = app.windows["Long Caption UI Test"]
        XCTAssertTrue(window.waitForExistence(timeout: 60),
                      (try? String(contentsOf: root.appendingPathComponent("fixture-error.txt"), encoding: .utf8)) ?? app.debugDescription)
        app.activate()
        window.click()
        let card = element("library.item.\(projectID)", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 15), app.debugDescription)
        card.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 20, dy: 15)).click()
        XCTAssertTrue(element("inspector.tab.captions", in: app).waitForExistence(timeout: 15), app.debugDescription)
        return app
    }

    @MainActor
    private func openCaptions(in app: XCUIApplication) {
        element("inspector.tab.captions", in: app).click()
        XCTAssertTrue(element("caption-editor-text.\(firstID)", in: app).waitForExistence(timeout: responseBudget))
    }

    @MainActor
    private func openRetimer(in app: XCUIApplication) {
        element("caption-editor-retime", in: app).click()
        XCTAssertTrue(element("caption-retime-text.\(firstID)", in: app).waitForExistence(timeout: responseBudget))
    }

    @MainActor
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        // Keep queries typed: walking every accessibility element in a long
        // transcript measures XCTest's tree traversal as well as app work.
        if id.hasPrefix("inspector.tab.") { return app.radioButtons[id] }
        // Selectable caption text is exposed as a container on macOS.
        if id.hasPrefix("caption-editor-text.") {
            return app.descendants(matching: .any).matching(identifier: id).firstMatch
        }
        if id.contains("-text.") || id == "caption-editor-count"
            || id == "caption-retime-position" || id == "caption-retime-playhead" {
            return app.staticTexts[id]
        }
        return app.buttons[id]
    }

    @MainActor
    private func text(_ element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }

    private func record(_ operation: String, seconds: TimeInterval) {
        let report = "\(operation): \(String(format: "%.3f", seconds)) s (2000 active captions; 4000 stored)"
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = operation
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
