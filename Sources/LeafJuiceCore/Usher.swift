import Foundation

// Usher looks after who may join and which profiles they have: a profile is a LuckPerms group plus the
// worlds and chat circle it opens, with Usher's own safety rules and change log. On a server with Usher,
// Leaf Juice goes through Usher's commands (format 1) and never falls back to raw LuckPerms or
// `whitelist add`: owner decision, 2026-11-07, recorded in docs/PLAN.md.

public struct UsherProfile: Sendable, Equatable, Decodable, Identifiable {
    public let id: String
    public let label: String
    public let group: String?
    public let circle: String?
    public let worlds: [String]
    public let description: [String]

    enum CodingKeys: String, CodingKey { case id, label, group, circle, worlds, description }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        group = try c.decodeIfPresent(String.self, forKey: .group)
        circle = try c.decodeIfPresent(String.self, forKey: .circle)
        worlds = try c.decodeIfPresent([String].self, forKey: .worlds) ?? []
        description = (try? c.decodeIfPresent([String].self, forKey: .description)) ?? []
    }
    public init(id: String, label: String, group: String? = nil, circle: String? = nil, worlds: [String] = [], description: [String] = []) {
        self.id = id; self.label = label; self.group = group; self.circle = circle; self.worlds = worlds; self.description = description
    }
}

/// What `usher show` says about one account.
public struct UsherPlayer: Sendable, Equatable, Decodable {
    public let profiles: [String]
    /// Profiles they get through some other group, which Usher can't take away here.
    public let throughOtherGroups: [String]
    public let circles: [String]
    public let whitelisted: Bool

    enum CodingKeys: String, CodingKey { case profiles, throughOtherGroups, circles, whitelisted }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try c.decodeIfPresent([String].self, forKey: .profiles) ?? []
        throughOtherGroups = try c.decodeIfPresent([String].self, forKey: .throughOtherGroups) ?? []
        circles = try c.decodeIfPresent([String].self, forKey: .circles) ?? []
        whitelisted = try c.decodeIfPresent(Bool.self, forKey: .whitelisted) ?? false
    }
}

/// Someone the whitelist turned away, from `usher attempts`.
public struct UsherAttempt: Sendable, Equatable, Decodable, Identifiable {
    public let uuid: String
    public let name: String
    /// How many times the whitelist turned them away.
    public let count: Int
    public var id: String { uuid }

    enum CodingKeys: String, CodingKey { case uuid, name, attempts }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        name = try c.decode(String.self, forKey: .name)
        count = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 1
    }
}

public enum UsherStatus: Sendable, Equatable {
    case notInstalled
    /// Usher is on the server, but Leaf Juice can't reach it right now. Changes are refused, never done another way.
    case unavailable(String)
    case ready(version: String, profiles: [UsherProfile], luckPerms: Bool, problems: [String])

    public var isInstalled: Bool { self != .notInstalled }
}

public enum UsherApplyResult: Sendable, Equatable {
    case done(String)
    /// Nothing changed. Each question needs a yes before sending again.
    case questions([ConfirmQuestion])
    case failed(String)
    /// No answer in time. It may still have happened.
    case notConfirmed
}

extension ServerController {
    public var hasUsher: Bool { plugins.contains { $0.enabled && $0.key == "usher" } }

    /// The commands Leaf Juice needs, as `describe` names them.
    static let usherCommandsNeeded = ["profiles", "show", "apply", "attempts"]

    /// Whether Leaf Juice can go through Usher on this server now, and its profiles if so.
    public func usherStatus() async -> UsherStatus {
        guard hasUsher else { return .notInstalled }
        guard Modules.shared.isOn(.pluginCommands) else {
            return .unavailable("Usher looks after who can join this server. Turn on Plugin commands so Leaf Juice can go through it.")
        }
        guard state == .running, process != nil else {
            return .unavailable("Usher can only be reached while Leaf Juice runs this server. Start it here first.")
        }
        let described: PluginDescription
        switch await commands.describe("usher") {
        case .described(let d): described = d
        case .newerFormat(let n): return .unavailable("Usher speaks command format \(n), newer than this Leaf Juice knows. Update Leaf Juice.")
        case .unreadable: return .unavailable("Usher's list of commands couldn't be read.")
        case .outcome(let outcome): return .unavailable(Self.plain(outcome, doing: "Asking Usher what it offers"))
        }
        let have = Set(described.commands.map(\.name))
        if let missing = Self.usherCommandsNeeded.first(where: { !have.contains($0) }) {
            return .unavailable("This Usher (\(described.version)) has no \(missing) command. Leaf Juice needs Usher 0.4.0 or later.")
        }
        let reply = await commands.run("usher", ["profiles"])
        guard case .done(let answer) = reply.outcome else { return .unavailable(Self.plain(reply.outcome, doing: "Reading Usher's profiles")) }
        // problems: Usher's own config check, such as a profile left out because its group is missing.
        struct Wire: Decodable { let profiles: [UsherProfile]?; let luckperms: Bool?; let problems: [String]? }
        guard let wire = try? answer.decode(Wire.self) else { return .unavailable("Usher's profiles couldn't be read.") }
        return .ready(version: described.version, profiles: wire.profiles ?? [], luckPerms: wire.luckperms ?? false, problems: wire.problems ?? [])
    }

    public func usherShow(uuid: String) async -> Result<UsherPlayer, UsherProblem> {
        guard let dashed = AccountLookup.dashed(uuid) else { return .failure(UsherProblem("That account's ID isn't valid.")) }
        let reply = await commands.run("usher", ["show"], [.player(dashed)])
        guard case .done(let answer) = reply.outcome else { return .failure(UsherProblem(Self.plain(reply.outcome, doing: "Asking Usher"))) }
        guard let player = try? answer.decode(UsherPlayer.self) else { return .failure(UsherProblem("Usher's answer couldn't be read.")) }
        return .success(player)
    }

    /// Adds and removes profiles, then whitelists them, all in Usher. `yes` answers questions Usher asked before.
    public func usherApply(uuid: String, name: String, add: [String], remove: [String], yes: [String] = []) async -> UsherApplyResult {
        guard let dashed = AccountLookup.dashed(uuid) else { return .failed("That account's ID isn't valid.") }
        guard AccountLookup.isValidName(name) else { return .failed("That account's name isn't valid.") }
        // "none" means an empty list to Usher, so it can never be a profile here.
        guard (add + remove).allSatisfy({ $0 != "none" }) else { return .failed("A profile can't be called “none”.") }
        func list(_ ids: [String]) -> CommandArg { ids.isEmpty ? .word("none") : .list(ids.map { .word($0) }) }
        let reply = await commands.run("usher", ["apply"], [.uuid(dashed), .player(name), list(add), list(remove), .bool(true), .word("leaf-juice")], yes: yes)
        switch reply.outcome {
        case .done(let answer):
            struct Wire: Decodable { let message: String? }
            return .done((try? answer.decode(Wire.self).message).flatMap { $0 } ?? "Done.")
        case .needsYes(let questions): return .questions(questions)
        case .notConfirmed: return .notConfirmed
        case let other: return .failed(Self.plain(other, doing: "Changing \(name) in Usher"))
        }
    }

    public func usherAttempts(limit: Int = 20) async -> Result<[UsherAttempt], UsherProblem> {
        let reply = await commands.run("usher", ["attempts"], [.int(limit)])
        guard case .done(let answer) = reply.outcome else { return .failure(UsherProblem(Self.plain(reply.outcome, doing: "Asking Usher"))) }
        // The spec names a page's list `items`; Usher 0.4.0 calls it `attempts`. Either is read.
        struct Wire: Decodable { let items: [UsherAttempt]?; let attempts: [UsherAttempt]? }
        guard let wire = try? answer.decode(Wire.self) else { return .failure(UsherProblem("Usher's answer couldn't be read.")) }
        return .success(wire.items ?? wire.attempts ?? [])
    }

    static func plain(_ outcome: CommandOutcome, doing: String) -> String {
        switch outcome {
        case .done: return "\(doing) worked."
        case .failed(let e): return e.plainMessage
        case .needsYes(let qs): return qs.map(\.question).joined(separator: " ")
        case .notConfirmed: return "\(doing) got no answer in 15 seconds. It may still have happened, so check before trying again."
        case .refused(let why): return why
        }
    }
}

public struct UsherProblem: Error, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}
