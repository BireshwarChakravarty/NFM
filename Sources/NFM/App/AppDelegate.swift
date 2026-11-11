import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var browser: BrowserWindowController!
    private var controllers: GameControllerManager?
    private var settingsWindow: SettingsWindowController?
    private var shortcutsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var audioDiagnostics: AudioDiagnosticsWindowController?
    private var pendingURLs: [URL] = []
    private var launched = false

    // MARK: Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        Prefs.register()
        NSApp.mainMenu = MainMenu.build()
        // Lets the system "Press and hold" / window tabbing behave like a single-window app.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SelfTest.armTimeout()
        browser = BrowserWindowController()
        browser.showWindow(nil)
        browser.window?.makeKeyAndOrderFront(nil)

        if let first = pendingURLs.first {
            browser.loadInitialPage(resolve(first))
        } else {
            browser.loadInitialPage()
        }
        pendingURLs.removeAll()
        launched = true

        if Prefs.openInTVMode { browser.setTVMode(true) }
        let controllers = GameControllerManager()
        controllers.onInput = { [weak self] in self?.browser.handleController($0) }
        controllers.onConnect = { [weak self] _ in
            guard let self, Prefs.tvOnController, !self.browser.isTV, !self.browser.state.isActive else { return }
            self.browser.setTVMode(true)
        }
        self.controllers = controllers

        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(websiteDataCleared),
                                               name: .nfmWebsiteDataCleared, object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationDidResignActive(_ notification: Notification) {
        browser?.appDidResignActive()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        browser?.appDidBecomeActive()
    }

    // MARK: Deep links (netflix://, nfm://, and netflix.com URLs handed to the app)

    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        if let url = urls.first { browser.open(resolve(url)) }
    }

    private func resolve(_ url: URL) -> URL {
        if let scheme = url.scheme?.lowercased(), scheme == "netflix" || scheme == "nfm" {
            return NetflixRoutes.resolveCustomScheme(url)
        }
        return NetflixRoutes.resolve(url.absoluteString) ?? NetflixRoutes.home
    }

    // MARK: Dock menu

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        if browser.state.isActive {
            let title = browser.state.title.isEmpty ? "Now Playing" : browser.state.title
            let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(dockItem(browser.state.playing ? "Pause" : "Play",
                                  #selector(BrowserWindowController.togglePlayPause(_:))))
            menu.addItem(dockItem("Back 10 Seconds", #selector(BrowserWindowController.skipBackward(_:))))
            menu.addItem(dockItem("Next Episode", #selector(BrowserWindowController.nextEpisode(_:))))
            menu.addItem(dockItem(browser.isMini ? "Exit Mini Player" : "Mini Player",
                                  #selector(BrowserWindowController.toggleMiniPlayer(_:))))
            menu.addItem(.separator())
        }
        menu.addItem(dockItem(browser.isTV ? "Exit TV Mode" : "TV Mode", #selector(BrowserWindowController.toggleTVMode(_:))))
        menu.addItem(.separator())
        menu.addItem(dockItem("Home", #selector(BrowserWindowController.goHome(_:))))
        menu.addItem(dockItem("My List", #selector(BrowserWindowController.goMyList(_:))))
        menu.addItem(dockItem("New & Popular", #selector(BrowserWindowController.goNewAndPopular(_:))))
        menu.addItem(dockItem("Search…", #selector(BrowserWindowController.showQuickSearch(_:))))
        return menu
    }

    private func dockItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = browser
        return item
    }

    // MARK: Actions

    @objc func showMainWindow(_ sender: Any?) {
        browser.showWindow(nil)
        browser.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showAbout(_ sender: Any?) {
        if aboutWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
            window.title = "About NFM"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            aboutWindow = window
        }
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showShortcuts(_ sender: Any?) {
        if shortcutsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ShortcutsView()))
            window.title = "Keyboard Shortcuts"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            shortcutsWindow = window
        }
        shortcutsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showAudioDiagnostics(_ sender: Any?) {
        if audioDiagnostics == nil { audioDiagnostics = AudioDiagnosticsWindowController(browser: browser) }
        audioDiagnostics?.present()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openNetflixHelp(_ sender: Any?) {
        NSWorkspace.shared.open(NetflixRoutes.help)
    }

    @objc func togglePreference(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(togglePreference(_:)), let key = menuItem.representedObject as? String {
            menuItem.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
        }
        return true
    }

    // MARK: Notifications

    @objc private func defaultsChanged() {
        DispatchQueue.main.async { self.browser?.settingsChanged() }
    }

    @objc private func websiteDataCleared() {
        Prefs.lastURL = nil
        Prefs.lastProfile = ""
        browser.loadInitialPage(NetflixRoutes.home)
    }
}

// MARK: - App version

enum AppInfo {
    /// "v1.0.0", from the VERSION file via Info.plist.
    static var versionLabel: String {
        "v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
    }
}

// MARK: - About window

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("NFM").font(.title.bold())
            Text(AppInfo.versionLabel)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
            Text("A native Mac home for Netflix.")
                .padding(.top, 6)
            Text("Not affiliated with or endorsed by Netflix, Inc.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 320)
    }
}

// MARK: - Shortcuts window

private struct ShortcutsView: View {
    private let groups: [(String, [(String, String)])] = [
        ("Playback", [
            ("Play / Pause", "⌘P  or  Space"),
            ("Forward / back 10 seconds", "⌘→  /  ⌘←"),
            ("Forward / back 1 minute", "⌥⌘→  /  ⌥⌘←"),
            ("Skip intro or recap", "⌘J"),
            ("Next episode", "⇧⌘→"),
            ("Volume up / down", "⌘↑  /  ⌘↓"),
            ("Mute", "⌥⌘↓"),
            ("Extra boost past 100%", "⌘↑ at full volume"),
            ("Voice Boost (clearer dialogue)", "⌥⌘B"),
            ("Loudness Match on / off", "⌥⌘L"),
            ("Audio Diagnostics", "⌥⌘D"),
            ("Faster / slower / normal speed", "⌥⌘]  /  ⌥⌘[  /  ⌥⌘0"),
        ]),
        ("TV mode", [
            ("Turn TV mode on / off", "⌥⌘T"),
            ("Move between titles", "← → ↑ ↓"),
            ("Open / play", "Return"),
            ("Back", "Esc  or  Delete"),
            ("Game controller", "D-pad · A select · B back · Menu toggles"),
        ]),
        ("Watching", [
            ("Full screen", "⌃⌘F  or  F"),
            ("Mini player", "⇧⌘M"),
            ("Picture in Picture", "⇧⌘P"),
            ("Fill screen (crop black bars)", "⌥⌘F"),
            ("Smaller / larger subtitles", "⌃⌘−  /  ⌃⌘="),
            ("Keep on top", "⇧⌘T"),
        ]),
        ("Browsing", [
            ("Search", "⌘K  or  ⌘F"),
            ("Open a Netflix link from the clipboard", "⌘L"),
            ("Home · TV Shows · Movies · New · My List", "⌘1 – ⌘5"),
            ("Back / forward", "⌘[  /  ⌘]"),
            ("Copy link to this title", "⇧⌘C"),
            ("Zoom in / out / actual size", "⌘+  /  ⌘−  /  ⌘0"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groups, id: \.0) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.0).font(.headline)
                    ForEach(group.1, id: \.0) { row in
                        HStack {
                            Text(row.0)
                            Spacer(minLength: 24)
                            Text(row.1).font(.system(.body, design: .rounded)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("In the mini player: drag anywhere to move, double-click to return, swipe sideways to skip.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 460)
    }
}
