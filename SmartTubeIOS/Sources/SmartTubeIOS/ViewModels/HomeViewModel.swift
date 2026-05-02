import Foundation
import Observation
import os
import SmartTubeIOSCore

private let homeLog = CrashlyticsLogger(category: "Home")

// MARK: - HomeViewModel
//
// Fetches Subscriptions and Recommended shelves in parallel
// to populate the Home tab's multi-section feed.

@MainActor
@Observable
public final class HomeViewModel {

    // MARK: - Section state

    public struct SectionState: Identifiable {
        public let section: BrowseSection
        public var videos: [Video] = []
        public var isLoading: Bool = true
        public var isLoadingMore: Bool = false
        public var hasFailed: Bool = false
        public var nextPageToken: String? = nil
        public var id: String { section.id }
    }

    // MARK: - State

    public private(set) var sections: [SectionState]
    public private(set) var isRefreshing: Bool = false
    /// Timestamp of the last successful load. Used for staleness checks.
    public private(set) var loadedAt: Date? = nil

    // MARK: - Shelf definitions (in display order)

    public static let shelfSections: [BrowseSection] = [
        BrowseSection(id: BrowseSection.SectionType.home.rawValue,          title: "Recommended",   type: .home),
        BrowseSection(id: BrowseSection.SectionType.subscriptions.rawValue, title: "Subscriptions", type: .subscriptions),
    ]

    // MARK: - Dependencies

    private let api: InnerTubeAPI
    private var loadTask: Task<Void, Never>?

    public init(api: InnerTubeAPI = InnerTubeAPI()) {
        self.api = api
        self.sections = Self.shelfSections.map { SectionState(section: $0) }
    }

    // MARK: - Public API

    public func load() {
        loadTask?.cancel()
        loadedAt = nil
        isRefreshing = true
        for i in sections.indices {
            sections[i].videos = []
            sections[i].isLoading = true
            sections[i].isLoadingMore = false
            sections[i].hasFailed = false
            sections[i].nextPageToken = nil
        }
        loadTask = Task {
            await withTaskGroup(of: (String, [Video], String?).self) { group in
                for state in sections {
                    let sectionId = state.id
                    let type = state.section.type
                    let api = self.api
                    group.addTask {
                        let (videos, token) = await HomeViewModel.fetchVideos(type: type, api: api)
                        return (sectionId, videos, token)
                    }
                }
                for await (sectionId, videos, token) in group {
                    guard !Task.isCancelled else { break }
                    if let idx = sections.firstIndex(where: { $0.id == sectionId }) {
                        sections[idx].videos = videos
                        sections[idx].nextPageToken = token
                        sections[idx].isLoading = false
                        sections[idx].hasFailed = videos.isEmpty
                    }
                }
            }
            isRefreshing = false
            loadedAt = Date()
        }
    }

    public func updateAuthToken(_ token: String?) async {
        await api.setAuthToken(token)
        if token != nil { load() }
    }

    /// Refreshes both shelves if the last successful load was more than
    /// `threshold` seconds ago (default 15 min). No-op while loading.
    public func refreshIfStale(threshold: TimeInterval = 15 * 60) {
        guard !isRefreshing else { return }
        let age = loadedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        guard age > threshold else { return }
        let ageDesc = age.isFinite ? "\(Int(age))s" : "never loaded"
        homeLog.notice("refreshIfStale: age=\(ageDesc) — reloading shelves")
        load()
    }

    // MARK: - Pagination

    public func loadMore(sectionId: String) {
        guard let idx = sections.firstIndex(where: { $0.id == sectionId }),
              let token = sections[idx].nextPageToken,
              !sections[idx].isLoadingMore,
              !sections[idx].isLoading else { return }
        sections[idx].isLoadingMore = true
        let type = sections[idx].section.type
        Task {
            let (newVideos, nextToken) = await HomeViewModel.fetchMoreVideos(type: type, token: token, api: api)
            if let idx = sections.firstIndex(where: { $0.id == sectionId }) {
                let existingIds = Set(sections[idx].videos.map(\.id))
                let deduplicated = newVideos.filter { !existingIds.contains($0.id) }
                sections[idx].videos.append(contentsOf: deduplicated)
                sections[idx].nextPageToken = nextToken
                sections[idx].isLoadingMore = false
            }
        }
    }

    // MARK: - Private fetch helpers

    /// Non-isolated so child tasks run on the global executor and network
    /// calls can overlap.
    private static func fetchVideos(type: BrowseSection.SectionType, api: InnerTubeAPI) async -> ([Video], String?) {
        do {
            switch type {
            case .subscriptions:
                let group = try await api.fetchSubscriptions()
                return (Array(group.videos.prefix(InnerTubeClients.maxVideoResults)), group.nextPageToken)
            case .home:
                let rows = try await api.fetchHomeRows()
                let token = rows.last(where: { $0.nextPageToken != nil })?.nextPageToken
                var seen = Set<String>()
                let deduped = rows.flatMap(\.videos).filter { seen.insert($0.id).inserted }
                if deduped.isEmpty {
                    // Home feed empty (no watch history / feedNudgeRenderer) — fall back to popular
                    let popular = try await api.search(query: "popular")
                    return (popular.videos, popular.nextPageToken)
                }
                return (Array(deduped.prefix(InnerTubeClients.maxVideoResults)), token)
            default:
                return ([], nil)
            }
        } catch {
            homeLog.error("HomeViewModel fetch \(String(describing: type)): \(error.localizedDescription)")
            return ([], nil)
        }
    }

    private static func fetchMoreVideos(type: BrowseSection.SectionType, token: String, api: InnerTubeAPI) async -> ([Video], String?) {
        do {
            switch type {
            case .subscriptions:
                let group = try await api.fetchSubscriptions(continuationToken: token)
                return (group.videos, group.nextPageToken)
            case .home:
                let rows = try await api.fetchHomeRows(continuationToken: token)
                let nextToken = rows.last(where: { $0.nextPageToken != nil })?.nextPageToken
                return (rows.flatMap(\.videos), nextToken)
            default:
                return ([], nil)
            }
        } catch {
            homeLog.error("HomeViewModel loadMore \(String(describing: type)): \(error.localizedDescription)")
            return ([], nil)
        }
    }
}
