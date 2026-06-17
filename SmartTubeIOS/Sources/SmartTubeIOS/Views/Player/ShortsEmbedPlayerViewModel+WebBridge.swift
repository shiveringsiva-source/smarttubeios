#if !os(tvOS)
import Foundation
import CoreFoundation
import WebKit
import os
import SmartTubeIOSCore

private let shortsLog = Logger(subsystem: "com.void.smarttube.app", category: "ShortsPlayer")

// MARK: - JS Message Handling
//
// Receives every message posted by `stateDetectionJS` (ShortsEmbedJS.swift) via
// window.__nativeYTCallback.postMessage, relayed through
// `ShortsScriptMessageProxy.userContentController(_:didReceive:)`. Mirrors
// TOSPlayerViewModel+WebBridge.swift — see that file's doc comments for why this
// poll-and-relay channel is the only way playback state reaches Swift.
//
// SponsorBlock calls (fetchSponsorSegments in "ready"; checkSponsorSkip/
// logSkipLanding in "tick") are added by Task 6's edits to this file. Watch-history
// (Task 7) lives in ShortsEmbedPlayerViewModel.swift's loadShort/onDisappear, not here.

extension ShortsEmbedPlayerViewModel {

    /// Called from `ShortsScriptMessageProxy` (main thread guaranteed by WKWebView).
    /// - Parameter frameInfo: the originating frame, threaded through from
    ///   `WKScriptMessage.frameInfo` — see `embedFrameInfo`'s doc comment for why
    ///   this is the missing link that fixes `play/seekTo/setPlaybackRate`.
    func handleScriptMessage(_ body: String, frameInfo: WKFrameInfo) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            shortsLog.debug("[ytCallback] unparseable message: \(body)")
            return
        }

        switch type {
        case "ping":
            shortsLog.notice("[ytCallback] JS<->Swift bridge ping received")
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName("com.void.smarttube.shortsplayer.bridge" as CFString),
                nil, nil, true
            )

        case "ready":
            // Cancel the "ready" timeout started by loadShort() — see
            // startReadyTimeout(for:) (ShortsEmbedPlayerViewModel.swift).
            readyTimeoutTask?.cancel()
            readyTimeoutTask = nil

            // CAPTURE the embed iframe's frame info — `embedFrameInfo` is reset to
            // nil in loadShort(), so each iframe-src swap re-captures its own
            // frame here exactly once. See embedFrameInfo's doc comment
            // (ShortsEmbedPlayerViewModel.swift) for the full root-cause story.
            if embedFrameInfo == nil {
                embedFrameInfo = frameInfo
                shortsLog.notice("[frame] captured embed iframe frameInfo — isMainFrame=\(frameInfo.isMainFrame, privacy: .public) url=\(frameInfo.request.url?.absoluteString ?? "nil", privacy: .public)")

            }
            isReady = true
            duration = (json["duration"] as? Double) ?? 0
            shortsLog.notice("[ytCallback] ready — duration=\(self.duration, format: .fixed(precision: 1))s")
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName("com.void.smarttube.shortsplayer.ready" as CFString),
                nil, nil, true
            )
            // Kick off SponsorBlock segment loading for this Short — parity with
            // TOSPlayerViewModel+WebBridge.swift's "ready" case.
            sponsorTask?.cancel()
            sponsorTask = Task { await self.fetchSponsorSegments() }
            // Apply the user's saved playback-speed preference — parity with
            // TOSPlayerViewModel+WebBridge.swift's "ready" case.
            if settings.playbackSpeed != 1.0 {
                setPlaybackRate(settings.playbackSpeed)
                shortsLog.notice("[ytCallback] applied saved playback speed \(self.settings.playbackSpeed, format: .fixed(precision: 2))×")
            }

        case "stateChange":
            let raw = (json["state"] as? Int) ?? 999
            playerState = YTPlayerState(raw: raw)
            if playerState == .paused {
                showEmbedControls()
                showControls()
                cancelControlsHide()
                shortsLog.notice("[ytCallback] stateChange → paused — showEmbedControls + showControls called")
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName("com.void.smarttube.shortsplayer.paused" as CFString),
                    nil, nil, true
                )
            } else {
                hideEmbedControls()
                shortsLog.notice("[ytCallback] stateChange → \(raw)")
            }
            if playerState == .playing {
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName("com.void.smarttube.shortsplayer.playing" as CFString),
                    nil, nil, true
                )
            }

        case "autoUnmuted":
            // One-shot trace from stateDetectionJS's pollVideo: confirms the
            // load-muted-then-unmute workaround dropped the mute once forward
            // playback was observed.
            let unmutedAt = (json["t"] as? Double) ?? -1
            let stillMuted = (json["muted"] as? Bool) ?? true
            shortsLog.notice("[ytCallback] 🔊 auto-unmuted at t=\(unmutedAt, format: .fixed(precision: 2))s — video.muted now \(stillMuted, privacy: .public)")

        case "tick":
            let t = (json["t"] as? Double) ?? 0
            let s = (json["state"] as? Int) ?? 999
            currentTime = t
            let newState = YTPlayerState(raw: s)
            if !hasReceivedFirstTick {
                hasReceivedFirstTick = true
                shortsLog.notice("[ytCallback] first tick — state=\(s) t=\(t, format: .fixed(precision: 2))s")
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName("com.void.smarttube.shortsplayer.tickstarted" as CFString),
                    nil, nil, true
                )
            }
            let wasActivelyPlaying = playerState == .playing || playerState == .buffering
            let isNowActivelyPlaying = newState == .playing || newState == .buffering
            if isNowActivelyPlaying && !wasActivelyPlaying {
                shortsLog.notice("[ytCallback] tick detected active playback (state=\(s)) — firing playing notification")
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName("com.void.smarttube.shortsplayer.playing" as CFString),
                    nil, nil, true
                )
            }
            if newState != playerState {
                shortsLog.notice("[ytCallback] tick state: \(self.playerState.rawValue) → \(s) at t=\(t, format: .fixed(precision: 1))s")
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName("com.void.smarttube.shortsplayer.state.\(s)" as CFString),
                    nil, nil, true
                )
            }
            playerState = newState
            checkSponsorSkip(at: t)
            // Confirm/observe the landing of any in-flight auto-skip seek (no-op when
            // none is pending — see PendingSkipLog for why this must happen here, on
            // the next observed tick, rather than synchronously after seekTo()).
            logSkipLanding(at: t)

        case "error":
            let code = (json["code"] as? Int) ?? -1
            let errText = (json["text"] as? String) ?? ""
            let errName: String
            switch code {
            case 2:        errName = "invalid-param";          playerError = .iframeError(code)
            case 5:        errName = "html5-not-supported";    playerError = .iframeError(code)
            case 100:      errName = "video-not-found";        playerError = .notFound
            case 101, 150: errName = "embedding-disabled";     playerError = .embeddingDisabled
            case 153:      errName = "player-config-error";    playerError = .iframeError(code)
            default:       errName = "unknown(\(code))";       playerError = .iframeError(code)
            }
            shortsLog.notice("[ytCallback] ❌ player error \(code) (\(errName)) text='\(errText)' isFatal=\(self.playerError?.isFatal ?? false)")
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName("com.void.smarttube.shortsplayer.error.\(code)" as CFString),
                nil, nil, true
            )

        default:
            break
        }
    }
}
#endif // !os(tvOS)
