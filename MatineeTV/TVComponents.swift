import SwiftUI

/// Sizes for a 1920×1080 screen viewed from the couch.
enum TVSize {
    static let posterWidth: CGFloat = 230
    static let landscapeWidth: CGFloat = 420
    static let itemSpacing: CGFloat = 44
    static let rowSpacing: CGFloat = 36

    static func width(for meta: MetaItem) -> CGFloat {
        meta.posterShape == "landscape" ? landscapeWidth : posterWidth
    }
}

// MARK: - Posters

/// Poster art for a focusable card. Calls `onFocus` when its card gains focus.
struct TVPosterArt: View {
    let meta: MetaItem
    var width: CGFloat? = nil
    var progress: Double? = nil
    var onFocus: ((MetaItem) -> Void)? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.isFocused) private var focused

    var body: some View {
        let watched = model.entry(for: meta.id)?.isWatched == true
        Color.clear
            .aspectRatio(1 / meta.posterAspect, contentMode: .fit)
            .frame(width: width)
            .overlay { RemoteImage(url: meta.poster, placeholderText: meta.name) }
            .overlay(alignment: .topLeading) {
                if watched { WatchedBadge().scaleEffect(1.4).padding(14) }
            }
            .overlay(alignment: .bottom) {
                if let progress, progress > 0 {
                    ProgressLine(value: progress).padding(10)
                }
            }
            .onChange(of: focused) { _, isFocused in
                if isFocused { onFocus?(meta) }
            }
            .accessibilityLabel(meta.name)
    }
}

/// A poster that opens the title's page.
struct TVPosterLink: View {
    let meta: MetaItem
    var route: TVRoute? = nil
    var width: CGFloat? = nil
    var progress: Double? = nil
    var onFocus: ((MetaItem) -> Void)? = nil

    var body: some View {
        NavigationLink(value: route ?? .meta(meta)) {
            TVPosterArt(meta: meta, width: width, progress: progress, onFocus: onFocus)
        }
        .buttonStyle(.card)
    }
}

/// The last card in a row, opening the full catalog.
struct TVSeeAllCard: View {
    let route: TVRoute
    let width: CGFloat
    let aspect: CGFloat

    var body: some View {
        NavigationLink(value: route) {
            Color.clear
                .aspectRatio(aspect, contentMode: .fit)
                .frame(width: width)
                .overlay {
                    VStack(spacing: 14) {
                        Image(systemName: "square.grid.2x2").font(.system(size: 44, weight: .semibold))
                        Text("See All").font(.headline)
                    }
                    .foregroundStyle(.secondary)
                }
                .background(Color(white: 0.16))
        }
        .buttonStyle(.card)
    }
}

/// A titled row of posters that scrolls sideways.
struct TVPosterRow: View {
    let title: String
    let items: [MetaItem]
    var seeAll: TVRoute? = nil
    var onFocus: ((MetaItem) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: TVSize.itemSpacing) {
                    ForEach(items) { meta in
                        TVPosterLink(meta: meta, width: TVSize.width(for: meta), onFocus: onFocus)
                    }
                    if let seeAll, let first = items.first {
                        TVSeeAllCard(route: seeAll, width: TVSize.width(for: first), aspect: 1 / first.posterAspect)
                    }
                }
                .padding(.vertical, 36)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

// MARK: - Backdrop

/// Full-screen art behind a page, faded toward the bottom and left so text stays readable.
struct TVBackdrop: View {
    let meta: MetaItem?
    var dim: Double = 0.55

    var body: some View {
        ZStack {
            Theme.background
            if let meta {
                RemoteImage(url: meta.backdrop ?? meta.poster, fallback: meta.poster)
                    .id(meta.id)
                    .transition(.opacity)
                    .overlay {
                        LinearGradient(colors: [.black.opacity(dim + 0.3), .black.opacity(dim * 0.6), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                    }
                    .overlay {
                        LinearGradient(colors: [.clear, Theme.background.opacity(0.75), Theme.background],
                                       startPoint: .center, endPoint: .bottom)
                    }
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.45), value: meta?.id)
    }
}

// MARK: - Filters

/// The label for a dropdown Menu: current choice and a chevron.
struct TVMenuLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption.weight(.bold))
        }
        .padding(.horizontal, 8)
    }
}

/// Grid columns for posters: 6 across, 4 for wide channel art.
func tvPosterColumns(for items: [MetaItem]) -> [GridItem] {
    let landscape = !items.isEmpty && items.prefix(6).allSatisfy { $0.posterShape == "landscape" }
    return Array(repeating: GridItem(.flexible(), spacing: TVSize.itemSpacing, alignment: .top),
                 count: landscape ? 4 : 6)
}

// MARK: - Text helpers

enum TVText {
    /// "2019 · 2h 10m · ★ 7.8"
    static func metaLine(_ meta: MetaItem) -> String {
        var parts: [String] = []
        if let year = meta.year { parts.append(year) }
        if let runtime = meta.runtime, !runtime.isEmpty { parts.append(runtime) }
        if let rating = meta.imdbRating, !rating.isEmpty { parts.append("★ \(rating)") }
        if meta.hasEpisodes {
            let count = meta.seasons.filter { $0 > 0 }.count
            if count > 0 { parts.append(count == 1 ? "1 Season" : "\(count) Seasons") }
        }
        return parts.joined(separator: "  ·  ")
    }

    /// "S2 E5" from a Stremio video id like "tt0903747:2:5".
    static func episodeLabel(videoId: String?) -> String? {
        guard let parts = videoId?.split(separator: ":"), parts.count >= 3,
              let s = Int(parts[parts.count - 2]), let e = Int(parts[parts.count - 1]) else { return nil }
        return "S\(s) E\(e)"
    }
}
