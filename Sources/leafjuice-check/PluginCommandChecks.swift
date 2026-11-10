import Darwin
import Foundation
@testable import LeafJuiceCore

// The shared plugin command format, format 1. Everything is made up: a fake plugin in Swift for the
// runner, and a fake server in Java that prints format 1 for the whole path through the console.

private let head = "[12:00:00 INFO]: "

@MainActor func pluginCommandChecks() async {
    section("Plugin commands: the wire")
    wireChecks()
    section("Plugin commands: reading answers, and spoofs")
    answerLineChecks()
    section("Plugin commands: the runner")
    await runnerChecks()
    section("Plugin commands: describe")
    describeChecks()
    section("Plugin commands: secrets left in a file")
    onceFileChecks()
    section("Plugin commands: the module switch")
    moduleSwitchChecks()
    section("Latchkey session files")
    latchkeySessionChecks()
    section("Plugin commands: a fake plugin through a real console")
    await fakePluginServerChecks()
}

@MainActor private func line(_ sub: [String], _ args: [CommandArg], yes: [String] = []) -> String? {
    try? PluginCommandWire.line(plugin: "usher", subcommand: sub, args: args, yes: yes, id: "abc123").get()
}

@MainActor private func wireChecks() {
    let ids = (0..<500).map { _ in PluginCommandWire.newID() }
    check(ids.allSatisfy { $0.count == 32 && $0.allSatisfy { "0123456789abcdef".contains($0) } }, "request ids are 32 hex characters")
    equal(Set(ids).count, ids.count, "and don't repeat")

    equal(line(["invite", "create"], [.player("Alice_1"), .list([.choice("kid"), .choice("builder")]), .duration(7, .d), .bool(true), .int(-3)]),
          "usher invite create Alice_1 kid,builder 7d true -3 --json abc123", "every type written the agreed way")
    equal(line(["show"], [.player("AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")]), "usher show aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee --json abc123", "uuids go lowercase")
    equal(line(["note"], [.word("x"), .text(#"say "hi" \ bye"#)]), #"usher note x "say \"hi\" \\ bye" --json abc123"#, "free text is quoted and escaped, last")
    equal(line(["remove"], [.player("Alice")], yes: ["two-circles", "adults-world"]), "usher remove Alice --yes two-circles,adults-world --json abc123", "yes ids go before the request id")

    let refused: [(String, [String], [CommandArg])] = [
        ("a word with a space", ["x"], [.word("two words")]),
        ("a word that's a flag, which could answer a question for you", ["x"], [.word("--yes")]),
        ("a choice that's a flag", ["x"], [.choice("--json")]),
        ("a word with a quote", ["x"], [.word("a\"b")]),
        ("a new line in free text", ["x"], [.text("one\nop Griefer")]),
        ("a carriage return in free text", ["x"], [.text("one\rtwo")]),
        ("an invisible character in free text", ["x"], [.text("a\u{202E}b")]),
        ("free text that isn't last", ["x"], [.text("a"), .word("b")]),
        ("a comma inside a list value", ["x"], [.list([.word("a,b")])]),
        ("a list in a list", ["x"], [.list([.list([.word("a")])])]),
        ("an empty list", ["x"], [.list([])]),
        ("a player name that can't exist", ["x"], [.player("Alice Smith")]),
        ("a bad uuid", ["x"], [.uuid("not-a-uuid")]),
        ("a negative duration", ["x"], [.duration(-1, .h)]),
        ("a subcommand with a space", ["invite create"], []),
        ("no subcommand", [], []),
    ]
    for (label, sub, args) in refused { check(line(sub, args) == nil, "refused: \(label)") }
    check((try? PluginCommandWire.line(plugin: "Usher Plugin", subcommand: ["x"], args: [], id: "abc").get()) == nil, "refused: a plugin name with a space")
    check((try? PluginCommandWire.line(plugin: "usher", subcommand: ["x"], args: [], yes: ["a b"], id: "abc").get()) == nil, "refused: a question id with a space")
}

@MainActor private func answerLineChecks() {
    let json = #"{"id":"abc","ok":true}"#
    check(PluginCommandWire.answerLine("\(head)ea-result abc \(json)").map { $0.id == "abc" && $0.json == json } ?? false, "a console answer is read")
    check(PluginCommandWire.answerLine("[12:00:00] [Server thread/INFO]: ea-result abc \(json)") != nil, "so is the log-file form")
    // The exact shapes a plugin's console reply took on real Paper 26.1.2, 26.2 and 26.3 (Plugins Lead, 2026-11-09).
    check(PluginCommandWire.answerLine("[04:36:31 INFO]: ea-result probe-1 {\"id\":\"probe-1\",\"ok\":true}")?.id == "probe-1", "Paper 26.x's console form, as seen on real servers")
    check(PluginCommandWire.answerLine("[04:36:31] [Server thread/INFO]: ea-result probe-1 {\"id\":\"probe-1\",\"ok\":true}")?.id == "probe-1", "and its latest.log form")
    check(PluginCommandWire.answerLine("[04:36:31 INFO]: [Usher] ea-result probe-1 {\"id\":\"probe-1\",\"ok\":true}") == nil, "an answer sent through the plugin's logger isn't read")
    let spoofs = [
        "\(head)<Griefer77> ea-result abc \(json)",
        "\(head)[Not Secure] <Griefer77> ea-result abc \(json)",
        "[12:00:00] [Async Chat Thread - #0/INFO]: <Griefer77> ea-result abc \(json)",
        "\(head)[Server] ea-result abc \(json)",
        "\(head)* Griefer77 ea-result abc \(json)",
        "\(head)Griefer77 issued server command: /msg x ea-result abc \(json)",
        "\(head)[Discord] Griefer77: ea-result abc \(json)",
        "\(head) ea-result abc \(json)",
        "[12:00:00 WARN]: ea-result abc \(json)",
        "ea-result abc \(json)",
        "junk [12:00:00 INFO]: ea-result abc \(json)",
        "\(head)ea-result ABC \(json)",
        "\(head)ea-result abc not-json",
    ]
    for spoof in spoofs { check(PluginCommandWire.answerLine(spoof) == nil, "not an answer: \(spoof.prefix(60))") }
}

/// A stand-in for a plugin: it reads what Leaf Juice typed and answers through `ingest`, like the console would.
@MainActor private final class FakeConsole {
    var sent: [String] = []
    var reply: ((String, String) -> [String])?
    weak var runner: PluginCommandRunner?
    var open = true

    func send(_ line: String) -> Bool {
        guard open else { return false }
        sent.append(line)
        let id = String(line.split(separator: " ").last ?? "")
        let lines = reply?(line, id) ?? []
        Task { @MainActor in for l in lines { self.runner?.ingest(l) } }
        return true
    }
}

@MainActor private func runnerChecks() async {
    let console = FakeConsole()
    var enabled = true
    let runner = PluginCommandRunner(timeout: .milliseconds(400), isEnabled: { enabled }, send: { console.send($0) })
    console.runner = runner

    // A player types the answer's shape in chat with the right id, before the real one and after it.
    console.reply = { _, id in [
        "\(head)<Griefer77> ea-result \(id) {\"id\":\"\(id)\",\"ok\":false,\"error\":{\"code\":\"spoofed\",\"message\":\"chat\"}}",
        "\(head)ea-result \(id) {\"id\":\"\(id)\",\"ok\":true,\"pong\":true}",
        "\(head)ea-result \(id) {\"id\":\"\(id)\",\"ok\":false,\"error\":{\"code\":\"second\",\"message\":\"again\"}}",
    ] }
    let before = runner.ignored
    let ping = await runner.run("fakeplug", ["ping"])
    if case .done(let answer) = ping.outcome {
        struct Pong: Decodable { let pong: Bool }
        check((try? answer.decode(Pong.self).pong) == true, "the real answer is the one read, with its own fields")
    } else { check(false, "ping answered: \(ping.outcome)") }
    try? await Task.sleep(for: .milliseconds(50))
    equal(runner.ignored - before, 1, "a second answer to the same id is ignored (the chat spoof never looked like one)")
    check(console.sent.last?.hasSuffix("--json \(ping.id)") ?? false, "the id sent is the one answered")

    // An answer to an id nobody sent, and one replaying an id already answered.
    let ignoredBefore = runner.ignored
    check(!runner.ingest("\(head)ea-result \(PluginCommandWire.newID()) {\"ok\":true}"), "an answer to an unknown id is ignored")
    check(!runner.ingest("\(head)ea-result \(ping.id) {\"id\":\"\(ping.id)\",\"ok\":true}"), "a reused id is ignored")
    equal(runner.ignored - ignoredBefore, 2, "both counted as ignored")

    var seen: Set<String> = []
    console.reply = { _, id in seen.insert(id); return ["\(head)ea-result \(id) {\"id\":\"\(id)\",\"ok\":true}"] }
    for _ in 0..<20 { _ = await runner.run("fakeplug", ["ping"]) }
    equal(seen.count, 20, "every request gets a new id")

    // Answers that can't be used.
    console.reply = { _, id in ["\(head)ea-result \(id) {\"id\":\"someone-else\",\"ok\":true}"] }
    if case .failed(let e) = await runner.run("fakeplug", ["ping"]).outcome { equal(e.code, CommandError.badAnswer, "an answer naming another id inside is refused") } else { check(false, "mismatched id refused") }
    console.reply = { _, id in ["\(head)ea-result \(id) {\"id\":\"\(id)\",\"ok\":true,\"items\":[\"\(String(repeating: "x", count: 9000))\"]}"] }
    if case .failed(let e) = await runner.run("fakeplug", ["list"]).outcome { equal(e.code, CommandError.tooLong, "an answer over 8 KB is refused") } else { check(false, "long answer refused") }
    console.reply = { _, id in ["\(head)ea-result \(id) {\"id\":\"\(id)\",\"ok\":false}"] }
    if case .failed(let e) = await runner.run("fakeplug", ["ping"]).outcome { equal(e.code, CommandError.badAnswer, "a refusal with no reason is refused") } else { check(false, "empty refusal") }

    // Errors keep the plugin's words, and fill in only when there are none.
    console.reply = { _, id in ["\(head)ea-result \(id) {\"id\":\"\(id)\",\"ok\":false,\"error\":{\"code\":\"not-found\",\"message\":\"No invite for Alice.\"}}"] }
    if case .failed(let e) = await runner.run("fakeplug", ["revoke"]).outcome { check(e.code == "not-found" && e.plainMessage == "No invite for Alice.", "an error keeps its code and the plugin's words") } else { check(false, "error answered") }
    check(CommandError.baseCodes.allSatisfy { !CommandError(code: $0, message: "").plainMessage.isEmpty }, "every base code has plain words when the plugin gives none")

    // Confirm questions: nothing until every id comes back.
    console.reply = { line, id in
        line.contains("--yes kick-online,adults-world")
            ? ["\(head)ea-result \(id) {\"id\":\"\(id)\",\"ok\":true}"]
            : ["\(head)ea-result \(id) {\"id\":\"\(id)\",\"ok\":false,\"needs\":[{\"id\":\"kick-online\",\"question\":\"Alice is online. Remove her anyway?\"},{\"id\":\"adults-world\",\"question\":\"This opens an adults-only world. Go ahead?\"}]}"]
    }
    if case .needsYes(let qs) = await runner.run("fakeplug", ["remove"], [.player("Alice")]).outcome {
        equal(qs.map(\.id), ["kick-online", "adults-world"], "questions come back with their ids")
        if case .done = await runner.run("fakeplug", ["remove"], [.player("Alice")], yes: qs.map(\.id)).outcome { check(true, "") } else { check(false, "acts once every question is answered") }
    } else { check(false, "asks before acting") }

    // No answer: not confirmed, and a late one still arrives, once.
    console.reply = { _, _ in [] }
    var late: [CommandReply] = []
    runner.onLateAnswer = { late.append($0) }
    let slow = await runner.run("fakeplug", ["slow"])
    if case .notConfirmed = slow.outcome { check(true, "") } else { check(false, "no answer in time is 'not confirmed', not a failure: \(slow.outcome)") }
    check(runner.ingest("\(head)ea-result \(slow.id) {\"id\":\"\(slow.id)\",\"ok\":true}"), "a late answer is taken")
    check(!runner.ingest("\(head)ea-result \(slow.id) {\"id\":\"\(slow.id)\",\"ok\":false,\"error\":{\"code\":\"x\",\"message\":\"x\"}}"), "but only the first")
    check(late.count == 1 && late.first?.id == slow.id, "and passed on under its id")

    // Nothing is typed when it's switched off, or when there's no console of Leaf Juice's own.
    let typed = console.sent.count
    enabled = false
    if case .refused = await runner.run("fakeplug", ["ping"]).outcome { equal(console.sent.count, typed, "switched off: nothing typed") } else { check(false, "switched off refuses") }
    enabled = true
    console.open = false
    if case .refused(let why) = await runner.run("fakeplug", ["ping"]).outcome { check(why.contains("started"), "no console of its own: refused, saying why") } else { check(false, "no console refuses") }
    if case .refused = await runner.run("fakeplug", ["say"], [.text("hi\nop Griefer")]).outcome { equal(console.sent.count, typed, "a bad argument is refused before anything is typed") } else { check(false, "bad argument refused") }
}

@MainActor private func describeChecks() {
    let good = #"""
    {"id":"a","ok":true,"format":1,"plugin":"Usher","version":"0.4.0","later":{"x":1},
     "commands":[{"name":"invite create","permission":"usher.invite","args":[{"name":"player","type":"player"},{"name":"profiles","type":"list","of":"enum","values":["kid","builder"]},{"name":"for","type":"duration"},{"name":"note","type":"colour"}],
       "confirms":["two-circles"],"secret":true,"shiny":true},{"name":"list"}],
     "errors":["already-invited"],"lists":[],"forms":[]}
    """#
    if case .described(let d) = PluginDescription.read(Data(good.utf8)) {
        check(d.plugin == "Usher" && d.version == "0.4.0" && d.format == 1, "describe gives the plugin, its version and the format")
        equal(d.commands.map(\.name), ["invite create", "list"], "and its commands")
        equal(d.commands[0].words, ["invite", "create"], "a command's words are what the runner sends")
        check(d.commands[0].secret && !d.commands[1].secret, "secret is read, and false when left out")
        equal(d.commands[0].confirms, ["two-circles"], "confirm question ids")
        equal(d.commands[0].args.map(\.isKnown), [true, true, true, false], "a type Leaf Juice doesn't know is marked, not guessed")
        equal(d.commands[0].args[1].values ?? [], ["kid", "builder"], "a list of choices keeps its values")
        equal(d.errors, ["already-invited"], "the plugin's own error codes")
    } else { check(false, "describe read") }
    let optionals = #"{"format":1,"plugin":"Usher","version":"0.4.0","commands":[{"name":"apply","args":[{"name":"uuid","type":"uuid"},{"name":"whitelist","type":"bool","optional":true},{"name":"via","type":"string","optional":true}]}]}"#
    if case .described(let d) = PluginDescription.read(Data(optionals.utf8)) {
        equal(d.commands[0].args.map(\.optional), [false, true, true], "optional arguments are marked, and required ones carry no key")
    } else { check(false, "optional arguments read") }
    let misordered = #"{"format":1,"plugin":"Usher","version":"0.4.0","commands":[{"name":"apply","args":[{"name":"via","type":"string","optional":true},{"name":"uuid","type":"uuid"}]}]}"#
    if case .unreadable = PluginDescription.read(Data(misordered.utf8)) { check(true, "") } else { check(false, "a required argument after an optional one is refused") }
    if case .newerFormat(2) = PluginDescription.read(Data(#"{"format":2,"plugin":"Usher","version":"9","commands":"changed shape"}"#.utf8)) { check(true, "") } else { check(false, "a newer format is refused, not half-read") }
    for (label, json) in [("no format", #"{"plugin":"Usher","version":"1"}"#), ("format 0", #"{"format":0,"plugin":"Usher","version":"1"}"#),
                          ("a plugin name that's a path", #"{"format":1,"plugin":"../Latchkey","version":"1"}"#), ("not JSON", "nope")] {
        if case .unreadable = PluginDescription.read(Data(json.utf8)) { check(true, "") } else { check(false, "unreadable: \(label)") }
    }
}

@MainActor private func onceFileChecks() {
    let root = folder("once-files")
    let plugins = root.appendingPathComponent("plugins", isDirectory: true)
    let once = plugins.appendingPathComponent("Latchkey/once", isDirectory: true)
    try? FileManager.default.createDirectory(at: once, withIntermediateDirectories: true)
    chmod(once.path, 0o700)
    let future = Date().timeIntervalSince1970 + 3600
    func plant(_ id: String, value: String = "MADEUP-CODE-1234", fileID: String? = nil, expires: Double? = nil, mode: mode_t = 0o600) -> URL {
        let url = once.appendingPathComponent("\(id).json")
        let exp = expires.map { String(Int($0)) } ?? "null"
        try? Data("{\"id\":\"\(fileID ?? id)\",\"kind\":\"invite-code\",\"value\":\"\(value)\",\"expires\":\(exp),\"later\":1}".utf8).write(to: url)
        chmod(url.path, mode)
        return url
    }
    func take(_ id: String, file: String? = nil, plugin: String = "Latchkey") -> Result<OnceSecrets.Secret, OnceSecrets.Problem> {
        OnceSecrets.take(serverRoot: root, plugin: plugin, requestID: id, secretFile: file ?? "once/\(id).json")
    }
    let exists = { (u: URL) in FileManager.default.fileExists(atPath: u.path) }

    let a = PluginCommandWire.newID(), aURL = plant(a, expires: future)
    if case .success(let s) = take(a) {
        check(s.value == "MADEUP-CODE-1234" && s.kind == "invite-code" && s.expires != nil, "the secret is read")
    } else { check(false, "secret read") }
    check(!exists(aURL), "and its file deleted")
    equal(take(a).failureValue, .missing, "so it can be read only once")

    let b = PluginCommandWire.newID(), bURL = plant(b, mode: 0o644)
    equal(take(b).failureValue, .notPrivate, "a file others could read isn't shown")
    check(!exists(bURL), "but is still deleted")

    let c = PluginCommandWire.newID(), cURL = plant(c, fileID: "someone-else")
    equal(take(c).failureValue, .wrongRequest, "a file for another request isn't shown")
    check(!exists(cURL), "and is deleted")

    let d = PluginCommandWire.newID(), dURL = plant(d, expires: Date().timeIntervalSince1970 - 5)
    equal(take(d).failureValue, .expired, "an expired secret isn't shown")
    check(!exists(dURL), "and is deleted")

    let e = PluginCommandWire.newID(), eURL = plant(e)
    if case .success(let s) = take(e) { check(s.expires == nil, "a secret that doesn't expire") } else { check(false, "no expiry is fine") }
    check(!exists(eURL), "deleted too")

    // Paths Leaf Juice won't follow.
    let elsewhere = folder("once-elsewhere").appendingPathComponent("target.json")
    write("{\"id\":\"x\",\"kind\":\"k\",\"value\":\"keep me\",\"expires\":null}", elsewhere)
    chmod(elsewhere.path, 0o600)
    let f = PluginCommandWire.newID()
    try? FileManager.default.createSymbolicLink(at: once.appendingPathComponent("\(f).json"), withDestinationURL: elsewhere)
    equal(take(f).failureValue, .badPath, "a link to another file isn't followed")
    check(exists(elsewhere), "and what it pointed at is left alone")
    let g = PluginCommandWire.newID(); _ = plant(g)
    equal(take(g, file: "once/../../../x.json").failureValue, .badPath, "an answer naming another path is refused")
    equal(take(g, file: "once/\(PluginCommandWire.newID()).json").failureValue, .badPath, "so is one naming another request's file")
    equal(take(g, plugin: "../Latchkey").failureValue, .badPath, "and a plugin name that's a path")
    equal(take("../\(g)").failureValue, .badPath, "and a request id that's a path")
    check(take(g).isSuccess, "the right file is still read after all that")

    // The plugin's folder is a link somewhere else.
    let linked = folder("once-linked-root")
    try? FileManager.default.createDirectory(at: linked.appendingPathComponent("plugins"), withIntermediateDirectories: true)
    try? FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("plugins/Latchkey"), withDestinationURL: plugins.appendingPathComponent("Latchkey"))
    let h = PluginCommandWire.newID(); let hURL = plant(h)
    equal(OnceSecrets.take(serverRoot: linked, plugin: "Latchkey", requestID: h, secretFile: "once/\(h).json").failureValue, .badPath, "a plugin folder that's a link elsewhere isn't read")
    check(exists(hURL), "and nothing is deleted through it")

    // The folder others can read.
    chmod(once.path, 0o755)
    let i = PluginCommandWire.newID(), iURL = plant(i)
    equal(take(i).failureValue, .notPrivate, "a once folder others can look in isn't trusted")
    check(!exists(iURL), "and the file is deleted")
    chmod(once.path, 0o700)
}

@MainActor private func moduleSwitchChecks() {
    let store = Modules.shared
    let modulesFile = AppPaths.home.appendingPathComponent("modules.json")
    let saved = try? Data(contentsOf: modulesFile)
    defer { if let saved { try? saved.write(to: modulesFile) } else { try? FileManager.default.removeItem(at: modulesFile) }; store.reload() }
    try? FileManager.default.removeItem(at: modulesFile)
    store.reload()
    check(LeafModule.pluginCommands.startsOff && !store.isOn(.pluginCommands), "plugin commands start off on a fresh install")
    store.set(.pluginCommands, on: true)
    store.reload()
    check(store.isOn(.pluginCommands), "turned on, it stays on")
    store.set(.pluginCommands, on: false)
    check(!store.isOn(.pluginCommands), "and off again")
}

/// A Java program that talks like a server with a format-1 plugin, through Leaf Juice's real console.
@MainActor private func fakePluginServerChecks() async {
    let runtimes = await JavaManager.discover()
    guard let jdk = runtimes.first(where: { FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: $0.path).deletingLastPathComponent().appendingPathComponent("javac").path) }) else {
        print("  skipped: no JDK found")
        return
    }
    let store = Modules.shared
    let modulesFile = AppPaths.home.appendingPathComponent("modules.json")
    let saved = try? Data(contentsOf: modulesFile)
    defer { if let saved { try? saved.write(to: modulesFile) } else { try? FileManager.default.removeItem(at: modulesFile) }; store.reload() }
    do {
        let root = folder("fake-format1-server")
        try await buildFakeFormatOne(jdk: jdk, into: root.appendingPathComponent("fake.jar"))
        write("server-port=25596\nmotd=fake\nlevel-name=world\n", root.appendingPathComponent("server.properties"))
        write("{}", root.appendingPathComponent("bukkit.yml"))
        let c = try await ServerController.adopt(root: root, name: "Fake format 1")
        c.requiresEULA = false
        c.profile.software.flavor = .custom
        c.profile.software.jarName = "fake.jar"
        c.profile.software.mcVersion = "26.3"
        c.profile.software.requiredJava = jdk.major
        c.profile.launch.javaPath = jdk.path
        c.profile.launch.preset = .none
        c.profile.launch.restartOnCrash = false
        c.profile.launch.maxMemoryMB = 512
        c.profile.launch.minMemoryMB = 256
        c.profile.backup.enabled = false
        c.profile.lastPluginCheck = Date()
        c.profile.software.lastCheck = Date()
        c.commands.timeout = .seconds(5)

        store.set(.pluginCommands, on: true)
        if case .refused = await c.commands.run("fakeplug", ["ping"]).outcome { check(true, "") } else { check(false, "a stopped server gets nothing typed") }

        await c.start()
        await checkUntil(30, "the fake server runs (last: \(c.console.suffix(3).map(\.text)))") { c.state == .running }

        let ping = await c.commands.run("fakeplug", ["ping"])
        if case .done = ping.outcome { check(true, "") } else { check(false, "through the console, the real answer is read: \(ping.outcome)") }
        check(c.console.contains { $0.text.contains("<Griefer77> ea-result \(ping.id)") }, "even though a player sent a fake one first, with the same id")
        try? await Task.sleep(for: .milliseconds(400))
        check(c.commands.ignored >= 1, "and a second answer came after, and was ignored")

        let said = await c.commands.run("fakeplug", ["say"], [.text(#"quote " and back \ slash"#)])
        if case .done(let a) = said.outcome {
            struct Raw: Decodable { let text: String }
            equal((try? a.decode(Raw.self))?.text, #"quote " and back \ slash"#, "free text survives the console, quotes and all")
        } else { check(false, "say answered: \(said.outcome)") }

        if case .described(let d) = await c.commands.describe("fakeplug") {
            check(d.plugin == "FakePlug" && d.commands.contains { $0.name == "invite create" && $0.secret }, "describe comes through the console")
        } else { check(false, "describe through the console") }

        let invite = await c.commands.run("fakeplug", ["invite", "create"], [.player("Alice")])
        if case .done(let a) = invite.outcome, let file = a.secretFile {
            let logged = c.console.map(\.text).joined(separator: "\n")
            check(!logged.contains("FAKE-INVITE"), "the invite code never reaches the console")
            if case .success(let secret) = OnceSecrets.take(serverRoot: root, plugin: "FakePlug", requestID: invite.id, secretFile: file) {
                equal(secret.value, "FAKE-INVITE-\(invite.id.prefix(6))", "it's read from the plugin's file")
            } else { check(false, "the once-file is read") }
            check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("plugins/FakePlug/once/\(invite.id).json").path), "and the file is gone")
        } else { check(false, "invite answered with a file: \(invite.outcome)") }

        let quiet = await c.commands.run("fakeplug", ["slow"])
        if case .notConfirmed = quiet.outcome { check(true, "") } else { check(false, "a plugin that never answers is 'not confirmed': \(quiet.outcome)") }

        await usherThroughFake(c, root: root)
        await latchkeyThroughFake(c, root: root)

        store.set(.pluginCommands, on: false)
        let typed = c.console.count
        if case .refused = await c.commands.run("fakeplug", ["ping"]).outcome { equal(c.console.count, typed, "switched off: nothing typed into a running server") } else { check(false, "switched off refuses") }

        c.stop()
        await checkUntil(20, "the fake server stops") { c.state == .stopped }
    } catch { failures.append("fake format 1 server: \(error)") }
}

private func buildFakeFormatOne(jdk: JavaRuntime, into jar: URL) async throws {
    let source = #"""
    import java.io.*; import java.net.*; import java.nio.file.*; import java.nio.file.attribute.*; import java.util.*;
    public class FakeFormatOne {
      static void log(String text) { System.out.println("[12:00:00 INFO]: " + text); System.out.flush(); }
      static String esc(String s) {
        StringBuilder b = new StringBuilder();
        for (char ch : s.toCharArray()) {
          if (ch == '"' || ch == '\\') b.append('\\').append(ch);
          else if (ch < 0x20 || ch > 0x7e) b.append(String.format("\\u%04x", (int) ch));
          else b.append(ch);
        }
        return b.toString();
      }
      static void answer(String id, String rest) { log("ea-result " + id + " {\"id\":\"" + id + "\"," + rest + "}"); }
      static java.util.Set<String> has = new java.util.TreeSet<>();
      static boolean listed = false;
      static void usher(String body, String id, String line) throws Exception {
        Files.writeString(Path.of("usher-commands.txt"), line + "\n", StandardOpenOption.CREATE, StandardOpenOption.APPEND);
        String uuid = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
        if (body.equals("describe")) {
          String cmds = new File("usher-old").exists() ? "[{\"name\":\"profiles\"},{\"name\":\"show\"}]"
            : "[{\"name\":\"profiles\"},{\"name\":\"show\",\"args\":[{\"name\":\"player\",\"type\":\"player\"}]},{\"name\":\"apply\",\"args\":[{\"name\":\"uuid\",\"type\":\"uuid\"},{\"name\":\"name\",\"type\":\"player\"},{\"name\":\"add\",\"type\":\"list\",\"of\":\"string\"},{\"name\":\"remove\",\"type\":\"list\",\"of\":\"string\"},{\"name\":\"whitelist\",\"type\":\"bool\",\"optional\":true},{\"name\":\"via\",\"type\":\"string\",\"optional\":true}],\"confirms\":[\"bridge\"]},{\"name\":\"attempts\",\"args\":[{\"name\":\"limit\",\"type\":\"int\",\"optional\":true}]}]";
          int format = new File("usher-format-2").exists() ? 2 : 1;
          answer(id, "\"ok\":true,\"format\":" + format + ",\"plugin\":\"Usher\",\"version\":\"0.4.0\",\"commands\":" + cmds);
        } else if (body.equals("profiles")) {
          answer(id, "\"ok\":true,\"luckperms\":true,\"problems\":[\"Profile builders is left out: made up.\"],\"profiles\":[{\"id\":\"young\",\"label\":\"Young explorers\",\"group\":\"young\",\"toggle\":false,\"circle\":\"young\",\"worlds\":[\"young_build\"],\"description\":[\"Made-up young worlds.\"]},{\"id\":\"grown\",\"label\":\"Grown-ups\",\"group\":\"grown\",\"circle\":\"grown\",\"worlds\":[]}]");
        } else if (body.startsWith("show ")) {
          answer(id, "\"ok\":true,\"uuid\":\"" + uuid + "\",\"whitelisted\":" + listed + ",\"profiles\":[" + String.join(",", has.stream().map(x -> "\"" + x + "\"").toList()) + "],\"throughOtherGroups\":[],\"circles\":[]");
        } else if (body.startsWith("apply ")) {
          String[] p = body.split(" ");
          boolean bridge = !p[3].equals("none") && p[3].contains("grown") && (has.contains("young") || p[3].contains("young"));
          if (bridge && !line.contains("--yes bridge")) {
            answer(id, "\"ok\":false,\"needs\":[{\"id\":\"bridge\",\"question\":\"This puts them in two chat circles. Go ahead?\"}]");
            return;
          }
          if (!p[3].equals("none")) has.addAll(Arrays.asList(p[3].split(",")));
          if (!p[4].equals("none")) has.removeAll(Arrays.asList(p[4].split(",")));
          listed = true;
          answer(id, "\"ok\":true,\"status\":\"ok\",\"code\":\"applied\",\"message\":\"" + p[2] + " is approved and can join now.\"");
        } else if (body.startsWith("attempts")) {
          answer(id, "\"ok\":true,\"attempts\":[{\"uuid\":\"" + uuid + "\",\"name\":\"MadeUpKid\",\"attempts\":3,\"first\":1,\"last\":2}],\"next\":20");
        } else {
          answer(id, "\"ok\":false,\"error\":{\"code\":\"unknown-command\",\"message\":\"\"}");
        }
      }
      static java.util.List<String> invites = new java.util.ArrayList<>();
      static String invite(String id, String name, String profiles, String status) {
        return "{\"invite\":\"" + id + "\",\"uuid\":\"AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE\",\"name\":\"" + name + "\",\"profiles\":[" + profiles + "],\"confirmed\":[],\"status\":\"" + status + "\",\"created\":1800000000,\"expires\":4000000000}";
      }
      static void latchkey(String body, String id, String line) throws Exception {
        Files.writeString(Path.of("latchkey-commands.txt"), line + "\n", StandardOpenOption.CREATE, StandardOpenOption.APPEND);
        if (body.equals("describe")) {
          answer(id, "\"ok\":true,\"format\":1,\"plugin\":\"Latchkey\",\"version\":\"" + (new File("latchkey-v3").exists() ? "0.3.0" : "0.2.0") + "\",\"commands\":[{\"name\":\"invite create\",\"secret\":true},{\"name\":\"invite list\"},{\"name\":\"invite revoke\"},{\"name\":\"status\"}]");
        } else if (body.equals("status")) {
          boolean closed = new File("latchkey-closed").exists();
          answer(id, "\"ok\":true,\"landing\":true,\"redemption\":" + !closed + ",\"signIn\":true,\"whitelist\":true,\"publicUrl\":\"https://play.example.test\"," + (new File("latchkey-v3").exists() ? "\"lobby\":true," : "") + "\"problems\":[" + (closed ? "\"online-mode is off, so invites are off.\"" : "") + "]");
        } else if (body.startsWith("invite create ")) {
          String[] p = body.split(" ");
          if (p[3].contains("grown") && !line.contains("--yes bridge")) {
            answer(id, "\"ok\":false,\"needs\":[{\"id\":\"bridge\",\"question\":\"This puts them in two chat circles. Go ahead?\"}]");
            return;
          }
          String profiles = p[3].equals("none") ? "" : "\"" + String.join("\",\"", p[3].split(",")) + "\"";
          String inviteId = String.format("%08x", invites.size() + 0x1a2b3c4d);
          invites.add(invite(inviteId, p[2], profiles, "pending"));
          Path dir = Path.of("plugins/Latchkey/once");
          Files.createDirectories(dir);
          Files.setPosixFilePermissions(dir, PosixFilePermissions.fromString("rwx------"));
          Path tmp = Files.createTempFile(dir, "w", ".tmp", PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")));
          Files.writeString(tmp, "{\"id\":\"" + id + "\",\"kind\":\"invite-code\",\"value\":\"QW3RTY\",\"expires\":4000000000}");
          Files.move(tmp, dir.resolve(id + ".json"), StandardCopyOption.ATOMIC_MOVE);
          String fields = invites.get(invites.size() - 1);
          answer(id, "\"ok\":true,\"secretFile\":\"once/" + id + ".json\"," + fields.substring(1, fields.length() - 1));
        } else if (body.startsWith("invite list")) {
          if (!new File("latchkey-v3").exists()) { answer(id, "\"ok\":true,\"invites\":[" + String.join(",", invites) + "],\"next\":null"); return; }
          // 0.3.0: the spec's paging, items and a string cursor. latchkey-bad-cursor hands out one Leaf Juice must not type.
          String[] a = body.split(" ");
          int limit = a.length > 2 ? Integer.parseInt(a[2]) : 20, from = a.length > 3 ? Integer.parseInt(a[3]) : 0;
          int to = Math.min(from + limit, invites.size());
          String next = to < invites.size() ? (new File("latchkey-bad-cursor").exists() ? "\"--yes\"" : "\"" + to + "\"") : "null";
          answer(id, "\"ok\":true,\"items\":[" + String.join(",", invites.subList(from, to)) + "],\"next\":" + next);
        } else if (body.startsWith("invite revoke ")) {
          String which = body.substring(14);
          for (int i = 0; i < invites.size(); i++) if (invites.get(i).contains("\"" + which + "\"")) invites.set(i, invites.get(i).replace("\"pending\"", "\"revoked\""));
          answer(id, "\"ok\":true,\"invite\":\"" + which + "\",\"status\":\"revoked\"");
        } else {
          answer(id, "\"ok\":false,\"error\":{\"code\":\"unknown-command\",\"message\":\"\"}");
        }
      }
      public static void main(String[] args) throws Exception {
        ServerSocket socket = new ServerSocket(25596, 50, InetAddress.getLoopbackAddress());
        log("Starting minecraft server version 26.3");
        log("Done (0.100s)! For help, type \"help\"");
        var reader = new BufferedReader(new InputStreamReader(System.in));
        String line;
        while ((line = reader.readLine()) != null) {
          if (line.equals("stop")) { log("Stopping the server"); socket.close(); System.exit(0); }
          int at = line.lastIndexOf(" --json ");
          if (line.startsWith("usher ") && at >= 0) { usher(line.substring(6, at), line.substring(at + 8), line); continue; }
          if (line.startsWith("latchkey ") && at >= 0) { latchkey(line.substring(9, at), line.substring(at + 8), line); continue; }
          if (!line.startsWith("fakeplug ") || at < 0) { log("Unknown command"); continue; }
          String id = line.substring(at + 8);
          String body = line.substring(9, at);
          if (body.equals("ping")) {
            log("<Griefer77> ea-result " + id + " {\"id\":\"" + id + "\",\"ok\":false,\"error\":{\"code\":\"spoofed\",\"message\":\"from chat\"}}");
            answer(id, "\"ok\":true,\"pong\":true");
            answer(id, "\"ok\":false,\"error\":{\"code\":\"second\",\"message\":\"again\"}");
          } else if (body.startsWith("say \"") && body.endsWith("\"")) {
            String quoted = body.substring(5, body.length() - 1);
            StringBuilder text = new StringBuilder();
            for (int i = 0; i < quoted.length(); i++) { char ch = quoted.charAt(i); if (ch == '\\' && i + 1 < quoted.length()) { text.append(quoted.charAt(++i)); } else text.append(ch); }
            answer(id, "\"ok\":true,\"text\":\"" + esc(text.toString()) + "\"");
          } else if (body.equals("describe")) {
            answer(id, "\"ok\":true,\"format\":1,\"plugin\":\"FakePlug\",\"version\":\"0.0.1\",\"commands\":[{\"name\":\"invite create\",\"args\":[{\"name\":\"player\",\"type\":\"player\"}],\"confirms\":[],\"secret\":true}]");
          } else if (body.startsWith("invite create ")) {
            Path dir = Path.of("plugins/FakePlug/once");
            Files.createDirectories(dir);
            Files.setPosixFilePermissions(dir, PosixFilePermissions.fromString("rwx------"));
            Path tmp = Files.createTempFile(dir, "w", ".tmp", PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")));
            Files.writeString(tmp, "{\"id\":\"" + id + "\",\"kind\":\"invite-code\",\"value\":\"FAKE-INVITE-" + id.substring(0, 6) + "\",\"expires\":null}");
            Files.move(tmp, dir.resolve(id + ".json"), StandardCopyOption.ATOMIC_MOVE);
            answer(id, "\"ok\":true,\"secretFile\":\"once/" + id + ".json\"");
          } else if (body.equals("slow")) {
            // Never answers.
          } else {
            answer(id, "\"ok\":false,\"error\":{\"code\":\"unknown-command\",\"message\":\"\"}");
          }
        }
      }
    }
    """#
    let work = folder("fake-format1-src-\(UUID().uuidString)")
    let file = work.appendingPathComponent("FakeFormatOne.java")
    write(source, file)
    let bin = URL(fileURLWithPath: jdk.path).deletingLastPathComponent()
    let compile = try await Tool.run(bin.appendingPathComponent("javac").path, ["-d", work.path, file.path])
    guard compile.ok else { throw LeafError("javac: \(compile.err)") }
    let pack = try await Tool.run(bin.appendingPathComponent("jar").path, ["cfe", jar.path, "FakeFormatOne", "-C", work.path, "FakeFormatOne.class"])
    guard pack.ok else { throw LeafError("jar: \(pack.err)") }
}

extension Result {
    var failureValue: Failure? { if case .failure(let f) = self { f } else { nil } }
    var isSuccess: Bool { if case .success = self { true } else { false } }
}

/// Real Paper with a real Usher jar (given on the command line) on a throwaway server on 127.0.0.1:
/// its describe, a list, a refusal and an unknown command, all through Leaf Juice's console.
@MainActor func runRealUsher(jar: URL, dump: URL?) async {
    section("REAL USHER THROUGH PLUGIN COMMANDS (EULA accepted by the person running this)")
    do {
        let root = folder("real-usher")
        write("server-port=25592\nserver-ip=127.0.0.1\nonline-mode=false\nwhite-list=false\nview-distance=4\nsimulation-distance=4\nlevel-type=minecraft\\:flat\n", root.appendingPathComponent("server.properties"))
        let c = try await ServerController.adopt(root: root, name: "real-usher")
        try EULA.accept(c.paths)
        try await c.installSoftware(try await SoftwareCatalog.latestBuild(.paper, mc: realMC)!)
        try FileOps.ensureDir(root.appendingPathComponent("plugins"))
        try FileManager.default.copyItem(at: jar, to: root.appendingPathComponent("plugins/\(jar.lastPathComponent)"))
        let withLuckPerms = CommandLine.arguments.contains("--with-luckperms")
        if withLuckPerms { try await c.addPlugin(source: .modrinth(project: "luckperms", allowBeta: false)) }
        c.profile.lastPluginCheck = Date(); c.profile.software.lastCheck = Date()
        c.profile.backup.enabled = false
        c.profile.launch.restartOnCrash = false
        defer { c.forceStop(); c.stopTicker() }
        Modules.shared.set(.pluginCommands, on: true)
        defer { Modules.shared.set(.pluginCommands, on: false) }

        await c.start()
        await checkUntil(240, "Paper \(realMC) with Usher runs (last: \(c.console.suffix(3).map(\.text)))") { c.state == .running }

        switch await c.commands.describe("usher") {
        case .described(let d):
            print("  describe: \(d.plugin) \(d.version), format \(d.format)")
            for cmd in d.commands {
                print("    \(cmd.name): " + cmd.args.map { "\($0.name):\($0.type)\($0.of.map { "<\($0)>" } ?? "")\($0.optional ? "?" : "")" }.joined(separator: " ")
                      + (cmd.confirms.isEmpty ? "" : "  asks \(cmd.confirms)") + (cmd.secret ? "  secret" : ""))
            }
            check(d.plugin == "Usher" && d.format == 1, "Usher answers describe in format 1")
            check(d.commands.flatMap(\.args).allSatisfy(\.isKnown), "every argument type is one Leaf Juice knows")
            func optionals(_ name: String) -> [String] { d.commands.first { $0.name == name }?.args.filter(\.optional).map(\.name) ?? ["missing"] }
            equal(optionals("apply"), ["whitelist", "via"], "apply's whitelist and via are optional")
            equal(optionals("attempts"), ["limit", "cursor"], "attempts' limit and cursor are optional")
            equal(optionals("log"), ["limit"], "log's limit is optional")
        case let other: check(false, "describe read: \(other)")
        }
        if let dump {
            let raw = await c.commands.run("usher", ["describe"])
            if case .done(let a) = raw.outcome { try a.json.write(to: dump) }
        }

        let profiles = await c.commands.run("usher", ["profiles"])
        if case .done(let a) = profiles.outcome { print("  profiles: \(String(decoding: a.json, as: UTF8.self).prefix(400))") } else { check(false, "profiles: \(profiles.outcome)") }

        if withLuckPerms {
            await realUsherApproval(c, root: root)
            c.stop()
            await checkUntil(90, "stops") { c.state == .stopped }
            return
        }
        let apply = await c.commands.run("usher", ["apply"], [.uuid("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"), .player("MadeUpKid"), .word("none"), .word("none")])
        if case .failed(let e) = apply.outcome {
            print("  apply without LuckPerms: \(e.code): \(e.plainMessage)")
            check(e.code == "luckperms-missing", "without LuckPerms, apply is refused with its own code")
        } else { check(false, "apply without LuckPerms is refused: \(apply.outcome)") }

        let unknown = await c.commands.run("usher", ["nosuchthing"])
        if case .failed(let e) = unknown.outcome { equal(e.code, "unknown-command", "an unknown subcommand gets the base code") } else { check(false, "unknown subcommand: \(unknown.outcome)") }

        c.stop()
        await checkUntil(90, "stops") { c.state == .stopped }
    } catch { failures.append("real usher: \(error)") }
}

/// Usher's part of the Allowlist page, against the fake server: refusals that must fail closed, then a whole approval.
@MainActor private func usherThroughFake(_ c: ServerController, root: URL) async {
    let made = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    check(!c.hasUsher, "no Usher jar, no Usher")
    equal(await c.usherStatus(), .notInstalled, "and the page uses its own path")
    makeJarInPlugins(root, "Usher")
    await c.refreshPlugins()
    check(c.hasUsher, "an Usher jar is noticed")

    // With Usher on the server, nothing goes around it.
    c.accessAllowsOffline = true
    defer { c.accessAllowsOffline = false }
    for (label, change) in [("adding someone", AccessChange(uuid: made, name: "MadeUpKid", addGroups: [])),
                            ("adding a group", AccessChange(uuid: made, name: "MadeUpKid", addGroups: ["young"], addToAllowlist: false)),
                            ("removing a group", AccessChange(uuid: made, name: "MadeUpKid", removeGroups: ["young"], addToAllowlist: false))] {
        let refusal = await c.requestAccess(change)
        check(refusal?.contains("Usher") ?? false, "with Usher here, raw \(label) is refused: \(refusal ?? "allowed")")
    }
    check(c.waitingAccess.isEmpty, "and nothing is queued to happen later")
    check(!c.console.contains { $0.text.contains("lp user") || $0.text.contains("whitelist add") }, "and no LuckPerms or whitelist command was typed")

    Modules.shared.set(.pluginCommands, on: false)
    if case .unavailable(let why) = await c.usherStatus() { check(why.contains("Plugin commands"), "switched off: Usher can't be reached, saying how to fix it") } else { check(false, "switched off is unavailable") }
    Modules.shared.set(.pluginCommands, on: true)

    write("", root.appendingPathComponent("usher-old"))
    if case .unavailable(let why) = await c.usherStatus() { check(why.contains("0.4.0"), "an Usher without apply is refused, naming the version needed: \(why)") } else { check(false, "old Usher refused") }
    try? FileManager.default.removeItem(at: root.appendingPathComponent("usher-old"))
    write("", root.appendingPathComponent("usher-format-2"))
    if case .unavailable(let why) = await c.usherStatus() { check(why.contains("newer"), "an Usher speaking a newer format is refused") } else { check(false, "newer format refused") }
    try? FileManager.default.removeItem(at: root.appendingPathComponent("usher-format-2"))

    guard case .ready(let version, let profiles, let luckPerms, let problems) = await c.usherStatus() else { check(false, "the fake Usher is ready"); return }
    equal(problems, ["Profile builders is left out: made up."], "Usher's own settings problems come through, to be shown")
    check(version == "0.4.0" && luckPerms, "ready, with its version and LuckPerms state")
    equal(profiles.map(\.label), ["Young explorers", "Grown-ups"], "its profiles, with their labels")
    equal(profiles.first?.worlds ?? [], ["young_build"], "and what each opens")

    equal(await c.usherApply(uuid: made, name: "MadeUpKid", add: ["none"], remove: []), .failed("A profile can't be called “none”."), "a profile called none is refused before anything is typed")
    equal(await c.usherApply(uuid: made, name: "MadeUpKid", add: ["young"], remove: []), .done("MadeUpKid is approved and can join now."), "approving with a profile")
    if case .success(let p) = await c.usherShow(uuid: made) { check(p.profiles == ["young"] && p.whitelisted, "Usher then shows the profile, and the whitelist") } else { check(false, "show read") }
    equal(await c.usherApply(uuid: made, name: "MadeUpKid", add: ["grown"], remove: []), .questions([ConfirmQuestion(id: "bridge", question: "This puts them in two chat circles. Go ahead?")]), "a risky change comes back as a question")
    if case .success(let p) = await c.usherShow(uuid: made) { equal(p.profiles, ["young"], "and nothing changed") } else { check(false, "show read") }
    equal(await c.usherApply(uuid: made, name: "MadeUpKid", add: ["grown"], remove: ["young"], yes: ["bridge"]), .done("MadeUpKid is approved and can join now."), "it goes ahead with the yes")
    if case .success(let p) = await c.usherShow(uuid: made) { equal(p.profiles, ["grown"], "added and removed in one go") } else { check(false, "show read") }
    let typed = (try? String(contentsOf: root.appendingPathComponent("usher-commands.txt"), encoding: .utf8)) ?? ""
    check(typed.contains("usher apply \(made) MadeUpKid young none true leaf-juice --json "), "the command typed: lists, none for an empty one, whitelist and who asked")
    check(typed.contains("usher apply \(made) MadeUpKid grown young true leaf-juice --yes bridge --json "), "and the yes goes before the request id")

    if case .success(let list) = await c.usherAttempts() {
        check(list.count == 1 && list.first?.name == "MadeUpKid" && list.first?.count == 3, "people turned away are read, with Usher 0.4.0's list key and number cursor")
    } else { check(false, "attempts read") }

    try? FileManager.default.removeItem(at: root.appendingPathComponent("plugins/Usher.jar"))
    await c.refreshPlugins()
}

/// A whole approval through real Usher and LuckPerms, as the Allowlist page does it, on a made-up offline account.
@MainActor private func realUsherApproval(_ c: ServerController, root: URL) async {
    await c.refreshPlugins()
    check(c.hasUsher && c.hasLuckPerms, "Usher and LuckPerms are both on the server")
    if case .ready(_, _, _, let problems) = await c.usherStatus() {
        check(problems.contains { $0.contains("doesn't exist in LuckPerms") }, "before its groups exist, Usher's problems say so, for the page to show")
    }
    for group in ["young", "grown", "grown_sky"] { await expectLine(c, "lp creategroup \(group)", group, "made-up group \(group)") }
    if case .done = await c.commands.run("usher", ["reload"]).outcome { check(true, "") } else { check(false, "usher reload through plugin commands") }
    guard case .ready(let version, let profiles, let luckPerms, _) = await c.usherStatus() else { check(false, "real Usher is ready"); return }
    print("  Usher \(version), LuckPerms \(luckPerms), profiles \(profiles.map(\.id))")
    check(luckPerms, "Usher sees LuckPerms")
    let name = "MadeUpKid", uuid = PlayerFiles.offlineUUID(name: name)

    let first = await c.usherApply(uuid: uuid, name: name, add: ["young"], remove: [])
    print("  approve with young: \(first)")
    if case .done = first { check(true, "") } else { check(false, "approving with one profile goes through: \(first)") }
    if case .success(let p) = await c.usherShow(uuid: uuid) {
        check(p.profiles == ["young"] && p.whitelisted, "Usher shows the profile, and they're whitelisted: \(p)")
    } else { check(false, "show read") }
    check(c.allowlist.contains { $0.uuid == uuid }, "the server's whitelist file has them")
    let groups = await c.currentGroups(uuid: uuid) ?? []
    check(groups.contains("young"), "LuckPerms has the group: \(groups)")

    let risky = await c.usherApply(uuid: uuid, name: name, add: ["grown"], remove: [])
    print("  add grown: \(risky)")
    if case .questions(let qs) = risky {
        check(!qs.isEmpty, "a second chat circle comes back as a question")
        if case .success(let p) = await c.usherShow(uuid: uuid) { equal(p.profiles, ["young"], "and nothing changed") }
        let yes = await c.usherApply(uuid: uuid, name: name, add: ["grown"], remove: [], yes: qs.map(\.id))
        if case .done = yes { check(true, "") } else { check(false, "it goes through with every yes: \(yes)") }
    } else { check(false, "adding a second circle asks first: \(risky)") }

    let sky = await c.usherApply(uuid: uuid, name: name, add: ["grown_sky"], remove: ["young"])
    print("  grown sky, minus young: \(sky)")
    if case .questions(let qs) = sky {
        check(qs.contains { $0.id == "confirm-grown-sky" }, "a profile with its own question asks it: \(qs.map(\.id))")
        let yes = await c.usherApply(uuid: uuid, name: name, add: ["grown_sky"], remove: ["young"], yes: qs.map(\.id))
        if case .done = yes { check(true, "") } else { check(false, "and goes ahead with the yes: \(yes)") }
        if case .success(let p) = await c.usherShow(uuid: uuid) { equal(Set(p.profiles), ["grown", "grown_sky"], "added and removed in one go") }
    } else { check(false, "a profile with a confirm question asks: \(sky)") }

    c.accessAllowsOffline = true
    let raw = await c.requestAccess(AccessChange(uuid: PlayerFiles.offlineUUID(name: "MadeUpOther"), name: "MadeUpOther", addGroups: ["young"]))
    c.accessAllowsOffline = false
    check(raw?.contains("Usher") ?? false, "the raw LuckPerms path is refused with Usher here: \(raw ?? "allowed")")
    check(!c.allowlist.contains { $0.name == "MadeUpOther" }, "and nobody was added around it")

    let log = (try? String(contentsOf: root.appendingPathComponent("plugins/Usher/changes.log"), encoding: .utf8)) ?? ""
    check(log.contains("leaf-juice"), "Usher's change log says the changes came from Leaf Juice")
    if case .success(let list) = await c.usherAttempts() { print("  attempts: \(list.count)") } else { check(false, "attempts read on real Usher") }
}

/// Invites through a fake Latchkey: the code comes only from the once-file, questions hold the invite back.
@MainActor private func latchkeyThroughFake(_ c: ServerController, root: URL) async {
    check(!c.hasLatchkey, "no Latchkey jar, no invites card")
    equal(await c.latchkeyStatus(), .notInstalled, "and no Latchkey status")
    makeJarInPlugins(root, "Latchkey")
    await c.refreshPlugins()
    defer { try? FileManager.default.removeItem(at: root.appendingPathComponent("plugins/Latchkey.jar")) }

    Modules.shared.set(.pluginCommands, on: false)
    if case .unavailable(let why) = await c.latchkeyStatus() { check(why.contains("Plugin commands"), "switched off, invites say how to turn them on") } else { check(false, "switched off is unavailable") }
    Modules.shared.set(.pluginCommands, on: true)

    write("", root.appendingPathComponent("latchkey-closed"))
    if case .ready(_, let works, _, let problems, _) = await c.latchkeyStatus() {
        check(!works && problems == ["online-mode is off, so invites are off."], "Latchkey not taking invites is shown, with its reason")
    } else { check(false, "closed Latchkey read") }
    try? FileManager.default.removeItem(at: root.appendingPathComponent("latchkey-closed"))
    guard case .ready(let version, true, let url, _, let lobby) = await c.latchkeyStatus() else { check(false, "the fake Latchkey is ready"); return }
    check(version == "0.2.0" && url == "https://play.example.test", "ready, with its version and sign-up page")
    check(lobby == nil, "Latchkey 0.2.0 says nothing about a lobby, so none is shown")

    for (label, result) in [("a bad name", await c.createInvite(name: "Not A Name", profiles: [], days: 14)),
                            ("0 days", await c.createInvite(name: "MadeUpKid", profiles: [], days: 0)),
                            ("31 days", await c.createInvite(name: "MadeUpKid", profiles: [], days: 31)),
                            ("a profile called none", await c.createInvite(name: "MadeUpKid", profiles: ["none"], days: 14))] {
        if case .failed = result { check(true, "") } else { check(false, "refused before anything is typed: \(label)") }
    }
    check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("latchkey-commands.txt").path) ||
          !((try? String(contentsOf: root.appendingPathComponent("latchkey-commands.txt"), encoding: .utf8)) ?? "").contains("invite create"), "and none of them reached Latchkey")

    let consoleBefore = c.console.count
    guard case .made(let lobby) = await c.createInvite(name: "MadeUpKid", profiles: [], days: 14) else { check(false, "a lobby-only invite is made"); return }
    equal(lobby.code, "QW3RTY", "the code is read from Latchkey's once-file")
    check(lobby.invite.profiles.isEmpty && lobby.invite.isOpen(), "lobby only, and waiting")
    check(!c.console.dropFirst(consoleBefore).contains { $0.text.contains("QW3RTY") }, "the code never reaches the console")
    check(((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("plugins/Latchkey/once").path)) ?? []).isEmpty, "and its file is gone")

    if case .questions(let qs) = await c.createInvite(name: "MadeUpKid", profiles: ["young", "grown"], days: 7) {
        equal(qs.map(\.id), ["bridge"], "an invite with a risky mix asks first")
        if case .made(let new) = await c.createInvite(name: "MadeUpKid", profiles: ["young", "grown"], days: 7, yes: ["bridge"]) {
            equal(new.invite.profiles, ["young", "grown"], "and is made with the yes, with its profiles")
        } else { check(false, "made with the yes") }
    } else { check(false, "risky invite asks") }
    let typed = (try? String(contentsOf: root.appendingPathComponent("latchkey-commands.txt"), encoding: .utf8)) ?? ""
    check(typed.contains("latchkey invite create MadeUpKid none 14d --json "), "the command typed for a lobby-only invite")
    check(typed.contains("latchkey invite create MadeUpKid young,grown 7d --yes bridge --json "), "and for one with profiles and a yes")

    guard case .success(let listed) = await c.listInvites() else { check(false, "invites listed"); return }
    let list = listed.invites
    equal(list.count, 2, "both invites listed, from Latchkey 0.2.0's own list key")
    check(!listed.more, "and that's all of them")
    equal(await c.revokeInvite("not-an-id"), "That isn't an invite id.", "a bad invite id is refused before anything is typed")
    equal(await c.revokeInvite(list[0].invite), nil, "revoking an invite")
    if case .success(let after) = await c.listInvites() { equal(after.invites.first?.stateText(), "Revoked", "and it shows as revoked") }

    // Latchkey 0.3.0: the lobby in its status, and the list paged the spec's way.
    write("", root.appendingPathComponent("latchkey-v3"))
    defer { try? FileManager.default.removeItem(at: root.appendingPathComponent("latchkey-v3")) }
    if case .ready(let v3, _, _, _, let lobby) = await c.latchkeyStatus() {
        check(v3 == "0.3.0" && lobby == true, "Latchkey 0.3.0's lobby shows as on")
    } else { check(false, "Latchkey 0.3.0 is ready") }
    for n in 0..<5 { _ = await c.createInvite(name: "MadeUpPal\(n)", profiles: [], days: 3) }
    let logFile = root.appendingPathComponent("latchkey-commands.txt")
    try? FileManager.default.removeItem(at: logFile)
    if case .success(let paged) = await c.listInvites(pageSize: 2) {
        equal(paged.invites.count, 7, "every invite is read, two to a page")
        check(!paged.more, "and the last page ends it")
        equal(Set(paged.invites.map(\.invite)).count, 7, "with none read twice")
    } else { check(false, "paged list read") }
    let pages = ((try? String(contentsOf: logFile, encoding: .utf8)) ?? "").split(separator: "\n")
    check(pages.count == 4 && pages[1].hasPrefix("latchkey invite list 2 2 --json ") && pages[3].hasPrefix("latchkey invite list 2 6 --json "), "each page asks from the last page's cursor")
    if case .success(let capped) = await c.listInvites(pageSize: 2, maxPages: 2) {
        check(capped.invites.count == 4 && capped.more, "a long list stops at the page limit and says there's more")
    } else { check(false, "capped list read") }
    write("", root.appendingPathComponent("latchkey-bad-cursor"))
    defer { try? FileManager.default.removeItem(at: root.appendingPathComponent("latchkey-bad-cursor")) }
    try? FileManager.default.removeItem(at: logFile)
    if case .success(let odd) = await c.listInvites(pageSize: 2) {
        check(odd.invites.count == 2 && odd.more, "a cursor that looks like a flag ends the list instead of being typed")
    } else { check(false, "odd cursor list read") }
    check(!((try? String(contentsOf: logFile, encoding: .utf8)) ?? "").contains("--yes"), "and it never reaches the console")
}

/// Latchkey's session files, read the agreed way, and the links page signing someone in by them.
@MainActor private func latchkeySessionChecks() {
    let root = folder("latchkey-sessions")
    let paths = ServerPaths(root: root)
    let sessions = paths.plugins.appendingPathComponent("Latchkey/sessions", isDirectory: true)
    try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    chmod(sessions.path, 0o700)
    let uuid = "00000000-0000-4000-8000-0000000000aa"
    let now = Date()
    func sha(_ s: String) -> String { LinksWeb.hash(s) }
    @discardableResult func plant(_ cookie: String, _ json: String, mode: mode_t = 0o600) -> URL {
        let url = sessions.appendingPathComponent("\(sha(cookie)).json")
        try? Data(json.utf8).write(to: url)
        chmod(url.path, mode)
        return url
    }
    func body(uuid u: String = uuid, name: String = "MadeUp", expires: Date = now.addingTimeInterval(3600), since: Date? = now.addingTimeInterval(-60)) -> String {
        var j = "{\"uuid\":\"\(u)\",\"name\":\"\(name)\",\"expires\":\(Int(expires.timeIntervalSince1970))"
        if let since { j += ",\"since\":\(Int(since.timeIntervalSince1970))" }
        return j + ",\"later\":true}"
    }
    func read(_ cookie: String) -> LatchkeySessions.Session? { LatchkeySessions.read(plugins: paths.plugins, cookieValue: cookie, now: now) }

    let good = LinksWeb.randomSecret()
    plant(good, body())
    check(read(good).map { $0.uuid == uuid && $0.name == "MadeUp" } ?? false, "a session file is read by the hash of the cookie as sent, with unknown keys ignored")
    let cases: [(String, String, mode_t)] = [
        ("no since", body(since: nil), 0o600),
        ("expiry before sign-in", body(expires: now.addingTimeInterval(60), since: now.addingTimeInterval(120)), 0o600),
        ("more than 30 days from sign-in", body(expires: now.addingTimeInterval(3600), since: now.addingTimeInterval(-31 * 86400)), 0o600),
        ("run out", body(expires: now.addingTimeInterval(-1)), 0o600),
        ("signed in in the future", body(expires: now.addingTimeInterval(7200), since: now.addingTimeInterval(3600)), 0o600),
        ("a uuid in capitals", body(uuid: uuid.uppercased()), 0o600),
        ("a bad name", body(name: "Not A Name"), 0o600),
        ("not JSON", "nope", 0o600),
        ("readable by others", body(), 0o644),
    ]
    for (label, json, mode) in cases {
        let cookie = LinksWeb.randomSecret()
        plant(cookie, json, mode: mode)
        check(read(cookie) == nil, "no session: \(label)")
    }
    let linkTarget = folder("latchkey-elsewhere").appendingPathComponent("s.json")
    write(body(), linkTarget); chmod(linkTarget.path, 0o600)
    let linked = LinksWeb.randomSecret()
    try? FileManager.default.createSymbolicLink(at: sessions.appendingPathComponent("\(sha(linked)).json"), withDestinationURL: linkTarget)
    check(read(linked) == nil, "no session: a link to a file elsewhere")
    check(read(LinksWeb.randomSecret()) == nil, "no session: no file")
    chmod(sessions.path, 0o755)
    check(read(good) == nil, "no session: a folder others can look in")
    chmod(sessions.path, 0o700)
    check(LatchkeySessions.cookieValue("a=b; latchkey_session=\(good); c=d") == good, "the cookie is found among others")
    check(LatchkeySessions.cookieValue("latchkey_session=../../x") == nil && LatchkeySessions.cookieValue("latchkey_session=short") == nil, "an odd cookie isn't used")

    // The links page signs someone in by Latchkey's cookie, checking the allowlist and bans itself.
    write("online-mode=true\n", paths.properties)
    write(#"[{"uuid":"\#(uuid)","name":"MadeUp"}]"#, root.appendingPathComponent("whitelist.json"))
    var settings = LinksPageSettings(); settings.address = "https://links.example.test/"
    let web = LinksWeb(paths: paths, settings: { settings }, content: { LinksPageContent(serverVersion: "Paper 26.3", plugins: []) })
    func page(_ cookie: String) -> String {
        String(decoding: web.handle(.init(method: "GET", path: "/", headers: ["host": "links.example.test", "cookie": "latchkey_session=\(cookie)"], body: Data()), now: now).body, as: UTF8.self)
    }
    check(page(good).contains("Signed in as MadeUp"), "the links page signs someone in by Latchkey's session")
    write(#"[{"uuid":"\#(uuid)","name":"MadeUp"}]"#, root.appendingPathComponent("banned-players.json"))
    check(!page(good).contains("Signed in as"), "but not once they're banned")
    try? FileManager.default.removeItem(at: root.appendingPathComponent("banned-players.json"))
    write("[]", root.appendingPathComponent("whitelist.json"))
    check(!page(good).contains("Signed in as"), "or off the allowlist")
    write(#"[{"uuid":"\#(uuid)","name":"MadeUp"}]"#, root.appendingPathComponent("whitelist.json"))
    try? FileManager.default.removeItem(at: sessions.appendingPathComponent("\(sha(good)).json"))
    check(!page(good).contains("Signed in as"), "or once Latchkey deletes the file")
    plant(good, body(expires: now.addingTimeInterval(86400 * 2)))
    check(page(good).contains("Signed in as MadeUp"), "an extended session counts at once, since the file is read every time")
}

/// A tiny browser for Latchkey's page, using curl, keeping cookies itself (they're Secure, and this is plain HTTP on 127.0.0.1).
private final class PageClient {
    let port: Int
    var cookies: [String: String] = [:]
    init(port: Int) { self.port = port }

    func request(_ path: String, form: [String: String]? = nil) async throws -> (status: Int, setCookies: [String], body: String) {
        var args = ["-s", "-i", "--max-time", "15", "http://127.0.0.1:\(port)\(path)"]
        if !cookies.isEmpty { args += ["-H", "Cookie: " + cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")] }
        if let form {
            for (k, v) in form { args += ["--data-urlencode", "\(k)=\(v)"] }
        }
        let r = try await Tool.run("/usr/bin/curl", args)
        let text = r.out.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = text.components(separatedBy: "\n\n")
        let head = parts.first ?? "", body = parts.dropFirst().joined(separator: "\n\n")
        let lines = head.split(separator: "\n").map(String.init)
        let status = Int(lines.first?.split(separator: " ").dropFirst().first ?? "") ?? 0
        let set = lines.filter { $0.lowercased().hasPrefix("set-cookie:") }.map { String($0.dropFirst(11)).trimmingCharacters(in: .whitespaces) }
        for c in set {
            let kv = c.split(separator: ";").first.map(String.init) ?? ""
            guard let eq = kv.firstIndex(of: "=") else { continue }
            let k = String(kv[..<eq]), v = String(kv[kv.index(after: eq)...])
            if v.isEmpty || c.contains("Max-Age=0") { cookies[k] = nil } else { cookies[k] = v }
        }
        return (status, set, body)
    }

    func csrf(_ path: String) async throws -> String {
        let page = try await request(path).body
        guard let r = page.range(of: #"name="csrf" value=""#), let end = page[r.upperBound...].firstIndex(of: "\"") else { throw LeafError("no form on \(path)") }
        return String(page[r.upperBound..<end])
    }
}

/// Real Paper with LuckPerms, Usher and Latchkey: an invite made through Leaf Juice is redeemed on Latchkey's page,
/// a bot signs in, Leaf Juice reads the session file, and taking them off the whitelist ends it. Made-up offline accounts.
@MainActor func runRealInvites(usher: URL, latchkey: URL) async {
    section("REAL INVITES THROUGH LATCHKEY AND USHER (EULA accepted by the person running this)")
    do {
        let port = 25593, web = 25694
        let root = folder("real-invites")
        let c = try await buildInvitesServer(root: root, port: port, web: web, usher: usher, latchkey: latchkey)
        defer { c.forceStop(); c.stopTicker() }
        Modules.shared.set(.pluginCommands, on: true)
        defer { Modules.shared.set(.pluginCommands, on: false) }
        let runtimes = await JavaManager.discover()
        guard let java = JavaManager.best(for: 25, in: runtimes) else { failures.append("no Java 25"); return }
        let table = try await ProtocolTable.load(mc: realMC, cache: folder("real-invites-protocol"), java: java.path)

        await c.start()
        await checkUntil(240, "Paper \(realMC) with Usher and Latchkey runs (last: \(c.console.suffix(3).map(\.text)))") { c.state == .running }
        await c.refreshPlugins()
        for group in ["young", "grown"] { await expectLine(c, "lp creategroup \(group)", group, "made-up group \(group)") }
        _ = await c.commands.run("usher", ["reload"])

        guard case .ready(let version, let works, let url, let problems, let lobby) = await c.latchkeyStatus() else { check(false, "real Latchkey is ready"); return }
        print("  Latchkey \(version), invites \(works), page \(url ?? "none"), lobby \(lobby.map(String.init) ?? "not said"), problems \(problems)")
        if !version.hasPrefix("0.2.") { check(lobby != nil, "Latchkey \(version) says whether its lobby is on") }
        check(works, "Latchkey takes invites on this throwaway setup")
        guard case .ready(_, let profiles, _, _) = await c.usherStatus() else { check(false, "Usher ready"); return }
        check(profiles.contains { $0.id == "young" }, "Usher's young profile is there")

        let name = "MadeUpKid", uuid = PlayerFiles.offlineUUID(name: name)
        let consoleBefore = c.console.count
        guard case .made(let invite) = await c.createInvite(name: name, profiles: ["young"], days: 7) else { check(false, "an invite with a profile is made"); return }
        print("  invite \(invite.invite.invite) for \(invite.invite.name), \(invite.invite.profiles), code length \(invite.code.count)")
        check(invite.code.count == 6, "a six-character code comes back, from the once-file")
        check(!c.console.dropFirst(consoleBefore).contains { $0.text.contains(invite.code) }, "the code never reaches the console")
        let logText = (try? String(contentsOf: root.appendingPathComponent("logs/latest.log"), encoding: .utf8)) ?? ""
        check(!logText.contains(invite.code), "or latest.log")
        check(((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("plugins/Latchkey/once").path)) ?? []).isEmpty, "and the once-file is gone")

        let risky = await c.createInvite(name: "MadeUpOther", profiles: ["young", "grown"], days: 7)
        if case .questions(let qs) = risky { check(qs.contains { $0.id == "bridge" }, "Usher's bridge question comes back through Latchkey, before any invite is made") } else { check(false, "a risky invite asks first: \(risky)") }
        guard case .made(let spare) = await c.createInvite(name: "MadeUpSpare", profiles: [], days: 1) else { check(false, "a lobby-only invite"); return }
        equal(await c.revokeInvite(spare.invite.invite), nil, "revoking an invite")
        if case .success(let listed) = await c.listInvites() { let list = listed.invites
            equal(Set(list.map { "\($0.name):\($0.stateText())" }), ["MadeUpKid:Waiting", "MadeUpSpare:Revoked"], "the list shows both, and only those")
        } else { check(false, "invites listed") }

        // Redeemed on Latchkey's own page, as the player would.
        let browser = PageClient(port: web)
        let redeemed = try await browser.request("/invite", form: ["csrf": try await browser.csrf("/"), "code": invite.code.lowercased(), "name": name])
        print("  redeem: HTTP \(redeemed.status)")
        await checkUntil(10, "redeeming whitelists them") { c.allowlist.contains { $0.uuid == uuid } }
        if case .success(let p) = await c.usherShow(uuid: uuid) { equal(p.profiles, ["young"], "Usher applied the invite's profile") } else { check(false, "show after redeeming") }
        if case .success(let list) = await c.listInvites() { equal(list.invites.first { $0.name == name }?.stateText(), "Used", "the invite shows as used") }

        // A bot signs in, and Leaf Juice reads Latchkey's session file.
        // Sign-in is op-only by default; an admin gives it to the players who should have it.
        await expectLine(c, "lp user \(name) permission set latchkey.signin true", "latchkey.signin", "sign-in allowed for \(name)")
        let bot = try await join(name, c, table, port: port)
        bot.command("signin")
        await checkUntil(10, "/signin sends a link (got \(bot.privateMessages.map { String($0.filter { $0.isASCII && !$0.isNewline }.prefix(120)) }))") { bot.privateMessages.contains { $0.contains("/signin#") } }
        // The bot's messages are raw packet bytes, so the link is picked out by its exact shape, nothing more.
        let linkPattern = regex(#"https://play\.example\.test/signin#[A-Za-z0-9_-]{43}"#)
        guard let message = bot.privateMessages.first(where: { $0.contains("/signin#") }),
              let m = linkPattern.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let range = Range(m.range, in: message) else { check(false, "the link"); return }
        let link = String(message[range])
        let signin = PageClient(port: web)
        let signed = try await signin.request("/signin", form: ["csrf": try await signin.csrf("/signin"), "link": link])
        print("  sign-in: HTTP \(signed.status)")
        guard let cookie = signin.cookies[LatchkeySessions.cookie] else { check(false, "Latchkey set its session cookie"); return }
        let session = LatchkeySessions.read(plugins: c.paths.plugins, cookieValue: cookie)
        check(session?.uuid == uuid && session?.name == name, "Leaf Juice reads the real session file: \(String(describing: session))")
        let web2 = LinksWeb(paths: c.paths, settings: { var s = LinksPageSettings(); s.address = "https://links.example.test/"; return s }, content: { LinksPageContent(serverVersion: "Paper", plugins: []) })
        web2.requireOnlineMode = false
        func page() -> String { String(decoding: web2.handle(.init(method: "GET", path: "/", headers: ["host": "links.example.test", "cookie": "\(LatchkeySessions.cookie)=\(cookie)"], body: Data())).body, as: UTF8.self) }
        check(page().contains("Signed in as \(name)"), "Leaf Juice's links page signs them in by Latchkey's cookie")

        await expectLine(c, "whitelist remove \(name)", "Removed", "taken off the whitelist")
        await checkUntil(5, "which ends the session file") { LatchkeySessions.read(plugins: c.paths.plugins, cookieValue: cookie) == nil }
        check(!page().contains("Signed in as"), "and Leaf Juice's page with it")
        bot.leave()

        c.stop()
        await checkUntil(90, "stops") { c.state == .stopped }
    } catch { failures.append("real invites: \(error)") }
}

/// A throwaway offline Paper server with LuckPerms, Usher and Latchkey, set up the way their own tests do it.
/// Latchkey's offline-testing flag goes in this server's launch settings only.
@MainActor func buildInvitesServer(root: URL, port: Int, web: Int, usher: URL, latchkey: URL) async throws -> ServerController {
        write("server-ip=127.0.0.1\nserver-port=\(port)\nonline-mode=false\nwhite-list=true\nenforce-whitelist=true\nview-distance=4\nsimulation-distance=4\nlevel-type=minecraft\\:flat\ngenerate-structures=false\nspawn-protection=0\nnetwork-compression-threshold=-1\n", root.appendingPathComponent("server.properties"))
        let c = try await ServerController.adopt(root: root, name: "real-invites")
        try EULA.accept(c.paths)
        try await c.installSoftware(try await SoftwareCatalog.latestBuild(.paper, mc: realMC)!)
        try await c.addPlugin(source: .modrinth(project: "luckperms", allowBeta: false))
        for jar in [usher, latchkey] { try FileManager.default.copyItem(at: jar, to: root.appendingPathComponent("plugins/\(jar.lastPathComponent)")) }
        // Each plugin's shipped config, set for a throwaway offline server the way their own tests do it.
        var usherConfig = try await Tool.run("/usr/bin/unzip", ["-p", usher.path, "config.yml"]).out
        usherConfig = usherConfig.replacingOccurrences(of: "name-lookup: auto", with: "name-lookup: offline").replacingOccurrences(of: "lobby-world: \"\"", with: "lobby-world: world")
        try FileOps.ensureDir(root.appendingPathComponent("plugins/Usher"))
        write(usherConfig, root.appendingPathComponent("plugins/Usher/config.yml"))
        var lk = try await Tool.run("/usr/bin/unzip", ["-p", latchkey.path, "config.yml"]).out
        for (a, b) in [("enabled: false", "enabled: true"), ("port: 25680", "port: \(web)"), ("public-url: \"\"", "public-url: \"https://play.example.test\"")] {
            guard lk.contains(a) else { throw LeafError("Latchkey's shipped config no longer has \(a)") }
            lk = lk.replacingOccurrences(of: a, with: b)
        }
        try FileOps.ensureDir(root.appendingPathComponent("plugins/Latchkey"))
        write(lk, root.appendingPathComponent("plugins/Latchkey/config.yml"))
        c.profile.launch.extraJVMArgs = "-Dlatchkey.allowOfflineForTesting=true"
        c.profile.lastPluginCheck = Date(); c.profile.software.lastCheck = Date()
        c.profile.backup.enabled = false
        c.profile.launch.restartOnCrash = false
        return c
}

/// --demo-invites <folder>: a throwaway server with made-up players and invites, for the owner's hand check of the
/// Allowlist and Invites screens. The app is opened with this folder as its home, so no real server is in sight.
@MainActor func runDemoInvites(_ demo: URL) async throws {
    let jars = demo.appendingPathComponent("jars", isDirectory: true)
    try FileOps.ensureDir(jars)
    var got: [URL] = []
    for (name, url, sha) in [
        ("Usher-0.4.0.jar", "https://github.com/ExtantApe/Usher/releases/download/v0.4.0/Usher-0.4.0.jar", "543629b0d81bf117697f185457b03d86954ccc6d44314d63affd1f7876a799d7"),
        ("Latchkey-0.2.0.jar", "https://github.com/ExtantApe/Latchkey/releases/download/v0.2.0/Latchkey-0.2.0.jar", "bc9f991f948c0df53f55723fb0e7f487c33d1026cf4b31b4fdefc4faaf4e8ecb"),
    ] {
        let to = jars.appendingPathComponent(name)
        _ = try await HTTP.download(URL(string: url)!, to: to, expect: ExpectedHashes(sha256: sha))
        got.append(to)
    }
    let root = demo.appendingPathComponent("servers/invites-demo", isDirectory: true)
    try FileOps.ensureDir(root)
    let c = try await buildInvitesServer(root: root, port: 25595, web: 25695, usher: got[0], latchkey: got[1])
    c.profile.name = "Invites demo"
    Modules.shared.set(.pluginCommands, on: true)
    await c.start()
    guard await until(240, { c.state == .running }) else { throw LeafError("The demo server didn't start: \(c.console.suffix(3).map(\.text))") }
    await c.refreshPlugins()
    for group in ["young", "grown", "young_sky", "grown_sky", "builders"] { _ = await c.ask("lp creategroup \(group)") { $0.contains { $0.contains(group) } } }
    _ = await c.commands.run("usher", ["reload"])
    _ = await c.usherApply(uuid: PlayerFiles.offlineUUID(name: "MadeUpBuilder"), name: "MadeUpBuilder", add: ["builders"], remove: [])
    _ = await c.createInvite(name: "MadeUpExplorer", profiles: ["young"], days: 14)
    c.stop()
    _ = await until(90, { c.state == .stopped })
    c.stopTicker()
    // Warnings from the first start, before the groups existed, would only confuse the hand check.
    try? FileManager.default.removeItem(at: c.paths.issues)
    try? FileManager.default.removeItem(at: root.appendingPathComponent("logs/latest.log"))
    // Listed in the demo home, so the app opens straight onto it.
    try JSONStore.save([root.path], to: AppPaths.registry)
    print("Demo ready in \(demo.path): one approved player, one waiting invite, made-up names only.")
}
