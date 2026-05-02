import Foundation
import AVFoundation
import Observation
import os
#if canImport(UIKit)
import UIKit
import MediaPlayer
#endif
import SmartTubeIOSCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - PlaybackViewModel
//
// Manages video playback state and the AVPlayer instance.
// Mirrors the Android `PlaybackPresenter` + `PlayerUIController`.

@MainActor
@Observable
public final class PlaybackViewModel {

    // MARK: - State

    public private(set) var playerInfo: PlayerInfo?
    public private(set) var isLoading: Bool = false
    public private(set) var isPlaying: Bool = false
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var availableFormats: [VideoFormat] = []
    public private(set) var selectedFormat: VideoFormat? = nil
    public private(set) var sponsorSegments: [SponsorSegment] = []
    /// The segment currently under the playhead whose action is `.showToast` (nil otherwise).
    public private(set) var currentToastSegment: SponsorSegment? = nil
    public private(set) var relatedVideos: [Video] = []
    public private(set) var chapters: [Chapter] = []
    public private(set) var hasPrevious: Bool = false
    public private(set) var hasNext: Bool = false
    /// The last stream URL handed to AVPlayer (primary or fallback). Stamped onto
    /// Crashlytics non-fatal reports so the exact URL that failed is visible.
    private var lastAttemptedStreamURL: URL?
    public var error: Error? {
        didSet {
            guard let error else { return }
            let nsError = error as NSError
            playerLog.recordNonFatal(error, userInfo: [
                "video_id":          currentVideo?.id    ?? "unknown",
                "video_title":       currentVideo?.title ?? "unknown",
                "stream_url":        lastAttemptedStreamURL?.absoluteString ?? "none",
                "error_message":     error.localizedDescription,
                "error_domain":      nsError.domain,
                "error_code":        "\(nsError.code)",
                "has_retried":       "\(hasRetriedPlayback)",
                "current_time":      "\(Int(currentTime))s",
            ])
        }
    }
    public var controlsVisible: Bool = false
    /// True while the user is holding a long-press to temporarily boost speed to 2×.
    public private(set) var isHoldingToSpeed: Bool = false
    public private(set) var likeStatus: LikeStatus = .none
    public private(set) var statsForNerdsVisible: Bool = false
    public private(set) var statsSnapshot: StatsForNerdsSnapshot = .empty
    /// End-screen cards to overlay during the final seconds of the video.
    public private(set) var endCards: [EndCard] = []

    // MARK: - Captions

    public private(set) var availableCaptions: [CaptionTrack] = []
    public private(set) var selectedCaption: CaptionTrack? = nil

    // MARK: - Audio tracks

    public private(set) var availableAudioTracks: [AudioTrack] = []
    public private(set) var selectedAudioTrack: AudioTrack? = nil
    /// The caption cue active at the current playhead position (nil when CC is off or no cue matches).
    public private(set) var currentCaptionCue: CaptionCue? = nil

    /// True while the user is dragging the progress slider.
    /// The time observer skips `currentTime` updates while this is set so the
    /// slider thumb doesn't jump back to the real playhead mid-scrub.
    public private(set) var isScrubbing: Bool = false
    /// True if playback was active when `suspend()` was last called.
    /// Used by `PlayerView.onAppear` to decide whether to resume after a
    /// sheet dismissal — prevents overriding an intentional user pause.
    public private(set) var wasPlayingBeforeSuspend: Bool = false
    /// Position tracked during a scrub drag; committed to AVPlayer on release.
    public private(set) var scrubTime: TimeInterval = 0

    /// The chapter whose start time is closest-but-not-greater-than `currentTime`.
    /// Nil when no chapters are available or the video hasn't started.
    public var currentChapter: Chapter? {
        guard !chapters.isEmpty else { return nil }
        return chapters.last(where: { $0.startTime <= currentTime })
    }

    /// True when there is a chapter ahead of the current playhead position.
    public var hasNextChapter: Bool {
        chapters.contains { $0.startTime > currentTime }
    }

    /// True when the playhead can be moved backward to a chapter boundary —
    /// either to the start of the current chapter (if >3 s in) or to the previous one.
    public var hasPreviousChapter: Bool {
        guard let current = currentChapter else { return false }
        if currentTime - current.startTime > 3 { return true }
        return chapters.contains { $0.startTime < current.startTime }
    }

    /// True when at least one VIDEO end card is within its display window at the current playhead.
    /// Used by `PlayerView` to suppress swipe-overlay tap-to-toggle-controls so taps land on cards.
    public var hasVisibleEndCards: Bool {
        let ms = Int(currentTime * 1000)
        return endCards.contains { $0.style == .video && $0.videoId != nil && ms >= $0.startMs && ms <= $0.endMs }
    }

    // MARK: - History

    /// Videos played before the current one (oldest first).
    private var history: [Video] = []
    /// The video currently loaded (nil before first load).
    private var currentVideo: Video? = nil

    // MARK: - AVPlayer

    public let player = AVPlayer()
    @ObservationIgnored nonisolated(unsafe) private var timeObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var audioSessionObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var rateObserver: NSKeyValueObservation?
    /// Prevents infinite retry loops: set once the first fallback attempt has been made.
    private var hasRetriedPlayback: Bool = false
    /// True while a SponsorBlock auto-skip seek is in-flight. Guards against the periodic
    /// time observer re-triggering `checkSponsorSkip` before the seek completes, which
    /// causes the end-of-video twitch / audio loop.
    private var isSkippingSegment: Bool = false
    private var itemObserverTask: Task<Void, Never>?
    private var endObserverTask: Task<Void, Never>?
    private var controlsTimer: Task<Void, Never>?
    @ObservationIgnored private var sleepTimerTask: Task<Void, Never>?
    /// Remaining minutes on the sleep timer (nil = off). Observable so PlayerView can show it.
    public private(set) var sleepTimerMinutes: Int? = nil
    /// Available sleep timer durations in minutes.
    public static let sleepTimerOptions: [Int] = [15, 30, 45, 60]
    /// Position to seek to once the AVPlayerItem is ready.
    private var savedPositionToRestore: TimeInterval? = nil
    /// Manages watch-history state: position saving, playback-started ping,
    /// and watchtime segment reporting. See WatchtimeTracker.
    private var tracker: WatchtimeTracker

    // AVMediaSelectionGroup for audio — not Sendable, kept nonisolated(unsafe) and only
    // accessed from MainActor context (Task { [weak self] in ... } on the main actor).
    @ObservationIgnored nonisolated(unsafe) private var audioSelectionGroup: AVMediaSelectionGroup? = nil
    @ObservationIgnored private var audioOptionsByID: [String: AVMediaSelectionOption] = [:]

    // Caption cues loaded for the currently selected track
    private var captionCues: [CaptionCue] = []
    @ObservationIgnored private var captionFetchTask: Task<Void, Never>? = nil
    /// Timestamp of the last commitScrub(). Used to ignore the spurious
    /// beginScrubbing() that SwiftUI's Slider fires immediately after commitScrub
    /// causes a binding re-evaluation and the slider thumb re-positions itself.
    var lastCommitScrubTime: Date = .distantPast
    /// Debounce task for preview seeks while dragging the slider.
    /// Fires a seek after the thumb has been held still for 300 ms.
    private var seekDebounceTask: Task<Void, Never>?
    /// Tracks the in-flight loadAsync so it can be cancelled if load() is called again.
    private var loadTask: Task<Void, Never>?

    // MARK: - Now Playing cache
    // Never read nowPlayingInfo back from MPNowPlayingInfoCenter — doing a
    // read-modify-write while MediaPlayer is processing on its accessQueue
    // causes EXC_BREAKPOINT. Mirror the dict locally instead.
    @ObservationIgnored private var nowPlayingInfoCache: [String: Any] = [:]

    // MARK: - Dependencies

    private let api: InnerTubeAPI
    private let sponsorBlock: SponsorBlockService
    private let deArrow: DeArrowService
    private var settings: AppSettings
    private var hasAuthToken: Bool = false
    private var currentAuthToken: String? = nil

    public init(
        api: InnerTubeAPI = InnerTubeAPI(),
        sponsorBlock: SponsorBlockService = SponsorBlockService(),
        deArrow: DeArrowService = DeArrowService(),
        settings: AppSettings = AppSettings()
    ) {
        self.api = api
        self.tracker = WatchtimeTracker(api: api)
        self.sponsorBlock = sponsorBlock
        self.deArrow = deArrow
        self.settings = settings
        #if canImport(UIKit)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            playerLog.error("AVAudioSession setup failed: \(error.localizedDescription)")
        }
        #endif
        setupTimeObserver()
        setupRateObserver()
        #if canImport(UIKit)
        setupRemoteCommandCenter()
        setupAudioSessionObserver()
        #endif
    }

    deinit {
        if let obs = timeObserver { player.removeTimeObserver(obs) }
        rateObserver?.invalidate()
    }

    // MARK: - Load video

    /// The ID of the video currently loaded (or being loaded). Exposed so PlayerView
    /// can detect spurious onAppear/onDisappear cycles (e.g. when a ShareLink sheet
    /// temporarily covers the player) and skip unnecessary reloads.
    public var currentVideoId: String? { currentVideo?.id }

    public func load(video: Video) {
        playerLog.notice("[load] load() called — id=\(video.id) currentVideo=\(self.currentVideo?.id ?? "nil") isLoading=\(self.isLoading)")
        CrashlyticsLogger.setVideoContext(id: video.id, title: video.title)
        // Cancel any previous in-flight load so we never have two concurrent API
        // fetches for the same (or different) video running at the same time.
        loadTask?.cancel()

        // Report watchtime for the video being replaced before tearing it down.
        // This is the only opportunity when switching via load() directly (e.g. autoplay),
        // since stop()/suspend() are not called in that path.
        if settings.historyState == .enabled, duration > 0 {
            let pos = self.currentTime
            let dur = self.duration
            let flush = tracker.transition(to: video.id, cpn: InnerTubeAPI.generateCPN(),
                                           flushPosition: pos, flushDuration: dur)
            Task { await flush() }
        } else {
            tracker.transition(to: video.id, cpn: InnerTubeAPI.generateCPN(),
                               flushPosition: 0, flushDuration: 0)
        }

        // Stop and clear the current item immediately so the previous frame
        // is not visible while the next video is loading.
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        wasPlayingBeforeSuspend = false
        currentTime = 0
        duration = 0
        error = nil
        controlsVisible = false
        controlsTimer?.cancel()
        seekDebounceTask?.cancel()
        isScrubbing = false
        chapters = []
        availableCaptions = []
        selectedCaption = nil
        currentCaptionCue = nil
        captionCues = []
        captionFetchTask?.cancel()
        captionFetchTask = nil
        availableAudioTracks = []
        selectedAudioTrack = nil
        audioSelectionGroup = nil
        audioOptionsByID = [:]
        endCards = []

        // Push the currently playing video onto the history stack before switching
        if let prev = currentVideo {
            history.append(prev)
        }
        currentVideo = video
        hasPrevious = !history.isEmpty
        hasRetriedPlayback = false
        loadTask = Task { await loadAsync(video: video) }
    }

    /// Call when the app returns to the foreground and this PlayerView is the visible one.
    /// Reactivates the AVAudioSession and resumes the player if it was playing
    /// before the interruption/background transition.
    public func handleForeground() {
        guard player.currentItem != nil else { return }
        #if canImport(UIKit)
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            playerLog.error("AVAudioSession reactivation failed: \(error.localizedDescription)")
        }
        #endif
        // Resume only if we consider ourselves to be in playing state.
        // isPlaying is kept in sync with player.rate via KVO, so this only fires
        // when the player was paused while still intending to play (e.g. background transition).
        if isPlaying && player.rate == 0 {
            player.rate = Float(settings.playbackSpeed)
            playerLog.notice("[handleForeground] resumed player after foreground transition")
        }
    }

    /// Call when the app enters the background.
    /// Pauses playback when the user has disabled background audio.
    public func handleBackground() {
        guard !settings.backgroundPlaybackEnabled else { return }
        guard isPlaying else { return }
        player.pause()
        // isPlaying is synced to false by the rate KVO observer.
        playerLog.notice("[handleBackground] background playback disabled — paused")
    }

    /// Pauses playback and saves the watch position without tearing down the AVPlayerItem.
    /// Called when the PlayerView temporarily disappears (e.g. a sheet slides over it).
    /// Use `resume()` to restart playback, or `load(video:)` to switch videos.
    public func suspend() {
        playerLog.notice("[suspend] suspend() called — currentVideo=\(self.currentVideo?.id ?? "nil") currentTime=\(Int(self.currentTime))s")
        if settings.historyState == .enabled, duration > 0 {
            let pos = self.currentTime
            let dur = self.duration
            Task {
                await self.tracker.checkpoint(position: pos, duration: dur)
                playerLog.notice("Saved position \(Int(pos))s for suspend")
            }
        }
        wasPlayingBeforeSuspend = isPlaying
        player.pause()
        isPlaying = false
        controlsTimer?.cancel()
        #if canImport(UIKit)
        updateNowPlayingPlayback()
        #endif
    }

    /// Resumes playback after a `suspend()`. If the player has no current item
    /// (e.g. `stop()` was called), this is a no-op — use `load(video:)` instead.
    public func resume() {
        guard player.currentItem != nil else {
            playerLog.notice("[resume] no item — skipping resume")
            return
        }
        playerLog.notice("[resume] resume() called — currentVideo=\(self.currentVideo?.id ?? "nil")")
        wasPlayingBeforeSuspend = false
        player.rate = Float(settings.playbackSpeed)
        isPlaying = true
        showControls()
        #if canImport(UIKit)
        updateNowPlayingPlayback()
        #endif
    }

    private func loadAsync(video: Video) async {
        isLoading = true
        defer { isLoading = false }
        playerLog.notice("load video id=\(video.id) title=\(video.title)")
        do {
            // --- Cache-first load ---
            // Check VideoPreloadCache for all data types. Fresh hits skip the network
            // call entirely; partial hits fill only the missing pieces in parallel.
            let cached = await VideoPreloadCache.shared.consume(videoId: video.id)
            playerLog.notice("cache: playerInfo=\(cached.playerInfo != nil) nextInfo=\(cached.nextInfo != nil) sponsor=\(cached.sponsorSegments != nil) endCards=\(cached.endCards != nil) tracking=\(cached.trackingURLs != nil)")

            // --- Player info (stream URLs + metadata) ---
            // Kick off an authenticated TV-client player request in parallel with the
            // primary iOS player fetch when the cache doesn't already have tracking URLs.
            // cached.trackingURLs is PlaybackTrackingURLs?? — .some(nil) means the prefetch
            // ran before auth was ready; treat that as a miss so we still get live URLs.
            let cachedTrackingURLs: PlaybackTrackingURLs? = cached.trackingURLs.flatMap { $0 }
            let authTrackingTask: Task<PlaybackTrackingURLs?, Never>?
            if cachedTrackingURLs != nil {
                // Tracking URLs came from the cache; no need for a parallel TV-client call.
                authTrackingTask = nil
            } else {
                authTrackingTask = Task<PlaybackTrackingURLs?, Never> { [api = self.api] in
                    await api.fetchAuthenticatedTrackingURLs(videoId: video.id)
                }
            }

            // Fetch player info using the iOS client (unauthenticated).
            // If YouTube returns UNPLAYABLE/LOGIN_REQUIRED and the user is signed in,
            // automatically retry with the authenticated TV client before showing an error.
            let info: PlayerInfo
            if let cachedInfo = cached.playerInfo {
                playerLog.notice("cache HIT: playerInfo (skipping network)")
                info = cachedInfo
            } else {
                do {
                    info = try await api.fetchPlayerInfo(videoId: video.id)
                } catch {
                    if case APIError.unavailable = error, hasAuthToken {
                        playerLog.notice("⚠️ iOS client returned unavailable — retrying with authenticated TV client")
                        info = try await api.fetchPlayerInfoAuthenticated(videoId: video.id)
                    } else {
                        throw error
                    }
                }
                await VideoPreloadCache.shared.store(playerInfo: info, for: video.id)
            }
            playerInfo = info
            availableFormats = Self.deduplicatedVideoFormats(info.formats)
            availableCaptions = info.captionTracks
            selectedFormat = nil

            playerLog.notice("playerInfo: formats=\(info.formats.count) hlsURL=\(info.hlsURL?.absoluteString ?? "nil") dashURL=\(info.dashURL?.absoluteString ?? "nil")")
            for (i, fmt) in info.formats.enumerated() {
                playerLog.notice("  format[\(i)] mimeType=\(fmt.mimeType) quality=\(fmt.label) url=\(fmt.url?.absoluteString.prefix(80) ?? "nil")")
            }

            let prefURL = info.preferredStreamURL
            playerLog.notice("preferredStreamURL=\(prefURL?.absoluteString.prefix(120) ?? "nil")")

            // --- SponsorBlock ---
            let channelIsExcluded = video.channelId.map {
                settings.sponsorBlockExcludedChannels.keys.contains($0)
            } ?? false
            if settings.sponsorBlockEnabled, !channelIsExcluded {
                var segments: [SponsorSegment]
                if let cachedSegments = cached.sponsorSegments {
                    playerLog.notice("cache HIT: sponsorSegments (skipping network)")
                    segments = cachedSegments
                } else {
                    segments = await sponsorBlock.fetchSegments(
                        videoId: video.id,
                        categories: settings.activeSponsorCategories
                    )
                    await VideoPreloadCache.shared.store(sponsorSegments: segments, for: video.id)
                }
                let minDur = settings.sponsorBlockMinSegmentDuration
                if minDur > 0 {
                    segments = segments.filter { ($0.end - $0.start) >= minDur }
                }
                sponsorSegments = segments
            }

            // --- Related videos + like status ---
            let nextInfo: NextInfo?
            if let cachedNext = cached.nextInfo {
                playerLog.notice("cache HIT: nextInfo (skipping network)")
                nextInfo = cachedNext
            } else {
                nextInfo = try? await api.fetchNextInfo(videoId: video.id)
                if let nextInfo { await VideoPreloadCache.shared.store(nextInfo: nextInfo, for: video.id) }
            }

            if let nextInfo, !nextInfo.relatedVideos.isEmpty {
                relatedVideos = nextInfo.relatedVideos.filter { $0.id != video.id }
                hasNext = !relatedVideos.isEmpty
            } else {
                // Fallback to search if /next returns nothing.
                // Use video.title (from the original Video parameter) — info.video.title
                // can be empty for ads/unplayable content where videoDetails is sparse.
                let fallbackQuery = video.title.isEmpty ? nil : video.title
                if let query = fallbackQuery {
                    let searched = try? await api.search(query: query)
                    relatedVideos = searched?.videos.filter { $0.id != video.id }.prefix(InnerTubeClients.maxVideoResults).map { $0 } ?? []
                    hasNext = !relatedVideos.isEmpty
                }
            }
            // Apply like status returned from the authenticated /next call
            if let status = nextInfo?.likeStatus { likeStatus = status }
            if let ch = nextInfo?.chapters, !ch.isEmpty { chapters = ch }

            // --- End cards ---
            if let cachedCards = cached.endCards {
                playerLog.notice("cache HIT: endCards (skipping network)")
                endCards = cachedCards
            } else if !info.endCards.isEmpty {
                endCards = info.endCards
                playerLog.notice("endCards: \(info.endCards.count) from primary response")
                await VideoPreloadCache.shared.store(endCards: info.endCards, for: video.id)
            } else {
                do {
                    let webCards = try await api.fetchEndCards(videoId: video.id)
                    endCards = webCards
                    playerLog.notice("endCards: \(webCards.count) from web client fallback")
                    await VideoPreloadCache.shared.store(endCards: webCards, for: video.id)
                } catch {
                    playerLog.error("endCards fetch failed: \(error.localizedDescription)")
                    endCards = []
                }
            }

            // --- Kick off neighbour pre-fetch now that relatedVideos is populated ---
            let neighbourIds = Array(relatedVideos.prefix(3).map(\.id))
            let prefetchToken = currentAuthToken
            let sponsorCats = settings.activeSponsorCategories
            Task(priority: .background) {
                for videoId in neighbourIds {
                    await VideoPreloadCache.shared.prefetch(
                        videoId: videoId,
                        sponsorCategories: sponsorCats,
                        authToken: prefetchToken
                    )
                }
            }

            // Restore saved watch position (mirrors VideoStateController)
            let savedState = await VideoStateStore.shared.state(for: video.id)
            if let pos = savedState?.position, pos > 5 {
                savedPositionToRestore = pos
                playerLog.notice("Restoring position \(Int(pos))s for \(video.id)")
            }

            // --- Tracking URLs ---
            // Prefer account-bound TV-client URLs over the anonymous iOS-client URLs.
            // Use the cached value if present; otherwise await the parallel task result.
            let resolvedTrackingURLs: PlaybackTrackingURLs?
            if let cachedTracking = cachedTrackingURLs {
                resolvedTrackingURLs = cachedTracking
                playerLog.notice("cache HIT: trackingURLs")
            } else {
                resolvedTrackingURLs = await authTrackingTask?.value ?? info.trackingURLs
                await VideoPreloadCache.shared.store(trackingURLs: resolvedTrackingURLs, for: video.id)
            }
            tracker.setTrackingURLs(resolvedTrackingURLs)
            playerLog.notice("activeTrackingURLs resolved: \(resolvedTrackingURLs != nil ? "account-bound" : "none")")
            // Build player item — preferredStreamURL is guaranteed non-nil here because
            // parsePlayerInfo throws APIError.unavailable when streamingData is absent.
            guard let streamURL = info.preferredStreamURL else {
                playerLog.error("❌ No stream URL after successful parse (should not happen)")
                throw APIError.decodingError("No stream URL")
            }
            playerLog.notice("Starting AVPlayer with: \(streamURL.absoluteString.prefix(120))")
            lastAttemptedStreamURL = streamURL
            // YouTube HLS manifest URLs require the YouTube iOS app User-Agent to be sent
            // in the fetch request. AVPlayer's default `AppleCoreMedia/x.x.x` User-Agent
            // causes YouTube to return HTTP 404 immediately for the variant manifest.
            // Injecting the correct User-Agent via AVURLAsset fixes this.
            let playerAsset = AVURLAsset(
                url: streamURL,
                options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": InnerTubeClients.iOS.userAgent]]
            )
            let item = AVPlayerItem(asset: playerAsset)
            // Apply resolution cap using preferredMaximumResolution on the HLS adaptive stream.
            // This avoids HTTP 403 errors that occur when playing video-only adaptive URLs directly.
            if settings.preferredQuality != .auto, let maxH = settings.preferredQuality.maxHeight {
                let h = CGFloat(maxH)
                item.preferredMaximumResolution = CGSize(width: h * 4, height: h)
                selectedFormat = availableFormats.first { $0.height <= maxH }
                let qualityLabel = settings.preferredQuality.rawValue
                playerLog.notice("Quality cap \(qualityLabel) via preferredMaximumResolution")
            }
            // Observe item status using async/await (withCheckedContinuation is not needed
            // here since we only need to react to status changes, not await them).
            itemObserverTask?.cancel()
            itemObserverTask = Task { [weak self] in
                for await status in item.statusStream {
                    guard let self, !Task.isCancelled else { return }
                    switch status {
                    case .readyToPlay:
                        playerLog.notice("✅ AVPlayerItem readyToPlay")
                        if let pos = self.savedPositionToRestore, pos > 0 {
                            self.savedPositionToRestore = nil
                            self.seek(to: pos)
                        }
                        // Load alternate audio renditions (dubbed / translated tracks).
                        self.loadAudioTracks(from: item)
                    case .failed:
                        let err = item.error.map { "\($0)" } ?? "nil"
                        playerLog.error("❌ AVPlayerItem failed: \(err)")
                        if !self.hasRetriedPlayback, let video = self.currentVideo {
                            self.hasRetriedPlayback = true
                            Task { await self.retryWithFallbackPlayer(video: video, originalError: item.error) }
                        } else {
                            self.error = item.error
                        }
                    case .unknown:
                        playerLog.notice("AVPlayerItem status: unknown (loading)")
                    @unknown default:
                        break
                    }
                }
            }
            player.replaceCurrentItem(with: item)
            duration = info.video.duration ?? 0

            // Observe end-of-item using NotificationCenter async sequence
            endObserverTask?.cancel()
            endObserverTask = Task { [weak self] in
                let notifications = NotificationCenter.default.notifications(
                    named: AVPlayerItem.didPlayToEndTimeNotification,
                    object: item
                )
                for await _ in notifications {
                    guard let self, !Task.isCancelled else { return }
                    self.handlePlaybackEnd()
                }
            }

            player.rate = Float(settings.playbackSpeed)
            isPlaying = true
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = true
            updateNowPlayingInfo()
            #endif
            scheduleControlsHide()
        } catch {
            playerLog.error("❌ loadAsync error: \(String(describing: error))")
            self.error = error
        }
    }

    // MARK: - Playback fallback

    /// Called when the primary iOS-client HLS stream fails to open.
    /// Re-fetches using the Android InnerTube client, which returns direct CDN videoplayback
    /// URLs instead of an IP-bound HLS manifest. YouTube's iOS-client HLS manifests embed
    /// the requester's IP; on the iOS Simulator AVPlayer's download IP can differ from the
    /// URLSession IP used by InnerTubeAPI, causing a 404. Android-client URLs are signed with
    /// Android credentials and are not subject to the same IP-binding restriction.
    /// Shows the original error if the Android-client fallback also fails.
    private func retryWithFallbackPlayer(video: Video, originalError: Error?) async {
        do {
            playerLog.notice("Retrying playback with Android client for \(video.id)")
            let fallbackInfo = try await api.fetchPlayerInfoAndroid(videoId: video.id)
            guard let fallbackURL = fallbackInfo.preferredStreamURL else {
                playerLog.error("❌ Fallback player: no stream URL")
                self.error = originalError
                return
            }
            playerLog.notice("Fallback stream URL: \(fallbackURL.absoluteString.prefix(120))")
            lastAttemptedStreamURL = fallbackURL
            let fallbackItem = AVPlayerItem(url: fallbackURL)
            itemObserverTask?.cancel()
            itemObserverTask = Task { [weak self] in
                for await status in fallbackItem.statusStream {
                    guard let self, !Task.isCancelled else { return }
                    switch status {
                    case .readyToPlay:
                        playerLog.notice("✅ Fallback AVPlayerItem readyToPlay")
                        if let pos = self.savedPositionToRestore, pos > 0 {
                            self.savedPositionToRestore = nil
                            self.seek(to: pos)
                        }
                    case .failed:
                        let err = fallbackItem.error.map { "\($0)" } ?? "nil"
                        playerLog.error("❌ Fallback AVPlayerItem failed: \(err)")
                        self.error = fallbackItem.error ?? originalError
                    case .unknown:
                        break
                    @unknown default:
                        break
                    }
                }
            }
            player.replaceCurrentItem(with: fallbackItem)
            player.rate = Float(settings.playbackSpeed)
            isPlaying = true
        } catch {
            playerLog.error("❌ Fallback player fetch failed: \(String(describing: error))")
            self.error = originalError
        }
    }

    // MARK: - Autoplay

    public func updateSettings(_ newSettings: AppSettings) {
        settings = newSettings
    }

    // MARK: - Sleep Timer

    /// Activates (or cancels) the sleep timer.
    /// - Parameter minutes: Nil cancels any running timer; a positive value starts a new countdown.
    public func setSleepTimer(minutes: Int?) {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerMinutes = minutes
        guard let minutes else { return }
        sleepTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard let self, !Task.isCancelled else { return }
            self.player.pause()
            self.isPlaying = false
            self.sleepTimerMinutes = nil
        }
    }

    // MARK: - Auth

    /// Updates the local auth flag used for LOGIN_REQUIRED retry logic.
    /// The shared InnerTubeAPI instance already carries the updated token.
    public func updateAuthToken(_ token: String?) {
        let wasAuthenticated = hasAuthToken
        hasAuthToken = token != nil
        currentAuthToken = token
        // Keep the cache's InnerTubeAPI instance in sync so prefetch requests
        // can make authenticated calls (e.g. fetchAuthenticatedTrackingURLs).
        Task { await VideoPreloadCache.shared.setAuthToken(token) }
        if wasAuthenticated, token == nil {
            // Signed out: evict account-bound cache data
            Task { await VideoPreloadCache.shared.evictAuthSensitiveData() }
        } else if wasAuthenticated, token != nil {
            // Token refreshed: tracking URLs bound to the old token are stale
            Task { await VideoPreloadCache.shared.evictTrackingURLs() }
        }
    }

    // MARK: - Stats for Nerds

    public func toggleStatsForNerds() {
        statsForNerdsVisible.toggle()
        if statsForNerdsVisible { updateStatsSnapshot() }
    }

    private func updateStatsSnapshot() {
        guard let item = player.currentItem else {
            statsSnapshot = .empty
            return
        }
        let logEvent = item.accessLog()?.events.last
        let videoId = playerInfo?.video.id ?? currentVideo?.id ?? ""

        // Resolution – prefer actual presentation size, fall back to format metadata
        let presentationSize = item.presentationSize
        let res: String
        if presentationSize.width > 0 && presentationSize.height > 0 {
            res = "\(Int(presentationSize.width))×\(Int(presentationSize.height))"
        } else if let fmt = selectedFormat, fmt.height > 0 {
            res = fmt.width > 0 ? "\(fmt.width)×\(fmt.height)" : "\(fmt.height)p"
        } else {
            res = "—"
        }

        let fps = selectedFormat?.fps ?? 0

        // Codec: if a format is manually selected use its mimeType; otherwise
        // reflect the adaptive stream type (HLS / DASH) or fallback to the
        // best available progressive format.
        let codec: String
        if let fmt = selectedFormat {
            codec = Self.extractCodec(from: fmt.mimeType)
        } else if playerInfo?.hlsURL != nil {
            codec = "HLS"
        } else if playerInfo?.dashURL != nil {
            codec = "DASH"
        } else if let fmt = playerInfo?.formats.first {
            codec = Self.extractCodec(from: fmt.mimeType)
        } else {
            codec = "—"
        }

        let nominalBitrate: String
        if let br = selectedFormat?.bitrate, br > 0 {
            nominalBitrate = Self.formatBitrate(br)
        } else if playerInfo?.hlsURL != nil || playerInfo?.dashURL != nil {
            nominalBitrate = "Adaptive"
        } else if let br = playerInfo?.formats.first?.bitrate, br > 0 {
            nominalBitrate = Self.formatBitrate(br)
        } else {
            nominalBitrate = "—"
        }

        let observedBitrate: String
        if let br = logEvent?.observedBitrate, br > 0 {
            observedBitrate = Self.formatBitrate(Int(br))
        } else {
            observedBitrate = "—"
        }

        let droppedFrames = logEvent.map { $0.numberOfDroppedVideoFrames } ?? 0
        let stalls = logEvent.map { $0.numberOfStalls } ?? 0

        statsSnapshot = StatsForNerdsSnapshot(
            videoId: videoId,
            displayResolution: res,
            fps: fps,
            codec: codec,
            nominalBitrate: nominalBitrate,
            observedBitrate: observedBitrate,
            droppedFrames: droppedFrames,
            stalls: stalls
        )
    }

    private static func extractCodec(from mimeType: String) -> String {
        if mimeType.contains("mpegURL") || mimeType.contains("m3u8") { return "HLS" }
        if let range = mimeType.range(of: #"codecs="([^"]+)""#, options: .regularExpression) {
            let matched = String(mimeType[range])
            if let valueRange = matched.range(of: #"(?<==)[^"]+"#, options: .regularExpression) {
                let codecs = String(matched[valueRange])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let first = codecs.components(separatedBy: ",").first?
                    .trimmingCharacters(in: .whitespaces) ?? codecs
                return first.components(separatedBy: ".").first ?? first
            }
        }
        if mimeType.contains("mp4")  { return "mp4" }
        if mimeType.contains("webm") { return "webm" }
        return mimeType.isEmpty ? "—" : mimeType
    }

    private static func formatBitrate(_ bps: Int) -> String {
        if bps >= 1_000_000 { return String(format: "%.1f Mbps", Double(bps) / 1_000_000) }
        if bps >= 1_000     { return String(format: "%.0f kbps", Double(bps) / 1_000) }
        return "\(bps) bps"
    }

    // MARK: - Like / Dislike

    /// Toggles the like state for the current video (optimistic update; rolls back on failure).
    public func like() {
        guard let videoId = currentVideo?.id else { return }
        let prev = likeStatus
        likeStatus = prev == .like ? .none : .like
        Task {
            do {
                if prev == .like {
                    try await api.removeLike(videoId: videoId)
                } else {
                    try await api.like(videoId: videoId)
                }
            } catch {
                self.likeStatus = prev
                playerLog.error("like failed: \(String(describing: error))")
            }
        }
    }

    /// Toggles the dislike state for the current video (optimistic update; rolls back on failure).
    public func dislike() {
        guard let videoId = currentVideo?.id else { return }
        let prev = likeStatus
        likeStatus = prev == .dislike ? .none : .dislike
        Task {
            do {
                if prev == .dislike {
                    try await api.removeLike(videoId: videoId)
                } else {
                    try await api.dislike(videoId: videoId)
                }
            } catch {
                self.likeStatus = prev
                playerLog.error("dislike failed: \(String(describing: error))")
            }
        }
    }

    /// Switch to a specific quality. Pass `nil` to return to Auto (no resolution cap).
    /// Sets `preferredMaximumResolution` on the active HLS item instead of switching to a
    /// direct adaptive URL — avoids HTTP 403 errors from video-only adaptive streams.
    public func selectFormat(_ format: VideoFormat?) {
        selectedFormat = format
        if let h = format.map({ CGFloat($0.height) }), h > 0 {
            player.currentItem?.preferredMaximumResolution = CGSize(width: h * 4, height: h)
        } else {
            player.currentItem?.preferredMaximumResolution = .zero
        }
        playerLog.notice("Quality → \(format?.qualityLabel ?? "Auto")")
    }

    // MARK: - Captions

    /// Selects a caption track and fetches its VTT cues. Pass `nil` to disable captions.
    public func selectCaption(_ track: CaptionTrack?) {
        selectedCaption = track
        currentCaptionCue = nil
        captionCues = []
        captionFetchTask?.cancel()
        captionFetchTask = nil
        guard let track else { return }
        captionFetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let parser = WebVTTParser()
                let cues = try await parser.fetchCues(from: track.baseURL)
                guard !Task.isCancelled else { return }
                self.captionCues = cues
                self.updateCaptionCue(for: self.currentTime)
                playerLog.notice("Loaded \(cues.count) cues for track \(track.id)")
            } catch {
                playerLog.error("Caption fetch failed for \(track.id): \(String(describing: error))")
            }
        }
    }

    private func updateCaptionCue(for time: TimeInterval) {
        guard !captionCues.isEmpty else { currentCaptionCue = nil; return }
        currentCaptionCue = captionCues.last(where: { $0.startTime <= time && $0.endTime > time })
    }

    // MARK: - Audio track selection

    /// Switches to `track`, or resets to the HLS default when `nil`.
    /// Persists the language code in `AppSettings` so subsequent videos auto-apply the preference.
    public func selectAudioTrack(_ track: AudioTrack?) {
        selectedAudioTrack = track
        settings.preferredAudioLanguage = track?.languageCode  // nil clears the preference
        guard let item = player.currentItem, let group = audioSelectionGroup else { return }
        if let track, let option = audioOptionsByID[track.id] {
            item.select(option, in: group)
        } else {
            item.selectMediaOptionAutomatically(in: group)
        }
        playerLog.notice("Audio → \(track?.name ?? "Auto (preference cleared)")")
    }

    /// Loads alternate audio renditions from the HLS manifest of `item` and auto-applies
    /// the user's saved language preference. No-ops when the manifest has ≤ 1 rendition.
    private func loadAudioTracks(from item: AVPlayerItem) {
        Task { [weak self] in
            guard let self else { return }
            let asset = item.asset
            guard let group = try? await asset.loadMediaSelectionGroup(for: .audible),
                  group.options.count > 1 else { return }
            let currentSelection = await item.currentMediaSelection
            var tracks: [AudioTrack] = []
            var optionMap: [String: AVMediaSelectionOption] = [:]
            for option in group.options {
                let locale = option.locale?.identifier
                    ?? option.extendedLanguageTag
                    ?? "unknown"
                let displayName = option.locale.flatMap {
                    Locale.current.localizedString(forLanguageCode: $0.identifier)
                } ?? locale
                let isDefault = currentSelection.selectedMediaOption(in: group) == option
                let track = AudioTrack(id: locale, name: displayName,
                                       languageCode: locale, isOriginal: isDefault)
                tracks.append(track)
                optionMap[locale] = option
            }
            self.audioSelectionGroup = group
            self.audioOptionsByID = optionMap
            self.availableAudioTracks = tracks

            // Auto-apply the user's saved language preference (fuzzy-match on base language).
            let preferred = self.settings.preferredAudioLanguage
            let autoSelect: AudioTrack? = {
                guard let lang = preferred else { return tracks.first(where: \.isOriginal) }
                if let exact = tracks.first(where: { $0.languageCode == lang }) { return exact }
                let base = lang.components(separatedBy: "-").first ?? lang
                return tracks.first(where: { $0.languageCode.hasPrefix(base) })
                    ?? tracks.first(where: \.isOriginal)
            }()
            self.selectedAudioTrack = autoSelect
            if let autoSelect, let option = optionMap[autoSelect.id],
               autoSelect.id != tracks.first(where: \.isOriginal)?.id {
                item.select(option, in: group)
            }
            playerLog.notice("Audio tracks: \(tracks.map(\.name).joined(separator: ", ")) — auto-selected: \(autoSelect?.name ?? "default")")
        }
    }

    private static func deduplicatedVideoFormats(_ formats: [VideoFormat]) -> [VideoFormat] {
        let candidates = formats.filter { $0.url != nil && $0.height > 0 }
        var seen = Set<String>()
        var result: [VideoFormat] = []
        for fmt in candidates.sorted(by: {
            if $0.height != $1.height { return $0.height > $1.height }
            if $0.fps != $1.fps { return $0.fps > $1.fps }
            return ($0.bitrate ?? 0) > ($1.bitrate ?? 0)
        }) {
            let key = "\(fmt.height):\(fmt.fps)"
            if !seen.contains(key) {
                seen.insert(key)
                result.append(fmt)
            }
        }
        return result
    }

    /// Play the next related video (first in the suggestions list).
    public func playNext() {
        guard let next = relatedVideos.first else { return }
        playerLog.notice("playNext: id=\(next.id)")
        load(video: next)
    }

    /// Play the most recently played video from the history stack.
    /// Pops the last entry from history; load() will push the current video back so
    /// the user can navigate forward again with playNext() or via suggestions.
    public func playPrevious() {
        guard !history.isEmpty else { return }
        let prev = history.removeLast()
        hasPrevious = !history.isEmpty
        playerLog.notice("playPrevious: id=\(prev.id)")
        load(video: prev)
    }

    private func handlePlaybackEnd() {
        if settings.loopEnabled {
            player.seek(to: .zero)
            player.rate = Float(settings.playbackSpeed)
            return
        }
        if settings.shuffleEnabled, !relatedVideos.isEmpty {
            let pick = relatedVideos[Int.random(in: 0..<relatedVideos.count)]
            playerLog.notice("Shuffle: loading id=\(pick.id)")
            load(video: pick)
            return
        }
        guard settings.autoplayEnabled, let next = relatedVideos.first else { return }
        playerLog.notice("Autoplay: loading next video id=\(next.id)")
        load(video: next)
    }

    // MARK: - Playback controls

    public func togglePlayPause() {
        if isPlaying { player.pause() } else { player.rate = Float(settings.playbackSpeed) }
        isPlaying.toggle()
        showControls()
        #if canImport(UIKit)
        updateNowPlayingPlayback()
        #endif
    }

    // MARK: - Scrubbing (slider drag)

    /// Called when the user starts dragging the progress slider.
    public func beginScrubbing() {
        // Guard against the spurious onEditingChanged(true) that SwiftUI's Slider
        // fires right after commitScrub() triggers a binding re-evaluation.
        let sinceCommit = Date.now.timeIntervalSince(lastCommitScrubTime)
        guard sinceCommit > 0.5 else {
            playerLog.debug("[scrub] beginScrubbing IGNORED (spurious, \(String(format: "%.3f", sinceCommit))s since commit — threshold=0.5s)")
            return
        }
        playerLog.debug("[scrub] beginScrubbing at \(String(format: "%.1f", self.currentTime))s — sinceCommit=\(String(format: "%.3f", sinceCommit))s isScrubbing=\(self.isScrubbing) controlsVisible=\(self.controlsVisible)")
        seekDebounceTask?.cancel()
        isScrubbing = true
        scrubTime = currentTime
        playerLog.debug("[scrub] beginScrubbing done — isScrubbing=\(self.isScrubbing)")
    }

    /// Called on every incremental slider position update while dragging.
    /// Only updates the local `scrubTime` — does NOT seek AVPlayer, preventing
    /// rapid-seek stalls. Seeking happens only on `commitScrub`.
    public func updateScrub(to time: TimeInterval) {
        scrubTime = time
    }

    /// Called when the user releases the slider. Issues a single precise seek.
    public func commitScrub() {
        // SwiftUI's Slider fires onEditingChanged(false) on initialization (when the
        // view first renders), before the user has ever touched it. Guard here so that
        // spurious call doesn't (a) call showControls() at load time, or (b) poison
        // lastCommitScrubTime and block the user's first real scrub attempt via the
        // debounce guard in beginScrubbing().
        guard isScrubbing else { return }
        seekDebounceTask?.cancel()  // release-seek supersedes any pending debounce
        let target = scrubTime
        playerLog.debug("[scrub] commitScrub to \(String(format: "%.1f", target))s — isScrubbing=\(self.isScrubbing) controlsVisible=\(self.controlsVisible)")
        lastCommitScrubTime = .now
        isScrubbing = false
        seek(to: target)
        showControls()
        playerLog.debug("[scrub] commitScrub done — isScrubbing=\(self.isScrubbing) controlsVisible=\(self.controlsVisible)")
    }

    /// Issues a seek to the given time. Does NOT show controls — callers that
    /// want the overlay to appear (user-initiated gestures) must call
    /// `showControls()` themselves after this.
    public func seek(to time: TimeInterval) {
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.currentTime = time }
        }
    }

    public func seekRelative(seconds: TimeInterval) {
        seek(to: max(0, currentTime + seconds))
        showControls()
    }

    /// Seek to the start of the next chapter.
    public func skipToNextChapter() {
        guard let next = chapters.first(where: { $0.startTime > currentTime }) else { return }
        seek(to: next.startTime)
        showControls()
    }

    /// Seek to the start of the current chapter (if >3 s in) or to the previous chapter.
    public func skipToPreviousChapter() {
        guard let current = currentChapter else { return }
        if currentTime - current.startTime > 3 {
            seek(to: current.startTime)
        } else if let prev = chapters.last(where: { $0.startTime < current.startTime }) {
            seek(to: prev.startTime)
        }
        showControls()
    }

    public func setPlaybackSpeed(_ speed: Double) {
        // Setting player.rate to a non-zero value on a paused AVPlayer restarts
        // playback — only apply the rate while actively playing.
        if isPlaying {
            player.rate = Float(speed)
        }
    }

    /// Called when the user begins a long-press on the video surface (controls hidden).
    /// Temporarily boosts playback to 2× until `endHoldSpeed()` is called.
    public func beginHoldSpeed() {
        guard isPlaying, !isHoldingToSpeed else { return }
        isHoldingToSpeed = true
        player.rate = 2.0
        playerLog.notice("[hold-speed] began — boosting to 2×")
    }

    /// Called when the user lifts their finger after a long-press speed boost.
    /// Restores playback to the configured speed.
    public func endHoldSpeed() {
        guard isHoldingToSpeed else { return }
        isHoldingToSpeed = false
        if isPlaying {
            player.rate = Float(settings.playbackSpeed)
        }
        playerLog.notice("[hold-speed] ended — restored to \(self.settings.playbackSpeed)×")
    }

    // MARK: - Controls visibility

    public func showControls() {
        playerLog.debug("[controls] showControls — isScrubbing=\(self.isScrubbing)")
        controlsVisible = true
        scheduleControlsHide()
    }

    public func toggleControls() {
        playerLog.notice("[controls] toggleControls — controlsVisible=\(self.controlsVisible)")
        if controlsVisible {
            controlsTimer?.cancel()
            controlsVisible = false
        } else {
            showControls()
        }
    }

    private func scheduleControlsHide() {
        playerLog.debug("[controls] scheduleControlsHide — resetting \(self.settings.controlsHideTimeout)s timer, isScrubbing=\(self.isScrubbing)")
        controlsTimer?.cancel()
        controlsTimer = Task {
            try? await Task.sleep(for: .seconds(settings.controlsHideTimeout))
            playerLog.debug("[controls] timer fired — isCancelled=\(Task.isCancelled) isScrubbing=\(self.isScrubbing)")
            guard !Task.isCancelled else {
                playerLog.debug("[controls] hide suppressed (cancelled)")
                return
            }
            if !self.isScrubbing {
                playerLog.debug("[controls] hiding controls")
                self.controlsVisible = false
            } else {
                // Still scrubbing — commitScrub will call showControls when the user
                // lifts their finger, but reschedule as a safety net for edge cases.
                playerLog.debug("[controls] hide suppressed (still scrubbing) — rescheduling")
                self.scheduleControlsHide()
            }
        }
    }

    // MARK: - SponsorBlock skip

    /// Call this from the time observer. Handles per-category actions:
    ///   `.skip`      → seeks past the segment automatically.
    ///   `.showToast` → surfaces `currentToastSegment` so the view can show a skip button.
    ///   `.nothing`   → no-op.
    /// Returns true if an auto-seek was triggered.
    @discardableResult
    public func checkSponsorSkip(at time: TimeInterval) -> Bool {
        guard settings.sponsorBlockEnabled else {
            currentToastSegment = nil
            return false
        }
        // Check whether the playhead is inside any active segment.
        if let seg = sponsorSegments.first(where: { time >= $0.start && time < $0.end }) {
            switch settings.sponsorAction(for: seg.category) {
            case .skip:
                // Guard: don't re-trigger while a seek is already in-flight. Without this
                // the 0.5 s time observer fires again before the seek completes and issues
                // another seek, producing the end-of-video twitch / 500 ms audio loop.
                guard !isSkippingSegment else { return true }
                currentToastSegment = nil
                // If the segment reaches (or exceeds) the video end, seeking would clamp
                // to the last decodable frame and never fire didPlayToEndTimeNotification,
                // leaving the player stuck in the segment window forever. Treat it as a
                // natural end instead.
                let effectiveDuration = player.currentItem?.duration.seconds ?? duration
                if effectiveDuration > 0 && seg.end >= effectiveDuration - 0.5 {
                    handlePlaybackEnd()
                    return true
                }
                isSkippingSegment = true
                // Use toleranceAfter so the seek always lands at or past seg.end even when
                // there is no keyframe at exactly that timestamp. This prevents the seek from
                // returning finished=false, resetting the guard, and immediately re-entering
                // the skip loop.
                player.seek(
                    to: CMTime(seconds: seg.end, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600)
                ) { [weak self] finished in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if finished { self.currentTime = seg.end }
                        self.isSkippingSegment = false
                    }
                }
                return true
            case .showToast:
                currentToastSegment = seg
                return false
            case .nothing:
                currentToastSegment = nil
                return false
            }
        } else {
            currentToastSegment = nil
        }
        return false
    }

    /// Manually skip the segment shown in `currentToastSegment` (called by the view's skip button).
    public func skipToastSegment() {
        guard let seg = currentToastSegment else { return }
        currentToastSegment = nil
        let effectiveDuration = player.currentItem?.duration.seconds ?? duration
        if effectiveDuration > 0 && seg.end >= effectiveDuration - 0.5 {
            handlePlaybackEnd()
            return
        }
        seek(to: seg.end)
        showControls()
    }

    // MARK: - Time observer

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: nil) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Don't overwrite the slider position or trigger SponsorBlock auto-seeks
                // while the user is scrubbing. Auto-seeks call seek() → showControls() →
                // scheduleControlsHide(), which cancels and restarts the 4 s hide-timer
                // every 0.5 s, preventing controls from ever auto-hiding post-scrub.
                guard !self.isScrubbing else { return }
                self.currentTime = seconds
                self.checkSponsorSkip(at: seconds)
                self.updateCaptionCue(for: seconds)
                if self.statsForNerdsVisible { self.updateStatsSnapshot() }
            }
        }
    }

    private func setupRateObserver() {
        // KVO on player.rate so isPlaying stays in sync when the system externally
        // pauses the player (e.g. headphones removed, audio session interruption ends
        // without shouldResume). Without this, isPlaying stays true while the player
        // is actually silent, causing handleForeground() to re-start a ghost session.
        rateObserver = player.observe(\.rate, options: [.new]) { [weak self] _, change in
            guard let self, let newRate = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Ignore rate changes that we ourselves triggered (load/pause/resume/stop)
                // by only acting when the player goes silent unexpectedly while we
                // believed it was playing.
                let playerWentSilent = newRate == 0 && self.isPlaying
                if playerWentSilent {
                    self.isPlaying = false
                    playerLog.notice("[rateObserver] player.rate→0 while isPlaying=true — syncing isPlaying=false")
                    #if canImport(UIKit)
                    self.updateNowPlayingPlayback()
                    #endif
                }
            }
        }
    }

    // MARK: - Cleanup

    public func stop() {
        playerLog.notice("[stop] stop() called — currentVideo=\(self.currentVideo?.id ?? "nil") currentTime=\(Int(self.currentTime))s isLoading=\(self.isLoading)")
        // Save watch position before stopping (mirrors VideoStateController)
        if settings.historyState == .enabled, duration > 0 {
            let pos = self.currentTime
            let dur = self.duration
            Task {
                await self.tracker.checkpoint(position: pos, duration: dur)
                playerLog.notice("Saved position \(Int(pos))s for stop")
            }
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
        controlsTimer?.cancel()
        seekDebounceTask?.cancel()
        #if canImport(UIKit)
        clearNowPlayingInfo()
        #endif
    }
}

// MARK: - Now Playing (lock screen + Dynamic Island)

#if canImport(UIKit)
private extension PlaybackViewModel {

    func setupAudioSessionObserver() {
        audioSessionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            switch type {
            case .began:
                // System (phone call, Siri, etc.) took the audio session — note we
                // were playing so we can resume when it ends.
                playerLog.notice("[interruption] began — pausing player")
                Task { @MainActor [weak self] in
                    self?.player.pause()
                }
            case .ended:
                let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                playerLog.notice("[interruption] ended — shouldResume=\(options.contains(.shouldResume))")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try AVAudioSession.sharedInstance().setActive(true)
                    } catch {
                        playerLog.error("[interruption] setActive failed: \(error.localizedDescription)")
                    }
                    if options.contains(.shouldResume) && self.isPlaying {
                        self.player.rate = Float(self.settings.playbackSpeed)
                    }
                }
            @unknown default:
                break
            }
        }
    }

    func setupRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                player.rate = Float(settings.playbackSpeed)
                isPlaying = true
                updateNowPlayingPlayback()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.player.pause()
                self?.isPlaying = false
                self?.updateNowPlayingPlayback()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.togglePlayPause() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            Task { @MainActor [weak self] in self?.seekRelative(seconds: interval) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            Task { @MainActor [weak self] in self?.seekRelative(seconds: -interval) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            Task { @MainActor [weak self] in self?.seek(to: position) }
            return .success
        }
    }

    func updateNowPlayingInfo() {
        let video = playerInfo?.video ?? currentVideo
        guard let video else {
            nowPlayingInfoCache = [:]
            setNowPlayingInfo(nil)
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: video.title,
            MPMediaItemPropertyArtist: video.channelTitle,
            MPNowPlayingInfoPropertyMediaType: NSNumber(value: MPNowPlayingInfoMediaType.video.rawValue),
            MPNowPlayingInfoPropertyIsLiveStream: NSNumber(value: video.isLive),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: NSNumber(value: currentTime),
            MPNowPlayingInfoPropertyPlaybackRate: NSNumber(value: isPlaying ? Double(player.rate) : 0.0),
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = NSNumber(value: duration)
        }
        nowPlayingInfoCache = info
        setNowPlayingInfo(nowPlayingInfoCache)
        // Artwork is intentionally omitted: fetching it requires an async Task,
        // and calling MPNowPlayingInfoCenter after any `await` — regardless of
        // threading wrapper — crashes on MediaPlayer's internal accessQueue.
    }

    func updateNowPlayingPlayback() {
        nowPlayingInfoCache[MPNowPlayingInfoPropertyElapsedPlaybackTime] = NSNumber(value: currentTime)
        nowPlayingInfoCache[MPNowPlayingInfoPropertyPlaybackRate] = NSNumber(value: isPlaying ? Double(player.rate) : 0.0)
        setNowPlayingInfo(nowPlayingInfoCache)
    }

    func clearNowPlayingInfo() {
        nowPlayingInfoCache = [:]
        setNowPlayingInfo(nil)
    }

    /// Writes to `MPNowPlayingInfoCenter` directly on `@MainActor` (= main thread).
    /// Do NOT use DispatchQueue.main.async here — dispatching async from @MainActor
    /// creates a new GCD block that may lack the proper queue-specific context that
    /// MediaPlayer's internal accessQueue asserts, causing EXC_BREAKPOINT.
    /// Since every caller is already @MainActor-isolated this call is always
    /// synchronous on the main thread.
    private func setNowPlayingInfo(_ info: [String: Any]?) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
#endif

// MARK: - StatsForNerdsSnapshot

/// Snapshot of playback diagnostics for the "Stats for Nerds" overlay.
public struct StatsForNerdsSnapshot: Sendable {
    public var videoId: String
    public var displayResolution: String
    public var fps: Int
    public var codec: String
    public var nominalBitrate: String
    public var observedBitrate: String
    public var droppedFrames: Int
    public var stalls: Int

    public static let empty = StatsForNerdsSnapshot(
        videoId: "",
        displayResolution: "",
        fps: 0,
        codec: "",
        nominalBitrate: "",
        observedBitrate: "",
        droppedFrames: 0,
        stalls: 0
    )
}

// MARK: - AVPlayerItem async helpers

private extension AVPlayerItem {
    /// An `AsyncStream` that emits the item's `status` on each KVO change.
    var statusStream: AsyncStream<AVPlayerItem.Status> {
        AsyncStream { continuation in
            let observer = observe(\.status, options: [.initial, .new]) { item, _ in
                continuation.yield(item.status)
                if item.status == .readyToPlay || item.status == .failed {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in observer.invalidate() }
        }
    }
}
