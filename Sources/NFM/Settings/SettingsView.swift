import AppKit
import SwiftUI
import WebKit

struct SettingsView: View {
    var body: some View {
        TabView {
            PlaybackSettings()
                .tabItem { Label("Playback", systemImage: "play.rectangle") }
            WindowSettings()
                .tabItem { Label("Window", systemImage: "macwindow") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520)
        .padding(.vertical, 6)
    }
}

private struct PlaybackSettings: View {
    @AppStorage(PrefKey.autoSkipIntro) private var autoSkipIntro = true
    @AppStorage(PrefKey.autoSkipRecap) private var autoSkipRecap = true
    @AppStorage(PrefKey.autoNextEpisode) private var autoNextEpisode = false
    @AppStorage(PrefKey.dismissStillWatching) private var dismissStillWatching = true
    @AppStorage(PrefKey.rememberSpeed) private var rememberSpeed = false
    @AppStorage(PrefKey.subtitleSize) private var subtitleSize = 100
    @AppStorage(PrefKey.videoFill) private var videoFill = VideoFill.fit.rawValue
    @AppStorage(PrefKey.soundBoost) private var soundBoost = 100
    @AppStorage(PrefKey.voiceBoost) private var voiceBoost = false
    @AppStorage(PrefKey.loudnessMatch) private var loudnessMatch = true
    @AppStorage(PrefKey.loudnessTarget) private var loudnessTarget = -16

    var body: some View {
        Form {
            Section("Skip the boring parts") {
                Toggle("Skip intros automatically", isOn: $autoSkipIntro)
                Toggle("Skip recaps automatically", isOn: $autoSkipRecap)
                Toggle("Jump to the next episode as soon as credits start", isOn: $autoNextEpisode)
                Toggle("Answer “Are you still watching?” for me", isOn: $dismissStillWatching)
            }
            Section {
                Toggle("Loudness Match", isOn: $loudnessMatch)
                Picker("Target", selection: $loudnessTarget) {
                    ForEach(LoudnessTarget.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .disabled(!loudnessMatch)
                Toggle("Voice Boost: clearer dialogue (presence lift + gentle compression)", isOn: $voiceBoost)
                Picker("Extra boost", selection: $soundBoost) {
                    ForEach(BrowserWindowController.boostSteps, id: \.self) { step in
                        Text(step == 100 ? "Off" : "\(step)%").tag(step)
                    }
                }
            } header: {
                Text("Sound")
            } footer: {
                Text("Netflix delivers its sound well below full scale, so it plays quieter than other apps. Loudness Match measures it as you watch and raises it to the target, never by more than the headroom allows, so nothing distorts. macOS asks once for System Audio Recording access; NFM only processes its own sound and records nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Picture & speed") {
                Picker("Video", selection: $videoFill) {
                    ForEach(VideoFill.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Subtitle size", selection: $subtitleSize) {
                    ForEach(BrowserWindowController.subtitleSizes, id: \.self) { size in
                        Text(size == 100 ? "Normal" : "\(size)%").tag(size)
                    }
                }
                Toggle("Keep my playback speed between episodes", isOn: $rememberSpeed)
            }
        }
        .formStyle(.grouped)
        .frame(height: 540)
    }
}

private struct WindowSettings: View {
    @AppStorage(PrefKey.hideChromeWhenIdle) private var hideChromeWhenIdle = true
    @AppStorage(PrefKey.autoFullscreen) private var autoFullscreen = false
    @AppStorage(PrefKey.keepOnTop) private var keepOnTop = false
    @AppStorage(PrefKey.miniOnDeactivate) private var miniOnDeactivate = false
    @AppStorage(PrefKey.miniAllSpaces) private var miniAllSpaces = true
    @AppStorage(PrefKey.miniOpacity) private var miniOpacity = 1.0
    @AppStorage(PrefKey.quitOnClose) private var quitOnClose = false
    @AppStorage(PrefKey.openInTVMode) private var openInTVMode = false
    @AppStorage(PrefKey.tvOnController) private var tvOnController = true

    var body: some View {
        Form {
            Section("While watching") {
                Toggle("Hide window buttons when the mouse is idle", isOn: $hideChromeWhenIdle)
                Toggle("Go full screen when a video starts", isOn: $autoFullscreen)
                Toggle("Keep window on top of other apps", isOn: $keepOnTop)
            }
            Section {
                Toggle("Open NFM in TV mode", isOn: $openInTVMode)
                Toggle("Switch to TV mode when a game controller is used", isOn: $tvOnController)
            } header: {
                Text("TV mode")
            } footer: {
                Text("Full screen with bigger titles. Browse with the arrow keys or a controller, Return to open, Esc to go back. ⌥⌘T toggles it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Mini player") {
                Toggle("Float in the mini player when I switch to another app", isOn: $miniOnDeactivate)
                Toggle("Show the mini player on every Space", isOn: $miniAllSpaces)
                LabeledContent("Opacity") {
                    Slider(value: $miniOpacity, in: 0.3...1.0)
                        .frame(width: 220)
                }
            }
            Section("Closing the window") {
                Toggle("Quit NFM when the window is closed", isOn: $quitOnClose)
            }
        }
        .formStyle(.grouped)
        .frame(height: 540)
    }
}

private struct GeneralSettings: View {
    @AppStorage(PrefKey.autoProfile) private var autoProfile = false
    @AppStorage(PrefKey.lastProfile) private var lastProfile = ""
    @AppStorage(PrefKey.restoreLastPage) private var restoreLastPage = true
    @AppStorage(PrefKey.nowPlaying) private var nowPlaying = true
    @AppStorage(PrefKey.preventSleep) private var preventSleep = true
    @AppStorage(PrefKey.showHUD) private var showHUD = true

    var body: some View {
        Form {
            Section("Starting up") {
                Toggle(isOn: $autoProfile) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Skip the “Who’s watching?” screen")
                        Text(lastProfile.isEmpty
                             ? "Pick a profile once and NFM will remember it."
                             : "Opens “\(lastProfile)” automatically, once per launch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Reopen the page I was on last time", isOn: $restoreLastPage)
            }
            Section("System") {
                Toggle("Show in Now Playing and use media keys & AirPods controls", isOn: $nowPlaying)
                Toggle("Keep the display awake while playing", isOn: $preventSleep)
                Toggle("Show on-screen feedback for volume, speed and skips", isOn: $showHUD)
            }
        }
        .formStyle(.grouped)
        .frame(height: 330)
    }
}

private struct AdvancedSettings: View {
    @AppStorage(PrefKey.developerExtras) private var developerExtras = false
    @AppStorage(PrefKey.userAgentOverride) private var userAgentOverride = ""
    @State private var confirmSignOut = false
    @State private var cleared = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable Web Inspector (right-click → Inspect Element)", isOn: $developerExtras)
                TextField("Custom user agent", text: $userAgentOverride,
                          prompt: Text("Automatic: \(WebViewFactory.safariApplicationName())"))
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Developer")
            } footer: {
                Text("These take effect the next time NFM starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Data") {
                HStack {
                    Text(cleared ? "Signed out and website data cleared." : "Sign out and remove all Netflix cookies and cached data.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset…", role: .destructive) { confirmSignOut = true }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
        .confirmationDialog("Sign out and clear all website data?", isPresented: $confirmSignOut) {
            Button("Sign Out & Clear", role: .destructive) {
                let store = WKWebsiteDataStore.default()
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                    cleared = true
                    NotificationCenter.default.post(name: .nfmWebsiteDataCleared, object: nil)
                }
            }
        }
    }
}

extension Notification.Name {
    static let nfmWebsiteDataCleared = Notification.Name("NFMWebsiteDataCleared")
}

final class SettingsWindowController: NSWindowController {
    convenience init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }
}
