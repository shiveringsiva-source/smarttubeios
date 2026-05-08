import SwiftUI
import FirebaseCore
import SmartTubeIOS
import SmartTubeIOSCore

/// Unified entry point for iOS, iPadOS and macOS.
@main
struct AppEntry: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    // Declared without default values so that init() can call FirebaseApp.configure()
    // before any of these objects are instantiated. @State default values are evaluated
    // before init() runs, which would trigger Firebase before it is configured.
    @State private var api: InnerTubeAPI
    @State private var authService: AuthService
    @State private var browseViewModel: BrowseViewModel
    @State private var settingsStore: SettingsStore
    #if os(iOS)
    @State private var playerStateStore: PlayerStateStore
    #endif
    @State private var deepLinkLaunchArgConsumed = false
    @State private var pendingVideoArgConsumed = false
    @Environment(\.scenePhase) private var scenePhase

    private static let appGroup   = "group.com.void.smarttube"
    private static let pendingKey = "pendingVideoID"

    init() {
        FirebaseApp.configure()
        let api = InnerTubeAPI()
        _api             = State(initialValue: api)
        _authService     = State(initialValue: AuthService())
        _browseViewModel = State(initialValue: BrowseViewModel(api: api))
        _settingsStore   = State(initialValue: SettingsStore())
        #if os(iOS)
        _playerStateStore = State(initialValue: PlayerStateStore(api: api))
        #endif
    }

    /// When launched with `--uitesting-shorts` the app skips the full navigation
    /// stack and presents ShortsPlayerView directly with three stub videos so
    /// XCUITest can exercise swipe-up / swipe-down navigation without a network
    /// call or sign-in state.
    private var isShortsUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting-shorts")
    }

    /// When launched with `--uitesting-enable-shorts`, ensure the Shorts section
    /// is present in `enabledSections` so Shorts chip tests can run without
    /// requiring the user to manually toggle it in Settings.
    private func enableShortsIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--uitesting-enable-shorts") else { return }
        if !settingsStore.settings.enabledSections.contains(.shorts) {
            let ordered = BrowseSection.allSections
                .filter { settingsStore.settings.enabledSections.contains($0.type) || $0.type == .shorts }
                .map(\.type)
            settingsStore.settings.enabledSections = ordered
        }
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            RootView()
                .environment(authService)
                .environment(browseViewModel)
                .environment(settingsStore)
                .environment(\.innerTubeAPI, api)
                .onChange(of: authService.accessToken, initial: true) { _, newToken in
                    Task {
                        await api.setAuthToken(newToken)
                        await browseViewModel.updateAuthToken(newToken)
                    }
                }
                .onChange(of: settingsStore.settings.enabledSections) { _, newSections in
                    browseViewModel.configureSections(newSections)
                }
                .onChange(of: settingsStore.settings.historyState, initial: true) { _, newState in
                    browseViewModel.updateHistoryEnabled(newState == .enabled)
                }
                .onOpenURL { url in handleOpenURL(url) }
        }
        .defaultSize(width: 1280, height: 800)

        Settings {
            SettingsView()
                .environment(authService)
                .environment(browseViewModel)
                .environment(settingsStore)
                .frame(minWidth: 480)
        }
        #elseif os(tvOS)
        // tvOS: no Share Extension, no Settings scene, no App Group pending video.
        // The device-code + QR sign-in flow works natively on Apple TV.
        WindowGroup {
            RootView()
                .environment(authService)
                .environment(browseViewModel)
                .environment(settingsStore)
                .environment(\.innerTubeAPI, api)
                .onChange(of: authService.accessToken, initial: true) { _, newToken in
                    Task {
                        await api.setAuthToken(newToken)
                        await browseViewModel.updateAuthToken(newToken)
                    }
                }
                .onChange(of: settingsStore.settings.enabledSections) { _, newSections in
                    browseViewModel.configureSections(newSections)
                }
                .onChange(of: settingsStore.settings.historyState, initial: true) { _, newState in
                    browseViewModel.updateHistoryEnabled(newState == .enabled)
                }
        }
        #else
        WindowGroup {
            if isShortsUITesting {
                ShortsPlayerView(videos: AppEntry.shortsForUITesting(), startIndex: 0, api: InnerTubeAPI())
                    .environment(authService)
                    .environment(settingsStore)
            } else {
                RootView()
                    .environment(authService)
                    .environment(browseViewModel)
                    .environment(settingsStore)
                    .environment(\.innerTubeAPI, api)
                    #if os(iOS)
                    .environment(playerStateStore)
                    #endif
                    .onChange(of: authService.accessToken, initial: true) { _, newToken in
                        #if os(iOS)
                        playerStateStore.vm.updateAuthToken(newToken)
                        #endif
                        Task {
                            await api.setAuthToken(newToken)
                            await browseViewModel.updateAuthToken(newToken)
                        }
                    }
                    .onChange(of: settingsStore.settings.enabledSections) { _, newSections in
                        browseViewModel.configureSections(newSections)
                    }
                    .onChange(of: settingsStore.settings.historyState, initial: true) { _, newState in
                        browseViewModel.updateHistoryEnabled(newState == .enabled)
                    }
                    .onOpenURL { url in handleOpenURL(url) }
                    .onChange(of: scenePhase, initial: true) { _, phase in
                        if phase == .active {
                            consumePendingVideoID()
                            consumePendingVideoFromLaunchArgs()
                            consumeDeepLinkFromLaunchArgs()
                            authService.handleForeground()
                            browseViewModel.refreshIfStale()
                            #if os(iOS)
                            if playerStateStore.presentation == .miniPlayer {
                                playerStateStore.vm.handleForeground()
                            }
                            #endif
                        } else if phase == .background {
                            #if os(iOS)
                            if playerStateStore.presentation == .miniPlayer {
                                playerStateStore.vm.handleBackground()
                            }
                            #endif
                        }
                    }
                    .onAppear { enableShortsIfNeeded() }
            }
        }
        #endif
    }

    // MARK: - URL handling

    @MainActor
    private func handleOpenURL(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""

        // smarttube://video/VIDEO_ID — fired by the Share Extension
        guard scheme == "smarttube", url.host?.lowercased() == "video" else { return }
        let components = url.pathComponents.filter { $0 != "/" }
        guard let videoID = components.first, !videoID.isEmpty else { return }
        browseViewModel.deepLinkedVideo = Video(id: videoID, title: "", channelTitle: "")

        // Clear the App Group pending key so consumePendingVideoID() does not replay
        // this video on the next cold start. When the app is already active, scenePhase
        // never transitions to .active, so the onChange handler never fires —
        // handleOpenURL is the only thing that runs, and it must clean up the key itself.
        if let defaults = UserDefaults(suiteName: Self.appGroup) {
            defaults.removeObject(forKey: Self.pendingKey)
            defaults.synchronize()
        }
    }

    // MARK: - App Group pending video (from Share Extension)

    @MainActor
    private func consumePendingVideoID() {
        guard let defaults = UserDefaults(suiteName: Self.appGroup),
              let videoID = defaults.string(forKey: Self.pendingKey),
              !videoID.isEmpty
        else { return }

        defaults.removeObject(forKey: Self.pendingKey)
        defaults.synchronize()
        browseViewModel.deepLinkedVideo = Video(id: videoID, title: "", channelTitle: "")
    }

    /// Handles `--uitesting-deeplink-video=<id>` launch argument.
    ///
    /// Simulates `OpenYouTubeVideoIntent.perform()` firing `smarttube://video/<id>`
    /// by re-opening the URL through `UIApplication.shared.open(_:)`. This goes through
    /// the registered `onOpenURL` handler, which fires after the view hierarchy is
    /// fully set up — avoiding the timing issue of setting `deepLinkedVideo` directly
    /// during the initial scene-phase `.active` callback.
    @MainActor
    private func consumeDeepLinkFromLaunchArgs() {
        guard !deepLinkLaunchArgConsumed else { return }
        let args = ProcessInfo.processInfo.arguments
        guard let arg = args.first(where: { $0.hasPrefix("--uitesting-deeplink-video=") }) else { return }
        let videoID = String(arg.dropFirst("--uitesting-deeplink-video=".count))
        guard !videoID.isEmpty, let deepLink = URL(string: "smarttube://video/\(videoID)") else { return }
        deepLinkLaunchArgConsumed = true
        #if os(iOS)
        Task { @MainActor in
            await UIApplication.shared.open(deepLink)
        }
        #endif
    }

    /// Handles `--uitesting-pending-video=<id>` launch argument.
    ///
    /// Simulates the App Group path: `consumePendingVideoID()` reads `pendingVideoID`
    /// from `UserDefaults(suiteName: appGroup)` after the Share Extension writes it.
    /// In XCUITest the test process cannot write to a shared app group container, so
    /// this launch argument exercises the same `browseViewModel.deepLinkedVideo` code
    /// path without touching UserDefaults at all. Fires only once per launch.
    @MainActor
    private func consumePendingVideoFromLaunchArgs() {
        guard !pendingVideoArgConsumed else { return }
        let args = ProcessInfo.processInfo.arguments
        guard let arg = args.first(where: { $0.hasPrefix("--uitesting-pending-video=") }) else { return }
        let videoID = String(arg.dropFirst("--uitesting-pending-video=".count))
        guard !videoID.isEmpty else { return }
        pendingVideoArgConsumed = true
        browseViewModel.deepLinkedVideo = Video(id: videoID, title: "", channelTitle: "")
    }

    // MARK: - Stub data for UI testing

    /// Resolves the `[Video]` list used when launched with `--uitesting-shorts`.
    ///
    /// If the launch argument `--uitesting-shorts-ids=ID1,ID2,ID3` is present the
    /// returned videos use those real YouTube Short video IDs, allowing tests that
    /// verify actual playback (e.g. no error banner) to load real streams without
    /// navigating through the full app.
    ///
    /// If no custom IDs are provided the default `stubShorts` (fake IDs) are used,
    /// which is fine for tests that only exercise player UI (index label, swipes,
    /// controls overlay) and don't care about real video loading.
    static func shortsForUITesting() -> [Video] {
        let args = ProcessInfo.processInfo.arguments
        guard let idsArg = args.first(where: { $0.hasPrefix("--uitesting-shorts-ids=") }) else {
            return stubShorts
        }
        let raw = String(idsArg.dropFirst("--uitesting-shorts-ids=".count))
        let ids = raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return stubShorts }
        return ids.enumerated().map { idx, id in
            Video(id: id, title: "Short \(idx + 1)", channelTitle: "Test Channel", isShort: true)
        }
    }

    static let stubShorts: [Video] = [
        Video(id: "short-1", title: "Short One",   channelTitle: "Channel A", isShort: true),
        Video(id: "short-2", title: "Short Two",   channelTitle: "Channel B", isShort: true),
        Video(id: "short-3", title: "Short Three", channelTitle: "Channel C", isShort: true),
    ]
}
