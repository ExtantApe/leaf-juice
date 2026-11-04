import Foundation

/// Everything known about one world, merged from the folders on disk and Multiverse's `worlds.yml`.
public struct WorldEntry: Identifiable, Equatable, Sendable {
    public var id: String { name }
    /// What Multiverse calls it: a folder name, or a namespaced key such as `minecraft:resource` on Paper 26.1+.
    public var name: String
    public var relativePath: String?
    public var size: Int64 = 0
    /// The server's own world, or one of its built-in Nether and End folders. These can't be removed.
    public var isCore = false
    public var isMain = false
    public var multiverse: MultiverseWorld?

    /// The name to show: an alias if set, otherwise the folder, otherwise the key without its `minecraft:` prefix.
    public var title: String {
        if let alias = multiverse?.alias, !alias.isEmpty { return alias }
        if let path = relativePath, !path.contains("/") { return path }
        return name.hasPrefix("minecraft:") ? String(name.dropFirst(10)) : name
    }
    public var isManaged: Bool { multiverse != nil }
    public var folderMissing: Bool { relativePath == nil }
}

public struct MultiverseWorld: Equatable, Sendable {
    public var name: String
    public var alias = ""
    public var environment: String?
    public var gamemode: String?
    public var difficulty: String?
    public var autoLoad = true
    public var hidden = false
}

public enum WorldEnvironment: String, CaseIterable, Identifiable, Sendable {
    case normal, nether, theEnd = "the_end"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .normal: "Overworld"
        case .nether: "Nether"
        case .theEnd: "The End"
        }
    }
    /// A sensible guess from a world's name, for importing.
    public static func guess(from name: String) -> WorldEnvironment {
        let lower = name.lowercased()
        if lower.hasSuffix("the_end") || lower.hasSuffix("_end") { return .theEnd }
        if lower.hasSuffix("nether") { return .nether }
        return .normal
    }
}

public enum WorldType: String, CaseIterable, Identifiable, Sendable {
    case normal = "NORMAL", flat = "FLAT", largeBiomes = "LARGE_BIOMES", amplified = "AMPLIFIED"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .normal: "Default"
        case .flat: "Superflat"
        case .largeBiomes: "Large biomes"
        case .amplified: "Amplified"
        }
    }
}

public struct NewWorld: Equatable, Sendable {
    public var name = ""
    public var environment: WorldEnvironment = .normal
    public var type: WorldType = .normal
    public var seed = ""
    public var structures = true
    public init() {}
}

public enum Multiverse {
    public static let pluginKey = "multiverse-core"
    public static let source = PluginSource.modrinth(project: "multiverse-core", allowBeta: false)

    /// Official add-ons, offered once Core is installed.
    public static let addOns: [(title: String, detail: String, source: PluginSource)] = [
        ("Portals", "Portals between worlds.", .modrinth(project: "multiverse-portals", allowBeta: false)),
        ("Nether Portals", "Link each world to its own Nether and End.", .modrinth(project: "multiverse-netherportals", allowBeta: false)),
        ("Inventories", "Separate inventories per world.", .modrinth(project: "multiverse-inventories", allowBeta: false)),
    ]

    /// The console is line-based, so a stray newline or space in a name could run or change a command.
    public static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9_-]+(:[A-Za-z0-9_/.-]+)?$"#, options: .regularExpression) != nil
    }
    public static func isValidSeed(_ seed: String) -> Bool {
        seed.isEmpty || seed.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }

    // Syntax differs between major versions. Taken from Multiverse-Core's command classes.

    public static func createCommand(_ w: NewWorld, major: Int) -> String {
        var out = "mv create \(w.name) \(w.environment.rawValue)"
        if major >= 5 {
            if !w.seed.isEmpty { out += " --seed \(w.seed)" }
            if w.type != .normal { out += " --world-type \(w.type.rawValue)" }
            if !w.structures { out += " --no-structures" }
        } else {
            if !w.seed.isEmpty { out += " -s \(w.seed)" }
            if w.type != .normal { out += " -t \(w.type.rawValue)" }
            if !w.structures { out += " -a false" }
        }
        return out
    }

    public static func importCommand(_ name: String, environment: WorldEnvironment) -> String {
        "mv import \(name) \(environment.rawValue)"
    }
    public static func loadCommand(_ name: String) -> String { "mv load \(name)" }
    /// `--remove-players` is confirmed present from Multiverse 5.2 on, and absent from 4.x.
    public static func supportsRemovePlayers(_ version: LooseVersion?) -> Bool {
        guard let version else { return false }
        return version >= LooseVersion("5.2")!
    }
    public static func unloadCommand(_ name: String, removePlayers: Bool) -> String {
        "mv unload \(name)" + (removePlayers ? " --remove-players" : "")
    }
    public static func removeCommand(_ name: String, removePlayers: Bool) -> String {
        "mv remove \(name)" + (removePlayers ? " --remove-players" : "")
    }
    public static func deleteCommand(_ name: String, removePlayers: Bool) -> String {
        "mv delete \(name)" + (removePlayers ? " --remove-players" : "")
    }

    public enum Action: Sendable { case create, importWorld, load, unload, remove, clone, modify, delete }

    /// Replies that mean a command won't succeed.
    public static let failureTexts = ["is already loaded", "already exists", "not found", "isn't loaded", "is not loaded", "unknown or incomplete command", "failed to", "unable to"]

    /// Text that reports success. Versions 4 and 5 word these differently; see their message sources.
    public static func successText(_ action: Action, major: Int) -> String {
        if major >= 5 {
            switch action {
            case .create: return "' created!"
            case .importWorld: return "' imported!"
            case .load: return "' loaded!"
            case .unload: return "' unloaded!"
            case .remove: return "' removed!"
            case .clone: return "world cloned to"
            case .modify: return "successfully"
            case .delete: return "' deleted!"
            }
        }
        switch action {
        case .create, .importWorld: return "complete!"
        case .load: return "loaded"
        case .unload: return "unloaded"
        case .remove: return "removed from config"
        case .clone: return "world cloned!"
        case .modify: return "was set to"
        case .delete: return "was deleted!"
        }
    }
    public static func cloneCommand(_ name: String, to target: String) -> String { "mv clone \(name) \(target)" }

    public static func modifyCommand(_ name: String, property: String, value: String, major: Int) -> String {
        major >= 5 ? "mv modify \(name) set \(property) \(value)" : "mv modify set \(property) \(value) \(name)"
    }

    private static let confirmPattern = regex(#"/mv confirm(?: (\d+))?"#)

    /// Reads a confirm prompt: `Run /mv confirm 726 to continue. This will expire in 30 seconds.`
    /// Returns the command to send, one-time code included when the prompt has one.
    public static func confirmCommand(fromPrompt line: String) -> String? {
        guard let match = confirmPattern.firstMatch(in: line) else { return nil }
        if let r = Range(match.range(at: 1), in: line) { return "mv confirm \(line[r])" }
        return "mv confirm"
    }

    // MARK: worlds.yml

    /// Reads `worlds.yml`. Version 5 keys worlds at the top level; version 4 nests them under `worlds:`.
    /// Only the flat fields used here are read; nested sections are skipped.
    public static func parseWorlds(_ text: String) -> [MultiverseWorld] {
        let lines = text.components(separatedBy: .newlines).filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("#")
        }
        func indent(_ s: String) -> Int { s.prefix { $0 == " " }.count }
        let nested = lines.contains { $0.trimmingCharacters(in: .whitespaces) == "worlds:" && indent($0) == 0 }
        let worldIndent = nested ? 2 : 0
        var out: [MultiverseWorld] = []
        var current: MultiverseWorld?
        var fieldIndent: Int?

        func clean(_ value: String) -> String {
            var v = value.trimmingCharacters(in: .whitespaces)
            if v.count >= 2, let q = v.first, q == "'" || q == "\"", v.last == q { v = String(v.dropFirst().dropLast()) }
            return v
        }
        for line in lines {
            let level = indent(line)
            let body = line.trimmingCharacters(in: .whitespaces)
            if nested, level == 0 { continue }
            if level == worldIndent, body.hasSuffix(":") {
                if let current { out.append(current) }
                let key = clean(String(body.dropLast()))
                current = MultiverseWorld(name: key.replacingOccurrences(of: "[dot]", with: "."))
                fieldIndent = nil
                continue
            }
            guard current != nil, level > worldIndent, let colon = body.firstIndex(of: ":") else { continue }
            // Fields sit one level in. Anything deeper belongs to a nested section.
            if fieldIndent == nil { fieldIndent = level }
            guard level == fieldIndent else { continue }
            let value = clean(String(body[body.index(after: colon)...]))
            switch body[..<colon].lowercased() {
            case "alias": current?.alias = value
            case "environment": current?.environment = value
            case "gamemode": current?.gamemode = value
            case "difficulty": current?.difficulty = value
            case "auto-load", "autoload": current?.autoLoad = value.lowercased() != "false"
            case "hidden": current?.hidden = value.lowercased() == "true"
            default: break
            }
        }
        if let current { out.append(current) }
        return out
    }
}

public enum WorldScanner {
    /// Combines what's on disk with what Multiverse knows. Works whether or not Multiverse is installed.
    public static func scan(_ paths: ServerPaths) -> [WorldEntry] {
        let propsText = (try? String(contentsOf: paths.properties, encoding: .utf8)) ?? ""
        let level = PropertiesDocument(propsText).value("level-name").flatMap { $0.isEmpty ? nil : $0 } ?? "world"
        var entries: [String: WorldEntry] = [:]

        for folder in Backups.worldFolders(paths.root) {
            let isCompanion = folder == "\(level)_nether" || folder == "\(level)_the_end"
            entries[folder] = WorldEntry(
                name: folder, relativePath: folder, size: FileOps.directorySize(paths.root.appendingPathComponent(folder)),
                isCore: folder == level || isCompanion, isMain: folder == level)
        }

        // Paper 26.1+ keeps custom worlds at <level>/dimensions/<namespace>/<key>.
        let dimensions = paths.root.appendingPathComponent(level).appendingPathComponent("dimensions")
        let builtIn: Set<String> = ["minecraft:overworld", "minecraft:the_nether", "minecraft:the_end"]
        for namespace in FileOps.children(dimensions) where FileOps.isDirectory(namespace) {
            for world in FileOps.children(namespace) where FileOps.isDirectory(world) {
                let key = "\(namespace.lastPathComponent):\(world.lastPathComponent)"
                guard !builtIn.contains(key) else { continue }
                entries[key] = WorldEntry(
                    name: key, relativePath: "\(level)/dimensions/\(namespace.lastPathComponent)/\(world.lastPathComponent)",
                    size: FileOps.directorySize(world))
            }
        }

        // Multiverse 5.8 keys worlds as `minecraft:overworld` even before Minecraft 26, and older versions
        // use the folder name. Either way, tie each one to its real folder rather than listing it twice.
        let coreKeys = ["minecraft:overworld": level, "minecraft:the_nether": "\(level)_nether", "minecraft:the_end": "\(level)_the_end"]
        let file = paths.plugins.appendingPathComponent("Multiverse-Core/worlds.yml")
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            for known in Multiverse.parseWorlds(text) {
                let parts = known.name.split(separator: ":", maxSplits: 1).map(String.init)
                let bare = parts.count == 2 && parts[0] == "minecraft" ? parts[1] : nil
                let match = [known.name, coreKeys[known.name], bare].compactMap { $0 }.first { entries[$0] != nil }
                    ?? entries.keys.first { $0.hasSuffix(":\(known.name)") }
                var entry = match.flatMap { entries.removeValue(forKey: $0) } ?? WorldEntry(name: known.name)
                if entry.relativePath == nil {
                    // A folder without a level.dat yet (a world just created), or a built-in dimension on 26.x.
                    var options: [String] = []
                    if let bare { options.append(bare) }
                    if parts.count == 2 { options.append("\(level)/dimensions/\(parts[0])/\(parts[1])") }
                    else { options.append(known.name) }
                    if let found = options.first(where: { FileOps.isDirectory(paths.root.appendingPathComponent($0)) }) {
                        entry.relativePath = found
                        entry.size = FileOps.directorySize(paths.root.appendingPathComponent(found))
                    }
                }
                entry.name = known.name
                entry.multiverse = known
                if coreKeys[known.name] != nil { entry.isCore = true }
                if known.name == "minecraft:overworld" || match == level { entry.isMain = true; entry.isCore = true }
                entries[known.name] = entry
            }
        }
        if !entries.values.contains(where: \.isMain) {
            entries[level] = WorldEntry(name: level, isCore: true, isMain: true)
        }

        return entries.values.sorted {
            if $0.isMain != $1.isMain { return $0.isMain }
            if $0.isCore != $1.isCore { return $0.isCore }
            return $0.name.lowercased() < $1.name.lowercased()
        }
    }
}
