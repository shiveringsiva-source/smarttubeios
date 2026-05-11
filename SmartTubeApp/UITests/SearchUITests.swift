import XCTest

// MARK: - SearchUITests
//
// UI tests for the Search tab: bar, suggestions, filters, results, player open.
//
// Requirements:
//   • Network access is required for suggestion and results tests.
//   • Run on an iOS 17+ simulator with the SmartTubeApp scheme selected.

final class SearchUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    private func openSearch() {
        UITestHelpers.tapTab(named: "Search", in: app)
    }

    private var searchBar: XCUIElement {
        app.textFields["search.bar"]
    }

    /// Types `query` into the search bar and submits it.
    private func search(for query: String) {
        openSearch()
        let bar = searchBar
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "search.bar must exist")
        bar.tap()
        bar.typeText(query)
        app.keyboards.buttons["search"].firstMatch.tap()
    }

    // MARK: - Structural tests

    func testSearchBarAppearsOnSearchTab() {
        openSearch()
        XCTAssertTrue(searchBar.waitForExistence(timeout: 5),
                      "search.bar must appear after tapping the Search tab")
        XCTAssertTrue(searchBar.isHittable, "search.bar must be hittable")
    }

    func testSearchTabOpensWithoutCrash() {
        openSearch()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(app.state, .runningForeground,
                       "App should still be running after opening the Search tab")
    }

    // MARK: - Suggestions

    func testTypingQueryShowsSuggestions() throws {
        openSearch()
        let bar = searchBar
        guard bar.waitForExistence(timeout: 5) else {
            XCTFail("search.bar not found")
            return
        }
        bar.tap()
        bar.typeText("swift")

        let suggestions = app.tables["search.suggestionsContainer"]
        guard suggestions.waitForExistence(timeout: 20) else {
            throw XCTSkip("search.suggestionsContainer did not appear within 20 s — network may be unavailable")
        }
        XCTAssertGreaterThan(suggestions.cells.count, 0,
                             "At least one suggestion should appear after typing 'swift'")
    }

    // MARK: - Clear button

    func testClearButtonEmptiesQuery() throws {
        openSearch()
        let bar = searchBar
        guard bar.waitForExistence(timeout: 5) else {
            XCTFail("search.bar not found")
            return
        }
        bar.tap()
        bar.typeText("swift")
        XCTAssertEqual(bar.value as? String, "swift",
                       "Search bar should contain the typed query before clearing")

        // The clear (×) button is a custom SwiftUI Button next to the text field.
        let clearButton = app.buttons["search.clearButton"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 3),
                      "search.clearButton should appear when query is non-empty")
        clearButton.tap()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertNotEqual(bar.value as? String, "swift",
                          "Search bar value should change after tapping clear")
    }

    // MARK: - Results

    func testSearchReturnsVideoCards() throws {
        search(for: "swift programming")
        let results = app.scrollViews["search.results"]
        guard results.waitForExistence(timeout: 5) else {
            XCTFail("search.results container did not appear — network may be unavailable")
            return
        }
        guard let _ = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            XCTFail("No video cards appeared in search results within 20 s")
            return
        }
    }

    func testNoErrorAlertOnSearch() throws {
        search(for: "swift")
        Thread.sleep(forTimeInterval: 10)
        UITestHelpers.assertNoErrorAlert(in: app)
    }

    // MARK: - Filter sheet

    func testFilterSheetOpensAndCloses() throws {
        search(for: "swift")
        // Wait for results so the filter button is definitely visible.
        _ = UITestHelpers.waitForVideoCards(in: app, timeout: 20)

        let filterButton = app.buttons["search.filterButton"]
        guard filterButton.waitForExistence(timeout: 5) else {
            XCTFail("search.filterButton not found")
            return
        }
        filterButton.tap()

        let sheet = app.otherElements["search.filterSheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5),
                      "search.filterSheet should appear after tapping the filter button")

        // Dismiss via Cancel.
        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 3), "Cancel button must exist in filter sheet")
        cancelButton.tap()

        XCTAssertFalse(sheet.waitForExistence(timeout: 3),
                       "search.filterSheet should be dismissed after tapping Cancel")
    }

    func testFilterSheetApplyCreatesActiveChip() throws {
        search(for: "swift")
        _ = UITestHelpers.waitForVideoCards(in: app, timeout: 20)

        let filterButton = app.buttons["search.filterButton"]
        guard filterButton.waitForExistence(timeout: 5) else {
            XCTFail("search.filterButton not found")
            return
        }
        filterButton.tap()

        let sheet = app.otherElements["search.filterSheet"]
        guard sheet.waitForExistence(timeout: 5) else {
            XCTFail("search.filterSheet did not appear")
            return
        }

        // Select "This week" in the Upload date section.
        // The inline Picker option may be accessible by label OR identifier depending on
        // SwiftUI version; scroll until visible then tap using the broadest query.
        let thisWeekPredicate = NSPredicate(format: "label == 'This week' OR identifier == 'This week'")
        let thisWeekOption = app.descendants(matching: .any).matching(thisWeekPredicate).firstMatch
        // The Upload date section is below Sort by — scroll the sheet form to reveal it.
        let sheetForm = app.collectionViews.firstMatch
        UITestHelpers.scrollUntilVisible(thisWeekOption, in: sheetForm)
        XCTAssertTrue(thisWeekOption.waitForExistence(timeout: 5),
                      "'This week' option must be visible in the Upload date picker")
        thisWeekOption.tap()

        let applyButton = app.buttons["Apply"]
        XCTAssertTrue(applyButton.waitForExistence(timeout: 3), "Apply button must exist in filter sheet")
        applyButton.tap()

        // An active filter chip should appear in the filter chips row.
        // FilterChip uses Text(label) — match by accessibility label (not identifier).
        let chipPredicate = NSPredicate(format: "label == 'This week'")
        let chip = app.staticTexts.matching(chipPredicate).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5),
                      "An active filter chip labelled 'This week' should appear after applying the filter")
    }

    // MARK: - Player navigation

    func testTappingResultOpensPlayer() throws {
        search(for: "swift programming")
        guard let firstCard = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            XCTFail("No video cards in search results — network may be unavailable")
            return
        }
        XCTAssertTrue(UITestHelpers.openPlayer(from: firstCard, in: app),
                      "player.titleLabel should appear after tapping a search result")
    }

    // MARK: - Search history

    func testSubmittedQueryAppearsInHistory() throws {
        search(for: "history test query")

        // Re-focus the search bar to show the suggestions/history list.
        let bar = searchBar
        guard bar.waitForExistence(timeout: 5) else { XCTFail("search.bar not found"); return }
        bar.tap()
        // Clear the query so the full history list is shown.
        app.buttons["search.clearButton"].firstMatch.tap()

        let historyRow = app.buttons["search.history.history test query"]
        XCTAssertTrue(historyRow.waitForExistence(timeout: 5),
                      "Submitted query should appear as a history row")
    }

    func testTappingHistoryRowTriggersSearch() throws {
        search(for: "history tap test")

        let bar = searchBar
        guard bar.waitForExistence(timeout: 5) else { XCTFail("search.bar not found"); return }
        bar.tap()
        app.buttons["search.clearButton"].firstMatch.tap()

        let historyRow = app.buttons["search.history.history tap test"]
        guard historyRow.waitForExistence(timeout: 5) else {
            XCTFail("History row not found — previous search may not have persisted")
            return
        }
        historyRow.tap()

        // After tapping a history row the search results container should appear.
        let results = app.scrollViews["search.results"]
        XCTAssertTrue(results.waitForExistence(timeout: 10),
                      "Tapping a history row should trigger the search and show results")
    }

    func testDeleteHistoryEntryRemovesRow() throws {
        search(for: "entry to delete")

        let bar = searchBar
        guard bar.waitForExistence(timeout: 5) else { XCTFail("search.bar not found"); return }
        bar.tap()
        app.buttons["search.clearButton"].firstMatch.tap()

        let deleteButton = app.buttons["Remove entry to delete from history"]
        guard deleteButton.waitForExistence(timeout: 5) else {
            XCTFail("Delete button for history entry not found")
            return
        }
        deleteButton.tap()

        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(app.buttons["search.history.entry to delete"].exists,
                       "History entry should be removed after tapping its delete button")
    }

    func testClearAllHistoryRemovesAllEntries() throws {
        search(for: "clear all test a")
        search(for: "clear all test b")

        let bar = searchBar
        guard bar.waitForExistence(timeout: 5) else { XCTFail("search.bar not found"); return }
        bar.tap()
        app.buttons["search.clearButton"].firstMatch.tap()

        let clearAll = app.buttons["search.history.clearAll"]
        guard clearAll.waitForExistence(timeout: 5) else {
            XCTFail("Clear History button not found")
            return
        }
        clearAll.tap()

        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(app.buttons["search.history.clear all test a"].exists,
                       "All history entries should be removed after Clear History")
        XCTAssertFalse(app.buttons["search.history.clear all test b"].exists,
                       "All history entries should be removed after Clear History")
    }
}
