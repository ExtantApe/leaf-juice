import CryptoKit
import Darwin
import Foundation

// WelcomeWagon owns invites and browser sessions. LeafJuice makes and lists invites through WelcomeWagon's format-1
// commands, so it can do that only while it runs the server. It checks a sign-in by reading WelcomeWagon's session
// file. Agreed with the Plugins Lead and decided by the owner on 2026-11-09; see docs/PLAN.md.

public struct WelcomeWagonInvite: Sendable, Equatable, Decodable, Identifiable {
    /// WelcomeWagon's own id for the invite, 8 hex characters. Not the code.
    public let invite: String
    public let uuid: String
    public let name: String
    public let profiles: [String]
    public let status: String
    public let created: Date
    public let expires: Date
    public var id: String { invite }

    /// Pending, but past its expiry: WelcomeWagon keeps it as pending and refuses it when it's used.
    public func isOpen(now: Date = Date()) -> Bool { status == "pending" && expires > now }
    public func stateText(now: Date = Date()) -> String {
        switch status {
        case "pending": expires > now ? "Waiting" : "Expired"
        case "redeemed", "used": "Used"
        case "revoked": "Revoked"
        default: status.capitalized
        }
    }

    enum CodingKeys: String, CodingKey { case invite, uuid, name, profiles, status, created, expires }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        invite = try c.decode(String.self, forKey: .invite)
        uuid = try c.decode(String.self, forKey: .uuid).lowercased()
        name = try c.decode(String.self, forKey: .name)
        profiles = try c.decodeIfPresent([String].self, forKey: .profiles) ?? []
        status = try c.decode(String.self, forKey: .status)
        created = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .created))
        expires = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .expires))
    }
}

public enum WelcomeWagonStatus: Sendable, Equatable {
    case notInstalled
    case unavailable(String)
    /// `invitesWork` is false when WelcomeWagon won't make invites (`/welcomewagon status` says why, in `problems`).
    /// `lobby` is whether WelcomeWagon's lobby is on, from 0.3.0; nil when this WelcomeWagon doesn't say.
    case ready(version: String, invitesWork: Bool, publicURL: String?, problems: [String], lobby: Bool?)
}

/// A new invite: the code is shown once, then forgotten.
public struct NewInvite: Sendable, Equatable {
    public let invite: WelcomeWagonInvite
    public let code: String
    /// WelcomeWagon's own warning, such as profiles nobody checked.
    public let warning: String?
    /// A printable ticket, when invites can be used on the page (D187).
    public let ticket: InviteTicket?
    public init(invite: WelcomeWagonInvite, code: String, warning: String?, ticket: InviteTicket? = nil) {
        self.invite = invite; self.code = code; self.warning = warning; self.ticket = ticket
    }
}

public struct InviteList: Sendable, Equatable {
    public let invites: [WelcomeWagonInvite]
    /// True when there were more than LeafJuice read, or a cursor it wouldn't send back.
    public let more: Bool
}

public enum InviteResult: Sendable, Equatable {
    case made(NewInvite)
    case questions([ConfirmQuestion])
    case failed(String)
    case notConfirmed
}

extension ServerController {

    static let welcomewagonCommandsNeeded = ["invite create", "invite list", "invite revoke", "status"]

    public func welcomewagonStatus() async -> WelcomeWagonStatus {
        guard hasWelcomeWagon else { return .notInstalled }
        guard Modules.shared.isOn(.pluginCommands) else {
            return .unavailable("Turn on Plugin commands so LeafJuice can make invites through WelcomeWagon.")
        }
        guard state == .running, process != nil else {
            return .unavailable("Invites from LeafJuice only work while LeafJuice runs this server, because it types WelcomeWagon's commands into the console. Start it here first.")
        }
        let described: PluginDescription
        switch await commands.describe("welcomewagon") {
        case .described(let d): described = d
        case .newerFormat(let n): return .unavailable("WelcomeWagon speaks command format \(n), newer than this LeafJuice knows. Update LeafJuice.")
        case .unreadable: return .unavailable("WelcomeWagon's list of commands couldn't be read.")
        case .outcome(let outcome): return .unavailable(Self.plain(outcome, doing: "Asking WelcomeWagon what it offers"))
        }
        let have = Set(described.commands.map(\.name))
        if let missing = Self.welcomewagonCommandsNeeded.first(where: { !have.contains($0) }) {
            return .unavailable("This WelcomeWagon (\(described.version)) has no \(missing) command. This WelcomeWagon is too old for LeafJuice. Update it.")
        }
        let reply = await commands.run("welcomewagon", ["status"])
        guard case .done(let answer) = reply.outcome else { return .unavailable(Self.plain(reply.outcome, doing: "Asking WelcomeWagon how it's set up")) }
        struct Wire: Decodable { let redemption: Bool?; let publicUrl: String?; let problems: [String]?; let lobby: Bool? }
        guard let wire = try? answer.decode(Wire.self) else { return .unavailable("WelcomeWagon's status couldn't be read.") }
        return .ready(version: described.version, invitesWork: wire.redemption ?? false, publicURL: wire.publicUrl,
                      problems: wire.problems ?? [], lobby: wire.lobby)
    }

    /// Makes an invite for a name, with Sheriff profiles. The code comes back once, from WelcomeWagon's once-file.
    public func createInvite(name: String, profiles: [String], days: Int, yes: [String] = []) async -> InviteResult {
        guard AccountLookup.isValidName(name) else { return .failed("That can't be a Minecraft name.") }
        guard (1...30).contains(days) else { return .failed("An invite lasts from 1 to 30 days.") }
        guard profiles.allSatisfy({ $0 != "none" }) else { return .failed("A profile can't be called “none”.") }
        let list: CommandArg = profiles.isEmpty ? .word("none") : .list(profiles.map { .word($0) })
        let reply = await commands.run("welcomewagon", ["invite", "create"], [.player(name), list, .duration(days, .d)], yes: yes)
        switch reply.outcome {
        case .done(let answer):
            guard let file = answer.secretFile else { return .failed("WelcomeWagon made the invite but didn't say where its code is. Revoke it and make another.") }
            struct Wire: Decodable { let warning: String?; let ticket: InviteTicket.Wire? }
            guard let invite = try? answer.decode(WelcomeWagonInvite.self) else { return .failed("WelcomeWagon's answer couldn't be read. Check the invite list, and revoke anything you don't recognise.") }
            switch OnceSecrets.take(serverRoot: paths.root, plugin: "WelcomeWagon", requestID: reply.id, secretFile: file) {
            case .success(let secret):
                let wire = try? answer.decode(Wire.self)
                return .made(NewInvite(invite: invite, code: secret.value, warning: wire?.warning, ticket: InviteTicket.make(wire?.ticket, code: secret.value)))
            case .failure(let problem):
                return .failed(problem.message + " The invite was made without a code you can see, so revoke it and make another.")
            }
        case .needsYes(let questions): return .questions(questions)
        case .notConfirmed: return .notConfirmed
        case let other: return .failed(Self.plain(other, doing: "Making the invite"))
        }
    }

    /// Pages through WelcomeWagon's invites, newest first. Stops at `maxPages`, and says so with `more`.
    /// The 0.3.0 release pages the spec's way (`items`, a string `next`); 0.2.0 answers one page as `invites`,
    /// and its numeric `next` isn't a cursor it takes back, so only the first page of that is read.
    public func listInvites(pageSize: Int = 50, maxPages: Int = 10) async -> Result<InviteList, SheriffProblem> {
        var all: [WelcomeWagonInvite] = []
        var cursor: String?
        for _ in 0..<maxPages {
            var args: [CommandArg] = [.int(pageSize)]
            if let cursor { args.append(.word(cursor)) }
            let reply = await commands.run("welcomewagon", ["invite", "list"], args)
            guard case .done(let answer) = reply.outcome else { return .failure(SheriffProblem(Self.plain(reply.outcome, doing: "Asking WelcomeWagon"))) }
            struct Wire: Decodable { let items: [WelcomeWagonInvite]?; let invites: [WelcomeWagonInvite]? }
            guard let wire = try? answer.decode(Wire.self) else { return .failure(SheriffProblem("WelcomeWagon's list couldn't be read.")) }
            all += wire.items ?? wire.invites ?? []
            guard wire.items != nil, let next = answer.next else { return .success(InviteList(invites: all, more: false)) }
            // A cursor goes back as a plain word; anything else ends the list here rather than being typed.
            guard Self.isCursor(next), next != cursor else { return .success(InviteList(invites: all, more: true)) }
            cursor = next
        }
        return .success(InviteList(invites: all, more: true))
    }

    static func isCursor(_ s: String) -> Bool { PluginCommandWire.matches(PluginCommandWire.wordPattern, s) && !s.hasPrefix("-") }

    public func revokeInvite(_ invite: String) async -> String? {
        guard invite.count == 8, invite.allSatisfy({ "0123456789abcdef".contains($0) }) else { return "That isn't an invite id." }
        let reply = await commands.run("welcomewagon", ["invite", "revoke"], [.word(invite)])
        if case .done = reply.outcome { return nil }
        return Self.plain(reply.outcome, doing: "Revoking the invite")
    }
}

/// Someone's browser sign-ins, as WelcomeWagon counts them.
public enum WelcomeWagonSignIns: Sendable, Equatable {
    /// This WelcomeWagon's `describe` doesn't offer `session list` and `session revoke`, so nothing is shown.
    case unsupported
    case signedIn(browsers: Int)
    case problem(String)
}

extension ServerController {
    static let welcomewagonSessionCommands = ["session list", "session revoke"]

    /// Whether this WelcomeWagon offers every one of `names`, from its own `describe`. False when it can't be asked.
    func welcomewagonOffers(_ names: [String]) async -> Bool {
        guard hasWelcomeWagon, Modules.shared.isOn(.pluginCommands), state == .running, process != nil,
              case .described(let d) = await commands.describe("welcomewagon") else { return false }
        let have = Set(d.commands.map(\.name))
        return names.allSatisfy(have.contains)
    }

    /// How many browsers someone is signed in on. Nothing is said when WelcomeWagon doesn't offer it.
    public func welcomewagonSignIns(name: String) async -> WelcomeWagonSignIns {
        guard AccountLookup.isValidName(name) else { return .problem("That account's name isn't valid.") }
        guard await welcomewagonOffers(Self.welcomewagonSessionCommands) else { return .unsupported }
        let reply = await commands.run("welcomewagon", ["session", "list"], [.player(name)])
        guard case .done(let answer) = reply.outcome else { return .problem(Self.plain(reply.outcome, doing: "Asking WelcomeWagon")) }
        struct Wire: Decodable { let sessions: Int }
        guard let wire = try? answer.decode(Wire.self), wire.sessions >= 0 else { return .problem("WelcomeWagon's answer couldn't be read.") }
        return .signedIn(browsers: wire.sessions)
    }

    /// Ends every browser sign-in someone has. Their allowlist place and profiles stay.
    public func signOutEverywhere(name: String) async -> Result<Int, SheriffProblem> {
        guard AccountLookup.isValidName(name) else { return .failure(SheriffProblem("That account's name isn't valid.")) }
        guard await welcomewagonOffers(Self.welcomewagonSessionCommands) else { return .failure(SheriffProblem("This WelcomeWagon can't sign people out from LeafJuice.")) }
        let reply = await commands.run("welcomewagon", ["session", "revoke"], [.player(name)])
        guard case .done(let answer) = reply.outcome else { return .failure(SheriffProblem(Self.plain(reply.outcome, doing: "Signing \(name) out"))) }
        struct Wire: Decodable { let ended: Int }
        guard let wire = try? answer.decode(Wire.self) else { return .failure(SheriffProblem("WelcomeWagon signed them out, but its answer couldn't be read. Check again.")) }
        return .success(wire.ended)
    }
}

/// Reads WelcomeWagon's file for one browser session. Format agreed 2026-11-09:
/// `plugins/WelcomeWagon/sessions/<lowercase hex SHA-256 of the cookie as sent>.json`, folder 0700, file 0600, holding
/// `{"uuid", "name", "expires", "since"}` in Unix seconds. Unknown keys are ignored. Anything odd is no session.
public enum WelcomeWagonSessions {
    public static let cookie = "welcomewagon_session"
    public static let longest: TimeInterval = 30 * 24 * 60 * 60

    public struct Session: Sendable, Equatable {
        public let uuid: String
        public let name: String
        public let since: Date
        public let expires: Date
    }

    /// The cookie's value from a Cookie header, if it looks like one WelcomeWagon could have set.
    public static func cookieValue(_ header: String?) -> String? {
        guard let header else { return nil }
        for part in header.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard pair.hasPrefix("\(cookie)=") else { continue }
            let value = String(pair.dropFirst(cookie.count + 1))
            guard (16...256).contains(value.count), value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.~+/=".contains($0)) }) else { return nil }
            return value
        }
        return nil
    }

    /// Read fresh every time, so an extension, a revoke or an expiry counts at once.
    public static func read(plugins: URL, cookieValue value: String, now: Date = Date()) -> Session? {
        let name = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = plugins.appendingPathComponent("WelcomeWagon/sessions", isDirectory: true)
        let file = folder.appendingPathComponent("\(name).json")
        var dir = stat(), info = stat()
        guard lstat(folder.path, &dir) == 0, (dir.st_mode & S_IFMT) == S_IFDIR, (dir.st_mode & 0o077) == 0, dir.st_uid == getuid() else { return nil }
        guard folder.resolvingSymlinksInPath().path == plugins.resolvingSymlinksInPath().appendingPathComponent("WelcomeWagon/sessions").path else { return nil }
        guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, (info.st_mode & 0o077) == 0,
              info.st_uid == getuid(), info.st_size <= 4096 else { return nil }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: true).readDataToEndOfFile()
        struct Wire: Decodable { let uuid: String; let name: String; let expires: Double; let since: Double }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data),
              PluginCommandWire.matches(PluginCommandWire.uuidPattern, wire.uuid),
              AccountLookup.isValidName(wire.name) else { return nil }
        let since = Date(timeIntervalSince1970: wire.since), expires = Date(timeIntervalSince1970: wire.expires)
        // The same limits WelcomeWagon keeps: after sign-in, at most 30 days from it, and not yet run out.
        guard expires > since, expires.timeIntervalSince(since) <= longest, since <= now.addingTimeInterval(60), expires > now else { return nil }
        return Session(uuid: wire.uuid, name: wire.name, since: since, expires: expires)
    }
}
