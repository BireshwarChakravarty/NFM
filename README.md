# NFM: Netflix for Mac

**v1.1.0** · [Changelog](CHANGELOG.md)

A native macOS app for Netflix. NFM gives Netflix its own window, Dock icon, menus and keyboard shortcuts. It shows up in Now Playing, responds to media keys and AirPods controls, and has a floating mini player.

**Requires an Apple silicon Mac (M1 or later) running macOS 27 or later.**

> NFM is an unofficial client. It is not made, endorsed or supported by Netflix, Inc. You need your own Netflix subscription.

## How it works

Netflix doesn't offer a Mac app, and it only streams to browsers it recognizes. Safari plays Netflix with Apple's FairPlay DRM, and the same WebKit engine with the same FairPlay support is available to every Mac app as `WKWebView`. NFM hosts Netflix in a `WKWebView` that identifies itself as the version of Safari installed on your Mac. Then it adds the native layer that the browser doesn't have:

```
┌──────────────────────────── NFM.app ────────────────────────────┐
│  AppKit window · menus · Dock menu · Settings (SwiftUI)          │
│  Now Playing + media keys · sleep guard · HUD · mini player      │
│        ▲ state (title, time, playing…)      │ commands           │
│        │                                    ▼                    │
│  ┌─────────────── WKWebView (FairPlay / EME) ───────────────┐    │
│  │  netflix.com   +   nfm.js  (injected page bridge)        │    │
│  │                     └─ talks to Netflix's player API     │    │
│  └──────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────┘
```

The DRM path is Apple's own, so NFM uses no private DRM code and doesn't break any protection. Video quality matches Safari: up to 4K HDR with a capable display and a Premium plan.

## Features

**Watching**
- **Mini player** (⇧⌘M): a floating video window you can drag and resize at the video's aspect ratio. It follows you across Spaces and full-screen apps. Hover to show controls, double-click to go back to the full window, swipe sideways to skip.
- **Auto mini player** (optional): when you switch to another app mid-episode, the video keeps playing in the mini player.
- **Picture in Picture** (⇧⌘P): uses system PiP. If WebKit refuses, NFM falls back to the mini player.
- **Native full screen** (⌃⌘F, or Netflix's own button or `F`). NFM maps Netflix's fullscreen request onto the window's real full screen, so Spaces, gestures and Mission Control behave normally.
- **Fill screen** (⌥⌘F): crops the black bars on wide films, which helps on MacBook displays.
- **Subtitle size** (⌃⌘− / ⌃⌘=, or Playback ▸ Subtitle Size): from 60% to 130% of Netflix's size, kept in place at the bottom of the picture. This only affects NFM; Netflix's own subtitle settings on other devices are untouched.
- **Cinematic chrome**: the title bar is transparent, and the on-screen controls, search bar and HUD use macOS Liquid Glass. While a video plays, the traffic lights fade out when the mouse is idle.
- **Zoom fits the video**: the green button or a title-bar double-click resizes the window to the video's shape.

**Sound**
- **Loudness Match** (on by default, ⌥⌘L): Netflix delivers its sound well below full scale. Audio Diagnostics measured titles at −22 to −30 LUFS with peaks around −8 to −13 dBFS, so they play 8 to 16 dB quieter than other apps. NFM measures loudness as you watch, using the BS.1770 standard, and raises it to a target: −16 LUFS by default, or −14 to match YouTube and Spotify. It never adds more gain than the measured headroom allows, and moves slowly (1 dB/s up, 3 dB/s down), so dialogue gets louder without distortion or pumping. A −1 dBFS limiter is only a safety net. The last gain is remembered, so the next title starts close to right.
- **Voice Boost** (⌥⌘B): a +3 dB presence lift at 3 kHz plus gentle 3:1 compression, for clearer dialogue from small speakers.
- **Extra Boost**: keep pressing ⌘↑ at full volume for up to 300% on top of Loudness Match. Combined gain is capped at +18 dB, and the limiter keeps peaks clean.
- How it works: Netflix's audio is DRM-protected and played by WebKit's helper processes, so a web page can't process it. NFM uses macOS Core Audio process taps, the mechanism per-app volume mixers use, on the WebKit helpers playing Netflix in NFM, and never on NFM's own process or other apps. It mutes the original and plays the processed sound through your current output, and rebuilds when you switch output devices. macOS asks once for **System Audio Recording** access; nothing is recorded or saved. If the tap ever hears silence while Netflix plays, NFM gives you the normal sound back within seconds.

**Audio Diagnostics** (Help ▸ Audio Diagnostics…, ⌥⌘D)
- Measures Netflix's sound as it leaves the player with an ITU-R BS.1770 loudness meter (the standard Netflix itself uses): integrated, short-term and momentary loudness, loudness range, sample peak, and a limiter check.
- Shows what Netflix is actually streaming (codec, channels), Netflix's own volume setting, and your output device and its volume.
- Turns it into plain findings: whether anything is turning the sound down or limiting it, and how the level compares with Netflix's −27 LKFS dialogue target and the −14 LUFS of YouTube and Spotify.
- Listen-only: it uses an unmuted audio tap on the WebKit helpers playing Netflix, so what you hear never changes. **Copy Report** puts the results on the clipboard.

**Control**
- **Now Playing**: the title and episode show in Control Center and the menu bar Now Playing widget. Play, pause, ±10s, scrubbing and next episode work from the keyboard media keys, AirPods and headphones.
- **Keyboard shortcuts** for everything (Help ▸ Keyboard Shortcuts, ⌘/), plus a QuickTime-style on-screen HUD for volume, speed and skips.
- **Playback speed** from 0.5× to 3×, held across Netflix's buffering. It can also persist between episodes.
- **Dock menu**: play/pause, skip, next episode, mini player, plus jumps to Home, My List and Search.

**TV mode** (⌥⌘T)
- Full screen with larger titles, made for watching from the couch.
- Arrow keys move a glowing highlight between titles. At the end of a row the row pages along. Return opens or plays, and Esc or Delete goes back.
- **Game controllers** (Xbox, PlayStation, Switch Pro and other MFi controllers) work as a remote: the D-pad or left stick moves, A selects, B goes back, Y searches, and Menu toggles TV mode. While a video plays, the D-pad seeks ±10 s and changes the volume, and A/X pauses.
- Optionally, NFM can open in TV mode, or switch to it as soon as you pick up a controller.

**Less friction**
- **Auto skip** intros, recaps and credits (each one optional), and auto-answer "Are you still watching?".
- **Skip the profile picker**: NFM remembers your profile and picks it once per launch, so switching profiles from Netflix's own menu still works.
- **Quick search** (⌘K / ⌘F): a Spotlight-style search bar. Paste a Netflix link or title ID to open it directly (⌘L reads the clipboard).
- **Deep links**: `netflix://title/80100172`, `nfm://search?q=dark` and `nfm://browse/my-list` open in the app.
- **Picks up where you left off**: NFM reopens the last page you were on. If you were watching, it opens that title's page rather than auto-playing.
- **Stays signed in**, keeps the display awake only while video plays, and opens non-Netflix links in your default browser.

## Install

### Download a build

Every push builds the app on GitHub Actions. Download `NFM-<version>.zip` from **Releases**, or from the latest run's **Artifacts** on the Actions tab.

The CI build is signed ad hoc, not notarized, so macOS asks for permission on the first launch:

```bash
xattr -dr com.apple.quarantine /Applications/NFM.app
```

You can also right-click the app ▸ **Open** ▸ **Open**.

### Build it yourself

You need an Apple silicon Mac with macOS 27 and Xcode 26.6 or later.

```bash
git clone https://github.com/BireshwarChakravarty/NFM.git
```

```bash
cd NFM && make run
```

`make app` builds `build/NFM.app`, `make install` copies it to `/Applications`, `make zip` packages `build/NFM-<version>.zip`, and `make clean` removes all build output.

To sign with your Developer ID (hardened runtime is enabled automatically):

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh
```

During development you can also open `Package.swift` in Xcode. Run the app from `build/NFM.app` so that the Info.plist and `nfm.js` are bundled.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Play / pause | ⌘P (or Space) |
| Forward / back 10s | ⌘→ / ⌘← |
| Forward / back 1 min | ⌥⌘→ / ⌥⌘← |
| Skip intro or recap | ⌘J |
| Next episode | ⇧⌘→ |
| Volume up / down, mute | ⌘↑ / ⌘↓ (past 100% = Extra Boost), ⌥⌘↓ |
| Loudness Match · Voice Boost | ⌥⌘L · ⌥⌘B |
| Faster / slower / normal speed | ⌥⌘] / ⌥⌘[ / ⌥⌘0 |
| TV mode | ⌥⌘T (then arrows, Return, Esc) |
| Mini player · PiP · keep on top | ⇧⌘M · ⇧⌘P · ⇧⌘T |
| Full screen · fill screen | ⌃⌘F · ⌥⌘F |
| Smaller / larger subtitles | ⌃⌘− / ⌃⌘= |
| Search · open link | ⌘K (⌘F) · ⌘L |
| Home · TV · Movies · New · My List | ⌘1 – ⌘5 |
| Back / forward | ⌘[ / ⌘] |

Playback shortcuts are active only while a video is on screen, so they never steal keys from text fields.

## Settings

| Tab | What you can change |
| --- | --- |
| **Playback** | Loudness Match and its target; Voice Boost; extra boost; auto-skip intros, recaps and credits; answer "still watching"; fit or fill; subtitle size; keep speed between episodes |
| **Window** | Hide chrome when idle; auto full screen; keep on top; open in TV mode; TV mode when a controller is used; mini player on app switch, on all Spaces, and its opacity; quit on close |
| **General** | Skip the profile picker; reopen last page; Now Playing and media keys; keep display awake; on-screen HUD |
| **Advanced** | Web Inspector; custom user agent; sign out and clear all website data |

## Project layout

```
VERSION         The app version (single source of truth)
CHANGELOG.md    What changed in each version
Sources/NFM/
  App/          main.swift, AppDelegate (lifecycle, Dock menu, deep links), MainMenu
  Browser/      BrowserWindowController (window, modes, commands, WebKit delegates),
                WebViewFactory (WebKit config, Safari identity), NetflixRoutes (URLs, links)
  Bridge/       PlayerBridge: typed state and commands between Swift and nfm.js
  Audio/        AudioEnhancer (Loudness Match, Voice Boost, Extra Boost), LoudnessMeter (BS.1770),
                AudioTapMeter, AudioHelpers, AudioDiagnostics (window)
  Features/     NowPlayingController, SleepGuard, GameControllers,
                Overlays (HUD, search, mini player controls, loading/error)
  Settings/     SettingsView (SwiftUI)
  Support/      Preferences, SelfTest (used by CI)
Resources/
  nfm.js        The page bridge: Netflix player API, auto-skip, fullscreen mapping, metadata, TV-mode navigation
  Info.plist, AppIcon.icns (the app icon; replace this file to change it)
scripts/        build-app.sh (bundle and sign)
```

### When Netflix changes its site

All knowledge of Netflix's page lives in **`Resources/nfm.js`**: the `data-uia` selectors for skip buttons and titles, and the path to Netflix's internal player (`netflix.appContext.state.playerApp.getAPI().videoPlayer`). Seeking must go through that player API, because setting `video.currentTime` directly makes Netflix fail with error M7375. If a feature stops working after a Netflix update, the fix is almost always a selector in that file. To find the new one, turn on **Settings ▸ Advanced ▸ Web Inspector** and right-click ▸ Inspect Element.

## Versions and releases

The version lives in the `VERSION` file (`1.1.0`). The app shows it as **v1.1.0** in About NFM and in Audio Diagnostics reports.

To release a new version:
1. Update `VERSION` (for example `1.1.0`) and add a section for it at the top of `CHANGELOG.md`.
2. Commit, then tag and push the tag:

```bash
git tag v1.1.0 && git push origin v1.1.0
```

CI checks that the tag matches `VERSION`, builds the app and publishes a GitHub Release with `NFM-1.1.0.zip` and that version's changelog section.

## Troubleshooting

- **"Unsupported browser" or a playback error (M7xxx / S7xxx).** Update macOS so that Safari's FairPlay support is current, then relaunch. If that doesn't help, set a full Safari user agent in Settings ▸ Advanced. Copy it from Safari's Develop menu, or search for "what is my user agent" in Safari.
- **Loudness Match switches itself off.** Allow NFM in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording, then play the title again.
- **Black video in screenshots or screen recordings** is expected. FairPlay-protected video is hidden from capture, in Safari too.
- **Signed in to the wrong account or stuck in a loop.** Use Settings ▸ Advanced ▸ Reset… to sign out and clear website data.
- **The menu bar Now Playing widget shows nothing.** Make sure **Show in Now Playing** is on in Settings ▸ General, and that the video is playing in NFM.

## Limits

- No offline downloads: Netflix allows those only in its own iOS, iPadOS and Windows apps.
- Quality and stream limits are whatever Netflix allows Safari on your Mac and plan.
- Picture in Picture depends on what WebKit permits for Netflix's player. The mini player always works.
