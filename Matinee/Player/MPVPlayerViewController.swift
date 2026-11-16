import SwiftUI
import UIKit

/// Full-screen mpv player: a Metal video layer with SwiftUI controls on top.
final class MPVPlayerViewController: UIViewController {
    let session: PlaybackSession
    let player = MPVPlayer()
    var onClose: (() -> Void)?

    private let startAt: Double
    private let notice: String?
    private let videoView = UIView()
    private var timer: Timer?
    private var closed = false
    private var addedSubtitles = false

    init(session: PlaybackSession, startAt: Double, notice: String?) {
        self.session = session
        self.startAt = startAt
        self.notice = notice
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .phone ? .landscape : .all
    }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        UIDevice.current.userInterfaceIdiom == .phone ? .landscapeRight : super.preferredInterfaceOrientationForPresentation
    }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        videoView.backgroundColor = .black
        videoView.frame = view.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(videoView)
        player.layer.frame = videoView.bounds
        player.layer.contentsScale = traitCollection.displayScale
        videoView.layer.addSublayer(player.layer)

        let request = session.request
        let controls = MPVControlsView(
            player: player,
            title: request.title,
            subtitle: request.subtitle,
            notice: notice,
            canHandOff: !request.url.isFileURL,
            onClose: { [weak self] in self?.close() },
            onOpenIn: { [weak self] app in self?.openIn(app) },
            onSeek: { [weak self] seconds in self?.session.seeked(to: seconds) }
        )
        let host = UIHostingController(rootView: controls)
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let defaults = UserDefaults.standard
        let options = MPVPlayer.Options(
            hardwareDecoding: defaults.bool(forKey: Pref.hardwareDecoding),
            audioLanguages: defaults.string(forKey: Pref.audioLanguages) ?? "en,eng",
            subtitleLanguages: defaults.string(forKey: Pref.subtitleLanguages) ?? "en,eng",
            autoSubtitles: defaults.bool(forKey: Pref.autoSubtitles)
        )
        player.onFileLoaded = { [weak self] in self?.loadAddonSubtitles() }
        player.start(url: request.url, headers: request.headers, startAt: startAt, options: options)

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(willEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        player.layer.frame = videoView.bounds
        player.layer.contentsScale = traitCollection.displayScale
        CATransaction.commit()
    }

    private func report() {
        guard player.started else { return }
        session.tick(position: player.position, duration: player.duration, playing: !player.paused && !player.buffering)
    }

    private func loadAddonSubtitles() {
        guard !addedSubtitles, let loader = session.request.subtitleLoader else { return }
        addedSubtitles = true
        Task { [weak self] in
            let subs = await loader()
            guard let self, !self.closed else { return }
            // A few per language keeps the menu usable.
            var perLanguage: [String: Int] = [:]
            for sub in subs {
                let count = perLanguage[sub.lang, default: 0]
                guard count < 3 else { continue }
                perLanguage[sub.lang] = count + 1
                let name = Locale.current.localizedString(forLanguageCode: sub.lang) ?? sub.lang
                self.player.addSubtitle(url: sub.url, title: "\(name) \(count + 1)", lang: sub.lang)
            }
        }
    }

    @objc private func didEnterBackground() {
        player.pause()
        player.setVideoEnabled(false)
    }

    @objc private func willEnterForeground() {
        player.setVideoEnabled(true)
    }

    private func close() {
        guard !closed else { return }
        closed = true
        report()
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self)
        player.shutdown()
        onClose?()
        dismiss(animated: true)
    }

    enum ExternalApp { case infuse, vlc }

    private func openIn(_ app: ExternalApp) {
        let url = session.request.url
        let encoded = AddonClient.encode(url.absoluteString)
        let link = app == .infuse
            ? "infuse://x-callback-url/play?url=\(encoded)"
            : "vlc-x-callback://x-callback-url/stream?url=\(encoded)"
        guard let target = URL(string: link) else { return }
        close()
        UIApplication.shared.open(target)
    }
}

struct MPVControlsView: View {
    @ObservedObject var player: MPVPlayer
    let title: String
    let subtitle: String?
    let notice: String?
    let canHandOff: Bool
    let onClose: () -> Void
    let onOpenIn: (MPVPlayerViewController.ExternalApp) -> Void
    let onSeek: (Double) -> Void

    @AppStorage(Pref.skipSeconds) private var skipSeconds = 10
    @State private var visible = true
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var interaction = 0
    @State private var flash: String?
    @State private var showNotice = true

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture(count: 2)
                            .onEnded { value in
                                let forward = value.location.x > geo.size.width / 2
                                skip(forward ? Double(skipSeconds) : -Double(skipSeconds))
                            }
                            .exclusively(before: TapGesture().onEnded {
                                withAnimation(.easeOut(duration: 0.2)) { visible.toggle() }
                                poke()
                            })
                    )

                if (player.buffering || !player.started) && player.errorMessage == nil {
                    ProgressView().controlSize(.large).tint(.white)
                }

                if let flash {
                    Text(flash)
                        .font(.headline)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.opacity)
                }

                if visible && player.errorMessage == nil {
                    controls(geo)
                        .transition(.opacity)
                }

                if let error = player.errorMessage {
                    errorOverlay(error)
                }

                if let notice, showNotice {
                    VStack {
                        Text(notice)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.top, 60)
                        Spacer()
                    }
                    .task {
                        try? await Task.sleep(for: .seconds(4))
                        withAnimation { showNotice = false }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .task(id: interaction) {
            // Hide the controls a few seconds after the last touch while playing.
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !player.paused, !scrubbing else { return }
            withAnimation(.easeOut(duration: 0.3)) { visible = false }
        }
        .statusBarHidden()
    }

    private func poke() { interaction += 1 }

    private func skip(_ seconds: Double) {
        player.skip(seconds)
        onSeek(max(0, player.position + seconds))
        withAnimation { flash = seconds > 0 ? "+\(Int(seconds))s" : "−\(Int(-seconds))s" }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation { flash = nil }
        }
        poke()
    }

    @ViewBuilder
    private func controls(_ geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(alignment: .center, spacing: 16) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.caption).opacity(0.75).lineLimit(1) }
                }
                Spacer()
                trackMenu
                speedMenu
                if canHandOff {
                    Menu {
                        Button("Open in Infuse") { onOpenIn(.infuse) }
                        Button("Open in VLC") { onOpenIn(.vlc) }
                    } label: {
                        Image(systemName: "arrow.up.forward.app").font(.title3).frame(width: 44, height: 44)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea())

            Spacer()

            // Center transport
            HStack(spacing: geo.size.width > 600 ? 80 : 50) {
                Button { skip(-Double(skipSeconds)) } label: {
                    Image(systemName: "gobackward.\(skipSeconds)").font(.system(size: 34, weight: .medium))
                }
                Button {
                    player.togglePause()
                    poke()
                } label: {
                    Image(systemName: player.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 50, weight: .medium))
                        .frame(width: 70, height: 70)
                        .contentTransition(.symbolEffect(.replace))
                }
                Button { skip(Double(skipSeconds)) } label: {
                    Image(systemName: "goforward.\(skipSeconds)").font(.system(size: 34, weight: .medium))
                }
            }
            .opacity(player.buffering && !player.paused ? 0 : 1)

            Spacer()

            // Scrubber
            VStack(spacing: 6) {
                Slider(value: Binding(
                    get: { scrubbing ? scrubValue : player.position },
                    set: { scrubValue = $0 }
                ), in: 0...max(player.duration, 1), onEditingChanged: { editing in
                    if editing {
                        scrubbing = true
                    } else {
                        player.seek(to: scrubValue)
                        onSeek(scrubValue)
                        scrubbing = false
                    }
                    poke()
                })
                .tint(Theme.accent)
                HStack {
                    Text(Format.clock(scrubbing ? scrubValue : player.position))
                    Spacer()
                    Text("-" + Format.clock(max(0, player.duration - (scrubbing ? scrubValue : player.position))))
                }
                .font(.caption.monospacedDigit())
                .opacity(0.85)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea())
        }
    }

    private var trackMenu: some View {
        Menu {
            if !player.audioTracks.isEmpty {
                Section("Audio") {
                    ForEach(player.audioTracks) { track in
                        Button {
                            player.selectAudio(track.id)
                        } label: {
                            if track.selected { Label(track.title, systemImage: "checkmark") } else { Text(track.title) }
                        }
                    }
                }
            }
            Section("Subtitles") {
                Button {
                    player.selectSubtitle(nil)
                } label: {
                    if player.subtitleTracks.contains(where: \.selected) { Text("Off") } else { Label("Off", systemImage: "checkmark") }
                }
                ForEach(player.subtitleTracks) { track in
                    Button {
                        player.selectSubtitle(track.id)
                    } label: {
                        if track.selected { Label(track.title, systemImage: "checkmark") } else { Text(track.title) }
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble").font(.title3).frame(width: 44, height: 44)
        }
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                Button {
                    player.setSpeed(rate)
                } label: {
                    let label = rate == 1 ? "Normal" : String(format: "%gx", rate)
                    if abs(player.speed - rate) < 0.01 { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
        } label: {
            Image(systemName: "gauge.with.dots.needle.67percent").font(.title3).frame(width: 44, height: 44)
        }
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(Theme.accent)
            Text(message).font(.headline).multilineTextAlignment(.center)
            Text("The link may have expired or the addon's server may be down. Try another stream.")
                .font(.subheadline).opacity(0.75).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Close", action: onClose).buttonStyle(.borderedProminent).foregroundStyle(.black)
                if canHandOff {
                    Button("Open in Infuse") { onOpenIn(.infuse) }.buttonStyle(.bordered)
                }
            }
        }
        .padding(30)
        .frame(maxWidth: 460)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
