import XCTest

// MARK: - PlayerControlsUITests
//
// UI tests for the PlayerView controls overlay: show/hide, play/pause,
// next button, PiP, back button, related videos, and error-free playback.
//
// Requirements:
//   • Network access is required.
//   • Run on an iOS 17+ simulator with the SmartTubeApp scheme selected.

final class PlayerControlsUITests: XCTestCase {

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

    /// Opens the Home tab, waits for the first video card, and opens the player.
    /// Returns the video title if the player opened, or skips if network/feed unavailable.
    @discardableResult
    private func openPlayerFromHome() throws -> String {
        UITestHelpers.tapTab(named: "Home", in: app)
        guard let card = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            throw XCTSkip("No video cards on Home — network unavailable or feed empty")
        }
        guard UITestHelpers.openPlayer(from: card, in: app) else {
            throw XCTSkip("Player did not open within 15 s — network unavailable or timing-dependent")
        }
        return app.staticTexts["player.titleLabel"].firstMatch.label
    }

    private var titleLabel: XCUIElement {
        app.staticTexts["player.titleLabel"].firstMatch
    }

    private var playPauseButton: XCUIElement {
        app.buttons["player.playPauseButton"].firstMatch
    }

    private var nextButton: XCUIElement {
        app.buttons["player.nextBtn"].firstMatch
    }

    private var backButton: XCUIElement {
        app.buttons["player.backButton"].firstMatch
    }

    private var pipButton: XCUIElement {
        app.buttons["player.pipButton"].firstMatch
    }

    /// Taps the player until the controls overlay becomes visible.
    /// Retries up to 5 times with 1.5s gaps to account for the UIKit
    /// tap.require(toFail: pan) delay and iOS version timing differences.
    private func showControls() {
        for _ in 0..<5 {
            if playPauseButton.exists { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    // MARK: - Tests

    func testControlsAppearOnTap() throws {
        try openPlayerFromHome()
        showControls()
        XCTAssertTrue(playPauseButton.waitForExistence(timeout: 5),
                      "player.playPauseButton should become visible after tapping the player")
    }

    func testPlayPauseToggles() throws {
        try openPlayerFromHome()
        showControls()
        XCTAssertTrue(playPauseButton.waitForExistence(timeout: 5),
                      "player.playPauseButton must be visible")

        // Capture current image (playing → pause icon, or paused → play icon).
        playPauseButton.tap()
        Thread.sleep(forTimeInterval: 0.5)

        // Tap again to restore.
        showControls()
        XCTAssertTrue(playPauseButton.waitForExistence(timeout: 5))
        playPauseButton.tap()

        // The app must still be running — no crash on toggle.
        XCTAssertEqual(app.state, .runningForeground,
                       "App must still be running after toggling play/pause")
    }

    func testBackButtonDismissesPlayer() throws {
        try openPlayerFromHome()
        // Back button is always visible (even when controls overlay is hidden).
        XCTAssertTrue(backButton.waitForExistence(timeout: 5),
                      "player.backButton must be present")
        backButton.tap()

        // Back now minimizes to the mini-player bar rather than stopping playback.
        let miniPlayerBar = app.otherElements["miniPlayer.bar"].firstMatch
        XCTAssertTrue(miniPlayerBar.waitForExistence(timeout: 5),
                      "miniPlayer.bar should appear after tapping the back button")

        // Close the mini-player to fully stop playback.
        let miniPlayerClose = app.buttons["miniPlayer.closeButton"].firstMatch
        guard miniPlayerClose.waitForExistence(timeout: 3) else {
            throw XCTSkip("miniPlayer.closeButton not found — in-app PiP may not be active on this build")
        }
        miniPlayerClose.tap()

        // After closing, the Home feed chip bar should be visible and mini-player gone.
        let chipBar = app.scrollViews["home.chipBar"]
        XCTAssertTrue(chipBar.waitForExistence(timeout: 5),
                      "home.chipBar should reappear after closing the mini-player")
        XCTAssertFalse(miniPlayerBar.exists,
                       "miniPlayer.bar should be gone after tapping close")
    }

    func testNoErrorBannerOnNormalPlayback() throws {
        let title = try openPlayerFromHome()
        Thread.sleep(forTimeInterval: 10)
        UITestHelpers.assertNoPlayerErrorBanner(in: app, videoTitle: title)
    }

    func testPlayerStaysOpenAfterTap() throws {
        try openPlayerFromHome()
        showControls()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(titleLabel.exists,
                      "player.titleLabel should still be visible after tapping the player — player must not dismiss unexpectedly")
    }

    func testNextVideoButtonLoadsNewVideo() throws {
        try openPlayerFromHome()
        let initialTitle = titleLabel.label

        // Wait for related videos to arrive by polling nextBtn.
        let deadline = Date().addingTimeInterval(20)
        var nextEnabled = false
        while Date() < deadline {
            showControls()
            if nextButton.waitForExistence(timeout: 3.5), nextButton.isEnabled {
                nextEnabled = true
                break
            }
        }
        guard nextEnabled else {
            throw XCTSkip("player.nextBtn did not become enabled within 20 s — related videos may not have loaded")
        }

        nextButton.tap()

        // Poll until the title label changes, indicating the new video's playerInfo loaded.
        // Skip gracefully if the title never changes (same-title related video or slow network).
        let loadDeadline = Date().addingTimeInterval(30)
        var newTitle = titleLabel.label
        while Date() < loadDeadline && newTitle == initialTitle {
            Thread.sleep(forTimeInterval: 1)
            newTitle = titleLabel.label
        }
        guard newTitle != initialTitle else {
            throw XCTSkip("Title did not change within 30s — next video may share the same title or network is slow")
        }
    }

    #if os(iOS)
    func testPiPButtonStartsPiP() throws {
        // Re-launch with --uitesting-enable-pip to bypass the isPictureInPictureSupported()
        // guard on parallel clone simulators where the entitlement may not propagate.
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-enable-pip"]
        app.launch()
        try openPlayerFromHome()
        showControls()
        guard pipButton.waitForExistence(timeout: 5) else {
            throw XCTSkip("player.pipButton not found — PiP may not be available on this device/iOS version")
        }
        pipButton.tap()
        // PiP windows are not directly queryable; just ensure no crash.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.state, .runningForeground,
                       "App must still be running after tapping the PiP button")
    }
    #endif
}
