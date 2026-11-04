import Foundation

// MARK: - Folder cleanup

public struct CleanupItem: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public enum Confidence: Int, Comparable, Sendable {
        /// Known leftovers, and regenerated if ever needed.
        case safe
        /// Probably unused, but only you can say.
        case review
        public static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }
    }
    public let path: String
    public let reason: String
    public let size: Int64
    public let confidence: Confidence
}

public struct CleanupBatch: Codable, Identifiable, Equatable, Sendable {
    public var id: String { folder }
    public var folder: String
    public var date: Date
    public var items: [String]
    public var size: Int64
}

public enum Cleanup {
    private static let leftoverSuffixes = [".old", ".bak", ".backup", ".orig", ".tmp", ".temp", "~"]
    private static let daysToKeepLogs = 90
    private static let daysToKeepCrashReports = 30

    /// Finds likely leftovers. Reads only. Anything a current config mentions is left out.
    public static func scan(_ profile: ServerProfile, paths: ServerPaths, plugins: [InstalledPlugin], now: Date = Date()) -> [CleanupItem] {
        var out: [CleanupItem] = []
        let root = paths.root
        func add(_ url: URL, _ reason: String, _ confidence: CleanupItem.Confidence) {
            let rel = FileOps.relative(url, to: root)
            out.append(CleanupItem(path: rel, reason: reason, size: FileOps.isDirectory(url) ? FileOps.directorySize(url) : FileOps.size(url), confidence: confidence))
        }
        let current = profile.software
        let propsText = (try? String(contentsOf: paths.properties, encoding: .utf8)) ?? ""
        let level = PropertiesDocument(propsText).value("level-name").flatMap { $0.isEmpty ? nil : $0 } ?? "world"
        let scripts = FileOps.children(root).filter { ["sh", "command"].contains($0.pathExtension.lowercased()) }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")

        for item in FileOps.children(root) {
            let name = item.lastPathComponent
            let lower = name.lowercased()
            if lower.hasPrefix("hs_err_pid") || lower.hasPrefix("replay_pid") {
                add(item, "A Java crash log. Only useful while diagnosing that crash.", .safe)
            } else if leftoverSuffixes.contains(where: lower.hasSuffix) {
                add(item, "A backup or temporary copy left by a tool or an edit.", .safe)
            } else if lower.hasSuffix(".jar"), name != current.jarName, !scripts.contains(name) {
                add(item, "A server jar that isn't the one running, and no start script uses it.", .safe)
            } else if ["paper.yml", "pufferfish.yml.old"].contains(lower), FileOps.exists(root.appendingPathComponent("config/paper-global.yml")) {
                add(item, "Replaced by the files in config/ when Paper moved its settings in 1.19.", .safe)
            } else if lower == "paper.yml-readme.txt" || lower.hasSuffix("-readme.txt") {
                add(item, "A note left behind by a Paper settings migration.", .safe)
            } else if lower == "timings" || lower == "timings-reports" {
                add(item, "Old performance reports.", .safe)
            }
        }

        // Crash reports and logs past their useful life.
        for (folder, days, reason) in [("crash-reports", daysToKeepCrashReports, "An old crash report."), ("logs", daysToKeepLogs, "An old compressed log.")] {
            for file in FileOps.children(root.appendingPathComponent(folder)) {
                guard file.lastPathComponent != "latest.log", file.lastPathComponent.contains("."),
                      folder != "logs" || file.pathExtension == "gz",
                      let date = FileOps.modified(file), now.timeIntervalSince(date) > Double(days) * 86_400 else { continue }
                add(file, "\(reason) More than \(days) days old.", .safe)
            }
        }

        // Files for Minecraft versions no longer in use. Paper recreates what it needs.
        if !current.mcVersion.isEmpty {
            for version in FileOps.children(root.appendingPathComponent("versions")) where FileOps.isDirectory(version) && version.lastPathComponent != current.mcVersion {
                add(version, "Server files for Minecraft \(version.lastPathComponent). This server runs \(current.mcVersion).", .safe)
            }
        }

        // Old plugin files.
        for file in FileOps.children(paths.plugins) {
            let lower = file.lastPathComponent.lowercased()
            if leftoverSuffixes.contains(where: lower.hasSuffix) || lower.hasSuffix(".jar.old") {
                add(file, "An old copy of a plugin.", .safe)
            }
        }
        for file in FileOps.children(paths.plugins.appendingPathComponent("update")) {
            add(file, "Left waiting in the update folder.", .review)
        }

        // Settings folders whose plugin is gone. These can hold data worth keeping.
        let installed = Set(plugins.map { $0.name.lowercased() })
        if !plugins.isEmpty || FileOps.children(paths.plugins).contains(where: { $0.pathExtension == "jar" }) {
            for folder in FileOps.children(paths.plugins) where FileOps.isDirectory(folder) {
                let name = folder.lastPathComponent
                let lower = name.lowercased()
                if installed.contains(lower) || ["update", "bstats", ".paper-remapped", "paper-remapped", "spark"].contains(lower) { continue }
                add(folder, "No installed plugin uses this folder. It may be from one you removed, and could hold data you'd want.", .review)
            }
        }

        // World folders nothing refers to. Never suggested lightly.
        let worlds = WorldScanner.scan(paths)
        let knownFolders = Set(worlds.filter { $0.isManaged || $0.isCore }.compactMap(\.relativePath))
        let multiverseInstalled = plugins.contains { $0.key == Multiverse.pluginKey && $0.enabled }
        for world in worlds where !world.isCore && !world.isManaged {
            guard multiverseInstalled, let path = world.relativePath, !knownFolders.contains(path) else { continue }
            add(root.appendingPathComponent(path), "A world folder Multiverse doesn't manage, so it isn't loaded. Check it isn't one you still want.", .review)
        }
        // On 26.x, the old Nether and End folders are empty once migrated.
        let migrated = FileOps.isDirectory(root.appendingPathComponent("\(level)/dimensions/minecraft/the_nether"))
        if migrated {
            for suffix in ["_nether", "_the_end"] {
                let folder = root.appendingPathComponent(level + suffix)
                if FileOps.isDirectory(folder), !FileOps.exists(folder.appendingPathComponent("level.dat")) {
                    add(folder, "An old-style folder from before Minecraft 26 moved these worlds inside \(level).", .review)
                }
            }
        }

        // The double check: anything a current setting mentions stays.
        let references = settingsText(paths)
        out = out.filter { item in
            let name = (item.path as NSString).lastPathComponent
            guard item.confidence == .review, name.count > 3 else { return true }
            return RenameText.replaceToken(references, old: name, new: "").1 == 0
        }
        return out.sorted { ($0.confidence, $1.size) < ($1.confidence, $0.size) }
    }

    private static func settingsText(_ paths: ServerPaths) -> String {
        var parts: [String] = []
        for file in FileOps.children(paths.root) where ["yml", "properties"].contains(file.pathExtension.lowercased()) {
            if let t = try? String(contentsOf: file, encoding: .utf8) { parts.append(t) }
        }
        for sub in ["plugins/Multiverse-Core/worlds.yml", "plugins/Multiverse-Inventories/groups.yml", "plugins/Multiverse-NetherPortals/config.yml"] {
            if let t = try? String(contentsOf: paths.root.appendingPathComponent(sub), encoding: .utf8) { parts.append(t) }
        }
        return parts.joined(separator: "\n")
    }

    public static func holdingArea(_ profile: ServerProfile) -> URL {
        Backups.destination(profile).appendingPathComponent("CleanedUp", isDirectory: true)
    }

    /// Moves items to a holding area beside the backups, so any of it can come back.
    public static func apply(_ items: [CleanupItem], profile: ServerProfile, paths: ServerPaths) throws -> CleanupBatch {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        var folder = f.string(from: Date())
        var n = 2
        while FileOps.exists(holdingArea(profile).appendingPathComponent(folder)) { folder = f.string(from: Date()) + "-\(n)"; n += 1 }
        let target = holdingArea(profile).appendingPathComponent(folder, isDirectory: true)
        var moved: [String] = []
        for item in items {
            // Stay inside the server folder, whatever a path says.
            guard !item.path.contains(".."), !item.path.hasPrefix("/") else { continue }
            try FileOps.move(paths.root.appendingPathComponent(item.path), to: target.appendingPathComponent(item.path))
            moved.append(item.path)
        }
        let batch = CleanupBatch(folder: folder, date: Date(), items: moved, size: items.filter { moved.contains($0.path) }.reduce(0) { $0 + $1.size })
        try JSONStore.save(batch, to: target.appendingPathComponent("cleanup.json"))
        return batch
    }

    public static func batches(_ profile: ServerProfile) -> [CleanupBatch] {
        FileOps.children(holdingArea(profile)).compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("cleanup.json")) else { return nil }
            return try? JSONStore.decoder.decode(CleanupBatch.self, from: data)
        }.sorted { $0.date > $1.date }
    }

    public static func undo(_ batch: CleanupBatch, profile: ServerProfile, paths: ServerPaths) throws {
        let from = holdingArea(profile).appendingPathComponent(batch.folder)
        for item in batch.items {
            let target = paths.root.appendingPathComponent(item)
            guard !FileOps.exists(target) else { throw LeafError("\(item) already exists again, so it wasn't brought back. Nothing else was changed after that point.") }
            try FileOps.move(from.appendingPathComponent(item), to: target)
        }
        try FileManager.default.removeItem(at: from)
    }

    public static func discard(_ batch: CleanupBatch, profile: ServerProfile) throws {
        try FileManager.default.removeItem(at: holdingArea(profile).appendingPathComponent(batch.folder))
    }
}

// MARK: - TPS

public struct TPSReading: Equatable, Sendable {
    public let oneMinute: Double
    public let fiveMinutes: Double
    public let fifteenMinutes: Double
    public var isHealthy: Bool { oneMinute >= 18 }
}

public enum TPS {
    // Purpur adds a 5s figure: `TPS from last 5s, 1m, 5m, 15m: 20.0, 19.9, 19.9, 19.9`.
    private static let pattern = regex(#"TPS from last (?:5s, )?1m, 5m, 15m:\s*(?:\*?[\d.]+,\s*(?=\*?[\d.]+,\s*\*?[\d.]+,\s*\*?[\d.]+))?\*?([\d.]+),\s*\*?([\d.]+),\s*\*?([\d.]+)"#)

    public static func parse(_ line: String) -> TPSReading? {
        guard let m = pattern.firstMatch(in: line), m.numberOfRanges == 4 else { return nil }
        let ns = line as NSString
        guard let a = Double(ns.substring(with: m.range(at: 1))), let b = Double(ns.substring(with: m.range(at: 2))), let c = Double(ns.substring(with: m.range(at: 3))) else { return nil }
        return TPSReading(oneMinute: a, fiveMinutes: b, fifteenMinutes: c)
    }
}

// MARK: - Can friends connect?

public struct ConnectResult: Equatable, Sendable {
    public let reachable: Bool
    public let publicAddress: String
    public let detail: String
}

public enum ConnectCheck {
    /// Asks an outside service to try connecting, so this sends your public address to `api.ipify.org`
    /// and `api.mcsrvstat.us`. Only ever runs when asked.
    public static func run(port: Int) async throws -> ConnectResult {
        let ip = String(decoding: try await HTTP.data(HTTP.url("https://api.ipify.org")), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard ip.range(of: #"^[0-9a-fA-F:.]+$"#, options: .regularExpression) != nil else { throw LeafError("Couldn't work out this Mac's public address.") }
        let address = ip.contains(":") ? "[\(ip)]:\(port)" : "\(ip):\(port)"
        let body = try await HTTP.data(HTTP.url("https://api.mcsrvstat.us/3/\(ip.contains(":") ? "[\(ip)]" : ip):\(port)"))
        return parse(body, address: address)
    }

    static func parse(_ body: Data, address: String) -> ConnectResult {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if object?["online"] as? Bool == true {
            return ConnectResult(reachable: true, publicAddress: address, detail: "Friends can connect using \(address).")
        }
        return ConnectResult(
            reachable: false, publicAddress: address,
            detail: "The server couldn't be reached from the internet. Forward this port to this Mac in your router's settings, and check macOS's firewall allows Java. Some internet providers don't allow incoming connections at all (often called CGNAT).")
    }
}

// MARK: - Disk space

public enum DiskCheck {
    /// Below this, saving a world or a backup is at real risk.
    public static let criticalBytes: Int64 = 2 << 30
    public static let lowBytes: Int64 = 10 << 30

    public static func warning(free: Int64, name: String) -> (message: String, critical: Bool)? {
        if free < criticalBytes {
            return ("Only \(Format.bytes(free)) is free on the drive holding \(name). The server may not be able to save its world. Free up space or stop the server.", true)
        }
        if free < lowBytes {
            return ("\(Format.bytes(free)) is free on the drive holding \(name). Backups may start failing soon.", false)
        }
        return nil
    }
}

// MARK: - Test copies

public enum TrialChange: @unchecked Sendable {
    case software(SoftwareBuild)
    case pluginUpdate(name: String)
    case worldRename(worldName: String, to: String)
    case serverRename(to: String)
    /// For tests, and anything already staged.
    case custom(title: String, (ServerController) async throws -> Void)

    public var title: String {
        switch self {
        case let .software(build): "\(build.flavor.title) \(build.label)"
        case let .pluginUpdate(name): "Update \(name)"
        case let .worldRename(world, to): "Rename \(world) to \(to)"
        case let .serverRename(to): "Rename the server to \(to)"
        case let .custom(title, _): title
        }
    }
}

public struct TrialReport: Equatable, Sendable {
    public var booted = false
    public var seconds: Double?
    public var blockers: [String] = []
    /// Problems new to the copy: errors, plugins that didn't load, and so on.
    public var problems: [String] = []
    public var failedPlugins: [String] = []
    public var failure: String?
    /// Things the copy did differently from the real server.
    public var notes: [String] = []
    /// What searching for the cause found, once that's been run.
    public var culprit: String?
    public init() {}
    public var passed: Bool { booted && failedPlugins.isEmpty && failure == nil && blockers.isEmpty }
}

public enum TrialPhase: Equatable, Sendable {
    case copying, applying, booting, checking, open, searching(String), finished
    public var title: String {
        switch self {
        case .copying: "Making a test copy…"
        case .applying: "Applying the change to the copy…"
        case .booting: "Starting the copy…"
        case .checking: "Checking how it went…"
        case .open: "The test copy is running"
        case let .searching(step): step
        case .finished: "Finished"
        }
    }
}

public enum Trial {
    /// Plugins that talk to the outside world. A copy shouldn't post to your Discord or count votes.
    public static let disabledInCopies: Set<String> = [
        "discordsrv", "essentialsdiscord", "essentialsdiscordlink", "discordintegration", "nuvotifier", "votifier", "votingplugin",
        "dynmap", "bluemap", "plan", "drivebackupv2", "bungeecord", "velocity", "tcpshield", "geyser-spigot", "floodgate",
    ]
    private static let sharedDatabase = regex(#"^\s*(storage-method|type|driver|database-type|storage|use-mysql|mysql)\s*:\s*['"]?(mysql|mariadb|postgres\w*|postgresql|mongodb|true)['"]?\s*(#.*)?$"#, [.caseInsensitive, .anchorsMatchLines])

    /// Plugins whose main config points at an external database, which a copy would write to as well.
    public static func databasePlugins(_ paths: ServerPaths) -> [String] {
        FileOps.children(paths.plugins).filter(FileOps.isDirectory).compactMap { folder in
            for name in ["config.yml", "config.yaml", "settings.yml"] {
                if let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8), sharedDatabase.firstMatch(in: text) != nil {
                    return folder.lastPathComponent
                }
            }
            return nil
        }.sorted()
    }

    /// A port nothing else is using, starting from just above the server's own.
    public static func freePort(after port: Int) -> Int {
        var candidate = port + 1
        while candidate < 65535, SystemInfo.isPortBusy(candidate) { candidate += 1 }
        return candidate
    }

    /// APFS clones take almost no space and no time; other drives get a normal copy.
    static func clone(_ source: URL, to target: URL) async throws {
        try FileOps.ensureDir(target.deletingLastPathComponent())
        var result = try await Tool.run("/bin/cp", ["-cR", source.path, target.path])
        if !result.ok {
            try? FileManager.default.removeItem(at: target)
            result = try await Tool.run("/bin/cp", ["-R", source.path, target.path])
        }
        guard result.ok else { throw LeafError("Couldn't copy the server: \(result.err.prefix(200))") }
    }
}
