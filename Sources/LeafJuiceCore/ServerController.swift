import Foundation
import Observation

public struct RestartPlan: Equatable, Sendable {
    public var at: Date?
    public var whenEmpty = false
    public var reason: String
    public var warned: Set<Int> = []
    public init(at: Date? = nil, whenEmpty: Bool = false, reason: String) {
        self.at = at; self.whenEmpty = whenEmpty; self.reason = reason
    }
}

public struct ReadinessRow: Identifiable, Equatable, Sendable {
    public var id: String { plugin }
    public let plugin: String
    public let verdict: Compatibility.Verdict?
    public let detail: String
}

/// One server: its process, settings and everything that happens to it. All state lives on the main actor.
@MainActor @Observable
public final class ServerController: Identifiable {
    @ObservationIgnored var accessApplying = false
    /// Only tests turn this on, because bots can't join an online-mode server.
    @ObservationIgnored var accessAllowsOffline = false
    public nonisolated let id: UUID
    public private(set) var paths: ServerPaths
    public var profile: ServerProfile { didSet { if profile != oldValue { saveProfile() } } }

    public private(set) var state: ServerState = .stopped
    public private(set) var startedAt: Date?
    public private(set) var players: Set<String> = []
    public private(set) var metrics: ProcessMetrics?
    public private(set) var console: [ConsoleLine] = []
    public private(set) var issues: [IssueRecord] = []
    public private(set) var plugins: [InstalledPlugin] = []
    public private(set) var records: [String: PluginRecord] = [:]
    public private(set) var pending: [PendingChange] = []
    public private(set) var backups: [BackupRecord] = []
    public private(set) var configs: [ConfigFile] = []
    public private(set) var worlds: [WorldEntry] = []
    public private(set) var worldOperation: WorldOperation?
    /// An upgrade you haven't yet decided to keep or roll back.
    public private(set) var activeUpgrade: UpgradeRecord?
    public private(set) var shelved: [ShelvedUpgrade] = []

    public internal(set) var knownPlayers: [PlayerInfo] = []
    public internal(set) var playerHistory: [PlayerSession] = []
    public internal(set) var mergeSuggestions: [MergeSuggestion] = []
    public internal(set) var cleanupItems: [CleanupItem] = []
    public internal(set) var cleanupBatches: [CleanupBatch] = []
    public internal(set) var tps: TPSReading?
    public internal(set) var mspt: Double?
    public internal(set) var timeline: [ServerEvent] = []
    public internal(set) var metricHistory: [MetricSample] = []
    public internal(set) var sizeHistory: [DailySizes] = []
    public internal(set) var playerStats: [PlayerStats] = []
    public internal(set) var playerActivity: [PlayerActivity] = []
    public internal(set) var drillRunning = false
    var lastTPSRequest = Date.distantPast
    var lastSizeCheck = Date.distantPast
    var lagging = false
    public internal(set) var failedJoins: [FailedJoin] = []
    var awaitingMSPT = 0
    var bucket = MetricBucket()
    var gcReadOffset: UInt64 = 0
    public internal(set) var diskWarning: String?
    public internal(set) var connectResult: ConnectResult?
    public internal(set) var trialPhase: TrialPhase?
    public internal(set) var trialReport: TrialReport?
    public internal(set) var trialChange: TrialChange?
    public internal(set) var trialController: ServerController?
    var trialFolder: URL?
    /// This controller runs a throwaway copy: no restore points, schedules or snapshots.
    public internal(set) var isTrialCopy = false
    var isTrialFast = false
    var awaitingTPS = false
    var playSeconds: [String: TimeInterval] = [:]
    var playerUUIDs: [String: String] = [:]
    private var lastTick: Date?
    private var tickCount = 0
    public private(set) var restartPlan: RestartPlan?
    public private(set) var softwareUpdate: SoftwareBuild?
    public private(set) var launchedCommand: [String]?
    public var nextScheduledRestart: Date?

    public var blockers: [Blocker] = []
    /// Set by the app, to tell you about something you'd otherwise only see with Leaf Juice open in front of you.
    public var onAlert: (@MainActor (_ title: String, _ detail: String) -> Void)?
    /// The most recent ones, so tests and the app can both see what's been raised.
    public private(set) var recentAlerts: [String] = []
    public private(set) var activity: String?
    public private(set) var activityProgress: Double?
    public var notice: String?
    public private(set) var checkingPlugins = false

    /// Picks which Java runs a server. The app replaces this list on demand.
    public var runtimes: [JavaRuntime] = []

    var process: ServerProcess?
    private let sampler = MetricsSampler()
    private let analyzer = IssueAnalyzer()
    private var lineBuffer: [String] = []
    private var flushScheduled = false
    private var nextLineID = 0
    private var expectingStop = false
    private var restartAfterStop = false
    private var crashTimes: [Date] = []
    private var stopDeadline: Task<Void, Never>?
    private var waiters: [(needles: [String], resume: (String?) -> Void)] = []
    private var ticker: Task<Void, Never>?
    private var backingUp = false
    private var startedStopWhileStarting = false
    private var sleepAssertion: NSObjectProtocol?
    private var pendingRestorePoint: BackupRecord?

    public static let consoleLimit = 5000
    /// Only turned off by tests that run a stand-in jar rather than Minecraft.
    var requiresEULA: Bool = {
        #if DEBUG
        // Debug builds only, for looking at the interface with a stand-in jar. Never in a release build.
        return ProcessInfo.processInfo.environment["LEAFJUICE_STANDIN_JAR"] == nil
        #else
        return true
        #endif
    }()

    public init(root: URL, profile: ServerProfile) {
        self.id = profile.id
        self.paths = ServerPaths(root: root)
        self.profile = profile
        load()
    }

    /// Opens a folder that's already managed by Leaf Juice.
    public static func open(root: URL) -> ServerController? {
        let paths = ServerPaths(root: root)
        guard let profile = readProfile(root: root) else { return nil }
        let controller = ServerController(root: root, profile: profile)
        // An unreadable settings file is set aside, so without this the server would just look reset.
        let saved = ServerPaths(root: root).profile
        if FileOps.exists(saved.appendingPathExtension("corrupt")), !FileOps.exists(saved) {
            controller.notice = "This server's Leaf Juice settings couldn't be read, so they're back to their defaults. The old file was kept as server.json.corrupt in its .leafjuice folder."
        }
        // The Lab is disposable, so it skips restore points, schedules and analytics.
        controller.isTrialCopy = LabFiles.isLab(root: root, profile: profile)
        return controller
    }

    static func readProfile(root: URL) -> ServerProfile? {
        let paths = ServerPaths(root: root)
        guard FileOps.exists(paths.profile) else { return nil }
        return JSONStore.load(paths.profile, defaults: ServerProfile())
    }

    /// The Lab can't be removed or renamed.
    public var isLab: Bool { LabFiles.isLab(root: paths.root, profile: profile) }

    /// Starts managing an existing folder. Only `.leafjuice` is written; the server is left as it was.
    public static func adopt(root: URL, name: String?) async throws -> ServerController {
        if let existing = open(root: root) { return existing }
        guard FileOps.isDirectory(root) else { throw LeafError("That folder doesn't exist.") }
        var profile = ServerProfile()
        profile.name = name?.isEmpty == false ? name! : root.lastPathComponent
        let detected = await ServerDetector.detect(root)
        profile.software = detected.software
        if let launch = detected.launch { profile.launch = launch }
        profile.launch.maxMemoryMB = min(profile.launch.maxMemoryMB, SystemInfo.memoryMB * 3 / 4)
        profile.launch.minMemoryMB = min(profile.launch.minMemoryMB, profile.launch.maxMemoryMB)
        let controller = ServerController(root: root, profile: profile)
        controller.saveProfile()
        controller.notice = detected.notes.isEmpty ? nil : detected.notes.joined(separator: " ")
        // Past problems are worth knowing about straight away.
        controller.scanLatestLog()
        return controller
    }

    private func load() {
        records = JSONStore.load(paths.pluginRecords, defaults: [:])
        pending = JSONStore.load(paths.pending, defaults: [])
        // Read directly: the merge in JSONStore.load needs a default value, and "no upgrade" isn't one.
        activeUpgrade = (try? Data(contentsOf: paths.activeUpgrade)).flatMap { try? JSONStore.decoder.decode(UpgradeRecord.self, from: $0) }
        shelved = JSONStore.load(paths.shelved, defaults: [])
        let saved: [IssueRecord] = JSONStore.load(paths.issues, defaults: [])
        // Rules improve between versions, so an issue saved as uncategorized gets another look.
        saved.forEach { issue in
            if !issue.isKnown, issue.status == .open, analyzer.ruleMatches(issue.sample) {
                analyzer.ingest(issue.sample, at: issue.lastSeen)
            } else {
                analyzer.restore(issue)
            }
        }
        analyzer.markClean()
        issues = analyzer.sorted
        refreshConfigs()
        // Wait for a servers folder to be chosen before putting anything in it.
        if !AppPaths.needsServersFolderChoice { pinBackupFolder() }
        refreshBackups()
        nextScheduledRestart = profile.restart.enabled ? profile.restart.next(after: Date()) : nil
        Task {
            await refreshPlugins()
            await detectExternalServer()
            runtimes = await JavaManager.discover()
        }
        startTicker()
    }

    private func saveProfile() { try? JSONStore.save(profile, to: paths.profile) }
    private func savePending() { try? JSONStore.save(pending, to: paths.pending) }
    private func saveRecords() { try? JSONStore.save(records, to: paths.pluginRecords) }

    func setActivity(_ text: String?, progress: Double? = nil) {
        activity = text
        activityProgress = progress
    }

    // MARK: Rename

    /// Renames the server. Moving the folder is optional, and only possible while it's stopped.
    public func rename(to name: String, moveFolderTo folderName: String?) throws -> URL? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isLab else { throw LeafError("The Lab keeps its name, so Leaf Juice can always find it.") }
        guard !clean.isEmpty else { throw LeafError("The name can't be empty.") }
        var moved: URL?
        if let folderName, folderName != paths.root.lastPathComponent {
            guard !state.isLive else { throw LeafError("Stop the server before renaming its folder.") }
            guard !folderName.isEmpty, !folderName.contains("/"), !folderName.hasPrefix(".") else {
                throw LeafError("That isn't a usable folder name.")
            }
            let target = paths.root.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
            guard !FileOps.exists(target) else { throw LeafError("A folder called \(folderName) already exists there.") }
            try FileManager.default.moveItem(at: paths.root, to: target)
            paths = ServerPaths(root: target)
            moved = target
        }
        profile.name = clean
        moveBackupFolderForRename()
        return moved
    }

    // MARK: Lifecycle

    public var javaRequirement: Int {
        profile.software.requiredJava ?? profile.software.gameVersion.map(JavaRequirement.estimated) ?? 8
    }

    /// The Java that would be used for the next start.
    public func resolvedJava() -> JavaRuntime? {
        if let path = profile.launch.javaPath {
            return runtimes.first { $0.path == path } ?? JavaRuntime(path: path, version: "?", major: 0, vendor: nil, managed: false)
        }
        return JavaManager.best(for: javaRequirement, in: runtimes)
    }

    /// Says something once, not on every tick, for as long as it stays the same.
    public func raiseAlert(_ title: String, _ detail: String) {
        guard !isTrialCopy else { return }
        recentAlerts = Array((recentAlerts + [title]).suffix(20))
        onAlert?(title, detail)
    }

    public var serverPort: Int {
        let text = try? String(contentsOf: paths.properties, encoding: .utf8)
        return text.flatMap { PropertiesDocument($0).value("server-port") }.flatMap(Int.init) ?? 25565
    }

    public func preflight() async -> [Blocker] {
        var out: [Blocker] = []
        let jar = paths.root.appendingPathComponent(profile.software.jarName)
        let swapPending = pending.contains { if case .software = $0.kind { true } else { false } }
        if !swapPending, profile.software.jarName.isEmpty || !FileOps.exists(jar) {
            out.append(Blocker(kind: .noJar, title: "No server jar", detail: "Download one on the Software page."))
        }
        if !swapPending, let named = ServerDetector.versionInJarName(profile.software.jarName),
           !profile.software.mcVersion.isEmpty, named != profile.software.mcVersion {
            // Starting a newer jar would silently upgrade the world again.
            out.append(Blocker(kind: .noJar, title: "The jar doesn't match this world", detail: "\(profile.software.jarName) is for Minecraft \(named), but this server is on \(profile.software.mcVersion). Choose the matching jar on the Software page."))
        }
        // Observed: with level.dat gone the server starts anyway and writes new world data, losing the seed.
        let propsText = (try? String(contentsOf: paths.properties, encoding: .utf8)) ?? ""
        let level = PropertiesDocument(propsText).value("level-name").flatMap { $0.isEmpty ? nil : $0 } ?? "world"
        let world = paths.root.appendingPathComponent(level)
        if profile.software.flavor != .folia, !FileOps.exists(world.appendingPathComponent("level.dat")),
           FileOps.isDirectory(world.appendingPathComponent("region")) || FileOps.isDirectory(world.appendingPathComponent("dimensions")) {
            out.append(Blocker(kind: .worldData, title: "The main world is missing level.dat", detail: "Starting now would create new world data, losing its seed and settings. Restore a backup first."))
        }
        if requiresEULA, !EULA.isAccepted(paths) {
            out.append(Blocker(kind: .eula, title: "Accept the Minecraft EULA", detail: "Minecraft servers can't run until their owner accepts Mojang's End User License Agreement."))
        }
        if runtimes.isEmpty { runtimes = await JavaManager.discover() }
        let needed = javaRequirement
        if let java = resolvedJava() {
            if java.major > 0, java.major < needed {
                out.append(Blocker(kind: .java(required: needed), title: "Minecraft \(profile.software.mcVersion) needs Java \(needed)", detail: "This server is set to use Java \(java.major)."))
            }
            if !FileManager.default.isExecutableFile(atPath: java.path) {
                out.append(Blocker(kind: .java(required: needed), title: "That Java can't be found", detail: java.path))
            }
        } else {
            out.append(Blocker(kind: .java(required: needed), title: "Java \(needed) is needed", detail: "No suitable Java was found on this Mac. Leaf Juice can download one."))
        }
        if SystemInfo.isPortBusy(serverPort) {
            out.append(Blocker(kind: .portBusy(serverPort), title: "Port \(serverPort) is in use", detail: "Another program is using it. Stop it, or change server-port in server.properties."))
        }
        if profile.launch.minMemoryMB > profile.launch.maxMemoryMB {
            out.append(Blocker(kind: .other, title: "Memory settings conflict", detail: "Minimum memory is above maximum."))
        }
        return out
    }

    public func start() async {
        guard state.canStart, process == nil else { return }
        await detectExternalServer()
        guard state.canStart else { return }
        blockers = await preflight()
        guard blockers.isEmpty else { return }
        await applyPending()
        launch()
    }

    private func launch() {
        guard let java = resolvedJava() else { return }
        let arguments = LaunchCommand.arguments(profile.launch, software: profile.software, javaMajor: java.major)
        try? FileOps.ensureDir(paths.meta)
        gcReadOffset = 0
        let child = ServerProcess(java: java.path, arguments: arguments, directory: paths.root)
        child.onLine = { [weak self] line in
            Task { @MainActor in self?.bufferLine(line) }
        }
        child.onExit = { [weak self] code in
            Task { @MainActor in self?.handleExit(code) }
        }
        do {
            try child.start()
        } catch {
            state = .crashed(code: -1)
            appendWrapper("Couldn't start Java: \(error.localizedDescription)", level: .error)
            return
        }
        process = child
        launchedCommand = arguments
        startedAt = Date()
        players = []
        expectingStop = false
        state = .starting
        recordEvent(.start, "Started \(profile.software.label)")
        try? JSONStore.save(child.pid, to: paths.pid)
        appendWrapper("Starting \(profile.software.label) with Java \(java.major > 0 ? String(java.major) : java.path)…", level: .info)
        if profile.launch.keepAwake {
            sleepAssertion = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled], reason: "Minecraft server running")
        }
    }

    public func stop() {
        guard state == .running || state == .starting, let process else { return }
        expectingStop = true
        startedStopWhileStarting = state == .starting
        state = .stopping
        restartPlan = nil
        // Observed: while starting, the server isn't reading its console yet, so `stop` would sit unread.
        if state == .stopping, startedStopWhileStarting { process.terminate() } else { process.send("stop") }
        stopDeadline?.cancel()
        stopDeadline = Task { [weak self] in
            // Big worlds can take a while to save, so escalate gently.
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled, let self else { return }
            self.appendWrapper("The server hasn't stopped after 2 minutes. Asking Java to shut down.", level: .warn)
            self.process?.terminate()
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled else { return }
            self.appendWrapper("Still running. Forcing it to stop; unsaved data may be lost.", level: .error)
            self.process?.kill()
        }
    }

    /// Stops the server immediately, without waiting for a clean save.
    public func forceStop() {
        expectingStop = true
        process?.kill()
    }

    public func restart(reason: String = "Restart") {
        guard state == .running || state == .starting else { return }
        appendWrapper("\(reason): restarting.", level: .info)
        restartAfterStop = true
        stop()
    }

    private func handleExit(_ code: Int32) {
        flushLines()
        // Observed: a broken config makes the server quit with code 0. Giving up isn't a clean stop.
        let failedToStart = state == .starting && !expectingStop
        stopDeadline?.cancel()
        stopDeadline = nil
        process = nil
        metrics = nil
        startedAt = nil
        players = []
        launchedCommand = nil
        if let sleepAssertion { ProcessInfo.processInfo.endActivity(sleepAssertion) }
        sleepAssertion = nil
        try? FileManager.default.removeItem(at: paths.pid)
        finishWaiters()
        persistIssues()
        Task { await refreshPluginsAndConfigs() }

        // Exit code 0 is a clean stop, even when someone typed /stop in the game.
        if !failedToStart, expectingStop || code == 0 {
            appendWrapper("Server stopped.", level: .info)
            recordEvent(.stop, "Stopped")
            state = .stopped
            if restartAfterStop {
                restartAfterStop = false
                Task { await start() }
            } else if !pending.isEmpty {
                Task { await applyPending() }
            }
            return
        }

        restartAfterStop = false
        state = .crashed(code: code)
        appendWrapper(failedToStart ? "The server gave up before it finished starting. The Issues panel has what it reported." : "The server exited unexpectedly (code \(code)).", level: .error)
        recordEvent(.crash, "Crashed", detail: "Exit code \(code)")
        raiseAlert("\(profile.name) \(failedToStart ? "couldn't start" : "crashed")", failedToStart ? "It gave up while starting. The Issues panel has what it reported." : "Exit code \(code).\(profile.launch.restartOnCrash ? " Restarting in 10 seconds." : "")")
        reportCrash(code: code)
        crashTimes = crashTimes.filter { Date().timeIntervalSince($0) < 600 } + [Date()]
        // Starting again won't help something that can't start.
        guard profile.launch.restartOnCrash, !failedToStart else { return }
        if crashTimes.count >= 3 {
            raiseAlert("\(profile.name) keeps crashing", "Automatic restarts are paused after \(crashTimes.count) crashes in 10 minutes.")
            appendWrapper("Crashed \(crashTimes.count) times in 10 minutes, so automatic restarts are paused. Check the Issues panel.", level: .error)
            return
        }
        appendWrapper("Restarting in 10 seconds…", level: .warn)
        Task {
            try? await Task.sleep(for: .seconds(10))
            if case .crashed = self.state { await self.start() }
        }
    }

    private func reportCrash(code: Int32) {
        let now = Date()
        var attachment: String?
        let reports = FileOps.children(paths.root.appendingPathComponent("crash-reports")) + FileOps.children(paths.root).filter { $0.lastPathComponent.hasPrefix("hs_err_pid") }
        if let newest = reports.max(by: { (FileOps.modified($0) ?? .distantPast) < (FileOps.modified($1) ?? .distantPast) }),
           let date = FileOps.modified(newest), now.timeIntervalSince(date) < 180 {
            attachment = newest.path
        }
        analyzer.report(IssueRecord(
            id: "wrapper:crash", ruleID: "wrapper-crash", title: "The server crashed", severity: .critical, category: "Crash",
            explanation: "The Java process ended without being asked to, with exit code \(code).",
            steps: ["Look at the issues catalogued just before this one.", attachment == nil ? "No crash report was written, which often points to the system killing Java, for example when memory runs out." : "Read the crash report for the cause."],
            sample: "Exit code \(code)", firstSeen: now, lastSeen: now, attachment: attachment))
        issues = analyzer.sorted
        persistIssues()
    }

    /// A server left running by a previous session, or started outside Leaf Juice.
    public func detectExternalServer() async {
        guard process == nil else { return }
        // After a reboot the saved number can belong to something else, even another Java program.
        // It's only this server if it's also running in this folder.
        if let pid: Int32 = try? JSONStore.decoder.decode(Int32.self, from: Data(contentsOf: paths.pid)),
           SystemInfo.isAlive(pid: pid), let command = await SystemInfo.commandLine(pid: pid), command.contains("java"),
           SystemInfo.workingDirectory(pid: pid)?.standardizedFileURL.resolvingSymlinksInPath().path == paths.root.standardizedFileURL.resolvingSymlinksInPath().path {
            state = .external(pid: pid)
            return
        }
        if FileOps.exists(paths.pid) { try? FileManager.default.removeItem(at: paths.pid) }
        if case .external = state { state = .stopped }
    }

    /// Asks a server we no longer own to shut down cleanly.
    public func stopExternalServer() async {
        guard case let .external(pid) = state else { return }
        guard SystemInfo.workingDirectory(pid: pid)?.standardizedFileURL.resolvingSymlinksInPath().path == paths.root.standardizedFileURL.resolvingSymlinksInPath().path else {
            await detectExternalServer()
            return
        }
        kill(pid, SIGTERM)
        for _ in 0..<60 where SystemInfo.isAlive(pid: pid) { try? await Task.sleep(for: .seconds(1)) }
        await detectExternalServer()
    }

    // MARK: Console

    public func send(_ command: String) {
        let text = command.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let process else { return }
        append(">\u{00A0}\(text)", level: .info, origin: .command)
        let bare = text.hasPrefix("/") ? String(text.dropFirst()) : text
        if bare == "stop" {
            expectingStop = true
            state = .stopping
        }
        process.send(bare)
    }

    public func clearConsole() { console.removeAll() }

    private func bufferLine(_ line: String) {
        lineBuffer.append(line)
        guard !flushScheduled else { return }
        flushScheduled = true
        // Batching keeps a chatty server from redrawing the interface per line.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            self.flushLines()
        }
    }

    private func flushLines() {
        flushScheduled = false
        guard !lineBuffer.isEmpty else { return }
        let lines = lineBuffer
        lineBuffer.removeAll(keepingCapacity: true)
        var changedIssues = false
        for line in lines {
            let parsed = ParsedLogLine(line)
            if let reading = TPS.parse(parsed.message) {
                tps = reading
                bucket.tps.append(reading.oneMinute)
                // Asked for by the app, so it shouldn't fill the console every few seconds.
                if awaitingTPS { awaitingTPS = false; continue }
            }
            if awaitingMSPT > 0 {
                if TickTimes.isHeader(parsed.message) || TickTimes.isVanillaExtra(parsed.message) { continue }
                if let value = TickTimes.parse(parsed.message) {
                    mspt = value
                    bucket.mspt.append(value)
                    awaitingMSPT -= 1
                    continue
                }
            }
            if parsed.level != .debug, let refused = JoinFailures.parse(parsed.message, online: players) {
                failedJoins.insert(refused, at: 0)
                if failedJoins.count > 100 { failedJoins.removeLast() }
                recordEvent(.player, "\(refused.name) couldn't join", detail: refused.meaning)
            }
            append(line, level: parsed.level, origin: .server)
            analyzer.ingest(line)
            changedIssues = changedIssues || parsed.level >= .warn || analyzer.dirty
            observe(parsed)
        }
        if console.count > Self.consoleLimit { console.removeFirst(console.count - Self.consoleLimit) }
        if changedIssues { issues = analyzer.sorted }
    }

    private func append(_ text: String, level: LogLevel, origin: ConsoleLine.Origin) {
        console.append(ConsoleLine(id: nextLineID, text: text, level: level, origin: origin))
        nextLineID += 1
    }

    public func appendWrapper(_ text: String, level: LogLevel) {
        append("[Leaf Juice] \(text)", level: level, origin: .wrapper)
    }

    private static let donePattern = regex(#"^Done \(\d+[.,]\d+s\)!"#)
    private static let uuidPattern = regex(#"UUID of player (\.?[A-Za-z0-9_]{1,16}) is ([0-9a-fA-F-]{36})"#)
    private static let joinPattern = regex(#"^(\.?[A-Za-z0-9_]{1,16}) (joined|left) the game"#)

    private func observe(_ line: ParsedLogLine) {
        if !waiters.isEmpty {
            let lower = line.message.lowercased()
            for (i, waiter) in waiters.enumerated().reversed() where waiter.needles.contains(where: lower.contains) {
                waiter.resume(line.message)
                waiters.remove(at: i)
            }
        }
        if state == .starting, Self.donePattern.firstMatch(in: line.message) != nil {
            state = .running
            // The server has just written its settings files, so there's more to show.
            refreshConfigs()
            crashTimes.removeAll()
        }
        if let m = Self.joinPattern.firstMatch(in: line.message), m.numberOfRanges == 3,
           let nameRange = Range(m.range(at: 1), in: line.message), let verbRange = Range(m.range(at: 2), in: line.message) {
            let name = String(line.message[nameRange])
            if line.message[verbRange] == "joined" {
                players.insert(name)
                playSeconds[name] = 0
            } else {
                players.remove(name)
                playSeconds[name] = nil
                // The server writes their data as they leave, so this catches their final state.
                if profile.playerSnapshots.enabled, Modules.shared.isOn(.players), !isTrialCopy {
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(3))
                        self?.takeAutomaticSnapshot(name: name, trigger: "left")
                    }
                }
            }
        }
        if let m = Self.uuidPattern.firstMatch(in: line.message), m.numberOfRanges == 3,
           let n = Range(m.range(at: 1), in: line.message), let u = Range(m.range(at: 2), in: line.message) {
            playerUUIDs[String(line.message[n])] = String(line.message[u])
        }
    }

    /// Waits for a console line containing any of these, and returns it. nil on timeout or exit.
    private func waitForLine(containingAny needles: [String], timeout: Duration) async -> String? {
        await withCheckedContinuation { continuation in
            var finished = false
            let resume: (String?) -> Void = { value in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: value)
            }
            waiters.append((needles.map { $0.lowercased() }, resume))
            Task {
                try? await Task.sleep(for: timeout)
                resume(nil)
            }
        }
    }

    func waitForLine(containing needle: String, timeout: Duration) async -> Bool {
        await waitForLine(containingAny: [needle], timeout: timeout) != nil
    }

    private func finishWaiters() {
        waiters.forEach { $0.resume(nil) }
        waiters.removeAll()
    }

    // MARK: Issues

    public func setIssueStatus(_ status: IssueRecord.Status, id: String) {
        analyzer.setStatus(status, id: id)
        issues = analyzer.sorted
        persistIssues()
    }

    func reportIssue(_ record: IssueRecord) {
        analyzer.report(record)
        issues = analyzer.sorted
        persistIssues()
    }

    /// For a test copy, which watches for updates from the real server's source.
    func adoptRecord(_ record: PluginRecord, key: String) {
        records[key] = record
    }

    public func clearIssues() {
        analyzer.clear()
        issues = []
        persistIssues()
    }

    /// Reads `logs/latest.log` into the catalog. Stable, so scanning twice only raises counts.
    public func scanLatestLog() {
        let file = paths.root.appendingPathComponent("logs/latest.log")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let date = FileOps.modified(file) ?? Date()
        analyzer.setPlugins(plugins)
        for line in text.split(whereSeparator: \.isNewline).suffix(50_000) { analyzer.ingest(String(line), at: date) }
        issues = analyzer.sorted
        persistIssues()
    }

    private func persistIssues() {
        guard analyzer.dirty else { return }
        try? JSONStore.save(analyzer.sorted, to: paths.issues)
        analyzer.markClean()
    }

    // MARK: Pending changes

    public var isStagingRequired: Bool { state != .stopped && !isCrashedOrStopped }
    private var isCrashedOrStopped: Bool { state.canStart }

    /// Launch settings differ from what the running server started with.
    public var launchChangedSinceStart: Bool {
        guard let launchedCommand else { return false }
        return launchedCommand != LaunchCommand.arguments(profile.launch, software: profile.software, javaMajor: resolvedJava()?.major ?? 0)
    }

    public var needsRestart: Bool { state.isLive && (!pending.isEmpty || launchChangedSinceStart) }

    func enqueue(_ change: PendingChange) {
        pending.removeAll { $0.target == change.target }
        pending.append(change)
        savePending()
    }

    public func discard(_ change: PendingChange) {
        switch change.kind {
        case let .config(path):
            ConfigStage(paths: paths).discard(path)
        case let .software(file, _, _):
            try? FileManager.default.removeItem(at: paths.staged.appendingPathComponent(file))
        case let .pluginInstall(_, file, _, _, _):
            try? FileManager.default.removeItem(at: paths.staged.appendingPathComponent(file))
        default:
            break
        }
        pending.removeAll { $0.id == change.id }
        savePending()
        refreshConfigs()
    }

    /// Applies every queued change. The server must be stopped.
    public func applyPending() async {
        guard state.canStart, !pending.isEmpty else { return }
        for i in pending.indices { pending[i].conflict = nil }
        pendingRestorePoint = nil

        // A version change always gets a verified restore point, whatever the backup settings say.
        let majorUpgrade = pending.contains { if case .software(_, _, true) = $0.kind { true } else { false } }
        if majorUpgrade, hasWorld, !isTrialCopy {
            do {
                pendingRestorePoint = try await makeRestorePoint()
            } catch {
                holdBack(reason: "Upgrade held back, and nothing was changed, because the restore point failed: \(error.localizedDescription)") { change in
                    if case .software = change.kind { true } else { false }
                }
            }
        }
        // A restore point covers everything, so a second backup would only repeat it.
        if pendingRestorePoint == nil, !isTrialCopy, profile.backup.beforeUpdates, pending.contains(where: { $0.needsBackup && $0.conflict == nil }), hasWorld {
            do {
                _ = try await backupNow(trigger: "before-update")
            } catch {
                holdBack(reason: "Held back because the safety backup failed: \(error.localizedDescription)") { $0.needsBackup }
            }
        }
        setActivity("Applying changes…")
        defer { setActivity(nil) }
        var remaining: [PendingChange] = []
        for var change in pending {
            if change.conflict != nil { remaining.append(change); continue }
            do {
                if let conflict = try applyOne(change) {
                    change.conflict = conflict
                    remaining.append(change)
                    appendWrapper(conflict, level: .warn)
                } else {
                    appendWrapper("Applied: \(change.summary)", level: .info)
                    recordEvent(change.eventKind, change.summary)
                }
            } catch {
                change.conflict = error.localizedDescription
                remaining.append(change)
                appendWrapper("Couldn't apply \(change.summary): \(error.localizedDescription)", level: .error)
            }
        }
        pending = remaining
        savePending()
        await refreshPluginsAndConfigs()
    }

    private func holdBack(reason: String, where matches: (PendingChange) -> Bool) {
        appendWrapper(reason, level: .error)
        for i in pending.indices where matches(pending[i]) { pending[i].conflict = reason }
    }

    private func applyOne(_ change: PendingChange) throws -> String? {
        switch change.kind {
        case let .config(path):
            let format = configs.first { $0.path == path }?.format ?? ConfigCatalog.format(for: path)
            let p = paths
            return try ConfigStage(paths: paths).apply(path, format: format) { rel, text in
                ConfigHistory.record(rel, text: text, paths: p)
            }
        case let .software(file, build, _):
            let before = profile.software
            try swapJar(from: paths.staged.appendingPathComponent(file), build: build)
            if let point = pendingRestorePoint {
                setActiveUpgrade(UpgradeRecord(
                    from: before, toLabel: "\(build.flavor.title) \(build.label)", toFileName: build.fileName,
                    backupFile: point.fileName, backupFolder: Backups.destination(profile).path, worlds: Backups.worldFolders(paths.root), size: point.size))
                pendingRestorePoint = nil
            }
            return nil
        case let .pluginInstall(name, file, finalName, replaces, upstreamID):
            let staged = paths.staged.appendingPathComponent(file)
            guard FileOps.exists(staged) else { throw LeafError("The staged file for \(name) is missing.") }
            if let replaces, FileOps.exists(paths.plugins.appendingPathComponent(replaces)) {
                try FileOps.move(paths.plugins.appendingPathComponent(replaces), to: paths.pluginArchive.appendingPathComponent(replaces))
            }
            try FileOps.move(staged, to: paths.plugins.appendingPathComponent(finalName))
            var record = records[name.lowercased()] ?? PluginRecord()
            record.installedUpstreamID = upstreamID ?? record.installedUpstreamID
            record.available = nil
            records[name.lowercased()] = record
            saveRecords()
            return nil
        case let .pluginRemove(fileName):
            let source = paths.plugins.appendingPathComponent(fileName)
            if FileOps.exists(source) { try FileOps.move(source, to: paths.pluginArchive.appendingPathComponent(fileName)) }
            return nil
        case let .playerRestore(folder, uuid, _, inventoryOnly, containers):
            guard let snapshot = PlayerSnapshots.list(uuid: uuid, profile: profile).first(where: { $0.folder == folder }) else {
                throw LeafError("That snapshot is missing.")
            }
            try applyPlayerRestore(snapshot, inventoryOnly: inventoryOnly, containers: containers)
            return nil
        case let .pluginToggle(fileName, enable):
            let source = paths.plugins.appendingPathComponent(fileName)
            guard FileOps.exists(source) else { return nil }
            let target = enable ? source.deletingPathExtension() : source.appendingPathExtension("disabled")
            try FileOps.move(source, to: target)
            return nil
        }
    }

    private func swapJar(from staged: URL, build: SoftwareBuild) throws {
        guard FileOps.exists(staged) else { throw LeafError("The downloaded jar is missing. Download it again.") }
        if let old = FileOps.child(profile.software.jarName, of: paths.root), FileOps.exists(old), profile.software.jarName != build.fileName {
            try FileOps.move(old, to: paths.jarArchive.appendingPathComponent(profile.software.jarName))
        }
        try FileOps.move(staged, to: paths.root.appendingPathComponent(build.fileName))
        var software = profile.software
        software.flavor = build.flavor
        software.mcVersion = build.mcVersion
        software.build = build.build
        software.jarName = build.fileName
        software.requiredJava = build.javaMinimum ?? software.requiredJava
        if !build.recommendedFlags.isEmpty { software.recommendedFlags = build.recommendedFlags }
        software.supportStatus = build.supportStatus
        profile.software = software
        softwareUpdate = nil
    }

    // MARK: Scheduling a restart

    public func scheduleRestart(_ plan: RestartPlan) {
        guard state == .running else {
            // Nothing to restart: changes apply straight away.
            if state.canStart { Task { await applyPending() } }
            return
        }
        restartPlan = plan
    }

    public func cancelRestart() {
        guard restartPlan != nil else { return }
        restartPlan = nil
        if state == .running, profile.restart.warnings.isEmpty == false { process?.send("say Restart cancelled.") }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.tick()
            }
        }
    }

    public func refreshSchedule() {
        nextScheduledRestart = profile.restart.enabled ? profile.restart.next(after: Date()) : nil
    }

    func tick() async {
        let now = Date()
        tickPlayerSnapshots(elapsed: now.timeIntervalSince(lastTick ?? now))
        lastTick = now
        tickCount += 1
        if tickCount % 12 == 1 { tickDisk() }
        if isTrialCopy { return }
        if state == .running { await applyWaitingAccess() }
        tickAnalytics(now: now)
        if let pid = process?.pid { metrics = sampler.sample(pid: pid) }
        analyzer.setPlugins(plugins)
        persistIssues()
        tickRestart(now)
        if let next = nextScheduledRestart, state == .running, restartPlan == nil {
            let lead = Double(profile.restart.warnings.max() ?? 0) + 10
            if next.timeIntervalSince(now) <= lead {
                if !profile.restart.onlyIfPending || needsRestart {
                    restartPlan = RestartPlan(at: next, reason: "Scheduled restart")
                }
                nextScheduledRestart = profile.restart.next(after: next.addingTimeInterval(1))
            }
        } else if let next = nextScheduledRestart, next <= now {
            nextScheduledRestart = profile.restart.next(after: now)
        }
        // Scheduled backups run only while the server is up: a stopped world isn't changing.
        if profile.backup.enabled, !backingUp, state == .running, hasWorld,
           now.timeIntervalSince(profile.backup.lastRun ?? .distantPast) >= Double(profile.backup.intervalHours) * 3600 {
            if profile.software.flavor == .folia {
                appendWrapper("Skipped the scheduled backup: Folia can only be backed up while stopped.", level: .warn)
                profile.backup.lastRun = now
            } else {
                do { try await backupNow(trigger: "scheduled") }
                catch {
                    appendWrapper("Scheduled backup failed: \(error.localizedDescription)", level: .error)
                    raiseAlert("\(profile.name)'s backup failed", error.localizedDescription)
                }
            }
        }
        // Daily background checks, spread out by only running while nothing else is happening.
        let day: TimeInterval = 86_400
        if activity == nil, !checkingPlugins, now.timeIntervalSince(profile.lastPluginCheck ?? .distantPast) > day {
            profile.lastPluginCheck = now
            await checkPluginUpdates(autoInstall: true)
        }
        if activity == nil, now.timeIntervalSince(profile.software.lastCheck ?? .distantPast) > day {
            await checkSoftwareUpdate(autoInstall: true)
        }
    }

    var hasWorld: Bool { !Backups.worldFolders(paths.root).isEmpty }

    private func tickRestart(_ now: Date) {
        guard var plan = restartPlan, state == .running else { return }
        if plan.whenEmpty {
            if players.isEmpty {
                restartPlan = nil
                restart(reason: plan.reason)
            }
            return
        }
        guard let at = plan.at else { return }
        let left = Int(at.timeIntervalSince(now).rounded())
        if left <= 0 {
            restartPlan = nil
            restart(reason: plan.reason)
            return
        }
        // Announce the warning we've just entered.
        for warning in profile.restart.warnings.sorted() where left <= warning && !plan.warned.contains(warning) {
            plan.warned.formUnion(profile.restart.warnings.filter { $0 >= warning })
            let text = profile.restart.message.replacingOccurrences(of: "{time}", with: RestartSchedule.describe(seconds: warning))
            process?.send("say \(text)")
            break
        }
        restartPlan = plan
    }

    // MARK: Software

    public func checkSoftwareUpdate(autoInstall: Bool = false) async {
        let s = profile.software
        profile.software.lastCheck = Date()
        guard s.flavor.canDownload, !s.mcVersion.isEmpty else { return }
        do {
            guard let build = try await SoftwareCatalog.latestBuild(s.flavor, mc: s.mcVersion, channels: s.channels) else { return }
            // Keep the requirements current even when no update is due.
            if let java = build.javaMinimum { profile.software.requiredJava = java }
            if !build.recommendedFlags.isEmpty { profile.software.recommendedFlags = build.recommendedFlags }
            profile.software.supportStatus = build.supportStatus
            let move = SoftwareCatalog.classify(current: s, flavor: s.flavor, mc: s.mcVersion, build: build.build)
            let newer = move == .newBuild && (build.build ?? 0) > (s.build ?? -1)
            softwareUpdate = newer ? build : nil
            if newer, autoInstall, s.autoInstallBuilds { try await installSoftware(build) }
        } catch {
            if !autoInstall { notice = "Couldn't check for updates: \(error.localizedDescription)" }
        }
    }

    /// Downloads a jar and installs it now, or queues it if the server is running.
    public func installSoftware(_ build: SoftwareBuild) async throws {
        let move = SoftwareCatalog.classify(current: profile.software, flavor: build.flavor, mc: build.mcVersion, build: build.build)
        if move == .downgrade {
            throw LeafError("Minecraft worlds can't go back to an older version. To return to \(build.mcVersion), restore a backup made on that version, then switch.")
        }
        let name = "jars/\(build.fileName)"
        let staged = paths.staged.appendingPathComponent(name)
        setActivity("Downloading \(build.flavor.title) \(build.label)…", progress: 0)
        defer { setActivity(nil) }
        try await HTTP.download(HTTP.url(build.downloadURL), to: staged, expect: build.hashes) { [weak self] value in
            Task { @MainActor in self?.activityProgress = value }
        }
        let change = PendingChange(
            kind: .software(stagedFile: name, build: build, needsBackup: move.needsBackup),
            summary: "Switch to \(build.flavor.title) \(build.label)")
        enqueue(change)
        if state.canStart { await applyPending() } else { notice = "\(change.summary) will happen at the next restart." }
    }

    /// Jars previously replaced, available for rollback.
    public var archivedJars: [String] {
        FileOps.children(paths.jarArchive).filter { $0.pathExtension == "jar" }
            .sorted { (FileOps.modified($0) ?? .distantPast) > (FileOps.modified($1) ?? .distantPast) }
            .map(\.lastPathComponent)
    }

    /// Rolls back to an archived jar of the same Minecraft version.
    public func rollbackJar(_ name: String) async throws {
        guard state.canStart else { throw LeafError("Stop the server first.") }
        let detected = name.range(of: #"^(paper|purpur|folia)-(.+?)-(\d+)\.jar$"#, options: [.regularExpression, .caseInsensitive]) != nil
        if detected {
            let parts = (name as NSString).deletingPathExtension.components(separatedBy: "-")
            let mc = parts.dropFirst().dropLast().joined(separator: "-")
            if let from = profile.software.gameVersion, let to = GameVersion(mc), to < from {
                throw LeafError("That jar is for Minecraft \(mc), older than this world. Restore a backup from that version instead.")
            }
            if parts.count >= 3 { profile.software.build = Int(parts.last ?? "") }
        }
        if let current = FileOps.child(profile.software.jarName, of: paths.root), FileOps.exists(current) {
            try FileOps.move(current, to: paths.jarArchive.appendingPathComponent(profile.software.jarName))
        }
        guard let archived = FileOps.child(name, of: paths.jarArchive), let target = FileOps.child(name, of: paths.root) else { throw LeafError("That isn't a jar name.") }
        try FileOps.move(archived, to: target)
        profile.software.jarName = name
    }

    /// Would each plugin work on another Minecraft version?
    public func readiness(for target: GameVersion, flavor: Flavor) async -> [ReadinessRow] {
        var rows: [ReadinessRow] = []
        await withTaskGroup(of: ReadinessRow.self) { group in
            for plugin in plugins where plugin.enabled {
                let source = records[plugin.key]?.source ?? .none
                let name = plugin.name
                group.addTask {
                    guard source.isSet else {
                        return ReadinessRow(plugin: name, verdict: nil, detail: "No source set, so this can't be checked.")
                    }
                    do {
                        let result = try await PluginSources.check(source, mc: target, flavor: flavor)
                        if let c = result.candidate {
                            return ReadinessRow(plugin: name, verdict: c.compatibility.verdict, detail: "\(c.version): \(c.compatibility.reason)")
                        }
                        return ReadinessRow(plugin: name, verdict: .incompatible, detail: result.skippedNote ?? "No compatible release found.")
                    } catch {
                        return ReadinessRow(plugin: name, verdict: nil, detail: "Couldn't check: \(error.localizedDescription)")
                    }
                }
            }
            for await row in group { rows.append(row) }
        }
        return rows.sorted { $0.plugin.lowercased() < $1.plugin.lowercased() }
    }

    // MARK: Plugins

    public func record(for plugin: InstalledPlugin) -> PluginRecord { records[plugin.key] ?? PluginRecord() }

    public func refreshPlugins() async {
        plugins = await PluginScanner.scan(paths)
        analyzer.setPlugins(plugins)
        refreshConfigs()
        await identifySources()
    }

    private func refreshPluginsAndConfigs() async {
        await refreshPlugins()
        refreshConfigs()
    }

    /// Exact Modrinth hash matches can safely set a source without asking.
    private func identifySources() async {
        let unset = plugins.filter { !(records[$0.key]?.source.isSet ?? false) }
        let hashes = unset.compactMap { $0.digests?.sha1 }
        guard !hashes.isEmpty else { return }
        let matches = await SourceFinder.modrinthMatches(sha1s: hashes)
        guard !matches.isEmpty else { return }
        for plugin in unset {
            guard let sha = plugin.digests?.sha1, let project = matches[sha] else { continue }
            var record = records[plugin.key] ?? PluginRecord()
            guard !record.source.isSet else { continue }
            record.source = .modrinth(project: project, allowBeta: false)
            record.note = "Recognised from its file hash."
            records[plugin.key] = record
        }
        saveRecords()
    }

    public func setRecord(_ record: PluginRecord, for plugin: InstalledPlugin) {
        var updated = record
        // A different source means earlier results no longer apply.
        if records[plugin.key]?.source != record.source {
            updated.available = nil
            updated.lastError = nil
            updated.installedUpstreamID = nil
        }
        records[plugin.key] = updated
        saveRecords()
    }

    /// Checks every plugin with a source. Installs where the policy says to, given good evidence.
    public func checkPluginUpdates(autoInstall: Bool = false) async {
        guard !checkingPlugins else { return }
        checkingPlugins = true
        defer { checkingPlugins = false }
        let mc = profile.software.gameVersion, flavor = profile.software.flavor
        let targets = plugins.filter { (records[$0.key]?.source.isSet ?? false) && records[$0.key]?.policy != .pinned }
        await withTaskGroup(of: (String, Result<SourceCheck, Error>).self) { group in
            var running = 0
            for plugin in targets {
                // A polite limit: these are free community services.
                if running >= 4 { if let done = await group.next() { apply(done.1, key: done.0) }; running -= 1 }
                let source = records[plugin.key]!.source, key = plugin.key
                running += 1
                group.addTask {
                    do { return (key, .success(try await PluginSources.check(source, mc: mc, flavor: flavor))) }
                    catch { return (key, .failure(error)) }
                }
            }
            for await done in group { apply(done.1, key: done.0) }
        }
        saveRecords()
        guard autoInstall else { return }
        for plugin in plugins {
            let record = record(for: plugin)
            guard record.policy == .auto, let candidate = record.available, candidate.compatibility.allowsAutoInstall else { continue }
            do { try await installUpdate(for: plugin) }
            catch {
                records[plugin.key]?.lastError = error.localizedDescription
                saveRecords()
            }
        }
    }

    private func apply(_ result: Result<SourceCheck, Error>, key: String) {
        guard var record = records[key], let plugin = plugins.first(where: { $0.key == key }) else { return }
        record.lastCheck = Date()
        switch result {
        case let .success(check):
            record.lastError = nil
            record.note = check.skippedNote
            if let candidate = check.candidate {
                if UpdateDecision.isUpdate(candidate, installed: plugin, record: record) {
                    record.available = candidate
                } else {
                    record.available = nil
                    // What's installed now is this release; remember that for later comparisons.
                    if record.installedUpstreamID == nil { record.installedUpstreamID = candidate.upstreamID }
                }
            } else {
                record.available = nil
            }
        case let .failure(error):
            record.lastError = error.localizedDescription
        }
        records[key] = record
    }

    public func checkPlugin(_ plugin: InstalledPlugin) async {
        guard let source = records[plugin.key]?.source, source.isSet else { return }
        do {
            let check = try await PluginSources.check(source, mc: profile.software.gameVersion, flavor: profile.software.flavor)
            apply(.success(check), key: plugin.key)
        } catch { apply(.failure(error), key: plugin.key) }
        saveRecords()
    }

    /// Downloads and vets an update. Every source passes the same checks.
    public func installUpdate(for plugin: InstalledPlugin) async throws {
        guard let candidate = records[plugin.key]?.available else { return }
        guard let link = candidate.downloadURL else {
            throw LeafError("\(plugin.name) can't be downloaded automatically. Get it from its page.")
        }
        setActivity("Downloading \(plugin.name) \(candidate.version)…", progress: 0)
        defer { setActivity(nil) }
        let (name, descriptor, staged) = try await fetchPlugin(link: link, candidate: candidate, expectedName: plugin.name)
        // Some sources (Spiget's cache) can lag: don't reinstall what's already here.
        if !descriptor.version.isEmpty, descriptor.version == plugin.version, let a = try? Hashing.digests(of: staged), a == plugin.digests {
            try? FileManager.default.removeItem(at: staged)
            records[plugin.key]?.available = nil
            records[plugin.key]?.installedUpstreamID = candidate.upstreamID
            saveRecords()
            return
        }
        let stagedName = "plugins/\(name)"
        let change = PendingChange(
            kind: .pluginInstall(name: plugin.name, stagedFile: stagedName, finalName: name, replaces: plugin.fileName, upstreamID: candidate.upstreamID),
            summary: "Update \(plugin.name) to \(descriptor.version.isEmpty ? candidate.version : descriptor.version)")
        enqueue(change)
        if state.canStart { await applyPending() }
    }

    /// Adds a new plugin from a source. Queued while running: Paper doesn't load plugins live.
    public func addPlugin(source: PluginSource) async throws {
        let check = try await PluginSources.check(source, mc: profile.software.gameVersion, flavor: profile.software.flavor)
        guard let candidate = check.candidate else {
            throw LeafError(check.skippedNote ?? "No compatible release found for \(profile.software.mcVersion).")
        }
        guard let link = candidate.downloadURL else {
            throw LeafError(check.skippedNote ?? "This plugin can't be downloaded automatically.")
        }
        setActivity("Downloading \(candidate.version)…", progress: 0)
        defer { setActivity(nil) }
        let (name, descriptor, _) = try await fetchPlugin(link: link, candidate: candidate, expectedName: nil)
        if plugins.contains(where: { $0.key == descriptor.name.lowercased() }) {
            try? FileManager.default.removeItem(at: paths.staged.appendingPathComponent("plugins/\(name)"))
            throw LeafError("\(descriptor.name) is already installed. Set its source from the plugin's details instead.")
        }
        var record = PluginRecord()
        record.source = source
        records[descriptor.name.lowercased()] = record
        saveRecords()
        enqueue(PendingChange(
            kind: .pluginInstall(name: descriptor.name, stagedFile: "plugins/\(name)", finalName: name, replaces: nil, upstreamID: candidate.upstreamID),
            summary: "Add \(descriptor.name) \(descriptor.version)"))
        if state.canStart { await applyPending() }
    }

    private func fetchPlugin(link: String, candidate: UpdateCandidate, expectedName: String?) async throws -> (String, PluginDescriptor, URL) {
        let temp = paths.staged.appendingPathComponent("plugins/download-\(UUID().uuidString).part")
        let result = try await HTTP.download(HTTP.url(link), to: temp, expect: candidate.hashes) { [weak self] value in
            Task { @MainActor in self?.activityProgress = value }
        }
        do {
            let descriptor = await PluginYAML.read(jar: temp)
            _ = try UpdateDecision.inspect(descriptor, expectedName: expectedName, mc: profile.software.gameVersion, compat: candidate.compatibility)
            let suggested = candidate.fileName ?? result.suggestedName ?? ""
            let name = suggested.lowercased().hasSuffix(".jar") ? suggested : "\(descriptor!.name)-\(descriptor!.version).jar"
            let safeName = (name as NSString).lastPathComponent
            let staged = paths.staged.appendingPathComponent("plugins/\(safeName)")
            try FileOps.move(temp, to: staged)
            return (safeName, descriptor!, staged)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    public func setEnabled(_ enabled: Bool, plugin: InstalledPlugin) async throws {
        let change = PendingChange(kind: .pluginToggle(fileName: plugin.fileName, enable: enabled), summary: "\(enabled ? "Enable" : "Disable") \(plugin.name)")
        enqueue(change)
        if state.canStart { await applyPending() }
    }

    /// Archives rather than deletes, so a removal can be undone.
    public func removePlugin(_ plugin: InstalledPlugin) async {
        enqueue(PendingChange(kind: .pluginRemove(fileName: plugin.fileName), summary: "Remove \(plugin.name)"))
        if state.canStart { await applyPending() }
    }

    public var archivedPlugins: [String] {
        FileOps.children(paths.pluginArchive).filter { $0.lastPathComponent.hasSuffix(".jar") }.map(\.lastPathComponent).sorted()
    }

    public func restorePlugin(fileName: String) async throws {
        guard state.canStart else { throw LeafError("Stop the server first.") }
        let archived = paths.pluginArchive.appendingPathComponent(fileName)
        guard let descriptor = await PluginYAML.read(jar: archived) else { throw LeafError("That jar can't be read.") }
        if let current = plugins.first(where: { $0.key == descriptor.name.lowercased() }) {
            try FileOps.move(paths.plugins.appendingPathComponent(current.fileName), to: paths.pluginArchive.appendingPathComponent(current.fileName))
        }
        try FileOps.move(archived, to: paths.plugins.appendingPathComponent(fileName))
        records[descriptor.name.lowercased()]?.available = nil
        await refreshPlugins()
    }

    // MARK: Configs

    public func refreshConfigs() { configs = ConfigCatalog.scan(paths, plugins: plugins) }

    /// A plugin's settings files, in the order its page should show them.
    public func configs(for plugin: InstalledPlugin) -> [ConfigFile] {
        let folder = "plugins/\(plugin.name.lowercased())/"
        return configs.filter { $0.path.lowercased().hasPrefix(folder) }
    }

    public func configText(_ file: ConfigFile) -> String {
        ConfigStage(paths: paths).stagedText(file.path)
            ?? (try? String(contentsOf: paths.root.appendingPathComponent(file.path), encoding: .utf8)) ?? ""
    }

    /// What's on disk now, ignoring any edit waiting for a restart.
    public func liveConfigText(_ file: ConfigFile) -> String {
        (try? String(contentsOf: paths.root.appendingPathComponent(file.path), encoding: .utf8)) ?? ""
    }

    /// What players see in their server list, as plain text.
    public var serverMessage: String? {
        let file = configs.first { $0.path == "server.properties" } ?? ConfigCatalog.serverProperties
        guard let motd = PropertiesDocument(configText(file)).value("motd") else { return nil }
        let plain = ConfigForm.plainMOTD(motd)
        return plain.isEmpty ? nil : plain
    }

    /// Changes the server message, by the usual route: now if stopped, at the next restart if running.
    @discardableResult
    public func setServerMessage(_ message: String) throws -> SaveOutcome {
        let file = configs.first { $0.path == "server.properties" } ?? ConfigCatalog.serverProperties
        var doc = PropertiesDocument(configText(file))
        doc.set("motd", message)
        let outcome = try saveConfig(file, text: doc.text)
        refreshConfigs()
        return outcome
    }

    public func hasStagedEdit(_ file: ConfigFile) -> Bool { ConfigStage(paths: paths).stagedText(file.path) != nil }

    public enum SaveOutcome: Equatable { case saved, staged }

    /// Saves an edit now, or stages it for the next restart, according to the file's policy.
    @discardableResult
    public func saveConfig(_ file: ConfigFile, text: String) throws -> SaveOutcome {
        let problems = ConfigValidator.problems(text, format: file.format)
        if let first = problems.first { throw LeafError(first.description) }
        if !state.canStart {
            if case let .lockedWhileRunning(hint) = file.policy {
                throw LeafError("The server rewrites this file while running, so edits would be lost. \(hint)")
            }
            try ConfigStage(paths: paths).stage(file.path, text: text)
            enqueue(PendingChange(kind: .config(path: file.path), summary: "Update \(file.title)"))
            return .staged
        }
        let url = paths.root.appendingPathComponent(file.path)
        if let old = try? String(contentsOf: url, encoding: .utf8), old != text { ConfigHistory.record(file.path, text: old, paths: paths) }
        try FileOps.writeAtomic(text, to: url)
        // A direct save supersedes any older staged edit.
        if let staged = pending.first(where: { $0.target == "config:\(file.path)" }) { discard(staged) }
        return .saved
    }

    public func discardStagedEdit(_ file: ConfigFile) {
        if let staged = pending.first(where: { $0.target == "config:\(file.path)" }) { discard(staged) }
    }

    /// Applies a scaling preset: memory takes effect at next start; world settings follow the usual route.
    public func applyScaling(_ preset: ScalingPreset) throws {
        let reserve = max(SystemInfo.memoryMB / 4, 2048)
        let memory = min(preset.memoryMB, max(1024, SystemInfo.memoryMB - reserve))
        profile.launch.maxMemoryMB = memory
        profile.launch.minMemoryMB = memory
        let file = configs.first { $0.path == "server.properties" } ?? ConfigCatalog.serverProperties
        var doc = PropertiesDocument(configText(file))
        doc.set("view-distance", String(preset.viewDistance))
        doc.set("simulation-distance", String(preset.simulationDistance))
        doc.set("max-players", String(preset.maxPlayers))
        try saveConfig(file, text: doc.text)
    }

    public var memoryWarning: String? {
        let total = SystemInfo.memoryMB, heap = profile.launch.maxMemoryMB
        if heap >= total { return "That's more memory than this Mac has (\(Format.memory(mb: total)))." }
        if heap > total * 3 / 4 { return "This leaves little memory for macOS. The Mac may slow down or Java may be stopped by the system." }
        return nil
    }

    // MARK: Backups

    public var isBackingUp: Bool { backingUp }

    /// Settles where this server's backups go, the first time it matters.
    private func pinBackupFolder() {
        guard profile.backup.destination == nil else { return }
        let folder = Backups.defaultDestination(for: profile)
        guard (try? Backups.claim(folder, for: profile.id)) != nil else { return }
        profile.backup.destination = folder.path
    }

    /// Keeps the backup folder named after the server. Folders someone chose themselves are left alone.
    private func moveBackupFolderForRename() {
        guard let current = profile.backup.destination else { return }
        let old = URL(fileURLWithPath: current, isDirectory: true)
        guard Backups.isDefaultLocation(old), !backingUp else { return }
        let wanted = ServerFolders.folderName(for: profile.name) ?? profile.id.uuidString
        var target = old.deletingLastPathComponent().appendingPathComponent(wanted, isDirectory: true)
        var suffix = 2
        while FileOps.exists(target), target.path != old.path {
            target = old.deletingLastPathComponent().appendingPathComponent("\(wanted) \(suffix)", isDirectory: true)
            suffix += 1
        }
        guard target.path != old.path else { return }
        if FileOps.exists(old) {
            do { try FileManager.default.moveItem(at: old, to: target) } catch {
                notice = "The server was renamed, but its backup folder couldn't be: \(error.localizedDescription) Backups stay at \(old.path)."
                return
            }
        }
        profile.backup.destination = target.path
        if var upgrade = activeUpgrade, upgrade.backupFolder == old.path {
            upgrade.backupFolder = target.path
            setActiveUpgrade(upgrade)
        }
        refreshBackups()
    }

    /// Returns to `<servers folder>/LeafJuice/backups/<server name>`. Backups already made stay where they are.
    public func useDefaultBackupFolder() {
        profile.backup.destination = nil
        pinBackupFolder()
        refreshBackups()
    }

    public func refreshBackups() { backups = Backups.list(profile) }

    /// Takes a consistent backup. While running, saving is paused so the world doesn't change underneath it.
    @discardableResult
    public func backupNow(trigger: String = "manual", scope: BackupScope? = nil) async throws -> BackupRecord {
        guard !backingUp else { throw LeafError("A backup is already running.") }
        guard state == .running || state.canStart else { throw LeafError("Wait until the server has finished starting or stopping.") }
        // Observed: Folia has no save-off or save-all, so a running world can't be held still.
        if state == .running, profile.software.flavor == .folia {
            throw LeafError("Folia can't pause saving, so it can only be backed up while stopped. Stop the server, then back up.")
        }
        backingUp = true
        defer { backingUp = false }
        pinBackupFolder()
        let previousActivity = activity
        setActivity("Backing up…")
        defer { setActivity(previousActivity) }
        let wasRunning = state == .running
        if wasRunning, let process {
            process.send("save-off")
            let saved = Task { await waitForLine(containing: "saved the game", timeout: .seconds(120)) }
            await Task.yield()
            process.send("save-all flush")
            if await !saved.value { appendWrapper("The server didn't confirm its save in time. Backing up anyway.", level: .warn) }
        }
        defer { if wasRunning { self.process?.send("save-on") } }
        let record = try await Backups.create(profile, root: paths.root, trigger: trigger, scope: scope)
        profile.backup.lastRun = record.date
        Backups.prune(profile, protecting: record.fileName)
        await copyToMirror(record)
        refreshBackups()
        appendWrapper("Backup finished: \(Format.bytes(record.size)).", level: .info)
        recordEvent(.backup, "Backed up", detail: "\(Format.bytes(record.size)), \(trigger)")
        return record
    }

    /// A problem here is reported loudly, but never fails the backup itself, which already exists.
    private func copyToMirror(_ record: BackupRecord) async {
        guard let path = profile.backup.mirror, !path.isEmpty, !isTrialCopy else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        do {
            setActivity("Copying the backup to your second location…")
            try await Backups.mirror(record, profile: profile, to: folder)
            Backups.pruneMirror(profile, folder: folder, protecting: record.fileName)
            profile.backup.lastMirrored = Date()
            appendWrapper("Backup copied to \(path).", level: .info)
        } catch {
            appendWrapper("Couldn't copy the backup to your second location: \(error.localizedDescription)", level: .warn)
            let now = Date()
            reportIssue(IssueRecord(
                id: "wrapper:mirror-failed", ruleID: "wrapper-mirror", title: "A backup wasn't copied to your second location", severity: .warning, category: "Backups",
                explanation: "The backup itself is fine, but it's only in one place. \(error.localizedDescription)",
                steps: ["If it's on another drive, check it's connected.", "It's tried again with the next backup."],
                action: IssueAction(page: "backups", label: "Open Backups"), sample: error.localizedDescription, firstSeen: now, lastSeen: now))
            raiseAlert("A backup wasn't copied", error.localizedDescription)
        }
    }

    public func restoreBackup(_ record: BackupRecord) async throws {
        guard state.canStart else { throw LeafError("Stop the server before restoring a backup.") }
        // Making the safety copy runs retention, which could otherwise remove the very backup being restored.
        let wasPinned = record.pinned
        if !wasPinned { try? Backups.setPinned(record, pinned: true, profile: profile) }
        defer { if !wasPinned { try? Backups.setPinned(record, pinned: false, profile: profile); refreshBackups() } }
        // A safety copy of the present first, in case this was a mistake. It's pinned so pruning can't take it.
        let safety = try await backupNow(trigger: "before-restore", scope: record.scope)
        try? Backups.setPinned(safety, pinned: true, profile: profile)
        Backups.trimSafetyCopies(profile)
        setActivity("Restoring backup…")
        defer { setActivity(nil) }
        try await Backups.restore(record, profile: profile, root: paths.root)
        recordEvent(.restore, "Restored the backup from \(record.date.formatted(date: .abbreviated, time: .shortened))")
        // A whole-folder backup knows exactly what it ran, so it can start straight away.
        if record.scope == .everything, let software = record.softwareState,
           FileOps.exists(paths.root.appendingPathComponent(software.jarName)) {
            var restored = software
            restored.lastCheck = profile.software.lastCheck
            profile.software = restored
            if let launch = record.launch { profile.launch = launch }
            softwareUpdate = nil
        } else if record.mcVersion != profile.software.mcVersion {
            // Restoring a world from an older version must put the matching version back in charge.
            profile.software.mcVersion = record.mcVersion
            profile.software.build = nil
            // Put the matching jar back if there is one. Without it, the start check refuses to run.
            let wanted = "-\(record.mcVersion)-"
            let rootJars = FileOps.children(paths.root).map(\.lastPathComponent).filter { $0.hasSuffix(".jar") }
            if let jar = rootJars.first(where: { $0.contains(wanted) }) {
                profile.software.jarName = jar
            } else if let jar = archivedJars.first(where: { $0.contains(wanted) }) {
                try? FileOps.move(paths.jarArchive.appendingPathComponent(jar), to: paths.root.appendingPathComponent(jar))
                profile.software.jarName = jar
            } else {
                notice = "This backup was made on Minecraft \(record.mcVersion). Download that version on the Software page before starting."
            }
        }
        await refreshPluginsAndConfigs()
        refreshBackups()
    }

    public func setPinned(_ record: BackupRecord, pinned: Bool) {
        try? Backups.setPinned(record, pinned: pinned, profile: profile)
        refreshBackups()
    }

    public func deleteBackup(_ record: BackupRecord) throws {
        try Backups.delete(record, profile: profile)
        refreshBackups()
    }

    // MARK: Upgrades

    /// A whole-folder archive of the server as it stands, proven readable, pinned so nothing prunes it.
    func makeRestorePoint() async throws -> BackupRecord {
        let worlds = Backups.worldFolders(paths.root)
        let record = try await backupNow(trigger: "before-upgrade", scope: .everything)
        try await Backups.verify(record, in: Backups.destination(profile), expectingWorlds: worlds)
        try Backups.setPinned(record, pinned: true, profile: profile)
        refreshBackups()
        appendWrapper("Restore point verified: \(worlds.joined(separator: ", ")) (\(Format.bytes(record.size))).", level: .info)
        return record
    }

    func setActiveUpgrade(_ upgrade: UpgradeRecord?) {
        activeUpgrade = upgrade
        if let upgrade { try? JSONStore.save(upgrade, to: paths.activeUpgrade) }
        else { try? FileManager.default.removeItem(at: paths.activeUpgrade) }
    }

    private func saveShelved() { try? JSONStore.save(shelved, to: paths.shelved) }

    /// Stops the server if it's running, for actions that need it down.
    func stopAndWait() async throws {
        if state == .running || state == .starting { stop() }
        for _ in 0..<(180 * 4) where state.isLive { try? await Task.sleep(for: .milliseconds(250)) }
        guard state.canStart else { throw LeafError("The server didn't stop, so nothing was changed.") }
    }

    /// Accepts the upgrade. Its restore point goes back to being an ordinary backup under the retention rules.
    public func keepUpgrade() {
        guard let upgrade = activeUpgrade else { return }
        let folder = URL(fileURLWithPath: upgrade.backupFolder, isDirectory: true)
        if let record = Backups.list(profile, in: folder).first(where: { $0.fileName == upgrade.backupFile }) {
            try? Backups.setPinned(record, pinned: false, profile: profile, in: folder)
        }
        setActiveUpgrade(nil)
        refreshBackups()
    }

    /// Returns to how things were before the upgrade. The upgraded state moves to the Shelf rather than being lost.
    /// If any step before the swap fails, the server is left exactly as it was.
    public func rollBackUpgrade() async throws {
        guard let upgrade = activeUpgrade else { return }
        let folder = URL(fileURLWithPath: upgrade.backupFolder, isDirectory: true)
        guard let record = Backups.list(profile, in: folder).first(where: { $0.fileName == upgrade.backupFile }) else {
            throw LeafError("The restore point \(upgrade.backupFile) wasn't found in \(folder.path). If it's on an external drive, check it's connected. Nothing was changed.")
        }
        try await Backups.verify(record, in: folder, expectingWorlds: upgrade.worlds)
        try await stopAndWait()
        setActivity("Moving the upgraded server to the Shelf…")
        defer { setActivity(nil) }
        let shelfFolder = Backups.shelf(profile)
        let shelfRecord = try await Backups.create(profile, root: paths.root, trigger: "shelved", scope: .everything, into: shelfFolder)
        try await Backups.verify(shelfRecord, in: shelfFolder, expectingWorlds: Backups.worldFolders(paths.root))

        setActivity("Restoring the server from before the upgrade…")
        let current = profile.software
        try await Backups.restore(record, profile: profile, root: paths.root, from: folder)
        if current.jarName != upgrade.from.jarName, let jar = FileOps.child(current.jarName, of: paths.root) {
            try? FileManager.default.removeItem(at: jar)
        }
        var software = upgrade.from
        software.lastCheck = current.lastCheck
        profile.software = software
        softwareUpdate = nil
        shelved.insert(ShelvedUpgrade(
            label: upgrade.toLabel, software: current, fromLabel: upgrade.from.label,
            fileName: shelfRecord.fileName, size: shelfRecord.size), at: 0)
        saveShelved()
        setActiveUpgrade(nil)
        appendWrapper("Rolled back to \(software.label). The upgraded server is on the Shelf.", level: .info)
        recordEvent(.restore, "Undid: \(upgrade.toLabel)")
        await refreshPluginsAndConfigs()
        await refreshWorlds()
        refreshBackups()
    }

    /// Picks a shelved upgrade back up. What's running now gets a fresh restore point first.
    public func resumeShelved(_ entry: ShelvedUpgrade) async throws {
        let folder = Backups.shelf(profile)
        guard let record = Backups.list(profile, in: folder).first(where: { $0.fileName == entry.fileName }) else {
            throw LeafError("That shelved upgrade's file is missing from \(folder.path).")
        }
        try await Backups.verify(record, in: folder, expectingWorlds: [])
        try await stopAndWait()
        let before = profile.software
        let worlds = Backups.worldFolders(paths.root)
        let point = try await makeRestorePoint()
        setActivity("Bringing back \(entry.label)…")
        defer { setActivity(nil) }
        try await Backups.restore(record, profile: profile, root: paths.root, from: folder)
        if before.jarName != entry.software.jarName, let jar = FileOps.child(before.jarName, of: paths.root) {
            try? FileManager.default.removeItem(at: jar)
        }
        var software = entry.software
        software.lastCheck = before.lastCheck
        profile.software = software
        setActiveUpgrade(UpgradeRecord(
            from: before, toLabel: entry.label, toFileName: entry.software.jarName,
            backupFile: point.fileName, backupFolder: Backups.destination(profile).path, worlds: worlds, size: point.size))
        // Its contents are live again, so the shelf copy has done its job.
        try? Backups.delete(record, profile: profile, in: folder)
        shelved.removeAll { $0.id == entry.id }
        saveShelved()
        await refreshPluginsAndConfigs()
        await refreshWorlds()
        refreshBackups()
    }

    public func deleteShelved(_ entry: ShelvedUpgrade) throws {
        let folder = Backups.shelf(profile)
        if let record = Backups.list(profile, in: folder).first(where: { $0.fileName == entry.fileName }) {
            try Backups.delete(record, profile: profile, in: folder)
        }
        shelved.removeAll { $0.id == entry.id }
        saveShelved()
    }

    // MARK: Worlds

    /// The installed Multiverse-Core's major version, if it's installed and enabled.
    public var multiverseMajor: Int? {
        guard let plugin = plugins.first(where: { $0.key == Multiverse.pluginKey && $0.enabled }) else { return nil }
        return LooseVersion(plugin.version)?.parts.first ?? 5
    }

    private var multiverseRemovesPlayers: Bool {
        Multiverse.supportsRemovePlayers(plugins.first { $0.key == Multiverse.pluginKey }.flatMap { LooseVersion($0.version) })
    }

    public func refreshWorlds() async {
        let p = paths
        worlds = await Task.detached(priority: .utility) { WorldScanner.scan(p) }.value
    }

    public struct WorldOperation: Equatable, Sendable {
        public var title: String
        /// Console lines from this point on belong to the operation.
        public var firstLineID: Int
        public var finished = false
        public var succeeded = false
    }

    private func requireMultiverse() throws -> Int {
        guard state == .running else { throw LeafError("Start the server first: Multiverse does this work from inside it.") }
        guard let major = multiverseMajor else { throw LeafError("Multiverse-Core isn't installed.") }
        guard worldOperation?.finished ?? true else { throw LeafError("Another world action is still running.") }
        return major
    }

    /// Sends one Multiverse command and reports how it went. Output stays visible in the page.
    private func runWorldCommand(_ title: String, command: String, success: String, timeout: Duration = .seconds(120)) async {
        worldOperation = WorldOperation(title: title, firstLineID: nextLineID)
        send(command)
        // Stop waiting as soon as Multiverse says it can't, rather than sitting out the timeout.
        let line = await waitForLine(containingAny: [success] + Multiverse.failureTexts, timeout: timeout)
        worldOperation?.finished = true
        worldOperation?.succeeded = line?.lowercased().contains(success) ?? false
        // Multiverse saves worlds.yml just after reporting success.
        try? await Task.sleep(for: .seconds(1))
        await refreshWorlds()
    }

    public func createWorld(_ world: NewWorld) async throws {
        let major = try requireMultiverse()
        guard Multiverse.isValidName(world.name) else { throw LeafError("World names can use letters, numbers, - and _.") }
        guard Multiverse.isValidSeed(world.seed) else { throw LeafError("Seeds can use letters, numbers, - and _.") }
        await runWorldCommand("Creating \(world.name)", command: Multiverse.createCommand(world, major: major), success: Multiverse.successText(.create, major: major), timeout: .seconds(300))
    }

    public func importWorld(_ name: String, environment: WorldEnvironment) async throws {
        let major = try requireMultiverse()
        guard Multiverse.isValidName(name) else { throw LeafError("Multiverse can't import a world with that name.") }
        await runWorldCommand("Importing \(name)", command: Multiverse.importCommand(name, environment: environment), success: Multiverse.successText(.importWorld, major: major), timeout: .seconds(300))
    }

    public func loadWorld(_ name: String) async throws {
        let major = try requireMultiverse()
        await runWorldCommand("Loading \(name)", command: Multiverse.loadCommand(name), success: Multiverse.successText(.load, major: major))
    }

    public func unloadWorld(_ world: WorldEntry) async throws {
        let major = try requireMultiverse()
        guard !world.isCore else { throw LeafError("The server's own worlds can't be unloaded.") }
        await runWorldCommand("Unloading \(world.name)", command: Multiverse.unloadCommand(world.name, removePlayers: multiverseRemovesPlayers), success: Multiverse.successText(.unload, major: major))
    }

    /// Stops Multiverse managing a world. Its folder stays.
    public func removeWorldFromMultiverse(_ world: WorldEntry) async throws {
        let major = try requireMultiverse()
        guard !world.isCore else { throw LeafError("The server's own worlds can't be removed.") }
        await runWorldCommand("Removing \(world.name) from Multiverse", command: Multiverse.removeCommand(world.name, removePlayers: multiverseRemovesPlayers), success: Multiverse.successText(.remove, major: major))
    }

    public func cloneWorld(_ world: WorldEntry, to target: String) async throws {
        let major = try requireMultiverse()
        guard Multiverse.isValidName(target) else { throw LeafError("World names can use letters, numbers, - and _.") }
        await runWorldCommand("Copying \(world.name) to \(target)", command: Multiverse.cloneCommand(world.name, to: target), success: Multiverse.successText(.clone, major: major), timeout: .seconds(600))
    }

    public func modifyWorld(_ world: WorldEntry, property: String, value: String) async throws {
        let major = try requireMultiverse()
        guard value.range(of: #"^[A-Za-z0-9_ .:'&-]*$"#, options: .regularExpression) != nil else {
            throw LeafError("That value contains characters that can't be sent safely.")
        }
        await runWorldCommand("Setting \(property) on \(world.name)", command: Multiverse.modifyCommand(world.name, property: property, value: value, major: major), success: Multiverse.successText(.modify, major: major), timeout: .seconds(15))
    }

    /// Permanently deletes a world, after an automatic backup. A failed backup stops the delete.
    public func deleteWorld(_ world: WorldEntry) async throws {
        let major = try requireMultiverse()
        guard !world.isCore else { throw LeafError("The server's own worlds can't be deleted here.") }
        guard Multiverse.isValidName(world.name) else { throw LeafError("Multiverse can't delete a world with that name.") }
        try await backupNow(trigger: "before-world-delete", scope: .worlds)

        worldOperation = WorldOperation(title: "Deleting \(world.name)", firstLineID: nextLineID)
        let done = Multiverse.successText(.delete, major: major)
        send(Multiverse.deleteCommand(world.name, removePlayers: multiverseRemovesPlayers))
        // The prompt carries a one-time code. If confirmation is switched off, deletion just starts.
        let first = await waitForLine(containingAny: ["/mv confirm", done, "deleting world"], timeout: .seconds(20))
        if let first, let confirm = Multiverse.confirmCommand(fromPrompt: first) { send(confirm) }
        var deleted = first?.lowercased().contains(done) ?? false
        if !deleted, first != nil {
            deleted = await waitForLine(containing: done, timeout: .seconds(120))
        }
        worldOperation?.finished = true
        worldOperation?.succeeded = deleted
        try? await Task.sleep(for: .seconds(1))
        await refreshWorlds()
    }

    public func dismissWorldOperation() { worldOperation = nil }

    // MARK: Java

    public func installJava(major: Int) async throws {
        setActivity("Downloading Java \(major)…", progress: 0)
        defer { setActivity(nil) }
        _ = try await JavaManager.installTemurin(major: major) { [weak self] value in
            Task { @MainActor in self?.activityProgress = value }
        }
        runtimes = await JavaManager.discover()
    }

    public func stopTicker() { ticker?.cancel() }
}
