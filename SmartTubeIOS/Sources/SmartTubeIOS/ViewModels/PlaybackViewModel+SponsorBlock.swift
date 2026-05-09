import AVFoundation
import os
import SmartTubeIOSCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - SponsorBlock

extension PlaybackViewModel {

    /// Call this from the time observer. Handles per-category actions:
    ///   `.skip`      → seeks past the segment automatically.
    ///   `.showToast` → surfaces `currentToastSegment` so the view can show a skip button.
    ///   `.nothing`   → no-op.
    /// Returns true if an auto-seek was triggered.
    @discardableResult
    public func checkSponsorSkip(at time: TimeInterval) -> Bool {
        guard settings.sponsorBlockEnabled else {
            currentToastSegment = nil
            return false
        }
        // Check whether the playhead is inside any active segment.
        if let seg = sponsorSegments.first(where: { time >= $0.start && time < $0.end }) {
            switch settings.sponsorAction(for: seg.category) {
            case .skip:
                // Guard: don't re-trigger while a seek is already in-flight. Without this
                // the 0.5 s time observer fires again before the seek completes and issues
                // another seek, producing the end-of-video twitch / 500 ms audio loop.
                guard !isSkippingSegment else { return true }
                currentToastSegment = nil
                // If the segment end is within 2 s of the video's playable duration, seeking
                // there risks landing past the last decodable frame (especially with toleranceAfter).
                // The player would clamp to the final frame without ever firing
                // didPlayToEndTimeNotification, leaving it frozen. Treat as a natural end instead.
                // 2 s (vs the previous 0.5 s) gives sufficient margin for keyframe alignment
                // and CDN-reported duration inaccuracies.
                let effectiveDuration = player.currentItem?.duration.seconds ?? duration
                if effectiveDuration > 0 && seg.end >= effectiveDuration - 2.0 {
                    playerLog.notice("[SponsorBlock] segment \(seg.category) ends at \(seg.end)s near duration \(effectiveDuration)s — calling handlePlaybackEnd")
                    handlePlaybackEnd()
                    return true
                }
                isSkippingSegment = true
                playerLog.notice("[SponsorBlock] seeking past \(seg.category) segment \(seg.start)–\(seg.end)s")
                // Use toleranceAfter so the seek always lands at or past seg.end even when
                // there is no keyframe at exactly that timestamp. This prevents the seek from
                // returning finished=false, resetting the guard, and immediately re-entering
                // the skip loop.
                player.seek(
                    to: CMTime(seconds: seg.end, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600)
                ) { [weak self] finished in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        playerLog.notice("[SponsorBlock] seek to \(seg.end)s finished=\(finished), currentTime=\(self.currentTime)")
                        if finished { self.currentTime = seg.end }
                        self.isSkippingSegment = false
                    }
                }
                return true
            case .showToast:
                currentToastSegment = seg
                return false
            case .nothing:
                currentToastSegment = nil
                return false
            }
        } else {
            currentToastSegment = nil
        }
        return false
    }

    /// Manually skip the segment shown in `currentToastSegment` (called by the view's skip button).
    public func skipToastSegment() {
        guard let seg = currentToastSegment else { return }
        currentToastSegment = nil
        let effectiveDuration = player.currentItem?.duration.seconds ?? duration
        if effectiveDuration > 0 && seg.end >= effectiveDuration - 2.0 {
            handlePlaybackEnd()
            return
        }
        seek(to: seg.end)
        showControls()
    }
}
