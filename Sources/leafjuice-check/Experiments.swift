import Darwin
import Foundation
@testable import LeafJuiceCore

/// Experiments, not tests: each tries something real and writes down what actually happened.
/// `leafjuice-check --experiments versions,failures --i-accept-the-minecraft-eula`
/// Results go to `.lab-sandbox/findings/<group>.md`.
@MainActor final class Lab {
    let base: URL
    let servers: URL
    let group: String
    var lines: [String] = []

    init(base: URL, group: String) {
        self.base = base
        self.servers = base.appendingPathComponent("servers", isDirectory: true)
        self.group = group
        lines.append("# \(group)\n")
    }

    func heading(_ text: String) { lines.append("\n## \(text)\n"); print("  ▸ \(text)") }

    func saw(_ text: String) {
        lines.append("- \(text)")
        print("    \(text.prefix(300))")
    }

    func save() {
        let file = base.appendingPathComponent("findings/\(group).md")
        try? FileOps.writeAtomic(lines.joined(separator: "\n") + "\n", to: file)
    }

    func table(_ mc: String, java: String) async throws -> ProtocolTable {
        try await ProtocolTable.load(mc: mc, cache: base.appendingPathComponent("protocol"), java: java)
    }

    func quiet(_ c: ServerController) {
        c.profile.backup.enabled = false
        c.profile.backup.autoDrill = false
        c.profile.lastPluginCheck = Date()
        c.profile.software.lastCheck = Date()
        c.profile.launch.restartOnCrash = false
        c.profile.launch.maxMemoryMB = 2048
        c.profile.launch.minMemoryMB = 1024
        c.profile.launch.keepAwake = false
        c.profile.playerSnapshots.enabled = false
    }

    /// A brand new empty server on the given software.
    func fresh(_ name: String, flavor: Flavor = .paper, mc: String, plugins: [PluginSource] = [], port: Int = 25581) async throws -> ServerController {
        let root = servers.appendingPathComponent("lab-\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileOps.ensureDir(root)
        write("server-port=\(port)\nonline-mode=false\nview-distance=4\nsimulation-distance=4\nlevel-type=minecraft\\:flat\nnetwork-compression-threshold=-1\nspawn-protection=0\nmax-tick-time=-1\n", root.appendingPathComponent("server.properties"))
        let c = try await ServerController.adopt(root: root, name: "Lab \(name)")
        quiet(c)
        c.profile.backup.destination = root.appendingPathComponent(".leafjuice/backups").path
        try EULA.accept(c.paths)
        guard let build = try await SoftwareCatalog.latestBuild(flavor, mc: mc) else { throw LeafError("No \(flavor.title) \(mc)") }
        c.profile.software.flavor = flavor
        try await c.installSoftware(build)
        for source in plugins { try await c.addPlugin(source: source) }
        await c.refreshPlugins()
        return c
    }

    /// A clone of the seeded sandbox.
    func cloneSeed(_ name: String) async throws -> ServerController {
        let run = servers.appendingPathComponent("lab-\(name)-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try await Trial.clone(servers.appendingPathComponent("seed"), to: run)
        try? FileManager.default.removeItem(at: ServerPaths(root: run).meta)
        let c = try await ServerController.adopt(root: run, name: "Lab \(name)")
        quiet(c)
        c.profile.backup.destination = run.appendingPathComponent(".leafjuice/backups").path
        await c.refreshPlugins()
        return c
    }

    func discard(_ c: ServerController) {
        c.forceStop()
        c.stopTicker()
        try? FileManager.default.removeItem(at: c.paths.root)
    }

    /// Starts and waits. Returns how it went, in words.
    func boot(_ c: ServerController, timeout: Int = 240) async -> (up: Bool, seconds: Double) {
        let start = Date()
        await c.start()
        if !c.blockers.isEmpty { return (false, 0) }
        for _ in 0..<(timeout * 4) {
            if c.state == .running || c.state.canStart { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return (c.state == .running, Date().timeIntervalSince(start))
    }

    func down(_ c: ServerController) async {
        if c.state == .running || c.state == .starting { c.stop() }
        for _ in 0..<(120 * 4) where c.state.isLive { try? await Task.sleep(for: .milliseconds(250)) }
        if c.state.isLive { c.forceStop(); try? await Task.sleep(for: .seconds(2)) }
    }

    /// Runs a command and returns the lines it produced.
    func run(_ c: ServerController, _ command: String, wait: Double = 1.5) async -> [String] {
        let start = c.console.last?.id ?? -1
        c.send(command)
        try? await Task.sleep(for: .seconds(wait))
        return c.console.filter { $0.id > start && $0.origin == .server }.map(\.text)
    }

    func errors(_ c: ServerController, limit: Int = 4) -> [String] {
        c.console.filter { $0.level >= .warn && !$0.text.contains("*****") && !$0.text.contains("behind") && !$0.text.contains("update as soon") && !$0.text.contains("papermc.io/downloads") }.suffix(limit).map { String($0.text.prefix(200)) }
    }

    func issueSummary(_ c: ServerController) -> String {
        let known = c.issues.filter(\.isKnown).map { $0.ruleID ?? "" }
        let unknown = c.issues.filter { !$0.isKnown }.prefix(4).map { String($0.title.prefix(100)) }
        return "rules \(known), uncategorized \(unknown)"
    }
}

@MainActor func runExperiments(_ groups: [String]) async {
    let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".lab-sandbox", isDirectory: true)
    setenv("LEAFJUICE_HOME", base.appendingPathComponent("home").path, 1)
    setenv("LEAFJUICE_SERVERS", base.appendingPathComponent("servers").path, 1)
    let all: [(String, @MainActor (Lab) async throws -> Void)] = [
        ("versions", expVersions), ("failures", expFailures), ("multiverse", expMultiverse),
        ("players", expPlayers), ("renames", expRenames), ("restore", expRestore),
        ("packs", expPacks),
    ]
    for (name, experiment) in all where groups.contains(name) || groups.contains("all") {
        print("• EXPERIMENT: \(name)")
        let lab = Lab(base: base, group: name)
        do { try await experiment(lab) } catch { lab.saw("**Stopped early:** \(error)") }
        lab.save()
    }
}

// MARK: - What differs between versions and software?

@MainActor func expVersions(_ lab: Lab) async throws {
    let cases: [(Flavor, String)] = [
        (.paper, "1.20.4"), (.paper, "1.20.6"), (.paper, "1.21.1"), (.paper, "1.21.4"), (.paper, "1.21.8"), (.paper, "1.21.11"),
        (.paper, "26.1.2"), (.paper, "26.3"), (.purpur, "1.21.11"), (.folia, "1.21.11"), (.vanilla, "1.21.11"), (.vanilla, "26.3"),
    ]
    for (flavor, mc) in cases {
        lab.heading("\(flavor.title) \(mc)")
        do {
            let c = try await lab.fresh("v", flavor: flavor, mc: mc)
            defer { lab.discard(c) }
            lab.saw("Java required \(c.javaRequirement), using \(c.resolvedJava()?.major ?? 0); flags from API: \(c.profile.software.recommendedFlags.count)")
            let boot = await lab.boot(c)
            guard boot.up else {
                lab.saw("**Did not boot.** state \(c.state), blockers \(c.blockers.map(\.title)); \(lab.errors(c))")
                continue
            }
            lab.saw("Booted in \(Int(boot.seconds))s. Done line recognised.")
            let table = try await lab.table(mc, java: c.resolvedJava()?.path ?? "")
            lab.saw("Protocol \(table.version)")
            let bot = try Bot(name: "Probe", port: 25581, table: table)
            try? await Task.sleep(for: .seconds(6))
            lab.saw("Join tracked: \(c.players.contains("Probe")). Disconnect: \(bot.disconnectReason.map { String($0.prefix(120)) } ?? "none")")
            lab.saw("Join lines: \(c.console.filter { $0.text.contains("Probe") }.prefix(4).map { String($0.text.prefix(140)) })")
            let ids = c.console.filter { $0.text.contains("UUID of player") }.map(\.text).first
            lab.saw("UUID line: \(ids ?? "none")")
            lab.saw("save-all: \(await lab.run(c, "save-all flush", wait: 3).suffix(2))")
            lab.saw("give: \(await lab.run(c, "give Probe minecraft:diamond 1").suffix(1))")
            lab.saw("data get: \(await lab.run(c, "data get entity Probe Inventory").suffix(1).map { String($0.prefix(180)) })")
            lab.saw("tick query: \(await lab.run(c, "tick query").suffix(4).map { String($0.prefix(90)) })")
            c.requestTPS()
            try? await Task.sleep(for: .seconds(2))
            lab.saw("TPS read: \(String(describing: c.tps?.oneMinute)); MSPT read: \(String(describing: c.mspt))")
            lab.saw("Raw tps: \(await lab.run(c, "tps").suffix(2).map { String($0.prefix(120)) })")
            lab.saw("Raw mspt: \(await lab.run(c, "mspt").suffix(3).map { String($0.prefix(120)) })")
            bot.leave()
            try? await Task.sleep(for: .seconds(3))
            lab.saw("Leave tracked: \(!c.players.contains("Probe")). Lines: \(c.console.suffix(3).map { String($0.text.prefix(120)) })")
            _ = await lab.run(c, "save-all flush", wait: 2)
            let p = PlayerPaths(c.paths)
            lab.saw("Player data folder: \(FileOps.relative(p.dataFolder, to: c.paths.root)), exists \(FileOps.exists(p.dataFolder)), files \(FileOps.children(p.dataFolder).count)")
            lab.saw("Stats folder exists: \(FileOps.exists(p.statsFolder)); usercache exists: \(FileOps.exists(c.paths.root.appendingPathComponent("usercache.json")))")
            if let file = FileOps.children(p.dataFolder).first(where: { $0.pathExtension == "dat" }), let doc = try? NBT.read(file) {
                lab.saw("Top-level player keys: \(doc.root.keys.prefix(40))")
                lab.saw("DataVersion \(doc.root["DataVersion"]?.intValue ?? 0). Round trips: \((try? NBT.decode(NBT.encode(doc))) == doc). Armor key: \(doc.root["equipment"] != nil ? "equipment" : "in Inventory")")
                lab.saw("Item parsed: \(PlayerFiles.summary(doc.root).items.map(\.item))")
            }
            lab.saw("World folders: \(Backups.worldFolders(c.paths.root)); top level: \(FileOps.children(c.paths.root).filter(FileOps.isDirectory).map(\.lastPathComponent).sorted())")
            lab.saw("Config files seen: \(c.configs.map(\.path).prefix(12))")
            lab.saw("GC log written: \(FileOps.exists(GCLog.file(c.paths)))")
            lab.saw("Rule hits on a clean boot: \(lab.issueSummary(c))")
            await lab.down(c)
            lab.saw("Stopped cleanly: \(c.state == .stopped)")
        } catch {
            lab.saw("**Failed:** \(error)")
        }
    }
}

// MARK: - What happens when things go wrong?

@MainActor func expFailures(_ lab: Lab) async throws {
    func trial(_ title: String, _ setup: @MainActor (ServerController) async throws -> Void) async {
        lab.heading(title)
        do {
            let c = try await lab.cloneSeed("fail")
            defer { lab.discard(c) }
            try await setup(c)
            let boot = await lab.boot(c, timeout: 120)
            lab.saw("Booted: \(boot.up) (\(Int(boot.seconds))s), state \(c.state), blockers \(c.blockers.map(\.title))")
            try? await Task.sleep(for: .seconds(1))
            lab.saw("Log: \(lab.errors(c))")
            lab.saw("Catalogued: \(lab.issueSummary(c))")
            await lab.down(c)
        } catch { lab.saw("**Failed:** \(error)") }
    }

    let javas = await JavaManager.discover()

    await trial("Garbage plugin jar") { c in write("not a zip", c.paths.plugins.appendingPathComponent("Broken.jar")) }
    await trial("A jar with no plugin.yml") { c in
        makeJar(c.paths.plugins.appendingPathComponent("NoYaml.jar"), yaml: "name: x\n")
        _ = try await Tool.run("/usr/bin/zip", ["-qd", c.paths.plugins.appendingPathComponent("NoYaml.jar").path, "plugin.yml"])
        write("x", c.paths.plugins.appendingPathComponent("hold.txt"))
    }
    await trial("A Fabric mod in the plugins folder") { c in
        let work = folder("fabric-\(UUID().uuidString)")
        write(#"{"schemaVersion":1,"id":"somemod","version":"1.0"}"#, work.appendingPathComponent("fabric.mod.json"))
        _ = try await Tool.run("/usr/bin/zip", ["-q", c.paths.plugins.appendingPathComponent("somemod.jar").path, "fabric.mod.json"], cwd: work)
    }
    await trial("A plugin missing a required dependency") { c in makeJar(c.paths.plugins.appendingPathComponent("Needy.jar"), yaml: "name: Needy\nversion: 1\nmain: a.B\ndepend: [Vault]\napi-version: 1.13\n") }
    await trial("A plugin from a newer Minecraft") { c in makeJar(c.paths.plugins.appendingPathComponent("Future.jar"), yaml: "name: Future\nversion: 1\nmain: a.B\napi-version: 99.0\n") }
    await trial("A plugin whose main class is missing") { c in makeJar(c.paths.plugins.appendingPathComponent("Hollow.jar"), yaml: "name: Hollow\nversion: 1\nmain: no.such.Main\napi-version: 1.13\n") }
    await trial("Two jars claiming one plugin") { c in
        makeJar(c.paths.plugins.appendingPathComponent("Twin1.jar"), yaml: "name: Twin\nversion: 1\nmain: a.B\napi-version: 1.13\n")
        makeJar(c.paths.plugins.appendingPathComponent("Twin2.jar"), yaml: "name: Twin\nversion: 2\nmain: a.B\napi-version: 1.13\n")
    }
    await trial("Tab in bukkit.yml") { c in write("settings:\n\tallow-end: true\n", c.paths.root.appendingPathComponent("bukkit.yml")) }
    await trial("Broken spigot.yml") { c in write("settings: [unclosed\n  a: 'b\n", c.paths.root.appendingPathComponent("spigot.yml")) }
    await trial("Broken paper-global.yml") { c in write("this: is: not: valid: yaml: [\n", c.paths.root.appendingPathComponent("config/paper-global.yml")) }
    await trial("Broken plugin config") { c in write("storage-method: [\n\tbad", c.paths.plugins.appendingPathComponent("LuckPerms/config.yml")) }
    await trial("Garbage in server.properties") { c in
        write("server-port=25580\nview-distance=banana\nmax-players=-5\nonline-mode=false\nnonsense\n", c.paths.properties)
    }
    await trial("Heap far too small") { c in c.profile.launch.maxMemoryMB = 64; c.profile.launch.minMemoryMB = 64 }
    await trial("A bad JVM flag") { c in c.profile.launch.extraJVMArgs = "-XX:+NoSuchFlagAtAll" }
    await trial("Minimum above maximum, past the check") { c in c.profile.launch.extraJVMArgs = "-Xms8G -Xmx1G" }
    await trial("Java too old for the server") { c in
        guard let old = javas.first(where: { $0.major == 17 }) else { lab.saw("No Java 17 here."); return }
        c.profile.launch.javaPath = old.path
        c.profile.software.requiredJava = 8
    }
    await trial("Java much newer than the server expects") { c in
        guard let new = javas.max(by: { $0.major < $1.major }) else { return }
        lab.saw("Using Java \(new.major)")
        c.profile.launch.javaPath = new.path
    }
    await trial("Damaged region file") { c in
        let region = c.paths.root.appendingPathComponent("world/region/r.0.0.mca")
        if let data = try? Data(contentsOf: region) {
            var damaged = data
            for i in stride(from: 8192, to: min(damaged.count, 60000), by: 7) { damaged[i] = UInt8(truncatingIfNeeded: i) }
            try damaged.write(to: region)
            lab.saw("Damaged \(data.count) byte region")
        } else { lab.saw("No region file to damage") }
    }
    await trial("level.dat deleted, level.dat_old present") { c in
        let dat = c.paths.root.appendingPathComponent("world/level.dat")
        lab.saw("level.dat_old exists: \(FileOps.exists(c.paths.root.appendingPathComponent("world/level.dat_old")))")
        try? FileManager.default.removeItem(at: dat)
    }
    await trial("level.dat garbage") { c in write("garbage", c.paths.root.appendingPathComponent("world/level.dat")) }
    await trial("Player data file garbage") { c in
        let id = PlayerFiles.offlineUUID(name: "Alice")
        write("garbage", PlayerPaths(c.paths).data(id))
    }
    await trial("Multiverse worlds.yml garbage") { c in write("[[[not yaml", c.paths.plugins.appendingPathComponent("Multiverse-Core/worlds.yml")) }
    await trial("World folder in worlds.yml is missing") { c in
        try? FileManager.default.removeItem(at: c.paths.root.appendingPathComponent("creative"))
    }

    lab.heading("Forced kill while running, then start again")
    do {
        let c = try await lab.cloneSeed("kill")
        defer { lab.discard(c) }
        c.profile.launch.restartOnCrash = false
        _ = await lab.boot(c)
        let pid = c.process?.pid ?? 0
        kill(pid, SIGKILL)
        for _ in 0..<40 where c.state.isLive { try? await Task.sleep(for: .milliseconds(250)) }
        lab.saw("Noticed: state \(c.state). Issue: \(c.issues.contains { $0.id == "wrapper:crash" })")
        lab.saw("session.lock left behind: \(FileOps.exists(c.paths.root.appendingPathComponent("world/session.lock")))")
        let again = await lab.boot(c)
        lab.saw("Boots again: \(again.up) in \(Int(again.seconds))s. Log: \(lab.errors(c, limit: 3))")
        await lab.down(c)
    }

    lab.heading("Forced kill while saving")
    do {
        let c = try await lab.cloneSeed("killsave")
        defer { lab.discard(c) }
        _ = await lab.boot(c)
        c.send("save-all flush")
        kill(c.process?.pid ?? 0, SIGKILL)
        for _ in 0..<40 where c.state.isLive { try? await Task.sleep(for: .milliseconds(250)) }
        let again = await lab.boot(c)
        lab.saw("Boots again: \(again.up). Log: \(lab.errors(c, limit: 3))")
        await lab.down(c)
    }

    lab.heading("Stop while starting")
    do {
        let c = try await lab.cloneSeed("stopstart")
        defer { lab.discard(c) }
        await c.start()
        try? await Task.sleep(for: .seconds(1))
        c.stop()
        for _ in 0..<(120 * 4) where c.state.isLive { try? await Task.sleep(for: .milliseconds(250)) }
        lab.saw("Ended as \(c.state). Log tail: \(c.console.suffix(2).map { String($0.text.prefix(120)) })")
    }

    lab.heading("Quit the wrapper while the server runs (orphan)")
    do {
        let c = try await lab.cloneSeed("orphan")
        defer { lab.discard(c) }
        _ = await lab.boot(c)
        let pid = c.process?.pid ?? 0
        c.stopTicker()
        // A second controller sees the pid file, as a relaunched app would.
        let second = ServerController.open(root: c.paths.root)
        try? await Task.sleep(for: .seconds(2))
        await second?.detectExternalServer()
        lab.saw("A relaunched app sees: \(String(describing: second?.state))")
        lab.saw("Port busy: \(SystemInfo.isPortBusy(25580))")
        second?.stopTicker()
        _ = pid
        await lab.down(c)
    }

    lab.heading("Port taken by something else")
    do {
        let c = try await lab.cloneSeed("port")
        defer { lab.discard(c) }
        let other = try await lab.cloneSeed("port2")
        defer { lab.discard(other) }
        _ = await lab.boot(other)
        let blockers = await c.preflight()
        lab.saw("Second server's preflight: \(blockers.map(\.title))")
        await lab.down(other)
    }
}

// MARK: - How do the Multiverse plugins really behave?

@MainActor func expMultiverse(_ lab: Lab) async throws {
    let mc = "1.21.11"
    let c = try await lab.cloneSeed("mv")
    defer { lab.discard(c) }
    let table = try await lab.table(mc, java: "/usr/bin/java")
    try await c.addPlugin(source: .modrinth(project: "multiverse-netherportals", allowBeta: false))
    try await c.addPlugin(source: .modrinth(project: "multiverse-portals", allowBeta: false))
    await c.refreshPlugins()
    _ = await lab.boot(c)
    func files() -> String {
        ["worlds.yml", "config.yml", "anchors.yml"].compactMap { name -> String? in
            let t = (try? String(contentsOf: c.paths.plugins.appendingPathComponent("Multiverse-Core/\(name)"), encoding: .utf8)) ?? ""
            return "\(name): \(t.count)b"
        }.joined(separator: ", ")
    }
    lab.heading("Files")
    lab.saw(files())
    lab.saw("Plugin folders: \(FileOps.children(c.paths.plugins).filter(FileOps.isDirectory).map(\.lastPathComponent).sorted())")
    let inv = PlayerPaths(c.paths).inventories
    lab.saw("Inventories folder: \(FileOps.children(inv).map(\.lastPathComponent).sorted())")
    if let groups = try? String(contentsOf: inv.appendingPathComponent("groups.yml"), encoding: .utf8) { lab.saw("groups.yml:\n```\n\(groups.prefix(800))\n```") }
    let sample = (try? String(contentsOf: c.paths.plugins.appendingPathComponent("Multiverse-Core/worlds.yml"), encoding: .utf8)) ?? ""
    lab.saw("worlds.yml first entry:\n```\n\(sample.split(separator: "\n").prefix(60).joined(separator: "\n"))\n```")
    if let nether = try? String(contentsOf: c.paths.plugins.appendingPathComponent("Multiverse-NetherPortals/config.yml"), encoding: .utf8) { lab.saw("NetherPortals config:\n```\n\(nether.prefix(500))\n```") }
    if let portals = try? String(contentsOf: c.paths.plugins.appendingPathComponent("Multiverse-Portals/portals.yml"), encoding: .utf8) { lab.saw("portals.yml: \(portals.prefix(200))") }

    lab.heading("Commands")
    lab.saw("mv list: \(await lab.run(c, "mv list").map { String($0.prefix(70)) })")
    lab.saw("mvinv group list: \(await lab.run(c, "mvinv group list").map { String($0.prefix(120)) })")
    lab.saw("mvinv info: \(await lab.run(c, "mvinv info mining").map { String($0.prefix(120)) })")
    lab.saw("mvnp show: \(await lab.run(c, "mvnp show").map { String($0.prefix(120)) })")
    lab.saw("create a group: \(await lab.run(c, "mvinv group create mining,creative shared", wait: 3).map { String($0.prefix(140)) })")
    lab.saw("groups.yml after: \((try? String(contentsOf: inv.appendingPathComponent("groups.yml"), encoding: .utf8))?.prefix(700) ?? "none")")
    lab.saw("link nether: \(await lab.run(c, "mvnp link nether mining deep", wait: 2).map { String($0.prefix(140)) })")

    lab.heading("Game modes inside per-world files")
    let alice = try Bot(name: "Alice", port: 25580, table: table)
    try? await Task.sleep(for: .seconds(4))
    _ = await lab.run(c, "gamemode creative Alice", wait: 2)
    _ = await lab.run(c, "give Alice minecraft:bedrock 2")
    _ = await lab.run(c, "gamemode survival Alice", wait: 2)
    lab.saw("Inventory after switching back: \(await lab.run(c, "data get entity Alice Inventory").suffix(1).map { String($0.prefix(200)) })")
    _ = await lab.run(c, "mv tp Alice mining", wait: 3)
    _ = await lab.run(c, "mv tp Alice world", wait: 3)
    alice.leave()
    try? await Task.sleep(for: .seconds(3))
    let world = inv.appendingPathComponent("worlds/world/Alice.json")
    if let text = try? String(contentsOf: world, encoding: .utf8) {
        let top = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?.keys.sorted() ?? []
        lab.saw("Sections in worlds/world/Alice.json: \(top)")
    }
    lab.saw("players folder: \(FileOps.children(inv.appendingPathComponent("players")).prefix(4).map(\.lastPathComponent))")
    if let global = FileOps.children(inv.appendingPathComponent("players")).first, let t = try? String(contentsOf: global, encoding: .utf8) { lab.saw("Global player file: \(t.prefix(300))") }

    lab.heading("Worlds set not to load")
    _ = await lab.run(c, "mv modify creative set auto-load false", wait: 2)
    await lab.down(c)
    await c.refreshWorlds()
    lab.saw("Read as auto-load: \(String(describing: c.worlds.first { $0.title == "creative" }?.multiverse?.autoLoad))")
    _ = await lab.boot(c)
    lab.saw("mv list: \(await lab.run(c, "mv list").map { String($0.prefix(70)) })")
    await lab.down(c)

    // Multiverse 4.x, on a server old enough to get it.
    lab.heading("Multiverse 4.x on 1.16.5")
    do {
        let old = try await lab.fresh("mv4", mc: "1.16.5", plugins: [Multiverse.source], port: 25582)
        defer { lab.discard(old) }
        lab.saw("Plugins: \(old.plugins.map { "\($0.name) \($0.version)" }); major \(String(describing: old.multiverseMajor)); Java \(old.resolvedJava()?.major ?? 0)")
        let boot = await lab.boot(old)
        lab.saw("Booted \(boot.up): \(lab.errors(old))")
        guard boot.up else { return }
        var w = NewWorld(); w.name = "oldworld"
        try await old.createWorld(w)
        lab.saw("Create: success \(String(describing: old.worldOperation?.succeeded)). Output: \(old.console.suffix(5).map { String($0.text.prefix(120)) })")
        await old.refreshWorlds()
        lab.saw("Entries: \(old.worlds.map { "\($0.name) managed=\($0.isManaged) path=\($0.relativePath ?? "-")" })")
        if let world = old.worlds.first(where: { $0.title == "oldworld" }) {
            try await old.loadWorld("oldworld")
            lab.saw("Load (already loaded): \(old.worldOperation?.succeeded == true); \(old.console.suffix(2).map { String($0.text.prefix(100)) })")
            try await old.unloadWorld(world)
            lab.saw("Unload: \(old.worldOperation?.succeeded == true); \(old.console.suffix(2).map { String($0.text.prefix(100)) })")
            try await old.loadWorld("oldworld")
            lab.saw("Load: \(old.worldOperation?.succeeded == true); \(old.console.suffix(2).map { String($0.text.prefix(100)) })")
            try await old.modifyWorld(world, property: "alias", value: "Old")
            lab.saw("Modify: \(old.worldOperation?.succeeded == true); \(old.console.suffix(2).map { String($0.text.prefix(100)) })")
            try await old.deleteWorld(world)
            lab.saw("Delete: \(old.worldOperation?.succeeded == true); \(old.console.suffix(5).map { String($0.text.prefix(100)) })")
        }
        await lab.down(old)
        lab.saw("worlds.yml: \((try? String(contentsOf: old.paths.plugins.appendingPathComponent("Multiverse-Core/worlds.yml"), encoding: .utf8))?.prefix(300) ?? "none")")
    } catch { lab.saw("**Failed:** \(error)") }
}

// MARK: - What really happens to player data?

@MainActor func expPlayers(_ lab: Lab) async throws {
    let table = try await lab.table("1.21.11", java: "/usr/bin/java")
    let c = try await lab.cloneSeed("players")
    defer { lab.discard(c) }
    let id = PlayerFiles.offlineUUID(name: "Alice")
    _ = await lab.boot(c)

    lab.heading("Armor and ender chest")
    var bot = try Bot(name: "Alice", port: 25580, table: table)
    try? await Task.sleep(for: .seconds(3))
    _ = await lab.run(c, "item replace entity Alice armor.chest with minecraft:diamond_chestplate")
    _ = await lab.run(c, "item replace entity Alice enderchest.0 with minecraft:elytra")
    _ = await lab.run(c, "item replace entity Alice weapon.offhand with minecraft:shield")
    lab.saw("In game equipment: \(await lab.run(c, "data get entity Alice equipment").suffix(1).map { String($0.prefix(220)) })")
    _ = await lab.run(c, "save-all flush", wait: 2)
    let doc = try NBT.read(PlayerPaths(c.paths).data(id))
    lab.saw("Top-level keys: \(doc.root.keys)")
    lab.saw("Armor in the file: `equipment` \(doc.root["equipment"] != nil); ender items \(PlayerFiles.summary(doc.root).enderItems.map(\.item))")

    lab.heading("How stale is a snapshot without forcing a save?")
    _ = await lab.run(c, "give Alice minecraft:cake 1")
    try? await Task.sleep(for: .seconds(2))
    let unsaved = try NBT.read(PlayerPaths(c.paths).data(id))
    lab.saw("Cake in the file 2s after giving: \(PlayerFiles.summary(unsaved.root).items.contains { $0.item == "minecraft:cake" })")
    lab.saw("save-all (not flush) writes players: ")
    _ = await lab.run(c, "save-all", wait: 3)
    lab.saw("  cake now on disk: \(PlayerFiles.summary(try NBT.read(PlayerPaths(c.paths).data(id)).root).items.contains { $0.item == "minecraft:cake" })")

    lab.heading("Snapshot taken in one world, restored while in another")
    _ = await lab.run(c, "mv tp Alice mining", wait: 3)
    _ = await lab.run(c, "save-all flush", wait: 2)
    let inMining = try PlayerSnapshots.take(uuid: id, name: "Alice", trigger: "manual", paths: c.paths, profile: c.profile)
    let snapRoot = PlayerSnapshots.location(inMining, profile: c.profile)
    let snapDoc = try NBT.read(snapRoot.appendingPathComponent("player.dat"))
    lab.saw("Snapshot's world markers: Dimension \(snapDoc.root["Dimension"]?.stringValue ?? "-"), WorldUUID \(snapDoc.root["WorldUUIDMost"] != nil), items \(PlayerFiles.summary(snapDoc.root).items.map(\.item))")
    _ = await lab.run(c, "mv tp Alice world", wait: 3)
    bot.leave()
    try? await Task.sleep(for: .seconds(3))
    await lab.down(c)
    try PlayerSnapshots.restore(inMining, inventoryOnly: true, containers: [], paths: c.paths, profile: c.profile)
    _ = await lab.boot(c)
    bot = try Bot(name: "Alice", port: 25580, table: table)
    try? await Task.sleep(for: .seconds(3))
    lab.saw("Inventory-only, no per-world files, last in world: \(await lab.run(c, "data get entity Alice Inventory").suffix(1).map { String($0.prefix(200)) })")
    bot.leave()
    try? await Task.sleep(for: .seconds(3))
    await lab.down(c)
    try PlayerSnapshots.restore(inMining, inventoryOnly: true, containers: inMining.containers, paths: c.paths, profile: c.profile)
    _ = await lab.boot(c)
    bot = try Bot(name: "Alice", port: 25580, table: table)
    try? await Task.sleep(for: .seconds(3))
    lab.saw("Same, with its per-world files: \(await lab.run(c, "data get entity Alice Inventory").suffix(1).map { String($0.prefix(200)) })")
    _ = await lab.run(c, "mv tp Alice mining", wait: 3)
    lab.saw("Then in mining: \(await lab.run(c, "data get entity Alice Inventory").suffix(1).map { String($0.prefix(200)) })")
    _ = await lab.run(c, "mv tp Alice world", wait: 3)
    bot.leave()
    try? await Task.sleep(for: .seconds(3))

    lab.heading("Names differing only by capitalization, on a case-insensitive Mac disk")
    let lower = try Bot(name: "alice", port: 25580, table: table)
    try? await Task.sleep(for: .seconds(4))
    lab.saw("Disconnect: \(lower.disconnectReason.map { String($0.prefix(100)) } ?? "none"). Tracked: \(c.players.contains("alice"))")
    _ = await lab.run(c, "give alice minecraft:dirt 1")
    lab.saw("Inventory: \(await lab.run(c, "data get entity alice Inventory").suffix(1).map { String($0.prefix(200)) })")
    lower.leave()
    try? await Task.sleep(for: .seconds(3))
    let p = PlayerPaths(c.paths)
    lab.saw("Offline UUIDs differ: \(PlayerFiles.offlineUUID(name: "alice") != id); data files for both: \(FileOps.exists(p.data(PlayerFiles.offlineUUID(name: "alice"))))")
    lab.saw("Inventory files in worlds/world: \(FileOps.children(p.inventories.appendingPathComponent("worlds/world")).map(\.lastPathComponent).sorted())")
    if let text = try? String(contentsOf: p.inventories.appendingPathComponent("worlds/world/Alice.json"), encoding: .utf8) {
        lab.saw("Alice.json now holds dirt (a collision): \(text.contains("minecraft:dirt"))")
    }

    lab.heading("Restoring an old snapshot after an upgrade")
    let oldSnap = try PlayerSnapshots.take(uuid: id, name: "Alice", trigger: "manual", paths: c.paths, profile: c.profile)
    lab.saw("Snapshot DataVersion \(try NBT.read(PlayerSnapshots.location(oldSnap, profile: c.profile).appendingPathComponent("player.dat")).root["DataVersion"]?.intValue ?? 0)")
    await lab.down(c)
    let build = try await SoftwareCatalog.latestBuild(.paper, mc: "26.3")!
    c.runtimes = await JavaManager.discover()
    try await c.installSoftware(build)
    c.keepUpgrade()
    let upgrade = await lab.boot(c)
    lab.saw("26.3 booted: \(upgrade.up). Issues: \(lab.issueSummary(c))")
    let t26 = try await lab.table("26.3", java: c.resolvedJava()?.path ?? "")
    var b26 = try Bot(name: "Alice", port: 25580, table: t26)
    try? await Task.sleep(for: .seconds(4))
    lab.saw("Tracked on 26.3: \(c.players.contains("Alice")); join lines \(c.console.filter { $0.text.contains("Alice") }.suffix(2).map { String($0.text.prefix(120)) })")
    _ = await lab.run(c, "clear Alice")
    b26.leave()
    try? await Task.sleep(for: .seconds(3))
    await lab.down(c)
    try PlayerSnapshots.restore(oldSnap, inventoryOnly: false, containers: oldSnap.containers, paths: c.paths, profile: c.profile)
    _ = await lab.boot(c)
    b26 = try Bot(name: "Alice", port: 25580, table: t26)
    try? await Task.sleep(for: .seconds(4))
    lab.saw("Old 1.21 snapshot, full restore on 26.3: \(await lab.run(c, "data get entity Alice Inventory").suffix(1).map { String($0.prefix(220)) })")
    lab.saw("Errors: \(lab.errors(c, limit: 3))")
    let newDoc = try? NBT.read(PlayerPaths(c.paths).data(id))
    lab.saw("New top-level keys on 26.3: \(newDoc?.root.keys ?? [])")
    _ = await lab.run(c, "save-all flush", wait: 2)
    let newer = try PlayerSnapshots.take(uuid: id, name: "Alice", trigger: "manual", paths: c.paths, profile: c.profile)
    b26.leave()
    try? await Task.sleep(for: .seconds(3))
    await lab.down(c)
    lab.saw("A newer snapshot onto an older server is a question for the upgrade rollback: DataVersion \(try NBT.read(PlayerSnapshots.location(newer, profile: c.profile).appendingPathComponent("player.dat")).root["DataVersion"]?.intValue ?? 0).")
}

// MARK: - Which renames survive?

@MainActor func expRenames(_ lab: Lab) async throws {
    let table = try await lab.table("1.21.11", java: "/usr/bin/java")
    func rename(_ title: String, world: String, to new: String, prepare: (@MainActor (ServerController) async throws -> Void)? = nil) async {
        lab.heading(title)
        do {
            let c = try await lab.cloneSeed("rn")
            defer { lab.discard(c) }
            try await c.addPlugin(source: .modrinth(project: "multiverse-netherportals", allowBeta: false))
            await c.refreshPlugins()
            // Observed: `mvinv group` is conversational from a console, so groups go in the file while stopped.
            write("groups:\n  default:\n    worlds:\n    - world\n    - world_nether\n    - world_the_end\n    shares:\n    - all\n  shared:\n    worlds:\n    - mining\n    - creative\n    shares:\n    - all\n", PlayerPaths(c.paths).inventories.appendingPathComponent("groups.yml"))
            _ = await lab.boot(c)
            _ = await lab.run(c, "mvnp link nether mining deep", wait: 2)
            try await prepare?(c)
            await lab.down(c)
            await c.refreshWorlds()
            guard let entry = c.worlds.first(where: { $0.title == world || $0.isMain && world == "MAIN" }) else { lab.saw("World not found: \(c.worlds.map(\.title))"); return }
            let plan = c.worldRenamePlan(entry, to: new)
            lab.saw("Plan: \(plan.items.map { "\($0.description) [\($0.location)]" })")
            lab.saw("Mentions: \(plan.mentions)")
            try await c.applyRename(plan)
            let boot = await lab.boot(c)
            lab.saw("Booted \(boot.up). Log: \(lab.errors(c))")
            lab.saw("mv list: \(await lab.run(c, "mv list").filter { $0.contains(" - ") }.map { String($0.drop { $0 != "]" }.prefix(50)) })")
            lab.saw("Group file: \((try? String(contentsOf: PlayerPaths(c.paths).inventories.appendingPathComponent("groups.yml"), encoding: .utf8))?.prefix(260) ?? "none")")
            lab.saw("NetherPortals: \((try? String(contentsOf: c.paths.plugins.appendingPathComponent("Multiverse-NetherPortals/config.yml"), encoding: .utf8))?.prefix(260) ?? "none")")
            let bot = try Bot(name: "Alice", port: 25580, table: table)
            try? await Task.sleep(for: .seconds(3))
            lab.saw("Alice's inventory: \(await lab.run(c, "data get entity Alice Inventory").suffix(1).map { String($0.prefix(160)) })")
            if world != "MAIN" {
                _ = await lab.run(c, "mv tp Alice \(new)", wait: 3)
                lab.saw("In \(new): \(await lab.run(c, "data get entity Alice Inventory").suffix(1).map { String($0.prefix(160)) })")
                lab.saw("Dimension: \(await lab.run(c, "data get entity Alice Dimension").suffix(1).map { String($0.prefix(100)) })")
            }
            bot.leave()
            if title.contains("last logged out") {
                let bob = try Bot(name: "Bob", port: 25580, table: table)
                try? await Task.sleep(for: .seconds(3))
                lab.saw("Bob rejoins, joined: \(c.players.contains("Bob")), in \(await lab.run(c, "data get entity Bob Dimension").suffix(1).map { String($0.prefix(100)) }), holding \(await lab.run(c, "data get entity Bob Inventory").suffix(1).map { String($0.prefix(140)) })")
                bob.leave()
                try? await Task.sleep(for: .seconds(2))
            }
            await lab.down(c)
            let invPlayers = PlayerPaths(c.paths).inventories.appendingPathComponent("players")
            let lastWorlds: [String] = FileOps.children(invPlayers).compactMap { file in
                guard let text = try? String(contentsOf: file, encoding: .utf8), let r = text.range(of: "\"lastWorld\"[^,}]*", options: .regularExpression) else { return nil }
                return String(text[r])
            }
            lab.saw("Per-player lastWorld after renaming: \(lastWorlds)")
            lab.saw("links.yml: \((try? String(contentsOf: c.paths.plugins.appendingPathComponent("Multiverse-NetherPortals/links.yml"), encoding: .utf8)) ?? "none")")
            lab.saw("Stale old-name files: \(FileOps.children(c.paths.root).map(\.lastPathComponent).filter { $0 == world })")
        } catch { lab.saw("**Failed:** \(error)") }
    }
    await rename("Plain extra world", world: "deep", to: "abyss")
    await rename("World in an inventory group, and in a Nether link", world: "mining", to: "quarry")
    await rename("The linked Nether world", world: "deep", to: "underworld")
    await rename("The main world", world: "MAIN", to: "homeworld")
    await rename("A world a player last logged out in", world: "mining", to: "quarry") { c in
        let bot = try Bot(name: "Bob", port: 25580, table: table)
        try? await Task.sleep(for: .seconds(3))
        _ = await lab.run(c, "mv tp Bob mining", wait: 3)
        bot.leave()
        try? await Task.sleep(for: .seconds(3))
    }
    await rename("A world set not to load", world: "creative", to: "workshop") { c in
        _ = await lab.run(c, "mv modify creative set auto-load false", wait: 2)
    }
}

// MARK: - What does a restore really give you?

@MainActor func expRestore(_ lab: Lab) async throws {
    lab.heading("Whole-folder restore with no internet")
    let c = try await lab.cloneSeed("offline")
    defer { lab.discard(c) }
    _ = await lab.boot(c)
    await lab.down(c)
    let backup = try await c.backupNow(trigger: "manual", scope: .everything)
    lab.saw("Backup size \(Format.bytes(backup.size))")
    for name in ["libraries", "versions", "cache", "world", "plugins"] {
        try? FileManager.default.removeItem(at: c.paths.root.appendingPathComponent(name))
    }
    try await Backups.restore(backup, profile: c.profile, root: c.paths.root)
    // A dead proxy: anything reaching for the internet fails.
    c.profile.launch.extraJVMArgs = "-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=9 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=9"
    let offline = await lab.boot(c)
    lab.saw("Booted without internet: \(offline.up) in \(Int(offline.seconds))s. Log: \(lab.errors(c))")
    await lab.down(c)

    lab.heading("Which folders does it need to start, if it has internet?")
    c.profile.launch.extraJVMArgs = ""
    for name in ["libraries", "versions", "cache"] {
        let before = FileOps.directorySize(c.paths.root.appendingPathComponent(name))
        try? FileManager.default.removeItem(at: c.paths.root.appendingPathComponent(name))
        let boot = await lab.boot(c)
        lab.saw("\(name) (\(Format.bytes(before))) deleted: booted \(boot.up) in \(Int(boot.seconds))s, came back \(Format.bytes(FileOps.directorySize(c.paths.root.appendingPathComponent(name))))")
        await lab.down(c)
    }

    lab.heading("Backup while busy: does save-off really freeze the world files?")
    _ = await lab.boot(c)
    let bot = try Bot(name: "Alice", port: 25580, table: try await lab.table("1.21.11", java: "/usr/bin/java"))
    try? await Task.sleep(for: .seconds(3))
    for i in 0..<20 { _ = await lab.run(c, "setblock \(i) 70 0 minecraft:stone", wait: 0.05) }
    let during = try await c.backupNow(trigger: "manual", scope: .everything)
    lab.saw("Warning recorded: \(during.warning ?? "none"); size \(Format.bytes(during.size)); listed ok: \((try? await Tool.run("/usr/bin/tar", ["-tzf", Backups.destination(c.profile).appendingPathComponent(during.fileName).path]))?.ok == true)")
    lab.saw("Log during: \(c.console.suffix(4).map { String($0.text.prefix(90)) })")
    bot.leave()
    await lab.down(c)
    await c.runBackupDrill(during)
    lab.saw("That backup boots: \(c.profile.lastDrill?.passed == true); \(c.profile.lastDrill?.detail ?? "")")

    lab.heading("Compression: what's a backup made of?")
    for name in FileOps.children(c.paths.root).map(\.lastPathComponent).sorted() {
        let size = FileOps.directorySize(c.paths.root.appendingPathComponent(name))
        if size > 1_000_000 { lab.saw("\(name): \(Format.bytes(size))") }
    }
}

// MARK: - What really happens with resource packs?

@MainActor func expPacks(_ lab: Lab) async throws {
    struct Search: Decodable { struct Hit: Decodable { let slug: String; let title: String }; let hits: [Hit] }
    lab.heading("Real packs from Modrinth, through the same route as the app")
    let query = #"[["project_type:resourcepack"],["versions:1.21.11"]]"#.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    let search = try await HTTP.decode(Search.self, HTTP.url("https://api.modrinth.com/v2/search?facets=\(query)&index=downloads&limit=6"))
    var added: [LibraryPack] = []
    let wanted = ["tardis-resource-pack", "tardis-sounds"].map { (slug: $0, title: $0) } + search.hits.map { (slug: $0.slug, title: $0.title) }
    for hit in wanted where added.count < 6 {
        do {
            let pack = try await ResourcePacks.download(.modrinth(project: hit.slug), mc: "1.21.11")
            added.append(pack)
            lab.saw("\(pack.title): \(Format.bytes(pack.latest?.size ?? 0)), format \(pack.latest?.format.map(String.init) ?? "?"), \(pack.latest?.fileCount ?? 0) files, \(pack.latest?.imageCount ?? 0) images, license \(pack.license?.id ?? "none"), by \(pack.authors.prefix(2))")
        } catch { lab.saw("\(hit.title): refused: \(error.localizedDescription)") }
    }

    lab.heading("Ranking them")
    var recipe = ResourcePacks.reconcile(PackRecipe(), with: added)
    recipe.name = "Experiment"
    let started = Date()
    let lock = try await ResourcePacks.resolve(recipe)
    lab.saw("Resolved \(lock.files.count) files in \(String(format: "%.1f", Date().timeIntervalSince(started)))s. Differing copies: \(ResourcePacks.conflicts(lock).count). By category: \(Dictionary(grouping: ResourcePacks.conflicts(lock), by: { ResourcePacks.category(of: $0.path) }).mapValues(\.count)). Merged: \(lock.files.filter { $0.reason == .merged }.count). Lock file size: \(Format.bytes(Int64((try? JSONStore.compactEncoder.encode(lock).count) ?? 0)))")
    let result = try await ResourcePacks.combine(recipe)
    lab.saw("Built: \(Format.bytes(result.size)), \(result.fileCount) files, format \(result.format.map(String.init) ?? "?"), warnings \(result.warnings)")
    let second = try await ResourcePacks.combine(recipe)
    lab.saw("Built again, same SHA-1: \(second.sha1 == result.sha1)")
    let file = ResourcePacks.buildFile(result, recipe: recipe.name)
    let rebuilt = try await ResourcePacks.read(file, version: "check")
    lab.saw("It reads back as a pack: format \(rebuilt.info.format.map(String.init) ?? "?"), \(rebuilt.info.fileCount) files")
    var badJSON: [String] = []
    for rel in ResourcePacks.listing(rebuilt.root) where rel.hasSuffix(".json") || rel.hasSuffix(".mcmeta") {
        if (try? JSONSerialization.jsonObject(with: Data(contentsOf: rebuilt.root.appendingPathComponent(rel)))) == nil { badJSON.append(rel) }
    }
    for item in ResourcePacks.conflicts(lock).prefix(12) { lab.saw("Differs: \(item.path), between \(item.copies.map(\.pack)), \(item.winner) wins") }
    for item in lock.files.filter({ $0.reason == .merged }).prefix(8) { lab.saw("Merged: \(item.path), from \(item.copies.map(\.pack))") }
    if let tardis = added.first(where: { $0.title.lowercased().contains("tardis resource") }) {
        var ranked = recipe
        ranked.categoryWinners["Models"] = tardis.id
        let check = try await ResourcePacks.resolve(ranked)
        lab.saw("With TARDIS first for Models: \(check.files.filter { $0.reason == .category }.count) files decided by category")
    }
    lab.saw("JSON that doesn't parse in the build: \(badJSON.prefix(5))")
    lab.saw("License review: \(ResourcePacks.licenseReview(recipe).map { "\($0.pack.title): \($0.sharing)" })")
    let exported = try ResourcePacks.exportRecipe(recipe)
    lab.saw("Recipe export: \(Format.bytes(Int64(exported.count)))")
    let keptPacks = ResourcePacks.list()
    for pack in keptPacks { try await ResourcePacks.remove(pack) }
    let imported = try await ResourcePacks.importRecipe(exported, mc: "1.21.11")
    lab.saw("Imported into an empty library: fetched \(imported.fetched), missing \(imported.missing.map(\.title))")
    let rebuiltFromRecipe = try await ResourcePacks.combine(imported.recipe)
    lab.saw("Rebuilt from the recipe alone, same SHA-1 as the original: \(rebuiltFromRecipe.sha1 == result.sha1)")

    lab.heading("What a server does with the settings")
    let table = try await lab.table("1.21.11", java: "/usr/bin/java")
    let c = try await lab.cloneSeed("packs")
    defer { lab.discard(c) }
    let url = "https://download.mc-packs.net/pack/\(result.sha1).zip"
    func configured(required: Bool, sha1: String = result.sha1) throws {
        let text = try String(contentsOf: c.paths.properties, encoding: .utf8)
        try FileOps.writeAtomic(try ResourcePacks.applying(url: url, sha1: sha1, required: required, to: text), to: c.paths.properties)
    }
    func tryJoin(_ title: String, name: String, answer: Int32?) async throws {
        let bot = try Bot(name: name, port: 25580, table: table, packAnswer: answer)
        try? await Task.sleep(for: .seconds(6))
        lab.saw("\(title): offered \(bot.packOffer.map { "\($0.url.suffix(24)) hash \($0.hash.prefix(8)) required \($0.required)" } ?? "nothing"); in the game: \(c.players.contains(name)); kicked: \(bot.disconnectReason.map { String($0.prefix(100)) } ?? "no")")
        bot.leave()
        try? await Task.sleep(for: .seconds(2))
    }
    try configured(required: false)
    _ = await lab.boot(c)
    lab.saw("Stored as: \((try String(contentsOf: c.paths.properties, encoding: .utf8)).split(separator: "\n").filter { $0.hasPrefix("resource-pack") || $0.hasPrefix("require") }.map { String($0.prefix(90)) })")
    try await tryJoin("Optional, says nothing", name: "Alice", answer: nil)
    try await tryJoin("Optional, declines", name: "Bob", answer: 1)
    await lab.down(c)
    try configured(required: true)
    _ = await lab.boot(c)
    try await tryJoin("Required, accepts", name: "Alice", answer: 0)
    try await tryJoin("Required, declines", name: "Bob", answer: 1)
    try await tryJoin("Required, says nothing", name: "Carol", answer: nil)
    lab.saw("Errors: \(lab.errors(c, limit: 4))")
    await lab.down(c)
    let text = try String(contentsOf: c.paths.properties, encoding: .utf8)
    var doc = PropertiesDocument(text); doc.set("resource-pack-sha1", "nothex")
    try FileOps.writeAtomic(doc.text, to: c.paths.properties)
    _ = await lab.boot(c)
    lab.saw("A malformed SHA-1: \(c.console.filter { $0.text.lowercased().contains("sha") || $0.text.lowercased().contains("resource") }.suffix(3).map { String($0.text.prefix(130)) }). Issues: \(lab.issueSummary(c))")
    await lab.down(c)
}

extension NBT {
    /// For reports.
    var keys: [String] {
        if case let .compound(entries) = self { return entries.map(\.name) }
        return []
    }
}
