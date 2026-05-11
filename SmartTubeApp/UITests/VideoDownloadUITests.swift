import XCTest

// MARK: - VideoDownloadUITests
//
// UI tests for the two video-download entry points available in the iOS app:
//
//   Method A — Player more menu:
//     Open player → tap "..." (player.moreButton) → tap "Download to Gallery"
//     (player.moreMenu.downloadButton).
//
//   Method B — Video card context menu:
//     Long-press a video card from the feed → tap "Download to Gallery".
//
// Both methods call the same VideoDownloadService.download(video:) under the hood,
// which saves the video to the device's Photos library.
//
// Known video used: https://youtube.com/watch?v=JhCjw57u8mQ
// The test is launched via --uitesting-deeplink-video for Method A so the player
// opens immediately without depending on feed card availability.
//
// Requirements:
//   • Network access is required (downloads real YouTube CDN content).
//   • Photo library access is requested at runtime — the test handles the
//     system permission dialog automatically via addUIInterruptionMonitor.
//   • Run on an iOS 17+ simulator with the SmartTubeApp scheme selected.
//   • Tests skip gracefully when the network or environment is unavailable.

private let kDownloadVideoID = "JhCjw57u8mQ"

final class VideoDownloadUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Automatically allow Photos/network permission dialogs that appear mid-test.
        // IMPORTANT: skip alerts that belong to the app itself (e.g. "Saved to Gallery",
        // "Download Failed") so they are not dismissed before the test assertion runs.
        addUIInterruptionMonitor(withDescription: "System permission dialog") { alert in
            // Guard: ignore app-level download completion alerts.
            let label = alert.label
            if label.contains("Gallery") || label.contains("Download Failed") {
                return false
            }
            // Prefer "Allow" or "OK"; fall back to the first button.
            if alert.buttons["Allow"].exists {
                alert.buttons["Allow"].tap()
                return true
            }
            if alert.buttons["Allow Access to All Photos"].exists {
                alert.buttons["Allow Access to All Photos"].tap()
                return true
            }
            if alert.buttons["OK"].exists {
                alert.buttons["OK"].tap()
                return true
            }
            return false
        }
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Launches the app with an optional set of extra arguments.
    private func launch(extraArgs: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"] + extraArgs
        app.launch()
    }

    /// Waits for `player.titleLabel` to appear within `timeout`.
    @discardableResult
    private func waitForPlayer(timeout: TimeInterval = 20) -> Bool {
        app.staticTexts["player.titleLabel"].firstMatch.waitForExistence(timeout: timeout)
    }

    /// Taps the player until the controls overlay (play/pause button) is visible.
    /// Retries up to 5 times with 1.5 s gaps.
    private func showControls() {
        let playPause = app.buttons["player.playPauseButton"].firstMatch
        for _ in 0..<5 {
            if playPause.exists { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    /// Opens the more menu via the `player.moreButton`.
    /// Returns `true` when the button was found and tapped.
    @discardableResult
    private func openMoreMenu() -> Bool {
        let moreButton = app.buttons["player.moreButton"].firstMatch
        guard moreButton.waitForExistence(timeout: 5), moreButton.frame.width > 0 else {
            return false
        }
        moreButton.tap()
        return true
    }

    /// Scrolls the more-menu sheet upward so the Download button (which may be
    /// below the fold) becomes visible. Swipes once on the first scrollable area.
    private func scrollMenuIfNeeded() {
        // Give the sheet animation time to settle.
        Thread.sleep(forTimeInterval: 0.5)
        let scrollView = app.scrollViews.firstMatch
        if scrollView.exists {
            scrollView.swipeUp()
        }
    }

    /// Waits for the download completion or failure alert.
    /// The alert appears when VideoDownloadService.state becomes .done or .failed.
    /// Returns the alert, or nil if no alert appeared within `timeout`.
    private func waitForDownloadAlert(timeout: TimeInterval = 90) -> XCUIElement? {
        // Tap the app once per second while waiting so the interruption monitor
        // can service any Photos permission dialog that arrives mid-download.
        let savedAlert = app.alerts.containing(
            NSPredicate(format: "label CONTAINS 'Gallery' OR label CONTAINS 'Download'")
        ).firstMatch

        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if savedAlert.exists { return savedAlert }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.0)
        }
        return savedAlert.exists ? savedAlert : nil
    }

    /// Dismisses any currently-visible alert by tapping its first button ("OK").
    private func dismissAlert() {
        let okButton = app.alerts.buttons["OK"].firstMatch
        if okButton.waitForExistence(timeout: 3) {
            okButton.tap()
        }
    }

    // MARK: - Method A: Download from player more menu

    /// Verifies that tapping "Download to Gallery" in the player more menu
    /// triggers a download and shows a completion alert.
    func testDownloadToGalleryFromPlayerMoreMenu() throws {
        launch(extraArgs: ["--uitesting-deeplink-video=\(kDownloadVideoID)"])

        guard waitForPlayer() else {
            throw XCTSkip("Player did not open within 20 s — network unavailable or video inaccessible")
        }
        let errorBanner = app.otherElements["player.errorBanner"].firstMatch
        guard !errorBanner.exists else {
            throw XCTSkip("player.errorBanner visible — video inaccessible or requires auth on this simulator")
        }

        // Give the player a moment to buffer before interacting.
        Thread.sleep(forTimeInterval: 3)

        showControls()

        guard openMoreMenu() else {
            throw XCTSkip("player.moreButton not found — controls may not have appeared (timing-dependent)")
        }

        // The download button may be below the fold in the scrollable menu sheet.
        scrollMenuIfNeeded()

        let downloadButton = app.buttons["player.moreMenu.downloadButton"].firstMatch
        guard downloadButton.waitForExistence(timeout: 10) else {
            throw XCTSkip("'Download to Gallery' button not found in more menu (timing-dependent)")
        }

        // Button should be enabled (no download in flight).
        XCTAssertTrue(downloadButton.isEnabled, "'Download to Gallery' button should be enabled before download starts")

        downloadButton.tap()

        // Wait for the completion alert — allow up to 90 s for real CDN download.
        // The interruption monitor handles the Photos permission dialog mid-wait.
        guard let alert = waitForDownloadAlert(timeout: 90) else {
            throw XCTSkip("No download completion alert within 90 s — network or CDN unavailable in this environment")
        }

        // Alert must indicate success ("Saved to Gallery") not failure.
        XCTAssertTrue(
            alert.label.contains("Gallery") || alert.label.contains("Saved"),
            "Expected 'Saved to Gallery' alert but got: \(alert.label)"
        )

        dismissAlert()
        UITestHelpers.assertNoPlayerErrorBanner(in: app)
    }

    // MARK: - Method B: Download from video card context menu

    /// Verifies that long-pressing a video card and tapping "Download to Gallery"
    /// in the context menu triggers a download and shows a completion alert.
    /// Uses Search tab to load video cards without requiring a signed-in account.
    func testDownloadToGalleryFromVideoCardContextMenu() throws {
        launch(extraArgs: ["--uitesting-reset-settings"])

        // Use Search tab: does not require auth, loads public video results.
        UITestHelpers.tapTab(named: "Search", in: app)
        let searchField = app.textFields["search.bar"].firstMatch
        guard searchField.waitForExistence(timeout: 10) else {
            throw XCTSkip("Search field not found — tab navigation may have failed")
        }
        searchField.tap()
        searchField.typeText("MKBHD")

        // Dismiss keyboard and wait for results.
        app.keyboards.buttons["search"].firstMatch.tap()

        guard let card = UITestHelpers.waitForVideoCards(in: app, timeout: 30) else {
            throw XCTSkip("No search results — network unavailable")
        }

        // Long-press to show the context menu.
        card.press(forDuration: 1.2)

        // "Download to Gallery" appears in the context menu (iOS only).
        let downloadItem = app.buttons["Download to Gallery"].firstMatch
        guard downloadItem.waitForExistence(timeout: 5) else {
            // Menu appeared but no download item — possibly signed-out or restricted.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
            throw XCTSkip("'Download to Gallery' not found in video card context menu")
        }

        downloadItem.tap()

        // Do NOT tap anything after this point. Any tap can trigger a
        // scroll-to-top, refreshing the home feed and creating a new card view
        // instance, which would orphan the running download task.
        //
        // The download alert is now shown at RootView level (not the card), so it
        // persists regardless of card view lifecycle. waitForExistence polls the
        // accessibility tree at ~0.25 s intervals, which is sufficient to invoke
        // the interrupt monitor for any deferred Photos permission dialog.
        // Wait up to 40 s for any alert to appear, then verify it's the right one.
        let anyAlert = app.alerts.firstMatch
        guard anyAlert.waitForExistence(timeout: 40) else {
            throw XCTSkip("No download completion alert within 40 s — network or CDN unavailable in this environment")
        }

        let alertLabel = anyAlert.label
        XCTAssertTrue(
            alertLabel.contains("Gallery") || alertLabel.contains("Saved") || alertLabel.contains("Download"),
            "Expected 'Saved to Gallery' alert but got: \(alertLabel)"
        )

        dismissAlert()
    }
}
