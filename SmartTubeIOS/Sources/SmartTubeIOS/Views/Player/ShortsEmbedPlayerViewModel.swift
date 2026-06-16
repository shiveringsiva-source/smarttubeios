#if !os(tvOS)
import Foundation
import CoreFoundation
import AVFoundation
import WebKit
import os
import SmartTubeIOSCore

private let shortsLog = Logger(subsystem: "com.void.smarttube.app", category: "ShortsPlayer")

/// State owner for the iOS Shorts TOS-embed player — replaces the AVPlayer-based
/// `PlaybackViewModel` for the Shorts pipeline (see
/// `docs/superpowers/specs/2026-06-11-tos-player-shorts-design.md`).
///
/// Owns ONE persistent `WKWebView` for the lifetime of a `ShortsPlayerView` session.
/// `loadShort(video:)` is called once per Short: the first call loads the HTML
/// wrapper page via `webView.loadHTMLString`; every subsequent call swaps the
/// already-loaded `<iframe id="yt">`'s `src` via `eval()` — the mechanism validated
/// by Task 1's `ShortsEmbedSrcSwapSpikeViewModel.swapToNextVideo()`.
///
/// Structurally mirrors `TOSPlayerViewModel` (same JS-bridge architecture, same
/// frame-targeted `eval()` pattern via `embedFrameInfo`), but is a separate type per
/// the design spec's "Code-structure approach" decision — isolation from the
/// production regular-video player in exchange for some duplication.
@MainActor
@Observable
final class ShortsEmbedPlayerViewModel: NSObject {

    // MARK: - Public state

    var playerState: YTPlayerState = .unstarted
    var currentTime: Double = 0
    var duration: Double = 0
    var isReady: Bool = false
    /// Non-nil when the player encounters an error that requires falling back
    /// (e.g. auto-advancing to the next Short — see Task 9).
    var playerError: TOSPlayerError? = nil

    // MARK: - View State
    //
    // Controls visibility, playback-ended state, and lifecycle bookkeeping —
    // surfaced via ShortsEmbedPlayerViewModel+ViewState.swift (Task 9) to give this
    // type the same name-matching surface as PlaybackViewModel, which
    // ShortsPlayerView's shared (non-#if) call sites rely on.

    var controlsVisible: Bool = false
    var videoEnded: Bool = false
    var wasPlayingBeforeSuspend: Bool = false
    var controlsTimer: Task<Void, Never>?
    /// Cancelled once "ready" arrives for the in-flight `loadShort` (see
    /// ShortsEmbedPlayerViewModel+WebBridge.swift's "ready" case); if it fires
    /// first, `playerError` is set to `.webViewLoadFailed` so the new `advanceAfterError()`
    /// (below) can skip to the next Short.
    var readyTimeoutTask: Task<Void, Never>?
    /// Tracks the in-flight SponsorBlock fetch so it can be cancelled on swipe.
    var sponsorTask: Task<Void, Never>?

    // MARK: - SponsorBlock
    //
    // Declared here so Task 4 compiles standalone. Fetch (loadShort → Task 6's
    // fetchSponsorSegments) and tick-driven skip (Task 6's checkSponsorSkip) are
    // wired up by Task 6's edits to this file and to +WebBridge.swift.

    var sponsorSegments: [SponsorSegment] = []
    /// The segment currently showing a skip toast, if any.
    var currentToastSegment: SponsorSegment? = nil
    /// Guards against re-triggering a skip within the same segment.
    var activeSkipEnd: Double? = nil
    /// Bridges an auto-skip's "before" log line to its "after" line — see
    /// `PendingSkipLog` in TOSPlayerViewModel+SponsorBlock.swift (reused as-is).
    var pendingSkipLog: PendingSkipLog? = nil
    var lastLoggedToastSegment: SponsorSegment? = nil
    var lastLoggedNearEndSegment: SponsorSegment? = nil

    // MARK: - Sleep Timer
    //
    // Mirrors TOSPlayerViewModel.swift:92-101 — the sleep timer calls pause() on
    // whatever's playing, so it works automatically once pause() exists below.

    let sleepTimer = SleepTimerController()
    var sleepTimerMinutes: Int? { sleepTimer.sleepTimerMinutes }
    func setSleepTimer(minutes: Int?) {
        sleepTimer.setSleepTimer(minutes: minutes) { [weak self] in
            self?.pause()
            shortsLog.notice("[sleepTimer] fired — pausing playback")
        }
    }

    // MARK: - Dependencies

    private(set) var settings: AppSettings = AppSettings()
    /// Used by `fetchSponsorSegments()` (ShortsEmbedPlayerViewModel+SponsorBlock.swift,
    /// Task 6).
    let sponsorService = SponsorBlockService()
    let api: InnerTubeAPI
    /// Used by `transitionWatchHistory(to:)` (called from `loadShort`, once per
    /// swipe) and `saveProgress()` (called on dismiss) — see
    /// ShortsEmbedPlayerViewModel+WatchHistory.swift, Task 7.
    let tracker: WatchtimeTracker

    // MARK: - Internal

    let webView: WKWebView
    /// Set by `loadShort(video:)`. Read by Task 6's `fetchSponsorSegments()` and
    /// Task 7's watch-history tracking — hence `private(set)`, not `private`.
    private(set) var videoId: String = ""
    /// Used to respect `settings.sponsorBlockExcludedChannels` — read by
    /// `fetchSponsorSegments()` (Task 6).
    private(set) var channelId: String? = nil

    /// Fires the "tickstarted" Darwin notification on the first tick received after
    /// each `loadShort(video:)` call — reset to `false` on every load.
    var hasReceivedFirstTick = false
    /// `false` until the first `loadShort(video:)` call — gates whether `loadShort`
    /// performs the initial `loadHTMLString` (`startEmbed`) or an iframe-src swap
    /// (`swapEmbed`).
    private var hasStarted = false
    /// Strong reference to the WKWebView's navigation delegate (WKWebView retains it
    /// weakly).
    private var navigationDelegate: ShortsNavigationDelegate?

    /// `WKFrameInfo` of the cross-origin YouTube embed `<iframe>` — see
    /// `TOSPlayerViewModel.embedFrameInfo`'s doc comment (TOSPlayerViewModel.swift:161-184)
    /// for the full root-cause story of why `eval()` must target this frame rather
    /// than the wrapper page's main frame. Reset to `nil` on every
    /// `loadShort(video:)` call (each iframe-src swap produces a new frame) and
    /// re-captured from the next "ready" message
    /// (ShortsEmbedPlayerViewModel+WebBridge.swift, Task 5).
    var embedFrameInfo: WKFrameInfo?

    // MARK: - Init

    init(api: InnerTubeAPI) {
        self.api = api
        self.tracker = WatchtimeTracker(api: api)

        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        // CRITICAL on iOS: without this, YouTube's embed hijacks the native system
        // video player when the user taps play — mirrors TOSPlayerViewModel.swift:206-209.
        config.allowsInlineMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        #endif

        let contentController = WKUserContentController()
        let proxyHandler = ShortsScriptMessageProxy()
        contentController.add(proxyHandler, contentWorld: .page, name: "ytCallback")

        contentController.addUserScript(WKUserScript(
            source: ShortsEmbedJS.webkitHiderJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        ))
        contentController.addUserScript(WKUserScript(
            source: ShortsEmbedJS.stateDetectionJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false,
            in: .page
        ))
        config.userContentController = contentController

        self.webView = WKWebView(frame: .zero, configuration: config)
        #if os(iOS)
        self.webView.isOpaque = false
        self.webView.backgroundColor = .clear
        self.webView.scrollView.backgroundColor = .clear
        #endif

        super.init()

        proxyHandler.target = self

        let navDel = ShortsNavigationDelegate()
        self.webView.navigationDelegate = navDel
        self.navigationDelegate = navDel
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "ytCallback",
            contentWorld: .page
        )
    }

    // MARK: - Settings update

    /// Called from `ShortsPlayerView.onAppear`. Mirrors `TOSPlayerViewModel.updateSettings(_:)`.
    func updateSettings(_ newSettings: AppSettings) {
        settings = newSettings
    }

    // MARK: - Loading

    /// Loads `video` into the persistent `WKWebView`. The first call loads the HTML
    /// wrapper page (`startEmbed`); every subsequent call swaps the already-loaded
    /// `<iframe id="yt">`'s `src` (`swapEmbed`) — the mechanism validated by Task 1's
    /// spike. Resets all per-video `@Observable` state before loading, per the design
    /// spec's Data Flow section.
    func loadShort(video: Video) {
        transitionWatchHistory(to: video.id)

        sponsorTask?.cancel()
        sponsorTask = nil

        videoId = video.id
        channelId = video.channelId

        playerState = .unstarted
        currentTime = 0
        duration = 0
        isReady = false
        playerError = nil
        videoEnded = false
        embedFrameInfo = nil
        hasReceivedFirstTick = false
        sponsorSegments = []
        currentToastSegment = nil
        activeSkipEnd = nil
        pendingSkipLog = nil
        lastLoggedToastSegment = nil
        lastLoggedNearEndSegment = nil

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.void.smarttube.shortsplayer.loadstarted" as CFString),
            nil, nil, true
        )

        if hasStarted {
            swapEmbed(to: video.id)
        } else {
            hasStarted = true
            startEmbed(videoId: video.id)
        }

        startReadyTimeout(for: video.id)
    }

    /// First-ever load for this session — loads the HTML wrapper page via
    /// `webView.loadHTMLString`. Mirrors `TOSPlayerViewModel.loadEmbed`
    /// (TOSPlayerViewModel.swift:392-453), using `ShortsEmbedURL` (Task 2) instead of
    /// duplicating the URL/HTML construction.
    private func startEmbed(videoId: String) {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            shortsLog.error("[audioSession] setActive(true) failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
        let url = ShortsEmbedURL.embedURL(videoId: videoId)
        let html = ShortsEmbedURL.htmlWrapper(embedURL: url)
        shortsLog.notice("[loadShort] initial load — videoId=\(videoId, privacy: .public)")
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.example.com")!)
    }

    /// Every load after the first — swaps the already-loaded `<iframe id="yt">`'s
    /// `src` to the new video's embed URL. This is the core mechanic validated by
    /// Task 1's `ShortsEmbedSrcSwapSpikeViewModel.swapToNextVideo()`.
    private func swapEmbed(to videoId: String) {
        let url = ShortsEmbedURL.embedURL(videoId: videoId)
        shortsLog.notice("[loadShort] src swap — videoId=\(videoId, privacy: .public)")
        eval("swap", "document.getElementById('yt').src = '\(url.absoluteString)';")
    }

    /// Starts a 9s timeout for the in-flight `loadShort(video:)` call. Cancelled by
    /// the "ready" case in ShortsEmbedPlayerViewModel+WebBridge.swift once the new
    /// frame reports ready; if it fires first, sets `playerError =
    /// .webViewLoadFailed` so ShortsPlayerView+Navigation.swift's
    /// `advanceAfterError()` can skip to the next Short. Mirrors the design spec's
    /// Error Handling section ("ready" timeout, ~8-10s).
    private func startReadyTimeout(for videoId: String) {
        readyTimeoutTask?.cancel()
        readyTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(9))
            guard let self, !Task.isCancelled else { return }
            guard self.videoId == videoId, !self.isReady else { return }
            shortsLog.notice("[loadShort] ready TIMEOUT — videoId=\(videoId, privacy: .public) after 9s")
            self.playerError = .webViewLoadFailed
        }
    }

    // MARK: - JS Commands (operating on YouTube embed page's <video> element)
    //
    // Identical eval()-based pattern to TOSPlayerViewModel.swift:292-388 — see
    // `embedFrameInfo`'s doc comment for why frame-targeting is required.

    func play() {
        eval("play", "(function(){var v=document.querySelector('video');var ifr=document.querySelectorAll('iframe').length;if(v){v.play();}return {found: !!v, iframes: ifr, paused: v ? v.paused : null};})();")
    }

    /// Stops playback — including audio — regardless of which frame the `<video>`
    /// element lives in. See `TOSPlayerViewModel.pause()`'s doc comment
    /// (TOSPlayerViewModel.swift:296-324) for the cross-origin-iframe root cause this
    /// works around.
    func pause() {
        Task {
            await self.webView.pauseAllMediaPlayback()
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName("com.void.smarttube.shortsplayer.pausedAllMedia" as CFString),
                nil, nil, true
            )
        }
        eval("pause", "(function(){var v=document.querySelector('video');var ifr=document.querySelectorAll('iframe').length;if(v){v.pause();}return {found: !!v, iframes: ifr, paused: v ? v.paused : null};})();")
    }

    func seekTo(_ seconds: Double) {
        eval("seekTo(\(seconds))", "(function(){var v=document.querySelector('video');var ifr=document.querySelectorAll('iframe').length;if(v){v.currentTime=\(seconds);}return {found: !!v, iframes: ifr, currentTime: v ? v.currentTime : null};})();")
    }

    func setPlaybackRate(_ rate: Double) {
        eval("setPlaybackRate(\(rate))", "(function(){var v=document.querySelector('video');var ifr=document.querySelectorAll('iframe').length;if(v){v.playbackRate=\(rate);}return {found: !!v, iframes: ifr, playbackRate: v ? v.playbackRate : null};})();")
    }

    // MARK: - Private helpers

    /// Frame-targeted eval — see `TOSPlayerViewModel.eval`'s doc comment
    /// (TOSPlayerViewModel.swift:363-378).
    private func eval(_ label: String, _ js: String) {
        webView.evaluateJavaScript(js, in: embedFrameInfo, in: .page) { result in
            switch result {
            case .success(let value):
                shortsLog.notice("[eval] \(label, privacy: .public) result: \(String(describing: value), privacy: .public)")
            case .failure(let error):
                shortsLog.notice("[eval] \(label, privacy: .public) ERROR: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

// MARK: - ShortsNavigationDelegate

/// Minimal navigation delegate — logs provisional-navigation failures only. Modeled
/// on Task 1's `SpikeNavigationDelegate`; per-Short "ready"/"tick" notifications
/// (Task 5) already give Task 10's UI test what it needs without porting
/// `TOSNavigationDelegate`'s full set of diagnostic notifications.
private final class ShortsNavigationDelegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        shortsLog.error("[nav] provisional navigation failed: \(error)")
    }
}

// MARK: - ShortsScriptMessageProxy

/// Breaks the retain cycle: `WKUserContentController` retains its handlers strongly.
/// This proxy holds a `weak` reference so `ShortsEmbedPlayerViewModel` is not kept
/// alive by the web view's content controller — mirrors `ScriptMessageProxy` in
/// TOSPlayerViewModel.swift:631-656 / `SpikeScriptMessageProxy` in Task 1.
private final class ShortsScriptMessageProxy: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    weak var target: ShortsEmbedPlayerViewModel?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? String else { return }
        let frameInfo = message.frameInfo
        MainActor.assumeIsolated { [weak target] in
            target?.handleScriptMessage(body, frameInfo: frameInfo)
        }
    }
}
#endif
