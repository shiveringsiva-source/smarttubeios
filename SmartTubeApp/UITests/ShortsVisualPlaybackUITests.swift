#if os(iOS)
import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After every run of this test, load .github/skills/ui-tests-with-logs/SKILL.md and
// inspect the extracted device log. Classify every skip before closing the task:
//
// LEGITIMATE skip:
//   - "home.shortsRow not found" / "No shorts.card.* in home.shortsRow" — home feed
//     network unavailable or the Shorts row is empty.
//   - "only N Shorts available — need at least 4" — signed-in account's Shorts feed
//     returned fewer than 4 items.
//
// BUG skip (must fix before closing):
//   - None — this test exists specifically because Darwin-notification-based tests
//     (ShortsEmbedPlayerUITests) can report "ready"/"tick"/"playing" while the actual
//     WKWebView renders solid black on screen. Every brightness assertion here is a
//     hard XCTAssertGreaterThan, not a skip — a failure means the screen really is
//     black, not a flaky network condition.
//
// Log events to verify (grep the extracted device log by the per-VM tag added in #275 —
// e.g. "[vm1]", "[vm2]/standby" — to disambiguate the active VM from the concurrently
// pre-warming standby VM; they share the same log category):
//   ✓ "[vmN] [ytCallback] ready" for the ACTIVE vm (no "/standby" suffix) per Short
//   ✓ "[prewarm] starting" followed later by "[prewarm] standby ready" for the
//     standby VM one step ahead of the currently visible Short
//   ✓ "[goTo] standby swap" when a swipe lands on an already-warmed standby — confirms
//     the pre-warm pipeline is actually engaging, not silently falling back to a full
//     reload every time (see #274)
//
// RED FLAGS in device log:
//   - "[goTo] standby swap" never appears across 3+ swipes → pre-warm pipeline isn't
//     actually being used (always falling back to loadVideo(at:))
//   - A brightness assertion fails after "[vmN] [ytCallback] ready" already logged →
//     JS bridge believes the video is ready/playing but the WKWebView isn't actually
//     painting pixels — a UIKit/WebKit rendering bug, not a JS bridge bug

// MARK: - ShortsVisualPlaybackUITests
//
// Programmatically verifies Shorts ACTUALLY RENDER on screen, not just that the JS
// bridge reports ready/playing. Samples average pixel brightness of the video area
// from real XCUIScreenshot captures — Darwin notifications can lie (and did: #275 was
// filed because ShortsEmbedPlayerUITests passed on every notification assertion while
// the device showed a solid black screen), but a real screenshot's pixels cannot.
//
// Launch: --uitesting --uitesting-signed-in --uitesting-reset-settings
//         --uitesting-disable-sponsorblock
final class ShortsVisualPlaybackUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-signed-in",
            "--uitesting-reset-settings",
            "--uitesting-disable-sponsorblock",
        ]
        app.launch()
        UITestHelpers.tapTab(named: "Home", in: app)
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Helpers

    private var indexLabel: XCUIElement {
        app.staticTexts["shorts.indexLabel"].firstMatch
    }

    private func swipePlayerUp() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let end   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: end)
        Thread.sleep(forTimeInterval: 0.6)
    }

    private func totalCount(from label: String) -> Int? {
        let parts = label.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let n = Int(parts[1]) else { return nil }
        return n
    }

    @discardableResult
    private func openFirstShort(timeout: TimeInterval = 25) throws -> String {
        let row = app.scrollViews["home.shortsRow"]
        guard row.waitForExistence(timeout: timeout) else {
            try captureAndSkip("home.shortsRow not found within \(timeout)s — Shorts row missing", in: app)
        }
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'shorts.card.'")
        let cards = row.descendants(matching: .any).matching(predicate)
        guard cards.firstMatch.waitForExistence(timeout: 10) else {
            try captureAndSkip("No shorts.card.* in home.shortsRow — Shorts not loaded", in: app)
        }
        cards.firstMatch.tap()
        guard indexLabel.waitForExistence(timeout: 15) else {
            try captureAndSkip("shorts.indexLabel did not appear — Shorts player did not open", in: app)
        }
        return indexLabel.label
    }

    /// Waits up to `timeout` for `shorts.loadingCover` to disappear (i.e. `vm.isReady`
    /// became true for the currently visible Short).
    private func waitForLoadingCoverToClear(timeout: TimeInterval = 15) -> Bool {
        let cover = app.otherElements["shorts.loadingCover"]
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if !cover.exists { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return !cover.exists
    }

    /// Average 0-255 brightness of the center video region of a full-screen
    /// screenshot — avoids the top-right index label and bottom control bar so a
    /// genuinely-playing video reliably samples bright/colorful pixels, while a
    /// black screen (whether margin or a non-rendering WKWebView) samples near 0.
    private func centerBrightness(of screenshot: XCUIScreenshot) -> CGFloat {
        let image = screenshot.image
        guard let cgImage = image.cgImage else { return 0 }
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let cropRect = CGRect(x: w * 0.25, y: h * 0.35, width: w * 0.5, height: h * 0.3)
        guard let cropped = cgImage.cropping(to: cropRect) else { return 0 }

        let sampleSide = 12
        var pixelData = [UInt8](repeating: 0, count: sampleSide * sampleSide * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData,
            width: sampleSide,
            height: sampleSide,
            bitsPerComponent: 8,
            bytesPerRow: sampleSide * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: sampleSide, height: sampleSide))

        var total: CGFloat = 0
        var count = 0
        for i in stride(from: 0, to: pixelData.count, by: 4) {
            total += (CGFloat(pixelData[i]) + CGFloat(pixelData[i + 1]) + CGFloat(pixelData[i + 2])) / 3
            count += 1
        }
        return count > 0 ? total / CGFloat(count) : 0
    }

    /// Takes a screenshot, attaches it to the test report (visible in Xcode's Test
    /// Report / the .xcresult bundle for manual review), and returns its center
    /// brightness for the programmatic assertion.
    @discardableResult
    private func captureAndMeasureBrightness(name: String) -> CGFloat {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return centerBrightness(of: screenshot)
    }

    // MARK: - Tests

    /// Opens the Shorts player and swipes through 4 Shorts (5 total), taking a
    /// screenshot after each one becomes ready and asserting the center of the
    /// screen is not solid black. This is the test that would have caught #275 —
    /// the Darwin-notification-based ShortsEmbedPlayerUITests passed throughout
    /// while the on-screen content was actually black.
    func testShortsRenderVisibleContentAcrossSwipes() throws {
        let opening = try openFirstShort()
        print("[shorts-visual] opened player at '\(opening)'")

        let total = totalCount(from: opening)
        guard let total, total >= 4 else {
            throw XCTSkip("only \(total.map(String.init) ?? "?") Shorts available — need at least 4")
        }

        var brightnessResults: [(short: Int, brightness: CGFloat)] = []

        XCTAssertTrue(waitForLoadingCoverToClear(), "shorts.loadingCover never cleared for short 0 — vm.isReady stuck false")
        // Give the embed a moment past isReady to actually paint a frame before sampling.
        Thread.sleep(forTimeInterval: 1.0)
        let b0 = captureAndMeasureBrightness(name: "short-0-after-ready")
        brightnessResults.append((0, b0))
        print("[shorts-visual] short 0 — center brightness=\(b0)")

        for shortNum in 1...3 {
            swipePlayerUp()
            XCTAssertTrue(waitForLoadingCoverToClear(), "shorts.loadingCover never cleared for short \(shortNum) — vm.isReady stuck false")
            Thread.sleep(forTimeInterval: 1.0)
            let b = captureAndMeasureBrightness(name: "short-\(shortNum)-after-ready")
            brightnessResults.append((shortNum, b))
            print("[shorts-visual] short \(shortNum) — center brightness=\(b)")
        }

        for (short, brightness) in brightnessResults {
            XCTAssertGreaterThan(
                brightness, 8,
                "short \(short) — center of screen is solid black (brightness=\(brightness)) despite vm.isReady being true; the WKWebView is not rendering visible content"
            )
        }
    }

    /// Diagnostic-only (no hard assertions): samples brightness once per second for
    /// 6s on the very first Short, to distinguish "black forever" from "black for a
    /// brief startup window, then renders" — print output is the point of this test,
    /// not pass/fail. Used while investigating #275.
    func testShortsBrightnessOverTimeOnFirstShort() throws {
        let opening = try openFirstShort()
        print("[shorts-visual-time] opened player at '\(opening)'")
        XCTAssertTrue(waitForLoadingCoverToClear(), "shorts.loadingCover never cleared — vm.isReady stuck false")

        for second in 0...6 {
            let b = captureAndMeasureBrightness(name: "t+\(second)s")
            print("[shorts-visual-time] t+\(second)s — center brightness=\(b)")
            Thread.sleep(forTimeInterval: 1.0)
        }
    }
}
#endif // os(iOS)
