import Foundation
import Observation

/// The Movie Database: "more like this" recommendations and what's trending.
/// Accepts either a v3 API key or a v4 read access token, saved in the Keychain.
enum TMDB {
    private static let keychainAccount = "tmdb.apiKey"

    /// Bumped whenever the key changes, so Home can reload its rows.
    static let keyVersionDefaultsKey = "tmdb.keyVersion"

    static var apiKey: String? {
        get { Keychain.get(keychainAccount).flatMap { $0.isEmpty ? nil : $0 } }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            Keychain.set(trimmed?.isEmpty == false ? trimmed : nil, for: keychainAccount)
            let d = UserDefaults.standard
            d.set(d.integer(forKey: keyVersionDefaultsKey) + 1, forKey: keyVersionDefaultsKey)
        }
    }

    static var isConfigured: Bool { apiKey != nil }

    struct Item: Decodable, Hashable {
        let id: Int
        let mediaType: String?
        let title: String?
        let name: String?
        let overview: String?
        let posterPath: String?
        let backdropPath: String?
        let releaseDate: String?
        let firstAirDate: String?
        let voteAverage: Double?
        let popularity: Double?

        enum CodingKeys: String, CodingKey {
            case id, title, name, overview, popularity
            case mediaType = "media_type"
            case posterPath = "poster_path"
            case backdropPath = "backdrop_path"
            case releaseDate = "release_date"
            case firstAirDate = "first_air_date"
            case voteAverage = "vote_average"
        }
    }

    private struct Page: Decodable { let results: [Item] }
    private struct FindResult: Decodable {
        let movieResults: [Item]
        let tvResults: [Item]
        enum CodingKeys: String, CodingKey { case movieResults = "movie_results", tvResults = "tv_results" }
    }
    private struct ExternalIds: Decodable {
        let imdbId: String?
        enum CodingKeys: String, CodingKey { case imdbId = "imdb_id" }
    }

    enum Failure: Error { case noKey, rejected, http(Int) }

    private static func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        guard let key = apiKey else { throw Failure.noKey }
        var parts = URLComponents(string: "https://api.themoviedb.org/3" + path)!
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        let isToken = key.hasPrefix("eyJ")
        if !isToken { items.append(URLQueryItem(name: "api_key", value: key)) }
        parts.queryItems = items.isEmpty ? nil : items
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if isToken { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw Failure.rejected }
        guard (200..<300).contains(status) else { throw Failure.http(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Checks a key before saving it.
    static func validate(_ candidate: String) async -> Bool {
        let previous = apiKey
        apiKey = candidate
        let ok: Bool
        do {
            let _: Page = try await get("/trending/movie/week")
            ok = true
        } catch {
            ok = false
        }
        if !ok { apiKey = previous }
        return ok
    }

    // MARK: IMDb ↔ TMDB ids, cached for good since they never change

    private static let tmdbForImdbKey = "tmdb.byImdb"
    private static let imdbForTmdbKey = "tmdb.toImdb"

    private static func cached(_ key: String, _ id: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[id]
    }

    private static func cache(_ key: String, _ id: String, _ value: String) {
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        map[id] = value
        UserDefaults.standard.set(map, forKey: key)
    }

    /// "movie:603" or "tv:1396" for an IMDb id.
    static func tmdbId(imdb: String, type: String) async -> (kind: String, id: Int)? {
        if let hit = cached(tmdbForImdbKey, imdb) {
            let parts = hit.split(separator: ":")
            if parts.count == 2, let n = Int(parts[1]) { return (String(parts[0]), n) }
            return nil
        }
        guard let found: FindResult = try? await get("/find/\(imdb)", ["external_source": "imdb_id"]) else { return nil }
        let pick: (String, Item)?
        if type == "series" {
            pick = found.tvResults.first.map { ("tv", $0) } ?? found.movieResults.first.map { ("movie", $0) }
        } else {
            pick = found.movieResults.first.map { ("movie", $0) } ?? found.tvResults.first.map { ("tv", $0) }
        }
        guard let (kind, item) = pick else {
            cache(tmdbForImdbKey, imdb, "none")
            return nil
        }
        cache(tmdbForImdbKey, imdb, "\(kind):\(item.id)")
        return (kind, item.id)
    }

    static func imdbId(kind: String, id: Int) async -> String? {
        let key = "\(kind):\(id)"
        if let hit = cached(imdbForTmdbKey, key) { return hit == "none" ? nil : hit }
        guard let ids: ExternalIds = try? await get("/\(kind)/\(id)/external_ids") else { return nil }
        let imdb = ids.imdbId.flatMap { $0.hasPrefix("tt") ? $0 : nil }
        cache(imdbForTmdbKey, key, imdb ?? "none")
        return imdb
    }

    static func recommendations(kind: String, id: Int) async -> [Item] {
        let page: Page? = try? await get("/\(kind)/\(id)/recommendations", ["language": "en-US", "page": "1"])
        return (page?.results ?? []).map { $0.with(kind: kind) }
    }

    static func trending() async -> [Item] {
        let page: Page? = try? await get("/trending/all/week", ["language": "en-US"])
        return (page?.results ?? []).filter { $0.mediaType == "movie" || $0.mediaType == "tv" }
    }
}

extension TMDB.Item {
    var kind: String { mediaType == "tv" ? "tv" : "movie" }
    var key: String { "\(kind):\(id)" }

    fileprivate func with(kind: String) -> TMDB.Item {
        TMDB.Item(id: id, mediaType: mediaType ?? kind, title: title, name: name, overview: overview,
                  posterPath: posterPath, backdropPath: backdropPath, releaseDate: releaseDate,
                  firstAirDate: firstAirDate, voteAverage: voteAverage, popularity: popularity)
    }

    func meta(imdb: String) -> MetaItem {
        let year = (releaseDate ?? firstAirDate).map { String($0.prefix(4)) }
        return MetaItem(
            id: imdb,
            type: kind == "tv" ? "series" : "movie",
            name: title ?? name ?? "",
            poster: posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w342\($0)") },
            background: backdropPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w1280\($0)") },
            description: overview,
            releaseInfo: year?.isEmpty == false ? year : nil,
            imdbRating: voteAverage.flatMap { $0 > 0 ? String(format: "%.1f", $0) : nil }
        )
    }
}

/// Builds the profile's recommendation rows from what it has been watching.
/// Works with no key, from Cinemeta; a TMDB key, if added, blends TMDB's picks into "Recommended for You".
@MainActor
@Observable
final class RecommendationsModel {
    struct Row: Identifiable {
        let id: String
        let title: String
        let items: [MetaItem]
    }

    private(set) var recommended: [MetaItem] = []
    private(set) var trending: [MetaItem] = []
    private(set) var newForYou: [MetaItem] = []
    private(set) var becauseYouWatched: [Row] = []
    private(set) var loading = false
    @ObservationIgnored private var loadedKey = ""

    /// Rows in display order, after Continue Watching.
    var leadingRows: [Row] {
        var rows: [Row] = []
        if !recommended.isEmpty { rows.append(Row(id: "rec", title: "Recommended for You", items: recommended)) }
        return rows
    }

    var trailingRows: [Row] {
        var rows: [Row] = []
        if !trending.isEmpty { rows.append(Row(id: "trending", title: "Trending Now", items: trending)) }
        if !newForYou.isEmpty { rows.append(Row(id: "new", title: "New for You", items: newForYou)) }
        return rows + becauseYouWatched
    }

    /// A title for the big banner at the top of Home.
    var heroCandidates: [MetaItem] {
        Array((recommended.prefix(6) + trending.prefix(4)).filter { $0.background != nil })
    }

    func load(library: [LibraryEntry], profileId: String?, force: Bool = false) async {
        let seeds = TasteRecommender.seeds(from: library)
        let key = (profileId ?? "") + "|" + seeds.map(\.0.id).joined(separator: ",") + "|" + (TMDB.isConfigured ? "t" : "")
        guard force || key != loadedKey else { return }
        loadedKey = key
        loading = recommended.isEmpty && trending.isEmpty

        let known = Set(library.filter { $0.isWatched || $0.isInLibrary || $0.isInContinueWatching }.map(\.id))

        // Trending: Cinemeta's Popular movies and shows, alternated.
        async let popularMovies = Cinemeta.catalog(type: "movie", id: "top")
        async let popularShows = Cinemeta.catalog(type: "series", id: "top")
        async let tmdbPicks = TMDB.isConfigured ? tmdbRecommendations(seeds: seeds.prefix(8).map(\.0), known: known) : []

        let seeded = await TasteRecommender.features(for: seeds)
        let taste = TasteRecommender.taste(seeded)

        var rec: [MetaItem] = []
        var fresh: [MetaItem] = []
        var because: [Row] = []
        if !taste.isEmpty {
            async let candidates = TasteRecommender.pool(TasteRecommender.requests(for: taste))
            async let newCandidates = TasteRecommender.pool(TasteRecommender.requests(for: taste, catalogs: ["year"], genresPerType: 2))
            rec = TasteRecommender.rank(await candidates, taste: taste, excluding: known, limit: 24)
            fresh = TasteRecommender.rank(await newCandidates, taste: taste, excluding: known.union(rec.map(\.id)), limit: 20, minRating: 6.0)

            // Because You Watched: the two most recent titles you finished or are watching.
            let anchors = seeded.filter { $0.0.isWatched || $0.0.timeOffset > 0 }.prefix(2)
            for (entry, _, f) in anchors {
                var t = Taste()
                t.add(f, type: entry.type, weight: 1)
                var reqs: [(type: String, catalog: String, genre: String?)] = []
                for g in f.genres.prefix(2) { reqs += [(entry.type, "top", g), (entry.type, "imdbRating", g)] }
                let row = TasteRecommender.rank(await TasteRecommender.pool(reqs), taste: t,
                                                excluding: known.union([entry.id]), limit: 15, perGenre: 15)
                if row.count >= 4 {
                    because.append(Row(id: "because-\(entry.id)", title: "Because You Watched \(entry.name)", items: row))
                }
            }
        }

        // With a TMDB key, alternate its picks into Recommended for You.
        let tmdb = await tmdbPicks
        if !tmdb.isEmpty {
            var merged: [MetaItem] = []
            var seen = Set<String>()
            for i in 0..<max(rec.count, tmdb.count) {
                for list in [rec, tmdb] where i < list.count && seen.insert(list[i].id).inserted { merged.append(list[i]) }
            }
            rec = Array(merged.prefix(24))
        }

        let movies = await popularMovies, shows = await popularShows
        var trend: [MetaItem] = []
        for i in 0..<max(movies.count, shows.count) {
            if i < movies.count { trend.append(movies[i]) }
            if i < shows.count { trend.append(shows[i]) }
        }
        trend = Array(trend.filter { !known.contains($0.id) }.prefix(20))

        // A profile switch while this was loading makes these results stale.
        guard key == loadedKey else { return }
        recommended = rec
        trending = trend
        newForYou = fresh
        becauseYouWatched = because
        loading = false
    }

    /// TMDB's "recommended because you watched" picks, combined across recent titles.
    private func tmdbRecommendations(seeds: [LibraryEntry], known: Set<String>) async -> [MetaItem] {
        let perSeed: [(Int, [TMDB.Item])] = await withTaskGroup(of: (Int, [TMDB.Item]).self) { group in
            for (i, seed) in seeds.enumerated() {
                group.addTask {
                    let base = String(seed.id.split(separator: ":").first ?? Substring(seed.id))
                    guard let ref = await TMDB.tmdbId(imdb: base, type: seed.type) else { return (i, []) }
                    return (i, await TMDB.recommendations(kind: ref.kind, id: ref.id))
                }
            }
            var out: [(Int, [TMDB.Item])] = []
            for await r in group { out.append(r) }
            return out
        }
        var score: [String: Double] = [:]
        var items: [String: TMDB.Item] = [:]
        for (i, recs) in perSeed {
            let weight = 1.0 / Double(i + 1)
            for (rank, item) in recs.enumerated() {
                score[item.key, default: 0] += weight * (1.0 - Double(rank) / 40.0)
                items[item.key] = item
            }
        }
        let top = score.sorted { $0.value > $1.value }.prefix(24).compactMap { items[$0.key] }
        let resolved: [(Int, MetaItem?)] = await withTaskGroup(of: (Int, MetaItem?).self) { group in
            for (i, item) in top.enumerated() {
                group.addTask {
                    guard let imdb = await TMDB.imdbId(kind: item.kind, id: item.id) else { return (i, nil) }
                    return (i, item.meta(imdb: imdb))
                }
            }
            var out: [(Int, MetaItem?)] = []
            for await r in group { out.append(r) }
            return out
        }
        return resolved.sorted { $0.0 < $1.0 }.compactMap(\.1).filter { !known.contains($0.id) }
    }
}
