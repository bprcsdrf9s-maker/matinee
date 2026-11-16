import Foundation

/// Talks to addons over the HTTP addon protocol, building URLs exactly like stremio-core's
/// AddonHTTPTransport: <base>/<resource>/<type>/<id>[/<extra>].json, every part percent-encoded.
enum AddonClient {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config)
    }()

    // Same set as stremio-core's URI_COMPONENT_ENCODE_SET (like JS encodeURIComponent).
    private static let componentAllowed: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()")
        return set
    }()

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: componentAllowed) ?? s
    }

    static func resourceURL(_ addon: AddonDescriptor, resource: String, type: String, id: String,
                            extra: [(String, String)] = []) -> URL? {
        let transport = addon.transportUrl
        guard let range = transport.range(of: "/manifest.json", options: .backwards) else { return nil }
        var path = "/\(encode(resource))/\(encode(type))/\(encode(id))"
        if !extra.isEmpty {
            path += "/" + extra.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
        }
        path += ".json"
        return URL(string: transport.replacingCharacters(in: range, with: path))
    }

    static func fetch<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Catalogs

    static func catalog(_ addon: AddonDescriptor, _ catalog: ManifestCatalog,
                        extra: [(String, String)] = []) async throws -> [MetaItem] {
        guard let url = resourceURL(addon, resource: "catalog", type: catalog.type, id: catalog.id, extra: extra) else {
            return []
        }
        return try await fetch(CatalogResponse.self, from: url).metas
    }

    // MARK: Meta

    /// Asks each addon that serves meta for this id, in addon order, and returns the first answer.
    static func meta(addons: [AddonDescriptor], type: String, id: String) async -> MetaItem? {
        for addon in addons where addon.supports(resource: "meta", type: type, id: id) {
            guard let url = resourceURL(addon, resource: "meta", type: type, id: id) else { continue }
            if let meta = try? await fetch(MetaResponse.self, from: url).meta { return meta }
        }
        return nil
    }

    // MARK: Streams

    struct StreamGroup: Identifiable {
        let addon: AddonDescriptor
        var streams: [StreamItem]
        var failed: Bool
        var id: String { addon.transportUrl }
    }

    static func streamAddons(_ addons: [AddonDescriptor], type: String, videoId: String) -> [AddonDescriptor] {
        addons.filter { $0.supports(resource: "stream", type: type, id: videoId) }
    }

    static func streams(_ addon: AddonDescriptor, type: String, videoId: String) async throws -> [StreamItem] {
        guard let url = resourceURL(addon, resource: "stream", type: type, id: videoId) else { return [] }
        return try await fetch(StreamsResponse.self, from: url).streams
    }

    // MARK: Subtitles

    static func subtitles(addons: [AddonDescriptor], type: String, videoId: String,
                          filename: String?, videoSize: Int64?) async -> [AddonSubtitle] {
        var extra: [(String, String)] = []
        if let videoSize { extra.append(("videoSize", String(videoSize))) }
        if let filename { extra.append(("filename", filename)) }
        let targets = addons.filter { $0.supports(resource: "subtitles", type: type, id: videoId) }
        return await withTaskGroup(of: (Int, [AddonSubtitle]).self) { group in
            for (i, addon) in targets.enumerated() {
                group.addTask {
                    guard let url = resourceURL(addon, resource: "subtitles", type: type, id: videoId, extra: extra),
                          let res = try? await fetch(SubtitlesResponse.self, from: url) else { return (i, []) }
                    return (i, res.subtitles)
                }
            }
            var results: [(Int, [AddonSubtitle])] = []
            for await r in group { results.append(r) }
            return results.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }

    // MARK: Search

    struct SearchSection: Identifiable {
        let addon: AddonDescriptor
        let catalog: ManifestCatalog
        let items: [MetaItem]
        var id: String { addon.transportUrl + "|" + catalog.type + "|" + catalog.id }
    }

    static func search(_ query: String, addons: [AddonDescriptor]) async -> [SearchSection] {
        var targets: [(Int, AddonDescriptor, ManifestCatalog)] = []
        for addon in addons {
            for cat in addon.manifest.catalogs where cat.isSearchable {
                targets.append((targets.count, addon, cat))
            }
        }
        return await withTaskGroup(of: (Int, SearchSection?).self) { group in
            for (i, addon, cat) in targets {
                group.addTask {
                    guard let items = try? await catalog(addon, cat, extra: [("search", query)]), !items.isEmpty else {
                        return (i, nil)
                    }
                    return (i, SearchSection(addon: addon, catalog: cat, items: items))
                }
            }
            var results: [(Int, SearchSection?)] = []
            for await r in group { results.append(r) }
            return results.sorted { $0.0 < $1.0 }.compactMap(\.1)
        }
    }
}

extension ManifestCatalog {
    /// Stremio's row title: "Trending Movies - Movie".
    func title(addonName: String) -> String {
        let base = (name?.isEmpty == false ? name! : addonName)
        return "\(base) – \(Format.typeName(type))"
    }

    /// Name for the Discover catalog picker.
    func pickerName(addonName: String) -> String {
        name?.isEmpty == false ? name! : addonName
    }
}
