import Foundation

// Letting someone in before they've ever joined. A typed name has to match a real account, whatever its capitals.
// Groups go on before the allowlist, so nobody can join with only the default access while this is half done.
// LuckPerms keeps its data in a database only the running server can touch, so a stopped server waits.

public struct MojangAccount: Equatable, Sendable {
    public let name: String
    public let uuid: String
}

public enum AccountLookup {
    public enum Outcome: Equatable, Sendable {
        case found(MojangAccount)
        case noAccount
        case invalid
        /// Couldn't ask. That says nothing about whether the account exists.
        case unreachable(String)
    }

    public static func isValidName(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9_]{1,16}$"#, options: .regularExpression) != nil
    }

    /// Mojang matches any capitals and answers with the account's own spelling. Anything else isn't a match.
    static func interpret(typed: String, status: Int, data: Data) -> Outcome {
        switch status {
        case 200:
            guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = body["name"] as? String, let id = body["id"] as? String, let uuid = dashed(id) else {
                return .unreachable("Mojang's answer couldn't be read.")
            }
            return name.lowercased() == typed.lowercased() ? .found(MojangAccount(name: name, uuid: uuid)) : .noAccount
        case 204, 404: return .noAccount
        default: return .unreachable("Mojang answered with an error (\(status)). Try again in a minute.")
        }
    }

    static func dashed(_ id: String) -> String? {
        let plain = id.replacingOccurrences(of: "-", with: "").lowercased()
        guard plain.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else { return nil }
        let start = plain.startIndex
        func part(_ a: Int, _ b: Int) -> Substring { plain[plain.index(start, offsetBy: a)..<plain.index(start, offsetBy: b)] }
        return "\(part(0, 8))-\(part(8, 12))-\(part(12, 16))-\(part(16, 20))-\(part(20, 32))"
    }

    /// Its own connection. Observed: after using this host on the shared one, Mojang's version list answered 421,
    /// which would break anything that installs software after someone looks up a name.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": LeafJuice.userAgent]
        return URLSession(configuration: config)
    }()

    /// Sends the typed name to Mojang, and only when asked.
    public static func lookUp(_ typed: String) async -> Outcome {
        let name = typed.trimmingCharacters(in: .whitespaces)
        guard isValidName(name), let url = URL(string: "https://api.mojang.com/users/profiles/minecraft/\(name)") else { return .invalid }
        do {
            let (data, response) = try await session.data(for: HTTP.request(url))
            guard let http = response as? HTTPURLResponse else { return .unreachable("Mojang didn't answer properly.") }
            return interpret(typed: name, status: http.statusCode, data: data)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }
}

/// What the owner decided about groups on this server. Group names only ever come from here and the server itself.
public struct PlayerAccessSettings: Codable, Equatable, Sendable {
    /// Off until ticked, so a new or admin group is never offered by accident.
    public var grantable: Set<String> = []
    /// Pairs that shouldn't be held together. A warning, not a block.
    public var conflicts: [[String]] = []
    /// What the server last said it has, for choosing while it's stopped.
    public var knownGroups: [String] = []
    public var groupsRead: Date?
    public init() {}

    /// Only pairs that the choice would newly bring together.
    public func warnings(adding: Set<String>, alreadyHas: Set<String> = []) -> [String] {
        let all = adding.union(alreadyHas)
        return conflicts.compactMap { pair in
            guard pair.count == 2, all.contains(pair[0]), all.contains(pair[1]), adding.contains(pair[0]) || adding.contains(pair[1]) else { return nil }
            return "\(pair[0]) and \(pair[1]) are marked as not to be combined."
        }
    }
}

public struct AccessChange: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var uuid: String
    public var name: String
    public var addGroups: [String] = []
    public var removeGroups: [String] = []
    /// False when only someone's groups are changing.
    public var addToAllowlist = true
    public var created = Date()
    /// Why it stopped. Stays in view until it's retried or cancelled.
    public var problem: String?

    public init(uuid: String, name: String, addGroups: [String] = [], removeGroups: [String] = [], addToAllowlist: Bool = true) {
        self.uuid = uuid
        self.name = name
        self.addGroups = addGroups
        self.removeGroups = removeGroups
        self.addToAllowlist = addToAllowlist
    }

    public var summary: String {
        var parts: [String] = []
        if addToAllowlist { parts.append("allowlist") }
        if !addGroups.isEmpty { parts.append("add \(addGroups.joined(separator: ", "))") }
        if !removeGroups.isEmpty { parts.append("remove \(removeGroups.joined(separator: ", "))") }
        return parts.joined(separator: ", ")
    }
}

public struct AllowlistEntry: Equatable, Identifiable, Sendable {
    public var id: String { uuid }
    public let uuid: String
    public let name: String
}

public enum SignInAccess: Equatable, Sendable {
    case yes, no, noGroupGivesIt, unknown
}

/// Reads what LuckPerms prints. Observed on 5.5 with Paper 1.21.11.
enum LuckPermsText {
    private static func groups(_ pattern: String, _ line: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: line).map { String(line[$0]) } ?? "" }
    }

    static func isValidGroup(_ text: String) -> Bool {
        text.range(of: #"^[a-z0-9_.-]{1,36}$"#, options: .regularExpression) != nil
    }

    /// `[LP] -  name - 0`
    static func groupList(_ lines: [String]) -> [String] {
        lines.compactMap { groups(#"\[LP\] -\s+(\S+) - -?\d+"#, $0)?.first }
    }

    /// The `> name` lines after a `Parents:` header. Nil when there's no such header, because then nothing is known.
    static func parents(_ lines: [String]) -> Set<String>? {
        guard let header = lines.firstIndex(where: { $0.contains("Parents:") }) else { return nil }
        var out = Set<String>()
        for line in lines[(header + 1)...] {
            guard let name = groups(#"(?:^|: )>\s+(\S+)"#, line)?.first else { break }
            out.insert(name.lowercased())
        }
        return out
    }

    static func pageCount(_ lines: [String]) -> Int {
        lines.lazy.compactMap { groups(#"page \d+ of (\d+)"#, $0)?.first.flatMap(Int.init) }.first ?? 1
    }

    static func checkResult(_ lines: [String]) -> SignInAccess {
        switch lines.lazy.compactMap({ groups(#"Result:\s*(\w+)"#, $0)?.first }).first?.lowercased() {
        case "true": .yes
        case "false": .no
        case "undefined": .noGroupGivesIt
        default: .unknown
        }
    }
}

extension ServerController {
    private var savedSettings: URL { paths.meta.appendingPathComponent("player-access.json") }
    private var savedWaiting: URL { paths.meta.appendingPathComponent("player-access-waiting.json") }
    private var allowlistFile: URL { paths.root.appendingPathComponent("whitelist.json") }

    public var playerAccessSettings: PlayerAccessSettings {
        get { JSONStore.load(savedSettings, defaults: PlayerAccessSettings()) }
        set { try? JSONStore.save(newValue, to: savedSettings) }
    }

    public var waitingAccess: [AccessChange] {
        get { JSONStore.load(savedWaiting, defaults: []) }
        set { try? JSONStore.save(newValue, to: savedWaiting) }
    }

    public var hasLuckPerms: Bool { plugins.contains { $0.enabled && $0.key == "luckperms" } }

    /// Why accounts can't be looked up here. A name from Mojang only means anything to an online-mode server.
    public var playerAccessBlocked: String? {
        if accessAllowsOffline { return nil }
        let text = (try? String(contentsOf: paths.properties, encoding: .utf8)) ?? ""
        return PropertiesDocument(text).value("online-mode") == "true" ? nil : "This needs online-mode=true. Without it, the server uses different IDs from the ones Mojang gives."
    }

    public var allowlist: [AllowlistEntry] {
        guard let data = try? Data(contentsOf: allowlistFile), let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let uuid = item["uuid"] as? String, let name = item["name"] as? String else { return nil }
            return AllowlistEntry(uuid: uuid.lowercased(), name: name)
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Runs a console command and collects what comes back, until something does or it's clear nothing will.
    private func ask(_ command: String, seconds: Double = 8, until done: ([String]) -> Bool) async -> [String] {
        let mark = console.last?.id ?? -1
        func answer() -> [String] { console.filter { $0.id > mark && $0.origin == .server }.map(\.text) }
        send(command)
        for _ in 0..<Int(seconds * 10) where !done(answer()) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        // A list arrives over a few lines.
        var seen = -1
        for _ in 0..<8 where answer().count != seen {
            seen = answer().count
            try? await Task.sleep(for: .milliseconds(150))
        }
        return answer()
    }

    /// Asks the running server which groups exist.
    public func refreshGroups() async {
        guard state == .running, hasLuckPerms else { return }
        var found: [String] = []
        var page = 1, pages = 1
        repeat {
            let lines = await ask("lp listgroups\(page > 1 ? " \(page)" : "")") { !LuckPermsText.groupList($0).isEmpty }
            found += LuckPermsText.groupList(lines)
            pages = LuckPermsText.pageCount(lines)
            page += 1
        } while page <= pages && state == .running
        guard !found.isEmpty else { return }
        var settings = playerAccessSettings
        settings.knownGroups = Array(Set(found)).sorted()
        settings.groupsRead = Date()
        playerAccessSettings = settings
    }

    /// Nil when it can't be known, which is never treated as "none".
    public func currentGroups(uuid: String) async -> Set<String>? {
        guard state == .running, hasLuckPerms, AccountLookup.dashed(uuid) != nil else { return nil }
        var out = Set<String>()
        var page = 1, pages = 1
        repeat {
            let lines = await ask("lp user \(uuid) parent info\(page > 1 ? " \(page)" : "")") { $0.contains { $0.contains("Parents:") } }
            guard let found = LuckPermsText.parents(lines) else { return nil }
            out.formUnion(found)
            pages = LuckPermsText.pageCount(lines)
            page += 1
        } while page <= pages && state == .running
        return out
    }

    public func signInAccess(uuid: String) async -> SignInAccess {
        guard state == .running, hasLuckPerms, AccountLookup.dashed(uuid) != nil else { return .unknown }
        return LuckPermsText.checkResult(await ask("lp user \(uuid) permission check latchkey.signin") { $0.contains { $0.contains("Result:") } })
    }

    /// Anything that would go into a console command has to pass here first.
    func accessRefusal(_ change: AccessChange) -> String? {
        if let blocked = playerAccessBlocked { return blocked }
        guard AccountLookup.dashed(change.uuid) != nil else { return "That account's ID isn't valid." }
        guard AccountLookup.isValidName(change.name) else { return "That account's name isn't valid." }
        let settings = playerAccessSettings
        for group in change.addGroups + change.removeGroups {
            guard LuckPermsText.isValidGroup(group) else { return "\(group) isn't a valid group name." }
            guard settings.grantable.contains(group) else { return "\(group) isn't marked as a group this screen can change." }
        }
        if !change.addGroups.isEmpty || !change.removeGroups.isEmpty, !hasLuckPerms { return "Groups need LuckPerms on this server." }
        if change.addGroups.isEmpty, change.removeGroups.isEmpty, !change.addToAllowlist { return "There's nothing to change." }
        return nil
    }

    /// Saved first, so it can't be lost. Applied now if the server is up, or as soon as it is.
    @discardableResult
    public func requestAccess(_ change: AccessChange) async -> String? {
        if let refusal = accessRefusal(change) { return refusal }
        var waiting = waitingAccess.filter { $0.uuid != change.uuid }
        waiting.append(change)
        waitingAccess = waiting
        await applyWaitingAccess()
        return waitingAccess.first { $0.id == change.id }?.problem
    }

    public func cancelAccess(_ id: UUID) {
        waitingAccess = waitingAccess.filter { $0.id != id }
    }

    public func retryAccess(_ id: UUID) async {
        waitingAccess = waitingAccess.map { var change = $0; if change.id == id { change.problem = nil }; return change }
        await applyWaitingAccess()
    }

    /// Something that stopped with a problem waits for a person, because repeating it won't help by itself.
    public func applyWaitingAccess() async {
        guard state == .running, !accessApplying else { return }
        accessApplying = true
        defer { accessApplying = false }
        for change in waitingAccess where change.problem == nil {
            guard state == .running else { return }
            let problem = await apply(change)
            guard state == .running || problem == nil else { return }  // A server that stopped midway just tries again later.
            var waiting = waitingAccess
            if let problem {
                if let index = waiting.firstIndex(where: { $0.id == change.id }) { waiting[index].problem = problem }
            } else {
                waiting.removeAll { $0.id == change.id }
            }
            waitingAccess = waiting
        }
    }

    /// Returns what went wrong. Each step can be repeated safely, and each is read back rather than assumed.
    private func apply(_ change: AccessChange) async -> String? {
        if let refusal = accessRefusal(change) { return refusal }
        for group in change.removeGroups {
            _ = await ask("lp user \(change.uuid) parent remove \(group)") { $0.contains { $0.contains("[LP]") } }
        }
        for group in change.addGroups {
            let lines = await ask("lp user \(change.uuid) parent add \(group)") { $0.contains { $0.contains("[LP]") } }
            if lines.contains(where: { $0.contains("could not be found") }) { return "The group \(group) doesn't exist on this server, so \(change.name) wasn't added." }
        }
        if !change.addGroups.isEmpty || !change.removeGroups.isEmpty {
            guard let now = await currentGroups(uuid: change.uuid) else { return "LuckPerms didn't confirm \(change.name)'s groups, so they weren't added to the allowlist." }
            if let missing = change.addGroups.first(where: { !now.contains($0) }) { return "LuckPerms didn't keep \(missing) for \(change.name), so they weren't added to the allowlist." }
            if let kept = change.removeGroups.first(where: { now.contains($0) }) { return "LuckPerms still has \(kept) for \(change.name)." }
        }
        guard change.addToAllowlist else { return nil }
        func entry() -> AllowlistEntry? { allowlist.first { $0.name.lowercased() == change.name.lowercased() || $0.uuid == change.uuid } }
        if entry()?.uuid == change.uuid { return nil }
        let lines = await ask("whitelist add \(change.name)") { lines in
            lines.contains { $0.contains("does not exist") || $0.contains("Added ") || $0.contains("already") }
        }
        if lines.contains(where: { $0.contains("does not exist") }) { return "The server couldn't find an account called \(change.name)." }
        for _ in 0..<50 where entry() == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let added = entry() else { return "The server didn't save \(change.name) to the allowlist." }
        guard added.uuid == change.uuid else {
            // The name may have moved to someone else since it was looked up. That person mustn't stay on the list.
            send("whitelist remove \(added.name)")
            return "The server found a different account under \(change.name), so that entry was taken off again. Look the name up again."
        }
        return nil
    }

    /// A running server owns the file, so it's asked. A stopped one doesn't, and taking someone off shouldn't have to wait.
    /// Their groups stay, so adding them back later restores what they had.
    public func removeFromAllowlist(_ entry: AllowlistEntry) async -> String? {
        guard AccountLookup.isValidName(entry.name) else { return "That name can't be sent to the server." }
        waitingAccess = waitingAccess.filter { $0.uuid != entry.uuid }
        switch state {
        case .running:
            _ = await ask("whitelist remove \(entry.name)") { $0.contains { $0.contains("Removed ") || $0.contains("not whitelisted") } }
            for _ in 0..<50 where allowlist.contains(where: { $0.uuid == entry.uuid }) { try? await Task.sleep(for: .milliseconds(100)) }
        case _ where !state.isLive:
            guard let data = try? Data(contentsOf: allowlistFile), let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return "The allowlist couldn't be read." }
            let kept = items.filter { ($0["uuid"] as? String)?.lowercased() != entry.uuid }
            do {
                let out = try JSONSerialization.data(withJSONObject: kept, options: [.prettyPrinted])
                try FileOps.writeAtomic(String(decoding: out, as: UTF8.self), to: allowlistFile)
            } catch { return error.localizedDescription }
        default:
            return "The server is starting or stopping. Try again in a moment."
        }
        return allowlist.contains { $0.uuid == entry.uuid } ? "\(entry.name) is still on the allowlist." : nil
    }
}
