import SwiftUI

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
            .scrollsToTopOnReselect()
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
