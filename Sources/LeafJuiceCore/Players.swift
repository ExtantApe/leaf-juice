import CryptoKit
import Foundation

// MARK: - Where player data lives

/// Vanilla files are per server, in the main world. Before 26.1: `world/playerdata`; from 26.1: `world/players/data`.
public struct PlayerPaths: Sendable {
    public let root: URL
    public let world: URL
    private let modern: Bool

    public init(_ paths: ServerPaths) {
        root = paths.root
        let text = (try? String(contentsOf: paths.properties, encoding: .utf8)) ?? ""
        let level = PropertiesDocument(text).value("level-name").flatMap { $0.isEmpty ? nil : $0 } ?? "world"
        world = paths.root.appendingPathComponent(level, isDirectory: true)
        modern = FileOps.isDirectory(world.appendingPathComponent("players"))
    }

    public var dataFolder: URL { world.appendingPathComponent(modern ? "players/data" : "playerdata") }
    public var statsFolder: URL { world.appendingPathComponent(modern ? "players/stats" : "stats") }
    public var advancementsFolder: URL { world.appendingPathComponent(modern ? "players/advancements" : "advancements") }

    public func data(_ id: String) -> URL { dataFolder.appendingPathComponent("\(id).dat") }
    public func stats(_ id: String) -> URL { statsFolder.appendingPathComponent("\(id).json") }
    public func advancements(_ id: String) -> URL { advancementsFolder.appendingPathComponent("\(id).json") }

    /// Multiverse-Inventories: `worlds/<world>/<name>.json` and `groups/<group>/<name>.json`, by player *name*.
    public var inventories: URL { root.appendingPathComponent("plugins/Multiverse-Inventories", isDirectory: true) }
    public var hasInventoriesPlugin: Bool { FileOps.isDirectory(inventories) }

    /// A player's per-world and per-group files, relative to the plugin's folder.
    public func inventoryContainers(name: String) -> [String] {
        var out: [String] = []
        for kind in ["worlds", "groups"] {
            for container in FileOps.children(inventories.appendingPathComponent(kind)) where FileOps.isDirectory(container) {
                if FileOps.exists(container.appendingPathComponent("\(name).json")) {
                    out.append("\(kind)/\(container.lastPathComponent)/\(name).json")
                }
            }
        }
        return out.sorted()
    }
}

// MARK: - Profiles

public struct PlayerInfo: Identifiable, Equatable, Sendable {
    public var id: String { uuid }
    public let uuid: String
    public let name: String?
    public let lastSeen: Date?
    public let playTicks: Int?
    public var playTime: TimeInterval? { playTicks.map { Double($0) / 20 } }
    public var title: String { name ?? uuid }
}

public struct InventoryItem: Identifiable, Equatable, Sendable {
    public var id: String { "\(slot)-\(item)" }
    public let slot: Int
    public let item: String
    public let count: Int
    public var title: String { ConfigForm.humanize(item.replacingOccurrences(of: "minecraft:", with: "")) }
}

public struct InventorySummary: Equatable, Sendable {
    public var items: [InventoryItem] = []
    public var enderItems: [InventoryItem] = []
    public var level: Int?
    public var dimension: String?
}

public enum PlayerFiles {
    /// Players the server knows: from its data files, with names from `usercache.json` or the file itself.
    public static func list(_ paths: ServerPaths) -> [PlayerInfo] {
        let p = PlayerPaths(paths)
        let names = userCache(paths)
        return FileOps.children(p.dataFolder).filter { $0.pathExtension == "dat" }.compactMap { file in
            let id = file.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: id) != nil else { return nil }
            let name = names[id.lowercased()] ?? (try? NBT.read(file))?.root["bukkit"]?["lastKnownName"]?.stringValue
            return PlayerInfo(uuid: id, name: name, lastSeen: FileOps.modified(file), playTicks: playTicks(p.stats(id)))
        }.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    /// uuid → name.
    public static func userCache(_ paths: ServerPaths) -> [String: String] {
        guard let data = try? Data(contentsOf: paths.root.appendingPathComponent("usercache.json")),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for entry in list {
            if let id = entry["uuid"] as? String, let name = entry["name"] as? String { out[id.lowercased()] = name }
        }
        return out
    }

    static func playTicks(_ stats: URL) -> Int? {
        guard let data = try? Data(contentsOf: stats),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let all = object["stats"] as? [String: Any], let custom = all["minecraft:custom"] as? [String: Any] else { return nil }
        return (custom["minecraft:play_time"] ?? custom["minecraft:play_one_minute"]) as? Int
    }

    public static func summary(of file: URL) -> InventorySummary? {
        guard let doc = try? NBT.read(file) else { return nil }
        return summary(doc.root)
    }

    public static func summary(_ root: NBT) -> InventorySummary {
        func items(_ tag: NBT?) -> [InventoryItem] {
            (tag?.listValue ?? []).compactMap { entry in
                guard let id = entry["id"]?.stringValue else { return nil }
                // `count` from 1.20.5, `Count` before.
                let count = entry["count"]?.intValue ?? entry["Count"]?.intValue ?? 1
                return InventoryItem(slot: entry["Slot"]?.intValue ?? -1, item: id, count: count)
            }
        }
        return InventorySummary(
            items: items(root["Inventory"]), enderItems: items(root["EnderItems"]),
            level: root["XpLevel"]?.intValue, dimension: root["Dimension"]?.stringValue)
    }

    /// A Multiverse-Inventories file holds one section per game mode:
    /// `{"SURVIVAL":{"inventoryContents":{"0":{"id":"minecraft:iron_ingot","count":7}},"enderChestContents":{}}}`.
    public static func summary(ofInventoryFile file: URL) -> InventorySummary? {
        guard let data = try? Data(contentsOf: file),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func items(_ section: Any?) -> [InventoryItem] {
            guard let slots = section as? [String: Any] else { return [] }
            return slots.compactMap { key, value in
                guard let item = value as? [String: Any], let id = item["id"] as? String else { return nil }
                return InventoryItem(slot: Int(key) ?? -1, item: id, count: item["count"] as? Int ?? 1)
            }.sorted { $0.slot < $1.slot }
        }
        var out = InventorySummary()
        for mode in root.values.compactMap({ $0 as? [String: Any] }) {
            out.items += items(mode["inventoryContents"]) + items(mode["armorContents"])
            out.enderItems += items(mode["enderChestContents"])
        }
        return out
    }

    /// The UUID an offline-mode server gives this name. A mode switch leaves two profiles behind.
    public static func offlineUUID(name: String) -> String {
        var bytes = Array(Insecure.MD5.hash(data: Data("OfflinePlayer:\(name)".utf8)))
        bytes[6] = (bytes[6] & 0x0F) | 0x30
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        func part(_ a: Int, _ b: Int) -> Substring { hex[hex.index(hex.startIndex, offsetBy: a)..<hex.index(hex.startIndex, offsetBy: b)] }
        return "\(part(0, 8))-\(part(8, 12))-\(part(12, 16))-\(part(16, 20))-\(part(20, 32))"
    }
}

// MARK: - Snapshots

public struct PlayerSnapshotConfig: Codable, Equatable, Sendable {
    public var enabled = true
    public var intervalMinutes = 15
    /// 96 at 15 minutes is the last 24 hours of play, per player.
    public var keep = 96
    public init() {}
}

public struct PlayerSnapshot: Codable, Identifiable, Equatable, Sendable {
    public var id: String { folder }
    public var folder: String
    public var uuid: String
    public var name: String
    public var date: Date
    /// "playing", "left", "manual", "backup" or "before-restore".
    public var trigger: String
    public var containers: [String]
}

public enum PlayerSnapshots {
    /// Puts a copy of `source` at `target` without ever leaving `target` missing: copied beside it first, then
    /// swapped in. A failed copy leaves the old file as it was (K158 audit).
    static func replaceCopying(_ source: URL, at target: URL) throws {
        let temp = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).restoring")
        try? FileManager.default.removeItem(at: temp)
        try FileManager.default.copyItem(at: source, to: temp)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: target)
        }
    }

    public static func folder(_ profile: ServerProfile) -> URL {
        Backups.destination(profile).appendingPathComponent("PlayerSnapshots", isDirectory: true)
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: date)
    }

    /// Copies a player's saved data as it stands. Doesn't touch the server, so it's safe mid-game.
    @discardableResult
    public static func take(uuid: String, name: String, trigger: String, paths: ServerPaths, profile: ServerProfile, keep: Int? = nil) throws -> PlayerSnapshot {
        let p = PlayerPaths(paths)
        let base = folder(profile).appendingPathComponent(uuid, isDirectory: true)
        var target = base.appendingPathComponent(stamp(Date()), isDirectory: true)
        var n = 2
        while FileOps.exists(target) { target = base.appendingPathComponent("\(stamp(Date()))-\(n)", isDirectory: true); n += 1 }
        try FileOps.ensureDir(target)
        let source = p.data(uuid)
        if FileOps.exists(source) { try FileManager.default.copyItem(at: source, to: target.appendingPathComponent("player.dat")) }
        let containers = p.inventoryContainers(name: name)
        for rel in containers {
            let to = target.appendingPathComponent("inventories").appendingPathComponent(rel)
            try FileOps.ensureDir(to.deletingLastPathComponent())
            try FileManager.default.copyItem(at: p.inventories.appendingPathComponent(rel), to: to)
        }
        let snapshot = PlayerSnapshot(folder: target.lastPathComponent, uuid: uuid, name: name, date: Date(), trigger: trigger, containers: containers)
        try JSONStore.save(snapshot, to: target.appendingPathComponent("snapshot.json"))
        if let keep { prune(uuid: uuid, keep: keep, profile: profile) }
        return snapshot
    }

    public static func list(uuid: String, profile: ServerProfile) -> [PlayerSnapshot] {
        let base = folder(profile).appendingPathComponent(uuid, isDirectory: true)
        return FileOps.children(base).compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("snapshot.json")) else { return nil }
            return try? JSONStore.decoder.decode(PlayerSnapshot.self, from: data)
        }.sorted { $0.date > $1.date }
    }

    /// Observed: an inventory-only restore puts the items wherever the player is now, even if they came from another world.
    /// Returns both worlds when they differ.
    public static func crossWorld(_ snapshot: PlayerSnapshot, paths: ServerPaths, profile: ServerProfile) -> (taken: String, now: String)? {
        guard let saved = try? NBT.read(location(snapshot, profile: profile).appendingPathComponent("player.dat")),
              let live = try? NBT.read(PlayerPaths(paths).data(snapshot.uuid)),
              let taken = saved.root["Dimension"]?.stringValue, let now = live.root["Dimension"]?.stringValue, taken != now else { return nil }
        func short(_ name: String) -> String { name.replacingOccurrences(of: "minecraft:", with: "") }
        return (short(taken), short(now))
    }

    /// Observed: Minecraft upgrades old player data when it loads, but nothing can read data from a newer version.
    public static func isFromNewerVersion(_ snapshot: PlayerSnapshot, paths: ServerPaths, profile: ServerProfile) -> Bool {
        guard let saved = try? NBT.read(location(snapshot, profile: profile).appendingPathComponent("player.dat")),
              let live = try? NBT.read(PlayerPaths(paths).data(snapshot.uuid)),
              let old = saved.root["DataVersion"]?.intValue, let current = live.root["DataVersion"]?.intValue else { return false }
        return old > current
    }

    public static func location(_ snapshot: PlayerSnapshot, profile: ServerProfile) -> URL {
        folder(profile).appendingPathComponent(snapshot.uuid).appendingPathComponent(snapshot.folder)
    }

    /// Automatic ones roll off. Ones you asked for, or made before a restore, stay until you delete them.
    public static func prune(uuid: String, keep: Int, profile: ServerProfile) {
        let automatic = list(uuid: uuid, profile: profile).filter { $0.trigger == "playing" || $0.trigger == "left" }
        for old in automatic.dropFirst(max(1, keep)) {
            try? FileManager.default.removeItem(at: location(old, profile: profile))
        }
    }

    public static func delete(_ snapshot: PlayerSnapshot, profile: ServerProfile) throws {
        try FileManager.default.removeItem(at: location(snapshot, profile: profile))
    }

    /// Pulls one player's data out of a backup, without restoring the world.
    public static func fromBackup(_ record: BackupRecord, uuid: String, name: String, paths: ServerPaths, profile: ServerProfile) async throws -> PlayerSnapshot {
        let archive = Backups.folder(of: record, profile: profile).appendingPathComponent(record.fileName)
        let work = paths.meta.appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
        try FileOps.ensureDir(work)
        defer { try? FileManager.default.removeItem(at: work) }
        // Covers both layouts, in whichever world folder held the data.
        let result = try await Tool.run("/usr/bin/tar", [
            "-xzf", archive.path, "-C", work.path,
            "--include", "*/playerdata/\(uuid).dat", "--include", "*/players/data/\(uuid).dat",
            "--include", "plugins/Multiverse-Inventories/worlds/*/\(name).json",
            "--include", "plugins/Multiverse-Inventories/groups/*/\(name).json",
        ])
        // tar reports each pattern that didn't match, which is normal: only one layout applies.
        guard result.ok || result.err.contains("Not found in archive") else { throw LeafError("Couldn't read that backup. \(result.err.prefix(200))") }

        var dat: URL?
        if let walker = FileManager.default.enumerator(at: work, includingPropertiesForKeys: nil) {
            for case let file as URL in walker where file.lastPathComponent == "\(uuid).dat" { dat = file }
        }
        let invRoot = work.appendingPathComponent("plugins/Multiverse-Inventories")
        var containers: [String] = []
        for kind in ["worlds", "groups"] {
            for c in FileOps.children(invRoot.appendingPathComponent(kind)) where FileOps.exists(c.appendingPathComponent("\(name).json")) {
                containers.append("\(kind)/\(c.lastPathComponent)/\(name).json")
            }
        }
        guard dat != nil || !containers.isEmpty else { throw LeafError("\(name) has no saved data in that backup.") }

        let target = folder(profile).appendingPathComponent(uuid).appendingPathComponent("\(stamp(record.date))-backup", isDirectory: true)
        if FileOps.exists(target) { try FileManager.default.removeItem(at: target) }
        try FileOps.ensureDir(target)
        if let dat { try FileOps.move(dat, to: target.appendingPathComponent("player.dat")) }
        for rel in containers {
            try FileOps.move(invRoot.appendingPathComponent(rel), to: target.appendingPathComponent("inventories").appendingPathComponent(rel))
        }
        let snapshot = PlayerSnapshot(folder: target.lastPathComponent, uuid: uuid, name: name, date: record.date, trigger: "backup", containers: containers.sorted())
        try JSONStore.save(snapshot, to: target.appendingPathComponent("snapshot.json"))
        return snapshot
    }

    /// Puts a snapshot back. `inventoryOnly` keeps the player's position, XP and health as they are now.
    /// `containers` chooses which worlds or groups to restore when Multiverse-Inventories is in use.
    public static func restore(_ snapshot: PlayerSnapshot, inventoryOnly: Bool, containers: [String], paths: ServerPaths, profile: ServerProfile) throws {
        let p = PlayerPaths(paths)
        let from = location(snapshot, profile: profile)
        let saved = from.appendingPathComponent("player.dat")
        if FileOps.exists(saved) {
            let live = p.data(snapshot.uuid)
            if inventoryOnly, FileOps.exists(live) {
                var doc = try NBT.read(live)
                let old = try NBT.read(saved)
                for key in ["Inventory", "EnderItems", "equipment"] { doc.root[key] = old.root[key] }
                try NBT.write(doc, to: live)
            } else {
                try FileOps.ensureDir(live.deletingLastPathComponent())
                try Self.replaceCopying(saved, at: live)
            }
        }
        for rel in containers where snapshot.containers.contains(rel) {
            let to = p.inventories.appendingPathComponent(rel)
            try FileOps.ensureDir(to.deletingLastPathComponent())
            try Self.replaceCopying(from.appendingPathComponent("inventories").appendingPathComponent(rel), at: to)
        }
    }
}

// MARK: - Merging profiles

public struct MergeSuggestion: Identifiable, Equatable, Sendable {
    public var id: String { "\(from.uuid)|\(from.name ?? "")|\(to.uuid)|\(reason)" }
    public let from: PlayerRef
    public let to: PlayerRef
    public let reason: String
}

public struct PlayerRef: Equatable, Hashable, Sendable {
    public let uuid: String
    public let name: String?
    public init(uuid: String, name: String?) { self.uuid = uuid; self.name = name }
    public var title: String { name ?? uuid }
}

public struct MergePlan: Equatable, Sendable {
    public var from: PlayerRef
    public var to: PlayerRef
    /// Whose inventory, position and XP to keep.
    public var keepFromSource = false
    /// Conflicting Multiverse-Inventories files: container → use the old profile's copy.
    public var useOldContainer: [String: Bool] = [:]
    public init(from: PlayerRef, to: PlayerRef) { self.from = from; self.to = to }
}

public enum PlayerMerge {
    /// Observed: on an offline server, `Alice` and `alice` are different players, but on a Mac disk one's
    /// Multiverse-Inventories file overwrites the other's, because files there are named by player.
    public static func caseCollisions(_ paths: ServerPaths, players: [PlayerInfo]) -> [[String]] {
        let text = (try? String(contentsOf: paths.properties, encoding: .utf8)) ?? ""
        guard PropertiesDocument(text).value("online-mode") == "false", PlayerPaths(paths).hasInventoriesPlugin else { return [] }
        let names = Set(players.compactMap(\.name))
        return Dictionary(grouping: names) { $0.lowercased() }.values.filter { $0.count > 1 }.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }

    /// Profiles that look like the same person.
    public static func suggestions(_ paths: ServerPaths) -> [MergeSuggestion] {
        let p = PlayerPaths(paths)
        let players = PlayerFiles.list(paths)
        var out: [MergeSuggestion] = []
        // A mode switch: the same name has an online profile and its offline twin.
        for player in players {
            guard let name = player.name else { continue }
            let twin = PlayerFiles.offlineUUID(name: name)
            guard twin != player.uuid.lowercased(), FileOps.exists(p.data(twin)) else { continue }
            out.append(MergeSuggestion(
                from: PlayerRef(uuid: twin, name: name), to: PlayerRef(uuid: player.uuid, name: name),
                reason: "\(name) has an offline-mode profile and an online-mode one, usually from switching online-mode."))
        }
        // A rename: Multiverse-Inventories files for a name nobody has any more.
        guard p.hasInventoriesPlugin else { return out }
        let current = Set(players.compactMap { $0.name?.lowercased() })
        var orphaned = Set<String>()
        for kind in ["worlds", "groups"] {
            for container in FileOps.children(p.inventories.appendingPathComponent(kind)) {
                for file in FileOps.children(container) where file.pathExtension == "json" {
                    let name = file.deletingPathExtension().lastPathComponent
                    if !current.contains(name.lowercased()) { orphaned.insert(name) }
                }
            }
        }
        for name in orphaned.sorted() {
            out.append(MergeSuggestion(
                from: PlayerRef(uuid: "", name: name), to: PlayerRef(uuid: "", name: nil),
                reason: "Per-world inventories exist for \(name), but no current player has that name. They may have changed it."))
        }
        return out
    }

    /// Adds statistics together.
    public static func mergedStats(_ a: Data, _ b: Data) -> Data? {
        guard var x = (try? JSONSerialization.jsonObject(with: a)) as? [String: Any],
              let y = (try? JSONSerialization.jsonObject(with: b)) as? [String: Any],
              var xs = x["stats"] as? [String: [String: Int]], let ys = y["stats"] as? [String: [String: Int]] else { return nil }
        for (category, values) in ys {
            for (key, value) in values { xs[category, default: [:]][key, default: 0] += value }
        }
        x["stats"] = xs
        return try? JSONSerialization.data(withJSONObject: x, options: [.prettyPrinted, .sortedKeys])
    }

    /// Combines advancements: anything either profile earned stays earned, with the earlier date.
    public static func mergedAdvancements(_ a: Data, _ b: Data) -> Data? {
        guard var x = (try? JSONSerialization.jsonObject(with: a)) as? [String: Any],
              let y = (try? JSONSerialization.jsonObject(with: b)) as? [String: Any] else { return nil }
        for (key, value) in y {
            guard let theirs = value as? [String: Any], let criteria = theirs["criteria"] as? [String: String] else {
                if x[key] == nil { x[key] = value }
                continue
            }
            var mine = (x[key] as? [String: Any]) ?? [:]
            var combined = (mine["criteria"] as? [String: String]) ?? [:]
            for (name, date) in criteria {
                if let existing = combined[name], existing <= date { continue }
                combined[name] = date
            }
            mine["criteria"] = combined
            mine["done"] = (mine["done"] as? Bool ?? false) || (theirs["done"] as? Bool ?? false)
            x[key] = mine
        }
        return try? JSONSerialization.data(withJSONObject: x, options: [.prettyPrinted, .sortedKeys])
    }

    /// Multiverse-Inventories files both profiles have, which need a choice.
    public static func conflicts(_ plan: MergePlan, paths: ServerPaths) -> [String] {
        let p = PlayerPaths(paths)
        guard let oldName = plan.from.name, let newName = plan.to.name, oldName != newName else { return [] }
        let new = Set(p.inventoryContainers(name: newName).map { ($0 as NSString).deletingLastPathComponent })
        return p.inventoryContainers(name: oldName).map { ($0 as NSString).deletingLastPathComponent }.filter(new.contains).sorted()
    }

    /// Plugin files named after a profile's UUID, which aren't changed automatically.
    public static func otherFiles(uuid: String, paths: ServerPaths) -> [String] {
        guard !uuid.isEmpty, let walker = FileManager.default.enumerator(at: paths.plugins, includingPropertiesForKeys: nil) else { return [] }
        var out: [String] = []
        for case let file as URL in walker where file.lastPathComponent.lowercased().hasPrefix(uuid.lowercased()) {
            out.append(FileOps.relative(file, to: paths.root))
            if out.count > 50 { break }
        }
        return out.sorted()
    }

    /// Applies with the server stopped. The profile merged away is kept in `archive`, not deleted.
    public static func apply(_ plan: MergePlan, paths: ServerPaths, archive: URL) throws {
        let p = PlayerPaths(paths)
        try FileOps.ensureDir(archive)
        let from = plan.from.uuid, to = plan.to.uuid

        if !from.isEmpty, !to.isEmpty, from.lowercased() != to.lowercased() {
            // Data file: keep the chosen one, always identifying as the profile that stays.
            let source = plan.keepFromSource ? p.data(from) : p.data(to)
            if FileOps.exists(source), let target = UUID(uuidString: to) {
                var doc = try NBT.read(source)
                doc.root["UUID"] = NBT.uuid(target)
                // Older files keep it as two numbers.
                doc.root["UUIDMost"] = nil
                doc.root["UUIDLeast"] = nil
                if let name = plan.to.name, var bukkit = doc.root["bukkit"] {
                    bukkit["lastKnownName"] = .string(name)
                    doc.root["bukkit"] = bukkit
                }
                let live = p.data(to)
                if FileOps.exists(live) { try FileManager.default.copyItem(at: live, to: archive.appendingPathComponent("kept-\(to).dat")) }
                try NBT.write(doc, to: live)
            }
            if FileOps.exists(p.data(from)) { try FileOps.move(p.data(from), to: archive.appendingPathComponent("\(from).dat")) }

            // Statistics add up; advancements combine.
            for (url, combine): (((String) -> URL), (Data, Data) -> Data?) in [(p.stats, mergedStats), (p.advancements, mergedAdvancements)] {
                let old = url(from), new = url(to)
                guard FileOps.exists(old) else { continue }
                if let a = try? Data(contentsOf: new), let b = try? Data(contentsOf: old), let merged = combine(a, b) {
                    try merged.write(to: new, options: .atomic)
                    try FileOps.move(old, to: archive.appendingPathComponent(old.deletingLastPathComponent().lastPathComponent + "-" + old.lastPathComponent))
                } else {
                    try FileOps.move(old, to: new)
                }
            }
        }

        // Per-world inventories follow the name.
        if let oldName = plan.from.name, let newName = plan.to.name, oldName != newName {
            for rel in p.inventoryContainers(name: oldName) {
                let container = (rel as NSString).deletingLastPathComponent
                let old = p.inventories.appendingPathComponent(rel)
                let new = p.inventories.appendingPathComponent(container).appendingPathComponent("\(newName).json")
                let safe = container.replacingOccurrences(of: "/", with: "-")
                if FileOps.exists(new) {
                    if plan.useOldContainer[container] == true {
                        try FileOps.move(new, to: archive.appendingPathComponent("\(safe)-\(newName).json"))
                        try FileOps.move(old, to: new)
                    } else {
                        try FileOps.move(old, to: archive.appendingPathComponent("\(safe)-\(oldName).json"))
                    }
                } else {
                    try FileOps.move(old, to: new)
                }
            }
        }

        // The plugin's own name records. Observed to do no harm when left, but a merged profile shouldn't linger.
        let oldID = plan.from.uuid.lowercased(), newID = plan.to.uuid.lowercased()
        let namesFile = p.inventories.appendingPathComponent("playernames.json")
        if let data = try? Data(contentsOf: namesFile), var names = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] {
            if !oldID.isEmpty, oldID != newID { names[oldID] = nil }
            if !newID.isEmpty, let newName = plan.to.name { names[newID] = newName }
            if let out = try? JSONSerialization.data(withJSONObject: names, options: [.sortedKeys]) { try out.write(to: namesFile, options: .atomic) }
        }
        let records = p.inventories.appendingPathComponent("players")
        if !oldID.isEmpty, oldID != newID {
            let old = records.appendingPathComponent("\(oldID).json")
            if FileOps.exists(old) { try FileOps.move(old, to: archive.appendingPathComponent("inventories-player-\(oldID).json")) }
        }
        if !newID.isEmpty, let newName = plan.to.name {
            let record = records.appendingPathComponent("\(newID).json")
            if let text = try? String(contentsOf: record, encoding: .utf8) {
                let fixed = text.replacingOccurrences(of: #""lastKnownName"\s*:\s*"[^"]*""#, with: "\"lastKnownName\":\"\(newName)\"", options: String.CompareOptions.regularExpression)
                try FileOps.writeAtomic(fixed, to: record)
            }
        }
    }
}

// MARK: - Who was on, and when

public struct PlayerSession: Codable, Identifiable, Equatable, Sendable {
    public var id: String { "\(name)-\(start.timeIntervalSince1970)" }
    public var name: String
    public var start: Date
    public var end: Date?
    public init(name: String, start: Date, end: Date? = nil) { self.name = name; self.start = start; self.end = end }
}

public enum PlayerHistory {
    private static let timed = regex(#"^\[(\d\d):(\d\d):(\d\d)[^\]]*\](?: \[[^\]]*\])?:? ?(\.?[A-Za-z0-9_]{1,16}) (joined|left) the game"#)
    private static let logName = regex(#"^(\d{4})-(\d\d)-(\d\d)-\d+\.log\.gz$"#)

    /// Reads a log's sessions. `day` is midnight of the log's date. A line is `[12:00:00] [Server thread/INFO]: Steve joined the game`.
    public static func sessions(inLog text: String, day: Date, calendar: Calendar = .current) -> [PlayerSession] {
        var open: [String: PlayerSession] = [:]
        var done: [PlayerSession] = []
        var last = day
        for line in text.split(whereSeparator: \.isNewline) {
            let s = String(line)
            guard let m = timed.firstMatch(in: s), m.numberOfRanges == 6 else { continue }
            let ns = s as NSString
            guard let h = Int(ns.substring(with: m.range(at: 1))), let mi = Int(ns.substring(with: m.range(at: 2))), let se = Int(ns.substring(with: m.range(at: 3))),
                  var when = calendar.date(bySettingHour: h, minute: mi, second: se, of: day) else { continue }
            // Logs can run past midnight.
            if when < last { when = calendar.date(byAdding: .day, value: 1, to: when) ?? when }
            last = when
            let name = ns.substring(with: m.range(at: 4))
            if ns.substring(with: m.range(at: 5)) == "joined" {
                if let stale = open[name] { done.append(stale) }
                open[name] = PlayerSession(name: name, start: when)
            } else if var session = open.removeValue(forKey: name) {
                session.end = when
                done.append(session)
            }
        }
        return done + open.values
    }

    /// Everything the server's logs remember, newest first.
    public static func read(_ paths: ServerPaths, limitFiles: Int = 60) -> [PlayerSession] {
        let logs = paths.root.appendingPathComponent("logs")
        var out: [PlayerSession] = []
        let calendar = Calendar.current
        let archived = FileOps.children(logs).filter { logName.firstMatch(in: $0.lastPathComponent) != nil }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(limitFiles)
        for file in archived {
            guard let m = logName.firstMatch(in: file.lastPathComponent),
                  FileOps.size(file) <= 32 << 20,   // a spam-loop log isn't read whole (K158 audit)
                  let data = try? Data(contentsOf: file), let plain = try? Gzip.decompress(data) else { continue }
            let ns = file.lastPathComponent as NSString
            var parts = DateComponents()
            parts.year = Int(ns.substring(with: m.range(at: 1)))
            parts.month = Int(ns.substring(with: m.range(at: 2)))
            parts.day = Int(ns.substring(with: m.range(at: 3)))
            guard let day = calendar.date(from: parts) else { continue }
            out += sessions(inLog: String(decoding: plain, as: UTF8.self), day: day)
        }
        let latest = logs.appendingPathComponent("latest.log")
        if let data = PackGate.tail(latest, bytes: 16 << 20), let modified = FileOps.modified(latest) {
            out += sessions(inLog: String(decoding: data, as: UTF8.self), day: calendar.startOfDay(for: modified))
        }
        return out.sorted { $0.start > $1.start }
    }
}
