import AppKit
import SwiftUI
import Combine
import ServiceManagement

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private var primaryScreen: NSScreen? { NSScreen.screens.first }

/// Vrai si une app occupe tout l'écran principal (vidéo plein écran, jeu…).
private func fullscreenAppActive() -> Bool {
    guard let screen = primaryScreen,
          let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return false }
    let me = ProcessInfo.processInfo.processIdentifier
    let size = screen.frame.size
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              (w[kCGWindowOwnerPID as String] as? Int32) != me,
              let dict = w[kCGWindowBounds as String] as? NSDictionary,
              let b = CGRect(dictionaryRepresentation: dict) else { continue }
        if b.minX <= 0, b.minY <= 0, b.width >= size.width, b.height >= size.height { return true }
    }
    return false
}

// MARK: - Roue du coin

final class CornerPanelController {
    let panel: NSPanel
    let state = CornerState()
    private let spotify: SpotifyMonitor
    private var timer: Timer?
    private var leaveSince: Date?
    private var fullscreenCheck = 0
    private var suppressed = false
    private var bag = Set<AnyCancellable>()

    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "showCorner"); updateVisibility() }
    }

    init(spotify: SpotifyMonitor, web: SpotifyWebAPI, lyrics: LyricsProvider, audio: AudioCapture) {
        self.spotify = spotify
        enabled = UserDefaults.standard.object(forKey: "showCorner") as? Bool ?? true

        panel = NSPanel(contentRect: NSRect(origin: .zero, size: CornerWidgetView.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = FirstMouseHostingView(rootView: CornerWidgetView(
            spotify: spotify, state: state, web: web, lyrics: lyrics, audio: audio))

        reposition()
        panel.orderFrontRegardless()

        spotify.$track
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateVisibility() } }
            .store(in: &bag)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.reposition() }

        if ProcessInfo.processInfo.environment["MYSPOTIFY_NOTIMER"] == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    func reposition() {
        guard let screen = primaryScreen else { return }
        let vf = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: vf.minX, y: vf.minY))
    }

    private func updateVisibility() {
        let visible = enabled && spotify.track != nil && !suppressed
        if state.visible != visible { state.visible = visible }
        if !visible { setExpanded(false) }
    }

    private func setExpanded(_ v: Bool) {
        if state.expanded != v { state.expanded = v }
        spotify.fastPolling = v
        if !v, state.panel == .queue { state.panel = nil } // les paroles, elles, restent épinglées
        panel.ignoresMouseEvents = !v
        leaveSince = nil
    }

    /// Détection du survol par la position de la souris (fiable même quand l'app n'est pas active).
    private func tick() {
        fullscreenCheck += 1
        if fullscreenCheck >= 30 { // ~1 fois par seconde
            fullscreenCheck = 0
            let s = AppSettings.shared.hideInFullscreen && !state.expanded && fullscreenAppActive()
            if s != suppressed { suppressed = s; updateVisibility() }
        }

        guard state.visible else { return }
        let m = NSEvent.mouseLocation
        let o = panel.frame.origin
        let p = CGPoint(x: m.x - o.x, y: m.y - o.y)

        if !state.expanded {
            let c = CornerWidgetView.collapsedCenter
            let r = CornerWidgetView.disc / 2 + 12
            if p.x >= -1, p.y >= -1, hypot(p.x - c.x, p.y - c.y) < r {
                setExpanded(true)
            } else {
                // Paroles épinglées : on ne capte la souris qu'au-dessus du panneau
                let overPinned = state.panel == .lyrics && CornerWidgetView.panelRect(expanded: false).contains(p)
                if panel.ignoresMouseEvents == overPinned { panel.ignoresMouseEvents = !overPinned }
            }
        } else {
            let zone = CGRect(x: -2, y: -2,
                              width: CornerWidgetView.size.width,
                              height: CornerWidgetView.hoverZoneHeight(panelOpen: state.panel != nil))
            if zone.contains(p) || NSEvent.pressedMouseButtons != 0 {
                leaveSince = nil
            } else if let l = leaveSince {
                if Date().timeIntervalSince(l) > 0.35 { setExpanded(false) }
            } else {
                leaveSince = Date()
            }
        }
    }
}

// MARK: - Roue du bureau (centrée et fixe)

final class DesktopWindowController {
    let window: NSWindow
    private let visibility = WindowVisibility()
    private var bag = Set<AnyCancellable>()
    private var playing = false
    private var hideWork: DispatchWorkItem?

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "showDesktop")
            updateShown(animated: false)
        }
    }

    /// La roue n'est affichée que si elle est activée ET qu'une musique joue.
    private func updateShown(animated: Bool) {
        let show = enabled && playing
        hideWork?.cancel(); hideWork = nil
        if show {
            visibility.enabled = true
            if !window.isVisible { window.alphaValue = animated ? 0 : 1; window.orderFront(nil) }
            NSAnimationContext.runAnimationGroup { $0.duration = animated ? 0.4 : 0; window.animator().alphaValue = 1 }
        } else if window.isVisible {
            // Petit délai : évite le clignotement lors d'un changement de piste / pause brève
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hideWork = nil
                NSAnimationContext.runAnimationGroup({ $0.duration = animated ? 0.6 : 0
                    self.window.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    guard let self, !(self.enabled && self.playing) else { return }
                    self.window.orderOut(nil)
                    self.visibility.enabled = false
                })
            }
            hideWork = item
            DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 1.5 : 0), execute: item)
        } else {
            visibility.enabled = false
        }
    }

    init(spotify: SpotifyMonitor, audio: AudioCapture, lyrics: LyricsProvider) {
        enabled = UserDefaults.standard.object(forKey: "showDesktop") as? Bool ?? true
        window = NSWindow(contentRect: NSRect(origin: .zero, size: DesktopWidgetView.size(scale: AppSettings.shared.desktopScale)),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true // fixe : les clics passent au bureau
        // Juste au-dessus des icônes du bureau, sous toutes les fenêtres
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.contentView = NSHostingView(rootView: DesktopWidgetView(
            spotify: spotify, lyrics: lyrics, visibility: visibility, audio: audio))

        center()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.center() }

        // Économie d'énergie : plus d'animation quand la roue est entièrement cachée par des fenêtres
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                               object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            let v = self.window.occlusionState.contains(.visible)
            if self.visibility.visible != v { self.visibility.visible = v }
        }

        AppSettings.shared.$desktopScale
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.center() } }
            .store(in: &bag)

        playing = spotify.isPlaying
        spotify.$isPlaying
            .removeDuplicates()
            .sink { [weak self] p in DispatchQueue.main.async {
                guard let self, self.playing != p else { return }
                self.playing = p
                self.updateShown(animated: true)
            } }
            .store(in: &bag)
        updateShown(animated: false)
    }

    /// Place le centre du disque exactement au centre du bureau.
    func center() {
        guard let vf = primaryScreen?.visibleFrame else { return }
        let scale = AppSettings.shared.desktopScale
        let s = DesktopWidgetView.size(scale: scale)
        let discFromBottom = s.height - DesktopWidgetView.discCenterFromTop(scale: scale)
        window.setFrame(NSRect(x: (vf.midX - s.width / 2).rounded(),
                               y: (vf.midY - discFromBottom).rounded(),
                               width: s.width, height: s.height), display: true)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let spotify = SpotifyMonitor()
    let audio = AudioCapture()
    let web = SpotifyWebAPI()
    let lyrics = LyricsProvider()
    var corner: CornerPanelController!
    var desktop: DesktopWindowController!
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        corner = CornerPanelController(spotify: spotify, web: web, lyrics: lyrics, audio: audio)
        desktop = DesktopWindowController(spotify: spotify, audio: audio, lyrics: lyrics)
        setupStatusItem()

        spotify.onStateChange = { [weak self] in self?.audio.retarget() }
        lyrics.position = { [weak self] in self?.spotify.currentPosition() ?? 0 }
        spotify.onTrackChange = { [weak self] track in
            guard let self else { return }
            self.lyrics.load(track)
            self.web.trackChanged(track?.id)
            if self.corner.state.panel == .queue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.web.fetchQueue() }
            }
        }
        spotify.start()
        if ProcessInfo.processInfo.environment["MYSPOTIFY_NOAUDIO"] == nil { audio.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        audio.stop()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "opticaldisc", accessibilityDescription: "MySpotify")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = AppSettings.shared

        let title: String
        if let t = spotify.track {
            title = "\(spotify.isPlaying ? "▶︎" : "❙❙")  \(t.name) — \(t.artist)"
        } else if let err = spotify.lastError {
            title = "⚠︎ Spotify : \(err)"
        } else {
            title = spotify.spotifyRunning ? "Rien en lecture" : "Spotify n'est pas ouvert"
        }
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(item("Roue sur le bureau", #selector(toggleDesktop), on: desktop.enabled))
        menu.addItem(item("Roue dans le coin", #selector(toggleCorner), on: corner.enabled))
        menu.addItem(.separator())

        menu.addItem(choice("Style des vinyles", DiscStyle.allCases.map { ($0.title, $0.rawValue as Any) },
                            current: settings.style.rawValue, action: #selector(pickStyle(_:))))
        menu.addItem(choice("Taille du vinyle du bureau", AppSettings.scales.map { ($0.0, $0.1 as Any) },
                            current: settings.desktopScale, action: #selector(pickScale(_:))))
        menu.addItem(choice("Vitesse de rotation", AppSettings.speeds.map { ($0.0, $0.1 as Any) },
                            current: settings.spinSpeed, action: #selector(pickSpeed(_:))))
        menu.addItem(choice("Intensité de l'onde", AppSettings.intensities.map { ($0.0, $0.1 as Any) },
                            current: settings.waveIntensity, action: #selector(pickIntensity(_:))))
        menu.addItem(item("Bras de lecture", #selector(toggleTonearm), on: settings.showTonearm))
        menu.addItem(item("Paroles sous le vinyle du bureau", #selector(toggleLyrics), on: settings.desktopLyrics))
        menu.addItem(item("Masquer le coin en plein écran", #selector(toggleFullscreen), on: settings.hideInFullscreen))
        menu.addItem(.separator())

        if web.isConfigured {
            if web.isLoggedIn {
                menu.addItem(item("Compte Spotify connecté — Se déconnecter", #selector(logout)))
            } else {
                menu.addItem(item("Connecter mon compte Spotify (j'aime, à suivre)…", #selector(login)))
            }
            if let s = web.status {
                let i = NSMenuItem(title: "⚠︎ \(s)", action: nil, keyEquivalent: "")
                i.isEnabled = false
                menu.addItem(i)
            }
        }
        menu.addItem(item("Ouvrir au démarrage du Mac", #selector(toggleLogin),
                          on: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quitter MySpotify", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, on: Bool? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        if let on { i.state = on ? .on : .off }
        return i
    }

    private func choice(_ title: String, _ options: [(String, Any)], current: AnyHashable,
                        action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (label, value) in options {
            let i = item(label, action, on: (value as? AnyHashable) == current)
            i.representedObject = value
            sub.addItem(i)
        }
        parent.submenu = sub
        return parent
    }

    @objc private func toggleDesktop() { desktop.enabled.toggle() }
    @objc private func toggleCorner() { corner.enabled.toggle() }
    @objc private func toggleTonearm() { AppSettings.shared.showTonearm.toggle() }
    @objc private func toggleLyrics() { AppSettings.shared.desktopLyrics.toggle() }
    @objc private func toggleFullscreen() { AppSettings.shared.hideInFullscreen.toggle() }
    @objc private func login() { web.login() }
    @objc private func logout() { web.logout() }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let style = DiscStyle(rawValue: raw) {
            AppSettings.shared.style = style
        }
    }
    @objc private func pickScale(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { AppSettings.shared.desktopScale = v }
    }
    @objc private func pickSpeed(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { AppSettings.shared.spinSpeed = v }
    }
    @objc private func pickIntensity(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { AppSettings.shared.waveIntensity = v }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("[MySpotify] Login item: %@", error.localizedDescription)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
