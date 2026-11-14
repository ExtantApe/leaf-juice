import Foundation
import Network
import Security

/// One recipe's address on one server. Kept apart from the recipe, because recipes get exported and shared.
public struct HostedRecipe: Codable, Equatable, Sendable {
    /// The long random part of the address. The game can't sign in, so this is all that keeps strangers from stumbling on it.
    public var token: String
    /// The build to send when server.properties doesn't decide, as with Packmule.
    public var published: String?
    /// A full address on another host, in place of serving it from here.
    public var elsewhere: String?
    public init(token: String, published: String? = nil, elsewhere: String? = nil) {
        self.token = token
        self.published = published
        self.elsewhere = elsewhere
    }
}

public struct PackHostSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var port = 8766
    /// Where players reach this Mac, such as https://packs.example.net. It should not be the sign-in page's hostname.
    public var address = ""
    public var recipes: [String: HostedRecipe] = [:]
    /// Serve packs only to whitelisted players the server shows joining. On unless turned off. See PackGate.
    public var joiningOnly = true
    public init() {}

    enum CodingKeys: String, CodingKey { case enabled, port, address, recipes, joiningOnly }
    /// Settings saved before a field existed keep everything else, and get that field's default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 8766
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        recipes = try c.decodeIfPresent([String: HostedRecipe].self, forKey: .recipes) ?? [:]
        joiningOnly = try c.decodeIfPresent(Bool.self, forKey: .joiningOnly) ?? true
    }
    public var portIsUsable: Bool { (1024...65535).contains(port) }
}

/// What the listener needs to answer one address. A copy, so it can be read away from the main thread.
public struct PackRoute: Equatable, Sendable {
    public var token: String
    public var recipe: String
    public var url: String?
    public var published: String?
    /// False when Packmule is on the server, because server.properties then says nothing about this pack.
    public var followsProperties: Bool
    public init(token: String, recipe: String, url: String?, published: String?, followsProperties: Bool) {
        self.token = token
        self.recipe = recipe
        self.url = url
        self.published = published
        self.followsProperties = followsProperties
    }
}

public struct PackURLCheck: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case matches
        case differs(actual: String)
        case status(Int)
        case failed(String)
    }
    public var outcome: Outcome
    public var size: Int64 = 0
    public var ok: Bool { outcome == .matches }

    public var summary: String {
        switch outcome {
        case .matches:
            let base = "It downloaded, \(Format.bytes(size)), and its SHA-1 matches."
            return size > ResourcePacks.clientLimit ? base + " At this size, players' games may not accept it." : base
        case let .differs(actual): return "It downloaded, but it's a different file. Its SHA-1 is \(actual)."
        case let .status(code): return "The address answered with error \(code)."
        case let .failed(reason): return "Couldn't download it. \(reason)"
        }
    }
}

public enum PackHosting {
    /// Plugins that send packs per world. With one present, server.properties isn't how packs reach players.
    /// Packmule was called ResourcePackButler before 0.2.0; servers still on 0.1.x keep the old name.
    public static let perWorldPlugins: [String: String] = ["packmule": "Packmule", "resourcepackbutler": "Packmule", "worldresourcepacks": "WorldResourcepacks"]
    public static let fileName = "pack.zip"
    static let tokenBytes = 32

    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: tokenBytes)
        guard SecRandomCopyBytes(kSecRandomDefault, tokenBytes, &bytes) == errSecSuccess else {
            // Without good randomness the address could be guessed, so there is no address.
            fatalError("The system's random number generator failed.")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func isSHA1(_ text: String) -> Bool { text.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil }

    /// A web address with nothing after the host, since the route's own path follows it. nil when it isn't one.
    public static func cleanAddress(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: trimmed), let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.query == nil, parts.fragment == nil, parts.user == nil, parts.password == nil,
              parts.path.isEmpty || parts.path == "/" else { return nil }
        var out = "\(scheme)://\(host.lowercased())"
        if let port = parts.port { out += ":\(port)" }
        return out
    }

    public static func isFullAddress(_ text: String) -> Bool {
        guard let parts = URLComponents(string: text), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), parts.host?.isEmpty == false else { return false }
        return true
    }

    public static func playerURL(address: String, token: String) -> String { "\(address)/\(token)/\(fileName)" }

    /// An address that only ever gives one build, so a hash copied into a plugin's config can't go stale.
    public static func buildURL(address: String, token: String, sha1: String) -> String { "\(address)/\(token)/\(sha1).zip" }

    /// True for an address only this Mac can reach, which no player could download from.
    public static func isOnlyThisMac(_ address: String) -> Bool {
        guard let host = URLComponents(string: address)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".localhost")
    }

    /// Follows server.properties when it points here, so a change staged for the next restart keeps the running
    /// server's file and hash together until that restart. Otherwise whatever was chosen.
    public static func servedSHA1(_ route: PackRoute, properties: String?) -> String? {
        if route.followsProperties, let url = route.url, let properties {
            let live = ResourcePacks.current(properties)
            let hash = live.sha1.lowercased()
            if live.url == url, isSHA1(hash) { return hash }
        }
        return route.published.flatMap { isSHA1($0) ? $0 : nil }
    }

    public enum Asked: Equatable, Sendable { case pack, hash, build(String) }

    /// Exact matches only: there's no listing, and every other path gets the same answer.
    public static func match(path: String, routes: [PackRoute]) -> (route: PackRoute, asked: Asked)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty else { return nil }
        let asked: Asked
        switch parts[2] {
        case fileName: asked = .pack
        case "\(fileName).sha1": asked = .hash
        default:
            let name = String(parts[2])
            guard name.hasSuffix(".zip"), isSHA1(String(name.dropLast(4))) else { return nil }
            asked = .build(String(name.dropLast(4)))
        }
        let given = Array(parts[1].utf8)
        var found: PackRoute?
        for route in routes {
            let token = Array(route.token.utf8)
            guard token.count == given.count else { continue }
            var difference: UInt8 = 0
            for index in token.indices { difference |= token[index] ^ given[index] }
            if difference == 0 { found = route }
        }
        return found.map { ($0, asked) }
    }

    public enum Parsed: Equatable, Sendable {
        case incomplete
        case bad
        case ok(method: String, path: String, headers: [String: String])
    }

    /// The first line, and headers by lowercase name for the joining check. Nothing here reads a cookie, a query or a body.
    public static func parse(_ data: Data, limit: Int = 8192) -> Parsed {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return data.count > limit ? .bad : .incomplete }
        guard end.lowerBound <= limit, let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .bad }
        let first = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let parts = first.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), parts[1].hasPrefix("/") else { return .bad }
        var headers: [String: String] = [:]
        for line in head.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .bad }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            // A header sent twice is ambiguous, so the first one stands and a second makes the whole request bad.
            guard !name.isEmpty, headers[name] == nil else { return .bad }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return .ok(method: String(parts[0]), path: String(parts[1]), headers: headers)
    }

    /// Downloads it the way a player's game would, with nothing remembered, and compares what arrives.
    public static func check(url text: String, expected: String, ticket: String? = nil, headers extra: [String: String] = [:]) async -> PackURLCheck {
        guard isFullAddress(text), let url = URL(string: text) else { return PackURLCheck(outcome: .failed("That isn't a full web address.")) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        var headers = extra
        if let ticket { headers[PackGate.checkHeader] = ticket }
        configuration.httpAdditionalHeaders = headers
        // With a pass, no redirect is followed, so the pass can't be carried to another host.
        let session = URLSession(configuration: configuration, delegate: ticket == nil ? nil : NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (file, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: file) }
            guard let http = response as? HTTPURLResponse else { return PackURLCheck(outcome: .failed("The answer wasn't from a web server.")) }
            guard http.statusCode == 200 else { return PackURLCheck(outcome: .status(http.statusCode)) }
            let actual = try Hashing.digests(of: file).sha1.lowercased()
            let size = FileOps.size(file)
            return PackURLCheck(outcome: actual == expected.lowercased() ? .matches : .differs(actual: actual), size: size)
        } catch {
            return PackURLCheck(outcome: .failed(error.localizedDescription))
        }
    }
}

/// A read-only web server for built packs, on this Mac only, with something like Caddy in front. It's separate from
/// anything with sign-ins. Files go out in pieces, so a large pack isn't held in memory, and nobody's address is kept.
public final class PackHost: @unchecked Sendable {
    public static let maxConnections = 32
    static let chunkSize = 256 * 1024
    static let stallSeconds = 60.0

    private final class Exchange: @unchecked Sendable {
        var answered = false
        var progress = 0
    }

    private let queue = DispatchQueue(label: "leafjuice.packs")
    private let properties: URL
    private let allowed: @MainActor @Sendable () -> Bool
    /// Asked on this host's own queue, before anything about a pack is sent. False is a plain 404.
    private let admit: @Sendable ([String: String]) -> Bool
    public let tickets = PackCheckTickets()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var routes: [PackRoute]
    private let flag = NSLock()
    private var listening = false
    public var onFailure: (@MainActor @Sendable (String) -> Void)?

    public init(routes: [PackRoute], properties: URL, allowed: @escaping @MainActor @Sendable () -> Bool = { true },
                admit: @escaping @Sendable ([String: String]) -> Bool = { _ in true }) {
        self.routes = routes
        self.properties = properties
        self.allowed = allowed
        self.admit = admit
    }

    public var isListening: Bool {
        flag.lock(); defer { flag.unlock() }
        return listening
    }

    private func setListening(_ value: Bool) {
        flag.lock(); defer { flag.unlock() }
        listening = value
    }

    public func update(routes new: [PackRoute]) { queue.async { self.routes = new } }

    public func start(port: Int) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw LeafError("\(port) isn't a usable port.") }
        try listen(on: endpointPort, port: port, triesLeft: 10)
    }

    /// A host that was just stopped closes its socket a moment later, so a restart on the same port can find it
    /// still taken. Observed in tests: tries again every 0.2 s, for up to 2 s, before reporting the port as unusable.
    private func listen(on endpointPort: NWEndpoint.Port, port: Int, triesLeft: Int) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        let created = try NWListener(using: parameters)
        created.stateUpdateHandler = { [weak self, weak created] state in
            guard let self else { return }
            switch state {
            case .ready: self.setListening(true)
            case let .failed(error) where error == .posix(.EADDRINUSE) && triesLeft > 0:
                created?.cancel()
                self.queue.asyncAfter(deadline: .now() + 0.2) {
                    // stop() clears the listener, and then there's nothing to retry.
                    guard let created, self.listener === created else { return }
                    do { try self.listen(on: endpointPort, port: port, triesLeft: triesLeft - 1) } catch { self.stop() }
                }
            case let .failed(error):
                self.stop()
                let message = "Port \(port) couldn't be used: \(error.localizedDescription)"
                if let report = self.onFailure { Task { @MainActor in report(message) } }
            default: break
            }
        }
        created.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener = created
        created.start(queue: queue)
    }

    /// Stops listening and ends downloads in progress.
    public func stop() {
        setListening(false)
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections.values { connection.cancel() }
            self.connections = [:]
        }
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil, connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: self?.connections[key] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        let exchange = Exchange()
        // A connection that never asks for anything doesn't get to hold a place.
        queue.asyncAfter(deadline: .now() + 10) { if !exchange.answered { connection.cancel() } }
        read(connection, Data(), exchange)
    }

    private func read(_ connection: NWConnection, _ soFar: Data, _ exchange: Exchange) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, finished, error in
            guard let self, error == nil else { connection.cancel(); return }
            let all = soFar + (data ?? Data())
            switch PackHosting.parse(all) {
            case .incomplete:
                if finished { connection.cancel() } else { self.read(connection, all, exchange) }
            case .bad:
                exchange.answered = true
                self.finish(status: 400, reason: "Bad Request", head: false, connection)
            case let .ok(method, path, headers):
                exchange.answered = true
                let check = self.allowed
                Task { @MainActor in
                    let on = check()
                    self.queue.async {
                        guard on else { self.stop(); return }
                        self.answer(method: method, path: path, headers: headers, connection, exchange)
                    }
                }
            }
        }
    }

    private func answer(method: String, path: String, headers: [String: String], _ connection: NWConnection, _ exchange: Exchange) {
        guard method == "GET" || method == "HEAD" else {
            finish(status: 405, reason: "Method Not Allowed", head: false, connection, extra: "Allow: GET, HEAD\r\n")
            return
        }
        let head = method == "HEAD"
        // First, so a refused request learns nothing, not even whether an address exists.
        guard tickets.redeem(headers[PackGate.checkHeader]) || admit(headers) else {
            finish(status: 404, reason: "Not Found", head: head, connection)
            return
        }
        let text = try? String(contentsOf: properties, encoding: .utf8)
        guard let (route, asked) = PackHosting.match(path: path, routes: routes) else {
            finish(status: 404, reason: "Not Found", head: head, connection)
            return
        }
        let chosen: String?
        if case let .build(fixed) = asked { chosen = fixed } else { chosen = PackHosting.servedSHA1(route, properties: text) }
        guard let sha1 = chosen else {
            finish(status: 404, reason: "Not Found", head: head, connection)
            return
        }
        switch asked {
        case .hash:
            let body = Data("\(sha1)\n".utf8)
            connection.send(content: Self.header(length: Int64(body.count), type: "text/plain; charset=utf-8") + (head ? Data() : body), completion: .contentProcessed { _ in connection.cancel() })
        case .pack, .build:
            let url = ResourcePacks.buildFile(sha1: sha1, recipe: route.recipe)
            guard let file = try? FileHandle(forReadingFrom: url), let size = try? file.seekToEnd(), (try? file.seek(toOffset: 0)) != nil else {
                finish(status: 404, reason: "Not Found", head: head, connection)
                return
            }
            let type = "application/zip\r\nETag: \"\(sha1)\"\r\nContent-Disposition: attachment; filename=\"\(PackHosting.fileName)\""
            let start = Self.header(length: Int64(size), type: type)
            if head {
                connection.send(content: start, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            connection.send(content: start, completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else { connection.cancel(); return }
                self.pump(file, connection, exchange)
            })
        }
    }

    /// The next piece goes when the last has left, so a slow download costs a slow download's worth of memory.
    private func pump(_ file: FileHandle, _ connection: NWConnection, _ exchange: Exchange) {
        guard let chunk = try? file.read(upToCount: Self.chunkSize), !chunk.isEmpty else {
            connection.cancel()
            return
        }
        exchange.progress += 1
        let mark = exchange.progress
        queue.asyncAfter(deadline: .now() + Self.stallSeconds) { if exchange.progress == mark { connection.cancel() } }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            self.pump(file, connection, exchange)
        })
    }

    private static func header(length: Int64, type: String) -> Data {
        Data("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: \(length)\r\nContent-Type: \(type)\r\nCache-Control: no-cache\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n\r\n".utf8)
    }

    private func finish(status: Int, reason: String, head: Bool, _ connection: NWConnection, extra: String = "") {
        let text = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: 0\r\nX-Content-Type-Options: nosniff\r\n\(extra)\r\n"
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

extension ServerController {
    private var savedHosting: URL { paths.meta.appendingPathComponent("pack-hosting.json") }

    public var packHostSettings: PackHostSettings {
        get { JSONStore.load(savedHosting, defaults: PackHostSettings()) }
        set {
            try? JSONStore.save(newValue, to: savedHosting)
            syncPackRoutes()
        }
    }

    /// Counted even if switched off, because if that can't be told apart this stays out of its way.
    public var perWorldPackPlugin: String? { plugins.lazy.compactMap { PackHosting.perWorldPlugins[$0.key] }.first }
    public var hasPerWorldPacks: Bool { perWorldPackPlugin != nil }

    /// The address for one build, which never changes what it gives. nil when this recipe is hosted elsewhere.
    public func packBuildAddress(recipe name: String, sha1: String) -> String? {
        let settings = packHostSettings
        let hosted = settings.recipes[ResourcePacks.slug(name)] ?? hostedRecipe(name)
        guard hosted.elsewhere == nil, !settings.address.isEmpty else { return nil }
        return PackHosting.buildURL(address: settings.address, token: hosted.token, sha1: sha1)
    }

    public var packHostIsListening: Bool { packHost?.isListening == true }

    /// A one-time pass for this app's own check of a pack address. Nil when nothing is being served from here.
    public func packCheckTicket() -> String? { packHost?.isListening == true ? packHost?.tickets.issue() : nil }

    /// A pass only for this server's own pack address: anywhere else would receive a key to skip the joining check
    /// (K158 audit). Compares scheme, host and port.
    public func packCheckTicket(for address: String) -> String? {
        guard let own = URL(string: packHostSettings.address), let asked = URL(string: address),
              own.scheme?.lowercased() == asked.scheme?.lowercased(), own.host?.lowercased() == asked.host?.lowercased(),
              own.port == asked.port else { return nil }
        return packCheckTicket()
    }

    /// Turns the joining check on or off. Serving restarts so the change applies to the next request.
    public func setPackJoiningOnly(_ on: Bool) throws {
        var settings = packHostSettings
        settings.joiningOnly = on
        packHostSettings = settings
        if packHost != nil { try startPackHost() }
    }

    /// Gives the recipe its random path the first time it's asked for.
    @discardableResult
    public func hostedRecipe(_ name: String) -> HostedRecipe {
        let key = ResourcePacks.slug(name)
        var settings = packHostSettings
        if let existing = settings.recipes[key] { return existing }
        let fresh = HostedRecipe(token: PackHosting.newToken())
        settings.recipes[key] = fresh
        packHostSettings = settings
        return fresh
    }

    /// The address to give players, or nil until there's somewhere to serve it from.
    public func packAddress(recipe name: String) -> String? {
        let settings = packHostSettings
        let hosted = settings.recipes[ResourcePacks.slug(name)] ?? hostedRecipe(name)
        if let elsewhere = hosted.elsewhere { return elsewhere }
        return settings.address.isEmpty ? nil : PackHosting.playerURL(address: settings.address, token: hosted.token)
    }

    func isBuildAddress(_ address: String, recipe name: String) -> Bool {
        guard let hosted = packHostSettings.recipes[ResourcePacks.slug(name)], hosted.elsewhere == nil else { return false }
        return address.contains("/\(hosted.token)/")
    }

    public func isServedFromHere(address: String, recipe name: String) -> Bool {
        let settings = packHostSettings
        guard let hosted = settings.recipes[ResourcePacks.slug(name)], hosted.elsewhere == nil, !settings.address.isEmpty else { return false }
        return address == PackHosting.playerURL(address: settings.address, token: hosted.token)
    }

    /// The build this address sends right now. nil means it answers "not found".
    public func servedPackSHA1(recipe name: String) -> String? {
        guard let route = route(for: name, settings: packHostSettings) else { return nil }
        return PackHosting.servedSHA1(route, properties: try? String(contentsOf: paths.properties, encoding: .utf8))
    }

    /// Chooses what the recipe's address sends, or nothing. It switches as soon as this returns, so anything still
    /// holding the old hash fails to load the pack until it's given the new one.
    public func serveBuild(sha1: String?, recipe name: String) throws {
        if let sha1 {
            guard PackHosting.isSHA1(sha1), FileOps.exists(ResourcePacks.buildFile(sha1: sha1, recipe: name)) else { throw LeafError("That build isn't in the library any more.") }
        }
        hostedRecipe(name)
        var settings = packHostSettings
        settings.recipes[ResourcePacks.slug(name)]?.published = sha1
        packHostSettings = settings
    }

    /// Anyone holding the old address loses it, including this server if it's set there.
    public func newPackPath(recipe name: String) {
        hostedRecipe(name)
        var settings = packHostSettings
        settings.recipes[ResourcePacks.slug(name)]?.token = PackHosting.newToken()
        packHostSettings = settings
    }

    public func setPackElsewhere(_ address: String?, recipe name: String) throws {
        let trimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, !PackHosting.isFullAddress(trimmed) { throw LeafError("That needs to be a full web address, starting with https://.") }
        hostedRecipe(name)
        var settings = packHostSettings
        settings.recipes[ResourcePacks.slug(name)]?.elsewhere = trimmed.isEmpty ? nil : trimmed
        packHostSettings = settings
    }

    public func setPackHost(address: String, port: Int) throws {
        guard let clean = PackHosting.cleanAddress(address) else { throw LeafError("Enter the address players reach, with nothing after the name, such as https://packs.example.net.") }
        var settings = packHostSettings
        settings.address = clean
        settings.port = port
        guard settings.portIsUsable else { throw LeafError("The port has to be between 1024 and 65535.") }
        packHostSettings = settings
    }

    private func route(for name: String, settings: PackHostSettings) -> PackRoute? {
        let key = ResourcePacks.slug(name)
        guard let hosted = settings.recipes[key], hosted.elsewhere == nil else { return nil }
        let url = settings.address.isEmpty ? nil : PackHosting.playerURL(address: settings.address, token: hosted.token)
        return PackRoute(token: hosted.token, recipe: key, url: url, published: hosted.published, followsProperties: !hasPerWorldPacks)
    }

    func syncPackRoutes() {
        guard let packHost else { return }
        let settings = packHostSettings
        packHost.update(routes: settings.recipes.keys.sorted().compactMap { route(for: $0, settings: settings) })
    }

    public func startPackHost() throws {
        stopPackHost(remember: false)
        guard Modules.shared.isOn(.resourcePacks) else { throw LeafError("Resource packs is switched off in Settings.") }
        var settings = packHostSettings
        guard !settings.address.isEmpty else { throw LeafError("Enter the address players reach first.") }
        guard settings.portIsUsable else { throw LeafError("The port has to be between 1024 and 65535.") }
        let root = paths.root
        let gated = settings.joiningOnly
        let host = PackHost(routes: [], properties: paths.properties, allowed: { Modules.shared.isOn(.resourcePacks) },
                            admit: { headers in !gated || PackGate.admits(headers: headers, root: root) })
        host.onFailure = { [weak self] message in
            self?.packHostError = message
            self?.packHost = nil
        }
        try host.start(port: settings.port)
        packHost = host
        packHostError = nil
        syncPackRoutes()
        if !settings.enabled {
            settings.enabled = true
            packHostSettings = settings
        }
    }

    public func stopPackHost(remember: Bool = true) {
        packHost?.stop()
        packHost = nil
        if remember {
            var settings = packHostSettings
            if settings.enabled {
                settings.enabled = false
                packHostSettings = settings
            }
        }
    }

    /// A required pack with nothing answering at its address would turn players away, so this comes back by itself.
    public func startPackHostIfWanted() {
        guard !isTrialCopy, packHost == nil, packHostSettings.enabled, Modules.shared.isOn(.resourcePacks) else { return }
        do { try startPackHost() } catch { packHostError = error.localizedDescription }
    }

    /// Writes the pack into server.properties. With a per-world pack plugin this refuses, because the packs are its to send.
    public func usePack(url: String, sha1: String, required: Bool, recipe: String) async throws -> SaveOutcome {
        await refreshPlugins()
        if let plugin = perWorldPackPlugin { throw LeafError("\(plugin) is on this server, so LeafJuice leaves its pack settings alone. Give \(plugin) the build's address and SHA-1 instead.") }
        if isServedFromHere(address: url, recipe: recipe) || isBuildAddress(url, recipe: recipe), !packHostIsListening {
            throw LeafError("That address is served by this app, and serving is off. Start it first, or players couldn't download the pack.")
        }
        guard let file = configs.first(where: { $0.path == "server.properties" }) else { throw LeafError("This server has no server.properties yet. Start it once first.") }
        return try saveConfig(file, text: try ResourcePacks.applying(url: url, sha1: sha1, required: required, to: configText(file)))
    }
}

/// Refuses every redirect, for downloads that carry a one-time pass.
final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
