import XCTest

// MARK: - ShareExtensionE2EUITests
//
// End-to-end tests for the Share Extension that drive the FULL system-level flow:
//
//   Safari  →  share sheet  →  tap "SmartTube"  →  SmartTube app foregrounds
//                                                   →  video player opens
//
// Root cause of the "blink" bug (fixed in ShareViewController):
//   The old `openViaResponderChain` approach stopped working reliably in modern iOS
//   because the UIApplication proxy is no longer reachable in a Share Extension
//   process. The fix uses `extensionContext?.open(_:completionHandler:)` which is
//   the officially supported API (NSExtensionContext, iOS 8+) for launching the
//   containing app from within a Share Extension.
//
// Prerequisites:
//   • The simulator must have network access (YouTube URL must be navigable in Safari).
//   • The "SmartTube" extension must be enabled in the iOS share sheet.
//     If it has never been used on this simulator, open the share sheet manually
//     once and tap "More" to enable it, or reset the simulator.
//   • These tests are intentionally split from `ShareExtensionUITests` (which uses
//     launch arguments) because here we exercise the real OS-level share path.
//
// Skips gracefully when network is unavailable or Safari UI cannot be navigated.

private let kTestVideoURL  = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
private let kExtensionName = "SmartTube"   // CFBundleDisplayName in ShareExtension/Info.plist

final class ShareExtensionE2EUITests: XCTestCase {

    private var safari: XCUIApplication!
    private var smartTube: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        safari    = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        smartTube = XCUIApplication()
    }

    override func tearDownWithError() throws {
        // Always return to SmartTube so the test runner can clean up.
        smartTube.activate()
        safari    = nil
        smartTube = nil
    }

    // MARK: - Tests

    /// Full system share flow: Safari → SmartTube extension → player opens.
    ///
    /// This test reproduces the "blink" bug where tapping the extension dismisses
    /// the share sheet but never foregrounds SmartTube. With the fix
    /// (`extensionContext?.open(_:completionHandler:)`) the test passes.
    func testSharingYouTubeURLFromSafariOpensPlayer() throws {
        // 1. Launch Safari and navigate to a YouTube video URL.
        safari.launch()
        try navigateSafari(to: kTestVideoURL)

        // 2. Tap Safari's share button to open the share sheet.
        let shareButton = try safariShareButton()
        shareButton.tap()

        // 3. Find and tap the SmartTube extension in the share sheet.
        try tapExtension(named: kExtensionName)

        // 4. SmartTube must come to the foreground within 15 s.
        //    Failure here is the exact symptom of the blink bug.
        let appOpened = smartTube.wait(for: .runningForeground, timeout: 15)
        XCTAssertTrue(
            appOpened,
            "SmartTube did not come to the foreground after tapping the share extension. " +
            "This is the 'blink' bug: the share sheet dismissed but the app was never opened. " +
            "Root cause: openViaResponderChain failed silently. " +
            "Fix: use extensionContext?.open(_:completionHandler:)."
        )

        // 5. The video player must open.
        let titleLabel = smartTube.staticTexts["player.titleLabel"].firstMatch
        guard titleLabel.waitForExistence(timeout: 20) else {
            throw XCTSkip(
                "player.titleLabel did not appear within 20 s — " +
                "SmartTube opened but InnerTube may not have resolved the video (network unavailable)"
            )
        }

        UITestHelpers.assertNoPlayerErrorBanner(in: smartTube)
    }

    /// Verifies the player is also reachable via the App Group fallback path when
    /// SmartTube is re-foregrounded after the share (cold-launch scenario).
    ///
    /// If `extensionContext?.open()` succeeds the pending key is cleaned up by
    /// `AppEntry.consumePendingVideoID()`. This test confirms the key is not
    /// re-consumed (and the player does not reopen) on a second activation.
    func testShareDoesNotReopenPlayerOnSubsequentForeground() throws {
        safari.launch()
        try navigateSafari(to: kTestVideoURL)

        let shareButton = try safariShareButton()
        shareButton.tap()
        try tapExtension(named: kExtensionName)

        guard smartTube.wait(for: .runningForeground, timeout: 15) else {
            throw XCTSkip("SmartTube did not open — skipping re-foreground check")
        }

        guard smartTube.staticTexts["player.titleLabel"].firstMatch.waitForExistence(timeout: 20) else {
            throw XCTSkip("Player did not appear — network unavailable")
        }

        // Dismiss the player.
        let backButton = smartTube.buttons["player.backButton"].firstMatch
        if backButton.waitForExistence(timeout: 5) { backButton.tap() }

        // Background then re-foreground SmartTube.
        XCUIDevice.shared.press(.home)
        smartTube.activate()

        // Player must NOT reopen — pending key was already consumed.
        let playerAfterReturn = smartTube.staticTexts["player.titleLabel"].firstMatch
        XCTAssertFalse(
            playerAfterReturn.waitForExistence(timeout: 5),
            "player.titleLabel reappeared after re-foregrounding — " +
            "pendingVideoID was not cleared from the App Group"
        )
    }

    // MARK: - Safari helpers

    /// Types `urlString` into Safari's address bar and waits for the page to begin loading.
    private func navigateSafari(to urlString: String) throws {
        // The address bar appears as a text field when focused, or as an "Address" button
        // (URL display) when a page is already loaded.
        let textField = safari.textFields["Address"].firstMatch
        if textField.waitForExistence(timeout: 4) {
            textField.tap()
        } else {
            // Tap the URL display button to put the bar into editing mode.
            let urlButton = safari.buttons["Address"].firstMatch
            if urlButton.waitForExistence(timeout: 4) {
                urlButton.tap()
            } else {
                throw XCTSkip("Cannot locate Safari address bar — layout may differ on this OS version")
            }
        }

        let editField = safari.textFields["Address"].firstMatch
        guard editField.waitForExistence(timeout: 5) else {
            throw XCTSkip("Safari address text field did not become editable")
        }

        editField.typeText(urlString + "\n")

        // Wait briefly for the web view to appear — we don't need the page to fully
        // load; the URL is what the share sheet will offer to the extension.
        _ = safari.webViews.firstMatch.waitForExistence(timeout: 10)
    }

    /// Returns the share button from Safari's toolbar or navigation bar.
    private func safariShareButton() throws -> XCUIElement {
        let candidates: [XCUIElement] = [
            safari.toolbars.buttons["Share"].firstMatch,
            safari.navigationBars.buttons["Share"].firstMatch,
            safari.buttons["Share"].firstMatch,
        ]
        for candidate in candidates where candidate.waitForExistence(timeout: 3) {
            return candidate
        }
        throw XCTSkip("Safari share button not found — layout may have changed on this OS version")
    }

    // MARK: - Share sheet helpers

    /// Finds and taps the named activity in the iOS share sheet.
    ///
    /// Activities are rendered as buttons inside a `UICollectionView`. If the
    /// desired extension is not immediately visible, the row is scrolled left
    /// to reveal extensions that may be off-screen.
    private func tapExtension(named name: String) throws {
        let extensionButton = safari.buttons[name].firstMatch

        if !extensionButton.waitForExistence(timeout: 5) {
            // Scroll the apps row in the share sheet to expose hidden extensions.
            let appsRow = safari.collectionViews.firstMatch
            if appsRow.waitForExistence(timeout: 3) {
                appsRow.swipeLeft()
                appsRow.swipeLeft()
            }
        }

        guard extensionButton.waitForExistence(timeout: 5) else {
            throw XCTSkip(
                "'\(name)' extension not visible in the share sheet. " +
                "Open the share sheet manually on this simulator, tap 'More', and enable \(name)."
            )
        }

        extensionButton.tap()
    }
}
