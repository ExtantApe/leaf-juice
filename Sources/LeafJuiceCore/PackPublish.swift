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
    /// Whether Packmule is known to use this link: it said so, or the owner marked it done by hand. Until it is, the
    /// build before stays, because players may still be sent there.
    public var handedOff: Bool?
    /// What happened when LeafJuice last told Packmule, in words.
    public var handOffNote: String?
}

public struct PackPublishSettings: Codable, Equatable, Sendable {
    /// The folder Caddy serves, such as /usr/local/var/www/join. LeafJuice only adds and removes its own folders in it.
    public var folder = ""
    /// What that folder is on the web, such as https://join.example.test/packs/.
    public var baseURL = ""
    /// Per recipe: the build players get now, then any still waiting to be removed, newest first.
    public var builds: [String: [PublishedBuild]] = [:]
    /// Per recipe: the name of the pack in Packmule's config.yml that this recipe feeds, such as "main".
    public var packmuleNames: [String: String]?
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
        // Never while Packmule might still be sending players to an older link (2026-11-14).
        guard current.handedOff == true else { return [] }
        let waited = now.timeIntervalSince(current.publishedAt) >= Double(graceMinutes) * 60
        let stillOn = !Set(current.onlineAtSwitch).isDisjoint(with: online)
        guard waited, !stillOn else { return [] }
        return Array(builds.dropFirst())
    }

    /// Only an https link to a published build, in characters that can't do anything else in a console line.
    public static func isSendable(_ url: String) -> Bool {
        url.count <= 400 && url.hasPrefix("https://")
            && url.range(of: #"^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/[A-Za-z0-9._~%/-]*[0-9a-f]{40}\.zip$"#, options: .regularExpression) != nil
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

    public enum HandOff: Equatable, Sendable {
        case done(String)
        case notTold(String)
    }

    /// Tells Packmule the current build's link with `packmule pack set`, when Packmule offers it. Only a confirmed
    /// answer for the same SHA-1 counts; anything else leaves the build waiting, and says why.
    @discardableResult
    public func tellPackmule(recipe name: String) async -> HandOff {
        var s = packPublishSettings
        let key = ResourcePacks.slug(name)
        guard let current = s.builds[key]?.first else { return .notTold("Nothing is published for \(name) yet.") }
        func finish(_ result: HandOff) -> HandOff {
            var latest = packPublishSettings
            if var list = latest.builds[key], let i = list.firstIndex(where: { $0.token == current.token }) {
                switch result {
                case let .done(note): list[i].handedOff = true; list[i].handOffNote = note
                case let .notTold(note): list[i].handOffNote = note
                }
                latest.builds[key] = list
                packPublishSettings = latest
            }
            return result
        }
        guard let pack = s.packmuleNames?[key], !pack.isEmpty else { return finish(.notTold("No Packmule pack name is set for \(name), so the link has to be copied into Packmule by hand.")) }
        guard PackPublish.isSendable(current.url) else { return finish(.notTold("That link can't be sent to Packmule.")) }
        guard Modules.shared.isOn(.pluginCommands) else { return finish(.notTold("Plugin commands are off, so LeafJuice can't tell Packmule. Turn them on, or copy the link by hand.")) }
        guard state == .running, process != nil else { return finish(.notTold("The server isn't running in LeafJuice, so Packmule couldn't be told. It's told when you press Send to Packmule with the server running.")) }
        switch await commands.describe("packmule") {
        case .described(let d) where d.commands.contains(where: { $0.name == "pack set" }): break
        case .described(let d): return finish(.notTold("This Packmule (\(d.version)) can't be told a new link. Packmule 0.2.1 or later can."))
        case .newerFormat(let n): return finish(.notTold("Packmule speaks command format \(n), newer than this LeafJuice knows."))
        case .unreadable: return finish(.notTold("Packmule's list of commands couldn't be read."))
        case .outcome(let o): return finish(.notTold("Packmule didn't answer: \(Self.plain(o, doing: "Asking Packmule what it offers"))"))
        }
        // Packmule downloads and checks the file before it answers, so this waits longer than usual.
        let reply = await commands.run("packmule", ["pack", "set"], [.word(pack), .word(current.url)], timeout: .seconds(180))
        switch reply.outcome {
        case .done(let answer):
            struct Wire: Decodable { let pack: String?; let sha1: String?; let check: String? }
            guard let w = try? answer.decode(Wire.self), w.sha1?.lowercased() == current.sha1.lowercased(), w.check == "passed" else {
                return finish(.notTold("Packmule answered, but not with this build's SHA-1 and a passed check, so the old build is kept."))
            }
            appendWrapper("Packmule now sends \(name) build \(current.sha1.prefix(8)).", level: .info)
            return finish(.done("Packmule checked the link and uses it now."))
        case .failed(let e) where e.code == "check-failed":
            return finish(.notTold("Packmule couldn't download the new link, or its SHA-1 didn't match, so it kept the old one. Check the web server serves the folder. \(e.message)"))
        case let other:
            return finish(.notTold(Self.plain(other, doing: "Telling Packmule the new link")))
        }
    }

    /// For a Packmule updated by hand: marks the current build as the one players are sent.
    public func markHandedOff(recipe name: String) {
        var s = packPublishSettings
        let key = ResourcePacks.slug(name)
        guard var list = s.builds[key], !list.isEmpty else { return }
        list[0].handedOff = true
        list[0].handOffNote = "Marked as updated in Packmule by hand."
        s.builds[key] = list
        packPublishSettings = s
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
