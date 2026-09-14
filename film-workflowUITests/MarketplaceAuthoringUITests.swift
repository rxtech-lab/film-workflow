import XCTest

final class MarketplaceAuthoringUITests: XCTestCase {
    @MainActor func testAdminCreatesAndReopensTemplateDraft() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-skipStartupAuth", "-marketplaceAuthoringUITest", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-NSQuitAlwaysKeepsWindows", "NO"]
        app.launch()
        app.typeKey("m", modifierFlags: [.command, .option])
        let create = app.buttons["marketplace-create-item"]
        XCTAssertTrue(create.waitForExistence(timeout: 15)); create.click()
        let title = app.textFields["marketplace-author-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.click(); title.typeText("Cinematic Travel Template")
        let prompt = app.textViews["template-prompt"]
        XCTAssertTrue(prompt.exists); prompt.click(); prompt.typeText("Make a travel story from a wide shot and a detail shot.")
        app.buttons["Save Draft"].click()
        XCTAssertTrue(app.staticTexts["Draft saved"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Template editor draft saved"; screenshot.lifetime = .keepAlways; add(screenshot)
        // The confirmation replaces the form and its action bar, so the way
        // back to the fields is its own button.
        app.buttons["Keep Editing"].firstMatch.click()
        app.buttons["Done"].firstMatch.click()
        // Publishing and deleting moved to the row's context menu, so the
        // editor is reopened from the sidebar's authoring list.
        sidebarItem(app, "marketplace-manage-button").click()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Cinematic Travel Template")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.click()
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        XCTAssertEqual(prompt.value as? String, "Make a travel story from a wide shot and a detail shot.")
        XCTAssertEqual(title.value as? String, "Cinematic Travel Template")
        app.terminate()
    }
    @MainActor func testSignedOutMarketplaceHidesAuthoring() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-skipStartupAuth", "-AppleLanguages", "(en)", "-NSQuitAlwaysKeepsWindows", "NO"]
        app.launch(); app.typeKey("m", modifierFlags: [.command, .option])
        XCTAssertTrue(app.windows["Marketplace"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["marketplace-create-item"].exists)
        XCTAssertFalse(sidebarItem(app, "marketplace-manage-button").exists)
        XCTAssertFalse(sidebarItem(app, "marketplace-my-items").exists)
        app.terminate()
    }

    /// A sidebar row is not a button, and its element type differs between
    /// macOS releases, so it is matched by identifier alone.
    @MainActor private func sidebarItem(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
