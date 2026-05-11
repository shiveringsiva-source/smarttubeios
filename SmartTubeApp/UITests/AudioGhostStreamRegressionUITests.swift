import XCTest

// MARK: - AudioGhostStreamRegressionUITests
//
// Regression tests for the audio-duplication / ghost-stream bug.
//
// Root causes fixed (May 2026):
//   1. MPRemoteCommandCenter – `addTarget` was never balanced with `removeTarget`.
//      Ghost VMs responded to lock screen "Play", re-starting audio alongside the
//      active player.  Fix: `suspend()` and `stop()` now call `removeAllTargets()`;
//      `resume()` and `loadAsync()` re-register via `setupRemoteCommandCenter()`.
//
//   2. ShortsPlayerView – had no `scenePhase` observer, so `handleBackground()` /
//      `handleForeground()` were never called; locking the phone left audio in an
//      undefined state for Shorts.  Fix: `.onChange(of: scenePhase)` added.
//
//   3. ShortsPlayerView.onAppear – unconditionally called `loadVideo(at:)`, causing
//      a full reload (and transient double-audio) on every spurious appear (e.g. after
//      navigating to a channel and coming back).  Fix: idempotency guard matching
//      PlayerView's pattern.
//
//   4. audioSessionObserver – never removed, so stopped VMs responded to
//      interruption-ended notifications and could restart their player.
//      Fix: observer removed in `stop()` and `deinit`.
//
// Requirements:
//   • Network access is required for most tests.
//   • Run on an iOS 17+ simulator with the SmartTubeApp scheme selected.
//   • Launch args: --uitesting  (disables animations; adds --uitesting-enable-shorts
//     where Shorts access is required).

// MARK: - Suite 1: PlayerView — sequential video loads (ghost stream root cause 1 & 4)

final class PlayerGhostStreamRegressionUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws { app = nil }

    // MARK: - Helpers

    private var backButton: XCUIElement {
        app.buttons["player.backButton"].firstMatch
    }

    private var titleLabel: XCUIElement {
        app.staticTexts["player.titleLabel"].firstMatch
    }

    /// Opens the player from the first Home video card.
    /// Calls XCTFail if the network is unavailable or the player does not open.
    @discardableResult
    private func openPlayerFromHome() throws -> String {
        UITestHelpers.tapTab(named: "Home", in: app)
        guard let card = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            XCTFail("No video cards on Home — network unavailable or feed empty")
            return ""
        }
        guard UITestHelpers.openPlayer(from: card, in: app) else {
            XCTFail("Player did not open within 15 s")
            return ""
        }
        return titleLabel.label
    }

    // MARK: - Tests

    /// Opening two different videos back-to-back must not produce an error banner on
    /// the second video.  Before the fix, the first VM's MPRemoteCommandCenter handler
    /// (and audioSessionObserver) could re-activate the first player's AVAudioSession
    /// while the second video was loading, causing an audio conflict or state corruption
    /// that surfaced as an error banner.
    func testOpenSecondVideoAfterFirstNoErrorBanner() throws {
        let firstTitle = try openPlayerFromHome()
        XCTAssertTrue(backButton.waitForExistence(timeout: 5),
                      "player.backButton must appear after opening first video")
        backButton.tap()

        // Navigate back to Home and open a second video card.
        UITestHelpers.tapTab(named: "Home", in: app)
        let cards = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'video.card.'"))
        // Tap a different card by picking the second one, or fall back to the first.
        let secondCard: XCUIElement = {
            if cards.count > 1 { return cards.element(boundBy: 1) }
            return cards.firstMatch
        }()
        guard UITestHelpers.openPlayer(from: secondCard, in: app) else {
            XCTFail("Second player did not open within 15 s")
            return
        }

        // Allow a few seconds for any ghost-stream audio conflict to manifest.
        Thread.sleep(forTimeInterval: 5)

        UITestHelpers.assertNoPlayerErrorBanner(in: app, videoTitle: firstTitle)
        XCTAssertEqual(app.state, .runningForeground,
                       "App must still be running after opening two sequential videos")
    }

    /// Opening two videos back-to-back must not produce an error on the second video,
    /// even when the first video's `playerLog` emits a ghost-resume log line.
    /// This variant uses the next-video button to switch without returning to Home —
    /// the path where `load(video:)` is called directly (skipping `stop()`).
    func testNextVideoButtonNoGhostAudio() throws {
        try openPlayerFromHome()

        // Wait for related videos so the next button is enabled.
        let nextButton = app.buttons["player.nextBtn"].firstMatch
        let deadline = Date().addingTimeInterval(20)
        var nextEnabled = false
        while Date() < deadline {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.0)
            if nextButton.waitForExistence(timeout: 3), nextButton.isEnabled {
                nextEnabled = true; break
            }
        }
        guard nextEnabled else {
            XCTFail("player.nextBtn did not become enabled within 20 s")
            return
        }
        nextButton.tap()

        // Wait for the second video to start loading.
        let secondTitle = app.staticTexts["player.titleLabel"].firstMatch
        guard secondTitle.waitForExistence(timeout: 15) else {
            XCTFail("Second video title did not appear after tapping next")
            return
        }

        Thread.sleep(forTimeInterval: 5)
        UITestHelpers.assertNoPlayerErrorBanner(in: app)
        XCTAssertEqual(app.state, .runningForeground,
                       "App must still be running after next-video navigation")
    }

    /// After opening a video and returning to Home via the back button, the app must
    /// remain in the foreground with no stale audio (crash-free is the testable proxy).
    func testBackFromPlayerNoResidualState() throws {
        try openPlayerFromHome()
        Thread.sleep(forTimeInterval: 3)

        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        backButton.tap()

        // Home chip bar should be visible — player fully dismissed.
        let chipBar = app.scrollViews["home.chipBar"]
        XCTAssertTrue(chipBar.waitForExistence(timeout: 5),
                      "home.chipBar should reappear after dismissing the player")
        XCTAssertEqual(app.state, .runningForeground,
                       "App must still be running after dismissing the player")
    }
}

// MARK: - Suite 2: ShortsPlayerView — spurious onAppear & scenePhase (root cause 2 & 3)

final class ShortsGhostStreamRegressionUITests: XCTestCase {

    /// Real YouTube Short IDs used for direct-launch testing.
    /// Tried in order; the first set launches the Shorts player without navigating
    /// through the home feed, avoiding auth dependency on parallel clone simulators.
    private static let shortIDs = ["MCv4EyEFgVg", "pPvd8UxmCGY", "fKopy74weus"]

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Do NOT launch here — openFirstShort() launches with the Shorts deeplink.
        app = XCUIApplication()
    }

    override func tearDownWithError() throws { app = nil }

    // MARK: - Helpers

    private var indexLabel: XCUIElement {
        app.staticTexts["shorts.indexLabel"].firstMatch
    }

    /// Launches the Shorts player directly with real Short IDs, bypassing home feed navigation.
    /// Uses `--uitesting-shorts-ids` so the player opens without requiring a signed-in account
    /// on parallel clone simulators.
    private func openFirstShort() throws {
        let ids = Self.shortIDs.joined(separator: ",")
        app.launchArguments = [
            "--uitesting",
            "--uitesting-shorts",
            "--uitesting-shorts-ids=\(ids)",
        ]
        app.launch()

        guard indexLabel.waitForExistence(timeout: 20) else {
            throw XCTSkip("Shorts player did not appear — network unavailable or short IDs may be stale")
        }
    }

    /// Taps the player until `shorts.controlsOverlay` is visible.
    private func showControls() {
        let pred = NSPredicate(format: "identifier == 'shorts.controlsOverlay'")
        let overlay = app.descendants(matching: .any).matching(pred).firstMatch
        for _ in 0..<5 {
            if overlay.exists { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    // MARK: - Tests

    /// Regression for root cause 3 (spurious onAppear).
    ///
    /// Before the fix, returning from ChannelView (a `navigationDestination` pushed
    /// inside ShortsPlayerView's NavigationStack) triggered `onAppear` on
    /// ShortsPlayerView, which unconditionally called `loadVideo(at:)` → `vm.load()`.
    /// This restarted the AVPlayerItem, producing a brief moment of overlapping audio.
    ///
    /// After the fix the idempotency guard keeps `currentIndex` and the loaded video
    /// unchanged, so the index label should show the same value before and after.
    func testIndexUnchangedAfterChannelNavAndBack() throws {
        try openFirstShort()
        let indexBefore = indexLabel.label

        // Show the overlay so the channel button is on screen.
        showControls()

        // Tap the channel button (added identifier `shorts.channelButton`).
        let channelPred = NSPredicate(format: "identifier == 'shorts.channelButton'")
        let channelButton = app.descendants(matching: .any).matching(channelPred).firstMatch

        guard channelButton.waitForExistence(timeout: 5), channelButton.isEnabled else {
            throw XCTSkip("shorts.channelButton not found or disabled — channelId unavailable for this Short")
        }
        channelButton.tap()

        // Wait for ChannelView to push (navigation bar title changes).
        let navBarPred = NSPredicate(format: "identifier CONTAINS 'Channel'")
        let channelNavBar = app.navigationBars.matching(navBarPred).firstMatch
        guard channelNavBar.waitForExistence(timeout: 15) else {
            XCTFail("ChannelView did not appear within 15 s")
            return
        }

        // Navigate back via the system back button / swipe.
        let backBtn = app.navigationBars.buttons.firstMatch
        if backBtn.exists {
            backBtn.tap()
        } else {
            app.swipeRight()
        }

        // ShortsPlayerView should be back; index must be unchanged.
        XCTAssertTrue(indexLabel.waitForExistence(timeout: 5),
                      "shorts.indexLabel must reappear after returning from ChannelView")
        XCTAssertEqual(indexLabel.label, indexBefore,
                       "Index label must not change after returning from ChannelView — spurious onAppear must not restart the video")
    }

    /// Regression for root cause 3 — simpler variant that doesn't require a live
    /// channelId.  A sheet appearing and disappearing on top of ShortsPlayerView
    /// (here: the controls overlay itself being shown) must not reset the index.
    func testIndexStableAfterShowingAndHidingControls() throws {
        try openFirstShort()
        let indexBefore = indexLabel.label

        // Toggle controls on then wait for them to auto-hide.
        showControls()
        Thread.sleep(forTimeInterval: 5) // controls auto-hide after ~4 s

        XCTAssertTrue(indexLabel.waitForExistence(timeout: 5),
                      "shorts.indexLabel must remain after controls auto-hide")
        XCTAssertEqual(indexLabel.label, indexBefore,
                       "Index must not change after showing/hiding controls overlay")
    }

    /// Regression for root cause 2 (missing scenePhase handler).
    ///
    /// Before the fix, backgrounding (locking) the device while watching a Short
    /// left `handleBackground()` uncalled, so `backgroundPlaybackEnabled = false`
    /// had no effect and audio might continue or resume unexpectedly on unlock.
    ///
    /// The test backgrounds the app via the Home button, waits briefly, then
    /// reactivates the app and verifies the player is still present without errors.
    /// This is the observable proxy for the underlying scenePhase fix.
    ///
    /// Note: `XCUIDevice.shared.press(.home)` is only available on iOS simulators.
    func testShortsPlayerStableAfterBackground() throws {
        try openFirstShort()
        let indexBefore = indexLabel.label

        // Background the app (simulates lock / home button).
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)

        // Re-activate the app.
        app.activate()
        Thread.sleep(forTimeInterval: 1)

        // Player must still be visible and on the same Short.
        XCTAssertTrue(indexLabel.waitForExistence(timeout: 5),
                      "shorts.indexLabel must still be visible after returning from background")
        XCTAssertEqual(indexLabel.label, indexBefore,
                       "Index must not change when returning from background — no spurious reload")
        XCTAssertEqual(app.state, .runningForeground,
                       "App must be running in the foreground after reactivation")
    }

    /// Opening two shorts sequentially (swipe-up then swipe-down) must leave the
    /// player error-free.  This exercises both the `load()` call from `goTo()` and
    /// the scenePhase machinery that keeps `isPlaying` in sync.
    func testNoErrorAfterSwipeUpAndBack() throws {
        try openFirstShort()

        let swipeUp: () -> Void = {
            let start = self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            let end   = self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        let swipeDown: () -> Void = {
            let start = self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            let end   = self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            start.press(forDuration: 0.05, thenDragTo: end)
        }

        swipeUp()
        Thread.sleep(forTimeInterval: 2)
        swipeDown()
        Thread.sleep(forTimeInterval: 2)

        UITestHelpers.assertNoPlayerErrorBanner(in: app)
        XCTAssertEqual(app.state, .runningForeground,
                       "App must still be running after swipe-up then swipe-down")
    }
}
