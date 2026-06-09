#if !os(tvOS)
import Foundation
import os
import SmartTubeIOSCore

private let tosLog = Logger(subsystem: "com.void.smarttube.app", category: "TOSPlayer")

// MARK: - Sleep Timer
//
// Transferred from PlaybackViewModel+SleepTimer.swift — a pure Task-scheduling
// feature with zero AVPlayer dependency. The one TOS-specific adaptation: the
// fire handler calls `self.pause()` (the existing JS-bridge pause command)
// instead of `player.pause(); isPlaying = false` — TOS has neither an AVPlayer
// nor an `isPlaying` flag; `playerState` is driven entirely by the JS bridge's
// "tick"/"stateChange" messages, which will reflect the pause once YouTube's
// IFrame posts it back.

extension TOSPlayerViewModel {

    /// Activates (or cancels) the sleep timer.
    /// - Parameter minutes: Nil cancels any running timer; a positive value starts a new countdown.
    func setSleepTimer(minutes: Int?) {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerMinutes = minutes
        guard let minutes else { return }
        sleepTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard let self, !Task.isCancelled else { return }
            self.pause()
            self.sleepTimerMinutes = nil
            tosLog.notice("[sleepTimer] fired — pausing playback")
        }
    }
}
#endif // !os(tvOS)
