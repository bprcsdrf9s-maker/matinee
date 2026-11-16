import SwiftUI

/// Home, laid out like the streaming apps: a featured title up top, then Continue Watching,
/// recommendations, My List, Trending, "Because You Watched", and a row per addon catalog.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sizing) private var sizing
    @State private var home = HomeModel()
    @State private var recs = RecommendationsModel()
    @State private var hero: MetaItem?
    @State private var heroFromRecs = false
    @AppStorage(TMDB.keyVersionDefaultsKey) private var tmdbKeyVersion = 0

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if let hero {
                        HeroBanner(meta: hero)
                    }

                    if !model.continueWatching.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            RowHeader(title: "Continue Watching").padding(.horizontal, sizing.hPad)
                            continueRow
                        }
                    }

                    ForEach(recs.leadingRows) { row in
                        section(row.title, items: row.items)
                    }

                    if !model.savedLibrary.isEmpty {
                        section("My List", items: model.savedLibrary.prefix(30).map(\.asMeta))
                    }

                    ForEach(recs.trailingRows) { row in
                        section(row.title, items: row.items)
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
                    } else if home.rows.isEmpty && model.continueWatching.isEmpty && recs.leadingRows.isEmpty {
                        if let error = model.errorMessage {
                            EmptyStateView(symbol: "wifi.exclamationmark", title: "Couldn't load", message: error)
                        } else if !model.addons.isEmpty {
                            EmptyStateView(symbol: "square.stack.3d.up.slash", title: "No catalogs",
                                           message: "None of your addons have catalogs. Add Cinemeta in Stremio to fill Home.")
                        }
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, 24)
            }
            .refreshable {
                await model.refresh()
                async let a: Void = home.load(model.boardCatalogs, force: true)
                async let b: Void = recs.load(library: model.library, profileId: model.activeProfileId, force: true)
                _ = await (a, b)
            }
            .scrollsToTopOnReselect()
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: model.addons.map(\.transportUrl)) {
            await home.load(model.boardCatalogs)
            pickHero()
        }
        .task(id: "\(model.activeProfileId ?? "")|\(model.library.count)|\(tmdbKeyVersion)") {
            await recs.load(library: model.library, profileId: model.activeProfileId)
            pickHero()
        }
    }

    /// Picks the banner title once: a recommendation when there are some, else something from the first catalog.
    private func pickHero() {
        let fromRecs = recs.heroCandidates
        if !fromRecs.isEmpty {
            if !heroFromRecs {
                hero = fromRecs.randomElement()
                heroFromRecs = true
            }
        } else if hero == nil {
            hero = home.rows.first?.items.prefix(6).filter { $0.backdrop != nil }.randomElement()
        }
    }

    private func section(_ title: String, items: [MetaItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            RowHeader(title: title).padding(.horizontal, sizing.hPad)
            PosterRow(items: items)
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

/// The featured title: a tall poster card on iPhone, a wide backdrop on iPad, with Play, My List and Info.
struct HeroBanner: View {
    let meta: MetaItem
    @Environment(AppModel.self) private var model
    @Environment(\.sizing) private var sizing

    var body: some View {
        Group {
            if sizing.regular { wide } else { card }
        }
        .animation(.easeInOut(duration: 0.3), value: meta.id)
    }

    // MARK: iPhone: poster card

    private var card: some View {
        Color.clear
            .aspectRatio(0.74, contentMode: .fit)
            .overlay { RemoteImage(url: HeroArt.poster(meta), placeholderText: meta.name, fallback: meta.poster) }
            .overlay {
                LinearGradient(stops: [.init(color: .clear, location: 0.45), .init(color: .black.opacity(0.85), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 12) {
                    let line = HeroArt.metaLine(meta)
                    if !line.isEmpty {
                        Text(line).font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    }
                    buttons
                }
                .padding(16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
            .padding(.horizontal, sizing.hPad + 10)
            .padding(.top, 4)
    }

    // MARK: iPad: backdrop banner

    private var wide: some View {
        Color.clear
            .frame(height: 470)
            .overlay { RemoteImage(url: meta.backdrop ?? meta.poster, placeholderText: meta.name, fallback: meta.poster) }
            .overlay {
                LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .leading, endPoint: .center)
            }
            .overlay {
                LinearGradient(stops: [.init(color: .clear, location: 0.55), .init(color: Theme.background, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 12) {
                    if let logo = meta.logo {
                        RemoteImage(url: logo, contentMode: .fit)
                            .frame(maxWidth: 380, maxHeight: 120, alignment: .leading)
                    } else {
                        Text(meta.name)
                            .font(.system(size: 44, weight: .heavy))
                            .lineLimit(2)
                            .shadow(color: .black.opacity(0.5), radius: 8)
                    }
                    let line = HeroArt.metaLine(meta)
                    if !line.isEmpty {
                        Text(line).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                    }
                    if let d = meta.description, !d.isEmpty {
                        Text(d).font(.subheadline).foregroundStyle(.white.opacity(0.8)).lineLimit(3)
                            .frame(maxWidth: 520, alignment: .leading)
                    }
                    buttons.frame(maxWidth: 460)
                }
                .padding(.horizontal, sizing.hPad + 8)
                .padding(.bottom, 26)
            }
            .clipped()
    }

    // MARK: Buttons

    private var buttons: some View {
        let entry = model.entry(for: meta.id)
        let inList = entry?.isInLibrary == true
        let resume = entry?.videoId ?? (meta.type == "movie" ? meta.id : nil)
        return HStack(spacing: 10) {
            NavigationLink(value: Route.meta(meta, autoplayVideoId: resume)) {
                Label(entry?.progress ?? 0 > 0 ? "Resume" : "Play", systemImage: "play.fill")
                    .font(.body.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .foregroundStyle(.black)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                model.toggleLibrary(LibrarySeed(meta))
            } label: {
                Label("My List", systemImage: inList ? "checkmark" : "plus")
                    .font(.body.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .foregroundStyle(.white)
                    .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(inList ? "Remove from My List" : "Add to My List")

            NavigationLink(value: Route.meta(meta)) {
                Image(systemName: "info.circle")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.white)
                    .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More info")
        }
    }
}

/// Bigger art and a short info line for the featured title.
enum HeroArt {
    static func poster(_ meta: MetaItem) -> URL? {
        guard let url = meta.poster?.absoluteString else { return nil }
        let upgraded = url
            .replacingOccurrences(of: "image.tmdb.org/t/p/w342", with: "image.tmdb.org/t/p/w780")
            .replacingOccurrences(of: "/poster/medium/", with: "/poster/large/")
            .replacingOccurrences(of: "/poster/small/", with: "/poster/large/")
        return URL(string: upgraded)
    }

    static func metaLine(_ meta: MetaItem) -> String {
        var parts: [String] = []
        if let r = meta.releaseInfo, !r.isEmpty { parts.append(r) }
        parts.append(Format.typeName(meta.type))
        if !meta.genres.isEmpty { parts.append(meta.genres.prefix(2).joined(separator: " · ")) }
        if let rating = meta.imdbRating, !rating.isEmpty { parts.append("★ \(rating)") }
        return parts.joined(separator: "  •  ")
    }
}
