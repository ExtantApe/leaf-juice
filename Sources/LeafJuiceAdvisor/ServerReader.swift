import Darwin
import Foundation

/// Read-only views of one server, built only from values that pass a strict check.
/// Paths are fixed here and never come from a caller.
public final class ServerReader {
    public let root: URL
    public let sanitizer: Sanitizer
    /// With every symlink resolved once, so that nothing after it has to follow one.
    private let realRoot: String?

    /// Useful for advice, and identify nothing. Everything else stays private, secrets included.
    static let safeProperties: Set<String> = [
        "difficulty", "enable-command-block", "enable-query", "enable-rcon", "enforce-secure-profile", "enforce-whitelist",
        "entity-broadcast-range-percentage", "gamemode", "hardcore", "management-server-enabled", "max-chained-neighbor-updates",
        "max-players", "max-tick-time", "max-world-size", "network-compression-threshold", "online-mode", "pause-when-empty-seconds",
        "player-idle-timeout", "prevent-proxy-connections", "pvp", "rate-limit", "simulation-distance", "spawn-protection",
        "allow-flight", "sync-chunk-writes", "use-native-transport", "view-distance", "white-list",
    ]
    static let maxLogBytes = 2 << 20
    static let maxJSONBytes = 16 << 20
    static let maxPropertiesBytes = 1 << 20
    private static let noFollowAny: Int32 = 0x2000_0000 // O_NOFOLLOW_ANY: refuses a symlink at any point in the path.

    private static func check(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) == text.startIndex..<text.endIndex
    }

    public init(root: URL, sanitizer: Sanitizer) {
        self.root = root.standardizedFileURL
        self.sanitizer = sanitizer
        if let resolved = realpath(self.root.path, nil) {
            realRoot = String(cString: resolved)
            free(resolved)
        } else {
            realRoot = nil
        }
    }

    /// The name a person would know it by. Only ever stored in the key file.
    public var displayName: String {
        // Plain words only: this reaches a person's screen, framed as the server's name.
        let named = ((try? object(".leafjuice/server.json")) ?? nil)?["name"] as? String
        for candidate in [named, root.lastPathComponent] {
            if let candidate, Self.check(#"[A-Za-z0-9][A-Za-z0-9 _.'\-]{0,39}"#, candidate) { return candidate }
        }
        return "Unnamed server"
    }

    // MARK: Reading files

    /// Nil if it isn't there. Throws if it is but can't be trusted, so a missing safeguard can't pass for no data.
    private func read(_ relative: String, tailBytes: Int? = nil, maxBytes: Int = ServerReader.maxJSONBytes) throws -> Data? {
        guard let realRoot else { throw AdvisorError("That server's folder can't be read.") }
        // A moved server would otherwise look like a quiet one.
        var rootInfo = stat()
        guard stat(realRoot, &rootInfo) == 0 else { throw AdvisorError("That server's folder can't be read.") }
        let fd = open(realRoot + "/" + relative, O_RDONLY | O_NONBLOCK | Self.noFollowAny)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw AdvisorError("A server file isn't safe to read, so nothing was shared.")
        }
        defer { close(fd) }
        var info = stat()
        // A hard link would be a way out of the folder that no path check can see.
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw AdvisorError("A server file isn't safe to read, so nothing was shared.")
        }
        if let tailBytes {
            if info.st_size > tailBytes { lseek(fd, off_t(-tailBytes), SEEK_END) }
        } else if info.st_size > maxBytes {
            throw AdvisorError("A server file is too large to read, so nothing was shared.")
        }
        // Bounded too, in case the file grows while being read.
        return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: tailBytes ?? maxBytes) ?? Data()
    }

    /// Nil if absent. A damaged file is an error, because reporting "no issues" or "no players" from one would be false.
    private func parsed(_ relative: String) throws -> Any? {
        guard let data = try read(relative) else { return nil }
        guard let value = try? JSONSerialization.jsonObject(with: data) else {
            throw AdvisorError("A server file couldn't be understood, so nothing was shared.")
        }
        return value
    }

    private func object(_ relative: String) throws -> [String: Any]? {
        guard let value = try parsed(relative) else { return nil }
        guard let object = value as? [String: Any] else { throw AdvisorError("A server file couldn't be understood, so nothing was shared.") }
        return object
    }

    private func list(_ relative: String) throws -> [[String: Any]] {
        guard let value = try parsed(relative) else { return [] }
        guard let items = value as? [[String: Any]] else { throw AdvisorError("A server file couldn't be understood, so nothing was shared.") }
        return items
    }

    private func logLines() throws -> [String] {
        guard let data = try read("logs/latest.log", tailBytes: Self.maxLogBytes) else { return [] }
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        // The tail probably began partway through a line, which could split a name or secret.
        if data.count >= Self.maxLogBytes, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    /// Real files directly in `plugins`, without following anything.
    private func jarNames() throws -> [String] {
        guard let realRoot else { throw AdvisorError("That server's folder can't be read.") }
        let fd = open(realRoot + "/plugins", O_RDONLY | O_DIRECTORY | O_NONBLOCK | Self.noFollowAny)
        if fd < 0 {
            if errno == ENOENT { return [] }
            throw AdvisorError("The plugins folder isn't safe to read, so nothing was shared.")
        }
        guard let directory = fdopendir(fd) else { close(fd); return [] }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            guard entry.pointee.d_type == UInt8(DT_REG) else { continue }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name.hasSuffix(".jar"), Self.check(#"[A-Za-z][A-Za-z0-9_.+\-]{0,79}\.jar"#, name), name.filter({ $0 == "_" }).count <= 3 { names.append(name) }
        }
        return names.sorted()
    }

    /// Names known to the server itself, read each time as players get added. Only the server's own cache ties a name to a
    /// UUID: ban and op lists can hold a name that has since passed to someone else.
    private func learnPlayers() throws {
        for item in try list("usercache.json") {
            if let name = item["name"] as? String { sanitizer.learnPlayer(name: name, uuid: item["uuid"] as? String) }
        }
        for file in ["whitelist.json", "ops.json", "banned-players.json"] {
            for item in try list(file) {
                if let name = item["name"] as? String { sanitizer.learnPlayer(name: name) }
            }
        }
    }

    // MARK: What the tools return

    public func summary() throws -> [String: Any] {
        try learnPlayers()
        var out: [String: Any] = [:]
        if let software = try object(".leafjuice/server.json")?["software"] as? [String: Any] {
            if let flavor = software["flavor"] as? String, ["paper", "folia", "purpur", "vanilla", "custom"].contains(flavor) { out["software"] = flavor }
            if let version = software["mcVersion"] as? String, Self.check(#"[0-9]{1,2}(\.[0-9]{1,2}){1,2}(-(pre|rc)[0-9]{1,2})?|[0-9]{2}w[0-9]{2}[a-z]"#, version) { out["minecraftVersion"] = version }
            if let build = software["build"] as? Int { out["build"] = build }
            if let java = software["requiredJava"] as? Int { out["requiredJava"] = java }
        }
        var settings: [String: String] = [:]
        if let data = try read("server.properties", maxBytes: Self.maxPropertiesBytes) {
            // Lossy, so one odd byte in a welcome message can't hide every setting. Only allowlisted lines are used.
            let text = String(decoding: data, as: UTF8.self)
            for line in text.components(separatedBy: .newlines) where !line.hasPrefix("#") {
                guard let split = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<split]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: split)...]).trimmingCharacters(in: .whitespaces)
                guard Self.safeProperties.contains(key),
                      Self.check("true|false|-?[0-9]{1,10}|peaceful|easy|normal|hard|survival|creative|adventure|spectator", value) else { continue }
                settings[key] = value
            }
        }
        out["settings"] = settings
        // Already limited to a plain file name. A jar named after a player shows their token instead.
        out["pluginFiles"] = try jarNames().map { try sanitizer.cleanFileName($0) }
        return out
    }

    /// Facts only. A stored title or sample can be any line from the log, chat included, so neither is ever sent.
    public func openIssues(limit: Int) throws -> [[String: Any]] {
        let log = ProblemLog(sanitizer: sanitizer, installedJars: try jarNames())
        try learnPlayers()
        try sanitizer.prepareForCode()
        let all = try list(".leafjuice/issues.json")
        var characters = 0
        var out: [[String: Any]] = []
        for issue in all where issue["status"] as? String == "open" {
            var item: [String: Any] = [:]
            if let rule = issue["ruleID"] as? String, Self.check(#"[a-z0-9][a-z0-9.\-]{0,47}"#, rule), try sanitizer.codeText(rule) == rule { item["rule"] = rule } else { item["rule"] = "uncatalogued" }
            if let severity = issue["severity"] as? String, ["info", "warning", "error", "critical"].contains(severity) { item["severity"] = severity }
            if let category = issue["category"] as? String, Self.check("[A-Z][a-z]{1,15}( [A-Za-z][a-z]{1,10}){0,1}", category) { item["category"] = category }
            if let plugin = issue["plugin"] as? String, let trusted = try log.trustedPlugin(plugin) { item["plugin"] = trusted }
            for field in ["firstSeen", "lastSeen"] {
                if let seen = issue[field] as? String, Self.check(#"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]{8,16}Z"#, seen) { item[field] = seen }
            }
            if let count = issue["count"] as? Int { item["count"] = count }
            if let stack = issue["stack"] as? [String] {
                let trace = try stack.prefix(60).filter { $0.utf16.count <= ProblemLog.maxLine }.compactMap { try log.traceLine(Scrub.controls($0)) }
                if !trace.isEmpty {
                    item["stack"] = Array(trace.prefix(30))
                    characters += trace.prefix(30).reduce(0) { $0 + $1.count }
                }
            }
            out.append(item)
            // The same limit as the log, on what any one plugin can put in front of the AI.
            if out.count >= limit || characters > ProblemLog.maxReportCharacters { break }
        }
        return out
    }

    public func recentProblems(limit: Int) throws -> ProblemLog.Report {
        try learnPlayers()
        return try ProblemLog(sanitizer: sanitizer, installedJars: try jarNames()).report(lines: try logLines(), limit: limit)
    }

    /// Before cleaning what the AI wrote, so a name from this server is recognised there too.
    public func prepareForSuggestion() throws { try learnPlayers() }
}
