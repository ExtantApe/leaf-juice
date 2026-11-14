import Foundation
import Network
import Security

// MARK: - What's saved

/// How players and admins reach this server: the address players type, and each tunnel or service that carries traffic.
/// Saved in the server's `.leafjuice/connections.json`. Only names, addresses and where a secret lives are saved here,
/// never a secret itself: those stay in the Keychain or in the service's own file.
public struct ConnectionSettings: Codable, Equatable, Sendable {
    /// What players type in Minecraft to join, such as play.example.test. Shown on the Overview page.
    public var playerAddress = ""
    /// The web map players open, such as https://map.example.test.
    public var mapURL = ""
    /// The website sign-in page that goes with the code LeafJuice issues after an account lookup.
    public var signInURL = ""
    public var services: [ConnectionService] = []
    public init() {}

    enum CodingKeys: String, CodingKey { case playerAddress, mapURL, signInURL, services }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playerAddress = try c.decodeIfPresent(String.self, forKey: .playerAddress) ?? ""
        mapURL = try c.decodeIfPresent(String.self, forKey: .mapURL) ?? ""
        signInURL = try c.decodeIfPresent(String.self, forKey: .signInURL) ?? ""
        services = try c.decodeIfPresent([ConnectionService].self, forKey: .services) ?? []
    }
}

/// Who provides a connection. playit has its own checks; anything else gets the checks every service gets.
/// Another tunnel can be added as a case with its own check, without changing the file format (2026-11-14: playit only).
public enum ConnectionProvider: String, Codable, CaseIterable, Sendable {
    case playit, other

    public var title: String {
        switch self {
        case .playit: "playit.gg"
        case .other: "Other"
        }
    }

    /// A provider this version doesn't know is read as Other, so a newer file still opens.
    public init(from decoder: Decoder) throws {
        self = ConnectionProvider(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }
}

/// What a connection carries, which decides how it's checked.
public enum ConnectionTraffic: String, Codable, CaseIterable, Sendable {
    /// Minecraft players. Checked with the game's own status ping.
    case game
    /// A web address, such as pack downloads or a sign-in page. Checked with an HTTP request.
    case web
    /// Nothing checked end to end.
    case access
    /// A name at a DNS provider, such as play.example.test. Checked by looking it up.
    case dns

    public var title: String {
        switch self {
        case .game: "Players (Minecraft)"
        case .web: "Web"
        case .access: "Admin access"
        case .dns: "A name (DNS)"
        }
    }

    public init(from decoder: Decoder) throws {
        self = ConnectionTraffic(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .access
    }
}

/// Where a service's secret lives. The value itself is never in LeafJuice's files.
public enum SecretLocation: Codable, Equatable, Sendable {
    /// In the login Keychain, under ConnectionSecrets.service and this account.
    case keychain(account: String)
    /// In a file the service itself keeps, such as playit's agent file.
    case file(path: String)
    /// The service's own agent holds it and reports whether it has one (playit).
    case agent
}

public struct ConnectionService: Codable, Equatable, Identifiable, Sendable {
    /// A short name with no spaces. Also names its Keychain item.
    public var id: String
    public var name: String
    public var provider: ConnectionProvider
    public var traffic: ConnectionTraffic
    public var enabled: Bool
    /// What the tunnel forwards to on this Mac, such as 127.0.0.1:25565. Empty when it isn't a tunnel.
    public var localAddress: String
    /// What people outside use: play.example.test for a game, https://pack.example.test:14248 for web.
    public var publicAddress: String
    public var secret: SecretLocation?
    /// Only for Other providers: which tool's agent this is, in words. Shown, not run.
    public var note: String

    public init(id: String, name: String, provider: ConnectionProvider, traffic: ConnectionTraffic, enabled: Bool = true,
                localAddress: String = "", publicAddress: String = "", secret: SecretLocation? = nil, note: String = "") {
        self.id = id; self.name = name; self.provider = provider; self.traffic = traffic; self.enabled = enabled
        self.localAddress = localAddress; self.publicAddress = publicAddress; self.secret = secret; self.note = note
    }

    enum CodingKeys: String, CodingKey { case id, name, provider, traffic, enabled, localAddress, publicAddress, secret, note }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        provider = try c.decodeIfPresent(ConnectionProvider.self, forKey: .provider) ?? .other
        traffic = try c.decodeIfPresent(ConnectionTraffic.self, forKey: .traffic) ?? .access
        // Off unless the file says on, so a half-written entry doesn't start being checked or shown as working.
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        localAddress = try c.decodeIfPresent(String.self, forKey: .localAddress) ?? ""
        publicAddress = try c.decodeIfPresent(String.self, forKey: .publicAddress) ?? ""
        // A pasted value instead of a location is dropped (and named by the loader), keeping the rest of the entry.
        secret = (try? c.decodeIfPresent(SecretLocation.self, forKey: .secret)) ?? nil
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    public static func isUsableID(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9][a-z0-9-]{0,39}$"#, options: .regularExpression) != nil
    }

    /// A starting point for each common setup. Addresses are left for the owner to fill in.
    public static func preset(_ provider: ConnectionProvider, _ traffic: ConnectionTraffic, id: String) -> ConnectionService {
        switch (provider, traffic) {
        case (.playit, .game): ConnectionService(id: id, name: "playit game tunnel", provider: .playit, traffic: .game, localAddress: "127.0.0.1:25565", secret: .agent)
        case (.playit, _): ConnectionService(id: id, name: "playit web tunnel", provider: .playit, traffic: .web, localAddress: "127.0.0.1:8766", secret: .agent)
        case (.other, .dns): ConnectionService(id: id, name: "Domain name", provider: .other, traffic: .dns)
        case (.other, let t): ConnectionService(id: id, name: t == .web ? "Web service" : "Port forward", provider: .other, traffic: t)
        }
    }
}

// MARK: - Loading

public enum ConnectionStore {
    public static func file(_ meta: URL) -> URL { meta.appendingPathComponent("connections.json") }

    public struct Loaded: Equatable, Sendable {
        public var settings: ConnectionSettings
        /// Plain-language problems with the file. The settings are still usable; nothing here is fatal.
        public var problems: [String]
        /// The file couldn't be read at all. Saving moves it aside first, so nothing is lost.
        public var unreadable: Bool
        /// Secrets pasted into the file, by where they are. Never their values.
        public var pasted: [PastedSecret] = []
    }

    public struct PastedSecret: Equatable, Sendable, Identifiable {
        /// The connection it's in, or nil for the top of the file.
        public var service: String?
        public var key: String
        public var id: String { "\(service ?? "-")/\(key)" }
        public var account: String { service ?? "connections-\(key.lowercased())" }
        public init(service: String?, key: String) { self.service = service; self.key = key }
    }

    /// Takes a pasted secret out of the file and puts it in the Keychain. For a connection, it becomes that connection's
    /// secret. The value goes straight from the file to `save` and isn't kept, shown or logged anywhere else.
    /// If `save` fails, the file is left as it was.
    public static func moveToKeychain(_ pasted: PastedSecret, meta: URL, save: (String, String) throws -> Void) throws {
        let url = file(meta)
        guard let data = try? Data(contentsOf: url), var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LeafError("connections.json couldn't be read.")
        }
        if let service = pasted.service {
            guard var services = object["services"] as? [Any],
                  let index = services.firstIndex(where: { ($0 as? [String: Any])?["id"] as? String == service }),
                  var entry = services[index] as? [String: Any] else { throw LeafError("\(service) isn't in the file any more.") }
            guard let value = entry[pasted.key] as? String, !value.isEmpty else { throw LeafError("There's no text to move in \(pasted.key).") }
            try save(value, pasted.account)
            entry.removeValue(forKey: pasted.key)
            entry["secret"] = ["keychain": ["account": pasted.account]]
            services[index] = entry
            object["services"] = services
        } else {
            guard let value = object[pasted.key] as? String, !value.isEmpty else { throw LeafError("There's no text to move in \(pasted.key).") }
            try save(value, pasted.account)
            object.removeValue(forKey: pasted.key)
        }
        let out = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: url, options: .atomic)
    }

    /// Keys that look like a secret was pasted into the file. They're ignored, and named so it can be moved.
    static let secretLooking = ["secret", "token", "key", "password", "authkey", "auth_key", "apikey", "api_key", "agent_key", "secretkey"]

    public static func load(_ meta: URL) -> Loaded {
        let url = file(meta)
        guard let data = try? Data(contentsOf: url) else { return Loaded(settings: ConnectionSettings(), problems: [], unreadable: false) }
        return parse(data)
    }

    public static func parse(_ data: Data) -> Loaded {
        var problems: [String] = []
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Loaded(settings: ConnectionSettings(), problems: ["connections.json couldn't be read, so no connections are shown. It's kept as it is until you save."], unreadable: true)
        }
        var settings = ConnectionSettings()
        settings.playerAddress = (object["playerAddress"] as? String) ?? ""
        settings.mapURL = (object["mapURL"] as? String) ?? ""
        settings.signInURL = (object["signInURL"] as? String) ?? ""
        flagSecrets(object, at: "the file", into: &problems)
        var pasted: [PastedSecret] = []
        func collect(_ entry: [String: Any], service: String?) {
            for key in entry.keys.sorted() where secretLooking.contains(key.lowercased()) {
                if key == "secret", entry[key] is [String: Any] { continue }
                if let text = entry[key] as? String, !text.isEmpty { pasted.append(PastedSecret(service: service, key: key)) }
            }
        }
        collect(object, service: nil)
        var seen = Set<String>()
        for (index, raw) in ((object["services"] as? [Any]) ?? []).enumerated() {
            guard let entry = raw as? [String: Any], let body = try? JSONSerialization.data(withJSONObject: entry),
                  let service = try? JSONStore.decoder.decode(ConnectionService.self, from: body) else {
                problems.append("Connection \(index + 1) couldn't be read and was skipped.")
                continue
            }
            let label = service.name.isEmpty ? service.id : service.name
            flagSecrets(entry, at: label, into: &problems)
            if ConnectionService.isUsableID(service.id) { collect(entry, service: service.id) }
            guard ConnectionService.isUsableID(service.id) else {
                problems.append("\(label) was skipped: its id must be lowercase letters, numbers and hyphens.")
                continue
            }
            guard seen.insert(service.id).inserted else {
                problems.append("A second connection called \(service.id) was skipped.")
                continue
            }
            settings.services.append(service)
        }
        return Loaded(settings: settings, problems: problems, unreadable: false, pasted: pasted)
    }

    private static func flagSecrets(_ entry: [String: Any], at label: String, into problems: inout [String]) {
        for key in entry.keys.sorted() where secretLooking.contains(key.lowercased()) {
            // `secret` holding where a secret lives ({"agent":{}}, {"keychain":…}, {"file":…}) is the real field.
            if key == "secret", entry[key] is [String: Any] { continue }
            problems.append("\(label) has a field called \(key), which was ignored. Secrets belong in the Keychain, never in this file.")
        }
    }

    public static func save(_ settings: ConnectionSettings, meta: URL, replacingUnreadable: Bool) throws {
        let url = file(meta)
        if replacingUnreadable, FileManager.default.fileExists(atPath: url.path) {
            let aside = meta.appendingPathComponent("connections.json.unreadable")
            try? FileManager.default.removeItem(at: aside)
            try FileManager.default.moveItem(at: url, to: aside)
        }
        try JSONStore.save(settings, to: url)
    }
}

// MARK: - Secrets

/// Whether a secret is there, without reading it.
public enum SecretPresence: Equatable, Sendable {
    case present
    case missing
    /// The Keychain is locked or wouldn't answer without asking. Not the same as missing.
    case unavailable(String)
}

/// The login Keychain, for services that need a secret LeafJuice itself holds.
public enum ConnectionSecrets {
    public static let service = "LeafJuice connections"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// Looks for the item without reading its value and without showing a password prompt.
    /// `keychain` is for checks, which use a throwaway keychain file; the app always uses the login Keychain.
    public static func presence(account: String, in keychain: SecKeychain? = nil) -> SecretPresence {
        var q = query(account)
        q[kSecReturnAttributes as String] = true
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        if let keychain { q[kSecMatchSearchList as String] = [keychain] }
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        switch status {
        case errSecSuccess: return .present
        case errSecItemNotFound: return .missing
        case errSecInteractionNotAllowed, errSecAuthFailed: return .unavailable("The Keychain is locked, or didn't let LeafJuice look.")
        default: return .unavailable("The Keychain answered with error \(status).")
        }
    }

    /// Saves or replaces it. The value is never logged or written anywhere else.
    public static func save(_ value: String, account: String, in keychain: SecKeychain? = nil) throws {
        guard !value.isEmpty else { throw LeafError("Nothing to save.") }
        remove(account: account, in: keychain)
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrLabel as String] = "LeafJuice connection: \(account)"
        if let keychain { q[kSecUseKeychain as String] = keychain }
        else { q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw LeafError("The Keychain didn't save it (error \(status)).") }
    }

    public static func remove(account: String, in keychain: SecKeychain? = nil) {
        var q = query(account)
        if let keychain { q[kSecMatchSearchList as String] = [keychain] }
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - Checking

public enum ConnectionHealth: Int, Comparable, Sendable {
    case off, ready, unknown, warning, notReady
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    public var title: String {
        switch self {
        case .off: "Off"
        case .ready: "Ready"
        case .unknown: "Not checked"
        case .warning: "Needs a look"
        case .notReady: "Not ready"
        }
    }
}

public struct ConnectionStatus: Equatable, Sendable {
    public var health: ConnectionHealth
    /// One sentence for the list.
    public var summary: String
    /// Each thing checked, in order, in plain words.
    public var details: [String]
    public init(_ health: ConnectionHealth, _ summary: String, details: [String] = []) {
        self.health = health; self.summary = summary; self.details = details
    }
}

/// Everything a check touches outside its own code, so checks can run against made-up answers.
public protocol ConnectionProbe: Sendable {
    /// Runs a tool with a time limit. Nil when it couldn't start.
    func run(_ path: String, _ args: [String], timeout: TimeInterval) async -> (status: Int32, out: String)?
    func isExecutable(_ path: String) -> Bool
    /// Size and permission bits, or nil when there's no such file.
    func fileInfo(_ path: String) -> (size: Int, mode: Int)?
    /// The last part of a text file, or nil.
    func tail(_ path: String, bytes: Int) -> String?
    func keychain(_ account: String) -> SecretPresence
    func tcp(host: String, port: Int, timeout: TimeInterval) async -> Bool
    /// Asks a Minecraft server for its status, as the game's server list does.
    func minecraftStatus(host: String, port: Int, timeout: TimeInterval) async -> Bool
    /// The HTTP status code, or nil when nothing answered.
    func httpStatus(_ url: URL, timeout: TimeInterval) async -> Int?
    /// The addresses a name looks up to, or nil when the lookup failed.
    func resolve(_ host: String) async -> [String]?
    var now: Date { get }
    var home: String { get }
}

/// What the check needs to know about the server itself.
public struct ConnectionContext: Sendable {
    public var serverRunning: Bool
    public var serverIP: String
    public var serverPort: Int
    public var packHostPort: Int?
    public init(serverRunning: Bool, serverIP: String, serverPort: Int, packHostPort: Int? = nil) {
        self.serverRunning = serverRunning; self.serverIP = serverIP; self.serverPort = serverPort; self.packHostPort = packHostPort
    }
}

public struct HostPort: Equatable, Sendable {
    public init(host: String, port: Int) { self.host = host; self.port = port }
    public var host: String
    public var port: Int

    /// Reads host:port, [v6]:port, or a bare host with a default port. Nil for anything else.
    public static func parse(_ text: String, defaultPort: Int? = nil) -> HostPort? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains(" "), !t.contains("/") else { return nil }
        var host = t, portText: String?
        if t.hasPrefix("[") {
            guard let close = t.firstIndex(of: "]") else { return nil }
            host = String(t[t.index(after: t.startIndex)..<close])
            let rest = t[t.index(after: close)...]
            if !rest.isEmpty { guard rest.hasPrefix(":") else { return nil }; portText = String(rest.dropFirst()) }
        } else if let colon = t.lastIndex(of: ":") {
            guard t.firstIndex(of: ":") == colon else { return nil }
            host = String(t[..<colon]); portText = String(t[t.index(after: colon)...])
        }
        guard !host.isEmpty, host.range(of: #"^[A-Za-z0-9.:_-]+$"#, options: .regularExpression) != nil else { return nil }
        let port: Int?
        if let portText { port = Int(portText) } else { port = defaultPort }
        guard let port, (1...65535).contains(port) else { return nil }
        return HostPort(host: host, port: port)
    }

    public var text: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
    public var isLoopback: Bool { host == "127.0.0.1" || host == "::1" || host == "localhost" }
}

public enum ConnectionCheck {
    /// Where each provider's command-line tool usually is. The first that runs is used.
    public static func playitTools(home: String) -> [String] {
        ["\(home)/Minecraft/_tools/playit/playit", "/opt/homebrew/bin/playit", "/usr/local/bin/playit", "/usr/bin/playit"]
    }
    public static func playitLog(home: String) -> String { "\(home)/Library/Logs/playit/playitd.log" }
    public static func playitSocket(home: String) -> String { "\(home)/Library/Application Support/playit_gg/playitd.sock" }

    /// Checks one service. `outside` also tries the public address over the internet, which only happens when asked.
    /// Never throws: anything that can't be worked out is reported as not ready or unknown.
    public static func run(_ service: ConnectionService, context: ConnectionContext, probe: ConnectionProbe, outside: Bool = false) async -> ConnectionStatus {
        guard service.enabled else { return ConnectionStatus(.off, "Turned off.") }
        var details: [String] = []
        var worst = ConnectionHealth.ready
        var headline: String?
        func note(_ health: ConnectionHealth, _ text: String) {
            details.append(text)
            if health > worst { worst = health; headline = text }
        }

        // The settings themselves.
        let local: HostPort? = service.localAddress.isEmpty ? nil : HostPort.parse(service.localAddress)
        if !service.localAddress.isEmpty, local == nil {
            note(.notReady, "The local address isn't something like 127.0.0.1:25565.")
        }
        if service.provider == .playit, service.localAddress.isEmpty {
            note(.notReady, "A playit tunnel needs the local address it forwards to.")
        }
        let publicTarget = publicTarget(service)
        if !service.publicAddress.isEmpty, publicTarget == nil {
            note(.notReady, service.traffic == .web ? "The public address isn't a web address like https://pack.example.test." : "The public address isn't something like play.example.test or play.example.test:25565.")
        }

        // Its secret, without reading it.
        if let secret = service.secret {
            switch secret {
            case let .keychain(account):
                switch probe.keychain(account) {
                case .present: details.append("Its secret is in the Keychain.")
                case .missing: note(.notReady, "Its secret isn't in the Keychain yet. Add it in the connection's settings.")
                case let .unavailable(why): note(.unknown, "Couldn't look for its secret. \(why)")
                }
            case let .file(path):
                let expanded = path.hasPrefix("~/") ? probe.home + path.dropFirst() : path
                if let info = probe.fileInfo(expanded) {
                    if info.size == 0 { note(.notReady, "Its secret file is empty.") }
                    else if info.mode & 0o077 != 0 { note(.warning, "Its secret file can be read by other accounts on this Mac. Run chmod 600 on it.") }
                    else { details.append("Its secret file is there, readable only by you.") }
                } else {
                    note(.notReady, "Its secret file isn't there.")
                }
            case .agent:
                break  // The provider's own check reports it.
            }
        }

        // The provider's own agent.
        let found: [Finding]
        switch service.provider {
        case .playit: found = await checkPlayit(local: local, probe: probe)
        case .other: found = []
        }
        for f in found {
            if let h = f.health { note(h, f.text) } else { details.append(f.text) }
        }

        // The thing on this Mac it forwards to.
        if let local {
            if service.traffic == .game {
                let ip = context.serverIP.trimmingCharacters(in: .whitespaces)
                if local.port != context.serverPort {
                    note(.notReady, "It forwards to port \(local.port), but the server uses port \(context.serverPort).")
                } else if ["127.0.0.1", "localhost", "::1"].contains(ip), !local.isLoopback {
                    note(.notReady, "It forwards to \(local.text), but the server only listens on this Mac (127.0.0.1). Change the tunnel to 127.0.0.1:\(local.port).")
                } else if !ip.isEmpty, ip != "0.0.0.0", ip != local.host, !(local.isLoopback && ["127.0.0.1", "localhost", "::1"].contains(ip)) {
                    note(.notReady, "It forwards to \(local.text), but the server only listens on \(ip).")
                }
            }
            if service.traffic == .web, let pack = context.packHostPort, local.port != pack, service.provider == .playit {
                details.append("It forwards to port \(local.port); pack serving here uses \(pack).")
            }
            let answers: Bool = service.traffic == .game
                ? await probe.minecraftStatus(host: local.host, port: local.port, timeout: 2)
                : await probe.tcp(host: local.host, port: local.port, timeout: 2)
            if answers {
                details.append("Something answers at \(local.text).")
            } else if service.traffic == .game && !context.serverRunning {
                note(.warning, "The server isn't running, so nothing answers at \(local.text) yet.")
            } else {
                note(service.traffic == .game ? .notReady : .warning, "Nothing answers at \(local.text), so the tunnel has nowhere to send people.")
            }
        }

        // From outside, only when asked.
        if outside, let publicTarget {
            switch publicTarget {
            case let .game(hp):
                if await probe.minecraftStatus(host: hp.host, port: hp.port, timeout: 6) { details.append("The server answered at \(hp.text), from the internet.") }
                else { note(.notReady, "The server didn't answer at \(hp.text) from the internet.") }
            case let .name(host):
                if let found = await probe.resolve(host), !found.isEmpty { details.append("The name looks up to \(found.count) address\(found.count == 1 ? "" : "es").") }
                else { note(.notReady, "The name \(host) doesn't look up to anything.") }
            case let .web(url):
                if let code = await probe.httpStatus(url, timeout: 8) { details.append("The web address answered (HTTP \(code)).") }
                else { note(.notReady, "Nothing answered at the web address from the internet.") }
            }
        } else if publicTarget != nil {
            details.append("Not tried from the internet yet.")
        }

        switch worst {
        case .ready: return ConnectionStatus(.ready, readySummary(service), details: details)
        default: return ConnectionStatus(worst, headline ?? worst.title, details: details)
        }
    }

    /// A web address players are given, such as the map or the sign-in page. Nil when it isn't one.
    public static func playerURL(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains(" "), let url = URL(string: t), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Checks a player-facing web address. The quiet check only reads it; `outside` also asks it for a page.
    public static func runURL(_ text: String, probe: ConnectionProbe, outside: Bool) async -> ConnectionStatus {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return ConnectionStatus(.off, "Not set.") }
        guard let url = playerURL(t) else { return ConnectionStatus(.notReady, "This isn't a web address like https://example.test.") }
        let insecure = url.scheme?.lowercased() == "http"
        let plain = "It uses http, so sign-in links and cookies would cross the internet unprotected. Use https."
        var details = insecure ? [plain] : []
        guard outside else {
            details.append("Not tried from the internet yet.")
            return insecure ? ConnectionStatus(.warning, plain, details: details) : ConnectionStatus(.unknown, "Not checked yet.", details: details)
        }
        guard let code = await probe.httpStatus(url, timeout: 8) else {
            return ConnectionStatus(.notReady, "Nothing answered at this address from the internet.", details: details)
        }
        details.append("It answered (HTTP \(code)).")
        if code >= 500 { return ConnectionStatus(.notReady, "It answered with a server error (HTTP \(code)).", details: details) }
        if code == 401 || code == 403 {
            return ConnectionStatus(insecure ? .warning : .ready, insecure ? plain : "It answers from the internet, and asks for sign-in.", details: details)
        }
        if code >= 400 { return ConnectionStatus(.warning, "It answered, but with HTTP \(code). Players may see an error page.", details: details) }
        if insecure { return ConnectionStatus(.warning, plain, details: details) }
        return ConnectionStatus(.ready, "It answers from the internet.", details: details)
    }

    enum PublicTarget: Equatable { case game(HostPort), web(URL), name(String) }

    static func publicTarget(_ service: ConnectionService) -> PublicTarget? {
        let text = service.publicAddress.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        switch service.traffic {
        case .access:
            return nil
        case .dns:
            return HostPort.parse(text, defaultPort: 1).map { .name($0.host) }
        case .game:
            return HostPort.parse(text, defaultPort: 25565).map { .game($0) }
        case .web:
            guard let url = URL(string: text), ["https", "http"].contains(url.scheme ?? ""), url.host?.isEmpty == false else { return nil }
            return .web(url)
        }
    }

    static func readySummary(_ service: ConnectionService) -> String {
        switch service.provider {
        case .playit: "playit's agent is running and the tunnel reaches this Mac."
        case .other: service.localAddress.isEmpty ? "Set up." : "Reaches this Mac."
        }
    }

    // MARK: playit

    /// What `playit status` says about the agent. Read from its plain output, which is all it offers.
    public struct PlayitAgent: Equatable, Sendable {
        public var running: Bool
        public var secretConfigured: Bool?
        public var version: String?
    }

    public static func parsePlayitStatus(_ text: String) -> PlayitAgent? {
        var phase: String?, secret: Bool?, version: String?
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Phase:") { phase = t.dropFirst(6).trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("Secret configured:") { secret = t.hasSuffix("true") ? true : t.hasSuffix("false") ? false : nil }
            if t.hasPrefix("Version:") { version = t.dropFirst(8).trimmingCharacters(in: .whitespaces) }
        }
        guard let phase else { return nil }
        return PlayitAgent(running: phase == "running", secretConfigured: secret, version: version)
    }

    /// Recent lines where the agent couldn't reach this address on this Mac.
    public static func playitRefusals(log: String, local: HostPort, since: Date) -> Int {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var count = 0
        for line in log.split(separator: "\n") where line.contains("ConnectionRefused") || line.contains("failed to connect to local") {
            guard line.contains(", \(local.text))") else { continue }
            guard let space = line.firstIndex(of: " "), let when = stamp.date(from: String(line[..<space])), when >= since else { continue }
            count += 1
        }
        return count
    }

    /// One thing a provider check found. No health means it's just information.
    struct Finding { var health: ConnectionHealth?; var text: String }

    private static func checkPlayit(local: HostPort?, probe: ConnectionProbe) async -> [Finding] {
        var out: [Finding] = []
        func note(_ h: ConnectionHealth, _ t: String) { out.append(Finding(health: h, text: t)) }
        func info(_ t: String) { out.append(Finding(health: nil, text: t)) }
        guard let tool = playitTools(home: probe.home).first(where: probe.isExecutable) else {
            note(.notReady, "playit's agent isn't installed where LeafJuice looks (\(playitTools(home: "~").first!)).")
            return out
        }
        // `status` can stay open after printing, so it gets a short limit and whatever it printed is read.
        let result = await probe.run(tool, ["--socket-path", playitSocket(home: probe.home), "status"], timeout: 5)
        guard let result, let agent = parsePlayitStatus(result.out) else {
            note(.notReady, "playit's agent isn't running, or didn't answer.")
            return out
        }
        guard agent.running else { note(.notReady, "playit's agent isn't running."); return out }
        info("playit's agent is running\(agent.version.map { " (version \($0))" } ?? "").")
        switch agent.secretConfigured {
        case true?: info("The agent has its secret.")
        case false?: note(.notReady, "playit's agent has no secret yet, so it can't open tunnels. Run playit setup.")
        case nil: note(.unknown, "Couldn't tell whether playit's agent has its secret.")
        }
        if let local, let log = probe.tail(playitLog(home: probe.home), bytes: 256 << 10) {
            let refused = playitRefusals(log: log, local: local, since: probe.now.addingTimeInterval(-15 * 60))
            if refused > 0 { note(.warning, "In the last 15 minutes playit couldn't reach \(local.text) \(refused) time\(refused == 1 ? "" : "s").") }
        }
        return out
    }

}

// MARK: - The real probe

public struct SystemConnectionProbe: ConnectionProbe {
    public init() {}
    public var now: Date { Date() }
    public var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    public func run(_ path: String, _ args: [String], timeout: TimeInterval) async -> (status: Int32, out: String)? {
        guard let result = try? await Tool.run(path, args, maxOutput: 1 << 20, timeout: timeout) else { return nil }
        return (result.code, result.out)
    }

    public func isExecutable(_ path: String) -> Bool { FileManager.default.isExecutableFile(atPath: path) }

    public func fileInfo(_ path: String) -> (size: Int, mode: Int)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return ((a[.size] as? NSNumber)?.intValue ?? 0, (a[.posixPermissions] as? NSNumber)?.intValue ?? 0o777)
    }

    public func tail(_ path: String, bytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > UInt64(bytes) ? end - UInt64(bytes) : 0)
        return (try? handle.readToEnd()).map { String(decoding: $0, as: UTF8.self) }
    }

    public func keychain(_ account: String) -> SecretPresence { ConnectionSecrets.presence(account: account) }

    public func resolve(_ host: String) async -> [String]? {
        await Task.detached(priority: .utility) { () -> [String]? in
            var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return nil }
            defer { freeaddrinfo(list) }
            var found = Set<String>()
            var node: UnsafeMutablePointer<addrinfo>? = first
            while let n = node {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(n.pointee.ai_addr, n.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    found.insert(String(cString: buffer))
                }
                node = n.pointee.ai_next
            }
            return found.sorted()
        }.value
    }

    public func tcp(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        await exchange(host: host, port: port, timeout: timeout, send: nil)
    }

    public func minecraftStatus(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        await exchange(host: host, port: port, timeout: timeout, send: MinecraftPing.request(host: host, port: port))
    }

    public func httpStatus(_ url: URL, timeout: TimeInterval) async -> Int? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("LeafJuice-connection-check", forHTTPHeaderField: "User-Agent")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = timeout
        guard let (_, response) = try? await URLSession(configuration: config).data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }

    /// Connects, optionally sends a status request, and says whether a real answer came back in time.
    private func exchange(host: String, port: Int, timeout: TimeInterval, send: Data?) async -> Bool {
        guard let p = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        let queue = DispatchQueue(label: "leafjuice.connection-check")
        return await withCheckedContinuation { continuation in
            let once = Once(connection: connection, continuation: continuation)
            let finish: @Sendable (Bool) -> Void = { once.finish($0) }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let send else { finish(true); return }
                    connection.send(content: send, completion: .contentProcessed { _ in })
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { data, _, _, _ in
                        finish(MinecraftPing.looksLikeStatus(data ?? Data()))
                    }
                case .failed, .cancelled: finish(false)
                case .waiting: finish(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}

/// Answers a check exactly once, whichever of the connection or the time limit comes first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let connection: NWConnection
    private let continuation: CheckedContinuation<Bool, Never>
    init(connection: NWConnection, continuation: CheckedContinuation<Bool, Never>) { self.connection = connection; self.continuation = continuation }
    func finish(_ ok: Bool) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        lock.unlock()
        connection.cancel()
        continuation.resume(returning: ok)
    }
}

/// The game's server-list ping: a handshake asking for status, then a status request. Unchanged across versions.
public enum MinecraftPing {
    static func varInt(_ value: Int) -> [UInt8] {
        var v = UInt32(truncatingIfNeeded: value), out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F); v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    static func packet(_ body: [UInt8]) -> [UInt8] { varInt(body.count) + body }

    public static func request(host: String, port: Int) -> Data {
        let name = Array(host.utf8)
        var handshake: [UInt8] = [0x00] + varInt(-1) + varInt(name.count) + name
        handshake += [UInt8(port >> 8 & 0xFF), UInt8(port & 0xFF)] + varInt(1)
        return Data(packet(handshake) + packet([0x00]))
    }

    /// A status answer is a length, packet id 0, then a JSON string. The first bytes are enough to tell.
    public static func looksLikeStatus(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var i = 0
        func read() -> Int? {
            var result = 0, shift = 0
            while i < bytes.count, shift < 35 {
                let b = bytes[i]; i += 1
                result |= Int(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        guard let length = read(), length > 2, read() == 0, let _ = read(), i < bytes.count else { return false }
        return bytes[i] == UInt8(ascii: "{")
    }
}

/// Which sign-in address goes beside an invite code: the one in Connections, else the one WelcomeWagon reports.
public enum InviteAddress {
    public struct Choice: Equatable, Sendable { public var url: String?; public var note: String? }
    public static func choose(configured: String, welcomewagon: String?) -> Choice {
        let mine = configured.trimmingCharacters(in: .whitespaces)
        let theirs = (welcomewagon ?? "").trimmingCharacters(in: .whitespaces)
        if !mine.isEmpty {
            if !theirs.isEmpty, theirs != mine {
                return Choice(url: mine, note: "WelcomeWagon's own setting says \(theirs). Check which one is right before sending this.")
            }
            return Choice(url: mine, note: nil)
        }
        if !theirs.isEmpty { return Choice(url: theirs, note: "This is WelcomeWagon's own setting. Add the sign-in page in Connections to keep it with the server's other addresses.") }
        return Choice(url: nil, note: "No sign-in page is set, so only the code is shown. Add the address in Connections on the Overview page.")
    }
}

// MARK: - On a server

extension ServerController {
    public var savedConnections: ConnectionStore.Loaded { ConnectionStore.load(paths.meta) }

    public func saveConnections(_ settings: ConnectionSettings, replacingUnreadable: Bool) throws {
        try ConnectionStore.save(settings, meta: paths.meta, replacingUnreadable: replacingUnreadable)
    }

    /// What the connection checks compare against: the server's own address and port, and pack serving's port.
    public var connectionContext: ConnectionContext {
        let text = (try? String(contentsOf: paths.properties, encoding: .utf8)) ?? ""
        let ip = PropertiesDocument(text).value("server-ip") ?? ""
        let hosting = packHostSettings
        let running: Bool
        switch state {
        case .running, .external: running = true  // A server started outside LeafJuice is still running.
        default: running = false
        }
        return ConnectionContext(serverRunning: running, serverIP: ip, serverPort: serverPort,
                                 packHostPort: hosting.enabled ? hosting.port : nil)
    }
}
