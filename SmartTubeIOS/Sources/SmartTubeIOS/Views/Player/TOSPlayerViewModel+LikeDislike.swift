#if !os(tvOS)
import Foundation
import os
import SmartTubeIOSCore

private let tosLog = Logger(subsystem: "com.void.smarttube.app", category: "TOSPlayer")

// MARK: - Like / Dislike
//
// Transferred from PlaybackViewModel+LikeDislike.swift — a pure InnerTubeAPI
// feature with zero AVPlayer dependency, so the port is near-verbatim. The one
// TOS-specific adaptation: these use `self.videoId` directly rather than
// `currentVideo?.id` — TOS always has exactly one video for the lifetime of the
// view model, so there is no optional to unwrap.

extension TOSPlayerViewModel {

    /// Toggles the like state for the current video (optimistic update; rolls back on failure).
    func like() {
        let prev = likeStatus
        likeStatus = prev == .like ? .none : .like
        let videoId = videoId
        Task {
            do {
                if prev == .like {
                    try await api.removeLike(videoId: videoId)
                } else {
                    try await api.like(videoId: videoId)
                }
            } catch {
                self.likeStatus = prev
                tosLog.error("[likeDislike] like failed: \(String(describing: error))")
            }
        }
    }

    /// Toggles the dislike state for the current video (optimistic update; rolls back on failure).
    func dislike() {
        let prev = likeStatus
        likeStatus = prev == .dislike ? .none : .dislike
        let videoId = videoId
        Task {
            do {
                if prev == .dislike {
                    try await api.removeLike(videoId: videoId)
                } else {
                    try await api.dislike(videoId: videoId)
                }
            } catch {
                self.likeStatus = prev
                tosLog.error("[likeDislike] dislike failed: \(String(describing: error))")
            }
        }
    }
}
#endif // !os(tvOS)
