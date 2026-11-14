import Foundation

// Plugins on upgrade, through Preflight's own command-line tool (preflight-upgrade, ExtantApe/Preflight). The tool
// decides: it boots a copy on the new version, says what won't start and what needs it, switches plugins off and
// back on, and keeps its own plugin restore point. LeafJuice makes the copy with saving paused, asks the person,
// adds its own verified restore point of the whole server, and shows the result. See docs/PLAN.md, 2026-11-08.

/// Which release of the tool LeafJuice uses, pinned by hash so a changed download is refused.
public enum UpgradeTool {
    public static let version = "0.3.0"
    public static let sha256 = "1789f326e44f841ede148e6338e2d9399b52a0695c4a6f1397d1c8ed9609b7ef"
    public static let javaMajor = 25
    public static var fileName: String { "preflight-upgrade-\(version).jar" }
    public static var url: URL { URL(string: "https://github.com/ExtantApe/Preflight/releases/download/v\(version)/\(fileName)")! }
    public static var folder: URL { AppPaths.servers.appendingPathComponent(AppPaths.ownFolderName, isDirectory: true).appendingPathComponent("tools", isDirectory: true) }
    public static var jar: URL { folder.appendingPathComponent(fileName) }

    /// For the checks: runs something else in place of `java -jar <tool>`.
    nonisolated(unsafe) public static var runOverride: (([String]) async throws -> ToolResult)?

    /// The tool's jar, downloaded once and checked against the pinned hash every time it's used.
    public static func ensureJar() async throws -> URL {
        if FileOps.exists(jar), (try? Hashing.digests(of: jar).sha256) == sha256 { return jar }
        try? FileManager.default.removeItem(at: jar)
        try FileOps.ensureDir(folder)
        try await HTTP.download(url, to: jar, expect: ExpectedHashes(sha256: sha256))
        return jar
    }

    static func run(java: String, _ args: [String]) async throws -> ToolResult {
        if let runOverride { return try await runOverride(args) }
        let tool = try await ensureJar()
        return try await Tool.run(java, ["-jar", tool.path] + args)
    }

    /// The last thing the tool said, for when it fails without JSON.
    static func lastWords(_ result: ToolResult) -> String {
        let lines = (result.err + "\n" + result.out).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.last.map { String($0) } ?? "It gave no reason (exit \(result.code))."
    }
}

/// The tool's plan, as `check --json` prints it. Kept with its original bytes, which `apply` takes back.
public struct PluginUpgradePlan: Equatable, Sendable {
    public struct Target: Codable, Equatable, Sendable {
        public var file: String?
        public var brand: String?
        public var minecraft: String?
        public var build: Int?
        public var version: String?
    }
    public struct Off: Codable, Equatable, Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var files: [String]
        public var why: [String]
    }
    public struct Blocked: Codable, Equatable, Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var rule: String
        public var why: [String]
    }
    public struct NotChecked: Codable, Equatable, Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var why: String
    }
    public struct Recheck: Codable, Equatable, Sendable, Identifiable {
        public var id: String { plugin + note }
        public var plugin: String
        public var note: String
    }
    struct Body: Codable {
        var format: Int
        var server: String?
        var target: Target?
        var status: String
        var stop: String?
        var off: [Off]?
        var blocked: [Blocked]?
        var notChecked: [NotChecked]?
        var warnings: [String]?
        var recheck: [Recheck]?
    }

    public var target: String
    /// Set when there's no plan to act on, and says why.
    public var stop: String?
    public var status = "stop"
    public var server: String?
    public var off: [Off] = []
    public var blocked: [Blocked] = []
    public var notChecked: [NotChecked] = []
    public var warnings: [String] = []
    public var recheck: [Recheck] = []
    public var hasRules = false
    /// Offered to the person when the stop was only about a shared outside database.
    public var sharedDatabase = false
    var raw = Data()

    public var canApply: Bool { status == "switch-off" && stop == nil && blocked.isEmpty && !off.isEmpty }
    public var allClear: Bool { status == "all-clear" }

    public init(target: String, stop: String) { self.target = target; self.stop = stop }

    /// nil if it isn't the tool's JSON. A format LeafJuice doesn't know becomes a stop.
    public static func decode(_ data: Data, target fallback: String) -> PluginUpgradePlan? {
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return nil }
        guard body.format == 1 else {
            return PluginUpgradePlan(target: fallback, stop: "The upgrade tool gave format \(body.format), which this version of LeafJuice doesn't know. Look for a LeafJuice update.")
        }
        var plan = PluginUpgradePlan(target: fallback, stop: "")
        if let t = body.target, let mc = t.minecraft { plan.target = "\(t.brand ?? "Paper") \(mc)" + (t.build.map { " build \($0)" } ?? "") }
        plan.status = body.status
        plan.server = body.server
        plan.off = body.off ?? []
        plan.blocked = body.blocked ?? []
        plan.notChecked = body.notChecked ?? []
        plan.warnings = body.warnings ?? []
        plan.recheck = body.recheck ?? []
        plan.raw = data
        switch body.status {
        case "switch-off", "all-clear", "wait": plan.stop = nil
        case "stop":
            plan.stop = body.stop ?? "The upgrade tool stopped without saying why."
            plan.sharedDatabase = body.stop?.contains("--allow-shared-database") == true || body.stop?.localizedCaseInsensitiveContains("outside database") == true
        default: plan.stop = "The upgrade tool gave a result LeafJuice doesn't know: \(body.status)."
        }
        return plan
    }
}

/// What the tool has switched off, from `status --json`.
public struct SwitchedOffPlugins: Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var files: [String]
        public var why: [String]?
        public var date: String?
        public var target: String?
    }
    struct Body: Codable { var format: Int; var switchedOff: [Entry]? }
    public var entries: [Entry] = []
    public init() {}
    public static func decode(_ data: Data) -> SwitchedOffPlugins? {
        guard let body = try? JSONDecoder().decode(Body.self, from: data), body.format == 1 else { return nil }
        var out = SwitchedOffPlugins()
        out.entries = body.switchedOff ?? []
        return out
    }
}

extension ServerPaths {
    /// The tool's own files on this server, readable without LeafJuice.
    public var upgradeFolder: URL { plugins.appendingPathComponent("Preflight/upgrade", isDirectory: true) }
    public var upgradeRules: URL { upgradeFolder.appendingPathComponent("rules.json") }
    public var switchedOffFile: URL { upgradeFolder.appendingPathComponent("switched-off.json") }
}

extension ServerController {
    /// Java for the tool, which needs 25 or newer.
    func upgradeToolJava() throws -> String {
        guard let java = JavaManager.best(for: UpgradeTool.javaMajor, in: runtimes) else {
            throw LeafError("The upgrade check needs Java \(UpgradeTool.javaMajor) or newer. Install it from Settings, then try again.")
        }
        return java.path
    }

    /// Makes an empty rules file to fill in, if there isn't one, and returns where it is.
    public func ensureUpgradeRules() throws -> URL {
        if !FileOps.exists(paths.upgradeRules) {
            try FileOps.ensureDir(paths.upgradeFolder)
            try FileOps.writeAtomic(#"{"format": 1, "neverOff": [], "recheck": []}"# + "\n", to: paths.upgradeRules)
        }
        return paths.upgradeRules
    }

    /// Copies the server with saving paused, downloads the target Paper, and has the tool boot the copy and plan.
    /// The copy and the downloaded jar are deleted afterwards. The real server isn't changed.
    public func checkPluginsForUpgrade(_ build: SoftwareBuild, allowSharedDatabase: Bool = false) async -> PluginUpgradePlan {
        let target = "\(build.flavor.title) \(build.label)"
        guard build.flavor == .paper else { return PluginUpgradePlan(target: target, stop: "The upgrade check works for Paper only.") }
        guard trialPhase == nil || trialPhase == .finished else { return PluginUpgradePlan(target: target, stop: "A test copy is already in use. Finish it first.") }
        let work = paths.root.deletingLastPathComponent()
            .appendingPathComponent(AppPaths.ownFolderName, isDirectory: true).appendingPathComponent("test-copies", isDirectory: true)
            .appendingPathComponent("upgrade-check-\(paths.root.lastPathComponent)-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            let java = try upgradeToolJava()
            setActivity("Getting \(target) for the check…")
            defer { setActivity(nil) }
            try FileOps.ensureDir(work)
            let paper = work.appendingPathComponent(build.fileName)
            guard !build.hashes.isEmpty else { throw LeafError("That Paper build has no published checksum, so it wasn't used.") }
            try await HTTP.download(HTTP.url(build.downloadURL), to: paper, expect: build.hashes)
            setActivity("Copying the server for the check…")
            let copy = work.appendingPathComponent("copy", isDirectory: true)
            try await copyWithSavingPaused(to: copy)
            setActivity("Checking plugins on \(target). This takes a few minutes…")
            var args = ["check", "--server", paths.root.path, "--copy", copy.path, "--paper", paper.path, "--json",
                        "--memory", "\(min(profile.launch.maxMemoryMB, 4096))M", "--java", java]
            if allowSharedDatabase { args.append("--allow-shared-database") }
            let result = try await UpgradeTool.run(java: java, args)
            guard var plan = PluginUpgradePlan.decode(Data(result.out.utf8), target: target) else {
                return PluginUpgradePlan(target: target, stop: "The check didn't finish. \(UpgradeTool.lastWords(result))")
            }
            plan.hasRules = FileOps.exists(paths.upgradeRules)
            appendWrapper("Plugin check for \(plan.target): \(plan.status).", level: .info)
            return plan
        } catch {
            return PluginUpgradePlan(target: target, stop: error.localizedDescription)
        }
    }

    /// A copy taken the way test copies are: a running server stops saving for the moment it takes.
    func copyWithSavingPaused(to copy: URL) async throws {
        let wasRunning = state == .running
        if wasRunning, let process {
            process.send("save-off")
            let saved = Task { await waitForLine(containing: "saved the game", timeout: .seconds(120)) }
            await Task.yield()
            process.send("save-all flush")
            _ = await saved.value
        }
        defer { if wasRunning { process?.send("save-on") } }
        try await Trial.clone(paths.root, to: copy)
    }

    /// Switches off what the plan lists, through the tool. LeafJuice's own verified restore point of the whole server
    /// comes first. The tool then refuses if the server is running or a jar changed since the check.
    public func applyPluginPlan(_ plan: PluginUpgradePlan) async throws {
        guard plan.canApply else { throw LeafError(plan.stop ?? (plan.blocked.isEmpty ? "There's nothing to switch off." : "A plugin that must stay on would have to go, so the upgrade waits.")) }
        guard state.canStart, !state.isLive else { throw LeafError("Stop the server first. Plugins are only switched off while it's stopped.") }
        let java = try upgradeToolJava()
        if !isTrialCopy { _ = try await makeRestorePoint() }
        let file = paths.meta.appendingPathComponent("upgrade-plan-\(UUID().uuidString).json")
        try FileOps.ensureDir(paths.meta)
        try plan.raw.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        setActivity("Switching plugins off…")
        defer { setActivity(nil) }
        let result = try await UpgradeTool.run(java: java, ["apply", "--server", paths.root.path, "--plan", file.path, "--yes"])
        await refreshPlugins()
        guard result.ok else { throw LeafError("Nothing was switched off. \(UpgradeTool.lastWords(result))") }
        appendWrapper("Switched off for \(plan.target): \(plan.off.map(\.name).joined(separator: ", ")).", level: .info)
        recordEvent(.plugin, "Plugins switched off for \(plan.target)", detail: plan.off.map(\.name).joined(separator: ", "))
    }

    /// What the tool has switched off on this server.
    public func switchedOffPlugins() async -> SwitchedOffPlugins {
        guard FileOps.exists(paths.switchedOffFile), let java = try? upgradeToolJava(),
              let result = try? await UpgradeTool.run(java: java, ["status", "--server", paths.root.path, "--json"]) else { return SwitchedOffPlugins() }
        return SwitchedOffPlugins.decode(Data(result.out.utf8)) ?? SwitchedOffPlugins()
    }

    /// Puts plugins the tool switched off back on. Only while stopped; a newer jar in its place is left alone.
    public func switchBackOn(_ names: [String]) async throws {
        guard !names.isEmpty else { return }
        guard state.canStart, !state.isLive else { throw LeafError("Stop the server first. Plugins are only switched on while it's stopped.") }
        let java = try upgradeToolJava()
        setActivity("Switching plugins back on…")
        defer { setActivity(nil) }
        let result = try await UpgradeTool.run(java: java, ["restore", "--server", paths.root.path] + names.flatMap { ["--plugin", $0] } + ["--yes"])
        await refreshPlugins()
        guard result.ok else { throw LeafError("Not every plugin went back on. \(UpgradeTool.lastWords(result))") }
        appendWrapper("Switched back on: \(names.joined(separator: ", ")).", level: .info)
        recordEvent(.plugin, "Plugins switched back on", detail: names.joined(separator: ", "))
    }
}
