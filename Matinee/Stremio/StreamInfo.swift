import Foundation

/// Quality details pulled out of a stream's name, description and file name for the badges in the stream list.
struct StreamInfo {
    let resolution: String?
    let hdr: String?
    let codec: String?
    let audio: String?
    let size: String?
    let container: String?
    let isCached: Bool
    /// Lower is better; used for "Play best".
    let rank: Int

    init(_ stream: StreamItem) {
        let name = stream.name ?? ""
        let text = [name, stream.details, stream.filename ?? ""].joined(separator: "\n")
        let lower = text.lowercased()

        func has(_ needles: String...) -> Bool { needles.contains { lower.contains($0) } }

        if has("2160p", "4k", "uhd") { resolution = "4K" }
        else if has("1440p") { resolution = "1440p" }
        else if has("1080p", "1080i") { resolution = "1080p" }
        else if has("720p") { resolution = "720p" }
        else if has("480p", "576p") { resolution = "SD" }
        else { resolution = nil }

        if has("dolby vision", "dovi", ".dv.", " dv ", "dv hdr", "hdr dv", "| dv", "dv |") { hdr = "Dolby Vision" }
        else if has("hdr10+", "hdr10plus") { hdr = "HDR10+" }
        else if has("hdr") { hdr = "HDR" }
        else { hdr = nil }

        if has("av1") { codec = "AV1" }
        else if has("x265", "h265", "h.265", "hevc") { codec = "HEVC" }
        else if has("x264", "h264", "h.264", "avc") { codec = "H.264" }
        else { codec = nil }

        if has("atmos") { audio = "Atmos" }
        else if has("truehd") { audio = "TrueHD" }
        else if has("dts-hd", "dts:x", "dts") { audio = "DTS" }
        else if has("ddp", "dd+", "eac3", "e-ac-3") { audio = "DD+" }
        else if has("ac3", "dd5.1", "dd 5.1") { audio = "DD" }
        else if has("aac") { audio = "AAC" }
        else { audio = nil }

        if let bytes = stream.videoSize, bytes > 0 {
            size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        } else if let m = text.range(of: #"\d+(\.\d+)?\s?(GB|MB|GiB|MiB)"#, options: .regularExpression) {
            size = String(text[m])
        } else {
            size = nil
        }

        let file = (stream.filename ?? stream.url?.lastPathComponent ?? "").lowercased()
        let ext = (file as NSString).pathExtension
        container = ext.isEmpty || ext.count > 4 ? nil : ext.uppercased()

        // Debrid addons mark cached results with a "+" in the tag, e.g. "[TB+]" or "[RD+]".
        isCached = name.range(of: #"\[[A-Za-z]{2,3}\+\]"#, options: .regularExpression) != nil
            || name.contains("⚡")

        var r = 50
        switch resolution {
        case "4K": r = 10
        case "1440p": r = 15
        case "1080p": r = 20
        case "720p": r = 30
        case "SD": r = 40
        default: break
        }
        if !isCached && name.contains("[") { r += 100 } // uncached debrid results need downloading first
        if stream.url == nil { r += 1000 }
        rank = r
    }

    var badges: [String] {
        [resolution, hdr, codec, audio].compactMap { $0 }
    }

    /// The addon's own name line, minus line breaks: "[TB+] Torrentio 4k DV".
    static func headline(_ stream: StreamItem) -> String {
        (stream.name ?? "Stream")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
