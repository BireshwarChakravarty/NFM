import AppKit
import MediaPlayer

/// Publishes the current title to macOS Now Playing (Control Center, the menu
/// bar widget, the Lock Screen) and routes media keys, AirPods/headphone
/// controls and the Touch Bar to the Netflix player.
final class NowPlayingController {
    private let bridge: PlayerBridge
    private var enabled = false
    private var lastPublished: PlayerState?

    private lazy var artwork: MPMediaItemArtwork? = {
        guard let icon = NSApp.applicationIconImage else { return nil }
        return MPMediaItemArtwork(boundsSize: CGSize(width: 512, height: 512)) { _ in icon }
    }()

    init(bridge: PlayerBridge) {
        self.bridge = bridge
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on { registerCommands() } else { unregisterCommands(); clear() }
    }

    func update(with state: PlayerState) {
        guard enabled else { return }
        guard state.isActive else { clear(); return }

        // Avoid churning MediaRemote with identical updates.
        if let last = lastPublished,
           last.title == state.title, last.subtitle == state.subtitle,
           last.playing == state.playing, last.rate == state.rate,
           abs(last.duration - state.duration) < 1,
           abs((last.time + (last.playing ? 1 : 0)) - state.time) < 2.5 {
            return
        }
        lastPublished = state

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: state.title.isEmpty ? "Netflix" : state.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.time,
            MPNowPlayingInfoPropertyPlaybackRate: state.playing ? state.rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if !state.subtitle.isEmpty { info[MPMediaItemPropertyArtist] = state.subtitle }
        if state.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = state.duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = state.playing ? .playing : .paused

        let commands = MPRemoteCommandCenter.shared()
        commands.nextTrackCommand.isEnabled = true
        commands.changePlaybackPositionCommand.isEnabled = state.duration > 0
    }

    private func clear() {
        guard lastPublished != nil || MPNowPlayingInfoCenter.default().nowPlayingInfo != nil else { return }
        lastPublished = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    // MARK: Remote commands

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()

        // Explicit play/pause (not a blind toggle) so a key press can never
        // cancel itself out if WebKit also reacts to it.
        center.playCommand.addTarget { [weak self] _ in self?.perform("play") ?? .commandFailed }
        center.pauseCommand.addTarget { [weak self] _ in self?.perform("pause") ?? .commandFailed }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.perform(self.bridge.state.playing ? "pause" : "play")
        }

        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            return self?.perform("seekBy", interval) ?? .commandFailed
        }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            return self?.perform("seekBy", -interval) ?? .commandFailed
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self?.perform("seekTo", event.positionTime) ?? .commandFailed
        }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.perform("nextEpisode") ?? .commandFailed }
        // Treat "previous" as "back 10 seconds", like most video players.
        center.previousTrackCommand.addTarget { [weak self] _ in self?.perform("seekBy", -10) ?? .commandFailed }

        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.skipForwardCommand, center.skipBackwardCommand,
                        center.changePlaybackPositionCommand, center.nextTrackCommand,
                        center.previousTrackCommand] {
            command.isEnabled = true
        }
    }

    private func unregisterCommands() {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.skipForwardCommand, center.skipBackwardCommand,
                        center.changePlaybackPositionCommand, center.nextTrackCommand,
                        center.previousTrackCommand] {
            command.removeTarget(nil)
            command.isEnabled = false
        }
    }

    private func perform(_ command: String, _ argument: Any? = nil) -> MPRemoteCommandHandlerStatus {
        guard bridge.state.isActive else { return .noActionableNowPlayingItem }
        DispatchQueue.main.async { self.bridge.run(command, argument) }
        return .success
    }
}
