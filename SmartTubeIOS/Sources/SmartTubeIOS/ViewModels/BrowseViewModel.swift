import Foundation
import Observation
import os
import SmartTubeIOSCore

private let browseLog = CrashlyticsLogger(category: "Browse")

// MARK: - BrowseViewModel
//
// Drives the main browse screen.  Mirrors the Android `BrowsePresenter`.

@MainActor
@Observable
public final class BrowseViewModel {

    // MARK: - State

    public private(set) var sections: [BrowseSection] = BrowseSection.defaultSections
    public private(set) var currentSection: BrowseSection = BrowseSection.defaultSections[0]
    public private(set) var videoGroups: [VideoGroup] = []
    /// Populated when the current section is `.channels`; empty for all other sections.
    public private(set) var subscribedChannels: [Channel] = []
    public private(set) var isLoading: Bool = false
    public var error: Error?
    /// True when the current section requires authentication and the user is not signed in.
    public private(set) var isAuthRequired: Bool = false
    /// Timestamp of the last successful content fetch for the current section.
    /// Used to detect stale feeds after the app returns from background.
    public private(set) var loadedAt: Date? = nil
    /// A video to open immediately via deeplink / URL interception.
    /// Cleared by the UI after the player is presented.
    public var deepLinkedVideo: Video?

    // MARK: - Dependencies

    private let api: InnerTubeAPI
    private var fetchTask: Task<Void, Never>?
    private var enrichTask: Task<Void, Never>?
    /// When `false`, the History section returns empty content rather than fetching from YouTube.
    private var historyEnabled: Bool = true

    public init(api: InnerTubeAPI = InnerTubeAPI(), initialSection: BrowseSection? = nil) {
        self.api = api
        if let initial = initialSection {
            // Ensure the initial section appears in the picker list.
            if !sections.contains(initial) {
                sections = [initial] + sections
            }
            currentSection = initial
        }
    }

    // MARK: - Section selection

    public func select(section: BrowseSection) {
        guard section != currentSection else {
            browseLog.notice("select: already on section \(section.title) — ignored")
            return
        }
        let fromTitle = currentSection.title
        browseLog.notice("select: switching to \(section.title) from \(fromTitle)")
        currentSection = section
        loadContent(for: section, refresh: true, source: "select")
    }

    /// Rebuilds the visible sections list from settings.
    /// Call this when AppSettings.enabledSections changes.
    public func configureSections(_ enabledTypes: [BrowseSection.SectionType]) {
        let allSections = BrowseSection.allSections
        let ordered = enabledTypes.compactMap { type in allSections.first { $0.type == type } }
        sections = ordered.isEmpty ? BrowseSection.defaultSections : ordered
        // If current section is no longer in the list, switch to first
        if !sections.contains(currentSection), let first = sections.first {
            currentSection = first
        }
    }

    // MARK: - Loading

    public func loadContent(for section: BrowseSection? = nil, refresh: Bool = false, source: String = "unknown") {
        let target = section ?? currentSection
        let chCount = subscribedChannels.count
        let vCount = videoGroups.flatMap(\.videos).count
        let loading = isLoading
        browseLog.notice("loadContent source=\(source) section=\(target.title) refresh=\(refresh) channels=\(chCount) videos=\(vCount) loading=\(loading)")
        if refresh {
            videoGroups = []
            subscribedChannels = []
            loadedAt = nil
            enrichTask?.cancel()
            enrichTask = nil
        }
        fetchTask?.cancel()
        fetchTask = Task { await fetchSection(target) }
    }

    public func loadMoreIfNeeded(lastVideo: Video) {
        guard let lastGroup = videoGroups.last,
              let lastInGroup = lastGroup.videos.last,
              lastInGroup.id == lastVideo.id,
              lastGroup.nextPageToken != nil,
              !isLoading
        else { return }
        isLoading = true  // synchronous guard — prevents duplicate tasks before the Task body runs
        fetchTask = Task { await fetchNextPage(for: currentSection) }
    }

    /// Refreshes the current section's feed if the last successful fetch was more than
    /// `threshold` seconds ago (default 15 min). No-op while a fetch is already in flight.
    public func refreshIfStale(threshold: TimeInterval = 15 * 60) {
        guard !isLoading else { return }
        let age = loadedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        guard age > threshold else { return }
        let ageDesc = age.isFinite ? "\(Int(age))s" : "never loaded"
        browseLog.notice("refreshIfStale: age=\(ageDesc) > threshold=\(Int(threshold))s — refreshing \(currentSection.title)")
        loadContent(refresh: true, source: "refreshIfStale")
    }

    /// Update whether history is enabled. If currently on the history section, reloads it.
    public func updateHistoryEnabled(_ enabled: Bool) {
        guard historyEnabled != enabled else { return }
        historyEnabled = enabled
        if currentSection.type == .history {
            loadContent(refresh: true, source: "updateHistoryEnabled")
        }
    }

    // MARK: - Auth

    /// Triggers a content reload when auth state changes.
    /// Sets the token on the API first so that the fetch always runs authenticated.
    public func updateAuthToken(_ token: String?) async {
        await api.setAuthToken(token)
        if token != nil {
            loadContent(refresh: true, source: "updateAuthToken")
        }
    }

    // MARK: - Private fetching

    private func fetchSection(_ section: BrowseSection) async {
        isLoading = true
        defer { isLoading = false }
        browseLog.notice("Fetching section: \(section.title) (\(String(describing: section.type)))")
        do {
            switch section.type {

            case .home:
                let rows = try await api.fetchHomeRows()
                if !Task.isCancelled {
                    if rows.flatMap({ $0.videos }).isEmpty {
                        isAuthRequired = true
                        let popular = try await api.search(query: "popular")
                        videoGroups = [popular]
                    } else {
                        isAuthRequired = false
                        videoGroups = rows
                    }
                }

            case .subscriptions:
                let group = try await api.fetchSubscriptions()
                if !Task.isCancelled {
                    isAuthRequired = group.videos.isEmpty
                    videoGroups = group.videos.isEmpty ? [] : [group]
                }

            case .history:
                guard historyEnabled else {
                    if !Task.isCancelled { videoGroups = []; isAuthRequired = false }
                    return
                }
                let group = try await api.fetchHistory()
                if !Task.isCancelled {
                    isAuthRequired = group.videos.isEmpty
                    videoGroups = group.videos.isEmpty ? [] : [group]
                }

            case .playlists:
                let playlists = try await api.fetchUserPlaylists()
                if !Task.isCancelled {
                    isAuthRequired = playlists.isEmpty
                    // Convert PlaylistInfo list into a VideoGroup of placeholder videos
                    let videos = playlists.map { pl -> Video in
                        Video(id: pl.id, title: pl.title, channelTitle: pl.videoCount.map { "\($0) videos" } ?? "",
                              thumbnailURL: pl.thumbnailURL, playlistId: pl.id)
                    }
                    videoGroups = videos.isEmpty ? [] : [VideoGroup(title: "Playlists", videos: videos)]
                }

            case .channels:
                let channels = try await api.fetchSubscribedChannels()
                browseLog.notice("channels fetch complete: \(channels.count) channels, isCancelled=\(Task.isCancelled)")
                if !Task.isCancelled {
                    isAuthRequired = channels.isEmpty
                    subscribedChannels = channels
                    videoGroups = []
                    let chCount = subscribedChannels.count
                    let authReq = isAuthRequired
                    browseLog.notice("channels state set: subscribedChannels=\(chCount) isAuthRequired=\(authReq)")
                    // Background-enrich avatars — the guide/params approaches yield no thumbnails;
                    // fetch each channel's About tab concurrently to get the avatar URL.
                    if !channels.isEmpty {
                        enrichTask?.cancel()
                        enrichTask = Task { await self.enrichChannelAvatars() }
                    }
                }

            case .shorts:
                let group = try await api.fetchShorts()
                if !Task.isCancelled { videoGroups = [group] }

            case .music:
                let group = try await api.fetchMusic()
                if !Task.isCancelled { videoGroups = [group] }

            case .gaming:
                let group = try await api.fetchGaming()
                if !Task.isCancelled { videoGroups = [group] }

            case .news:
                let group = try await api.fetchNews()
                if !Task.isCancelled { videoGroups = [group] }

            case .live:
                let group = try await api.fetchLive()
                if !Task.isCancelled { videoGroups = [group] }

            case .sports:
                let group = try await api.fetchSports()
                if !Task.isCancelled { videoGroups = [group] }

            case .settings:
                break
            }
            if !Task.isCancelled { loadedAt = Date() }
        } catch {
            if !Task.isCancelled {
                // HTTP 401/403 on an auth-gated section means the user is not signed in
                // rather than a real error — surface it as a sign-in prompt.
                let authSections: Set<BrowseSection.SectionType> = [.subscriptions, .history, .playlists, .channels]
                if let apiErr = error as? APIError,
                   case .httpError(let code) = apiErr,
                   (code == 401 || code == 403),
                   authSections.contains(section.type) {
                    isAuthRequired = true
                    browseLog.notice("Auth required for \(section.title) (HTTP \(code))")
                } else {
                    isAuthRequired = false
                    browseLog.error("❌ \(section.title) error: \(String(describing: error))")
                    self.error = error
                }
            }
        }
    }

    private func fetchNextPage(for section: BrowseSection) async {
        guard let token = videoGroups.last?.nextPageToken else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            switch section.type {
            case .home:
                let newRows = try await api.fetchHomeRows(continuationToken: token)
                if !Task.isCancelled { videoGroups.append(contentsOf: newRows) }
            case .subscriptions:
                let group = try await api.fetchSubscriptions(continuationToken: token)
                if !Task.isCancelled { mergeIntoFirstGroup(group) }
            case .history:
                let group = try await api.fetchHistory(continuationToken: token)
                if !Task.isCancelled { mergeIntoFirstGroup(group) }
            case .channels:
                break  // channel list doesn't paginate via videoGroups
            case .shorts:
                let group = try await api.fetchShorts()
                if !Task.isCancelled { mergeIntoFirstGroup(group) }
            case .music:
                let group = try await api.fetchMusic()
                if !Task.isCancelled { mergeIntoFirstGroup(group) }
            case .gaming:
                let group = try await api.fetchGaming()
                if !Task.isCancelled { mergeIntoFirstGroup(group) }
            case .news:
                let group = try await api.fetchNews()
                if !Task.isCancelled { mergeIntoFirstGroup(group) }
            case .live:
                let group = try await api.fetchLive()
                if !Task.isCancelled { mergeIntoFirstGroup(group) }
            case .sports:
                let group = try await api.fetchSports()
                if !Task.isCancelled { mergeIntoFirstGroup(group) }
            default:
                break
            }
        } catch {
            if !Task.isCancelled { self.error = error }
        }
    }

    /// Appends `group.videos` into `videoGroups[0]` and updates its pagination token.
    /// Falls back to inserting `group` as a new group if none exist yet.
    private func mergeIntoFirstGroup(_ group: VideoGroup) {
        if videoGroups.isEmpty {
            videoGroups.append(group)
        } else {
            videoGroups[0].videos.append(contentsOf: group.videos)
            videoGroups[0].nextPageToken = group.nextPageToken
        }
    }

    // MARK: - Channel avatar enrichment

    /// Concurrently fetches the avatar thumbnail URL for each subscribed channel and
    /// patches it into `subscribedChannels` as results arrive.
    ///
    /// The TV subscription feed only returns video tiles (no channel avatars), so we
    /// fetch each channel's About tab to get the avatar URL. Requests are fired
    /// concurrently. The task is cancelled automatically when the user leaves the
    /// Channels section (enrichTask?.cancel() in loadContent).
    private func enrichChannelAvatars() async {
        let snapshot = subscribedChannels
        guard !snapshot.isEmpty else { return }
        let missing = snapshot.filter { $0.thumbnailURL == nil }
        guard !missing.isEmpty else { return }
        browseLog.notice("enrichChannelAvatars: fetching avatars for \(missing.count) channels")

        let apiRef = api
        let indexByID: [String: Int] = Dictionary(
            uniqueKeysWithValues: snapshot.enumerated().map { ($1.id, $0) }
        )

        await withTaskGroup(of: (String, URL?).self) { group in
            for channel in missing {
                guard !Task.isCancelled else { break }
                let channelId = channel.id
                group.addTask {
                    let url = try? await apiRef.fetchChannelThumbnailURL(channelId: channelId)
                    return (channelId, url)
                }
            }
            for await (channelId, thumbURL) in group {
                guard !Task.isCancelled else { break }
                guard let thumbURL,
                      let idx = indexByID[channelId],
                      idx < self.subscribedChannels.count
                else { continue }
                self.subscribedChannels[idx].thumbnailURL = thumbURL
            }
        }

        let finalCount = self.subscribedChannels.filter { $0.thumbnailURL != nil }.count
        let total = self.subscribedChannels.count
        browseLog.notice("enrichChannelAvatars done: \(finalCount)/\(total) have avatars")
    }
}
