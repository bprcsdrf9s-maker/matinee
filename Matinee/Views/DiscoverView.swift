import SwiftUI

/// Browse any addon catalog: Type, Catalog and Genre pills over a poster grid, like Stremio's Discover.
struct DiscoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sizing) private var sizing

    @State private var type: String?
    @State private var catalogKey: String?
    @State private var genre: String?
    @State private var items: [MetaItem] = []
    @State private var loading = false
    @State private var reachedEnd = false
    @State private var sheet: FilterKind?
    /// Bumped on every reload so pages from an older filter choice are dropped.
    @State private var generation = 0

    private enum FilterKind: String, Identifiable {
        case type, catalog, genre
        var id: String { rawValue }
    }

    private struct Source {
        let addon: AddonDescriptor
        let catalog: ManifestCatalog
        var key: String { addon.transportUrl + "|" + catalog.type + "|" + catalog.id }
    }

    // MARK: Options

    /// Catalogs Discover can show: ones that need nothing, or only a genre.
    private var sources: [Source] {
        model.addons.flatMap { addon in
            addon.manifest.catalogs
                .filter { $0.requiredExtras.isSubset(of: ["genre"]) && !($0.requiredExtras.contains("genre") && $0.genres.isEmpty) }
                .map { Source(addon: addon, catalog: $0) }
        }
    }

    private var types: [String] {
        var seen: [String] = []
        for s in sources where !seen.contains(s.catalog.type) { seen.append(s.catalog.type) }
        let order = ["movie", "series"]
        return seen.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? Int.max, ib = order.firstIndex(of: b) ?? Int.max
            return ia != ib ? ia < ib : false
        }
    }

    private var currentType: String? { type ?? types.first }

    private var catalogsForType: [Source] {
        sources.filter { $0.catalog.type == currentType }
    }

    private var currentSource: Source? {
        let list = catalogsForType
        return list.first { $0.key == catalogKey } ?? list.first
    }

    /// Picker labels; the addon name is added when two catalogs share a name.
    private func label(_ s: Source) -> String {
        let name = s.catalog.pickerName(addonName: s.addon.manifest.name)
        let dupes = catalogsForType.filter { $0.catalog.pickerName(addonName: $0.addon.manifest.name) == name }.count
        return dupes > 1 ? "\(name) (\(s.addon.manifest.name))" : name
    }

    private var genreRequired: Bool { currentSource?.catalog.requiredExtras.contains("genre") ?? false }

    private var currentGenre: String? {
        if let genre { return genre }
        return genreRequired ? currentSource?.catalog.genres.first : nil
    }

    private let allGenres = "All genres"

    // MARK: View

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            if sources.isEmpty {
                Spacer()
                if model.addons.isEmpty {
                    ProgressView()
                } else {
                    EmptyStateView(symbol: "square.grid.3x3", title: "Nothing to discover",
                                   message: "None of your addons have browsable catalogs. Add Cinemeta in Stremio.")
                }
                Spacer()
            } else {
                filters
                ScrollView {
                    LazyVGrid(columns: posterColumns(for: items, sizing: sizing), spacing: 10) {
                        ForEach(items) { meta in
                            NavigationLink(value: Route.meta(meta)) {
                                PosterCard(meta: meta)
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                if meta == items.last { Task { await loadMore() } }
                            }
                        }
                    }
                    .padding(.horizontal, sizing.hPad)
                    .padding(.top, 4)

                    if loading {
                        ProgressView().padding(30)
                    } else if items.isEmpty && reachedEnd {
                        EmptyStateView(symbol: "film.stack", title: "Nothing here",
                                       message: "This catalog didn't return anything.")
                            .padding(.top, 40)
                    }
                }
                .refreshable { await reload() }
                .scrollsToTopOnReselect()
            }
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $sheet) { which in
            switch which {
            case .type:
                OptionSheet(title: "Type", options: types.map(Format.typeName),
                            selected: currentType.map(Format.typeName) ?? "") { picked in
                    if let t = types.first(where: { Format.typeName($0) == picked }), t != currentType {
                        type = t
                        catalogKey = nil
                        genre = nil
                    }
                }
            case .catalog:
                let list = catalogsForType
                OptionSheet(title: "Catalog", options: list.map(label),
                            selected: currentSource.map(label) ?? "") { picked in
                    if let s = list.first(where: { label($0) == picked }), s.key != currentSource?.key {
                        catalogKey = s.key
                        genre = nil
                    }
                }
            case .genre:
                let genres = currentSource?.catalog.genres ?? []
                OptionSheet(title: "Genre", options: genreRequired ? genres : [allGenres] + genres,
                            selected: currentGenre ?? allGenres) { picked in
                    genre = picked == allGenres ? nil : picked
                }
            }
        }
        .task(id: "\(currentSource?.key ?? "")|\(currentGenre ?? "")") {
            await reload()
        }
    }

    private var filters: some View {
        HStack(spacing: 8) {
            FilterPill(title: currentType.map(Format.typeName) ?? "Type") { sheet = .type }
            FilterPill(title: currentSource.map(label) ?? "Catalog") { sheet = .catalog }
            if !(currentSource?.catalog.genres.isEmpty ?? true) {
                FilterPill(title: currentGenre ?? allGenres) { sheet = .genre }
            }
        }
        .padding(.horizontal, sizing.hPad)
        .padding(.bottom, 10)
    }

    // MARK: Loading

    private func reload() async {
        generation += 1
        items = []
        reachedEnd = false
        loading = false
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, !reachedEnd, let source = currentSource else { return }
        loading = true
        defer { loading = false }
        var extra: [(String, String)] = []
        if let g = currentGenre { extra.append(("genre", g)) }
        if !items.isEmpty {
            guard source.catalog.supportsSkip else { reachedEnd = true; return }
            extra.append(("skip", String(items.count)))
        }
        let gen = generation
        let page = (try? await AddonClient.catalog(source.addon, source.catalog, extra: extra)) ?? []
        // Drop the page if the filters changed while it loaded.
        guard gen == generation else { return }
        let known = Set(items.map(\.id))
        let fresh = page.filter { !known.contains($0.id) }
        if fresh.isEmpty { reachedEnd = true }
        items.append(contentsOf: fresh)
    }
}
