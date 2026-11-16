import Foundation
import Observation

/// Account, addons and library for the whole app.
@MainActor
@Observable
final class AppModel {
    private(set) var authKey: String?
    private(set) var email: String?
    private(set) var addons: [AddonDescriptor] = []
    private(set) var library: [LibraryEntry] = []
    /// Same entries keyed by id, for quick lookups from every poster.
    private(set) var libraryById: [String: LibraryEntry] = [:]

    private func setLibrary(_ entries: [LibraryEntry]) {
        library = entries
        libraryById = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
    private(set) var isRefreshing = false
    var errorMessage: String?

    @ObservationIgnored private var syncChain: Task<Void, Never>?

    var isSignedIn: Bool { authKey != nil }

    init() {
        authKey = Keychain.get("authKey")
        email = UserDefaults.standard.string(forKey: "account.email")
        if authKey != nil { loadCache() }
    }

    // MARK: Session

    func signIn(email: String, password: String) async throws {
        let account = try await StremioAPI.login(email: email, password: password)
        await finishSignIn(account)
    }

    func signIn(linkAuthKey: String) async throws {
        // The link service hands back an auth key; confirm it and fetch the account email.
        let mail = try? await StremioAPI.getUserEmail(authKey: linkAuthKey)
        await finishSignIn(.init(authKey: linkAuthKey, email: mail))
    }

    private func finishSignIn(_ account: StremioAPI.Account) async {
        authKey = account.authKey
        email = account.email
        Keychain.set(account.authKey, for: "authKey")
        UserDefaults.standard.set(account.email, forKey: "account.email")
        await refresh()
    }

    func signOut() {
        if let key = authKey { Task.detached { await StremioAPI.logout(authKey: key) } }
        authKey = nil
        email = nil
        addons = []
        setLibrary([])
        Keychain.set(nil, for: "authKey")
        UserDefaults.standard.removeObject(forKey: "account.email")
        DiskCache.clear()
    }

    // MARK: Loading

    private func loadCache() {
        if let data = DiskCache.read("addons.json") {
            addons = StremioAPI.decodeAddons(data)
        }
        if let data = DiskCache.read("library.json"),
           let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            setLibrary(items.compactMap(LibraryEntry.init))
        }
    }

    @ObservationIgnored private var lastRefresh: Date?

    /// Reloads when returning to the app, at most once every 30 seconds.
    func refreshIfStale() async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 30 { return }
        await refresh()
    }

    func refresh() async {
        guard let key = authKey, !isRefreshing else { return }
        lastRefresh = Date()
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let addonsCall = StremioAPI.addonCollection(authKey: key)
            async let libraryCall = StremioAPI.libraryItems(authKey: key)
            let (collection, items) = try await (addonsCall, libraryCall)
            addons = collection.addons
            setLibrary(items.compactMap(LibraryEntry.init))
            DiskCache.write(collection.raw, name: "addons.json")
            if let data = try? JSONSerialization.data(withJSONObject: items) {
                DiskCache.write(data, name: "library.json")
            }
            errorMessage = nil
        } catch let error as StremioError where error.isSessionExpired {
            signOut()
            errorMessage = "Your Stremio session ended. Sign in again."
        } catch {
            if addons.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    func refreshLibrary() async {
        guard let key = authKey, let items = try? await StremioAPI.libraryItems(authKey: key) else { return }
        setLibrary(items.compactMap(LibraryEntry.init))
        if let data = try? JSONSerialization.data(withJSONObject: items) {
            DiskCache.write(data, name: "library.json")
        }
    }

    // MARK: Library views

    var continueWatching: [LibraryEntry] {
        library.filter(\.isInContinueWatching).sorted { $0.sortDate > $1.sortDate }
    }

    var savedLibrary: [LibraryEntry] {
        library.filter(\.isInLibrary).sorted { ($0.mtime ?? .distantPast) > ($1.mtime ?? .distantPast) }
    }

    func entry(for id: String) -> LibraryEntry? {
        libraryById[id]
    }

    /// Catalogs shown as rows on Home, in addon order.
    var boardCatalogs: [(addon: AddonDescriptor, catalog: ManifestCatalog)] {
        addons.flatMap { addon in
            addon.manifest.catalogs.filter(\.isBoard).map { (addon: addon, catalog: $0) }
        }
    }

    // MARK: Writing to the library

    private func replaceLocal(_ raw: [String: Any]) {
        guard let entry = LibraryEntry(raw) else { return }
        var entries = library
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
        setLibrary(entries)
    }

    /// Runs library writes one after another so a periodic save and a close never race.
    private func enqueue(_ work: @escaping @MainActor (String) async throws -> Void) {
        guard let key = authKey else { return }
        let previous = syncChain
        syncChain = Task { @MainActor in
            await previous?.value
            do { try await work(key) } catch { /* best effort; next save retries */ }
        }
    }

    /// Pulls the account's newest copy first so changes from other devices aren't overwritten.
    private func latestRaw(key: String, seed: LibrarySeed) async throws -> [String: Any] {
        let remote = try await StremioAPI.libraryItems(authKey: key, ids: [seed.id]).first
        return remote ?? entry(for: seed.id)?.raw
            ?? LibraryEntry.newRaw(id: seed.id, type: seed.type, name: seed.name, poster: seed.poster)
    }

    func toggleLibrary(_ seed: LibrarySeed) {
        let adding = !(entry(for: seed.id)?.isInLibrary ?? false)
        // Update the screen right away, then sync.
        let base = entry(for: seed.id)?.raw
            ?? LibraryEntry.newRaw(id: seed.id, type: seed.type, name: seed.name, poster: seed.poster)
        replaceLocal(ProgressRules.setInLibrary(base, adding))
        enqueue { [weak self] key in
            guard let self else { return }
            let latest = try await self.latestRaw(key: key, seed: seed)
            let updated = ProgressRules.setInLibrary(latest, adding)
            try await StremioAPI.putLibraryItems(authKey: key, [updated])
            self.replaceLocal(updated)
        }
    }

    func dismissFromContinueWatching(_ entry: LibraryEntry) {
        let updated = ProgressRules.dismissFromContinueWatching(entry.raw)
        replaceLocal(updated)
        enqueue { [weak self] key in
            guard let self else { return }
            let latest = try await self.latestRaw(key: key, seed: LibrarySeed(entry.asMeta))
            let fresh = ProgressRules.dismissFromContinueWatching(latest)
            try await StremioAPI.putLibraryItems(authKey: key, [fresh])
            self.replaceLocal(fresh)
        }
    }

    func saveProgress(seed: LibrarySeed, videoId: String, positionMs: UInt64, durationMs: UInt64,
                      watchedMs: UInt64, closing: Bool, nextVideoId: String?) {
        guard UserDefaults.standard.bool(forKey: Pref.syncProgress) else { return }
        enqueue { [weak self] key in
            guard let self else { return }
            let latest = try await self.latestRaw(key: key, seed: seed)
            let updated = ProgressRules.apply(to: latest, videoId: videoId, positionMs: positionMs,
                                              durationMs: durationMs, watchedMs: watchedMs,
                                              closing: closing, nextVideoId: nextVideoId)
            try await StremioAPI.putLibraryItems(authKey: key, [updated])
            self.replaceLocal(updated)
        }
    }

    /// Where to resume a video: the synced position if Stremio's library is on this video, else the local one.
    func resumePosition(itemId: String?, videoId: String) -> Double? {
        if let itemId, let e = entry(for: itemId), e.videoId == videoId || (e.videoId == nil && videoId == itemId),
           e.timeOffset > 1000, e.duration == 0 || e.progress < ProgressRules.creditsThreshold {
            return e.resumeSeconds
        }
        if let local = LocalResume.position(for: videoId), local > 5 { return local }
        return nil
    }
}
