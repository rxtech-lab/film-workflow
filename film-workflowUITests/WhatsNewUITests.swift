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
        XCTAssertTrue(dismiss.waitForExistence(timeout: 10))
        XCTAssertEqual(app.sheets.count, 1)
        XCTAssertTrue(app.staticTexts["whats-new.title"].label.contains("Marketplace is here"))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "RxFilm subscription service")).firstMatch.exists)
        let light = XCTAttachment(screenshot: app.screenshot())
        light.name = "Marketplace announcement — light"
        light.lifetime = .keepAlways
        add(light)
        dismiss.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))

        app.terminate()
        app.launchArguments[app.launchArguments.firstIndex(of: "Light")!] = "Dark"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 2))

        showWhatsNew(in: app)
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        XCTAssertEqual(app.sheets.count, 1)
        let dark = XCTAttachment(screenshot: app.screenshot())
        dark.name = "Marketplace announcement — dark"
        dark.lifetime = .keepAlways
        add(dark)
        app.buttons["whats-new.close"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))

        showWhatsNew(in: app)
        let explore = app.buttons["whats-new.explore"]
        XCTAssertTrue(explore.waitForExistence(timeout: 5))
        explore.click()
        XCTAssertTrue(app.windows["Marketplace"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))

        // The app menu also works when Marketplace, rather than a film, is key.
        showWhatsNew(in: app)
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        XCTAssertEqual(app.sheets.count, 1)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))

        app.typeKey("w", modifierFlags: .command)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertEqual(app.windows.count, 0)
        showWhatsNew(in: app)
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        XCTAssertTrue(app.windows["Welcome to RxFilmStudio"].exists)
        dismiss.click()
    }

    @MainActor
    private func showWhatsNew(in app: XCUIApplication) {
        app.menuBars.menuBarItems["film-workflow"].click()
        app.menuItems["What's New…"].click()
    }
}
