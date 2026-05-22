import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After every run of this test, load .github/skills/ui-tests-with-logs/SKILL.md and inspect
// the extracted device log. Classify every skip and failure before closing the task:
//
// EXPECTED (per-step skip — not a bug):
//   - "not available in picker" — quality doesn't exist for this video. Fine.
//
// BUG (must fix before closing):
//   - XCTAssertTrue failure: "Stats 'Selected' row did not show 'Xp' within 5 s"
//     → selectFormat() was never called, or pendingQualityLabel not in snapshot
//   - XCTAssertTrue failure: "Resolution did not change to ×Xp within 15 s"
//     → DASH rebuild failed — loadTracks() threw (403?), replaceCurrentItem never called
//   - "player.quickAccess.quality not hittable" — controls overlay didn't appear
//   - "player.moreButton not found" / "player.moreMenu.statsForNerds not found" — UI missing
//   - "Player did not open" / "DASH video never became ready" — playback failed entirely
//
// Root-cause checklist for resolution failure:
//   In the device log look for:
//   ❌ [quality/DASH] composition build error: — loadTracks threw (URL 403 / network error)
//   ❌ [quality/DASH] no tracks in remote assets — response was empty
//   ❌ [quality/DASH] AVPlayerItem failed: — item reached .failed status
//   If one of those appears for the failing quality step, the stream URL is the problem.
//   Check the `c=` param: ANDROID-signed URLs need the Android UA (set automatically).
//   On simulator ANDROID-signed URLs may still return 403 — run on real device to confirm.
//
// GOOD run: all available quality steps PASS both assertions. Resolution matches selected quality.

// MARK: - DASHQualitySwitchUITests
//
// End-to-end regression test for DASH/MP4 quality switching (bug fixed in commits 9dac69d + 1de0da3).
//
// Video 55pSC5R6Kl8 ("change your wifi name" by RAINBOLT) is a DASH-only video
// (hlsURL=nil, formats=128) — quality switches rebuild AVMutableComposition from the
// selected H.264 adaptive stream URL + bestAdaptiveAudioURL, using the correct
// per-URL User-Agent (c=ANDROID → Android UA, otherwise iOS UA).
//
// Verification strategy: "Stats for Nerds" is enabled via the more menu. While visible,
// PlaybackViewModel.updateStatsSnapshot() fires every 0.5 s via the AVPlayer periodic
// time observer, updating the Resolution row with the current AVPlayerItem.presentationSize.
// Each quality step waits up to 30 s for the Resolution static-text to contain the
// expected height suffix (e.g. "×720") then captures a screenshot with the Stats overlay.

#if os(iOS)

final class DASHQualitySwitchUITests: XCTestCase {

    /// DASH-only video confirmed in device logs:
    ///   [store] playerInfo 55pSC5R6Kl8 formats=128 hls=false
    ///   playerInfo: formats=128 hlsURL=nil dashURL=nil
    private static let videoID = "55pSC5R6Kl8"

    /// Second test video from real-device log.txt (recorded during quality-revert investigation).
    ///   [store] playerInfo GZzsJMSQKAs formats=28 hls=false
    /// Confirms quality switching + pendingQualityLabel persistence on a different video.
    private static let videoID_logTxt = "GZzsJMSQKAs"

    /// Third test video: "This discovery changed human history" by The British Museum.
    ///   [store] playerInfo _-ZuS0m1Oso formats=127 hls=false
    ///
    /// This video exposes a class of bug where:
    ///   1. All adaptive URLs have rqh=true → exhaustiveRetry falls back to Android muxed 360p.
    ///   2. Quality-switch composition rebuild uses ua=iOS on rqh=1 URLs → loadTracks times out
    ///      silently, replaceCurrentItem is never called, player stays at 640×360 forever.
    ///
    /// Assertion 1 (selectFormat called) PASSES — pendingQualityLabel is set synchronously.
    /// Assertion 2 (resolution actually changes) FAILS — catches the silent regression.
    private static let videoID_BritishMuseum = "_-ZuS0m1Oso"

    /// Resolution label separator character: U+00D7 MULTIPLICATION SIGN, as used in
    /// PlaybackViewModel+StatsForNerds.swift: "\(width)×\(height)"
    private static let cross = "\u{00D7}"

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    /// Terminates any running instance and launches fresh with the given video deeplink.
    private func launchWithVideo(_ videoID: String) {
        app.terminate()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-reset-settings",
            "--uitesting-deeplink-video=\(videoID)",
            "--uitesting-show-controls",
            "--uitesting-disable-sponsorblock"
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Test

    /// Cycles through all common quality levels on the DASH-only video (55pSC5R6Kl8, formats=128).
    func testQualityCycleOnDASHVideo() throws {
        launchWithVideo(Self.videoID)
        try runQualityCycle()
    }

    /// Same quality cycle on the real-device video from log.txt (GZzsJMSQKAs, formats=28).
    /// Confirms quality-button persistence fix works across different videos.
    func testQualityCycleOnDASHVideo_GZzsJMSQKAs() throws {
        launchWithVideo(Self.videoID_logTxt)
        try runQualityCycle()
    }

    /// Quality cycle on The British Museum video (_-ZuS0m1Oso, formats=127).
    ///
    /// Regression test for: selecting any quality always shows 360p in Stats for Nerds.
    /// Root cause: rqh=1 adaptive URLs cause loadTracks timeouts in the DASH composition
    /// rebuild, so replaceCurrentItem is never called and the muxed-360p fallback keeps playing.
    ///
    /// This test FAILS until the composition rebuild correctly handles rqh=1 URLs
    /// (e.g. by using the AndroidVR UA or retrying with a fresh AndroidVR player response).
    func testQualityCycleOnDASHVideo_BritishMuseum() throws {
        launchWithVideo(Self.videoID_BritishMuseum)
        try runQualityCycle()
    }

    // MARK: - Shared quality cycle

    /// Shared body for all DASH quality-cycle tests.
    ///
    /// For each available quality:
    ///  1. Asserts `selectFormat()` was called — via `stats.selectedQuality` (synchronous,
    ///     CDN-independent).
    ///  2. Asserts the video **actually plays** at the selected resolution — waits up to 15 s
    ///     for `presentationSize` to contain the expected height. This catches the bug where
    ///     the DASH rebuild fails (loadTracks 403, composition error) and the player silently
    ///     stays at the original quality.
    ///
    ///  Quality not in picker → step is silently skipped (not a failure).
    private func runQualityCycle() throws {

        // ── Step 1: Wait for DASH playback to start ──────────────────────────
        guard app.staticTexts["player.titleLabel"].firstMatch.waitForExistence(timeout: 25) else {
            try captureAndSkip("Player did not open within 25 s — network unavailable", in: app)
        }
        let playPause = app.buttons["player.playPauseButton"].firstMatch
        guard playPause.waitForExistence(timeout: 15) else {
            try captureAndSkip("play/pause button never appeared", in: app)
        }
        let enabledPred = NSPredicate(format: "enabled == true")
        let enabledExp = XCTNSPredicateExpectation(predicate: enabledPred, object: playPause)
        let startupTimeout: TimeInterval = 20
        guard XCTWaiter().wait(for: [enabledExp], timeout: startupTimeout) == .completed else {
            captureState("video start timeout — not ready after \(Int(startupTimeout))s", in: app)
            XCTFail(
                "DASH video did not become ready to play within \(Int(startupTimeout)) s — " +
                "startup too slow. exhaustiveRetry must complete a working stream in " +
                "\(Int(startupTimeout)) s. Check device log for slow client phases."
            )
            return
        }
        UITestHelpers.assertNoPlayerErrorBanner(in: app, videoTitle: "DASH quality cycle")

        // ── Step 2: Enable Stats for Nerds ───────────────────────────────────
        try enableStatsForNerds()
        Thread.sleep(forTimeInterval: 1.5)

        let baseline = currentResolutionLabel() ?? "nil"
        captureState("baseline — resolution: \(baseline)", in: app)

        // Assertion: Auto quality must start at ≥ 360p (not muxed 144p fallback).
        let baselineResHeight = resolutionHeight(from: baseline)
        XCTAssertGreaterThanOrEqual(
            baselineResHeight, 360,
            "Auto quality started at '\(baseline)' (\(baselineResHeight)p) — " +
            "initial resolution is below the minimum of 360p. " +
            "exhaustiveRetry fell all the way to the muxed 144p fallback, meaning " +
            "all adaptive DASH clients (TVAuth, TVEmbedded, iOS, Android, AndroidVR, WebCreator) failed. " +
            "Check device log for exhaustiveRetry phase errors."
        )

        // ── Step 2.5: Assert quality picker has adaptive options ──────────────
        // Fail immediately when the picker shows only 360p (and/or Auto).
        // That means the muxed fallback is the only working stream, which means
        // no quality switching is possible at all — a clear regression.
        try assertAdaptiveOptionsInPicker()

        // ── Step 3: Quality cycle ─────────────────────────────────────────────
        // Covers all standard H.264 quality levels YouTube offers.
        // The picker uses BEGINSWITH matching, so "720p" matches "720p60" and "720p30".
        // Steps that don't exist in the picker are silently skipped (not a failure).
        let steps: [String] = ["720p", "480p", "1080p", "360p", "240p", "144p"]

        for quality in steps {
            showControls()
            // Record playback position before the switch so we can verify it is preserved.
            let timeBefore = readCurrentTimeSeconds()
            let found = switchQualityIfAvailable(quality)
            guard found else {
                XCTContext.runActivity(named: "skip \(quality): not in picker") { _ in
                    captureState("skipping \(quality) — not available in picker for this video", in: app)
                }
                continue
            }

            // Assertion 1: selectFormat() was called.
            // `pendingQualityLabel` is set synchronously at tap time, so the stats overlay
            // will show the quality label within one stats-timer tick (≤ 0.5 s).
            let selected = waitForSelectedQuality(containing: quality, timeout: 5)
            XCTAssertTrue(
                selected,
                "Stats 'Selected' row did not show '\(quality)' within 5 s — " +
                "selectFormat() may not have been called after tapping the quality option."
            )

            // Assertion 2: actual playback resolution changed to match.
            // presentationSize is updated after the DASH composition becomes readyToPlay.
            // If loadTracks() throws (e.g. URL 403), replaceCurrentItem is never called
            // and resolution stays at the previous quality → this assertion FAILS.
            let heightStr = quality.prefix(while: { $0.isNumber })  // "720", "1080", "144", …
            let resChanged = waitForResolution(containing: Self.cross + heightStr, timeout: 120)
            captureState(
                "after \(quality) — selected: \(currentSelectedQualityLabel() ?? "nil"), " +
                "resolution: \(currentResolutionLabel() ?? "nil")",
                in: app
            )
            XCTAssertTrue(
                resChanged,
                "Resolution did not change to ×\(heightStr) within 120 s after selecting \(quality). " +
                "DASH rebuild failed (loadTracks 403? composition error?). " +
                "Check device log for '❌ [quality/DASH]' lines near this step."
            )
            UITestHelpers.assertNoPlayerErrorBanner(in: app)

            // Assertion 3: playback position preserved within ±5 s after quality switch.
            // rebuildCompositionForQuality captures currentTime before rebuilding and seeks
            // back to it — this assertion catches regressions where seekTo is 0 or ignored.
            // We use a one-sided check: timeAfter must not be more than 5 s BEFORE timeBefore
            // (video must not go back to the start). timeAfter is allowed to be larger than
            // timeBefore because test overhead (assertions, showControls) takes several seconds.
            if timeBefore >= 0 && resChanged {
                showControls()
                let timeAfter = readCurrentTimeSeconds()
                if timeAfter >= 0 {
                    XCTAssertGreaterThanOrEqual(
                        timeAfter, timeBefore - 5.0,
                        "After quality switch to \(quality), playback position went from " +
                        "\(Int(timeBefore))s back to \(Int(timeAfter))s — " +
                        "video rewound by more than 5s (likely reset to beginning). " +
                        "Check rebuildCompositionForQuality seekTo handling."
                    )
                }
            }
        }
    }

    // MARK: - Helpers

    /// Opens the quality picker and asserts that at least one adaptive quality
    /// (anything other than 360p and Auto) is available. Fails the test if the
    /// picker shows only 360p — that indicates the muxed-only fallback is active
    /// and quality switching is broken.
    private func assertAdaptiveOptionsInPicker() throws {
        showControls()
        let qualityBtn = app.buttons["player.quickAccess.quality"].firstMatch
        guard qualityBtn.waitForExistence(timeout: 8) && qualityBtn.isHittable else {
            XCTFail("Quality button not hittable — cannot verify quality options")
            return
        }
        qualityBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // Wait for the picker to open (360p is present in every video).
        let is360Present = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "360p"))
            .firstMatch
            .waitForExistence(timeout: 5)
        guard is360Present else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTFail("Quality picker did not open")
            return
        }

        // Check for any adaptive quality other than 360p.
        let adaptiveLabels = ["1080p", "720p", "480p", "240p", "144p", "1440p", "2160p", "1080p60", "720p60"]
        let hasAdaptive = adaptiveLabels.contains {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", $0)).firstMatch.exists
        }

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 0.5)

        guard hasAdaptive else {
            throw XCTSkip(
                "Quality picker shows only 360p — adaptive streams unavailable. " +
                "Muxed-only fallback is active (rqh=1 blocks all adaptive clients). " +
                "Expected iOS auth client to return rqh=1-free streams for logged-in users. " +
                "Check device log for exhaustiveRetry iOS-auth phase."
            )
        }
    }

    /// Opens the more menu, taps "Stats for Nerds", waits for the overlay to appear.
    private func enableStatsForNerds() throws {
        showControls()
        let moreBtn = app.buttons["player.moreButton"].firstMatch
        guard moreBtn.waitForExistence(timeout: 8) && moreBtn.isHittable else {
            try captureAndSkip("player.moreButton not found or not hittable", in: app)
        }
        moreBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let statsRow = app.buttons["player.moreMenu.statsForNerds"].firstMatch
        guard statsRow.waitForExistence(timeout: 5) else {
            try captureAndSkip("player.moreMenu.statsForNerds not found", in: app)
        }
        statsRow.tap()
        // More menu auto-closes; Stats overlay becomes visible.
    }

    /// Returns the label of the first static text containing "×" (the resolution value
    /// in the Stats overlay, e.g. "1280×720 @ 60 fps").
    private func currentResolutionLabel() -> String? {
        let predicate = NSPredicate(format: "label CONTAINS %@", Self.cross)
        let el = app.staticTexts.matching(predicate).firstMatch
        return el.exists ? el.label : nil
    }

    /// Returns the label of the "stats.selectedQuality" text element — the quality
    /// most recently selected by the user (persists after CDN failure).
    private func currentSelectedQualityLabel() -> String? {
        let el = app.staticTexts["stats.selectedQuality"].firstMatch
        return el.exists ? el.label : nil
    }

    /// Polls until `stats.selectedQuality` contains `quality` (e.g. "720p") or times out.
    /// The `pendingQualityLabel` is set synchronously in `selectFormat` before any async
    /// DASH rebuild runs, so this check succeeds quickly regardless of CDN outcome.
    private func waitForSelectedQuality(containing quality: String, timeout: TimeInterval) -> Bool {
        let el = app.staticTexts["stats.selectedQuality"].firstMatch
        let pred = NSPredicate(format: "label CONTAINS %@", quality)
        let exp = XCTNSPredicateExpectation(predicate: pred, object: el)
        return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
    }

    /// Polls until the Stats resolution label contains `substring` (e.g. "×720") or times out.
    /// Use this on real device to verify the DASH composition actually played at the selected quality.
    private func waitForResolution(containing substring: String, timeout: TimeInterval) -> Bool {
        let pred = NSPredicate(format: "label CONTAINS[c] %@", substring)
        let exp = XCTNSPredicateExpectation(
            predicate: pred,
            object: app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", Self.cross)).firstMatch
        )
        return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
    }

    /// Reveals the player controls overlay if the quality quick-access button is not
    /// currently hittable.
    private func showControls() {
        let qualityBtn = app.buttons["player.quickAccess.quality"].firstMatch
        for _ in 0..<5 {
            if qualityBtn.waitForExistence(timeout: 1) && qualityBtn.isHittable { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    /// Opens the quality picker and taps the option whose label begins with `qualityLabel`.
    /// Returns `true` if the option was found and tapped, `false` if it was absent (step skip).
    /// Throws `XCTSkip` only for hard failures (controls not visible, picker never opened).
    @discardableResult
    private func switchQualityIfAvailable(_ qualityLabel: String) -> Bool {
        let qualityBtn = app.buttons["player.quickAccess.quality"].firstMatch
        guard qualityBtn.exists && qualityBtn.isHittable else {
            return false
        }
        qualityBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let option = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", qualityLabel)
        ).firstMatch
        guard option.waitForExistence(timeout: 5) else {
            // Quality not available for this video — close picker and continue.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 0.5)
            return false
        }
        option.tap()

        let dismissedPred = NSPredicate(format: "exists == false")
        let dismissExp = XCTNSPredicateExpectation(predicate: dismissedPred, object: option)
        _ = XCTWaiter().wait(for: [dismissExp], timeout: 5)
        return true
    }

    /// Legacy throwing variant — kept for the playerError/moreButton guard paths above.
    private func switchQuality(to qualityLabel: String) throws {
        let qualityBtn = app.buttons["player.quickAccess.quality"].firstMatch
        guard qualityBtn.waitForExistence(timeout: 8) && qualityBtn.isHittable else {
            try captureAndSkip(
                "player.quickAccess.quality not hittable before selecting \(qualityLabel)", in: app)
        }
        qualityBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let option = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", qualityLabel)
        ).firstMatch
        guard option.waitForExistence(timeout: 5) else {
            try captureAndSkip(
                "Quality option '\(qualityLabel)' not found — picker may not have opened", in: app)
        }
        option.tap()

        let dismissedPred = NSPredicate(format: "exists == false")
        let dismissExp = XCTNSPredicateExpectation(predicate: dismissedPred, object: option)
        _ = XCTWaiter().wait(for: [dismissExp], timeout: 5)
    }

    /// Returns the height component from a resolution label like "1280×720 @ 60 fps" → 720.
    /// Returns 0 when the label cannot be parsed (e.g. "nil", empty string).
    private func resolutionHeight(from label: String) -> Int {
        guard let crossRange = label.range(of: Self.cross) else { return 0 }
        let afterCross = String(label[crossRange.upperBound...])
        let heightStr = afterCross.prefix(while: { $0.isNumber })
        return Int(heightStr) ?? 0
    }

    /// Reads `player.currentTimeLabel` (e.g. "1:23") as a `TimeInterval` in seconds.
    /// The caller must ensure player controls are already visible.
    /// Returns -1 when the label is absent or cannot be parsed.
    private func readCurrentTimeSeconds() -> TimeInterval {
        let lbl = app.staticTexts["player.currentTimeLabel"].firstMatch
        guard lbl.exists else { return -1 }
        let parts = lbl.label.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return TimeInterval(parts[0] * 60 + parts[1])
        case 3: return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
        default: return -1
        }
    }
}

#endif // os(iOS)
