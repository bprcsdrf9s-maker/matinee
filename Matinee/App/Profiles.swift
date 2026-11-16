import SwiftUI

/// A "Who's watching?" profile. Each one signs into its own Stremio account, so libraries,
/// watch history and Continue Watching stay separate. The account's auth key lives in the Keychain.
struct Profile: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var avatar: Int
    var email: String?

    init(name: String, avatar: Int, email: String? = nil) {
        id = UUID().uuidString
        self.name = name
        self.avatar = avatar
        self.email = email
    }

    var keychainAccount: String { "authKey.\(id)" }

    /// A first name from an email address: "jane.doe@x.com" → "Jane".
    static func name(fromEmail email: String?) -> String {
        guard let email, let local = email.split(separator: "@").first, !local.isEmpty else { return "Me" }
        let word = local.split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        guard word.count >= 2 else { return "Me" }
        return String(word.prefix(12)).capitalized
    }
}

/// Profile avatars: a symbol on a two-tone gradient, like streaming apps' profile tiles.
enum Avatar {
    struct Style {
        let symbol: String
        let colors: [Color]
    }

    static let all: [Style] = [
        Style(symbol: "popcorn.fill", colors: [Color(red: 0.95, green: 0.33, blue: 0.33), Color(red: 0.62, green: 0.10, blue: 0.24)]),
        Style(symbol: "film.fill", colors: [Color(red: 0.49, green: 0.40, blue: 1.0), Color(red: 0.24, green: 0.15, blue: 0.62)]),
        Style(symbol: "star.fill", colors: [Color(red: 1.0, green: 0.78, blue: 0.25), Color(red: 0.86, green: 0.43, blue: 0.08)]),
        Style(symbol: "bolt.fill", colors: [Color(red: 0.25, green: 0.80, blue: 0.95), Color(red: 0.09, green: 0.36, blue: 0.70)]),
        Style(symbol: "leaf.fill", colors: [Color(red: 0.40, green: 0.86, blue: 0.50), Color(red: 0.07, green: 0.48, blue: 0.33)]),
        Style(symbol: "heart.fill", colors: [Color(red: 1.0, green: 0.50, blue: 0.75), Color(red: 0.70, green: 0.16, blue: 0.48)]),
        Style(symbol: "gamecontroller.fill", colors: [Color(red: 0.62, green: 0.90, blue: 0.30), Color(red: 0.20, green: 0.52, blue: 0.14)]),
        Style(symbol: "pawprint.fill", colors: [Color(red: 1.0, green: 0.62, blue: 0.35), Color(red: 0.72, green: 0.30, blue: 0.12)]),
        Style(symbol: "moon.stars.fill", colors: [Color(red: 0.42, green: 0.48, blue: 0.95), Color(red: 0.10, green: 0.12, blue: 0.40)]),
        Style(symbol: "car.fill", colors: [Color(red: 0.92, green: 0.26, blue: 0.20), Color(red: 0.25, green: 0.25, blue: 0.28)]),
        Style(symbol: "music.note", colors: [Color(red: 0.20, green: 0.90, blue: 0.80), Color(red: 0.05, green: 0.45, blue: 0.55)]),
        Style(symbol: "teddybear.fill", colors: [Color(red: 0.86, green: 0.66, blue: 0.48), Color(red: 0.50, green: 0.32, blue: 0.20)]),
    ]

    static func style(_ index: Int) -> Style { all[((index % all.count) + all.count) % all.count] }
}

/// A profile's square tile: the avatar symbol on its gradient.
struct ProfileAvatar: View {
    let avatar: Int
    var size: CGFloat = 96

    var body: some View {
        let style = Avatar.style(avatar)
        RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
            .fill(LinearGradient(colors: style.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: style.symbol)
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.25), radius: size * 0.04, y: size * 0.02)
            }
            .accessibilityHidden(true)
    }
}

/// Which profile the add/edit screen is for.
enum EditorTarget: Identifiable {
    case add
    case edit(Profile)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let p): return p.id
        }
    }
}

/// Saved list of profiles and which one is active.
enum ProfileStore {
    private static let listKey = "profiles.list"
    private static let activeKey = "profiles.active"

    static func load() -> [Profile] {
        guard let data = UserDefaults.standard.data(forKey: listKey),
              let list = try? JSONDecoder().decode([Profile].self, from: data) else { return [] }
        return list
    }

    static func save(_ profiles: [Profile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: listKey)
        }
    }

    static var activeId: String? {
        get { UserDefaults.standard.string(forKey: activeKey) }
        set { UserDefaults.standard.set(newValue, forKey: activeKey) }
    }
}
