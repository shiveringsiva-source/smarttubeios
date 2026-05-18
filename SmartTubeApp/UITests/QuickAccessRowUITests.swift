import XCTest

// MARK: - QuickAccessRowUITests
//
// Regression test for GitHub issue #52: quick-access row should appear
// below the progress bar with speed/quality/audio-track/sleep-timer buttons.
//
// TODO: NEEDS REVIEW — all 4 tests currently fail.
//
// What we tried:
// 1. Tap at (0.5, 0.5) to toggle controls visible → playPauseButton found but
//    player.quickAccess.speed / .sleepTimer / player.quickAccessRow NOT found.
// 2. --uitesting-show-controls launch arg (iOS onAppear handler) → same result:
//    playPauseButton found, quick-access elements still absent from the tree.
// 3. [TREE] accessibility dump after titleLabel appears shows ONLY player.backButton.
//    After showControls() tap it shows playPauseButton but none of the quickAccess buttons.
//
// Hypothesis: the quickAccessButtonRow HStack (bottom of PlayerControlsOverlay) may be
// off-screen / clipped in portrait, or the .accessibilityIdentifier on the HStack causes
// the XCTest accessibility tree to flatten/collapse its children. Needs deeper inspection.
// See also: PlayerView+ControlElements.swift → quickAccessButtonRow / quickAccessButton.

final class QuickAccessRowUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-deeplink-video=dQw4w9WgXcQ",
            "--uitesting-disable-sponsorblock"
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    private func waitForPlayer() {
        let title = app.staticTexts["player.titleLabel"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 20),
                      "player.titleLabel did not appear — deep-link did not open player")
        // Dump accessible buttons so we can inspect what's in the tree
        print("[TREE] buttons after titleLabel appears:")
        for b in app.buttons.allElementsBoundByIndex {
            print("[TREE]   btn id='\(b.identifier)' label='\(b.label)'")
        }
    }

    private func showControls() {
        let playPause = app.buttons["player.playPauseButton"].firstMatch
        if playPause.exists { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        if playPause.waitForExistence(timeout: 5) { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        _ = playPause.waitForExistence(timeout: 5)
        print("[TREE] buttons after showControls:")
        for b in app.buttons.allElementsBoundByIndex {
            print("[TREE]   btn id='\(b.identifier)' label='\(b.label)'")
        }
    }

    func testQuickAccessSpeedButtonVisibleInPlayer() throws {
        waitForPlayer()
        showControls()
        XCTAssertTrue(
            app.buttons["player.quickAccess.speed"].waitForExistence(timeout: 3),
            "Quick-access speed button should be visible below the progress bar")
    }

    func testQuickAccessSpeedButtonOpensPicker() throws {
        waitForPlayer()
        showControls()
        let speedBtn = app.buttons["player.quickAccess.speed"]
        XCTAssertTrue(speedBtn.waitForExistence(timeout: 3),
                      "Quick-access speed button must be visible before tapping")
        speedBtn.tap()
        XCTAssertTrue(
            app.otherElements["player.speedPicker"].waitForExistence(timeout: 5),
            "Tapping quick-access speed button should open the speed picker overlay")
    }

    func testQuickAccessRowHasAccessibilityIdentifier() throws {
        waitForPlayer()
        showControls()
        XCTAssertTrue(
            app.otherElements["player.quickAccessRow"].waitForExistence(timeout: 3),
            "Quick-access row should have accessibility identifier 'player.quickAccessRow'")
    }

    func testQuickAccessSleepTimerButtonVisible() throws {
        waitForPlayer()
        showControls()
        XCTAssertTrue(
            app.buttons["player.quickAccess.sleepTimer"].waitForExistence(timeout: 3),
            "Quick-access sleep timer button should be visible")
    }
}
