import SwiftUI
import SmartTubeIOSCore

// MARK: - BrowseView
//
// Main home feed.  Mirrors the Android `BrowseFragment`.

public struct BrowseView: View {
    @Environment(BrowseViewModel.self) private var vm
    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var settings
    @Environment(\.innerTubeAPI) private var api
    @State private var selectedVideo: Video?
    @State private var selectedPlaylist: Video?
    @State private var shortsPresentation: ShortsPresentation?
    @State private var channelDestination: ChannelDestination?
    @State private var showSignIn = false
    @State private var showError = false
    #if os(iOS)
    @Environment(PlayerStateStore.self) private var playerState
    #endif

    public init() {}

    public var body: some View {
        Group {
            if vm.isLoading && vm.videoGroups.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.videoGroups.isEmpty && !vm.isLoading {
                emptyState
            } else {
                content
            }
        }
        .navigationTitle(vm.currentSection.title)
        .toolbar { sectionPicker }
        #if !os(iOS) && !os(macOS)
        .fullScreenCover(item: $selectedVideo) { video in
            PlayerView(video: video, api: api)
        }
        #endif
        .navigationDestination(item: $selectedPlaylist) { stub in
            PlaylistView(playlistId: stub.id, playlistTitle: stub.title, api: api)
        }
        .navigationDestination(item: $channelDestination) { dest in
            ChannelView(channelId: dest.channelId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChannel)) { note in
            guard let channelId = note.userInfo?["channelId"] as? String, !channelId.isEmpty else { return }
            channelDestination = ChannelDestination(channelId: channelId)
        }
        .alert("Error", isPresented: $showError, presenting: vm.error) { _ in
            Button("Retry") { vm.loadContent(refresh: true) }
            Button("Dismiss", role: .cancel) { vm.error = nil }
        } message: { err in
            Text(err.localizedDescription)
        }
        .onChange(of: vm.error == nil ? 0 : 1) { _, hasError in
            if hasError == 1 { showError = true }
        }
        #if !os(macOS)
        .fullScreenCover(item: $shortsPresentation) { target in
            ShortsPlayerView(videos: target.videos, startIndex: target.startIndex, api: api)
        }
        #endif
        .sheet(isPresented: $showSignIn) { SignInView() }
        .onAppear {
            if vm.videoGroups.isEmpty { vm.loadContent() }
        }
        .refreshable { vm.loadContent(refresh: true) }
    }

    // MARK: - Subviews

    private var content: some View {
        let hideShorts = settings.settings.hideShorts
        let rowGroups: [VideoGroup] = vm.videoGroups.filter { $0.layout == .row }.map { g in
            guard hideShorts else { return g }
            var copy = g
            copy.videos = g.videos.filter { !$0.isShort }
            return copy
        }
        let gridVideos = vm.videoGroups.filter { $0.layout != .row }.flatMap(\.videos).filter { !hideShorts || !$0.isShort }
        return ScrollView {
            if settings.settings.compactThumbnails {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if vm.isAuthRequired && !auth.isSignedIn { guestBanner }
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
                    ForEach(gridVideos) { video in
                        #if os(tvOS)
                        Button { selectVideo(video, from: gridVideos) } label: {
                            VideoCardView(video: video, compact: true)
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("video.card.\(video.id)")
                        .onAppear {
                            if video.id == gridVideos.last?.id {
                                vm.loadMoreIfNeeded(lastVideo: video)
                            }
                        }
                        #else
                        VideoCardView(video: video, compact: true)
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                            .accessibilityIdentifier("video.card.\(video.id)")
                            .onTapGesture { selectVideo(video, from: gridVideos) }
                            .onAppear {
                                if video.id == gridVideos.last?.id {
                                    vm.loadMoreIfNeeded(lastVideo: video)
                                }
                            }
                        #endif
                        Divider().padding(.horizontal)
                    }
                    if vm.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    }
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if vm.isAuthRequired && !auth.isSignedIn { guestBanner }
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
                    ForEach(Array(stride(from: 0, to: gridVideos.count, by: 2)), id: \.self) { idx in
                        HStack(alignment: .top, spacing: videoGridRowSpacing) {
                            let v1 = gridVideos[idx]
                            #if os(tvOS)
                            Button { selectVideo(v1, from: gridVideos) } label: {
                                VideoCardView(video: v1, compact: false)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("video.card.\(v1.id)")
                            #else
                            VideoCardView(video: v1, compact: false)
                                .frame(maxWidth: .infinity)
                                .accessibilityIdentifier("video.card.\(v1.id)")
                                .onTapGesture { selectVideo(v1, from: gridVideos) }
                            #endif
                            if idx + 1 < gridVideos.count {
                                let v2 = gridVideos[idx + 1]
                                #if os(tvOS)
                                Button { selectVideo(v2, from: gridVideos) } label: {
                                    VideoCardView(video: v2, compact: false)
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("video.card.\(v2.id)")
                                #else
                                VideoCardView(video: v2, compact: false)
                                    .frame(maxWidth: .infinity)
                                    .accessibilityIdentifier("video.card.\(v2.id)")
                                    .onTapGesture { selectVideo(v2, from: gridVideos) }
                                #endif
                            } else {
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.horizontal, 0)
                        .padding(.vertical, videoGridRowSpacing / 2)
                        .onAppear {
                            if idx + 2 >= gridVideos.count, let last = gridVideos.last {
                                vm.loadMoreIfNeeded(lastVideo: last)
                            }
                        }
                    }
                    if vm.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    }
                }
            }
        }
    }

    private func selectVideo(_ video: Video, from groupVideos: [Video]) {
        if vm.currentSection.type == .playlists {
            selectedPlaylist = video
        } else if video.isShort {
            let shorts = groupVideos.filter { $0.isShort }
            let idx = shorts.firstIndex(where: { $0.id == video.id }) ?? 0
            shortsPresentation = ShortsPresentation(videos: shorts, startIndex: idx)
        } else {
            #if os(iOS)
            playerState.play(video: video)
            #else
            selectedVideo = video
            #endif
        }
    }

    private var guestBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: AppSymbol.personCircle)
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign in for your personal feed")
                    .font(.subheadline.weight(.semibold))
                Text("Showing popular videos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Sign In") { showSignIn = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        #if !os(tvOS)
        .background(.bar)
        #endif
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: vm.isAuthRequired ? AppSymbol.personCircleWarning : AppSymbol.tvPlay)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            if vm.isAuthRequired && !auth.isSignedIn {
                Text("Sign in to see your feed")
                    .font(.title3)
                Text("Your home feed, subscriptions and history\nrequire a Google account.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Sign In") { showSignIn = true }
                    .buttonStyle(.borderedProminent)
            } else {
                Text("Nothing here yet")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Button("Refresh") { vm.loadContent(refresh: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var sectionPicker: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Section", selection: Binding(
                get: { vm.currentSection },
                set: { vm.select(section: $0) }
            )) {
                ForEach(vm.sections) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }
}

// MARK: - VideoGridSection

struct VideoGridSection: View {
    let videos: [Video]
    let onSelect: (Video) -> Void
    var loadMore: (() -> Void)? = nil

    @Environment(SettingsStore.self) private var store

    var body: some View {
        let compact = store.settings.compactThumbnails
        if compact {
            LazyVStack(spacing: 0) {
                ForEach(videos) { video in
                    #if os(tvOS)
                    Button { onSelect(video) } label: {
                        VideoCardView(video: video, compact: true)
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("video.card.\(video.id)")
                    .onAppear {
                        if video.id == videos.last?.id { loadMore?() }
                    }
                    #else
                    VideoCardView(video: video, compact: true)
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("video.card.\(video.id)")
                        .onTapGesture { onSelect(video) }
                        .onAppear {
                            if video.id == videos.last?.id { loadMore?() }
                        }
                    #endif
                    Divider().padding(.horizontal)
                }
            }
        } else {
            #if os(tvOS)
            // LazyVGrid on tvOS causes the first row of grid items to appear
            // invisible — the focus engine cannot traverse cells that have not
            // been laid out yet. Use LazyVStack + HStack rows (4 per row) instead,
            // which is the same approach BrowseView.content already uses on tvOS.
            let columnCount = 4
            LazyVStack(alignment: .leading, spacing: videoGridRowSpacing) {
                ForEach(Array(stride(from: 0, to: videos.count, by: columnCount)), id: \.self) { startIdx in
                    let rowVideos = Array(videos[startIdx..<min(startIdx + columnCount, videos.count)])
                    HStack(alignment: .top, spacing: videoGridRowSpacing) {
                        ForEach(rowVideos) { video in
                            Button { onSelect(video) } label: {
                                VideoCardView(video: video, compact: false)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("video.card.\(video.id)")
                        }
                        let remainder = columnCount - rowVideos.count
                        if remainder > 0 {
                            ForEach(0..<remainder, id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .onAppear {
                        if rowVideos.last?.id == videos.last?.id { loadMore?() }
                    }
                }
            }
            .padding(.horizontal, 0)
            .padding(.vertical, 8)
            #else
            LazyVGrid(columns: videoGridColumns, spacing: videoGridRowSpacing) {
                ForEach(videos) { video in
                    VideoCardView(video: video, compact: false)
                        .accessibilityIdentifier("video.card.\(video.id)")
                        .onTapGesture { onSelect(video) }
                        .onAppear {
                            if video.id == videos.last?.id { loadMore?() }
                        }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            #endif
        }
    }
}

// MARK: - VideoRowSection

/// Horizontal scrolling shelf row — used for home feed shelves (layout == .row).
struct VideoRowSection: View {
    let videos: [Video]
    let onSelect: (Video) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: videoGridRowSpacing) {
                ForEach(videos) { video in
                    #if os(tvOS)
                    Button { onSelect(video) } label: {
                        VideoCardView(video: video, compact: false)
                            .frame(width: 360)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("video.card.\(video.id)")
                    #else
                    VideoCardView(video: video, compact: false)
                        .frame(width: 220)
                        .accessibilityIdentifier("video.card.\(video.id)")
                        .onTapGesture { onSelect(video) }
                    #endif
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }
}
