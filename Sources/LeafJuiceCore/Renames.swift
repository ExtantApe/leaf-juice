import Foundation

/// One change a rename would make, always shown before it happens.
public struct RenameItem: Identifiable, Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case moveFolder(from: String, to: String)
        case replaceFile(path: String, text: String)
        case levelName(path: String, to: String)
    }
    public var id: String { description + String(describing: action).prefix(120) }
    public let action: Action
    public let description: String
    /// Line-by-line, for the preview.
    public var changes: [String] = []
    /// Off by default: changing it has side effects, which `warning` explains.
    public var optional = false
    public var warning: String?
    public var selected = true

    /// Which file or folder this touches, which stays the same if the plan is worked out again.
    public var location: String {
        switch action {
        case let .moveFolder(from, _): from
        case let .replaceFile(path, _): path
        case let .levelName(path, _): path
        }
    }
}

public struct RenamePlan: Equatable, Sendable {
    public var title: String
    public var items: [RenameItem] = []
    /// Places that mention the name but aren't changed: shown so nothing is a surprise.
    public var mentions: [String] = []
    /// Things stored where a rename can't reach, such as a plugin's database.
    public var notes: [String] = []
}

// MARK: - Editing text precisely

public enum RenameText {
    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    private static func keyOf(_ line: String) -> (key: String, rest: String)? {
        let body = line.dropFirst(indent(line))
        if body.hasPrefix("#") || body.hasPrefix("- ") { return nil }
        var key = ""
        var rest = ""
        if let q = body.first, q == "'" || q == "\"" {
            guard let close = body.dropFirst().firstIndex(of: q) else { return nil }
            key = String(body[body.index(after: body.startIndex)..<close])
            let after = body[body.index(after: close)...]
            guard after.first == ":" else { return nil }
            rest = String(after.dropFirst())
        } else {
            // Keys may contain a colon (`minecraft:foo:`), so the key ends at the last `:` before a space or line end.
            guard let range = body.range(of: #":(\s|$)"#, options: .regularExpression) else { return nil }
            key = String(body[..<range.lowerBound])
            rest = String(body[body.index(after: range.lowerBound)...])
        }
        return (key, rest)
    }

    /// Renames a key directly under `section` (nil for the top level).
    public static func renameKey(_ text: String, section: String?, names: [String: String]) -> (String, [String]) {
        var lines = text.components(separatedBy: "\n")
        var changes: [String] = []
        var sectionIndent: Int? = section == nil ? -1 : nil
        var childIndent: Int?
        for i in lines.indices {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let level = indent(line)
            if let section, sectionIndent == nil {
                if level == 0, keyOf(line)?.key == section { sectionIndent = 0 }
                continue
            }
            if section != nil, let parent = sectionIndent, level <= parent { sectionIndent = nil; childIndent = nil; continue }
            if childIndent == nil { childIndent = level }
            guard level == childIndent, let parsed = keyOf(line), let new = names[parsed.key] else { continue }
            let body = line.dropFirst(level)
            let quote = body.first == "'" || body.first == "\"" ? String(body.first!) : ""
            lines[i] = String(repeating: " ", count: level) + quote + new + quote + ":" + parsed.rest
            changes.append("\(parsed.key) → \(new)")
        }
        return (lines.joined(separator: "\n"), changes)
    }

    /// Changes values of the named keys, and list items beneath them, only where the whole value matches.
    public static func replaceValues(_ text: String, keys: Set<String>, names: [String: String]) -> (String, [String]) {
        var lines = text.components(separatedBy: "\n")
        var changes: [String] = []
        var listOwner: (indent: Int, key: String)?
        func swap(_ raw: String) -> (String, String)? {
            let t = raw.trimmingCharacters(in: .whitespaces)
            var value = t, comment = ""
            if let q = t.first, q == "'" || q == "\"" {
                let rest = t.dropFirst()
                guard let close = rest.firstIndex(of: q) else { return nil }
                value = String(rest[..<close])
                comment = String(rest[rest.index(after: close)...])
                guard let new = names[value] else { return nil }
                return ("\(q)\(new)\(q)\(comment)", value)
            }
            if let hash = t.range(of: " #") { value = String(t[..<hash.lowerBound]); comment = String(t[hash.lowerBound...]) }
            guard let new = names[value] else { return nil }
            return ("\(new)\(comment)", value)
        }
        for i in lines.indices {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let level = indent(line)
            if trimmed.hasPrefix("- ") {
                if let owner = listOwner, level >= owner.indent, keys.contains(owner.key), let (new, old) = swap(String(trimmed.dropFirst(2))) {
                    lines[i] = String(repeating: " ", count: level) + "- " + new
                    changes.append("\(owner.key): \(old) → \(new)")
                }
                continue
            }
            guard let parsed = keyOf(line) else { listOwner = nil; continue }
            listOwner = (level, parsed.key)
            let rest = parsed.rest.trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty, keys.contains(parsed.key) else { continue }
            if rest.hasPrefix("[") {
                // Inline list.
                let inner = rest.dropFirst().prefix { $0 != "]" }
                let tail = rest.dropFirst(inner.count + 1)
                var changed = false
                let items = inner.split(separator: ",").map { item -> String in
                    let bare = item.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
                    if let new = names[bare] { changed = true; return item.replacingOccurrences(of: bare, with: new) }
                    return String(item)
                }
                if changed {
                    lines[i] = String(line.prefix(level)) + String(line.dropFirst(level).prefix { $0 != ":" }) + ": [" + items.joined(separator: ",") + tail
                    changes.append("\(parsed.key): list updated")
                }
            } else if let (new, old) = swap(rest), let colon = line.range(of: ":", options: .backwards, range: line.startIndex..<line.index(line.endIndex, offsetBy: -parsed.rest.count)) {
                lines[i] = String(line[..<colon.upperBound]) + " " + new
                changes.append("\(parsed.key): \(old) → \(new)")
            }
        }
        return (lines.joined(separator: "\n"), changes)
    }

    /// Multiverse's `w:old` and `e:old:x,y,z` destinations.
    public static func replaceDestinations(_ text: String, names: [String: String]) -> (String, [String]) {
        var out = text
        var changes: [String] = []
        for (old, new) in names {
            let escaped = NSRegularExpression.escapedPattern(for: old)
            let pattern = regex(#"(^|[\s'":=,])(w|e|ws|ca):"# + escaped + #"(?=$|[\s'":,])"#, .anchorsMatchLines)
            let range = NSRange(out.startIndex..., in: out)
            let count = pattern.numberOfMatches(in: out, range: range)
            if count > 0 {
                out = pattern.stringByReplacingMatches(in: out, range: range, withTemplate: "$1$2:\(NSRegularExpression.escapedTemplate(for: new))")
                changes.append("\(count) destination\(count == 1 ? "" : "s"): \(old) → \(new)")
            }
        }
        return (out, changes)
    }

    /// Whole-token match, for paths and names in start scripts.
    public static func replaceToken(_ text: String, old: String, new: String) -> (String, Int) {
        let pattern = regex(#"(?<![A-Za-z0-9_-])"# + NSRegularExpression.escapedPattern(for: old) + #"(?![A-Za-z0-9_-])"#)
        let range = NSRange(text.startIndex..., in: text)
        let count = pattern.numberOfMatches(in: text, range: range)
        return (pattern.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: new)), count)
    }

    /// Anchors are stored `world:x,y,z:pitch:yaw`.
    public static func replaceAnchors(_ text: String, names: [String: String]) -> (String, [String]) {
        var out = text
        var changes: [String] = []
        for (old, new) in names {
            let pattern = regex(#"(:\s+['"]?)"# + NSRegularExpression.escapedPattern(for: old) + #"(:-?\d)"#)
            let range = NSRange(out.startIndex..., in: out)
            let count = pattern.numberOfMatches(in: out, range: range)
            if count > 0 {
                out = pattern.stringByReplacingMatches(in: out, range: range, withTemplate: "$1\(NSRegularExpression.escapedTemplate(for: new))$2")
                changes.append("\(count) anchor\(count == 1 ? "" : "s"): \(old) → \(new)")
            }
        }
        return (out, changes)
    }
}

// MARK: - World renames

public enum WorldRename {
    /// Files known to hold world names, and how. Nothing outside this list is ever edited.
    enum Rule {
        case key(section: String?)
        case values(Set<String>)
        case destinations
        case anchors
    }
    static let knownFiles: [(glob: String, rules: [Rule], label: String)] = [
        ("bukkit.yml", [.key(section: "worlds")], "Bukkit world settings"),
        ("spigot.yml", [.key(section: "world-settings")], "Spigot world settings"),
        ("purpur.yml", [.key(section: "world-settings")], "Purpur world settings"),
        ("plugins/Multiverse-Core/worlds.yml", [.key(section: nil), .key(section: "worlds"), .values(["respawn-world", "respawnWorld", "legacy-world-name"])], "Multiverse world list"),
        ("plugins/Multiverse-Core/config.yml", [.values(["first-spawn-location", "firstspawnworld", "join-destination"]), .destinations], "Multiverse settings"),
        ("plugins/Multiverse-Core/anchors.yml", [.anchors], "Multiverse anchors"),
        ("plugins/Multiverse-Portals/portals.yml", [.values(["world"]), .destinations], "Multiverse portals"),
        ("plugins/Multiverse-NetherPortals/config.yml", [.key(section: "worlds"), .values(["world", "nether", "end"])], "Multiverse Nether links"),
        ("plugins/Multiverse-Inventories/groups.yml", [.values(["worlds"])], "Multiverse inventory groups"),
        ("plugins/Multiverse-Inventories/config.yml", [.values(["worlds"])], "Multiverse-Inventories settings"),
        ("plugins/Essentials/spawn.yml", [.values(["world", "world-name"])], "Essentials spawn"),
        ("plugins/Essentials/jail.yml", [.values(["world", "world-name"])], "Essentials jails"),
        ("plugins/Essentials/warps/*.yml", [.values(["world", "world-name"])], "Essentials warps"),
        ("plugins/Essentials/userdata/*.yml", [.values(["world", "world-name"])], "Essentials homes and logout spots"),
        ("plugins/Citizens/saves.yml", [.values(["world"])], "Citizens NPC locations"),
        ("plugins/dynmap/worlds.txt", [.values(["name"])], "Dynmap worlds"),
        ("plugins/WorldGuard/config.yml", [.values(["world"])], "WorldGuard settings"),
        // Observed format: `mining:` then `  nether: deep`, written by `mvnp link`.
        ("plugins/Multiverse-NetherPortals/links.yml", [.key(section: nil), .values(["nether", "end"])], "Multiverse Nether links"),
    ]

    /// Per-world folders inside plugins.
    static let knownFolders: [(path: String, label: String)] = [
        ("plugins/WorldGuard/worlds", "WorldGuard regions and flags"),
        ("plugins/Multiverse-Inventories/worlds", "Per-world inventories"),
        ("plugins/WorldEdit/schematics", ""),
    ]

    static let databaseNotes: [(plugin: String, note: String)] = [
        ("CoreProtect", "CoreProtect keeps history in its database under the old world name. Past records stay under that name."),
        ("LuckPerms", "LuckPerms permissions limited to world=<name> are stored in its data, and need changing with /lp commands."),
        ("Plan", "Plan's history stays under the old world name in its database."),
        ("GriefPrevention", "Check GriefPrevention's claims after renaming: it stores world names in its claim data."),
    ]

    /// A name that's safe everywhere, including namespaced keys, which must be lowercase.
    public static func problem(with name: String, world: WorldEntry?, existing: [WorldEntry]) -> String? {
        if name.isEmpty { return "Enter a name." }
        if name.range(of: #"^[a-z0-9_-]+$"#, options: .regularExpression) == nil { return "Use lowercase letters, numbers, - and _. Newer Minecraft versions require this." }
        if existing.contains(where: { $0.title.lowercased() == name || $0.name.lowercased() == name || $0.name.lowercased() == "minecraft:\(name)" }) {
            return "A world called \(name) already exists."
        }
        return nil
    }

    /// Works out every change, reading only. Renames the world's folders and each known reference.
    public static func plan(world: WorldEntry, to new: String, paths: ServerPaths) -> RenamePlan {
        let propsText = (try? String(contentsOf: paths.properties, encoding: .utf8)) ?? ""
        let level = PropertiesDocument(propsText).value("level-name").flatMap { $0.isEmpty ? nil : $0 } ?? "world"
        let old = world.isMain ? level : world.title.replacingOccurrences(of: "minecraft:", with: "")
        let folderName = world.relativePath.map { ($0 as NSString).lastPathComponent } ?? old
        let base = world.isMain ? level : folderName

        var plan = RenamePlan(title: "Rename \(base) to \(new)")
        var names = [base: new]
        var folders: [(from: String, to: String)] = []

        if world.isMain {
            for suffix in ["_nether", "_the_end"] where FileOps.isDirectory(paths.root.appendingPathComponent(base + suffix)) {
                names[base + suffix] = new + suffix
                folders.append((base + suffix, new + suffix))
            }
            folders.insert((base, new), at: 0)
        } else if let path = world.relativePath {
            // Top-level before 26.1; `<level>/dimensions/<namespace>/<key>` from then on.
            let parent = (path as NSString).deletingLastPathComponent
            folders.append((path, parent.isEmpty ? new : "\(parent)/\(new)"))
        }
        // Multiverse may use the namespaced form.
        for (o, n) in names { names["minecraft:\(o)"] = "minecraft:\(n)" }

        for move in folders {
            plan.items.append(RenameItem(action: .moveFolder(from: move.from, to: move.to), description: "World folder", changes: ["\(move.from) → \(move.to)"]))
        }

        if world.isMain {
            var doc = PropertiesDocument(propsText)
            doc.set("level-name", new)
            plan.items.append(RenameItem(action: .replaceFile(path: "server.properties", text: doc.text), description: "Server properties", changes: ["level-name: \(base) → \(new)"]))
        }

        // The name inside the world's own data.
        if world.isMain || (world.relativePath.map { !$0.contains("/") } ?? false), FileOps.exists(paths.root.appendingPathComponent("\(base)/level.dat")) {
            plan.items.append(RenameItem(action: .levelName(path: "\(new)/level.dat", to: new), description: "Name stored in the world", changes: ["LevelName → \(new)"]))
        }

        var edited = Set<String>()
        for entry in knownFiles {
            for rel in expand(entry.glob, root: paths.root) {
                guard var text = try? String(contentsOf: paths.root.appendingPathComponent(rel), encoding: .utf8) else { continue }
                let original = text
                var changes: [String] = []
                for rule in entry.rules {
                    let result: (String, [String])
                    switch rule {
                    case let .key(section): result = RenameText.renameKey(text, section: section, names: names)
                    case let .values(keys): result = RenameText.replaceValues(text, keys: keys, names: names)
                    case .destinations: result = RenameText.replaceDestinations(text, names: names)
                    case .anchors: result = RenameText.replaceAnchors(text, names: names)
                    }
                    text = result.0
                    changes += result.1
                }
                edited.insert(rel)
                if text != original {
                    plan.items.append(RenameItem(action: .replaceFile(path: rel, text: text), description: entry.label, changes: changes.isEmpty ? ["Updated"] : changes))
                }
            }
        }

        for folder in knownFolders where !folder.label.isEmpty {
            for (o, n) in names where !o.contains(":") {
                let from = "\(folder.path)/\(o)"
                if FileOps.isDirectory(paths.root.appendingPathComponent(from)) {
                    plan.items.append(RenameItem(action: .moveFolder(from: from, to: "\(folder.path)/\(n)"), description: folder.label, changes: ["\(o) → \(n)"]))
                }
            }
        }

        // Observed: Multiverse-Inventories remembers the world each player was last in, and a rename left that stale.
        let inventoryPlayers = "plugins/Multiverse-Inventories/players"
        for file in FileOps.children(paths.root.appendingPathComponent(inventoryPlayers)) where file.pathExtension == "json" {
            guard var text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var changes: [String] = []
            for (o, n) in names where !o.contains(":") {
                let pattern = "\"lastWorld\"\\s*:\\s*\"\(NSRegularExpression.escapedPattern(for: o))\""
                if text.range(of: pattern, options: .regularExpression) != nil {
                    text = text.replacingOccurrences(of: pattern, with: "\"lastWorld\":\"\(n)\"", options: .regularExpression)
                    changes.append("\(o) → \(n)")
                }
            }
            if !changes.isEmpty {
                plan.items.append(RenameItem(action: .replaceFile(path: "\(inventoryPlayers)/\(file.lastPathComponent)", text: text), description: "A player's last world", changes: changes))
            }
        }

        for note in databaseNotes where FileOps.isDirectory(paths.plugins.appendingPathComponent(note.plugin)) {
            plan.notes.append(note.note)
        }
        plan.mentions = mentions(of: Array(names.keys.filter { !$0.contains(":") }), root: paths.root, skipping: edited)
        return plan
    }

    /// `*` matches one path component, in the last position only.
    static func expand(_ glob: String, root: URL) -> [String] {
        guard glob.contains("*") else {
            return FileOps.exists(root.appendingPathComponent(glob)) ? [glob] : []
        }
        let dir = (glob as NSString).deletingLastPathComponent
        let ext = (glob as NSString).pathExtension
        return FileOps.children(root.appendingPathComponent(dir)).filter { $0.pathExtension == ext }.map { "\(dir)/\($0.lastPathComponent)" }.sorted()
    }

    /// Other settings files that contain the name. Listed, never changed. Words like `world` are too common to search for.
    static func mentions(of names: [String], root: URL, skipping: Set<String>) -> [String] {
        let distinctive = names.filter { !["world", "world_nether", "world_the_end", "nether", "end", "the_end", "default", "main"].contains($0.lowercased()) }
        guard !distinctive.isEmpty else { return [] }
        var out: [String] = []
        let plugins = root.appendingPathComponent("plugins")
        for folder in FileOps.children(plugins) where FileOps.isDirectory(folder) {
            for rel in ConfigCatalog.settingsFiles(in: folder) {
                let full = "plugins/\(folder.lastPathComponent)/\(rel)"
                guard !skipping.contains(full), let text = try? String(contentsOf: folder.appendingPathComponent(rel), encoding: .utf8) else { continue }
                if distinctive.contains(where: { RenameText.replaceToken(text, old: $0, new: "").1 > 0 }) { out.append(full) }
                if out.count >= 40 { return out }
            }
        }
        return out
    }
}

// MARK: - Server renames

public enum ServerRename {
    /// `Sonoran Realms` → `sonoran-realms`, `sonoranrealms`, `SonoranRealms`, `sonoran_realms`.
    public static func folderFormats(for name: String) -> [String] {
        let words = name.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let lower = words.map { $0.lowercased() }
        let options = [
            lower.joined(separator: "-"), lower.joined(), words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(), lower.joined(separator: "_"),
        ]
        var seen = Set<String>()
        return options.filter { seen.insert($0).inserted }
    }

    /// Settings that hold the server's own name, in files known to have them.
    static let knownNames: [(path: String, key: String, label: String, warning: String?)] = [
        ("plugins/LuckPerms/config.yml", "server", "LuckPerms server name", "This name decides which server-specific permissions apply. Change it only if you also move those permissions, or players may lose access."),
        ("plugins/dynmap/configuration.txt", "webpage-title", "Dynmap page title", nil),
        ("plugins/Plan/config.yml", "Name", "Plan server name", nil),
        ("plugins/BlueMap/core.conf", "name", "BlueMap name", nil),
    ]

    public static func plan(oldName: String, newName: String, oldFolder: String, newFolder: String?, motd: String?, paths: ServerPaths) -> RenamePlan {
        var plan = RenamePlan(title: "Rename \(oldName) to \(newName)")
        let oldForms = Set(folderFormats(for: oldName) + [oldName, oldFolder])
        let target = newFolder ?? newName

        // A motd that mentions the old name is a suggestion, because people word these carefully.
        if let text = try? String(contentsOf: paths.properties, encoding: .utf8) {
            let doc = PropertiesDocument(text)
            if let current = doc.value("motd") {
                var updated = current
                for form in oldForms.sorted(by: { $0.count > $1.count }) { updated = RenameText.replaceToken(updated, old: form, new: newName).0 }
                if let motd { updated = motd }
                if updated != current {
                    var next = doc
                    next.set("motd", updated)
                    plan.items.append(RenameItem(action: .replaceFile(path: "server.properties", text: next.text), description: "Server message", changes: ["\(ConfigForm.plainMOTD(current)) → \(ConfigForm.plainMOTD(updated))"]))
                }
            }
        }

        // Start scripts: their paths and screen or tmux session names.
        for script in FileOps.children(paths.root).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where ["sh", "command"].contains(script.pathExtension.lowercased()) || script.lastPathComponent == "start" {
            guard var text = try? String(contentsOf: script, encoding: .utf8) else { continue }
            let original = text
            var count = 0
            let forms: [(String, String)] = [(oldFolder, target)] + oldForms.filter { $0 != oldFolder }.map { ($0, target) }
            for (o, n) in forms.sorted(by: { $0.0.count > $1.0.count }) where o != n {
                let result = RenameText.replaceToken(text, old: o, new: n)
                text = result.0
                count += result.1
            }
            if text != original {
                plan.items.append(RenameItem(action: .replaceFile(path: script.lastPathComponent, text: text), description: "Start script", changes: ["\(count) reference\(count == 1 ? "" : "s") updated"]))
            }
        }

        // Absolute paths to the old folder, anywhere in plugin settings.
        if newFolder != nil {
            let oldPath = paths.root.path
            let newPath = paths.root.deletingLastPathComponent().appendingPathComponent(target).path
            for file in rootAndPluginSettings(paths) {
                guard let text = try? String(contentsOf: paths.root.appendingPathComponent(file), encoding: .utf8), text.contains(oldPath) else { continue }
                let count = text.components(separatedBy: oldPath).count - 1
                plan.items.append(RenameItem(action: .replaceFile(path: file, text: text.replacingOccurrences(of: oldPath, with: newPath)), description: "Folder path in \(file)", changes: ["\(count) path\(count == 1 ? "" : "s") updated"]))
            }
        }

        for known in knownNames {
            guard let text = try? String(contentsOf: paths.root.appendingPathComponent(known.path), encoding: .utf8) else { continue }
            var names: [String: String] = [:]
            for form in oldForms { names[form] = newName }
            let isYAML = known.path.hasSuffix(".yml") || known.path.hasSuffix(".txt")
            let result = isYAML ? RenameText.replaceValues(text, keys: [known.key], names: names) : (text, [])
            if result.0 != text {
                var item = RenameItem(action: .replaceFile(path: known.path, text: result.0), description: known.label, changes: result.1, warning: known.warning)
                if known.warning != nil { item.optional = true; item.selected = false }
                plan.items.append(item)
            }
        }

        let edited = Set(plan.items.compactMap { item -> String? in if case let .replaceFile(path, _) = item.action { return path } else { return nil } })
        plan.mentions = WorldRename.mentions(of: Array(oldForms), root: paths.root, skipping: edited)
        return plan
    }

    private static func rootAndPluginSettings(_ paths: ServerPaths) -> [String] {
        var out = FileOps.children(paths.root).filter { ["yml", "yaml", "properties"].contains($0.pathExtension.lowercased()) }.map(\.lastPathComponent)
        for folder in FileOps.children(paths.plugins) where FileOps.isDirectory(folder) {
            out += ConfigCatalog.settingsFiles(in: folder).map { "plugins/\(folder.lastPathComponent)/\($0)" }
        }
        return out
    }
}
