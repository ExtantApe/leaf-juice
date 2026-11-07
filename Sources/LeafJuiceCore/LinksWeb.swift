import CryptoKit
import Foundation
import Network

// The plugin links page for people provisioned on the server. It only listens on this Mac. Whatever carries it
// to the internet has to end in HTTPS on this Mac too, so sign-in links and cookies can't be read along the way.
// A player proves who they are in game: the Latchkey plugin gives them a one-time link and leaves its hash in a file.

public struct LinksPageSettings: Codable, Equatable, Sendable {
    public var on = false
    public var port = 8765
    /// What players see, such as https://links.example.com. Requests for any other host are refused.
    public var address = ""
    /// Off until ticked, so a new or private plugin never appears by itself.
    public var shared: Set<String> = []
    public var showPluginVersions = true
    public var showServerVersion = true
    public init() {}

    /// The address only counts if it's plain https, since the sign-in cookie can't travel any other way.
    public var origin: String? {
        guard let parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { return nil }
        return "https://\(host)\(parts.port.map { ":\($0)" } ?? "")"
    }
    public var portIsUsable: Bool { (1024...65535).contains(port) }
}

public struct SignInEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case signedIn, signedOut, expired, refused, removed

        public var title: String {
            switch self {
            case .signedIn: "Signed in"
            case .signedOut: "Signed out"
            case .expired: "Session ended"
            case .refused: "Refused"
            case .removed: "Lost access"
            }
        }
    }
    public var id: String { "\(date.timeIntervalSince1970)-\(uuid)-\(kind.rawValue)" }
    public var date: Date
    public var uuid: String
    public var name: String
    public var kind: Kind
}

/// Everything the page says. The controller fills this from what's been ticked.
public struct LinksPageContent: Equatable, Sendable {
    public struct Plugin: Equatable, Sendable {
        public var name: String
        public var version: String?
        public var link: String?
    }
    public var serverVersion: String?
    public var plugins: [Plugin] = []
}

@MainActor
public final class LinksWeb {
    public static let sessionLength: TimeInterval = 12 * 60 * 60
    public static let logDays = 30
    static let cookie = "__Host-leafjuice"
    static let maxSessions = 200

    public struct Session: Equatable, Identifiable, Sendable {
        public var id: String { uuid }
        public let uuid: String
        public let name: String
        public let started: Date
        public let expires: Date
    }

    public struct Request: Equatable, Sendable {
        public var method: String
        public var path: String
        public var headers: [String: String]
        public var body: Data
    }

    public struct Response: Equatable, Sendable {
        public var status: Int
        public var headers: [String: String] = [:]
        public var body = Data()
    }

    public enum Parsed: Equatable, Sendable {
        case incomplete, bad, ok(Request)
    }

    let paths: ServerPaths
    var settings: () -> LinksPageSettings
    var content: () -> LinksPageContent
    /// Only tests turn this off, because bots can't join an online-mode server.
    var requireOnlineMode = true
    /// Only tests set this, to reach the page without HTTPS.
    var testOrigin: String?
    /// Keyed by a hash of the cookie, so the secret itself isn't kept.
    private var sessions: [String: Session] = [:]
    public var signedIn: [Session] { sessions.values.sorted { $0.started > $1.started } }

    init(paths: ServerPaths, settings: @escaping () -> LinksPageSettings, content: @escaping () -> LinksPageContent) {
        self.paths = paths
        self.settings = settings
        self.content = content
    }

    // MARK: Reading requests

    /// Limits come first, so a stranger can't make this hold much. Anything unusual is refused rather than guessed at.
    public nonisolated static func parse(_ data: Data) -> Parsed {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else { return data.count > 8192 ? .bad : .incomplete }
        guard end.lowerBound <= 8192, let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .bad }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0", first[1].hasPrefix("/") else { return .bad }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return .bad }
            let name = line[..<colon].lowercased()
            guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return .bad }
            // Two of these could mean different things to Caddy and to this.
            if ["host", "content-length", "cookie", "origin"].contains(name), headers[name] != nil { return .bad }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { return .bad }
        var length = 0
        if let text = headers["content-length"] {
            guard let value = Int(text), (0...1024).contains(value) else { return .bad }
            length = value
        }
        let bodyStart = end.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<data.index(bodyStart, offsetBy: length)]
        let path = String(first[1].prefix { $0 != "?" })
        return .ok(Request(method: String(first[0]), path: path, headers: headers, body: Data(body)))
    }

    // MARK: Answering

    public func handle(_ request: Request, now: Date = Date()) -> Response {
        let origin = testOrigin ?? settings().origin
        guard let origin, let separator = origin.range(of: "://"), request.headers["host"]?.lowercased() == String(origin[separator.upperBound...]) else {
            return page(421, "Wrong address", "<p>This page isn't served at that address.</p>")
        }
        switch (request.method, request.path) {
        case ("GET", "/"), ("HEAD", "/"):
            guard let session = session(for: request, now: now) else { return signInHelp() }
            return linksPage(for: session)
        case ("GET", "/signin"), ("HEAD", "/signin"):
            return confirmPage()
        case ("GET", "/signin.js"), ("HEAD", "/signin.js"):
            return Response(status: 200, headers: common(type: "text/javascript; charset=utf-8"), body: Data(Self.script.utf8))
        case ("POST", "/signin"):
            guard request.headers["origin"]?.lowercased() == origin else { return page(403, "Not allowed", "<p>That request didn't come from this page.</p>") }
            return signIn(request, now: now)
        case ("POST", "/signout"):
            guard request.headers["origin"]?.lowercased() == origin else { return page(403, "Not allowed", "<p>That request didn't come from this page.</p>") }
            return signOut(request, now: now)
        case (_, "/"), (_, "/signin"), (_, "/signin.js"), (_, "/signout"):
            var response = page(405, "Not allowed", "<p>That isn't something this page does.</p>")
            response.headers["Allow"] = "GET, HEAD, POST"
            return response
        default:
            return page(404, "Not found", "<p>There's nothing here. <a href=\"/\">Go to the plugin list</a>.</p>")
        }
    }

    private func session(for request: Request, now: Date) -> Session? {
        guard let secret = Self.cookieValue(request.headers["cookie"]) else { return nil }
        let key = Self.hash(secret)
        guard let found = sessions[key] else { return nil }
        if found.expires <= now {
            sessions[key] = nil
            record(.expired, found.uuid, found.name, now)
            return nil
        }
        // Checked on every request, so taking someone off the allowlist ends their access at once.
        guard accessProblem(found.uuid) == nil else {
            sessions[key] = nil
            record(.removed, found.uuid, found.name, now)
            return nil
        }
        return found
    }

    private func signIn(_ request: Request, now: Date) -> Response {
        let failed = page(400, "That link didn't work", "<p>It may have been used already, or be more than two minutes old. Type <code>/signin</code> in game for a new one.</p>")
        guard let token = Self.formValue("token", request.body), token.count == 43,
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return failed }
        let file = paths.plugins.appendingPathComponent("Latchkey/pending/\(Self.hash(token)).json")
        guard let data = try? Data(contentsOf: file),
              // Deleting it is what makes the link single use. If that fails, the link isn't honoured.
              (try? FileManager.default.removeItem(at: file)) != nil,
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uuid = (saved["uuid"] as? String)?.lowercased(), let name = saved["name"] as? String,
              UUID(uuidString: uuid) != nil,
              let expires = (saved["expires"] as? NSNumber)?.doubleValue else { return failed }
        guard Date(timeIntervalSince1970: expires) > now else { return failed }
        if accessProblem(uuid) != nil {
            record(.refused, uuid, name, now)
            return page(403, "You don't have access", "<p>This page is for people on the server's allowlist.</p>")
        }
        // One session per person, and never an unbounded pile of them.
        sessions = sessions.filter { $0.value.uuid != uuid }
        if sessions.count >= Self.maxSessions, let oldest = sessions.min(by: { $0.value.started < $1.value.started }) { sessions[oldest.key] = nil }
        let secret = Self.randomSecret()
        sessions[Self.hash(secret)] = Session(uuid: uuid, name: name, started: now, expires: now.addingTimeInterval(Self.sessionLength))
        record(.signedIn, uuid, name, now)
        var headers = common(type: "text/plain; charset=utf-8")
        headers["Location"] = "/"
        headers["Set-Cookie"] = "\(Self.cookie)=\(secret); Path=/; Max-Age=\(Int(Self.sessionLength)); Secure; HttpOnly; SameSite=Strict"
        return Response(status: 303, headers: headers)
    }

    private func signOut(_ request: Request, now: Date) -> Response {
        if let secret = Self.cookieValue(request.headers["cookie"]), let found = sessions.removeValue(forKey: Self.hash(secret)) {
            record(.signedOut, found.uuid, found.name, now)
        }
        var headers = common(type: "text/plain; charset=utf-8")
        headers["Location"] = "/"
        headers["Set-Cookie"] = "\(Self.cookie)=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict"
        return Response(status: 303, headers: headers)
    }

    /// Whoever runs the server can end someone's session from the app.
    public func signOut(uuid: String, now: Date = Date()) {
        for (key, session) in sessions where session.uuid == uuid {
            sessions[key] = nil
            record(.signedOut, session.uuid, session.name, now)
        }
    }

    /// Closes what's run out and forgets old log entries, even when nobody's visiting.
    public func tidy(now: Date = Date()) {
        for (key, session) in sessions where session.expires <= now {
            sessions[key] = nil
            record(.expired, session.uuid, session.name, now)
        }
        let kept = Self.pruned(log, now: now)
        if kept.count != log.count { try? JSONStore.save(kept, to: logFile) }
    }

    /// Nil means they may see the page. Anything unreadable counts as a no.
    func accessProblem(_ uuid: String) -> String? {
        if requireOnlineMode {
            guard let text = try? String(contentsOf: paths.properties, encoding: .utf8), PropertiesDocument(text).value("online-mode") == "true" else {
                return "online-mode is off"
            }
        }
        guard let allowed = Self.uuids(in: paths.root.appendingPathComponent("whitelist.json")), allowed.contains(uuid.lowercased()) else { return "not on the allowlist" }
        // A server that has never banned anyone may not have this file yet. One it can't make sense of isn't a yes.
        let bans = paths.root.appendingPathComponent("banned-players.json")
        if FileOps.exists(bans) {
            guard let banned = Self.uuids(in: bans), !banned.contains(uuid.lowercased()) else { return "banned" }
        }
        return nil
    }

    private nonisolated static func uuids(in file: URL) -> Set<String>? {
        guard let data = try? Data(contentsOf: file), let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return Set(list.compactMap { ($0["uuid"] as? String)?.lowercased() })
    }

    // MARK: The log

    var logFile: URL { paths.meta.appendingPathComponent("sign-in-log.json") }

    /// Account, time and what happened. No addresses, browsers or pages visited.
    public var log: [SignInEvent] { JSONStore.load(logFile, defaults: []) }

    private func record(_ kind: SignInEvent.Kind, _ uuid: String, _ name: String, _ now: Date) {
        var events = Self.pruned(log, now: now)
        events.append(SignInEvent(date: now, uuid: uuid, name: name, kind: kind))
        try? JSONStore.save(events, to: logFile)
    }

    private nonisolated static func pruned(_ events: [SignInEvent], now: Date) -> [SignInEvent] {
        let cutoff = now.addingTimeInterval(-Double(logDays) * 24 * 60 * 60)
        return events.filter { $0.date >= cutoff }
    }

    // MARK: Small pieces

    nonisolated static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func randomSecret() -> String {
        var bytes = SystemRandomNumberGenerator()
        let raw = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &bytes) })
        return raw.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func cookieValue(_ header: String?) -> String? {
        guard let header else { return nil }
        for part in header.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces)
            if pair.hasPrefix("\(cookie)=") { return String(pair.dropFirst(cookie.count + 1)) }
        }
        return nil
    }

    nonisolated static func formValue(_ name: String, _ body: Data) -> String? {
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") where pair.hasPrefix("\(name)=") {
            return String(pair.dropFirst(name.count + 1)).removingPercentEncoding
        }
        return nil
    }

    nonisolated static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    private func common(type: String) -> [String: String] {
        [
            "Content-Type": type, "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "same-origin",
            "X-Robots-Tag": "noindex", "Strict-Transport-Security": "max-age=31536000",
            "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
        ]
    }

    private func page(_ status: Int, _ title: String, _ html: String) -> Response {
        let body = """
        <!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>\(Self.escape(title))</title><style>\(Self.style)</style></head><body><main><h1>\(Self.escape(title))</h1>\(html)</main></body></html>
        """
        return Response(status: status, headers: common(type: "text/html; charset=utf-8"), body: Data(body.utf8))
    }

    private func signInHelp() -> Response {
        page(200, "Sign in", "<p>This page is for people on this Minecraft server. Join the server and type <code>/signin</code>, then click the link it sends you.</p>")
    }

    private func confirmPage() -> Response {
        page(200, "Sign in", """
        <p id="none">This address needs a link from the game. Join the server and type <code>/signin</code>.</p>
        <form id="form" method="post" action="/signin" hidden><input type="hidden" name="token" id="token"><p>You're about to sign in as the player who asked for this link.</p><button type="submit">Sign in</button></form>
        <script src="/signin.js"></script>
        """)
    }

    private func linksPage(for session: Session) -> Response {
        let shown = content()
        var html = "<form class=\"who\" method=\"post\" action=\"/signout\"><span>Signed in as \(Self.escape(session.name))</span><button type=\"submit\">Sign out</button></form>"
        if let version = shown.serverVersion { html += "<p>This server runs \(Self.escape(version)).</p>" }
        if shown.plugins.isEmpty {
            html += "<p>Nothing has been shared here yet.</p>"
        } else {
            let rows = shown.plugins.map { plugin -> String in
                let link = plugin.link.map { "<a rel=\"noopener noreferrer\" href=\"\(Self.escape($0))\">\(Self.escape(URL(string: $0)?.host ?? $0))</a>" } ?? "<span class=\"muted\">No link yet</span>"
                return "<li><strong>\(Self.escape(plugin.name))</strong>\(plugin.version.map { " <span class=\"muted\">\(Self.escape($0))</span>" } ?? "")<span class=\"go\">\(link)</span></li>"
            }.joined()
            html += "<ul>\(rows)</ul>"
        }
        return page(200, "Plugins", html)
    }

    private static let script = """
    var t=location.hash.slice(1);
    if(t){document.getElementById('token').value=t;document.getElementById('form').hidden=false;document.getElementById('none').hidden=true;history.replaceState(null,'',location.pathname);}
    """

    private static let style = """
    :root{color-scheme:light dark;--ink:#26301f;--bg:#f6f4e8;--card:#fffef6;--line:#dcd9c6;--muted:#66705c;--a:#2e6b1f}
    @media(prefers-color-scheme:dark){:root{--ink:#eceadb;--bg:#1c2018;--card:#262b21;--line:#3b4233;--muted:#a5ad99;--a:#9fd488}}
    body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.5 -apple-system,system-ui,sans-serif}main{max-width:680px;margin:0 auto;padding:32px 20px}
    h1{font-size:28px;margin:0 0 12px}a{color:var(--a)}code{font:15px ui-monospace,monospace}.muted{color:var(--muted)}
    ul{list-style:none;margin:16px 0;padding:0;background:var(--card);border:1px solid var(--line);border-radius:10px}li{display:flex;gap:8px;align-items:baseline;padding:10px 14px;border-top:1px solid var(--line)}li:first-child{border-top:0}.go{margin-left:auto}
    button{font:inherit;padding:6px 14px;border-radius:8px;border:1px solid var(--line);background:var(--card);color:var(--ink);cursor:pointer}.who{display:flex;justify-content:space-between;align-items:center;margin-bottom:12px;color:var(--muted)}
    """
}

/// Listens on this Mac only. Each connection gets one answer and is closed.
@MainActor
public final class LinksListener {
    private var listener: NWListener?
    private var open = 0
    private let web: LinksWeb
    private let allowed: () -> Bool
    private let queue = DispatchQueue(label: "leafjuice.links")
    private static let maxConnections = 32
    public private(set) var isListening = false
    public var onFailure: ((String) -> Void)?

    init(web: LinksWeb, allowed: @escaping () -> Bool = { true }) {
        self.web = web
        self.allowed = allowed
    }

    public func start(port: Int) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw LeafError("\(port) isn't a usable port.") }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        let created = try NWListener(using: parameters)
        created.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready: self?.isListening = true
                case let .failed(error):
                    self?.stop()
                    self?.onFailure?("Port \(port) couldn't be used: \(error.localizedDescription)")
                default: break
                }
            }
        }
        created.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in self?.accept(connection) }
        }
        created.start(queue: queue)
        listener = created
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isListening = false
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil, open < Self.maxConnections, allowed() else {
            if !allowed() { stop() }
            connection.cancel()
            return
        }
        open += 1
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: Task { @MainActor [weak self] in self?.open -= 1 }
            default: break
            }
        }
        connection.start(queue: queue)
        // A connection that says nothing doesn't get to sit here.
        queue.asyncAfter(deadline: .now() + 10) { connection.cancel() }
        read(connection, Data())
    }

    private nonisolated func read(_ connection: NWConnection, _ soFar: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, finished, error in
            guard let self, error == nil else { connection.cancel(); return }
            let all = soFar + (data ?? Data())
            switch LinksWeb.parse(all) {
            case .incomplete:
                if finished || all.count > 16384 { connection.cancel() } else { self.read(connection, all) }
            case .bad:
                self.send(LinksWeb.Response(status: 400), head: false, connection)
            case let .ok(request):
                Task { @MainActor [weak self] in
                    guard let self else { connection.cancel(); return }
                    guard self.allowed() else { self.stop(); connection.cancel(); return }
                    let response = self.web.handle(request)
                    self.send(response, head: request.method == "HEAD", connection)
                }
            }
        }
    }

    private nonisolated func send(_ response: LinksWeb.Response, head: Bool, _ connection: NWConnection) {
        let reason = [200: "OK", 303: "See Other", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 421: "Misdirected Request"][response.status] ?? "Error"
        var text = "HTTP/1.1 \(response.status) \(reason)\r\nConnection: close\r\nContent-Length: \(response.body.count)\r\n"
        for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        let bytes = Data(text.utf8) + (head ? Data() : response.body)
        connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
    }
}

extension ServerController {
    private var savedPage: URL { paths.meta.appendingPathComponent("links-page.json") }

    public var linksPageSettings: LinksPageSettings {
        get { JSONStore.load(savedPage, defaults: LinksPageSettings()) }
        set { try? JSONStore.save(newValue, to: savedPage) }
    }

    /// Only what's ticked, and only the fields switched on. Suggestions are never included.
    public var linksPageContent: LinksPageContent {
        let current = linksPageSettings
        var out = LinksPageContent(serverVersion: current.showServerVersion ? profile.software.label : nil)
        out.plugins = pluginLinkRows.filter { current.shared.contains($0.key) }.map {
            .init(name: $0.name, version: current.showPluginVersions && !$0.version.isEmpty ? $0.version : nil, link: $0.link?.url)
        }
        return out
    }

    public var linksPageProblem: String? {
        let current = linksPageSettings
        if current.origin == nil { return "Enter the page's address first. It has to start with https://." }
        if !current.portIsUsable { return "The port has to be between 1024 and 65535." }
        return nil
    }

    /// Readable whether or not the page is being served.
    public var signInLog: [SignInEvent] { JSONStore.load(paths.meta.appendingPathComponent("sign-in-log.json"), defaults: []) }

    /// Holds the log to its 30 days even on a server whose page stays off.
    public func tidySignInLog() {
        (linksWeb ?? LinksWeb(paths: paths, settings: { LinksPageSettings() }, content: { LinksPageContent() })).tidy()
    }

    public var hasLatchkey: Bool { plugins.contains { $0.enabled && $0.key == "latchkey" } }

    public var onlineModeIsOn: Bool {
        guard let text = try? String(contentsOf: paths.properties, encoding: .utf8) else { return false }
        return PropertiesDocument(text).value("online-mode") == "true"
    }

    public func startLinksPage() throws {
        stopLinksPage()
        guard Modules.shared.isOn(.links) else { throw LeafError("Plugin links is switched off in Settings.") }
        if let problem = linksPageProblem { throw LeafError(problem) }
        let web = linksWeb ?? LinksWeb(paths: paths, settings: { [weak self] in self?.linksPageSettings ?? LinksPageSettings() }, content: { [weak self] in self?.linksPageContent ?? LinksPageContent() })
        web.tidy()
        let listener = LinksListener(web: web, allowed: { Modules.shared.isOn(.links) })
        listener.onFailure = { [weak self] message in
            self?.linksPageError = message
            self?.linksListener = nil
        }
        try listener.start(port: linksPageSettings.port)
        linksWeb = web
        linksListener = listener
        linksPageError = nil
        linksTidying = Task { [weak web] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                web?.tidy()
            }
        }
    }

    /// Sessions stay until they expire or the app quits, so turning it off and on doesn't sign anyone out.
    /// The page can't be reached while it's off.
    public func stopLinksPage() {
        linksListener?.stop()
        linksListener = nil
        linksTidying?.cancel()
        linksTidying = nil
    }
}
