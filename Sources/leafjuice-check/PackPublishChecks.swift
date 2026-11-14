import Foundation
@testable import LeafJuiceCore

/// Publishing packs to a web server's folder (D189).
@MainActor func packPublishChecks() async {
    section("Publishing packs to a web server's folder")
    let served = folder("caddy-root")
    var s = PackPublishSettings()
    check(PackPublish.problem(s) != nil, "no folder: not usable")
    s.folder = served.path
    for bad in ["http://join.example.test/packs/", "https://join.example.test/packs", "https://join.example.test/packs/?a=1", "not a url"] {
        s.baseURL = bad
        check(PackPublish.problem(s) != nil, "refused web address: \(bad)")
    }
    s.baseURL = "https://join.example.test/packs/"
    check(PackPublish.problem(s) == nil, "an https folder address ending in a slash is fine")

    let builds = folder("publish-builds")
    let content = Data("made up pack \(UUID())".utf8)
    let build = builds.appendingPathComponent("b.zip"); try? content.write(to: build)
    let sha1 = (try? Hashing.digests(of: build).sha1.lowercased()) ?? ""
    write("someone else's file", served.appendingPathComponent("index.html"))
    guard let first = try? PackPublish.publish(build: build, sha1: sha1, settings: s, online: ["MadeUpKid"]) else { check(false, "a build publishes"); return }
    check(first.token.count == 64 && first.url == "https://join.example.test/packs/\(first.token)/\(sha1).zip", "under a 64-character random path, named by its SHA-1")
    let published = served.appendingPathComponent(first.token).appendingPathComponent("\(sha1).zip")
    equal(try? Data(contentsOf: published), content, "the published file is the build, byte for byte")
    let mode = ((try? FileManager.default.attributesOfItem(atPath: published.path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0
    equal(mode, 0o644, "readable by the web server, writable only by this account")
    let second = try? PackPublish.publish(build: build, sha1: sha1, settings: s, online: [])
    check(second != nil && second?.token != first.token, "every publish gets a new path")
    check((try? PackPublish.publish(build: build, sha1: String(repeating: "a", count: 40), settings: s, online: [])) == nil, "a build that doesn't match its SHA-1 isn't published")
    let left = (try? FileManager.default.contentsOfDirectory(atPath: served.path)) ?? []
    equal(Set(left), Set(["index.html", first.token, second?.token ?? ""]), "and leaves nothing behind; nothing else in the folder is touched")
    check(!left.contains { $0.hasSuffix(".json") }, "LeafJuice's record, which names who was online, never goes in the served folder")
    DiskGuard.standIn = { _ in (19 << 30, 500 << 30) }
    check((try? PackPublish.publish(build: build, sha1: sha1, settings: s, online: [])) == nil, "the disk guard applies here too")
    DiskGuard.standIn = nil

    // When an old build may go.
    let now = Date()
    func b(_ token: String, minutesAgo: Double, online: [String] = []) -> PublishedBuild {
        PublishedBuild(token: token, sha1: sha1, url: "", publishedAt: now.addingTimeInterval(-minutesAgo * 60), onlineAtSwitch: online)
    }
    check(PackPublish.removable([b("new", minutesAgo: 5), b("old", minutesAgo: 60)], online: []).isEmpty, "not within ten minutes of the switch")
    check(PackPublish.removable([b("new", minutesAgo: 30, online: ["MadeUpKid"]), b("old", minutesAgo: 60)], online: ["MadeUpKid"]).isEmpty, "not while someone online at the switch is still on")
    equal(PackPublish.removable([b("new", minutesAgo: 30, online: ["MadeUpKid"]), b("old", minutesAgo: 60)], online: ["MadeUpOther"]).map(\.token), ["old"], "once they've left, the old one goes")
    check(PackPublish.removable([b("only", minutesAgo: 600)], online: []).isEmpty, "the current build never goes")

    // Removing only what LeafJuice made.
    check((try? PackPublish.remove(PublishedBuild(token: "../index.html", sha1: sha1, url: "", publishedAt: now, onlineAtSwitch: []), settings: s)) == nil, "a record that isn't a random path removes nothing")
    if let second {
        write("extra", served.appendingPathComponent(second.token).appendingPathComponent("someone-elses.txt"))
        check((try? PackPublish.remove(second, settings: s)) == nil && FileOps.exists(served.appendingPathComponent(second.token)), "a folder holding something else is left alone")
    }
    try? PackPublish.remove(first, settings: s)
    check(!FileOps.exists(served.appendingPathComponent(first.token)) && FileOps.exists(served.appendingPathComponent("index.html")), "its own folder goes, and the rest of the served folder stays")

    // Through a made-up server: publish, publish again, and the old build tidied away when it's safe.
    let root = folder("publish-server")
    write("level-name=world\n", root.appendingPathComponent("server.properties"))
    guard let c = try? await ServerController.adopt(root: root, name: "Made-up Publish") else { check(false, "couldn't adopt a made-up server"); return }
    let served2 = folder("caddy-root-2")
    var cs = PackPublishSettings(); cs.folder = served2.path; cs.baseURL = "https://join.example.test/p/"
    c.packPublishSettings = cs
    func makeBuild(_ text: String) -> String {
        let data = Data(text.utf8), tmp = folder("tmp-build").appendingPathComponent("x.zip")
        try? data.write(to: tmp)
        let h = (try? Hashing.digests(of: tmp).sha1.lowercased()) ?? ""
        let dest = ResourcePacks.buildFile(sha1: h, recipe: "Made-up Recipe")
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: dest)
        return h
    }
    let h1 = makeBuild("one \(UUID())"), h2 = makeBuild("two \(UUID())")
    do {
        let p1 = try c.publishPack(recipe: "Made-up Recipe", sha1: h1)
        check((try? c.publishPack(recipe: "Made-up Recipe", sha1: h1)) == nil, "publishing the same build again is refused")
        let p2 = try c.publishPack(recipe: "Made-up Recipe", sha1: h2)
        equal(c.packPublishSettings.builds[ResourcePacks.slug("Made-up Recipe")]?.map(\.token), [p2.token, p1.token], "the newest is current, the old one waits")
        c.tidyPublishedPacks(now: Date())
        check(FileOps.exists(served2.appendingPathComponent(p1.token)), "inside the grace time, the old build stays")
        c.tidyPublishedPacks(now: Date().addingTimeInterval(11 * 60))
        check(!FileOps.exists(served2.appendingPathComponent(p1.token)) && FileOps.exists(served2.appendingPathComponent(p2.token)), "after it, with nobody on, only the current build is left")
        equal(c.packPublishSettings.builds[ResourcePacks.slug("Made-up Recipe")]?.map(\.token), [p2.token], "and the record says so")
    } catch { check(false, "publishing through the server threw: \(error)") }
}
