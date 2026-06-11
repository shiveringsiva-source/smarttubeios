#if !os(tvOS)
import Foundation
import os
import SmartTubeIOSCore

private let tosLog = Logger(subsystem: "com.void.smarttube.app", category: "TOSPlayer")

// MARK: - Comments
//
// Transferred from PlayerView+Overlays.swift's loadComments() — a pure
// InnerTubeAPI fetch with zero AVPlayer dependency. The one TOS-specific
// adaptation: the empty/in-flight guard that PlayerView+Overlays' moreMenuCommentsRow
// applies at the call site lives here instead, since TOSPlayerView has no
// equivalent per-row gating logic.

extension TOSPlayerViewModel {

    /// Fetches top-level comments for the current video (no-op if already
    /// loaded or a fetch is in flight).
    func loadComments() {
        guard videoComments.isEmpty, !isLoadingComments else { return }
        isLoadingComments = true
        Task {
            do {
                videoComments = try await api.fetchComments(videoId: videoId)
            } catch {
                tosLog.error("[comments] fetchComments failed: \(String(describing: error))")
            }
            isLoadingComments = false
        }
    }
}
#endif // !os(tvOS)
