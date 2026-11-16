import Foundation
import UIKit
import Combine
import Libmpv

struct MPVTrack: Identifiable, Hashable {
    let id: Int
    let title: String
    let selected: Bool
}

/// Workarounds from MPVKit's Metal demo: MoltenVK sometimes sets a 1x1 drawable, and the
/// EDR flag only takes effect when set on the main thread.
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    #if os(iOS)
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.sync { super.wantsExtendedDynamicRangeContent = newValue }
            }
        }
    }
    #endif
}

/// A thin wrapper around libmpv (via MPVKit), rendering with Vulkan/MoltenVK into a Metal layer,
/// set up the way MPVKit's iOS demo does it.
final class MPVPlayer: ObservableObject {
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var paused = false
    @Published private(set) var buffering = true
    @Published private(set) var started = false
    @Published private(set) var ended = false
    @Published private(set) var speed: Double = 1
    @Published private(set) var audioTracks: [MPVTrack] = []
    @Published private(set) var subtitleTracks: [MPVTrack] = []
    @Published var errorMessage: String?

    let layer = MPVMetalLayer()
    var onFileLoaded: (() -> Void)?

    private var mpv: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "matinee.mpv.events", qos: .userInitiated)
    private let commandQueue = DispatchQueue(label: "matinee.mpv.commands", qos: .userInitiated)

    struct Options {
        var hardwareDecoding = true
        var audioLanguages = "en,eng"
        var subtitleLanguages = "en,eng"
        var autoSubtitles = false
    }

    deinit {
        if let h = mpv {
            mpv_set_wakeup_callback(h, nil, nil)
            mpv_terminate_destroy(h)
        }
    }

    // MARK: Start / stop

    func start(url: URL, headers: [String: String], startAt: Double, options: Options) {
        guard mpv == nil else { return }
        guard let h = mpv_create() else {
            errorMessage = "Couldn't start the player."
            return
        }
        mpv = h

        layer.framebufferOnly = true
        layer.backgroundColor = UIColor.black.cgColor
        var layerRef = layer
        mpv_set_option(h, "wid", MPV_FORMAT_INT64, &layerRef)

        set("vo", "gpu-next")
        set("gpu-api", "vulkan")
        set("gpu-context", "moltenvk")
        set("hwdec", options.hardwareDecoding ? "videotoolbox" : "no")
        set("video-rotate", "no")
        set("keep-open", "yes")
        set("ytdl", "no")
        set("cache", "yes")
        set("demuxer-max-bytes", "300MiB")
        set("demuxer-max-back-bytes", "100MiB")
        set("network-timeout", "30")
        set("alang", options.audioLanguages)
        set("subs-match-os-language", "no")
        if options.autoSubtitles {
            set("slang", options.subtitleLanguages)
            set("subs-fallback", "yes")
        } else {
            set("sid", "no")
        }
        if startAt > 1 { set("start", String(format: "%.3f", startAt)) }
        for (name, value) in headers where !name.isEmpty {
            set("http-header-fields-append", "\(name): \(value)")
        }

        guard mpv_initialize(h) >= 0 else {
            errorMessage = "Couldn't start the player."
            return
        }

        mpv_observe_property(h, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(h, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(h, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(h, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(h, 0, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(h, 0, "speed", MPV_FORMAT_DOUBLE)
        mpv_observe_property(h, 0, "track-list/count", MPV_FORMAT_NONE)
        mpv_observe_property(h, 0, "aid", MPV_FORMAT_NONE)
        mpv_observe_property(h, 0, "sid", MPV_FORMAT_NONE)

        mpv_set_wakeup_callback(h, { ctx in
            guard let ctx else { return }
            Unmanaged<MPVPlayer>.fromOpaque(ctx).takeUnretainedValue().drainEvents()
        }, Unmanaged.passUnretained(self).toOpaque())

        let target = url.isFileURL ? url.path : url.absoluteString
        command(["loadfile", target, "replace"])
    }

    /// Stops playback and frees mpv off the main thread. Holds on to self until mpv is gone,
    /// so the wakeup callback never sees a freed object.
    func shutdown() {
        guard let h = mpv else { return }
        mpv = nil
        eventQueue.async { [self] in
            mpv_set_wakeup_callback(h, nil, nil)
            mpv_terminate_destroy(h)
            _ = self.layer
        }
    }

    // MARK: Controls

    func togglePause() { setFlag("pause", !paused) }
    func play() { setFlag("pause", false) }
    func pause() { setFlag("pause", true) }

    func seek(to seconds: Double) {
        position = seconds
        command(["seek", String(format: "%.3f", max(0, seconds)), "absolute+exact"])
    }

    func skip(_ seconds: Double) {
        command(["seek", String(format: "%.3f", seconds), "relative"])
    }

    func setSpeed(_ value: Double) {
        guard let h = mpv else { return }
        var v = value
        mpv_set_property(h, "speed", MPV_FORMAT_DOUBLE, &v)
    }

    func selectAudio(_ id: Int) { setString("aid", String(id)) }
    func selectSubtitle(_ id: Int?) { setString("sid", id.map(String.init) ?? "no") }

    /// Adds an external subtitle. mpv downloads it, so this runs off the main thread.
    func addSubtitle(url: URL, title: String, lang: String) {
        command(["sub-add", url.absoluteString, "auto", title, lang], async: true)
    }

    /// MoltenVK can't draw while the app is in the background; turn video off and back on.
    func setVideoEnabled(_ enabled: Bool) {
        setString("vid", enabled ? "auto" : "no")
    }

    // MARK: libmpv plumbing

    private func set(_ name: String, _ value: String) {
        guard let h = mpv else { return }
        mpv_set_option_string(h, name, value)
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard let h = mpv else { return }
        var flag: Int32 = value ? 1 : 0
        mpv_set_property(h, name, MPV_FORMAT_FLAG, &flag)
    }

    private func setString(_ name: String, _ value: String) {
        guard let h = mpv else { return }
        mpv_set_property_string(h, name, value)
    }

    private func command(_ args: [String], async: Bool = false) {
        guard let h = mpv else { return }
        let run = {
            var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
            cargs.append(nil)
            defer {
                for ptr in cargs where ptr != nil { free(UnsafeMutablePointer(mutating: ptr)) }
            }
            _ = mpv_command(h, &cargs)
        }
        if async { commandQueue.async(execute: run) } else { run() }
    }

    private func getString(_ h: OpaquePointer, _ name: String) -> String? {
        guard let cstr = mpv_get_property_string(h, name) else { return nil }
        defer { mpv_free(cstr) }
        return String(cString: cstr)
    }

    private func getInt(_ h: OpaquePointer, _ name: String) -> Int {
        var v: Int64 = 0
        mpv_get_property(h, name, MPV_FORMAT_INT64, &v)
        return Int(v)
    }

    private func getFlag(_ h: OpaquePointer, _ name: String) -> Bool {
        var v: Int32 = 0
        mpv_get_property(h, name, MPV_FORMAT_FLAG, &v)
        return v != 0
    }

    private func drainEvents() {
        eventQueue.async { [weak self] in
            guard let self else { return }
            while let h = self.mpv {
                guard let event = mpv_wait_event(h, 0)?.pointee, event.event_id != MPV_EVENT_NONE else { break }
                self.process(event, h)
            }
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    private func process(_ event: mpv_event, _ h: OpaquePointer) {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data else { return }
            let prop = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            let name = String(cString: prop.name)
            switch name {
            case "time-pos":
                if let v = double(prop) { onMain { self.position = v } }
            case "duration":
                if let v = double(prop) { onMain { self.duration = v } }
            case "speed":
                if let v = double(prop) { onMain { self.speed = v } }
            case "pause":
                if let v = flag(prop) { onMain { self.paused = v } }
            case "paused-for-cache":
                if let v = flag(prop) { onMain { self.buffering = v } }
            case "eof-reached":
                if let v = flag(prop) { onMain { self.ended = v } }
            case "track-list/count", "aid", "sid":
                refreshTracks(h)
            default:
                break
            }
        case MPV_EVENT_FILE_LOADED:
            refreshTracks(h)
            onMain { self.onFileLoaded?() }
        case MPV_EVENT_PLAYBACK_RESTART:
            onMain {
                self.buffering = false
                self.started = true
            }
        case MPV_EVENT_END_FILE:
            guard let data = event.data else { return }
            let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            if end.reason == MPV_END_FILE_REASON_ERROR {
                let reason = String(cString: mpv_error_string(end.error))
                onMain {
                    self.buffering = false
                    self.errorMessage = "This stream couldn't be played (\(reason))."
                }
            }
        default:
            break
        }
    }

    private func double(_ prop: mpv_event_property) -> Double? {
        guard prop.format == MPV_FORMAT_DOUBLE, let d = prop.data else { return nil }
        return d.assumingMemoryBound(to: Double.self).pointee
    }

    private func flag(_ prop: mpv_event_property) -> Bool? {
        guard prop.format == MPV_FORMAT_FLAG, let d = prop.data else { return nil }
        return d.assumingMemoryBound(to: Int32.self).pointee != 0
    }

    private func refreshTracks(_ h: OpaquePointer) {
        var audio: [MPVTrack] = []
        var subs: [MPVTrack] = []
        let count = getInt(h, "track-list/count")
        for i in 0..<max(0, count) {
            let p = "track-list/\(i)"
            guard let type = getString(h, "\(p)/type") else { continue }
            let id = getInt(h, "\(p)/id")
            let lang = getString(h, "\(p)/lang")
            let title = getString(h, "\(p)/title")
            let codec = getString(h, "\(p)/codec")
            let selected = getFlag(h, "\(p)/selected")
            let external = getFlag(h, "\(p)/external")
            let forced = getFlag(h, "\(p)/forced")
            switch type {
            case "audio":
                let channels = getInt(h, "\(p)/demux-channel-count")
                audio.append(MPVTrack(id: id, title: Self.label(lang: lang, title: title, codec: codec,
                                                                channels: channels, extra: nil, fallback: "Track \(id)"),
                                      selected: selected))
            case "sub":
                var extra: [String] = []
                if forced { extra.append("Forced") }
                if external { extra.append("Addon") }
                subs.append(MPVTrack(id: id, title: Self.label(lang: lang, title: title, codec: nil, channels: 0,
                                                               extra: extra.isEmpty ? nil : extra.joined(separator: ", "),
                                                               fallback: "Subtitle \(id)"),
                                     selected: selected))
            default:
                break
            }
        }
        onMain {
            self.audioTracks = audio
            self.subtitleTracks = subs
        }
    }

    private static func label(lang: String?, title: String?, codec: String?, channels: Int,
                              extra: String?, fallback: String) -> String {
        var parts: [String] = []
        if let lang, !lang.isEmpty, lang != "und" {
            parts.append(Locale.current.localizedString(forLanguageCode: lang) ?? lang.uppercased())
        }
        if let title, !title.isEmpty, !parts.contains(title) { parts.append(title) }
        var tech: [String] = []
        if let codec, !codec.isEmpty { tech.append(codec.uppercased()) }
        switch channels {
        case 1: tech.append("Mono")
        case 2: tech.append("Stereo")
        case 6: tech.append("5.1")
        case 8: tech.append("7.1")
        default: break
        }
        if !tech.isEmpty { parts.append(tech.joined(separator: " ")) }
        if let extra { parts.append(extra) }
        return parts.isEmpty ? fallback : parts.joined(separator: " · ")
    }
}
