import Foundation

extension ServerController {
    // MARK: Renames

    public func worldRenamePlan(_ world: WorldEntry, to new: String) -> RenamePlan {
        WorldRename.plan(world: world, to: new, paths: paths)
    }

    public func serverRenamePlan(name: String, folder: String?, motd: String? = nil) -> RenamePlan {
        ServerRename.plan(oldName: profile.name, newName: name, oldFolder: paths.root.lastPathComponent, newFolder: folder, motd: motd, paths: paths)
    }

    /// Makes the selected changes. Any failure part-way puts the files back from the restore point,
    /// so a rename either happens completely or not at all.
    /// `rebuild` works the plan out again once the server has stopped, because plugins save their files
    /// on the way down and the previewed text could be out of date. Choices made in the preview carry over.
    public func applyRename(_ previewed: RenamePlan, rebuild: (@MainActor () -> RenamePlan)? = nil, restart: Bool = true, afterwards: (@MainActor () throws -> Void)? = nil) async throws {
        let wasRunning = state == .running
        try await stopAndWait()
        var plan = rebuild?() ?? previewed
        let unchosen = Set(previewed.items.filter { !$0.selected }.map(\.location))
        for i in plan.items.indices where unchosen.contains(plan.items[i].location) { plan.items[i].selected = false }
        let point: BackupRecord? = isTrialCopy || !hasWorld ? nil : try await makeRestorePoint()
        setActivity(plan.title + "…")
        defer { setActivity(nil) }
        let before = profile.software
        // As the restore point holds them, not as they'll be named afterwards.
        let worldsBefore = Backups.worldFolders(paths.root)
        do {
            for item in plan.items where item.selected { try apply(item) }
            try afterwards?()
        } catch {
            if let point {
                try? await Backups.restore(point, profile: profile, root: paths.root)
                refreshConfigs()
                throw LeafError("The rename stopped part-way, so everything was put back. \(error.localizedDescription)")
            }
            throw error
        }
        if let point {
            setActiveUpgrade(UpgradeRecord(
                from: before, toLabel: plan.title, toFileName: before.jarName, backupFile: point.fileName,
                backupFolder: Backups.destination(profile).path, worlds: worldsBefore, size: point.size, isRename: true))
        }
        refreshConfigs()
        await refreshWorlds()
        appendWrapper("\(plan.title): done.", level: .info)
        if wasRunning, restart { await start() }
    }

    private func apply(_ item: RenameItem) throws {
        switch item.action {
        case let .moveFolder(from, to):
            let source = paths.root.appendingPathComponent(from), target = paths.root.appendingPathComponent(to)
            guard FileOps.exists(source) else { return }
            guard !FileOps.exists(target) else { throw LeafError("\(to) already exists.") }
            try FileOps.ensureDir(target.deletingLastPathComponent())
            try FileManager.default.moveItem(at: source, to: target)
        case let .replaceFile(path, text):
            try FileOps.writeAtomic(text, to: paths.root.appendingPathComponent(path))
        case let .levelName(path, name):
            let url = paths.root.appendingPathComponent(path)
            guard FileOps.exists(url) else { return }
            var doc = try NBT.read(url)
            guard var data = doc.root["Data"], data["LevelName"] != nil else { return }
            data["LevelName"] = .string(name)
            doc.root["Data"] = data
            try NBT.write(doc, to: url)
        }
    }

    // MARK: Test copies

    /// Tries a change on a throwaway copy of the server. The real server isn't touched.
    public func startTrial(_ change: TrialChange, keepOpen: Bool = false) async {
        guard trialPhase == nil || trialPhase == .finished else { return }
        trialReport = nil
        trialChange = change
        trialPhase = .copying
        var report = TrialReport()
        do {
            let copy = paths.root.deletingLastPathComponent()
                .appendingPathComponent(AppPaths.ownFolderName, isDirectory: true).appendingPathComponent("test-copies", isDirectory: true)
                .appendingPathComponent("\(paths.root.lastPathComponent)-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
            trialFolder = copy
            // A running server pauses saving for the moment it takes to copy.
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
            if wasRunning { process?.send("save-on") }

            // Its own identity, port and data: it must not be mistaken for the real thing.
            let copyPaths = ServerPaths(root: copy)
            try? FileManager.default.removeItem(at: copyPaths.meta)
            try? FileManager.default.removeItem(at: copy.appendingPathComponent("logs"))
            removeLocks(in: copy)
            var doc = PropertiesDocument((try? String(contentsOf: copyPaths.properties, encoding: .utf8)) ?? "")
            let port = Trial.freePort(after: serverPort)
            doc.set("server-port", String(port))
            doc.set("enable-rcon", "false")
            doc.set("enable-query", "false")
            doc.set("motd", "Test copy of \(profile.name)")
            try FileOps.writeAtomic(doc.text, to: copyPaths.properties)
            for plugin in plugins where plugin.enabled && Trial.disabledInCopies.contains(plugin.key) {
                let jar = copyPaths.plugins.appendingPathComponent(plugin.fileName)
                try? FileOps.move(jar, to: jar.appendingPathExtension("disabled"))
                report.notes.append("\(plugin.name) is off in the copy, so it can't reach anything outside.")
            }
            for name in Trial.databasePlugins(paths) {
                report.notes.append("\(name) uses an outside database, and the copy shares it. Test it with care.")
            }

            var p = profile
            p.id = UUID()
            p.name = "Test copy of \(profile.name)"
            p.backup.enabled = false
            p.backup.destination = copyPaths.meta.appendingPathComponent("backups").path
            p.restart.enabled = false
            p.launch.restartOnCrash = false
            p.launch.startWithApp = false
            p.launch.keepAwake = false
            p.launch.minMemoryMB = min(p.launch.minMemoryMB, 1024)
            p.launch.maxMemoryMB = min(p.launch.maxMemoryMB, 4096)
            p.lastPluginCheck = Date()
            p.software.lastCheck = Date()
            p.playerSnapshots.enabled = false
            try FileOps.ensureDir(copyPaths.meta)
            let child = ServerController(root: copy, profile: p)
            child.isTrialCopy = true
            child.requiresEULA = requiresEULA
            child.runtimes = runtimes
            trialController = child
            await child.refreshPlugins()

            trialPhase = .applying
            switch change {
            case let .software(build):
                try await child.installSoftware(build)
            case let .pluginUpdate(name):
                guard let plugin = child.plugins.first(where: { $0.name == name }), let record = records[plugin.key] else {
                    throw LeafError("\(name) isn't in the copy.")
                }
                child.adoptRecord(record, key: plugin.key)
                try await child.installUpdate(for: plugin)
            case let .worldRename(worldName, to):
                await child.refreshWorlds()
                guard let world = child.worlds.first(where: { $0.name == worldName }) else { throw LeafError("\(worldName) isn't in the copy.") }
                try await child.applyRename(child.worldRenamePlan(world, to: to), restart: false)
            case let .serverRename(to):
                try await child.applyRename(child.serverRenamePlan(name: to, folder: nil), restart: false)
            case let .custom(_, work):
                try await work(child)
            }
            if let held = child.pending.compactMap(\.conflict).first { throw LeafError(held) }

            trialPhase = .booting
            let started = Date()
            await child.start()
            if !child.blockers.isEmpty {
                report.blockers = child.blockers.map(\.title)
                finishTrial(report)
                return
            }
            for _ in 0..<(600 * 4) {
                if child.state == .running || child.state.canStart { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            report.booted = child.state == .running
            report.seconds = report.booted ? Date().timeIntervalSince(started) : nil
            if !report.booted {
                report.failure = "It didn't finish starting."
                report.problems = child.console.filter { $0.level >= .warn }.suffix(8).map(\.text)
            }

            trialPhase = .checking
            if report.booted { try? await Task.sleep(for: .seconds(isTrialFast ? 1 : 10)) }
            collect(into: &report, child: child)
            if keepOpen, report.booted {
                trialReport = report
                trialPhase = .open
                return
            }
            await stopChild(child)
            finishTrial(report)
        } catch {
            report.failure = error.localizedDescription
            if let child = trialController { await stopChild(child) }
            finishTrial(report)
        }
    }

    private func removeLocks(in root: URL) {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in walker {
            if file.lastPathComponent == "session.lock" { try? FileManager.default.removeItem(at: file) }
            if walker.level > 4 { walker.skipDescendants() }
        }
    }

    private func collect(into report: inout TrialReport, child: ServerController) {
        let known = Set(issues.map(\.id))
        let fresh = child.issues.filter { $0.status == .open && $0.severity >= .error && !known.contains($0.id) }
        report.problems += fresh.map { $0.count > 1 ? "\($0.title) (\($0.count) times)" : $0.title }
        let pluginRules: Set<String> = ["plugin-load-failed", "plugin-enable-failed", "plugin-unsupported-api", "plugin-unknown-dependency", "plugin-class-mismatch"]
        report.failedPlugins = fresh.filter { pluginRules.contains($0.ruleID ?? "") }.map { $0.plugin ?? $0.title }
        // Paper announces each plugin it enables, so a silent absence counts too.
        if report.booted, child.profile.software.flavor != .custom {
            for plugin in child.plugins where plugin.enabled && plugin.descriptor != nil {
                if !child.console.contains(where: { $0.text.contains("Enabling \(plugin.name)") }), !report.failedPlugins.contains(plugin.name) {
                    report.failedPlugins.append(plugin.name)
                }
            }
        }
    }

    private func stopChild(_ child: ServerController) async {
        if child.state == .running || child.state == .starting { child.stop() }
        for _ in 0..<(150 * 4) where child.state.isLive { try? await Task.sleep(for: .milliseconds(250)) }
        if child.state.isLive { child.forceStop() }
    }

    private func finishTrial(_ report: TrialReport) {
        trialReport = report
        trialPhase = .finished
    }

    /// Ends a test copy that was left running to try in game.
    public func finishOpenTrial() async {
        guard let child = trialController else { return }
        var report = trialReport ?? TrialReport()
        collect(into: &report, child: child)
        await stopChild(child)
        finishTrial(report)
    }

    /// Finds which plugin causes a problem by booting the copy with half of them, then halving again.
    /// Plugins can't be switched on reliably in a running server, so each step is a real boot.
    public func findTrialCulprit() async {
        guard let child = trialController, trialPhase == .finished, var report = trialReport else { return }
        await stopChild(child)
        func boot(_ enabled: Set<String>, step: String) async -> Bool {
            trialPhase = .searching(step)
            let all = await PluginScanner.scan(child.paths)
            // Whatever a plugin needs has to come along with it.
            var wanted = enabled
            var grew = true
            while grew {
                grew = false
                for p in all where wanted.contains(p.key) {
                    for need in p.descriptor?.depend ?? [] where wanted.insert(need.lowercased()).inserted { grew = true }
                }
            }
            for p in all where p.descriptor != nil {
                let on = wanted.contains(p.key)
                if on == p.enabled { continue }
                let url = child.paths.plugins.appendingPathComponent(p.fileName)
                try? FileOps.move(url, to: on ? url.deletingPathExtension() : url.appendingPathExtension("disabled"))
            }
            await child.refreshPlugins()
            child.clearIssues()
            child.clearConsole()
            await child.start()
            guard child.blockers.isEmpty else { return false }
            for _ in 0..<(300 * 4) {
                if child.state == .running || child.state.canStart { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            let up = child.state == .running
            if up { try? await Task.sleep(for: .seconds(isTrialFast ? 1 : 5)) }
            var check = TrialReport()
            check.booted = up
            collect(into: &check, child: child)
            await stopChild(child)
            return up && check.failedPlugins.isEmpty
        }

        let suspects = await PluginScanner.scan(child.paths)
            .filter { $0.descriptor != nil && $0.enabled && !report.notes.contains("\($0.name) is off in the copy, so it can't reach anything outside.") }
            .map(\.key).sorted()
        if await boot([], step: "Starting the copy with no plugins…") == false {
            report.culprit = "It has the problem even with no plugins, so a plugin isn't the cause."
        } else {
            var remaining = suspects
            var round = 1
            while remaining.count > 1 {
                let half = Array(remaining.prefix(remaining.count / 2))
                let ok = await boot(Set(half), step: "Search round \(round): trying \(half.count) of \(remaining.count) plugins…")
                remaining = ok ? Array(remaining.dropFirst(half.count)) : half
                round += 1
            }
            if let found = remaining.first {
                let alone = await boot([found], step: "Confirming \(found)…")
                let name = await PluginScanner.scan(child.paths).first { $0.key == found }?.name ?? found
                report.culprit = alone
                    ? "No single plugin causes it alone. \(name) was the last suspect, so it may be a combination of plugins."
                    : "\(name) causes it. It has the problem by itself, along with anything it depends on."
            } else {
                report.culprit = "There are no plugins to suspect."
            }
        }
        finishTrial(report)
    }

    /// Removes the copy. The real server was never involved.
    public func collapseTrial() async {
        if let child = trialController {
            await stopChild(child)
            child.stopTicker()
        }
        if let folder = trialFolder { try? FileManager.default.removeItem(at: folder) }
        trialController = nil
        trialFolder = nil
        trialPhase = nil
        trialReport = nil
        trialChange = nil
    }

    /// The copy worked: remove it, and make the same change for real, with its restore point.
    public func proceedAfterTrial() async throws {
        guard let change = trialChange else { return }
        await collapseTrial()
        switch change {
        case let .software(build):
            try await installSoftware(build)
        case let .pluginUpdate(name):
            if let plugin = plugins.first(where: { $0.name == name }) { try await installUpdate(for: plugin) }
        case let .worldRename(worldName, to):
            await refreshWorlds()
            guard let world = worlds.first(where: { $0.name == worldName }) else { throw LeafError("\(worldName) wasn't found.") }
            try await applyRename(worldRenamePlan(world, to: to), rebuild: { [self] in worldRenamePlan(world, to: to) })
        case let .serverRename(to):
            try await applyRename(serverRenamePlan(name: to, folder: nil), rebuild: { [self] in serverRenamePlan(name: to, folder: nil) })
        case .custom:
            break
        }
    }

    /// For quitting: a copy can't outlive the app.
    public func stopTrialCopy() { trialController?.stop() }
    public var trialIsLive: Bool { trialController?.state.isLive ?? false }

    // MARK: Players

    public func refreshPlayers() async {
        let p = paths
        let (found, history, merges) = await Task.detached(priority: .utility) {
            (PlayerFiles.list(p), PlayerHistory.read(p), PlayerMerge.suggestions(p))
        }.value
        knownPlayers = found
        playerHistory = history
        mergeSuggestions = merges
    }

    public func playerSnapshots(_ player: PlayerInfo) -> [PlayerSnapshot] {
        PlayerSnapshots.list(uuid: player.uuid, profile: profile)
    }

    @discardableResult
    public func snapshotPlayer(_ player: PlayerInfo) throws -> PlayerSnapshot {
        try PlayerSnapshots.take(uuid: player.uuid, name: player.title, trigger: "manual", paths: paths, profile: profile)
    }

    /// Takes the periodic snapshot for players online. Runs from the ticker.
    func tickPlayerSnapshots(elapsed: TimeInterval) {
        guard profile.playerSnapshots.enabled, !isTrialCopy, state == .running else { return }
        let interval = Double(max(1, profile.playerSnapshots.intervalMinutes)) * 60
        for name in players {
            playSeconds[name, default: 0] += elapsed
            guard playSeconds[name, default: 0] >= interval else { continue }
            playSeconds[name] = 0
            takeAutomaticSnapshot(name: name, trigger: "playing")
        }
    }

    func takeAutomaticSnapshot(name: String, trigger: String) {
        let names = PlayerFiles.userCache(paths)
        guard let uuid = playerUUIDs[name] ?? names.first(where: { $0.value == name })?.key else { return }
        do {
            try PlayerSnapshots.take(uuid: uuid, name: name, trigger: trigger, paths: paths, profile: profile, keep: profile.playerSnapshots.keep)
        } catch {
            appendWrapper("Couldn't snapshot \(name): \(error.localizedDescription)", level: .warn)
        }
    }

    /// Restores a player without touching the world. Waits for a restart whenever the server might overwrite it.
    public func restorePlayer(_ snapshot: PlayerSnapshot, inventoryOnly: Bool, containers: [String]) throws -> SaveOutcome {
        let online = players.contains(snapshot.name)
        // Multiverse-Inventories keeps profiles in memory, so its files are only safe while stopped.
        let needsStop = !state.canStart && (online || !containers.isEmpty)
        if needsStop {
            enqueue(PendingChange(
                kind: .playerRestore(folder: snapshot.folder, uuid: snapshot.uuid, name: snapshot.name, inventoryOnly: inventoryOnly, containers: containers),
                summary: "Restore \(snapshot.name) from \(snapshot.date.formatted(date: .abbreviated, time: .shortened))"))
            return .staged
        }
        try applyPlayerRestore(snapshot, inventoryOnly: inventoryOnly, containers: containers)
        return .saved
    }

    func applyPlayerRestore(_ snapshot: PlayerSnapshot, inventoryOnly: Bool, containers: [String]) throws {
        try PlayerSnapshots.take(uuid: snapshot.uuid, name: snapshot.name, trigger: "before-restore", paths: paths, profile: profile)
        try PlayerSnapshots.restore(snapshot, inventoryOnly: inventoryOnly, containers: containers, paths: paths, profile: profile)
        appendWrapper("Restored \(snapshot.name) from \(snapshot.date.formatted(date: .abbreviated, time: .shortened)).", level: .info)
    }

    /// Merges two profiles, after a verified restore point.
    public func mergePlayers(_ plan: MergePlan) async throws {
        let wasRunning = state == .running
        try await stopAndWait()
        let point: BackupRecord? = hasWorld ? try await makeRestorePoint() : nil
        setActivity("Merging \(plan.from.title) into \(plan.to.title)…")
        defer { setActivity(nil) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let archive = Backups.destination(profile).appendingPathComponent("MergedPlayers/\(f.string(from: Date()))", isDirectory: true)
        do {
            try PlayerMerge.apply(plan, paths: paths, archive: archive)
        } catch {
            if let point { try? await Backups.restore(point, profile: profile, root: paths.root) }
            throw LeafError("The merge stopped part-way, so everything was put back. \(error.localizedDescription)")
        }
        if let point {
            setActiveUpgrade(UpgradeRecord(
                from: profile.software, toLabel: "Merge \(plan.from.title) into \(plan.to.title)", toFileName: profile.software.jarName,
                backupFile: point.fileName, backupFolder: Backups.destination(profile).path, worlds: Backups.worldFolders(paths.root), size: point.size, isRename: true))
        }
        await refreshPlayers()
        if wasRunning { await start() }
    }

    // MARK: Cleanup

    public func scanForCleanup() async {
        let (profile, paths, plugins) = (self.profile, self.paths, self.plugins)
        let found = await Task.detached(priority: .utility) { Cleanup.scan(profile, paths: paths, plugins: plugins) }.value
        cleanupItems = found
        cleanupBatches = Cleanup.batches(profile)
    }

    public func cleanUp(_ items: [CleanupItem]) async throws {
        guard state.canStart else { throw LeafError("Stop the server before cleaning up its folder.") }
        _ = try Cleanup.apply(items, profile: profile, paths: paths)
        await refreshPlugins()
        await scanForCleanup()
    }

    public func undoCleanup(_ batch: CleanupBatch) async throws {
        guard state.canStart else { throw LeafError("Stop the server first.") }
        try Cleanup.undo(batch, profile: profile, paths: paths)
        await refreshPlugins()
        await scanForCleanup()
    }

    public func discardCleanup(_ batch: CleanupBatch) async throws {
        try Cleanup.discard(batch, profile: profile)
        await scanForCleanup()
    }

    // MARK: TPS, connection, disk

    /// Asks a Paper-family server for its ticks per second. The answer is kept out of the console view.
    public func requestTPS() {
        guard state == .running, profile.software.flavor != .vanilla, let process else { return }
        awaitingTPS = true
        process.send("tps")
    }

    public func checkConnection() async throws {
        connectResult = try await ConnectCheck.run(port: serverPort)
    }

    public func clearConnectionResult() { connectResult = nil }

    func tickDisk() {
        guard !isTrialCopy else { return }
        var worst: (message: String, critical: Bool)?
        for (url, name) in [(paths.root, "this server"), (Backups.destination(profile), "its backups")] {
            guard let free = FileOps.freeSpace(at: url), let warning = DiskCheck.warning(free: free, name: name) else { continue }
            if worst == nil || (warning.critical && !(worst?.critical ?? false)) { worst = warning }
        }
        diskWarning = worst?.message
        if let worst, worst.critical, state.isLive {
            let now = Date()
            reportIssue(IssueRecord(
                id: "wrapper:disk-low", ruleID: "wrapper-disk-low", title: "The disk is nearly full", severity: .critical, category: "System",
                explanation: worst.message, steps: ["Free up space on the drive.", "Keep fewer backups, or move them to another drive."],
                action: IssueAction(page: "backups", label: "Open Backups"), sample: worst.message, firstSeen: now, lastSeen: now))
        }
    }
}
