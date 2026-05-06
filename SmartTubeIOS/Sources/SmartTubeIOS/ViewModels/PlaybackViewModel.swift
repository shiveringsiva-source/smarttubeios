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
//
// Behaviour is split across extension files in the same folder:
//   PlaybackViewModel+Loading.swift          – load / suspend / resume / stop lifecycle
//   PlaybackViewModel+Fallback.swift         – AVPlayer error recovery (403, Android client)
//   PlaybackViewModel+Quality.swift          – format selection & HLS variant parsing
//   PlaybackViewModel+Captions.swift         – caption track selection & VTT cue matching
//   PlaybackViewModel+AudioTracks.swift      – audio rendition discovery & auto-selection
//   PlaybackViewModel+Controls.swift         – transport controls & scrubbing
//   PlaybackViewModel+ControlsVisibility.swift – overlay show/hide timer
//   PlaybackViewModel+Navigation.swift       – queue, history & chapter navigation
//   PlaybackViewModel+SponsorBlock.swift     – SponsorBlock skip / toast
//   PlaybackViewModel+StatsForNerds.swift    – diagnostics overlay + StatsForNerdsSnapshot
//   PlaybackViewModel+LikeDislike.swift      – like / dislike
//   PlaybackViewModel+SleepTimer.swift       – sleep timer
//   PlaybackViewModel+Auth.swift             – auth token + cache eviction
//   PlaybackViewModel+Observers.swift        – AVPlayer time & rate KVO observers
//   PlaybackViewModel+NowPlaying.swift       – lock screen / remote command centre (UIKit)
//   AVPlayerItem+StatusStream.swift          – statusStream async helper

@MainActor
@Observable
public final class PlaybackViewModel {

    // MARK: - State

    public internal(set) var playerInfo: PlayerInfo?
    public internal(set) var isLoading: Bool = false
    public internal(set) var isPlaying: Bool = false
    public internal(set) var currentTime: TimeInterval = 0
    public internal(set) var duration: TimeInterval = 0
    public internal(set) var availableFormats: [VideoFormat] = []
    public internal(set) var selectedFormat: VideoFormat? = nil
    public internal(set) var sponsorSegments: [SponsorSegment] = []
    /// The segment currently under the playhead whose action is `.showToast` (nil otherwise).
    public internal(set) var currentToastSegment: SponsorSegment? = nil
    public internal(set) var relatedVideos: [Video] = []
    public internal(set) var chapters: [Chapter] = []
    public internal(set) var hasPrevious: Bool = false
    public internal(set) var hasNext: Bool = false
    /// The last stream URL handed to AVPlayer (primary or fallback). Stamped onto
    /// Crashlytics non-fatal reports so the exact URL that failed is visible.
    var lastAttemptedStreamURL: URL?
    public var error: Error? {
        didSet {
            guard let error else { return }
            let nsError = error as NSError
            // Transient connectivity errors (-1005 = connection lost, -1009 = offline) are
            // expected in poor-network conditions and are not actionable via Crashlytics.
            // Logging them caused a spike in non-fatal events in v2.0 — skip them.
            let transientCodes = [-1005, -1009]
            guard !(nsError.domain == NSURLErrorDomain && transientCodes.contains(nsError.code)) else {
                return
            }
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
    public internal(set) var isHoldingToSpeed: Bool = false
    /// True when the player is displaying in landscape orientation.
    /// Updated automatically when the device rotates or when the
    /// "Landscape Always Play" setting forces landscape mode.
    public var isLandscape: Bool = false
    public internal(set) var likeStatus: LikeStatus = .none
    public internal(set) var statsForNerdsVisible: Bool = false
    public internal(set) var statsSnapshot: StatsForNerdsSnapshot = .empty
    /// End-screen cards to overlay during the final seconds of the video.
    public internal(set) var endCards: [EndCard] = []

    // MARK: - Captions

    public internal(set) var availableCaptions: [CaptionTrack] = []
    public internal(set) var selectedCaption: CaptionTrack? = nil

    // MARK: - Audio tracks

    public internal(set) var availableAudioTracks: [AudioTrack] = []
    public internal(set) var selectedAudioTrack: AudioTrack? = nil
    /// The caption cue active at the current playhead position (nil when CC is off or no cue matches).
    public internal(set) var currentCaptionCue: CaptionCue? = nil

    /// True while the user is dragging the progress slider.
    /// The time observer skips `currentTime` updates while this is set so the
    /// slider thumb doesn't jump back to the real playhead mid-scrub.
    public internal(set) var isScrubbing: Bool = false
    /// True if playback was active when `suspend()` was last called.
    /// Used by `PlayerView.onAppear` to decide whether to resume after a
    /// sheet dismissal — prevents overriding an intentional user pause.
    public internal(set) var wasPlayingBeforeSuspend: Bool = false
    /// Position tracked during a scrub drag; committed to AVPlayer on release.
    public internal(set) var scrubTime: TimeInterval = 0

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
    var history: [Video] = []
    /// The video currently loaded (nil before first load).
    var currentVideo: Video? = nil

    // MARK: - AVPlayer

    public let player = AVPlayer()
    @ObservationIgnored nonisolated(unsafe) var timeObserver: Any?
    @ObservationIgnored nonisolated(unsafe) var audioSessionObserver: Any?
    @ObservationIgnored nonisolated(unsafe) var rateObserver: NSKeyValueObservation?
    /// Prevents infinite retry loops: set once the first fallback attempt has been made.
    var hasRetriedPlayback: Bool = false
    /// True while a SponsorBlock auto-skip seek is in-flight. Guards against the periodic
    /// time observer re-triggering `checkSponsorSkip` before the seek completes, which
    /// causes the end-of-video twitch / audio loop.
    var isSkippingSegment: Bool = false
    var itemObserverTask: Task<Void, Never>?
    var endObserverTask: Task<Void, Never>?
    var controlsTimer: Task<Void, Never>?
    @ObservationIgnored var sleepTimerTask: Task<Void, Never>?
    /// Remaining minutes on the sleep timer (nil = off). Observable so PlayerView can show it.
    public internal(set) var sleepTimerMinutes: Int? = nil
    /// Available sleep timer durations in minutes.
    public static let sleepTimerOptions: [Int] = [15, 30, 45, 60]
    /// Position to seek to once the AVPlayerItem is ready.
    var savedPositionToRestore: TimeInterval? = nil
    /// In-flight quality-switch task. Cancelled before starting a new switch so
    /// rapid taps in the quality picker never leave two competing replacements.
    var qualityTask: Task<Void, Never>?
    /// Maps HLS variant height (in pixels) to the direct single-quality playlist URL
    /// parsed from the master manifest. Used by reloadHLSItem to bypass ABR entirely
    /// when the user selects a specific quality tier.
    var hlsVariantURLs: [Int: URL] = [:]
    /// Manages watch-history state: position saving, playback-started ping,
    /// and watchtime segment reporting. See WatchtimeTracker.
    var tracker: WatchtimeTracker

    // AVMediaSelectionGroup for audio — not Sendable, kept nonisolated(unsafe) and only
    // accessed from MainActor context (Task { [weak self] in ... } on the main actor).
    @ObservationIgnored nonisolated(unsafe) var audioSelectionGroup: AVMediaSelectionGroup? = nil
    @ObservationIgnored var audioOptionsByID: [String: AVMediaSelectionOption] = [:]

    // Caption cues loaded for the currently selected track
    var captionCues: [CaptionCue] = []
    @ObservationIgnored var captionFetchTask: Task<Void, Never>? = nil
    /// Timestamp of the last commitScrub(). Used to ignore the spurious
    /// beginScrubbing() that SwiftUI's Slider fires immediately after commitScrub
    /// causes a binding re-evaluation and the slider thumb re-positions itself.
    var lastCommitScrubTime: Date = .distantPast
    /// Debounce task for preview seeks while dragging the slider.
    /// Fires a seek after the thumb has been held still for 300 ms.
    var seekDebounceTask: Task<Void, Never>?
    /// Tracks the in-flight loadAsync so it can be cancelled if load() is called again.
    var loadTask: Task<Void, Never>?

    // MARK: - Now Playing cache
    // Never read nowPlayingInfo back from MPNowPlayingInfoCenter — doing a
    // read-modify-write while MediaPlayer is processing on its accessQueue
    // causes EXC_BREAKPOINT. Mirror the dict locally instead.
    @ObservationIgnored var nowPlayingInfoCache: [String: Any] = [:]

    // MARK: - Dependencies

    let api: InnerTubeAPI
    let sponsorBlock: SponsorBlockService
    let deArrow: DeArrowService
    var settings: AppSettings
    var hasAuthToken: Bool = false
    var currentAuthToken: String? = nil

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
        if let obs = audioSessionObserver { NotificationCenter.default.removeObserver(obs) }
        #if canImport(UIKit)
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        #endif
    }

    // MARK: - Settings

    public func updateSettings(_ newSettings: AppSettings) {
        settings = newSettings
    }

    // MARK: - Current video identity

    /// The ID of the video currently loaded (or being loaded). Exposed so PlayerView
    /// can detect spurious onAppear/onDisappear cycles (e.g. when a ShareLink sheet
    /// temporarily covers the player) and skip unnecessary reloads.
    public var currentVideoId: String? { currentVideo?.id }
}
