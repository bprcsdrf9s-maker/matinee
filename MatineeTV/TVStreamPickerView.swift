import SwiftUI

/// Full-screen stream list for one movie or episode. Long-press a stream for more ways to play it.
struct TVStreamPickerView: View {
    let target: StreamTarget

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @AppStorage(Pref.resumeAutomatically) private var resumeDefault = true
    @AppStorage(Pref.onlyWorkingStreams) private var onlyWorking = true
    @State private var streams = StreamsModel()
    @State private var resume = true
    @State private var revealAll = false

    private var showAll: Bool { !onlyWorking || revealAll }
    private var loadingCount: Int { streams.groups.filter(\.loading).count }

    private var resumeAt: Double? {
        model.resumePosition(itemId: target.meta.id, videoId: target.videoId)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 70) {
            infoColumn
                .frame(width: 440)
            list
        }
        .padding(.horizontal, 20)
        .background { TVBackdrop(meta: target.meta, dim: 0.85) }
        .onAppear { resume = resumeDefault }
        .task {
            await streams.load(addons: model.addons, type: target.meta.type, videoId: target.videoId)
        }
    }

    // MARK: Left column

    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 22) {
            Color.clear
                .aspectRatio(1 / target.meta.posterAspect, contentMode: .fit)
                .frame(width: 300)
                .overlay { RemoteImage(url: target.meta.poster, placeholderText: target.meta.name) }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(radius: 20)
            Text(target.meta.name)
                .font(.title3.weight(.bold))
                .lineLimit(2)
            if let subtitle = target.subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let resumeAt {
                Toggle(isOn: $resume) {
                    Text("Resume from \(Format.clock(resumeAt))")
                }
            }
            Text("Hold the Select button on a stream to choose the player.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.top, 20)
        .focusSection()
    }

    // MARK: Streams

    private var list: some View {
        List {
            if let best = streams.best {
                Section {
                    Button {
                        play(best, engine: nil)
                    } label: {
                        HStack(spacing: 20) {
                            Image(systemName: "play.circle.fill").font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Play Best Match").font(.headline)
                                Text(StreamInfo.headline(best))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }

            if loadingCount > 0 {
                Section {
                    HStack(spacing: 20) {
                        ProgressView()
                        Text(loadingCount == 1 ? "Checking 1 more addon…" : "Checking \(loadingCount) addons…")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(streams.groups) { group in
                let visible = streams.visible(group, showAll: showAll)
                if !visible.isEmpty || (showAll && group.failed) {
                    Section(group.addon.manifest.name) {
                        if group.failed {
                            Label("Couldn't reach this addon.", systemImage: "wifi.exclamationmark")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(visible) { stream in
                            Button {
                                play(stream, engine: nil)
                            } label: {
                                TVStreamRow(stream: stream)
                            }
                            .contextMenu { menu(for: stream) }
                        }
                    }
                }
            }

            if streams.allLoaded && onlyWorking {
                let hidden = streams.hiddenCount(showAll: showAll)
                if hidden > 0 || revealAll {
                    Section {
                        Button(revealAll ? "Show only working streams"
                                         : "Show \(hidden) hidden stream\(hidden == 1 ? "" : "s")") {
                            revealAll.toggle()
                        }
                    } footer: {
                        Text("Hidden: torrent-only results, debrid results that still need downloading, links that open outside the app, and streams that failed to play in the last 7 days.")
                    }
                }
            }

            if streams.started && streams.groups.isEmpty {
                EmptyStateView(symbol: "antenna.radiowaves.left.and.right.slash", title: "No stream addons",
                               message: "Install a stream addon like Torrentio in Stremio.")
            } else if streams.allLoaded && !streams.groups.isEmpty
                        && streams.groups.allSatisfy({ streams.visible($0, showAll: showAll).isEmpty }) {
                EmptyStateView(symbol: "film.stack", title: "No working streams",
                               message: showAll ? "Your addons didn't return anything for this one."
                                                : "Nothing that plays right away. Try again later, or show the hidden streams.")
            }
        }
        .focusSection()
    }

    @ViewBuilder
    private func menu(for stream: StreamItem) -> some View {
        if stream.playURL != nil {
            Button { play(stream, engine: .apple) } label: { Label("Play with Apple Player", systemImage: "play.rectangle") }
            Button { play(stream, engine: .mpv) } label: { Label("Play with mpv", systemImage: "play.square.stack") }
            Button { openInInfuse(stream) } label: { Label("Open in Infuse", systemImage: "arrow.up.forward.app") }
        }
    }

    private func openInInfuse(_ stream: StreamItem) {
        guard let url = stream.playURL,
              let link = URL(string: "infuse://x-callback-url/play?url=\(AddonClient.encode(url.absoluteString))") else { return }
        openURL(link)
    }

    private func play(_ stream: StreamItem, engine: PlayerEngine?) {
        guard let url = stream.playURL else {
            if let open = stream.openURL { openURL(open) }
            return
        }
        let addons = model.addons
        let type = target.meta.type
        let videoId = target.videoId
        let filename = stream.filename
        let size = stream.videoSize
        let request = PlaybackRequest(
            url: url,
            headers: stream.requestHeaders,
            title: target.meta.name,
            subtitle: target.subtitle,
            filenameHint: stream.filename,
            startAt: resume ? (resumeAt ?? 0) : 0,
            seed: LibrarySeed(target.meta),
            videoId: videoId,
            nextVideoId: target.nextVideoId,
            subtitleLoader: {
                await AddonClient.subtitles(addons: addons, type: type, videoId: videoId,
                                            filename: filename, videoSize: size)
            }
        )
        PlayerPresenter.shared.play(request, engine: engine)
    }
}

/// One stream: quality and source on top, file details under it.
struct TVStreamRow: View {
    let stream: StreamItem

    var body: some View {
        let info = StreamInfo(stream)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if info.isCached {
                    Image(systemName: "bolt.fill").font(.caption).foregroundStyle(Theme.accent)
                }
                Text(StreamInfo.headline(stream))
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                if let container = info.container { Chip(text: container) }
            }
            let chips = info.badges
            if !chips.isEmpty || info.size != nil {
                HStack(spacing: 8) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { i, chip in
                        Chip(text: chip, highlighted: i == 0 && info.resolution != nil)
                    }
                    if let size = info.size {
                        Text(size).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
            }
            if !stream.details.isEmpty {
                Text(stream.details)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if !stream.isPlayableInApp {
                Text(stream.openURL != nil ? "Opens outside the app" : "Torrent only. Needs a debrid service to play here.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 6)
    }
}
