import SwiftUI
import SmartTubeIOSCore

// MARK: - HomeView
//
// YouTube-style home tab.  A horizontal chip bar at the top lets the user
// switch between every available section:
//   • "Home"  chip  → multi-shelf overview (Subscriptions row,
//                      Recommended row) driven by HomeViewModel.
//   • Any other chip → full-screen video feed for that section driven by a
//                      dedicated BrowseViewModel instance.

public struct HomeView: View {
    @State private var homeVM: HomeViewModel
    @State private var sectionVM: BrowseViewModel
    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var store
    @Environment(\.innerTubeAPI) private var api
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(PlayerStateStore.self) private var playerState
    #endif

    // "Home" is always first; its type is .home.
    @State private var selectedSection: BrowseSection = BrowseSection.allSections[0]
    @State private var selectedVideo: Video?
    @State private var selectedPlaylist: Video?
    @State private var shortsPresentation: ShortsPresentation?
    @State private var channelDestination: ChannelDestination?
    @State private var showSignIn = false
    @State private var queueVideosCount: Int = 0
    #if os(tvOS)
    @FocusState private var focusedSection: BrowseSection?
    #endif
    private var visibleSections: [BrowseSection] {
        let types = store.settings.enabledSections
        var all: [BrowseSection] = types.isEmpty
            ? BrowseSection.defaultSections
            : types.compactMap { type in BrowseSection.allSections.first { $0.type == type } }
        // Always keep a "Recommended" chip directly after the "Home" chip so the
        // user can filter to only recommended videos regardless of settings.
        if !all.contains(where: { $0.type == .recommended }),
           let homeIdx = all.firstIndex(where: { $0.type == .home }) {
            all.insert(BrowseSection(type: .recommended), at: homeIdx + 1)
        }
        if store.settings.hideShorts {
            return all.filter { $0.type != .shorts }
        }
        return all
    }

    public init(api: InnerTubeAPI) {
        _homeVM = State(initialValue: HomeViewModel(api: api))
        _sectionVM = State(initialValue: BrowseViewModel(api: api))
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            chipBar
            #if !os(tvOS)
            Divider()
            #endif
            contentArea
                #if os(tvOS)
                .navigationDestination(item: $selectedVideo) { video in
                    PlayerView(video: video, api: api)
                }
                #endif
                .navigationDestination(item: $selectedPlaylist) { stub in
                    PlaylistView(playlistId: stub.id, playlistTitle: stub.title, api: api)
                }
                .navigationDestination(item: $channelDestination) { dest in
                    ChannelView(channelId: dest.channelId)
                }
                #if os(tvOS)
                .focusSection()
                #endif
        }
        #if os(iOS)
        // Player cover is centralised in MainTabView; deep-link handled there too.
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(item: $shortsPresentation) { target in
            ShortsPlayerView(videos: target.videos, startIndex: target.startIndex, api: api)
        }
        #endif
        .sheet(isPresented: $showSignIn) { SignInView() }
        .onReceive(NotificationCenter.default.publisher(for: .openChannel)) { note in
            guard let channelId = note.userInfo?["channelId"] as? String, !channelId.isEmpty else { return }
            channelDestination = ChannelDestination(channelId: channelId)
        }
        .onChange(of: visibleSections) { _, newSections in
            if !newSections.contains(selectedSection), let first = newSections.first {
                selectedSection = first
            }
        }
        .task(id: auth.accessToken) {
            await homeVM.updateAuthToken(auth.accessToken)
            await sectionVM.updateAuthToken(auth.accessToken)
        }
        .task(id: selectedSection) {
            if selectedSection.type == .playlists {
                queueVideosCount = await CurrentQueueStore.shared.videos.count
            } else if selectedSection.type != .home {
                // Safety net: if sectionVM somehow fell out of sync with selectedSection
                // (e.g., the chip action raced with an in-flight cancellation, or an
                // @Observable tracking gap left the view empty), force a reload.
                if sectionVM.currentSection != selectedSection {
                    sectionVM.select(section: selectedSection)
                }
            }
        }
    }

    // MARK: - Chip bar

    private var chipBar: some View {
        #if os(tvOS)
        HStack(spacing: 8) {
            ForEach(visibleSections) { section in
                chipButton(section: section)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .focusSection()
        .defaultFocus($focusedSection, selectedSection)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.chipBar")
        #else
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(visibleSections) { section in
                    chipButton(section: section)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .accessibilityIdentifier("home.chipBar")
        #endif
    }

    private func chipButton(section: BrowseSection) -> some View {
        let isSelected = selectedSection == section
        let action = {
            let isNewSection = selectedSection != section
            if isNewSection { selectedSection = section }
            guard section.type != .home else { return }
            if isNewSection {
                sectionVM.select(section: section)
            } else if sectionVM.videoGroups.isEmpty && !sectionVM.isLoading {
                // Same chip re-tapped on an empty section — retry the load.
                // This handles failed fetches or cases where an observation gap
                // left the view showing an empty state despite data being available.
                sectionVM.reload(section: section)
            }
        }
        #if os(tvOS)
        let isFocused = focusedSection == section
        return Button(action: action) {
            Text(section.title)
                .font(.headline)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    (isSelected || isFocused) ? Color.primary : Color.secondary.opacity(0.15),
                    in: Capsule()
                )
                .foregroundStyle(
                    (isSelected || isFocused)
                        ? Color(white: colorScheme == .dark ? 0 : 1)
                        : Color.primary
                )
                .focusEffectDisabled()
        }
        .buttonStyle(.borderless)
        .scaleEffect(isFocused ? 1.12 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: focusedSection)
        .animation(.easeInOut(duration: 0.15), value: selectedSection)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel(section.title)
        .accessibilityIdentifier("chip.\(section.title)")
        .focused($focusedSection, equals: section)
        #else
        return Button(action: action) {
            Text(section.title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    isSelected ? Color.primary : Color.secondary.opacity(0.15),
                    in: Capsule()
                )
                .foregroundStyle(
                    isSelected
                        ? Color(white: colorScheme == .dark ? 0 : 1)
                        : Color.primary
                )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: selectedSection)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        #endif
    }

    // MARK: - Content area

    @ViewBuilder
    private var contentArea: some View {
        if selectedSection.type == .home {
            if auth.isSignedIn {
                homeShelves
            } else {
                homeSignedOutPrompt
            }
        } else if selectedSection.type == .channels {
            channelListFeed
                .accessibilityIdentifier("home.sectionContainer")
        } else {
            sectionFeed
                .accessibilityIdentifier("home.sectionContainer")
        }
    }

    @ViewBuilder
    private var channelListFeed: some View {
        if sectionVM.isLoading && sectionVM.subscribedChannels.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sectionVM.subscribedChannels.isEmpty && !sectionVM.isLoading {
            feedEmptyState
        } else {
            ChannelListView(channels: sectionVM.subscribedChannels) { channel in
                channelDestination = ChannelDestination(channelId: channel.id)
            }
        }
    }

    private var homeSignedOutPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: AppSymbol.personCircleQuestion)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("Sign in to see your feed")
                .font(.headline)
                .foregroundStyle(.secondary)
            Button("Sign In") { showSignIn = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Home shelves  (unified interleaved feed)

    private var homeShelves: some View {
        Group {
            if homeVM.isLoadingAny && homeVM.mergedVideos.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let hideShorts = store.settings.hideShorts
                let regularVideos = homeVM.homeRegularVideos
                let shortsVideos = hideShorts ? [] : homeVM.homeShortsVideos
                ScrollView {
                    if !shortsVideos.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Shorts")
                                .font(.headline)
                                .padding(.horizontal)
                                .padding(.top, 16)
                                .padding(.bottom, 4)
                            ShortsRowSection(
                                videos: shortsVideos,
                                onSelect: { selectVideo($0, from: shortsVideos) },
                                accessibilityID: "home.shortsRow"
                            )
                        }
                    }
                    VideoGridSection(
                        videos: regularVideos,
                        onSelect: { selectVideo($0, from: regularVideos) },
                        loadMore: { homeVM.loadMoreMerged() }
                    )
                    let isLoadingMore = homeVM.sections.contains { $0.isLoadingMore }
                    if isLoadingMore {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    }
                }
                .refreshable { homeVM.load() }
                #if os(tvOS)
                .focusSection()
                #endif
            }
        }
    }

    // MARK: - Section feed  (non-Home chips)

    @ViewBuilder
    private var sectionFeed: some View {
        if sectionVM.isLoading && sectionVM.videoGroups.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sectionVM.videoGroups.isEmpty && !sectionVM.isLoading {
            feedEmptyState
        } else {
            feedContent
        }
    }

    private var feedContent: some View {
        let hideShorts = store.settings.hideShorts
        let rowGroups: [VideoGroup] = sectionVM.videoGroups.filter { $0.layout == .row }.map { g in
            guard hideShorts else { return g }
            var copy = g
            copy.videos = g.videos.filter { !$0.isShort }
            return copy
        }
        let gridVideos = sectionVM.videoGroups.filter { $0.layout != .row }.flatMap(\.videos).filter { !hideShorts || !$0.isShort }
        // VStack (not LazyVStack) is required here. LazyVGrid inside LazyVStack
        // collapses to zero height — grid items become invisible and non-tappable
        // because LazyVStack never provides a measured height to LazyVGrid.
        // Row groups are few (typically ≤15 carousels) so eager rendering is fine.
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if selectedSection.type == .playlists, queueVideosCount > 0 {
                    currentQueueRow
                }
                // Shorts row for Recommended section.
                // FEwhat_to_watch (TV client) never includes a Shorts shelf, so
                // BrowseViewModel fetches FEshorts separately and stores them here.
                if selectedSection.type == .recommended,
                   !hideShorts,
                   !sectionVM.recommendedShortsVideos.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Shorts")
                            .font(.headline)
                            .padding(.horizontal)
                            .padding(.top, 16)
                            .padding(.bottom, 4)
                        ShortsRowSection(
                            videos: sectionVM.recommendedShortsVideos,
                            onSelect: { selectVideo($0, from: sectionVM.recommendedShortsVideos) },
                            accessibilityID: "recommended.shortsRow"
                        )
                    }
                }
                ForEach(rowGroups) { group in
                    if let title = group.title, !title.isEmpty {
                        Text(title)
                            .font(.headline)
                            .padding(.horizontal)
                            .padding(.top, 16)
                            .padding(.bottom, 4)
                    }
                    VideoRowSection(videos: group.videos, onSelect: { selectVideo($0, from: group.videos) })
                }
                if !gridVideos.isEmpty {
                    VideoGridSection(
                        videos: gridVideos,
                        onSelect: { selectVideo($0, from: gridVideos) },
                        loadMore: { if let last = gridVideos.last { sectionVM.loadMoreIfNeeded(lastVideo: last) } }
                    )
                }
                if sectionVM.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
        }
        .accessibilityIdentifier("home.sectionFeed")
        .refreshable { sectionVM.loadContent(refresh: true) }
        #if os(tvOS)
        .focusSection()
        #endif
    }

    @ViewBuilder private var currentQueueRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "list.number")
                .font(.title2)
                .frame(width: 44, height: 44)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Current Queue")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                Text("\(queueVideosCount) video\(queueVideosCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedPlaylist = Video(
                id: CurrentQueueStore.playlistID,
                title: "Current Queue",
                channelTitle: ""
            )
        }
        .accessibilityIdentifier("home.currentQueueRow")
        Divider().padding(.horizontal)
    }

    private var feedEmptyState: some View {
        VStack(spacing: 16) {
            if sectionVM.isAuthRequired && !auth.isSignedIn {
                Image(systemName: AppSymbol.personCircleWarning)
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
                Text("Sign in to see this section")
                    .font(.title3)
                Text("Your Google account is required.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Sign In") { showSignIn = true }
                    .buttonStyle(.borderedProminent)
            } else if !auth.isSignedIn && (selectedSection.type == .subscriptions || selectedSection.type == .channels) {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
                Text("Follow channels to see their latest videos here")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                Text("Search for a channel and tap Follow.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Search") {
                    NotificationCenter.default.post(name: .navigateToSearch, object: nil)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Image(systemName: AppSymbol.tvPlay)
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
                Text("Nothing here yet")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Button("Refresh") { sectionVM.loadContent(refresh: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Video selection

    private func selectVideo(_ video: Video, from groupVideos: [Video]) {
        if video.playlistId == video.id {
            selectedPlaylist = video
        } else if video.isShort {
            #if os(iOS)
            let shorts = groupVideos.filter { $0.isShort }
            let idx = shorts.firstIndex(where: { $0.id == video.id }) ?? 0
            shortsPresentation = ShortsPresentation(videos: shorts, startIndex: idx)
            #else
            selectedVideo = video
            #endif
        } else {
            #if os(iOS)
            playerState.play(video: video)
            #else
            selectedVideo = video
            #endif
        }
    }
}
