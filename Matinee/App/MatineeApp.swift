import SwiftUI
import AVFoundation

@main
struct MatineeApp: App {
    @State private var model = AppModel()

    init() {
        Pref.register()
        NetworkStatus.shared.start()
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 400 * 1024 * 1024)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onAppear { PlayerPresenter.shared.model = model }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.choosingProfile {
                ProfilePickerView()
                    .transition(.opacity)
            } else if model.isSignedIn {
                MainTabs()
                    .id(model.activeProfileId)
                    .task { await model.refresh() }
            } else {
                SignInView()
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if model.activeProfile != nil { ProfileSignInHeader() }
                    }
            }
        }
        .animation(.default, value: model.isSignedIn)
        .animation(.default, value: model.choosingProfile)
        .onChange(of: scenePhase) { _, phase in
            // Pick up changes made in Stremio on other devices when coming back to the app.
            if phase == .active && model.isSignedIn {
                Task { await model.refreshIfStale() }
            }
        }
    }
}

/// Five tabs under a floating capsule tab bar. Each tab keeps its own navigation history,
/// and a tab is only built the first time it's opened.
struct MainTabs: View {
    @State private var selection: MainTab = .board
    @State private var opened: Set<MainTab> = [.board]
    @State private var paths: [MainTab: NavigationPath] = [:]
    @State private var scrollToTop: [MainTab: Int] = [:]

    var body: some View {
        ZStack {
            ForEach(MainTab.allCases) { tab in
                if opened.contains(tab) {
                    NavigationStack(path: path(for: tab)) {
                        root(tab).withMatineeDestinations()
                    }
                    .environment(\.scrollToTopRequest, scrollToTop[tab] ?? 0)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear.frame(height: Theme.tabBarClearance)
                    }
                    .opacity(selection == tab ? 1 : 0)
                    .allowsHitTesting(selection == tab)
                    .accessibilityHidden(selection != tab)
                }
            }
        }
        .overlay(alignment: .bottom) {
            FloatingTabBar(selection: $selection) { tab in
                // First tap on the current tab goes back to its first screen; on that screen it scrolls to the top.
                if let path = paths[tab], !path.isEmpty {
                    paths[tab] = NavigationPath()
                } else {
                    scrollToTop[tab, default: 0] += 1
                }
            }
            .padding(.bottom, 2)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background(Theme.background.ignoresSafeArea())
        .onChange(of: selection) { _, tab in opened.insert(tab) }
    }

    private func path(for tab: MainTab) -> Binding<NavigationPath> {
        Binding(get: { paths[tab] ?? NavigationPath() }, set: { paths[tab] = $0 })
    }

    @ViewBuilder
    private func root(_ tab: MainTab) -> some View {
        switch tab {
        case .board: HomeView()
        case .discover: DiscoverView()
        case .library: LibraryView()
        case .addons: AddonsView()
        case .settings: SettingsView()
        }
    }
}
