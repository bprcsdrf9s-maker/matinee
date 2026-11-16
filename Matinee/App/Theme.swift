import SwiftUI

enum Theme {
    /// Violet accent.
    static let accent = Color(red: 0.49, green: 0.40, blue: 1.0)
    /// Text/icons drawn on top of the accent.
    static let onAccent = Color.white
    static let background = Color(red: 0.06, green: 0.055, blue: 0.08)
    static let card = Color(white: 0.13)
    static let pill = Color(white: 1, opacity: 0.09)
    static let cardRadius: CGFloat = 8
    /// Room left at the bottom of every screen for the floating tab bar.
    static let tabBarClearance: CGFloat = 84
}

/// Places the app navigates to from any tab.
enum Route: Hashable {
    case meta(MetaItem, autoplayVideoId: String? = nil)
    case catalog(addonUrl: String, type: String, id: String, title: String)
    case search
}

extension View {
    func withMatineeDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case let .meta(meta, videoId):
                DetailView(preview: meta, autoplayVideoId: videoId)
            case let .catalog(addonUrl, type, id, title):
                CatalogGridView(addonUrl: addonUrl, type: type, catalogId: id, title: title)
            case .search:
                SearchView()
            }
        }
    }
}

/// Poster widths that suit phone and tablet.
struct Sizing {
    let regular: Bool
    var posterWidth: CGFloat { regular ? 150 : 112 }
    var landscapeWidth: CGFloat { regular ? 300 : 220 }
    var gridColumns: Int { regular ? 5 : 3 }
    var hPad: CGFloat { regular ? 24 : 14 }
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

    /// Stremio's type labels: "Movie", "Series", "Channel", "Tv".
    static func typeName(_ type: String) -> String {
        switch type {
        case "movie": return "Movie"
        case "series": return "Series"
        case "tv": return "TV"
        default: return type.prefix(1).uppercased() + type.dropFirst()
        }
    }
}
