import SwiftUI

// MARK: - Search

struct TVSearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var sections: [AddonClient.SearchSection] = []
    @State private var searching = false
    @State private var searchedFor = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TVSize.rowSpacing) {
                ForEach(sections) { section in
                    TVPosterRow(title: section.catalog.title(addonName: section.addon.manifest.name),
                                items: section.items)
                }
            }
            .padding(.bottom, 60)
        }
        .searchable(text: $query, prompt: "Movies, series, channels")
        .overlay {
            if searching && sections.isEmpty {
                ProgressView()
            } else if !query.isEmpty && !searching && sections.isEmpty && searchedFor == query {
                ContentUnavailableView.search(text: query)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard q.count >= 2 else { sections = []; return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            searching = true
            let results = await AddonClient.search(q, addons: model.addons)
            guard !Task.isCancelled else { return }
            sections = results
            searchedFor = query
            searching = false
        }
    }
}

// MARK: - Discover

/// Browse any addon catalog with Type, Catalog and Genre menus over a poster grid.
struct TVDiscoverView: View {
    @Environment(AppModel.self) private var model

    @State private var type: String?
    @State private var catalogKey: String?
    @State private var genre: String?
    @State private var items: [MetaItem] = []
    @State private var loading = false
    @State private var reachedEnd = false
    /// Bumped on every reload so pages from an older filter choice are dropped.
    @State private var generation = 0

    private struct Source {
        let addon: AddonDescriptor
        let catalog: ManifestCatalog
        var key: String { addon.transportUrl + "|" + catalog.type + "|" + catalog.id }
    }

    private let allGenres = "All Genres"

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
    private var catalogsForType: [Source] { sources.filter { $0.catalog.type == currentType } }

    private var currentSource: Source? {
        let list = catalogsForType
        return list.first { $0.key == catalogKey } ?? list.first
    }

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if sources.isEmpty {
                    if model.addons.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 200)
                    } else {
                        EmptyStateView(symbol: "square.grid.3x3", title: "Nothing to discover",
                                       message: "None of your addons have browsable catalogs. Add Cinemeta in Stremio.")
                    }
                } else {
                    filters
                    TVPosterGrid(items: items, onLastAppear: { Task { await loadMore() } })
                    if loading {
                        ProgressView().frame(maxWidth: .infinity).padding(30)
                    } else if items.isEmpty && reachedEnd {
                        EmptyStateView(symbol: "film.stack", title: "Nothing here",
                                       message: "This catalog didn't return anything.")
                    }
                }
            }
            .padding(.bottom, 60)
        }
        .background(Theme.background.ignoresSafeArea())
        .task(id: "\(currentSource?.key ?? "")|\(currentGenre ?? "")") {
            await reload()
        }
    }

    private var filters: some View {
        HStack(spacing: 30) {
            Menu {
                ForEach(types, id: \.self) { t in
                    Button(Format.typeName(t)) {
                        if t != currentType { type = t; catalogKey = nil; genre = nil }
                    }
                }
            } label: {
                TVMenuLabel(title: currentType.map(Format.typeName) ?? "Type")
            }

            Menu {
                ForEach(catalogsForType, id: \.key) { s in
                    Button(label(s)) {
                        if s.key != currentSource?.key { catalogKey = s.key; genre = nil }
                    }
                }
            } label: {
                TVMenuLabel(title: currentSource.map(label) ?? "Catalog")
            }

            let genres = currentSource?.catalog.genres ?? []
            if !genres.isEmpty {
                Menu {
                    if !genreRequired {
                        Button(allGenres) { genre = nil }
                    }
                    ForEach(genres, id: \.self) { g in
                        Button(g) { genre = g }
                    }
                } label: {
                    TVMenuLabel(title: currentGenre ?? allGenres)
                }
            }
            Spacer()
        }
        .focusSection()
    }

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
        guard gen == generation else { return }
        let known = Set(items.map(\.id))
        let fresh = page.filter { !known.contains($0.id) }
        if fresh.isEmpty { reachedEnd = true }
        items.append(contentsOf: fresh)
    }
}

/// A grid of posters that asks for more when its last poster appears.
struct TVPosterGrid: View {
    let items: [MetaItem]
    var onLastAppear: (() -> Void)? = nil

    var body: some View {
        LazyVGrid(columns: tvPosterColumns(for: items), spacing: 60) {
            ForEach(items) { meta in
                TVPosterLink(meta: meta)
                    .onAppear {
                        if meta == items.last { onLastAppear?() }
                    }
            }
        }
        .padding(.vertical, 20)
        .focusSection()
    }
}

// MARK: - Library

struct TVLibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = "all"
    @State private var sort = "Last Watched"

    private let sorts = ["Last Watched", "Recently Added", "A–Z"]

    private var types: [String] {
        var seen: [String] = []
        for e in model.savedLibrary where !seen.contains(e.type) { seen.append(e.type) }
        return seen
    }

    private var items: [LibraryEntry] {
        let list = model.savedLibrary.filter { filter == "all" || $0.type == filter }
        switch sort {
        case "A–Z": return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case "Recently Added": return list.sorted { ($0.mtime ?? .distantPast) > ($1.mtime ?? .distantPast) }
        default: return list.sorted { $0.sortDate > $1.sortDate }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 30) {
                    Menu {
                        Button("All Types") { filter = "all" }
                        ForEach(types, id: \.self) { t in
                            Button(Format.typeName(t)) { filter = t }
                        }
                    } label: {
                        TVMenuLabel(title: filter == "all" ? "All Types" : Format.typeName(filter))
                    }
                    Menu {
                        ForEach(sorts, id: \.self) { s in
                            Button(s) { sort = s }
                        }
                    } label: {
                        TVMenuLabel(title: sort)
                    }
                    Spacer()
                }
                .focusSection()

                let metas = items.map(\.asMeta)
                LazyVGrid(columns: tvPosterColumns(for: metas), spacing: 60) {
                    ForEach(items) { entry in
                        TVPosterLink(meta: entry.asMeta, progress: entry.progress > 0 ? entry.progress : nil)
                            .contextMenu {
                                Button(role: .destructive) {
                                    model.toggleLibrary(LibrarySeed(entry.asMeta))
                                } label: {
                                    Label("Remove from Library", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(.vertical, 20)
                .focusSection()

                if items.isEmpty && !model.isRefreshing {
                    EmptyStateView(symbol: "square.stack", title: "Nothing saved yet",
                                   message: "Choose Add to Library on any movie or series to save it here.")
                }
            }
            .padding(.bottom, 60)
        }
        .background(Theme.background.ignoresSafeArea())
        .task { await model.refreshLibrary() }
    }
}

// MARK: - Catalog "See All"

struct TVCatalogGridView: View {
    let addonUrl: String
    let type: String
    let catalogId: String
    let title: String

    @Environment(AppModel.self) private var model
    @State private var items: [MetaItem] = []
    @State private var loadingMore = false
    @State private var reachedEnd = false
    @State private var genre: String?

    private let allGenres = "All Genres"

    private var source: (AddonDescriptor, ManifestCatalog)? {
        guard let addon = model.addons.first(where: { $0.transportUrl == addonUrl }),
              let cat = addon.manifest.catalogs.first(where: { $0.type == type && $0.id == catalogId }) else { return nil }
        return (addon, cat)
    }

    private var genres: [String] { source?.1.genres ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 30) {
                    Text(title).font(.title2.weight(.bold)).lineLimit(1)
                    if !genres.isEmpty {
                        Menu {
                            Button(allGenres) { genre = nil }
                            ForEach(genres, id: \.self) { g in
                                Button(g) { genre = g }
                            }
                        } label: {
                            TVMenuLabel(title: genre ?? allGenres)
                        }
                    }
                    Spacer()
                }
                .focusSection()

                TVPosterGrid(items: items, onLastAppear: { Task { await loadMore() } })
                if loadingMore { ProgressView().frame(maxWidth: .infinity).padding(30) }
            }
            .padding(.bottom, 60)
        }
        .background(Theme.background.ignoresSafeArea())
        .task(id: genre) {
            items = []
            reachedEnd = false
            loadingMore = false
            await loadMore()
        }
    }

    private func loadMore() async {
        guard !loadingMore, !reachedEnd, case let (addon, cat)? = source else { return }
        loadingMore = true
        defer { loadingMore = false }
        var extra: [(String, String)] = []
        if let genre { extra.append(("genre", genre)) }
        if !items.isEmpty {
            guard cat.supportsSkip else { reachedEnd = true; return }
            extra.append(("skip", String(items.count)))
        }
        let requested = genre
        let page = (try? await AddonClient.catalog(addon, cat, extra: extra)) ?? []
        guard requested == genre else { return }
        let known = Set(items.map(\.id))
        let fresh = page.filter { !known.contains($0.id) }
        if fresh.isEmpty { reachedEnd = true }
        items.append(contentsOf: fresh)
    }
}
