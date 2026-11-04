import Foundation

// All of this stays on this Mac, in the server's `.leafjuice` folder. Nothing is ever sent anywhere.

// MARK: - The timeline

public struct ServerEvent: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case start, stop, crash, software, plugin, config, backup, restore, rename, player, cleanup, drill, lag
    }
    public var id: String { "\(date.timeIntervalSince1970)-\(title)" }
    public var date: Date
    public var kind: Kind
    public var title: String
    public var detail: String?
    public init(date: Date = Date(), kind: Kind, title: String, detail: String? = nil) {
        self.date = date; self.kind = kind; self.title = title; self.detail = detail
    }
}

// MARK: - Trends

/// Five minutes of server health, boiled down to one row.
public struct MetricSample: Codable, Identifiable, Equatable, Sendable {
    public var id: Date { date }
    public var date: Date
    public var tps: Double?
    public var mspt: Double?
    public var memoryMB: Double?
    public var cpu: Double?
    public var players: Int
    /// The longest garbage collection pause, which players feel as a stutter.
    public var gcPauseMS: Double?
    public init(date: Date, tps: Double? = nil, mspt: Double? = nil, memoryMB: Double? = nil, cpu: Double? = nil, players: Int = 0, gcPauseMS: Double? = nil) {
        self.date = date; self.tps = tps; self.mspt = mspt; self.memoryMB = memoryMB; self.cpu = cpu; self.players = players; self.gcPauseMS = gcPauseMS
    }
}

/// One row a day, for slow things.
public struct DailySizes: Codable, Identifiable, Equatable, Sendable {
    public var id: Date { date }
    public var date: Date
    public var worldBytes: Int64
    public var backupBytes: Int64
    public var freeBytes: Int64
}

/// Append-only files, one JSON value per line, trimmed as they grow. Cheap enough to write every few minutes.
public enum History {
    static let maxEvents = 5000
    /// 90 days of five-minute rows.
    static let maxSamples = 90 * 288
    static let maxDays = 400

    static func events(_ paths: ServerPaths) -> URL { paths.meta.appendingPathComponent("timeline.jsonl") }
    static func samples(_ paths: ServerPaths) -> URL { paths.meta.appendingPathComponent("metrics.jsonl") }
    static func days(_ paths: ServerPaths) -> URL { paths.meta.appendingPathComponent("sizes.jsonl") }

    static func append<T: Encodable>(_ value: T, to url: URL, limit: Int) {
        guard let line = try? JSONStore.compactEncoder.encode(value) else { return }
        var row = line
        row.append(0x0A)
        do {
            try FileOps.ensureDir(url.deletingLastPathComponent())
            if !FileOps.exists(url) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: row)
        } catch { return }
        // Trimmed now and then rather than rewriting on every append.
        if FileOps.size(url) > Int64(limit) * 260, let text = try? String(contentsOf: url, encoding: .utf8) {
            let lines = text.split(whereSeparator: \.isNewline).suffix(limit)
            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) -> [T] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONStore.decoder
        return text.split(whereSeparator: \.isNewline).compactMap { try? decoder.decode(T.self, from: Data($0.utf8)) }
    }

    public static func record(_ event: ServerEvent, paths: ServerPaths) { append(event, to: events(paths), limit: maxEvents) }
    public static func record(_ sample: MetricSample, paths: ServerPaths) { append(sample, to: samples(paths), limit: maxSamples) }
    public static func record(_ day: DailySizes, paths: ServerPaths) { append(day, to: days(paths), limit: maxDays) }
}

public enum Trend {
    /// Days until the disk fills, from how fast free space has been falling. nil if it isn't, or it's too soon to say.
    public static func daysUntilFull(_ days: [DailySizes]) -> Int? {
        guard days.count >= 3, let first = days.first, let last = days.last else { return nil }
        let span = last.date.timeIntervalSince(first.date) / 86_400
        guard span >= 2 else { return nil }
        let perDay = Double(first.freeBytes - last.freeBytes) / span
        guard perDay > 1_048_576 else { return nil }
        return Int(Double(last.freeBytes) / perDay)
    }

    /// Averages of each hour of the day, to suggest a quiet time for restarts.
    public static func quietestHour(_ samples: [MetricSample], calendar: Calendar = .current) -> Int? {
        guard samples.count >= 288 else { return nil }
        var totals = [Double](repeating: 0, count: 24), counts = [Double](repeating: 0, count: 24)
        for s in samples {
            let hour = calendar.component(.hour, from: s.date)
            totals[hour] += Double(s.players)
            counts[hour] += 1
        }
        let averages = (0..<24).map { counts[$0] > 0 ? totals[$0] / counts[$0] : .infinity }
        return averages.indices.min { averages[$0] < averages[$1] }
    }

    public static func uptime(_ events: [ServerEvent], since: Date, now: Date = Date()) -> (crashes: Int, restarts: Int) {
        let recent = events.filter { $0.date >= since }
        return (recent.filter { $0.kind == .crash }.count, recent.filter { $0.kind == .start }.count)
    }
}

// MARK: - Tick times

public enum TickTimes {
    private static let paper = regex(#"([\d.]+)/([\d.]+)/([\d.]+),\s*([\d.]+)/([\d.]+)/([\d.]+),\s*([\d.]+)/([\d.]+)/([\d.]+)"#)
    private static let vanilla = regex(#"Average time per tick:\s*([\d.]+)\s*ms"#)

    /// Paper's `/mspt` gives avg/min/max over 5s, 10s and 1m. Vanilla's `/tick query` gives an average.
    public static func parse(_ line: String) -> Double? {
        if let m = paper.firstMatch(in: line), m.numberOfRanges == 10 {
            return Double((line as NSString).substring(with: m.range(at: 7)))
        }
        return vanilla.firstGroup(in: line).flatMap(Double.init)
    }

    public static func isHeader(_ line: String) -> Bool { line.contains("Server tick times") }

    /// The rest of vanilla's `/tick query` answer, which would otherwise fill the console once a minute.
    public static func isVanillaExtra(_ line: String) -> Bool {
        line.hasPrefix("The game is running normally") || line.hasPrefix("Target tick rate:") || line.hasPrefix("Percentiles: P50")
    }
}

public enum GCLog {
    private static let pause = regex(#"Pause [^\n]*?([\d.]+)ms\s*$"#)

    /// `[…] GC(3) Pause Young (Normal) (G1 Evacuation Pause) 100M->50M(200M) 12.345ms`
    public static func longestPause(in text: String) -> Double? {
        var longest: Double?
        for line in text.split(whereSeparator: \.isNewline) {
            guard let value = pause.firstGroup(in: String(line)).flatMap(Double.init) else { continue }
            longest = max(longest ?? 0, value)
        }
        return longest
    }

    public static func file(_ paths: ServerPaths) -> URL { paths.meta.appendingPathComponent("gc.log") }
}

// MARK: - Failed joins

public struct FailedJoin: Codable, Identifiable, Equatable, Sendable {
    public var id: String { "\(date.timeIntervalSince1970)-\(name)" }
    public var date: Date
    public var name: String
    public var reason: String
    /// In plain words, with what to do about it.
    public var meaning: String
}

public enum JoinFailures {
    private static let line = regex(#"^(?:Disconnecting )?(?:com\.mojang\.authlib\.GameProfile@\S+ |GameProfile\{[^}]*name=)?(\.?[A-Za-z0-9_]{1,16})?\}?[^:]*?(?:lost connection|\(/[^)]*\)): (.+)$"#)

    private static let reasons: [(needle: String, meaning: String)] = [
        ("whitelisted", "They aren't on the allowlist. Add them on the Configs page if they should get in."),
        ("white-listed", "They aren't on the allowlist. Add them on the Configs page if they should get in."),
        ("banned", "They're banned. Check the ban list if that's a mistake."),
        ("outdated client", "Their game is older than the server. They need to update, or the server needs ViaBackwards."),
        ("outdated server", "Their game is newer than the server. Update the server, or add ViaVersion."),
        ("incompatible client", "Their game version doesn't match the server."),
        ("failed to verify", "Minecraft couldn't confirm their account. They should restart their game and launcher."),
        ("server is full", "The server was full. Raise max-players if this happens often."),
        ("timed out", "Their connection dropped while joining. Usually their network, or a port forwarding problem."),
    ]

    /// Recognises a refused join from a log message. Ordinary disconnects of players who got in aren't refusals.
    public static func parse(_ message: String, date: Date = Date(), online: Set<String> = []) -> FailedJoin? {
        guard let m = line.firstMatch(in: message), m.numberOfRanges == 3, let reasonRange = Range(m.range(at: 2), in: message) else { return nil }
        let reason = String(message[reasonRange]).trimmingCharacters(in: .whitespaces)
        let lower = reason.lowercased()
        guard let known = reasons.first(where: { lower.contains($0.needle) }) else { return nil }
        let name = Range(m.range(at: 1), in: message).map { String(message[$0]) } ?? "Someone"
        if online.contains(name) { return nil }
        return FailedJoin(date: date, name: name, reason: reason, meaning: known.meaning)
    }
}

// MARK: - Player statistics

public struct PlayerStats: Identifiable, Equatable, Sendable {
    public var id: String { uuid }
    public let uuid: String
    public let name: String
    public var values: [String: Int] = [:]
    public func value(_ stat: PlayerStat) -> Int { values[stat.id] ?? 0 }
}

/// The ones worth a leaderboard. The file holds hundreds.
public struct PlayerStat: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    let keys: [String]
    /// Sums a whole category, such as every block mined.
    let category: String?
    public let format: Format

    public enum Format: Sendable { case count, hours, kilometres }

    public func display(_ value: Int) -> String {
        switch format {
        case .count: return value.formatted()
        case .hours: return String(format: "%.1f h", Double(value) / 72_000)
        case .kilometres: return String(format: "%.1f km", Double(value) / 100_000)
        }
    }

    public static let all: [PlayerStat] = [
        .init(id: "play", title: "Time played", keys: ["minecraft:play_time", "minecraft:play_one_minute"], category: nil, format: .hours),
        .init(id: "deaths", title: "Deaths", keys: ["minecraft:deaths"], category: nil, format: .count),
        .init(id: "mobs", title: "Mobs killed", keys: ["minecraft:mob_kills"], category: nil, format: .count),
        .init(id: "pvp", title: "Players killed", keys: ["minecraft:player_kills"], category: nil, format: .count),
        .init(id: "mined", title: "Blocks mined", keys: [], category: "minecraft:mined", format: .count),
        .init(id: "crafted", title: "Items crafted", keys: [], category: "minecraft:crafted", format: .count),
        .init(id: "walked", title: "Distance walked", keys: ["minecraft:walk_one_cm", "minecraft:sprint_one_cm"], category: nil, format: .kilometres),
        .init(id: "jumps", title: "Jumps", keys: ["minecraft:jump"], category: nil, format: .count),
        .init(id: "fish", title: "Fish caught", keys: ["minecraft:fish_caught"], category: nil, format: .count),
        .init(id: "sleep", title: "Nights slept", keys: ["minecraft:sleep_in_bed"], category: nil, format: .count),
    ]
}

public enum PlayerStatsReader {
    public static func read(_ paths: ServerPaths) -> [PlayerStats] {
        let p = PlayerPaths(paths)
        let names = PlayerFiles.userCache(paths)
        return FileOps.children(p.statsFolder).filter { $0.pathExtension == "json" }.compactMap { file in
            let uuid = file.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: file),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let stats = root["stats"] as? [String: [String: Int]] else { return nil }
            var out = PlayerStats(uuid: uuid, name: names[uuid.lowercased()] ?? uuid)
            let custom = stats["minecraft:custom"] ?? [:]
            for stat in PlayerStat.all {
                if let category = stat.category {
                    out.values[stat.id] = (stats[category] ?? [:]).values.reduce(0, +)
                } else {
                    out.values[stat.id] = stat.keys.reduce(0) { $0 + (custom[$1] ?? 0) }
                }
            }
            return out
        }
    }

    public static func leaderboard(_ players: [PlayerStats], stat: PlayerStat) -> [PlayerStats] {
        players.filter { $0.value(stat) > 0 }.sorted { $0.value(stat) > $1.value(stat) }
    }
}

// MARK: - Regulars

public struct PlayerActivity: Identifiable, Equatable, Sendable {
    public enum Status: String, Sendable {
        case new = "New", regular = "Regular", occasional = "Occasional", drifted = "Drifted away"
    }
    public var id: String { name }
    public let name: String
    public let firstSeen: Date
    public let lastSeen: Date
    public let sessions: Int
    public let hours: Double
    public let status: Status
}

public enum Activity {
    /// From sessions in the logs, so it only knows as far back as logs are kept.
    public static func summarize(_ sessions: [PlayerSession], now: Date = Date(), calendar: Calendar = .current) -> [PlayerActivity] {
        let grouped = Dictionary(grouping: sessions, by: \.name)
        return grouped.map { name, list in
            let first = list.map(\.start).min() ?? now
            let last = list.map { $0.end ?? $0.start }.max() ?? now
            let hours = list.reduce(0.0) { $0 + (($1.end ?? $1.start).timeIntervalSince($1.start)) } / 3600
            let recentDays = Set(list.filter { now.timeIntervalSince($0.start) < 30 * 86_400 }.map { calendar.startOfDay(for: $0.start) }).count
            let everDays = Set(list.map { calendar.startOfDay(for: $0.start) }).count
            let status: PlayerActivity.Status
            if now.timeIntervalSince(first) < 7 * 86_400 {
                status = .new
            } else if recentDays >= 3 {
                status = .regular
            } else if now.timeIntervalSince(last) > 30 * 86_400, everDays >= 3 {
                status = .drifted
            } else {
                status = .occasional
            }
            return PlayerActivity(name: name, firstSeen: first, lastSeen: last, sessions: list.count, hours: hours, status: status)
        }.sorted { $0.lastSeen > $1.lastSeen }
    }
}

// MARK: - The backup drill

public struct DrillResult: Codable, Equatable, Sendable {
    public var date: Date
    public var backupDate: Date
    public var fileName: String
    public var passed: Bool
    public var detail: String
}

/// Five minutes of readings, before they're boiled down.
struct MetricBucket {
    var started = Date()
    var tps: [Double] = []
    var mspt: [Double] = []
    var memory: [Double] = []
    var cpu: [Double] = []
    var players = 0
}
