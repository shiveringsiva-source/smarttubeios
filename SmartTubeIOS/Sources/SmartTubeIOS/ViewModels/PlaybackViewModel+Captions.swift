import Foundation
import os
import SmartTubeIOSCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - Caption Track Selection

extension PlaybackViewModel {

    /// Selects a caption track and fetches its VTT cues. Pass `nil` to disable captions.
    public func selectCaption(_ track: CaptionTrack?) {
        selectedCaption = track
        currentCaptionCue = nil
        captionCues = []
        captionFetchTask?.cancel()
        captionFetchTask = nil
        guard let track else { return }
        captionFetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let parser = WebVTTParser()
                let cues = try await parser.fetchCues(from: track.baseURL)
                guard !Task.isCancelled else { return }
                self.captionCues = cues
                self.updateCaptionCue(for: self.currentTime)
                playerLog.notice("Loaded \(cues.count) cues for track \(track.id)")
            } catch {
                playerLog.error("Caption fetch failed for \(track.id): \(String(describing: error))")
            }
        }
    }

    func updateCaptionCue(for time: TimeInterval) {
        guard !captionCues.isEmpty else { currentCaptionCue = nil; return }
        currentCaptionCue = captionCues.last(where: { $0.startTime <= time && $0.endTime > time })
    }
}
