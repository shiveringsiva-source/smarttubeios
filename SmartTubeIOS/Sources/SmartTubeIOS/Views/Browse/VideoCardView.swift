import SwiftUI
import SmartTubeIOSCore

// MARK: - Notification names

extension Notification.Name {
    /// Posted when the user selects "Open Channel" from a video's context menu.
    /// userInfo keys: "channelId", "channelTitle"
    static let openChannel = Notification.Name("com.smarttube.openChannel")
}

// MARK: - VideoCardView
//
// A card showing a video thumbnail, title, channel and metadata.
// Adapts its layout for list (compact) and grid (default) modes.

public struct VideoCardView: View {
    public let video: Video
    public var compact: Bool = false

    @Environment(AuthService.self) private var authService
    @Environment(SettingsStore.self) private var store
    @State private var localProgress: Double?
    #if !os(tvOS)
    @State private var downloadService = VideoDownloadService()
    @State private var downloadAlertItem: DownloadAlertItem?
    #endif
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    private var effectiveProgress: Double? {
        localProgress ?? video.watchProgress
    }

    public init(video: Video, compact: Bool = false) {
        self.video = video
        self.compact = compact
    }

    public var body: some View {
        Group {
            if compact {
                compactLayout
            } else {
                gridLayout
            }
        }
        .task {
            localProgress = await VideoStateStore.shared.state(for: video.id)?.watchedFraction
        }
        .task(id: video.id) {
            // Pre-fetch all playback data for this video in the background while
            // the user is browsing. The cache skips the call if data is already fresh.
            // Pass the actual token (not just a Bool) so runPrefetch can sync it to
            // its internal API before the tracking URL fetch — eliminating the race
            // where prefetch fires before PlaybackViewModel.updateAuthToken propagates.
            await VideoPreloadCache.shared.prefetch(
                videoId: video.id,
                sponsorCategories: store.settings.activeSponsorCategories,
                authToken: authService.accessToken
            )
        }
        .contextMenu {
            #if !os(tvOS)
            if let shareURL = URL(string: "https://www.youtube.com/watch?v=\(video.id)") {
                ShareLink(item: shareURL) {
                    Label("Share", systemImage: AppSymbol.share)
                }
            }
            #endif
            if let channelId = video.channelId, !channelId.isEmpty {
                Button {
                    NotificationCenter.default.post(
                        name: .openChannel,
                        object: nil,
                        userInfo: ["channelId": channelId, "channelTitle": video.channelTitle]
                    )
                } label: {
                    Label("Open Channel", systemImage: AppSymbol.personRectangle)
                }
            }
            #if !os(tvOS)
            Button {
                downloadService.download(video: video)
            } label: {
                if downloadService.state.isActive {
                    Label("Downloading…", systemImage: AppSymbol.download)
                } else {
                    Label("Download to Gallery", systemImage: AppSymbol.download)
                }
            }
            .disabled(downloadService.state.isActive)
            #endif
        } preview: {
            Group {
                if compact {
                    compactLayout
                } else {
                    gridLayout
                }
            }
            .padding(12)
            .frame(width: 300)
            .background(.background)
        }
        #if !os(tvOS)
        .onChange(of: downloadService.state) { _, newState in
            switch newState {
            case .done:
                downloadAlertItem = DownloadAlertItem(title: "Saved to Gallery", message: "\"\(video.title)\" has been saved to your Photos library.")
                downloadService.reset()
            case .failed(let reason):
                downloadAlertItem = DownloadAlertItem(title: "Download Failed", message: reason)
                downloadService.reset()
            default:
                break
            }
        }
        .alert(item: $downloadAlertItem) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("OK")))
        }
        #else
        .focused($isFocused)
        .shadow(color: isFocused ? .white.opacity(0.9) : .clear, radius: 18, x: 0, y: 0)
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .zIndex(isFocused ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        #endif
    }

    // MARK: Grid layout (default)

    private var gridLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(thumbnailView.clipped())
                .overlay(alignment: .bottom) {
                    if let progress = effectiveProgress, progress > 0 {
                        watchProgressBar(progress)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    let dur = video.formattedDuration
                    if !dur.isEmpty { durationBadge(dur) }
                }
                .overlay(alignment: .bottomLeading) {
                    if let label = uploadDateLabel { durationBadge(label) }
                }
                .overlay(alignment: .topLeading) {
                    if video.isLive { liveBadge }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(video.title)
                    #if os(tvOS)
                    .font(.title3.weight(.medium))
                    #else
                    .font(.subheadline.weight(.medium))
                    #endif
                    .lineLimit(2, reservesSpace: true)
                Text(video.channelTitle)
                    #if os(tvOS)
                    .font(.subheadline)
                    #else
                    .font(.caption)
                    #endif
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    let vc = video.formattedViewCount
                    if !vc.isEmpty { Text(vc) }
                }
                #if os(tvOS)
                .font(.caption)
                #else
                .font(.caption2)
                #endif
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: Compact (list) layout

    private var compactLayout: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnailView
                .frame(width: 120, height: 68)
                .overlay(alignment: .bottom) {
                    if let progress = effectiveProgress, progress > 0 {
                        watchProgressBar(progress)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottomTrailing) {
                    let dur = video.formattedDuration
                    if !dur.isEmpty { durationBadge(dur) }
                }
                .overlay(alignment: .bottomLeading) {
                    if let label = uploadDateLabel { durationBadge(label) }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    #if os(tvOS)
                    .font(.title3)
                    #else
                    .font(.subheadline)
                    #endif
                    .lineLimit(2)
                Text(video.channelTitle)
                    #if os(tvOS)
                    .font(.subheadline)
                    #else
                    .font(.caption)
                    #endif
                    .foregroundStyle(.secondary)
                let vc = video.formattedViewCount
                if !vc.isEmpty {
                    Text(vc)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Shared

    @ViewBuilder
    private var thumbnailView: some View {
        if video.thumbnailURL == nil, video.id == "WL" || video.id == "LL" {
            systemPlaylistThumbnail
        } else {
            // Prefer the explicit thumbnailURL (set for playlist stubs and API-provided thumbs).
            // Fall back to highQualityThumbnailURL only when no explicit URL was provided.
            let url = video.thumbnailURL ?? video.highQualityThumbnailURL
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                case .failure:
                    placeholderThumbnail
                default:
                    placeholderThumbnail.overlay(ProgressView())
                }
            }
        }
    }

    private var systemPlaylistThumbnail: some View {
        let icon = video.id == "WL" ? "clock.fill" : "hand.thumbsup.fill"
        return ZStack {
            Rectangle().fill(Color.secondary.opacity(0.15))
            Image(systemName: icon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.secondary)
        }
    }

    private var placeholderThumbnail: some View {
        Rectangle().fill(Color.secondary.opacity(0.2))
    }

    private func watchProgressBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.black.opacity(0.3))
                Rectangle()
                    .fill(Color.red)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 3)
    }

    private func durationBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.black.opacity(0.75))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .padding(4)
    }

    private var uploadDateLabel: String? {
        guard let date = video.publishedAt, !video.isLive, !video.isUpcoming else { return nil }
        let now = Date()
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 86_400 { return "Today" }
        let days = Int(elapsed / 86_400)
        if days < 7 { return days == 1 ? "1 day ago" : "\(days) days ago" }
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
        return sameYear
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).year())
    }

    private var liveBadge: some View {
        Text("LIVE")
            .font(.caption2)
            .fontWeight(.bold)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.red)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .padding(4)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    VideoCardView(video: Video(
        id: "dQw4w9WgXcQ",
        title: "Rick Astley – Never Gonna Give You Up",
        channelTitle: "Rick Astley",
        duration: 213,
        viewCount: 1_400_000_000
    ))
    .frame(width: 320)
    .padding()
}
#endif
