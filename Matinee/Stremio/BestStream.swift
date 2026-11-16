import Foundation
import Network
#if os(iOS)
import UIKit
#endif

/// Picks the stream "Play Best Match" plays.
///
/// Among streams that play right away (cached, with a direct link, not recently failed) it prefers, in order:
/// 1. The target resolution: 4K on Apple TV and on Wi-Fi; 1080p on cellular or a phone hotspot.
/// 2. Untouched picture: no cam/telesync/screener copies, nothing marked upscaled.
/// 3. HDR: Dolby Vision with an HDR10 base, HDR10+, HDR10, then Dolby Vision only, then SDR.
/// 4. Source: Remux, Blu-ray encode, WEB-DL, WEBRip, then HDTV/DVD.
/// 5. Audio: TrueHD Atmos, DTS:X, TrueHD, DTS-HD MA, DD+ Atmos, DTS-HD, DD+, DTS, DD, AAC; more channels win ties.
/// 6. Bigger file (more bitrate), then the addon's own order.
enum BestStream {
    static func pick(_ streams: [StreamItem]) -> StreamItem? {
        let target = targetHeight
        let scored = streams.enumerated().map { ($0.offset, $0.element, Score($0.element, target: target)) }
        return scored.max { a, b in
            if a.2 != b.2 { return a.2 < b.2 }
            return a.0 > b.0 // earlier in the addon's list wins a full tie
        }?.1
    }

    /// 2160 or 1080, from the device and the current network.
    static var targetHeight: Int {
        #if os(iOS)
        return NetworkStatus.shared.isCellular ? 1080 : 2160
        #else
        return 2160
        #endif
    }

    struct Score: Comparable {
        let notJunk: Int
        let resolution: Int
        let hdr: Int
        let source: Int
        let audio: Int
        let channels: Int
        let bytes: Int64

        private var tuple: [Int64] {
            [Int64(notJunk), Int64(resolution), Int64(hdr), Int64(source), Int64(audio), Int64(channels), bytes]
        }

        static func < (a: Score, b: Score) -> Bool {
            for (x, y) in zip(a.tuple, b.tuple) where x != y { return x < y }
            return false
        }

        init(_ stream: StreamItem, target: Int) {
            let text = [stream.name ?? "", stream.details, stream.filename ?? ""].joined(separator: "\n")
            let lower = text.lowercased()
            func has(_ needles: String...) -> Bool { needles.contains { lower.contains($0) } }
            func word(_ pattern: String) -> Bool {
                lower.range(of: "(^|[^a-z0-9])(\(pattern))([^a-z0-9]|$)", options: .regularExpression) != nil
            }

            // Theater recordings and fake 4K never win while anything else is available.
            let junk = word("cam|camrip|hdcam|ts|hdts|telesync|tc|telecine|scr|screener|dvdscr")
                || has("upscale", "upscaling", "ai-enhanced", "ai enhanced")
            notJunk = junk ? 0 : 1

            let height: Int?
            if has("2160p", "4k", "uhd") { height = 2160 }
            else if has("1440p") { height = 1440 }
            else if has("1080p", "1080i") { height = 1080 }
            else if has("720p") { height = 720 }
            else if has("480p", "576p") { height = 480 }
            else { height = nil }
            let order: [Int] = target >= 2160 ? [2160, 1440, 1080, 720, 480] : [1080, 720, 1440, 480, 2160]
            if let height, let i = order.firstIndex(of: height) { resolution = order.count - i } else { resolution = 0 }

            let dv = has("dolby vision", "dovi") || word("dv")
            let hdr10plus = has("hdr10+", "hdr10plus", "hdr10 plus")
            let hdr10 = has("hdr")
            if dv && (hdr10plus || hdr10) { hdr = 5 }   // DV with an HDR10 base layer
            else if hdr10plus { hdr = 4 }
            else if hdr10 { hdr = 3 }
            else if dv { hdr = 2 }                      // DV only: no HDR10 fallback
            else { hdr = 1 }

            if has("remux") { source = 6 }
            else if has("bluray", "blu-ray", "bdrip", "brrip") || word("bd") { source = 5 }
            else if has("web-dl", "webdl", "web dl") { source = 4 }
            else if has("webrip", "web-rip", "web rip") || word("web") { source = 3 }
            else if has("hdtv", "dvdrip", "dvd") { source = 1 }
            else { source = 2 }

            let atmos = has("atmos")
            if has("truehd", "true-hd") && atmos { audio = 10 }
            else if has("dts:x", "dts-x", "dtsx") { audio = 9 }
            else if has("truehd", "true-hd") { audio = 8 }
            else if has("dts-hd ma", "dts-hd.ma", "dts-hd-ma", "dtshd-ma", "dts-hdma", "dts hd ma") { audio = 7 }
            else if has("ddp", "dd+", "eac3", "e-ac-3", "e-ac3") && atmos { audio = 6 }
            else if has("dts-hd", "dtshd") { audio = 5 }
            else if atmos { audio = 6 }
            else if has("ddp", "dd+", "eac3", "e-ac-3", "e-ac3") { audio = 4 }
            else if word("dts") { audio = 3 }
            else if has("ac3", "dd5", "dd 5", "dd2", "dd 2") || word("dd") { audio = 2 }
            else if word("aac|opus|flac") { audio = has("flac") ? 3 : 1 }
            else { audio = 0 }

            if has("7.1") { channels = 3 }
            else if has("5.1") { channels = 2 }
            else if has("2.0", "stereo") { channels = 1 }
            else { channels = 0 }

            if let size = stream.videoSize, size > 0 {
                bytes = size
            } else if let m = text.range(of: #"(\d+(?:\.\d+)?)\s?(GB|GiB|MB|MiB)"#, options: .regularExpression) {
                let match = String(text[m])
                let number = Double(match.filter { $0.isNumber || $0 == "." }) ?? 0
                let gb = match.uppercased().contains("G")
                bytes = Int64(number * (gb ? 1_073_741_824 : 1_048_576))
            } else {
                bytes = 0
            }
        }
    }
}

/// Whether the device is on cellular data right now, counting a phone's hotspot as cellular.
final class NetworkStatus: @unchecked Sendable {
    static let shared = NetworkStatus()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var cellular = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let onCellular = path.usesInterfaceType(.cellular) || (path.isExpensive && !path.usesInterfaceType(.wiredEthernet))
            self.lock.lock()
            self.cellular = onCellular
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "matinee.network"))
    }

    /// Call at launch so the first answer is ready before the stream list opens.
    func start() {}

    var isCellular: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cellular
    }
}
