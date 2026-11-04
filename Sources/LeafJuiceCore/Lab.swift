import Foundation
import Observation

// A protected practice server. Everything in it is made by Leaf Juice, so wiping it costs nothing,
// and it can rehearse an upgrade without the real server's worlds or players ever being involved.

public enum LabFiles {
    public static let folderName = "lab"
    public static var root: URL { AppPaths.servers.appendingPathComponent(folderName, isDirectory: true) }
    static var own: URL { AppPaths.servers.appendingPathComponent(AppPaths.ownFolderName, isDirectory: true) }
    public static var saves: URL { own.appendingPathComponent("rehearsals", isDirectory: true) }
    static var state: URL { own.appendingPathComponent("lab.json") }
    static var scratch: URL { own.appendingPathComponent("lab-scratch", isDirectory: true) }
    static var protocols: URL { AppPaths.home.appendingPathComponent("protocol", isDirectory: true) }

    /// Wiping is only ever allowed where both hold, so a server merely named "lab" is safe.
    public static func isLab(root candidate: URL, profile: ServerProfile) -> Bool {
        profile.isLab && candidate.standardizedFileURL.resolvingSymlinksInPath().path == root.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// `2026-11-03_20-15_paper-1.21.11-build132_before-26-upgrade.tar.gz`
    public static func saveName(date: Date, software: SoftwareState, note: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        var parts = [f.string(from: date), "\(software.flavor.rawValue)-\(software.mcVersion.isEmpty ? "unknown" : software.mcVersion)\(software.build.map { "-build\($0)" } ?? "")"]
        let slug = slug(note)
        if !slug.isEmpty { parts.append(slug) }
        return parts.joined(separator: "_") + ".tar.gz"
    }

    static func slug(_ note: String) -> String {
        let words = note.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : " " }
        return String(words).split(separator: " ").joined(separator: "-").prefix(48).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

public struct LabSave: Codable, Identifiable, Equatable, Sendable {
    public var id: String { fileName }
    public var fileName: String
    public var date: Date
    public var note: String
    public var software: String
    public var plugins: [String]
    public var size: Int64
}

/// The check outcomes keep "didn't run" apart from "passed".
public struct LabCheck: Codable, Identifiable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case passed, failed, skipped }
    public var id: String { title }
    public var title: String
    public var outcome: Outcome
    public var detail: String
    public init(_ title: String, _ outcome: Outcome, _ detail: String = "") {
        self.title = title; self.outcome = outcome; self.detail = detail
    }
}

public struct RehearsalPath: Codable, Equatable, Sendable {
    public var title: String
    /// How this path got to the new version, in words.
    public var route: String
    public var checks: [LabCheck] = []
    public var passed: Bool { !checks.isEmpty && !checks.contains { $0.outcome == .failed } }
    public var failures: [LabCheck] { checks.filter { $0.outcome == .failed } }
    public init(title: String, route: String, checks: [LabCheck] = []) { self.title = title; self.route = route; self.checks = checks }
}

public struct RehearsalReport: Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Sendable { case bothPassed, upgradeFailed, freshFailed, bothFailed }
    public var date: Date
    public var serverName: String
    public var from: String
    public var to: String
    public var migrated: RehearsalPath
    public var fresh: RehearsalPath
    /// The new version with the real server's plugin settings, if that was asked for.
    public var withSettings: RehearsalPath?
    /// Run only after fresh settings pass, so a failure here points at the settings.
    public var settingsProblem: Bool { fresh.passed && withSettings?.passed == false }

    public var verdict: Verdict {
        switch (migrated.passed, fresh.passed) {
        case (true, true): .bothPassed
        case (false, true): .upgradeFailed
        case (true, false): .freshFailed
        case (false, false): .bothFailed
        }
    }
    public var headline: String {
        switch verdict {
        case .bothPassed where settingsProblem: "It works, except with this server's settings"
        case .bothPassed: "Both paths passed these checks"
        case .upgradeFailed: "Fresh works, but upgrading doesn't"
        case .freshFailed: "Upgrading works, but a new install doesn't"
        case .bothFailed: "\(to) didn't work with these plugins"
        }
    }
    public var explanation: String {
        switch verdict {
        case .bothPassed where settingsProblem: "The new version and plugins work with fresh settings, but not with this server's. That points at a setting, so look at the failures below before upgrading."
        case .bothPassed: "Nothing here stands in the way of upgrading. The real server has its own data, so the upgrade still makes a restore point first."
        case .upgradeFailed: "The new version and plugins are fine together. The trouble is in moving existing data across, so look closely before upgrading the real server."
        case .freshFailed: "Upgraded data works, but something relies on a setup only older data had. It may be fine for now, and would bite on a rebuild."
        case .bothFailed: "This looks like a real incompatibility rather than a data problem. Look at the failures below before going further."
        }
    }
    /// So a pass isn't read as a promise.
    public static let notChecked = [
        "What each plugin does in play, beyond loading without errors.",
        "Your real worlds, players and plugin settings. The Lab uses its own.",
        "Real players' clients, mods and resource packs.",
        "How it runs under a real load.",
    ]
}

/// The built-in seed: a script rather than bundled files, so it works on any version and ships nothing of Mojang's.
public enum LabRecipe {
    public static let players = ["Alice", "Bob", "Carol"]
    public static let worlds: [(name: String, environment: WorldEnvironment, type: WorldType)] = [
        ("mining", .normal, .flat), ("creative", .normal, .flat), ("deep", .nether, .normal),
    ]
    public static let defaultPlugins: [PluginSource] = [
        Multiverse.source, .modrinth(project: "multiverse-inventories", allowBeta: false), .modrinth(project: "luckperms", allowBeta: false),
    ]
    /// Offline mode lets bots in, so the Lab only listens on this Mac.
    static func properties(port: Int) -> String {
        [
            "server-ip=127.0.0.1", "server-port=\(port)", "online-mode=false", "white-list=false", "enforce-whitelist=false",
            "network-compression-threshold=-1", "view-distance=4", "simulation-distance=4", "spawn-protection=0", "max-tick-time=-1",
            "level-type=minecraft\\:flat", "motd=Leaf Juice Lab",
            // Observed: slimes killed a bot on a flat world, which looks like lost items.
            "difficulty=peaceful", "spawn-monsters=false", "enable-rcon=false", "enable-query=false",
        ].joined(separator: "\n") + "\n"
    }
}

/// What a Lab is built from.
public struct LabSpec: Sendable {
    public var build: SoftwareBuild
    public var sources: [PluginSource]
    /// Plugins with no source can only be copied. Just the jar, never its settings or data.
    public var jars: [URL]
    /// Not run in the Lab, and why.
    public var leftOut: [String] = []
    public init(build: SoftwareBuild, sources: [PluginSource] = LabRecipe.defaultPlugins, jars: [URL] = []) {
        self.build = build; self.sources = sources; self.jars = jars
    }
}

struct LabState: Codable, Equatable {
    var eulaAcceptedAt: Date?
    var lastReport: RehearsalReport?
    /// The server the Lab is modeled on, by folder.
    var modelServer: String?
    var target: SoftwareBuild?
    var board: [LabStation: StationResult] = [:]
    /// Problems the plugins already have on the current version, so an upgrade doesn't get blamed for them.
    var knownProblems: Set<String>?
}

@MainActor @Observable
public final class LabController {
    public private(set) var server: ServerController?
    public private(set) var saves: [LabSave] = []
    /// What's happening now. Nil when idle.
    public private(set) var step: String?
    public private(set) var log: [String] = []
    public private(set) var failure: String?
    /// The station running now, for its light.
    public private(set) var running: LabStation?
    private var lastProblems: Set<String> = []
    public var report: RehearsalReport? { state.lastReport }
    /// The chosen server, or the only one, or the first.
    public func model(from servers: [ServerController]) -> ServerController? {
        let real = servers.filter { !$0.isLab }
        return real.first { $0.paths.root.path == state.modelServer } ?? real.first
    }
    public func chooseModel(_ server: ServerController) { state.modelServer = server.paths.root.path }
    public var isBusy: Bool { step != nil }
    public var eulaAccepted: Bool { state.eulaAcceptedAt != nil }
    /// Tells the app which server to list when a wipe or restore replaces it.
    public var onServerChanged: ((_ old: ServerController?, _ new: ServerController?) -> Void)?
    /// Only for tests that run a stand-in jar.
    var bootLimit = 600

    private var state: LabState { didSet { try? JSONStore.save(state, to: LabFiles.state) } }

    public init(existing: ServerController? = nil) {
        state = (try? Data(contentsOf: LabFiles.state)).flatMap { try? JSONStore.decoder.decode(LabState.self, from: $0) } ?? LabState()
        server = existing
        if server == nil, let found = ServerController.open(root: LabFiles.root), LabFiles.isLab(root: found.paths.root, profile: found.profile) { server = found }
        refreshSaves()
    }

    /// Asked for in the Lab's own panel. It lasts for the Lab's rebuilds, which are all the same local test server.
    public func acceptEULA() { state.eulaAcceptedAt = Date() }

    private func say(_ text: String) {
        step = text
        log.append(text)
    }

    private func perform(_ work: () async throws -> Void) async {
        guard !isBusy else { return }
        failure = nil
        log = []
        step = "Starting…"
        defer { step = nil }
        do { try await work() } catch {
            failure = error.localizedDescription
            log.append(error.localizedDescription)
            if let server, server.state.isLive { await shutDown(server) }
        }
    }

    // MARK: Set up, wipe

    /// Creates the Lab. A folder already called lab that isn't one is moved aside, never touched otherwise.
    public func setUp(_ spec: LabSpec) async {
        await perform { _ = try await rebuild(spec) }
    }

    public func setUpWithDefaults() async {
        await perform {
            say("Looking up the newest stable Paper…")
            _ = try await rebuild(try await Self.newestSpec())
        }
    }

    /// Back to a clean seed on the same version and plugins.
    /// Builds the Lab with a real server's version and plugins, all at once.
    public func setUp(modeledOn model: ServerController) async {
        await perform {
            say("Reading \(model.profile.name)'s plugin list…")
            _ = try await rebuild(try await Self.spec(copying: model))
        }
    }

    public func wipeAndStartFresh() async {
        await perform {
            guard let server else { throw LeafError("There's no Lab yet.") }
            say("Reading what the Lab has now…")
            _ = try await rebuild(try await Self.spec(copying: server))
        }
    }

    static func newestSpec() async throws -> LabSpec {
        for mc in try await SoftwareCatalog.versions(.paper) where GameVersion(mc) != nil && !mc.contains("-") {
            if let build = try await SoftwareCatalog.latestBuild(.paper, mc: mc) { return LabSpec(build: build) }
        }
        throw LeafError("Couldn't find a stable Paper build.")
    }

    /// The same software and plugins as another server. Reads its plugin list and jars, and nothing else.
    public static func spec(copying other: ServerController, build chosen: SoftwareBuild? = nil) async throws -> LabSpec {
        await other.refreshPlugins()
        let software = other.profile.software
        let found: SoftwareBuild?
        if let chosen { found = chosen } else { found = try await SoftwareCatalog.latestBuild(software.flavor, mc: software.mcVersion) }
        guard let build = found else { throw LeafError("Couldn't find \(software.flavor.title) \(software.mcVersion) to download.") }
        var sources: [PluginSource] = [], jars: [URL] = []
        var leftOut: [String] = []
        for plugin in other.plugins where plugin.enabled {
            if reachesOutside(plugin) {
                leftOut.append("\(plugin.name) reaches outside this Mac, so it doesn't run here.")
                continue
            }
            let source = other.record(for: plugin).source
            if source.isSet { sources.append(source) } else { jars.append(other.paths.plugins.appendingPathComponent(plugin.fileName)) }
        }
        var spec = LabSpec(build: build, sources: sources, jars: jars)
        spec.leftOut = leftOut
        return spec
    }

    /// Clears the Lab and builds it again from the recipe. Returns notes about anything it couldn't include.
    private func rebuild(_ spec: LabSpec) async throws -> (controller: ServerController, notes: [LabCheck]) {
        guard eulaAccepted else { throw LeafError("The Minecraft EULA has to be accepted before the Lab can run a server.") }
        // Jars first: the Lab's own may be among them, about to be cleared.
        try? FileManager.default.removeItem(at: LabFiles.scratch)
        try FileOps.ensureDir(LabFiles.scratch)
        defer { try? FileManager.default.removeItem(at: LabFiles.scratch) }
        var kept: [URL] = []
        for jar in spec.jars where FileOps.exists(jar) {
            let copy = LabFiles.scratch.appendingPathComponent(jar.lastPathComponent)
            try FileManager.default.copyItem(at: jar, to: copy)
            kept.append(copy)
        }
        let old = server
        let identity = old?.profile.id
        try await clearFolder()

        say("Installing \(spec.build.flavor.title) \(spec.build.label)…")
        let root = LabFiles.root
        try FileOps.ensureDir(root)
        try FileOps.writeAtomic(LabRecipe.properties(port: Trial.freePort(after: 25579)), to: root.appendingPathComponent("server.properties"))
        var profile = ServerProfile()
        profile.id = identity ?? UUID()
        profile.isLab = true
        profile.name = "Lab"
        profile.backup.enabled = false
        profile.backup.autoDrill = false
        profile.backup.destination = ServerPaths(root: root).meta.appendingPathComponent("backups").path
        profile.restart.enabled = false
        profile.playerSnapshots.enabled = false
        profile.lastPluginCheck = Date()
        profile.software.lastCheck = Date()
        profile.software.flavor = spec.build.flavor
        profile.launch.restartOnCrash = false
        profile.launch.startWithApp = false
        profile.launch.keepAwake = false
        profile.launch.logGC = false
        profile.launch.maxMemoryMB = min(2048, SystemInfo.memoryMB / 2)
        profile.launch.minMemoryMB = min(1024, profile.launch.maxMemoryMB)
        try FileOps.ensureDir(ServerPaths(root: root).meta)
        try JSONStore.save(profile, to: ServerPaths(root: root).profile)
        let c = ServerController(root: root, profile: profile)
        c.isTrialCopy = true
        c.requiresEULA = old?.requiresEULA ?? c.requiresEULA
        try EULA.accept(c.paths)
        server = c
        onServerChanged?(old, c)
        try await c.installSoftware(spec.build)

        var notes: [LabCheck] = []
        for source in spec.sources {
            say("Adding \(source.summary)…")
            do { try await c.addPlugin(source: source) }
            catch { notes.append(LabCheck("Plugin available for \(spec.build.mcVersion): \(source.summary)", .failed, error.localizedDescription)) }
        }
        try FileOps.ensureDir(c.paths.plugins)
        for jar in kept { try FileManager.default.copyItem(at: jar, to: c.paths.plugins.appendingPathComponent(jar.lastPathComponent)) }
        await c.refreshPlugins()
        try await seed(c)
        return (c, notes)
    }

    /// The one place the Lab's folder is deleted. Checks what's on disk, not what's in memory.
    private func clearFolder() async throws {
        let root = LabFiles.root
        if let server {
            guard !server.state.isLive else { throw LeafError("Stop the Lab first.") }
            await server.detectExternalServer()
            if case .external = server.state { throw LeafError("The Lab is running outside Leaf Juice. Stop it first.") }
        }
        guard FileOps.exists(root) else { return }
        guard let onDisk = ServerController.readProfile(root: root), LabFiles.isLab(root: root, profile: onDisk) else {
            // Someone's folder that happens to be called lab. Keep it, under another name.
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd-HHmmss"
            let aside = root.deletingLastPathComponent().appendingPathComponent("lab-previous-\(f.string(from: Date()))", isDirectory: true)
            try FileManager.default.moveItem(at: root, to: aside)
            log.append("A folder called lab already existed and isn't a Lab. It's now \(aside.lastPathComponent).")
            return
        }
        server?.stopTicker()
        try FileManager.default.removeItem(at: root)
    }

    // MARK: Seed

    private func table(_ c: ServerController) async -> ProtocolTable? {
        guard let java = c.resolvedJava()?.path else { return nil }
        return try? await ProtocolTable.load(mc: c.profile.software.mcVersion, cache: LabFiles.protocols, java: java)
    }

    private func boot(_ c: ServerController) async throws {
        await prepareJava(c)
        await c.start()
        if !c.blockers.isEmpty { throw LeafError(c.blockers.map(\.title).joined(separator: ", ")) }
        for _ in 0..<(bootLimit * 4) {
            if c.state == .running || c.state.canStart { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard c.state == .running else {
            let lines = c.console.filter { $0.level >= .warn }.suffix(3).map(\.text).joined(separator: " ")
            throw LeafError("It didn't finish starting. \(lines)")
        }
    }

    /// A rehearsal may well need a newer Java than this Mac has.
    private func prepareJava(_ c: ServerController) async {
        if c.runtimes.isEmpty { c.runtimes = await JavaManager.discover() }
        let needed = c.javaRequirement
        if JavaManager.best(for: needed, in: c.runtimes) == nil, c.profile.launch.javaPath == nil {
            say("Downloading Java \(needed)…")
            try? await c.installJava(major: needed)
        }
    }

    private func shutDown(_ c: ServerController) async {
        if c.state == .running || c.state == .starting { c.stop() }
        for _ in 0..<(120 * 4) where c.state.isLive { try? await Task.sleep(for: .milliseconds(250)) }
        if c.state.isLive { c.forceStop(); try? await Task.sleep(for: .seconds(1)) }
    }

    private func ask(_ c: ServerController, _ command: String, expecting needle: String, seconds: Int = 10) async -> String? {
        let start = c.console.last?.id ?? -1
        c.send(command)
        for _ in 0..<(seconds * 4) {
            try? await Task.sleep(for: .milliseconds(250))
            if let line = c.console.first(where: { $0.id > start && $0.origin == .server && $0.text.contains(needle) }) { return line.text }
        }
        return nil
    }

    private func join(_ name: String, _ c: ServerController, _ table: ProtocolTable) async -> Bot? {
        guard let bot = try? Bot(name: name, port: c.serverPort, table: table) else { return nil }
        for _ in 0..<(40 * 4) {
            if c.players.contains(name) { try? await Task.sleep(for: .milliseconds(500)); return bot }
            try? await Task.sleep(for: .milliseconds(250))
        }
        bot.leave()
        return nil
    }

    private func leave(_ bot: Bot, _ c: ServerController) async {
        bot.leave()
        for _ in 0..<(20 * 4) where c.players.contains(bot.name) { try? await Task.sleep(for: .milliseconds(250)) }
    }

    /// Observed: a fixed wait after a teleport is sometimes too short with many plugins, which looks like lost items.
    /// So this waits for the player to arrive.
    private func travel(_ c: ServerController, to world: String) async -> Bool {
        let target = world == "world" ? "overworld" : world
        c.send("mv tp Alice \(world)")
        for _ in 0..<20 {
            try? await Task.sleep(for: .seconds(1))
            if let line = await ask(c, "data get entity Alice Dimension", expecting: "entity data", seconds: 2), line.contains(target) {
                // The plugin swaps inventories as part of arriving.
                try? await Task.sleep(for: .seconds(1))
                return true
            }
        }
        return false
    }

    /// The inventory line, once it has the item or after a few tries.
    private func inventory(_ c: ServerController, holding item: String) async -> String? {
        var last: String?
        for _ in 0..<5 {
            last = await ask(c, "data get entity Alice Inventory", expecting: "entity data", seconds: 3) ?? last
            if last?.contains(item) == true { return last }
            try? await Task.sleep(for: .seconds(1))
        }
        return last
    }

    private func hasPlugin(_ c: ServerController, _ key: String) -> Bool {
        c.plugins.contains { $0.enabled && $0.key == key }
    }

    /// Worlds and players, so the checks have something real to look at.
    private func seed(_ c: ServerController) async throws {
        say("Starting the Lab for the first time…")
        try await boot(c)
        if hasPlugin(c, "multiverse-core") {
            for recipe in LabRecipe.worlds {
                say("Creating the \(recipe.name) world…")
                var world = NewWorld()
                world.name = recipe.name; world.environment = recipe.environment; world.type = recipe.type
                try? await c.createWorld(world)
            }
        }
        if let table = await table(c) {
            say("Players joining…")
            var bots: [Bot] = []
            for name in LabRecipe.players { if let bot = await join(name, c, table) { bots.append(bot) } }
            for (who, item, count) in [("Alice", "diamond", 5), ("Alice", "golden_apple", 2), ("Bob", "emerald", 9), ("Carol", "netherite_ingot", 1)] {
                _ = await ask(c, "give \(who) minecraft:\(item) \(count)", expecting: "Gave ")
            }
            if hasPlugin(c, "multiverse-core") {
                _ = await travel(c, to: "mining")
                _ = await ask(c, "give Alice minecraft:iron_ingot 7", expecting: "Gave ")
                _ = await travel(c, to: "world")
            }
            // A fixed place, not beside a player: anything that moves a player mustn't look like lost blocks.
            _ = await ask(c, "forceload add 0 0", expecting: "orce", seconds: 3)
            _ = await ask(c, "setblock 0 100 0 minecraft:gold_block", expecting: "Changed the block")
            for bot in bots { await leave(bot, c) }
            c.profile.labSeededPlayers = !bots.isEmpty
        } else {
            log.append("No bot players on Minecraft \(c.profile.software.mcVersion). Its data generator doesn't describe the network packets.")
            c.profile.labSeededPlayers = false
        }
        say("Saving the seed…")
        await shutDown(c)
        c.profile.labSeededAt = Date()
    }

    // MARK: Scripted checks

    /// The same script on both paths: that's what makes their results comparable.
    /// `known` problems were already reported. They're left out, or shown as not new, so nothing gets blamed twice.
    /// `underSettings`: inventories are handed out again first. Observed: real Multiverse-Inventories settings can load a
    /// different profile on join, so what the seed saved under fresh settings says nothing about them.
    private func runChecks(_ c: ServerController, known: Set<String> = [], reportKnown: Bool = true, underSettings: Bool = false) async -> [LabCheck] {
        lastProblems = []
        func problems(since: Date) -> [LabCheck] {
            var out: [LabCheck] = []
            for issue in c.issues where issue.lastSeen >= since && issue.severity >= .error {
                let key = "\(issue.ruleID ?? issue.id)|\(issue.plugin ?? "")"
                let title = issue.plugin.map { "\($0): \(issue.title)" } ?? issue.title
                if known.contains(key) {
                    if reportKnown { out.append(LabCheck(title, .skipped, "It does this on your current version too, so it isn't new.")) }
                    continue
                }
                lastProblems.insert(key)
                out.append(LabCheck(issue.count > 1 ? "\(title) (\(issue.count) times)" : title, .failed, String(issue.sample.prefix(200))))
            }
            return out
        }
        var out: [LabCheck] = []
        let bootStart = Date()
        let firstLine = c.console.last?.id ?? -1
        say("Starting on \(c.profile.software.label)…")
        do {
            try await boot(c)
            out.append(LabCheck("Starts", .passed, "In \(Int(Date().timeIntervalSince(bootStart))) seconds"))
        } catch {
            out.append(LabCheck("Starts", .failed, error.localizedDescription))
            out += problems(since: bootStart)
            if c.state.isLive { await shutDown(c) }
            return out
        }
        if c.requiresEULA { try? await Task.sleep(for: .seconds(3)) }

        say("Checking plugins…")
        let enabled = c.console.filter { $0.id > firstLine }
        for plugin in c.plugins where plugin.enabled && plugin.descriptor != nil {
            let ok = enabled.contains { $0.text.contains("Enabling \(plugin.name)") }
            out.append(LabCheck("\(plugin.name) \(plugin.version) loads", ok ? .passed : .failed, ok ? "" : "It was never enabled."))
        }

        if hasPlugin(c, "multiverse-core") {
            let start = c.console.last?.id ?? -1
            c.send("mv list")
            try? await Task.sleep(for: .seconds(2))
            let lines = c.console.filter { $0.id > start }.map(\.text).joined(separator: " ")
            let missing = LabRecipe.worlds.map(\.name).filter { !lines.contains($0) }
            out.append(LabCheck("All worlds are listed", missing.isEmpty ? .passed : .failed, missing.isEmpty ? LabRecipe.worlds.map(\.name).joined(separator: ", ") : "Missing: \(missing.joined(separator: ", "))"))
        } else {
            out.append(LabCheck("All worlds are listed", .skipped, "Multiverse isn't installed."))
        }

        let seededPlayers = c.profile.labSeededPlayers
        if seededPlayers, let table = await table(c) {
            say("Players joining…")
            if underSettings, let first = await join("Alice", c, table) {
                _ = await ask(c, "clear Alice", expecting: "Alice", seconds: 3)
                _ = await ask(c, "give Alice minecraft:diamond 5", expecting: "Gave ")
                if hasPlugin(c, "multiverse-inventories") {
                    _ = await travel(c, to: "mining")
                    _ = await ask(c, "give Alice minecraft:iron_ingot 7", expecting: "Gave ")
                    _ = await travel(c, to: "world")
                }
                await leave(first, c)
                await shutDown(c)
                try? await boot(c)
            }
            if let bot = await join("Alice", c, table) {
                out.append(LabCheck("A player can join", .passed))
                let held = await inventory(c, holding: "minecraft:diamond")
                let hasItems = held?.contains("minecraft:diamond") == true
                out.append(LabCheck("Inventory came through", hasItems ? .passed : .failed, hasItems ? "" : String((held ?? "No answer").prefix(160))))
                if hasPlugin(c, "multiverse-inventories") {
                    let arrived = await travel(c, to: "mining")
                    let there = arrived ? await inventory(c, holding: "minecraft:iron_ingot") : nil
                    let ok = there?.contains("minecraft:iron_ingot") == true
                    out.append(LabCheck("Per-world inventory came through", ok ? .passed : .failed, ok ? "" : arrived ? String((there ?? "No answer").prefix(160)) : "The player never arrived in the other world."))
                    _ = await travel(c, to: "world")
                } else {
                    out.append(LabCheck("Per-world inventory came through", .skipped, "Multiverse-Inventories isn't installed."))
                }
                let block = await ask(c, "execute if block 0 100 0 minecraft:gold_block", expecting: "Test passed", seconds: 5)
                out.append(LabCheck("A block placed earlier is still there", block != nil ? .passed : .failed))
                // Cleared first: placing what's already there reports no change, and the Lab reruns this.
                _ = await ask(c, "setblock 1 100 0 minecraft:air", expecting: "lock", seconds: 3)
                let placed = await ask(c, "setblock 1 100 0 minecraft:emerald_block", expecting: "Changed the block")
                await leave(bot, c)
                say("Stopping and starting again…")
                let stopStart = Date()
                await shutDown(c)
                let cleanly = c.state == .stopped
                out.append(LabCheck("Stops cleanly", cleanly ? .passed : .failed, Self.took(stopStart)))
                do {
                    try await boot(c)
                    if placed != nil, let again = await join("Alice", c, table) {
                        let still = await ask(c, "execute if block 1 100 0 minecraft:emerald_block", expecting: "Test passed", seconds: 5)
                        out.append(LabCheck("A change survives a restart", still != nil ? .passed : .failed))
                        await leave(again, c)
                    } else {
                        out.append(LabCheck("A change survives a restart", .failed, "The player couldn't rejoin, or the block wasn't placed."))
                    }
                } catch {
                    out.append(LabCheck("A change survives a restart", .failed, error.localizedDescription))
                }
            } else {
                out.append(LabCheck("A player can join", .failed, "Alice couldn't get in."))
            }
        } else {
            let why = seededPlayers ? "The packet list for this version couldn't be made." : "Bot players don't work on this Minecraft version."
            for title in ["A player can join", "Inventory came through", "A change survives a restart"] { out.append(LabCheck(title, .skipped, why)) }
        }
        if c.state.isLive {
            let stopStart = Date()
            await shutDown(c)
            if !out.contains(where: { $0.title == "Stops cleanly" }) {
                out.append(LabCheck("Stops cleanly", c.state == .stopped ? .passed : .failed, Self.took(stopStart)))
            }
        }
        // Last, so errors from the restart count too.
        out += problems(since: bootStart)
        return out
    }

    private static func took(_ start: Date) -> String {
        let seconds = Date().timeIntervalSince(start)
        return seconds < 2 ? "" : "In \(Int(seconds)) seconds"
    }

    // MARK: Rehearsal

    /// The whole rehearsal in one go: upgrade, then fresh, then optionally settings. The board runs these one at a time.
    public func rehearse(for target: ServerController, to build: SoftwareBuild, withSettings: Bool = false) async {
        chooseTarget(build)
        await perform {
            try await stationUpgrade(target)
            try await stationFresh(target)
            if withSettings, state.board[.fresh]?.outcome == .passed { try await stationFreshSettings(target) }
        }
    }

    // MARK: The board

    /// What a light shows for a station, given what's been run and whether it still applies.
    public func light(_ station: LabStation, model: ServerController) -> StationLight {
        if running == station { return .running }
        let print = fingerprint(model)
        if let found = state.board[station] {
            if found.fingerprint != print { return .stale }
            return found.outcome == .passed ? .passed : .failed(acknowledged: found.acknowledged)
        }
        if let reason = lockReason(station, fingerprint: print) { return .locked(reason) }
        return .ready
    }

    public func result(_ station: LabStation) -> StationResult? { state.board[station] }
    public var target: SoftwareBuild? { state.target }
    public func chooseTarget(_ build: SoftwareBuild) {
        guard state.target != build else { return }
        state.target = build
        for later in LabStation.allCases where later.dependsOnTarget { state.board[later] = nil }
    }

    private func settled(_ station: LabStation, _ print: String) -> Bool {
        guard let found = state.board[station], found.fingerprint == print else { return false }
        return found.outcome == .passed || found.acknowledged
    }

    private func lockReason(_ station: LabStation, fingerprint print: String) -> String? {
        switch station {
        case .plugins: return nil
        case .settings: return settled(.plugins, print) ? nil : "Waiting for \(LabStation.plugins.title.lowercased())"
        case .upgrade:
            if !settled(.plugins, print) { return "Waiting for \(LabStation.plugins.title.lowercased())" }
            return state.target == nil ? "Choose a version" : nil
        case .fresh:
            // Finished is enough: an upgrade that failed and a fresh install that passes says where the problem is.
            guard let done = state.board[.upgrade], done.fingerprint == print else { return "Waiting for \(LabStation.upgrade.title.lowercased())" }
            return nil
        case .freshSettings: return settled(.fresh, print) ? nil : "Waiting for \(LabStation.fresh.title.lowercased())"
        }
    }

    /// Whatever could change the answer: the version, the target, and which plugins exactly.
    func fingerprint(_ model: ServerController) -> String {
        let plugins = model.plugins.filter(\.enabled).map { "\($0.key)=\($0.digests?.sha1 ?? $0.version)" }.sorted()
        return ([model.paths.root.path, model.profile.software.label] + plugins).joined(separator: "|")
    }

    /// Flicking a switch off: forget this and everything that relied on it.
    public func clear(_ station: LabStation) {
        for other in LabStation.allCases where other == station || other.follows(station) { state.board[other] = nil }
        if station == .upgrade || station == .fresh || station == .freshSettings { state.lastReport = nil }
    }

    /// For tests of the locks, which don't need real servers.
    func place(_ station: LabStation, outcome: StationResult.Outcome, model: ServerController, checks: [LabCheck] = [], groups: [MirrorBatch] = [], note: String = "", leftOut: [String] = []) {
        state.board[station] = StationResult(outcome: outcome, fingerprint: fingerprint(model), checks: checks, groups: groups, note: note, leftOut: leftOut)
        if station == .fresh { updateReport(model) }
    }

    /// Unlocks the next switch despite a red light. The light stays red.
    public func continueAnyway(_ station: LabStation) { state.board[station]?.acknowledged = true }

    /// Flicking a switch on.
    public func run(_ station: LabStation, model: ServerController) async {
        guard !isBusy, lockReason(station, fingerprint: fingerprint(model)) == nil else { return }
        for other in LabStation.allCases where other == station || other.follows(station) { state.board[other] = nil }
        running = station
        defer { running = nil }
        await perform {
            switch station {
            case .plugins: try await stationPlugins(model)
            case .settings: try await stationSettings(model)
            case .upgrade: try await stationUpgrade(model)
            case .fresh: try await stationFresh(model)
            case .freshSettings: try await stationFreshSettings(model)
            }
        }
        // A station that couldn't even begin still needs a red light.
        if state.board[station] == nil, let failure {
            state.board[station] = StationResult(outcome: .failed, fingerprint: fingerprint(model), checks: [LabCheck("It couldn't finish", .failed, failure)])
        }
    }

    private func record(_ station: LabStation, model: ServerController, checks: [LabCheck] = [], groups: [MirrorBatch] = [], note: String = "", leftOut: [String] = []) {
        let failed = checks.contains { $0.outcome == .failed } || groups.contains { $0.outcome != .passed }
        state.board[station] = StationResult(outcome: failed ? .failed : .passed, fingerprint: fingerprint(model), checks: checks, groups: groups, note: note, leftOut: leftOut)
    }

    /// The server's own version, its exact jars, a few at a time, with fresh settings.
    private func stationPlugins(_ model: ServerController) async throws {
        say("Reading \(model.profile.name)'s plugin list…")
        let spec = try await Self.spec(copying: model)
        let enabled = model.plugins.filter(\.enabled)
        let groups = PluginThemes.batches(enabled.filter { !Self.reachesOutside($0) })
        var out: [MirrorBatch] = []
        var seen: Set<String> = []
        var lab: ServerController?
        if groups.isEmpty { lab = try await rebuild(LabSpec(build: spec.build, sources: [], jars: [])).controller }
        for (index, group) in groups.enumerated() {
            var batch = MirrorBatch(title: group.title, plugins: group.plugins.map(\.name))
            let jars = group.plugins.map { model.paths.plugins.appendingPathComponent($0.fileName) }
            if lab == nil {
                say("Building the Lab with \(group.title.lowercased())…")
                lab = try await rebuild(LabSpec(build: spec.build, sources: [], jars: jars)).controller
            } else if let lab {
                try FileOps.ensureDir(lab.paths.plugins)
                for jar in jars { try FileManager.default.copyItem(at: jar, to: lab.paths.plugins.appendingPathComponent(jar.lastPathComponent)) }
                await lab.refreshPlugins()
            }
            guard let lab else { continue }
            say("Group \(index + 1) of \(groups.count): \(group.title)…")
            batch.fresh = await runChecks(lab, known: seen, reportKnown: false)
            seen.formUnion(lastProblems)
            // Take out what didn't load, so it doesn't get blamed for the next group too.
            for plugin in group.plugins where batch.fresh.contains(where: { $0.outcome == .failed && $0.title.hasPrefix("\(plugin.name) ") }) {
                let jar = lab.paths.plugins.appendingPathComponent(plugin.fileName)
                try? FileManager.default.moveItem(at: jar, to: jar.appendingPathExtension("disabled"))
                batch.notes.append("\(plugin.name) was taken out before the next group.")
            }
            await lab.refreshPlugins()
            out.append(batch)
        }
        state.knownProblems = seen
        record(.plugins, model: model, groups: out, note: model.profile.software.label, leftOut: spec.leftOut)
    }

    /// The same groups, now with the real settings. Back to fresh afterwards, so later stations aren't affected.
    private func stationSettings(_ model: ServerController) async throws {
        guard let lab = server else { throw LeafError("There's no Lab yet.") }
        guard lab.state.canStart else { throw LeafError("Stop the Lab first.") }
        await lab.refreshPlugins()
        // Observed: settings change world and player data as well as files in plugins/, so each group gets a clean copy.
        let baseline = LabFiles.scratch.appendingPathComponent("baseline", isDirectory: true)
        try? FileManager.default.removeItem(at: baseline)
        try FileOps.ensureDir(LabFiles.scratch)
        try await Trial.clone(lab.paths.root, to: baseline)
        defer { try? FileManager.default.removeItem(at: baseline) }
        func backToBaseline() async throws {
            for child in FileOps.children(lab.paths.root) where child.lastPathComponent != ".leafjuice" { try FileManager.default.removeItem(at: child) }
            for child in FileOps.children(baseline) where child.lastPathComponent != ".leafjuice" {
                try await Trial.clone(child, to: lab.paths.root.appendingPathComponent(child.lastPathComponent))
            }
            await lab.refreshPlugins()
        }
        let groups = PluginThemes.batches(lab.plugins.filter(\.enabled))
        var out: [MirrorBatch] = []
        var seen = state.knownProblems ?? []
        for (index, group) in groups.enumerated() {
            var batch = MirrorBatch(title: group.title, plugins: group.plugins.map(\.name))
            say("Group \(index + 1) of \(groups.count): \(group.title), with \(model.profile.name)'s settings…")
            batch.notes += try Self.copySettings(from: model.paths, to: lab.paths, plugins: group.plugins.map(\.name))
            batch.withSettings = await runChecks(lab, known: seen, reportKnown: false, underSettings: true)
            seen.formUnion(lastProblems)
            try await backToBaseline()
            out.append(batch)
        }
        record(.settings, model: model, groups: out, note: "World lists and player data stay the Lab's own.")
    }

    /// The Lab's existing data moved to the new version, with updated plugins.
    private func stationUpgrade(_ model: ServerController) async throws {
        guard let build = state.target, let to = GameVersion(build.mcVersion) else { throw LeafError("Choose a version first.") }
        say("Reading \(model.profile.name)'s plugin list…")
        let current = try await Self.spec(copying: model)
        var checks = current.leftOut.map { LabCheck($0, .skipped) }
        var route: String
        if let lab = server, lab.profile.labSeededAt != nil, let version = lab.profile.software.gameVersion, version < to || version == to && lab.profile.software.build != build.build {
            route = "Kept the Lab's data from \(lab.profile.software.label), then moved it to \(build.label)"
        } else {
            say("Building a Lab on \(current.build.label), the version you're on now…")
            checks += try await rebuild(current).notes
            route = "New seed on \(current.build.label), then moved it to \(build.label)"
        }
        guard let lab = server else { throw LeafError("There's no Lab.") }
        do {
            say("Moving to \(build.label) with updated plugins…")
            try await upgrade(lab, to: build, adding: current, model: model, notes: &checks)
            checks += await runChecks(lab, known: state.knownProblems ?? [])
        } catch {
            checks.append(LabCheck("Upgrades", .failed, error.localizedDescription))
            route += ". It didn't get that far"
        }
        if lab.state.isLive { await shutDown(lab) }
        record(.upgrade, model: model, checks: checks, note: route)
    }

    /// Wiped, new on the target version, seeded, with the same checks.
    private func stationFresh(_ model: ServerController) async throws {
        guard let build = state.target else { throw LeafError("Choose a version first.") }
        say("Wiping the Lab for a fresh install…")
        var spec = try await Self.spec(copying: model)
        spec.build = build
        var checks = spec.leftOut.map { LabCheck($0, .skipped) }
        do {
            let built = try await rebuild(spec)
            checks += built.notes
            checks += await runChecks(built.controller, known: state.knownProblems ?? [])
        } catch {
            checks.append(LabCheck("Installs", .failed, error.localizedDescription))
        }
        if let server, server.state.isLive { await shutDown(server) }
        record(.fresh, model: model, checks: checks, note: "Wiped the Lab, installed \(build.label), then seeded it")
        updateReport(model)
    }

    /// Run only after fresh passes, so a failure can only be the settings.
    private func stationFreshSettings(_ model: ServerController) async throws {
        guard let lab = server else { throw LeafError("There's no Lab.") }
        say("Trying \(model.profile.name)'s plugin settings…")
        var checks = try Self.copySettings(from: model.paths, to: lab.paths, plugins: lab.plugins.filter(\.enabled).map(\.name)).map { LabCheck($0, .skipped) }
        checks += await runChecks(lab, known: state.knownProblems ?? [], underSettings: true)
        if lab.state.isLive { await shutDown(lab) }
        record(.freshSettings, model: model, checks: checks, note: "The fresh install, given \(model.profile.name)'s plugin settings")
        updateReport(model)
    }

    private func updateReport(_ model: ServerController) {
        guard let upgrade = state.board[.upgrade], let fresh = state.board[.fresh], let build = state.target else { return }
        func path(_ title: String, _ r: StationResult) -> RehearsalPath { RehearsalPath(title: title, route: r.note, checks: r.checks) }
        state.lastReport = RehearsalReport(date: Date(), serverName: model.profile.name, from: model.profile.software.label, to: "\(build.flavor.title) \(build.label)", migrated: path("Upgrade", upgrade), fresh: path("Fresh install", fresh), withSettings: state.board[.freshSettings].map { path("With your settings", $0) })
    }

    private func upgrade(_ lab: ServerController, to build: SoftwareBuild, adding spec: LabSpec, model: ServerController, notes: inout [LabCheck]) async throws {
        try await lab.installSoftware(build)
        if let held = lab.pending.compactMap(\.conflict).first { throw LeafError(held) }
        await lab.refreshPlugins()
        // Jars copied from the real server arrive without knowing where they came from, so updates need telling.
        for plugin in lab.plugins where !lab.record(for: plugin).source.isSet {
            if let original = model.plugins.first(where: { $0.key == plugin.key }) {
                let record = model.record(for: original)
                if record.source.isSet { lab.adoptRecord(record, key: plugin.key) }
            }
        }
        let have = lab.plugins.map { lab.record(for: $0).source }
        for source in spec.sources where !have.contains(where: { $0 == source }) {
            do { try await lab.addPlugin(source: source) }
            catch { notes.append(LabCheck("Plugin available for \(build.mcVersion): \(source.summary)", .failed, error.localizedDescription)) }
        }
        try FileOps.ensureDir(lab.paths.plugins)
        for jar in spec.jars where FileOps.exists(jar) && !FileOps.exists(lab.paths.plugins.appendingPathComponent(jar.lastPathComponent)) {
            try FileManager.default.copyItem(at: jar, to: lab.paths.plugins.appendingPathComponent(jar.lastPathComponent))
        }
        await lab.refreshPlugins()
        await lab.checkPluginUpdates()
        for plugin in lab.plugins where lab.record(for: plugin).available != nil {
            do { try await lab.installUpdate(for: plugin) }
            catch { notes.append(LabCheck("\(plugin.name) updates", .failed, error.localizedDescription)) }
        }
        await lab.refreshPlugins()
        lab.keepUpgrade()
    }

    // MARK: Saved incarnations

    public func refreshSaves() {
        saves = FileOps.children(LabFiles.saves).filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONStore.decoder.decode(LabSave.self, from: $0) } }
            .filter { FileOps.exists(LabFiles.saves.appendingPathComponent($0.fileName)) }
            .sorted { $0.date > $1.date }
    }

    static func sidecar(_ fileName: String) -> URL {
        LabFiles.saves.appendingPathComponent(fileName.replacingOccurrences(of: ".tar.gz", with: ".json"))
    }

    /// Keeps this Lab, named so it can be recognized later. Only while stopped, so nothing changes mid-copy.
    public func save(note: String) async {
        await perform {
            guard let server else { throw LeafError("There's no Lab yet.") }
            guard server.state.canStart else { throw LeafError("Stop the Lab before saving it.") }
            say("Saving the Lab…")
            try FileOps.ensureDir(LabFiles.saves)
            let now = Date()
            var name = LabFiles.saveName(date: now, software: server.profile.software, note: note)
            var n = 2
            while FileOps.exists(LabFiles.saves.appendingPathComponent(name)) {
                name = LabFiles.saveName(date: now, software: server.profile.software, note: note).replacingOccurrences(of: ".tar.gz", with: "-\(n).tar.gz")
                n += 1
            }
            let file = LabFiles.saves.appendingPathComponent(name)
            let part = file.appendingPathExtension("part")
            defer { try? FileManager.default.removeItem(at: part) }
            let packed = try await Tool.run("/usr/bin/tar", ["-czf", part.path, "--exclude", "./.leafjuice/backups", "--exclude", "./.leafjuice/staged", "--exclude", "./logs", "-C", server.paths.root.path, "."])
            guard packed.ok else { throw LeafError("Couldn't save the Lab. \(packed.err.prefix(200))") }
            let listed = try await Tool.run("/usr/bin/tar", ["-tzf", part.path])
            guard listed.ok, listed.out.contains("server.properties"), listed.out.contains(".leafjuice/server.json") else { throw LeafError("The saved file didn't read back correctly.") }
            try FileOps.move(part, to: file)
            await server.refreshPlugins()
            let record = LabSave(fileName: name, date: now, note: note, software: server.profile.software.label, plugins: server.plugins.filter(\.enabled).map(\.name), size: FileOps.size(file))
            try JSONStore.save(record, to: Self.sidecar(name))
            refreshSaves()
        }
    }

    /// Replaces the Lab with a saved one.
    public func restore(_ saved: LabSave) async {
        await perform {
            let archive = LabFiles.saves.appendingPathComponent(saved.fileName)
            guard FileOps.exists(archive) else { throw LeafError("That save is missing.") }
            say("Checking the save…")
            let listed = try await Tool.run("/usr/bin/tar", ["-tzf", archive.path])
            guard listed.ok else { throw LeafError("That save can't be read. The Lab hasn't been touched.") }
            say("Restoring \(saved.note.isEmpty ? saved.software : saved.note)…")
            let old = server
            try await clearFolder()
            try FileOps.ensureDir(LabFiles.root)
            let result = try await Tool.run("/usr/bin/tar", ["-xzf", archive.path, "-C", LabFiles.root.path])
            guard result.ok else { throw LeafError("Couldn't unpack the save. \(result.err.prefix(200))") }
            guard let restored = ServerController.open(root: LabFiles.root), LabFiles.isLab(root: restored.paths.root, profile: restored.profile) else {
                throw LeafError("That save isn't a Lab.")
            }
            restored.requiresEULA = old?.requiresEULA ?? restored.requiresEULA
            server = restored
            onServerChanged?(old, restored)
            await restored.refreshPlugins()
        }
    }

    public func deleteSave(_ saved: LabSave) throws {
        try FileManager.default.removeItem(at: LabFiles.saves.appendingPathComponent(saved.fileName))
        try? FileManager.default.removeItem(at: Self.sidecar(saved.fileName))
        refreshSaves()
    }
}

// MARK: - Modeling the Lab on a real server

/// Groups plugins so a failure points at a few of them rather than all of them.
public enum PluginThemes {
    /// Goes first, because the seed needs worlds and permissions to exist.
    static let themes: [(title: String, keys: Set<String>)] = [
        ("Worlds and permissions", ["multiverse-core", "multiverse-inventories", "luckperms", "vault", "worldedit", "fastasyncworldedit", "worldguard"]),
        ("Libraries and compatibility", ["protocollib", "placeholderapi", "bkcommonlib", "nashornjs", "viaversion", "viabackwards", "viarewind", "packetevents", "citizenscmd", "nbtapi", "decentholograms"]),
        ("Travel and building", ["multiverse-portals", "multiverse-netherportals", "multiverse-signportals", "tardis", "elevator", "animatedarchitecture", "chunky", "chunkyborder", "lightcleaner", "worldborder", "plotsquared", "griefprevention", "coreprotect"]),
        ("Gameplay", ["auraskills", "mcmmo", "levelledmobs", "magic", "citizens", "lootchest", "silkspawners_v2", "silkspawners", "deathmessages", "mythicmobs", "jobs", "shopkeepers", "towny"]),
        ("Everyday comforts", ["essentials", "chestsort", "angelchest", "gsit", "lumberjack", "treeassist", "veinminer", "tweaky", "actionhealth", "chococoords"]),
    ]
    /// A few at a time.
    static let batchSize = 6

    public struct Batch: Equatable, Sendable {
        public var title: String
        public var plugins: [InstalledPlugin]
    }

    public static func batches(_ plugins: [InstalledPlugin]) -> [Batch] {
        var remaining = plugins.sorted { $0.key < $1.key }
        var out: [Batch] = []
        func add(_ title: String, _ members: [InstalledPlugin]) {
            let chunks = stride(from: 0, to: members.count, by: batchSize).map { Array(members[$0..<min($0 + batchSize, members.count)]) }
            for (index, chunk) in chunks.enumerated() {
                out.append(Batch(title: chunks.count > 1 ? "\(title) \(index + 1)" : title, plugins: chunk))
            }
        }
        for theme in themes {
            let members = remaining.filter { theme.keys.contains($0.key) }
            remaining.removeAll { theme.keys.contains($0.key) }
            add(theme.title, members)
        }
        add("Everything else", remaining)
        // A plugin can't load before what it needs, so anything needed earlier moves earlier.
        var changed = true
        while changed {
            changed = false
            for (index, batch) in out.enumerated() {
                let needed = Set(batch.plugins.flatMap { $0.descriptor?.depend ?? [] }.map { $0.lowercased() })
                for later in out.indices where later > index {
                    let moving = out[later].plugins.filter { needed.contains($0.key) }
                    if !moving.isEmpty {
                        out[index].plugins += moving
                        out[later].plugins.removeAll { needed.contains($0.key) }
                        changed = true
                    }
                }
            }
        }
        return out.filter { !$0.plugins.isEmpty }
    }
}

public struct MirrorBatch: Codable, Identifiable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case passed, pluginProblem, settingsProblem }
    public var id: String { title }
    public var title: String
    public var plugins: [String]
    /// Empty on the settings station, which has already passed these.
    public var fresh: [LabCheck] = []
    /// Nil when settings weren't tried.
    public var withSettings: [LabCheck]?
    public var notes: [String] = []

    public var outcome: Outcome {
        if fresh.contains(where: { $0.outcome == .failed }) { return .pluginProblem }
        if withSettings?.contains(where: { $0.outcome == .failed }) == true { return .settingsProblem }
        return .passed
    }
}

/// One row of the board.
public enum LabStation: String, Codable, CaseIterable, Identifiable, Sendable {
    case plugins, settings, upgrade, fresh, freshSettings
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .plugins: "Plugins load"
        case .settings: "Your plugin settings"
        case .upgrade: "Upgrade"
        case .fresh: "Fresh install"
        case .freshSettings: "New version with your settings"
        }
    }
    public var summary: String {
        switch self {
        case .plugins: "Rebuilds the Lab on your current version and adds your plugins a few at a time, with fresh settings. Anything unsaved in the Lab is lost."
        case .settings: "The same plugins with your real settings. A failure here is a settings problem, because fresh ones passed."
        case .upgrade: "Moves the Lab's data to the new version, with updated plugins."
        case .fresh: "Wipes the Lab and installs the new version from nothing, with the same checks."
        case .freshSettings: "The fresh install, given your real plugin settings."
        }
    }
    public var isOptional: Bool { self == .settings || self == .freshSettings }
    var dependsOnTarget: Bool { self == .upgrade || self == .fresh || self == .freshSettings }
    /// Whether this station's answer relies on the other's.
    func follows(_ other: LabStation) -> Bool {
        switch other {
        case .plugins: self != .plugins
        case .settings: false
        case .upgrade: self == .fresh || self == .freshSettings
        case .fresh: self == .freshSettings
        case .freshSettings: false
        }
    }
}

public struct StationResult: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case passed, failed }
    public var outcome: Outcome
    public var date = Date()
    public var fingerprint: String
    public var checks: [LabCheck] = []
    public var groups: [MirrorBatch] = []
    public var note = ""
    public var leftOut: [String] = []
    public var acknowledged = false
}

public enum StationLight: Equatable, Sendable {
    case locked(String), ready, running, passed
    case failed(acknowledged: Bool)
    /// It ran, but the plugins or version have changed since.
    case stale
}

extension LabController {
    /// Plugins that would act on the outside world if they ran here, such as uploading backups.
    static func reachesOutside(_ plugin: InstalledPlugin) -> Bool { Trial.disabledInCopies.contains(plugin.key) }

    /// Inside a plugin's folder, whatever's in these is about players and worlds, not how the plugin should behave.
    static let dataFolders: Set<String> = ["worlds", "groups", "players", "playerdata", "userdata", "users", "data", "storage", "cache", "logs", "backups", "stats"]
    /// These name the real server's worlds, which the Lab doesn't have, so they'd only fail.
    static let worldBoundFiles: Set<String> = [
        "multiverse-core/worlds.yml", "multiverse-core/anchors.yml", "multiverse-inventories/groups.yml", "multiverse-inventories/playernames.json",
        "multiverse-netherportals/links.yml", "multiverse-portals/portals.yml",
    ]

    /// A plugin's settings, without its player data or anything tied to real worlds.
    public static func settingsToCopy(in folder: URL) -> [String] {
        ConfigCatalog.settingsFiles(in: folder, limit: 500).filter { rel in
            let parts = rel.lowercased().components(separatedBy: "/")
            if parts.dropLast().contains(where: dataFolders.contains) { return false }
            return !worldBoundFiles.contains("\(folder.lastPathComponent.lowercased())/\(rel.lowercased())")
        }
    }

    /// Copies a plugin's settings files. Never its data, and nothing for one that shares an outside database.
    /// Returns what it held back.
    static func copySettings(from model: ServerPaths, to lab: ServerPaths, plugins: [String]) throws -> [String] {
        var notes: [String] = []
        let shared = Set(Trial.databasePlugins(model).map { $0.lowercased() })
        for name in plugins {
            guard let folder = FileOps.children(model.plugins).first(where: { FileOps.isDirectory($0) && $0.lastPathComponent.lowercased() == name.lowercased() }) else { continue }
            if shared.contains(name.lowercased()) {
                notes.append("\(name) kept fresh settings, because they mention an outside database that the Lab could write to.")
                continue
            }
            for rel in settingsToCopy(in: folder) {
                let target = lab.plugins.appendingPathComponent(folder.lastPathComponent).appendingPathComponent(rel)
                try FileOps.ensureDir(target.deletingLastPathComponent())
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: folder.appendingPathComponent(rel), to: target)
            }
        }
        return notes
    }
}
