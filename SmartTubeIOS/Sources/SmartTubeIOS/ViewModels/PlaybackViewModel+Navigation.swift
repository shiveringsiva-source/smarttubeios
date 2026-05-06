import AVFoundation
import os
import SmartTubeIOSCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - Queue, History & Chapter Navigation

extension PlaybackViewModel {

    /// Play the next related video (first in the suggestions list).
    public func playNext() {
        guard let next = relatedVideos.first else { return }
        playerLog.notice("playNext: id=\(next.id)")
        load(video: next)
    }

    /// Play the most recently played video from the history stack.
    /// Pops the last entry from history; load() will push the current video back so
    /// the user can navigate forward again with playNext() or via suggestions.
    public func playPrevious() {
        guard !history.isEmpty else { return }
        let prev = history.removeLast()
        hasPrevious = !history.isEmpty
        playerLog.notice("playPrevious: id=\(prev.id)")
        load(video: prev)
    }

    /// Seek to the start of the next chapter.
    public func skipToNextChapter() {
        guard let next = chapters.first(where: { $0.startTime > currentTime }) else { return }
        seek(to: next.startTime)
        showControls()
    }

    /// Seek to the start of the current chapter (if >3 s in) or to the previous chapter.
    public func skipToPreviousChapter() {
        guard let current = currentChapter else { return }
        if currentTime - current.startTime > 3 {
            seek(to: current.startTime)
        } else if let prev = chapters.last(where: { $0.startTime < current.startTime }) {
            seek(to: prev.startTime)
        }
        showControls()
    }

    func handlePlaybackEnd() {
        if settings.loopEnabled {
            player.seek(to: .zero)
            player.rate = Float(settings.playbackSpeed)
            return
        }
        if settings.shuffleEnabled, !relatedVideos.isEmpty {
            let pick = relatedVideos[Int.random(in: 0..<relatedVideos.count)]
            playerLog.notice("Shuffle: loading id=\(pick.id)")
            load(video: pick)
            return
        }
        guard settings.autoplayEnabled, let next = relatedVideos.first else { return }
        playerLog.notice("Autoplay: loading next video id=\(next.id)")
        load(video: next)
    }
}
