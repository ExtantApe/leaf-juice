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

    // Only links that are safe to type into a console go to Packmule.
    check(PackPublish.isSendable("https://join.example.test/packs/\(String(repeating: "a", count: 64))/\(sha1).zip"), "a published link can be sent")
    for bad in ["http://join.example.test/x/\(sha1).zip", "https://join.example.test/x/pack.zip", "https://join.example.test/x y/\(sha1).zip",
                "https://join.example.test/x/\(sha1).zip;op MadeUp", "https://join.example.test/x/\(sha1).zip\nop MadeUp", "https://u@join.example.test/\(sha1).zip"] {
        check(!PackPublish.isSendable(bad), "not sent: \(bad.debugDescription)")
    }

    // When an old build may go.
    let now = Date()
    func b(_ token: String, minutesAgo: Double, online: [String] = [], handedOff: Bool = true) -> PublishedBuild {
        var r = PublishedBuild(token: token, sha1: sha1, url: "", publishedAt: now.addingTimeInterval(-minutesAgo * 60), onlineAtSwitch: online)
        r.handedOff = handedOff
        return r
    }
    check(PackPublish.removable([b("new", minutesAgo: 600, handedOff: false), b("old", minutesAgo: 900)], online: []).isEmpty, "never while Packmule may still send players to the old link")
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
        c.tidyPublishedPacks(now: Date().addingTimeInterval(60 * 60))
        check(FileOps.exists(served2.appendingPathComponent(p1.token)), "until Packmule uses the new link, the old build stays, however long")
        c.markHandedOff(recipe: "Made-up Recipe")
        c.tidyPublishedPacks(now: Date())
        check(FileOps.exists(served2.appendingPathComponent(p1.token)), "inside the grace time, the old build stays")
        c.tidyPublishedPacks(now: Date().addingTimeInterval(11 * 60))
        check(!FileOps.exists(served2.appendingPathComponent(p1.token)) && FileOps.exists(served2.appendingPathComponent(p2.token)), "after it, with nobody on, only the current build is left")
        equal(c.packPublishSettings.builds[ResourcePacks.slug("Made-up Recipe")]?.map(\.token), [p2.token], "and the record says so")
    } catch { check(false, "publishing through the server threw: \(error)") }
}

/// The real Packmule 0.2.1 on a throwaway Paper server. No https host is reachable here, so this proves the two speak
/// the same language: describe lists pack set, the command is parsed, and a link that can't be downloaded is refused
/// with check-failed and the old link kept. A full success needs the real join host.
@MainActor func runRealPackmule(jar: String) async {
    section("REAL PACKMULE (EULA accepted by the person running this)")
    do {
        let root = folder("real-packmule")
        write("server-port=25591\nserver-ip=127.0.0.1\nonline-mode=false\nview-distance=4\nsimulation-distance=4\nmotd=made up\nlevel-type=minecraft\\:flat\n", root.appendingPathComponent("server.properties"))
        let c = try await ServerController.adopt(root: root, name: "Real Packmule test")
        defer { c.forceStop(); c.stopTicker() }
        try EULA.accept(c.paths)
        try await c.installSoftware(try await SoftwareCatalog.latestBuild(.paper, mc: realMC)!)
        c.profile.lastPluginCheck = Date(); c.profile.software.lastCheck = Date()
        try FileManager.default.createDirectory(at: c.paths.plugins.appendingPathComponent("Packmule"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: jar), to: c.paths.plugins.appendingPathComponent("Packmule.jar"))
        let oldSHA = String(repeating: "1", count: 40), newSHA = String(repeating: "2", count: 40)
        let oldURL = "https://127.0.0.1:9/old/\(oldSHA).zip"
        write("packs:\n  main:\n    url: \(oldURL)\nworlds:\n  world: [main]\n  world_nether: [main]\n  world_the_end: [main]\n", c.paths.plugins.appendingPathComponent("Packmule/config.yml"))
        Modules.shared.set(.pluginCommands, on: true)
        defer { Modules.shared.set(.pluginCommands, on: false) }
        await c.start()
        await checkUntil(240, "real server up: \(c.state)") { c.state == .running }

        var s = PackPublishSettings()
        s.builds["made-up-recipe"] = [PublishedBuild(token: String(repeating: "d", count: 64), sha1: newSHA, url: "https://127.0.0.1:9/new/\(newSHA).zip", publishedAt: Date(), onlineAtSwitch: [])]
        s.packmuleNames = ["made-up-recipe": "main"]
        c.packPublishSettings = s
        let told = await c.tellPackmule(recipe: "Made-up Recipe")
        if case .notTold(let why) = told {
            check(why.contains("couldn't download") || why.contains("kept the old one"), "the real Packmule refuses a link it can't download, in plain words: \(why)")
        } else { check(false, "a link nothing serves must not be accepted: \(told)") }
        check(c.packPublishSettings.builds["made-up-recipe"]?.first?.handedOff != true, "and the build isn't marked as in use")
        let config = (try? String(contentsOf: c.paths.plugins.appendingPathComponent("Packmule/config.yml"), encoding: .utf8)) ?? ""
        check(config.contains(oldURL), "Packmule kept the old link in its config")
        check(c.console.contains { $0.text.contains("packmule pack set main https://127.0.0.1:9/new/") }, "the command reached the real server's console")
        c.stop()
        await checkUntil(90, "stopped: \(c.state)") { c.state == .stopped }
    } catch { failures.append("real packmule: \(error)") }
}
