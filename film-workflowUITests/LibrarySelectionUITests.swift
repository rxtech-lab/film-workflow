import AppKit
import XCTest

/// The empty part of the library — the gap under the last card — has to behave
/// like a background: clicking it drops the selection, and right-clicking it
/// offers the same creation menu a folder offers. Both used to be attached to
/// the scroll view itself, which never sees a click that lands where it has no
/// content, so the gap swallowed them.
final class LibrarySelectionUITests: XCTestCase {
    private let blueID = "00000000-0000-0000-0000-0000000000E1"
    private let redID = "00000000-0000-0000-0000-0000000000E2"

    @MainActor
    func testClickingEmptySpaceClearsTheLibrarySelection() throws {
        let app = try launchFilm()
        select(blueID, in: app)
        XCTAssertEqual(footageTitle(in: app), "Blue Card",
                       "Selecting a card must show its takes.\n\(app.debugDescription)")
        XCTAssertTrue(element("library.item.\(blueID)", in: app).isSelected)

        clickEmptySpace(in: app)

        XCTAssertTrue(waitForFootageTitle("Footage", in: app),
                      "A click on the empty part of the library must clear the selection.\n\(app.debugDescription)")
        XCTAssertFalse(element("library.item.\(blueID)", in: app).isSelected,
                       "The card must stop reading as selected")
        attach(app, name: "Library after clicking its empty space")
    }

    /// The gap a row leaves beside its last card is as empty as the space
    /// under it, and clicking it means the same thing.
    @MainActor
    func testClickingBesideACardClearsTheSelection() throws {
        let app = try launchFilm()
        select(blueID, in: app)
        XCTAssertTrue(waitForFootageTitle("Blue Card", in: app), app.debugDescription)

        // Past the right-hand card of the row, which the film's own sequence
        // shares with the two imported stills.
        let grid = element("library.grid", in: app)
        let cards = [blueID, redID].map { element("library.item.\($0)", in: app) }
        let last = cards.max { $0.frame.maxX < $1.frame.maxX }!
        let x = last.frame.maxX + 16
        try XCTSkipUnless(x < grid.frame.maxX - 4, "The cards fill the row; no gap to click")
        grid.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: x - grid.frame.minX, dy: last.frame.midY - grid.frame.minY))
            .click()

        XCTAssertTrue(waitForFootageTitle("Footage", in: app),
                      "A click beside the last card must clear the selection.\n\(app.debugDescription)")
    }

    /// The click that clears the selection must still leave the cards
    /// selectable: the background takes only the clicks that miss them.
    @MainActor
    func testCardsStaySelectableAfterDeselecting() throws {
        let app = try launchFilm()
        select(blueID, in: app)
        clickEmptySpace(in: app)
        XCTAssertTrue(waitForFootageTitle("Footage", in: app), app.debugDescription)

        select(redID, in: app)
        XCTAssertTrue(waitForFootageTitle("Red Card", in: app),
                      "A card clicked after a deselect must select.\n\(app.debugDescription)")
        XCTAssertFalse(element("library.item.\(blueID)", in: app).isSelected,
                       "Only one card is selected at a time")
    }

    /// Right-clicking the same empty space is how footage is created where
    /// there is none yet, so it offers what the New menu offers.
    @MainActor
    func testEmptySpaceOffersTheCreationMenu() throws {
        let app = try launchFilm()
        emptySpace(in: app).rightClick()

        // The app's own menus carry a "New" of their own, so the kinds behind
        // it are what says this menu is the library's: they are listed only
        // once a submenu opens, which only a hover over an open context menu
        // does.
        let new = app.menuItems["New"]
        XCTAssertTrue(new.waitForExistence(timeout: 5), app.debugDescription)
        new.hover()
        XCTAssertTrue(app.menuItems["Remotion"].waitForExistence(timeout: 5),
                      "The empty part of the library must offer the creation menu.\n\(app.debugDescription)")
        // One snapshot of what is open, rather than a query per item: the menu
        // closes on its own if it is left alone for long.
        let items = Set(app.menuItems.allElementsBoundByIndex.map { $0.title.isEmpty ? $0.label : $0.title })
        for title in ["Sequence", "Music", "Narration", "Captions", "Images", "Video", "Remotion",
                      "Import Media…", "New Folder…"] {
            XCTAssertTrue(items.contains(title), "The menu must offer \(title), and offered \(items.sorted())")
        }
        attach(app, name: "Creation menu on the library's empty space")
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Steps

    /// Clicks a card's frames, where most of it is and where a click naturally
    /// lands.
    @MainActor
    private func select(_ id: String, in app: XCUIApplication) {
        let card = element("library.item.\(id)", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 15), app.debugDescription)
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).click()
    }

    /// The gap under the only row of cards. The fixture leaves the library
    /// pane far taller than the two cards in it, so the bottom of the grid is
    /// always empty.
    @MainActor
    private func emptySpace(in app: XCUIApplication) -> XCUICoordinate {
        let grid = element("library.grid", in: app)
        XCTAssertTrue(grid.waitForExistence(timeout: 15), app.debugDescription)
        return grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
    }

    @MainActor
    private func clickEmptySpace(in app: XCUIApplication) {
        emptySpace(in: app).click()
    }

    // MARK: - Helpers

    /// What the footage pane is titled, which is the selected item's name, or
    /// "Footage" when nothing is selected.
    @MainActor
    private func footageTitle(in app: XCUIApplication) -> String {
        app.buttons["toggle-footage-browser"].label
    }

    @MainActor
    private func waitForFootageTitle(_ title: String, in app: XCUIApplication) -> Bool {
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.footageTitle(in: app) == title
        }, object: nil)
        return XCTWaiter().wait(for: [matches], timeout: 10) == .completed
    }

    @MainActor
    private func launchFilm() throws -> XCUIApplication {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibrarySelectionUITests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-skipStartupAuth", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-NSQuitAlwaysKeepsWindows", "NO", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["RXFILM_LIBRARY_UI_TEST_ROOT"] = root.path
        addTeardownBlock { @MainActor in app.terminate(); try? FileManager.default.removeItem(at: root) }
        app.launch()
        let window = app.windows["Library Selection UI Test"]
        XCTAssertTrue(window.waitForExistence(timeout: 30),
                      (try? String(contentsOf: root.appendingPathComponent("fixture-error.txt"), encoding: .utf8)) ?? app.debugDescription)
        app.activate()
        window.click()
        return app
    }

    @MainActor
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
