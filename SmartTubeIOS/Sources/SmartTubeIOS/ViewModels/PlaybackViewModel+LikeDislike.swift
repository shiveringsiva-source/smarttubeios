import Foundation
import os
import SmartTubeIOSCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - Like / Dislike

extension PlaybackViewModel {

    /// Toggles the like state for the current video (optimistic update; rolls back on failure).
    public func like() {
        guard let videoId = currentVideo?.id else { return }
        let prev = likeStatus
        likeStatus = prev == .like ? .none : .like
        Task {
            do {
                if prev == .like {
                    try await api.removeLike(videoId: videoId)
                } else {
                    try await api.like(videoId: videoId)
                }
            } catch {
                self.likeStatus = prev
                playerLog.error("like failed: \(String(describing: error))")
            }
        }
    }

    /// Toggles the dislike state for the current video (optimistic update; rolls back on failure).
    public func dislike() {
        guard let videoId = currentVideo?.id else { return }
        let prev = likeStatus
        likeStatus = prev == .dislike ? .none : .dislike
        Task {
            do {
                if prev == .dislike {
                    try await api.removeLike(videoId: videoId)
                } else {
                    try await api.dislike(videoId: videoId)
                }
            } catch {
                self.likeStatus = prev
                playerLog.error("dislike failed: \(String(describing: error))")
            }
        }
    }
}
