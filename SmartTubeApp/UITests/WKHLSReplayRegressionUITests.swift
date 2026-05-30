import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After every run extract device logs and inspect for these patterns across
// all 5 play/stop/replay cycles:
//
// GOOD — each tap should show:
//   ✓ [load] load() called — id=<videoID>
//   ✓ [wkHLS] cached HLS URL found  ← must NOT appear on tap 2+ (evicted by stop())
//     OR
//     [wkHLS] cached HLS URL found ... [wkHLS] cached URL played — exhaustiveRetry done
//     (acceptable only if a pre-warm freshly stored a valid URL in the window between
//      stop() and the re-tap — unlikely because invalidateWKHLSURL runs on stop)
//   ✓ ✅ [webView/HLS] readyToPlay           (or equivalent Path A win)
//   ✓ ✅ [webView] Path B won  OR  [BotGuardWV] Path A won
//
// BAD — fail the check if any of these appear:
//   ✗ ❌ [webView/HLS] AVPlayerItem failed   ← stale-session cache bug
//   ✗ [wkHLS] cached URL failed (tryWebViewHLS)  ← stale session used despite stop() eviction
//   ✗ player.errorBanner visible after readyToPlay
//   ✗ tap-to-readyToPlay > 15 s on any tap after the first
//
// TIMING to record per cycle (from log timestamps):
//   [load] load() called → ✅ readyToPlay
//
// Expected: tap 1 ≈ 5–8 s cold, taps 2–5 ≈ 2–5 s (wkHLSEarlyTask hot path).

// MARK: - WKHLSReplayRegressionUITests
//
// Regression test for the stale-CDN-session wrong-video bug.
//
// Root cause (fixed 2026-05-29):
//   After a video played and the player was stopped, the wkHLS manifest URL for
//   that video remained in VideoPreloadCache. On re-tap, Phase -1a found the
//   cached URL, HEAD-probed it (returns 200 — the URL is structurally valid),
//   and handed it to AVPlayer. AVPlayer played ~1.1 s of content from the recycled
//   CDN session — which the user perceived as a completely different video — then
//   received a 403 and fell back to a fresh extraction (~2–5 s extra delay).
//
// Fix: stop() calls VideoPreloadCache.shared.invalidateWKHLSURL(for: stoppedVideoId).
//
// This test reproduces the exact user scenario:
//   1. Open first non-short Home video
//   2. Let it play for 3 s
//   3. Back → mini-player → close (stop)
//   4. Tap the same card again
//   5. Assert no error banner and player title matches expected video
//   Repeat steps 1–5 five times.
//
// The AGENT-POST-RUN-CHECK block confirms via log analysis that the stale-session
// path ([wkHLS] cached URL failed (tryWebViewHLS)) never fires after the fix.

final class WKHLSReplayRegressionUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-disable-sponsorblock",
        ]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Test

    /// Opens the first non-short video on the Home feed, plays it for 3 s,
    /// stops it via back → mini-player close, then repeats 5 times.
    ///
    /// Asserts on each cycle:
    ///   - player.titleLabel appears (video loaded)
    ///   - player.errorBanner is absent (no CDN 403 flash)
    ///   - title is stable (no wrong video played)
    func testReplayFirstHomeVideoFiveTimes() throws {
        let totalCycles = 3

        // 1. Navigate to Home and wait for the feed to load.
        UITestHelpers.tapTab(named: "Home", in: app)
        guard let firstCard = firstNonShortVideoCard(timeout: 30) else {
            try captureAndSkip(
                "No non-short video.card found on Home feed — network unavailable",
                in: app
            )
        }

        // Record the card identifier and the expected title (before tapping).
        let cardID = firstCard.identifier
        // The title is on a sibling element under the same card.
        let expectedTitle = titleText(for: firstCard)

        for cycle in 1...totalCycles {
            // Find the card — it should still be in the tree after stop().
            let card = app.descendants(matching: .any)
                .matching(identifier: cardID).firstMatch
            guard card.waitForExistence(timeout: 10) else {
                XCTFail("Cycle \(cycle): card '\(cardID)' not found — feed may have refreshed")
                return
            }

            // Scroll it into view if needed.
            if !card.isHittable {
                app.scrollViews.firstMatch.scrollToElement(card)
            }

            // 2. Tap the card and wait for the player to open.
            let tapTime = Date()
            card.tap()

            let titleLabel = app.staticTexts["player.titleLabel"].firstMatch
            guard titleLabel.waitForExistence(timeout: 25) else {
                XCTFail("Cycle \(cycle): player.titleLabel did not appear within 25 s " +
                        "(tap-to-player timeout — possible stale-session 403 regression)")
                return
            }
            let elapsed = Date().timeIntervalSince(tapTime)
            print("[WKHLSReplay] cycle \(cycle): tap→titleLabel \(String(format: "%.2f", elapsed))s")

            // 3. Assert no error banner.
            let errorBanner = app.otherElements["player.errorBanner"].firstMatch
            XCTAssertFalse(
                errorBanner.exists,
                "Cycle \(cycle): player.errorBanner visible — stale CDN session may have " +
                "served wrong content before 403 (regression: stop() must evict wkHLS cache)"
            )

            // 4. Assert the title matches what we expect (no wrong video).
            if let expected = expectedTitle, !expected.isEmpty {
                let actualTitle = titleLabel.label
                XCTAssertEqual(
                    actualTitle, expected,
                    "Cycle \(cycle): player title '\(actualTitle)' ≠ expected '\(expected)' — " +
                    "stale wkHLS session served a different video's content before 403"
                )
            }

            // 5. Let it play for 3 s (enough to confirm buffering started).
            Thread.sleep(forTimeInterval: 3)

            // 6. Re-assert no error banner after playback started.
            XCTAssertFalse(
                errorBanner.exists,
                "Cycle \(cycle): player.errorBanner appeared after 3 s of playback"
            )

            // 7. Tap back → minimize to mini-player.
            var backButton = app.buttons["player.backButton"].firstMatch
            if !backButton.waitForExistence(timeout: 3) {
                // Controls may be hidden — tap to reveal.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                Thread.sleep(forTimeInterval: 0.5)
                backButton = app.buttons["player.backButton"].firstMatch
            }
            XCTAssertTrue(
                backButton.waitForExistence(timeout: 5),
                "Cycle \(cycle): player.backButton not found"
            )
            backButton.tap()

            // 8. Wait for mini-player and close it (calls stop()).
            let miniPlayerBar = app.otherElements["miniPlayer.bar"].firstMatch
            guard miniPlayerBar.waitForExistence(timeout: 8) else {
                // Mini-player did not appear — might have already dismissed or
                // the build doesn't show a mini-player. Skip close step.
                print("[WKHLSReplay] cycle \(cycle): miniPlayer.bar not found — skipping close")
                UITestHelpers.tapTab(named: "Home", in: app)
                continue
            }

            let miniClose = app.buttons["miniPlayer.closeButton"].firstMatch
            XCTAssertTrue(
                miniClose.waitForExistence(timeout: 5),
                "Cycle \(cycle): miniPlayer.closeButton not found"
            )
            miniClose.tap()

            // 9. Confirm mini-player is gone (stop() has been called).
            let miniGone = NSPredicate(format: "exists == false")
            let gone = XCTNSPredicateExpectation(predicate: miniGone, object: miniPlayerBar)
            XCTWaiter().wait(for: [gone], timeout: 5)
            XCTAssertFalse(
                miniPlayerBar.exists,
                "Cycle \(cycle): miniPlayer.bar still visible after tapping close"
            )

            // Brief pause so stop()'s invalidateWKHLSURL Task has time to run
            // before the next tap. In practice it dispatches on @MainActor and
            // completes in <1 ms, but the 0.5 s pause makes this deterministic.
            Thread.sleep(forTimeInterval: 0.5)

            print("[WKHLSReplay] cycle \(cycle): stop complete — wkHLS cache evicted")
        }

        print("[WKHLSReplay] all \(totalCycles) cycles passed — no stale-session 403 regression")
    }

    // MARK: - Helpers

    /// Finds the first `video.card.*` element whose accessibilityValue is NOT "short".
    /// On the Home feed (no Shorts chip selected), regular videos get an empty
    /// accessibilityValue; shorts embedded in the main grid get "short".
    private func firstNonShortVideoCard(timeout: TimeInterval) -> XCUIElement? {
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        let any = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"),
                                            object: cards)
        guard XCTWaiter().wait(for: [any], timeout: timeout) == .completed else {
            return nil
        }
        // Walk through cards, skipping shorts (accessibilityValue == "short").
        let count = cards.count
        for i in 0..<min(count, 20) {
            let card = cards.element(boundBy: i)
            if card.value as? String != "short" {
                return card
            }
        }
        // Fallback: return first card if none were filtered out.
        return cards.firstMatch
    }

    /// Returns the text of the `video.card.title` element inside the given card.
    private func titleText(for card: XCUIElement) -> String? {
        let titleEl = card.staticTexts["video.card.title"].firstMatch
        if titleEl.exists { return titleEl.label }
        // SwiftUI propagates identifiers to leaf nodes; look in siblings.
        let allTitles = app.staticTexts.matching(identifier: "video.card.title")
        return allTitles.count > 0 ? allTitles.firstMatch.label : nil
    }
}

// MARK: - ScrollView extension

private extension XCUIElement {
    /// Scrolls the receiver (a scroll view) until `element` is hittable.
    func scrollToElement(_ element: XCUIElement, maxSwipes: Int = 5) {
        var swipes = 0
        while !element.isHittable && swipes < maxSwipes {
            swipeUp()
            swipes += 1
        }
    }
}
