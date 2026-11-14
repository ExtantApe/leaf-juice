import CryptoKit
import Foundation

public enum LeafJuice {
    public static let version = "0.2.0"
    public static let repository = "ExtantApe/LeafJuice"
    public static let userAgent = "LeafJuice/\(version) (https://github.com/\(repository))"
}

public struct LeafError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Locations

/// The separately packaged trial of the Advisor, made by `scripts/build-advisor-trial.sh`. It looks at real servers
/// while leaving them alone: it starts nothing, runs no schedules or update checks and writes nothing to their folders.
/// Normal builds don't have the key, so this is always false for them.
public enum AdvisorTrial {
    public static let isOn = Bundle.main.object(forInfoDictionaryKey: "LeafJuiceAdvisorTrial") as? Bool == true
}

public enum AppPaths {
    /// `LEAFJUICE_HOME` redirects app data, for tests and demos.
    public static var home: URL {
        if let override = ProcessInfo.processInfo.environment["LEAFJUICE_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Leaf Juice", isDirectory: true)  // Keeps its first name, so existing data stays put (D185).
    }
    /// Where servers live. `~/Minecraft` unless changed in Settings. `LEAFJUICE_SERVERS` redirects it for tests.
    public static var servers: URL {
        if ProcessInfo.processInfo.environment["LEAFJUICE_SERVERS"] != nil { return defaultServers }
        if let chosen = UserDefaults.standard.string(forKey: "serversFolder") {
            return URL(fileURLWithPath: chosen, isDirectory: true)
        }
        return defaultServers
    }
    public static var defaultServers: URL {
        if let override = ProcessInfo.processInfo.environment["LEAFJUICE_SERVERS"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Minecraft", isDirectory: true)
    }
    /// True until a servers folder has been chosen, which is asked on first launch.
    public static var needsServersFolderChoice: Bool {
        !UserDefaults.standard.bool(forKey: "serversFolderChosen")
    }
    /// Records the choice, creating the folder if it isn't there yet.
    public static func chooseServers(_ folder: URL) throws {
        try FileOps.ensureDir(folder)
        UserDefaults.standard.set(folder.path, forKey: "serversFolder")
        UserDefaults.standard.set(true, forKey: "serversFolderChosen")
    }
    /// LeafJuice's own folder beside the servers. Holds backups, and is never listed as a server.
    public static let ownFolderName = "LeafJuice"
    public static var backups: URL {
        servers.appendingPathComponent(ownFolderName, isDirectory: true).appendingPathComponent("backups", isDirectory: true)
    }
    public static var registry: URL { home.appendingPathComponent("servers.json") }
    public static var runtimes: URL { home.appendingPathComponent("Runtimes", isDirectory: true) }
    public static var rules: URL { home.appendingPathComponent("rules", isDirectory: true) }
}

/// Everything LeafJuice adds to a server lives under `.leafjuice`.
public struct ServerPaths: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public var meta: URL { root.appendingPathComponent(".leafjuice", isDirectory: true) }
    public var profile: URL { meta.appendingPathComponent("server.json") }
    public var pluginRecords: URL { meta.appendingPathComponent("plugins.json") }
    public var issues: URL { meta.appendingPathComponent("issues.json") }
    public var pending: URL { meta.appendingPathComponent("pending.json") }
    public var pid: URL { meta.appendingPathComponent("server.pid") }
    public var activeUpgrade: URL { meta.appendingPathComponent("upgrade.json") }
    public var shelved: URL { meta.appendingPathComponent("shelf.json") }
    public var staged: URL { meta.appendingPathComponent("staged", isDirectory: true) }
    public var jarArchive: URL { meta.appendingPathComponent("jars", isDirectory: true) }
    public var pluginArchive: URL { meta.appendingPathComponent("plugin-archive", isDirectory: true) }
    public var configHistory: URL { meta.appendingPathComponent("config-history", isDirectory: true) }
    public var plugins: URL { root.appendingPathComponent("plugins", isDirectory: true) }
    public var properties: URL { root.appendingPathComponent("server.properties") }
    public var eula: URL { root.appendingPathComponent("eula.txt") }
}

// MARK: - Files

public enum FileOps {
    public static func ensureDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    public static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    public static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Moves a file, replacing any existing destination.
    /// A file directly inside a folder, or nil if the name could mean anything else. An empty name would be the folder
    /// itself, so nothing that deletes or moves a named file should go without this.
    public static func child(_ name: String, of folder: URL) -> URL? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else { return nil }
        return folder.appendingPathComponent(name)
    }

    /// Whether two places are on the same drive, which matters for whether one protects against losing the other.
    public static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        var x = stat(), y = stat()
        func nearest(_ url: URL) -> String {
            var at = url
            while !exists(at), at.pathComponents.count > 1 { at = at.deletingLastPathComponent() }
            return at.path
        }
        guard stat(nearest(a), &x) == 0, stat(nearest(b), &y) == 0 else { return false }
        return x.st_dev == y.st_dev
    }

    public static func move(_ from: URL, to: URL) throws {
        try ensureDir(to.deletingLastPathComponent())
        if exists(to) { try FileManager.default.removeItem(at: to) }
        try FileManager.default.moveItem(at: from, to: to)
    }

    public static func writeAtomic(_ text: String, to url: URL) throws {
        try ensureDir(url.deletingLastPathComponent())
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A path relative to `root`, even when one of them goes through a symlink (`/var` is one on macOS).
    public static func relative(_ url: URL, to root: URL) -> String {
        let base = root.resolvingSymlinksInPath().path + "/"
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    public static func children(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [])) ?? []
    }

    public static func size(_ url: URL) -> Int64 {
        // Not resourceValues: a URL caches those, so a file that grows would look unchanged.
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    public static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    public static func directorySize(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return FileOps.size(url)
        }
        var total: Int64 = 0
        for case let file as URL in walker { total += size(file) }
        return total
    }

    public static func freeSpace(at url: URL) -> Int64? {
        var probe = url
        while !exists(probe), probe.path != "/" { probe.deleteLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}

// MARK: - JSON persistence

public enum JSONStore {
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    static var compactEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        guard !AdvisorTrial.isOn else { throw LeafError("The Advisor trial doesn't save anything.") }
        try FileOps.ensureDir(url.deletingLastPathComponent())
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    /// Loads a value, filling keys missing from the file from `defaults`, so settings added in a
    /// later version never invalidate an older file. An unreadable file is set aside, not lost.
    public static func load<T: Codable>(_ url: URL, defaults: T) -> T {
        guard let data = try? Data(contentsOf: url) else { return defaults }
        do {
            let file = try JSONSerialization.jsonObject(with: data)
            let base = try JSONSerialization.jsonObject(with: encoder.encode(defaults))
            let merged = merge(base, file)
            let out = try JSONSerialization.data(withJSONObject: merged, options: [.fragmentsAllowed])
            return try decoder.decode(T.self, from: out)
        } catch {
            if !AdvisorTrial.isOn { try? FileOps.move(url, to: url.appendingPathExtension("corrupt")) }
            return defaults
        }
    }

    private static func merge(_ base: Any, _ over: Any) -> Any {
        guard let b = base as? [String: Any], let o = over as? [String: Any] else { return over }
        var out = b
        for (key, value) in o { out[key] = b[key].map { merge($0, value) } ?? value }
        return out
    }
}

// MARK: - Hashing

public enum Hashing {
    public struct Digests: Codable, Equatable, Sendable {
        public var sha1: String, sha256: String, sha512: String, md5: String
    }

    public static func digests(of url: URL) throws -> Digests {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var a = Insecure.SHA1(), b = SHA256(), c = SHA512(), d = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            a.update(data: chunk); b.update(data: chunk); c.update(data: chunk); d.update(data: chunk)
        }
        return Digests(sha1: hex(a.finalize()), sha256: hex(b.finalize()), sha512: hex(c.finalize()), md5: hex(d.finalize()))
    }

    /// For many small files, where working out all four would add up.
    public static func sha1(_ data: Data) -> String { hex(Insecure.SHA1.hash(data: data)) }

    public static func sha256(_ text: String) -> String { hex(SHA256.hash(data: Data(text.utf8))) }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Hashes a download should match. Any one being wrong fails the install.
public struct ExpectedHashes: Codable, Equatable, Sendable {
    public var sha1: String?, sha256: String?, sha512: String?, md5: String?
    public init(sha1: String? = nil, sha256: String? = nil, sha512: String? = nil, md5: String? = nil) {
        self.sha1 = sha1; self.sha256 = sha256; self.sha512 = sha512; self.md5 = md5
    }
    /// No checksum at all: the download can't be checked against anything.
    public var isEmpty: Bool { sha1 == nil && sha256 == nil && sha512 == nil && md5 == nil }
    /// A checksum worth trusting on its own (MD5 isn't).
    public var hasStrongHash: Bool { sha1 != nil || sha256 != nil || sha512 != nil }

    public func verify(_ d: Hashing.Digests) -> Bool {
        func ok(_ want: String?, _ got: String) -> Bool { want.map { $0.lowercased() == got } ?? true }
        return ok(sha1, d.sha1) && ok(sha256, d.sha256) && ok(sha512, d.sha512) && ok(md5, d.md5)
    }
    public func matches(_ d: Hashing.Digests) -> Bool {
        (sha1 != nil || sha256 != nil || sha512 != nil || md5 != nil) && verify(d)
    }
}

// MARK: - Running tools

public struct ToolResult: Sendable {
    public init(code: Int32, out: String, err: String) { self.code = code; self.out = out; self.err = err }
    public let code: Int32
    public let out: String
    public let err: String
    public var ok: Bool { code == 0 }
}

public enum Tool {
    /// Runs a command at utility priority and waits for it, without blocking the caller's actor.
    /// `maxOutput` caps what's kept from each pipe; past it the tool is stopped. `timeout` stops a tool that runs too
    /// long (off by default: backups of big worlds legitimately take a while). Both from the K158 audit.
    public static func run(_ path: String, _ args: [String], cwd: URL? = nil, lowPriority: Bool = true,
                           maxOutput: Int = 64 << 20, timeout: TimeInterval? = nil) async throws -> ToolResult {
        try await withCheckedThrowingContinuation { continuation in
            // Real threads, not the shared pool: this blocks while the tool runs, and enough blocked pool
            // threads leave none free to finish the work they're waiting on. Observed hanging with 37 plugins.
            let worker = Thread {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: path)
                    process.arguments = args
                    if let cwd { process.currentDirectoryURL = cwd }
                    if lowPriority { process.qualityOfService = .utility }
                    let outPipe = Pipe(), errPipe = Pipe()
                    process.standardOutput = outPipe
                    process.standardError = errPipe
                    process.standardInput = FileHandle.nullDevice
                    try process.run()
                    if let timeout {
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
                    }
                    // Keeps at most `maxOutput`, and stops the tool once it's past that; reads on to the end so it can exit.
                    func capped(_ handle: FileHandle) -> Data {
                        var kept = Data()
                        while true {
                            let chunk = handle.availableData
                            if chunk.isEmpty { break }
                            if kept.count < maxOutput { kept.append(chunk.prefix(maxOutput - kept.count)) }
                            else if process.isRunning { process.terminate() }
                        }
                        return kept
                    }
                    // Read both pipes at once: a full pipe would otherwise stall the tool.
                    final class Box: @unchecked Sendable { var data = Data() }
                    let errBox = Box()
                    let group = DispatchGroup()
                    group.enter()
                    Thread.detachNewThread {
                        errBox.data = capped(errPipe.fileHandleForReading)
                        group.leave()
                    }
                    let outData = capped(outPipe.fileHandleForReading)
                    group.wait()
                    process.waitUntilExit()
                    continuation.resume(returning: ToolResult(
                        code: process.terminationStatus,
                        out: String(decoding: outData, as: UTF8.self),
                        err: String(decoding: errBox.data, as: UTF8.self)))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            worker.qualityOfService = lowPriority ? .utility : .userInitiated
            worker.start()
        }
    }
}

// MARK: - Argument strings

public enum ArgumentString {
    /// Splits a shell-like string on whitespace, honouring quotes and backslashes.
    public static func split(_ text: String) -> [String] {
        var out: [String] = [], current = "", quote: Character?, inToken = false, escaped = false
        for ch in text {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" && quote != "'" { escaped = true; inToken = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch; inToken = true
            } else if ch.isWhitespace {
                if inToken { out.append(current); current = ""; inToken = false }
            } else {
                current.append(ch); inToken = true
            }
        }
        if inToken { out.append(current) }
        return out
    }

    /// Quotes an argument for display or copying into a shell.
    public static func quote(_ arg: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_=+:./,@%"))
        if !arg.isEmpty, arg.unicodeScalars.allSatisfy({ safe.contains($0) }) { return arg }
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Regex helper

public extension NSRegularExpression {
    func firstMatch(in text: String) -> NSTextCheckingResult? {
        firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
    func firstGroup(in text: String, _ group: Int = 1) -> String? {
        guard let m = firstMatch(in: text), group < m.numberOfRanges,
              let r = Range(m.range(at: group), in: text) else { return nil }
        return String(text[r])
    }
}

public func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern, options: options)
}

public enum Format {
    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
    public static func memory(mb: Int) -> String {
        mb >= 1024 && mb % 512 == 0 ? String(format: "%g GB", Double(mb) / 1024) : "\(mb) MB"
    }
}
