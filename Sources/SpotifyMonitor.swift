import AppKit
import SwiftUI

struct Track: Equatable {
    var id: String
    var name: String
    var artist: String
    var album: String
    var artworkURL: String
    var duration: Double // secondes
}

/// Observe l'app Spotify (AppleScript + notifications distribuées). Aucune clé API nécessaire.
final class SpotifyMonitor: ObservableObject {
    static let bundleID = "com.spotify.client"

    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    /// Vrai pendant la lecture et quelques secondes après la pause (laisse le disque ralentir), puis faux pour économiser le CPU.
    @Published private(set) var animating = false
    @Published private(set) var artwork: NSImage?
    /// Change à chaque nouvelle pochette → déclenche l'animation de changement de disque.
    @Published private(set) var artworkVersion = 0
    private(set) var artworkChangedAt = Date.distantPast
    @Published private(set) var accent = NSColor(calibratedRed: 0.12, green: 0.84, blue: 0.38, alpha: 1)
    @Published private(set) var lastError: String?
    @Published private(set) var shuffling = false
    @Published private(set) var repeating = false
    @Published private(set) var volume: Double = 50 // 0…100

    /// Après une action locale, on ignore l'état renvoyé par Spotify pendant un court instant (évite les « sauts »).
    private var overrideUntil = Date.distantPast
    private var volumeWork: DispatchWorkItem?

    private var position: Double = 0
    private var positionStamp = Date()

    var onStateChange: (() -> Void)?
    var onTrackChange: ((Track?) -> Void)?

    private let queue = DispatchQueue(label: "myspotify.applescript", qos: .userInitiated)
    private var timer: Timer?
    private var inFlight = false
    private var statusScript: NSAppleScript?
    private var artworkTask: URLSessionDataTask?
    private var stopAnimating: DispatchWorkItem?

    private static let statusSource = """
    if application "Spotify" is running then
        tell application "Spotify"
            set ps to (player state as string)
            if ps is "stopped" then return {ps}
            set trk to current track
            return {ps, (name of trk), (artist of trk), (album of trk), (artwork url of trk), (duration of trk), (player position), (id of trk), shuffling, repeating, sound volume}
        end tell
    end if
    return {"notrunning"}
    """

    // MARK: - Lecture de l'état

    func currentPosition(at date: Date = Date()) -> Double {
        guard let track else { return 0 }
        let p = position + (isPlaying ? date.timeIntervalSince(positionStamp) : 0)
        return min(max(p, 0), max(track.duration, 0))
    }

    func progress(at date: Date = Date()) -> Double {
        guard let track, track.duration > 0 else { return 0 }
        return currentPosition(at: date) / track.duration
    }

    var spotifyRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(playbackChanged(_:)),
            name: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, suspensionBehavior: .deliverImmediately)

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(appsChanged(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appsChanged(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        scheduleTimer()
        refresh()
    }

    /// Spotify prévient déjà à chaque changement (morceau, lecture/pause) : on n'interroge souvent
    /// que lorsque la carte du coin est ouverte (barre de progression, volume…).
    var fastPolling = false {
        didSet { if fastPolling != oldValue { scheduleTimer(); if fastPolling { refresh() } } }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: fastPolling ? 1.0 : 5.0, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 0.3
    }

    @objc private func playbackChanged(_ n: Notification) { refresh() }

    @objc private func appsChanged(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == Self.bundleID else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    func refresh() {
        guard spotifyRunning else { apply(nil); return }
        guard !inFlight else { return }
        inFlight = true
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.runStatusScript()
            DispatchQueue.main.async {
                self.inFlight = false
                self.apply(result)
            }
        }
    }

    private struct Status {
        var state: String
        var track: Track?
        var position: Double
        var shuffling = false
        var repeating = false
        var volume: Double = 50
    }

    /// Exécuté sur `queue` uniquement.
    private func runStatusScript() -> Status? {
        if statusScript == nil {
            let s = NSAppleScript(source: Self.statusSource)
            var err: NSDictionary?
            s?.compileAndReturnError(&err)
            statusScript = s
        }
        var err: NSDictionary?
        guard let d = statusScript?.executeAndReturnError(&err) else { return nil }
        if let err {
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? "\(err)"
            DispatchQueue.main.async { self.lastError = msg }
            return nil
        }
        DispatchQueue.main.async { if self.lastError != nil { self.lastError = nil } }

        let state = d.atIndex(1)?.stringValue ?? "stopped"
        if state == "notrunning" { return nil }
        guard d.numberOfItems >= 8 else { return Status(state: state, track: nil, position: 0) }

        let track = Track(
            id: d.atIndex(8)?.stringValue ?? "",
            name: d.atIndex(2)?.stringValue ?? "",
            artist: d.atIndex(3)?.stringValue ?? "",
            album: d.atIndex(4)?.stringValue ?? "",
            artworkURL: d.atIndex(5)?.stringValue ?? "",
            duration: (d.atIndex(6)?.doubleValue ?? 0) / 1000)
        var status = Status(state: state, track: track, position: d.atIndex(7)?.doubleValue ?? 0)
        if d.numberOfItems >= 11 {
            status.shuffling = d.atIndex(9)?.booleanValue ?? false
            status.repeating = d.atIndex(10)?.booleanValue ?? false
            status.volume = d.atIndex(11)?.doubleValue ?? 50
        }
        return status
    }

    private func apply(_ s: Status?) {
        let newTrack = (s?.state == "stopped") ? nil : s?.track
        let trackChanged = newTrack?.id != track?.id
        let locked = Date() < overrideUntil && !trackChanged && s != nil
        let playing = locked ? isPlaying : (s?.state == "playing")
        if let s, !locked {
            position = s.position; positionStamp = Date()
            if shuffling != s.shuffling { shuffling = s.shuffling }
            if repeating != s.repeating { repeating = s.repeating }
            if abs(volume - s.volume) > 0.5 { volume = s.volume }
        }

        let playingChanged = playing != isPlaying
        if newTrack != track { track = newTrack }
        if playingChanged { isPlaying = playing }
        if trackChanged {
            loadArtwork(newTrack?.artworkURL)
            onTrackChange?(newTrack)
        }
        updateAnimating()
        if trackChanged || playingChanged { onStateChange?() }
    }

    private func updateAnimating() {
        if isPlaying {
            stopAnimating?.cancel(); stopAnimating = nil
            if !animating { animating = true }
        } else if animating, stopAnimating == nil {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.stopAnimating = nil
                if !self.isPlaying { self.animating = false }
            }
            stopAnimating = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
        }
    }

    // MARK: - Pochette

    private func loadArtwork(_ urlString: String?) {
        artworkTask?.cancel()
        guard let urlString, !urlString.isEmpty, let url = URL(string: urlString) else {
            if artwork != nil { setArtwork(nil, color: nil) }
            return
        }
        artworkTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            let color = Self.accentColor(of: image)
            DispatchQueue.main.async {
                guard let self, self.track?.artworkURL == urlString else { return }
                self.setArtwork(image, color: color)
            }
        }
        artworkTask?.resume()
    }

    private func setArtwork(_ image: NSImage?, color: NSColor?) {
        artwork = image
        if let color { accent = color }
        artworkChangedAt = Date()
        artworkVersion += 1
    }

    /// Couleur la plus vive de la pochette, utilisée pour l'onde.
    static func accentColor(of image: NSImage) -> NSColor? {
        let side = 20
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        var best: (h: CGFloat, s: CGFloat, b: CGFloat)?
        var bestScore: CGFloat = -1
        for x in 0..<side {
            for y in 0..<side {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                let score = s * (b > 0.3 ? b : b * 0.3)
                if score > bestScore { bestScore = score; best = (h, s, b) }
            }
        }
        guard let best, bestScore > 0.1 else { return NSColor(white: 0.92, alpha: 1) } // pochette en noir & blanc
        return NSColor(hue: best.h, saturation: max(best.s, 0.5), brightness: max(best.b, 0.85), alpha: 1)
    }

    // MARK: - Contrôles

    private func send(_ command: String, lock: Bool = true) {
        if lock { overrideUntil = Date().addingTimeInterval(0.8) }
        queue.async { [weak self] in
            var err: NSDictionary?
            NSAppleScript(source: "tell application \"Spotify\" to \(command)")?.executeAndReturnError(&err)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { self?.refresh() }
        }
    }

    func playPause() {
        position = currentPosition(); positionStamp = Date()
        isPlaying.toggle() // retour visuel immédiat
        updateAnimating()
        send("playpause")
    }
    func next() { send("next track", lock: false) }
    func previous() { send("previous track", lock: false) }

    func toggleShuffle() {
        shuffling.toggle()
        send("set shuffling to \(shuffling)")
    }

    func toggleRepeat() {
        repeating.toggle()
        send("set repeating to \(repeating)")
    }

    func seek(toFraction f: Double) {
        guard let track, track.duration > 0 else { return }
        let target = min(max(f, 0), 1) * track.duration
        position = target; positionStamp = Date()
        send(String(format: "set player position to %d", Int(target)))
    }

    /// Appelé en continu pendant qu'on glisse le volume : on limite le nombre d'appels AppleScript.
    func setVolume(_ v: Double, final: Bool = false) {
        volume = min(max(v, 0), 100)
        overrideUntil = Date().addingTimeInterval(1.5)
        volumeWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.send("set sound volume to \(Int(self.volume.rounded()))")
        }
        volumeWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (final ? 0 : 0.08), execute: item)
    }

    var webLink: URL? {
        guard let id = track?.id, id.hasPrefix("spotify:track:") else { return nil }
        return URL(string: "https://open.spotify.com/track/" + id.dropFirst("spotify:track:".count))
    }

    func copyLink() {
        guard let url = webLink else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    func openSpotify() {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}
