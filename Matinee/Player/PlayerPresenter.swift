import AVKit
import UIKit

struct PlaybackRequest {
    var url: URL
    var headers: [String: String] = [:]
    var title: String
    var subtitle: String? = nil
    var filenameHint: String? = nil
    /// Seconds.
    var startAt: Double = 0
    /// Present for Stremio titles, so progress can sync; nil for local files.
    var seed: LibrarySeed? = nil
    var videoId: String? = nil
    var nextVideoId: String? = nil
    var subtitleLoader: (() async -> [AddonSubtitle])? = nil

    /// Key for the on-device resume point.
    var resumeKey: String { videoId ?? "file:" + url.lastPathComponent }

    /// Apple's player for formats it handles natively (AirPlay, PiP, Dolby audio passthrough);
    /// mpv for MKV and anything else it can't open.
    var automaticEngine: PlayerEngine {
        let name = (filenameHint ?? url.lastPathComponent).lowercased()
        let ext = (name as NSString).pathExtension
        // Audio formats AVPlayer can't decode would play silently, so send those to mpv.
        if name.contains("truehd") || name.contains("dts") { return .mpv }
        let apple: Set<String> = ["mp4", "m4v", "mov", "m3u8", "mp3", "m4a", "aac", "wav", "caf"]
        let mpv: Set<String> = ["mkv", "mka", "avi", "webm", "flv", "wmv", "asf", "ts", "m2ts", "mts", "mpg",
                                "mpeg", "vob", "ogv", "ogg", "divx", "xvid", "rm", "rmvb", "3gp", "iso", "flac", "opus"]
        if apple.contains(ext) { return .apple }
        if mpv.contains(ext) { return .mpv }
        // Unknown (many debrid links have no extension): try Apple first, mpv takes over if it fails.
        return .apple
    }
}

/// Tracks one playback for resume and Stremio progress, whichever player is showing it.
@MainActor
final class PlaybackSession {
    let request: PlaybackRequest
    private weak var model: AppModel?
    private var unsyncedWatched: Double = 0
    private var lastPosition: Double?
    private var lastSync = Date()
    private var finished = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0

    init(request: PlaybackRequest, model: AppModel?) {
        self.request = request
        self.model = model
        self.position = request.startAt
    }

    /// Called about once a second by the player.
    func tick(position: Double, duration: Double, playing: Bool, keepAwake: Bool? = nil) {
        // Keep the screen from dimming and locking while the video is playing; a paused video can sleep as usual.
        let awake = !finished && (keepAwake ?? playing)
        if UIApplication.shared.isIdleTimerDisabled != awake { UIApplication.shared.isIdleTimerDisabled = awake }
        guard position.isFinite else { return }
        // Count only normal playback as watched time, never jumps from seeking.
        if playing, let last = lastPosition, position > last, position - last < 3 {
            unsyncedWatched += position - last
        }
        lastPosition = position
        self.position = position
        if duration.isFinite, duration > 0 { self.duration = duration }
        if Date().timeIntervalSince(lastSync) > 60 { sync(closing: false) }
    }

    func seeked(to position: Double) {
        lastPosition = position
        self.position = position
    }

    func finish() {
        guard !finished else { return }
        finished = true
        UIApplication.shared.isIdleTimerDisabled = false
        let nearEnd = duration > 0 && position > duration * ProgressRules.creditsThreshold
        LocalResume.save(nearEnd || position < 5 ? nil : position, for: request.resumeKey)
        sync(closing: true)
    }

    private func sync(closing: Bool) {
        lastSync = Date()
        guard let seed = request.seed, let videoId = request.videoId, position > 0 || unsyncedWatched > 0 else { return }
        model?.saveProgress(seed: seed, videoId: videoId,
                            positionMs: UInt64(max(0, position) * 1000),
                            durationMs: UInt64(max(0, duration) * 1000),
                            watchedMs: UInt64(unsyncedWatched * 1000),
                            closing: closing, nextVideoId: request.nextVideoId)
        unsyncedWatched = 0
    }
}

@MainActor
final class PlayerPresenter {
    static let shared = PlayerPresenter()
    weak var model: AppModel?

    private var session: PlaybackSession?
    private var scopedURL: URL?

    func play(_ request: PlaybackRequest, engine: PlayerEngine? = nil) {
        if let session { session.finish() }
        let session = PlaybackSession(request: request, model: model)
        self.session = session
        try? AVAudioSession.sharedInstance().setActive(true)

        let choice = engine ?? Pref.currentEngine
        let useMPV: Bool
        switch choice {
        case .mpv: useMPV = true
        case .apple: useMPV = false
        case .automatic: useMPV = request.automaticEngine == .mpv
        }
        if useMPV {
            presentMPV(session, startAt: request.startAt, notice: nil)
        } else {
            presentApple(session)
        }
    }

    func playLocalFile(_ url: URL) {
        stopScopedAccess()
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        var request = PlaybackRequest(url: url, title: url.deletingPathExtension().lastPathComponent)
        request.startAt = LocalResume.position(for: request.resumeKey) ?? 0
        play(request)
    }

    // MARK: Apple player

    private func presentApple(_ session: PlaybackSession) {
        let vc = ApplePlayerViewController(session: session)
        vc.onFailure = { [weak self, weak vc] position in
            guard let self else { return }
            let resumeAt = max(position, session.request.startAt)
            if let vc, vc.presentingViewController != nil {
                vc.dismiss(animated: false) {
                    self.presentMPV(session, startAt: resumeAt, notice: "Switched to mpv for this file.")
                }
            } else {
                self.presentMPV(session, startAt: resumeAt, notice: "Switched to mpv for this file.")
            }
        }
        vc.onClose = { [weak self] in self?.end(session) }
        present(vc)
    }

    // MARK: mpv

    private func presentMPV(_ session: PlaybackSession, startAt: Double, notice: String?) {
        #if os(tvOS)
        // Ask for every channel HDMI offers, so mpv can send 5.1/7.1 to the TV or receiver.
        let audio = AVAudioSession.sharedInstance()
        try? audio.setPreferredOutputNumberOfChannels(audio.maximumOutputNumberOfChannels)
        #endif
        let vc = MPVPlayerViewController(session: session, startAt: startAt, notice: notice)
        vc.onClose = { [weak self] in self?.end(session) }
        present(vc)
    }

    // MARK: Helpers

    private func end(_ session: PlaybackSession) {
        session.finish()
        if self.session === session {
            self.session = nil
            stopScopedAccess()
        }
    }

    private func stopScopedAccess() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    private func present(_ vc: UIViewController) {
        vc.modalPresentationStyle = .fullScreen
        guard let top = Self.topViewController() else { return }
        top.present(vc, animated: true)
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

/// Apple's own player, with Picture in Picture and AirPlay.
final class ApplePlayerViewController: AVPlayerViewController, AVPlayerViewControllerDelegate {
    let session: PlaybackSession
    var onClose: (() -> Void)?
    var onFailure: ((Double) -> Void)?

    private var statusObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var didStart = false
    private var handingOff = false
    private var closed = false
    private var appeared = false
    private var failedBeforeAppearing = false

    init(session: PlaybackSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    #if os(iOS)
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .phone ? .allButUpsideDown : .all
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        UIDevice.current.userInterfaceIdiom == .phone ? .landscapeRight : super.preferredInterfaceOrientationForPresentation
    }
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        allowsPictureInPicturePlayback = true
        #if os(iOS)
        canStartPictureInPictureAutomaticallyFromInline = true
        updatesNowPlayingInfoCenter = true
        #endif

        let request = session.request
        var options: [String: Any] = [:]
        if !request.headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = request.headers }
        let asset = AVURLAsset(url: request.url, options: options)
        let item = AVPlayerItem(asset: asset)
        item.externalMetadata = Self.metadata(title: request.title, subtitle: request.subtitle)

        let player = AVPlayer(playerItem: item)
        #if os(iOS)
        player.allowsExternalPlayback = true
        #endif
        self.player = player

        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async { self?.statusChanged(item) }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600),
                                                      queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportTime() }
        }
    }

    private static func metadata(title: String, subtitle: String?) -> [AVMetadataItem] {
        let t = AVMutableMetadataItem()
        t.identifier = .commonIdentifierTitle
        t.value = title as NSString
        t.extendedLanguageTag = "und"
        var items: [AVMetadataItem] = [t]
        if let subtitle {
            let s = AVMutableMetadataItem()
            s.identifier = .iTunesMetadataTrackSubTitle
            s.value = subtitle as NSString
            s.extendedLanguageTag = "und"
            items.append(s)
        }
        return items
    }

    private func statusChanged(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay where !didStart:
            didStart = true
            let start = session.request.startAt
            if start > 1 {
                player?.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                             toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.session.seeked(to: start)
                        self?.player?.play()
                    }
                }
            } else {
                player?.play()
            }
        case .failed:
            handOffToMPV()
        default:
            break
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
        if failedBeforeAppearing { handOffToMPV() }
    }

    private func handOffToMPV() {
        // Wait until the presentation finishes; dismissing mid-animation is ignored by UIKit.
        guard appeared else { failedBeforeAppearing = true; return }
        guard !handingOff, !closed else { return }
        handingOff = true
        let position = player?.currentTime().seconds ?? 0
        cleanup()
        onFailure?(position.isFinite ? position : 0)
    }

    private func reportTime() {
        guard let player, let item = player.currentItem, didStart else { return }
        let pos = player.currentTime().seconds
        let dur = item.duration.seconds
        session.tick(position: pos, duration: dur.isFinite ? dur : 0, playing: player.rate > 0)
    }

    private func cleanup() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil, !handingOff, !closed else { return }
        closed = true
        reportTime()
        cleanup()
        player?.replaceCurrentItem(with: nil)
        onClose?()
    }

    // Keep the player on screen when Picture in Picture starts, so closing PiP returns here.
    func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool {
        false
    }

    func playerViewController(_ playerViewController: AVPlayerViewController,
                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}
