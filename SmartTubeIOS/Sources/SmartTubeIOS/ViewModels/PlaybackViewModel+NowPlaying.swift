import AVFoundation
import os
#if canImport(UIKit)
import UIKit
import MediaPlayer
#endif
import SmartTubeIOSCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - Now Playing (lock screen + Dynamic Island)

#if canImport(UIKit)
extension PlaybackViewModel {

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
