import Foundation
import LeafJuiceCore

/// Only players joining get a pack: the headers, the server's log, the whitelist, and the real listener.
@MainActor func packGateChecks() async {
    section("Serving packs: only players joining")
    let uuid = "0b1c2d3e-4f50-4617-8899-aabbccddeeff"
    let undashed = uuid.replacingOccurrences(of: "-", with: "")
    let game = ["x-minecraft-username": "MadeUpJoiner", "x-minecraft-uuid": undashed, "x-minecraft-version": "26.3", "user-agent": "Minecraft Java/26.3"]

    // The game's headers, in its own shapes.
    equal(PackGate.player(headers: game), PackGate.Player(name: "MadeUpJoiner", uuid: uuid), "the game's headers name a player, its undashed UUID read")
    equal(PackGate.player(headers: game.merging(["x-minecraft-uuid": uuid]) { $1 })?.uuid, uuid, "a dashed UUID is read too")
    for (label, change) in [("no name", ["x-minecraft-username": nil]), ("no UUID", ["x-minecraft-uuid": nil]), ("no version", ["x-minecraft-version": nil]),
                            ("a name with a space", ["x-minecraft-username": "Made Up"]), ("a 17-letter name", ["x-minecraft-username": "SeventeenLettersX"]),
                            ("a short UUID", ["x-minecraft-uuid": "0b1c2d3e"]), ("a UUID that isn't hex", ["x-minecraft-uuid": String(repeating: "z", count: 32)]),
                            ("hyphens in odd places", ["x-minecraft-uuid": "0b1c2d3e4f50-4617-8899-aabb-ccddeeff"]), ("an empty version", ["x-minecraft-version": ""])] as [(String, [String: String?])] {
        var h = game
        for (k, v) in change { h[k] = v }
        check(PackGate.player(headers: h) == nil, "not a player's request: \(label)")
    }

    // The server's own lines, at times relative to now.
    let now = Date()
    let clock = DateFormatter(); clock.dateFormat = "HH:mm:ss"; clock.locale = Locale(identifier: "en_US_POSIX")
    func at(_ minutesAgo: Double) -> String { clock.string(from: now.addingTimeInterval(-minutesAgo * 60)) }
    func authLine(_ ago: Double, _ name: String = "MadeUpJoiner", _ id: String = uuid) -> String { "[\(at(ago))] [User Authenticator #1/INFO]: UUID of player \(name) is \(id)" }
    func joinLine(_ ago: Double, _ verb: String, _ name: String = "MadeUpJoiner") -> String { "[\(at(ago))] [Server thread/INFO]: \(name) \(verb) the game" }
    let whitelist = Data(#"[{"uuid":"\#(uuid)","name":"MadeUpJoiner"},{"uuid":"11111111-2222-4333-8444-555555555555","name":"MadeUpOther"}]"#.utf8)
    let player = PackGate.player(headers: game)
    func admits(_ log: [String], _ p: PackGate.Player? = PackGate.player(headers: game), whitelist w: Data? = whitelist) -> Bool {
        PackGate.admits(p, whitelist: w, log: log.joined(separator: "\n") + "\n", now: now)
    }
    check(admits([authLine(1)]), "a whitelisted player the server logged connecting a minute ago gets it")
    check(admits([authLine(4.5)]), "and at four and a half minutes")
    check(!admits([authLine(6)]), "but not six minutes later, having never joined")
    check(admits([authLine(30), joinLine(29, "joined")]), "someone online now still gets it, for a pack sent later")
    check(!admits([authLine(30), joinLine(29, "joined"), joinLine(10, "left")]), "but not once they've left")
    check(!admits([]), "nobody the log shows connecting gets nothing")
    check(!admits([authLine(1)], PackGate.player(headers: game.merging(["x-minecraft-username": "MadeUpImposter"]) { $1 })), "a different name with that UUID gets nothing")
    check(!admits([authLine(1, "MadeUpOther", "11111111-2222-4333-8444-555555555555")], PackGate.player(headers: ["x-minecraft-username": "MadeUpOther", "x-minecraft-uuid": "99999999222243338444555555555555", "x-minecraft-version": "26.3"])),
          "a UUID that isn't on the whitelist gets nothing")
    check(!admits([authLine(1)], whitelist: Data(#"[{"uuid":"11111111-2222-4333-8444-555555555555","name":"MadeUpOther"}]"#.utf8)), "someone not on the whitelist gets nothing, even while joining")
    check(!admits([authLine(1)], whitelist: nil), "an unreadable whitelist means nobody")
    check(!admits([authLine(1)], whitelist: Data("not json".utf8)), "and so does a damaged one")
    check(!PackGate.admits(player, whitelist: whitelist, log: nil, now: now), "an unreadable log means nobody")
    check(!admits([authLine(1)], nil), "and so do missing headers")
    // Chat and plugins writing look-alike text.
    check(!admits(["[\(at(1))] [Async Chat Thread - #0/INFO]: <Griefer> UUID of player MadeUpJoiner is \(uuid)"]), "chat can't vouch for someone")
    check(!admits(["[\(at(1))] [Server thread/INFO]: UUID of player MadeUpJoiner is \(uuid)"]), "nor can a line from another thread")
    check(!admits(["[\(at(30))] [Async Chat Thread - #0/INFO]: <Griefer> MadeUpJoiner joined the game", authLine(30)]), "chat can't make someone online")
    check(!admits([authLine(1) + " extra"]), "a line with more on the end isn't the server's")
    // A line from just before midnight, read just after.
    let late = Calendar.current.startOfDay(for: now).addingTimeInterval(-60)
    let seen = PackGate.joining(log: "[23:59:00] [User Authenticator #2/INFO]: UUID of player MadeUpJoiner is \(uuid)\n", now: Calendar.current.startOfDay(for: now).addingTimeInterval(120))
    equal(seen.connected[uuid]?.at, late, "a line from 23:59 read at 00:02 is yesterday's, three minutes ago")

    // The real listener on 127.0.0.1.
    do {
        let root = folder("pack-gate")
        write("server-port=25599\n", root.appendingPathComponent("server.properties"))
        let c = try await ServerController.adopt(root: root, name: "pack-gate")
        defer { c.stopPackHost() }
        let made = await makePack("Gate Pack", ["pack.mcmeta": #"{"pack":{"pack_format":75,"description":"gate"}}"#, "assets/madeup/x.json": "{}"])
        let build = try await ResourcePacks.addExact(made, name: "gate-pack")
        let port = 28772
        try c.setPackHost(address: "http://127.0.0.1:\(port)", port: port)
        check(c.packHostSettings.joiningOnly, "only players joining is on by default")
        try c.startPackHost()
        await checkUntil(5, "listening") { c.packHostIsListening }
        let url = c.packBuildAddress(recipe: "gate-pack", sha1: build.sha1)!
        let playerURL = c.packAddress(recipe: "gate-pack")!
        write(String(data: whitelist, encoding: .utf8)!, root.appendingPathComponent("whitelist.json"))
        let log = root.appendingPathComponent("logs/latest.log")
        write([authLine(1)].joined(separator: "\n") + "\n", log)
        let ok = await PackHosting.check(url: url, expected: build.sha1, headers: game)
        check(ok.ok, "a whitelisted player joining gets the pack: \(ok.summary)")
        let refused = await PackHosting.check(url: url, expected: build.sha1)
        equal(refused.outcome, .status(404), "a request with no game headers, as from curl, gets 404")
        let browser = await PackHosting.check(url: url, expected: build.sha1, headers: ["user-agent": "Mozilla/5.0 (Macintosh)"])
        equal(browser.outcome, .status(404), "and so does a browser")
        let stranger = await PackHosting.check(url: url, expected: build.sha1, headers: game.merging(["x-minecraft-uuid": "99999999222243338444555555555555"]) { $1 })
        equal(stranger.outcome, .status(404), "and a UUID that isn't on the whitelist")
        let wrongPath = await PackHosting.check(url: "http://127.0.0.1:\(port)/nothing/here.zip", expected: build.sha1)
        let gatedHash = await PackHosting.check(url: playerURL.replacingOccurrences(of: ".zip", with: ".sha1"), expected: build.sha1)
        check(wrongPath.outcome == .status(404) && gatedHash.outcome == .status(404), "a refused request looks the same as a wrong address, and the hash can't be read either")
        let head = await rawStatus(port: port, "HEAD \(URL(string: url)!.path) HTTP/1.1\r\nHost: x\r\n\r\n")
        equal(head, 404, "a HEAD without the headers gets 404 too")
        let twice = await rawStatus(port: port, "GET \(URL(string: url)!.path) HTTP/1.1\r\nHost: x\r\nX-Minecraft-Username: MadeUpJoiner\r\nX-Minecraft-Username: MadeUpOther\r\nX-Minecraft-UUID: \(undashed)\r\nX-Minecraft-Version: 26.3\r\n\r\n")
        equal(twice, 400, "a header sent twice makes the request bad")
        write([authLine(6)].joined(separator: "\n") + "\n", log)
        let stale = await PackHosting.check(url: url, expected: build.sha1, headers: game)
        equal(stale.outcome, .status(404), "six minutes after connecting, not online, the same player gets 404")
        write([authLine(30), joinLine(29, "joined")].joined(separator: "\n") + "\n", log)
        let online = await PackHosting.check(url: url, expected: build.sha1, headers: game)
        check(online.ok, "online now, they get it: \(online.summary)")
        try? FileManager.default.removeItem(at: log)
        let noLog = await PackHosting.check(url: url, expected: build.sha1, headers: game)
        equal(noLog.outcome, .status(404), "with no log to read, nobody gets it")
        write(authLine(1) + "\n", log)

        // The app's own check: a one-time pass.
        let ticket = c.packCheckTicket()
        check(ticket != nil, "the app can get a pass while serving")
        let own = await PackHosting.check(url: url, expected: build.sha1, ticket: ticket)
        check(own.ok, "its own check downloads the pack as a player would: \(own.summary)")
        let reused = await PackHosting.check(url: url, expected: build.sha1, ticket: ticket)
        equal(reused.outcome, .status(404), "and the pass works once")
        let madeUp = await PackHosting.check(url: url, expected: build.sha1, ticket: String(repeating: "a", count: 48))
        equal(madeUp.outcome, .status(404), "a made-up pass is refused")
        let tickets = PackCheckTickets()
        let old = tickets.issue(now: now.addingTimeInterval(-121))
        check(!tickets.redeem(old, now: now), "a pass lapses after two minutes")

        // Turned off, it serves anyone, as before.
        try c.setPackJoiningOnly(false)
        await checkUntil(5, "listening again") { c.packHostIsListening }
        let open = await PackHosting.check(url: url, expected: build.sha1)
        check(open.ok, "turned off, anyone with the address gets it: \(open.summary)")
        try c.setPackJoiningOnly(true)
        await checkUntil(5, "listening, gated again") { c.packHostIsListening }
        let back = await PackHosting.check(url: url, expected: build.sha1)
        equal(back.outcome, .status(404), "and back on, it's refused again")

        // Settings saved before this existed keep their addresses, and get the check switched on.
        let saved = Data(#"{"enabled":true,"port":8766,"address":"http://127.0.0.1:1","recipes":{"x":{"token":"made-up-token"}}}"#.utf8)
        let decoded = try JSONDecoder().decode(PackHostSettings.self, from: saved)
        check(decoded.joiningOnly && decoded.recipes["x"]?.token == "made-up-token" && decoded.enabled, "older saved settings keep their addresses and get the check on")
    } catch { failures.append("pack gate checks threw: \(error)") }
}

/// The status code for one raw request, for shapes URLSession won't send.
func rawStatus(port: Int, _ request: String) async -> Int? {
    await Task.detached { () -> Int? in
        guard let stream = try? socketConnect(port: port) else { return nil }
        defer { close(stream) }
        _ = request.withCString { send(stream, $0, strlen($0), 0) }
        var buffer = [UInt8](repeating: 0, count: 512)
        let n = recv(stream, &buffer, buffer.count, 0)
        guard n > 12, let line = String(bytes: buffer[0..<n], encoding: .utf8)?.split(separator: " ").dropFirst().first else { return nil }
        return Int(line)
    }.value
}

private func socketConnect(port: Int) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw LeafError("no socket") }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard ok == 0 else { close(fd); throw LeafError("no connection") }
    return fd
}

/// A throwaway server for owner test T28: online mode, the whitelist on, and a made-up required pack served by Leaf
/// Juice with only players joining on. The owner whitelists their own account in the Console and joins with the game.
@MainActor func runDemoPack(_ demo: URL) async throws {
    let root = demo.appendingPathComponent("servers/pack-demo", isDirectory: true)
    try FileOps.ensureDir(root)
    write("server-port=25596\nserver-ip=127.0.0.1\nonline-mode=true\nwhite-list=true\nenforce-whitelist=true\nview-distance=4\nsimulation-distance=4\nlevel-type=minecraft\\:flat\nmotd=Leaf Juice pack demo\nresource-pack-prompt={\"text\":\"Leaf Juice test pack: only players joining\"}\n",
          root.appendingPathComponent("server.properties"))
    let c = try await ServerController.adopt(root: root, name: "pack-demo")
    c.profile.name = "Pack demo"
    try EULA.accept(c.paths)
    try await c.installSoftware(try await SoftwareCatalog.latestBuild(.paper, mc: realMC)!)
    c.profile.lastPluginCheck = Date(); c.profile.software.lastCheck = Date()
    await c.start()
    guard await until(240, { c.state == .running }) else { throw LeafError("The demo server didn't start: \(c.console.suffix(3).map(\.text))") }
    c.stop()
    _ = await until(90, { c.state == .stopped })
    let made = await makePack("Leaf Juice Test Pack", ["pack.mcmeta": #"{"pack":{"pack_format":75,"description":"Leaf Juice test pack (made up)"}}"#, "assets/madeup/x.json": "{}"])
    let build = try await ResourcePacks.addExact(made, name: "demo-pack")
    try c.setPackHost(address: "http://127.0.0.1:28781", port: 28781)
    try c.startPackHost()
    _ = await until(5, { c.packHostIsListening })
    let url = c.packBuildAddress(recipe: "demo-pack", sha1: build.sha1)!
    _ = try await c.usePack(url: url, sha1: build.sha1, required: true, recipe: "demo-pack")
    // Left switched on, so the app starts serving when it opens.
    c.stopPackHost(remember: false)
    c.stopTicker()
    try? FileManager.default.removeItem(at: c.paths.issues)
    try? FileManager.default.removeItem(at: root.appendingPathComponent("logs/latest.log"))
    try JSONStore.save([root.path], to: AppPaths.registry)
    write(url + "\n", demo.appendingPathComponent("pack-address.txt"))
    print("Demo ready in \(demo.path). Pack address: \(url)")
}
