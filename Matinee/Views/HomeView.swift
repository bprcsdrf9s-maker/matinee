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

    /// Featured title for the banner: the first item with wide artwork.
    var hero: MetaItem? {
        rows.first?.items.first(where: { $0.backdrop != nil }) ?? rows.first?.items.first
    }
}

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sizing) private var sizing
    @State private var home = HomeModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let hero = home.hero {
                    HeroBanner(meta: hero)
                }

                if !model.continueWatching.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        RowHeader(title: "Continue Watching").padding(.horizontal, sizing.hPad)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(model.continueWatching) { entry in
                                    NavigationLink(value: Route.meta(entry.asMeta, autoplayVideoId: entry.videoId ?? entry.id)) {
                                        ContinueCard(entry: entry, width: sizing.landscapeWidth)
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

                ForEach(home.rows) { row in
                    VStack(alignment: .leading, spacing: 12) {
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
                                       message: "None of your addons have catalogs. Add Cinemeta in Stremio to fill Home.")
                    }
                }
            }
            .padding(.bottom, 30)
        }
        .background(Theme.background)
        .navigationTitle("Home")
        .toolbarTitleDisplayMode(.inlineLarge)
        .refreshable {
            await model.refresh()
            await home.load(model.boardCatalogs, force: true)
        }
        .task(id: model.addons.map(\.transportUrl)) {
            await home.load(model.boardCatalogs)
        }
    }
}

struct HeroBanner: View {
    let meta: MetaItem
    @Environment(\.sizing) private var sizing

    var body: some View {
        NavigationLink(value: Route.meta(meta)) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: meta.backdrop ?? meta.poster, fallback: meta.poster)
                    .frame(height: sizing.regular ? 380 : 240)
                    .frame(maxWidth: .infinity)
                    .clipped()
                LinearGradient(colors: [.clear, Theme.background.opacity(0.6), Theme.background],
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 8) {
                    if let logo = meta.logo {
                        RemoteImage(url: logo, contentMode: .fit)
                            .frame(maxWidth: sizing.regular ? 360 : 220, maxHeight: sizing.regular ? 110 : 70, alignment: .leading)
                    } else {
                        Text(meta.name).font(.largeTitle.weight(.heavy)).lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        Label("Featured", systemImage: "sparkles").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                        if let year = meta.year { Text(year).font(.caption).foregroundStyle(.secondary) }
                        if let rating = meta.imdbRating {
                            Label(rating, systemImage: "star.fill").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let d = meta.description {
                        Text(d).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            .frame(maxWidth: 560, alignment: .leading)
                    }
                }
                .padding(.horizontal, sizing.hPad)
                .padding(.bottom, 10)
            }
        }
        .buttonStyle(.plain)
    }
}
