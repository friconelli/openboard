import Foundation
import Darwin
import Security

/// The iPhone page: a small HTTP server inside OpenBoard, working on the same chats as the Mac.
///
/// It can drive Claude on this Mac, so it is off by default and locked down: it binds to the
/// Tailscale address only (never Wi-Fi or the internet, and the tailnet encrypts the traffic),
/// refuses peers outside Tailscale's range, wants a 256-bit secret from the link, checks the
/// Host header against DNS rebinding and a custom header on POST against cross-site requests.
@MainActor
final class RemoteServer: ObservableObject {
    static let shared = RemoteServer()
    static let enabledKey = "remoteAccessEnabled"
    static let port: UInt16 = 47123

    enum Status: Equatable {
        case off, noTailscale, starting, running, failed(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var address: String?
    @Published private(set) var token: String = RemoteServer.loadToken()

    private weak var store: DeckStore?
    private var acceptSource: DispatchSourceRead?

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// The link to open on the iPhone (the secret moves to a cookie on the first visit).
    var link: String? { address.map { "http://\($0):\(Self.port)/?t=\(token)" } }

    func attach(_ store: DeckStore) {
        self.store = store
        if isEnabled || UserDefaults.standard.bool(forKey: "debugRemote") { start() }
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled { start() } else { stop() }
    }

    /// Picks up a Tailscale address that appeared or changed.
    func refresh() {
        guard isEnabled, Self.tailscaleAddress() != address || status != .running else { return }
        start()
    }

    func stop() {
        closeSocket()
        status = .off
    }

    private func closeSocket() {
        acceptSource?.cancel()
        acceptSource = nil
    }

    func start() {
        closeSocket()
        guard let ip = Self.tailscaleAddress() else {
            address = nil
            status = .noTailscale
            return
        }
        address = ip
        status = .starting

        // A plain socket bound to the Tailscale address: nothing listens on Wi-Fi or loopback.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { status = .failed(String(cString: strerror(errno))); return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = Self.port.bigEndian
        inet_pton(AF_INET, ip, &local.sin_addr)
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            status = .failed(String(cString: strerror(errno)))
            close(fd)
            return
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in self?.acceptPending(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
        status = .running
    }

    /// New secret: every phone already connected is logged out.
    func regenerateToken() {
        token = Self.newToken()
        Self.saveToken(token)
    }

    // MARK: - Token

    private static var tokenURL: URL { ClaudePaths.appSupport.appendingPathComponent("remote-token") }

    private static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func saveToken(_ token: String) {
        try? Data(token.utf8).write(to: tokenURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
    }

    private static func loadToken() -> String {
        if let saved = try? String(contentsOf: tokenURL, encoding: .utf8), saved.count == 64 { return saved }
        let token = newToken()
        saveToken(token)
        return token
    }

    nonisolated static func sameSecret(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: - Tailscale

    /// Tailscale addresses are in the CGNAT range 100.64.0.0/10.
    nonisolated static func isTailscale(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    nonisolated static func tailscaleAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let socket = pointer.pointee.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET),
                  String(cString: pointer.pointee.ifa_name).hasPrefix("utun") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(socket, socklen_t(socket.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            if isTailscale(address) { return address }
        }
        return nil
    }

    // MARK: - HTTP

    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data

        var cookie: String? {
            headers["cookie"]?.components(separatedBy: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("openboard=") }
                .map { String($0.dropFirst("openboard=".count)) }
        }

        /// Parses a complete request; nil while more bytes are needed.
        static func parse(_ data: Data) -> Request? {
            guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let lines = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            guard first.count >= 2 else { return nil }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            let body = data[end.upperBound...]
            guard body.count >= length else { return nil }
            let components = URLComponents(string: String(first[1]))
            var query: [String: String] = [:]
            for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
            return Request(method: String(first[0]), path: components?.path ?? "/", query: query, headers: headers, body: Data(body.prefix(length)))
        }
    }

    struct Response {
        var status = "200 OK"
        var type = "application/json; charset=utf-8"
        var body = Data()
        var headers: [String] = []

        static func json(_ object: Any, status: String = "200 OK") -> Response {
            Response(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
        }
        static func text(_ text: String, type: String) -> Response { Response(type: type, body: Data(text.utf8)) }
        static func error(_ status: String, _ message: String) -> Response { json(["error": message], status: status) }

        var bytes: Data {
            let lines = ["HTTP/1.1 \(status)", "Content-Type: \(type)", "Content-Length: \(body.count)", "Connection: close",
                         "Cache-Control: no-store", "X-Content-Type-Options: nosniff", "Referrer-Policy: no-referrer", "X-Frame-Options: DENY",
                         "Content-Security-Policy: default-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"] + headers
            return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
        }
    }

    private nonisolated func acceptPending(_ listener: Int32) {
        while true {
            var peer = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener, $0, &length) }
            }
            guard client >= 0 else { return }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &peer.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
            guard Self.isTailscale(String(cString: text)) else { close(client); continue }
            DispatchQueue.global(qos: .userInitiated).async { self.serve(client) }
        }
    }

    private nonisolated func serve(_ client: Int32) {
        // Accepted sockets inherit O_NONBLOCK from the listener: this one must block on reads.
        _ = fcntl(client, F_SETFL, 0)
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigpipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while buffer.count <= 1_000_000 {
            if let request = Request.parse(buffer) {
                Task {
                    let bytes = await self.respond(to: request).bytes
                    bytes.withUnsafeBytes { raw in
                        var sent = 0
                        while sent < raw.count {
                            let count = write(client, raw.baseAddress! + sent, raw.count - sent)
                            if count <= 0 { break }
                            sent += count
                        }
                    }
                    close(client)
                }
                return
            }
            let count = read(client, &chunk, chunk.count)
            if count <= 0 { break }
            buffer.append(contentsOf: chunk[0..<count])
        }
        close(client)
    }

    private func respond(to request: Request) async -> Response {
        // DNS rebinding: only the address the link uses.
        guard let address, request.headers["host"] == "\(address):\(Self.port)" else {
            return .error("403 Forbidden", "Host non valido")
        }
        let cookie = "openboard=\(token); Path=/; Max-Age=31536000; HttpOnly; SameSite=Strict"

        switch (request.method, request.path) {
        case ("GET", "/"):
            if let given = request.query["t"], Self.sameSecret(given, token) {
                return Response(status: "302 Found", type: "text/plain", headers: ["Location: /", "Set-Cookie: \(cookie)"])
            }
            return .text(RemoteAssets.html, type: "text/html; charset=utf-8")
        case ("GET", "/app.js"): return .text(RemoteAssets.script, type: "text/javascript; charset=utf-8")
        case ("GET", "/app.css"): return .text(RemoteAssets.style, type: "text/css; charset=utf-8")
        case ("GET", "/manifest.webmanifest"): return .text(RemoteAssets.manifest, type: "application/manifest+json")
        case ("GET", "/icon.png"):
            let url = Bundle.main.url(forResource: "AppIcon-1024", withExtension: "png")
            return Response(type: "image/png", body: url.flatMap { try? Data(contentsOf: $0) } ?? Data())
        default: break
        }

        guard request.path.hasPrefix("/api/") else { return .error("404 Not Found", "Non trovato") }
        // Forms can't set this header and cross-site scripts would need a preflight we never answer.
        if request.method == "POST", request.headers["x-openboard"] != "1" { return .error("403 Forbidden", "Richiesta non valida") }

        if request.path == "/api/login", request.method == "POST" {
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            guard let given = body?["token"] as? String, Self.sameSecret(given, token) else {
                try? await Task.sleep(for: .milliseconds(400))
                return .error("401 Unauthorized", "Codice non valido")
            }
            var response = Response.json(["ok": true])
            response.headers = ["Set-Cookie: \(cookie)"]
            return response
        }
        guard let given = request.cookie, Self.sameSecret(given, token) else {
            return .error("401 Unauthorized", "Accesso richiesto")
        }
        guard let store else { return .error("503 Service Unavailable", "App non pronta") }

        switch (request.method, request.path) {
        case ("GET", "/api/state"): return .json(state(store))
        case ("GET", "/api/history"): return await history(request, store)
        case ("GET", "/api/live"): return live(request, store)
        case ("POST", "/api/send"), ("POST", "/api/permission"), ("POST", "/api/stop"): return action(request, store)
        default: return .error("404 Not Found", "Non trovato")
        }
    }

    // MARK: - API

    private func chatState(_ chat: ChatSession, _ store: DeckStore) -> String {
        if let live = store.liveChats[chat.id] {
            if live.pendingPermission != nil { return "permission" }
            if live.isRunning { return "running" }
        }
        guard let session = store.activeSessions.first(where: { $0.sessionId == chat.id }) else { return "" }
        return session.status == "busy" ? "running" : "waiting"
    }

    private func window(_ window: PlanUsage.Window?) -> Any {
        guard let window else { return NSNull() }
        return ["percent": window.percent, "resets": window.resets.map { PlanUsage.countdown(to: $0) } ?? ""] as [String: Any]
    }

    private func state(_ store: DeckStore) -> [String: Any] {
        let chats = store.visibleChats.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(150).map { chat -> [String: Any] in
            ["id": chat.id, "title": chat.displayTitle, "project": chat.projectName, "agent": chat.agent.rawValue,
             "modified": relative(chat.modifiedAt), "state": chatState(chat, store), "description": store.description(for: chat) ?? ""]
        }
        let named = store.accounts.filter { !$0.isDefault }
        var usage: [[String: Any]] = (named.isEmpty ? store.accounts : named).compactMap { account in
            store.planUsage[account.id].map { ["name": account.name, "session": window($0.session), "week": window($0.week)] }
        }
        if let codex = store.planUsage[DeckStore.codexUsageKey] {
            usage.append(["name": "Codex", "session": window(codex.session), "week": window(codex.week)])
        }
        return ["chats": Array(chats), "usage": usage]
    }

    /// Open in a terminal: writing from here too would write the transcript twice.
    private func isBlocked(_ chat: ChatSession, _ store: DeckStore) -> Bool {
        store.activeSessions.contains { $0.sessionId == chat.id && $0.pid != store.liveChats[chat.id]?.pid }
    }

    private func history(_ request: Request, _ store: DeckStore) async -> Response {
        guard let chat = request.query["id"].flatMap(store.chat(id:)) else { return .error("404 Not Found", "Chat non trovata") }
        let live = store.liveChats[chat.id]
        let cutoff = live?.isRunning == true ? live?.historyCutoff : nil
        let url = chat.fileURL
        let messages = await Task.detached(priority: .userInitiated) { TranscriptReader.read(url, limit: 80, upTo: cutoff).messages }.value
        let rows: [[String: Any]] = messages.map { message in
            switch message.kind {
            case .user: return ["kind": "user", "text": message.text]
            case .assistant: return ["kind": "assistant", "text": message.text]
            case .command: return ["kind": "command", "text": message.text]
            case .tools(let tools): return ["kind": "tools", "text": tools.joined(separator: "\n")]
            }
        }
        return .json(["title": chat.displayTitle, "agent": chat.agent.rawValue, "messages": rows])
    }

    private func live(_ request: Request, _ store: DeckStore) -> Response {
        guard let id = request.query["id"], let chat = store.chat(id: id) else { return .error("404 Not Found", "Chat non trovata") }
        let live = store.liveChats[id]
        var payload: [String: Any] = ["running": live?.isRunning ?? false, "blocked": isBlocked(chat, store),
                                      "queued": live?.queue.map(\.text) ?? []]
        // Once a turn is over its items are in the transcript, which the page reloads.
        if let live, live.isRunning {
            payload["items"] = live.items.compactMap { item -> [String: Any]? in
                switch item {
                case .user(_, let text): return ["kind": "user", "text": text]
                case .text(_, let text): return ["kind": "assistant", "text": text]
                case .thinking: return ["kind": "thinking", "text": ""]
                case .tool(let tool): return ["kind": "tool", "name": tool.name, "text": tool.summary, "done": tool.isDone, "error": tool.isError]
                case .notice(_, let text, _): return ["kind": "notice", "text": text]
                }
            }
        }
        if let permission = live?.pendingPermission {
            payload["permission"] = ["id": permission.id, "tool": permission.tool, "summary": permission.summary,
                                     "command": permission.input["command"] as? String ?? ""]
        }
        return .json(payload)
    }

    private func action(_ request: Request, _ store: DeckStore) -> Response {
        guard let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
              let id = body["id"] as? String, let chat = store.chat(id: id) else { return .error("400 Bad Request", "Richiesta non valida") }
        switch request.path {
        case "/api/send":
            guard let text = body["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .error("400 Bad Request", "Messaggio vuoto")
            }
            guard !isBlocked(chat, store) else { return .error("409 Conflict", "Questa chat è aperta in un terminale sul Mac") }
            store.liveChat(for: chat).send(text)
        case "/api/permission":
            guard let live = store.liveChats[id], let permission = live.pendingPermission,
                  body["permission"] as? String == permission.id, let allow = body["allow"] as? Bool else {
                return .error("409 Conflict", "Richiesta di permesso non più attiva")
            }
            live.answer(permission, allow: allow)
        default:
            store.liveChats[id]?.stop()
        }
        return .json(["ok": true])
    }
}
