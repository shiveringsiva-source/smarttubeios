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

    // "Home" is always first; its type is .home.
    @State private var selectedSection: BrowseSection = BrowseSection.allSections[0]
    @State private var selectedVideo: Video?
    @State private var selectedPlaylist: Video?
    @State private var shortsPresentation: ShortsPresentation?
    @State private var channelDestination: ChannelDestination?
    @State private var showSignIn = false
    #if os(tvOS)
    @FocusState private var focusedSection: BrowseSection?
    #endif
    private var visibleSections: [BrowseSection] {
        let types = store.settings.enabledSections
        let all: [BrowseSection] = types.isEmpty
            ? BrowseSection.defaultSections
            : types.compactMap { type in BrowseSection.allSections.first { $0.type == type } }
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
                #if os(iOS)
                .fullScreenCover(item: $selectedVideo) { video in
                    PlayerView(video: video, api: api)
                }
                #else
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
            guard selectedSection != section else { return }
            selectedSection = section
            if section.type != .home {
                sectionVM.select(section: section)
            }
        }
        #if os(tvOS)
        let isFocused = focusedSection == section
        return Button(action: action) {
            Text(section.title)
                .font(.title3.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
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

    // MARK: - Home shelves  (multi-section overview)

    private var homeShelves: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(homeVM.sections) { state in
                    if state.isLoading || !state.videos.isEmpty {
                        sectionView(state: state)
                    }
                }
            }
        }
        .refreshable { homeVM.load() }
        #if os(tvOS)
        .focusSection()
        #endif
    }

    @ViewBuilder
    private func sectionView(state: HomeViewModel.SectionState) -> some View {
        let hideShorts = store.settings.hideShorts
        let videos: [Video] = hideShorts ? state.videos.filter { !$0.isShort } : state.videos
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.section.title)
                    #if os(tvOS)
                    .font(.title2.bold())
                    #else
                    .font(.title3.bold())
                    #endif
                    .padding(.horizontal)
                    .padding(.top, 20)
                    .padding(.bottom, 8)
                Spacer()
                if !state.videos.isEmpty && state.section.type != .home {
                    Button("See all") {
                        if let chip = visibleSections.first(where: { $0.id == state.section.id }) {
                            selectedSection = chip
                            sectionVM.select(section: chip)
                        }
                    }
                    #if os(tvOS)
                    .font(.title3)
                    #else
                    .font(.subheadline)
                    #endif
                    .padding(.trailing)
                    .padding(.top, 20)
                }
            }
            if state.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                VideoGridSection(
                    videos: videos,
                    onSelect: { selectVideo($0, from: videos) },
                    loadMore: { homeVM.loadMore(sectionId: state.section.id) }
                )
                if state.isLoadingMore {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
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
        // LazyVStack for performance. Scroll position is preserved by UIKit across
        // fullScreenCover modal transitions (PlayerView is now presented as a cover).
        return ScrollView {
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
        .accessibilityIdentifier("home.sectionFeed")
        .refreshable { sectionVM.loadContent(refresh: true) }
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private var feedEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: sectionVM.isAuthRequired ? "person.crop.circle.badge.exclamationmark" : "play.tv")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            if sectionVM.isAuthRequired && !auth.isSignedIn {
                Text("Sign in to see this section")
                    .font(.title3)
                Text("Your Google account is required.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Sign In") { showSignIn = true }
                    .buttonStyle(.borderedProminent)
            } else {
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
            let shorts = groupVideos.filter { $0.isShort }
            let idx = shorts.firstIndex(where: { $0.id == video.id }) ?? 0
            shortsPresentation = ShortsPresentation(videos: shorts, startIndex: idx)
        } else {
            selectedVideo = video
        }
    }
}
