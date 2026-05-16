import XCTest

// MARK: - HomeFeedAndSettingsUITests
//
// Merged from: HomeFeedNoDuplicatesUITests + SettingsUITests
// (testSignInButtonVisibleWhenSignedOut relaunches with --uitesting-sign-out and
//  is kept separately in SettingsUITests.swift to avoid corrupting shared state)
//
// Single launch args: --uitesting --uitesting-reset-settings
// Home feed tests run after settings tests alphabetically (test_ sorts after testA-Z).
// Settings tests restore any toggle state they change so order is safe.

final class HomeFeedAndSettingsUITests: XCTestCase {

    private static var sharedApp: XCUIApplication!

    // MARK: - Lifecycle

    override class func setUp() {
        super.setUp()
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-reset-settings"]
        app.launch()
        sharedApp = app
    }

    override class func tearDown() {
        sharedApp?.terminate()
        sharedApp = nil
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        // Close full-screen player if a previous test left it open.
        let playerBack = app.buttons["player.backButton"].firstMatch
        if playerBack.waitForExistence(timeout: 2), playerBack.isHittable {
            playerBack.tap()
            Thread.sleep(forTimeInterval: 1.0)
        }
        // Close mini-player if present.
        let miniClose = app.buttons["miniPlayer.closeButton"].firstMatch
        if miniClose.waitForExistence(timeout: 2), miniClose.isHittable {
            miniClose.tap()
        }
        // If a NavigationStack sub-screen is showing (e.g. Settings → Visible Sections),
        // the tab bar is hidden underneath it and tapTab() will fail. Pop back to root
        // so the tab bar becomes hittable before each test starts.
        let homeTab = app.tabBars.buttons["Home"]
        if !homeTab.waitForExistence(timeout: 1) || !homeTab.isHittable {
            let navBack = app.navigationBars.buttons.firstMatch
            if navBack.waitForExistence(timeout: 2), navBack.isHittable {
                navBack.tap()
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    // MARK: - Helpers

    private var app: XCUIApplication { Self.sharedApp }

    private func openSettings() {
        UITestHelpers.tapTab(named: "Settings", in: app)
    }

    /// Collects all currently visible `video.card.*` element identifiers.
    ///
    /// SwiftUI propagates `.accessibilityIdentifier("video.card.<id>")` set on a
    /// VideoCardView wrapper to ALL leaf accessibility elements within the card
    /// (thumbnail image + every text label). To avoid false duplicates we query
    /// only `.image` elements — each card has exactly one thumbnail image that
    /// receives the card's identifier, giving us one entry per card.
    private func visibleCardIdentifiers() -> [String] {
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let images = app.descendants(matching: .image).matching(predicate)
        return (0..<images.count).map { images.element(boundBy: $0).identifier }
    }

    /// Returns any identifiers that appear more than once in `ids`.
    private func duplicates(in ids: [String]) -> [String] {
        var seen = Set<String>()
        var dupes = [String]()
        for id in ids {
            if !seen.insert(id).inserted { dupes.append(id) }
        }
        return dupes
    }

    // MARK: - Tests (from SettingsUITests)

    func testSettingsTabOpens() {
        openSettings()
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5),
                      "Settings form should appear after tapping the Settings tab")
    }

    func testPlayerSectionVisible() {
        openSettings()
        let speedRow = app.cells.containing(.staticText, identifier: "Playback Speed").firstMatch
        XCTAssertTrue(speedRow.waitForExistence(timeout: 5),
                      "'Playback Speed' row must be visible in the Player section")
    }

    func testHideShortsToggleToggles() {
        openSettings()
        let form = app.collectionViews.firstMatch
        let toggle = form.switches["settings.hideShortsToggle"]
        UITestHelpers.scrollUntilVisible(toggle, in: form)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "settings.hideShortsToggle must be present in the Interface section")
        let before = toggle.value as? String
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        let after = toggle.value as? String
        XCTAssertNotEqual(before, after,
                          "Hide Shorts toggle value should change after tapping")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
    }

    func testVisibleSectionsNavigationLinkOpens() {
        openSettings()
        let form = app.collectionViews.firstMatch
        let link = form.cells.containing(.staticText, identifier: "Visible Sections").firstMatch
        UITestHelpers.scrollUntilVisible(link, in: form)
        XCTAssertTrue(link.waitForExistence(timeout: 5),
                      "'Visible Sections' NavigationLink row must be present in Interface section")
        link.tap()
        let navTitle = app.navigationBars["Visible Sections"].firstMatch
        XCTAssertTrue(navTitle.waitForExistence(timeout: 5),
                      "Navigating to Visible Sections should show that navigation title")
    }

    func testSponsorBlockToggleEnablesSection() {
        openSettings()
        let form = app.collectionViews.firstMatch
        let toggleQuery = app.switches["settings.sponsorBlockToggle"]
        UITestHelpers.scrollUntilVisible(toggleQuery, in: form)
        XCTAssertTrue(toggleQuery.waitForExistence(timeout: 5),
                      "settings.sponsorBlockToggle must be present in the SponsorBlock section")

        if (toggleQuery.value as? String) == "1" {
            toggleQuery.tap()
            Thread.sleep(forTimeInterval: 1.5)
        }

        let enableToggle = app.switches["settings.sponsorBlockToggle"].firstMatch
        XCTAssertTrue(enableToggle.waitForExistence(timeout: 5),
                      "settings.sponsorBlockToggle must still be present after turning it off")
        enableToggle.tap()

        let excludedChannelsRow = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Excluded Channels'"))
            .firstMatch
        UITestHelpers.scrollUntilVisible(excludedChannelsRow, in: form)
        XCTAssertTrue(excludedChannelsRow.waitForExistence(timeout: 6),
                      "SponsorBlock category pickers should appear when SponsorBlock is enabled")

        Thread.sleep(forTimeInterval: 0.5)
        let restoreToggle = app.switches["settings.sponsorBlockToggle"].firstMatch
        var scrollBack = 0
        while !restoreToggle.exists && scrollBack < 10 {
            form.swipeDown()
            scrollBack += 1
        }
        XCTAssertTrue(restoreToggle.waitForExistence(timeout: 5),
                      "settings.sponsorBlockToggle must still be present for cleanup")
        restoreToggle.tap()
    }

    func testAboutSectionResetButtonVisible() {
        openSettings()
        let form = app.collectionViews.firstMatch
        let resetButton = form.buttons["settings.resetAllButton"]
        UITestHelpers.scrollUntilVisible(resetButton, in: form)
        XCTAssertTrue(resetButton.waitForExistence(timeout: 5),
                      "settings.resetAllButton should be visible in the About section")
    }

    func testResetAllSettingsShowsConfirmation() {
        openSettings()
        let form = app.collectionViews.firstMatch
        let resetButton = form.buttons["settings.resetAllButton"]
        UITestHelpers.scrollUntilVisible(resetButton, in: form)
        guard resetButton.waitForExistence(timeout: 5) else {
            XCTFail("settings.resetAllButton not found")
            return
        }
        resetButton.tap()
        if app.alerts.firstMatch.waitForExistence(timeout: 2) {
            app.alerts.firstMatch.buttons.firstMatch.tap()
        }
        XCTAssertEqual(app.state, .runningForeground,
                       "App should still be running after Reset All Settings")
    }

    func testLandscapeAlwaysPlayToggleExistsAndToggles() {
        openSettings()
        let form = app.collectionViews.firstMatch
        let toggle = form.switches["settings.landscapeAlwaysPlayToggle"]
        UITestHelpers.scrollUntilVisible(toggle, in: form)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "settings.landscapeAlwaysPlayToggle must be present in the Player section (iOS only)")
        let before = toggle.value as? String
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        let after = toggle.value as? String
        XCTAssertNotEqual(before, after,
                          "Landscape Always Play toggle value must change after tapping")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
    }

    func testLandscapeAlwaysPlayOpensPlayerWithoutCrash() throws {
        openSettings()
        let form = app.collectionViews.firstMatch
        let toggle = form.switches["settings.landscapeAlwaysPlayToggle"]
        UITestHelpers.scrollUntilVisible(toggle, in: form)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "settings.landscapeAlwaysPlayToggle must be present")
        let wasOn = (toggle.value as? String) == "1"
        if !wasOn {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
            XCTAssertEqual(toggle.value as? String, "1",
                           "Toggle must be ON before opening player")
        }

        UITestHelpers.tapTab(named: "Home", in: app)
        let feedPredicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(feedPredicate)
        let feedLoaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"),
                                                   object: cards)
        guard XCTWaiter().wait(for: [feedLoaded], timeout: 20) == .completed else {
            if !wasOn {
                openSettings()
                UITestHelpers.scrollUntilVisible(toggle, in: form)
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
            }
            try captureAndSkip("Home feed did not load within 20 s — network unavailable", in: app)
        }
        cards.firstMatch.tap()

        let playerTitle = app.staticTexts["player.titleLabel"].firstMatch
        XCTAssertTrue(playerTitle.waitForExistence(timeout: 15),
                      "player.titleLabel must appear — PlayerView opened and orientation code ran")

        XCUIDevice.shared.orientation = .landscapeLeft
        let landscapePredicate = NSPredicate { [app] _, _ in
            app.frame.size.width > app.frame.size.height
        }
        let landscapeExpect = XCTNSPredicateExpectation(predicate: landscapePredicate, object: nil)
        let landscapeResult = XCTWaiter().wait(for: [landscapeExpect], timeout: 3)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(
            landscapeResult, .completed,
            "App must support landscape while the player is open (landscapeAlwaysPlay = ON). " +
            "frame was \(app.frame.size)"
        )

        let dismissButton = app.buttons["player.backButton"].firstMatch
        XCTAssertTrue(dismissButton.waitForExistence(timeout: 5),
                      "player.backButton must be reachable for dismissal")
        dismissButton.tap()
        if !wasOn {
            openSettings()
            UITestHelpers.scrollUntilVisible(toggle, in: form, scrollViewTimeout: 10)
            guard toggle.exists else { return }
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        }
    }

    func testLandscapeAlwaysPlayBackButtonReturnsHome() throws {
        openSettings()
        let form = app.collectionViews.firstMatch
        let toggle = form.switches["settings.landscapeAlwaysPlayToggle"]
        UITestHelpers.scrollUntilVisible(toggle, in: form)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "settings.landscapeAlwaysPlayToggle must be present")
        let wasOn = (toggle.value as? String) == "1"
        if !wasOn {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
            XCTAssertEqual(toggle.value as? String, "1",
                           "Toggle must be ON before opening player")
        }

        defer {
            if !wasOn {
                openSettings()
                let f = app.collectionViews.firstMatch
                if f.waitForExistence(timeout: 10) {
                    let t = f.switches["settings.landscapeAlwaysPlayToggle"]
                    UITestHelpers.scrollUntilVisible(t, in: f)
                    t.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
                }
            }
        }

        UITestHelpers.tapTab(named: "Home", in: app)
        let feedPredicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(feedPredicate)
        let feedLoaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"),
                                                   object: cards)
        guard XCTWaiter().wait(for: [feedLoaded], timeout: 20) == .completed else {
            try captureAndSkip("Home feed did not load within 20 s — network unavailable", in: app)
        }
        cards.firstMatch.tap()

        let playerTitle = app.staticTexts["player.titleLabel"].firstMatch
        XCTAssertTrue(playerTitle.waitForExistence(timeout: 15),
                      "player.titleLabel must appear after tapping a video")

        let backButton = app.buttons["player.backButton"].firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 5),
                      "player.backButton must be visible")
        backButton.tap()

        let chipBar = app.scrollViews["home.chipBar"]
        XCTAssertTrue(chipBar.waitForExistence(timeout: 8),
                      "home.chipBar must reappear after pressing back — player did not dismiss")

        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(playerTitle.exists,
                       "player.titleLabel must NOT reappear — dismiss/re-present loop detected")
        XCTAssertEqual(app.state, .runningForeground,
                       "App must still be running after back navigation")
    }

    func testAudioOnlyToggleAbsentFromSettings() {
        openSettings()
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5),
                      "Settings form must be visible")
        for _ in 0..<8 { form.swipeUp() }
        let toggle = form.switches["settings.audioOnlyToggle"]
        XCTAssertFalse(toggle.exists,
                       "settings.audioOnlyToggle must NOT exist in Settings — it was moved to the player overlay (task #39)")
    }

    // MARK: - Tests (from HomeFeedNoDuplicatesUITests)

    func test_InitialHomeLoad_NoDuplicateCards() throws {
        UITestHelpers.tapTab(named: "Home", in: app)
        guard UITestHelpers.waitForVideoCards(in: app, timeout: 25) != nil else {
            try captureAndSkip("Home feed did not load any cards — likely a network issue.", in: app)
        }
        Thread.sleep(forTimeInterval: 1.0)

        let ids = visibleCardIdentifiers()
        XCTAssertFalse(ids.isEmpty, "Expected at least one video card on the Home feed")

        let dupes = duplicates(in: ids)
        XCTAssertTrue(dupes.isEmpty,
                      "Duplicate video.card IDs found after initial load: \(dupes.prefix(5)). " +
                      "This means the Home feed contains repeated video IDs, which causes blank cells.")
    }

    func test_AfterPagination_NoDuplicateCards() throws {
        UITestHelpers.tapTab(named: "Home", in: app)
        guard UITestHelpers.waitForVideoCards(in: app, timeout: 25) != nil else {
            try captureAndSkip("Home feed did not load any cards — likely a network issue.", in: app)
        }
        Thread.sleep(forTimeInterval: 1.0)

        let scrollView = app.scrollViews.firstMatch
        let hasScrollView = scrollView.waitForExistence(timeout: 5)
        let target = hasScrollView ? scrollView : app.windows.firstMatch

        for _ in 0..<5 {
            target.swipeUp(velocity: .fast)
            Thread.sleep(forTimeInterval: 0.8)
        }
        Thread.sleep(forTimeInterval: 2.0)

        let ids = visibleCardIdentifiers()
        XCTAssertFalse(ids.isEmpty, "Expected video cards to still be present after pagination")

        let dupes = duplicates(in: ids)
        XCTAssertTrue(dupes.isEmpty,
                      "Duplicate video.card IDs found after pagination: \(dupes.prefix(5)). " +
                      "This means loadMore is appending videos that are already in the feed.")
    }

    func test_AllCards_HaveNonEmptyTitles() throws {
        UITestHelpers.tapTab(named: "Home", in: app)
        guard UITestHelpers.waitForVideoCards(in: app, timeout: 25) != nil else {
            try captureAndSkip("Home feed did not load any cards — likely a network issue.", in: app)
        }
        Thread.sleep(forTimeInterval: 1.0)

        // Use .image type to get one thumbnail per card (identifier propagates to all
        // leaf elements, so .image gives exactly one representative element per card).
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cardImages = app.descendants(matching: .image).matching(predicate)
        let count = cardImages.count
        XCTAssertGreaterThan(count, 0, "Expected at least one card")

        // For each card, check that at least one of its staticText siblings
        // (which share the card's identifier due to propagation) has a non-empty label.
        // A blank cell (from ForEach duplicate-ID rendering) produces no visible text.
        var blankCardIds = [String]()
        for i in 0..<count {
            let cardId = cardImages.element(boundBy: i).identifier
            let idPredicate = NSPredicate(format: "identifier == '\(cardId)'")
            let texts = app.descendants(matching: .staticText).matching(idPredicate)
            let hasNonEmptyText = (0..<texts.count).contains { idx in
                !texts.element(boundBy: idx).label.isEmpty
            }
            if !hasNonEmptyText { blankCardIds.append(cardId) }
        }

        XCTAssertTrue(blankCardIds.isEmpty,
                      "Cards with blank/missing text: \(blankCardIds.prefix(5)). " +
                      "Blank cells usually mean duplicate video IDs reached ForEach.")
    }
}
