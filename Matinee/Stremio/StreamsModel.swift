import Foundation
import Observation

/// Streams for one video, fetched from every stream addon at once.
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

    /// First working stream in addon order, preferring cached debrid results.
    var best: StreamItem? {
        let all = groups.flatMap(\.streams).filter(\.isWorking)
        let preferred = all.first { stream in
            let info = StreamInfo(stream)
            return info.isCached || !(stream.name ?? "").contains("[")
        }
        return preferred ?? all.first
    }

    /// The streams to list for an addon: only working ones unless everything is being shown.
    func visible(_ group: AddonStreams, showAll: Bool) -> [StreamItem] {
        showAll ? group.streams : group.streams.filter(\.isWorking)
    }

    /// How many streams the filter is hiding across all addons.
    func hiddenCount(showAll: Bool) -> Int {
        showAll ? 0 : groups.reduce(0) { $0 + $1.streams.count - $1.streams.filter(\.isWorking).count }
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
