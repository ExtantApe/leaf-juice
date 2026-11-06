import Darwin
import Foundation

/// Says nothing specific on purpose: these messages reach the AI client.
public struct AdvisorError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum AdvisorPaths {
    /// Beside the app's own data, and never inside a server folder, so it can't travel with a backup or test copy.
    public static var home: URL {
        if let override = ProcessInfo.processInfo.environment["LEAFJUICE_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent("advisor", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Leaf Juice/advisor", isDirectory: true)
    }
}

/// Files only this user can touch: no symlinks, no one else's files, and no loosened permissions.
enum PrivateFiles {
    static func ensureDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0 && errno == ENOENT {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = mkdir(url.path, 0o700)
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw AdvisorError("The advisor's private folder isn't safe to use. Check its owner and permissions.")
        }
    }

    static let maxFileBytes = 32 << 20

    /// Nil if the file doesn't exist. Throws if it exists but isn't safe to trust.
    static func read(_ url: URL) throws -> Data? {
        // Non-blocking, so a FIFO put here can't hang the program.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw AdvisorError("A private advisor file couldn't be opened safely.")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_nlink == 1, info.st_size <= maxFileBytes else {
            throw AdvisorError("A private advisor file isn't safe to use. Check its owner and permissions.")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
    }

    /// Written whole beside its target and renamed over it, so a crash leaves the old file or the new one.
    static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AdvisorError("A private advisor file couldn't be written.") }
        var finished = false
        defer {
            close(fd)
            if !finished { unlink(temporary.path) }
        }
        let wrote = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard wrote == data.count, fsync(fd) == 0, rename(temporary.path, url.path) == 0 else {
            throw AdvisorError("A private advisor file couldn't be written.")
        }
        finished = true
    }
}

/// The map between tokens and the real values they stand for. Only identifiers go in here, never secrets or free text.
public final class PrivacyKey {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case player = "Player", ip = "IP", server = "Server"
    }

    struct Entry: Codable, Equatable {
        var token: String
        var kind: Kind
        /// What a person is shown.
        var display: String
        /// Lowercase forms that resolve to this token. A player's are `name:…` and `uuid:…`.
        var lookups: [String]
    }

    private struct Stored: Codable {
        var version = 2
        var entries: [Entry] = []
    }

    public static let tokenPattern = #"\b(?:Player|IP|Server)-[0-9a-f]{8}\b"#

    private let directory: URL
    private var file: URL { directory.appendingPathComponent("key.json") }
    private var lockFile: URL { directory.appendingPathComponent("key.lock") }
    private var entries: [Entry] = []
    /// Keyed by kind as well as value, so a player can't merge into an address.
    private var byLookup: [String: String] = [:]
    private var byToken: [String: Entry] = [:]
    private var loadedStamp: String?

    /// Refuses to start from a key it can't read, rather than starting afresh and overwriting it.
    public init(directory: URL = AdvisorPaths.home) throws {
        self.directory = directory
        try PrivateFiles.ensureDirectory(directory)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var folder = directory
        try? folder.setResourceValues(excluded)
        try reload()
    }

    /// Before every answer, so a damaged key stops things straight away, even if this answer holds no tokens.
    public func verify() throws { try reload() }

    /// Parsing is skipped if the file hasn't changed, but it's always checked.
    private func reload() throws {
        var info = stat()
        let exists = lstat(file.path, &info) == 0
        let stamp = exists ? "\(info.st_ino)|\(info.st_size)|\(info.st_mode)|\(info.st_nlink)|\(info.st_uid)|\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)|\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)" : "none"
        if stamp == loadedStamp { return }
        guard let data = try PrivateFiles.read(file) else { index([]); loadedStamp = "none"; return }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.version == 2,
              stored.entries.allSatisfy({ $0.token.range(of: "^" + Self.tokenPattern + "$", options: .regularExpression) != nil }) else {
            throw AdvisorError("The advisor's key file couldn't be read, so nothing was shared.")
        }
        index(stored.entries)
        loadedStamp = stamp
    }

    private func index(_ list: [Entry]) {
        entries = list
        byLookup.removeAll()
        byToken.removeAll()
        for entry in list {
            byToken[entry.token] = entry
            for lookup in entry.lookups { byLookup["\(entry.kind.rawValue)|\(lookup)"] = entry.token }
        }
    }

    /// Other copies of this program may run at once, so changes are made under a lock against the latest file.
    private func locked<T>(_ body: () throws -> T) throws -> T {
        let fd = open(lockFile.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        // Gives up rather than waiting forever on a copy of this program that has stalled.
        var held = false
        if fd >= 0 {
            for _ in 0..<500 {
                if flock(fd, LOCK_EX | LOCK_NB) == 0 { held = true; break }
                usleep(10_000)
            }
        }
        guard held else {
            if fd >= 0 { close(fd) }
            throw AdvisorError("The advisor's key file is busy, so nothing was shared.")
        }
        defer { flock(fd, LOCK_UN); close(fd) }
        try reload()
        return try body()
    }

    private func newToken(_ kind: Kind) -> String {
        var token: String
        repeat {
            token = "\(kind.rawValue)-" + String(format: "%08x", UInt32.random(in: .min ... .max))
        } while byToken[token] != nil
        return token
    }

    /// Saved before it's returned: if saving fails this throws, so a token is never sent that can't be translated back.
    private func token(_ kind: Kind, lookup: String, display: String) throws -> String {
        try locked {
            if let found = byLookup["\(kind.rawValue)|\(lookup)"] { return found }
            let token = newToken(kind)
            try save(entries + [Entry(token: token, kind: kind, display: display, lookups: [lookup])])
            return token
        }
    }

    public func ip(_ address: String) throws -> String {
        try token(.ip, lookup: address.lowercased(), display: address)
    }

    public func server(path: String, display: String) throws -> String {
        try token(.server, lookup: path, display: display)
    }

    /// A UUID is the person, and a name is just what they're called today. So a UUID decides the token. A name that
    /// has passed to someone else moves to them, and never makes two people share one token.
    public func player(name: String, uuid: String?) throws -> String {
        let nameKey = "name:\(name.lowercased())"
        let uuidKey = uuid.map { "uuid:\($0.lowercased())" }
        return try locked {
            var list = entries
            func at(_ key: String) -> Int? {
                byLookup["Player|\(key)"].flatMap { token in list.firstIndex { $0.token == token } }
            }
            func dropName(except keep: Int) {
                for i in list.indices where i != keep { list[i].lookups.removeAll { $0 == nameKey } }
            }
            if let uuidKey, let index = at(uuidKey) {
                if list[index].lookups.contains(nameKey), list[index].display == name { return list[index].token }
                dropName(except: index)
                if !list[index].lookups.contains(nameKey) { list[index].lookups.append(nameKey) }
                list[index].display = name
                try save(list)
                return list[index].token
            }
            if let index = at(nameKey) {
                guard let uuidKey else { return list[index].token }
                if !list[index].lookups.contains(where: { $0.hasPrefix("uuid:") }) {
                    list[index].lookups.append(uuidKey)
                    try save(list)
                    return list[index].token
                }
                list[index].lookups.removeAll { $0 == nameKey }
            }
            let token = newToken(.player)
            list.append(Entry(token: token, kind: .player, display: name, lookups: [nameKey] + (uuidKey.map { [$0] } ?? [])))
            try save(list)
            return token
        }
    }

    private func save(_ list: [Entry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Stored(entries: list)) else {
            throw AdvisorError("The advisor's key file couldn't be written, so nothing was shared.")
        }
        try PrivateFiles.write(data, to: file)
        index(list)
        loadedStamp = nil
    }

    /// Every name already mapped, old ones included.
    func knownPlayerNames() throws -> [String] {
        try reload()
        return entries.filter { $0.kind == .player }.flatMap { $0.lookups }.filter { $0.hasPrefix("name:") }.map { String($0.dropFirst(5)) }
    }

    /// Without creating or changing anything, so text mentioning an old name can't rename someone.
    func knownPlayerToken(lookup: String) throws -> String? {
        try reload()
        return byLookup["Player|\(lookup)"]
    }

    func knownIP(_ address: String) throws -> String? {
        try reload()
        return byLookup["IP|\(address.lowercased())"]
    }

    /// Real values for tokens. Only for showing a person. No MCP tool may ever call this.
    public func reveal(_ text: String) throws -> String {
        try reload()
        return Scrub.replace(text, Regexes.token) { byToken[$0]?.display ?? $0 }
    }
}
