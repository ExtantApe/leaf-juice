import Darwin
import Foundation

// Only players joining get the pack. Owner, 2026-11-10: "I'm fine if an authorized player just uses the standard pack
// URL. It's more than I don't want a random person to hit pack and be able to download it". Recorded in docs/PLAN.md.
//
// The game sends X-Minecraft-Username, X-Minecraft-UUID and X-Minecraft-Version when it downloads a server's pack. A
// request is served only if those name a player on this server's whitelist whom the server's own log shows connecting
// in the last few minutes, or still online. Headers can be faked, so this stops casual downloads and shared links, not
// someone who knows a whitelisted player's name and UUID and asks while that player is joining.

public enum PackGate {
    /// How long after the server logs someone connecting their game may fetch the pack.
    public static let window: TimeInterval = 5 * 60
    /// The most of `logs/latest.log` read for each request, from its end.
    static let logTail = 512 * 1024
    static let checkHeader = "x-leaf-juice-check"

    public struct Player: Equatable, Sendable {
        public let name: String
        /// Lowercase and hyphenated.
        public let uuid: String
        public init(name: String, uuid: String) { self.name = name; self.uuid = uuid }
    }

    /// The player a request says it's for, if every header is there in the game's own shape.
    public static func player(headers: [String: String]) -> Player? {
        guard let name = headers["x-minecraft-username"], let raw = headers["x-minecraft-uuid"], let version = headers["x-minecraft-version"],
              name.range(of: #"^[A-Za-z0-9_]{1,16}$"#, options: .regularExpression) != nil,
              !version.isEmpty, version.count <= 64, version.allSatisfy({ $0.isASCII && !$0.isNewline }),
              let uuid = dashed(raw) else { return nil }
        return Player(name: name, uuid: uuid)
    }

    /// The game sends the UUID without hyphens; either form is taken.
    static func dashed(_ raw: String) -> String? {
        let hex = raw.lowercased().replacingOccurrences(of: "-", with: "")
        guard hex.count == 32, hex.allSatisfy({ $0.isHexDigit }),
              raw.count == 32 || raw.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#, options: .regularExpression) != nil else { return nil }
        let c = Array(hex)
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(c[$0]) }.joined(separator: "-")
    }

    /// Who the server's log shows connecting: by UUID, each with its name and time, and who's online now.
    public struct Joining: Equatable, Sendable {
        public var connected: [String: (name: String, at: Date)] = [:]
        public var online: Set<String> = []
        public static func == (a: Joining, b: Joining) -> Bool {
            a.online == b.online && a.connected.keys.sorted() == b.connected.keys.sorted()
                && a.connected.allSatisfy { b.connected[$0.key]?.name == $0.value.name && b.connected[$0.key]?.at == $0.value.at }
        }
    }

    /// Only the server's own lines count: the login thread for UUIDs, the server thread for joins and leaves. Chat is
    /// written as `<Name> text`, so it can't take either shape.
    private static let uuidLine = try! NSRegularExpression(pattern: #"^\[(\d\d):(\d\d):(\d\d)\] \[User Authenticator #\d+/INFO\]: UUID of player ([A-Za-z0-9_]{1,16}) is ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$"#)
    private static let joinLine = try! NSRegularExpression(pattern: #"^\[\d\d:\d\d:\d\d\] \[Server thread/INFO\]: ([A-Za-z0-9_]{1,16}) (joined|left) the game$"#)

    /// `day` is the log's day: a time later than `now` (plus a minute's slack) is taken as the day before.
    public static func joining(log: String, now: Date, calendar: Calendar = .current) -> Joining {
        var result = Joining()
        let midnight = calendar.startOfDay(for: now)
        for line in log.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = String(line.hasSuffix("\r") ? line.dropLast() : line)
            let range = NSRange(text.startIndex..., in: text)
            if let m = uuidLine.firstMatch(in: text, range: range) {
                func part(_ i: Int) -> String { String(text[Range(m.range(at: i), in: text)!]) }
                var at = midnight.addingTimeInterval(TimeInterval(Int(part(1))! * 3600 + Int(part(2))! * 60 + Int(part(3))!))
                if at > now.addingTimeInterval(60) { at = at.addingTimeInterval(-86_400) }
                result.connected[part(5)] = (part(4), at)
            } else if let m = joinLine.firstMatch(in: text, range: range) {
                let name = String(text[Range(m.range(at: 1), in: text)!]).lowercased()
                if text[Range(m.range(at: 2), in: text)!] == "joined" { result.online.insert(name) } else { result.online.remove(name) }
            }
        }
        return result
    }

    /// The decision. Anything missing, unreadable or odd is a no.
    public static func admits(_ player: Player?, whitelist: Data?, log: String?, now: Date = Date()) -> Bool {
        guard let player, let whitelist, let log,
              let entries = try? JSONDecoder().decode([WhitelistRow].self, from: whitelist),
              entries.contains(where: { $0.uuid.lowercased() == player.uuid && $0.name.lowercased() == player.name.lowercased() }) else { return false }
        let seen = joining(log: log, now: now)
        guard let connected = seen.connected[player.uuid], connected.name.lowercased() == player.name.lowercased() else { return false }
        let recent = now.timeIntervalSince(connected.at) <= window && connected.at <= now.addingTimeInterval(60)
        return recent || seen.online.contains(player.name.lowercased())
    }

    private struct WhitelistRow: Decodable { let uuid: String; let name: String }

    /// The end of a file, read safely: no links, only a plain file this user owns. Nil if it can't be.
    static func tail(_ url: URL, bytes: Int) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid() else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let size = UInt64(max(info.st_size, 0))
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, var data = try? handle.readToEnd() ?? Data() else { return nil }
        // Starting part-way, the first line may be cut, so it's dropped.
        if start > 0, let cut = data.firstIndex(of: 0x0A) { data = data[(cut + 1)...] }
        return data
    }

    /// For one server folder: reads its whitelist and the end of its log fresh, for every request.
    public static func admits(headers: [String: String], root: URL, now: Date = Date()) -> Bool {
        // Nothing is read from disk for a request that doesn't even claim to be a player (K158 audit).
        guard let claimed = player(headers: headers) else { return false }
        return admits(claimed,
               whitelist: tail(root.appendingPathComponent("whitelist.json"), bytes: 4 << 20),
               log: tail(root.appendingPathComponent("logs/latest.log"), bytes: logTail).map { String(decoding: $0, as: UTF8.self) },
               now: now)
    }
}

/// One-time passes for the app's own check of its pack address, so it can download the pack as a player would
/// without a player's headers. Each is random, kept only in memory, works once, and lapses after two minutes.
public final class PackCheckTickets: @unchecked Sendable {
    private let lock = NSLock()
    private var open: [String: Date] = [:]
    public init() {}

    public func issue(now: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        arc4random_buf(&bytes, bytes.count)
        let ticket = bytes.map { String(format: "%02x", $0) }.joined()
        lock.lock(); defer { lock.unlock() }
        open = open.filter { $0.value > now }
        open[ticket] = now.addingTimeInterval(120)
        return ticket
    }

    /// True once for a ticket that was issued and hasn't lapsed.
    public func redeem(_ ticket: String?, now: Date = Date()) -> Bool {
        guard let ticket, ticket.count == 48 else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let until = open.removeValue(forKey: ticket) else { return false }
        return until > now
    }
}
