import CryptoKit
import Darwin
import Foundation

// Latchkey owns invites and browser sessions. Leaf Juice makes and lists invites through Latchkey's format-1
// commands, so it can do that only while it runs the server. It checks a sign-in by reading Latchkey's session
// file. Agreed with the Plugins Lead and decided by the owner on 2026-11-09; see docs/PLAN.md.

public struct LatchkeyInvite: Sendable, Equatable, Decodable, Identifiable {
    /// Latchkey's own id for the invite, 8 hex characters. Not the code.
    public let invite: String
    public let uuid: String
    public let name: String
    public let profiles: [String]
    public let status: String
    public let created: Date
    public let expires: Date
    public var id: String { invite }

    /// Pending, but past its expiry: Latchkey keeps it as pending and refuses it when it's used.
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

public enum LatchkeyStatus: Sendable, Equatable {
    case notInstalled
    case unavailable(String)
    /// `invitesWork` is false when Latchkey won't make invites (`/latchkey status` says why, in `problems`).
    /// `lobby` is whether Latchkey's lobby is on, from 0.3.0; nil when this Latchkey doesn't say.
    case ready(version: String, invitesWork: Bool, publicURL: String?, problems: [String], lobby: Bool?)
}

/// A new invite: the code is shown once, then forgotten.
public struct NewInvite: Sendable, Equatable {
    public let invite: LatchkeyInvite
    public let code: String
    /// Latchkey's own warning, such as profiles nobody checked.
    public let warning: String?
}

public struct InviteList: Sendable, Equatable {
    public let invites: [LatchkeyInvite]
    /// True when there were more than Leaf Juice read, or a cursor it wouldn't send back.
    public let more: Bool
}

public enum InviteResult: Sendable, Equatable {
    case made(NewInvite)
    case questions([ConfirmQuestion])
    case failed(String)
    case notConfirmed
}

extension ServerController {

    static let latchkeyCommandsNeeded = ["invite create", "invite list", "invite revoke", "status"]

    public func latchkeyStatus() async -> LatchkeyStatus {
        guard hasLatchkey else { return .notInstalled }
        guard Modules.shared.isOn(.pluginCommands) else {
            return .unavailable("Turn on Plugin commands so Leaf Juice can make invites through Latchkey.")
        }
        guard state == .running, process != nil else {
            return .unavailable("Invites from Leaf Juice only work while Leaf Juice runs this server, because it types Latchkey's commands into the console. Start it here first.")
        }
        let described: PluginDescription
        switch await commands.describe("latchkey") {
        case .described(let d): described = d
        case .newerFormat(let n): return .unavailable("Latchkey speaks command format \(n), newer than this Leaf Juice knows. Update Leaf Juice.")
        case .unreadable: return .unavailable("Latchkey's list of commands couldn't be read.")
        case .outcome(let outcome): return .unavailable(Self.plain(outcome, doing: "Asking Latchkey what it offers"))
        }
        let have = Set(described.commands.map(\.name))
        if let missing = Self.latchkeyCommandsNeeded.first(where: { !have.contains($0) }) {
            return .unavailable("This Latchkey (\(described.version)) has no \(missing) command. Leaf Juice needs Latchkey 0.2.0 or later.")
        }
        let reply = await commands.run("latchkey", ["status"])
        guard case .done(let answer) = reply.outcome else { return .unavailable(Self.plain(reply.outcome, doing: "Asking Latchkey how it's set up")) }
        struct Wire: Decodable { let redemption: Bool?; let publicUrl: String?; let problems: [String]?; let lobby: Bool? }
        guard let wire = try? answer.decode(Wire.self) else { return .unavailable("Latchkey's status couldn't be read.") }
        return .ready(version: described.version, invitesWork: wire.redemption ?? false, publicURL: wire.publicUrl,
                      problems: wire.problems ?? [], lobby: wire.lobby)
    }

    /// Makes an invite for a name, with Usher profiles. The code comes back once, from Latchkey's once-file.
    public func createInvite(name: String, profiles: [String], days: Int, yes: [String] = []) async -> InviteResult {
        guard AccountLookup.isValidName(name) else { return .failed("That can't be a Minecraft name.") }
        guard (1...30).contains(days) else { return .failed("An invite lasts from 1 to 30 days.") }
        guard profiles.allSatisfy({ $0 != "none" }) else { return .failed("A profile can't be called “none”.") }
        let list: CommandArg = profiles.isEmpty ? .word("none") : .list(profiles.map { .word($0) })
        let reply = await commands.run("latchkey", ["invite", "create"], [.player(name), list, .duration(days, .d)], yes: yes)
        switch reply.outcome {
        case .done(let answer):
            guard let file = answer.secretFile else { return .failed("Latchkey made the invite but didn't say where its code is. Revoke it and make another.") }
            struct Wire: Decodable { let warning: String? }
            guard let invite = try? answer.decode(LatchkeyInvite.self) else { return .failed("Latchkey's answer couldn't be read. Check the invite list, and revoke anything you don't recognise.") }
            switch OnceSecrets.take(serverRoot: paths.root, plugin: "Latchkey", requestID: reply.id, secretFile: file) {
            case .success(let secret):
                return .made(NewInvite(invite: invite, code: secret.value, warning: (try? answer.decode(Wire.self))?.warning))
            case .failure(let problem):
                return .failed(problem.message + " The invite was made without a code you can see, so revoke it and make another.")
            }
        case .needsYes(let questions): return .questions(questions)
        case .notConfirmed: return .notConfirmed
        case let other: return .failed(Self.plain(other, doing: "Making the invite"))
        }
    }

    /// Pages through Latchkey's invites, newest first. Stops at `maxPages`, and says so with `more`.
    /// Latchkey 0.3.0 pages the spec's way (`items`, a string `next`); 0.2.0 answers one page as `invites`,
    /// and its numeric `next` isn't a cursor it takes back, so only the first page of that is read.
    public func listInvites(pageSize: Int = 50, maxPages: Int = 10) async -> Result<InviteList, UsherProblem> {
        var all: [LatchkeyInvite] = []
        var cursor: String?
        for _ in 0..<maxPages {
            var args: [CommandArg] = [.int(pageSize)]
            if let cursor { args.append(.word(cursor)) }
            let reply = await commands.run("latchkey", ["invite", "list"], args)
            guard case .done(let answer) = reply.outcome else { return .failure(UsherProblem(Self.plain(reply.outcome, doing: "Asking Latchkey"))) }
            struct Wire: Decodable { let items: [LatchkeyInvite]?; let invites: [LatchkeyInvite]? }
            guard let wire = try? answer.decode(Wire.self) else { return .failure(UsherProblem("Latchkey's list couldn't be read.")) }
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
        let reply = await commands.run("latchkey", ["invite", "revoke"], [.word(invite)])
        if case .done = reply.outcome { return nil }
        return Self.plain(reply.outcome, doing: "Revoking the invite")
    }
}

/// Reads Latchkey's file for one browser session. Format agreed 2026-11-09:
/// `plugins/Latchkey/sessions/<lowercase hex SHA-256 of the cookie as sent>.json`, folder 0700, file 0600, holding
/// `{"uuid", "name", "expires", "since"}` in Unix seconds. Unknown keys are ignored. Anything odd is no session.
public enum LatchkeySessions {
    public static let cookie = "latchkey_session"
    public static let longest: TimeInterval = 30 * 24 * 60 * 60

    public struct Session: Sendable, Equatable {
        public let uuid: String
        public let name: String
        public let since: Date
        public let expires: Date
    }

    /// The cookie's value from a Cookie header, if it looks like one Latchkey could have set.
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
        let folder = plugins.appendingPathComponent("Latchkey/sessions", isDirectory: true)
        let file = folder.appendingPathComponent("\(name).json")
        var dir = stat(), info = stat()
        guard lstat(folder.path, &dir) == 0, (dir.st_mode & S_IFMT) == S_IFDIR, (dir.st_mode & 0o077) == 0, dir.st_uid == getuid() else { return nil }
        guard folder.resolvingSymlinksInPath().path == plugins.resolvingSymlinksInPath().appendingPathComponent("Latchkey/sessions").path else { return nil }
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
        // The same limits Latchkey keeps: after sign-in, at most 30 days from it, and not yet run out.
        guard expires > since, expires.timeIntervalSince(since) <= longest, since <= now.addingTimeInterval(60), expires > now else { return nil }
        return Session(uuid: wire.uuid, name: wire.name, since: since, expires: expires)
    }
}
