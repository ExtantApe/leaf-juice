import Foundation

/// Minecraft's own management server (JSON-RPC over a WebSocket, 1.21.9 and later), as a steadier source than the
/// console's text for who's online and whether the server is up (K160). LeafJuice only ever talks to it on this Mac.
public struct ManagementEndpoint: Equatable, Sendable {
    public let port: Int
    public let secret: String

    /// What `server.properties` says, if it's usable here: on, on a loopback address, a real port, plain WebSocket
    /// (it never leaves this Mac), and a secret. Anything else is nil, so LeafJuice falls back to reading the console.
    public static func from(properties text: String) -> ManagementEndpoint? {
        let doc = PropertiesDocument(text)
        guard doc.value("management-server-enabled") == "true",
              let host = doc.value("management-server-host"), ["127.0.0.1", "localhost", "::1"].contains(host),
              let port = doc.value("management-server-port").flatMap(Int.init), (1024...65535).contains(port),
              doc.value("management-server-tls-enabled") == "false",
              let secret = doc.value("management-server-secret"), secret.count >= 32 else { return nil }
        return ManagementEndpoint(port: port, secret: secret)
    }

    /// The same properties with the management server on, for this Mac only. The server makes the secret itself at
    /// its next start, if there isn't one.
    public static func enabling(_ text: String, port: Int) -> String {
        var doc = PropertiesDocument(text)
        doc.set("management-server-enabled", "true")
        doc.set("management-server-host", "127.0.0.1")
        doc.set("management-server-port", String(port))
        doc.set("management-server-tls-enabled", "false")
        return doc.text
    }
}

/// Answers from the management server, parsed. Kept apart from the connection so they can be checked offline.
public enum ManagementText {
    public struct Player: Equatable, Sendable { public let uuid: String; public let name: String }

    /// `minecraft:players`' result: `[{"id": uuid, "name": name}, ...]`.
    public static func players(_ result: Any?) -> [Player]? {
        guard let list = result as? [[String: Any]] else { return nil }
        return list.compactMap { p in
            guard let id = p["id"] as? String, let name = p["name"] as? String, AccountLookup.isValidName(name) else { return nil }
            return Player(uuid: id.lowercased(), name: name)
        }
    }

    public enum Event: Equatable, Sendable { case joined(Player), left(Player) }

    /// A notification, such as `minecraft:notification/players/joined` with the player as its parameter.
    public static func event(_ message: [String: Any]) -> Event? {
        guard message["id"] == nil, let method = message["method"] as? String else { return nil }
        let param = (message["params"] as? [Any])?.first ?? message["params"]
        guard let p = param as? [String: Any], let id = p["id"] as? String, let name = p["name"] as? String,
              AccountLookup.isValidName(name) else { return nil }
        let player = Player(uuid: id.lowercased(), name: name)
        switch method {
        case "minecraft:notification/players/joined": return .joined(player)
        case "minecraft:notification/players/left": return .left(player)
        default: return nil
        }
    }
}

/// One WebSocket to one server's management endpoint on 127.0.0.1. Calls are matched by id and time out;
/// notifications go to `onEvent`. Any failure just closes it, and LeafJuice goes back to the console's text.
public final class ManagementLink: NSObject, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<Any?, Never>] = [:]
    private var closedFlag = false
    public var onEvent: (@Sendable (ManagementText.Event) -> Void)?
    public var onClose: (@Sendable () -> Void)?

    public init(_ endpoint: ManagementEndpoint) {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(endpoint.port)/")!)
        request.setValue("Bearer \(endpoint.secret)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        task = URLSession(configuration: .ephemeral).webSocketTask(with: request)
        task.maximumMessageSize = 4 << 20
        super.init()
    }

    public func open() { task.resume(); listen() }

    public var isClosed: Bool { lock.withLock { closedFlag } }

    public func close() {
        let pending: [CheckedContinuation<Any?, Never>] = lock.withLock {
            guard !closedFlag else { return [] }
            closedFlag = true
            defer { waiting = [:] }
            return Array(waiting.values)
        }
        task.cancel(with: .goingAway, reason: nil)
        for c in pending { c.resume(returning: nil) }
        onClose?()
    }

    private func listen() {
        task.receive { [weak self] result in
            guard let self else { return }
            guard case let .success(message) = result else { self.close(); return }
            if case let .string(text) = message, let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let id = json["id"] as? Int {
                    let c = self.lock.withLock { self.waiting.removeValue(forKey: id) }
                    c?.resume(returning: json["error"] == nil ? (json["result"] ?? NSNull()) : nil)
                } else if let event = ManagementText.event(json) {
                    self.onEvent?(event)
                }
            }
            if !self.isClosed { self.listen() }
        }
    }

    /// The result, or nil for an error, a timeout or a closed link.
    public func call(_ method: String, params: Any? = nil, timeout: Duration = .seconds(5)) async -> Any? {
        let id: Int? = lock.withLock { closedFlag ? nil : { defer { nextID += 1 }; return nextID }() }
        guard let id else { return nil }
        var body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { body["params"] = params }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return await withCheckedContinuation { (c: CheckedContinuation<Any?, Never>) in
            lock.withLock { waiting[id] = c }
            task.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
                if error != nil, let c = self?.lock.withLock({ self?.waiting.removeValue(forKey: id) }) { c.resume(returning: nil) }
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                if let c = self?.lock.withLock({ self?.waiting.removeValue(forKey: id) }) { c.resume(returning: nil) }
            }
        }
    }
}
