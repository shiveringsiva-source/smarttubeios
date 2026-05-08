import SwiftUI
import AVFoundation
import AVKit
import SmartTubeIOSCore
import os
#if canImport(UIKit)
import UIKit
#endif

private let swipeLog = CrashlyticsLogger(category: "Player")

// MARK: - PlayerView
//
// Full-screen video player.  Wraps AVKit's `VideoPlayer` and overlays
// custom controls, chapter markers, and SponsorBlock skip toasts.
// Mirrors the Android `PlaybackFragment`.

public struct PlayerView: View {
    public let video: Video
    #if os(iOS)
    @Environment(PlayerStateStore.self) private var playerState
    var vm: PlaybackViewModel { playerState.vm }
    #else
    @State var vm: PlaybackViewModel
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) var dismiss
    @Environment(SettingsStore.self) var store
    @Environment(AuthService.self) var authService
    @State var showSpeedPicker = false
    @State var showQualityPicker = false
    @State var showCaptionPicker = false
    @State var showAudioTrackPicker = false
    @State var showSleepTimerPicker = false
    @State var showMoreMenu = false
    @State var showDescriptionSheet = false
    @State var showCommentsSheet = false
    @State var videoComments: [Comment] = []
    @State var isLoadingComments = false
    @State var commentsAPI: InnerTubeAPI
    @State private var slideOffset: CGFloat = 0
    @State private var isTransitioning = false
    @State var channelDestination: ChannelDestination?
    #if !os(tvOS)
    @State var downloadService: VideoDownloadService
    @State private var downloadAlertItem: DownloadAlertItem?
    #endif
    #if os(iOS)
    @State private var pipController: AVPictureInPictureController?
    @State private var pipDelegate: PiPDelegate?
    @State private var isPiPActive: Bool = false
    private var playerLayer: AVPlayerLayer { playerState.playerHostView.playerLayer }
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    /// True while the app is backgrounded. Prevents `onDisappear` from calling
    /// `suspend()` when iOS fires it as a side-effect of backgrounding rather
    /// than actual navigation away from the player.
    @State private var isInBackground = false
    /// True while this PlayerView instance is the top-most visible view.
    /// Guards scenePhase handlers so only the visible instance calls handleForeground/handleBackground,
    /// preventing ghost VMs from resuming audio when a new PlayerView is pushed on top.
    @State private var isVisible = false
    #if os(iOS)
    /// Drives the brief "Fit" / "Fill" toast shown after a double-tap scale toggle.
    @State private var scaleToast: String?
    #endif
    #if os(tvOS)
    @FocusState private var playerFocused: Bool
    /// Which playback control is visually highlighted in the overlay.
    /// nil = not in controls-nav mode; all remote input targets the video layer.
    @State var highlightedControl: TVPlayerControl? = nil
    /// Namespace for the player ZStack itself, used with `.focusScope` +
    /// `.prefersDefaultFocus` so the ZStack claims default focus when pushed via
    /// NavigationStack — preventing any child view from stealing focus first.
    @Namespace var playerBodyNamespace
    /// Namespace IDs used with `.focusScope` on picker overlays so the tvOS focus
    /// engine moves focus into the overlay when it opens.
    @Namespace var qualityPickerNamespace
    @Namespace var speedPickerNamespace
    @Namespace var sleepTimerNamespace
    /// Explicitly routes Siri Remote focus when overlays open programmatically.
    /// `moreMenuFocusedRow` drives D-pad navigation within the more menu via explicit
    /// `.onMoveCommand` (SwiftUI's spatial engine cannot navigate ZStack overlays).
    @FocusState var moreMenuFocusedRow: MoreMenuRow?
    @FocusState var speedPickerFocused: Bool
    @FocusState var sleepTimerPickerFocused: Bool
    #endif

    /// Scales player control icon sizes up on iPad so they're easier to tap.
    private var controlScale: CGFloat {
        #if os(iOS)
        horizontalSizeClass == .regular ? 4.0 / 3.0 : 1.0
        #else
        1.0
        #endif
    }

    public init(video: Video, api: InnerTubeAPI) {
        self.video = video
        #if !os(iOS)
        _vm = State(initialValue: PlaybackViewModel(api: api))
        #endif
        _commentsAPI = State(initialValue: api)
        #if !os(tvOS)
        _downloadService = State(initialValue: VideoDownloadService(api: api))
        #endif
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                #if os(iOS)
                // FullScreenPlayerLayerView: wraps PersistentPlayerHostView so the AVPlayerLayer
                // survives PlayerView dismiss/re-present cycles (mini-player feature).
                FullScreenPlayerLayerView(
                    hostView: playerState.playerHostView,
                    videoGravity: store.settings.videoGravityMode.avGravity
                )
                .ignoresSafeArea()
                .accessibilityHidden(true)
                #elseif os(tvOS)
                // AVPlayerLayerView: bare AVPlayerLayer without AVPlayerViewController.
                // AVPlayerViewController (VideoPlayer) dominates the UIKit accessibility
                // tree, making all overlaid SwiftUI elements invisible to XCUITest.
                AVPlayerLayerView(player: vm.player, videoGravity: store.settings.videoGravityMode.avGravity)
                .ignoresSafeArea()
                .accessibilityHidden(true)
                #else
                Color.black.ignoresSafeArea()
                #endif

                #if os(iOS)
                // Horizontal swipe layer: left → next video, right → previous video.
                // Uses UIKit-level UIPanGestureRecognizer so it fires above AVPlayerLayer.
                SwipeGestureOverlay(
                    onSwipeLeft: {
                        swipeLog.debug("[swipe-overlay] onSwipeLeft — isTransitioning=\(isTransitioning) isScrubbing=\(vm.isScrubbing) controlsVisible=\(vm.controlsVisible) hasNext=\(vm.hasNext)")
                        guard !isTransitioning else { return }
                        if vm.hasNext { performHorizontalTransition(direction: -1, screenWidth: geo.size.width) { vm.playNext() } }
                        else { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { slideOffset = 0 } }
                    },
                    onSwipeRight: {
                        swipeLog.debug("[swipe-overlay] onSwipeRight — isTransitioning=\(isTransitioning) isScrubbing=\(vm.isScrubbing) controlsVisible=\(vm.controlsVisible) hasPrevious=\(vm.hasPrevious)")
                        guard !isTransitioning else { return }
                        if vm.hasPrevious { performHorizontalTransition(direction: 1, screenWidth: geo.size.width) { vm.playPrevious() } }
                        else { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { slideOffset = 0 } }
                    },
                    onTap: {
                        // Suppress toggle-controls when end cards are active — taps belong to the cards.
                        if !vm.hasVisibleEndCards { vm.toggleControls() }
                    },
                    onDoubleTap: {
                        let newMode: AppSettings.VideoGravityMode =
                            store.settings.videoGravityMode == .fit ? .fill : .fit
                        store.settings.videoGravityMode = newMode
                        scaleToast = newMode == .fill ? "Fill" : "Fit"
                    },
                    onTwoFingerTap: { vm.toggleStatsForNerds() },
                    onPanChanged: { dx in
                        guard !isTransitioning else { return }
                        if (dx < 0 && vm.hasNext) || (dx > 0 && vm.hasPrevious) {
                            slideOffset = dx
                        } else {
                            slideOffset = dx * 0.15
                        }
                    },
                    onSwipeCancelled: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { slideOffset = 0 }
                    },
                    onLongPressStart: { vm.beginHoldSpeed() },
                    onLongPressEnd:   { vm.endHoldSpeed() },
                    onSwipeDown: { playerState.minimize() },
                    // Disabled during scrubbing so the Slider can claim touches uncontested.
                    // Also disabled when controls are visible so SwiftUI buttons (Menu, etc.)
                    // receive touches directly without UIKit gesture interference.
                    isEnabled: !vm.isScrubbing && !vm.controlsVisible
                )
                .ignoresSafeArea()
                .accessibilityHidden(true)
                #endif

                // Loading spinner
                if vm.isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.5)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: vm.isLoading)
                }

                // Hold-to-speed badge — shown while user long-presses to boost to 2×
                #if os(iOS) || os(tvOS)
                if vm.isHoldingToSpeed {
                    HoldSpeedBadge()
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        .animation(.easeOut(duration: 0.15), value: vm.isHoldingToSpeed)
                }
                #endif

                // Custom overlay controls
                if vm.controlsVisible {
                    controlsOverlay(size: geo.size, safeAreaInsets: geo.safeAreaInsets)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.25), value: vm.controlsVisible)
                        #if os(iOS)
                        // Allow horizontal swipe navigation even when the controls overlay is
                        // on screen.  .simultaneousGesture fires alongside button taps so the
                        // controls remain fully interactive; only clear horizontal drags
                        // (abs(dx) > abs(dy), distance > 50 pt) trigger navigation.
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 50, coordinateSpace: .global)
                                .onEnded { value in
                                    let dx = value.translation.width
                                    let dy = value.translation.height
                                    guard !isTransitioning, !vm.isScrubbing else { return }
                                    // Swipe-down → minimize to mini-player
                                    if dy > 50, abs(dy) > abs(dx) {
                                        playerState.minimize()
                                        return
                                    }
                                    guard abs(dx) > abs(dy) else { return }
                                    if dx < 0, vm.hasNext {
                                        performHorizontalTransition(direction: -1, screenWidth: geo.size.width) { vm.playNext() }
                                    } else if dx > 0, vm.hasPrevious {
                                        performHorizontalTransition(direction: 1, screenWidth: geo.size.width) { vm.playPrevious() }
                                    }
                                }
                        )
                        #endif
                }

                // Error banner
                if let err = vm.error {
                    errorBanner(err)
                }

                // SponsorBlock skip toast
                sponsorSkipToast

                // Caption cue overlay — shown when a track is selected and a cue is active
                #if !os(tvOS)
                if let cue = vm.currentCaptionCue {
                    VStack(spacing: 0) {
                        Spacer()
                        CaptionCueView(text: cue.text)
                            .padding(.bottom, 72)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }
                #endif

                // End cards — shown in the final seconds of a video.
                // Displayed regardless of controls visibility, matching official YouTube behaviour.
                #if !os(tvOS)
                if !vm.endCards.isEmpty {
                    EndCardOverlay(
                        cards: vm.endCards,
                        currentTime: vm.currentTime,
                        size: geo.size,
                        onSelect: { card in
                            guard let videoId = card.videoId else { return }
                            let video = Video(
                                id: videoId,
                                title: card.title,
                                channelTitle: "",
                                thumbnailURL: card.thumbnailURL
                            )
                            vm.load(video: video)
                        }
                    )
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: vm.controlsVisible)
                }
                #endif

                // Stats for Nerds overlay (toggled by two-finger tap)
                if vm.statsForNerdsVisible {
                    StatsForNerdsOverlay(snapshot: vm.statsSnapshot)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: vm.statsForNerdsVisible)
                }

                // More-menu — pure SwiftUI overlay so no UIKit presentation fires
                // onDisappear on the player and tears itself down.
                if showMoreMenu {
                    moreMenuOverlay
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .animation(.easeOut(duration: 0.2), value: showMoreMenu)
                }

                // Speed picker — pure SwiftUI overlay, no UIKit sheet presentation.
                if showSpeedPicker {
                    speedPickerOverlay
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .animation(.easeOut(duration: 0.2), value: showSpeedPicker)
                }

                // Quality picker — pure SwiftUI overlay, no UIKit sheet presentation.
                if showQualityPicker {
                    qualityPickerOverlay
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .animation(.easeOut(duration: 0.2), value: showQualityPicker)
                }

                // Caption picker — pure SwiftUI overlay, no UIKit sheet presentation.
                #if !os(tvOS)
                if showCaptionPicker {
                    captionPickerOverlay
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .animation(.easeOut(duration: 0.2), value: showCaptionPicker)
                }
                #endif

                // Audio track picker — pure SwiftUI overlay, no UIKit sheet presentation.
                #if !os(tvOS)
                if showAudioTrackPicker {
                    audioTrackPickerOverlay
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .animation(.easeOut(duration: 0.2), value: showAudioTrackPicker)
                }
                #endif

                // Sleep timer picker — pure SwiftUI overlay, no UIKit presentation.
                if showSleepTimerPicker {
                    sleepTimerPickerOverlay
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .animation(.easeOut(duration: 0.2), value: showSleepTimerPicker)
                }

                // Description sheet — pure SwiftUI overlay.
                if showDescriptionSheet {
                    descriptionOverlay
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .animation(.easeOut(duration: 0.2), value: showDescriptionSheet)
                }

                // Comments sheet — pure SwiftUI overlay.
                if showCommentsSheet {
                    commentsOverlay
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .animation(.easeOut(duration: 0.2), value: showCommentsSheet)
                }
            }
            .offset(x: slideOffset)
        }
        .background(Color.black.ignoresSafeArea())
        #if os(iOS)
        .toast(message: $scaleToast)
        #endif
        #if os(tvOS)
        // When no overlay is open, the outer view is the exclusive focus target and
        // handles all remote input via onMoveCommand / onTapGesture.
        // When an overlay (more menu, quality, speed, sleep timer) is visible, focus is
        // yielded so the overlay's buttons are reachable by the Siri Remote.
        // `.focusScope` + `.prefersDefaultFocus` ensure the ZStack actively claims
        // default focus when pushed via NavigationStack, rather than waiting for the
        // focus engine to pick a child element or leaving focus on the previous screen.
        .focusScope(playerBodyNamespace)
        .prefersDefaultFocus(in: playerBodyNamespace)
        .focusable(!isAnyOverlayVisible)
        .focused($playerFocused)
        .modifier(ConditionalMoveCommand(enabled: !isAnyOverlayVisible) { direction in
            swipeLog.debug("[tv] onMoveCommand dir=\(String(describing: direction)) isTransitioning=\(isTransitioning) highlighted=\(String(describing: highlightedControl))")
            guard !isTransitioning else { return }
            if let current = highlightedControl {
                // Controls-nav mode: move the highlight between buttons.
                highlightedControl = tvNextControl(from: current, direction: direction)
                vm.showControls()
            } else if vm.controlsVisible {
                // Controls visible but nav not started: any d-pad enters nav mode.
                highlightedControl = .playPause
                vm.showControls()
            } else {
                // Controls hidden: left/right seek, up/down shows controls.
                switch direction {
                case .left:  vm.seekRelative(seconds: -10)
                case .right: vm.seekRelative(seconds: 10)
                default:     vm.showControls(); highlightedControl = .playPause
                }
            }
        })
        .onTapGesture {
            swipeLog.notice("[tv] onTapGesture (select) — isAnyOverlayVisible=\(isAnyOverlayVisible) highlighted=\(String(describing: highlightedControl)) controlsVisible=\(vm.controlsVisible)")
            guard !isAnyOverlayVisible else { return }
            if let current = highlightedControl {
                tvActivateControl(current)
            } else if vm.controlsVisible {
                highlightedControl = .playPause
                vm.showControls()
            } else {
                vm.showControls()
                highlightedControl = .playPause
            }
        }
        .onPlayPauseCommand { vm.togglePlayPause() }
        .onExitCommand {
            swipeLog.notice("[tv] onExitCommand — showMoreMenu=\(showMoreMenu) showQuality=\(showQualityPicker) showSpeed=\(showSpeedPicker) showSleep=\(showSleepTimerPicker) highlighted=\(String(describing: highlightedControl)) controlsVisible=\(vm.controlsVisible)")
            // Dismiss any open overlay first — Menu/Back is the tvOS dismiss convention.
            if showMoreMenu      { showMoreMenu = false; return }
            if showQualityPicker { showQualityPicker = false; return }
            if showSpeedPicker   { showSpeedPicker = false; return }
            if showSleepTimerPicker { showSleepTimerPicker = false; return }
            if highlightedControl != nil {
                // Esc/Menu from nav mode → exit nav mode, controls stay until timer.
                highlightedControl = nil
            } else if vm.controlsVisible {
                vm.toggleControls()
            } else {
                vm.stop()
                dismiss()
            }
        }
        .onChange(of: playerFocused) { _, focused in
            swipeLog.notice("[tv] playerFocused changed → \(focused) isAnyOverlayVisible=\(isAnyOverlayVisible)")
        }
        .onChange(of: showMoreMenu) { _, visible in
            swipeLog.notice("[tv] showMoreMenu changed → \(visible) isAnyOverlayVisible=\(isAnyOverlayVisible) playerFocused=\(playerFocused)")
            if visible {
                // prefersDefaultFocus is consulted only when focus ENTERS a scope naturally.
                // Since the overlay opens programmatically, we must explicitly route focus to
                // the speed row so the Siri Remote Select button works immediately.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000) // one render cycle (~50 ms)
                    moreMenuFocusedRow = .speed
                    swipeLog.notice("[tv] moreMenuFocusedRow set → .speed")
                }
            } else {
                moreMenuFocusedRow = nil
            }
        }
        .onChange(of: showSpeedPicker) { _, visible in
            swipeLog.notice("[tv] showSpeedPicker changed → \(visible)")
            if visible {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    speedPickerFocused = true
                    swipeLog.notice("[tv] speedPickerFocused set → true")
                }
            }
        }
        .onChange(of: showSleepTimerPicker) { _, visible in
            swipeLog.notice("[tv] showSleepTimerPicker changed → \(visible)")
            if visible {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    sleepTimerPickerFocused = true
                    swipeLog.notice("[tv] sleepTimerPickerFocused set → true")
                }
            }
        }
        .onChange(of: vm.controlsVisible) { _, visible in
            swipeLog.debug("[tv] controlsVisible changed → \(visible) highlighted=\(String(describing: highlightedControl)) isAnyOverlayVisible=\(isAnyOverlayVisible)")
            if !visible {
                highlightedControl = nil
                // Only reclaim player focus when no overlay is open.
                // focusScope(moreMenuNamespace) keeps focus inside the menu when
                // controls hide, so no re-assertion is needed (and re-asserting
                // would steal focus back from whichever row the user navigated to).
                if !isAnyOverlayVisible {
                    playerFocused = true
                }
            }
        }
        .onChange(of: isAnyOverlayVisible) { _, overlayVisible in
            swipeLog.notice("[tv] isAnyOverlayVisible changed → \(overlayVisible) — moreMenu=\(showMoreMenu) quality=\(showQualityPicker) speed=\(showSpeedPicker) sleep=\(showSleepTimerPicker)")
            if overlayVisible {
                // Pause the controls auto-hide timer so transport controls stay
                // visible behind the overlay while it is open.
                vm.cancelControlsHide()
            } else {
                // Overlay dismissed — reclaim focus and clear nav state.
                highlightedControl = nil
                playerFocused = true
            }
        }
        #endif
        #if os(iOS)
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        #elseif os(tvOS)
        .toolbar(.hidden, for: .tabBar)
        #endif
        // Always-visible title badge so XCUITest can read the current video title
        // without waiting for the controls overlay to be shown.
        // Also provides an always-accessible back button for UI automation.
        .overlay(alignment: .topLeading) {
            HStack(spacing: 0) {
                Button {
                    #if os(iOS)
                    swipeLog.notice("[PlayerView] backButton tapped — calling playerState.minimize(), presentation=\(String(describing: playerState.presentation))")
                    playerState.minimize()
                    swipeLog.notice("[PlayerView] backButton — minimize() returned, presentation=\(String(describing: playerState.presentation))")
                    #else
                    vm.stop(); withAnimation(.none) { dismiss() }
                    #endif
                } label: {
                    Color.clear.frame(width: 60, height: 60)
                }
                .accessibilityIdentifier("player.backButton")
                #if os(tvOS)
                .buttonStyle(.plain)
                .focusable(false)
                #endif
                Text(vm.playerInfo?.video.title ?? video.title)
                    .font(.caption)
                    .opacity(0)   // visually invisible (including emoji), accessible
                    .accessibilityIdentifier("player.titleLabel")
                    .allowsHitTesting(false)
            }
            #if !os(tvOS)
            .padding(.top, 60)
            #endif
        }
        .onAppear {
            swipeLog.notice("[PlayerView] onAppear id=\(video.id)")
            isVisible = true
            #if os(tvOS)
            playerFocused = true
            #endif
            #if os(iOS)
            swipeLog.notice("[orientation] onAppear — calling beginGeneratingDeviceOrientationNotifications")
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            let rawOrientation = UIDevice.current.orientation
            let physicallyLandscape = rawOrientation.isLandscape
            let alwaysPlayOnAppear = store.settings.landscapeAlwaysPlay
            let isLandscapeOnAppear = alwaysPlayOnAppear || physicallyLandscape
            vm.isLandscape = isLandscapeOnAppear
            swipeLog.notice("[orientation] onAppear — rawOrientation=\(rawOrientation.rawValue) physicallyLandscape=\(physicallyLandscape) landscapeAlwaysPlay=\(alwaysPlayOnAppear) → isLandscape=\(isLandscapeOnAppear)")
            if alwaysPlayOnAppear {
                swipeLog.notice("[orientation] onAppear — landscapeAlwaysPlay=true, setting playerIsActive=true")
                OrientationManager.shared.playerIsActive = true
            } else {
                swipeLog.notice("[orientation] onAppear — landscapeAlwaysPlay=false, playerIsActive remains false")
            }
            #endif
            #if os(iOS)
            // On iOS, PlayerStateStore.play(video:) already called vm.load() before
            // presenting. Only sync current user preferences; the video is already loading.
            vm.setPlaybackSpeed(store.settings.playbackSpeed)
            vm.updateSettings(store.settings)
            vm.updateAuthToken(authService.accessToken)
            #else
            if vm.currentVideoId == video.id {
                // Spurious appear (e.g. a sheet temporarily covered us) — only resume
                // if playback was active before the view disappeared, so an intentional
                // user pause is not overridden (e.g. pause → background → foreground).
                if vm.wasPlayingBeforeSuspend {
                    vm.resume()
                }
            } else {
                vm.load(video: video)
            }
            vm.setPlaybackSpeed(store.settings.playbackSpeed)
            vm.updateSettings(store.settings)
            vm.updateAuthToken(authService.accessToken)
            // UI testing only: force-show controls and/or the more menu so tests can
            // verify focus routing without relying on gesture delivery, which is
            // unreliable on the tvOS simulator.
            // Called AFTER load() so it runs after controlsVisible is reset to false.
            if ProcessInfo.processInfo.arguments.contains("--uitesting-show-controls") {
                swipeLog.notice("[tv] --uitesting-show-controls launch arg detected — calling showControls()")
                vm.showControls()
            }
            if ProcessInfo.processInfo.arguments.contains("--uitesting-open-more-menu") {
                swipeLog.notice("[tv] --uitesting-open-more-menu launch arg detected — scheduling showMoreMenu=true after focus settles")
                Task { @MainActor in
                    // Brief delay lets the player body establish focus (via .prefersDefaultFocus)
                    // before the overlay opens, so moreMenuNamespace can attract focus correctly.
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    swipeLog.notice("[tv] --uitesting-open-more-menu: setting showMoreMenu=true (playerFocused=\(playerFocused))")
                    showMoreMenu = true
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--uitesting-open-sleep-timer-picker") {
                swipeLog.notice("[tv] --uitesting-open-sleep-timer-picker launch arg detected — scheduling showSleepTimerPicker=true")
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    swipeLog.notice("[tv] --uitesting-open-sleep-timer-picker: setting showSleepTimerPicker=true")
                    showSleepTimerPicker = true
                }
            }
            #endif
        }
        .onDisappear {
            swipeLog.notice("[PlayerView] onDisappear id=\(video.id) isInBackground=\(isInBackground)")
            isVisible = false
            guard !isInBackground else { return }
            #if os(iOS)
            let rawOrientationOnDisappear = UIDevice.current.orientation
            swipeLog.notice("[orientation] onDisappear — rawOrientation=\(rawOrientationOnDisappear.rawValue) isLandscape was \(vm.isLandscape), playerIsActive was \(OrientationManager.shared.playerIsActive)")
            OrientationManager.shared.playerIsActive = false
            vm.isLandscape = false
            swipeLog.notice("[orientation] onDisappear — playerIsActive=false isLandscape=false, calling endGeneratingDeviceOrientationNotifications")
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            // Skip suspend when minimizing to mini-player — playback should continue.
            guard playerState.presentation != .miniPlayer else { return }
            vm.suspend()
            #else
            vm.suspend()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                isInBackground = true
                if isVisible { vm.handleBackground() }
            case .active:
                isInBackground = false
                if isVisible { vm.handleForeground() }
            default:
                break
            }
        }
        #if os(iOS)
        // Create the PiP controller the first time the player actually starts
        // playing — AVPlayer must have a ready item for isPictureInPicturePossible
        // to ever become true. Creating it at view-appear time (before any item
        // is loaded) means it stays permanently inert.
        .onChange(of: vm.isPlaying) { _, playing in
            guard playing, pipController == nil,
                  store.settings.pipEnabled,
                  AVPictureInPictureController.isPictureInPictureSupported() else { return }
            let pip = AVPictureInPictureController(playerLayer: playerLayer)
            pip?.canStartPictureInPictureAutomaticallyFromInline = true
            let delegate = PiPDelegate { active in isPiPActive = active }
            pip?.delegate = delegate
            pipDelegate = delegate
            pipController = pip
        }
        // Update isLandscape when the device physically rotates.
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            let orientation = UIDevice.current.orientation
            swipeLog.notice("[orientation] orientationDidChange — rawValue=\(orientation.rawValue) isValidInterfaceOrientation=\(orientation.isValidInterfaceOrientation) isLandscape=\(orientation.isLandscape) isPortrait=\(orientation.isPortrait)")
            guard orientation.isValidInterfaceOrientation else {
                swipeLog.notice("[orientation] orientationDidChange — skipped (not a valid interface orientation, e.g. face-up/face-down/unknown)")
                return
            }
            let alwaysLandscape = store.settings.landscapeAlwaysPlay
            let physicalLandscape = orientation.isLandscape
            let newIsLandscape = alwaysLandscape || physicalLandscape
            let prevIsLandscape = vm.isLandscape
            let prevPlayerIsActive = OrientationManager.shared.playerIsActive
            vm.isLandscape = newIsLandscape
            OrientationManager.shared.playerIsActive = newIsLandscape
            swipeLog.notice("[orientation] orientationDidChange — landscapeAlwaysPlay=\(alwaysLandscape) physicalLandscape=\(physicalLandscape) isLandscape: \(prevIsLandscape) → \(newIsLandscape) playerIsActive: \(prevPlayerIsActive) → \(newIsLandscape)")
        }
        // Keep isLandscape in sync when the user toggles "Landscape Always Play" while
        // the player is on screen.
        .onChange(of: store.settings.landscapeAlwaysPlay) { oldValue, alwaysLandscape in
            let rawOrientation = UIDevice.current.orientation
            let physicallyLandscape = rawOrientation.isLandscape
            let newIsLandscape = alwaysLandscape || physicallyLandscape
            let prevIsLandscape = vm.isLandscape
            let prevPlayerIsActive = OrientationManager.shared.playerIsActive
            vm.isLandscape = newIsLandscape
            OrientationManager.shared.playerIsActive = alwaysLandscape
            swipeLog.notice("[orientation] landscapeAlwaysPlay: \(oldValue) → \(alwaysLandscape) rawOrientation=\(rawOrientation.rawValue) physicallyLandscape=\(physicallyLandscape) isLandscape: \(prevIsLandscape) → \(newIsLandscape) playerIsActive: \(prevPlayerIsActive) → \(alwaysLandscape)")
        }
        #endif
        .navigationDestination(item: $channelDestination) { dest in
            ChannelView(channelId: dest.channelId)
        }
        #if !os(tvOS)
        .onChange(of: downloadService.state) { _, newState in
            switch newState {
            case .done:
                let title = vm.playerInfo?.video.title ?? video.title
                downloadAlertItem = DownloadAlertItem(
                    title: String(localized: "Saved to Gallery", bundle: .module),
                    message: String(localized: "\"\(title)\" has been saved to your Photos library.", bundle: .module)
                )
                downloadService.reset()
            case .failed(let reason):
                downloadAlertItem = DownloadAlertItem(
                    title: String(localized: "Download Failed", bundle: .module),
                    message: reason
                )
                downloadService.reset()
            default:
                break
            }
        }
        .alert(item: $downloadAlertItem) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("OK")))
        }
        #endif
    }

    // MARK: - Slide transition

    /// Animates the current content off-screen in `direction` (-1 = left, +1 = right),
    /// runs `action` to load the next/previous video, then slides the new content in
    /// from the opposite side.
    private func performHorizontalTransition(direction: CGFloat, screenWidth: CGFloat, action: @escaping () -> Void) {
        // Set the re-entry guard synchronously so any concurrent gesture event
        // arriving before the Task runs still sees isTransitioning == true.
        isTransitioning = true
        // Defer ALL SwiftUI state mutations (incl. the initial slide-out animation)
        // into the async Task so none of them execute synchronously inside UIKit's
        // touch-event delivery pass. On iOS 26 the UpdateCycle framework throws when
        // @Observable/@State mutations happen synchronously during event dispatch.
        Task { @MainActor in
            withAnimation(.easeIn(duration: 0.2)) {
                slideOffset = direction * screenWidth
            }
            try? await Task.sleep(for: .milliseconds(220))
            action()                                        // load new video, clears AVPlayer
            slideOffset = -direction * screenWidth          // snap to opposite side (off-screen)
            withAnimation(.easeOut(duration: 0.25)) {
                slideOffset = 0                             // slide new content in
            }
            try? await Task.sleep(for: .milliseconds(270))
            isTransitioning = false
        }
    }

    // MARK: - Controls overlay

    private func controlsOverlay(size: CGSize, safeAreaInsets: EdgeInsets) -> some View {
        VStack {
            // Top bar: back + title
            HStack {
                Button {
                    #if os(iOS)
                    playerState.minimize()
                    #else
                    vm.stop(); withAnimation(.none) { dismiss() }
                    #endif
                } label: {
                    Image(systemName: AppSymbol.chevronLeft)
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.black.opacity(0.4))
                        .clipShape(Circle())
                }
                .accessibilityIdentifier("player.backButton")
                #if os(tvOS)
                .buttonStyle(.plain)
                .scaleEffect(highlightedControl == .back ? 1.5 : 1.0)
                .shadow(color: highlightedControl == .back ? .white.opacity(0.85) : .clear, radius: 12)
                .animation(.easeInOut(duration: 0.15), value: highlightedControl)
                #endif
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.playerInfo?.video.title ?? video.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .accessibilityIdentifier("player.titleLabel")
                    let channelId = vm.playerInfo?.video.channelId ?? video.channelId
                    let channelTitle = vm.playerInfo?.video.channelTitle ?? video.channelTitle
                    Button {
                        guard let cid = channelId, !cid.isEmpty else { return }
                        #if os(iOS)
                        // PlayerView is presented via fullScreenCover — there is no
                        // NavigationStack, so setting channelDestination is a no-op.
                        // Post the shared notification instead (same path as VideoCardView),
                        // then dismiss the player so the parent can push ChannelView.
                        NotificationCenter.default.post(
                            name: .openChannel,
                            object: nil,
                            userInfo: ["channelId": cid]
                        )
                        dismiss()
                        #else
                        channelDestination = ChannelDestination(channelId: cid)
                        #endif
                    } label: {
                        Text(channelTitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    #if os(tvOS)
                    .buttonStyle(.plain)
                    .scaleEffect(highlightedControl == .channel ? 1.5 : 1.0)
                    .shadow(color: highlightedControl == .channel ? .white.opacity(0.85) : .clear, radius: 12)
                    .animation(.easeInOut(duration: 0.15), value: highlightedControl)
                    #else
                    .buttonStyle(.plain)
                    #endif
                    .accessibilityIdentifier("player.channelName")
                    .disabled(channelId == nil || channelId?.isEmpty == true)
                }
                Spacer()
                #if os(iOS)
                // Picture-in-Picture button — shown when PiP is enabled in settings and supported on this device
                if store.settings.pipEnabled, let pip = pipController {
                    Button {
                        if isPiPActive {
                            pip.stopPictureInPicture()
                        } else {
                            pip.startPictureInPicture()
                        }
                    } label: {
                        Image(systemName: isPiPActive ? "pip.exit" : "pip.enter")
                            .font(.system(size: 18 * controlScale))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.4))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("player.pipButton")
                }
                #endif
                // Share / Download menu
                Button {
                    swipeLog.notice("[menu] ... button tapped — controlsVisible=\(vm.controlsVisible) showMoreMenu=\(showMoreMenu)")
                    showMoreMenu = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18 * controlScale))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.4))
                        .clipShape(Circle())
                }
                .accessibilityIdentifier("player.moreButton")
                #if os(tvOS)
                .buttonStyle(.plain)
                .scaleEffect(highlightedControl == .more ? 1.5 : 1.0)
                .shadow(color: highlightedControl == .more ? .white.opacity(0.85) : .clear, radius: 12)
                .animation(.easeInOut(duration: 0.15), value: highlightedControl)
                #else
                .buttonStyle(.plain)
                #endif
            }
            .padding(.horizontal, 20)
            #if os(tvOS)
            .padding(.top, 0)
            #else
            .padding(.top, max(safeAreaInsets.top, 20))
            #endif

            Spacer()

            // Centre: rewind / play-pause / forward
            HStack(spacing: 40) {
                #if os(tvOS)
                seekButton(symbol: "gobackward.\(store.settings.seekBackSeconds)",
                           seconds: -Double(store.settings.seekBackSeconds),
                           tvHighlighted: highlightedControl == .seekBack)
                #else
                seekButton(symbol: "gobackward.\(store.settings.seekBackSeconds)",
                           seconds: -Double(store.settings.seekBackSeconds))
                #endif
                playPauseButton
                #if os(tvOS)
                seekButton(symbol: "goforward.\(store.settings.seekForwardSeconds)",
                           seconds: Double(store.settings.seekForwardSeconds),
                           tvHighlighted: highlightedControl == .seekForward)
                #else
                seekButton(symbol: "goforward.\(store.settings.seekForwardSeconds)",
                           seconds: Double(store.settings.seekForwardSeconds))
                #endif
            }
            .disabled(vm.isLoading)
            .opacity(vm.isLoading ? 0.3 : 1)

            Spacer()

            // Bottom: progress bar + prev/next
            VStack(spacing: 8) {
                // Current chapter title — shown whenever chapters are available
                if let chapter = vm.currentChapter {
                    Text(chapter.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: chapter.title)
                }
                progressBar
                HStack {
                    // Previous video button
                    Button {
                        vm.playPrevious()
                    } label: {
                        Image(systemName: AppSymbol.previousTrack)
                            .font(.system(size: 18 * controlScale))
                            .foregroundStyle(vm.hasPrevious && !vm.isLoading ? .white : .white.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    #if os(tvOS)
                    .focusable(false)
                    .scaleEffect(highlightedControl == .prevVideo ? 1.55 : 1.0)
                    .shadow(color: highlightedControl == .prevVideo ? .white.opacity(0.85) : .clear, radius: 14)
                    .animation(.easeInOut(duration: 0.15), value: highlightedControl)
                    #endif
                    .disabled(!vm.hasPrevious || vm.isLoading)

                    // Previous chapter button — only present when the video has chapters
                    if !vm.chapters.isEmpty {
                        Button {
                            vm.skipToPreviousChapter()
                        } label: {
                            Image(systemName: AppSymbol.previousChapter)
                                .font(.system(size: 18 * controlScale))
                                .foregroundStyle(vm.hasPreviousChapter && !vm.isLoading ? .white : .white.opacity(0.3))
                        }
                        .buttonStyle(.plain)
                        #if os(tvOS)
                        .focusable(false)
                        .scaleEffect(highlightedControl == .prevChapter ? 1.55 : 1.0)
                        .shadow(color: highlightedControl == .prevChapter ? .white.opacity(0.85) : .clear, radius: 14)
                        .animation(.easeInOut(duration: 0.15), value: highlightedControl)
                        #endif
                        .disabled(!vm.hasPreviousChapter || vm.isLoading)
                        .accessibilityIdentifier("player.prevChapterBtn")
                    }

                    #if !os(tvOS)
                    Text(formatDuration(vm.currentTime))
                        .padding(.leading, 6)
                    Spacer()
                    Text(formatDuration(vm.duration))
                        .padding(.trailing, 6)
                    #else
                    Spacer()
                    #endif

                    // Next chapter button — only present when the video has chapters
                    if !vm.chapters.isEmpty {
                        Button {
                            vm.skipToNextChapter()
                        } label: {
                            Image(systemName: AppSymbol.nextChapter)
                                .font(.system(size: 18 * controlScale))
                                .foregroundStyle(vm.hasNextChapter && !vm.isLoading ? .white : .white.opacity(0.3))
                        }
                        .buttonStyle(.plain)
                        #if os(tvOS)
                        .focusable(false)
                        .scaleEffect(highlightedControl == .nextChapter ? 1.55 : 1.0)
                        .shadow(color: highlightedControl == .nextChapter ? .white.opacity(0.85) : .clear, radius: 14)
                        .animation(.easeInOut(duration: 0.15), value: highlightedControl)
                        #endif
                        .disabled(!vm.hasNextChapter || vm.isLoading)
                        .accessibilityIdentifier("player.nextChapterBtn")
                    }

                    // Next video button
                    Button {
                        vm.playNext()
                    } label: {
                        Image(systemName: AppSymbol.nextTrack)
                            .font(.system(size: 18 * controlScale))
                            .foregroundStyle(vm.hasNext && !vm.isLoading ? .white : .white.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    #if os(tvOS)
                    .focusable(false)
                    .scaleEffect(highlightedControl == .nextVideo ? 1.55 : 1.0)
                    .shadow(color: highlightedControl == .nextVideo ? .white.opacity(0.85) : .clear, radius: 14)
                    .animation(.easeInOut(duration: 0.15), value: highlightedControl)
                    #endif
                    .disabled(!vm.hasNext || vm.isLoading)
                    .accessibilityIdentifier("player.nextBtn")
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                #if os(tvOS)
                .padding(.horizontal, 40)
                #else
                .padding(.horizontal, 20)
                #endif
            }
            .padding(.bottom, 20)
        }
        .background(
            LinearGradient(
                colors: [.black.opacity(0.6), .clear, .clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
            .contentShape(Rectangle())
            .onTapGesture {
                swipeLog.notice("[menu] gradient background tap — controlsVisible=\(vm.controlsVisible)")
                vm.toggleControls()
            }
        )
        #if os(tvOS)
        // Controls overlay is not a focus section — the outer view handles all input.
        .onTapGesture { vm.toggleControls() }
        #endif
    }

    // MARK: - Control elements
    // moreMenuOverlay / descriptionOverlay / commentsOverlay / loadComments()
    // → PlayerView+Overlays.swift

    private var playPauseButton: some View {
        Button { vm.togglePlayPause() } label: {
            Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 42 * controlScale))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        #if os(tvOS)
        .focusable(false)
        .scaleEffect(highlightedControl == .playPause ? 1.6 : 1.0)
        .shadow(color: highlightedControl == .playPause ? .white.opacity(0.9) : .clear, radius: 16)
        .animation(.easeInOut(duration: 0.15), value: highlightedControl)
        #endif
        .accessibilityIdentifier("player.playPauseButton")
    }

    private func seekButton(symbol: String, seconds: TimeInterval, tvHighlighted: Bool = false) -> some View {
        Button { vm.seekRelative(seconds: seconds) } label: {
            Image(systemName: symbol)
                .font(.system(size: 28 * controlScale))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        #if os(tvOS)
        .focusable(false)
        .scaleEffect(tvHighlighted ? 1.55 : 1.0)
        .shadow(color: tvHighlighted ? .white.opacity(0.85) : .clear, radius: 14)
        .animation(.easeInOut(duration: 0.15), value: tvHighlighted)
        #endif
    }

    private var progressBar: some View {
        #if os(tvOS)
        tvProgressBar
        #else
        iosProgressBar
        #endif
    }

    private var iosProgressBar: some View {
        VStack(spacing: 4) {
            // Tooltip row — always occupies space so layout doesn't jump
            GeometryReader { geo in
                if vm.isScrubbing && vm.duration > 0 {
                    let hPad: CGFloat = 20
                    let trackW = geo.size.width - hPad * 2
                    let fraction = CGFloat(vm.scrubTime / vm.duration)
                    let thumbX = hPad + trackW * fraction
                    let chapterAtScrub = vm.chapters.last(where: { $0.startTime <= vm.scrubTime })
                    let labelW: CGFloat = chapterAtScrub != nil ? min(geo.size.width * 0.5, 180) : 64
                    let clampedX = min(max(thumbX, hPad + labelW / 2), geo.size.width - hPad - labelW / 2)

                    VStack(spacing: 2) {
                        if let chapter = chapterAtScrub {
                            Text(chapter.title)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Text(formatDuration(vm.scrubTime))
                            .font(.caption.monospacedDigit())
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                    .frame(width: labelW)
                    .position(x: clampedX, y: geo.size.height / 2)
                }
            }
            .frame(height: 28)

            // Track + slider row (custom — fully transparent thumb and track)
            GeometryReader { geo in
                let hPad: CGFloat = 20
                let trackW = geo.size.width - hPad * 2
                let time = vm.isScrubbing ? vm.scrubTime : vm.currentTime
                let progress = vm.duration > 0 ? CGFloat(time / vm.duration) : 0
                let thumbX = hPad + trackW * progress

                ZStack {
                    // Background track
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 4)
                        .padding(.horizontal, hPad)

                    // Progress fill
                    HStack(spacing: 0) {
                        Capsule()
                            .fill(Color.red.opacity(0.5))
                            .frame(width: max(thumbX - hPad, 0), height: 4)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, hPad)

                    // Thumb
                    Circle()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 16, height: 16)
                        .position(x: thumbX, y: geo.size.height / 2)
                }
                .overlay(sponsorBlockMarkers)
                .overlay(chapterMarkers)
                .contentShape(Rectangle())
                #if !os(tvOS)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = min(max((value.location.x - hPad) / trackW, 0), 1)
                            if !vm.isScrubbing { vm.beginScrubbing() }
                            vm.updateScrub(to: Double(fraction) * vm.duration)
                        }
                        .onEnded { _ in vm.commitScrub() }
                )
                #endif
            }
            .frame(height: 28)
        }
    }

    // Chapter tick marks on the progress bar — small white notches at each chapter boundary.
    // Each tick has a 24×44 pt transparent tap area so the user can tap to jump to it.
    var chapterMarkers: some View {
        GeometryReader { geo in
            ForEach(vm.chapters) { chapter in
                let x = geo.size.width * CGFloat(chapter.startTime / max(vm.duration, 1))
                ZStack {
                    // Invisible enlarged hit area
                    Color.clear
                        .frame(width: 24, height: 44)
                    // Visible tick
                    Rectangle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 2, height: 12)
                }
                .contentShape(Rectangle())
                .onTapGesture { vm.seek(to: chapter.startTime) }
                .position(x: x, y: geo.size.height / 2)
            }
        }
    }

    // SponsorBlock segment markers on the progress bar
    var sponsorBlockMarkers: some View {
        GeometryReader { geo in
            ForEach(vm.sponsorSegments) { seg in
                let x = geo.size.width * CGFloat(seg.start / max(vm.duration, 1))
                let w = geo.size.width * CGFloat((seg.end - seg.start) / max(vm.duration, 1))
                Rectangle()
                    .fill(seg.category.color.opacity(0.8))
                    .frame(width: max(w, 2), height: 4)
                    .position(x: x + w / 2, y: geo.size.height / 2)
            }
        }
    }

    private var sponsorSkipToast: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if let seg = vm.currentToastSegment {
                    Button("Skip \(seg.category.displayName)") {
                        vm.skipToastSegment()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(seg.category.color)
                    .padding()
                    .transition(.move(edge: .trailing))
                }
            }
        }
        .animation(.easeInOut, value: vm.currentToastSegment?.id)
    }

    private func errorBanner(_ err: Error) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: AppSymbol.warning)
                    .foregroundStyle(.yellow)
                Text(err.localizedDescription)
                    .font(.callout)
                    .foregroundStyle(.white)
            }
            Button {
                vm.retryLoad()
            } label: {
                Text("Try Again")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.white)
                    .clipShape(Capsule())
            }
            .accessibilityIdentifier("player.retryButton")
        }
        .padding()
        .background(.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding()
        .accessibilityIdentifier("player.errorBanner")
    }

    // MARK: - Picker overlays + share sheet
    // qualityPickerOverlay / speedPickerOverlay / sleepTimerPickerOverlay
    // captionPickerOverlay / audioTrackPickerOverlay / presentShareSheet(url:)
    // → PlayerView+PickerOverlays.swift
}

// MARK: - StatsForNerdsOverlay

struct StatsForNerdsOverlay: View {
    let snapshot: StatsForNerdsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            row("Video ID",         snapshot.videoId)
            row("Resolution",       snapshot.fps > 0
                    ? "\(snapshot.displayResolution) @ \(snapshot.fps) fps"
                    : snapshot.displayResolution)
            row("Codec",            snapshot.codec)
            row("Nominal Bitrate",  snapshot.nominalBitrate)
            row("Connection Speed", snapshot.observedBitrate)
            row("Dropped Frames",   "\(snapshot.droppedFrames)")
            row("Stalls",           "\(snapshot.stalls)")
            Text("Two-finger tap to dismiss")
                .foregroundStyle(.white.opacity(0.4))
                .font(.system(.caption2, design: .monospaced))
                .padding(.top, 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
        .padding(.top, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .foregroundStyle(.white.opacity(0.55))
                .frame(minWidth: 130, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .foregroundStyle(.white)
        }
        .font(.system(.caption, design: .monospaced))
    }
}

// MARK: - FullScreenPlayerLayerView (iOS)

#if os(iOS)
/// UIViewRepresentable that embeds the shared PersistentPlayerHostView into the
/// full-screen player context. UIView.addSubview transplants the hostView from
/// the mini-player container automatically, keeping the AVPlayerLayer live.
private struct FullScreenPlayerLayerView: UIViewRepresentable {
    let hostView: PersistentPlayerHostView
    var videoGravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.isAccessibilityElement = false
        container.accessibilityElementsHidden = true
        hostView.videoGravity = videoGravity
        hostView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostView)
        NSLayoutConstraint.activate([
            hostView.topAnchor.constraint(equalTo: container.topAnchor),
            hostView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        hostView.videoGravity = videoGravity
    }
}
#endif

// MARK: - AVPlayerLayerView

#if os(iOS) || os(tvOS)
/// Lightweight UIViewRepresentable wrapping an `AVPlayerLayer` directly.
/// Unlike `VideoPlayer` / `AVPlayerViewController`, it does not interfere
/// with the UIKit accessibility tree so SwiftUI overlays remain reachable.
/// On tvOS, `AVPlayerViewController` would provide system transport controls
/// but `AVPlayerLayer` is used here for layout consistency with iOS.
private struct AVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    var onLayerReady: ((AVPlayerLayer) -> Void)? = nil

    func makeUIView(context: Context) -> _PlayerUIView {
        let view = _PlayerUIView()
        view.backgroundColor = .black
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        view.onLayerReady = onLayerReady
        return view
    }

    func updateUIView(_ uiView: _PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = videoGravity
    }

    final class _PlayerUIView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var onLayerReady: ((AVPlayerLayer) -> Void)?
        private var didFireCallback = false

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            guard newWindow != nil, !didFireCallback else { return }
            didFireCallback = true
            // Defer to next run-loop tick so the layer has a non-zero frame.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onLayerReady?(self.playerLayer)
            }
        }
    }
}

// MARK: - PiPDelegate

/// AVPictureInPictureControllerDelegate that notifies a SwiftUI closure when
/// PiP starts or stops, and implements the restore callback required for a
/// smooth transition back to full-screen without rebuffering.
private final class PiPDelegate: NSObject, AVPictureInPictureControllerDelegate {
    private let onActiveChange: (Bool) -> Void

    init(onActiveChange: @escaping (Bool) -> Void) {
        self.onActiveChange = onActiveChange
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        onActiveChange(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        onActiveChange(false)
    }

    /// Called when the user taps the PiP window to return to the app.
    /// Must call completionHandler(true) once the UI is ready to show the video
    /// again — without this iOS cannot complete the restore animation and the
    /// player rebuffers/stutters.
    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // The AVPlayerLayer is always present and visible in PlayerView, so the
        // UI is immediately ready. Calling completionHandler(true) right away
        // lets AVKit animate the video seamlessly back into the layer.
        completionHandler(true)
    }
}

// MARK: - HoldSpeedBadge

private struct HoldSpeedBadge: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "forward.fill")
                .font(.system(size: 20, weight: .semibold))
            Text("2×")
                .font(.system(size: 14, weight: .bold, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .allowsHitTesting(false)
    }
}

// MARK: - SwipeGestureOverlay (horizontal)

#if os(iOS)
/// Left swipe → `onSwipeLeft`, right swipe → `onSwipeRight`, tap → `onTap`.
/// Set `isEnabled = false` (e.g. while the progress slider is being scrubbed) to
/// temporarily suppress pan recognition so the scrub drag is not mistaken for a swipe.
private struct SwipeGestureOverlay: UIViewRepresentable {
    var onSwipeLeft:        () -> Void
    var onSwipeRight:       () -> Void
    var onTap:              () -> Void
    var onDoubleTap:        () -> Void = {}
    var onTwoFingerTap:     () -> Void = {}
    var onPanChanged:       ((CGFloat) -> Void)?
    var onSwipeCancelled:   (() -> Void)?
    var onLongPressStart:   (() -> Void)?
    var onLongPressEnd:     (() -> Void)?
    var onSwipeDown:        (() -> Void)? = nil
    var isEnabled:          Bool = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.cancelsTouchesInView = true
        view.addGestureRecognizer(pan)
        context.coordinator.pan = pan

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.require(toFail: pan)
        view.addGestureRecognizer(doubleTap)
        context.coordinator.doubleTap = doubleTap

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                          action: #selector(Coordinator.handleTap))
        tap.cancelsTouchesInView = false
        tap.require(toFail: pan)
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(tap)
        context.coordinator.tap = tap

        let twoFingerTap = UITapGestureRecognizer(target: context.coordinator,
                                                   action: #selector(Coordinator.handleTwoFingerTap))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.cancelsTouchesInView = false
        view.addGestureRecognizer(twoFingerTap)

        let longPress = UILongPressGestureRecognizer(target: context.coordinator,
                                                      action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.4
        longPress.cancelsTouchesInView = false
        view.addGestureRecognizer(longPress)
        context.coordinator.longPress = longPress

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.pan?.isEnabled = isEnabled
        context.coordinator.tap?.isEnabled = isEnabled
        context.coordinator.doubleTap?.isEnabled = isEnabled
        context.coordinator.longPress?.isEnabled = isEnabled
    }

    final class Coordinator: NSObject {
        var parent: SwipeGestureOverlay
        weak var pan: UIPanGestureRecognizer?
        weak var tap: UITapGestureRecognizer?
        weak var doubleTap: UITapGestureRecognizer?
        weak var longPress: UILongPressGestureRecognizer?
        private let minDistance: CGFloat = 40

        init(_ parent: SwipeGestureOverlay) { self.parent = parent }

        @MainActor @objc func handlePan(_ gr: UIPanGestureRecognizer) {
            let t = gr.translation(in: gr.view)
            switch gr.state {
            case .changed:
                // Only forward horizontal pan for slide-offset animation.
                if abs(t.x) >= abs(t.y) { parent.onPanChanged?(t.x) }
            case .ended:
                // Swipe-down: vertical-dominant, downward, meets threshold → minimize
                if abs(t.y) > minDistance, t.y > 0, abs(t.y) > abs(t.x) {
                    parent.onSwipeCancelled?() // reset any horizontal offset
                    parent.onSwipeDown?()
                    return
                }
                guard abs(t.x) > minDistance, abs(t.x) > abs(t.y) else {
                    parent.onSwipeCancelled?()
                    return
                }
                if t.x < 0 { parent.onSwipeLeft() } else { parent.onSwipeRight() }
            case .cancelled, .failed:
                parent.onSwipeCancelled?()
            default:
                break
            }
        }

        @MainActor @objc func handleTap() { parent.onTap() }
        @MainActor @objc func handleDoubleTap() { parent.onDoubleTap() }
        @MainActor @objc func handleTwoFingerTap() { parent.onTwoFingerTap() }

        @MainActor @objc func handleLongPress(_ gr: UILongPressGestureRecognizer) {
            switch gr.state {
            case .began:
                parent.onLongPressStart?()
            case .ended, .cancelled, .failed:
                parent.onLongPressEnd?()
            default:
                break
            }
        }
    }
}
#endif // os(iOS)
#endif // os(iOS) || os(tvOS)

// MARK: - RelatedVideosView
struct RelatedVideosView: View {
    let videos: [Video]
    let onSelect: (Video) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(videos) { video in
                    VideoCardView(video: video, compact: true)
                        .padding(.horizontal)
                        .onTapGesture { onSelect(video) }
                }
            }
        }
    }
}

// MARK: - CommentRowView

struct CommentRowView: View {
    let comment: Comment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: comment.authorAvatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(Color.secondary.opacity(0.3))
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.author)
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text(comment.publishedTime)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(comment.text)
                    .font(.callout)
                if !comment.likeCount.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "hand.thumbsup")
                            .font(.caption2)
                        Text(comment.likeCount)
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - EndCardOverlay

/// Positions YouTube end-screen cards absolutely within the player bounds.
/// Cards are shown only during their `startMs…endMs` window and dismissed when
/// the controls overlay is visible (consistent with official YouTube behaviour).
#if !os(tvOS)
private struct EndCardOverlay: View {
    let cards: [EndCard]
    let currentTime: TimeInterval
    let size: CGSize
    let onSelect: (EndCard) -> Void

    private var visibleCards: [EndCard] {
        let ms = Int(currentTime * 1000)
        return cards.filter { $0.style == .video && $0.videoId != nil && ms >= $0.startMs && ms <= $0.endMs }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(visibleCards) { card in
                let cardWidth  = card.width / 100 * size.width
                let cardHeight = cardWidth / max(card.aspectRatio, 0.1)
                let x          = card.left / 100 * size.width
                let y          = card.top  / 100 * size.height
                EndCardButton(card: card, width: cardWidth, height: cardHeight, onSelect: onSelect)
                    .offset(x: x, y: y)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .animation(.easeOut(duration: 0.2), value: visibleCards.count)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(!visibleCards.isEmpty)
    }
}

private struct EndCardButton: View {
    let card: EndCard
    let width: CGFloat
    let height: CGFloat
    let onSelect: (EndCard) -> Void

    var body: some View {
        Button { onSelect(card) } label: {
            ZStack(alignment: .bottom) {
                AsyncImage(url: card.thumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Color.gray.opacity(0.4)
                    }
                }
                .frame(width: width, height: height)
                .clipped()

                if !card.title.isEmpty {
                    Text(card.title)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.65))
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.white.opacity(0.4), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("End card: \(card.title)")
    }
}
#endif

// MARK: - AppSettings.VideoGravityMode → AVLayerVideoGravity mapping

private extension AppSettings.VideoGravityMode {
    var avGravity: AVLayerVideoGravity {
        self == .fill ? .resizeAspectFill : .resizeAspect
    }
}
