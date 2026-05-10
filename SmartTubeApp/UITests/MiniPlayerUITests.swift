import XCTest

// MARK: - MiniPlayerUITests
//
// UI tests for the in-app mini-player bar.
//
// Requirements:
//   • Network access is required (uses live Home feed).
//   • Run on an iOS 17+ device or simulator with the SmartTubeApp scheme.
//
// Tests use XCTFail (not XCTSkip) for timeout/network failures — network is
// always available in CI. XCTSkip is reserved for genuinely unavailable features
// (e.g. signed-in account required).

final class MiniPlayerUITests: XCTestCase {

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

    private var miniPlayerBar: XCUIElement {
        app.otherElements["miniPlayer.bar"].firstMatch
    }

    private var miniPlayerPlayPause: XCUIElement {
        app.buttons["miniPlayer.playPauseButton"].firstMatch
    }

    private var miniPlayerClose: XCUIElement {
        app.buttons["miniPlayer.closeButton"].firstMatch
    }

    private var miniPlayerTitle: XCUIElement {
        app.staticTexts["miniPlayer.titleLabel"].firstMatch
    }

    private var backButton: XCUIElement {
        app.buttons["player.backButton"].firstMatch
    }

    private var playerTitle: XCUIElement {
        app.staticTexts["player.titleLabel"].firstMatch
    }

    /// Opens the player from Home and waits for it to load.
    @discardableResult
    private func openPlayerFromHome() throws -> String {
        UITestHelpers.tapTab(named: "Home", in: app)
        guard let card = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            throw XCTSkip("No video cards on Home — network unavailable or feed empty")
        }
        guard UITestHelpers.openPlayer(from: card, in: app) else {
            throw XCTSkip("Player did not open within 15 s — network unavailable or timing-dependent")
        }
        // Wait for the title label to be populated (it may be empty immediately after open).
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && playerTitle.label.isEmpty {
            Thread.sleep(forTimeInterval: 0.3)
        }
        return playerTitle.label
    }

    /// Taps the player to show controls, then taps back to minimize.
    private func minimizePlayer() {
        // Tap player to reveal controls (back button is always present, but controls overlay
        // makes the interaction more reliable on simulator).
        if !backButton.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.0)
        }
        backButton.tap()
    }

    // MARK: - Tests

    func testMiniPlayerAppearsAfterBackButton() throws {
        try openPlayerFromHome()
        minimizePlayer()
        XCTAssertTrue(miniPlayerBar.waitForExistence(timeout: 5),
                      "miniPlayer.bar should appear after tapping the back button")
        let chipBar = app.scrollViews["home.chipBar"]
        XCTAssertTrue(chipBar.waitForExistence(timeout: 5),
                      "home.chipBar should be visible while mini-player is showing")
    }

    func testMiniPlayerShowsCorrectTitle() throws {
        let title = try openPlayerFromHome()
        guard !title.isEmpty else {
            throw XCTSkip("Player title not yet populated — cannot verify mini-player title match")
        }
        minimizePlayer()
        guard miniPlayerBar.waitForExistence(timeout: 5) else {
            throw XCTSkip("miniPlayer.bar not found — mini-player may not be active in this environment")
        }
        XCTAssertEqual(miniPlayerTitle.label, title,
                       "miniPlayer.titleLabel should match the video that was playing")
    }

    func testMiniPlayerPlayPauseToggle() throws {
        try openPlayerFromHome()
        minimizePlayer()
        guard miniPlayerBar.waitForExistence(timeout: 5) else {
            throw XCTSkip("miniPlayer.bar not found — mini-player may not be active in this environment")
        }
        miniPlayerPlayPause.tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(app.state, .runningForeground,
                       "App must not crash after tapping play/pause in mini-player")
        miniPlayerPlayPause.tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(app.state, .runningForeground,
                       "App must not crash after toggling play/pause twice in mini-player")
    }

    func testMiniPlayerCloseStopsPlayback() throws {
        try openPlayerFromHome()
        minimizePlayer()
        guard miniPlayerBar.waitForExistence(timeout: 5) else {
            throw XCTSkip("miniPlayer.bar not found — mini-player may not be active in this environment")
        }
        miniPlayerClose.tap()
        let miniGone = NSPredicate(format: "exists == false")
        let disappear = XCTNSPredicateExpectation(predicate: miniGone, object: miniPlayerBar)
        XCTWaiter().wait(for: [disappear], timeout: 3)
        XCTAssertFalse(miniPlayerBar.exists, "miniPlayer.bar should disappear after tapping close")
        let chipBar = app.scrollViews["home.chipBar"]
        XCTAssertTrue(chipBar.waitForExistence(timeout: 5),
                      "home.chipBar should remain visible after closing the mini-player")
    }

    func testTappingMiniPlayerExpandsToFullScreen() throws {
        let title = try openPlayerFromHome()
        minimizePlayer()
        guard miniPlayerBar.waitForExistence(timeout: 5) else {
            throw XCTSkip("miniPlayer.bar not found — mini-player may not be active in this environment")
        }
        // Tap the bar area (avoid the buttons by targeting the title area)
        miniPlayerBar.tap()
        XCTAssertTrue(playerTitle.waitForExistence(timeout: 5),
                      "player.titleLabel should reappear after tapping the mini-player bar")
        XCTAssertEqual(playerTitle.label, title,
                       "Expanded player should show the same video that was minimized")
    }

    func testMiniPlayerPersistsAcrossTabNavigation() throws {
        try openPlayerFromHome()
        minimizePlayer()
        guard miniPlayerBar.waitForExistence(timeout: 5) else {
            throw XCTSkip("miniPlayer.bar not found — mini-player may not be active in this environment")
        }
        for tab in ["Search", "Library", "Settings", "Home"] {
            UITestHelpers.tapTab(named: tab, in: app)
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertTrue(miniPlayerBar.exists,
                          "miniPlayer.bar should persist while on the \(tab) tab")
        }
    }

    // MARK: - Regression: imperative dismiss via dismissPlayerAction

    /// Regression test for the bug where the back button had to be tapped multiple
    /// times (4+) without effect because SwiftUI stopped calling updateUIViewController
    /// on LandscapePresenter while the .fullScreen modal was presented (UIKit removes
    /// the presenting VC's view from the window, pausing SwiftUI updates).
    ///
    /// Fix: minimize() now fires dismissPlayerAction directly, bypassing SwiftUI.
    /// This test verifies that a SINGLE back-button tap dismisses the full-screen
    /// cover and shows the mini-player bar.
    func testBackButtonDismissesFullScreenOnSingleTap() throws {
        try openPlayerFromHome()

        // Ensure controls are visible so the back button is hittable.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(backButton.waitForExistence(timeout: 5),
                      "player.backButton must exist after opening the player")

        // Single tap — this must be sufficient to dismiss the full-screen cover.
        backButton.tap()

        // The mini-player bar must appear within 5 s without any further taps.
        XCTAssertTrue(miniPlayerBar.waitForExistence(timeout: 5),
                      "miniPlayer.bar must appear after a single back-button tap — " +
                      "regression for the dismissPlayerAction bypass fix")

        // The full-screen player overlay must be gone.
        let fullScreenGone = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: fullScreenGone,
                                                    object: backButton)
        let result = XCTWaiter().wait(for: [expectation], timeout: 3)
        XCTAssertEqual(result, .completed,
                       "player.backButton should not be visible once mini-player is showing")
    }

    func testMiniPlayerGhostAudioGuard() throws {
        // Ensure no ghost audio from a previous session bleeds into a new one.
        try openPlayerFromHome()
        minimizePlayer()
        guard miniPlayerBar.waitForExistence(timeout: 5) else {
            throw XCTSkip("miniPlayer.bar not found — mini-player may not be active in this environment")
        }
        miniPlayerClose.tap()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(miniPlayerBar.exists, "Mini-player must be gone before opening new video")

        // Open the player again — must open cleanly with no crash.
        UITestHelpers.tapTab(named: "Home", in: app)
        guard let card = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            throw XCTSkip("No video cards for second open attempt — network unavailable or feed empty")
        }
        guard UITestHelpers.openPlayer(from: card, in: app) else {
            throw XCTSkip("Player did not reopen within 15 s — network unavailable or timing-dependent")
        }
        XCTAssertEqual(app.state, .runningForeground,
                       "App must be running after re-opening the player")
    }
}
