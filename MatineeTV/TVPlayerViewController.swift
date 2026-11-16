import SwiftUI
import UIKit
import Combine

/// Full-screen mpv player for Apple TV, driven by the Siri Remote:
/// click or Play/Pause to pause, left/right to skip, down for audio and subtitles, Back to close.
final class MPVPlayerViewController: UIViewController {
    let session: PlaybackSession
    let player = MPVPlayer()
    var onClose: (() -> Void)?

    private let startAt: Double
    private let notice: String?
    private let videoView = UIView()
    private var host: UIHostingController<TVMPVControlsView>?
    private var timer: Timer?
    private var closed = false
    private var addedSubtitles = false
    private var errorWatch: AnyCancellable?

    init(session: PlaybackSession, startAt: Double, notice: String?) {
        self.session = session
        self.startAt = startAt
        self.notice = notice
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        host.map { [$0] } ?? super.preferredFocusEnvironments
    }

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
        let controls = TVMPVControlsView(
            player: player,
            title: request.title,
            subtitle: request.subtitle,
            notice: notice,
            canHandOff: !request.url.isFileURL,
            onClose: { [weak self] in self?.close() },
            onOpenInInfuse: { [weak self] in self?.openInInfuse() },
            onSeek: { [weak self] seconds in self?.session.seeked(to: seconds) }
        )
        let host = UIHostingController(rootView: controls)
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        self.host = host

        let defaults = UserDefaults.standard
        let options = MPVPlayer.Options(
            hardwareDecoding: defaults.bool(forKey: Pref.hardwareDecoding),
            audioLanguages: defaults.string(forKey: Pref.audioLanguages) ?? "en,eng",
            subtitleLanguages: defaults.string(forKey: Pref.subtitleLanguages) ?? "en,eng",
            autoSubtitles: defaults.bool(forKey: Pref.autoSubtitles)
        )
        player.onFileLoaded = { [weak self] in self?.loadAddonSubtitles() }
        // A stream that fails here is hidden from the stream list for a week.
        let failedURL = request.url
        errorWatch = player.$errorMessage
            .compactMap { $0 }
            .first()
            .sink { _ in BadStreams.mark(failedURL) }
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

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // If the system dismissed the player (Back pressed with nothing focused), still stop and save progress.
        if isBeingDismissed || presentingViewController == nil { teardown() }
    }

    private func report() {
        guard player.started else { return }
        session.tick(position: player.position, duration: player.duration, playing: !player.paused && !player.buffering,
                     keepAwake: !player.paused)
    }

    private func loadAddonSubtitles() {
        guard !addedSubtitles, let loader = session.request.subtitleLoader else { return }
        addedSubtitles = true
        Task { [weak self] in
            let subs = await loader()
            guard let self, !self.closed else { return }
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

    private func teardown() {
        guard !closed else { return }
        closed = true
        report()
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self)
        player.shutdown()
        onClose?()
    }

    private func close() {
        teardown()
        if presentingViewController != nil { dismiss(animated: true) }
    }

    private func openInInfuse() {
        let encoded = AddonClient.encode(session.request.url.absoluteString)
        guard let target = URL(string: "infuse://x-callback-url/play?url=\(encoded)") else { return }
        close()
        UIApplication.shared.open(target)
    }
}

/// Draws nothing for a button that only exists to receive remote presses.
private struct InvisibleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

struct TVMPVControlsView: View {
    @ObservedObject var player: MPVPlayer
    let title: String
    let subtitle: String?
    let notice: String?
    let canHandOff: Bool
    let onClose: () -> Void
    let onOpenInInfuse: () -> Void
    let onSeek: (Double) -> Void

    @AppStorage(Pref.skipSeconds) private var skipSeconds = 10
    @State private var overlay = true
    @State private var panel = false
    @State private var interaction = 0
    @State private var flash: String?
    @State private var showNotice = true
    @FocusState private var focus: Focus?

    private enum Focus: Hashable {
        case surface
        case option(String)
        case errorClose
    }

    var body: some View {
        ZStack {
            // Takes the remote's presses while nothing else is on screen.
            Button {
                player.togglePause()
                showOverlay()
            } label: {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(InvisibleButtonStyle())
            .focused($focus, equals: .surface)
            .disabled(panel || player.errorMessage != nil)
            .onMoveCommand(perform: move)

            if (player.buffering || !player.started) && player.errorMessage == nil {
                ProgressView().scaleEffect(1.5)
            }

            if player.paused && player.started && !panel && player.errorMessage == nil {
                Image(systemName: "pause.fill")
                    .font(.system(size: 80, weight: .semibold))
                    .padding(40)
                    .background(.ultraThinMaterial, in: Circle())
                    .transition(.opacity)
            }

            if let flash {
                Text(flash)
                    .font(.title2.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 30).padding(.vertical, 16)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
            }

            if overlay && !panel && player.errorMessage == nil {
                bottomBar.transition(.opacity)
            }

            if panel {
                HStack {
                    Spacer()
                    optionsPanel
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if let error = player.errorMessage {
                errorOverlay(error)
            }

            if let notice, showNotice {
                VStack {
                    Text(notice)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 26).padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }
                .task {
                    try? await Task.sleep(for: .seconds(5))
                    withAnimation { showNotice = false }
                }
            }
        }
        .foregroundStyle(.white)
        .onPlayPauseCommand {
            player.togglePause()
            showOverlay()
        }
        .onExitCommand(perform: exit)
        .onAppear { focus = .surface }
        .onChange(of: player.errorMessage) { _, message in
            if message != nil { focus = .errorClose }
        }
        .task(id: interaction) {
            // Hide the bar a few seconds after the last press while playing.
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, !player.paused, !panel else { return }
            withAnimation(.easeOut(duration: 0.4)) { overlay = false }
        }
        .animation(.easeInOut(duration: 0.25), value: panel)
        .animation(.easeInOut(duration: 0.2), value: player.paused)
    }

    // MARK: Remote

    private func showOverlay() {
        withAnimation(.easeOut(duration: 0.2)) { overlay = true }
        interaction += 1
    }

    private func move(_ direction: MoveCommandDirection) {
        switch direction {
        case .left: skip(-Double(skipSeconds))
        case .right: skip(Double(skipSeconds))
        case .down: openPanel()
        case .up: showOverlay()
        @unknown default: break
        }
    }

    private func exit() {
        if panel {
            panel = false
            focus = .surface
            showOverlay()
        } else if overlay && !player.paused {
            withAnimation(.easeOut(duration: 0.3)) { overlay = false }
        } else {
            onClose()
        }
    }

    private func skip(_ seconds: Double) {
        player.skip(seconds)
        onSeek(max(0, player.position + seconds))
        withAnimation { flash = seconds > 0 ? "+\(Int(seconds))s" : "−\(Int(-seconds))s" }
        let shown = flash
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            if flash == shown { withAnimation { flash = nil } }
        }
        showOverlay()
    }

    private func openPanel() {
        panel = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            let first = player.audioTracks.first(where: \.selected).map { "a\($0.id)" }
                ?? player.subtitleTracks.first(where: \.selected).map { "s\($0.id)" }
                ?? "s-off"
            focus = .option(first)
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.bold)).lineLimit(1)
                if let subtitle { Text(subtitle).font(.callout).opacity(0.8).lineLimit(1) }
            }
            GeometryReader { geo in
                let fraction = player.duration > 0 ? min(1, max(0, player.position / player.duration)) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3))
                    Capsule().fill(.white).frame(width: max(10, geo.size.width * fraction))
                }
            }
            .frame(height: 10)
            HStack {
                Text(Format.clock(player.position))
                Spacer()
                Text("◀︎ ▶︎ \(skipSeconds)s     ▼ Audio & Subtitles")
                    .opacity(0.7)
                Spacer()
                Text("-" + Format.clock(max(0, player.duration - player.position)))
            }
            .font(.caption.monospacedDigit())
        }
        .padding(.horizontal, 90)
        .padding(.bottom, 60)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                .frame(height: 420)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Audio, subtitles, speed

    private var optionsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !player.audioTracks.isEmpty {
                    header("Audio")
                    ForEach(player.audioTracks) { track in
                        option(track.title, id: "a\(track.id)", selected: track.selected) {
                            player.selectAudio(track.id)
                        }
                    }
                }

                header("Subtitles")
                option("Off", id: "s-off", selected: !player.subtitleTracks.contains(where: \.selected)) {
                    player.selectSubtitle(nil)
                }
                ForEach(player.subtitleTracks) { track in
                    option(track.title, id: "s\(track.id)", selected: track.selected) {
                        player.selectSubtitle(track.id)
                    }
                }

                header("Speed")
                ForEach([0.75, 1.0, 1.25, 1.5], id: \.self) { rate in
                    option(rate == 1 ? "Normal" : String(format: "%gx", rate), id: "r\(rate)",
                           selected: abs(player.speed - rate) < 0.01) {
                        player.setSpeed(rate)
                    }
                }

                if canHandOff {
                    header("Other Apps")
                    option("Open in Infuse", id: "infuse", selected: false, action: onOpenInInfuse)
                }
            }
            .padding(40)
        }
        .frame(width: 640)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .ignoresSafeArea()
        .focusSection()
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.callout.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.top, 20)
    }

    private func option(_ title: String, id: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                if selected { Image(systemName: "checkmark") }
            }
            .font(.callout)
        }
        .focused($focus, equals: .option(id))
    }

    // MARK: Errors

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 70)).foregroundStyle(Theme.accent)
            Text(message).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text("The link may have expired or the addon's server may be down. Try another stream.")
                .font(.callout).opacity(0.8).multilineTextAlignment(.center)
            HStack(spacing: 30) {
                Button("Close", action: onClose)
                    .focused($focus, equals: .errorClose)
                if canHandOff {
                    Button("Open in Infuse", action: onOpenInInfuse)
                }
            }
        }
        .padding(60)
        .frame(maxWidth: 900)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30))
    }
}
