#if os(macOS)
import XCTest

// MARK: - TOSPlayerUITests
//
// Smoke test for the macOS IFrame (TOS-compliant) player.
//
// What it verifies:
//   1. Tapping the first non-short video card opens the TOS player (close button visible).
//   2. The IFrame player starts playing within 30 s (Darwin notification fires + AX state = "playing").
//   3. No crash / close-button disappearance during 5 s of playback.
//   4. Tapping the close button dismisses the player (close button disappears).
//
// Preconditions:
//   - useTOSPlayerOnMac defaults to true on macOS (AppSettings.swift).
//   - The test passes --uitesting-disable-sponsorblock to avoid SponsorBlock skips
//     interfering with the simple "is it playing?" assertion.

final class TOSPlayerUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-disable-sponsorblock",
        ]
        // Remove saved macOS window state so WindowGroup always opens a fresh window.
        let savedState = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Saved Application State/com.void.smarttube.app.savedState")
        try? FileManager.default.removeItem(at: savedState)
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        _ = app.windows.firstMatch.waitForExistence(timeout: 10)
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Test

    func testTOSPlayerPlaysFirstHomeVideo() throws {
        // ── 1. Wait for the home feed ─────────────────────────────────────────
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        let anyCard = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"), object: cards)
        guard XCTWaiter().wait(for: [anyCard], timeout: 30) == .completed else {
            throw XCTSkip("No video cards found — network unavailable or home feed empty")
        }

        // Find first non-short card.
        guard let card = firstNonShortCard(from: cards, maxCheck: 20) else {
            throw XCTSkip("No non-short video card found in first 20 cards")
        }

        let cardID = card.identifier  // "video.card.<videoId>"
        print("[TOS] clicking card: \(cardID)")

        // ── 2. Tap the card — the TOS player should open ──────────────────────
        if !card.isHittable {
            app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 100)
            Thread.sleep(forTimeInterval: 0.5)
        }
        card.click()

        // ── 3. Wait for the close button (player appeared) ───────────────────
        let closeBtn = app.buttons["tosPlayer.closeButton"].firstMatch
        XCTAssertTrue(
            closeBtn.waitForExistence(timeout: 15),
            "tosPlayer.closeButton did not appear — TOS player was not opened (check useTOSPlayerOnMac=true)"
        )
        print("[TOS] ✓ player opened — closeButton visible")

        // ── 4. Wait for IFrame to start playing (Darwin notification) ─────────
        let playingNote = XCTDarwinNotificationExpectation(
            notificationName: "com.void.smarttube.tosplayer.playing"
        )
        let playResult = XCTWaiter().wait(for: [playingNote], timeout: 30)

        // Also poll the AX state label as a secondary check.
        let stateLabel = app.staticTexts["tosPlayer.stateLabel"].firstMatch
        let isPlaying: Bool
        if playResult == .completed {
            isPlaying = true
            print("[TOS] ✓ Darwin notification received — player is playing")
        } else {
            // Darwin notification timed out — check AX state label directly.
            let labelValue = (stateLabel.exists ? stateLabel.label : "")
            isPlaying = labelValue == "playing" || labelValue == "buffering"
            print("[TOS] Darwin notification timed out — stateLabel='\(labelValue)'")
        }

        XCTAssertTrue(
            isPlaying,
            "TOS player did not reach 'playing' state within 30 s — check network, baseURL whitelist, and autoplay config"
        )

        // ── 5. Let it play for 5 s and verify no crash ───────────────────────
        Thread.sleep(forTimeInterval: 5)
        XCTAssertTrue(
            closeBtn.exists,
            "tosPlayer.closeButton disappeared during playback — possible crash or view re-render"
        )
        print("[TOS] ✓ 5 s of playback — no crash")

        // ── 6. Close the player ───────────────────────────────────────────────
        closeBtn.click()

        let closedPredicate = NSPredicate(format: "exists == false")
        let closedExpect = XCTNSPredicateExpectation(predicate: closedPredicate, object: closeBtn)
        let closedResult = XCTWaiter().wait(for: [closedExpect], timeout: 5)
        XCTAssertEqual(
            closedResult, .completed,
            "tosPlayer.closeButton still visible after close tap — player did not dismiss"
        )
        print("[TOS] ✓ player dismissed — test complete")
    }

    // MARK: - Helpers

    private func firstNonShortCard(from query: XCUIElementQuery, maxCheck: Int) -> XCUIElement? {
        let count = min(query.count, maxCheck)
        for i in 0..<count {
            let el = query.element(boundBy: i)
            // AX value "short" is set on short cards by VideoCardView.
            if el.value as? String != "short" { return el }
        }
        return nil
    }
}

#endif // os(macOS)
