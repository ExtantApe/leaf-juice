import Foundation
import LeafJuiceCore
import Network
import Security

/// Made-up answers for every outside thing a connection check touches, with a record of what was asked.
final class FakeConnectionProbe: ConnectionProbe, @unchecked Sendable {
    private let lock = NSLock()
    var tools: [String: (Int32, String)] = [:]
    var executables: Set<String> = []
    var files: [String: (size: Int, mode: Int)] = [:]
    var tails: [String: String] = [:]
    var secrets: [String: SecretPresence] = [:]
    var answering: Set<String> = []     // host:port that answer a TCP connect
    var gameAnswering: Set<String> = [] // host:port that answer a status ping
    var web: [String: Int] = [:]
    var names: [String: [String]] = [:]
    private var _asked: [String] = []
    var asked: [String] { lock.lock(); defer { lock.unlock() }; return _asked }
    let now = Date()
    let home = "/made-up-home"

    private func ask(_ s: String) { lock.lock(); _asked.append(s); lock.unlock() }
    func run(_ path: String, _ args: [String], timeout: TimeInterval) async -> (status: Int32, out: String)? { ask("run \(path)"); return tools[path] }
    func isExecutable(_ path: String) -> Bool { executables.contains(path) }
    func fileInfo(_ path: String) -> (size: Int, mode: Int)? { files[path] }
    func tail(_ path: String, bytes: Int) -> String? { tails[path] }
    func keychain(_ account: String) -> SecretPresence { ask("keychain \(account)"); return secrets[account] ?? .missing }
    func tcp(host: String, port: Int, timeout: TimeInterval) async -> Bool { ask("tcp \(host):\(port)"); return answering.contains("\(host):\(port)") }
    func minecraftStatus(host: String, port: Int, timeout: TimeInterval) async -> Bool { ask("ping \(host):\(port)"); return gameAnswering.contains("\(host):\(port)") }
    func httpStatus(_ url: URL, timeout: TimeInterval) async -> Int? { ask("http \(url.absoluteString)"); return web[url.absoluteString] }
    func resolve(_ host: String) async -> [String]? { ask("dns \(host)"); return names[host] }
}

@MainActor func connectionChecks() async {
    section("Connections: the file")
    let meta = folder("connections-meta")
    var loaded = ConnectionStore.load(meta)
    check(loaded.settings == ConnectionSettings() && loaded.problems.isEmpty && !loaded.unreadable, "no file means no connections and no complaint")

    write("{not json", ConnectionStore.file(meta))
    loaded = ConnectionStore.load(meta)
    check(loaded.unreadable && loaded.settings.services.isEmpty && loaded.problems.count == 1, "an unreadable file is reported, not a crash")
    var fresh = ConnectionSettings(); fresh.playerAddress = "play.example.test"
    try? ConnectionStore.save(fresh, meta: meta, replacingUnreadable: true)
    check(FileManager.default.fileExists(atPath: meta.appendingPathComponent("connections.json.unreadable").path), "saving over it moves the old file aside first")
    equal(ConnectionStore.load(meta).settings, fresh, "and the new file reads back")

    let pasted = "made-up-secret-value-0000"
    let text = """
    {"playerAddress":"play.example.test","token":"\(pasted)","services":[
      {"id":"play","name":"Game tunnel","provider":"playit","traffic":"game","enabled":true,"localAddress":"127.0.0.1:25565","publicAddress":"play.example.test","secret":{"agent":{}}},
      {"id":"pack","provider":"playit","traffic":"web","localAddress":"127.0.0.1:8766","secret_key":"x","authKey":"\(pasted)"},
      {"id":"later","provider":"wireguard-someday","traffic":"teleport","enabled":true},
      {"id":"Bad Name","provider":"other","enabled":true},
      {"id":"play","provider":"other","enabled":true},
      {"name":"no id"},
      "not an object"
    ]}
    """
    loaded = ConnectionStore.parse(Data(text.utf8))
    equal(loaded.settings.services.map(\.id), ["play", "pack", "later"], "good entries load; a bad id, a repeated id and broken entries are skipped")
    equal(loaded.settings.services.first?.secret, .agent, "where a secret lives is read")
    equal(loaded.settings.services[1].enabled, false, "an entry that doesn't say it's on is off")
    equal(loaded.settings.services[2].provider, .other, "a provider this version doesn't know reads as Other")
    equal(loaded.settings.services[2].traffic, .access, "and unknown traffic as admin access, which is never pinged")
    check(loaded.problems.contains { $0.contains("token") && $0.contains("Keychain") }, "a secret pasted at the top is named as ignored")
    check(loaded.problems.contains { $0.contains("authKey") }, "and one pasted into a service")
    check(!loaded.problems.joined().contains(pasted), "the pasted value itself is never repeated")
    check(loaded.problems.count >= 6, "each skipped entry says why (\(loaded.problems.count) problems)")
    let saved = folder("connections-meta-2")
    try? ConnectionStore.save(loaded.settings, meta: saved, replacingUnreadable: false)
    let savedText = (try? String(contentsOf: ConnectionStore.file(saved), encoding: .utf8)) ?? ""
    check(!savedText.contains(pasted) && !savedText.contains("authKey") && !savedText.contains("\"token\""), "saving drops the pasted secrets")
    equal(ConnectionStore.load(saved).settings, loaded.settings, "and everything else reads back the same")

    // Reported on 2026-11-14: the README's own shape must not be flagged.
    let readmeShaped = ConnectionStore.parse(Data(#"{"playerAddress":"play.example.test","services":[{"id":"play","provider":"playit","traffic":"game","enabled":true,"localAddress":"127.0.0.1:25565","secret":{"agent":{}}},{"id":"api","provider":"other","traffic":"web","enabled":true,"secret":{"keychain":{"account":"api"}}},{"id":"f","provider":"other","traffic":"web","secret":{"file":{"path":"~/x"}}}]}"#.utf8))
    check(readmeShaped.problems.isEmpty, "the documented secret field, holding where a secret lives, isn't flagged (\(readmeShaped.problems))")
    let pastedIntoSecret = ConnectionStore.parse(Data(#"{"services":[{"id":"play","provider":"playit","secret":"made-up-pasted-value"}]}"#.utf8))
    check(pastedIntoSecret.problems.contains { $0.contains("secret") } && !pastedIntoSecret.problems.joined().contains("made-up-pasted-value"), "but a secret pasted straight into that field is named, without repeating it")
    check(pastedIntoSecret.settings.services.first?.id == "play" && pastedIntoSecret.settings.services.first?.secret == nil, "and isn't kept, while the rest of the entry is")

    section("Connections: addresses")
    equal(HostPort.parse("127.0.0.1:25565"), HostPort(host: "127.0.0.1", port: 25565), "host and port")
    equal(HostPort.parse("[::1]:8766"), HostPort(host: "::1", port: 8766), "IPv6 in brackets")
    equal(HostPort.parse("play.example.test", defaultPort: 25565)?.port, 25565, "a bare name takes the game's port")
    for bad in ["", "play.example.test", "host:0", "host:70000", "a b:1", "https://x:1", "::1:25565", "[::1", "host:port"] {
        check(HostPort.parse(bad) == nil, "refused: '\(bad)'")
    }
    check(HostPort.parse("100.93.1.2:25565")!.isTailscale && !HostPort.parse("100.200.1.2:1")!.isTailscale, "Tailscale's range is told apart")

    section("Connections: checks with made-up answers")
    let tool = "/made-up-home/Minecraft/_tools/playit/playit"
    let running = "playitd daemon status for socket /x:\n  Phase: running\n  PID: 4242\n  Version: 2.0.0\n  Secret configured: true\n"
    func playitProbe() -> FakeConnectionProbe {
        let p = FakeConnectionProbe()
        p.executables = [tool]
        p.tools[tool] = (0, running)
        p.gameAnswering = ["127.0.0.1:25565"]
        p.answering = ["127.0.0.1:8766"]
        return p
    }
    let ctx = ConnectionContext(serverRunning: true, serverIP: "127.0.0.1", serverPort: 25565, packHostPort: 8766)
    var play = ConnectionService(id: "play", name: "Game tunnel", provider: .playit, traffic: .game, localAddress: "127.0.0.1:25565", publicAddress: "play.example.test", secret: .agent)
    func run(_ s: ConnectionService, _ p: FakeConnectionProbe, _ c: ConnectionContext = ctx, outside: Bool = false) async -> ConnectionStatus {
        await ConnectionCheck.run(s, context: c, probe: p, outside: outside)
    }

    var p = playitProbe()
    var status = await run(play, p)
    equal(status.health, .ready, "a running agent with its secret, forwarding to a server that answers, is ready: \(status.summary)")
    check(!p.asked.contains { $0.hasPrefix("ping play.example.test") || $0.hasPrefix("http") }, "nothing goes over the internet unless asked")
    check(status.details.contains("Not tried from the internet yet."), "and it says so")

    var off = play; off.enabled = false
    p = playitProbe()
    let v1 = await run(off, p).health
    equal(v1, .off, "a connection that's off is shown off")
    check(p.asked.isEmpty, "and nothing about it is checked")

    p = playitProbe(); p.executables = []
    status = await run(play, p)
    equal(status.health, .notReady, "no playit agent installed: not ready")
    check(status.summary.contains("isn't installed"), "and says so: \(status.summary)")

    p = playitProbe(); p.tools[tool] = nil
    let v2 = await run(play, p).health
    equal(v2, .notReady, "an agent that won't answer: not ready")
    p = playitProbe(); p.tools[tool] = (0, "garbage")
    let v3 = await run(play, p).health
    equal(v3, .notReady, "an answer that can't be read: not ready")
    p = playitProbe(); p.tools[tool] = (0, running.replacingOccurrences(of: "Phase: running", with: "Phase: stopped"))
    let v4 = await run(play, p).health
    equal(v4, .notReady, "an agent that's stopped: not ready")
    p = playitProbe(); p.tools[tool] = (0, running.replacingOccurrences(of: "Secret configured: true", with: "Secret configured: false"))
    status = await run(play, p)
    equal(status.health, .notReady, "an agent with no secret: not ready, not a crash")
    check(status.summary.contains("no secret"), "and says what's missing: \(status.summary)")
    p = playitProbe(); p.tools[tool] = (0, running.replacingOccurrences(of: "  Secret configured: true\n", with: ""))
    let v5 = await run(play, p).health
    equal(v5, .unknown, "an agent that doesn't say: unknown, never ready")

    // The real case from 2026-11-10: the tunnel forwards to the Tailscale address, the server listens on 127.0.0.1 only.
    var viaTailscale = play; viaTailscale.localAddress = "100.64.10.20:25565"
    p = playitProbe()
    status = await run(viaTailscale, p)
    check(status.health == .notReady && status.summary.contains("127.0.0.1:25565"), "a tunnel pointing away from a server that only listens on 127.0.0.1 is flagged, with the fix: \(status.summary)")
    var wrongPort = play; wrongPort.localAddress = "127.0.0.1:25566"
    status = await run(wrongPort, playitProbe())
    check(status.health == .notReady && status.summary.contains("25566"), "a tunnel to the wrong port is flagged: \(status.summary)")
    status = await run(play, playitProbe(), ConnectionContext(serverRunning: true, serverIP: "", serverPort: 25565))
    equal(status.health, .ready, "a server listening everywhere is fine with 127.0.0.1")

    p = playitProbe(); p.gameAnswering = []
    status = await run(play, p)
    equal(status.health, .notReady, "a running server that doesn't answer where the tunnel points: not ready")
    p = playitProbe(); p.gameAnswering = []
    status = await run(play, p, ConnectionContext(serverRunning: false, serverIP: "127.0.0.1", serverPort: 25565))
    equal(status.health, .warning, "a stopped server is a warning, not a broken tunnel")

    let stamp = ISO8601DateFormatter(); stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func refusal(_ minutesAgo: Double, _ target: String = "127.0.0.1:25565") -> String {
        "\(stamp.string(from: Date().addingTimeInterval(-minutesAgo * 60))) ERROR playit_agent_core::network::lan_address: Failed to establish connection for flow (198.51.100.7:50030, \(target)) Os { code: 61, kind: ConnectionRefused, message: \"Connection refused\" }"
    }
    p = playitProbe(); p.tails["/made-up-home/Library/Logs/playit/playitd.log"] = [refusal(3), refusal(4), refusal(40), refusal(2, "127.0.0.1:8766")].joined(separator: "\n")
    status = await run(play, p)
    check(status.health == .warning && status.summary.contains("2 times"), "recent refusals in playit's log for this address are counted, older ones and other addresses aren't: \(status.summary)")

    // Secrets kept by LeafJuice: missing is not ready, never a crash; the value is never read.
    var keyed = ConnectionService(id: "status-api", name: "Status page", provider: .other, traffic: .web, publicAddress: "https://status.example.test", secret: .keychain(account: "status-api"))
    p = FakeConnectionProbe()
    status = await run(keyed, p)
    equal(status.health, .notReady, "a secret missing from the Keychain: not ready")
    check(status.summary.contains("Keychain"), "and it says where to put it: \(status.summary)")
    p = FakeConnectionProbe(); p.secrets["status-api"] = .unavailable("The Keychain is locked.")
    let v6 = await run(keyed, p).health
    equal(v6, .unknown, "a locked Keychain: unknown, not missing and not ready")
    p = FakeConnectionProbe(); p.secrets["status-api"] = .present
    let v7 = await run(keyed, p).health
    equal(v7, .ready, "with the secret there, ready")
    keyed.secret = .file(path: "~/Library/Application Support/madeup/agent.toml")
    let secretFile = "/made-up-home/Library/Application Support/madeup/agent.toml"
    p = FakeConnectionProbe()
    let v8 = await run(keyed, p).health
    equal(v8, .notReady, "a secret file that isn't there: not ready (~ is expanded)")
    p = FakeConnectionProbe(); p.files[secretFile] = (0, 0o600)
    let v9 = await run(keyed, p).health
    equal(v9, .notReady, "an empty secret file: not ready")
    p = FakeConnectionProbe(); p.files[secretFile] = (120, 0o644)
    let v10 = await run(keyed, p).health
    equal(v10, .warning, "a secret file others can read: flagged")
    p = FakeConnectionProbe(); p.files[secretFile] = (120, 0o600)
    let v11 = await run(keyed, p).health
    equal(v11, .ready, "a private one: fine")

    // Bad settings are reported, not run.
    var broken = play; broken.localAddress = "not an address"; broken.publicAddress = "https://wrong-kind.example.test"
    status = await run(broken, playitProbe())
    equal(status.health, .notReady, "addresses that can't be read: not ready")
    check(status.details.contains { $0.contains("local address") } && status.details.contains { $0.contains("public address") }, "each one is named")
    var noLocal = play; noLocal.localAddress = ""
    let v12 = await run(noLocal, playitProbe()).health
    equal(v12, .notReady, "a playit tunnel with nowhere to forward: not ready")

    // From outside, only when asked.
    p = playitProbe()
    status = await run(play, p, outside: true)
    check(p.asked.contains("ping play.example.test:25565"), "asked, it pings the public address as a player would")
    equal(status.health, .notReady, "and a public address that doesn't answer is not ready")
    p = playitProbe(); p.gameAnswering.insert("play.example.test:25565")
    let v13 = await run(play, p, outside: true).health
    equal(v13, .ready, "one that answers is ready")
    let packTunnel = ConnectionService(id: "pack", name: "Pack tunnel", provider: .playit, traffic: .web, localAddress: "127.0.0.1:8766", publicAddress: "https://pack.example.test:14248", secret: .agent)
    p = playitProbe(); p.web["https://pack.example.test:14248"] = 404
    status = await run(packTunnel, p, outside: true)
    equal(status.health, .ready, "any web answer proves the web tunnel reaches this Mac (pack serving answers strangers 404)")
    check(p.asked.contains("tcp 127.0.0.1:8766") && !p.asked.contains("ping 127.0.0.1:8766"), "web tunnels are checked with a plain connection, not a game ping")

    // A DNS name: looked up only when checking from outside.
    let name = ConnectionService(id: "dns", name: "Domain name", provider: .other, traffic: .dns, publicAddress: "example.test")
    p = FakeConnectionProbe()
    let dnsQuiet = await run(name, p)
    check(dnsQuiet.health == .ready && p.asked.isEmpty, "a name isn't looked up by the quiet check")
    p = FakeConnectionProbe()
    let dnsMissing = await run(name, p, outside: true)
    check(dnsMissing.health == .notReady && p.asked == ["dns example.test"], "from outside, a name that doesn't look up is not ready")
    p = FakeConnectionProbe(); p.names["example.test"] = ["192.0.2.10"]
    let dnsFound = await run(name, p, outside: true)
    equal(dnsFound.health, .ready, "and one that does is ready")
    let resolved = await SystemConnectionProbe().resolve("localhost")
    check(resolved?.contains("127.0.0.1") == true || resolved?.contains("::1") == true, "the real lookup finds localhost")

    // Tailscale.
    let ts = ConnectionService(id: "tailscale", name: "Tailscale", provider: .tailscale, traffic: .access)
    let tsTool = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    func tsProbe(_ json: String?) -> FakeConnectionProbe {
        let p = FakeConnectionProbe(); p.executables = [tsTool]
        if let json { p.tools[tsTool] = (0, json) }
        return p
    }
    let v14 = await run(ts, tsProbe(#"{"BackendState":"Running","Self":{"Online":true,"HostName":"made-up"},"TailscaleIPs":["100.64.0.9","fd7a::9"]}"#)).health
    equal(v14, .ready, "Tailscale running and online: ready")
    let v15 = await run(ts, tsProbe(#"{"BackendState":"Running","Self":{"Online":false},"TailscaleIPs":[]}"#)).health
    equal(v15, .warning, "running but offline: flagged")
    let v16 = await run(ts, tsProbe(#"{"BackendState":"NeedsLogin"}"#)).health
    equal(v16, .notReady, "logged out: not ready")
    let v17 = await run(ts, tsProbe(nil)).health
    equal(v17, .notReady, "no answer: not ready")
    let v18 = await run(ts, FakeConnectionProbe()).health
    equal(v18, .notReady, "not installed: not ready")
    status = await run(ts, tsProbe(#"{"BackendState":"Running","Self":{"Online":true,"DNSName":"made-up-mac.tail0000.ts.net."},"TailscaleIPs":["100.64.0.9"]}"#))
    check(!(status.summary + status.details.joined()).contains("made-up-mac"), "the tailnet's own name isn't repeated in the status")

    section("Connections: the map and sign-in page")
    let withURLs = ConnectionStore.parse(Data(#"{"playerAddress":"play.example.test","mapURL":"https://map.example.test","signInURL":"https://example.test/signin","services":[]}"#.utf8))
    equal(withURLs.settings.mapURL, "https://map.example.test", "the map address is read")
    equal(withURLs.settings.signInURL, "https://example.test/signin", "and the sign-in page")
    let urlMeta = folder("connections-urls")
    try? ConnectionStore.save(withURLs.settings, meta: urlMeta, replacingUnreadable: false)
    equal(ConnectionStore.load(urlMeta).settings, withURLs.settings, "both survive a save")
    equal(ConnectionStore.parse(Data(#"{"services":[]}"#.utf8)).settings.signInURL, "", "a file from before them still opens, with them unset")
    for bad in ["example.test", "ftp://example.test", "https://", "https:// example.test", "javascript:alert(1)"] {
        check(ConnectionCheck.playerURL(bad) == nil, "not a player address: '\(bad)'")
    }
    p = FakeConnectionProbe()
    let unset = await ConnectionCheck.runURL("", probe: p, outside: true)
    check(unset.health == .off && unset.summary == "Not set." && p.asked.isEmpty, "unset: says so, and nothing is asked")
    p = FakeConnectionProbe()
    let quiet = await ConnectionCheck.runURL("https://map.example.test", probe: p, outside: false)
    check(quiet.health == .unknown && p.asked.isEmpty, "the quiet check never fetches it")
    let notURL = await ConnectionCheck.runURL("map.example.test", probe: p, outside: true)
    equal(notURL.health, .notReady, "an address without https:// is not ready")
    let plainHTTP = await ConnectionCheck.runURL("http://map.example.test", probe: p, outside: false)
    check(plainHTTP.health == .warning && plainHTTP.summary.contains("https"), "plain http is flagged even before checking")
    for (code, health, label) in [(200, ConnectionHealth.ready, "a page"), (401, .ready, "a sign-in prompt"), (403, .ready, "a refusal to strangers"),
                                  (404, .warning, "not found"), (502, .notReady, "a proxy error"), (nil, .notReady, "no answer")] as [(Int?, ConnectionHealth, String)] {
        p = FakeConnectionProbe()
        if let code { p.web["https://map.example.test"] = code }
        let s = await ConnectionCheck.runURL("https://map.example.test", probe: p, outside: true)
        equal(s.health, health, "from outside, \(label) (\(code.map(String.init) ?? "none")) is \(health.title)")
    }
    p = FakeConnectionProbe(); p.web["http://map.example.test"] = 200
    equal((await ConnectionCheck.runURL("http://map.example.test", probe: p, outside: true)).health, .warning, "an http page that answers is still flagged")

    // Beside the invite code.
    let both = InviteAddress.choose(configured: "https://example.test/signin", latchkey: "https://example.test/signin")
    check(both.url == "https://example.test/signin" && both.note == nil, "the configured address is shown, with nothing to add when Latchkey agrees")
    let differ = InviteAddress.choose(configured: "https://example.test/signin", latchkey: "https://old.example.test")
    check(differ.url == "https://example.test/signin" && differ.note?.contains("old.example.test") == true, "when Latchkey disagrees, the configured one is shown and the other named")
    let fallback = InviteAddress.choose(configured: "", latchkey: "https://example.test/join")
    check(fallback.url == "https://example.test/join" && fallback.note != nil, "with none configured, Latchkey's is shown and said to be Latchkey's")
    let none = InviteAddress.choose(configured: " ", latchkey: nil)
    check(none.url == nil && none.note?.contains("only the code") == true, "with neither, the screen says so and still shows the code")

    section("Connections: the game's status ping, on real sockets")
    let request = [UInt8](MinecraftPing.request(host: "127.0.0.1", port: 25565))
    equal(request.last, 0x00, "the request ends with the status request")
    equal(Array(request.suffix(2)), [0x01, 0x00], "which is one byte long, id 0")
    let answer: [UInt8] = { let json = Array(#"{"version":{"name":"26.3","protocol":775},"description":"made up"}"#.utf8); let body = [0x00] + [UInt8(json.count)] + json; return [UInt8(body.count)] + body }()
    check(MinecraftPing.looksLikeStatus(Data(answer)), "a status answer is recognised")
    check(!MinecraftPing.looksLikeStatus(Data("HTTP/1.1 404 Not Found\r\n".utf8)), "a web answer isn't")
    check(!MinecraftPing.looksLikeStatus(Data()), "and nothing isn't")

    let real = SystemConnectionProbe()
    if let game = try? fakeListener(reply: Data(answer)), let web = try? fakeListener(reply: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8)) {
        let gp = Int(game.port!.rawValue), wp = Int(web.port!.rawValue)
        let v19 = await real.minecraftStatus(host: "127.0.0.1", port: gp, timeout: 3)
        check(v19, "a server that answers the ping is seen")
        let v20 = await real.minecraftStatus(host: "127.0.0.1", port: wp, timeout: 3)
        check(!v20, "something that accepts but isn't Minecraft isn't mistaken for it")
        let v21 = await real.tcp(host: "127.0.0.1", port: wp, timeout: 3)
        check(v21, "a plain connection is seen")
        game.cancel(); web.cancel()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let v22 = await real.tcp(host: "127.0.0.1", port: gp, timeout: 2)
        check(!v22, "a closed port isn't")
    } else {
        check(false, "couldn't open a listener on 127.0.0.1")
    }

    section("Connections: a real Keychain, with a made-up secret")
    // A throwaway keychain file, never the login Keychain (see the top of main.swift).
    let (path, _) = throwawayKeychain("connections")
    var kc: SecKeychain?
    guard SecKeychainOpen(path, &kc) == errSecSuccess, let kc else { check(false, "couldn't open the throwaway keychain"); return }
    let account = "made-up-service"
    equal(ConnectionSecrets.presence(account: account, in: kc), .missing, "a secret never saved is missing")
    do {
        try ConnectionSecrets.save("made-up-\(UUID().uuidString)", account: account, in: kc)
        equal(ConnectionSecrets.presence(account: account, in: kc), .present, "once saved it's there, found without reading it")
        try ConnectionSecrets.save("made-up-replacement", account: account, in: kc)
        equal(ConnectionSecrets.presence(account: account, in: kc), .present, "saving again replaces it")
        ConnectionSecrets.remove(account: account, in: kc)
        equal(ConnectionSecrets.presence(account: account, in: kc), .missing, "and removed it's gone")
    } catch {
        check(false, "the throwaway keychain refused a made-up secret: \(error.localizedDescription)")
    }
    check((try? ConnectionSecrets.save("", account: account, in: kc)) == nil, "an empty secret is refused")
    try? ConnectionSecrets.save("made-up-again", account: account, in: kc)
    runSecurity(["lock-keychain", path])
    check(ConnectionSecrets.presence(account: account, in: kc) != .missing, "a locked keychain isn't mistaken for a missing secret")
}

/// A listener on 127.0.0.1 that answers every connection with fixed bytes once it has read something.
func fakeListener(reply: Data) throws -> NWListener {
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: params)
    let queue = DispatchQueue(label: "leafjuice.fake-listener")
    listener.newConnectionHandler = { c in
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
            c.send(content: reply, completion: .contentProcessed { _ in c.cancel() })
        }
    }
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 3) == .success, listener.port != nil else { listener.cancel(); throw LeafError("no listener") }
    return listener
}
