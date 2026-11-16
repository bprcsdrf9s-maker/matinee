import SwiftUI
import AVFoundation

@main
struct MatineeTVApp: App {
    @State private var model = AppModel()

    init() {
        Pref.register()
        URLCache.shared = URLCache(memoryCapacity: 96 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onAppear { PlayerPresenter.shared.model = model }
        }
    }
}

struct TVRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.isSignedIn {
                TVTabs()
                    .task { await model.refresh() }
            } else {
                TVSignInView()
            }
        }
        .animation(.default, value: model.isSignedIn)
        .onChange(of: scenePhase) { _, phase in
            // Pick up changes made in Stremio on other devices when coming back to the app.
            if phase == .active && model.isSignedIn {
                Task { await model.refreshIfStale() }
            }
        }
    }
}

enum TVTab: Hashable {
    case home, discover, library, search, settings
}

/// The tab bar along the top of the screen, like the Apple TV app.
struct TVTabs: View {
    @State private var selection: TVTab = .home

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: TVTab.home) {
                NavigationStack { TVHomeView().tvDestinations() }
            }
            Tab("Discover", systemImage: "safari", value: TVTab.discover) {
                NavigationStack { TVDiscoverView().tvDestinations() }
            }
            Tab("Library", systemImage: "square.stack", value: TVTab.library) {
                NavigationStack { TVLibraryView().tvDestinations() }
            }
            Tab(value: TVTab.search, role: .search) {
                NavigationStack { TVSearchView().tvDestinations() }
            }
            Tab("Settings", systemImage: "gearshape", value: TVTab.settings) {
                NavigationStack { TVSettingsView() }
            }
        }
    }
}

/// Places the Apple TV app navigates to from any tab.
enum TVRoute: Hashable {
    case meta(MetaItem, autoplayVideoId: String? = nil)
    case catalog(addonUrl: String, type: String, id: String, title: String)
}

extension View {
    func tvDestinations() -> some View {
        navigationDestination(for: TVRoute.self) { route in
            switch route {
            case let .meta(meta, videoId):
                TVDetailView(preview: meta, autoplayVideoId: videoId)
            case let .catalog(addonUrl, type, id, title):
                TVCatalogGridView(addonUrl: addonUrl, type: type, catalogId: id, title: title)
            }
        }
    }
}
