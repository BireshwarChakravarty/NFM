import Foundation

/// All user settings live in `UserDefaults.standard`, so SwiftUI can bind to
/// them with `@AppStorage` and the rest of the app reads them through `Prefs`.
enum PrefKey {
    // Playback automation
    static let autoSkipIntro = "autoSkipIntro"
    static let autoSkipRecap = "autoSkipRecap"
    static let autoNextEpisode = "autoNextEpisode"
    static let dismissStillWatching = "dismissStillWatching"
    static let rememberSpeed = "rememberSpeed"
    static let subtitleSize = "subtitleSize" // percent of Netflix's size
    static let videoFill = "videoFill"
    static let soundBoost = "soundBoost"   // percent, 100 = off
    static let voiceBoost = "voiceBoost"
    static let loudnessMatch = "loudnessMatch"
    static let loudnessTarget = "loudnessTarget" // LUFS, e.g. -16
    static let lastMatchGain = "lastMatchGain"   // dB, to start the next video close to right

    // System integration
    static let nowPlaying = "nowPlaying"
    static let preventSleep = "preventSleep"
    static let showHUD = "showHUD"

    // Window
    static let hideChromeWhenIdle = "hideChromeWhenIdle"
    static let autoFullscreen = "autoFullscreen"
    static let miniOnDeactivate = "miniOnDeactivate"
    static let miniOpacity = "miniOpacity"
    static let miniAllSpaces = "miniAllSpaces"
    static let miniFrame = "miniFrame"
    static let keepOnTop = "keepOnTop"
    static let quitOnClose = "quitOnClose"

    // TV mode
    static let openInTVMode = "openInTVMode"
    static let tvOnController = "tvOnController"

    // Startup
    static let autoProfile = "autoProfile"
    static let lastProfile = "lastProfile"
    static let restoreLastPage = "restoreLastPage"
    static let lastURL = "lastURL"

    // Advanced
    static let developerExtras = "developerExtras"
    static let userAgentOverride = "userAgentOverride"
}

enum VideoFill: String, CaseIterable, Identifiable {
    case fit, fill
    var id: String { rawValue }
    var title: String { self == .fit ? "Fit (show whole picture)" : "Fill (crop black bars)" }
}

/// Loudness Match targets.
enum LoudnessTarget: Int, CaseIterable, Identifiable {
    case youtube = -14, recommended = -16, gentle = -20
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .youtube: return "−14 LUFS · as loud as YouTube and Spotify"
        case .recommended: return "−16 LUFS · recommended"
        case .gentle: return "−20 LUFS · gentle"
        }
    }
}

enum Prefs {
    static let defaults = UserDefaults.standard

    static func register() {
        // Retired setting (the Dolby audio option was removed).
        defaults.removeObject(forKey: "dolbyAudio")
        defaults.register(defaults: [
            PrefKey.autoSkipIntro: true,
            PrefKey.autoSkipRecap: true,
            PrefKey.autoNextEpisode: false,
            PrefKey.dismissStillWatching: true,
            PrefKey.rememberSpeed: false,
            PrefKey.subtitleSize: 100,
            PrefKey.videoFill: VideoFill.fit.rawValue,
            PrefKey.soundBoost: 100,
            PrefKey.voiceBoost: false,
            PrefKey.loudnessMatch: true,
            PrefKey.loudnessTarget: -16,
            PrefKey.lastMatchGain: 6.0,
            PrefKey.nowPlaying: true,
            PrefKey.preventSleep: true,
            PrefKey.showHUD: true,
            PrefKey.hideChromeWhenIdle: true,
            PrefKey.autoFullscreen: false,
            PrefKey.miniOnDeactivate: false,
            PrefKey.miniOpacity: 1.0,
            PrefKey.miniAllSpaces: true,
            PrefKey.keepOnTop: false,
            PrefKey.quitOnClose: false,
            PrefKey.openInTVMode: false,
            PrefKey.tvOnController: true,
            PrefKey.autoProfile: false,
            PrefKey.lastProfile: "",
            PrefKey.restoreLastPage: true,
            PrefKey.developerExtras: false,
            PrefKey.userAgentOverride: "",
        ])
    }

    static var autoSkipIntro: Bool { defaults.bool(forKey: PrefKey.autoSkipIntro) }
    static var autoSkipRecap: Bool { defaults.bool(forKey: PrefKey.autoSkipRecap) }
    static var autoNextEpisode: Bool { defaults.bool(forKey: PrefKey.autoNextEpisode) }
    static var dismissStillWatching: Bool { defaults.bool(forKey: PrefKey.dismissStillWatching) }
    static var rememberSpeed: Bool { defaults.bool(forKey: PrefKey.rememberSpeed) }
    static var subtitleSize: Int {
        get { min(150, max(50, defaults.integer(forKey: PrefKey.subtitleSize))) }
        set { defaults.set(min(150, max(50, newValue)), forKey: PrefKey.subtitleSize) }
    }
    static var videoFill: VideoFill {
        get { VideoFill(rawValue: defaults.string(forKey: PrefKey.videoFill) ?? "") ?? .fit }
        set { defaults.set(newValue.rawValue, forKey: PrefKey.videoFill) }
    }

    static var soundBoost: Int {
        get { min(300, max(100, defaults.integer(forKey: PrefKey.soundBoost))) }
        set { defaults.set(min(300, max(100, newValue)), forKey: PrefKey.soundBoost) }
    }
    static var voiceBoost: Bool {
        get { defaults.bool(forKey: PrefKey.voiceBoost) }
        set { defaults.set(newValue, forKey: PrefKey.voiceBoost) }
    }

    static var loudnessMatch: Bool {
        get { defaults.bool(forKey: PrefKey.loudnessMatch) }
        set { defaults.set(newValue, forKey: PrefKey.loudnessMatch) }
    }
    static var loudnessTarget: Int {
        get { min(-10, max(-24, defaults.integer(forKey: PrefKey.loudnessTarget))) }
        set { defaults.set(newValue, forKey: PrefKey.loudnessTarget) }
    }
    static var lastMatchGain: Double {
        get { min(12, max(0, defaults.double(forKey: PrefKey.lastMatchGain))) }
        set { defaults.set(newValue, forKey: PrefKey.lastMatchGain) }
    }

    static var nowPlaying: Bool { defaults.bool(forKey: PrefKey.nowPlaying) }
    static var preventSleep: Bool { defaults.bool(forKey: PrefKey.preventSleep) }
    static var showHUD: Bool { defaults.bool(forKey: PrefKey.showHUD) }

    static var hideChromeWhenIdle: Bool { defaults.bool(forKey: PrefKey.hideChromeWhenIdle) }
    static var autoFullscreen: Bool { defaults.bool(forKey: PrefKey.autoFullscreen) }
    static var miniOnDeactivate: Bool { defaults.bool(forKey: PrefKey.miniOnDeactivate) }
    static var miniOpacity: Double { min(1, max(0.2, defaults.double(forKey: PrefKey.miniOpacity))) }
    static var miniAllSpaces: Bool { defaults.bool(forKey: PrefKey.miniAllSpaces) }
    static var keepOnTop: Bool {
        get { defaults.bool(forKey: PrefKey.keepOnTop) }
        set { defaults.set(newValue, forKey: PrefKey.keepOnTop) }
    }
    static var quitOnClose: Bool { defaults.bool(forKey: PrefKey.quitOnClose) }
    static var openInTVMode: Bool { defaults.bool(forKey: PrefKey.openInTVMode) }
    static var tvOnController: Bool { defaults.bool(forKey: PrefKey.tvOnController) }

    static var autoProfile: Bool { defaults.bool(forKey: PrefKey.autoProfile) }
    static var lastProfile: String {
        get { defaults.string(forKey: PrefKey.lastProfile) ?? "" }
        set { defaults.set(newValue, forKey: PrefKey.lastProfile) }
    }
    static var restoreLastPage: Bool { defaults.bool(forKey: PrefKey.restoreLastPage) }
    static var lastURL: URL? {
        get { defaults.string(forKey: PrefKey.lastURL).flatMap(URL.init(string:)) }
        set { defaults.set(newValue?.absoluteString, forKey: PrefKey.lastURL) }
    }

    static var developerExtras: Bool { defaults.bool(forKey: PrefKey.developerExtras) }
    static var userAgentOverride: String {
        defaults.string(forKey: PrefKey.userAgentOverride)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var miniFrame: NSRectCodable? {
        get {
            guard let data = defaults.data(forKey: PrefKey.miniFrame) else { return nil }
            return try? JSONDecoder().decode(NSRectCodable.self, from: data)
        }
        set {
            defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: PrefKey.miniFrame)
        }
    }
}

struct NSRectCodable: Codable {
    var x, y, width, height: Double
}
