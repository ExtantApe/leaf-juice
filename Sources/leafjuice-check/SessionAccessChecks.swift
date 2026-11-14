import Foundation
@testable import LeafJuiceCore
import Security

/// Session access: every refusal, what a session may see, the record of calls, and the real socket with the real client.
@MainActor func sessionAccessChecks() async {
    section("Session access: who may ask, and what")
    var on = SessionAccessSettings(); on.enabled = true
    let token = "made-up-token-0123456789abcdef"
    func decide(_ json: String, _ s: SessionAccessSettings = on, token expected: String? = token) -> Result<SessionAccess.Call, SessionAccess.Refusal> {
        SessionAccess.authorize(Data(json.utf8), settings: s, token: expected).1
    }
    func ok(_ extra: String) -> String { #"{"token":"\#(token)","caller":"Made-up Session",\#(extra)}"# }

    equal(SessionAccessSettings(), { var d = SessionAccessSettings(); d.enabled = false; d.commands = ["welcomewagon reload", "save-all", "list"]; return d }(), "off by default, with the three starting commands")
    equal(decide(ok(#""call":"status""#), SessionAccessSettings()), .failure(.off), "off: refused, even with the right token")
    equal(decide("not json"), .failure(.unreadable), "unreadable: refused")
    equal(decide(String(repeating: "x", count: SessionAccess.maxRequestBytes + 1)), .failure(.tooLong), "too long: refused")
    equal(decide(#"{"caller":"x","call":"status"}"#), .failure(.noToken), "no token: refused")
    equal(decide(#"{"token":"wrong","caller":"x","call":"status"}"#), .failure(.badToken), "wrong token: refused")
    equal(decide(#"{"token":"made-up-token-0123456789abcdeX","caller":"x","call":"status"}"#), .failure(.badToken), "a token one character off: refused")
    equal(decide(ok(#""call":"status""#), token: nil), .failure(.badToken), "no token in the Keychain: everything refused")
    equal(decide(ok(#""call":"status""#), token: ""), .failure(.badToken), "an empty one: same")
    equal(decide(#"{"token":"\#(token)","call":"status"}"#), .failure(.noCaller), "nobody named: refused")
    equal(decide(#"{"token":"\#(token)","caller":"a\nb","call":"status"}"#), .failure(.noCaller), "a caller with a line break: refused")
    equal(decide(ok(#""call":"shell""#)), .failure(.unknownCall("shell")), "an unknown call: refused")
    equal(decide(ok(#""call":"status""#)), .success(.status), "status: allowed")
    equal(decide(ok(#""call":"log","lines":100000"#)), .success(.log(lines: 200)), "log is capped at 200 lines")
    equal(decide(ok(#""call":"log","lines":-5"#)), .success(.log(lines: 1)), "and at least one")
    equal(decide(ok(#""call":"run","command":"save-all""#)), .success(.run(command: "save-all")), "a listed command: allowed")
    equal(decide(ok(#""call":"run","command":"  /welcomewagon   reload ""#)), .success(.run(command: "welcomewagon reload")), "with a slash and extra spaces, it's the same command")
    for (bad, label) in [("save-all flush", "a listed command with arguments added"), ("op MadeUpPlayer", "a command that isn't listed"),
                         ("SAVE-ALL", "a listed command in other letters"), ("stop", "stop"), ("", "nothing"), ("welcomewagon", "part of a listed command")] {
        if case .failure(.notOnList) = decide(ok(#""call":"run","command":"\#(bad)""#)) { check(true, "refused: \(label)") } else { check(false, "refused: \(label)") }
    }
    equal(decide(ok(#""call":"run","command":"list\nop MadeUp""#)), .failure(.lineBreak), "a second command after a line break: refused")
    equal(decide(ok(#""call":"run","command":"list\u0000""#)), .failure(.lineBreak), "a control character: refused")
    check(SessionAccess.problem(adding: "stop") != nil && SessionAccess.problem(adding: " /STOP now") != nil, "stop can't be put on the list")
    check(SessionAccess.problem(adding: "a\nb") != nil && SessionAccess.problem(adding: "  ") != nil, "nor a line break, nor nothing")
    check(SessionAccess.problem(adding: "whitelist reload") == nil, "an ordinary command can")
    let saved = folder("session-settings")
    try? JSONStore.save(on, to: saved.appendingPathComponent("s.json"))
    equal(JSONStore.load(saved.appendingPathComponent("s.json"), defaults: SessionAccessSettings()), on, "settings read back")

    section("Session access: what a session may see")
    let lines = [
        ConsoleLine(id: 1, text: "[12:00:00] [Server thread/INFO]: <MadeUpKid> my house is at 100 64 200", level: .info, origin: .server),
        ConsoleLine(id: 2, text: "[12:00:01] [Server thread/INFO]: MadeUpKid[/203.0.113.9:51234] logged in with entity id 42", level: .info, origin: .server),
        ConsoleLine(id: 3, text: "[12:00:02] [User Authenticator #1/INFO]: UUID of player MadeUpKid is 0b1c2d3e-4f50-4617-8899-aabbccddeeff", level: .info, origin: .server),
        ConsoleLine(id: 4, text: "[12:00:03] [Server thread/INFO]: madeupkid joined the game. Hello from 2001:db8::1", level: .info, origin: .server),
        ConsoleLine(id: 5, text: "[12:00:04] [Server thread/INFO]: MadeUpKidTwo left the game", level: .info, origin: .server),
        ConsoleLine(id: 6, text: "[12:00:05] [Server thread/INFO]: Saved the game", level: .info, origin: .server),
    ]
    let shown = SessionAccess.shareable(lines, players: ["MadeUpKid", "MadeUpKidTwo"])
    equal(shown.count, 5, "chat is left out")
    check(!shown.joined().lowercased().contains("madeupkid"), "player names are taken out, in any case, longest first")
    check(!shown.joined().contains("203.0.113.9") && !shown.joined().contains("2001:db8"), "addresses are taken out")
    check(!shown.joined().contains("0b1c2d3e"), "and UUIDs")
    check(shown.contains { $0.contains("Saved the game") }, "the rest is kept")
    equal(SessionAccess.redact("Samantha joined", players: ["Sam"]), "Samantha joined", "a name inside a longer word is left alone")
    check(shown.first?.hasPrefix("[12:00:01]") == true, "log times aren't mistaken for addresses: \(shown.first ?? "")")
    equal(SessionAccess.redact("from [fe80::1%en0]:25565 and 2001:0db8:0000:0000:0000:0000:0000:0001", players: []), "from [[address]]:25565 and [address]", "IPv6 in its other shapes too")

    section("Session access: the record of calls")
    let logFile = folder("session-log").appendingPathComponent("calls.jsonl")
    let req = SessionAccess.Request(token: token, caller: "Made-up\nSession" + String(repeating: "x", count: 100), call: "run", command: "op MadeUp")
    SessionAccess.record(req, outcome: .failure(.notOnList("op MadeUp")), server: "Made-up Server", to: logFile)
    SessionAccess.record(SessionAccess.Request(token: token, caller: "Made-up Session", call: "status"), outcome: .success(.status), server: "Made-up Server", to: logFile)
    let text = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
    check(!text.contains(token), "the token is never written to the record")
    let entries = SessionAccess.recentLog(10, from: logFile)
    equal(entries.count, 2, "both calls are recorded, refused and allowed")
    check(entries.last?.allowed == false && entries.last?.command == "op MadeUp" && entries.last?.note.contains("isn't on") == true, "a refusal says what and why")
    check(entries.last.map { $0.caller.count <= 64 && !$0.caller.contains("\n") } == true, "a caller can't bloat or break the record")
    equal(entries.first?.allowed, true, "newest first")

    section("Session access: the token, in a throwaway keychain")
    let (path, _) = throwawayKeychain("session-access")
    var kc: SecKeychain?
    guard SecKeychainOpen(path, &kc) == errSecSuccess, let kc else { check(false, "couldn't open the throwaway keychain"); return }
    check(SessionAccess.token(create: false, keychain: kc) == nil, "no token until one is made")
    let first = SessionAccess.token(create: true, keychain: kc)
    check(first?.count == 64, "one is made when asked: 32 random bytes")
    equal(SessionAccess.token(create: true, keychain: kc), first, "and the same one is read back")
    let second = try? SessionAccess.newToken(keychain: kc)
    check(second != nil && second != first, "a new token replaces it")
    equal(SessionAccess.token(create: false, keychain: kc), second, "the new one is what's read")

    section("Session access: the real socket and the real client")
    let root = folder("session-server")
    write("server-port=25598\nserver-ip=127.0.0.1\nmotd=made up\n", root.appendingPathComponent("server.properties"))
    guard let server = try? await ServerController.adopt(root: root, name: "Made-up Server") else { check(false, "couldn't adopt a made-up server"); return }
    let service = SessionAccessService()
    service.keychain = kc
    service.logFile = folder("session-log-2").appendingPathComponent("calls.jsonl")
    service.servers = { [server] }
    try? SessionAccess.saveSettings(on)
    let socketPath = "/private/tmp/lj-check-\(getpid()).sock"
    service.apply(on, path: socketPath)
    check(service.isListening, "it listens when turned on")
    let mode = ((try? FileManager.default.attributesOfItem(atPath: socketPath))?[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
    equal(mode & 0o077, 0, "the socket is private to this account (\(String(mode, radix: 8)))")
    let client = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("leafjuice-session").path
    let current = SessionAccess.token(create: false, keychain: kc) ?? ""
    func ask(_ args: [String], token t: String? = nil) async -> (code: Int32, json: [String: Any]) {
        let env = "LEAFJUICE_SESSION_TOKEN=\(t ?? current)"
        let r = try? await Tool.run("/usr/bin/env", [env, "LEAFJUICE_SESSION_SOCKET=\(socketPath)", client] + args, timeout: 15)
        let json = (try? JSONSerialization.jsonObject(with: Data((r?.out ?? "").utf8))) as? [String: Any] ?? [:]
        return (r?.code ?? -1, json)
    }
    var r = await ask(["--as", "Made-up Session", "status"])
    check(r.code == 0 && r.json["ok"] as? Bool == true, "status answers")
    let first0 = (r.json["servers"] as? [[String: Any]])?.first
    check(first0?["name"] as? String == "Made-up Server" && first0?["playersOnline"] as? Int == 0, "with the server's name and a count of players, not their names")
    r = await ask(["--as", "Made-up Session", "log", "--lines", "5"])
    check(r.code == 0 && r.json["lines"] is [String], "the log answers")
    r = await ask(["--as", "Made-up Session", "run", "save-all"])
    check(r.code == 1 && (r.json["error"] as? String)?.contains("isn't running") == true, "a listed command on a stopped server: refused, nothing sent")
    r = await ask(["--as", "Made-up Session", "run", "op", "MadeUp"])
    check(r.code == 1 && (r.json["error"] as? String)?.contains("isn't on the owner's list") == true, "an unlisted command: refused")
    r = await ask(["--as", "Made-up Session", "status"], token: "wrong")
    check(r.code == 1 && (r.json["error"] as? String)?.contains("token") == true, "the wrong token: refused")
    r = await ask(["--as", "Made-up Session", "log", "--server", "No Such Server"])
    check(r.code == 1, "an unknown server: refused")
    let calls = SessionAccess.recentLog(20, from: service.logFile!)
    equal(calls.count, 6, "every call was recorded")
    equal(calls.filter(\.allowed).count, 2, "two allowed, four refused")
    service.apply(SessionAccessSettings())
    check(!service.isListening && !FileManager.default.fileExists(atPath: socketPath), "turned off, it stops listening and removes the socket")
    r = await ask(["--as", "Made-up Session", "status"])
    equal(r.code, 2, "and the client says LeafJuice can't be reached")
    write("not a socket", URL(fileURLWithPath: socketPath))
    service.apply(on, path: socketPath)
    check(!service.isListening && service.error?.contains("isn't a socket") == true, "a file in the socket's place isn't deleted or used")
    try? FileManager.default.removeItem(atPath: socketPath)
    try? SessionAccess.saveSettings(SessionAccessSettings())
}

/// A real Paper server on 127.0.0.1, a made-up bot, and the real client running listed commands. Deleted afterwards.
@MainActor func runRealSession() async {
    section("REAL SESSION ACCESS (EULA accepted by the person running this)")
    do {
        let root = folder("real-session")
        write("server-port=25596\nserver-ip=127.0.0.1\nonline-mode=false\nwhite-list=false\nnetwork-compression-threshold=-1\nview-distance=4\nsimulation-distance=4\nmotd=made up\nlevel-type=minecraft\\:flat\n", root.appendingPathComponent("server.properties"))
        let c = try await ServerController.adopt(root: root, name: "Real session test")
        defer { c.forceStop(); c.stopTicker() }
        try EULA.accept(c.paths)
        try await c.installSoftware(try await SoftwareCatalog.latestBuild(.paper, mc: realMC)!)
        c.profile.lastPluginCheck = Date(); c.profile.software.lastCheck = Date()
        await c.start()
        await checkUntil(240, "real server up: \(c.state)") { c.state == .running }

        let (path, _) = throwawayKeychain("real-session")
        var kc: SecKeychain?
        guard SecKeychainOpen(path, &kc) == errSecSuccess, let kc else { throw LeafError("no throwaway keychain") }
        let service = SessionAccessService()
        service.keychain = kc
        service.logFile = folder("real-session-log").appendingPathComponent("calls.jsonl")
        service.servers = { [c] }
        var on = SessionAccessSettings(); on.enabled = true
        try SessionAccess.saveSettings(on)
        let socketPath = "/private/tmp/lj-real-\(getpid()).sock"
        service.apply(on, path: socketPath)
        defer { service.apply(SessionAccessSettings()); try? SessionAccess.saveSettings(SessionAccessSettings()) }
        let client = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("leafjuice-session").path
        let token = SessionAccess.token(create: false, keychain: kc) ?? ""
        func ask(_ args: [String]) async -> [String: Any] {
            let r = try? await Tool.run("/usr/bin/env", ["LEAFJUICE_SESSION_TOKEN=\(token)", "LEAFJUICE_SESSION_SOCKET=\(socketPath)", client, "--as", "Made-up Session"] + args, timeout: 20)
            return (try? JSONSerialization.jsonObject(with: Data((r?.out ?? "").utf8))) as? [String: Any] ?? [:]
        }

        let java = c.resolvedJava()?.path ?? ""
        let table = try await ProtocolTable.load(mc: realMC, cache: folder("session-protocol"), java: java)
        let bot = try Bot(name: "MadeUpSessionBot", port: 25596, table: table)
        await checkUntil(60, "bot in game: \(bot.disconnectReason ?? "")") { bot.inGame }
        await checkUntil(10, "the server sees the bot") { c.players.contains("MadeUpSessionBot") }

        var answer = await ask(["status"])
        let status = (answer["servers"] as? [[String: Any]])?.first
        check(status?["state"] as? String == c.state.title && status?["playersOnline"] as? Int == 1, "status on a real server: running, one player (\(status ?? [:]))")
        check(!String(describing: answer).contains("MadeUpSessionBot"), "status never names the player")
        answer = await ask(["run", "list"])
        let output = (answer["output"] as? [String]) ?? []
        check(answer["ok"] as? Bool == true && output.contains { $0.contains("1 of a max") || $0.contains("1 of") }, "list runs, and its answer comes back: \(output)")
        check(!output.joined().contains("MadeUpSessionBot") && output.joined().contains("[player]"), "with the player's name taken out")
        answer = await ask(["run", "save-all"])
        check(answer["ok"] as? Bool == true && ((answer["output"] as? [String]) ?? []).contains { $0.lowercased().contains("sav") }, "save-all runs: \(answer["output"] ?? "")")
        answer = await ask(["run", "op", "MadeUpSessionBot"])
        check(answer["ok"] as? Bool == false, "op isn't on the list, so it's refused")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        check(!c.console.contains { $0.origin == .command && $0.text.contains("op MadeUpSessionBot") }, "and it never reached the console")
        check(c.console.contains { $0.text.contains("A session (Made-up Session) ran: save-all") }, "the app's console says a session ran save-all")
        let log = (await ask(["log", "--lines", "40"])["lines"] as? [String]) ?? []
        check(!log.isEmpty && !log.joined().contains("MadeUpSessionBot") && !log.joined().contains("127.0.0.1"), "the real log comes back without the player's name or address")
        let calls = SessionAccess.recentLog(20, from: service.logFile!)
        check(calls.count == 5 && calls.filter { !$0.allowed }.count == 1, "all five calls recorded, one refused")
        bot.leave()
        c.stop()
        await checkUntil(90, "stopped: \(c.state)") { c.state == .stopped }
    } catch { failures.append("real session access: \(error)") }
}
