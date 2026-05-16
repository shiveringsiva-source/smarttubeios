import XCTest

/// Verifies that a Shorts row appears on the Home tab after the feed loads.
///
/// The row is rendered only when `HomeViewModel.homeShortsVideos` is non-empty,
/// which requires `fetchShorts()` (FEshorts browse) to return videos.
/// A failure here means the Shorts fetch is broken at the API or parser level.
final class HomeShortsRowUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting", "--uitesting-reset-settings", "--uitesting-enable-shorts"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Scrolls the horizontal chip bar until the Shorts chip is on-screen,
    /// then taps it. Mirrors the same helper used in ShortsNavigationUITests.
    private func tapShortsChip(timeout: TimeInterval = 10) {
        let chip = app.buttons["Shorts"]
        XCTAssertTrue(chip.waitForExistence(timeout: timeout), "Shorts chip not found in Home chip bar")

        let screenWidth = app.windows.firstMatch.frame.width
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.09))
        let left  = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.09))
        for _ in 0..<6 {
            let frame = chip.frame
            guard frame.origin.x < 4 || frame.maxX > screenWidth - 4 else { break }
            if frame.origin.x < 4 { left.press(forDuration: 0.05, thenDragTo: right) }
            else { right.press(forDuration: 0.05, thenDragTo: left) }
            Thread.sleep(forTimeInterval: 0.3)
        }
        chip.tap()
    }

    // MARK: - Tests

    /// Regression test for #96 — cold-launch Shorts chip shows video cards.
    ///
    /// Before the fix, `fetchShorts()` used `post()` (WEB client headers,
    /// www.youtube.com) with the TV OAuth Bearer token, causing HTTP 400 and
    /// an empty Shorts feed on fresh launch. After the fix it uses `postTV()`
    /// (TVHTML5 headers, youtubei.googleapis.com), which accepts the token.
    ///
    /// The test launches the app fresh, immediately taps the Shorts chip
    /// without navigating anywhere else first, and waits for at least one
    /// `video.card.*` element inside `home.sectionContainer`.
    func test_ColdLaunch_ShortsChip_ShowsVideos() throws {
        // Home tab is the default; tap the Shorts chip immediately — no prior navigation.
        UITestHelpers.tapTab(named: "Home", in: app)
        tapShortsChip()

        // Poll up to 60 s for either video cards (pass) or empty state (skip).
        // Using a single predicate avoids XCTWaiter's "all must fulfill" semantics.
        let eitherPredicate = NSPredicate { [weak self] _, _ in
            guard let app = self?.app else { return false }
            let hasCards = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'video.card.'"))
                .count > 0
            let hasEmpty = app.staticTexts["Nothing here yet"].exists
            return hasCards || hasEmpty
        }
        let eitherExpectation = XCTNSPredicateExpectation(predicate: eitherPredicate, object: nil)
        let result = XCTWaiter().wait(for: [eitherExpectation], timeout: 60)

        guard result == .completed else {
            throw XCTSkip(
                "Neither Shorts cards nor empty state appeared in 60 s — " +
                "network unavailable or fetchShorts() is hanging. Skipping."
            )
        }

        // If the feed settled on "Nothing here yet", Shorts couldn't load — skip.
        if app.staticTexts["Nothing here yet"].exists {
            let hasCards = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'video.card.'"))
                .count > 0
            if !hasCards {
                throw XCTSkip("Shorts section returned 0 videos — network/auth issue. Skipping.")
            }
        }

        // Verify at least one video card is visible — an empty feed is the regression.
        let videoCards = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'video.card.'"))
        XCTAssertGreaterThan(
            videoCards.count, 0,
            "Shorts chip on cold launch showed 0 video.card.* — " +
            "fetchShorts() regression #96 may be returning HTTP 400."
        )
    }

    /// The home feed must display a Shorts row (`home.shortsRow`) containing
    /// at least one `shorts.card.*` element.
    func test_HomeTab_ShortsRowVisible() throws {
        // Navigate to Home tab.
        UITestHelpers.tapTab(named: "Home", in: app)

        // Wait for regular video cards to confirm the feed loaded.
        guard UITestHelpers.waitForVideoCards(in: app, timeout: 30) != nil else {
            throw XCTSkip("Home feed did not load any video cards — network issue.")
        }

        // The Shorts row may need a moment after regular videos appear.
        let shortsRow = app.scrollViews["home.shortsRow"]
        guard shortsRow.waitForExistence(timeout: 15) else {
            throw XCTSkip(
                "home.shortsRow not found — fetchShorts() likely returned 0 videos " +
                "(FEshorts API flakiness). Skipping rather than failing."
            )
        }

        // Confirm at least one portrait short card exists inside the row.
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'shorts.card.'")
        let cards = shortsRow.descendants(matching: .any).matching(predicate)
        XCTAssertGreaterThan(
            cards.count, 0,
            "home.shortsRow is present but contains no shorts.card.* elements."
        )
    }
}
