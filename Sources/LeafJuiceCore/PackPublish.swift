import Foundation
import Security

// Publishing packs (D189, owner, 2026-11-14): each finished build goes into the folder Caddy serves on the join host,
// under a long random path that changes with every build, named by its SHA-1 so Packmule reads the hash from the
// name. Only the current build, and one on its way out, are ever in that folder. LeafJuice's own record of what it
// put there stays in the server's .leafjuice folder, never in the served folder, because it names who was online.

public struct PublishedBuild: Codable, Equatable, Sendable {
    public var token: String
    public var sha1: String
    public var url: String
    public var publishedAt: Date
    /// Who was online when this build replaced the last one. The old build goes once they've all left.
    public var onlineAtSwitch: [String]
}

public struct PackPublishSettings: Codable, Equatable, Sendable {
    /// The folder Caddy serves, such as /usr/local/var/www/join. LeafJuice only adds and removes its own folders in it.
    public var folder = ""
    /// What that folder is on the web, such as https://join.example.test/packs/.
    public var baseURL = ""
    /// Per recipe: the build players get now, then any still waiting to be removed, newest first.
    public var builds: [String: [PublishedBuild]] = [:]
    public init() {}
}

public enum PackPublish {
    public static func file(_ meta: URL) -> URL { meta.appendingPathComponent("pack-publish.json") }
    /// An old build stays at least this long after the switch, so a download already under way can finish.
    public static let graceMinutes = 10

    /// Why these settings can't be used, or nil.
    public static func problem(_ s: PackPublishSettings) -> String? {
        let folder = (s.folder as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard !folder.isEmpty, FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
            return "Choose the folder your web server serves."
        }
        guard FileManager.default.isWritableFile(atPath: folder) else { return "LeafJuice can't write to that folder." }
        guard let url = URL(string: s.baseURL), url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              url.query == nil, url.fragment == nil, url.user == nil, s.baseURL.hasSuffix("/") else {
            return "The web address must be https and end with a slash, such as https://join.example.test/packs/."
        }
        return nil
    }

    static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw LeafError("Couldn't make a random path.") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Copies one build into the served folder under a new random path and checks the copy. Returns where it is.
    /// Fails closed: nothing is recorded unless the copy is whole and has the right hash.
    public static func publish(build: URL, sha1: String, settings s: PackPublishSettings, online: [String], now: Date = Date()) throws -> PublishedBuild {
        if let why = problem(s) { throw LeafError(why) }
        guard PackHosting.isSHA1(sha1), FileOps.exists(build) else { throw LeafError("That build isn't in the library any more.") }
        let root = URL(fileURLWithPath: (s.folder as NSString).expandingTildeInPath, isDirectory: true)
        let room = (DiskGuard.standIn ?? DiskGuard.space)(root)
        if let why = DiskGuard.refusal(free: room.free, capacity: room.capacity, needed: FileOps.size(build)) { throw LeafError("Not published. \(why)") }
        let token = try randomToken()
        let dir = root.appendingPathComponent(token, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let target = dir.appendingPathComponent("\(sha1).zip"), part = dir.appendingPathComponent(".\(sha1).part")
        do {
            try FileManager.default.copyItem(at: build, to: part)
            guard try Hashing.digests(of: part).sha1.lowercased() == sha1.lowercased() else { throw LeafError("The copy didn't match the build, so it was removed.") }
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: part.path)
            try FileManager.default.moveItem(at: part, to: target)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return PublishedBuild(token: token, sha1: sha1, url: s.baseURL + token + "/" + sha1 + ".zip", publishedAt: now, onlineAtSwitch: online.sorted())
    }

    /// Old builds that can go: older than the current one, past the grace time, with everyone who was online at the
    /// switch gone. The current build never goes.
    public static func removable(_ builds: [PublishedBuild], online: Set<String>, now: Date = Date()) -> [PublishedBuild] {
        guard let current = builds.first else { return [] }
        let waited = now.timeIntervalSince(current.publishedAt) >= Double(graceMinutes) * 60
        let stillOn = !Set(current.onlineAtSwitch).isDisjoint(with: online)
        guard waited, !stillOn else { return [] }
        return Array(builds.dropFirst())
    }

    /// Removes one old build's folder, only if it's exactly what LeafJuice put there: a 64-character random folder
    /// holding that build's zip and nothing else. Anything else in the served folder is never touched.
    public static func remove(_ build: PublishedBuild, settings s: PackPublishSettings) throws {
        guard build.token.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, PackHosting.isSHA1(build.sha1) else {
            throw LeafError("That record doesn't look like one of LeafJuice's builds, so nothing was removed.")
        }
        let root = URL(fileURLWithPath: (s.folder as NSString).expandingTildeInPath, isDirectory: true)
        let dir = root.appendingPathComponent(build.token, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let inside = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard inside == ["\(build.sha1).zip"] else {
            throw LeafError("\(build.token.prefix(8))… holds something LeafJuice didn't put there, so it was left alone.")
        }
        try FileManager.default.removeItem(at: dir)
    }
}

extension ServerController {
    public var packPublishSettings: PackPublishSettings {
        get { JSONStore.load(PackPublish.file(paths.meta), defaults: PackPublishSettings()) }
        set { try? JSONStore.save(newValue, to: PackPublish.file(paths.meta)) }
    }

    /// Publishes a recipe's build and makes it the current one. The last one waits until players have moved on.
    @discardableResult
    public func publishPack(recipe name: String, sha1: String) throws -> PublishedBuild {
        var s = packPublishSettings
        let key = ResourcePacks.slug(name)
        if s.builds[key]?.first?.sha1 == sha1 { throw LeafError("That build is already the one players get.") }
        let made = try PackPublish.publish(build: ResourcePacks.buildFile(sha1: sha1, recipe: name), sha1: sha1, settings: s, online: Array(players))
        s.builds[key] = [made] + (s.builds[key] ?? [])
        packPublishSettings = s
        appendWrapper("Published \(name) build \(sha1.prefix(8)) at a new address.", level: .info)
        recordEvent(.config, "Pack published", detail: "\(name), \(sha1.prefix(8))")
        return made
    }

    /// Run from the tick: removes old builds once nobody who could still need them is online.
    func tidyPublishedPacks(now: Date = Date()) {
        var s = packPublishSettings
        guard !s.builds.isEmpty else { return }
        var changed = false
        for (key, builds) in s.builds {
            for old in PackPublish.removable(builds, online: players, now: now) {
                do {
                    try PackPublish.remove(old, settings: s)
                    s.builds[key]?.removeAll { $0.token == old.token }
                    changed = true
                } catch {
                    appendWrapper("An old published pack wasn't removed: \(error.localizedDescription)", level: .warn)
                }
            }
        }
        if changed { packPublishSettings = s }
    }
}
