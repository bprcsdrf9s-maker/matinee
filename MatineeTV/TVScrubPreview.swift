import Foundation
import UIKit
import Libmpv

/// Preview frames for the scrub bar, like the Apple TV app's thumbnails.
/// A second, silent mpv instance opens the same stream paused and renders the nearest keyframe
/// in software into memory whenever the scrub marker moves. Only the newest request is kept,
/// so fast swipes skip straight to where the marker stops.
final class MPVThumbnailer: @unchecked Sendable {
    /// Called on the main thread with a frame and the time it was asked for.
    var onImage: ((UIImage, Double) -> Void)?

    private let queue = DispatchQueue(label: "matinee.thumbnails", qos: .userInitiated)
    private var mpv: OpaquePointer?
    private var render: OpaquePointer?
    private var loaded = false
    private var seeking = false
    private var pending: Double?
    private var inFlight: Double?
    private var closed = false

    private let width: Int32 = 400
    private let height: Int32 = 225
    private var buffer: UnsafeMutableRawPointer
    private let apiType = strdup("sw")
    private let pixelFormat = strdup("bgr0")

    init(url: URL, headers: [String: String]) {
        buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(width) * Int(height) * 4, alignment: 64)
        queue.async { self.setUp(url: url, headers: headers) }
    }

    deinit {
        buffer.deallocate()
        free(apiType)
        free(pixelFormat)
    }

    /// Ask for the frame at this time. Cheap to call on every marker move.
    func request(_ seconds: Double) {
        queue.async {
            guard !self.closed else { return }
            self.pending = max(0, seconds)
            self.next()
        }
    }

    /// Frees mpv. The object can be dropped right after.
    func close() {
        queue.async {
            guard !self.closed else { return }
            self.closed = true
            if let render = self.render {
                mpv_render_context_set_update_callback(render, nil, nil)
                mpv_render_context_free(render)
            }
            self.render = nil
            if let h = self.mpv {
                mpv_set_wakeup_callback(h, nil, nil)
                mpv_terminate_destroy(h)
            }
            self.mpv = nil
        }
    }

    // MARK: Setup

    private func setUp(url: URL, headers: [String: String]) {
        guard !closed, let h = mpv_create() else { return }
        mpv = h
        func opt(_ name: String, _ value: String) { mpv_set_option_string(h, name, value) }
        opt("vo", "libmpv")
        opt("hwdec", "videotoolbox-copy")
        opt("aid", "no")
        opt("sid", "no")
        opt("audio-display", "no")
        opt("pause", "yes")
        opt("hr-seek", "no")
        opt("keep-open", "yes")
        opt("ytdl", "no")
        opt("cache", "yes")
        opt("demuxer-max-bytes", "24MiB")
        opt("demuxer-max-back-bytes", "4MiB")
        opt("demuxer-readahead-secs", "1")
        opt("network-timeout", "20")
        opt("sws-scaler", "fast-bilinear")
        for (name, value) in headers where !name.isEmpty {
            opt("http-header-fields-append", "\(name): \(value)")
        }
        guard mpv_initialize(h) >= 0 else { return }

        var params = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiType)),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
        ]
        var ctx: OpaquePointer?
        guard mpv_render_context_create(&ctx, h, &params) >= 0, let ctx else { return }
        render = ctx
        let me = Unmanaged.passUnretained(self).toOpaque()
        mpv_render_context_set_update_callback(ctx, { raw in
            guard let raw else { return }
            Unmanaged<MPVThumbnailer>.fromOpaque(raw).takeUnretainedValue().frameMayBeReady()
        }, me)
        mpv_set_wakeup_callback(h, { raw in
            guard let raw else { return }
            Unmanaged<MPVThumbnailer>.fromOpaque(raw).takeUnretainedValue().drainEvents()
        }, me)

        let target = url.isFileURL ? url.path : url.absoluteString
        command(["loadfile", target, "replace"])
    }

    // MARK: Seeking

    private func next() {
        guard loaded, !seeking, let target = pending else { return }
        pending = nil
        if let last = inFlight, abs(last - target) < 1 { return }
        inFlight = target
        seeking = true
        command(["seek", String(format: "%.2f", target), "absolute+keyframes"])
    }

    private func drainEvents() {
        queue.async {
            while let h = self.mpv, !self.closed {
                guard let event = mpv_wait_event(h, 0)?.pointee, event.event_id != MPV_EVENT_NONE else { break }
                switch event.event_id {
                case MPV_EVENT_FILE_LOADED:
                    self.loaded = true
                    self.next()
                case MPV_EVENT_PLAYBACK_RESTART:
                    // The seek landed; its frame arrives through the render callback.
                    self.seeking = false
                    self.next()
                case MPV_EVENT_END_FILE:
                    self.seeking = false
                default:
                    break
                }
            }
        }
    }

    // MARK: Rendering

    private func frameMayBeReady() {
        queue.async {
            guard !self.closed, let ctx = self.render else { return }
            let flags = mpv_render_context_update(ctx)
            guard flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }
            self.draw(ctx)
        }
    }

    private func draw(_ ctx: OpaquePointer) {
        var size: [Int32] = [width, height]
        var stride = Int(width) * 4
        size.withUnsafeMutableBufferPointer { sizePtr in
            withUnsafeMutablePointer(to: &stride) { stridePtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(sizePtr.baseAddress)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(pixelFormat)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stridePtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: buffer),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                _ = mpv_render_context_render(ctx, &params)
            }
        }
        guard let image = makeImage(), let time = inFlight else { return }
        let handler = onImage
        DispatchQueue.main.async { handler?(image, time) }
    }

    private func makeImage() -> UIImage? {
        let bytes = Int(width) * Int(height) * 4
        let data = Data(bytes: buffer, count: bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let cg = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: Int(width) * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg)
    }

    private func command(_ args: [String]) {
        guard let h = mpv else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { for p in cargs where p != nil { free(UnsafeMutablePointer(mutating: p)) } }
        _ = mpv_command_async(h, 0, &cargs)
    }
}
