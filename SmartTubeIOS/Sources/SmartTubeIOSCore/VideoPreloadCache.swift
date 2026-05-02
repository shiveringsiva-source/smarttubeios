import Foundation
import os

private let cacheLog = Logger(subsystem: appSubsystem, category: "PreloadCache")

// MARK: - VideoPreloadCache
//
// An in-memory, actor-isolated cache for all per-video API responses that
// PlaybackViewModel needs before playback can start.
//
// Design goals:
//  - Zero-contention reads/writes via actor isolation (no locks needed)
//  - TTL-based expiry per data type (stream URLs expire earliest, ~5.5 h)
//  - LRU eviction: keeps at most `maxVideoEntries` videos worth of data
//  - Active prefetch tasks are tracked so duplicates are skipped and
//    tasks can be cancelled when the user navigates away
//
// Usage:
//  1. Call `prefetch(videoId:...)` from a VideoCardView `.task` modifier
//     as cards become visible.
//  2. In PlaybackViewModel.loadAsync(), call `consume(videoId:)` first —
//     if the cache holds fresh data you avoid all network calls.
//  3. After a live fetch, store results with `store(...)`.

public actor VideoPreloadCache {

    // MARK: - Singleton

    public static let shared = VideoPreloadCache()

    // MARK: - Owned service instances
    //
    // The cache owns lightweight service instances so callers (e.g. VideoCardView)
    // only need to supply `videoId`, `isAuthenticated`, and `sponsorCategories` —
    // no service references need to flow through the view hierarchy.
    // Auth token is kept in sync via `setAuthToken(_:)`.

    private let api          = InnerTubeAPI()
    private let sponsorBlock = SponsorBlockService()
    private let deArrow      = DeArrowService()

    // MARK: - TTL constants

    /// iOS-client CDN stream URLs expire after ~6 h; use 5 h 30 m to be safe.
    public static let playerInfoTTL:     TimeInterval = 5.5 * 3600
    /// Tracking URLs are account-bound; token lifetime is typically 1 h.
    public static let trackingTTL:       TimeInterval = 3600
    /// Related-video list can change; 5-min window is enough for
    /// back-to-back playback within a session.
    public static let nextInfoTTL:       TimeInterval = 300
    /// End cards and SponsorBlock/DeArrow data are stable for hours.
    public static let endCardsTTL:       TimeInterval = 3600
    public static let sponsorTTL:        TimeInterval = 3600
    public static let deArrowTTL:        TimeInterval = 3600

    // MARK: - LRU cap

    /// Maximum number of distinct video IDs kept in memory.
    private static let maxVideoEntries = 30

    // MARK: - Cache entry

    struct CacheEntry<T: Sendable>: Sendable {
        let value: T
        let storedAt: Date
        let ttl: TimeInterval
        var isExpired: Bool { Date().timeIntervalSince(storedAt) > ttl }
    }

    // MARK: - Sub-caches (keyed by videoId)

    private var playerInfoCache:  [String: CacheEntry<PlayerInfo>]               = [:]
    private var trackingCache:    [String: CacheEntry<PlaybackTrackingURLs?>]    = [:]
    private var nextInfoCache:    [String: CacheEntry<NextInfo>]                 = [:]
    private var endCardsCache:    [String: CacheEntry<[EndCard]>]                = [:]
    private var sponsorCache:     [String: CacheEntry<[SponsorSegment]>]         = [:]
    private var deArrowCache:     [String: CacheEntry<DeArrowService.BrandingInfo>] = [:]

    // MARK: - Access order (LRU)

    /// Ordered from oldest to newest access.
    private var accessOrder: [String] = []

    // MARK: - Active prefetch tasks

    private var prefetchTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Concurrency semaphore

    /// Caps the number of simultaneous prefetch network fetches.
    private var activePrefetchCount = 0
    private static let maxConcurrentPrefetches = 3

    private init() {}

    // MARK: - Public: auth token

    /// Forward the current auth token so prefetch requests can make authenticated calls.
    /// Call this from PlaybackViewModel.updateAuthToken and at app launch.
    public func setAuthToken(_ token: String?) async {
        cacheLog.notice("[auth] setAuthToken: \(token != nil ? "present" : "nil", privacy: .public)")
        await api.setAuthToken(token)
    }

    // MARK: - Public: prefetch

    /// Kicks off a background fetch for all data types for `videoId`.
    /// No-op if fresh data already exists or a task is already running.
    /// Pass the actual `authToken` value (not just a Bool) so the cache can
    /// sync it to its internal API before the tracking URL fetch fires —
    /// eliminating a race where prefetch starts before `setAuthToken` runs.
    public func prefetch(
        videoId: String,
        sponsorCategories: Set<SponsorSegment.Category>,
        authToken: String?
    ) {
        // Playlist IDs are not video IDs — skip them to avoid wasted /player calls.
        let isPlaylistId = videoId == "WL" || videoId == "LL" || videoId.hasPrefix("PL")
        if isPlaylistId { return }
        // Skip if still fresh
        if let entry = playerInfoCache[videoId], !entry.isExpired { return }
        // Skip if already in-flight
        if prefetchTasks[videoId] != nil { return }
        // Respect concurrency cap
        guard activePrefetchCount < Self.maxConcurrentPrefetches else { return }
        activePrefetchCount += 1
        let task = Task(priority: .background) {
            await self.runPrefetch(
                videoId: videoId,
                sponsorCategories: sponsorCategories,
                authToken: authToken
            )
            await self.decrementPrefetchCount()
        }
        prefetchTasks[videoId] = task
    }

    /// Cancels any in-flight prefetch for `videoId` (e.g. when a cell scrolls far off screen).
    public func cancelPrefetch(for videoId: String) {
        guard prefetchTasks[videoId] != nil else { return }
        prefetchTasks[videoId]?.cancel()
        prefetchTasks.removeValue(forKey: videoId)
    }

    // MARK: - Public: consume (cache-first read)

    /// Returns whatever fresh cached data exists for `videoId`, or `nil` fields
    /// for data that is missing or expired. Callers fetch only the missing pieces.
    public func consume(videoId: String) -> CachedVideoData {
        touch(videoId)
        let data = CachedVideoData(
            playerInfo:      fresh(playerInfoCache[videoId]),
            trackingURLs:    trackingCache[videoId].flatMap { $0.isExpired ? nil : $0.value },
            nextInfo:        fresh(nextInfoCache[videoId]),
            endCards:        fresh(endCardsCache[videoId]),
            sponsorSegments: fresh(sponsorCache[videoId]),
            deArrowBranding: fresh(deArrowCache[videoId])
        )
        cacheLog.notice("[consume] \(videoId, privacy: .public) — player=\(data.playerInfo != nil, privacy: .public) tracking=\(data.trackingURLs != nil, privacy: .public) next=\(data.nextInfo != nil, privacy: .public) endCards=\(data.endCards != nil, privacy: .public) sponsor=\(data.sponsorSegments != nil, privacy: .public) deArrow=\(data.deArrowBranding != nil, privacy: .public) complete=\(data.isComplete, privacy: .public)")
        return data
    }

    // MARK: - Public: store (write after live fetch)

    public func store(playerInfo: PlayerInfo, for videoId: String) {
        cacheLog.debug("[store] playerInfo \(videoId, privacy: .public) formats=\(playerInfo.formats.count, privacy: .public) hls=\(playerInfo.hlsURL != nil, privacy: .public)")
        playerInfoCache[videoId] = CacheEntry(value: playerInfo, storedAt: .init(), ttl: Self.playerInfoTTL)
        touch(videoId)
    }

    public func store(trackingURLs: PlaybackTrackingURLs?, for videoId: String) {
        cacheLog.debug("[store] trackingURLs \(videoId, privacy: .public) present=\(trackingURLs != nil, privacy: .public)")
        trackingCache[videoId] = CacheEntry(value: trackingURLs, storedAt: .init(), ttl: Self.trackingTTL)
        touch(videoId)
    }

    public func store(nextInfo: NextInfo, for videoId: String) {
        cacheLog.debug("[store] nextInfo \(videoId, privacy: .public) related=\(nextInfo.relatedVideos.count, privacy: .public) chapters=\(nextInfo.chapters.count, privacy: .public)")
        nextInfoCache[videoId] = CacheEntry(value: nextInfo, storedAt: .init(), ttl: Self.nextInfoTTL)
        touch(videoId)
    }

    public func store(endCards: [EndCard], for videoId: String) {
        cacheLog.debug("[store] endCards \(videoId, privacy: .public) count=\(endCards.count, privacy: .public)")
        endCardsCache[videoId] = CacheEntry(value: endCards, storedAt: .init(), ttl: Self.endCardsTTL)
        touch(videoId)
    }

    public func store(sponsorSegments: [SponsorSegment], for videoId: String) {
        cacheLog.debug("[store] sponsorSegments \(videoId, privacy: .public) count=\(sponsorSegments.count, privacy: .public)")
        sponsorCache[videoId] = CacheEntry(value: sponsorSegments, storedAt: .init(), ttl: Self.sponsorTTL)
        touch(videoId)
    }

    public func store(deArrowBranding: DeArrowService.BrandingInfo, for videoId: String) {
        cacheLog.debug("[store] deArrowBranding \(videoId, privacy: .public) hasTitle=\(deArrowBranding.title != nil, privacy: .public)")
        deArrowCache[videoId] = CacheEntry(value: deArrowBranding, storedAt: .init(), ttl: Self.deArrowTTL)
        touch(videoId)
    }

    // MARK: - Public: auth invalidation

    /// Call on sign-out: tracking URLs and like-status in nextInfo are account-bound.
    public func evictAuthSensitiveData() {
        cacheLog.notice("[evict] auth sign-out — clearing trackingCache (\(self.trackingCache.count, privacy: .public) entries) + nextInfoCache (\(self.nextInfoCache.count, privacy: .public) entries)")
        trackingCache.removeAll()
        nextInfoCache.removeAll()
    }

    /// Call after a token refresh: tracking URLs bound to the old token are stale.
    public func evictTrackingURLs() {
        cacheLog.notice("[evict] token refresh — clearing trackingCache (\(self.trackingCache.count, privacy: .public) entries)")
        trackingCache.removeAll()
    }

    // MARK: - Private: prefetch implementation

    private func runPrefetch(
        videoId: String,
        sponsorCategories: Set<SponsorSegment.Category>,
        authToken: String?
    ) async {
        guard !Task.isCancelled else { return }
        let startedAt = Date()

        // Spawn 5 child tasks immediately so they run in parallel with the tracking fetch below.
        async let playerResult   = (try? await api.fetchPlayerInfo(videoId: videoId))
        async let nextResult     = (try? await api.fetchNextInfo(videoId: videoId))
        async let endCardsResult = (try? await api.fetchEndCards(videoId: videoId))
        async let sponsorResult  = await sponsorBlock.fetchSegments(videoId: videoId, categories: sponsorCategories)
        async let deArrowResult  = await deArrow.fetchBranding(videoId: videoId)

        // Pass the caller-supplied token directly — no dependency on api.authToken being set —
        // eliminating the actor-timing race that caused tracking=false on browse-phase prefetch.
        // This runs concurrently with the 5 child tasks above (all are in flight by this point).
        let tracking: PlaybackTrackingURLs?
        if let token = authToken {
            tracking = await api.fetchAuthenticatedTrackingURLs(videoId: videoId, usingToken: token)
        } else {
            tracking = nil
        }

        let (player, next, cards, sponsor, dearrow) =
            await (playerResult, nextResult, endCardsResult, sponsorResult, deArrowResult)

        guard !Task.isCancelled else { return }

        let elapsed = String(format: "%.2fs", Date().timeIntervalSince(startedAt))
        _ = elapsed

        if let player  { store(playerInfo: player,          for: videoId) }
        store(trackingURLs: tracking,                        for: videoId)
        if let next    { store(nextInfo: next,               for: videoId) }
        if let cards   { store(endCards: cards,              for: videoId) }
        store(sponsorSegments: sponsor,                      for: videoId)
        store(deArrowBranding: dearrow,                      for: videoId)

        prefetchTasks.removeValue(forKey: videoId)
    }

    private func decrementPrefetchCount() {
        activePrefetchCount = max(0, activePrefetchCount - 1)
    }

    // MARK: - Private: LRU helpers

    private func touch(_ videoId: String) {
        accessOrder.removeAll { $0 == videoId }
        accessOrder.append(videoId)
        if accessOrder.count > Self.maxVideoEntries {
            let evict = accessOrder.removeFirst()
            cacheLog.notice("[lru] EVICT \(evict, privacy: .public) — cache full (\(Self.maxVideoEntries, privacy: .public) entries)")
            playerInfoCache.removeValue(forKey: evict)
            trackingCache.removeValue(forKey: evict)
            nextInfoCache.removeValue(forKey: evict)
            endCardsCache.removeValue(forKey: evict)
            sponsorCache.removeValue(forKey: evict)
            deArrowCache.removeValue(forKey: evict)
            prefetchTasks[evict]?.cancel()
            prefetchTasks.removeValue(forKey: evict)
        }
    }

    private func fresh<T: Sendable>(_ entry: CacheEntry<T>?) -> T? {
        guard let entry, !entry.isExpired else { return nil }
        return entry.value
    }
}

// MARK: - CachedVideoData

/// A snapshot of whatever pre-fetched data is available for a video.
/// Fields that are `nil` were not cached or have expired — callers must fetch those live.
public struct CachedVideoData: Sendable {
    public let playerInfo:      PlayerInfo?
    public let trackingURLs:    PlaybackTrackingURLs??   // outer nil = not cached, inner nil = cached as "no URLs"
    public let nextInfo:        NextInfo?
    public let endCards:        [EndCard]?
    public let sponsorSegments: [SponsorSegment]?
    public let deArrowBranding: DeArrowService.BrandingInfo?

    /// True when every field that is required for instant playback start is fresh.
    public var isComplete: Bool {
        playerInfo != nil && nextInfo != nil && sponsorSegments != nil
    }
}
