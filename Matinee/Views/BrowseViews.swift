import SwiftUI
import UniformTypeIdentifiers

// MARK: - Search

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sizing) private var sizing
    @State private var query = ""
    @State private var sections: [AddonClient.SearchSection] = []
    @State private var searching = false
    @State private var searchedFor = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search movies, series…", text: $query)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Theme.pill, in: Capsule())
            .padding(.horizontal, sizing.hPad)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            RowHeader(title: section.catalog.title(addonName: section.addon.manifest.name))
                                .padding(.horizontal, sizing.hPad)
                            PosterRow(items: section.items)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay {
                if searching && sections.isEmpty {
                    ProgressView()
                } else if query.isEmpty {
                    EmptyStateView(symbol: "magnifyingglass", title: "Search",
                                   message: "Find movies and series across all your addons.")
                } else if !searching && sections.isEmpty && searchedFor == query {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .background(Theme.background)
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard q.count >= 2 else { sections = []; return }
            try? await Task.sleep(for: .milliseconds(400))
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

// MARK: - Library

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sizing) private var sizing
    @State private var filter = "all"
    @State private var sort = "Last watched"
    @State private var sheet: String?
    @State private var importing = false

    private let sorts = ["Last watched", "Recently added", "A–Z"]

    private var types: [String] {
        var seen: [String] = []
        for e in model.savedLibrary where !seen.contains(e.type) { seen.append(e.type) }
        return seen
    }

    private var items: [LibraryEntry] {
        let list = model.savedLibrary.filter { filter == "all" || $0.type == filter }
        switch sort {
        case "A–Z": return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case "Recently added": return list.sorted { ($0.mtime ?? .distantPast) > ($1.mtime ?? .distantPast) }
        default: return list.sorted { $0.sortDate > $1.sortDate }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            HStack(spacing: 8) {
                FilterPill(title: filter == "all" ? "All types" : Format.typeName(filter)) { sheet = "type" }
                FilterPill(title: sort) { sheet = "sort" }
                Button {
                    importing = true
                } label: {
                    Image(systemName: "folder")
                        .font(.subheadline.weight(.medium))
                        .frame(width: 44, height: 36)
                        .background(Theme.pill, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play a file")
            }
            .padding(.horizontal, sizing.hPad)
            .padding(.bottom, 10)

            ScrollView {
                let metas = items.map(\.asMeta)
                LazyVGrid(columns: posterColumns(for: metas, sizing: sizing), spacing: 10) {
                    ForEach(items) { entry in
                        NavigationLink(value: Route.meta(entry.asMeta)) {
                            PosterCard(meta: entry.asMeta, progress: entry.progress > 0 ? entry.progress : nil)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                model.toggleLibrary(LibrarySeed(entry.asMeta))
                            } label: {
                                Label("Remove from Library", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, sizing.hPad)
                .padding(.top, 4)
            }
            .refreshable { await model.refreshLibrary() }
            .scrollsToTopOnReselect()
            .overlay {
                if items.isEmpty && !model.isRefreshing {
                    EmptyStateView(symbol: "square.stack", title: "Nothing saved yet",
                                   message: "Tap + on any movie or series to save it here.")
                }
            }
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: Binding(get: { sheet.map(SheetID.init) }, set: { sheet = $0?.id })) { which in
            if which.id == "type" {
                OptionSheet(title: "Type", options: ["All types"] + types.map(Format.typeName),
                            selected: filter == "all" ? "All types" : Format.typeName(filter)) { picked in
                    filter = types.first(where: { Format.typeName($0) == picked }) ?? "all"
                }
            } else {
                OptionSheet(title: "Sort", options: sorts, selected: sort) { sort = $0 }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .audiovisualContent, .data]) { result in
            if case let .success(url) = result {
                PlayerPresenter.shared.playLocalFile(url)
            }
        }
    }

    private struct SheetID: Identifiable { let id: String }
}

// MARK: - Catalog "See All"

struct CatalogGridView: View {
    let addonUrl: String
    let type: String
    let catalogId: String
    let title: String

    @Environment(AppModel.self) private var model
    @Environment(\.sizing) private var sizing
    @State private var items: [MetaItem] = []
    @State private var loadingMore = false
    @State private var reachedEnd = false
    @State private var genre: String?
    @State private var showGenres = false

    private let allGenres = "All genres"

    private var source: (AddonDescriptor, ManifestCatalog)? {
        guard let addon = model.addons.first(where: { $0.transportUrl == addonUrl }),
              let cat = addon.manifest.catalogs.first(where: { $0.type == type && $0.id == catalogId }) else { return nil }
        return (addon, cat)
    }

    private var genres: [String] { source?.1.genres ?? [] }

    var body: some View {
        ScrollView {
            if !genres.isEmpty {
                HStack {
                    FilterPill(title: genre ?? allGenres) { showGenres = true }
                        .frame(maxWidth: 220)
                    Spacer()
                }
                .padding(.horizontal, sizing.hPad)
                .padding(.bottom, 6)
            }

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

            if loadingMore { ProgressView().padding(30) }
        }
        .background(Theme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showGenres) {
            OptionSheet(title: "Genre", options: [allGenres] + genres, selected: genre ?? allGenres) { picked in
                genre = picked == allGenres ? nil : picked
            }
        }
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
