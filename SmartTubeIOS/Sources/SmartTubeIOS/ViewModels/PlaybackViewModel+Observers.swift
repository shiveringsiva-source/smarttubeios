import AVFoundation
import os
#if canImport(UIKit)
import MediaPlayer
#endif
import SmartTubeIOSCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - AVPlayer Observers

extension PlaybackViewModel {

    func setupTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: nil) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Don't overwrite the slider position or trigger SponsorBlock auto-seeks
                // while the user is scrubbing. Auto-seeks call seek() → showControls() →
                // scheduleControlsHide(), which cancels and restarts the 4 s hide-timer
                // every 0.5 s, preventing controls from ever auto-hiding post-scrub.
                guard !self.isScrubbing else { return }
                // Also skip updates while a SponsorBlock auto-seek is in flight so we
                // don't update currentTime to an intermediate position mid-seek.
                guard !self.isSkippingSegment else { return }
                self.currentTime = seconds
                self.checkSponsorSkip(at: seconds)
                self.updateCaptionCue(for: seconds)
                if self.statsForNerdsVisible { self.updateStatsSnapshot() }
            }
        }
    }

    func setupRateObserver() {
        // KVO on player.rate so isPlaying stays in sync when the system externally
        // pauses the player (e.g. headphones removed, audio session interruption ends
        // without shouldResume). Without this, isPlaying stays true while the player
        // is actually silent, causing handleForeground() to re-start a ghost session.
        rateObserver = player.observe(\.rate, options: [.new]) { [weak self] _, change in
            guard let self, let newRate = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Ignore rate changes that we ourselves triggered (load/pause/resume/stop)
                // by only acting when the player goes silent unexpectedly while we
                // believed it was playing.
                let playerWentSilent = newRate == 0 && self.isPlaying && !self.isSwappingItem
                if playerWentSilent {
                    self.isPlaying = false
                    playerLog.notice("[rateObserver] player.rate→0 while isPlaying=true — syncing isPlaying=false")
                    #if canImport(UIKit)
                    self.updateNowPlayingPlayback()
                    #endif
                }
            }
        }
    }
}
