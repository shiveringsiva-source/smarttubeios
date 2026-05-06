import Foundation
import os
import SmartTubeIOSCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - Auth Token

extension PlaybackViewModel {

    /// Updates the local auth flag used for LOGIN_REQUIRED retry logic.
    /// The shared InnerTubeAPI instance already carries the updated token.
    public func updateAuthToken(_ token: String?) {
        let wasAuthenticated = hasAuthToken
        hasAuthToken = token != nil
        currentAuthToken = token
        // Keep the cache's InnerTubeAPI instance in sync so prefetch requests
        // can make authenticated calls (e.g. fetchAuthenticatedTrackingURLs).
        Task { await VideoPreloadCache.shared.setAuthToken(token) }
        if wasAuthenticated, token == nil {
            // Signed out: evict account-bound cache data
            Task { await VideoPreloadCache.shared.evictAuthSensitiveData() }
        } else if wasAuthenticated, token != nil {
            // Token refreshed: tracking URLs bound to the old token are stale
            Task { await VideoPreloadCache.shared.evictTrackingURLs() }
        }
    }
}
