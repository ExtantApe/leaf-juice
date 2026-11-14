import Foundation

// Sheriff looks after who may join and which profiles they have: a profile is a LuckPerms group plus the
// worlds and chat circle it opens, with Sheriff's own safety rules and change log. On a server with Sheriff,
// LeafJuice goes through Sheriff's commands (format 1) and never falls back to raw LuckPerms or
// `whitelist add`: owner decision, 2026-11-07, recorded in docs/PLAN.md.

public struct SheriffProfile: Sendable, Equatable, Decodable, Identifiable {
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

/// What `sheriff show` says about one account.
public struct SheriffPlayer: Sendable, Equatable, Decodable {
    public let profiles: [String]
    /// Profiles they get through some other group, which Sheriff can't take away here.
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

/// Someone the whitelist turned away, from `sheriff attempts`.
public struct SheriffAttempt: Sendable, Equatable, Decodable, Identifiable {
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

public enum SheriffStatus: Sendable, Equatable {
    case notInstalled
    /// Sheriff is on the server, but LeafJuice can't reach it right now. Changes are refused, never done another way.
    case unavailable(String)
    case ready(version: String, profiles: [SheriffProfile], luckPerms: Bool, problems: [String])

    public var isInstalled: Bool { self != .notInstalled }
}

public enum SheriffApplyResult: Sendable, Equatable {
    case done(String)
    /// Nothing changed. Each question needs a yes before sending again.
    case questions([ConfirmQuestion])
    case failed(String)
    /// No answer in time. It may still have happened.
    case notConfirmed
}

extension ServerController {
    public var hasSheriff: Bool { plugins.contains { $0.enabled && $0.key == "sheriff" } }

    /// The commands LeafJuice needs, as `describe` names them.
    static let sheriffCommandsNeeded = ["profiles", "show", "apply", "attempts"]

    /// Whether LeafJuice can go through Sheriff on this server now, and its profiles if so.
    public func sheriffStatus() async -> SheriffStatus {
        guard hasSheriff else { return .notInstalled }
        guard Modules.shared.isOn(.pluginCommands) else {
            return .unavailable("Sheriff looks after who can join this server. Turn on Plugin commands so LeafJuice can go through it.")
        }
        guard state == .running, process != nil else {
            return .unavailable("Sheriff can only be reached while LeafJuice runs this server. Start it here first.")
        }
        let described: PluginDescription
        switch await commands.describe("sheriff") {
        case .described(let d): described = d
        case .newerFormat(let n): return .unavailable("Sheriff speaks command format \(n), newer than this LeafJuice knows. Update LeafJuice.")
        case .unreadable: return .unavailable("Sheriff's list of commands couldn't be read.")
        case .outcome(let outcome): return .unavailable(Self.plain(outcome, doing: "Asking Sheriff what it offers"))
        }
        let have = Set(described.commands.map(\.name))
        if let missing = Self.sheriffCommandsNeeded.first(where: { !have.contains($0) }) {
            return .unavailable("This Sheriff (\(described.version)) has no \(missing) command. LeafJuice needs Sheriff 0.5.0 or later.")
        }
        let reply = await commands.run("sheriff", ["profiles"])
        guard case .done(let answer) = reply.outcome else { return .unavailable(Self.plain(reply.outcome, doing: "Reading Sheriff's profiles")) }
        // problems: Sheriff's own config check, such as a profile left out because its group is missing.
        struct Wire: Decodable { let profiles: [SheriffProfile]?; let luckperms: Bool?; let problems: [String]? }
        guard let wire = try? answer.decode(Wire.self) else { return .unavailable("Sheriff's profiles couldn't be read.") }
        return .ready(version: described.version, profiles: wire.profiles ?? [], luckPerms: wire.luckperms ?? false, problems: wire.problems ?? [])
    }

    public func sheriffShow(uuid: String) async -> Result<SheriffPlayer, SheriffProblem> {
        guard let dashed = AccountLookup.dashed(uuid) else { return .failure(SheriffProblem("That account's ID isn't valid.")) }
        let reply = await commands.run("sheriff", ["show"], [.player(dashed)])
        guard case .done(let answer) = reply.outcome else { return .failure(SheriffProblem(Self.plain(reply.outcome, doing: "Asking Sheriff"))) }
        guard let player = try? answer.decode(SheriffPlayer.self) else { return .failure(SheriffProblem("Sheriff's answer couldn't be read.")) }
        return .success(player)
    }

    /// Adds and removes profiles, then whitelists them, all in Sheriff. `yes` answers questions Sheriff asked before.
    public func sheriffApply(uuid: String, name: String, add: [String], remove: [String], yes: [String] = []) async -> SheriffApplyResult {
        guard let dashed = AccountLookup.dashed(uuid) else { return .failed("That account's ID isn't valid.") }
        guard AccountLookup.isValidName(name) else { return .failed("That account's name isn't valid.") }
        // "none" means an empty list to Sheriff, so it can never be a profile here.
        guard (add + remove).allSatisfy({ $0 != "none" }) else { return .failed("A profile can't be called “none”.") }
        func list(_ ids: [String]) -> CommandArg { ids.isEmpty ? .word("none") : .list(ids.map { .word($0) }) }
        let reply = await commands.run("sheriff", ["apply"], [.uuid(dashed), .player(name), list(add), list(remove), .bool(true), .word("leaf-juice")], yes: yes)
        switch reply.outcome {
        case .done(let answer):
            struct Wire: Decodable { let message: String? }
            return .done((try? answer.decode(Wire.self).message).flatMap { $0 } ?? "Done.")
        case .needsYes(let questions): return .questions(questions)
        case .notConfirmed: return .notConfirmed
        case let other: return .failed(Self.plain(other, doing: "Changing \(name) in Sheriff"))
        }
    }

    public func sheriffAttempts(limit: Int = 20) async -> Result<[SheriffAttempt], SheriffProblem> {
        let reply = await commands.run("sheriff", ["attempts"], [.int(limit)])
        guard case .done(let answer) = reply.outcome else { return .failure(SheriffProblem(Self.plain(reply.outcome, doing: "Asking Sheriff"))) }
        // The spec names a page's list `items`; the plugin's 0.4 releases, before it was Sheriff, call it `attempts`. Either is read.
        struct Wire: Decodable { let items: [SheriffAttempt]?; let attempts: [SheriffAttempt]? }
        guard let wire = try? answer.decode(Wire.self) else { return .failure(SheriffProblem("Sheriff's answer couldn't be read.")) }
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

public struct SheriffProblem: Error, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}
