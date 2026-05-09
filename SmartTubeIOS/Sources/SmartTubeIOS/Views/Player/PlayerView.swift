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
    @State var slideOffset: CGFloat = 0
    @State var isTransitioning = false
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
    /// Drives the brief seek-direction toast shown after a double-tap in the left/right zone.
    @State private var seekToastMessage: String?
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
    var controlScale: CGFloat {
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
                // PlayerAVLayerView: bare AVPlayerLayer without AVPlayerViewController.
                // AVPlayerViewController (VideoPlayer) dominates the UIKit accessibility
                // tree, making all overlaid SwiftUI elements invisible to XCUITest.
                PlayerAVLayerView(player: vm.player, videoGravity: store.settings.videoGravityMode.avGravity)
                .ignoresSafeArea()
                .accessibilityHidden(true)
                #else
                Color.black.ignoresSafeArea()
                #endif

                #if os(iOS)
                // Horizontal swipe layer: left → next video, right → previous video.
                // Uses UIKit-level UIPanGestureRecognizer so it fires above AVPlayerLayer.
                PlayerSwipeGestureOverlay(
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
                    onDoubleTap: { normalizedX in
                        if normalizedX < 1.0 / 3.0 {
                            vm.seekRelative(seconds: -Double(store.settings.seekBackSeconds))
                            seekToastMessage = "← \(store.settings.seekBackSeconds)s"
                        } else if normalizedX > 2.0 / 3.0 {
                            vm.seekRelative(seconds: Double(store.settings.seekForwardSeconds))
                            seekToastMessage = "\(store.settings.seekForwardSeconds)s →"
                        } else {
                            let newMode: AppSettings.VideoGravityMode =
                                store.settings.videoGravityMode == .fit ? .fill : .fit
                            store.settings.videoGravityMode = newMode
                            scaleToast = newMode == .fill ? "Fill" : "Fit"
                        }
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
                    onSwipeDown: { store.settings.miniPlayerEnabled ? playerState.minimize() : playerState.stop() },
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
                        .allowsHitTesting(false)
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
                                    // Swipe-down → minimize to mini-player (or stop if disabled)
                                    if dy > 50, abs(dy) > abs(dx) {
                                        store.settings.miniPlayerEnabled ? playerState.minimize() : playerState.stop()
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
        .toast(message: $seekToastMessage)
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
                // Controls visible but nav not started yet.
                // Left/right seeks directly (Siri Remote gen 1 edge-tap and D-pad seek UX);
                // up/down enters control-navigation mode so the user can reach other buttons.
                switch direction {
                case .left:  vm.seekRelative(seconds: -Double(store.settings.seekBackSeconds))
                case .right: vm.seekRelative(seconds: Double(store.settings.seekForwardSeconds))
                default:
                    highlightedControl = .playPause
                    vm.showControls()
                }
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
                    swipeLog.notice("[PlayerView] backButton tapped — miniPlayerEnabled=\(store.settings.miniPlayerEnabled) presentation=\(String(describing: playerState.presentation))")
                    if store.settings.miniPlayerEnabled { playerState.minimize() } else { playerState.stop() }
                    swipeLog.notice("[PlayerView] backButton — done, presentation=\(String(describing: playerState.presentation))")
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
                    swipeLog.notice("[tv] --uitesting-open-more-menu: setting showMoreMenu=true")
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
    // performHorizontalTransition(direction:screenWidth:action:)
    // → PlayerView+ControlElements.swift

    // MARK: - Controls overlay

    private func controlsOverlay(size: CGSize, safeAreaInsets: EdgeInsets) -> some View {
        VStack {
            // Top bar: back + title
            HStack {
                Button {
                    #if os(iOS)
                    if store.settings.miniPlayerEnabled { playerState.minimize() } else { playerState.stop() }
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
    // playPauseButton / seekButton / progressBar / iosProgressBar /
    // chapterMarkers / sponsorBlockMarkers / sponsorSkipToast / errorBanner
    // → PlayerView+ControlElements.swift

    // MARK: - Picker overlays + share sheet
    // qualityPickerOverlay / speedPickerOverlay / sleepTimerPickerOverlay
    // captionPickerOverlay / audioTrackPickerOverlay / presentShareSheet(url:)
    // → PlayerView+PickerOverlays.swift
}
