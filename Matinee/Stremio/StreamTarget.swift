import Foundation

/// What the stream picker is choosing streams for: a movie, or one episode of a series.
struct StreamTarget: Identifiable {
    let meta: MetaItem
    let video: Video?

    var videoId: String { video?.id ?? meta.playableVideoId }
    var id: String { videoId }
    var subtitle: String? {
        guard let video else { return nil }
        return video.title.isEmpty ? video.episodeLabel : "\(video.episodeLabel) · \(video.title)"
    }
    var nextVideoId: String? { video.flatMap { meta.video(after: $0.id)?.id } }
}
