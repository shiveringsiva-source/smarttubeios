import SwiftUI
import SmartTubeIOSCore
import os

private let focusLog = Logger(subsystem: "com.smarttube", category: "focus")

// MARK: - Notification names

extension Notification.Name {
    /// Posted when the user selects "Open Channel" from a video's context menu.
    /// userInfo keys: "channelId", "channelTitle"
    static let openChannel = Notification.Name("com.smarttube.openChannel")
    /// Posted when a feature requests navigation to the Search tab (e.g. empty-state CTA).
    static let navigateToSearch = Notification.Name("com.smarttube.navigateToSearch")
    // hideVideoFromFeed and hideChannelFromFeed are defined in SmartTubeIOSCore/FeedFeedbackNotifications.swift
}

// MARK: - VideoCardView
//
// A card showing a video thumbnail, title, channel and metadata.
// Adapts its layout for list (compact) and grid (default) modes.

public struct VideoCardView: View {
    public let video: Video
    public var compact: Bool = false
    /// Called when the user taps/selects the card on tvOS (via `.onTapGesture`).
    /// iOS call sites continue using their own tap handlers; this is only invoked
    /// from the `#else` (tvOS) modifier block below.
    public var onSelect: (() -> Void)? = nil

    @Environment(AuthService.self) private var authService
    @Environment(SettingsStore.self) private var store
    @Environment(\.innerTubeAPI) private var api
    @State private var localProgress: Double?
    @State private var watchLaterAlert: DownloadAlertItem?
    /// Index into `video.thumbnailFallbackURLs`. -1 = use primary `thumbnailURL`.
    @State private var thumbnailFallbackIndex: Int = -1
    #if !os(tvOS)
    @Environment(VideoDownloadService.self) private var downloadService
    #endif
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    private var effectiveProgress: Double? {
        localProgress ?? video.watchProgress
    }

    public init(video: Video, compact: Bool = false, onSelect: (() -> Void)? = nil) {
        self.video = video
        self.compact = compact
        self.onSelect = onSelect
    }

    // MARK: - Shared card content (tasks + context menu)
    // Extracted so the tvOS body can wrap it in a Button (which handles the
    // Select button press natively) while iOS continues using the bare view.

    private var cardContent: some View {
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
                authToken: authService.accessToken,
                priority: .visible
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
            if authService.isSignedIn {
                Button {
                    Task {
                        do {
                            try await api.addToWatchLater(videoId: video.id)
                            watchLaterAlert = DownloadAlertItem(
                                title: String(localized: "Saved to Watch Later", bundle: .module),
                                message: String(localized: "\"\(video.title)\" was added to your Watch Later playlist.", bundle: .module)
                            )
                        } catch {
                            watchLaterAlert = DownloadAlertItem(
                                title: String(localized: "Could Not Save", bundle: .module),
                                message: error.localizedDescription
                            )
                        }
                    }
                } label: {
                    Label("Save to Watch Later", systemImage: AppSymbol.watchLater)
                }
            }
            Button {
                Task { await CurrentQueueStore.shared.append(video) }
            } label: {
                Label("Add to Queue", systemImage: "text.badge.plus")
            }
            Button {
                Task {
                    let count = await CurrentQueueStore.shared.videos.count
                    await CurrentQueueStore.shared.insertNext(video, afterIndex: count - 1)
                }
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            if authService.isSignedIn {
                if let token = video.notInterestedToken {
                    Button(role: .destructive) {
                        Task {
                            try? await api.sendFeedback(token: token)
                            NotificationCenter.default.post(
                                name: .hideVideoFromFeed,
                                object: nil,
                                userInfo: ["videoId": video.id]
                            )
                        }
                    } label: {
                        Label("Not Interested", systemImage: "hand.raised")
                    }
                }
                if let token = video.dontLikeToken {
                    Button(role: .destructive) {
                        Task {
                            try? await api.sendFeedback(token: token)
                            NotificationCenter.default.post(
                                name: .hideVideoFromFeed,
                                object: nil,
                                userInfo: ["videoId": video.id]
                            )
                        }
                    } label: {
                        Label("Don't Like This Video", systemImage: "hand.thumbsdown")
                    }
                }
                if let token = video.hideChannelToken, let channelId = video.channelId, !channelId.isEmpty {
                    Button(role: .destructive) {
                        Task {
                            try? await api.sendFeedback(token: token)
                            NotificationCenter.default.post(
                                name: .hideChannelFromFeed,
                                object: nil,
                                userInfo: ["channelId": channelId]
                            )
                        }
                    } label: {
                        Label("Don't Recommend Channel", systemImage: "person.slash")
                    }
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
        // Download state is observed at app-root level (RootView) so the alert
        // survives context menu dismiss animations that would otherwise reset
        // the card-level @State. Only the button label/disabled state is read here.
        .padding(0)  // zero-effect modifier to keep the view chain well-typed
        #endif
    }

    // MARK: - Body

    public var body: some View {
        #if os(tvOS)
        // Modifier order is critical on tvOS:
        //
        //   cardContent  (contains .contextMenu — handles long press)
        //       .focusable()          — registers view with focus engine (D-pad navigation)
        //       .onTapGesture { }     — fires on Select press (outermost → receives event first)
        //       .focused($isFocused)  — tracks focus state (does not consume events)
        //
        // Why this order works:
        // • .onTapGesture outermost → Select button press fires the action.
        //   (.focusable() outermost broke Select because the focus engine intercepted
        //    the primary-action event before the inner tap gesture could see it.)
        // • .contextMenu innermost, co-located in the same modifier chain as
        //   .onTapGesture → SwiftUI's gesture arbiter can cancel the pending tap
        //   recogniser when it detects a long press, so long press shows the menu
        //   without also playing the video.
        // • .focusable() between contextMenu and onTapGesture keeps the view in the
        //   focus engine so D-pad UP/DOWN can reach it.
        cardContent
            .focusable()
            .onTapGesture { onSelect?() }
            .focused($isFocused)
            .onChange(of: isFocused) { _, newValue in
                focusLog.info("[VideoCard] isFocused=\(newValue) id=\(self.video.id)")
            }
            .shadow(color: isFocused ? .white.opacity(0.9) : .clear, radius: 18, x: 0, y: 0)
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .zIndex(isFocused ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            .alert(item: $watchLaterAlert) { item in
                Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("OK")))
            }
        #else
        cardContent
            .alert(item: $watchLaterAlert) { item in
                Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("OK")))
            }
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
                Text(displayTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2, reservesSpace: true)
                    .accessibilityIdentifier("video.card.title")
                Text(video.channelTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .onTapGesture {
                        guard let channelId = video.channelId, !channelId.isEmpty else { return }
                        NotificationCenter.default.post(
                            name: .openChannel,
                            object: nil,
                            userInfo: ["channelId": channelId, "channelTitle": video.channelTitle]
                        )
                    }
                    .accessibilityIdentifier("video.card.channelName")
                HStack(spacing: 4) {
                    let vc = video.formattedViewCount
                    if !vc.isEmpty { Text(vc) }
                }
                .font(.caption2)
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
                Text(displayTitle)
                    .font(.subheadline)
                    .lineLimit(2)
                    .accessibilityIdentifier("video.card.title")
                Text(video.channelTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .onTapGesture {
                        guard let channelId = video.channelId, !channelId.isEmpty else { return }
                        NotificationCenter.default.post(
                            name: .openChannel,
                            object: nil,
                            userInfo: ["channelId": channelId, "channelTitle": video.channelTitle]
                        )
                    }
                    .accessibilityIdentifier("video.card.channelName")
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

    /// Returns the DeArrow thumbnail URL if the feature is enabled and a timestamp is available.
    private var deArrowThumbnailURL: URL? {
        guard store.settings.deArrowEnabled,
              let ts = video.deArrowThumbnailTimestamp else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(video.id)/\(Int(ts)).jpg")
    }

    /// The title to show — community de-arrow title when enabled, raw title otherwise.
    private var displayTitle: String {
        if store.settings.deArrowEnabled, let t = video.deArrowTitle { return t }
        return video.title
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if video.thumbnailURL == nil, video.id == "WL" || video.id == "LL" {
            systemPlaylistThumbnail
        } else {
            // Walk a fallback chain on each successive failure:
            //   -1 → deArrowThumbnailURL (community thumbnail) or thumbnailURL (API-provided)
            //    0 → sddefault.jpg  (640×480, available for most videos)
            //    1 → hqdefault.jpg  (480×360, always available)
            //    2 → mqdefault.jpg  (320×180, always available — last resort)
            let fallbacks = video.thumbnailFallbackURLs
            let url: URL? = thumbnailFallbackIndex < 0
                ? (deArrowThumbnailURL ?? video.thumbnailURL ?? fallbacks.first)
                : (thumbnailFallbackIndex < fallbacks.count ? fallbacks[thumbnailFallbackIndex] : nil)
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                case .failure:
                    let nextIndex = thumbnailFallbackIndex + 1
                    if nextIndex < fallbacks.count {
                        placeholderThumbnail
                            .onAppear { thumbnailFallbackIndex = nextIndex }
                    } else {
                        placeholderThumbnail
                    }
                default:
                    placeholderThumbnail.overlay(ProgressView())
                }
            }
            .task(id: video.id) {
                // Reset so a reused card slot always tries the primary URL for the new video.
                thumbnailFallbackIndex = -1
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
