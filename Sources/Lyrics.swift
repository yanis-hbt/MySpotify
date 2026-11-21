import Foundation

/// Paroles synchronisées via LRCLIB (base libre et gratuite, sans compte).
/// Seuls le titre, l'artiste, l'album et la durée du morceau sont envoyés.
final class LyricsProvider: ObservableObject {
    struct Line: Equatable {
        let time: Double
        let text: String
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var plain: String?
    @Published private(set) var loading = false
    /// Ligne en cours (publiée uniquement quand elle change → très peu de rafraîchissements).
    @Published private(set) var currentIndex: Int?

    /// Fournit la position de lecture (secondes).
    var position: () -> Double = { 0 }
    private var timer: Timer?

    private var currentKey = ""

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard !lines.isEmpty else { if currentIndex != nil { currentIndex = nil }; return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let i = self.index(at: self.position())
            if i != self.currentIndex { self.currentIndex = i }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    var currentLine: String? {
        guard let i = currentIndex, i < lines.count, !lines[i].text.isEmpty else { return nil }
        return lines[i].text
    }

    func load(_ track: Track?) {
        lines = []
        plain = nil
        updateTimer()
        guard let track, !track.name.isEmpty else { loading = false; currentKey = ""; return }
        let key = track.id
        currentKey = key
        loading = true

        var get = URLComponents(string: "https://lrclib.net/api/get")!
        get.queryItems = [
            .init(name: "track_name", value: track.name),
            .init(name: "artist_name", value: track.artist),
            .init(name: "album_name", value: track.album),
            .init(name: "duration", value: String(Int(track.duration.rounded()))),
        ]
        fetch(get.url!) { [weak self] json in
            if let dict = json as? [String: Any], dict["syncedLyrics"] is String || dict["plainLyrics"] is String {
                self?.finish(key, dict)
                return
            }
            // Pas de correspondance exacte → recherche plus souple
            var search = URLComponents(string: "https://lrclib.net/api/search")!
            search.queryItems = [.init(name: "track_name", value: track.name),
                                 .init(name: "artist_name", value: track.artist)]
            self?.fetch(search.url!) { json in
                let results = json as? [[String: Any]] ?? []
                let best = results.first { $0["syncedLyrics"] is String } ?? results.first
                self?.finish(key, best ?? [:])
            }
        }
    }

    /// Index de la ligne en cours à la position donnée (secondes).
    func index(at time: Double) -> Int? {
        guard !lines.isEmpty else { return nil }
        var lo = 0, hi = lines.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= time + 0.25 { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    private func finish(_ key: String, _ dict: [String: Any]) {
        let synced = (dict["syncedLyrics"] as? String).map(Self.parse) ?? []
        let plain = dict["plainLyrics"] as? String
        DispatchQueue.main.async {
            guard self.currentKey == key else { return }
            self.lines = synced
            self.plain = (plain?.isEmpty ?? true) ? nil : plain
            self.loading = false
            self.updateTimer()
        }
    }

    private func fetch(_ url: URL, completion: @escaping (Any?) -> Void) {
        var req = URLRequest(url: url)
        req.setValue("MySpotify/1.0 (macOS desktop widget)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, _, _ in
            completion(data.flatMap { try? JSONSerialization.jsonObject(with: $0) })
        }.resume()
    }

    static func parse(_ lrc: String) -> [Line] {
        let regex = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        var out: [Line] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
                out.append(Line(time: min * 60 + sec, text: text))
            }
        }
        return out.sorted { $0.time < $1.time }
    }
}
