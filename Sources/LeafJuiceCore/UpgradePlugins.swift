import Foundation

// Plugins on upgrade: boot a throwaway copy on the new version with Preflight, read what it reports, and offer to
// switch off what doesn't start, plus whatever can't start without it. Nothing changes on the real server without a
// yes, and only while it's stopped, after a verified restore point. Each plugin can be switched back on later.

/// What Preflight wrote to plugins/Preflight/report.xml. Only its properties are read: `plugin.<Name>.<field>`,
/// `test.<Owner:check>.<field>` and a few run-wide ones. Keys are split on the last dot, since names can contain dots.
public struct PreflightReport: Equatable, Sendable {
    public enum State: String, Sendable { case enabled, disabled, notLoaded = "not-loaded", unknown }
    public struct Plugin: Equatable, Sendable {
        public var name: String
        public var state: State = .unknown
        public var version = ""
        public var files: [String] = []
        public var depends: [String] = []
        public var softDepends: [String] = []
        public var requiredBy: [String] = []
        public var missingDepends: [String] = []
        public var failedTests: [String] = []
        public var reason: String?
    }
    public struct Test: Equatable, Sendable {
        public var id: String
        public var result = ""
        public var severity = ""
        public var message: String?
        public var failed: Bool { result == "failed" || result == "timed-out" }
    }
    public var format: Int?
    public var preflightVersion: String?
    public var minecraft: String?
    public var serverVersion: String?
    public var finishedAt: String?
    public var serverChecks: String?
    public var plugins: [String: Plugin] = [:]
    public var tests: [String: Test] = [:]

    public static let fileName = "plugins/Preflight/report.xml"

    public static func parse(_ data: Data) -> PreflightReport? {
        let reader = PropertyReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { return nil }
        var out = PreflightReport()
        func list(_ text: String) -> [String] { text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        for (key, value) in reader.properties {
            switch key {
            case "preflight.report.format": out.format = Int(value)
            case "preflight.version": out.preflightVersion = value
            case "preflight.finished-at": out.finishedAt = value
            case "preflight.server-checks": out.serverChecks = value
            case "server.minecraft-version": out.minecraft = value
            case "server.version": out.serverVersion = value
            default:
                guard let dot = key.lastIndex(of: ".") else { continue }
                let field = String(key[key.index(after: dot)...]), head = key[..<dot]
                if head.hasPrefix("plugin.") {
                    let name = String(head.dropFirst("plugin.".count))
                    guard !name.isEmpty else { continue }
                    var p = out.plugins[name] ?? Plugin(name: name)
                    switch field {
                    case "state": p.state = State(rawValue: value) ?? .unknown
                    case "version": p.version = value
                    case "files", "file": p.files = list(value)
                    case "depends": p.depends = list(value)
                    case "soft-depends": p.softDepends = list(value)
                    case "required-by": p.requiredBy = list(value)
                    case "missing-depends": p.missingDepends = list(value)
                    case "failed-tests": p.failedTests = list(value)
                    case "reason": p.reason = value
                    default: break
                    }
                    out.plugins[name] = p
                } else if head.hasPrefix("test.") {
                    let id = String(head.dropFirst("test.".count))
                    guard !id.isEmpty else { continue }
                    var t = out.tests[id] ?? Test(id: id)
                    switch field {
                    case "result": t.result = value
                    case "severity": t.severity = value
                    case "message": t.message = value
                    default: break
                    }
                    out.tests[id] = t
                }
            }
        }
        return out
    }

    private final class PropertyReader: NSObject, XMLParserDelegate {
        var properties: [String: String] = [:]
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            guard name == "property", let key = attributes["name"], let value = attributes["value"] else { return }
            properties[key] = value
        }
    }
}

/// Per-server rules, kept in `.leafjuice/upgrade-rules.json` so they're plain to read and edit.
public struct UpgradeRules: Codable, Equatable, Sendable {
    public struct Keep: Codable, Equatable, Sendable, Identifiable {
        public var id: String { plugin }
        public var plugin: String
        public var why: String
        public init(plugin: String, why: String) { self.plugin = plugin; self.why = why }
    }
    public struct Recheck: Codable, Equatable, Sendable, Identifiable {
        public var id: String { plugin + note }
        public var plugin: String
        public var note: String
        public init(plugin: String, note: String) { self.plugin = plugin; self.note = note }
    }
    public var format = 1
    /// Never switched off. If one of these would have to go, the upgrade waits instead.
    public var neverOff: [Keep] = []
    /// What to try by hand after the upgrade. Never switches anything.
    public var recheck: [Recheck] = []
    public init() {}

    /// Names are matched ignoring case, so a rule written "OneBlock" still protects a plugin that calls itself "Oneblock".
    public func keep(_ name: String) -> Keep? { neverOff.first { $0.plugin.caseInsensitiveCompare(name) == .orderedSame } }
}

public struct PluginUpgradePlan: Equatable, Sendable {
    public struct Off: Equatable, Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var files: [String]
        /// In plain words, such as "It didn't start: …" or "Off because Chunky is off".
        public var why: [String]
    }
    public struct Blocked: Equatable, Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var rule: String
        public var why: [String]
    }
    public var target: String
    /// Set when there's nothing safe to offer at all, and says why.
    public var stop: String?
    public var off: [Off] = []
    /// Never-off plugins that would have to go. Any of these means the upgrade waits.
    public var blocked: [Blocked] = []
    /// For a person to decide. Nothing is switched off for these.
    public var warnings: [String] = []
    public var recheck: [UpgradeRules.Recheck] = []
    public var hasRules = false
    public var canApply: Bool { stop == nil && blocked.isEmpty && !off.isEmpty }
    public var allClear: Bool { stop == nil && blocked.isEmpty && off.isEmpty }

    public init(target: String, stop: String? = nil) { self.target = target; self.stop = stop }

    /// Works out the plan from a report. Doesn't touch anything.
    public static func make(report: PreflightReport?, rules: UpgradeRules?, target: String) -> PluginUpgradePlan {
        var plan = PluginUpgradePlan(target: target)
        plan.hasRules = rules != nil
        guard let report else { return PluginUpgradePlan(target: target, stop: "Preflight didn't write a report on the test copy, so nothing can be judged. Check that Preflight 0.2.0 or later is installed.") }
        guard report.format == 1 else {
            return PluginUpgradePlan(target: target, stop: report.format == nil
                ? "Preflight's report has no format number, so it's from a version too old for this. Preflight 0.2.0 or later is needed."
                : "Preflight's report is format \(report.format!), which this version of Leaf Juice doesn't know. Look for a Leaf Juice update.")
        }
        guard report.finishedAt != nil else { return PluginUpgradePlan(target: target, stop: "Preflight's report isn't finished, so nothing can be judged. Try the check again.") }
        if report.serverChecks == "failed" {
            return PluginUpgradePlan(target: target, stop: "Preflight's own server checks failed, so \(target) itself doesn't run properly on this server. Switching plugins off won't fix that.")
        }
        let rules = rules ?? UpgradeRules()
        let plugins = report.plugins
        func failedCritical(_ p: PreflightReport.Plugin) -> [PreflightReport.Test] {
            p.failedTests.compactMap { report.tests[$0] }.filter { $0.failed && $0.severity != "warning" }
        }

        // Why each plugin can't stay on by itself.
        var reasons: [String: [String]] = [:]
        for p in plugins.values {
            var why: [String] = []
            switch p.state {
            case .notLoaded: why.append("It didn't load." + (p.reason.map { " \($0)" } ?? ""))
            case .disabled: why.append("It didn't start." + (p.reason.map { " \($0)" } ?? ""))
            case .enabled, .unknown: break
            }
            if !p.missingDepends.isEmpty { why.append("It needs \(p.missingDepends.joined(separator: ", ")), which didn't load.") }
            for test in failedCritical(p) { why.append("It failed \(test.id)" + (test.message.map { ": \($0)" } ?? ".")) }
            if !why.isEmpty { reasons[p.name] = why }
        }

        // Whatever needs a plugin that goes off has to go too, however far down the chain.
        var off = reasons
        var queue = Array(reasons.keys)
        while let name = queue.popLast() {
            let needers = Set(plugins.values.filter { $0.depends.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }.map(\.name))
                .union(plugins[name]?.requiredBy ?? [])
            for needer in needers.sorted() where needer != name {
                if off[needer] == nil { queue.append(needer) }
                if off[needer]?.contains("Off because \(name) is off.") != true { off[needer, default: []].append("Off because \(name) is off.") }
            }
        }

        for name in off.keys.sorted(by: { $0.lowercased() < $1.lowercased() }) {
            if let rule = rules.keep(name) {
                plan.blocked.append(Blocked(name: name, rule: rule.why, why: off[name]!))
            } else {
                let files = plugins[name]?.files ?? []
                if files.isEmpty || files.contains(where: { $0.contains("/") || $0.hasPrefix(".") }) {
                    plan.blocked.append(Blocked(name: name, rule: "Preflight didn't say which file it is, so it can't be switched off safely.", why: off[name]!))
                } else {
                    plan.off.append(Off(name: name, files: files, why: off[name]!))
                }
            }
        }

        for test in report.tests.values.sorted(by: { $0.id < $1.id }) where test.failed && test.severity == "warning" {
            plan.warnings.append("\(test.id) warned" + (test.message.map { ": \($0)" } ?? "."))
        }
        for p in plugins.values.sorted(by: { $0.name < $1.name }) where off[p.name] == nil {
            let gone = p.softDepends.filter { soft in off.keys.contains { $0.caseInsensitiveCompare(soft) == .orderedSame } }
            if !gone.isEmpty { plan.warnings.append("\(p.name) stays on, but works with \(gone.joined(separator: ", ")), which would be off. Check it by hand.") }
        }
        let installed = Set(plugins.keys.map { $0.lowercased() })
        plan.recheck = rules.recheck.filter { installed.contains($0.plugin.lowercased()) }
        return plan
    }
}

/// Plugins this helper switched off, so they can be offered back. Kept in `.leafjuice/upgrade-switched-off.json`.
public struct SwitchedOffPlugins: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var files: [String]
        public var why: [String]
        public var date: Date
        public var target: String
    }
    public var entries: [Entry] = []
    public var backupFile: String?
    public init() {}
}

extension ServerPaths {
    public var upgradeRules: URL { meta.appendingPathComponent("upgrade-rules.json") }
    public var switchedOff: URL { meta.appendingPathComponent("upgrade-switched-off.json") }
}

extension ServerController {
    /// nil when there's no rules file. A file that can't be read is an error, not "no rules", because a missing
    /// never-off rule could let a protective plugin be switched off.
    public func upgradeRules() throws -> UpgradeRules? {
        guard FileOps.exists(paths.upgradeRules) else { return nil }
        guard let data = try? Data(contentsOf: paths.upgradeRules), let rules = try? JSONDecoder().decode(UpgradeRules.self, from: data) else {
            throw LeafError("\(paths.upgradeRules.path) couldn't be read, so no plugin plan is offered until it's fixed.")
        }
        guard rules.format == 1 else { throw LeafError("The upgrade rules file is format \(rules.format), which this version of Leaf Juice doesn't know.") }
        return rules
    }

    public func saveUpgradeRules(_ rules: UpgradeRules) throws {
        try FileOps.ensureDir(paths.meta)
        try JSONStore.save(rules, to: paths.upgradeRules)
    }

    public var switchedOffPlugins: SwitchedOffPlugins { JSONStore.load(paths.switchedOff, defaults: SwitchedOffPlugins()) }

    /// Boots a throwaway copy on `build` with Preflight warning instead of stopping, and works out the plan from its
    /// report. The real server isn't touched.
    public func checkPluginsForUpgrade(_ build: SoftwareBuild, waitForReport: Duration = .seconds(180)) async -> PluginUpgradePlan {
        let target = "\(build.flavor.title) \(build.label)"
        let rules: UpgradeRules?
        do { rules = try upgradeRules() } catch { return PluginUpgradePlan(target: target, stop: error.localizedDescription) }
        guard plugins.contains(where: { $0.enabled && $0.key == "preflight" }) else {
            return PluginUpgradePlan(target: target, stop: "Preflight isn't installed on this server, and the check needs it. Install Preflight 0.2.0 or later first.")
        }
        await startTrial(.custom(title: "Check plugins on \(target)") { child in
            try await child.installSoftware(build)
            child.profile.launch.extraJVMArgs += " -Dpreflight.on-failure=WARN"
        }, keepOpen: true)
        return await planFromOpenTrial(target: target, rules: rules, waitForReport: waitForReport)
    }

    /// Reads Preflight's report from the test copy once it's finished, then deletes the copy.
    func planFromOpenTrial(target: String, rules: UpgradeRules?, waitForReport: Duration) async -> PluginUpgradePlan {
        guard trialPhase == .open, let folder = trialFolder else {
            let why = trialReport?.failure ?? trialReport?.blockers.first ?? "it didn't start"
            await collapseTrial()
            return PluginUpgradePlan(target: target, stop: "The test copy on \(target) couldn't be checked: \(why)")
        }
        let file = folder.appendingPathComponent(PreflightReport.fileName)
        var report: PreflightReport?
        let deadline = ContinuousClock.now + waitForReport
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: file), let read = PreflightReport.parse(data), read.finishedAt != nil { report = read; break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if report == nil, let data = try? Data(contentsOf: file) { report = PreflightReport.parse(data) }
        // The copy has done its job, and none is left between runs.
        await collapseTrial()
        return PluginUpgradePlan.make(report: report, rules: rules, target: target)
    }

    /// Switches off what the plan lists, on the real server. It must be stopped, and a verified restore point is
    /// taken first. If any file can't be moved, the ones already moved are put back.
    public func applyPluginPlan(_ plan: PluginUpgradePlan) async throws {
        guard plan.canApply else { throw LeafError(plan.stop ?? (plan.blocked.isEmpty ? "There's nothing to switch off." : "A plugin that must stay on would have to go, so the upgrade waits.")) }
        guard state.canStart, !state.isLive else { throw LeafError("Stop the server first. Plugins are only switched off while it's stopped.") }
        // Every file must be there and switched on before anything moves.
        for item in plan.off {
            for file in item.files where !FileOps.exists(paths.plugins.appendingPathComponent(file)) {
                throw LeafError("\(file) isn't in the plugins folder as it was on the test copy, so nothing was changed. Check the plugins again.")
            }
        }
        let point: BackupRecord? = isTrialCopy ? nil : try await makeRestorePoint()
        var moved: [URL] = []
        do {
            for item in plan.off {
                for file in item.files {
                    let jar = paths.plugins.appendingPathComponent(file)
                    try FileOps.move(jar, to: jar.appendingPathExtension("disabled"))
                    moved.append(jar)
                }
            }
        } catch {
            for jar in moved.reversed() { try? FileOps.move(jar.appendingPathExtension("disabled"), to: jar) }
            throw LeafError("Switching plugins off stopped part-way, so the ones already switched off were put back. \(error.localizedDescription)")
        }
        var record = switchedOffPlugins
        record.entries.removeAll { entry in plan.off.contains { $0.name == entry.name } }
        record.entries += plan.off.map { .init(name: $0.name, files: $0.files, why: $0.why, date: Date(), target: plan.target) }
        record.backupFile = point?.fileName ?? record.backupFile
        try JSONStore.save(record, to: paths.switchedOff)
        await refreshPlugins()
        appendWrapper("Switched off for \(plan.target): \(plan.off.map(\.name).joined(separator: ", ")).", level: .info)
        recordEvent(.plugin, "Plugins switched off for \(plan.target)", detail: plan.off.map(\.name).joined(separator: ", "))
    }

    /// Puts plugins the helper switched off back on. Only while stopped.
    public func switchBackOn(_ names: [String]) async throws {
        guard state.canStart, !state.isLive else { throw LeafError("Stop the server first. Plugins are only switched on while it's stopped.") }
        var record = switchedOffPlugins
        let chosen = record.entries.filter { names.contains($0.name) }
        for entry in chosen {
            for file in entry.files {
                let jar = paths.plugins.appendingPathComponent(file), off = jar.appendingPathExtension("disabled")
                guard FileOps.exists(off) else { continue }
                guard !FileOps.exists(jar) else { throw LeafError("\(file) is already in the plugins folder, switched on, so \(entry.name) was left as it is.") }
                try FileOps.move(off, to: jar)
            }
        }
        record.entries.removeAll { names.contains($0.name) }
        if record.entries.isEmpty { try? FileManager.default.removeItem(at: paths.switchedOff) } else { try JSONStore.save(record, to: paths.switchedOff) }
        await refreshPlugins()
        if !chosen.isEmpty {
            appendWrapper("Switched back on: \(chosen.map(\.name).joined(separator: ", ")).", level: .info)
            recordEvent(.plugin, "Plugins switched back on", detail: chosen.map(\.name).joined(separator: ", "))
        }
    }
}
