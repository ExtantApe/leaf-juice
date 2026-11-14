import Foundation

/// What changed between two backups, sorted by what people care about.
public struct BackupDiff: Equatable, Sendable {
    public struct Setting: Identifiable, Equatable, Sendable {
        public var id: String { "\(file)|\(key)" }
        public let file: String
        public let key: String
        public let before: String?
        public let after: String?
    }
    public struct PluginChange: Identifiable, Equatable, Sendable {
        public var id: String { name }
        public let name: String
        public let before: String?
        public let after: String?
    }
    public struct WorldChange: Identifiable, Equatable, Sendable {
        public var id: String { name }
        public let name: String
        public var chunksChanged = 0
        public var regionsAdded = 0
        public var regionsRemoved = 0
        public var added = false
        public var removed = false
    }
    public struct ItemChange: Identifiable, Equatable, Sendable {
        public var id: String { item }
        public let item: String
        public let before: Int
        public let after: Int
    }
    public struct PlayerChange: Identifiable, Equatable, Sendable {
        public var id: String { uuid }
        public let uuid: String
        public let name: String?
        public var added = false
        public var removed = false
        public var items: [ItemChange] = []
    }

    public var serverJar: PluginChange?
    public var settings: [Setting] = []
    /// Files that changed but aren't a format this can compare setting by setting.
    public var otherSettingsFiles: [String] = []
    public var plugins: [PluginChange] = []
    public var worlds: [WorldChange] = []
    public var players: [PlayerChange] = []
    public var otherFilesChanged = 0
    public init() {}

    public var isEmpty: Bool {
        serverJar == nil && settings.isEmpty && otherSettingsFiles.isEmpty && plugins.isEmpty && worlds.isEmpty && players.isEmpty
    }
}

public enum BackupCompare {
    private static let textFormats: Set<String> = ["yml", "yaml", "properties", "json", "toml", "conf", "txt"]
    private static let boringTop: Set<String> = ["logs", "cache", "libraries", "versions", "crash-reports", ".paper", ".paper-remapped"]

    /// Unpacks both into a temporary folder, compares them, and removes it. Reads the backups only.
    public static func compare(_ older: BackupRecord, _ newer: BackupRecord, profile: ServerProfile, paths: ServerPaths) async throws -> BackupDiff {
        let work = paths.meta.appendingPathComponent("compare-\(UUID().uuidString)", isDirectory: true)
        let a = work.appendingPathComponent("a", isDirectory: true), b = work.appendingPathComponent("b", isDirectory: true)
        try FileOps.ensureDir(a)
        try FileOps.ensureDir(b)
        defer { try? FileManager.default.removeItem(at: work) }
        let needed = (older.size + newer.size) * 3
        if let free = FileOps.freeSpace(at: work), free < needed {
            throw LeafError("Comparing needs about \(Format.bytes(needed)) of free space for a moment, and \(Format.bytes(free)) is free.")
        }
        for (record, target) in [(older, a), (newer, b)] {
            let result = try await Tool.run("/usr/bin/tar", ["-xzf", Backups.folder(of: record, profile: profile).appendingPathComponent(record.fileName).path, "-C", target.path])
            guard result.ok else { throw LeafError("Couldn't read \(record.fileName). \(result.err.prefix(200))") }
        }
        return await compare(old: a, new: b)
    }

    /// Compares two unpacked server folders.
    public static func compare(old a: URL, new b: URL) async -> BackupDiff {
        var diff = BackupDiff()
        let oldFiles = walk(a), newFiles = walk(b)
        let everything = Set(oldFiles.keys).union(newFiles.keys).sorted()
        var worlds: [String: BackupDiff.WorldChange] = [:]
        let oldWorlds = Set(Backups.worldFolders(a)), newWorlds = Set(Backups.worldFolders(b))
        for name in oldWorlds.union(newWorlds) {
            var change = BackupDiff.WorldChange(name: name)
            change.added = !oldWorlds.contains(name)
            change.removed = !newWorlds.contains(name)
            worlds[name] = change
        }
        var names = PlayerFiles.userCache(ServerPaths(root: b))
        names.merge(PlayerFiles.userCache(ServerPaths(root: a))) { current, _ in current }

        for rel in everything {
            let old = oldFiles[rel].map { _ in a.appendingPathComponent(rel) }
            let new = newFiles[rel].map { _ in b.appendingPathComponent(rel) }
            if let old, let new, same(old, new) { continue }
            let parts = rel.components(separatedBy: "/")
            let top = parts[0]
            let ext = (rel as NSString).pathExtension.lowercased()

            if ext == "jar", parts.count == 1 {
                diff.serverJar = BackupDiff.PluginChange(name: "Server jar", before: old != nil ? top : oldFiles.keys.first { !$0.contains("/") && $0.hasSuffix(".jar") }, after: new != nil ? top : newFiles.keys.first { !$0.contains("/") && $0.hasSuffix(".jar") })
                continue
            }
            if top == "plugins", parts.count == 2, ext == "jar" || rel.hasSuffix(".jar.disabled") { continue }   // Compared together below.
            if ext == "mca", let world = worldName(parts, known: oldWorlds.union(newWorlds)) {
                var change = worlds[world] ?? BackupDiff.WorldChange(name: world)
                if let old, let new { change.chunksChanged += changedChunks(old, new) }
                else if new != nil { change.regionsAdded += 1 }
                else { change.regionsRemoved += 1 }
                worlds[world] = change
                continue
            }
            if ext == "dat", parts.count >= 3, parts.contains("playerdata") || parts.suffix(3).first == "players", let uuid = UUID(uuidString: (parts.last! as NSString).deletingPathExtension) {
                diff.players.append(playerChange(uuid.uuidString.lowercased(), old, new, names))
                continue
            }
            if boringTop.contains(top) { diff.otherFilesChanged += 1; continue }
            if textFormats.contains(ext), !isPlayerStat(parts) {
                compareSettings(rel, old, new, into: &diff)
                continue
            }
            diff.otherFilesChanged += 1
        }

        diff.plugins = await pluginChanges(a, b)
        diff.worlds = worlds.values.filter { $0.added || $0.removed || $0.chunksChanged > 0 || $0.regionsAdded > 0 || $0.regionsRemoved > 0 }.sorted { $0.name < $1.name }
        diff.players.sort { ($0.name ?? $0.uuid).lowercased() < ($1.name ?? $1.uuid).lowercased() }
        return diff
    }

    private static func isPlayerStat(_ parts: [String]) -> Bool {
        parts.count >= 2 && (parts.contains("stats") || parts.contains("advancements"))
    }

    private static func worldName(_ parts: [String], known: Set<String>) -> String? {
        if let i = parts.firstIndex(of: "dimensions"), i + 2 < parts.count { return "\(parts[i + 1]):\(parts[i + 2])" }
        return known.contains(parts[0]) ? parts[0] : nil
    }

    private static func walk(_ root: URL) -> [String: Int64] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return [:] }
        var out: [String: Int64] = [:]
        let prefix = root.resolvingSymlinksInPath().path + "/"
        for case let file as URL in walker {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = file.resolvingSymlinksInPath().path
            guard path.hasPrefix(prefix) else { continue }
            out[String(path.dropFirst(prefix.count))] = FileOps.size(file)
        }
        return out
    }

    private static func same(_ a: URL, _ b: URL) -> Bool {
        guard FileOps.size(a) == FileOps.size(b) else { return false }
        guard let x = try? FileHandle(forReadingFrom: a), let y = try? FileHandle(forReadingFrom: b) else { return false }
        defer { try? x.close(); try? y.close() }
        while true {
            let p = (try? x.read(upToCount: 1 << 20)) ?? nil, q = (try? y.read(upToCount: 1 << 20)) ?? nil
            if p != q { return false }
            if p?.isEmpty ?? true { return true }
        }
    }

    /// Region files start with a table of each chunk's last-saved time, so changed chunks can be counted exactly.
    static func changedChunks(_ a: URL, _ b: URL) -> Int {
        func table(_ url: URL) -> Data? {
            guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? h.close() }
            return try? h.read(upToCount: 8192)
        }
        guard let x = table(a), let y = table(b), x.count == 8192, y.count == 8192 else { return 1 }
        var count = 0
        for i in stride(from: 4096, to: 8192, by: 4) where x[x.startIndex + i..<x.startIndex + i + 4] != y[y.startIndex + i..<y.startIndex + i + 4] { count += 1 }
        return count
    }

    private static func playerChange(_ uuid: String, _ old: URL?, _ new: URL?, _ names: [String: String]) -> BackupDiff.PlayerChange {
        var change = BackupDiff.PlayerChange(uuid: uuid, name: names[uuid])
        change.added = old == nil
        change.removed = new == nil
        func tally(_ url: URL?) -> [String: Int] {
            guard let url, let s = PlayerFiles.summary(of: url) else { return [:] }
            return (s.items + s.enderItems).reduce(into: [:]) { $0[$1.item, default: 0] += $1.count }
        }
        let before = tally(old), after = tally(new)
        change.items = Set(before.keys).union(after.keys).compactMap { item in
            let x = before[item] ?? 0, y = after[item] ?? 0
            return x == y ? nil : BackupDiff.ItemChange(item: item, before: x, after: y)
        }.sorted { $0.item < $1.item }
        return change
    }

    private static func compareSettings(_ rel: String, _ old: URL?, _ new: URL?, into diff: inout BackupDiff) {
        let format = ConfigCatalog.format(for: rel)
        guard ConfigForm.supports(format) else { diff.otherSettingsFiles.append(rel); return }
        let before = old.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let after = new.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        func values(_ text: String) -> [String: String] {
            Dictionary(ConfigForm.fields(text, format: format).map { ($0.path.joined(separator: "."), $0.value) }, uniquingKeysWith: { a, _ in a })
        }
        let x = values(before), y = values(after)
        let changed = Set(x.keys).union(y.keys).filter { x[$0] != y[$0] }.sorted()
        if changed.isEmpty {
            diff.otherSettingsFiles.append(rel)   // Comments, or something the form doesn't read.
        }
        for key in changed.prefix(200) {
            diff.settings.append(BackupDiff.Setting(file: rel, key: key, before: x[key], after: y[key]))
        }
    }

    private static func pluginChanges(_ a: URL, _ b: URL) async -> [BackupDiff.PluginChange] {
        func read(_ root: URL) async -> [String: String] {
            var out: [String: String] = [:]
            for p in await PluginScanner.scan(ServerPaths(root: root)) where p.enabled {
                out[p.name] = p.version.isEmpty ? p.fileName : p.version
            }
            return out
        }
        let x = await read(a), y = await read(b)
        return Set(x.keys).union(y.keys).filter { x[$0] != y[$0] }.sorted { $0.lowercased() < $1.lowercased() }
            .map { BackupDiff.PluginChange(name: $0, before: x[$0], after: y[$0]) }
    }
}
