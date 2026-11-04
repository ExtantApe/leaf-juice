import Foundation

/// A Minecraft version: `1.21.11`, `26.3`, `26.3-rc-3`, `1.21.11-pre5`. Also fits api-versions (`1.21`).
public struct GameVersion: Comparable, Hashable, Codable, CustomStringConvertible, Sendable {
    public let raw: String
    public let parts: [Int]
    public let prerelease: String?

    private static let pattern = regex(#"^(\d+(?:\.\d+)*)(?:\.x)?(?:[-_ +]?(.+))?$"#)

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let match = Self.pattern.firstMatch(in: trimmed),
              let numbers = Range(match.range(at: 1), in: trimmed) else { return nil }
        raw = trimmed
        parts = trimmed[numbers].split(separator: ".").compactMap { Int($0) }
        prerelease = Range(match.range(at: 2), in: trimmed).map { String(trimmed[$0]) }
    }

    public var isStableRelease: Bool { prerelease == nil }
    public var description: String { raw }

    /// `1.21.4` → `1.21`; `26.1.2` → `26.1`. Worlds and plugins move together within a line.
    public var line: String { parts.prefix(2).map(String.init).joined(separator: ".") }

    public static func < (a: GameVersion, b: GameVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil), (nil, _): return false
        case (_, nil): return true
        case let (x?, y?): return x.localizedStandardCompare(y) == .orderedAscending
        }
    }

    public static func == (a: GameVersion, b: GameVersion) -> Bool { !(a < b) && !(b < a) }
    public func hash(into hasher: inout Hasher) {
        var trimmed = parts
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed); hasher.combine(prerelease)
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = GameVersion(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad version \(text)"))
        }
        self = parsed
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(raw)
    }

    private static let tagged = regex(
        #"(?:^|[^a-z0-9])(?:mc|minecraft|paper|spigot|bukkit|purpur|for)[-_ ]?v?((?:1\.\d{1,2}|2\d\.\d{1,2})(?:\.\d{1,2})?)(?![0-9])"#,
        .caseInsensitive)

    /// Minecraft versions explicitly tagged in a release name or file name (`Foo-mc1.21.4.jar`).
    /// A bare `1.21.4` is deliberately ignored: it's as likely to be the plugin's own version.
    public static func mentioned(in text: String) -> [GameVersion] {
        let range = NSRange(text.startIndex..., in: text)
        return tagged.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).flatMap { GameVersion(String(text[$0])) }
        }
    }

    /// The plugin's stated Minecraft version matches this server, exactly or at line level (`1.21`).
    public func isCovered(by tags: [GameVersion]) -> Bool {
        tags.contains { $0 == self || ($0.parts.count == 2 && $0.line == line) }
    }
}

public enum JavaRequirement {
    /// Fallback for sources that don't publish it. Paper's Fill API gives the real number.
    public static func estimated(for mc: GameVersion) -> Int {
        guard let major = mc.parts.first else { return 21 }
        if major >= 26 { return 25 }
        if mc >= GameVersion("1.20.5")! { return 21 }
        if mc >= GameVersion("1.18")! { return 17 }
        if mc >= GameVersion("1.17")! { return 16 }
        return 8
    }
}

/// Plugin versions are free-form (`v5.5.71-bukkit`, `2.1-SNAPSHOT-b44`). Compare the first number run.
public struct LooseVersion: Comparable, Sendable {
    public let parts: [Int]
    private static let pattern = regex(#"\d+(?:\.\d+)*"#)

    public init?(_ text: String) {
        guard let run = Self.pattern.firstGroup(in: text, 0) else { return nil }
        parts = run.split(separator: ".").compactMap { Int($0) }
        if parts.isEmpty { return nil }
    }

    public static func < (a: LooseVersion, b: LooseVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }
    public static func == (a: LooseVersion, b: LooseVersion) -> Bool { !(a < b) && !(b < a) }
}
