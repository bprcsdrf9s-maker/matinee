import SwiftUI

/// A movie or series page: art across the screen, Play and Library buttons, then seasons and episodes.
struct TVDetailView: View {
    let preview: MetaItem
    let autoplayVideoId: String?

    @Environment(AppModel.self) private var model

    @State private var meta: MetaItem?
    @State private var loaded = false
    @State private var season = 1
    @State private var target: StreamTarget?
    @State private var didAutoplay = false
    @FocusState private var playFocused: Bool

    private var current: MetaItem { meta ?? preview }
    private var entry: LibraryEntry? { model.entry(for: preview.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                header
                if current.hasEpisodes { episodes }
            }
            .padding(.bottom, 80)
        }
        .background { TVBackdrop(meta: current, dim: 0.6) }
        .fullScreenCover(item: $target) { t in
            TVStreamPickerView(target: t)
        }
        .task { await load() }
        .onAppear { playFocused = true }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let logo = current.logo {
                RemoteImage(url: logo, contentMode: .fit)
                    .frame(maxWidth: 640, maxHeight: 200, alignment: .leading)
                    .accessibilityLabel(current.name)
            } else {
                Text(current.name)
                    .font(.system(size: 72, weight: .heavy))
                    .lineLimit(2)
            }

            let line = TVText.metaLine(current)
            if !line.isEmpty {
                Text(line).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            }
            if !current.genres.isEmpty {
                Text(current.genres.prefix(4).joined(separator: "  ·  "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let d = current.description, !d.isEmpty {
                Text(d)
                    .font(.callout)
                    .lineLimit(4)
                    .frame(maxWidth: 1050, alignment: .leading)
            }
            if let entry, entry.progress > 0, !current.hasEpisodes {
                HStack(spacing: 16) {
                    ProgressLine(value: entry.progress).frame(width: 300)
                    Text("\(Format.clock(entry.resumeSeconds)) watched")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 30) {
                Button {
                    target = StreamTarget(meta: current, video: resumeVideo)
                } label: {
                    Label(primaryLabel, systemImage: "play.fill")
                        .padding(.horizontal, 20)
                }
                .buttonStyle(.borderedProminent)
                .focused($playFocused)
                .disabled(!loaded && preview.type == "series")

                Button {
                    model.toggleLibrary(LibrarySeed(current))
                } label: {
                    let saved = entry?.isInLibrary ?? false
                    Label(saved ? "In Library" : "Add to Library", systemImage: saved ? "checkmark" : "plus")
                }
            }
            .padding(.top, 10)

            if !loaded {
                ProgressView().padding(.top, 10)
            } else if meta == nil {
                Label("No addon had details for this title.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 820, alignment: .bottomLeading)
        .focusSection()
    }

    // MARK: Episodes

    private var episodes: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(current.seasons, id: \.self) { s in
                        Button {
                            season = s
                        } label: {
                            Text(s == 0 ? "Specials" : "Season \(s)")
                                .fontWeight(season == s ? .bold : .regular)
                        }
                        .tint(season == s ? Theme.accent : nil)
                    }
                }
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
            .focusSection()

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: TVSize.itemSpacing) {
                    ForEach(current.sortedVideos.filter { ($0.season ?? 0) == season }) { video in
                        TVEpisodeCard(video: video,
                                      progress: entry?.videoId == video.id ? entry?.progress : nil,
                                      isNext: entry?.videoId == video.id) {
                            target = StreamTarget(meta: current, video: video)
                        }
                    }
                }
                .padding(.vertical, 36)
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }

    // MARK: Play button

    /// The episode to continue: the library's current one, else the first regular episode.
    private var resumeVideo: Video? {
        guard current.hasEpisodes else { return nil }
        if let vid = entry?.videoId, let v = current.videos.first(where: { $0.id == vid }) { return v }
        return current.sortedVideos.first { ($0.season ?? 0) > 0 } ?? current.sortedVideos.first
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
            meta = await AddonClient.meta(addons: model.addons, type: preview.type, id: preview.id)
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

/// One episode: a 16:9 still with the episode's title and date under it.
struct TVEpisodeCard: View {
    let video: Video
    let progress: Double?
    let isNext: Bool
    let action: () -> Void

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private let width: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: action) {
                Color.clear
                    .frame(width: width, height: width * 9 / 16)
                    .overlay { RemoteImage(url: video.thumbnail, placeholderText: video.episodeLabel) }
                    .overlay(alignment: .bottom) {
                        if let progress, progress > 0 { ProgressLine(value: progress).padding(12) }
                    }
                    .overlay(alignment: .topLeading) {
                        if isNext {
                            Text("Up Next")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Theme.accent, in: Capsule())
                                .padding(12)
                        }
                    }
            }
            .buttonStyle(.card)

            VStack(alignment: .leading, spacing: 4) {
                Text(titleLine)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                if let date = video.releasedDate {
                    Text(video.isUpcoming ? "Coming \(Self.dateFormat.string(from: date))" : Self.dateFormat.string(from: date))
                        .font(.caption2)
                        .foregroundStyle(video.isUpcoming ? Theme.accent : .secondary)
                }
                if let overview = video.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .opacity(video.isUpcoming ? 0.6 : 1)
    }

    private var titleLine: String {
        if let e = video.episode { return video.title.isEmpty ? "Episode \(e)" : "\(e). \(video.title)" }
        return video.title
    }
}
