#if os(macOS)
import SwiftUI
import WebKit
import SmartTubeIOSCore

// MARK: - TOSPlayerView
//
// macOS-only player backed by the YouTube IFrame API in a WKWebView.
// Renders YouTube's own player chrome (controls:1) with a native close
// button and SponsorBlock skip toast overlaid on top.
//
// Entry path:
//   MainSidebarView (RootView.swift)
//     └─ store.settings.useTOSPlayerOnMac == true
//          └─ TOSPlayerView(video:)
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

    @State private var vm: TOSPlayerViewModel

    public init(video: Video, onFallback: @escaping () -> Void = {}) {
        self.video = video
        self.onFallback = onFallback
        // startTime defaults to 0; saved position is restored asynchronously
        // in .task once the view has appeared (see body below).
        _vm = State(initialValue: TOSPlayerViewModel(videoId: video.id, startTime: 0))
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            // MARK: WKWebView layer
            YouTubeWebPlayerView(webView: vm.webView)
                .ignoresSafeArea()

            // MARK: Close button (top-left, always visible)
            closeButton

            // MARK: SponsorBlock skip toast (bottom-centre)
            if let seg = vm.currentToastSegment {
                sponsorToast(for: seg)
            }
        }
        // Invisible AX label exposing player state for UI tests.
        // Mirrors player.titleLabel / player.probeStreamResult on PlayerView.
        .overlay(alignment: .topTrailing) {
            Text(vm.playerState == .playing ? "playing"
                 : vm.playerState == .paused ? "paused"
                 : vm.playerState == .buffering ? "buffering"
                 : vm.playerState == .ended ? "ended" : "unstarted")
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityIdentifier("tosPlayer.stateLabel")
                .accessibilityHidden(false)
        }
        .background(Color.black)
        .ignoresSafeArea()
        .onAppear {
            vm.updateSettings(store.settings)
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
        .onChange(of: vm.playerError) { _, error in
            guard let error, error.isFatal else { return }
            browseVM.deepLinkedVideo = nil
            onFallback()
        }
    }

    // MARK: - Close button

    private var closeButton: some View {
        Button {
            // Clear deep-link overlay path AND pop NavigationStack path.
            browseVM.deepLinkedVideo = nil
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(.top, 16)
        .padding(.leading, 16)
        .accessibilityIdentifier("tosPlayer.closeButton")
        .accessibilityLabel("Close")
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

#endif // os(macOS)
