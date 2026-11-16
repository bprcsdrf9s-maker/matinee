import Foundation
import Security

enum PlayerEngine: String, CaseIterable, Identifiable {
    case automatic, apple, mpv
    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .apple: return "Apple Player"
        case .mpv: return "mpv"
        }
    }

    var detail: String {
        switch self {
        case .automatic: return "Apple's player when the file supports it (AirPlay, Picture in Picture), mpv for MKV and everything else."
        case .apple: return "Always try Apple's player first. Falls back to mpv if the file won't open."
        case .mpv: return "Always use mpv. Plays nearly any format, with addon subtitles."
        }
    }
}

/// Keys for @AppStorage, with their defaults registered at launch.
enum Pref {
    static let engine = "player.engine"
    static let hardwareDecoding = "player.hwdec"
    static let skipSeconds = "player.skip"
    static let audioLanguages = "player.alang"
    static let subtitleLanguages = "player.slang"
    static let autoSubtitles = "player.autosubs"
    static let syncProgress = "sync.progress"
    static let resumeAutomatically = "player.resume"
    static let onlyWorkingStreams = "streams.onlyWorking"

    static func register() {
        UserDefaults.standard.register(defaults: [
            engine: PlayerEngine.automatic.rawValue,
            hardwareDecoding: true,
            skipSeconds: 10,
            audioLanguages: "en,eng",
            subtitleLanguages: "en,eng",
            autoSubtitles: false,
            syncProgress: true,
            resumeAutomatically: true,
            onlyWorkingStreams: true,
        ])
    }

    static var currentEngine: PlayerEngine {
        PlayerEngine(rawValue: UserDefaults.standard.string(forKey: engine) ?? "") ?? .automatic
    }
}

/// The Stremio auth key lives in the Keychain, not UserDefaults.
enum Keychain {
    private static let service = "com.daniel.matinee"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Small on-disk cache so Home and Library show instantly on launch while fresh data loads.
enum DiskCache {
    private static var folder: URL {
        #if os(tvOS)
        // Apple TV apps may only write to Caches.
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        let dir = base.appendingPathComponent("Matinee", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func write(_ data: Data, name: String) {
        try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    static func read(_ name: String) -> Data? {
        try? Data(contentsOf: folder.appendingPathComponent(name))
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }

    static func clear() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Streams that failed to play. They're hidden from the stream list for 7 days.
enum BadStreams {
    private static let key = "streams.bad"
    private static let lifetime: TimeInterval = 7 * 24 * 3600

    private static func load() -> [String: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Date] ?? [:]
        let now = Date()
        return raw.filter { now.timeIntervalSince($0.value) < lifetime }
    }

    static func isBad(_ url: URL) -> Bool { load()[url.absoluteString] != nil }

    static func mark(_ url: URL) {
        guard !url.isFileURL else { return }
        var all = load()
        all[url.absoluteString] = Date()
        UserDefaults.standard.set(all, forKey: key)
    }

    static var count: Int { load().count }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

/// Resume points for things that aren't in the Stremio library (local files) or when sync is off.
enum LocalResume {
    private static let key = "resume.positions"

    static func position(for id: String) -> Double? {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        return all[id]
    }

    static func save(_ seconds: Double?, for id: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        all[id] = seconds
        if all.count > 300 { all = Dictionary(uniqueKeysWithValues: all.suffix(200).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(all, forKey: key)
    }
}
