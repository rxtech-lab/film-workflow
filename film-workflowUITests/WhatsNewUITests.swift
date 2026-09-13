import XCTest

final class WhatsNewUITests: XCTestCase {
    @MainActor
    func testAnnouncementMenuReplayAndMarketplaceNavigation() throws {
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
        XCTAssertTrue(app.buttons["whats-new.explore"].exists)
        let templatesLight = XCTAttachment(screenshot: app.screenshot())
        templatesLight.name = "Project templates announcement — light"
        templatesLight.lifetime = .keepAlways
        add(templatesLight)

        // Going back returns to the previous card, and the back control disappears on the first one.
        let back = app.buttons["whats-new.back"]
        XCTAssertTrue(back.exists)
        back.click()
        waitForCard("Marketplace is here", in: app)
        XCTAssertTrue(back.waitForNonExistence(timeout: 5))
        XCTAssertFalse(dismiss.exists)
        XCTAssertTrue(app.buttons["whats-new.next"].exists)
        app.buttons["whats-new.next"].click()
        waitForCard("Project templates are here", in: app)
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
        let dark = XCTAttachment(screenshot: app.screenshot())
        dark.name = "Project templates announcement — dark"
        dark.lifetime = .keepAlways
        add(dark)
        close.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))

        showWhatsNew(in: app)
        XCTAssertTrue(app.buttons["whats-new.next"].waitForExistence(timeout: 5))
        app.buttons["whats-new.next"].click()
        let explore = app.buttons["whats-new.explore"]
        XCTAssertTrue(explore.waitForExistence(timeout: 5))
        explore.click()
        XCTAssertTrue(app.windows["Marketplace"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))

        // The app menu also works when Marketplace, rather than a film, is key.
        showWhatsNew(in: app)
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertEqual(app.sheets.count, 1)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))

        app.typeKey("w", modifierFlags: .command)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertEqual(app.windows.count, 0)
        showWhatsNew(in: app)
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(app.windows["Welcome to RxFilmStudio"].exists)
        close.click()
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
