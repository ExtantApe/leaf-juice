import Foundation
import Network

// BlueMap's web map behind the plugin links page's sign-in, under /map/. A player sees a world's map only if they
// can enter that world, as Multiverse decides it. Anything that can't be read with confidence shows no maps.

public struct MapGatewaySettings: Codable, Equatable, Sendable {
    public var on = false
    public init() {}
}

/// Which maps one person may see, or why none.
public enum MapAccess: Equatable, Sendable {
    case maps(Set<String>)
    case problem(String)

    public var allowed: Set<String> {
        if case let .maps(ids) = self { return ids }
        return []
    }
}

public enum MapRoute: Equatable, Sendable {
    case redirect
    case settings
    case forward(String)
    case notFound
}

/// BlueMap's own settings for its web server, read from its config.
public struct BlueMapServer: Equatable, Sendable {
    public var port = 8100
    /// What it binds to. BlueMap's default is every network interface.
    public var ip = "0.0.0.0"
    public var webroot = "bluemap/web"
    public var onlyThisMac: Bool { ip == "127.0.0.1" || ip == "localhost" || ip == "::1" }
}

public enum MapGateway {
    public static let prefix = "/map"
    static let accessMinutes = 5.0

    /// Only paths the BlueMap web app is known to use, and only maps this person may see.
    public static func route(path: String, allowed: Set<String>) -> MapRoute {
        if path == prefix { return .redirect }
        guard path.hasPrefix(prefix + "/") else { return .notFound }
        let rest = String(path.dropFirst(prefix.count + 1))
        guard !rest.contains(".."), !rest.contains("//"),
              rest.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-/".contains($0)) }) else { return .notFound }
        if rest.isEmpty || rest == "index.html" { return .forward("/" + rest) }
        if rest == "settings.json" { return .settings }
        if rest.hasPrefix("assets/") || rest.hasPrefix("lang/") { return .forward("/" + rest) }
        if rest.hasPrefix("maps/") {
            let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count >= 3, !parts[2].isEmpty, allowed.contains(String(parts[1])) else { return .notFound }
            return .forward("/" + rest)
        }
        return .notFound
    }

    /// The web app's list of maps, cut down to this person's. nil if map data could be loaded from anywhere but
    /// through here, because then hiding a map from the list wouldn't hide it.
    public static func filterSettings(_ data: Data, allowed: Set<String>) -> Data? {
        guard var settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let maps = settings["maps"] as? [String] else { return nil }
        for key in ["mapDataRoot", "liveDataRoot"] {
            guard (settings[key] as? String ?? "maps") == "maps" else { return nil }
        }
        settings["maps"] = maps.filter { allowed.contains($0) }
        return try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// One setting from a HOCON file: the single uncommented `key: value` line. nil if missing or there's more than one.
    static func setting(_ key: String, in text: String) -> String? {
        let found = text.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key), let colon = trimmed.firstIndex(of: ":"), trimmed[..<colon].trimmingCharacters(in: .whitespaces) == key else { return nil }
            var value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let hash = value.firstIndex(of: "#"), !value.hasPrefix("\"") { value = value[..<hash].trimmingCharacters(in: .whitespaces) }
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            return value
        }
        return found.count == 1 ? found[0] : nil
    }

    public static func blueMapServer(webserverConf text: String?) -> BlueMapServer {
        var out = BlueMapServer()
        guard let text else { return out }
        if let port = setting("port", in: text).flatMap(Int.init) { out.port = port }
        if let ip = setting("ip", in: text) { out.ip = ip }
        if let root = setting("webroot", in: text) { out.webroot = root }
        return out
    }

    public static func isWorldName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-.".contains($0)) } && !name.hasPrefix(".")
    }

    /// Map id to the Bukkit world it shows, from BlueMap's one file per map. nil when there's no BlueMap config to read.
    /// A map whose world can't be worked out is left out, so it's never shown.
    ///
    /// Before Minecraft 26, `world:` is the world's own folder. From 26, Paper moves every world inside the level
    /// folder, so `world:` is the level and `dimension:` says which world: the three built-in dimensions are the
    /// level's main worlds, and `minecraft:<name>` is the world `<name>`. Which applies is read from the folders.
    public static func mapWorlds(in folder: URL, serverRoot: URL? = nil) -> [String: String]? {
        guard FileOps.exists(folder) else { return nil }
        var out: [String: String] = [:]
        for file in FileOps.children(folder) where file.pathExtension == "conf" {
            let id = file.deletingPathExtension().lastPathComponent
            guard isWorldName(id), let text = try? String(contentsOf: file, encoding: .utf8),
                  let world = setting("world", in: text), isWorldName(world) else { continue }
            let moved = serverRoot.map { FileOps.isDirectory($0.appendingPathComponent(world).appendingPathComponent("dimensions")) } ?? false
            guard moved else {
                out[id] = world
                continue
            }
            switch setting("dimension", in: text) ?? "minecraft:overworld" {
            case "minecraft:overworld": out[id] = world
            case "minecraft:the_nether": out[id] = "\(world)_nether"
            case "minecraft:the_end": out[id] = "\(world)_the_end"
            case let other where other.hasPrefix("minecraft:"):
                let name = String(other.dropFirst("minecraft:".count))
                if isWorldName(name) { out[id] = name }
            default: continue   // Another namespace: which world it is can't be told, so it isn't shown.
            }
        }
        return out
    }

    /// Multiverse's `enforce-access`. nil when it can't be told, which counts as no maps.
    public static func enforcesAccess(multiverseConfig text: String?) -> Bool? {
        guard let text else { return nil }
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") && $0.contains("enforce-access:") }
        guard lines.count == 1 else { return nil }
        switch lines[0].split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// Headers BlueMap's answer keeps. Cookies and caching rules are BlueMap's to forget: a page behind sign-in
    /// is never kept by a shared cache, and the browser asks again each time, so lost access takes effect.
    static func rewriteHead(_ head: String) -> String? {
        var lines = head.components(separatedBy: "\r\n")
        guard let status = lines.first, status.hasPrefix("HTTP/1.") else { return nil }
        lines.removeFirst()
        let dropped: Set<String> = ["set-cookie", "connection", "keep-alive", "cache-control", "expires", "access-control-allow-origin", "server"]
        var out = [status]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            if dropped.contains(line[..<colon].lowercased()) { continue }
            out.append(line)
        }
        out += ["Connection: close", "Cache-Control: private, no-cache", "X-Content-Type-Options: nosniff", "Referrer-Policy: same-origin",
                "X-Robots-Tag: noindex", "Content-Security-Policy: frame-ancestors 'none'"]
        return out.joined(separator: "\r\n") + "\r\n\r\n"
    }

    /// What goes to BlueMap: the path, and only the headers that help caching and compression.
    static func upstreamRequest(method: String, path: String, port: Int, headers: [String: String]) -> Data {
        var text = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n"
        for name in ["accept", "accept-encoding", "if-none-match", "if-modified-since"] {
            if let value = headers[name], value.count <= 512, value.allSatisfy({ $0.isASCII && $0 != "\r" && $0 != "\n" }) { text += "\(name): \(value)\r\n" }
        }
        return Data((text + "\r\n").utf8)
    }
}

extension ServerController {
    public var blueMapServer: BlueMapServer {
        MapGateway.blueMapServer(webserverConf: try? String(contentsOf: paths.plugins.appendingPathComponent("BlueMap/webserver.conf"), encoding: .utf8))
    }

    public var multiverseEnforcesAccess: Bool? {
        MapGateway.enforcesAccess(multiverseConfig: try? String(contentsOf: paths.plugins.appendingPathComponent("Multiverse-Core/config.yml"), encoding: .utf8))
    }

    /// Worked out at most every few minutes per person, because each world needs a question to LuckPerms.
    public func mapAccess(uuid: String) async -> MapAccess {
        let key = uuid.lowercased()
        if let cached = mapAccessCache[key], cached.date.timeIntervalSinceNow > -MapGateway.accessMinutes * 60 { return await cached.task.value }
        let task = Task { @MainActor [weak self] () -> MapAccess in
            guard let self else { return .problem("The server is gone.") }
            // One person's check at a time, so two checks can't read each other's answers (K158 audit).
            while self.mapCheckRunning { try? await Task.sleep(for: .milliseconds(50)) }
            self.mapCheckRunning = true
            defer { self.mapCheckRunning = false }
            return await self.workOutMapAccess(uuid: key)
        }
        mapAccessCache[key] = (Date(), task)
        let result = await task.value
        // A problem may be over in a moment, such as the server still starting, so it isn't kept.
        if case .problem = result { mapAccessCache[key] = nil }
        mapAccessNote = { if case let .problem(text) = result { return text } else { return nil } }()
        return result
    }

    public func forgetMapAccess() { mapAccessCache = [:] }

    private func workOutMapAccess(uuid: String) async -> MapAccess {
        guard state == .running else { return .problem("The server isn't running, so who can enter each world can't be asked.") }
        guard AccountLookup.dashed(uuid) != nil else { return .problem("That account's ID isn't valid.") }
        guard let worlds = MapGateway.mapWorlds(in: paths.plugins.appendingPathComponent("BlueMap/maps"), serverRoot: paths.root) else { return .problem("BlueMap's map settings can't be read.") }
        guard plugins.contains(where: { $0.enabled && $0.key == Multiverse.pluginKey }) else {
            return .problem("Multiverse isn't on this server, so who can enter each world can't be read.")
        }
        guard let enforced = multiverseEnforcesAccess else { return .problem("Multiverse's enforce-access setting can't be read.") }
        // Multiverse lets everyone into every world when it doesn't enforce access.
        guard enforced else { return .maps(Set(worlds.keys)) }
        guard hasLuckPerms else { return .problem("Reading who can enter each world needs LuckPerms.") }
        var open = Set<String>()
        for world in Set(worlds.values).sorted() {
            guard state == .running else { return .problem("The server stopped while checking.") }
            let lines = await ask("lp user \(uuid) permission check multiverse.access.\(world)") { $0.contains { $0.contains("Result:") } }
            // Only a plain yes counts. "undefined" and anything unreadable are a no.
            if LuckPermsText.checkResult(lines) == .yes { open.insert(world) }
        }
        return .maps(Set(worlds.filter { open.contains($0.value) }.keys))
    }
}

/// Passes one request to BlueMap and streams the answer back, re-checking access while it runs.
final class MapPipe: @unchecked Sendable {
    private let client: NWConnection
    private let upstream: NWConnection
    private let queue: DispatchQueue
    private var progress = 0
    private var ended = false
    private var headBuffer = Data()
    private var headDone = false
    let stillAllowed: @MainActor @Sendable () async -> Bool

    init(client: NWConnection, port: Int, queue: DispatchQueue, stillAllowed: @escaping @MainActor @Sendable () async -> Bool) {
        self.client = client
        self.queue = queue
        self.stillAllowed = stillAllowed
        upstream = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 8100, using: .tcp)
    }

    func run(request: Data, onFailure: @escaping @Sendable () -> Void) {
        upstream.stateUpdateHandler = { state in
            switch state {
            case .failed, .waiting:
                guard !self.headDone else { self.end(); return }
                self.headDone = true
                onFailure()
            default: break
            }
        }
        upstream.start(queue: queue)
        upstream.send(content: request, completion: .contentProcessed { error in
            guard error == nil else { self.end(); return }
            self.pull()
        })
        watch()
    }

    /// Long answers, such as live updates, are cut off once the person loses access.
    private func watch() {
        let mark = progress
        queue.asyncAfter(deadline: .now() + 60) {
            guard !self.ended else { return }
            if self.progress == mark { self.end(); return }
            let check = self.stillAllowed
            Task { @MainActor in
                let ok = await check()
                self.queue.async { if ok { self.watch() } else { self.end() } }
            }
        }
    }

    private func pull() {
        upstream.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, finished, error in
            guard !self.ended else { return }
            if let data, !data.isEmpty {
                self.progress += 1
                if self.headDone {
                    self.forward(data, last: finished || error != nil)
                } else {
                    self.headBuffer.append(data)
                    if let range = self.headBuffer.range(of: Data("\r\n\r\n".utf8)) {
                        self.headDone = true
                        guard let head = String(data: self.headBuffer[..<range.lowerBound], encoding: .utf8), let rewritten = MapGateway.rewriteHead(head) else { self.end(); return }
                        let rest = self.headBuffer[range.upperBound...]
                        self.forward(Data(rewritten.utf8) + rest, last: finished || error != nil)
                    } else if self.headBuffer.count > 16384 {
                        self.end()
                    } else if finished || error != nil {
                        self.end()
                    } else {
                        self.pull()
                    }
                }
            } else if finished || error != nil {
                self.end()
            } else {
                self.pull()
            }
        }
    }

    /// The next piece is read only once the last has gone, so a slow browser holds little.
    private func forward(_ data: Data, last: Bool) {
        client.send(content: data, completion: .contentProcessed { error in
            if error != nil || last { self.end() } else { self.pull() }
        })
    }

    func end() {
        guard !ended else { return }
        ended = true
        upstream.cancel()
        client.cancel()
    }
}
