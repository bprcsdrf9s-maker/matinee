import Foundation

/// One item from the Stremio library datastore. The raw JSON is kept so writes send every field back
/// unchanged (including the compressed "watched" field other Stremio apps rely on).
struct LibraryEntry: Identifiable {
    let raw: [String: Any]

    let id: String
    let type: String
    let name: String
    let poster: URL?
    let removed: Bool
    let temp: Bool
    let mtime: Date?
    let lastWatched: Date?
    /// Milliseconds, like Stremio stores them.
    let timeOffset: Double
    let duration: Double
    let videoId: String?
    let posterShape: String?
    /// Stremio marks a title watched once 70% of a video has played, or when the user marks it.
    let isWatched: Bool

    init?(_ raw: [String: Any]) {
        guard let id = raw["_id"] as? String else { return nil }
        self.raw = raw
        self.id = id
        type = raw["type"] as? String ?? "movie"
        name = raw["name"] as? String ?? ""
        poster = (raw["poster"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        removed = (raw["removed"] as? Bool) ?? false
        temp = (raw["temp"] as? Bool) ?? false
        mtime = (raw["_mtime"] as? String).flatMap(ISODate.parse)
        let state = raw["state"] as? [String: Any] ?? [:]
        lastWatched = (state["lastWatched"] as? String).flatMap(ISODate.parse)
        timeOffset = (state["timeOffset"] as? NSNumber)?.doubleValue ?? 0
        duration = (state["duration"] as? NSNumber)?.doubleValue ?? 0
        let vid = state["video_id"] as? String
        videoId = (vid?.isEmpty ?? true) ? nil : vid
        posterShape = raw["posterShape"] as? String
        let times = (state["timesWatched"] as? NSNumber)?.intValue ?? 0
        let flagged = (state["flaggedWatched"] as? NSNumber)?.intValue ?? 0
        isWatched = times > 0 || flagged > 0
    }

    /// stremio-core LibraryItem::is_in_library-style check: saved by the user.
    var isInLibrary: Bool { !removed && !temp }

    /// stremio-core LibraryItem::is_in_continue_watching.
    var isInContinueWatching: Bool { type != "other" && (!removed || temp) && timeOffset > 0 }

    var progress: Double {
        guard timeOffset > 0, duration > 0 else { return 0 }
        return min(1, timeOffset / duration)
    }

    var sortDate: Date { lastWatched ?? mtime ?? .distantPast }

    /// "S2 · E5" parsed from a video id like tt0903747:2:5.
    var episodeLabel: String? {
        guard let videoId, videoId != id else { return nil }
        let parts = videoId.split(separator: ":")
        guard parts.count >= 3, let s = Int(parts[parts.count - 2]), let e = Int(parts[parts.count - 1]) else { return nil }
        return "S\(s) · E\(e)"
    }

    var resumeSeconds: Double { timeOffset / 1000 }

    var asMeta: MetaItem { MetaItem(id: id, type: type, name: name, poster: poster, posterShape: posterShape) }

    // MARK: Building writes

    /// A brand-new entry, shaped like stremio-core's LibraryItem::from(MetaItemPreview): removed + temp,
    /// so it shows in Continue Watching without being added to the saved library.
    static func newRaw(id: String, type: String, name: String, poster: URL?, now: Date = Date()) -> [String: Any] {
        let stamp = ISODate.string(now)
        var item: [String: Any] = [
            "_id": id,
            "name": name,
            "type": type,
            "posterShape": "poster",
            "removed": true,
            "temp": true,
            "_ctime": stamp,
            "_mtime": stamp,
            "state": [
                "lastWatched": NSNull(),
                "timeWatched": 0,
                "timeOffset": 0,
                "overallTimeWatched": 0,
                "timesWatched": 0,
                "flaggedWatched": 0,
                "duration": 0,
                "video_id": NSNull(),
                "watched": NSNull(),
                "noNotif": false,
            ] as [String: Any],
            "behaviorHints": [
                "defaultVideoId": NSNull(),
                "featuredVideoId": NSNull(),
                "hasScheduledVideos": false,
            ] as [String: Any],
        ]
        if let poster { item["poster"] = poster.absoluteString }
        return item
    }
}

/// What's needed to create or update a library entry for something being played.
struct LibrarySeed: Hashable {
    let id: String
    let type: String
    let name: String
    let poster: URL?

    init(id: String, type: String, name: String, poster: URL?) {
        self.id = id; self.type = type; self.name = name; self.poster = poster
    }

    init(_ meta: MetaItem) {
        self.init(id: meta.id, type: meta.type, name: meta.name, poster: meta.poster)
    }
}

/// Progress rules ported from stremio-core's player model (models/player.rs):
/// time watched accumulates per video, 70% watched counts as watched, and closing past 90%
/// clears the resume point and moves a series on to its next episode.
enum ProgressRules {
    static let watchedThreshold = 0.7
    static let creditsThreshold = 0.9

    private static func u(_ v: Any?) -> UInt64 { (v as? NSNumber)?.uint64Value ?? 0 }

    static func apply(to raw: [String: Any], videoId: String, positionMs: UInt64, durationMs: UInt64,
                      watchedMs: UInt64, closing: Bool, nextVideoId: String?, now: Date = Date()) -> [String: Any] {
        var item = raw
        var state = item["state"] as? [String: Any] ?? [:]

        var timeWatched = u(state["timeWatched"])
        var overall = u(state["overallTimeWatched"])
        var flagged = u(state["flaggedWatched"])
        var timesWatched = u(state["timesWatched"])
        var timeOffset = u(state["timeOffset"])
        var duration = u(state["duration"])

        state["lastWatched"] = ISODate.string(now)

        if (state["video_id"] as? String) != videoId {
            state["video_id"] = videoId
            overall &+= timeWatched
            timeWatched = 0
            flagged = 0
        }
        timeWatched &+= watchedMs
        overall &+= watchedMs

        if positionMs > 0 {
            timeOffset = positionMs
            if durationMs > 0 { duration = durationMs }
        }

        if flagged == 0, duration > 0, Double(timeWatched) > Double(duration) * watchedThreshold {
            flagged = 1
            timesWatched &+= 1
        }

        if closing, duration > 0, Double(timeOffset) > Double(duration) * creditsThreshold {
            timeOffset = 0
            if let nextVideoId {
                // LibraryItem::advance_to_video
                state["video_id"] = nextVideoId
                overall &+= timeWatched
                timeWatched = 0
                flagged = 0
                timeOffset = 1
            }
        }

        state["timeWatched"] = timeWatched
        state["overallTimeWatched"] = overall
        state["flaggedWatched"] = flagged
        state["timesWatched"] = timesWatched
        state["timeOffset"] = timeOffset
        state["duration"] = duration
        item["state"] = state
        item["_mtime"] = ISODate.string(now)
        return item
    }

    /// Saved-library toggle, like stremio-core's AddToLibrary / RemoveFromLibrary.
    static func setInLibrary(_ raw: [String: Any], _ inLibrary: Bool, now: Date = Date()) -> [String: Any] {
        var item = raw
        item["removed"] = !inLibrary
        item["temp"] = false
        item["_mtime"] = ISODate.string(now)
        return item
    }

    /// Removes a title from Continue Watching (stremio-core's RewindLibraryItem-style dismiss).
    static func dismissFromContinueWatching(_ raw: [String: Any], now: Date = Date()) -> [String: Any] {
        var item = raw
        var state = item["state"] as? [String: Any] ?? [:]
        state["timeOffset"] = 0
        item["state"] = state
        item["_mtime"] = ISODate.string(now)
        return item
    }
}
