import SwiftUI

@MainActor
@Observable
final class HomeModel {
    struct Row: Identifiable {
        let addon: AddonDescriptor
        let catalog: ManifestCatalog
        var items: [MetaItem]
        var id: String { addon.transportUrl + "|" + catalog.type + "|" + catalog.id }
        var title: String { catalog.title(addonName: addon.manifest.name) }
    }

    private(set) var rows: [Row] = []
    private(set) var loading = false
    @ObservationIgnored private var loadedKey = ""

    func load(_ boards: [(addon: AddonDescriptor, catalog: ManifestCatalog)], force: Bool = false) async {
        let key = boards.map { $0.addon.transportUrl + $0.catalog.id + $0.catalog.type }.joined()
        guard force || key != loadedKey, !boards.isEmpty else { return }
        loadedKey = key
        loading = rows.isEmpty
        let results = await withTaskGroup(of: (Int, [MetaItem]).self) { group in
            for (i, board) in boards.enumerated() {
                group.addTask {
                    let items = (try? await AddonClient.catalog(board.addon, board.catalog)) ?? []
                    return (i, items)
                }
            }
            var out: [(Int, [MetaItem])] = []
            for await r in group { out.append(r) }
            return out
        }
        let byIndex = Dictionary(uniqueKeysWithValues: results)
        rows = boards.enumerated().compactMap { i, board in
            guard let items = byIndex[i], !items.isEmpty else { return nil }
            return Row(addon: board.addon, catalog: board.catalog, items: items)
        }
        loading = false
    }
}

/// The Board: Continue Watching, then a row per addon catalog.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sizing) private var sizing
    @State private var home = HomeModel()

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if !model.continueWatching.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            RowHeader(title: "Continue Watching").padding(.horizontal, sizing.hPad)
                            continueRow
                        }
                    }

                    ForEach(home.rows) { row in
                        VStack(alignment: .leading, spacing: 10) {
                            RowHeader(title: row.title,
                                      destination: .catalog(addonUrl: row.addon.transportUrl, type: row.catalog.type,
                                                            id: row.catalog.id, title: row.title))
                                .padding(.horizontal, sizing.hPad)
                            PosterRow(items: row.items)
                        }
                    }

                    if home.loading {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                    } else if home.rows.isEmpty && model.continueWatching.isEmpty {
                        if let error = model.errorMessage {
                            EmptyStateView(symbol: "wifi.exclamationmark", title: "Couldn't load", message: error)
                        } else if !model.addons.isEmpty {
                            EmptyStateView(symbol: "square.stack.3d.up.slash", title: "No catalogs",
                                           message: "None of your addons have catalogs. Add Cinemeta in Stremio to fill the Board.")
                        }
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
            .refreshable {
                await model.refresh()
                await home.load(model.boardCatalogs, force: true)
            }
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: model.addons.map(\.transportUrl)) {
            await home.load(model.boardCatalogs)
        }
    }

    private var continueRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 10) {
                ForEach(model.continueWatching) { entry in
                    NavigationLink(value: Route.meta(entry.asMeta, autoplayVideoId: entry.videoId ?? entry.id)) {
                        let meta = entry.asMeta
                        PosterCard(meta: meta,
                                   width: meta.posterShape == "landscape" ? sizing.landscapeWidth : sizing.posterWidth,
                                   progress: entry.progress > 0 ? entry.progress : nil)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        NavigationLink(value: Route.meta(entry.asMeta)) {
                            Label("Details", systemImage: "info.circle")
                        }
                        Button(role: .destructive) {
                            model.dismissFromContinueWatching(entry)
                        } label: {
                            Label("Remove from Continue Watching", systemImage: "eye.slash")
                        }
                    }
                }
            }
            .padding(.horizontal, sizing.hPad)
        }
        .scrollClipDisabled()
    }
}
