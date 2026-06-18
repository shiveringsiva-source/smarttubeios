import SwiftUI
import SmartTubeIOSCore
import os
#if canImport(UIKit)
import UIKit
#endif

private let shortsLog = Logger(subsystem: "com.void.smarttube.app", category: "ShortsPlayer")

extension ShortsPlayerView {

    // MARK: - Navigation

    /// Animates the current content off-screen in `direction` (-1 = up, +1 = down),
    /// runs `action` to switch to the new video, then slides the new content in
    /// from the opposite side.
    func performVerticalTransition(direction: CGFloat, action: @escaping () -> Void) {
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

    func goTo(_ index: Int) {
        guard index >= 0, index < videos.count else { return }

        #if os(iOS)
        // Hot path: if a pre-warmed VM is ready for this exact next Short, swap it in
        // immediately — no reload, no black-screen delay. The old VM is stopped async
        // so it doesn't block the transition. If the standby isn't ready (or this is a
        // backward swipe), fall back to a normal loadVideo.
        if index == currentIndex + 1,
           let readyStandby = standbyVM,
           readyStandby.isReady {
            let oldVM = vm
            standbyVM = nil
            vm = readyStandby         // triggers ShortsTOSWebView to attach the new WKWebView
            currentIndex = index
            let video = videos[index]
            CrashlyticsLogger.setIntendedVideo(id: video.id, title: video.title)
            vm.activate()             // clears isStandby, starts playback
            Task(priority: .background) { oldVM.stop() }
            shortsLog.notice("[goTo] standby swap — index=\(index, privacy: .public) isReady=\(readyStandby.isReady, privacy: .public)")
        } else {
            currentIndex = index
            loadVideo(at: index)
        }
        #else
        currentIndex = index
        loadVideo(at: index)
        #endif

        // Pre-fetch more Shorts when within 2 of the end.
        if index >= videos.count - 2 {
            loadMoreIfNeeded()
        }
        // Pre-fetch the next 2 shorts so swiping is instant.
        let lookahead = videos[(index + 1)..<min(index + 3, videos.count)].map(\.id)
        if !lookahead.isEmpty {
            let token = authService.accessToken
            let cats = store.settings.activeSponsorCategories
            Task(priority: .background) {
                for videoId in lookahead {
                    await VideoPreloadCache.shared.prefetch(
                        videoId: videoId,
                        sponsorCategories: cats,
                        authToken: token,
                        priority: .speculative
                    )
                }
            }
        }
        #if os(iOS)
        // Pre-warm next Short's WKWebView so swipe-to-next has no black-screen delay.
        prewarmStandby(for: index)
        #endif
    }

    #if os(iOS)
    /// Loads Short at `currentIndex + 1` into a background `ShortsEmbedPlayerViewModel`
    /// so it reaches `isReady == true` before the user swipes. `goTo(_:)` checks the
    /// standby and swaps it in immediately if ready — see Task #272.
    private func prewarmStandby(for index: Int) {
        let nextIndex = index + 1
        guard nextIndex < videos.count else {
            standbyVM = nil   // end of feed — no next Short to pre-warm
            return
        }
        let nextVideo = videos[nextIndex]
        let standby = ShortsEmbedPlayerViewModel(api: api)
        standby.updateSettings(store.settings)
        // Attach to the view hierarchy immediately (ShortsPlayerView hosts standbyVM
        // in a hidden ShortsTOSWebView) — an unattached WKWebView never progresses
        // past readyState 0 (WebKit throttles media loading the same way it does for
        // a backgrounded tab), so the embed must be mounted BEFORE
        // loadShortAsStandby starts polling for isReady, not after. See #274.
        standbyVM = standby
        Task(priority: .userInitiated) {
            await standby.loadShortAsStandby(video: nextVideo)
            if currentIndex == index {
                shortsLog.notice("[prewarm] standby ready — nextVideo=\(nextVideo.id, privacy: .public) isReady=\(standby.isReady, privacy: .public)")
            } else {
                shortsLog.notice("[prewarm] standby discarded — user already moved past index \(index, privacy: .public)")
            }
        }
    }
    #endif

    /// Fetches an additional batch of Shorts and appends them, deduplicating by id.
    func loadMoreIfNeeded() {
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
    func loadMoreAtStart() {
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

    func loadVideo(at index: Int) {
        let video = videos[index]
        CrashlyticsLogger.setIntendedVideo(id: video.id, title: video.title)
        #if os(iOS)
        vm.updateSettings(store.settings)
        vm.loadShort(video: video)
        #else
        vm.load(video: video)
        vm.setPlaybackSpeed(store.settings.playbackSpeed)
        vm.updateSettings(store.settings)
        #endif
    }

    #if os(iOS)

    // MARK: - End of video / error recovery (iOS)

    /// Replicates `PlaybackViewModel.handlePlaybackEnd()`'s decision tree
    /// (PlaybackViewModel+Navigation.swift:114-163) for Shorts, via
    /// `ShortsEndOfVideoDecision` (Task 3) — called from `.onChange(of:
    /// vm.playerState)` when the TOS embed's `"stateChange"` reports `.ended`.
    func handleShortEnded() {
        switch ShortsEndOfVideoDecision.decide(settings: store.settings, currentIndex: currentIndex, count: videos.count) {
        case .replay:
            vm.seekTo(0)
            vm.play()
        case .advance(let next):
            performVerticalTransition(direction: -1) { goTo(next) }
        case .freeze:
            vm.videoEnded = true
        }
    }

    /// Per the design spec's Error Handling section: on a per-Short load failure or
    /// "ready" timeout, log it and auto-advance to the next Short after a brief
    /// delay (so the error banner is visible), mirroring swipe-up. If there's no
    /// next Short, freeze like a natural end.
    func advanceAfterError() {
        guard let error = vm.playerError, error.isFatal else { return }
        let erroredVideoId = vm.currentVideoId
        logEmbedLoadError(error, videoId: erroredVideoId)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard vm.currentVideoId == erroredVideoId, !isTransitioning else { return }
            if let next = ShortsNavigation.targetIndex(vertical: -100, horizontal: 0, current: currentIndex, count: videos.count) {
                performVerticalTransition(direction: -1) { goTo(next) }
            } else {
                vm.videoEnded = true
            }
        }
    }

    /// Logs a Shorts embed load failure via Crashlytics — mirrors the stall-logging
    /// pattern at PlaybackViewModel+Loading.swift:938 (bug #193), giving visibility
    /// into real-world embed failure rates per the design spec's Error Handling
    /// section.
    private func logEmbedLoadError(_ error: TOSPlayerError, videoId: String) {
        let reason: String
        switch error {
        case .notFound:              reason = "notFound"
        case .embeddingDisabled:     reason = "embeddingDisabled"
        case .iframeError(let code): reason = "iframeError(\(code))"
        case .webViewLoadFailed:     reason = "readyTimeout"
        }
        let nsError = NSError(
            domain: "SmartTube.ShortsEmbedLoadFailure",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Shorts embed load failure: \(reason) (video \(videoId))"]
        )
        CrashlyticsLogger(category: "ShortsPlayer").recordNonFatal(nsError, userInfo: [
            "video_id": videoId,
            "reason": reason
        ])
    }

    #endif
}
