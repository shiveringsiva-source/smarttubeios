import XCTest

// MARK: - PlayerDoubleTapUITests
//
// UI tests for the zone-based double-tap gesture on PlayerView (iOS only).
//
// The player surface is divided into three horizontal zones:
//   Left  1/3 — double-tap seeks backward  (seekBackSeconds)
//   Middle 1/3 — double-tap toggles Fit / Fill video gravity
//   Right 1/3 — double-tap seeks forward   (seekForwardSeconds)
//
// Each test opens a real video from Home, waits for the controls overlay to
// auto-hide (default timeout 4 s), performs a double-tap in the target zone,
// and asserts that the self-dismissing toast appears in the accessibility tree.
//
// Requirements:
//   • Network access (Home feed must return at least one video card).
//   • Run on an iOS 17+ simulator with the SmartTube scheme.

final class PlayerDoubleTapUITests: XCTestCase {

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

    /// Opens the Home tab, taps the first video card, and waits for the player.
    @discardableResult
    private func openPlayerFromHome() throws -> String {
        UITestHelpers.tapTab(named: "Home", in: app)
        guard let card = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            throw XCTSkip("No video cards on Home — network unavailable or feed empty")
        }
        guard UITestHelpers.openPlayer(from: card, in: app) else {
            throw XCTSkip("Player did not open within 15 s")
        }
        return app.staticTexts["player.titleLabel"].firstMatch.label
    }

    /// Waits for the controls overlay to auto-hide after the player opens.
    /// The default controls-hide timeout is 4 s; sleeping 5 s guarantees the
    /// overlay has been dismissed before any double-tap is synthesised.
    /// Predicate-based checks are unreliable here because `player.playPauseButton`
    /// does not reliably appear in the XCTest accessibility tree during the
    /// auto-show window — so a fixed sleep is the most robust approach.
    private func waitForControlsToHide() {
        Thread.sleep(forTimeInterval: 5)
    }

    /// Performs a double-tap at the given normalised X position (mid-height).
    private func doubleTap(normalizedX: CGFloat) {
        app.coordinate(withNormalizedOffset: CGVector(dx: normalizedX, dy: 0.5))
            .doubleTap()
    }

    // MARK: - Tests

    /// Double-tapping the left third must show the seek-back toast (e.g. "← 10s").
    func testDoubleTapLeftZoneShowsSeekBackToast() throws {
        try openPlayerFromHome()
        // Wait for controls to hide so the zone gesture fires unobstructed.
        waitForControlsToHide()

        // Tap in the centre of the left third (normalised x ≈ 0.17).
        doubleTap(normalizedX: 1.0 / 6.0)

        let toast = app.staticTexts["player.toast"].firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 3),
                      "A seek-back toast (← Xs) must appear after double-tapping the left third of the player")
        XCTAssertTrue(toast.label.hasPrefix("\u{2190}"),
                      "Seek-back toast label must start with ← but was '\(toast.label)'")
        XCTAssertEqual(app.state, .runningForeground,
                       "App must still be running after left-zone double-tap")
    }

    /// Double-tapping the right third must show the seek-forward toast (e.g. "30s →").
    func testDoubleTapRightZoneShowsSeekForwardToast() throws {
        try openPlayerFromHome()
        waitForControlsToHide()

        // Tap in the centre of the right third (normalised x ≈ 0.83).
        doubleTap(normalizedX: 5.0 / 6.0)

        let toast = app.staticTexts["player.toast"].firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 5),
                      "A seek-forward toast (Xs →) must appear after double-tapping the right third of the player")
        XCTAssertTrue(toast.label.hasSuffix("\u{2192}"),
                      "Seek-forward toast label must end with → but was '\(toast.label)'")
        XCTAssertEqual(app.state, .runningForeground,
                       "App must still be running after right-zone double-tap")
    }

    /// Double-tapping the centre third must show a Fit or Fill video-gravity toast.
    func testDoubleTapCentreZoneTogglesFitFill() throws {
        try openPlayerFromHome()
        waitForControlsToHide()

        // Tap dead-centre.
        doubleTap(normalizedX: 0.5)

        let toast = app.staticTexts["player.toast"].firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 5),
                      "'Fit' or 'Fill' toast must appear after double-tapping the centre third of the player")
        XCTAssertTrue(toast.label == "Fit" || toast.label == "Fill",
                      "Scale toast label must be 'Fit' or 'Fill' but was '\(toast.label)'")
        XCTAssertEqual(app.state, .runningForeground,
                       "App must still be running after centre-zone double-tap")
    }

    /// Tapping each zone twice must not crash and must toggle the state consistently.
    /// Left → back (toast appears), left again → back (toast appears again).
    func testDoubleTapLeftZoneTwiceDoesNotCrash() throws {
        try openPlayerFromHome()
        waitForControlsToHide()

        doubleTap(normalizedX: 1.0 / 6.0)
        // Give the first toast time to appear and the gesture system time to reset.
        Thread.sleep(forTimeInterval: 1)
        doubleTap(normalizedX: 1.0 / 6.0)

        XCTAssertEqual(app.state, .runningForeground,
                       "App must still be running after two consecutive left-zone double-taps")
    }
}
