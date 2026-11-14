import Foundation
import Security
import Observation

// Session access: lets a program on this Mac (such as an assistant session) read a server's status and run a short
// list of console commands the owner picked. It's a Unix socket in LeafJuice's own folder, readable only by this
// macOS account, plus a token in the login Keychain. Off until the owner turns it on.
//
// What it can't do, by design: run anything off the list, pass arguments the list doesn't name, run a shell, or see
// chat. Player names and addresses are taken out of log lines. Every call, allowed or refused, is logged.

public struct SessionAccessSettings: Codable, Equatable, Sendable {
    public var enabled = false
    /// Exactly these console commands, with exactly these words. Nothing else is sent.
    public var commands: [String] = ["latchkey reload", "save-all", "list"]
    public init() {}

    enum CodingKeys: String, CodingKey { case enabled, commands }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        commands = try c.decodeIfPresent([String].self, forKey: .commands) ?? SessionAccessSettings().commands
    }
}

public enum SessionAccess {
    public static var settingsFile: URL { AppPaths.home.appendingPathComponent("session-access.json") }
    public static var logFile: URL { AppPaths.home.appendingPathComponent("session-access-log.jsonl") }
    /// Kept short: a Unix socket path can't be longer than 103 bytes.
    public static var socketPath: String { AppPaths.home.appendingPathComponent("session.sock").path }
    public static let keychainService = "LeafJuice session access"
    public static let keychainAccount = "token"
    public static let maxRequestBytes = 8 << 10
    public static let maxLogLines = 200

    public static func loadSettings() -> SessionAccessSettings { JSONStore.load(settingsFile, defaults: SessionAccessSettings()) }
    public static func saveSettings(_ s: SessionAccessSettings) throws { try JSONStore.save(s, to: settingsFile) }

    /// One command as the list keeps it: trimmed, single spaces, no leading slash.
    public static func normalize(_ command: String) -> String {
        var t = command.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("/") { t.removeFirst() }
        return t.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Why a command can't go on the list, or nil when it can.
    public static func problem(adding command: String) -> String? {
        if command.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 0x20 } == true }) { return "A command can't contain a line break or control characters." }
        let n = normalize(command)
        if n.isEmpty { return "Type a command." }
        if n.count > 100 { return "That's longer than any console command needs." }
        if n.lowercased() == "stop" || n.lowercased().hasPrefix("stop ") { return "Stopping the server stays in the app, so it can stop cleanly and keep its records." }
        return nil
    }

    // MARK: Requests

    public struct Request: Codable, Equatable, Sendable {
        public var token: String?
        /// Who's asking, in their own words. Shown in the log; not proof of anything.
        public var caller: String?
        public var call: String?
        public var server: String?
        public var command: String?
        public var lines: Int?
        public init(token: String?, caller: String?, call: String?, server: String? = nil, command: String? = nil, lines: Int? = nil) {
            self.token = token; self.caller = caller; self.call = call; self.server = server; self.command = command; self.lines = lines
        }
    }

    public enum Call: Equatable, Sendable {
        case status
        case log(lines: Int)
        case run(command: String)
    }

    public enum Refusal: Error, Equatable, Sendable {
        case off, unreadable, noToken, badToken, noCaller, unknownCall(String), notOnList(String), lineBreak, tooLong, server(String)
        public var message: String {
            switch self {
            case .off: "Session access is off. The owner turns it on in LeafJuice's Settings."
            case .unreadable: "The request couldn't be read. Send one JSON object on one line."
            case .noToken: "No token was sent."
            case .badToken: "The token is wrong. A new one may have been made."
            case .noCaller: "Say who's asking, in caller."
            case let .unknownCall(c): "\(c.isEmpty ? "No call" : "\"\(c)\"") isn't a call. Use status, log or run."
            case let .notOnList(c): "\"\(c)\" isn't on the owner's list of commands, so it wasn't sent."
            case .lineBreak: "A command can't contain a line break or control characters."
            case .tooLong: "The request is too long."
            case let .server(why): why
            }
        }
    }

    /// Decides whether a request may go ahead. Only this decides; the listener and the app follow it.
    public static func authorize(_ data: Data, settings: SessionAccessSettings, token expected: String?) -> (Request?, Result<Call, Refusal>) {
        guard data.count <= maxRequestBytes else { return (nil, .failure(.tooLong)) }
        guard let request = try? JSONDecoder().decode(Request.self, from: data) else { return (nil, .failure(.unreadable)) }
        guard settings.enabled else { return (request, .failure(.off)) }
        guard let sent = request.token, !sent.isEmpty else { return (request, .failure(.noToken)) }
        guard let expected, !expected.isEmpty, constantTimeEqual(sent, expected) else { return (request, .failure(.badToken)) }
        guard let caller = request.caller?.trimmingCharacters(in: .whitespaces), !caller.isEmpty, caller.count <= 64,
              !caller.contains(where: { $0.isNewline }) else { return (request, .failure(.noCaller)) }
        switch request.call ?? "" {
        case "status": return (request, .success(.status))
        case "log": return (request, .success(.log(lines: min(max(request.lines ?? 50, 1), maxLogLines))))
        case "run":
            let raw = request.command ?? ""
            if raw.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 0x20 } == true }) { return (request, .failure(.lineBreak)) }
            let command = normalize(raw)
            let allowed = Set(settings.commands.map(normalize))
            guard !command.isEmpty, allowed.contains(command) else { return (request, .failure(.notOnList(String(command.prefix(100))))) }
            return (request, .success(.run(command: command)))
        case let other: return (request, .failure(.unknownCall(String(other.prefix(40)))))
        }
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) { diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0) }
        return diff == 0
    }

    // MARK: What comes back

    /// Log lines as a session may see them: no chat, no network addresses, and known player names replaced.
    public static func shareable(_ lines: [ConsoleLine], players: [String]) -> [String] {
        lines.filter { !$0.isChat }.map { redact($0.text, players: players) }
    }

    static let ipv4 = try! NSRegularExpression(pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?\b"#)
    /// Anything that might be an IPv6 address. Each is checked with the system's own parser, so times like 12:00:01 stay.
    static let ipv6Candidate = try! NSRegularExpression(pattern: #"[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?:%[0-9A-Za-z]+)?"#)
    static let uuid = try! NSRegularExpression(pattern: #"\b[0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12}\b"#)

    public static func redact(_ text: String, players: [String]) -> String {
        var out = text
        out = uuid.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "[uuid]")
        for match in ipv6Candidate.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            let candidate = String(out[range]).split(separator: "%").first.map(String.init) ?? ""
            var buffer = in6_addr()
            if candidate.contains("::") || candidate.filter({ $0 == ":" }).count == 7, inet_pton(AF_INET6, candidate, &buffer) == 1 {
                out.replaceSubrange(range, with: "[address]")
            }
        }
        out = ipv4.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "[address]")
        // Longest first, so a name inside another name doesn't leave half of it.
        for name in players.filter({ $0.count >= 3 }).sorted(by: { $0.count > $1.count }) {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            guard let p = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_])\(escaped)(?![A-Za-z0-9_])", options: [.caseInsensitive]) else { continue }
            out = p.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "[player]")
        }
        return out
    }

    // MARK: The log of calls

    public struct LogEntry: Codable, Equatable, Sendable, Identifiable {
        public var id: String { "\(at.timeIntervalSince1970)-\(call)-\(caller)" }
        public var at: Date
        public var caller: String
        public var call: String
        public var server: String?
        public var command: String?
        public var allowed: Bool
        public var note: String
    }

    /// Never records the token. Fields are cut short so a caller can't fill the log with one request.
    public static func record(_ request: Request?, outcome: Result<Call, Refusal>, server: String?, note: String? = nil, at: Date = Date(), to file: URL = logFile) {
        func cut(_ s: String?, _ n: Int) -> String? { s.map { String($0.filter { !$0.isNewline }.prefix(n)) } }
        let entry: LogEntry
        switch outcome {
        case let .success(call):
            let name: String, command: String?
            switch call {
            case .status: name = "status"; command = nil
            case .log: name = "log"; command = nil
            case let .run(c): name = "run"; command = c
            }
            entry = LogEntry(at: at, caller: cut(request?.caller, 64) ?? "?", call: name, server: cut(server, 80), command: command, allowed: true, note: cut(note, 200) ?? "")
        case let .failure(refusal):
            entry = LogEntry(at: at, caller: cut(request?.caller, 64) ?? "?", call: cut(request?.call, 40) ?? "?", server: cut(server ?? request?.server, 80),
                             command: cut(request?.command, 100), allowed: false, note: refusal.message)
        }
        // Kept to the last 5,000 calls.
        History.append(entry, to: file, limit: 5000)
    }

    public static func recentLog(_ count: Int = 100, from file: URL = logFile) -> [LogEntry] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(count).compactMap { try? JSONStore.decoder.decode(LogEntry.self, from: Data($0.utf8)) }.reversed()
    }

    // MARK: The token

    /// The current token, made if there isn't one. Only LeafJuice can read it without asking: anything else, such as
    /// `security find-generic-password`, makes macOS ask the owner first.
    public static func token(create: Bool, keychain: SecKeychain? = nil) -> String? {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                kSecAttrAccount as String: keychainAccount, kSecReturnData as String: true]
        if let keychain { q[kSecMatchSearchList as String] = [keychain] }
        var found: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &found) == errSecSuccess, let data = found as? Data, !data.isEmpty {
            return String(decoding: data, as: UTF8.self)
        }
        guard create else { return nil }
        return try? newToken(keychain: keychain)
    }

    /// Replaces the token, so anything holding the old one is refused from now on.
    @discardableResult
    public static func newToken(keychain: SecKeychain? = nil) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw LeafError("Couldn't make a random token.") }
        let value = bytes.map { String(format: "%02x", $0) }.joined()
        var base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: keychainAccount]
        if let keychain { base[kSecMatchSearchList as String] = [keychain] }
        SecItemDelete(base as CFDictionary)
        var add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                  kSecAttrAccount as String: keychainAccount, kSecValueData as String: Data(value.utf8),
                                  kSecAttrLabel as String: keychainService]
        if let keychain { add[kSecUseKeychain as String] = keychain }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw LeafError("The Keychain didn't save the token (error \(status)).") }
        return value
    }
}

// MARK: - The listener

/// A Unix socket, one request per connection: a line of JSON in, a line of JSON out. Only this macOS account can
/// connect: the folder and the socket are made private to it.
public final class SessionSocket: @unchecked Sendable {
    public let path: String
    private var fd: Int32 = -1
    private let handle: @Sendable (Data) async -> Data
    private let lock = NSLock()

    public init(path: String, handle: @escaping @Sendable (Data) async -> Data) {
        self.path = path
        self.handle = handle
    }

    public var isListening: Bool { lock.lock(); defer { lock.unlock() }; return fd >= 0 }

    public func start() throws {
        guard path.utf8.count < 104 else { throw LeafError("The socket's path is too long for macOS.") }
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Only one listener: an old socket from a crash is removed, but only if it's a socket.
        if let type = try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType {
            guard type == .typeSocket else { throw LeafError("Something that isn't a socket is in the way at \(path).") }
            unlink(path)
        }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw LeafError("Couldn't make the socket.") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8)
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        // Made private before bind, so there's no moment anyone else could connect.
        let old = umask(0o077)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        umask(old)
        guard bound == 0 else { close(s); throw LeafError("Couldn't open the socket (\(String(cString: strerror(errno))))") }
        chmod(path, 0o600)
        guard listen(s, 8) == 0 else { close(s); unlink(path); throw LeafError("Couldn't listen on the socket.") }
        lock.lock(); fd = s; lock.unlock()
        let thread = Thread { [weak self] in self?.acceptLoop(s) }
        thread.name = "LeafJuice session access"
        thread.start()
    }

    public func stop() {
        lock.lock(); let s = fd; fd = -1; lock.unlock()
        guard s >= 0 else { return }
        shutdown(s, SHUT_RDWR)
        close(s)
        unlink(path)
    }

    private func acceptLoop(_ s: Int32) {
        while true {
            let client = accept(s, nil, nil)
            if client < 0 {
                if isListening && errno == EINTR { continue }
                return
            }
            // Same account only, checked again by the kernel's own record of who connected.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let request = Self.readLine(client)
            let handle = self.handle
            Task.detached {
                var reply = await handle(request)
                reply.append(0x0A)
                reply.withUnsafeBytes { raw in
                    var sent = 0
                    while sent < raw.count {
                        let n = write(client, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                        if n <= 0 { break }
                        sent += n
                    }
                }
                close(client)
            }
        }
    }

    /// Up to the first line break, or the size limit plus one byte so the limit is noticed.
    static func readLine(_ client: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while data.count <= SessionAccess.maxRequestBytes {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if let newline = data.firstIndex(of: 0x0A) { return data[data.startIndex..<newline] }
        }
        return data
    }
}

// MARK: - Answering, against the real servers

@MainActor @Observable
public final class SessionAccessService {
    public static let shared = SessionAccessService()
    /// The servers the app knows. Set by the app; the Lab is never offered.
    @ObservationIgnored public var servers: () -> [ServerController] = { [] }
    /// How long to collect a command's output before answering.
    public var commandWait: TimeInterval = 1.5
    public private(set) var socket: SessionSocket?
    public private(set) var error: String?
    /// Bumped on every call, so the app's list can refresh.
    public private(set) var calls = 0
    /// For checks: a throwaway keychain and log file. The app leaves both nil.
    @ObservationIgnored public var keychain: SecKeychain?
    @ObservationIgnored public var logFile: URL?

    public init() {}

    public var isListening: Bool { socket?.isListening == true }

    /// Starts or stops the socket to match the owner's switch.
    public func apply(_ settings: SessionAccessSettings, path: String = SessionAccess.socketPath) {
        if settings.enabled {
            guard socket == nil else { return }
            _ = SessionAccess.token(create: true, keychain: keychain)
            let s = SessionSocket(path: path) { data in await SessionAccessService.answerOnMain(self, data) }
            do { try s.start(); socket = s; error = nil } catch { self.error = error.localizedDescription }
        } else {
            socket?.stop(); socket = nil
        }
    }

    nonisolated static func answerOnMain(_ service: SessionAccessService, _ data: Data) async -> Data {
        await service.answer(data)
    }

    public func answer(_ data: Data) async -> Data {
        let settings = SessionAccess.loadSettings()
        let (request, decision) = SessionAccess.authorize(data, settings: settings, token: SessionAccess.token(create: false, keychain: keychain))
        defer { calls += 1 }
        let log = logFile ?? SessionAccess.logFile
        guard case let .success(call) = decision else {
            SessionAccess.record(request, outcome: decision, server: nil, to: log)
            if case let .failure(refusal) = decision { return Self.reply(["ok": false, "error": refusal.message]) }
            return Self.reply(["ok": false])
        }
        let known = servers().filter { !$0.isLab }
        func pick() -> (ServerController?, String?) {
            if let name = request?.server?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                guard let found = known.first(where: { $0.profile.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                    return (nil, "No server called \"\(name.prefix(60))\". Ask for status to see the names.")
                }
                return (found, nil)
            }
            guard known.count == 1 else { return (nil, known.isEmpty ? "LeafJuice has no servers." : "Name a server: \(known.map(\.profile.name).joined(separator: ", ")).") }
            return (known[0], nil)
        }
        func refuse(_ server: String?, _ why: String) -> Data {
            SessionAccess.record(request, outcome: .failure(.server(why)), server: server, to: log)
            return Self.reply(["ok": false, "error": why])
        }

        switch call {
        case .status:
            var chosen = known
            if request?.server?.isEmpty == false {
                let (found, why) = pick()
                guard let found else { return refuse(request?.server, why ?? "") }
                chosen = [found]
            }
            SessionAccess.record(request, outcome: decision, server: chosen.map(\.profile.name).joined(separator: ", "), to: log)
            return Self.reply(["ok": true, "servers": chosen.map(Self.status)])
        case let .log(lines):
            let (found, why) = pick()
            guard let server = found else { return refuse(request?.server, why ?? "") }
            SessionAccess.record(request, outcome: decision, server: server.profile.name, note: "\(lines) lines", to: log)
            return Self.reply(["ok": true, "server": server.profile.name, "lines": SessionAccess.shareable(Array(server.console.suffix(lines)), players: Self.names(server))])
        case let .run(command):
            let (found, why) = pick()
            guard let server = found else { return refuse(request?.server, why ?? "") }
            guard server.state == ServerState.running else {
                return refuse(server.profile.name, "\(server.profile.name) isn't running under LeafJuice (it's \(server.state.title.lowercased())), so nothing was sent.")
            }
            let before = server.console.last?.id ?? -1
            server.appendWrapper("A session (\(request?.caller ?? "?")) ran: \(command)", level: LogLevel.info)
            server.send(command)
            SessionAccess.record(request, outcome: decision, server: server.profile.name, to: log)
            try? await Task.sleep(nanoseconds: UInt64(commandWait * 1_000_000_000))
            let after = server.console.filter { $0.id > before && $0.origin == .server }
            return Self.reply(["ok": true, "server": server.profile.name, "sent": command, "output": SessionAccess.shareable(after, players: Self.names(server))])
        }
    }

    static func names(_ server: ServerController) -> [String] {
        Array(server.players) + server.knownPlayers.compactMap(\.name)
    }

    /// Counts, never names: who's on a server stays with the people running it.
    static func status(_ server: ServerController) -> [String: Any] {
        var out: [String: Any] = [
            "name": server.profile.name,
            "state": server.state.title,
            "software": server.profile.software.label,
            "playersOnline": server.players.count,
            "plugins": server.plugins.map { ["name": $0.name, "enabled": $0.enabled] as [String: Any] },
            "openIssues": server.issues.filter { $0.status == .open }.count,
        ]
        if let t = server.tps { out["tps"] = [t.oneMinute, t.fiveMinutes, t.fifteenMinutes] }
        if let m = server.mspt { out["mspt"] = m }
        if let started = server.startedAt { out["upSeconds"] = Int(Date().timeIntervalSince(started)) }
        return out
    }

    static func reply(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data(#"{"ok":false}"#.utf8)
    }
}
