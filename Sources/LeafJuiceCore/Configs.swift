import Foundation

// MARK: - server.properties

/// Line-preserving `.properties` document: comments, order and untouched values survive edits.
public struct PropertiesDocument: Equatable, Sendable {
    enum Line: Equatable, Sendable {
        case other(String)
        case pair(key: String, raw: String)
    }
    var lines: [Line]

    public init(_ text: String) {
        lines = text.components(separatedBy: .newlines).map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("!"),
                  let eq = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { return .other(line) }
            return .pair(key: String(line[..<eq]).trimmingCharacters(in: .whitespaces), raw: String(line[line.index(after: eq)...]))
        }
    }

    public var text: String {
        lines.map {
            switch $0 {
            case .other(let s): s
            case let .pair(key, raw): "\(key)=\(raw)"
            }
        }.joined(separator: "\n")
    }

    public var values: [String: String] {
        var out: [String: String] = [:]
        for case let .pair(key, raw) in lines { out[key] = Self.unescape(raw) }
        return out
    }

    public func value(_ key: String) -> String? { values[key] }

    public mutating func set(_ key: String, _ value: String) {
        let raw = Self.escape(value)
        if let i = lines.firstIndex(where: { if case .pair(key, _) = $0 { true } else { false } }) {
            if case .pair(_, let old) = lines[i], Self.unescape(old) == value { return }
            lines[i] = .pair(key: key, raw: raw)
        } else {
            let end = lines.last == .other("") ? lines.count - 1 : lines.count
            lines.insert(.pair(key: key, raw: raw), at: end)
        }
    }

    public mutating func remove(_ key: String) {
        lines.removeAll { if case .pair(key, _) = $0 { true } else { false } }
    }

    static func unescape(_ raw: String) -> String {
        var out = "", escaped = false
        var unicode: String?
        for ch in raw {
            if let collected = unicode {
                unicode = collected + String(ch)
                if unicode!.count == 4 {
                    if let code = UInt32(unicode!, radix: 16), let scalar = Unicode.Scalar(code) { out.append(Character(scalar)) }
                    unicode = nil
                }
            } else if escaped {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "u": unicode = ""
                default: out.append(ch)
                }
                escaped = false
            } else if ch == "\\" { escaped = true } else { out.append(ch) }
        }
        return out
    }

    static func escape(_ value: String) -> String {
        var out = ""
        for ch in value {
            switch ch {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "=", ":": out += "\\\(ch)"
            default: out.append(ch)
            }
        }
        return out
    }

    /// Applies what changed between `base` and `mine` on top of `theirs`.
    public static func merge(base: String, mine: String, theirs: String) -> String {
        let b = PropertiesDocument(base).values, m = PropertiesDocument(mine).values
        var out = PropertiesDocument(theirs)
        for (key, value) in m where b[key] != value { out.set(key, value) }
        for key in b.keys where m[key] == nil { out.remove(key) }
        return out.text
    }
}

public struct PropertySpec: Identifiable, Sendable {
    public enum Kind: Sendable {
        case bool
        case int(ClosedRange<Int>)
        case text
        case choice([String])
    }
    public var id: String { key }
    public let key: String
    public let title: String
    public let help: String
    public let kind: Kind
    public let group: String

    /// Sections for known settings. Anything else in the file lands in "Other settings".
    public static let groupOrder = ["Basics", "Players", "World", "Performance", "Network and security"]

    public static let known: [PropertySpec] = [
        .init(key: "motd", title: "Server message", help: "Shown in the multiplayer list. This is what players see as your server's name.", kind: .text, group: "Basics"),
        .init(key: "server-port", title: "Port", help: "Default is 25565. Each server on this Mac needs its own.", kind: .int(1...65535), group: "Basics"),
        .init(key: "max-players", title: "Max players", help: "Players allowed online at once.", kind: .int(1...100000), group: "Basics"),
        .init(key: "difficulty", title: "Difficulty", help: "", kind: .choice(["peaceful", "easy", "normal", "hard"]), group: "Basics"),
        .init(key: "gamemode", title: "Default game mode", help: "", kind: .choice(["survival", "creative", "adventure", "spectator"]), group: "Basics"),
        .init(key: "hardcore", title: "Hardcore", help: "Players are banned when they die.", kind: .bool, group: "Basics"),
        .init(key: "white-list", title: "Allowlist", help: "Only allowlisted players can join.", kind: .bool, group: "Players"),
        .init(key: "enforce-whitelist", title: "Enforce allowlist", help: "Removes players who aren't on the list when it's reloaded.", kind: .bool, group: "Players"),
        .init(key: "pvp", title: "Player combat", help: "", kind: .bool, group: "Players"),
        .init(key: "force-gamemode", title: "Force game mode", help: "Puts players in the default game mode every time they join.", kind: .bool, group: "Players"),
        .init(key: "player-idle-timeout", title: "Idle kick", help: "Minutes before idle players are kicked. 0 turns this off.", kind: .int(0...100000), group: "Players"),
        .init(key: "spawn-protection", title: "Spawn protection", help: "Radius around spawn that only operators can build in.", kind: .int(0...100000), group: "Players"),
        .init(key: "op-permission-level", title: "Operator level", help: "What operators can do, from 1 to 4. 4 is everything.", kind: .int(1...4), group: "Players"),
        .init(key: "level-name", title: "World folder", help: "Changing this starts or loads a different world.", kind: .text, group: "World"),
        .init(key: "level-seed", title: "World seed", help: "Only used when a new world is created.", kind: .text, group: "World"),
        .init(key: "level-type", title: "World type", help: "Only used when a new world is created.", kind: .text, group: "World"),
        .init(key: "generate-structures", title: "Generate structures", help: "Villages, strongholds and so on. Only affects new chunks.", kind: .bool, group: "World"),
        .init(key: "allow-nether", title: "Allow the Nether", help: "", kind: .bool, group: "World"),
        .init(key: "spawn-monsters", title: "Spawn monsters", help: "", kind: .bool, group: "World"),
        .init(key: "view-distance", title: "View distance", help: "Chunks sent to players. The biggest factor in memory and bandwidth.", kind: .int(2...32), group: "Performance"),
        .init(key: "simulation-distance", title: "Simulation distance", help: "Chunks that tick around players. The biggest factor in CPU use.", kind: .int(2...32), group: "Performance"),
        .init(key: "max-tick-time", title: "Watchdog time", help: "Milliseconds one tick can take before the server is treated as frozen and stopped. -1 turns this off.", kind: .int(-1...Int(Int32.max)), group: "Performance"),
        .init(key: "sync-chunk-writes", title: "Sync chunk writes", help: "Safer against power loss, and slower. Paper's default is usually right.", kind: .bool, group: "Performance"),
        .init(key: "network-compression-threshold", title: "Compression threshold", help: "Packets at or above this many bytes get compressed. -1 turns this off, which suits a proxy on the same machine.", kind: .int(-1...100000), group: "Performance"),
        .init(key: "online-mode", title: "Verify accounts", help: "Checks players against Minecraft's account servers. Only turn off behind a proxy that does this for you.", kind: .bool, group: "Network and security"),
        .init(key: "server-ip", title: "Listen address", help: "Leave blank to listen everywhere, which is almost always right.", kind: .text, group: "Network and security"),
        .init(key: "enforce-secure-profile", title: "Require signed chat", help: "", kind: .bool, group: "Network and security"),
        .init(key: "enable-rcon", title: "Remote console", help: "RCON is unencrypted. Leave it off unless you need it.", kind: .bool, group: "Network and security"),
        .init(key: "rcon.password", title: "Remote console password", help: "", kind: .text, group: "Network and security"),
        .init(key: "enable-query", title: "Server query", help: "Lets server lists fetch details.", kind: .bool, group: "Network and security"),
    ]
}

// MARK: - Catalog of editable files

public struct ConfigFile: Identifiable, Equatable, Sendable {
    public enum Format: Sendable { case properties, yaml, json, text }
    public enum Policy: Equatable, Sendable {
        /// Edits made while running wait for the next restart.
        case stagedWhileRunning
        /// The server rewrites this itself, so edits are only allowed while stopped.
        case lockedWhileRunning(hint: String)
    }
    public var id: String { path }
    public let path: String
    public let title: String
    public let summary: String
    public let group: String
    public let format: Format
    public let policy: Policy
    /// The name within its group, where the full title would repeat it.
    public var shortTitle: String?
    public var listTitle: String { shortTitle ?? title }
}

public enum ConfigCatalog {
    private static let known: [ConfigFile] = [
        .init(path: "server.properties", title: "Server properties", summary: "Port, player limit, distances, difficulty.", group: "Server", format: .properties, policy: .stagedWhileRunning),
        .init(path: "config/paper-global.yml", title: "Paper global", summary: "Server-wide Paper settings.", group: "Paper", format: .yaml, policy: .stagedWhileRunning),
        .init(path: "config/paper-world-defaults.yml", title: "Paper world defaults", summary: "Mob limits, despawn ranges, anti-xray and other per-world tuning.", group: "Paper", format: .yaml, policy: .stagedWhileRunning),
        .init(path: "paper.yml", title: "Paper (older servers)", summary: "Paper's single settings file, before 1.19.", group: "Paper", format: .yaml, policy: .stagedWhileRunning),
        .init(path: "purpur.yml", title: "Purpur", summary: "Purpur's gameplay options.", group: "Paper", format: .yaml, policy: .stagedWhileRunning),
        .init(path: "spigot.yml", title: "Spigot", summary: "Activation ranges, merge radius, restart script.", group: "Spigot and Bukkit", format: .yaml, policy: .stagedWhileRunning),
        .init(path: "bukkit.yml", title: "Bukkit", summary: "Spawn limits, chunk unloading, ticks per spawn.", group: "Spigot and Bukkit", format: .yaml, policy: .stagedWhileRunning),
        .init(path: "commands.yml", title: "Commands", summary: "Command aliases.", group: "Spigot and Bukkit", format: .yaml, policy: .stagedWhileRunning),
        .init(path: "help.yml", title: "Help", summary: "Contents of the /help command.", group: "Spigot and Bukkit", format: .yaml, policy: .stagedWhileRunning),
        .init(path: "permissions.yml", title: "Permissions", summary: "Default permission groups.", group: "Spigot and Bukkit", format: .yaml, policy: .stagedWhileRunning),
        .init(path: "ops.json", title: "Operators", summary: "Who has admin rights.", group: "Players", format: .json, policy: .lockedWhileRunning(hint: "Use /op and /deop in the console while the server runs.")),
        .init(path: "whitelist.json", title: "Allowlist", summary: "Who may join when the allowlist is on.", group: "Players", format: .json, policy: .lockedWhileRunning(hint: "Use /whitelist add and /whitelist remove in the console while the server runs.")),
        .init(path: "banned-players.json", title: "Banned players", summary: "", group: "Players", format: .json, policy: .lockedWhileRunning(hint: "Use /ban and /pardon in the console while the server runs.")),
        .init(path: "banned-ips.json", title: "Banned addresses", summary: "", group: "Players", format: .json, policy: .lockedWhileRunning(hint: "Use /ban-ip and /pardon-ip in the console while the server runs.")),
    ]

    public static let serverProperties = known[0]

    public static func format(for path: String) -> ConfigFile.Format {
        switch (path as NSString).pathExtension.lowercased() {
        case "yml", "yaml": .yaml
        case "json": .json
        case "properties": .properties
        default: .text
        }
    }

    /// The files that exist in this server: well-known ones first, then plugin configs.
    /// Folders plugins use for data rather than settings, or for dozens of translations.
    private static let notSettings: Set<String> = [
        "userdata", "users", "players", "playerdata", "data", "cache", "logs", "log", "libs", "libraries", "lib",
        "backup", "backups", "storage", "database", "databases", "translations", "lang", "languages", "locale", "locales", "temp", "tmp",
    ]

    /// A plugin's settings files, relative to its folder: main ones first, a few levels deep, within reason.
    static func settingsFiles(in folder: URL, limit: Int = 40) -> [String] {
        var found: [String] = []
        var queue: [(URL, String, Int)] = [(folder, "", 0)]
        while !queue.isEmpty, found.count < limit {
            let (dir, prefix, depth) = queue.removeFirst()
            for item in FileOps.children(dir).sorted(by: { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }) {
                let name = item.lastPathComponent
                if name.hasPrefix(".") { continue }
                if FileOps.isDirectory(item) {
                    if depth < 2, !notSettings.contains(name.lowercased()) { queue.append((item, prefix + name + "/", depth + 1)) }
                    continue
                }
                guard ["yml", "yaml", "json", "properties", "toml", "conf", "txt"].contains(item.pathExtension.lowercased()),
                      FileOps.size(item) < 2_000_000 else { continue }
                found.append(prefix + name)
            }
        }
        func rank(_ rel: String) -> Int {
            let lower = rel.lowercased()
            if lower == "config.yml" || lower == "settings.yml" || lower == "config.yaml" || lower == "config.toml" { return 0 }
            return rel.contains("/") ? 2 : 1
        }
        return Array(found.sorted { (rank($0), $0.lowercased()) < (rank($1), $1.lowercased()) }.prefix(limit))
    }

    public static func scan(_ paths: ServerPaths, plugins: [InstalledPlugin]? = nil) -> [ConfigFile] {
        var out = known.filter { FileOps.exists(paths.root.appendingPathComponent($0.path)) }
        let knownPaths = Set(out.map(\.path))
        // Per-world Paper configs live one level inside world folders; skip those to stay focused.
        for dir in FileOps.children(paths.root.appendingPathComponent("config")) where dir.pathExtension == "yml" {
            let rel = "config/\(dir.lastPathComponent)"
            if !knownPaths.contains(rel) {
                out.append(.init(path: rel, title: dir.lastPathComponent, summary: "", group: "Paper", format: .yaml, policy: .stagedWhileRunning))
            }
        }
        // Per-world Paper settings: beside each world before 26.x, in each dimension after.
        var perWorld: [String] = []
        for world in Backups.worldFolders(paths.root) {
            let top = "\(world)/paper-world.yml"
            if FileOps.exists(paths.root.appendingPathComponent(top)) { perWorld.append(top) }
            let dimensions = paths.root.appendingPathComponent(world).appendingPathComponent("dimensions")
            for namespace in FileOps.children(dimensions) {
                for dimension in FileOps.children(namespace) where FileOps.exists(dimension.appendingPathComponent("paper-world.yml")) {
                    perWorld.append("\(world)/dimensions/\(namespace.lastPathComponent)/\(dimension.lastPathComponent)/paper-world.yml")
                }
            }
        }
        for path in perWorld.sorted() {
            let parts = path.components(separatedBy: "/")
            out.append(.init(path: path, title: "Paper: \(parts[parts.count - 2])", summary: "Overrides Paper's world defaults for this world.", group: "Paper", format: .yaml, policy: .stagedWhileRunning))
        }
        // Each plugin's files, found from what's actually in its folder.
        var pluginConfigs: [ConfigFile] = []
        var leftovers: [ConfigFile] = []
        let byFolder = Dictionary((plugins ?? []).filter { $0.descriptor != nil }.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, b in a.enabled ? a : b })
        for folder in FileOps.children(paths.plugins).sorted(by: { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() })
        where FileOps.isDirectory(folder) && folder.lastPathComponent != "update" && !folder.lastPathComponent.hasPrefix(".") {
            let dirName = folder.lastPathComponent
            let plugin = byFolder[dirName.lowercased()]
            let group: String
            if plugins == nil || plugin != nil {
                group = plugin.map { $0.enabled ? $0.name : "\($0.name) (disabled)" } ?? dirName
            } else {
                group = "Leftover plugin folders"
            }
            for rel in settingsFiles(in: folder) {
                let file = folder.appendingPathComponent(rel)
                let format = ConfigCatalog.format(for: rel)
                // Multiverse rewrites its world list as worlds change, which would overwrite a staged edit.
                let isMultiverseWorlds = dirName == "Multiverse-Core" && rel == "worlds.yml"
                let entry = ConfigFile(
                    path: "plugins/\(dirName)/\(rel)", title: "\(dirName): \(rel)", summary: "",
                    group: group, format: format,
                    policy: isMultiverseWorlds ? .lockedWhileRunning(hint: "Use the Worlds page while the server runs.") : .stagedWhileRunning,
                    shortTitle: rel)
                if group == "Leftover plugin folders" { leftovers.append(entry) } else { pluginConfigs.append(entry) }
                _ = file
            }
            if pluginConfigs.count + leftovers.count > 1000 { break }
        }
        pluginConfigs += leftovers
        return out + pluginConfigs
    }
}

// MARK: - Validation

public struct ConfigProblem: Equatable, Sendable {
    public let line: Int?
    public let message: String
    public init(line: Int?, message: String) { self.line = line; self.message = message }
    public var description: String { line.map { "Line \($0): \(message)" } ?? message }
}

public enum ConfigValidator {
    /// Checks for mistakes that stop a server loading its config. YAML checks are basic on purpose:
    /// they catch the common errors without pulling in a YAML dependency.
    public static func problems(_ text: String, format: ConfigFile.Format) -> [ConfigProblem] {
        switch format {
        case .json:
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            do {
                _ = try JSONSerialization.jsonObject(with: Data(text.utf8))
                return []
            } catch {
                let detail = (error as NSError).userInfo["NSDebugDescription"] as? String ?? "Invalid JSON."
                return [ConfigProblem(line: nil, message: detail)]
            }
        case .yaml:
            return yaml(text)
        case .properties:
            var out: [ConfigProblem] = []
            for (i, line) in text.components(separatedBy: .newlines).enumerated() {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("!") { continue }
                if !t.contains("=") && !t.contains(":") { out.append(ConfigProblem(line: i + 1, message: "Expected key=value.")) }
            }
            return out
        case .text:
            return []
        }
    }

    private static func yaml(_ text: String) -> [ConfigProblem] {
        var out: [ConfigProblem] = []
        for (i, line) in text.components(separatedBy: .newlines).enumerated() {
            let n = i + 1
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            if indent.contains("\t") { out.append(ConfigProblem(line: n, message: "Tabs aren't allowed for indentation in YAML. Use spaces.")); continue }
            let body = line.dropFirst(indent.count)
            if body.isEmpty || body.hasPrefix("#") { continue }
            var single = false, double = false, previous: Character = " "
            for ch in body {
                if ch == "#", !single, !double, previous == " " { break }
                if ch == "'", !double { single.toggle() }
                if ch == "\"", !single, previous != "\\" { double.toggle() }
                previous = ch
            }
            // A scalar may legitimately begin with an apostrophe-free word and contain one, so only flag
            // quotes when the value itself starts quoted.
            let value = body.drop { $0 != ":" }.dropFirst().drop { $0 == " " }
            let opensQuoted = value.first == "\"" || value.first == "'" || body.first == "\"" || body.first == "'"
            if opensQuoted, single || double { out.append(ConfigProblem(line: n, message: "Unclosed quote.")) }
        }
        return out
    }
}

// MARK: - The EULA

public enum EULA {
    public static let url = URL(string: "https://aka.ms/MinecraftEULA")!

    public static func isAccepted(_ paths: ServerPaths) -> Bool {
        guard let text = try? String(contentsOf: paths.eula, encoding: .utf8) else { return false }
        return text.components(separatedBy: .newlines).contains {
            $0.trimmingCharacters(in: .whitespaces).lowercased() == "eula=true"
        }
    }

    /// Records the owner's own acceptance. Only called from an explicit choice in the interface.
    public static func accept(_ paths: ServerPaths) throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
        try FileOps.writeAtomic("# Accepted in Leaf Juice on \(stamp). \(url.absoluteString)\neula=true\n", to: paths.eula)
    }
}
