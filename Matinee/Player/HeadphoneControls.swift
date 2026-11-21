#if os(iOS)
import AVFoundation
import MediaPlayer
import UIKit

/// AirPods and headphone controls for a playing video.
///
/// - Play/pause from AirPods (press the stem), the Lock Screen and Control Center.
/// - Taking an AirPod out pauses; putting it back in resumes. iOS delivers both as
///   pause/play commands to the app showing in Now Playing.
/// - Headphones disconnecting (both AirPods out and in the case, Bluetooth dropping, a
///   wired pair unplugged) pauses, and resumes if they come back within a few minutes.
@MainActor
final class HeadphoneControls {
    struct Actions {
        var play: () -> Void
        var pause: () -> Void
        var isPaused: () -> Bool
        var skip: ((Double) -> Void)? = nil
        var seek: ((Double) -> Void)? = nil
    }

    private let actions: Actions
    private let title: String
    private let subtitle: String?
    /// Off for Apple's player, which already answers remote commands and keeps Now Playing current.
    private let handlesCommands: Bool
    private var targets: [(MPRemoteCommand, Any)] = []
    private var routeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var pausedByRouteAt: Date?
    private var lastPlaying = false
    private var active = true

    /// How long after headphones disconnect we still resume when they come back.
    private static let resumeWindow: TimeInterval = 5 * 60

    init(title: String, subtitle: String?, handlesCommands: Bool, actions: Actions) {
        self.title = title
        self.subtitle = subtitle
        self.handlesCommands = handlesCommands
        self.actions = actions
        if handlesCommands { registerCommands() }
        observeAudioSession()
    }

    // MARK: Remote commands (AirPods, Lock Screen, Control Center)

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()

        add(center.playCommand) { [weak self] in
            self?.pausedByRouteAt = nil
            self?.actions.play()
        }
        add(center.pauseCommand) { [weak self] in
            self?.actions.pause()
        }
        add(center.togglePlayPauseCommand) { [weak self] in
            guard let self else { return }
            self.pausedByRouteAt = nil
            if self.actions.isPaused() { self.actions.play() } else { self.actions.pause() }
        }

        if let skip = actions.skip {
            let saved = UserDefaults.standard.integer(forKey: Pref.skipSeconds)
            let seconds = Double(saved > 0 ? saved : 10)
            center.skipForwardCommand.preferredIntervals = [NSNumber(value: seconds)]
            center.skipBackwardCommand.preferredIntervals = [NSNumber(value: seconds)]
            add(center.skipForwardCommand) { skip(seconds) }
            add(center.skipBackwardCommand) { skip(-seconds) }
        }

        if let seek = actions.seek {
            let command = center.changePlaybackPositionCommand
            command.isEnabled = true
            let token = command.addTarget { event in
                guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                MainActor.assumeIsolated { seek(event.positionTime) }
                return .success
            }
            targets.append((command, token))
        }
    }

    private func add(_ command: MPRemoteCommand, _ handler: @escaping @MainActor () -> Void) {
        command.isEnabled = true
        let token = command.addTarget { _ in
            MainActor.assumeIsolated { handler() }
            return .success
        }
        targets.append((command, token))
    }

    /// Keeps the Lock Screen / Control Center card current. Call about once a second.
    func update(position: Double, duration: Double, playing: Bool) {
        guard active else { return }
        lastPlaying = playing
        guard handlesCommands else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        if position.isFinite { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, position) }
        if duration.isFinite, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = playing ? .playing : .paused
    }

    // MARK: Headphones connecting and disconnecting

    private func observeAudioSession() {
        let center = NotificationCenter.default
        routeObserver = center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                           object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.routeChanged(note) }
        }
        interruptionObserver = center.addObserver(forName: AVAudioSession.interruptionNotification,
                                                  object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.interrupted(note) }
        }
    }

    private func routeChanged(_ note: Notification) {
        guard active,
              let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        switch reason {
        case .oldDeviceUnavailable:
            let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            guard let previous, Self.hasHeadphones(previous) else { return }
            // Don't let the movie suddenly play out of the speaker. Apple's player may have
            // paused itself already, so go by whether it was playing a moment ago.
            if lastPlaying || !actions.isPaused() {
                actions.pause()
                lastPlaying = false
                pausedByRouteAt = Date()
            }
        case .newDeviceAvailable:
            guard let at = pausedByRouteAt, Date().timeIntervalSince(at) < Self.resumeWindow,
                  Self.hasHeadphones(AVAudioSession.sharedInstance().currentRoute) else { return }
            pausedByRouteAt = nil
            // Give the AirPods a moment to finish connecting so the first second isn't lost.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.active, self.actions.isPaused() else { return }
                self.actions.play()
            }
        default:
            break
        }
    }

    private func interrupted(_ note: Notification) {
        guard active, handlesCommands,
              let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // A call or Siri took the audio.
            actions.pause()
        case .ended:
            let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            if opts.contains(.shouldResume) {
                try? AVAudioSession.sharedInstance().setActive(true)
                actions.play()
            }
        @unknown default:
            break
        }
    }

    private static func hasHeadphones(_ route: AVAudioSessionRouteDescription) -> Bool {
        let kinds: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio]
        return route.outputs.contains { kinds.contains($0.portType) }
    }

    // MARK: Teardown

    /// Call when the player closes, so the controls stop pointing at it.
    func invalidate() {
        guard active else { return }
        active = false
        for (command, token) in targets { command.removeTarget(token) }
        targets.removeAll()
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        routeObserver = nil
        interruptionObserver = nil
        if handlesCommands {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }
    }
}
#endif
