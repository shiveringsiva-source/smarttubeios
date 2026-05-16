import XCTest

// MARK: - PlayerControlsUITests
//
// All tests except testPiPButtonStartsPiP have moved to PlayerAndMiniPlayerUITests.swift
// (combined with MiniPlayerUITests for a single shared app launch).
//
// testPiPButtonStartsPiP is kept here because it deliberately terminates and
// re-launches the app with --uitesting-enable-pip and cannot share state.

final class PlayerControlsUITests: XCTestCase {

    private var app: XCUIApplication!

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

    @discardableResult
    private func openPlayerFromHome() throws -> String {
        UITestHelpers.tapTab(named: "Home", in: app)
        guard let card = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No video cards on Home — network unavailable or feed empty", in: app)
        }
        guard UITestHelpers.openPlayer(from: card, in: app) else {
            try captureAndSkip("Player did not open within 15 s — network unavailable or timing-dependent", in: app)
        }
        return app.staticTexts["player.titleLabel"].firstMatch.label
    }

    private var playPauseButton: XCUIElement {
        app.buttons["player.playPauseButton"].firstMatch
    }

    private var pipButton: XCUIElement {
        app.buttons["player.pipButton"].firstMatch
    }

    private func showControls() {
        for _ in 0..<5 {
            if playPauseButton.exists { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    // MARK: - Tests

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
            try captureAndSkip("player.pipButton not found — PiP may not be available on this device/iOS version", in: app)
        }
        pipButton.tap()
        // PiP windows are not directly queryable; just ensure no crash.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.state, .runningForeground,
                       "App must still be running after tapping the PiP button")
    }
    #endif
}
