import AppKit
import WebKit

/// Builds the `WKWebView` that hosts Netflix.
///
/// Netflix only serves its DRM player to browsers it recognises. WebKit on
/// macOS supports Apple FairPlay through Encrypted Media Extensions, which is
/// what Safari uses — so the web view presents itself as the Safari that is
/// installed on this Mac. No private DRM plumbing is needed.
enum WebViewFactory {
    static func makeConfiguration(bridge: PlayerBridge) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()

        // Persistent cookies & storage: stay signed in across launches.
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = safariApplicationName()

        // Let Netflix autoplay (next episode, previews) without a click.
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true

        let preferences = config.preferences
        preferences.javaScriptCanOpenWindowsAutomatically = false
        // Fullscreen is mapped onto native window fullscreen by nfm.js, so
        // WebKit's own element-fullscreen window stays off.
        preferences.isElementFullscreenEnabled = false
        if Prefs.developerExtras {
            preferences.setValue(true, forKey: "developerExtrasEnabled")
        }
        enablePrivatePreference("_setAllowsPictureInPictureMediaPlayback:", on: preferences)

        let pagePrefs = WKWebpagePreferences()
        pagePrefs.allowsContentJavaScript = true
        pagePrefs.preferredContentMode = .desktop
        config.defaultWebpagePreferences = pagePrefs

        // Inject the page bridge into the main frame of every page.
        let controller = config.userContentController
        controller.add(WeakScriptMessageHandler(bridge), name: PlayerBridge.handlerName)
        if let script = Bundle.main.url(forResource: "nfm", withExtension: "js")
            .flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) {
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        } else {
            NSLog("NFM: nfm.js is missing from the app bundle; native player integration is disabled.")
        }
        return config
    }

    static func makeWebView(bridge: PlayerBridge) -> NFMWebView {
        let webView = NFMWebView(frame: .zero, configuration: makeConfiguration(bridge: bridge))
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = .black
        webView.isInspectable = Prefs.developerExtras
        let override = Prefs.userAgentOverride
        if !override.isEmpty { webView.customUserAgent = override }
        return webView
    }

    /// "Version/27.2 Safari/605.1.15", using the installed Safari's version so
    /// Netflix's browser check always sees a current, supported Safari.
    static func safariApplicationName() -> String {
        let candidates = ["/Applications/Safari.app", "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"]
        let version = candidates
            .compactMap { Bundle(path: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
            .first ?? "27.0"
        return "Version/\(version) Safari/605.1.15"
    }

    /// Flip a boolean WebKit preference that has no public API, if this
    /// WebKit build has it. Never crashes if the selector is gone.
    private static func enablePrivatePreference(_ selectorName: String, on preferences: WKPreferences) {
        let selector = NSSelectorFromString(selectorName)
        guard preferences.responds(to: selector),
              let method = class_getInstanceMethod(type(of: preferences), selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let implementation = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        implementation(preferences, selector, true)
    }
}

/// `WKUserContentController` retains its message handlers; this breaks the cycle.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// The web view, with a remembered mouse-down so the page can ask the window
/// to start a drag from an empty part of the title bar area.
final class NFMWebView: WKWebView {
    private(set) var lastMouseDown: NSEvent?

    override func mouseDown(with event: NSEvent) {
        lastMouseDown = event
        super.mouseDown(with: event)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
