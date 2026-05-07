import XCTest

// MARK: - ShortsNavigationUITests
//
// Full-app UI tests that launch SmartTube, navigate to the Home tab,
// select the Shorts chip, and assert that the Shorts feed is visible.
//
// Requirements: run on an iOS 17+ simulator with the SmartTube scheme selected.
// The test uses the XCUIApplication API — no live network calls are made;
// the app will show the empty / sign-in state which is sufficient for navigation.

final class ShortsNavigationUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // --uitesting skips animations; --uitesting-enable-shorts ensures the
        // Shorts section is present in enabledSections regardless of user settings.
        app.launchArguments += ["--uitesting", "--uitesting-enable-shorts"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Taps the named tab, supporting both the bottom tab bar (iPhone) and the
    /// iPadOS 18 sidebar where tab items appear as standalone buttons.
    private func tapTab(named label: String, timeout: TimeInterval = 5) {
        let tabBarButton = app.tabBars.buttons[label]
        if tabBarButton.waitForExistence(timeout: min(timeout, 3)) {
            tabBarButton.tap()
            return
        }
        // iPad iOS 18 sidebar: tab items render as buttons outside the tab bar.
        let sidebarButton = app.buttons[label].firstMatch
        XCTAssertTrue(sidebarButton.waitForExistence(timeout: timeout),
                      "'\(label)' navigation item not found in tab bar or sidebar")
        sidebarButton.tap()
    }

    /// Scrolls the chip bar until the Shorts chip is fully visible on screen.
    /// Uses app-level coordinate drags (which reliably scroll the chip bar) with
    /// direction checking so Shorts is never over-scrolled past.
    private func scrollToShortsChip() {
        let chip        = app.buttons["Shorts"]
        let screenWidth = app.windows.firstMatch.frame.width
        let rightEdge   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.09))
        let leftEdge    = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.09))
        for _ in 0..<6 {
            let frame = chip.frame
            guard frame.origin.x < 4 || frame.maxX > screenWidth - 4 else { break }
            if frame.origin.x < 4 {
                // Chip is off-screen to the left — drag left→right to scroll backward.
                leftEdge.press(forDuration: 0.05, thenDragTo: rightEdge)
            } else {
                // Chip is off-screen to the right — drag right→left to scroll forward.
                rightEdge.press(forDuration: 0.05, thenDragTo: leftEdge)
            }
            // Allow the scroll animation and accessibility tree to settle.
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    // MARK: - Tests

    /// Verifies the root window exists immediately after launch.
    func testAppLaunchesSuccessfully() {
        XCTAssertTrue(app.windows.firstMatch.exists, "App window should exist after launch")
    }

    func testNavigateToHomeTab() {
        tapTab(named: "Home")

        // After tapping Home, the chip bar should appear with section chips.
        let shortsChip = app.buttons["Shorts"]
        XCTAssertTrue(shortsChip.waitForExistence(timeout: 5), "Shorts chip should be visible in the Home chip bar")
    }

    func testShortsChipIsReachable() {
        // Navigate to Home tab first.
        tapTab(named: "Home")

        // Tap the Shorts chip in the horizontal chip bar.
        let shortsChip = app.buttons["Shorts"]
        XCTAssertTrue(shortsChip.waitForExistence(timeout: 5), "Shorts chip should exist in the Home chip bar")
        scrollToShortsChip()
        shortsChip.tap()

        // The Shorts chip should now be selected (filled background).
        XCTAssertTrue(
            shortsChip.isSelected,
            "Shorts chip should be selected after tap"
        )
    }

    func testShortsScreenShowsContentOrEmptyState() {
        // Navigate to Home → Shorts.
        tapTab(named: "Home")

        let shortsChip = app.buttons["Shorts"]
        XCTAssertTrue(shortsChip.waitForExistence(timeout: 5))
        scrollToShortsChip()
        shortsChip.tap()

        // Allow time for any loading animation to settle.
        let contentOrEmpty = app.scrollViews.firstMatch.waitForExistence(timeout: 5)
            || app.staticTexts["Nothing here yet"].waitForExistence(timeout: 5)
            || app.staticTexts["Sign in to see your library"].waitForExistence(timeout: 5)

        XCTAssertTrue(contentOrEmpty, "Shorts screen should show content, an empty state, or a sign-in prompt")
    }

    // MARK: - Smoke test

    func testNavigationDoesNotCrash() {
        // A simple smoke test: navigate all the way to Shorts without crashing.
        tapTab(named: "Home")

        let shortsChip = app.buttons["Shorts"]
        guard shortsChip.waitForExistence(timeout: 5) else {
            XCTFail("Shorts chip not found — --uitesting-enable-shorts should guarantee it")
            return
        }
        scrollToShortsChip()
        shortsChip.tap()

        // Pause briefly to let the view settle, then assert no crash occurred.
        _ = app.scrollViews.firstMatch.waitForExistence(timeout: 3)
        XCTAssertTrue(app.windows.firstMatch.exists, "App should still be running after navigating to Shorts")
    }
}

// MARK: - ShortsSwipeUITests
//
// Full-app UI tests that exercise swipe-up / swipe-down gesture navigation
// inside ShortsPlayerView.
//
// Setup: the app is launched with `--uitesting-shorts` which bypasses the full
// navigation stack and presents ShortsPlayerView directly with three stub shorts
// (Short One, Short Two, Short Three). No network calls or sign-in required.
//
// The index label `shorts.indexLabel` shows "N / 3" and is the primary assertion
// target: if the swipe registered, the label changes.

final class ShortsSwipeUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting", "--uitesting-shorts"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Performs initial setup: waits for the shorts player to be on screen.
    /// Returns the window element used for swipe gestures.
    private func openControls() -> XCUIElement {
        // The index label is always visible — wait for it as the ready signal.
        XCTAssertTrue(indexLabel.waitForExistence(timeout: 5), "Index label should appear on launch")
        return app.windows.firstMatch
    }

    private var indexLabel: XCUIElement {
        app.staticTexts["shorts.indexLabel"].firstMatch
    }

    private enum SwipeDirection { case up, down }

    private func swipe(_ direction: SwipeDirection, on element: XCUIElement) {
        switch direction {
        case .up:   element.swipeUp(velocity: .fast)
        case .down: element.swipeDown(velocity: .fast)
        }
    }

    // MARK: - Tests

    /// Shorts player appears on launch and shows "1 / 3".
    func testShortsPlayerAppears() {
        XCTAssertTrue(indexLabel.waitForExistence(timeout: 5), "Index label should be visible on launch")
        XCTAssertEqual(indexLabel.label, "1 / 3", "Should start at the first short")
    }

    /// Swipe up advances from short 1 → 2.
    func testSwipeUpAdvancesToNextShort() {
        let player = openControls()
        XCTAssertTrue(indexLabel.waitForExistence(timeout: 3))
        XCTAssertEqual(indexLabel.label, "1 / 3")

        swipe(.up, on: player)

        XCTAssertTrue(indexLabel.waitForExistence(timeout: 3))
        XCTAssertEqual(indexLabel.label, "2 / 3", "Swipe up should advance to the next short")
    }

    /// Swipe up twice reaches the last short (3 / 3).
    func testSwipeUpTwiceReachesLastShort() {
        let player = openControls()
        XCTAssertTrue(indexLabel.waitForExistence(timeout: 3))

        swipe(.up, on: player)
        _ = indexLabel.waitForExistence(timeout: 3)
        swipe(.up, on: player)
        _ = indexLabel.waitForExistence(timeout: 3)

        XCTAssertEqual(indexLabel.label, "3 / 3", "After two swipes up should be on last short")
    }

    /// Swipe down from short 2 goes back to short 1.
    func testSwipeDownGoesToPreviousShort() {
        let player = openControls()

        swipe(.up, on: player)
        _ = indexLabel.waitForExistence(timeout: 3)
        XCTAssertEqual(indexLabel.label, "2 / 3")

        swipe(.down, on: player)
        _ = indexLabel.waitForExistence(timeout: 3)
        XCTAssertEqual(indexLabel.label, "1 / 3", "Swipe down should go back to the previous short")
    }

    /// Swipe up at the last short does not overflow past "3 / 3".
    func testSwipeUpAtLastShortDoesNotOverflow() {
        let player = openControls()

        swipe(.up, on: player); _ = indexLabel.waitForExistence(timeout: 3)
        swipe(.up, on: player); _ = indexLabel.waitForExistence(timeout: 3)
        XCTAssertEqual(indexLabel.label, "3 / 3")

        swipe(.up, on: player)
        _ = indexLabel.waitForExistence(timeout: 2)

        XCTAssertEqual(indexLabel.label, "3 / 3", "Swipe up at the last short should stay on '3 / 3'")
    }

    /// Swipe down at the first short does not underflow below "1 / 3".
    func testSwipeDownAtFirstShortDoesNotUnderflow() {
        let player = openControls()
        XCTAssertTrue(indexLabel.waitForExistence(timeout: 3))
        XCTAssertEqual(indexLabel.label, "1 / 3")

        swipe(.down, on: player)
        _ = indexLabel.waitForExistence(timeout: 2)

        XCTAssertEqual(indexLabel.label, "1 / 3", "Swipe down at the first short should stay on '1 / 3'")
    }

    /// Full round-trip: advance to last short then swipe back to first.
    func testSwipeUpThenDownRoundTrip() {
        let player = openControls()

        swipe(.up, on: player);   _ = indexLabel.waitForExistence(timeout: 3)
        swipe(.up, on: player);   _ = indexLabel.waitForExistence(timeout: 3)
        XCTAssertEqual(indexLabel.label, "3 / 3", "Should reach the last short")

        swipe(.down, on: player); _ = indexLabel.waitForExistence(timeout: 3)
        swipe(.down, on: player); _ = indexLabel.waitForExistence(timeout: 3)
        XCTAssertEqual(indexLabel.label, "1 / 3", "Should return to the first short")
    }

    // MARK: - Controls-visible swipe tests
    //
    // These tests verify that swipe navigation still works when the controls
    // overlay is displayed on screen.  The overlay is revealed by tapping the
    // player window (which fires SwipeGestureOverlay.onTap → vm.showControls()).
    // The swipe is then performed immediately while the overlay is visible.

    /// Swipe up advances to the next short even when the controls overlay is shown.
    func testSwipeUpWorksWhenControlsAreVisible() {
        let player = openControls()
        XCTAssertTrue(indexLabel.waitForExistence(timeout: 3))
        XCTAssertEqual(indexLabel.label, "1 / 3")

        // Tap to reveal the controls overlay (vm.showControls → controlsVisible = true).
        player.tap()

        // Swipe up immediately while the controls overlay is still on screen.
        swipe(.up, on: player)
        _ = indexLabel.waitForExistence(timeout: 3)

        XCTAssertEqual(indexLabel.label, "2 / 3",
                       "Swipe up should advance to the next short even when controls are visible")
    }

    /// Swipe down returns to the previous short even when the controls overlay is shown.
    func testSwipeDownWorksWhenControlsAreVisible() {
        let player = openControls()

        // Advance to short 2 first (controls not shown).
        swipe(.up, on: player)
        _ = indexLabel.waitForExistence(timeout: 3)
        XCTAssertEqual(indexLabel.label, "2 / 3")

        // Tap to reveal the controls overlay.
        player.tap()

        // Swipe down while controls are visible.
        swipe(.down, on: player)
        _ = indexLabel.waitForExistence(timeout: 3)

        XCTAssertEqual(indexLabel.label, "1 / 3",
                       "Swipe down should return to the previous short even when controls are visible")
    }
}

// MARK: - ShortsLiveSwipeUITests
//
// End-to-end UI tests that use NO mocks and NO launch argument bypass.
// The app launches normally, navigates to Home → Shorts chip, waits for real
// content to load over the network, taps the first Short card to open
// ShortsPlayerView, then exercises swipe-up and swipe-down navigation.
//
// Requirements:
//   • The simulator must have network access so InnerTube can return Shorts.
//   • The test allows up to 20 s for the feed to populate.
//   • Swiping is performed via coordinate-based drag on the window so the
//     UIKit-level UIPanGestureRecognizer in SwipeGestureOverlay fires correctly.

final class ShortsLiveSwipeUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // --uitesting-enable-shorts ensures the Shorts chip is visible.
        app.launchArguments += ["--uitesting-enable-shorts"]
        app.launch()   // No --uitesting-shorts; full real navigation
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Taps the named tab, supporting both the bottom tab bar (iPhone) and the
    /// iPadOS 18 sidebar where tab items appear as standalone buttons.
    private func tapTab(named label: String, timeout: TimeInterval = 5) {
        let tabBarButton = app.tabBars.buttons[label]
        if tabBarButton.waitForExistence(timeout: min(timeout, 3)) {
            tabBarButton.tap()
            return
        }
        let sidebarButton = app.buttons[label].firstMatch
        XCTAssertTrue(sidebarButton.waitForExistence(timeout: timeout),
                      "'\(label)' navigation item not found in tab bar or sidebar")
        sidebarButton.tap()
    }

    /// Scrolls the chip bar left until the Shorts chip is in view then taps it.
    /// Throws XCTSkip if the Shorts chip is not present (section disabled in settings).
    private func navigateToShortsChip() throws {
        tapTab(named: "Home")

        let shortsChip = app.buttons["Shorts"]
        guard shortsChip.waitForExistence(timeout: 5) else {
            throw XCTSkip("Shorts chip not visible — --uitesting-enable-shorts may not have applied in time")
        }

        // Scroll chip bar until Shorts is fully on-screen, then tap.
        let rightEdge   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.09))
        let leftEdge    = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.09))
        let screenWidth = app.windows.firstMatch.frame.width
        for _ in 0..<6 {
            let frame = shortsChip.frame
            guard frame.origin.x < 4 || frame.maxX > screenWidth - 4 else { break }
            if frame.origin.x < 4 {
                leftEdge.press(forDuration: 0.05, thenDragTo: rightEdge)
            } else {
                rightEdge.press(forDuration: 0.05, thenDragTo: leftEdge)
            }
            Thread.sleep(forTimeInterval: 0.3)
        }

        shortsChip.tap()

        // Wait for the Shorts section feed before querying cards — prevents
        // the predicate matching stale Home-feed cards still in the tree.
        let sectionFeed = app.scrollViews["home.sectionFeed"]
        guard sectionFeed.waitForExistence(timeout: 20) else { return }
    }

    /// Waits up to `timeout` seconds for any `video.card.*` element to appear
    /// inside the Shorts section feed and returns the first one.
    private func waitForFirstVideoCard(timeout: TimeInterval = 10) -> XCUIElement? {
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"), object: cards)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        guard result == .completed else { return nil }
        return cards.firstMatch
    }

    /// Performs a swipe by dragging from bottom-centre to top-centre of the screen.
    private func swipeUp() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let end   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Performs a swipe by dragging from top-centre to bottom-centre of the screen.
    private func swipeDown() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private var indexLabel: XCUIElement {
        app.staticTexts["shorts.indexLabel"].firstMatch
    }

    // MARK: - Tests

    /// Full end-to-end: navigate to Shorts with real network, open a video,
    /// swipe up to next, swipe down back to previous.
    func testLiveShortSwipeUpThenDown() throws {
        try navigateToShortsChip()

        // Wait for real Shorts to load from the network.
        guard let firstCard = waitForFirstVideoCard(timeout: 20) else {
            throw XCTSkip("No Shorts loaded within 20 s — network unavailable or feed empty")
        }

        // Tap the first Short to open ShortsPlayerView.
        firstCard.tap()

        // Index label must appear (always-visible badge added for testability).
        XCTAssertTrue(indexLabel.waitForExistence(timeout: 10), "Shorts player index label should appear")
        let initialLabel = indexLabel.label   // e.g. "1 / N"

        // Swipe up → should advance to the next short.
        swipeUp()
        sleep(1)  // allow animation to settle
        let afterSwipeUp = indexLabel.label
        XCTAssertNotEqual(afterSwipeUp, initialLabel, "Swipe up should advance to the next short")

        // Swipe down → should go back to the previous short.
        swipeDown()
        sleep(1)
        let afterSwipeDown = indexLabel.label
        XCTAssertEqual(afterSwipeDown, initialLabel, "Swipe down should return to the original short")
    }

    /// Confirms swipe-up on the last short in the list does not crash or wrap.
    func testLiveShortsSwipeUpBoundary() throws {
        try navigateToShortsChip()

        guard let firstCard = waitForFirstVideoCard(timeout: 20) else {
            throw XCTSkip("No Shorts loaded within 20 s — network unavailable or feed empty")
        }
        firstCard.tap()

        XCTAssertTrue(indexLabel.waitForExistence(timeout: 5))

        // Swipe up repeatedly until the label stops changing (we're at the end).
        var previous = ""
        var current = indexLabel.label
        var attempts = 0
        while current != previous && attempts < 50 {
            previous = current
            swipeUp()
            sleep(1)
            current = indexLabel.label
            attempts += 1
        }

        // One extra swipe — label must not change (boundary clamped).
        swipeUp()
        sleep(1)
        XCTAssertEqual(indexLabel.label, current, "Swipe up past the last short should stay on the last item")
    }
}
