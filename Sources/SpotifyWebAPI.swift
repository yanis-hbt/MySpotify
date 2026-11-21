import Foundation
import AppKit
import CryptoKit
import Network
import Security

struct QueueItem: Identifiable, Equatable {
    let id: String
    let name: String
    let artist: String
    let imageURL: URL?
}

/// Accès au compte Spotify (titres likés, file d'attente) via la Web API officielle.
/// Connexion OAuth « PKCE » : aucun secret stocké dans l'app, seul un jeton de rafraîchissement dans le Trousseau.
final class SpotifyWebAPI: ObservableObject {
    static let port: UInt16 = 8765
    static let redirectURI = "http://127.0.0.1:8765/callback"
    static let scopes = "user-library-read user-library-modify user-read-playback-state user-read-currently-playing"

    @Published private(set) var isLoggedIn = false
    @Published private(set) var isLiked: Bool?
    @Published private(set) var queue: [QueueItem] = []
    @Published private(set) var status: String?

    var clientID: String { Config.spotifyClientID }
    var isConfigured: Bool { !clientID.isEmpty }

    private var accessToken: String?
    private var tokenExpiry = Date.distantPast
    private var verifier: String?
    private var listener: NWListener?
    private var currentTrackURI: String?
    private var pendingTokenCallbacks: [(String?) -> Void] = []

    private var refreshToken: String? {
        get { Keychain.read("spotify-refresh-token") }
        set {
            if let newValue { Keychain.write("spotify-refresh-token", newValue) } else { Keychain.delete("spotify-refresh-token") }
        }
    }

    init() {
        isLoggedIn = isConfigured && refreshToken != nil
    }

    // MARK: - Connexion

    func login() {
        guard isConfigured else { status = "Client ID manquant"; return }
        let v = Self.randomString(64)
        verifier = v
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(v.utf8))))
        startListener()

        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "scope", value: Self.scopes),
        ]
        NSWorkspace.shared.open(c.url!)
    }

    func logout() {
        refreshToken = nil
        accessToken = nil
        isLoggedIn = false
        isLiked = nil
        queue = []
    }

    private func startListener() {
        listener?.cancel()
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else { status = "Port \(Self.port) occupé"; return }
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let target = request.components(separatedBy: "\r\n").first?
                    .split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let comps = URLComponents(string: "http://127.0.0.1" + target)
                let isCallback = comps?.path == "/callback"
                let code = comps?.queryItems?.first { $0.name == "code" }?.value

                let message = code != nil ? "MySpotify est connecté ✓<br><small>Tu peux fermer cet onglet.</small>"
                                          : "Connexion annulée."
                let body = """
                <html><head><meta charset="utf-8"><title>MySpotify</title></head>
                <body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
                background:#0d0d12;color:#fff;font:600 28px -apple-system;text-align:center">\(message)</body></html>
                """
                let response = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })

                guard isCallback, let self else { return }
                self.listener?.cancel()
                self.listener = nil
                if let code { self.exchange(code: code) } else { self.status = "Connexion annulée" }
            }
        }
        l.start(queue: .main)
        listener = l
    }

    private func exchange(code: String) {
        guard let verifier else { return }
        tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ]) { [weak self] ok in
            guard let self else { return }
            self.status = ok ? nil : "Échec de la connexion"
            if ok { self.trackChanged(self.currentTrackURI) }
        }
    }

    private func tokenRequest(_ params: [String: String], completion: @escaping (Bool) -> Void) {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params.map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&").data(using: .utf8)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                guard let token = json?["access_token"] as? String else {
                    if json?["error"] as? String == "invalid_grant" { self.logout() }
                    completion(false)
                    return
                }
                self.accessToken = token
                self.tokenExpiry = Date().addingTimeInterval((json?["expires_in"] as? Double ?? 3600) - 60)
                if let r = json?["refresh_token"] as? String { self.refreshToken = r }
                self.isLoggedIn = true
                completion(true)
            }
        }.resume()
    }

    private func withToken(_ body: @escaping (String) -> Void) {
        if let t = accessToken, Date() < tokenExpiry { body(t); return }
        guard let r = refreshToken else { isLoggedIn = false; return }
        pendingTokenCallbacks.append { t in if let t { body(t) } }
        guard pendingTokenCallbacks.count == 1 else { return } // un rafraîchissement est déjà en cours
        tokenRequest(["grant_type": "refresh_token", "refresh_token": r, "client_id": clientID]) { [weak self] ok in
            guard let self else { return }
            let callbacks = self.pendingTokenCallbacks
            self.pendingTokenCallbacks = []
            callbacks.forEach { $0(ok ? self.accessToken : nil) }
        }
    }

    private func api(_ method: String, _ path: String, completion: @escaping (Int, Any?) -> Void) {
        withToken { token in
            var req = URLRequest(url: URL(string: "https://api.spotify.com/v1" + path)!)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let json = data.flatMap { $0.isEmpty ? nil : try? JSONSerialization.jsonObject(with: $0) }
                DispatchQueue.main.async {
                    if code == 401 { self.accessToken = nil }
                    completion(code, json)
                }
            }.resume()
        }
    }

    // MARK: - Titres likés

    func trackChanged(_ uri: String?) {
        currentTrackURI = uri
        isLiked = nil
        guard isLoggedIn, let uri, uri.hasPrefix("spotify:track:") else { return }
        let encoded = Self.formEncode(uri)
        api("GET", "/me/library/contains?uris=\(encoded)") { [weak self] _, json in
            guard let self, self.currentTrackURI == uri else { return }
            self.isLiked = (json as? [Bool])?.first
        }
    }

    func toggleLike() {
        guard isLoggedIn else { login(); return }
        guard let uri = currentTrackURI, uri.hasPrefix("spotify:track:"), let liked = isLiked else { return }
        isLiked = !liked
        let method = liked ? "DELETE" : "PUT"
        api(method, "/me/library?uris=\(Self.formEncode(uri))") { [weak self] code, _ in
            guard let self, !(200..<300).contains(code), self.currentTrackURI == uri else { return }
            self.isLiked = liked // échec → on revient à l'état précédent
        }
    }

    // MARK: - File d'attente

    func fetchQueue() {
        guard isLoggedIn else { return }
        api("GET", "/me/player/queue") { [weak self] _, json in
            guard let self, let dict = json as? [String: Any], let items = dict["queue"] as? [[String: Any]] else { return }
            self.queue = items.prefix(8).enumerated().compactMap { index, item in
                guard let name = item["name"] as? String else { return nil }
                let artists = (item["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ")
                let show = (item["show"] as? [String: Any])?["name"] as? String
                let images = ((item["album"] as? [String: Any])?["images"] as? [[String: Any]])
                    ?? (item["images"] as? [[String: Any]]) ?? []
                let url = (images.last?["url"] as? String).flatMap(URL.init(string:))
                return QueueItem(id: "\(index)-\(item["uri"] as? String ?? name)", name: name,
                                 artist: artists ?? show ?? "", imageURL: url)
            }
        }
    }

    // MARK: - Utilitaires

    static func randomString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var rng = SystemRandomNumberGenerator()
        return String((0..<n).map { _ in chars[Int(rng.next() % UInt64(chars.count))] })
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

enum Keychain {
    private static let service = "local.myspotify.vinyl"

    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    static func read(_ key: String) -> String? {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String) {
        delete(key)
        var q = base(key)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        SecItemDelete(base(key) as CFDictionary)
    }
}
