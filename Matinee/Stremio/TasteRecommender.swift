import Foundation

/// Stremio's own metadata service. Free, no key, and every title comes with genres, director,
/// writers, cast, IMDb rating and a popularity score, which is everything the recommender needs.
enum Cinemeta {
    static let base = "https://v3-cinemeta.strem.io"

    private struct CatalogResponse: Decodable { let metas: [Lossy<MetaItem>]? }
    private struct MetaResponse: Decodable { let meta: MetaItem? }

    /// Popular ("top"), Featured ("imdbRating") or New ("year"), optionally for one genre. About 50 titles a page.
    static func catalog(type: String, id: String, genre: String? = nil) async -> [MetaItem] {
        var path = "\(base)/catalog/\(type)/\(id)"
        if let genre, let g = genre.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) { path += "/genre=\(g)" }
        guard let url = URL(string: path + ".json") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(CatalogResponse.self, from: data) else { return [] }
        return (decoded.metas ?? []).compactMap(\.value)
    }

    /// What the recommender needs to know about a title: genres and people. Cached for good.
    struct Features: Codable {
        let genres: [String]
        let directors: [String]
        let writers: [String]
        let cast: [String]
    }

    private static let featuresKey = "cinemeta.features.v1"

    static func features(type: String, id: String) async -> Features? {
        let base = String(id.split(separator: ":").first ?? Substring(id))
        guard base.hasPrefix("tt") else { return nil }
        if let hit = cachedFeatures()[base] { return hit }
        guard let url = URL(string: "\(Cinemeta.base)/meta/\(type)/\(base).json") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let meta = (try? JSONDecoder().decode(MetaResponse.self, from: data))?.meta else { return nil }
        let f = Features(meta)
        store(f, for: base)
        return f
    }

    private static func cachedFeatures() -> [String: Features] {
        guard let data = UserDefaults.standard.data(forKey: featuresKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Features].self, from: data)) ?? [:]
    }

    private static func store(_ f: Features, for id: String) {
        Task { @MainActor in
            var all = cachedFeatures()
            all[id] = f
            if all.count > 600 { all = Dictionary(uniqueKeysWithValues: all.prefix(400).map { ($0.key, $0.value) }) }
            if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: featuresKey) }
        }
    }
}

extension Cinemeta.Features {
    init(_ meta: MetaItem) {
        genres = meta.genres
        directors = meta.directors
        writers = meta.writers
        cast = Array(meta.cast.prefix(4))
    }
}

/// A profile's taste, built from what it watched, is watching and saved; and the scoring that
/// ranks other titles against it. Everything comes from Cinemeta, so no third-party key is needed.
struct Taste {
    private(set) var genres: [String: Double] = [:]
    private(set) var people: [String: Double] = [:]
    private(set) var types: [String: Double] = [:]

    var isEmpty: Bool { genres.isEmpty }

    /// Genres to pull candidates from for one type, strongest first.
    func topGenres(for type: String, limit: Int) -> [String] {
        let typeGenres = genreWeights(for: type)
        return typeGenres.sorted { $0.value > $1.value }.map(\.key).prefix(limit).map { $0 }
    }

    private var genresByType: [String: [String: Double]] = [:]
    func genreWeights(for type: String) -> [String: Double] { genresByType[type] ?? genres }

    /// Adds one title. Weight reflects how recent it is and how much it was watched.
    mutating func add(_ f: Cinemeta.Features, type: String, weight w: Double) {
        let g = Double(max(1, f.genres.count)).squareRoot()
        for genre in f.genres {
            genres[genre, default: 0] += w / g
            genresByType[type, default: [:]][genre, default: 0] += w / g
        }
        for d in f.directors { people["d:" + d, default: 0] += 3 * w }
        for x in f.writers.prefix(3) { people["w:" + x, default: 0] += 2 * w }
        for c in f.cast.prefix(3) { people["c:" + c, default: 0] += w }
        types[type, default: 0] += w
    }

    /// 0…1 for how well a title fits: genre 50%, people 25%, IMDb rating 15%, popularity 10%.
    func score(_ m: MetaItem, maxPopularity: Double) -> Double {
        let gw = genreWeights(for: m.type)
        let topG = gw.values.max() ?? 1
        let matched = m.genres.map { (gw[$0] ?? 0) / topG }.sorted(by: >)
        let genre = matched.isEmpty ? 0 : (matched[0] + 0.5 * (matched.count > 1 ? matched[1] : 0)) / 1.5

        let topP = people.values.max() ?? 1
        var p = 0.0
        for d in m.directors { p += (people["d:" + d] ?? 0) / topP }
        for x in m.writers.prefix(3) { p += 0.7 * (people["w:" + x] ?? 0) / topP }
        for c in m.cast.prefix(4) { p += 0.4 * (people["c:" + c] ?? 0) / topP }
        let person = min(1, p)

        let rating = Taste.rating(m).map { min(1, max(0, ($0 - 5) / 4)) } ?? 0.4
        let pop = maxPopularity > 0 ? log1p(m.popularity ?? 0) / log1p(maxPopularity) : 0

        let totalType = types.values.reduce(0, +)
        let typeShare = totalType > 0 ? (types[m.type] ?? 0) / totalType : 0.5
        return (0.5 * genre + 0.25 * person + 0.15 * rating + 0.10 * pop) * (0.6 + 0.4 * typeShare)
    }

    static func rating(_ m: MetaItem) -> Double? { m.imdbRating.flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } }
}

enum TasteRecommender {
    /// Titles that drive recommendations: newest first, finished ones counting most.
    static func seeds(from library: [LibraryEntry], limit: Int = 20) -> [(LibraryEntry, Double)] {
        library
            .filter { $0.id.hasPrefix("tt") && ($0.type == "movie" || $0.type == "series") }
            .filter { $0.isWatched || $0.timeOffset > 0 || $0.isInLibrary }
            .sorted { $0.sortDate > $1.sortDate }
            .prefix(limit)
            .enumerated()
            .map { i, e in
                let status = e.isWatched ? 1.0 : e.timeOffset > 0 ? 0.8 : 0.5
                return (e, status / (1 + Double(i) * 0.15))
            }
    }

    static func features(for seeds: [(LibraryEntry, Double)]) async -> [(LibraryEntry, Double, Cinemeta.Features)] {
        await withTaskGroup(of: (Int, Cinemeta.Features?).self) { group in
            for (i, s) in seeds.enumerated() {
                group.addTask { (i, await Cinemeta.features(type: s.0.type, id: s.0.id)) }
            }
            var out: [(Int, Cinemeta.Features?)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.compactMap { i, f in f.map { (seeds[i].0, seeds[i].1, $0) } }
        }
    }

    static func taste(_ seeded: [(LibraryEntry, Double, Cinemeta.Features)]) -> Taste {
        var t = Taste()
        for (e, w, f) in seeded { t.add(f, type: e.type, weight: w) }
        return t
    }

    /// Fetches catalogs in parallel and merges them, keeping the first copy of each title.
    static func pool(_ requests: [(type: String, catalog: String, genre: String?)]) async -> [MetaItem] {
        let lists: [(Int, [MetaItem])] = await withTaskGroup(of: (Int, [MetaItem]).self) { group in
            for (i, r) in requests.enumerated() {
                group.addTask { (i, await Cinemeta.catalog(type: r.type, id: r.catalog, genre: r.genre)) }
            }
            var out: [(Int, [MetaItem])] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }
        }
        var seen = Set<String>()
        var merged: [MetaItem] = []
        for (_, list) in lists {
            for m in list where m.id.hasPrefix("tt") && seen.insert(m.id).inserted { merged.append(m) }
        }
        return merged
    }

    /// Ranks a pool against a taste, dropping known titles, weak ratings and genre pile-ups.
    static func rank(_ pool: [MetaItem], taste: Taste, excluding known: Set<String>, limit: Int,
                     minRating: Double = 5.8, perGenre: Int = 6) -> [MetaItem] {
        let maxPop = pool.compactMap(\.popularity).max() ?? 0
        let scored = pool
            .filter { !known.contains($0.id) }
            .filter { Taste.rating($0).map { $0 >= minRating } ?? true }
            .map { ($0, taste.score($0, maxPopularity: maxPop)) }
            .sorted { $0.1 > $1.1 }
        var perPrimary: [String: Int] = [:]
        var out: [MetaItem] = []
        for (m, _) in scored {
            let primary = m.genres.first ?? ""
            if perPrimary[primary, default: 0] >= perGenre { continue }
            perPrimary[primary, default: 0] += 1
            out.append(m)
            if out.count == limit { break }
        }
        return out
    }

    /// Candidate requests for a taste: Popular and Featured in each type's strongest genres.
    static func requests(for taste: Taste, catalogs: [String] = ["top", "imdbRating"], genresPerType: Int = 3) -> [(type: String, catalog: String, genre: String?)] {
        var out: [(type: String, catalog: String, genre: String?)] = []
        let total = taste.types.values.reduce(0, +)
        for type in ["movie", "series"] {
            let share = total > 0 ? (taste.types[type] ?? 0) / total : 0
            let n = share >= 0.25 ? genresPerType : share > 0 ? 1 : 0
            for g in taste.topGenres(for: type, limit: n) {
                for c in catalogs { out.append((type, c, g)) }
            }
        }
        return out
    }

    /// "More Like This" for one title: its own genres and people, with a nudge toward your taste.
    static func similar(to meta: MetaItem, known: Set<String>, limit: Int = 15) async -> [MetaItem] {
        var f = meta.directors.isEmpty && meta.cast.isEmpty ? nil : Cinemeta.Features(meta)
        if f == nil || f?.genres.isEmpty == true { f = await Cinemeta.features(type: meta.type, id: meta.id) ?? f }
        guard let f, !f.genres.isEmpty else { return [] }
        var t = Taste()
        t.add(f, type: meta.type, weight: 1)
        let type = meta.type == "series" ? "series" : "movie"
        var reqs: [(type: String, catalog: String, genre: String?)] = []
        for g in f.genres.prefix(2) { reqs += [(type, "top", g), (type, "imdbRating", g)] }
        let candidates = await pool(reqs)
        var exclude = known
        exclude.insert(String(meta.id.split(separator: ":").first ?? Substring(meta.id)))
        return rank(candidates, taste: t, excluding: exclude, limit: limit, perGenre: limit)
    }
}
