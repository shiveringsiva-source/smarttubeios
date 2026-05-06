import SwiftUI
import SmartTubeIOSCore

// MARK: - LibraryView
//
// Shows subscriptions, playlists, watch history and liked videos for the
// signed-in account.  Mirrors the Android launcher activities for
// Subscriptions, Playlists, History and Channels.

public struct LibraryView: View {
    @Environment(AuthService.self) private var auth
    @Environment(BrowseViewModel.self) private var browseVM
    @Environment(\.innerTubeAPI) private var api
    @State private var selectedSection: LibrarySection = .subscriptions
    @State private var selectedVideo: Video?
    @State private var selectedPlaylist: Video?
    @State private var channelDestination: ChannelDestination?
    /// KVO-based real-time scroll tracker — writes to a reference type so
    /// every scroll tick does NOT trigger a SwiftUI re-render.
    @State private var scrollStore = ScrollOffsetStore()
    /// Snapshot of the offset taken the moment the player sheet opens.
    @State private var savedScrollOffset: CGFloat? = nil
    /// Non-nil while a restore is pending; cleared by `ScrollOffsetRestorer.onComplete`.
    @State private var restoreOffset: CGFloat? = nil
    #if os(tvOS)
    @FocusState private var focusedSection: LibrarySection?
    #endif

    enum LibrarySection: String, CaseIterable, Identifiable {
        case subscriptions = "Subscriptions"
        case history       = "History"
        case playlists     = "Playlists"

        var id: String { rawValue }
        var browseSectionType: BrowseSection.SectionType {
            switch self {
            case .subscriptions: return .subscriptions
            case .history:       return .history
            case .playlists:     return .playlists
            }
        }
    }

    public init() {}

    public var body: some View {
        Group {
            if auth.isSignedIn {
                authenticatedContent
            } else {
                signedOutPrompt
            }
        }
        #if os(iOS) || os(tvOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        #if os(iOS)
        .landscapePlayerCover(item: $selectedVideo) { video in
            PlayerView(video: video, api: api)
        }
        #endif
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
        .onReceive(NotificationCenter.default.publisher(for: .openChannel)) { note in
            guard let channelId = note.userInfo?["channelId"] as? String, !channelId.isEmpty else { return }
            channelDestination = ChannelDestination(channelId: channelId)
        }
    }

    private var authenticatedContent: some View {
        VStack(spacing: 0) {
            #if os(tvOS)
            HStack(spacing: 8) {
                ForEach(LibrarySection.allCases) { sec in
                    let isSelected = selectedSection == sec
                    Button {
                        guard selectedSection != sec else { return }
                        selectedSection = sec
                    } label: {
                        Text(sec.rawValue)
                            .font(.headline)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(
                                (isSelected || focusedSection == sec) ? Color.primary : Color.secondary.opacity(0.15),
                                in: Capsule()
                            )
                            .foregroundStyle(
                                (isSelected || focusedSection == sec) ? Color(white: 0) : Color.primary
                            )
                    }
                    .buttonStyle(.borderless)
                    .scaleEffect(focusedSection == sec ? 1.12 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: focusedSection)
                    .animation(.easeInOut(duration: 0.15), value: selectedSection)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    .accessibilityIdentifier("library.chip.\(sec.rawValue.lowercased())")
                    .focused($focusedSection, equals: sec)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .focusSection()
            .defaultFocus($focusedSection, selectedSection)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library.chipBar")
            #else
            Picker("Library Section", selection: $selectedSection) {
                ForEach(LibrarySection.allCases) { sec in
                    Text(sec.rawValue).tag(sec)
                        .accessibilityIdentifier("library.picker.\(sec.rawValue.lowercased())")
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("library.sectionPicker")
            .padding()
            #endif

            Group {
                let videos = browseVM.videoGroups.flatMap { $0.videos }
                if browseVM.isLoading && videos.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if videos.isEmpty {
                    emptyLibraryView
                } else {
                    ScrollView {
                        // KVO reader — always present; writes to ScrollOffsetStore
                        // without triggering SwiftUI re-renders on every scroll tick.
                        ScrollOffsetReader(store: scrollStore)
                            .frame(width: 0, height: 0)

                        if browseVM.isLoading && videos.isEmpty {
                            ProgressView().frame(maxWidth: .infinity).padding()
                        }
                        VideoGridSection(
                            videos: videos,
                            onSelect: { video in
                                if video.playlistId == video.id {
                                    selectedPlaylist = video
                                } else {
                                    selectedVideo = video
                                }
                            },
                            loadMore: {
                                if let last = videos.last {
                                    browseVM.loadMoreIfNeeded(lastVideo: last)
                                }
                            }
                        )
                        // Offset restorer — always present; no-op when restoreOffset is nil.
                        ScrollOffsetRestorer(targetOffset: restoreOffset) {
                            restoreOffset = nil
                        }
                        .frame(width: 0, height: 0)

                        if browseVM.isLoading && !videos.isEmpty {
                            ProgressView().frame(maxWidth: .infinity).padding()
                        }
                    }
                    .refreshable {
                        browseVM.loadContent(
                            for: BrowseSection(
                                id: selectedSection.id,
                                title: selectedSection.rawValue,
                                type: selectedSection.browseSectionType
                            ),
                            refresh: true
                        )
                    }
                }
            }
        }
        .onChange(of: selectedSection) { _, section in
            browseVM.select(section: BrowseSection(
                id: section.id,
                title: section.rawValue,
                type: section.browseSectionType
            ))
        }
        .onChange(of: selectedVideo) { old, new in
            if old == nil, new != nil {
                // Read live UIKit contentOffset on the main actor — always accurate
                // regardless of how many SwiftUI layout passes have occurred.
                savedScrollOffset = scrollStore.scrollView?.contentOffset.y ?? 0
            } else if old != nil, new == nil, let saved = savedScrollOffset {
                restoreOffset = saved
                savedScrollOffset = nil
            }
        }
        .onAppear {
            browseVM.select(section: BrowseSection(
                id: selectedSection.id,
                title: selectedSection.rawValue,
                type: selectedSection.browseSectionType
            ))
        }
    }

    private var emptyLibraryView: some View {
        VStack(spacing: 16) {
            Image(systemName: AppSymbol.stackLayers)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("Nothing here yet")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var signedOutPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: AppSymbol.personCircleQuestion)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("Sign in to see your library")
                .font(.headline)
                .foregroundStyle(.secondary)
            NavigationLink("Sign In") {
                SignInView()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
