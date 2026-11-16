import SwiftUI
import AVFoundation

@main
struct MatineeApp: App {
    @State private var model = AppModel()

    init() {
        Pref.register()
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

    var body: some View {
        Group {
            if model.isSignedIn {
                MainTabs()
                    .task { await model.refresh() }
            } else {
                SignInView()
            }
        }
        .animation(.default, value: model.isSignedIn)
    }
}

struct MainTabs: View {
    @State private var selection = "home"

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house.fill", value: "home") {
                NavigationStack { HomeView().withMatineeDestinations() }
            }
            Tab("Library", systemImage: "books.vertical.fill", value: "library") {
                NavigationStack { LibraryView().withMatineeDestinations() }
            }
            Tab("Settings", systemImage: "gearshape.fill", value: "settings") {
                NavigationStack { SettingsView() }
            }
            Tab(value: "search", role: .search) {
                NavigationStack { SearchView().withMatineeDestinations() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
