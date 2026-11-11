import AppKit
import WebKit

/// The one Netflix window: web view, native overlays, mini player, fullscreen
/// and every playback command in the menus.
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let bridge = PlayerBridge()
    private(set) var webView: NFMWebView!
    private lazy var nowPlaying = NowPlayingController(bridge: bridge)
    private let sleepGuard = SleepGuard()
    private let enhancer = AudioEnhancer()
    private var explainedBoostFailure = false

    private let hud = HUDView()
    private let statusOverlay = StatusOverlayView()
    private let quickSearch = QuickSearchView()
    private let miniOverlay = MiniPlayerOverlayView()

    private var urlObservation: NSKeyValueObservation?
    private var hasLoadedOnce = false
    private var chromeHidden = false

    // Mini player
    private(set) var isMini = false
    private var enteredMiniAutomatically = false
    private var frameBeforeMini: NSRect?
    private var enterMiniAfterFullscreenExit = false
    private var hideAfterFullscreenExit = false
    private var autoEnteredFullscreen = false

    // TV mode
    private(set) var isTV = false
    private var fullscreenForTV = false
    private var zoomBeforeTV: CGFloat = 1
    private static let tvZoom: CGFloat = 1.25

    private static let normalMinSize = NSSize(width: 640, height: 400)
    private static let miniMinSize = NSSize(width: 256, height: 144)

    var state: PlayerState { bridge.state }
    private var isFullscreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    // MARK: Setup

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        self.init(window: window)
        configureWindow(window)
        buildContent(in: window)
        bridge.delegate = self
        enhancer.onFailure = { [weak self] in self?.enhancerFailed($0) }
        nowPlaying.setEnabled(Prefs.nowPlaying)
        applyWindowLevel()
    }

    private func configureWindow(_ window: NSWindow) {
        window.title = "Netflix"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.minSize = Self.normalMinSize
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("NFMMainWindow")
    }

    private func buildContent(in window: NSWindow) {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = container

        let webView = WebViewFactory.makeWebView(bridge: bridge)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        bridge.webView = webView
        self.webView = webView

        urlObservation = webView.observe(\.url, options: [.new]) { webView, _ in
            guard let url = webView.url, NetflixRoutes.isNetflixHost(url.host) else { return }
            Prefs.lastURL = url
        }

        container.addSubview(webView)
        container.addSubview(miniOverlay)
        container.addSubview(statusOverlay)
        container.addSubview(hud)
        container.addSubview(quickSearch)

        miniOverlay.isHidden = true
        miniOverlay.onCommand = { [weak self] in self?.handleMiniCommand($0) }
        statusOverlay.onRetry = { [weak self] in self?.retryLoad() }
        quickSearch.onSubmit = { [weak self] in self?.submitQuickSearch($0) }
        quickSearch.onCancel = { [weak self] in self?.closeQuickSearch() }

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            miniOverlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            miniOverlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            miniOverlay.topAnchor.constraint(equalTo: container.topAnchor),
            miniOverlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            statusOverlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusOverlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusOverlay.topAnchor.constraint(equalTo: container.topAnchor),
            statusOverlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            hud.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            hud.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            quickSearch.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            quickSearch.topAnchor.constraint(equalTo: container.topAnchor, constant: 96),
            quickSearch.widthAnchor.constraint(equalToConstant: 580).withPriority(.defaultHigh),
            quickSearch.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])
    }

    func loadInitialPage(_ url: URL? = nil) {
        webView.load(URLRequest(url: url ?? NetflixRoutes.startURL()))
    }

    // MARK: Opening things

    func open(_ url: URL) {
        let target: URL
        if let scheme = url.scheme?.lowercased(), scheme == "netflix" || scheme == "nfm" {
            target = NetflixRoutes.resolveCustomScheme(url)
        } else {
            target = url
        }
        showWindow(nil)
        if isMini { exitMini() }
        webView.load(URLRequest(url: target))
    }

    private func retryLoad() {
        statusOverlay.show(.loading)
        if webView.url == nil { loadInitialPage() } else { webView.reload() }
    }

    // MARK: Settings

    private var lastSettingsSignature = ""

    func settingsChanged() {
        let signature = [Prefs.autoSkipIntro, Prefs.autoSkipRecap, Prefs.autoNextEpisode, Prefs.dismissStillWatching,
                         Prefs.rememberSpeed, Prefs.nowPlaying, Prefs.preventSleep, Prefs.keepOnTop,
                         Prefs.autoProfile, Prefs.hideChromeWhenIdle, Prefs.miniAllSpaces, Prefs.voiceBoost]
            .map { $0 ? "1" : "0" }.joined() + Prefs.videoFill.rawValue + "\(Prefs.miniOpacity)" + Prefs.lastProfile
            + "\(Prefs.subtitleSize)"
            + "\(Prefs.soundBoost)\(Prefs.loudnessMatch)\(Prefs.loudnessTarget)"
        guard signature != lastSettingsSignature else { return }
        lastSettingsSignature = signature

        bridge.pushSettings()
        nowPlaying.setEnabled(Prefs.nowPlaying)
        nowPlaying.update(with: state)
        sleepGuard.update(playing: state.playing)
        enhancer.resetFailure()
        updateEnhancer()
        applyWindowLevel()
        if isMini {
            window?.alphaValue = Prefs.miniOpacity
            window?.collectionBehavior = miniCollectionBehavior()
        }
        if !Prefs.hideChromeWhenIdle { setChromeHidden(false) }
    }

    private func applyWindowLevel() {
        guard !isMini else { return }
        window?.level = Prefs.keepOnTop ? .floating : .normal
    }

    // MARK: Window chrome

    private func setChromeHidden(_ hidden: Bool, animated: Bool = true) {
        guard hidden != chromeHidden, let window else { return }
        chromeHidden = hidden
        let titlebar = window.standardWindowButton(.closeButton)?.superview
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.25 : 0
            titlebar?.animator().alphaValue = hidden ? 0 : 1
        }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if Prefs.quitOnClose {
            NSApp.terminate(nil)
            return false
        }
        if state.playing { bridge.run("pause") }
        if isMini { exitMini() }
        if isFullscreen {
            hideAfterFullscreenExit = true
            sender.toggleFullScreen(nil)
        } else {
            sender.orderOut(nil)
        }
        return false
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        bridge.setFullscreen(true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        bridge.setFullscreen(false)
        if isTV {
            // The user left full screen themselves (green button, ⌃⌘F): leave TV mode too.
            fullscreenForTV = false
            setTVMode(false)
        }
        if enterMiniAfterFullscreenExit {
            enterMiniAfterFullscreenExit = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.enterMini(automatic: self.enteredMiniAutomatically) }
        }
        if hideAfterFullscreenExit {
            hideAfterFullscreenExit = false
            window?.orderOut(nil)
        }
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        // Zoom (green button / double-click) fits the video's shape while watching.
        guard state.isActive, state.videoSize.width > 0, state.videoSize.height > 0 else { return newFrame }
        let aspect = state.videoSize.width / state.videoSize.height
        var size = newFrame.size
        if size.width / size.height > aspect { size.width = size.height * aspect } else { size.height = size.width / aspect }
        return NSRect(x: newFrame.midX - size.width / 2, y: newFrame.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    // MARK: Mini player

    func toggleMini() {
        if isMini { exitMini() } else { enterMini(automatic: false) }
    }

    func enterMini(automatic: Bool) {
        guard !isMini, let window else { return }
        guard state.isActive else {
            if !automatic { hud.flash(symbol: "pip", text: "Start a video first") }
            return
        }
        enteredMiniAutomatically = automatic
        if isTV { leaveTVState() }
        if isFullscreen {
            enterMiniAfterFullscreenExit = true
            window.toggleFullScreen(nil)
            return
        }
        quickSearch.dismiss()
        isMini = true
        frameBeforeMini = window.frame

        let aspect = videoAspect()
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? window.frame
        var frame: NSRect
        if let saved = Prefs.miniFrame,
           let restored = Optional(NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.width / aspect)),
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(restored) }) {
            frame = restored
        } else {
            let width = min(480, visible.width / 3)
            frame = NSRect(x: visible.maxX - width - 24, y: visible.minY + 24, width: width, height: width / aspect)
        }

        setChromeHidden(true, animated: false)
        window.minSize = Self.miniMinSize
        window.level = .floating
        window.collectionBehavior = miniCollectionBehavior()
        window.contentAspectRatio = NSSize(width: aspect, height: 1)
        miniOverlay.isHidden = false
        miniOverlay.update(with: state)
        bridge.run("setMini", true)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
            window.animator().alphaValue = Prefs.miniOpacity
        }
        if automatic {
            // Keep floating above the app the user switched to.
            window.orderFrontRegardless()
        }
    }

    func exitMini() {
        guard isMini, let window else { return }
        let frame = window.frame
        Prefs.miniFrame = NSRectCodable(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)

        isMini = false
        enteredMiniAutomatically = false
        miniOverlay.isHidden = true
        bridge.run("setMini", false)
        window.contentResizeIncrements = NSSize(width: 1, height: 1) // clears the aspect lock
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.minSize = Self.normalMinSize
        applyWindowLevel()
        setChromeHidden(false, animated: false)

        let target = frameBeforeMini ?? window.frame
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(target, display: true)
            window.animator().alphaValue = 1
        }
    }

    /// Called when the app loses focus (Settings: “Float in mini player when I switch apps”).
    func appDidResignActive() {
        guard Prefs.miniOnDeactivate, state.playing, !isMini, !isFullscreen,
              window?.isVisible == true, window?.isMiniaturized == false else { return }
        enterMini(automatic: true)
    }

    func appDidBecomeActive() {
        if isMini && enteredMiniAutomatically { exitMini() }
    }

    private func miniCollectionBehavior() -> NSWindow.CollectionBehavior {
        var behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .fullScreenNone]
        if Prefs.miniAllSpaces { behavior.insert(.canJoinAllSpaces) } else { behavior.insert(.managed) }
        return behavior
    }

    private func videoAspect() -> CGFloat {
        let size = state.videoSize
        guard size.width > 0, size.height > 0 else { return 16.0 / 9.0 }
        return min(max(size.width / size.height, 1.0), 2.8)
    }

    private func handleMiniCommand(_ command: String) {
        switch command {
        case "seekBack": skipBackward(nil)
        case "seekForward": skipForward(nil)
        case "togglePlay": togglePlayPause(nil)
        case "nextEpisode": nextEpisode(nil)
        case "exitMini": exitMini(); NSApp.activate(ignoringOtherApps: true)
        case "closeMini": bridge.run("pause"); exitMini()
        default: break
        }
    }

    // MARK: Quick search

    @objc func showQuickSearch(_ sender: Any?) {
        showWindow(nil)
        if isMini { exitMini() }
        quickSearch.present(prefill: nil)
    }

    @objc func openLinkFromClipboard(_ sender: Any?) {
        showWindow(nil)
        if isMini { exitMini() }
        let clip = NSPasteboard.general.string(forType: .string) ?? ""
        quickSearch.present(prefill: NetflixRoutes.resolve(clip) != nil ? clip : nil)
    }

    private func submitQuickSearch(_ text: String) {
        closeQuickSearch()
        let url = NetflixRoutes.resolve(text) ?? NetflixRoutes.search(text)
        webView.load(URLRequest(url: url))
    }

    private func closeQuickSearch() {
        guard quickSearch.isPresented else { return }
        quickSearch.dismiss()
        window?.makeFirstResponder(webView)
    }

    // MARK: Navigation actions

    @objc func goHome(_ sender: Any?) { navigate(NetflixRoutes.home) }
    @objc func goTVShows(_ sender: Any?) { navigate(NetflixRoutes.tvShows) }
    @objc func goMovies(_ sender: Any?) { navigate(NetflixRoutes.movies) }
    @objc func goNewAndPopular(_ sender: Any?) { navigate(NetflixRoutes.newAndPopular) }
    @objc func goMyList(_ sender: Any?) { navigate(NetflixRoutes.myList) }
    @objc func goLanguages(_ sender: Any?) { navigate(NetflixRoutes.languages) }
    @objc func goAccount(_ sender: Any?) { navigate(NetflixRoutes.account) }
    @objc func goBack(_ sender: Any?) { webView.goBack() }
    @objc func goForward(_ sender: Any?) { webView.goForward() }
    @objc func reloadPage(_ sender: Any?) { webView.reload() }

    @objc func copyPageLink(_ sender: Any?) {
        guard var url = webView.url else { return }
        // Share the title page rather than a raw player URL.
        if let id = NetflixRoutes.watchID(url) { url = NetflixRoutes.url("/title/\(id)") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        hud.flash(symbol: "link", text: "Link Copied")
    }

    private func navigate(_ url: URL) {
        showWindow(nil)
        if isMini { exitMini() }
        webView.load(URLRequest(url: url))
    }

    // MARK: Zoom

    @objc func zoomIn(_ sender: Any?) { setPageZoom(webView.pageZoom + 0.1) }
    @objc func zoomOut(_ sender: Any?) { setPageZoom(webView.pageZoom - 0.1) }
    @objc func actualSize(_ sender: Any?) { setPageZoom(1) }

    private func setPageZoom(_ zoom: CGFloat) {
        let clamped = min(2, max(0.5, (zoom * 10).rounded() / 10))
        webView.pageZoom = clamped
        hud.flash(symbol: "plus.magnifyingglass", text: "\(Int((clamped * 100).rounded()))%")
    }

    // MARK: Playback actions

    @objc func togglePlayPause(_ sender: Any?) {
        let willPlay = !state.playing
        bridge.run(willPlay ? "play" : "pause")
        hud.flash(symbol: willPlay ? "play.fill" : "pause.fill", text: willPlay ? "Play" : "Pause")
    }

    @objc func skipForward(_ sender: Any?) { seek(by: 10) }
    @objc func skipBackward(_ sender: Any?) { seek(by: -10) }
    @objc func skipForwardLong(_ sender: Any?) { seek(by: 60) }
    @objc func skipBackwardLong(_ sender: Any?) { seek(by: -60) }

    private func seek(by seconds: Double) {
        bridge.run("seekBy", seconds) { [weak self] result in
            guard (result as? Bool) == true else {
                self?.hud.flash(symbol: "exclamationmark.triangle", text: "Can’t seek yet")
                return
            }
            let symbol = seconds > 0 ? "goforward.\(Int(abs(seconds)) == 10 ? "10" : "60")"
                                     : "gobackward.\(Int(abs(seconds)) == 10 ? "10" : "60")"
            self?.hud.flash(symbol: symbol, text: "\(seconds > 0 ? "+" : "−")\(Int(abs(seconds)))s")
        }
    }

    @objc func skipSegment(_ sender: Any?) {
        bridge.run("skip") { [weak self] result in
            let kind = (result as? String).flatMap(AutoAction.init(rawValue:))
            if let kind {
                self?.hud.flash(symbol: "forward.fill", text: kind.hudText)
            } else {
                self?.hud.flash(symbol: "forward", text: "Nothing to Skip")
            }
        }
    }

    @objc func nextEpisode(_ sender: Any?) {
        bridge.run("nextEpisode") { [weak self] result in
            if (result as? Bool) == true {
                self?.hud.flash(symbol: "forward.end.fill", text: "Next Episode")
            } else {
                self?.hud.flash(symbol: "forward.end", text: "No Next Episode")
            }
        }
    }

    @objc func volumeUp(_ sender: Any?) { changeVolume(by: 0.1) }
    @objc func volumeDown(_ sender: Any?) { changeVolume(by: -0.1) }

    private func changeVolume(by delta: Double) {
        // Past 100% the volume keeps going with Extra Boost; on the way down
        // the boost comes off first.
        if delta > 0 && state.volume >= 0.999 && !state.muted {
            stepBoost(up: true)
            return
        }
        if delta < 0 && Prefs.soundBoost > 100 {
            stepBoost(up: false)
            return
        }
        bridge.run("volumeBy", delta) { [weak self] result in
            let volume = (result as? NSNumber)?.doubleValue ?? 0
            self?.hud.flash(symbol: Self.volumeSymbol(volume), text: "Volume \(Int((volume * 100).rounded()))%")
        }
    }

    // MARK: Sound (Loudness Match, Voice Boost, Extra Boost)

    static let boostSteps = [100, 125, 150, 175, 200, 250, 300]

    @objc func setExtraBoost(_ sender: NSMenuItem) { setBoost(percent: sender.tag) }

    var audioStatus: AudioEnhancer.Status { enhancer.status }

    @objc func toggleLoudnessMatch(_ sender: Any?) {
        Prefs.loudnessMatch.toggle()
        enhancer.resetFailure()
        updateEnhancer()
        hud.flash(symbol: "dial.medium.fill", text: Prefs.loudnessMatch ? "Loudness Match On" : "Loudness Match Off")
    }

    @objc func setLoudnessTarget(_ sender: NSMenuItem) {
        Prefs.loudnessTarget = sender.tag
        Prefs.loudnessMatch = true
        enhancer.resetFailure()
        updateEnhancer()
        hud.flash(symbol: "dial.medium.fill", text: "Target \(sender.tag) LUFS")
    }

    @objc func toggleVoiceBoost(_ sender: Any?) {
        Prefs.voiceBoost.toggle()
        enhancer.resetFailure()
        updateEnhancer()
        hud.flash(symbol: "person.wave.2.fill", text: Prefs.voiceBoost ? "Voice Boost On" : "Voice Boost Off")
    }

    private func stepBoost(up: Bool) {
        let current = Prefs.soundBoost
        let next = up ? (Self.boostSteps.first { $0 > current } ?? 300)
                      : (Self.boostSteps.last { $0 < current } ?? 100)
        setBoost(percent: next)
    }

    private func setBoost(percent: Int) {
        Prefs.soundBoost = percent
        enhancer.resetFailure()
        updateEnhancer()
        hud.flash(symbol: percent > 100 ? "speaker.wave.3.fill" : "speaker.wave.2.fill",
                  text: percent > 100 ? "Volume \(percent)% · Boost" : "Volume 100%")
    }

    private func updateEnhancer() {
        enhancer.update(watching: state.isActive, audible: state.playing && !state.muted && state.volume > 0)
    }

    private func enhancerFailed(_ failure: AudioEnhancer.Failure) {
        hud.flash(symbol: "speaker.slash", text: "Audio Enhancements Off")
        guard case .silent = failure, !explainedBoostFailure, let window else { return }
        explainedBoostFailure = true
        let alert = NSAlert()
        alert.messageText = "Loudness Match couldn’t reach Netflix’s audio"
        alert.informativeText = "Your normal sound is back. Loudness Match, Voice Boost and extra boost need “System Audio "
            + "Recording” access (NFM only processes its own sound; nothing is recorded). If you turned it down, allow NFM "
            + "in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording, then play the title again."
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Not Now")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn,
                  let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
            else { return }
            NSWorkspace.shared.open(url)
        }
    }

    @objc func toggleMute(_ sender: Any?) {
        bridge.run("toggleMute") { [weak self] result in
            let muted = (result as? Bool) ?? false
            self?.hud.flash(symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", text: muted ? "Muted" : "Unmuted")
        }
    }

    @objc func speedUp(_ sender: Any?) { changeRate(command: "rateBy", 1) }
    @objc func slowDown(_ sender: Any?) { changeRate(command: "rateBy", -1) }
    @objc func normalSpeed(_ sender: Any?) { changeRate(command: "setRate", 1) }
    @objc func setSpeed(_ sender: NSMenuItem) { changeRate(command: "setRate", Double(sender.tag) / 100) }

    private func changeRate(command: String, _ value: Double) {
        bridge.run(command, value) { [weak self] result in
            let rate = (result as? NSNumber)?.doubleValue ?? 1
            self?.hud.flash(symbol: rate == 1 ? "gauge.medium" : (rate > 1 ? "hare.fill" : "tortoise.fill"),
                            text: Self.rateText(rate))
        }
    }

    @objc func toggleFill(_ sender: Any?) {
        Prefs.videoFill = Prefs.videoFill == .fit ? .fill : .fit
        bridge.pushSettings()
        hud.flash(symbol: Prefs.videoFill == .fill ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
                  text: Prefs.videoFill == .fill ? "Fill Screen" : "Fit to Screen")
    }

    // MARK: Subtitle size

    static let subtitleSizes = [60, 70, 80, 90, 100, 115, 130]

    @objc func setSubtitleSize(_ sender: NSMenuItem) { applySubtitleSize(sender.tag) }
    @objc func smallerSubtitles(_ sender: Any?) { stepSubtitleSize(up: false) }
    @objc func largerSubtitles(_ sender: Any?) { stepSubtitleSize(up: true) }

    private func stepSubtitleSize(up: Bool) {
        let current = Prefs.subtitleSize
        let next = up ? (Self.subtitleSizes.first { $0 > current } ?? Self.subtitleSizes.last!)
                      : (Self.subtitleSizes.last { $0 < current } ?? Self.subtitleSizes.first!)
        applySubtitleSize(next)
    }

    private func applySubtitleSize(_ percent: Int) {
        Prefs.subtitleSize = percent
        bridge.pushSettings()
        hud.flash(symbol: "captions.bubble.fill", text: percent == 100 ? "Subtitles: Normal" : "Subtitles \(percent)%")
    }

    @objc func togglePictureInPicture(_ sender: Any?) {
        bridge.run("togglePiP") { [weak self] result in
            let mode = result as? String ?? ""
            if mode != "picture-in-picture" && mode != "inline" {
                // WebKit refused system PiP: fall back to the built-in mini player.
                self?.enterMini(automatic: false)
            }
        }
    }

    @objc func toggleMiniPlayer(_ sender: Any?) { toggleMini() }

    @objc func toggleKeepOnTop(_ sender: Any?) {
        Prefs.keepOnTop.toggle()
        applyWindowLevel()
        hud.flash(symbol: Prefs.keepOnTop ? "pin.fill" : "pin.slash", text: Prefs.keepOnTop ? "Keep on Top" : "Normal Window")
    }

    // MARK: TV mode

    @objc func toggleTVMode(_ sender: Any?) { setTVMode(!isTV) }

    /// Lean-back mode: full screen, larger UI, and arrow-key / game-controller
    /// navigation with a focus highlight (implemented in nfm.js).
    func setTVMode(_ on: Bool) {
        guard on != isTV, let window else { return }
        if on {
            showWindow(nil)
            if isMini { exitMini() }
            quickSearch.dismiss()
            isTV = true
            zoomBeforeTV = webView.pageZoom
            webView.pageZoom = Self.tvZoom
            bridge.run("setTV", true)
            if !isFullscreen {
                fullscreenForTV = true
                window.toggleFullScreen(nil)
            }
            hud.flash(symbol: "tv", text: "TV Mode")
        } else {
            let leaveFullscreen = fullscreenForTV && isFullscreen
            leaveTVState()
            if leaveFullscreen { window.toggleFullScreen(nil) }
            hud.flash(symbol: "macwindow", text: "Window Mode")
        }
        window.makeFirstResponder(webView)
    }

    /// Resets TV mode without touching full screen (callers handle that).
    private func leaveTVState() {
        isTV = false
        fullscreenForTV = false
        webView.pageZoom = zoomBeforeTV
        bridge.run("setTV", false)
    }

    /// Game controller input: a remote for browsing, transport controls while watching.
    func handleController(_ input: GameControllerManager.Input) {
        if input == .menu { toggleTVMode(nil); return }
        if state.isActive {
            switch input {
            case .left: seek(by: -10)
            case .right: seek(by: 10)
            case .up: changeVolume(by: 0.1)
            case .down: changeVolume(by: -0.1)
            case .select, .playPause: togglePlayPause(nil)
            case .back: bridge.run("tvBack")
            case .search: showQuickSearch(nil)
            case .menu: break
            }
            return
        }
        if !isTV && Prefs.tvOnController { setTVMode(true) }
        switch input {
        case .up: bridge.run("tvMove", "up")
        case .down: bridge.run("tvMove", "down")
        case .left: bridge.run("tvMove", "left")
        case .right: bridge.run("tvMove", "right")
        case .select: bridge.run("tvSelect")
        case .back: bridge.run("tvBack")
        case .playPause: bridge.run("tvSelect")
        case .search: showQuickSearch(nil)
        case .menu: break
        }
    }

    // MARK: Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }
        switch action {
        case #selector(togglePlayPause(_:)):
            menuItem.title = state.playing ? "Pause" : "Play"
            return state.isActive
        case #selector(skipForward(_:)), #selector(skipBackward(_:)), #selector(skipForwardLong(_:)),
             #selector(skipBackwardLong(_:)), #selector(skipSegment(_:)), #selector(nextEpisode(_:)),
             #selector(volumeUp(_:)), #selector(volumeDown(_:)), #selector(toggleMute(_:)),
             #selector(speedUp(_:)), #selector(slowDown(_:)), #selector(normalSpeed(_:)),
             #selector(togglePictureInPicture(_:)):
            return state.isActive
        case #selector(setSpeed(_:)):
            menuItem.state = abs(state.rate * 100 - Double(menuItem.tag)) < 1 ? .on : .off
            return state.isActive
        case #selector(toggleMiniPlayer(_:)):
            menuItem.title = isMini ? "Exit Mini Player" : "Mini Player"
            return isMini || state.isActive
        case #selector(setExtraBoost(_:)):
            menuItem.state = Prefs.soundBoost == menuItem.tag ? .on : .off
            return true
        case #selector(toggleVoiceBoost(_:)):
            menuItem.state = Prefs.voiceBoost ? .on : .off
            return true
        case #selector(toggleLoudnessMatch(_:)):
            menuItem.state = Prefs.loudnessMatch ? .on : .off
            return true
        case #selector(setLoudnessTarget(_:)):
            menuItem.state = Prefs.loudnessMatch && Prefs.loudnessTarget == menuItem.tag ? .on : .off
            return true
        case #selector(setSubtitleSize(_:)):
            menuItem.state = Prefs.subtitleSize == menuItem.tag ? .on : .off
            return true
        case #selector(toggleTVMode(_:)):
            menuItem.state = isTV ? .on : .off
            return true
        case #selector(toggleFill(_:)):
            menuItem.state = Prefs.videoFill == .fill ? .on : .off
            return true
        case #selector(toggleKeepOnTop(_:)):
            menuItem.state = Prefs.keepOnTop ? .on : .off
            return !isMini
        case #selector(goBack(_:)):
            return webView.canGoBack
        case #selector(goForward(_:)):
            return webView.canGoForward
        default:
            return true
        }
    }

    // MARK: Helpers

    static func volumeSymbol(_ volume: Double) -> String {
        switch volume {
        case ..<0.01: return "speaker.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    static func rateText(_ rate: Double) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return (formatter.string(from: NSNumber(value: rate)) ?? "1") + "×"
    }
}

// MARK: - PlayerBridgeDelegate

extension BrowserWindowController: PlayerBridgeDelegate {
    func bridge(_ bridge: PlayerBridge, didUpdate state: PlayerState, previous: PlayerState) {
        nowPlaying.update(with: state)
        sleepGuard.update(playing: state.playing)
        updateEnhancer()
        if isMini { miniOverlay.update(with: state) }

        window?.title = state.isActive && !state.title.isEmpty ? state.title : "Netflix"

        // Leaving the player: tidy up modes that only make sense while watching.
        if previous.watching && !state.watching {
            if isMini { exitMini() }
            if autoEnteredFullscreen && isFullscreen { window?.toggleFullScreen(nil) }
            autoEnteredFullscreen = false
            setChromeHidden(false)
        }

        // Auto fullscreen when playback starts (Settings → Window).
        if Prefs.autoFullscreen, state.isActive, state.playing, !previous.playing, !previous.watching || !previous.hasVideo,
           !isFullscreen, !isMini {
            autoEnteredFullscreen = true
            window?.toggleFullScreen(nil)
        }

        if !state.playing { setChromeHidden(false) }

        if isMini, state.videoSize != previous.videoSize, state.videoSize.width > 0 {
            window?.contentAspectRatio = NSSize(width: videoAspect(), height: 1)
        }
    }

    func bridgeRequestsFullscreen(_ bridge: PlayerBridge, enter: Bool) {
        guard let window else { return }
        if isMini {
            exitMini()
            return
        }
        if isTV && !enter { return } // TV mode owns full screen
        if enter != isFullscreen { window.toggleFullScreen(nil) }
    }

    func bridgeRequestsWindowDrag(_ bridge: PlayerBridge) {
        guard let window, let event = webView.lastMouseDown,
              NSEvent.pressedMouseButtons & 1 == 1 else { return }
        window.performDrag(with: event)
    }

    func bridgeRequestsTitlebarDoubleClick(_ bridge: PlayerBridge) {
        guard let window else { return }
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
        switch action {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default: window.zoom(nil)
        }
    }

    func bridge(_ bridge: PlayerBridge, idleChanged idle: Bool) {
        guard Prefs.hideChromeWhenIdle, !isMini else { return }
        setChromeHidden(idle && state.playing)
    }

    func bridge(_ bridge: PlayerBridge, didPerform action: AutoAction) {
        hud.flash(symbol: "forward.fill", text: action.hudText)
    }

    func bridgePageReady(_ bridge: PlayerBridge) {
        SelfTest.pageReady(in: webView)
        bridge.setFullscreen(isFullscreen)
        if isMini { bridge.run("setMini", true) }
        if isTV { bridge.run("setTV", true) }
    }
}

// MARK: - WKNavigationDelegate

extension BrowserWindowController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }

        switch scheme {
        case "netflix", "nfm":
            decisionHandler(.cancel)
            webView.load(URLRequest(url: NetflixRoutes.resolveCustomScheme(url)))
            return
        case "http", "https":
            break
        case "about", "blob", "data", "javascript":
            decisionHandler(.allow)
            return
        default:
            // mailto:, tel:, itms-apps: … belong to other apps.
            decisionHandler(.cancel)
            NSWorkspace.shared.open(url)
            return
        }

        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        if isMainFrame, action.navigationType == .linkActivated, !NetflixRoutes.isNetflixHost(url.host) {
            decisionHandler(.cancel)
            NSWorkspace.shared.open(url)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !hasLoadedOnce || !statusOverlay.isHidden else { return }
        hasLoadedOnce = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            statusOverlay.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.statusOverlay.isHidden = true
            self?.statusOverlay.alphaValue = 1
        })
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    private func handleLoadError(_ error: Error) {
        let nsError = error as NSError
        // Cancelled loads and policy decisions are not failures.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && (nsError.code == 102 || nsError.code == 204) { return }
        // Only take over the window if nothing is on screen yet, or we're offline.
        let offline = nsError.domain == NSURLErrorDomain &&
            [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
             NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed].contains(nsError.code)
        guard !hasLoadedOnce || offline else { return }
        statusOverlay.isHidden = false
        statusOverlay.alphaValue = 1
        statusOverlay.show(.error(nsError.localizedDescription))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page's process crashed or was reclaimed; bring it back.
        webView.reload()
    }
}

// MARK: - WKUIDelegate

extension BrowserWindowController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank / window.open: Netflix pages open here, anything else in the browser.
        if let url = action.request.url {
            if NetflixRoutes.isNetflixHost(url.host) {
                webView.load(action.request)
            } else if url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        present(alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
