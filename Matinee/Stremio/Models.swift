import Foundation
import CoreGraphics

// MARK: - Lenient decoding helpers

/// Decodes an element if possible and keeps going if it can't, so one malformed
/// addon, catalog item or stream never breaks a whole list.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// Reads a value that addons send as either a string or a number.
    func flexibleString(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return String(d) }
        return nil
    }

    func flexibleInt(_ key: Key) -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int(s) }
        return nil
    }

    func lossyArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        ((try? decodeIfPresent([Lossy<T>].self, forKey: key)) ?? nil)?.compactMap(\.value) ?? []
    }

    func url(_ key: Key) -> URL? {
        guard let s = flexibleString(key)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return URL(string: s)
    }
}

// MARK: - Addons

struct AddonDescriptor: Decodable, Identifiable, Hashable {
    let transportUrl: String
    let manifest: Manifest

    var id: String { transportUrl }

    static func == (lhs: AddonDescriptor, rhs: AddonDescriptor) -> Bool { lhs.transportUrl == rhs.transportUrl }
    func hash(into hasher: inout Hasher) { hasher.combine(transportUrl) }

    /// Mirrors stremio-core's `Manifest::is_resource_supported` for meta, stream and subtitles.
    func supports(resource: String, type: String, id: String) -> Bool {
        guard let res = manifest.resources.first(where: { $0.name == resource }) else { return false }
        let types: [String]? = res.isShort ? manifest.types : res.types
        let prefixes: [String]? = res.isShort ? manifest.idPrefixes : res.idPrefixes
        guard let types, types.contains(type) else { return false }
        guard let prefixes, !prefixes.isEmpty else { return true }
        return prefixes.contains { id.hasPrefix($0) }
    }
}

struct Manifest: Decodable {
    let id: String
    let name: String
    let version: String
    let description: String?
    let logo: URL?
    let types: [String]
    let idPrefixes: [String]?
    let resources: [ManifestResource]
    let catalogs: [ManifestCatalog]

    enum CodingKeys: String, CodingKey { case id, name, version, description, logo, types, idPrefixes, resources, catalogs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexibleString(.id) ?? UUID().uuidString
        name = c.flexibleString(.name) ?? "Addon"
        version = c.flexibleString(.version) ?? ""
        description = c.flexibleString(.description)
        logo = c.url(.logo)
        types = (try? c.decodeIfPresent([String].self, forKey: .types)) ?? []
        idPrefixes = (try? c.decodeIfPresent([String].self, forKey: .idPrefixes)) ?? nil
        resources = c.lossyArray(ManifestResource.self, .resources)
        catalogs = c.lossyArray(ManifestCatalog.self, .catalogs)
    }
}

/// A manifest resource is either a bare name ("stream") or an object with its own types and id prefixes.
struct ManifestResource: Decodable {
    let name: String
    let isShort: Bool
    let types: [String]?
    let idPrefixes: [String]?

    enum CodingKeys: String, CodingKey { case name, types, idPrefixes }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self) {
            name = s; isShort = true; types = nil; idPrefixes = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        isShort = false
        types = (try? c.decodeIfPresent([String].self, forKey: .types)) ?? nil
        idPrefixes = (try? c.decodeIfPresent([String].self, forKey: .idPrefixes)) ?? nil
    }
}

struct ManifestCatalog: Decodable, Hashable {
    let type: String
    let id: String
    let name: String?
    let requiredExtras: Set<String>
    let supportedExtras: Set<String>
    /// Values offered for the "genre" extra, if the catalog has one.
    let genres: [String]

    struct Extra: Decodable {
        let name: String
        let isRequired: Bool?
        let options: [String]?
    }

    enum CodingKeys: String, CodingKey { case type, id, name, extra, extraRequired, extraSupported }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        id = try c.decode(String.self, forKey: .id)
        name = c.flexibleString(.name)
        let extras = c.lossyArray(Extra.self, .extra)
        let legacyRequired = (try? c.decodeIfPresent([String].self, forKey: .extraRequired)) ?? nil
        let legacySupported = (try? c.decodeIfPresent([String].self, forKey: .extraSupported)) ?? nil
        var required = Set(extras.filter { $0.isRequired == true }.map(\.name))
        required.formUnion(legacyRequired ?? [])
        var supported = Set(extras.map(\.name))
        supported.formUnion(legacySupported ?? [])
        supported.formUnion(required)
        requiredExtras = required
        supportedExtras = supported
        genres = extras.first(where: { $0.name == "genre" })?.options ?? []
    }

    /// Catalogs that load with no extra parameters are the ones shown on Home.
    var isBoard: Bool { requiredExtras.isEmpty }
    var isSearchable: Bool { supportedExtras.contains("search") && requiredExtras.isSubset(of: ["search"]) }
    var supportsSkip: Bool { supportedExtras.contains("skip") }

    func hash(into hasher: inout Hasher) { hasher.combine(type); hasher.combine(id) }
    static func == (l: ManifestCatalog, r: ManifestCatalog) -> Bool { l.type == r.type && l.id == r.id }
}

// MARK: - Meta

struct MetaItem: Decodable, Identifiable, Hashable {
    let id: String
    let type: String
    let name: String
    let poster: URL?
    let background: URL?
    let logo: URL?
    let posterShape: String?
    let description: String?
    let releaseInfo: String?
    let runtime: String?
    let imdbRating: String?
    let genres: [String]
    let videos: [Video]
    let defaultVideoId: String?

    struct BehaviorHints: Decodable { let defaultVideoId: String? }

    enum CodingKeys: String, CodingKey {
        case id, type, name, poster, background, logo, posterShape, description, releaseInfo, year
        case runtime, imdbRating, genres, genre, videos, behaviorHints
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = c.flexibleString(.type) ?? "movie"
        name = c.flexibleString(.name) ?? ""
        poster = c.url(.poster)
        background = c.url(.background)
        logo = c.url(.logo)
        posterShape = c.flexibleString(.posterShape)
        description = c.flexibleString(.description)
        releaseInfo = c.flexibleString(.releaseInfo) ?? c.flexibleString(.year)
        runtime = c.flexibleString(.runtime)
        imdbRating = c.flexibleString(.imdbRating)
        let g = (try? c.decodeIfPresent([String].self, forKey: .genres)) ?? nil
        let g2 = (try? c.decodeIfPresent([String].self, forKey: .genre)) ?? nil
        genres = g ?? g2 ?? []
        videos = c.lossyArray(Video.self, .videos)
        defaultVideoId = ((try? c.decodeIfPresent(BehaviorHints.self, forKey: .behaviorHints)) ?? nil)?.defaultVideoId
    }

    init(id: String, type: String, name: String, poster: URL?, background: URL? = nil, posterShape: String? = nil) {
        self.id = id; self.type = type; self.name = name; self.poster = poster; self.background = background
        self.posterShape = posterShape
        logo = nil; description = nil; releaseInfo = nil; runtime = nil
        imdbRating = nil; genres = []; videos = []; defaultVideoId = nil
    }

    static func == (l: MetaItem, r: MetaItem) -> Bool { l.id == r.id && l.type == r.type }
    func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(type) }

    /// Height ÷ width of this item's poster, from the addon's posterShape.
    var posterAspect: CGFloat {
        switch posterShape {
        case "landscape": return 9.0 / 16.0
        case "square": return 1
        default: return 1.5
        }
    }

    /// Series and other multi-video items list their episodes in `videos`.
    var hasEpisodes: Bool { videos.count > 1 || (videos.count == 1 && videos[0].season != nil) }

    /// Videos in watch order: by season then episode, specials (season 0) last.
    var sortedVideos: [Video] {
        videos.sorted { a, b in
            let sa = a.season ?? 0, sb = b.season ?? 0
            if (sa == 0) != (sb == 0) { return sb == 0 }
            if sa != sb { return sa < sb }
            let ea = a.episode ?? 0, eb = b.episode ?? 0
            if ea != eb { return ea < eb }
            return (a.releasedDate ?? .distantPast) < (b.releasedDate ?? .distantPast)
        }
    }

    var seasons: [Int] {
        let all = Set(videos.compactMap(\.season))
        let regular = all.filter { $0 > 0 }.sorted()
        return all.contains(0) ? regular + [0] : regular
    }

    func video(after videoId: String) -> Video? {
        let list = sortedVideos
        guard let idx = list.firstIndex(where: { $0.id == videoId }), idx + 1 < list.count else { return nil }
        let next = list[idx + 1]
        // Don't roll from the last regular episode into specials.
        if (list[idx].season ?? 0) > 0 && (next.season ?? 0) == 0 { return nil }
        return next
    }

    /// The video id to request streams for when the item has no episodes.
    var playableVideoId: String { defaultVideoId ?? id }

    /// Wide artwork: the addon's background, or Stremio's image service for IMDb titles.
    var backdrop: URL? {
        if let background { return background }
        let base = id.split(separator: ":").first.map(String.init) ?? id
        return base.hasPrefix("tt") ? URL(string: "https://images.metahub.space/background/medium/\(base)/img") : nil
    }

    var year: String? {
        guard let r = releaseInfo, !r.isEmpty else { return nil }
        return r
    }
}

struct Video: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let season: Int?
    let episode: Int?
    let released: String?
    let thumbnail: URL?
    let overview: String?

    enum CodingKeys: String, CodingKey { case id, title, name, season, episode, number, released, thumbnail, overview, description }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = c.flexibleString(.title) ?? c.flexibleString(.name) ?? ""
        season = c.flexibleInt(.season)
        episode = c.flexibleInt(.episode) ?? c.flexibleInt(.number)
        released = c.flexibleString(.released)
        thumbnail = c.url(.thumbnail)
        overview = c.flexibleString(.overview) ?? c.flexibleString(.description)
    }

    var releasedDate: Date? { released.flatMap(ISODate.parse) }

    var episodeLabel: String {
        switch (season, episode) {
        case let (s?, e?): return s == 0 ? "Special \(e)" : "S\(s) · E\(e)"
        case let (nil, e?): return "Episode \(e)"
        default: return title
        }
    }

    var isUpcoming: Bool { (releasedDate ?? .distantPast) > Date() }
}

// MARK: - Streams & subtitles

struct StreamItem: Decodable, Identifiable, Hashable {
    let id = UUID()
    let url: URL?
    let ytId: String?
    let infoHash: String?
    let externalUrl: URL?
    let name: String?
    let title: String?
    let description: String?
    let filename: String?
    let videoSize: Int64?
    let notWebReady: Bool
    let requestHeaders: [String: String]

    struct Hints: Decodable {
        let filename: String?
        let videoSize: Int64?
        let notWebReady: Bool?
        let proxyHeaders: ProxyHeaders?
    }
    struct ProxyHeaders: Decodable { let request: [String: String]? }

    enum CodingKeys: String, CodingKey { case url, ytId, infoHash, externalUrl, name, title, description, behaviorHints }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = c.url(.url)
        ytId = c.flexibleString(.ytId)
        infoHash = c.flexibleString(.infoHash)
        externalUrl = c.url(.externalUrl)
        name = c.flexibleString(.name)
        title = c.flexibleString(.title)
        description = c.flexibleString(.description)
        let hints = (try? c.decodeIfPresent(Hints.self, forKey: .behaviorHints)) ?? nil
        filename = hints?.filename
        videoSize = hints?.videoSize
        notWebReady = hints?.notWebReady ?? false
        requestHeaders = hints?.proxyHeaders?.request ?? [:]
    }

    static func == (l: StreamItem, r: StreamItem) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// The text block addons put under the stream name (Torrentio puts the file name, size and source here).
    var details: String { (description ?? title ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    var isPlayableInApp: Bool { url != nil }

    var playURL: URL? {
        if let url { return url }
        return nil
    }

    var openURL: URL? {
        if let externalUrl { return externalUrl }
        if let ytId { return URL(string: "https://www.youtube.com/watch?v=\(ytId)") }
        return nil
    }
}

struct AddonSubtitle: Decodable, Hashable {
    let id: String
    let url: URL
    let lang: String

    enum CodingKeys: String, CodingKey { case id, url, lang }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let u = c.url(.url) else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "missing url")
        }
        url = u
        id = c.flexibleString(.id) ?? u.absoluteString
        lang = c.flexibleString(.lang) ?? "und"
    }
}

// MARK: - Responses

struct CatalogResponse: Decodable {
    let metas: [MetaItem]
    enum CodingKeys: String, CodingKey { case metas }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metas = c.lossyArray(MetaItem.self, .metas)
    }
}

struct MetaResponse: Decodable {
    let meta: MetaItem?
    enum CodingKeys: String, CodingKey { case meta }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meta = (try? c.decodeIfPresent(MetaItem.self, forKey: .meta)) ?? nil
    }
}

struct StreamsResponse: Decodable {
    let streams: [StreamItem]
    enum CodingKeys: String, CodingKey { case streams }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        streams = c.lossyArray(StreamItem.self, .streams)
    }
}

struct SubtitlesResponse: Decodable {
    let subtitles: [AddonSubtitle]
    enum CodingKeys: String, CodingKey { case subtitles }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subtitles = c.lossyArray(AddonSubtitle.self, .subtitles)
    }
}

// MARK: - Dates

enum ISODate {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ s: String) -> Date? {
        fractional.date(from: s) ?? plain.date(from: s)
    }

    /// Same shape stremio-core writes: 2026-11-15T18:40:12.345Z
    static func string(_ date: Date) -> String {
        fractional.string(from: date)
    }
}
