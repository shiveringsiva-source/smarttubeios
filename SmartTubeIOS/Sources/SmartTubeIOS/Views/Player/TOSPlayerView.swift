#if !os(tvOS)
import SwiftUI
import WebKit
import SmartTubeIOSCore
import os

private let tosViewLog = Logger(subsystem: "com.void.smarttube.app", category: "TOSPlayer")

// MARK: - TOSPlayerView
//
// macOS-only player backed by the YouTube IFrame API in a WKWebView.
// Renders YouTube's own player chrome (controls:1) with a SponsorBlock skip
// toast overlaid on top. Dismissal is via Esc (.onExitCommand below) — see
// its doc comment for why there is deliberately no on-screen back/close button.
//
// Entry path:
//   MainSidebarView (RootView.swift)
//     └─ store.settings.useTOSPlayerOnMac == true
//          └─ TOSPlayerView(video:api:)
//
// When the IFrame player returns error 101/150 (embedding disabled) or 100
// (not found), `playerError.isFatal` is true and this view calls `onFallback`
// so the caller can show the standard PlayerView instead.

public struct TOSPlayerView: View {
    public let video: Video
    /// Called when the IFrame player hits a fatal error and we must fall back
    /// to the standard AVPlayer-based PlayerView.
    public var onFallback: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var store
    @Environment(BrowseViewModel.self) private var browseVM
    @Environment(AuthService.self) private var authService

    @State private var vm: TOSPlayerViewModel

    public init(video: Video, api: InnerTubeAPI, onFallback: @escaping () -> Void = {}) {
        self.video = video
        self.onFallback = onFallback
        // startTime defaults to 0; saved position is restored asynchronously
        // in .task once the view has appeared (see body below).
        // `api` is threaded through so TOSPlayerViewModel can drive a WatchtimeTracker
        // (history/position-checkpoint parity with the standard PlayerView — see
        // TOSPlayerViewModel.saveProgress()).
        _vm = State(initialValue: TOSPlayerViewModel(videoId: video.id, channelId: video.channelId, startTime: 0, api: api))
    }

    public var body: some View {
        // GeometryReader captures `geo.safeAreaInsets` BEFORE `.ignoresSafeArea()`
        // erases them — same pattern as PlayerControlsOverlay's
        // `.padding(.top, max(safeAreaInsets.top, 20))` (PlayerView+ControlElements).
        //
        // Why this matters here specifically: TOSPlayerView is presented as a
        // full-window ZStack overlay *inside* RootView's content view (see
        // RootView.body — `if let video = browseVM.deepLinkedVideo { TOSPlayerView(...) }`),
        // sitting alongside (not replacing) the NavigationSplitView. macOS draws the
        // window's titlebar/toolbar (traffic lights, sidebar toggle, back chevron,
        // "SmartTube" title) as OS-level chrome ABOVE the content view's z-order —
        // no amount of SwiftUI overlay/zIndex/.ignoresSafeArea() can cover it, because
        // it isn't part of the content view's layer at all. `safeAreaInsets.top` is
        // exactly the height SwiftUI reserves to avoid drawing under that chrome, so
        // anchoring topRightControls below it (instead of a flat offset that lands
        // those controls under/behind the sidebar-toggle and back-chevron controls)
        // keeps them clear of it.
        //
        // NOTE: there is intentionally NO on-screen back/close button here anymore —
        // every attempt at one (an "X" close button, then a back-chevron button)
        // ended up rendered in/near the OS-level titlebar chrome (traffic lights,
        // sidebar toggle) — the "strange position" complaint that kept resurfacing
        // no matter how the anchoring math was tuned, because that chrome floats
        // above the content view's z-order and isn't something SwiftUI layout can
        // reliably steer clear of from inside this view. Esc (.onExitCommand below)
        // is the dismissal path now — see its doc comment.
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // MARK: WKWebView layer
                YouTubeWebPlayerView(webView: vm.webView)
                    .ignoresSafeArea()

                // MARK: Top-right control cluster — more menu (like/dislike, sleep
                // timer, share) + playback speed picker. See topRightControls for why
                // these are native Menus rather than ports of the standard player's
                // custom overlay views.
                topRightControls(topInset: geo.safeAreaInsets.top)

                // MARK: SponsorBlock skip toast (bottom-centre)
                if let seg = vm.currentToastSegment {
                    sponsorToast(for: seg)
                }
            }
        }
        // Invisible AX label exposing player state for UI tests.
        // Mirrors player.titleLabel / player.probeStreamResult on PlayerView.
        // foregroundColor(.clear) keeps the text in the AX tree with a readable
        // label while being visually transparent. opacity(0/0.001) and frame(1,1)
        // both cause macOS 26 AX to return an empty label.
        .overlay(alignment: .topTrailing) {
            Text(vm.playerState == .playing || vm.playerState == .buffering ? "playing"
                 : vm.playerState == .paused ? "paused"
                 : vm.playerState == .ended ? "ended" : "unstarted")
                .foregroundColor(.clear)  // visually invisible; AX still reads text
                .font(.caption2)
                .allowsHitTesting(false)
                .accessibilityIdentifier("tosPlayer.stateLabel")
                .accessibilityHidden(false)
        }
        .background(Color.black)
        .ignoresSafeArea()
        .onAppear {
            vm.updateSettings(store.settings)
            vm.startIfNeeded()
        }
        // Pause the embedded <video> element when this view leaves the hierarchy —
        // via the Esc key or a fallback transition. Without this,
        // the WKWebView keeps playing (and audio keeps being heard) after the player
        // UI has been dismissed, since nothing else stops it.
        //
        // saveProgress() mirrors the standard PlayerView's vm.suspend()/vm.stop() —
        // both of which checkpoint the watch position from the same onDisappear hook
        // (see PlayerView+Lifecycle.swift). Without it, closing a TOS-played video
        // silently lost the watch position (resume-from-last-position and "continue
        // watching"/history never worked for TOS sessions — see WatchtimeTracker).
        .onDisappear {
            tosViewLog.notice("[TOSPlayerView] onDisappear — videoId=\(self.video.id, privacy: .public) playerState=\(String(describing: vm.playerState), privacy: .public) currentTime=\(vm.currentTime, format: .fixed(precision: 1))s — pausing & checkpointing")
            vm.pause()
            vm.saveProgress()
        }
        // Esc key closes the player. This is the ONLY dismissal path now — every
        // on-screen back/close button tried so far ("X", then a back-chevron)
        // ended up rendered on/near the OS-level titlebar chrome (traffic lights,
        // sidebar toggle, native back chevron) no matter how its position was
        // anchored, because that chrome floats above the content view's z-order —
        // SwiftUI layout from inside this view simply can't steer reliably clear
        // of it. TOSPlayerView is presented as a conditional full-window overlay
        // (RootView: `if let video = browseVM.deepLinkedVideo`), not pushed onto a
        // NavigationStack, so the window's own titlebar "Back" chevron belongs to
        // the browse content underneath and does not affect this overlay at all —
        // Esc is genuinely the only way in.
        .onExitCommand {
            browseVM.deepLinkedVideo = nil
            dismiss()
        }
        // Restore saved watch position asynchronously.
        // We seek once the player reports .playing or .paused (i.e. after onReady fires)
        // so the IFrame API is ready to accept seekTo() calls.
        .task {
            let saved = await VideoStateStore.shared.state(for: video.id)?.position ?? 0
            guard saved > 1 else { return }
            // Poll briefly for player readiness before seeking.
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard vm.isReady else { continue }
                vm.seekTo(saved)
                return
            }
        }
        // Watch for fatal IFrame errors → fall back to standard player.
        // Do NOT clear deepLinkedVideo here — RootView uses tosPlayerFallbackVideoId
        // (set by onFallback()) to switch from TOSPlayerView to PlayerView while
        // keeping deepLinkedVideo set so the standard player can open the same video.
        .onChange(of: vm.playerError) { _, error in
            guard let error else { return }
            tosViewLog.notice("[TOSPlayerView] playerError=\(String(describing: error)) isFatal=\(error.isFatal)")
            guard error.isFatal else { return }
            tosViewLog.notice("[TOSPlayerView] ⚠️ fatal error — triggering fallback to standard player")
            onFallback()
        }
    }

    // MARK: - Top-right control cluster (speed + more)
    //
    // Both rendered as native macOS `Menu`s rather than the standard player's custom
    // overlay+backdrop pickers / more-menu sheet: controls:1 leaves no "more menu"
    // affordance to anchor a picker sheet from, and a Menu needs no new
    // dismissal/animation/focus state of its own — it's the idiomatic macOS control
    // for "pick one of a short list", and a `Menu`-of-`Menu`s is itself a minimal,
    // zero-new-state stand-in for the "more menu" the architecture analysis flagged
    // as a prerequisite for richer transfers (queue, captions, description, etc.) —
    // this is the lightest possible version of that affordance, available today
    // without waiting on the controls:0 fork.
    private func topRightControls(topInset: CGFloat) -> some View {
        HStack(spacing: 8) {
            Spacer()
            moreButton
            speedButton
        }
        .padding(.top, max(topInset, 16))
        .padding(.trailing, 16)
    }

    /// Transferred from PlayerView+PickerOverlays.speedPickerOverlay — same source of
    /// truth (`AppSettings.availableSpeeds` / `store.settings.playbackSpeed`) and the
    /// same JS-bridge call (`vm.setPlaybackRate`). Current rate is read live from
    /// `vm.playbackRate`, which the JS bridge already reports via "rateChange"/"tick".
    private var speedButton: some View {
        Menu {
            ForEach(AppSettings.availableSpeeds, id: \.self) { speed in
                Button {
                    store.settings.playbackSpeed = speed
                    vm.setPlaybackRate(speed)
                } label: {
                    if abs(vm.playbackRate - speed) < 0.01 {
                        Label(speedLabel(for: speed), systemImage: "checkmark")
                    } else {
                        Text(speedLabel(for: speed))
                    }
                }
            }
        } label: {
            Text(speedLabel(for: vm.playbackRate))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("tosPlayer.speedButton")
        .accessibilityLabel("Playback speed")
    }

    private func speedLabel(for speed: Double) -> String {
        speed == 1.0 ? "Normal (1\u{d7})" : String(format: "%.2g\u{d7}", speed)
    }

    // MARK: - More menu (Like/Dislike, Sleep Timer, Share)
    //
    // Transfer of three self-contained, AVPlayer-independent standard-player features
    // that previously had zero presence in TOS:
    //   • Like/Dislike  — PlaybackViewModel+LikeDislike.swift: pure InnerTubeAPI calls
    //                     with optimistic update + rollback. Gated on sign-in, mirroring
    //                     moreMenuLikeDislikeRow's `if authService.isSignedIn` guard.
    //   • Sleep Timer   — PlaybackViewModel+SleepTimer.swift: schedules a Task that
    //                     calls player.pause(); TOS only needed vm.pause() to slot in.
    //   • Share         — pure metadata (no player dependency at all).
    private var moreButton: some View {
        Menu {
            if authService.isSignedIn {
                Button {
                    vm.like()
                } label: {
                    Label(vm.likeStatus == .like ? "Liked" : "Like",
                          systemImage: vm.likeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
                }
                .accessibilityIdentifier("tosPlayer.moreMenu.likeRow")

                Button {
                    vm.dislike()
                } label: {
                    Label(vm.likeStatus == .dislike ? "Disliked" : "Dislike",
                          systemImage: vm.likeStatus == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                }
                .accessibilityIdentifier("tosPlayer.moreMenu.dislikeRow")

                Divider()
            }

            Menu {
                Button {
                    vm.setSleepTimer(minutes: nil)
                } label: {
                    if vm.sleepTimerMinutes == nil {
                        Label("Off", systemImage: "checkmark")
                    } else {
                        Text("Off")
                    }
                }
                ForEach(PlaybackViewModel.sleepTimerOptions, id: \.self) { mins in
                    Button {
                        vm.setSleepTimer(minutes: mins)
                    } label: {
                        if vm.sleepTimerMinutes == mins {
                            Label("\(mins) minutes", systemImage: "checkmark")
                        } else {
                            Text("\(mins) minutes")
                        }
                    }
                }
            } label: {
                Label(sleepTimerLabel, systemImage: "moon.zzz")
            }
            .accessibilityIdentifier("tosPlayer.moreMenu.sleepTimerRow")

            if let url = URL(string: "https://www.youtube.com/watch?v=\(video.id)") {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("tosPlayer.moreMenu.shareRow")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("tosPlayer.moreButton")
        .accessibilityLabel("More")
    }

    private var sleepTimerLabel: String {
        guard let minutes = vm.sleepTimerMinutes else { return "Sleep Timer" }
        return "Sleep Timer (\(minutes)m)"
    }

    // MARK: - SponsorBlock toast

    private func sponsorToast(for segment: SponsorSegment) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    vm.seekTo(segment.end)
                    vm.currentToastSegment = nil
                } label: {
                    Label(skipLabel(for: segment.category), systemImage: "forward.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 20)
                .padding(.bottom, 60)
            }
        }
        .accessibilityIdentifier("tosPlayer.skipToast")
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: vm.currentToastSegment?.start)
    }

    private func skipLabel(for category: SponsorSegment.Category) -> String {
        switch category {
        case .sponsor:       return "Skip Sponsor"
        case .selfPromo:     return "Skip Self-Promo"
        case .interaction:   return "Skip Interaction"
        case .intro:         return "Skip Intro"
        case .outro:         return "Skip Outro"
        case .preview:       return "Skip Preview"
        case .filler:        return "Skip Filler"
        case .musicOfftopic: return "Skip Music"
        case .poiHighlight:  return "Skip to Highlight"
        }
    }
}

// MARK: - YouTubeWebPlayerView (NSViewRepresentable)

/// Wraps the `WKWebView` owned by `TOSPlayerViewModel` in an `NSView`
/// so SwiftUI can host it. The view model owns the WKWebView instance;
/// this representable just displays it.
private struct YouTubeWebPlayerView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView.autoresizingMask = [.width, .height]
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

#endif // !os(tvOS)
