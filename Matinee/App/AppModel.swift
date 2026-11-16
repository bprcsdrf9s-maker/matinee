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

    // MARK: Profiles

    private(set) var profiles: [Profile] = []
    private(set) var activeProfileId: String?
    /// Showing the "Who's watching?" screen.
    var choosingProfile = false

    var activeProfile: Profile? { profiles.first { $0.id == activeProfileId } }

    /// A profile that was just added and hasn't signed in to Stremio yet.
    var isAddingProfile: Bool { activeProfile != nil && authKey == nil }

    var isSignedIn: Bool { authKey != nil }

    /// Cache files are kept per profile so switching shows the right library straight away.
    private func cacheName(_ base: String) -> String {
        guard let id = activeProfileId else { return base + ".json" }
        return "\(base)-\(id).json"
    }

    init() {
        profiles = ProfileStore.load()
        migrateSingleAccount()
        activeProfileId = ProfileStore.activeId.flatMap { id in profiles.contains { $0.id == id } ? id : nil }
            ?? profiles.first?.id
        loadActiveSession()
        // Like the streaming apps: ask who's watching at launch once there's more than one profile.
        choosingProfile = profiles.count > 1
    }

    /// Versions before profiles kept one account under "authKey"; that becomes the first profile.
    private func migrateSingleAccount() {
        guard profiles.isEmpty, let key = Keychain.get("authKey") else { return }
        let mail = UserDefaults.standard.string(forKey: "account.email")
        let profile = Profile(name: Profile.name(fromEmail: mail), avatar: 1, email: mail)
        Keychain.set(key, for: profile.keychainAccount)
        profiles = [profile]
        ProfileStore.save(profiles)
        ProfileStore.activeId = profile.id
        Keychain.set(nil, for: "authKey")
        UserDefaults.standard.removeObject(forKey: "account.email")
    }

    private func loadActiveSession() {
        addons = []
        setLibrary([])
        errorMessage = nil
        lastRefresh = nil
        guard let profile = activeProfile else {
            authKey = nil
            email = nil
            return
        }
        authKey = Keychain.get(profile.keychainAccount)
        email = profile.email
        if authKey != nil { loadCache() }
    }

    /// Switches to a profile from the "Who's watching?" screen.
    func select(_ profile: Profile) {
        guard profiles.contains(profile) else { return }
        if profile.id != activeProfileId {
            activeProfileId = profile.id
            ProfileStore.activeId = profile.id
            loadActiveSession()
        }
        choosingProfile = false
        Task { await refresh() }
    }

    /// Adds a profile and shows its Stremio sign-in.
    func addProfile(name: String, avatar: Int) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = Profile(name: trimmed.isEmpty ? "Profile \(profiles.count + 1)" : trimmed, avatar: avatar)
        profiles.append(profile)
        ProfileStore.save(profiles)
        activeProfileId = profile.id
        loadActiveSession()
        choosingProfile = false
    }

    /// Backs out of signing in a newly added profile.
    func cancelAddingProfile() {
        guard let profile = activeProfile, authKey == nil else { return }
        profiles.removeAll { $0.id == profile.id }
        ProfileStore.save(profiles)
        activeProfileId = ProfileStore.activeId.flatMap { id in profiles.contains { $0.id == id } ? id : nil }
            ?? profiles.first?.id
        loadActiveSession()
        choosingProfile = !profiles.isEmpty
    }

    func updateProfile(_ id: String, name: String, avatar: Int) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { profiles[i].name = trimmed }
        profiles[i].avatar = avatar
        ProfileStore.save(profiles)
    }

    /// Removes a profile from this device and signs its Stremio session out.
    func deleteProfile(_ id: String) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        if let key = Keychain.get(profile.keychainAccount) {
            Task.detached { await StremioAPI.logout(authKey: key) }
        }
        Keychain.set(nil, for: profile.keychainAccount)
        DiskCache.remove("addons-\(id).json")
        DiskCache.remove("library-\(id).json")
        profiles.removeAll { $0.id == id }
        ProfileStore.save(profiles)
        if activeProfileId == id {
            activeProfileId = profiles.first?.id
            ProfileStore.activeId = activeProfileId
            loadActiveSession()
            choosingProfile = profiles.count > 1
        }
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
        // Signing in with no profiles yet creates the first one, named from the account.
        if activeProfile == nil {
            let profile = Profile(name: Profile.name(fromEmail: account.email), avatar: profiles.count + 1)
            profiles.append(profile)
            activeProfileId = profile.id
            ProfileStore.activeId = profile.id
        }
        guard let i = profiles.firstIndex(where: { $0.id == activeProfileId }) else { return }
        profiles[i].email = account.email
        ProfileStore.save(profiles)
        ProfileStore.activeId = activeProfileId
        Keychain.set(account.authKey, for: profiles[i].keychainAccount)
        authKey = account.authKey
        email = account.email
        choosingProfile = false
        await refresh()
    }

    /// Signs this profile out of Stremio and removes it from the device.
    func signOut() {
        guard let id = activeProfileId else { return }
        deleteProfile(id)
    }

    /// Keeps the profile but asks it to sign in again (an expired Stremio session).
    private func endSession() {
        if let profile = activeProfile { Keychain.set(nil, for: profile.keychainAccount) }
        authKey = nil
        addons = []
        setLibrary([])
    }

    // MARK: Loading

    private func loadCache() {
        if let data = DiskCache.read(cacheName("addons")) {
            addons = StremioAPI.decodeAddons(data)
        }
        if let data = DiskCache.read(cacheName("library")),
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
        let profileId = activeProfileId
        lastRefresh = Date()
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let addonsCall = StremioAPI.addonCollection(authKey: key)
            async let libraryCall = StremioAPI.libraryItems(authKey: key)
            let (collection, items) = try await (addonsCall, libraryCall)
            // The profile may have been switched while this was loading.
            guard activeProfileId == profileId else { return }
            addons = collection.addons
            setLibrary(items.compactMap(LibraryEntry.init))
            DiskCache.write(collection.raw, name: cacheName("addons"))
            if let data = try? JSONSerialization.data(withJSONObject: items) {
                DiskCache.write(data, name: cacheName("library"))
            }
            errorMessage = nil
        } catch let error as StremioError where error.isSessionExpired {
            guard activeProfileId == profileId else { return }
            endSession()
            errorMessage = "Your Stremio session ended. Sign in again."
        } catch {
            if addons.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    func refreshLibrary() async {
        let profileId = activeProfileId
        guard let key = authKey, let items = try? await StremioAPI.libraryItems(authKey: key),
              activeProfileId == profileId else { return }
        setLibrary(items.compactMap(LibraryEntry.init))
        if let data = try? JSONSerialization.data(withJSONObject: items) {
            DiskCache.write(data, name: cacheName("library"))
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

    /// Puts a written entry into the shown library, unless it belongs to a profile that's no longer active.
    private func replaceLocal(_ raw: [String: Any], profileId: String? = nil) {
        if let profileId, profileId != activeProfileId { return }
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
    private func enqueue(_ work: @escaping @MainActor (_ key: String, _ profileId: String?) async throws -> Void) {
        guard let key = authKey else { return }
        let profileId = activeProfileId
        let previous = syncChain
        syncChain = Task { @MainActor in
            await previous?.value
            do { try await work(key, profileId) } catch { /* best effort; next save retries */ }
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
        enqueue { [weak self] key, profileId in
            guard let self else { return }
            let latest = try await self.latestRaw(key: key, seed: seed)
            let updated = ProgressRules.setInLibrary(latest, adding)
            try await StremioAPI.putLibraryItems(authKey: key, [updated])
            self.replaceLocal(updated, profileId: profileId)
        }
    }

    func dismissFromContinueWatching(_ entry: LibraryEntry) {
        let updated = ProgressRules.dismissFromContinueWatching(entry.raw)
        replaceLocal(updated)
        enqueue { [weak self] key, profileId in
            guard let self else { return }
            let latest = try await self.latestRaw(key: key, seed: LibrarySeed(entry.asMeta))
            let fresh = ProgressRules.dismissFromContinueWatching(latest)
            try await StremioAPI.putLibraryItems(authKey: key, [fresh])
            self.replaceLocal(fresh, profileId: profileId)
        }
    }

    func saveProgress(seed: LibrarySeed, videoId: String, positionMs: UInt64, durationMs: UInt64,
                      watchedMs: UInt64, closing: Bool, nextVideoId: String?) {
        guard UserDefaults.standard.bool(forKey: Pref.syncProgress) else { return }
        enqueue { [weak self] key, profileId in
            guard let self else { return }
            let latest = try await self.latestRaw(key: key, seed: seed)
            let updated = ProgressRules.apply(to: latest, videoId: videoId, positionMs: positionMs,
                                              durationMs: durationMs, watchedMs: watchedMs,
                                              closing: closing, nextVideoId: nextVideoId)
            try await StremioAPI.putLibraryItems(authKey: key, [updated])
            self.replaceLocal(updated, profileId: profileId)
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
