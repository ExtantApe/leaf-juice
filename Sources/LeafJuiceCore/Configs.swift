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
        for ch in raw {
            if escaped {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
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

    public static let common: [PropertySpec] = [
        .init(key: "motd", title: "Server message", help: "Shown in the multiplayer list.", kind: .text),
        .init(key: "server-port", title: "Port", help: "Default is 25565. Each server on this Mac needs its own.", kind: .int(1...65535)),
        .init(key: "max-players", title: "Max players", help: "Players allowed online at once.", kind: .int(1...1000)),
        .init(key: "view-distance", title: "View distance", help: "Chunks sent to players. The biggest factor in memory and bandwidth.", kind: .int(2...32)),
        .init(key: "simulation-distance", title: "Simulation distance", help: "Chunks that tick around players. The biggest factor in CPU use.", kind: .int(2...32)),
        .init(key: "difficulty", title: "Difficulty", help: "", kind: .choice(["peaceful", "easy", "normal", "hard"])),
        .init(key: "gamemode", title: "Default game mode", help: "", kind: .choice(["survival", "creative", "adventure", "spectator"])),
        .init(key: "pvp", title: "Player combat", help: "", kind: .bool),
        .init(key: "white-list", title: "Allowlist", help: "Only allowlisted players can join.", kind: .bool),
        .init(key: "online-mode", title: "Verify accounts", help: "Checks players against Minecraft's account servers. Only turn off behind a proxy that does this for you.", kind: .bool),
        .init(key: "level-name", title: "World folder", help: "Changing this starts or loads a different world.", kind: .text),
        .init(key: "level-seed", title: "World seed", help: "Only used when a new world is created.", kind: .text),
        .init(key: "spawn-protection", title: "Spawn protection", help: "Radius around spawn that only operators can build in.", kind: .int(0...1000)),
        .init(key: "enable-rcon", title: "Remote console", help: "RCON is unencrypted. Leave it off unless you need it.", kind: .bool),
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
    public static func scan(_ paths: ServerPaths) -> [ConfigFile] {
        var out = known.filter { FileOps.exists(paths.root.appendingPathComponent($0.path)) }
        let knownPaths = Set(out.map(\.path))
        // Per-world Paper configs live one level inside world folders; skip those to stay focused.
        for dir in FileOps.children(paths.root.appendingPathComponent("config")) where dir.pathExtension == "yml" {
            let rel = "config/\(dir.lastPathComponent)"
            if !knownPaths.contains(rel) {
                out.append(.init(path: rel, title: dir.lastPathComponent, summary: "", group: "Paper", format: .yaml, policy: .stagedWhileRunning))
            }
        }
        var pluginConfigs: [ConfigFile] = []
        for plugin in FileOps.children(paths.plugins).sorted(by: { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() })
        where FileOps.isDirectory(plugin) && plugin.lastPathComponent != "update" && !plugin.lastPathComponent.hasPrefix(".") {
            for file in FileOps.children(plugin).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let format: ConfigFile.Format
                switch file.pathExtension.lowercased() {
                case "yml", "yaml": format = .yaml
                case "json": format = .json
                case "properties": format = .properties
                case "toml", "conf", "txt": format = .text
                default: continue
                }
                guard FileOps.size(file) < 2_000_000 else { continue }
                // Multiverse rewrites its world list as worlds change, which would overwrite a staged edit.
                let isMultiverseWorlds = plugin.lastPathComponent == "Multiverse-Core" && file.lastPathComponent == "worlds.yml"
                pluginConfigs.append(.init(
                    path: "plugins/\(plugin.lastPathComponent)/\(file.lastPathComponent)",
                    title: "\(plugin.lastPathComponent): \(file.lastPathComponent)", summary: "",
                    group: "Plugins", format: format,
                    policy: isMultiverseWorlds ? .lockedWhileRunning(hint: "Use the Worlds page while the server runs.") : .stagedWhileRunning))
            }
            if pluginConfigs.count > 300 { break }
        }
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
