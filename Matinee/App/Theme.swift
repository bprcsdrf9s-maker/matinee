import SwiftUI

enum Theme {
    /// Warm marquee gold.
    static let accent = Color(red: 0.96, green: 0.72, blue: 0.26)
    static let background = Color(red: 0.05, green: 0.05, blue: 0.07)
    static let card = Color(white: 0.13)
    static let cardRadius: CGFloat = 10
}

/// Places the app navigates to from any tab.
enum Route: Hashable {
    case meta(MetaItem, autoplayVideoId: String? = nil)
    case catalog(addonUrl: String, type: String, id: String, title: String)
}

extension View {
    func withMatineeDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case let .meta(meta, videoId):
                DetailView(preview: meta, autoplayVideoId: videoId)
            case let .catalog(addonUrl, type, id, title):
                CatalogGridView(addonUrl: addonUrl, type: type, catalogId: id, title: title)
            }
        }
    }
}

/// Poster widths that suit phone and tablet.
struct Sizing {
    let regular: Bool
    var posterWidth: CGFloat { regular ? 150 : 112 }
    var landscapeWidth: CGFloat { regular ? 320 : 250 }
    var gridMin: CGFloat { regular ? 140 : 104 }
    var hPad: CGFloat { regular ? 28 : 16 }
}

extension EnvironmentValues {
    var sizing: Sizing { Sizing(regular: horizontalSizeClass == .regular) }
}

enum Format {
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
