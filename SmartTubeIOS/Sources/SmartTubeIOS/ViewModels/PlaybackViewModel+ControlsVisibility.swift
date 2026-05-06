import Foundation
import os
import SmartTubeIOSCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - Controls Overlay Visibility

extension PlaybackViewModel {

    public func showControls() {
        playerLog.debug("[controls] showControls — isScrubbing=\(self.isScrubbing)")
        controlsVisible = true
        scheduleControlsHide()
    }

    public func toggleControls() {
        playerLog.notice("[controls] toggleControls — controlsVisible=\(self.controlsVisible)")
        if controlsVisible {
            controlsTimer?.cancel()
            controlsVisible = false
        } else {
            showControls()
        }
    }

    func scheduleControlsHide() {
        playerLog.debug("[controls] scheduleControlsHide — resetting \(self.settings.controlsHideTimeout)s timer, isScrubbing=\(self.isScrubbing)")
        controlsTimer?.cancel()
        controlsTimer = Task {
            try? await Task.sleep(for: .seconds(settings.controlsHideTimeout))
            playerLog.debug("[controls] timer fired — isCancelled=\(Task.isCancelled) isScrubbing=\(self.isScrubbing)")
            guard !Task.isCancelled else {
                playerLog.debug("[controls] hide suppressed (cancelled)")
                return
            }
            if !self.isScrubbing {
                playerLog.debug("[controls] hiding controls")
                self.controlsVisible = false
            } else {
                // Still scrubbing — commitScrub will call showControls when the user
                // lifts their finger, but reschedule as a safety net for edge cases.
                playerLog.debug("[controls] hide suppressed (still scrubbing) — rescheduling")
                self.scheduleControlsHide()
            }
        }
    }
}
