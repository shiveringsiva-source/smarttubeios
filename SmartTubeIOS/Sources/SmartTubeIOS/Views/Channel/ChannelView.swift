import SwiftUI
import SmartTubeIOSCore

// MARK: - ChannelView
//
// Displays channel info, subscriber count and a grid of recent uploads.
// Mirrors the Android `ChannelFragment`.

// MARK: - ChannelFilter

private enum ChannelFilter: String, CaseIterable {
    case all    = "All"
    case shorts = "Shorts"
}

public struct ChannelView: View {
    public let channelId: String
    @State private var vm = ChannelViewModel()
    @State private var selectedVideo: Video?
    @State private var shortsPresentation: ShortsPresentation?
    @State private var channelDestination: ChannelDestination?
    @State private var filter: ChannelFilter = .all
    @Environment(SettingsStore.self) private var store

    public init(channelId: String) {
        self.channelId = channelId
    }

    public var body: some View {
        Group {
            if vm.isLoading && vm.channel == nil {
                ProgressView("Loading channel…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .navigationTitle(vm.channel?.title ?? "Channel")
        .onAppear { vm.load(channelId: channelId) }
        #if !os(macOS)
        .fullScreenCover(item: $selectedVideo) { video in
            PlayerView(video: video)
        }
        #endif
        .navigationDestination(item: $channelDestination) { dest in
            ChannelView(channelId: dest.channelId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChannel)) { note in
            guard let channelId = note.userInfo?["channelId"] as? String, !channelId.isEmpty else { return }
            channelDestination = ChannelDestination(channelId: channelId)
        }
        #if !os(macOS)
        .fullScreenCover(item: $shortsPresentation) { target in
            ShortsPlayerView(videos: target.videos, startIndex: target.startIndex)
        }
        #endif
        .alert("Error", isPresented: .constant(vm.error != nil), presenting: vm.error) { _ in
            Button("Retry") { vm.load(channelId: channelId) }
            Button("Dismiss", role: .cancel) {}
        } message: { err in
            Text(err.localizedDescription)
        }
        .toolbar {
            if let channel = vm.channel {
                #if os(macOS)
                ToolbarItem(placement: .automatic) {
                    let isExcluded = store.settings.sponsorBlockExcludedChannels[channel.id] != nil
                    Button {
                        toggleSponsorBlockExclusion(for: channel)
                    } label: {
                        Label(
                            isExcluded ? "Remove SponsorBlock Exclusion" : "Exclude from SponsorBlock",
                            systemImage: isExcluded ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.minus"
                        )
                    }
                }
                #else
                ToolbarItem(placement: .topBarTrailing) {
                    let isExcluded = store.settings.sponsorBlockExcludedChannels[channel.id] != nil
                    Button {
                        toggleSponsorBlockExclusion(for: channel)
                    } label: {
                        Label(
                            isExcluded ? "Remove SponsorBlock Exclusion" : "Exclude from SponsorBlock",
                            systemImage: isExcluded ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.minus"
                        )
                    }
                }
                #endif
            }
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Channel header
                if let channel = vm.channel {
                    channelHeader(channel)
                }

                // All / Shorts filter
                Picker("Filter", selection: $filter) {
                    ForEach(ChannelFilter.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)

                let filtered = filteredVideos
                if filter == .shorts {
                    shortsGrid(filtered)
                } else {
                    videosGrid(filtered)
                }

                if vm.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
        }
        .refreshable { vm.load(channelId: channelId) }
    }

    // MARK: - Filtered data

    private var filteredVideos: [Video] {
        switch filter {
        case .all:    return vm.videos
        case .shorts: return vm.videos.filter { $0.isShort }
        }
    }

    // MARK: - Grid layouts

    private func videosGrid(_ videos: [Video]) -> some View {
        let compact = store.settings.compactThumbnails
        return Group {
            if compact {
                LazyVStack(spacing: 0) {
                    ForEach(videos) { video in
                        VideoCardView(video: video, compact: true)
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                            .onTapGesture { selectedVideo = video }
                            .onAppear {
                                if video.id == vm.videos.last?.id { vm.loadMore() }
                            }
                        Divider().padding(.horizontal)
                    }
                }
            } else {
                LazyVGrid(columns: videoGridColumns, spacing: 12) {
                    ForEach(videos) { video in
                        VideoCardView(video: video, compact: false)
                            .onTapGesture { selectedVideo = video }
                            .onAppear {
                                if video.id == vm.videos.last?.id { vm.loadMore() }
                            }
                    }
                }
                .padding()
            }
        }
    }

    private func shortsGrid(_ videos: [Video]) -> some View {
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(videos) { video in
                VideoCardView(video: video)
                    .aspectRatio(9/16, contentMode: .fit)
                    .onTapGesture { selectShort(video, from: videos) }
                    .onAppear {
                        if video.id == vm.videos.last?.id { vm.loadMore() }
                    }
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Selection

    private func selectShort(_ video: Video, from videos: [Video]) {
        let idx = videos.firstIndex(where: { $0.id == video.id }) ?? 0
        shortsPresentation = ShortsPresentation(videos: videos, startIndex: idx)
    }

    private func toggleSponsorBlockExclusion(for channel: Channel) {
        if store.settings.sponsorBlockExcludedChannels[channel.id] != nil {
            store.settings.sponsorBlockExcludedChannels.removeValue(forKey: channel.id)
        } else {
            store.settings.sponsorBlockExcludedChannels[channel.id] = channel.title
        }
    }

    private func channelHeader(_ channel: Channel) -> some View {
        HStack(spacing: 16) {
            AsyncImage(url: channel.thumbnailURL) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(Color.secondary.opacity(0.3))
            }
            .frame(width: 72, height: 72)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(channel.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                if let subs = channel.subscriberCount {
                    Text(subs)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let desc = channel.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding()
        .background(.background)
    }
}


