import SwiftUI
import UIKit

@MainActor
@Observable
final class StreamsModel {
    struct AddonStreams: Identifiable {
        let addon: AddonDescriptor
        var streams: [StreamItem] = []
        var loading = true
        var failed = false
        var id: String { addon.transportUrl }
    }

    private(set) var groups: [AddonStreams] = []
    private(set) var started = false

    var allLoaded: Bool { groups.allSatisfy { !$0.loading } }

    /// First playable stream in addon order, preferring cached debrid results.
    var best: StreamItem? {
        let all = groups.flatMap(\.streams).filter(\.isPlayableInApp)
        let preferred = all.first { stream in
            let info = StreamInfo(stream)
            return info.isCached || !(stream.name ?? "").contains("[")
        }
        return preferred ?? all.first
    }

    func load(addons: [AddonDescriptor], type: String, videoId: String) async {
        guard !started else { return }
        started = true
        let targets = AddonClient.streamAddons(addons, type: type, videoId: videoId)
        groups = targets.map { AddonStreams(addon: $0) }
        await withTaskGroup(of: (Int, [StreamItem]?).self) { group in
            for (i, addon) in targets.enumerated() {
                group.addTask {
                    (i, try? await AddonClient.streams(addon, type: type, videoId: videoId))
                }
            }
            for await (i, result) in group {
                groups[i].loading = false
                if let result { groups[i].streams = result } else { groups[i].failed = true }
            }
        }
    }
}

struct StreamPickerView: View {
    let target: StreamTarget

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(Pref.resumeAutomatically) private var resumeDefault = true
    @State private var streams = StreamsModel()
    @State private var resume = true

    private var resumeAt: Double? {
        model.resumePosition(itemId: target.meta.id, videoId: target.videoId)
    }

    var body: some View {
        NavigationStack {
            List {
                if let resumeAt {
                    Section {
                        Toggle(isOn: $resume) {
                            Label("Resume from \(Format.clock(resumeAt))", systemImage: "clock.arrow.circlepath")
                        }
                    }
                }

                if let best = streams.best {
                    Section {
                        Button {
                            play(best, engine: nil)
                        } label: {
                            HStack {
                                Image(systemName: "play.circle.fill").font(.title2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Play Best Match").font(.headline)
                                    Text(StreamInfo.headline(best))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }

                ForEach(streams.groups) { group in
                    if group.loading || group.failed || !group.streams.isEmpty {
                        Section {
                            if group.loading && group.streams.isEmpty {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Finding streams…").foregroundStyle(.secondary)
                                }
                            } else if group.failed {
                                Label("Couldn't reach this addon.", systemImage: "wifi.exclamationmark")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(group.streams) { stream in
                                StreamRow(stream: stream)
                                    .contentShape(Rectangle())
                                    .onTapGesture { play(stream, engine: nil) }
                                    .contextMenu { menu(for: stream) }
                            }
                        } header: {
                            Text(group.addon.manifest.name)
                        }
                    }
                }

                if streams.started && streams.groups.isEmpty {
                    EmptyStateView(symbol: "antenna.radiowaves.left.and.right.slash", title: "No stream addons",
                                   message: "Install a stream addon like Torrentio in Stremio, then pull to refresh on Home.")
                } else if streams.allLoaded && streams.groups.allSatisfy({ $0.streams.isEmpty }) && !streams.groups.isEmpty {
                    EmptyStateView(symbol: "film.stack", title: "No streams found",
                                   message: "Your addons didn't return anything for this one.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(target.meta.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let subtitle = target.subtitle {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text(target.meta.name).font(.headline).lineLimit(1)
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { resume = resumeDefault }
        .task {
            await streams.load(addons: model.addons, type: target.meta.type, videoId: target.videoId)
        }
    }

    @ViewBuilder
    private func menu(for stream: StreamItem) -> some View {
        if stream.playURL != nil {
            Button { play(stream, engine: .apple) } label: { Label("Play with Apple Player", systemImage: "play.rectangle") }
            Button { play(stream, engine: .mpv) } label: { Label("Play with mpv", systemImage: "play.square.stack") }
            Divider()
            Button { openExternal(stream, scheme: .infuse) } label: { Label("Open in Infuse", systemImage: "arrow.up.forward.app") }
            Button { openExternal(stream, scheme: .vlc) } label: { Label("Open in VLC", systemImage: "arrow.up.forward.app") }
            Button {
                UIPasteboard.general.url = stream.playURL
            } label: { Label("Copy Link", systemImage: "link") }
        } else if let url = stream.openURL {
            Button { openURL(url) } label: { Label("Open", systemImage: "safari") }
        }
    }

    private enum External { case infuse, vlc }

    private func openExternal(_ stream: StreamItem, scheme: External) {
        guard let url = stream.playURL else { return }
        let encoded = AddonClient.encode(url.absoluteString)
        let link: String
        switch scheme {
        case .infuse: link = "infuse://x-callback-url/play?url=\(encoded)"
        case .vlc: link = "vlc-x-callback://x-callback-url/stream?url=\(encoded)"
        }
        if let u = URL(string: link) { openURL(u) }
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

struct StreamRow: View {
    let stream: StreamItem

    var body: some View {
        let info = StreamInfo(stream)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if info.isCached {
                    Image(systemName: "bolt.fill").font(.caption).foregroundStyle(Theme.accent)
                }
                Text(StreamInfo.headline(stream))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 4)
                if let container = info.container { Chip(text: container) }
            }
            let chips = info.badges
            if !chips.isEmpty || info.size != nil {
                HStack(spacing: 5) {
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            if !stream.isPlayableInApp {
                Text(stream.openURL != nil ? "Opens outside the app" : "Torrent only. Needs a debrid service to play here.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
        .opacity(stream.isPlayableInApp || stream.openURL != nil ? 1 : 0.45)
    }
}
