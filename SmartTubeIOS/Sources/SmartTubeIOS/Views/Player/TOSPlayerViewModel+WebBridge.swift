#if !os(tvOS)
import Foundation
import CoreFoundation
import WebKit
import os
import SmartTubeIOSCore

private let tosLog = Logger(subsystem: "com.void.smarttube.app", category: "TOSPlayer")

// MARK: - JS Message Handling
//
// Receives every message posted by `stateDetectionJS` (see the WKUserScripts
// section of TOSPlayerViewModel.swift) via window.__nativeYTCallback.postMessage,
// relayed through `ScriptMessageProxy.userContentController(_:didReceive:)`. This
// poll-and-relay channel is the *only* way playback state reaches Swift — the
// embed is loaded as a plain page (not via the IFrame JS API), so there is no
// native postMessage contract to lean on beyond what stateDetectionJS defines.

extension TOSPlayerViewModel {

    /// Called from `ScriptMessageProxy` (main thread guaranteed by WKWebView).
    /// - Parameter frameInfo: the originating frame, threaded through from
    ///   `WKScriptMessage.frameInfo` — see `embedFrameInfo`'s doc comment for why
    ///   this is the missing link that fixes `play/seekTo/setPlaybackRate`.
    func handleScriptMessage(_ body: String, frameInfo: WKFrameInfo) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            tosLog.debug("[ytCallback] unparseable message: \(body)")
            return
        }

        switch type {
        case "ping":
            tosLog.notice("[ytCallback] JS<->Swift bridge ping received")
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName("com.void.smarttube.tosplayer.bridge" as CFString),
                nil, nil, true
            )

        case "ready":
            // CAPTURE the embed iframe's frame info — exactly once, from the message
            // GUARANTEED to originate inside it: `stateDetectionJS` only posts "ready"
            // after `document.querySelector('video')` actually found the `<video>`
            // element (see pollVideo's `_prevState === -2` branch), and that query can
            // only succeed inside the iframe's own (cross-origin) document — never the
            // wrapper page's main frame, which has no `<video>` at all. From this point
            // on, `eval()` can target `play/seekTo/setPlaybackRate` JS directly at the
            // iframe via the frame-aware `evaluateJavaScript` overload. See
            // `embedFrameInfo`'s doc comment for the full root-cause story.
            if embedFrameInfo == nil {
                embedFrameInfo = frameInfo
                tosLog.notice("[frame] captured embed iframe frameInfo — isMainFrame=\(frameInfo.isMainFrame, privacy: .public) url=\(frameInfo.request.url?.absoluteString ?? "nil", privacy: .public)")
            }
            isReady = true
            duration = (json["duration"] as? Double) ?? 0
            tosLog.notice("[ytCallback] ready — duration=\(self.duration, format: .fixed(precision: 1))s")
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName("com.void.smarttube.tosplayer.ready" as CFString),
                nil, nil, true
            )
            // play() is intentionally NOT called here. "ready" fires only after
            // video.duration > 0, meaning YouTube's MSE stream is initialised.
            // The JS pollVideo() already called video.play() at that point (see
            // stateDetectionJS), so calling it again from Swift would be a no-op or
            // could interrupt the stream seek in progress.
            Task { await self.fetchSponsorSegments() }
            beginWatchtimeTracking()
            // Apply the user's saved playback-speed preference — parity with
            // PlaybackViewModel+Loading's `player.rate = Float(settings.playbackSpeed)`
            // at load time. setPlaybackRate's JS bridge already existed (used by the
            // standard player's speed picker via a shared call path) but TOS playback
            // always silently started at 1× regardless of the saved preference until now.
            if settings.playbackSpeed != 1.0 {
                setPlaybackRate(settings.playbackSpeed)
                tosLog.notice("[ytCallback] applied saved playback speed \(self.settings.playbackSpeed, format: .fixed(precision: 2))×")
            }

        case "stateChange":
            let raw = (json["state"] as? Int) ?? 999
            playerState = YTPlayerState(raw: raw)
            tosLog.debug("[ytCallback] stateChange → \(raw)")
            if playerState == .playing {
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName("com.void.smarttube.tosplayer.playing" as CFString),
                    nil, nil, true
                )
            }

        case "rateChange":
            playbackRate = (json["rate"] as? Double) ?? 1.0

        case "autoUnmuted":
            // One-shot trace from stateDetectionJS's pollVideo: confirms the
            // load-muted-then-unmute workaround actually dropped the mute once
            // forward playback was observed (see its doc comment for why loading
            // muted is unavoidable — WebKit's autoplay policy — and why this is
            // the right moment to undo it). Logged at .notice so it survives
            // xcresulttool diagnostic export — the empirical proof this fix works.
            let unmutedAt = (json["t"] as? Double) ?? -1
            let stillMuted = (json["muted"] as? Bool) ?? true
            tosLog.notice("[ytCallback] 🔊 auto-unmuted at t=\(unmutedAt, format: .fixed(precision: 2))s — video.muted now \(stillMuted, privacy: .public)")

        case "tick":
            let t = (json["t"] as? Double) ?? 0
            let s = (json["state"] as? Int) ?? 999
            currentTime = t
            let newState = YTPlayerState(raw: s)
            if !hasReceivedFirstTick {
                hasReceivedFirstTick = true
                tosLog.notice("[ytCallback] first tick — state=\(s) t=\(t, format: .fixed(precision: 2))s")
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName("com.void.smarttube.tosplayer.tickstarted" as CFString),
                    nil, nil, true
                )
            }
            let wasActivelyPlaying = playerState == .playing || playerState == .buffering
            let isNowActivelyPlaying = newState == .playing || newState == .buffering
            if isNowActivelyPlaying && !wasActivelyPlaying {
                tosLog.notice("[ytCallback] tick detected active playback (state=\(s)) — firing playing notification")
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName("com.void.smarttube.tosplayer.playing" as CFString),
                    nil, nil, true
                )
            }
            if newState != playerState {
                tosLog.notice("[ytCallback] tick state: \(self.playerState.rawValue) → \(s) at t=\(t, format: .fixed(precision: 1))s")
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName("com.void.smarttube.tosplayer.state.\(s)" as CFString),
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
            tosLog.notice("[ytCallback] ❌ player error \(code) (\(errName)) text='\(errText)' isFatal=\(self.playerError?.isFatal ?? false)")
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName("com.void.smarttube.tosplayer.error.\(code)" as CFString),
                nil, nil, true
            )

        default:
            break
        }
    }
}
#endif // !os(tvOS)
