import Foundation

// Smart backups (owner, 2026-11-14, D186): back up when the world has actually changed, keep a tidy spread of old
// ones, and use whichever storage is there, in the owner's order.
//
// "A dynamic backup system that only backs up when things actually change." "It should be able to use multiple
// storage devices, so long as they're there. If they aren't it'll default to another, or try its local folder."

// MARK: - Settings

public enum BackupTiming: String, Codable, CaseIterable, Sendable {
    /// After people have played: once the server has been empty a while, or during a long session.
    case afterPlay
    /// Every few hours while the server runs, whatever happened. How backups worked before.
    case interval
}

public struct SmartBackupConfig: Codable, Equatable, Sendable {
    public var timing: BackupTiming = .afterPlay
    /// How long the server must have been empty before an after-play backup, so a quick reconnect doesn't start one.
    public var idleMinutes = 10
    /// Never two automatic backups closer together than this.
    public var minimumGapMinutes = 60
    /// During a long session, back up anyway once the last backup is this old.
    public var duringPlayHours = 6
    /// With nobody playing, the world can still change (farms, plugins). Back up then too, but no more often than this.
    public var quietChangeHours = 24
    /// Keeping: everything from the last `recentHours`, then the newest per day, then the newest per week.
    public var tiered = true
    public var recentHours = 24
    public var dailyDays = 7
    public var weeklyWeeks = 8
    /// Where backups go, in order. The first one that's there, writable and has room is used. The server's own
    /// folder beside the servers comes after all of these, so there's always somewhere.
    public var targets: [String] = []
    public init() {}

    /// What a server from before smart backups gets until the owner switches: every few hours, simple keeping.
    public static var legacy: SmartBackupConfig { var c = SmartBackupConfig(); c.timing = .interval; c.tiered = false; return c }

    enum CodingKeys: String, CodingKey { case timing, idleMinutes, minimumGapMinutes, duringPlayHours, quietChangeHours, tiered, recentHours, dailyDays, weeklyWeeks, targets }
    /// A server set up before this existed keeps backing up every few hours, with its old keeping rules, until
    /// the owner switches. Nothing changes under a running server without a yes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SmartBackupConfig()
        timing = try c.decodeIfPresent(BackupTiming.self, forKey: .timing) ?? .interval
        idleMinutes = try c.decodeIfPresent(Int.self, forKey: .idleMinutes) ?? d.idleMinutes
        minimumGapMinutes = try c.decodeIfPresent(Int.self, forKey: .minimumGapMinutes) ?? d.minimumGapMinutes
        duringPlayHours = try c.decodeIfPresent(Int.self, forKey: .duringPlayHours) ?? d.duringPlayHours
        quietChangeHours = try c.decodeIfPresent(Int.self, forKey: .quietChangeHours) ?? d.quietChangeHours
        tiered = try c.decodeIfPresent(Bool.self, forKey: .tiered) ?? false
        recentHours = try c.decodeIfPresent(Int.self, forKey: .recentHours) ?? d.recentHours
        dailyDays = try c.decodeIfPresent(Int.self, forKey: .dailyDays) ?? d.dailyDays
        weeklyWeeks = try c.decodeIfPresent(Int.self, forKey: .weeklyWeeks) ?? d.weeklyWeeks
        targets = try c.decodeIfPresent([String].self, forKey: .targets) ?? []
    }
}

// MARK: - When to back up

public enum SmartBackup {
    /// What the server has been doing, as the tick sees it.
    public struct Activity: Equatable, Sendable {
        public var now: Date
        public var playersOnline: Int
        /// When the last player left, if the server is empty now.
        public var emptySince: Date?
        /// Whether anyone has been on since the last backup.
        public var playedSinceBackup: Bool
        /// The newest change to any world file, if known.
        public var worldChangedAt: Date?
        public var lastBackup: Date?
        public init(now: Date, playersOnline: Int, emptySince: Date?, playedSinceBackup: Bool, worldChangedAt: Date?, lastBackup: Date?) {
            self.now = now; self.playersOnline = playersOnline; self.emptySince = emptySince
            self.playedSinceBackup = playedSinceBackup; self.worldChangedAt = worldChangedAt; self.lastBackup = lastBackup
        }
    }

    public enum Decision: Equatable, Sendable {
        case backUp(trigger: String, reason: String)
        case wait(String)
    }

    /// Decides whether to back up now. Only this decides; the tick follows it.
    public static func decide(_ c: SmartBackupConfig, _ a: Activity) -> Decision {
        let sinceLast = a.lastBackup.map { a.now.timeIntervalSince($0) } ?? .infinity
        let gap = Double(max(5, c.minimumGapMinutes)) * 60
        guard sinceLast >= gap else { return .wait("The last backup was less than \(c.minimumGapMinutes) minutes ago.") }
        let changedSince = a.worldChangedAt.map { changed in a.lastBackup.map { changed > $0 } ?? true } ?? false

        if a.playersOnline > 0 {
            if sinceLast >= Double(max(1, c.duringPlayHours)) * 3600 {
                return .backUp(trigger: "during-play", reason: "People have been playing, and the last backup is over \(c.duringPlayHours) hours old.")
            }
            return .wait("People are playing. It backs up once they've left.")
        }
        if a.playedSinceBackup {
            guard let empty = a.emptySince else { return .wait("Waiting to see the server empty.") }
            let idle = a.now.timeIntervalSince(empty)
            if idle >= Double(max(1, c.idleMinutes)) * 60 {
                return .backUp(trigger: "after-play", reason: "Everyone left \(Int(idle / 60)) minutes ago.")
            }
            return .wait("Everyone left. It backs up after \(c.idleMinutes) quiet minutes, in case someone comes back.")
        }
        if changedSince, sinceLast >= Double(max(1, c.quietChangeHours)) * 3600 {
            return .backUp(trigger: "world-changed", reason: "Nobody played, but the world's files changed since the last backup.")
        }
        return .wait(changedSince ? "The world changed a little with nobody on. It's backed up at most once every \(c.quietChangeHours) hours like that." : "Nothing has changed since the last backup.")
    }

    // MARK: Keeping

    /// Which backups tiered keeping would remove. Never a pinned one, the one just made, the server's first backup,
    /// or anything LeafJuice didn't make (those have no record, so they never reach this list).
    public static func tieredPrunable(_ records: [BackupRecord], config c: SmartBackupConfig, now: Date = Date(), protecting: String? = nil,
                                      calendar: Calendar = .current) -> [BackupRecord] {
        let sorted = records.sorted { $0.date > $1.date }
        guard let first = sorted.last else { return [] }
        let recentCutoff = now.addingTimeInterval(-Double(max(1, c.recentHours)) * 3600)
        let dailyCutoff = now.addingTimeInterval(-Double(max(0, c.dailyDays)) * 86_400)
        let weeklyCutoff = now.addingTimeInterval(-Double(max(0, c.weeklyWeeks)) * 7 * 86_400)
        var keptDays = Set<DateComponents>(), keptWeeks = Set<DateComponents>()
        var out: [BackupRecord] = []
        for r in sorted {
            if r.pinned || r.fileName == protecting || r.fileName == first.fileName { continue }
            if r.date >= recentCutoff { continue }
            if r.date >= dailyCutoff {
                let day = calendar.dateComponents([.year, .month, .day], from: r.date)
                if keptDays.insert(day).inserted { continue }
            } else if r.date >= weeklyCutoff {
                let week = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: r.date)
                if keptWeeks.insert(week).inserted { continue }
            }
            out.append(r)
        }
        return out
    }

    // MARK: Where

    /// One place backups could go, and whether it can take one now.
    public struct Target: Equatable, Sendable {
        public var path: String
        public var usable: Bool
        public var reason: String
    }

    /// Checks each target in order. `needed` is the most the backup could take.
    public static func check(_ paths: [String], needed: Int64, fileManager: FileManager = .default,
                             space: (URL) -> (free: Int64?, capacity: Int64?) = { (DiskGuard.standIn ?? DiskGuard.space)($0) }) -> [Target] {
        paths.map { raw in
            let path = (raw as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: path, isDirectory: true)
            // An external drive's mount point exists only while it's plugged in. A missing parent means it isn't there,
            // and making the folder would quietly fill the Mac's own disk instead.
            let parent = url.deletingLastPathComponent().path
            var isDir: ObjCBool = false
            if !fileManager.fileExists(atPath: path, isDirectory: &isDir) {
                guard fileManager.fileExists(atPath: parent, isDirectory: &isDir), isDir.boolValue else {
                    return Target(path: path, usable: false, reason: "Not connected.")
                }
            } else if !isDir.boolValue {
                return Target(path: path, usable: false, reason: "Something that isn't a folder is there.")
            }
            let probe = fileManager.fileExists(atPath: path) ? path : parent
            guard fileManager.isWritableFile(atPath: probe) else { return Target(path: path, usable: false, reason: "Can't be written to.") }
            let probeURL = URL(fileURLWithPath: probe)
            let room = space(probeURL)
            if let why = DiskGuard.refusal(free: room.free, capacity: room.capacity, needed: needed) {
                return Target(path: path, usable: false, reason: why)
            }
            return Target(path: path, usable: true, reason: "Ready.")
        }
    }

    /// The first usable target, then the server's own folder. Nil only when even that can't take it.
    public static func choose(_ targets: [Target], fallback: Target) -> Target? {
        targets.first(where: \.usable) ?? (fallback.usable ? fallback : nil)
    }
}

// MARK: - Disk guard

/// Keeps backups and drills from filling a disk. Observed 2026-11-14: a drill unpacking a 47 GB backup took the Mac's
/// disk from about 50 GB free to 6 GB. Every write this size is checked first, and refused if it would leave less than
/// 20 GB free. (A share of the disk was tried first, but 5% of a 1 TB disk refused nearly everything on a normal Mac.)
public enum DiskGuard {
    public static let minimumFree: Int64 = 20 << 30

    public static func floor(capacity: Int64?) -> Int64 { minimumFree }

    /// Free space and size of the disk holding a folder. Checks pass their own, to stand in for a disk.
    public static func space(_ url: URL) -> (free: Int64?, capacity: Int64?) { (FileOps.freeSpace(at: url), capacity(at: url)) }

    /// For checks on a Mac whose own disk is nearly full: stands in for every disk the app asks about. Never set by the app.
    nonisolated(unsafe) public static var standIn: ((URL) -> (free: Int64?, capacity: Int64?))?
    /// For checks: stands in for "are these on the same disk?", since the check Mac has one. Never set by the app.
    nonisolated(unsafe) public static var sameDiskStandIn: ((URL, URL) -> Bool)?

    /// Why a write of `needed` bytes must not happen, or nil when it can. Unknown free space is a refusal.
    public static func refusal(free: Int64?, capacity: Int64?, needed: Int64) -> String? {
        guard let free else { return "Couldn't tell how much room is left there, so nothing was written." }
        let keep = floor(capacity: capacity)
        if free - needed < keep {
            return "Not enough room: \(Format.bytes(free)) free, it may need \(Format.bytes(needed)), and \(Format.bytes(keep)) is always left free."
        }
        return nil
    }

    public static func capacity(at url: URL) -> Int64? {
        var probe = url
        while !FileOps.exists(probe), probe.path != "/" { probe.deleteLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity.map(Int64.init)
    }

    /// Below this, a job that's already writing stops and removes what it wrote: 5 GB.
    public static func inFlightFloor(capacity: Int64?) -> Int64 { 5 << 30 }

    /// For `Tool.run(stopIf:)`: stops a running job when the disk holding `url` falls under the in-flight floor.
    public static func watch(_ url: URL) -> @Sendable () -> String? {
        let standIn = DiskGuard.standIn
        return {
            let room = (standIn ?? DiskGuard.space)(url)
            guard let free = room.free else { return "Couldn't read the free space any more." }
            let floor = inFlightFloor(capacity: room.capacity)
            return free < floor ? "Stopped to keep the disk from filling: \(Format.bytes(free)) was left, under \(Format.bytes(floor))." : nil
        }
    }

    /// Unpacked, a world takes more than its archive: region files are already compressed, so tar.gz saves little,
    /// and 47 GB became about 62 GB on the real server. Twice the archive leaves a margin.
    public static func unpackedEstimate(archive: Int64) -> Int64 { archive * 2 }

    /// Leaves out any folder on the running server's own disk, with the reason (2026-11-14). Stopped, any disk will do.
    public static func drillCandidates(_ folders: [URL], serverRoot: URL, serverRunning: Bool,
                                       sameDisk: (URL, URL) -> Bool = { (DiskGuard.sameDiskStandIn ?? FileOps.sameVolume)($0, $1) }) -> (kept: [URL], excluded: [String]) {
        guard serverRunning else { return (folders, []) }
        let kept = folders.filter { !sameDisk($0, serverRoot) }
        let excluded = folders.filter { sameDisk($0, serverRoot) }.map { "\($0.deletingLastPathComponent().path): it's on the running server's disk." }
        return (kept, excluded)
    }

    /// Where a drill may unpack: beside the backup on its own disk first, then the usual test-copies folder.
    /// Nil when neither has room, and the reasons.
    public static func drillFolder(candidates: [URL], needed: Int64, space: (URL) -> (free: Int64?, capacity: Int64?) = { (standIn ?? DiskGuard.space)($0) }) -> (URL?, [String]) {
        var reasons: [String] = []
        for folder in candidates {
            let room = space(folder)
            if let why = refusal(free: room.free, capacity: room.capacity, needed: needed) {
                reasons.append("\(folder.deletingLastPathComponent().path): \(why)")
            } else {
                return (folder, reasons)
            }
        }
        return (nil, reasons)
    }
}
