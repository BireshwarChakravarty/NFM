import AppKit

/// The menu bar, built in code. Playback items are sent down the responder
/// chain to `BrowserWindowController`, which enables them only while a video
/// is on screen, so their shortcuts never steal keys from text fields.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(goMenu()))
        main.addItem(submenu(playbackMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    // MARK: Menus

    private static func appMenu() -> NSMenu {
        let name = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: name)
        menu.addItem(item("About \(name)", #selector(AppDelegate.showAbout(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("Search…", #selector(BrowserWindowController.showQuickSearch(_:)), "k"))
        let find = item("Find…", #selector(BrowserWindowController.showQuickSearch(_:)), "f")
        menu.addItem(find)
        menu.addItem(item("Open Netflix Link…", #selector(BrowserWindowController.openLinkFromClipboard(_:)), "l"))
        menu.addItem(.separator())
        menu.addItem(item("Copy Link to This Page", #selector(BrowserWindowController.copyPageLink(_:)), "c", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        // Needed for copy/paste in Netflix's own text fields (sign in, search).
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Reload Page", #selector(BrowserWindowController.reloadPage(_:)), "r"))
        menu.addItem(.separator())
        menu.addItem(item("Actual Size", #selector(BrowserWindowController.actualSize(_:)), "0"))
        menu.addItem(item("Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "+"))
        let zoomInAlt = item("Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "=")
        zoomInAlt.isHidden = true
        zoomInAlt.allowsKeyEquivalentWhenHidden = true
        menu.addItem(zoomInAlt)
        menu.addItem(item("Zoom Out", #selector(BrowserWindowController.zoomOut(_:)), "-"))
        menu.addItem(.separator())
        menu.addItem(item("Fill Screen (Crop Black Bars)", #selector(BrowserWindowController.toggleFill(_:)), "f", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("TV Mode", #selector(BrowserWindowController.toggleTVMode(_:)), "t", [.command, .option]))
        menu.addItem(item("Mini Player", #selector(BrowserWindowController.toggleMiniPlayer(_:)), "m", [.command, .shift]))
        menu.addItem(item("Picture in Picture", #selector(BrowserWindowController.togglePictureInPicture(_:)), "p", [.command, .shift]))
        menu.addItem(item("Keep on Top", #selector(BrowserWindowController.toggleKeepOnTop(_:)), "t", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func goMenu() -> NSMenu {
        let menu = NSMenu(title: "Go")
        menu.addItem(item("Back", #selector(BrowserWindowController.goBack(_:)), "["))
        menu.addItem(item("Forward", #selector(BrowserWindowController.goForward(_:)), "]"))
        menu.addItem(.separator())
        menu.addItem(item("Home", #selector(BrowserWindowController.goHome(_:)), "1"))
        menu.addItem(item("TV Shows", #selector(BrowserWindowController.goTVShows(_:)), "2"))
        menu.addItem(item("Movies", #selector(BrowserWindowController.goMovies(_:)), "3"))
        menu.addItem(item("New & Popular", #selector(BrowserWindowController.goNewAndPopular(_:)), "4"))
        menu.addItem(item("My List", #selector(BrowserWindowController.goMyList(_:)), "5"))
        menu.addItem(item("Browse by Language", #selector(BrowserWindowController.goLanguages(_:)), "6"))
        menu.addItem(.separator())
        menu.addItem(item("Account", #selector(BrowserWindowController.goAccount(_:))))
        return menu
    }

    private static func playbackMenu() -> NSMenu {
        let menu = NSMenu(title: "Playback")
        menu.addItem(item("Play", #selector(BrowserWindowController.togglePlayPause(_:)), "p"))
        menu.addItem(.separator())
        menu.addItem(item("Forward 10 Seconds", #selector(BrowserWindowController.skipForward(_:)), arrow(.right)))
        menu.addItem(item("Back 10 Seconds", #selector(BrowserWindowController.skipBackward(_:)), arrow(.left)))
        menu.addItem(item("Forward 1 Minute", #selector(BrowserWindowController.skipForwardLong(_:)), arrow(.right), [.command, .option]))
        menu.addItem(item("Back 1 Minute", #selector(BrowserWindowController.skipBackwardLong(_:)), arrow(.left), [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Skip Intro / Recap", #selector(BrowserWindowController.skipSegment(_:)), "j"))
        menu.addItem(item("Next Episode", #selector(BrowserWindowController.nextEpisode(_:)), arrow(.right), [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Volume Up", #selector(BrowserWindowController.volumeUp(_:)), arrow(.up)))
        menu.addItem(item("Volume Down", #selector(BrowserWindowController.volumeDown(_:)), arrow(.down)))
        menu.addItem(item("Mute", #selector(BrowserWindowController.toggleMute(_:)), arrow(.down), [.command, .option]))

        let sound = NSMenu(title: "Sound")
        sound.addItem(item("Loudness Match", #selector(BrowserWindowController.toggleLoudnessMatch(_:)), "l", [.command, .option]))
        let targets = NSMenu(title: "Loudness Target")
        for target in LoudnessTarget.allCases {
            let targetItem = item(target.title, #selector(BrowserWindowController.setLoudnessTarget(_:)))
            targetItem.tag = target.rawValue
            targets.addItem(targetItem)
        }
        sound.addItem(submenuItem("Loudness Target", targets))
        sound.addItem(item("Voice Boost (Clearer Dialogue)", #selector(BrowserWindowController.toggleVoiceBoost(_:)), "b", [.command, .option]))
        sound.addItem(.separator())
        let boost = NSMenu(title: "Extra Boost")
        for percent in BrowserWindowController.boostSteps {
            let boostItem = item(percent == 100 ? "Off" : "\(percent)%", #selector(BrowserWindowController.setExtraBoost(_:)))
            boostItem.tag = percent
            boost.addItem(boostItem)
        }
        sound.addItem(submenuItem("Extra Boost", boost))
        sound.addItem(.separator())
        sound.addItem(item("Audio Diagnostics…", #selector(AppDelegate.showAudioDiagnostics(_:))))
        menu.addItem(submenuItem("Sound", sound))
        menu.addItem(.separator())

        let subtitles = NSMenu(title: "Subtitle Size")
        for percent in BrowserWindowController.subtitleSizes {
            let sizeItem = item(percent == 100 ? "Normal" : "\(percent)%", #selector(BrowserWindowController.setSubtitleSize(_:)))
            sizeItem.tag = percent
            subtitles.addItem(sizeItem)
        }
        subtitles.addItem(.separator())
        subtitles.addItem(item("Smaller", #selector(BrowserWindowController.smallerSubtitles(_:)), "-", [.command, .control]))
        subtitles.addItem(item("Larger", #selector(BrowserWindowController.largerSubtitles(_:)), "=", [.command, .control]))
        menu.addItem(submenuItem("Subtitle Size", subtitles))

        let speed = NSMenu(title: "Speed")
        for percent in [50, 75, 100, 125, 150, 175, 200, 250, 300] {
            let title = percent == 100 ? "Normal" : BrowserWindowController.rateText(Double(percent) / 100)
            let speedItem = item(title, #selector(BrowserWindowController.setSpeed(_:)))
            speedItem.tag = percent
            speed.addItem(speedItem)
        }
        speed.addItem(.separator())
        speed.addItem(item("Faster", #selector(BrowserWindowController.speedUp(_:)), "]", [.command, .option]))
        speed.addItem(item("Slower", #selector(BrowserWindowController.slowDown(_:)), "[", [.command, .option]))
        speed.addItem(item("Normal Speed", #selector(BrowserWindowController.normalSpeed(_:)), "0", [.command, .option]))
        let speedItem = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        speedItem.submenu = speed
        menu.addItem(speedItem)

        menu.addItem(.separator())
        menu.addItem(toggle("Skip Intros Automatically", PrefKey.autoSkipIntro))
        menu.addItem(toggle("Skip Recaps Automatically", PrefKey.autoSkipRecap))
        menu.addItem(toggle("Skip Credits to Next Episode", PrefKey.autoNextEpisode))
        menu.addItem(toggle("Answer “Still Watching?”", PrefKey.dismissStillWatching))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Netflix", #selector(AppDelegate.showMainWindow(_:)), "0", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("Keyboard Shortcuts", #selector(AppDelegate.showShortcuts(_:)), "/"))
        menu.addItem(item("Audio Diagnostics…", #selector(AppDelegate.showAudioDiagnostics(_:)), "d", [.command, .option]))
        menu.addItem(item("Netflix Help Center", #selector(AppDelegate.openNetflixHelp(_:))))
        return menu
    }

    // MARK: Builders

    private static func submenuItem(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return item
    }

    /// A checkable menu item bound straight to a boolean preference.
    private static func toggle(_ title: String, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(AppDelegate.togglePreference(_:)), keyEquivalent: "")
        item.representedObject = key
        return item
    }

    private enum Arrow { case left, right, up, down }

    private static func arrow(_ direction: Arrow) -> String {
        let scalar: Int
        switch direction {
        case .left: scalar = NSLeftArrowFunctionKey
        case .right: scalar = NSRightArrowFunctionKey
        case .up: scalar = NSUpArrowFunctionKey
        case .down: scalar = NSDownArrowFunctionKey
        }
        return String(Character(UnicodeScalar(UInt16(scalar))!))
    }
}
