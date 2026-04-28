import SwiftUI
import AVFoundation
import SmartTubeIOSCore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - ShortsPlayerView
//
// Full-screen vertical-swipe player for YouTube Shorts.
// Swipe up advances to the next short; swipe down goes to the previous one.
//
// AVPlayerViewController intercepts all UIKit touches before SwiftUI sees them,
// so a plain SwiftUI DragGesture layered above VideoPlayer is never delivered.
// Instead, a UIViewRepresentable installs a UIPanGestureRecognizer directly
// into the window that is set to cancel the AVPlayer's own recognizers, giving
// SwiftUI-side navigation full priority.

public struct ShortsPlayerView: View {
    public let startIndex: Int
    @State private var videos: [Video]
    @State private var vm = PlaybackViewModel()
    @State private var currentIndex: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var store
    @State private var slideOffset: CGFloat = 0
    @State private var isTransitioning = false
    @State private var isFetchingMore = false
    @State private var channelDestination: ChannelDestination?
    private let api = InnerTubeAPI()

    public init(videos: [Video], startIndex: Int = 0) {
        self.startIndex = startIndex
        self._videos = State(initialValue: videos)
        self._currentIndex = State(initialValue: startIndex)
    }

    private var currentVideo: Video { videos[currentIndex] }

    public var body: some View {
        NavigationStack {
        ZStack {
            Color.black.ignoresSafeArea()

            if ProcessInfo.processInfo.arguments.contains("--uitesting") {
                Color.black.ignoresSafeArea()
            } else {
                #if os(iOS) || os(tvOS)
                // AVPlayerLayerView instead of VideoPlayer/AVPlayerViewController.
                // Using AVPlayerViewController (VideoPlayer) causes it to dominate
                // the entire UIKit accessibility tree, hiding all overlaid SwiftUI
                // elements (index badge, controls). A bare AVPlayerLayer renders
                // video without any UIKit accessibility interference.
                AVPlayerLayerView(player: vm.player)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                #else
                Color.black.ignoresSafeArea()
                #endif
            }

            // Gesture capture layer — a UIViewRepresentable that installs a
            // UIPanGestureRecognizer at the UIKit level so it fires even when
            // AVPlayerViewController is absorbing touches below.
            #if os(iOS)
            SwipeGestureOverlay(
                onSwipeUp: {
                    guard !isTransitioning else { return }
                    if let next = ShortsNavigation.targetIndex(vertical: -100, horizontal: 0, current: currentIndex, count: videos.count) {
                        performVerticalTransition(direction: -1) { goTo(next) }
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { slideOffset = 0 }
                    }
                },
                onSwipeDown: {
                    guard !isTransitioning else { return }
                    if let prev = ShortsNavigation.targetIndex(vertical: 100, horizontal: 0, current: currentIndex, count: videos.count) {
                        performVerticalTransition(direction: 1) { goTo(prev) }
                    } else {
                        loadMoreAtStart()
                    }
                },
                onTap: { vm.showControls() },
                onTwoFingerTap: { vm.toggleStatsForNerds() },
                onPanChanged: { dy in
                    guard !isTransitioning else { return }
                    let canGoUp   = ShortsNavigation.targetIndex(vertical: -100, horizontal: 0, current: currentIndex, count: videos.count) != nil
                    let canGoDown = ShortsNavigation.targetIndex(vertical:  100, horizontal: 0, current: currentIndex, count: videos.count) != nil
                    if (dy < 0 && canGoUp) || (dy > 0 && canGoDown) {
                        slideOffset = dy
                    } else {
                        slideOffset = dy * 0.15  // rubber-band resistance at boundaries
                    }
                },
                onSwipeCancelled: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { slideOffset = 0 }
                }
            )
            .ignoresSafeArea()
            .accessibilityHidden(true)
            #endif

            if vm.isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.5)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: vm.isLoading)
            }

            if vm.controlsVisible {
                shortsOverlay
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: vm.controlsVisible)
            }

            if let err = vm.error {
                Text(err.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Stats for Nerds overlay (toggled by two-finger tap)
            if vm.statsForNerdsVisible {
                StatsForNerdsOverlay(snapshot: vm.statsSnapshot)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: vm.statsForNerdsVisible)
            }
        }
        .offset(y: slideOffset)
        .background(Color.black.ignoresSafeArea())
        #if os(tvOS)
        // Siri Remote D-pad: up/down navigate prev/next short.
        .onMoveCommand { direction in
            guard !isTransitioning else { return }
            switch direction {
            case .up:
                if let next = ShortsNavigation.targetIndex(vertical: -100, horizontal: 0, current: currentIndex, count: videos.count) {
                    performVerticalTransition(direction: -1) { goTo(next) }
                }
            case .down:
                if let prev = ShortsNavigation.targetIndex(vertical: 100, horizontal: 0, current: currentIndex, count: videos.count) {
                    performVerticalTransition(direction: 1) { goTo(prev) }
                }
            default:
                vm.toggleControls()
            }
        }
        #endif
        // indexBadge is placed OUTSIDE the ZStack as an overlay so it lives at
        // the top-level SwiftUI view layer, away from UIViewRepresentable elements
        // inside the ZStack that can absorb the accessibility tree in fullScreenCover.
        .overlay(alignment: .topTrailing) {
            indexBadge
        }
        .overlay(alignment: .bottomTrailing) {
            if isFetchingMore {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .padding(12)
                    .background(.black.opacity(0.4))
                    .clipShape(Circle())
                    .padding(.bottom, 60)
                    .padding(.trailing, 20)
                    .transition(.opacity)
            }
        }
        #if os(iOS)
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        #endif
        .ignoresSafeArea()
        .onAppear { loadVideo(at: currentIndex) }
        .onDisappear { vm.stop() }
        .navigationDestination(item: $channelDestination) { dest in
            ChannelView(channelId: dest.channelId)
        }
        } // NavigationStack
    }

    // MARK: - Always-visible index badge
    //
    // Rendered outside the ZStack (as an .overlay on the body) so UIViewRepresentable
    // elements inside the ZStack cannot absorb it from the accessibility tree.

    private var indexBadge: some View {
        Text("\(currentIndex + 1) / \(videos.count)")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.4))
            .clipShape(Capsule())
            .accessibilityIdentifier("shorts.indexLabel")
            .padding(.top, 60)
            .padding(.trailing, 20)
    }

    // MARK: - Overlay

    private var shortsOverlay: some View {
        VStack(spacing: 0) {
            // Top bar: back + index indicator
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: AppSymbol.chevronLeft)
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.black.opacity(0.4))
                        .clipShape(Circle())
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 60)

            Spacer()

            // Bottom section: navigation hints + title + play-pause
            VStack(spacing: 8) {
                if currentIndex > 0 {
                    Image(systemName: AppSymbol.chevronUp)
                        .foregroundStyle(.white.opacity(0.5))
                        .font(.caption)
                }

                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(vm.playerInfo?.video.title ?? currentVideo.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        let channelId = vm.playerInfo?.video.channelId ?? currentVideo.channelId
                        let channelTitle = vm.playerInfo?.video.channelTitle ?? currentVideo.channelTitle
                        Button {
                            guard let cid = channelId, !cid.isEmpty else { return }
                            channelDestination = ChannelDestination(channelId: cid)
                        } label: {
                            Text(channelTitle)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .disabled(channelId == nil || channelId?.isEmpty == true)
                    }
                    Spacer()
                    Button { vm.togglePlayPause() } label: {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.4))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 20)

                if currentIndex < videos.count - 1 {
                    Image(systemName: AppSymbol.chevronDown)
                        .foregroundStyle(.white.opacity(0.5))
                        .font(.caption)
                }
            }
            .padding(.bottom, 40)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.65)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 200)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            )
        }
        // Allow swipe navigation even when the controls overlay is on screen.
        // .simultaneousGesture fires alongside button taps so controls remain
        // interactive while vertical swipes still drive Shorts navigation.
        #if !os(tvOS)
        .simultaneousGesture(
            DragGesture(minimumDistance: 50, coordinateSpace: .global)
                .onEnded { value in
                    guard !isTransitioning else { return }
                    let dy = value.translation.height
                    guard abs(dy) > abs(value.translation.width) else { return }
                    if dy < 0 {
                        if let next = ShortsNavigation.targetIndex(
                            vertical: -100, horizontal: 0,
                            current: currentIndex, count: videos.count
                        ) { performVerticalTransition(direction: -1) { goTo(next) } }
                        else { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { slideOffset = 0 } }
                    } else {
                        if let prev = ShortsNavigation.targetIndex(
                            vertical: 100, horizontal: 0,
                            current: currentIndex, count: videos.count
                        ) { performVerticalTransition(direction: 1) { goTo(prev) } }
                        else { loadMoreAtStart() }
                    }
                }
        )
        #endif
    }

    // MARK: - Navigation

    /// Animates the current content off-screen in `direction` (-1 = up, +1 = down),
    /// runs `action` to switch to the new video, then slides the new content in
    /// from the opposite side.
    private func performVerticalTransition(direction: CGFloat, action: @escaping () -> Void) {
        #if os(iOS)
        let screenHeight = UIScreen.main.bounds.height
        #else
        let screenHeight: CGFloat = 800
        #endif
        isTransitioning = true
        withAnimation(.easeIn(duration: 0.2)) {
            slideOffset = direction * screenHeight
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            action()                                       // switch video, clears AVPlayer
            slideOffset = -direction * screenHeight        // snap to opposite side (off-screen)
            withAnimation(.easeOut(duration: 0.25)) {
                slideOffset = 0                            // slide new content in
            }
            try? await Task.sleep(for: .milliseconds(270))
            isTransitioning = false
        }
    }

    private func goTo(_ index: Int) {
        guard index >= 0, index < videos.count else { return }
        currentIndex = index
        loadVideo(at: index)
        // Pre-fetch more Shorts when within 2 of the end.
        if index >= videos.count - 2 {
            loadMoreIfNeeded()
        }
    }

    /// Fetches an additional batch of Shorts and appends them, deduplicating by id.
    private func loadMoreIfNeeded() {
        guard !ProcessInfo.processInfo.arguments.contains("--uitesting") else { return }
        guard !isFetchingMore else { return }
        isFetchingMore = true
        let existingIDs = Set(videos.map(\.id))
        Task { @MainActor in
            defer { isFetchingMore = false }
            guard let group = try? await api.fetchShorts() else { return }
            let newVideos = group.videos.filter { !existingIDs.contains($0.id) }
            guard !newVideos.isEmpty else { return }
            videos.append(contentsOf: newVideos)
        }
    }

    /// Fetches a batch of Shorts, prepends them before the current video, adjusts
    /// `currentIndex` to keep the current video in place, then animates down into
    /// the last prepended video — giving the user new content above.
    private func loadMoreAtStart() {
        guard !ProcessInfo.processInfo.arguments.contains("--uitesting") else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { slideOffset = 0 }
            return
        }
        guard !isFetchingMore else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { slideOffset = 0 }
            return
        }
        isFetchingMore = true
        // Spring back to centre while the fetch is in flight.
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { slideOffset = 0 }
        let existingIDs = Set(videos.map(\.id))
        Task { @MainActor in
            defer { isFetchingMore = false }
            guard let group = try? await api.fetchShorts() else { return }
            let newVideos = group.videos.filter { !existingIDs.contains($0.id) }
            guard !newVideos.isEmpty else { return }
            // Prepend the new videos; re-anchor currentIndex so the on-screen
            // video doesn't change, then animate down to the last prepended video.
            videos.insert(contentsOf: newVideos, at: 0)
            currentIndex += newVideos.count
            performVerticalTransition(direction: 1) { goTo(currentIndex - 1) }
        }
    }

    private func loadVideo(at index: Int) {
        vm.load(video: videos[index])
        vm.setPlaybackSpeed(store.settings.playbackSpeed)
        vm.updateSettings(store.settings)
    }
}

// MARK: - AVPlayerLayerView

#if os(iOS) || os(tvOS)
/// A lightweight UIView that hosts an `AVPlayerLayer` directly — no
/// `AVPlayerViewController` involved.  This keeps the UIKit accessibility
/// tree completely clean so SwiftUI overlays (index badge, controls) remain
/// visible to XCUITest.
private struct AVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> _AVLayerUIView {
        let view = _AVLayerUIView()
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: _AVLayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }

    /// UIView subclass that exposes `AVPlayerLayer` as its backing layer.
    final class _AVLayerUIView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
#endif

// MARK: - SwipeGestureOverlay

#if os(iOS)
/// A transparent UIKit view that captures pan and tap gestures before
/// AVPlayerViewController can consume them.
///
/// - `cancelsTouchesInView = false` lets taps still reach controls below.
/// - `require(toFail:)` is called against every sibling recognizer in the
///   window so this pan always wins when predominantly vertical.
private struct SwipeGestureOverlay: UIViewRepresentable {
    var onSwipeUp:        () -> Void
    var onSwipeDown:      () -> Void
    var onTap:            () -> Void
    var onTwoFingerTap:   () -> Void = {}
    var onPanChanged:     ((CGFloat) -> Void)?
    var onSwipeCancelled: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.cancelsTouchesInView = true
        view.addGestureRecognizer(pan)
        context.coordinator.pan = pan

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tap.cancelsTouchesInView = false
        tap.require(toFail: pan)
        view.addGestureRecognizer(tap)

        let twoFingerTap = UITapGestureRecognizer(target: context.coordinator,
                                                   action: #selector(Coordinator.handleTwoFingerTap))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.cancelsTouchesInView = false
        view.addGestureRecognizer(twoFingerTap)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: SwipeGestureOverlay
        weak var pan: UIPanGestureRecognizer?
        private let minDistance: CGFloat = 40

        init(_ parent: SwipeGestureOverlay) { self.parent = parent }

        @MainActor @objc func handlePan(_ gr: UIPanGestureRecognizer) {
            let t = gr.translation(in: gr.view)
            switch gr.state {
            case .changed:
                parent.onPanChanged?(t.y)
            case .ended:
                guard abs(t.y) > minDistance, abs(t.y) > abs(t.x) else {
                    parent.onSwipeCancelled?()
                    return
                }
                if t.y < 0 { parent.onSwipeUp() } else { parent.onSwipeDown() }
            case .cancelled, .failed:
                parent.onSwipeCancelled?()
            default:
                break
            }
        }

        @MainActor @objc func handleTap() { parent.onTap() }
        @MainActor @objc func handleTwoFingerTap() { parent.onTwoFingerTap() }
    }
}
#endif
