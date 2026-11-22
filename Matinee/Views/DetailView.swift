import SwiftUI

struct DetailView: View {
    let preview: MetaItem
    let autoplayVideoId: String?

    @Environment(AppModel.self) private var model
    @Environment(\.sizing) private var sizing

    @State private var meta: MetaItem?
    @State private var loaded = false
    @State private var season = 1
    @State private var target: StreamTarget?
    @State private var didAutoplay = false
    @State private var showFullDescription = false
    @State private var similar: [MetaItem] = []

    private var current: MetaItem { meta ?? preview }
    private var entry: LibraryEntry? { model.entry(for: preview.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if sizing.regular && current.hasEpisodes {
                    HStack(alignment: .top, spacing: 32) {
                        info.frame(width: 380, alignment: .leading)
                        episodes.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, sizing.hPad)
                } else {
                    VStack(alignment: .leading, spacing: 28) {
                        info
                        if current.hasEpisodes { episodes }
                    }
                    .frame(maxWidth: 820, alignment: .leading)
                    .padding(.horizontal, sizing.hPad)
                }
                if !similar.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        RowHeader(title: "More Like This").padding(.horizontal, sizing.hPad)
                        PosterRow(items: similar)
                    }
                    .padding(.top, 36)
                }
            }
            .padding(.bottom, 40)
        }
        .background(Theme.background)
        .ignoresSafeArea(edges: .top)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $target) { t in
            StreamPickerView(target: t)
                .presentationDetents([.large, .medium])
                .presentationDragIndicator(.visible)
        }
        .task { await load() }
        .task(id: loaded) {
            guard loaded, similar.isEmpty else { return }
            let known = Set(model.library.filter { $0.isWatched || $0.isInLibrary }.map(\.id))
            similar = await TasteRecommender.similar(to: current, known: known)
        }
    }

    // MARK: Header

    private var header: some View {
        // The backdrop sits in an overlay so a wide image can't widen the page and push content off-screen.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: sizing.regular ? 480 : 330)
            .overlay {
                RemoteImage(url: current.backdrop ?? current.poster, fallback: current.poster)
            }
            .clipped()
            .overlay {
                LinearGradient(colors: [.black.opacity(0.35), .clear, Theme.background.opacity(0.85), Theme.background],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                headerContent
            }
    }

    private var headerContent: some View {
        VStack(alignment: .leading, spacing: 12) {
                if let logo = current.logo {
                    RemoteImage(url: logo, contentMode: .fit)
                        .frame(maxWidth: sizing.regular ? 420 : 260, maxHeight: sizing.regular ? 130 : 84, alignment: .leading)
                        .accessibilityLabel(current.name)
                } else {
                    Text(current.name)
                        .font(sizing.regular ? .system(size: 44, weight: .heavy) : .largeTitle.weight(.heavy))
                        .lineLimit(3)
                }
                metaLine
                actionButtons
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, sizing.hPad)
            .padding(.bottom, 16)
    }

    private var metaLine: some View {
        HStack(spacing: 10) {
            if let year = current.year { Text(year) }
            if let runtime = current.runtime, !runtime.isEmpty { Text(runtime) }
            if let rating = current.imdbRating, !rating.isEmpty {
                Label(rating, systemImage: "star.fill").labelStyle(.titleAndIcon)
            }
            if current.hasEpisodes {
                Text("\(current.seasons.filter { $0 > 0 }.count) Seasons")
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                target = primaryTarget
            } label: {
                Label(primaryLabel, systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: sizing.regular ? 260 : .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(Theme.onAccent)
            .disabled(!loaded && preview.type == "series")

            Button {
                model.toggleLibrary(LibrarySeed(current))
            } label: {
                Image(systemName: (entry?.isInLibrary ?? false) ? "checkmark" : "plus")
                    .font(.headline)
                    .frame(width: 28)
                    .padding(.vertical, 6)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.bordered)
            .accessibilityLabel((entry?.isInLibrary ?? false) ? "Remove from Library" : "Add to Library")
        }
        .controlSize(.large)
        .padding(.top, 4)
    }

    // MARK: Info

    private var info: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !current.genres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(current.genres, id: \.self) { Chip(text: $0) }
                    }
                }
            }
            if let d = current.description, !d.isEmpty {
                Text(d)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(showFullDescription ? nil : 4)
                    .onTapGesture { withAnimation { showFullDescription.toggle() } }
            }
            if let entry, entry.progress > 0, !current.hasEpisodes {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressLine(value: entry.progress)
                    Text("\(Format.clock(entry.resumeSeconds)) watched")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 360)
            }
            if !loaded {
                ProgressView().padding(.top, 8)
            } else if meta == nil {
                Label("No addon had details for this title.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    // MARK: Episodes

    private var episodes: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(current.seasons, id: \.self) { s in
                        Button {
                            withAnimation(.snappy) { season = s }
                        } label: {
                            Text(s == 0 ? "Specials" : "Season \(s)")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .foregroundStyle(season == s ? Theme.onAccent : Color.primary)
                                .background(season == s ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.1)),
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollClipDisabled()

            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(current.sortedVideos.filter { ($0.season ?? 0) == season }) { video in
                    Button {
                        target = StreamTarget(meta: current, video: video)
                    } label: {
                        EpisodeRow(video: video,
                                   progress: entry?.videoId == video.id ? entry?.progress : nil,
                                   regular: sizing.regular)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Play button

    /// The episode to continue: the library's current one, else the first regular episode.
    private var resumeVideo: Video? {
        guard current.hasEpisodes else { return nil }
        if let vid = entry?.videoId, let v = current.videos.first(where: { $0.id == vid }) { return v }
        return current.sortedVideos.first { ($0.season ?? 0) > 0 } ?? current.sortedVideos.first
    }

    private var primaryTarget: StreamTarget {
        StreamTarget(meta: current, video: resumeVideo)
    }

    private var primaryLabel: String {
        if let v = resumeVideo {
            let started = entry?.videoId == v.id && (entry?.timeOffset ?? 0) > 1
            return "\(started ? "Resume" : "Play") \(v.episodeLabel)"
        }
        if let entry, entry.progress > 0 { return "Resume" }
        return "Play"
    }

    // MARK: Loading

    private func load() async {
        if meta == nil {
            let base = preview.id
            meta = await AddonClient.meta(addons: model.addons, type: preview.type, id: base)
            loaded = true
            if let v = resumeVideo { season = v.season ?? 1 }
            else if let first = current.seasons.first { season = first }
        }
        if !didAutoplay, let vid = autoplayVideoId {
            didAutoplay = true
            if let video = current.videos.first(where: { $0.id == vid }) {
                target = StreamTarget(meta: current, video: video)
            } else if !current.hasEpisodes {
                target = StreamTarget(meta: current, video: nil)
            }
        }
    }
}

struct EpisodeRow: View {
    let video: Video
    let progress: Double?
    let regular: Bool

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack(alignment: .bottom) {
                RemoteImage(url: video.thumbnail, placeholderText: video.episodeLabel)
                    .frame(width: regular ? 210 : 136, height: (regular ? 210 : 136) * 9 / 16)
                    .clipped()
                if let progress, progress > 0 {
                    ProgressLine(value: progress).padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                Image(systemName: "play.fill")
                    .font(.caption)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
                    .opacity(video.isUpcoming ? 0 : 1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(titleLine)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let date = video.releasedDate {
                    Text(video.isUpcoming ? "Coming \(Self.dateFormat.string(from: date))" : Self.dateFormat.string(from: date))
                        .font(.caption)
                        .foregroundStyle(video.isUpcoming ? Theme.accent : .secondary)
                }
                if let overview = video.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(regular ? 3 : 2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .opacity(video.isUpcoming ? 0.6 : 1)
    }

    private var titleLine: String {
        if let e = video.episode { return video.title.isEmpty ? "Episode \(e)" : "\(e). \(video.title)" }
        return video.title
    }
}
