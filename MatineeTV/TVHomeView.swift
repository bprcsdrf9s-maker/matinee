import SwiftUI

/// Home: the focused title's art fills the screen behind Continue Watching and a row per addon catalog.
struct TVHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var home = HomeModel()
    @State private var recs = RecommendationsModel()
    @State private var focused: MetaItem?
    @State private var hero: MetaItem?
    @AppStorage(TMDB.keyVersionDefaultsKey) private var tmdbKeyVersion = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TVSize.rowSpacing) {
                heroInfo

                if !model.continueWatching.isEmpty {
                    continueRow
                }

                ForEach(recs.leadingRows) { row in
                    TVPosterRow(title: row.title, items: row.items, onFocus: { focused = $0 })
                }

                if !model.savedLibrary.isEmpty {
                    TVPosterRow(title: "My List", items: model.savedLibrary.prefix(30).map(\.asMeta), onFocus: { focused = $0 })
                }

                ForEach(recs.trailingRows) { row in
                    TVPosterRow(title: row.title, items: row.items, onFocus: { focused = $0 })
                }

                ForEach(home.rows) { row in
                    TVPosterRow(
                        title: row.title,
                        items: row.items,
                        seeAll: .catalog(addonUrl: row.addon.transportUrl, type: row.catalog.type,
                                         id: row.catalog.id, title: row.title),
                        onFocus: { focused = $0 }
                    )
                }

                if home.loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                } else if home.rows.isEmpty && model.continueWatching.isEmpty && recs.leadingRows.isEmpty {
                    if let error = model.errorMessage {
                        EmptyStateView(symbol: "wifi.exclamationmark", title: "Couldn't load", message: error)
                    } else if !model.addons.isEmpty {
                        EmptyStateView(symbol: "square.stack.3d.up.slash", title: "No catalogs",
                                       message: "None of your addons have catalogs. Add Cinemeta in Stremio.")
                    }
                }
            }
            .padding(.bottom, 60)
        }
        .background { TVBackdrop(meta: hero) }
        .task(id: model.addons.map(\.transportUrl)) {
            await home.load(model.boardCatalogs)
            if hero == nil { hero = home.rows.first?.items.first }
        }
        .task(id: "\(model.activeProfileId ?? "")|\(model.library.count)|\(tmdbKeyVersion)") {
            await recs.load(library: model.library, profileId: model.activeProfileId)
            if focused == nil, let pick = recs.heroCandidates.randomElement() { hero = pick }
        }
        .task(id: focused?.id) {
            // Wait for focus to settle so quick scrolling doesn't flash every backdrop.
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            hero = focused
        }
        .onAppear {
            if hero == nil {
                hero = recs.heroCandidates.first ?? model.continueWatching.first?.asMeta ?? home.rows.first?.items.first
            }
        }
    }

    // MARK: Focused title

    private var heroInfo: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let hero {
                if let logo = hero.logo {
                    RemoteImage(url: logo, contentMode: .fit)
                        .frame(maxWidth: 560, maxHeight: 160, alignment: .leading)
                } else {
                    Text(hero.name)
                        .font(.system(size: 64, weight: .heavy))
                        .lineLimit(2)
                }
                let line = TVText.metaLine(hero)
                if !line.isEmpty {
                    Text(line).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                }
                if let d = hero.description, !d.isEmpty {
                    Text(d)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 330, alignment: .bottomLeading)
        .animation(.easeInOut(duration: 0.3), value: hero?.id)
    }

    // MARK: Continue Watching

    private var continueRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Continue Watching").font(.title3.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: TVSize.itemSpacing) {
                    ForEach(model.continueWatching) { entry in
                        TVContinueCard(entry: entry) { focused = $0 }
                    }
                }
                .padding(.vertical, 36)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

/// A wide card for Continue Watching: the title's art with a progress bar, the episode underneath.
struct TVContinueCard: View {
    let entry: LibraryEntry
    var onFocus: (MetaItem) -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        let meta = entry.asMeta
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: TVRoute.meta(meta, autoplayVideoId: entry.videoId ?? entry.id)) {
                ContinueArt(meta: meta, progress: entry.progress, onFocus: onFocus)
            }
            .buttonStyle(.card)
            .contextMenu {
                NavigationLink(value: TVRoute.meta(meta)) {
                    Label("Details", systemImage: "info.circle")
                }
                Button(role: .destructive) {
                    model.dismissFromContinueWatching(entry)
                } label: {
                    Label("Remove from Continue Watching", systemImage: "eye.slash")
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(meta.name).font(.caption.weight(.semibold)).lineLimit(1)
                if let ep = TVText.episodeLabel(videoId: entry.videoId) {
                    Text(ep).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: TVSize.landscapeWidth, alignment: .leading)
        }
    }

    private struct ContinueArt: View {
        let meta: MetaItem
        let progress: Double
        let onFocus: (MetaItem) -> Void
        @Environment(\.isFocused) private var focused

        var body: some View {
            Color.clear
                .frame(width: TVSize.landscapeWidth, height: TVSize.landscapeWidth * 9 / 16)
                .overlay { RemoteImage(url: meta.backdrop ?? meta.poster, placeholderText: meta.name, fallback: meta.poster) }
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                }
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 12) {
                        Image(systemName: "play.fill").font(.callout)
                        if progress > 0 { ProgressLine(value: progress) }
                    }
                    .padding(16)
                }
                .onChange(of: focused) { _, isFocused in
                    if isFocused { onFocus(meta) }
                }
        }
    }
}
