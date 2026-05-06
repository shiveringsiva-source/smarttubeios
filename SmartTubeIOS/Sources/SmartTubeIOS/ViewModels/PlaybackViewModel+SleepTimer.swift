import Foundation
import os
import SmartTubeIOSCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - Sleep Timer

extension PlaybackViewModel {

    /// Activates (or cancels) the sleep timer.
    /// - Parameter minutes: Nil cancels any running timer; a positive value starts a new countdown.
    public func setSleepTimer(minutes: Int?) {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerMinutes = minutes
        guard let minutes else { return }
        sleepTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard let self, !Task.isCancelled else { return }
            self.player.pause()
            self.isPlaying = false
            self.sleepTimerMinutes = nil
        }
    }
}
