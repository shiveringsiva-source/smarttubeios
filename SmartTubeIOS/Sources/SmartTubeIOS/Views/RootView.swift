import SwiftUI
import SmartTubeIOSCore
import OSLog

private let rootLog = Logger(subsystem: "com.void.smarttube.app", category: "RootView")

// MARK: - RootView
//
// Entry point that decides whether to show the main tab UI or the
// sign-in screen.  On macOS it uses a sidebar-based navigation.

public struct RootView: View {
    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var store
    @Environment(BrowseViewModel.self) private var browseVM
    @Environment(\.innerTubeAPI) private var api

    public init() {}

    public var body: some View {
        @Bindable var browseVM = browseVM
        Group {
            #if os(tvOS)
            MainTVTabView()
            #elseif os(macOS)
            MainSidebarView()
            #else
            MainTabView()
            #endif
        }
        .preferredColorScheme(store.settings.themeName.colorScheme)
        .sheet(isPresented: .constant(!auth.isSignedIn && requiresAuth)) {
            // Sign-in prompt is shown as a dismissible sheet so users
            // can still browse without being signed in.
            SignInView()
        }
        #if os(iOS)
        // Deep link is handled by MainTabView.onChange(of: browseVM.deepLinkedVideo)
        // which calls playerState.play(video:). No landscapePlayerCover needed here.
        #elseif !os(macOS)
        .fullScreenCover(item: $browseVM.deepLinkedVideo) { video in
            PlayerView(video: video, api: api)
                .environment(store)
                .environment(auth)
        }
        #endif
    }

    private var requiresAuth: Bool { false }   // guest browsing is allowed
}

// MARK: - AppSection

enum AppSection: String, CaseIterable, Identifiable {
    case home      = "Home"
    case search    = "Search"
    case library   = "Library"
    case settings  = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home:     return AppSymbol.home
        case .search:   return AppSymbol.search
        case .library:  return AppSymbol.library
        case .settings: return AppSymbol.settings
        }
    }

    @MainActor @ViewBuilder
    func destination(api: InnerTubeAPI) -> some View {
        switch self {
        case .home:     HomeView(api: api)
        case .search:   SearchView()
        case .library:  LibraryView()
        case .settings: SettingsView()
        }
    }
}

// MARK: - MainTabView  (iOS / iPadOS)

struct MainTabView: View {
    @State private var searchVM = SearchViewModel()
    @State private var selectedTab: AppSection = .home
    @Environment(\.innerTubeAPI) private var api
    #if os(iOS)
    @Environment(PlayerStateStore.self) private var playerState
    @Environment(BrowseViewModel.self) private var browseVM
    #endif

    var body: some View {
        #if os(iOS)
        // Read these in body so SwiftUI's @Observable tracker registers the dependency.
        // If only accessed inside the Binding.get closure, changes won't trigger a body re-render
        // and updateUIViewController won't be called, so the cover never dismisses.
        let fullScreenVideo: Video? = playerState.presentation == .fullScreen ? playerState.currentVideo : nil
        let _ = rootLog.notice("[MainTabView] body re-render — presentation=\(String(describing: playerState.presentation)) fullScreenVideo=\(fullScreenVideo?.id ?? "nil")")
        let fullScreenBinding = Binding<Video?>(
            get: { fullScreenVideo },
            set: { if $0 == nil { playerState.minimize() } }
        )
        #endif
        TabView(selection: $selectedTab) {
            ForEach(AppSection.allCases) { section in
                NavigationStack { section.destination(api: api) }
                    .tabItem { Label(section.rawValue, systemImage: section.icon) }
                    .tag(section)
                    .accessibilityIdentifier("tab.\(section.rawValue.lowercased())")
            }
        }
        .environment(searchVM)
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSearch)) { _ in
            selectedTab = .search
        }
        #if os(iOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if playerState.presentation == .miniPlayer {
                MiniPlayerView()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.2), value: playerState.presentation)
            }
        }
        .landscapePlayerCover(item: fullScreenBinding) { video in
            PlayerView(video: video, api: api)
        }
        .onChange(of: browseVM.deepLinkedVideo) { _, video in
            guard let video else { return }
            playerState.play(video: video)
            browseVM.deepLinkedVideo = nil
        }
        #endif
    }
}

// MARK: - MainTVTabView  (tvOS)
// Top-bar TabView is the Apple-recommended navigation pattern for Apple TV.
// Each tab contains a NavigationStack so drill-down is available within each section.

#if os(tvOS)
struct MainTVTabView: View {
    @State private var searchVM = SearchViewModel()
    @Environment(\.innerTubeAPI) private var api

    var body: some View {
        TabView {
            ForEach(AppSection.allCases) { section in
                NavigationStack { section.destination(api: api) }
                    .tabItem {
                        Label(section.rawValue, systemImage: section.icon)
                    }
            }
        }
        .environment(searchVM)
    }
}
#endif

// MARK: - MainSidebarView  (macOS)

struct MainSidebarView: View {
    @Environment(AuthService.self) private var auth
    @Environment(\.innerTubeAPI) private var api
    @State private var searchVM = SearchViewModel()

    @State private var selectedSection: AppSection? = .home

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .navigationTitle("SmartTube")
            if auth.isSignedIn {
                Divider()
                HStack {
                    AsyncImage(url: auth.accountAvatarURL) { img in img.resizable() } placeholder: { Color.gray }
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                    Text(auth.accountName ?? "Account")
                        .font(.subheadline)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        } detail: {
            NavigationStack { (selectedSection ?? .home).destination(api: api) }
        }
        .environment(searchVM)
    }
}
