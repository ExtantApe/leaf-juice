import Darwin
import Foundation
@testable import LeafJuiceCore

/// Is the advisor useful? Runs real Paper with a large plugin set and real bots, plants one known fault per scenario,
/// and leaves each server's files behind for scoring. Clones a test seed that already holds an accepted EULA, and
/// refuses to run otherwise: this doesn't accept anything itself. Its plugin mix is jars only, with fresh settings.
private let botNames = ["Alice", "Bob", "Carol", "Zephyr_Quill", "MossyTurnip", "Bramble42", "OakenShield", "fern_gully", "PixelPanda", "Tater_Tot", "NightOwl77", "RedstoneRae", "Sir_Digs", "LunaMoth", "CopperKettle", "xX_Slayer_Xx", "WillowWisp", "GravelGuy", "Sprout", "HoneyBadger9", "Griefer77", "BirchBark", "Mapleine", "CaptainCod"]
private let evalPort = 25590

private func evalShell(_ line: String) async throws { _ = try await Tool.run("/bin/zsh", ["-c", line]) }

@MainActor private func controller(_ root: URL, memory: Int = 4096) async throws -> ServerController {
    try? FileManager.default.removeItem(at: ServerPaths(root: root).meta)
    let c = try await ServerController.adopt(root: root, name: "Leaflands Test")
    c.profile.backup.enabled = false
    c.profile.backup.destination = root.appendingPathComponent(".leafjuice/backups").path
    c.profile.lastPluginCheck = Date(); c.profile.software.lastCheck = Date()
    c.profile.launch.restartOnCrash = false
    c.profile.launch.maxMemoryMB = memory; c.profile.launch.minMemoryMB = min(memory, 2048)
    await c.refreshPlugins()
    return c
}

@MainActor private func playAndStop(_ c: ServerController, table: ProtocolTable, bots: Int, dwell: Int, out: URL, name: String) async {
    let started = Date()
    await c.start()
    for _ in 0..<(420 * 2) {
        if c.state == .running { break }
        if case .crashed = c.state { break }
        if c.state == .stopped, Date().timeIntervalSince(started) > 5 { break }
        try? await Task.sleep(for: .milliseconds(500))
    }
    let bootSeconds = Int(Date().timeIntervalSince(started))
    let booted = c.state == .running
    var connected: [Bot] = []
    if booted {
        for who in botNames.prefix(bots) {
            if let bot = try? Bot(name: who, port: evalPort, table: table) { connected.append(bot) }
            try? await Task.sleep(for: .milliseconds(700))
        }
    }
    var peak = 0
    let until = Date().addingTimeInterval(TimeInterval(dwell))
    var step = 0
    while Date() < until, c.state == .running {
        peak = max(peak, c.players.count)
        if step % 30 == 0 { c.send("say Scheduled notice \(step)") }
        if step % 40 == 10, let who = connected.randomElement()?.name { c.send("give \(who) minecraft:bread 3") }
        step += 1
        try? await Task.sleep(for: .seconds(1))
    }
    let endState = "\(c.state)"
    connected.forEach { $0.leave() }
    if c.state == .running || c.state == .starting {
        c.stop()
        for _ in 0..<240 where c.state != .stopped { try? await Task.sleep(for: .milliseconds(500)) }
    }
    if c.state != .stopped, !c.state.canStart { c.forceStop() }
    try? await Task.sleep(for: .seconds(2))
    c.scanLatestLog()
    c.stopTicker()
    print("  \(name): booted=\(booted) boot=\(bootSeconds)s peakPlayers=\(peak) end=\(endState) issues=\(c.issues.count)")
    let result: [String: Any] = ["scenario": name, "booted": booted, "bootSeconds": bootSeconds, "peakPlayers": peak, "endState": endState, "issues": c.issues.count]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted) { try? data.write(to: out.appendingPathComponent("\(name).result.json")) }
}

@MainActor func runAdvisorEval(eval: URL, scenarios: [String]) async {
    let sandbox = URL(fileURLWithPath: "/Users/mgilardi/Code/leaf-juice/.lab-sandbox", isDirectory: true)
    let seed = sandbox.appendingPathComponent("servers/seed", isDirectory: true)
    let pluginSource = sandbox.appendingPathComponent("servers/lab-model-src/plugins", isDirectory: true)
    let servers = eval.appendingPathComponent("servers", isDirectory: true)
    let results = eval.appendingPathComponent("results", isDirectory: true)
    setenv("LEAFJUICE_HOME", eval.appendingPathComponent("home").path, 1)
    setenv("LEAFJUICE_SERVERS", servers.path, 1)
    let base = servers.appendingPathComponent("base", isDirectory: true)
    do {
        try FileOps.ensureDir(results)
        guard (try? String(contentsOf: seed.appendingPathComponent("eula.txt"), encoding: .utf8))?.contains("eula=true") == true else {
            print("The test seed has no accepted EULA, and this won't accept it for you."); return
        }
        let runtimes = await JavaManager.discover()
        guard let java = JavaManager.best(for: 21, in: runtimes) else { print("no Java 21"); return }
        let table = try await ProtocolTable.load(mc: "1.21.11", cache: sandbox.appendingPathComponent("protocol", isDirectory: true), java: java.path)

        if !FileOps.exists(base) {
            print("Seeding the large server")
            try await Trial.clone(seed, to: base)
            try? FileManager.default.removeItem(at: base.appendingPathComponent("seeded"))
            let plugins = base.appendingPathComponent("plugins", isDirectory: true)
            for old in FileOps.children(plugins) where old.pathExtension == "jar" { try FileManager.default.removeItem(at: old) }
            // Jars only. Any settings kept beside them in that folder aren't copied.
            for jar in FileOps.children(pluginSource) where jar.pathExtension == "jar" {
                try FileManager.default.copyItem(at: jar, to: plugins.appendingPathComponent(jar.lastPathComponent))
            }
            var properties = try String(contentsOf: base.appendingPathComponent("server.properties"), encoding: .utf8)
            properties = properties.replacingOccurrences(of: "server-port=25580", with: "server-port=\(evalPort)")
            properties = properties.replacingOccurrences(of: "server-ip=\n", with: "server-ip=127.0.0.1\n")
            if !properties.contains("server-ip=127.0.0.1") { properties += "\nserver-ip=127.0.0.1\n" }
            try properties.write(to: base.appendingPathComponent("server.properties"), atomically: true, encoding: .utf8)
            let c = try await controller(base)
            for plugin in c.plugins where LabController.reachesOutside(plugin) {
                print("    leaving out \(plugin.name): it reaches outside this Mac")
                try FileManager.default.removeItem(at: plugins.appendingPathComponent(plugin.fileName))
            }
            await c.refreshPlugins()
            print("    plugins: \(c.plugins.count)")
            await playAndStop(c, table: table, bots: 8, dwell: 40, out: results, name: "seed")
        }

        let jars = eval.appendingPathComponent("jars", isDirectory: true)
        for name in scenarios {
            let run = servers.appendingPathComponent("run-\(name)", isDirectory: true)
            try? FileManager.default.removeItem(at: run)
            try await Trial.clone(base, to: run)
            try? FileManager.default.removeItem(at: run.appendingPathComponent("logs/latest.log"))
            try? FileManager.default.removeItem(at: run.appendingPathComponent("logs"))
            let plugins = run.appendingPathComponent("plugins", isDirectory: true)
            let data = plugins.appendingPathComponent("HomeWarps", isDirectory: true)
            func plant(_ jar: String = "HomeWarps.jar", mode: String? = nil) throws {
                try FileManager.default.copyItem(at: jars.appendingPathComponent(jar), to: plugins.appendingPathComponent("HomeWarps-2.3.1.jar"))
                if let mode { try FileOps.writeAtomic(mode, to: data.appendingPathComponent("mode.txt")) }
            }
            var memory = 4096, dwell = 90, bots = 16
            switch name {
            case "healthy", "healthy2": break
            case "healthy-plugin": try plant()
            case "enable-npe", "event-npe", "task-ex", "db", "inject": try plant(mode: name)
            case "lag": try plant(mode: "lag"); dwell = 400
            case "bad-config":
                try plant(mode: name)
                try FileOps.writeAtomic("radius: 5\nworlds:\n  - main\n bad_indent: [unclosed\n", to: data.appendingPathComponent("config.yml"))
            case "missing-dep": try plant("HomeWarps-dep.jar")
            case "future-api": try plant("HomeWarps-api.jar")
            case "wrong-java": try plant("HomeWarps-j25.jar")
            case "corrupt-jar":
                try plant()
                try await evalShell("truncate -s 400 '\(plugins.appendingPathComponent("HomeWarps-2.3.1.jar").path)'")
            case "hang":
                try plant(mode: "hang"); dwell = 200
                try await evalShell("sed -i '' 's/timeout-time: .*/timeout-time: 20/' '\(run.appendingPathComponent("spigot.yml").path)'")
            case "leak": try plant(mode: "leak"); dwell = 200; memory = 2048
            case "many":
                try plant(mode: "task-ex")
                try FileManager.default.copyItem(at: plugins.appendingPathComponent("HomeWarps-2.3.1.jar"), to: plugins.appendingPathComponent("Spare-Broken.jar"))
                try await evalShell("truncate -s 400 '\(plugins.appendingPathComponent("Spare-Broken.jar").path)'")
                try FileOps.writeAtomic("broken: [unclosed\n", to: plugins.appendingPathComponent("LuckPerms/config.yml"))
            default: print("Unknown scenario \(name)"); continue
            }
            print("Scenario \(name)")
            let c = try await controller(run, memory: memory)
            await playAndStop(c, table: table, bots: bots, dwell: dwell, out: results, name: name)
            bots = 0
        }
    } catch { print("evaluation failed: \(error)") }
}
