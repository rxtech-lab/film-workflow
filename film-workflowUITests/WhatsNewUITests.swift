import XCTest

final class WhatsNewUITests: XCTestCase {
    @MainActor
    func testAnnouncementMenuReplayAndNewFilmNavigation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["RXFILM_WHATS_NEW_TEST_SUITE"] = "WhatsNewUITests.\(UUID().uuidString)"
        app.launchArguments = [
            "-uiTesting", "-skipStartupAuth", "-showWhatsNewForTesting",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-AppleInterfaceStyle", "Light", "-NSQuitAlwaysKeepsWindows", "NO",
        ]
        app.launch()

        let dismiss = app.buttons["whats-new.dismiss"]
        let close = app.buttons["whats-new.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertEqual(app.sheets.count, 1)
        // "Got it" is held back until the last card.
        XCTAssertFalse(dismiss.exists)
        waitForCard("Marketplace is here", in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "RxFilm subscription service")).firstMatch.exists)
        let light = XCTAttachment(screenshot: app.screenshot())
        light.name = "Marketplace announcement — light"
        light.lifetime = .keepAlways
        add(light)
        app.buttons["whats-new.next"].click()
        waitForCard("Project templates are here", in: app)
        XCTAssertTrue(app.staticTexts["Make it yours with the agent"].exists)
        // The call to action belongs to the last card only.
        XCTAssertFalse(dismiss.exists)
        let templatesLight = XCTAttachment(screenshot: app.screenshot())
        templatesLight.name = "Project templates announcement — light"
        templatesLight.lifetime = .keepAlways
        add(templatesLight)

        app.buttons["whats-new.next"].click()
        waitForCard("Simple mode", in: app)
        XCTAssertTrue(app.staticTexts["Start from a template"].exists)
        XCTAssertFalse(app.buttons["whats-new.explore"].exists)
        let simpleLight = XCTAttachment(screenshot: app.screenshot())
        simpleLight.name = "Simple mode announcement — light"
        simpleLight.lifetime = .keepAlways
        add(simpleLight)

        advanceToCaptionExport(in: app)
        let captionsLight = XCTAttachment(screenshot: app.screenshot())
        captionsLight.name = "Caption export announcement — light"
        captionsLight.lifetime = .keepAlways
        add(captionsLight)

        // Going back returns to the previous card, and the back control disappears on the first one.
        let back = app.buttons["whats-new.back"]
        XCTAssertTrue(back.exists)
        back.click()
        waitForCard("Background rendering", in: app)
        back.click()
        waitForCard("Simple mode", in: app)
        back.click()
        waitForCard("Project templates are here", in: app)
        back.click()
        waitForCard("Marketplace is here", in: app)
        XCTAssertTrue(back.waitForNonExistence(timeout: 5))
        XCTAssertFalse(dismiss.exists)
        XCTAssertTrue(app.buttons["whats-new.next"].exists)
        app.buttons["whats-new.next"].click()
        waitForCard("Project templates are here", in: app)
        app.buttons["whats-new.next"].click()
        waitForCard("Simple mode", in: app)
        advanceToCaptionExport(in: app)
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))

        dismiss.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))

        app.terminate()
        app.launchArguments[app.launchArguments.firstIndex(of: "Light")!] = "Dark"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 2))

        showWhatsNew(in: app)
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertEqual(app.sheets.count, 1)
        app.buttons["whats-new.next"].click()
        waitForCard("Project templates are here", in: app)
        app.buttons["whats-new.next"].click()
        waitForCard("Simple mode", in: app)
        advanceToCaptionExport(in: app)
        let dark = XCTAttachment(screenshot: app.screenshot())
        dark.name = "Caption export announcement — dark"
        dark.lifetime = .keepAlways
        add(dark)
        close.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))

        showWhatsNew(in: app)
        XCTAssertTrue(app.buttons["whats-new.next"].waitForExistence(timeout: 5))
        app.buttons["whats-new.next"].click()
        waitForCard("Project templates are here", in: app)
        app.buttons["whats-new.next"].click()
        waitForCard("Simple mode", in: app)
        advanceToCaptionExport(in: app)
        // The last card offers a new film so users can try caption export.
        let startFilm = app.buttons["whats-new.explore"]
        XCTAssertTrue(startFilm.waitForExistence(timeout: 5))
        startFilm.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["new-film.gallery"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["new-film.template.company-intro-video"].exists)

        // The app menu also works when the Welcome window, rather than a film, is key.
        showWhatsNew(in: app)
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertEqual(app.sheets.count, 1)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForNonExistence(timeout: 5))
        showWhatsNew(in: app)
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(app.windows["Welcome to RxFilmStudio"].exists)
        close.click()
    }

    @MainActor
    private func advanceToCaptionExport(in app: XCUIApplication) {
        app.buttons["whats-new.next"].click()
        waitForCard("Background rendering", in: app)
        XCTAssertTrue(app.staticTexts["One queue for every film"].exists)
        XCTAssertTrue(app.staticTexts["Your timeline keeps moving"].exists)
        XCTAssertFalse(app.buttons["whats-new.dismiss"].exists)
        let queue = XCTAttachment(screenshot: app.screenshot())
        queue.name = "Background rendering announcement"
        queue.lifetime = .keepAlways
        add(queue)

        app.buttons["whats-new.next"].click()
        waitForCard("Captions in your exports", in: app)
        XCTAssertTrue(app.staticTexts["Burn captions into the video"].exists)
        XCTAssertTrue(app.staticTexts["Save caption files too"].exists)
        XCTAssertTrue(app.buttons["whats-new.explore"].exists)
        XCTAssertFalse(app.buttons["whats-new.next"].exists)
    }

    /// The paging transition briefly keeps both cards mounted, so wait for one title to remain.
    @MainActor
    private func waitForCard(
        _ title: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let titles = app.staticTexts.matching(identifier: "whats-new.title")
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 1"), object: titles)
        XCTAssertEqual(
            XCTWaiter().wait(for: [settled], timeout: 5), .completed,
            "Paging transition never settled on a single card", file: file, line: line
        )
        XCTAssertEqual(titles.firstMatch.label, title, file: file, line: line)
    }

    @MainActor
    private func showWhatsNew(in app: XCUIApplication) {
        app.menuBars.menuBarItems["film-workflow"].click()
        app.menuItems["What's New…"].click()
    }
}
