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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        RowHeader(title: section.catalog.title(addonName: section.addon.manifest.name))
                            .padding(.horizontal, sizing.hPad)
                        PosterRow(items: section.items)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.background)
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
        .navigationTitle("Search")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Movies, series…")
        .autocorrectionDisabled()
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
    @State private var importing = false

    private var items: [LibraryEntry] {
        model.savedLibrary.filter { filter == "all" || $0.type == filter }
    }

    var body: some View {
        ScrollView {
            Picker("Type", selection: $filter) {
                Text("All").tag("all")
                Text("Movies").tag("movie")
                Text("Series").tag("series")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, sizing.hPad)
            .padding(.bottom, 8)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: sizing.gridMin), spacing: 14)], spacing: 18) {
                ForEach(items) { entry in
                    NavigationLink(value: Route.meta(entry.asMeta)) {
                        PosterCard(meta: entry.asMeta, width: sizing.gridMin, showTitle: true)
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
        }
        .background(Theme.background)
        .overlay {
            if items.isEmpty && !model.isRefreshing {
                EmptyStateView(symbol: "books.vertical", title: "Nothing saved yet",
                               message: "Tap + on any movie or series to save it here.")
            }
        }
        .navigationTitle("Library")
        .refreshable { await model.refreshLibrary() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    importing = true
                } label: {
                    Label("Play a File", systemImage: "folder")
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .audiovisualContent, .data]) { result in
            if case let .success(url) = result {
                PlayerPresenter.shared.playLocalFile(url)
            }
        }
    }
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

    private var source: (AddonDescriptor, ManifestCatalog)? {
        guard let addon = model.addons.first(where: { $0.transportUrl == addonUrl }),
              let cat = addon.manifest.catalogs.first(where: { $0.type == type && $0.id == catalogId }) else { return nil }
        return (addon, cat)
    }

    private var genres: [String] { source?.1.genres ?? [] }

    var body: some View {
        ScrollView {
            if !genres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        genreButton(nil, label: "All")
                        ForEach(genres, id: \.self) { g in genreButton(g, label: g) }
                    }
                    .padding(.horizontal, sizing.hPad)
                }
                .padding(.bottom, 6)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: sizing.gridMin), spacing: 14)], spacing: 18) {
                ForEach(items) { meta in
                    NavigationLink(value: Route.meta(meta)) {
                        PosterCard(meta: meta, width: sizing.gridMin)
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
        .task(id: genre) {
            items = []
            reachedEnd = false
            await loadMore()
        }
    }

    private func genreButton(_ value: String?, label: String) -> some View {
        Button {
            genre = value
        } label: {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .foregroundStyle(genre == value ? Color.black : Color.primary)
                .background(genre == value ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.1)), in: Capsule())
        }
        .buttonStyle(.plain)
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
        let page = (try? await AddonClient.catalog(addon, cat, extra: extra)) ?? []
        let known = Set(items.map(\.id))
        let fresh = page.filter { !known.contains($0.id) }
        if fresh.isEmpty { reachedEnd = true }
        items.append(contentsOf: fresh)
    }
}
