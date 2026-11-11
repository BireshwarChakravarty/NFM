import AppKit
import WebKit

/// A snapshot of what the Netflix page is doing, as reported by nfm.js.
struct PlayerState: Equatable {
    var watching = false
    var hasVideo = false
    var playing = false
    var time: Double = 0
    var duration: Double = 0
    var rate: Double = 1
    var volume: Double = 1
    var muted = false
    var videoSize: CGSize = .zero
    var title = ""
    var subtitle = ""

    /// True while there is a video on screen that can be controlled.
    var isActive: Bool { watching && hasVideo }
}

enum AutoAction: String {
    case intro, recap, credits, stillWatching

    var hudText: String {
        switch self {
        case .intro: return "Skipped Intro"
        case .recap: return "Skipped Recap"
        case .credits: return "Next Episode"
        case .stillWatching: return "Still Watching"
        }
    }
}

protocol PlayerBridgeDelegate: AnyObject {
    func bridge(_ bridge: PlayerBridge, didUpdate state: PlayerState, previous: PlayerState)
    func bridgeRequestsFullscreen(_ bridge: PlayerBridge, enter: Bool)
    func bridgeRequestsWindowDrag(_ bridge: PlayerBridge)
    func bridgeRequestsTitlebarDoubleClick(_ bridge: PlayerBridge)
    func bridge(_ bridge: PlayerBridge, idleChanged idle: Bool)
    func bridge(_ bridge: PlayerBridge, didPerform action: AutoAction)
    func bridgePageReady(_ bridge: PlayerBridge)
}

/// Two-way channel between native code and the Netflix page.
final class PlayerBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "nfm"

    weak var webView: WKWebView?
    weak var delegate: PlayerBridgeDelegate?
    private(set) var state = PlayerState()

    /// Auto-select the remembered profile only once per launch, so switching
    /// profiles from Netflix's own menu still works.
    private var autoProfileArmed = true

    // MARK: Page → native

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            pushSettings()
            delegate?.bridgePageReady(self)
        case "state":
            apply(body)
        case "route":
            var next = state
            next.watching = body["watching"] as? Bool ?? false
            if !next.watching {
                next.hasVideo = false
                next.playing = false
                next.title = ""
                next.subtitle = ""
            }
            publish(next)
        case "fullscreen":
            delegate?.bridgeRequestsFullscreen(self, enter: body["enter"] as? Bool ?? true)
        case "dragWindow":
            delegate?.bridgeRequestsWindowDrag(self)
        case "titlebarDoubleClick":
            delegate?.bridgeRequestsTitlebarDoubleClick(self)
        case "idle":
            delegate?.bridge(self, idleChanged: body["idle"] as? Bool ?? false)
        case "autoAction":
            if let action = (body["kind"] as? String).flatMap(AutoAction.init(rawValue:)) {
                delegate?.bridge(self, didPerform: action)
            }
        case "profileChosen":
            if let name = body["name"] as? String, !name.isEmpty { Prefs.lastProfile = name }
        case "profileAutoSelected":
            autoProfileArmed = false
        default:
            break
        }
    }

    private func apply(_ body: [String: Any]) {
        var next = state
        next.watching = body["watching"] as? Bool ?? false
        next.hasVideo = body["hasVideo"] as? Bool ?? false
        next.playing = body["playing"] as? Bool ?? false
        next.time = Self.double(body["time"])
        next.duration = Self.double(body["duration"])
        next.rate = Self.double(body["rate"], default: 1)
        next.volume = Self.double(body["volume"], default: 1)
        next.muted = body["muted"] as? Bool ?? false
        next.videoSize = CGSize(width: Self.double(body["videoWidth"]), height: Self.double(body["videoHeight"]))
        next.title = body["title"] as? String ?? ""
        next.subtitle = body["subtitle"] as? String ?? ""
        publish(next)
    }

    private func publish(_ next: PlayerState) {
        let previous = state
        state = next
        if next != previous { delegate?.bridge(self, didUpdate: next, previous: previous) }
    }

    private static func double(_ value: Any?, default fallback: Double = 0) -> Double {
        if let n = value as? NSNumber { return n.doubleValue.isFinite ? n.doubleValue : fallback }
        return fallback
    }

    // MARK: Native → page

    /// Runs a command from nfm.js's command table and hands back its result.
    func run(_ command: String, _ argument: Any? = nil, completion: ((Any?) -> Void)? = nil) {
        let arg = argument.map(Self.json) ?? "null"
        evaluate("window.__nfm ? window.__nfm.run(\(Self.json(command)), \(arg)) : null", completion: completion)
    }

    func pushSettings() {
        let profile = Prefs.autoProfile ? Prefs.lastProfile : ""
        let settings: [String: Any] = [
            "autoSkipIntro": Prefs.autoSkipIntro,
            "autoSkipRecap": Prefs.autoSkipRecap,
            "autoNextEpisode": Prefs.autoNextEpisode,
            "dismissStillWatching": Prefs.dismissStillWatching,
            "rememberSpeed": Prefs.rememberSpeed,
            "subtitleScale": Double(Prefs.subtitleSize) / 100,
            "videoFill": Prefs.videoFill.rawValue,
            "autoProfile": autoProfileArmed ? profile : "",
            "autoProfileArmed": autoProfileArmed,
        ]
        evaluate("window.__nfm && window.__nfm.configure(\(Self.json(settings)))")
    }

    func setFullscreen(_ on: Bool) {
        evaluate("window.__nfm && window.__nfm.setFullscreen(\(on ? "true" : "false"))")
    }

    private func evaluate(_ script: String, completion: ((Any?) -> Void)? = nil) {
        guard let webView else { completion?(nil); return }
        webView.evaluateJavaScript(script) { result, _ in completion?(result) }
    }

    static func json(_ value: Any) -> String {
        switch value {
        case let string as String:
            // JSONSerialization wants a container; wrap and unwrap.
            let data = (try? JSONSerialization.data(withJSONObject: [string])) ?? Data("[\"\"]".utf8)
            let wrapped = String(decoding: data, as: UTF8.self)
            return String(wrapped.dropFirst().dropLast())
        case let double as Double:
            return double.isFinite ? "\(double)" : "null"
        case let int as Int:
            return "\(int)"
        case let bool as Bool:
            return bool ? "true" : "false"
        default:
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value) else { return "null" }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
