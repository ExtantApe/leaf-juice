import Foundation

// MARK: - Software

public enum Flavor: String, Codable, CaseIterable, Identifiable, Sendable {
    case paper, folia, purpur, vanilla, custom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .paper: "Paper"
        case .folia: "Folia"
        case .purpur: "Purpur"
        case .vanilla: "Vanilla"
        case .custom: "Custom jar"
        }
    }
    public var blurb: String {
        switch self {
        case .paper: "Fast, stable and runs Spigot and Bukkit plugins. The recommended choice."
        case .folia: "Paper split across CPU cores for very busy servers. Many plugins don't support it."
        case .purpur: "Paper with extra gameplay options."
        case .vanilla: "Mojang's server. No plugins."
        case .custom: "Any jar you provide, such as Spigot built with BuildTools. Leaf Juice won't update it."
        }
    }
    public var supportsPlugins: Bool { self != .vanilla }
    public var canDownload: Bool { self != .custom }
    /// Modrinth loader tags that run on this software.
    public var modrinthLoaders: [String] {
        switch self {
        case .paper: ["paper", "spigot", "bukkit"]
        case .purpur: ["purpur", "paper", "spigot", "bukkit"]
        case .folia: ["folia"]
        case .vanilla: []
        case .custom: ["paper", "spigot", "bukkit"]
        }
    }
    public var hangarPlatform: String { "PAPER" }
}

public struct SoftwareState: Codable, Equatable, Sendable {
    public var flavor: Flavor = .paper
    public var mcVersion: String = ""
    public var build: Int?
    public var jarName: String = ""
    /// Fill channels accepted for updates, e.g. ["STABLE"].
    public var channels: [String] = ["STABLE"]
    /// Install new builds of the same Minecraft version without asking, at the next restart.
    public var autoInstallBuilds = false
    public var requiredJava: Int?
    public var recommendedFlags: [String] = []
    public var supportStatus: String?
    public var lastCheck: Date?
    public init() {}

    public var gameVersion: GameVersion? { GameVersion(mcVersion) }
    public var label: String {
        var text = flavor.title
        if !mcVersion.isEmpty { text += " \(mcVersion)" }
        if let build { text += " build \(build)" }
        return text
    }
}

// MARK: - Launch

public enum FlagPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case recommended, none, custom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .recommended: "Recommended"
        case .none: "Java defaults"
        case .custom: "Only my flags"
        }
    }
}

public struct LaunchConfig: Codable, Equatable, Sendable {
    /// nil picks a suitable runtime automatically.
    public var javaPath: String?
    public var minMemoryMB = 2048
    public var maxMemoryMB = 4096
    public var preset: FlagPreset = .recommended
    public var extraJVMArgs = ""
    public var serverArgs = ""
    public var noGUI = true
    public var restartOnCrash = true
    public var keepAwake = true
    public var startWithApp = false
    public init() {}
}

/// Aikar's flags, used only when Paper's API hasn't supplied its own list.
public let fallbackRecommendedFlags = [
    "-XX:+UseG1GC", "-XX:+ParallelRefProcEnabled", "-XX:MaxGCPauseMillis=200",
    "-XX:+UnlockExperimentalVMOptions", "-XX:+DisableExplicitGC", "-XX:+AlwaysPreTouch",
    "-XX:G1NewSizePercent=30", "-XX:G1MaxNewSizePercent=40", "-XX:G1HeapRegionSize=8M",
    "-XX:G1ReservePercent=20", "-XX:G1HeapWastePercent=5", "-XX:G1MixedGCCountTarget=4",
    "-XX:InitiatingHeapOccupancyPercent=15", "-XX:G1MixedGCLiveThresholdPercent=90",
    "-XX:G1RSetUpdatingPauseTimePercent=5", "-XX:SurvivorRatio=32", "-XX:+PerfDisableSharedMem",
    "-XX:MaxTenuringThreshold=1", "-Dusing.aikars.flags=https://mcflags.emc.gs", "-Daikars.new.flags=true",
]

public enum LaunchCommand {
    public static func jvmArguments(_ config: LaunchConfig, software: SoftwareState) -> [String] {
        var args = ["-Xms\(config.minMemoryMB)M", "-Xmx\(config.maxMemoryMB)M"]
        if config.preset == .recommended {
            args += software.recommendedFlags.isEmpty ? fallbackRecommendedFlags : software.recommendedFlags
        }
        return args + ArgumentString.split(config.extraJVMArgs)
    }

    public static func arguments(_ config: LaunchConfig, software: SoftwareState) -> [String] {
        var args = jvmArguments(config, software: software) + ["-jar", software.jarName]
        args += ArgumentString.split(config.serverArgs)
        if config.noGUI, !args.contains("nogui"), !args.contains("--nogui") { args.append("--nogui") }
        return args
    }

    public static func display(java: String, _ config: LaunchConfig, software: SoftwareState) -> String {
        ([java] + arguments(config, software: software)).map(ArgumentString.quote).joined(separator: " ")
    }
}

/// Ready-made sizes. Applying one sets memory now and stages the world settings.
public struct ScalingPreset: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let memoryMB: Int
    public let viewDistance: Int
    public let simulationDistance: Int
    public let maxPlayers: Int

    public static let all = [
        ScalingPreset(id: "friends", title: "Friends", detail: "Up to 5 players", memoryMB: 3072, viewDistance: 10, simulationDistance: 8, maxPlayers: 5),
        ScalingPreset(id: "group", title: "Group", detail: "Up to 15 players", memoryMB: 6144, viewDistance: 9, simulationDistance: 7, maxPlayers: 15),
        ScalingPreset(id: "community", title: "Community", detail: "Up to 40 players", memoryMB: 10240, viewDistance: 8, simulationDistance: 6, maxPlayers: 40),
        ScalingPreset(id: "large", title: "Large", detail: "Up to 100 players", memoryMB: 16384, viewDistance: 7, simulationDistance: 5, maxPlayers: 100),
    ]
}

// MARK: - Backups

public enum BackupScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case worlds, standard, everything
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .worlds: "Worlds only"
        case .standard: "Worlds, settings and plugins"
        case .everything: "Whole folder"
        }
    }
}

public struct BackupConfig: Codable, Equatable, Sendable {
    public var enabled = true
    public var intervalHours = 24
    public var scope: BackupScope = .standard
    /// nil uses Leaf Juice's own folder.
    public var destination: String?
    public var keepLast = 7
    public var keepDays = 30
    public var beforeUpdates = true
    public var lastRun: Date?
    public init() {}
}

// MARK: - Restart schedule

public struct RestartSchedule: Codable, Equatable, Sendable {
    public var enabled = false
    public var hour = 5
    public var minute = 0
    /// 1 is Sunday, as in Calendar. Empty means every day.
    public var weekdays: [Int] = []
    public var onlyIfPending = false
    /// Seconds before a restart at which players are warned.
    public var warnings: [Int] = [900, 300, 60, 10]
    public var message = "Server restarting in {time}."
    public init() {}

    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        var soonest: Date?
        for day in weekdays.isEmpty ? [nil] : weekdays.map(Optional.some) {
            var parts = DateComponents(hour: hour, minute: minute, second: 0)
            parts.weekday = day
            if let d = calendar.nextDate(after: date, matching: parts, matchingPolicy: .nextTime), soonest.map({ d < $0 }) ?? true {
                soonest = d
            }
        }
        return soonest
    }

    public static func describe(seconds: Int) -> String {
        if seconds >= 3600, seconds % 3600 == 0 { return "\(seconds / 3600) hour\(seconds == 3600 ? "" : "s")" }
        if seconds >= 60 { let m = seconds / 60; return "\(m) minute\(m == 1 ? "" : "s")" }
        return "\(seconds) second\(seconds == 1 ? "" : "s")"
    }
}

// MARK: - Profile

public struct ServerProfile: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name = "Minecraft Server"
    public var software = SoftwareState()
    public var launch = LaunchConfig()
    public var backup = BackupConfig()
    public var restart = RestartSchedule()
    public var lastPluginCheck: Date?
    public init() {}
}

// MARK: - State

public enum ServerState: Equatable, Sendable {
    case stopped, starting, running, stopping
    case crashed(code: Int32)
    case external(pid: Int32)

    public var title: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .stopping: "Stopping"
        case .crashed: "Crashed"
        case .external: "Running elsewhere"
        }
    }
    public var isLive: Bool { self == .starting || self == .running || self == .stopping }
    public var canStart: Bool {
        switch self {
        case .stopped, .crashed: true
        default: false
        }
    }
}

public struct ProcessMetrics: Equatable, Sendable {
    public var memoryBytes: Int64
    public var cpuPercent: Double
}

public struct ConsoleLine: Identifiable, Equatable, Sendable {
    public enum Origin: Sendable { case server, command, wrapper }
    public let id: Int
    public let text: String
    public let level: LogLevel
    public let origin: Origin
}

public enum LogLevel: String, Codable, Comparable, Sendable {
    case debug, info, warn, error
    private var rank: Int { [.debug: 0, .info: 1, .warn: 2, .error: 3][self]! }
    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rank < b.rank }
}

// MARK: - Preflight

public struct Blocker: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case eula, noJar, java(required: Int), portBusy(Int), other
    }
    public let id = UUID()
    public let kind: Kind
    public let title: String
    public let detail: String
    public static func == (a: Blocker, b: Blocker) -> Bool { a.kind == b.kind && a.title == b.title }
}
