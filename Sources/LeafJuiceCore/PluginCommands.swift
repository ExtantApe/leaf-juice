import Darwin
import Foundation

// The shared plugin command format, format 1 (ops `briefs/plugin-commands-spec.md`, agreed 2026-11-09).
//
// LeafJuice types a command into the console of a server it started, with `--json <id>` on the end.
// The plugin answers with one line, `ea-result <id> <json>`. LeafJuice reads only lines where that
// prefix comes straight after the log header, so a player typing "ea-result …" in chat (logged as
// `]: <Name> ea-result …`) never matches. Ids are 32 random hex characters, only the first answer to
// an id counts, and answers to ids LeafJuice didn't send are ignored.
//
// Secrets never come through the console. The answer names a file in `plugins/<Plugin>/once/`, and
// `OnceSecrets.take` reads it once and deletes it.

/// One argument, written the way format 1 says.
public enum CommandArg: Sendable, Equatable {
    /// A plain token: no spaces, quotes, backslashes or control characters, and never starting with `-`.
    case word(String)
    case int(Int)
    case bool(Bool)
    /// A player's name or uuid. Answers always give the uuid.
    case player(String)
    case uuid(String)
    /// One of the values `describe` lists: `[a-z0-9-]`.
    case choice(String)
    case duration(Int, DurationUnit)
    /// Comma-separated with no spaces. Values can't contain commas, and lists don't nest.
    case list([CommandArg])
    /// Free text. Only one, and it must come last. Sent in double quotes with `\"` and `\\` escapes.
    case text(String)

    public enum DurationUnit: String, Sendable { case s, m, h, d }
}

public enum PluginCommandWire {
    public static let format = 1
    public static let maxAnswerBytes = 8192
    static let idPattern = regex(#"^[a-z0-9-]{1,36}\z"#)
    static let labelPattern = regex(#"^[a-z0-9_-]{1,32}\z"#)
    static let wordPattern = regex(#"^[a-z0-9-]{1,32}\z"#)
    static let playerNamePattern = regex(#"^\.?[A-Za-z0-9_]{1,16}\z"#)
    static let uuidPattern = regex(#"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z"#)
    static let choicePattern = regex(#"^[a-z0-9][a-z0-9-]{0,63}\z"#)

    /// 32 hex characters from the system's secure random source, so nobody can guess one.
    public static func newID() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
    }

    static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The whole command line, or why LeafJuice won't send it.
    /// Flags go after every argument, including free text: `<plugin> <subcommand…> <args…> [--yes a,b] --json <id>`.
    public static func line(plugin: String, subcommand: [String], args: [CommandArg], yes: [String] = [], id: String) -> Result<String, CommandRefusal> {
        guard matches(labelPattern, plugin) else { return .failure(.init("“\(plugin)” isn't a plugin command LeafJuice can send.")) }
        guard !subcommand.isEmpty, subcommand.allSatisfy({ matches(wordPattern, $0) }) else { return .failure(.init("That isn't a subcommand LeafJuice can send.")) }
        guard matches(idPattern, id) else { return .failure(.init("Bad request id.")) }
        guard yes.allSatisfy({ matches(choicePattern, $0) }) else { return .failure(.init("Bad confirm question id.")) }
        var parts = [plugin] + subcommand
        for (i, arg) in args.enumerated() {
            if case .text = arg, i != args.count - 1 { return .failure(.init("Free text has to be the last argument.")) }
            switch encode(arg, inList: false) {
            case .success(let token): parts.append(token)
            case .failure(let refusal): return .failure(refusal)
            }
        }
        if !yes.isEmpty { parts += ["--yes", yes.joined(separator: ",")] }
        parts += ["--json", id]
        return .success(parts.joined(separator: " "))
    }

    static func encode(_ arg: CommandArg, inList: Bool) -> Result<String, CommandRefusal> {
        switch arg {
        case .word(let w):
            let bad = w.isEmpty || w.hasPrefix("-") || w.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "\\" || (inList && $0 == ",") })
                || w.unicodeScalars.contains(where: isControl)
            return bad ? .failure(.init("“\(w)” can't be sent as a single word.")) : .success(w)
        case .int(let n): return .success(String(n))
        case .bool(let b): return .success(b ? "true" : "false")
        case .player(let p):
            if matches(playerNamePattern, p) { return .success(p) }
            let lower = p.lowercased()
            return matches(uuidPattern, lower) ? .success(lower) : .failure(.init("“\(p)” isn't a player name or uuid."))
        case .uuid(let u):
            let lower = u.lowercased()
            return matches(uuidPattern, lower) ? .success(lower) : .failure(.init("“\(u)” isn't a uuid."))
        case .choice(let c):
            return matches(choicePattern, c) ? .success(c) : .failure(.init("“\(c)” isn't one of the choices."))
        case .duration(let n, let unit):
            return n >= 0 ? .success("\(n)\(unit.rawValue)") : .failure(.init("A duration can't be negative."))
        case .list(let items):
            guard !inList else { return .failure(.init("Lists can't hold lists.")) }
            guard !items.isEmpty else { return .failure(.init("An empty list can't be sent; leave the argument out.")) }
            var out: [String] = []
            for item in items {
                if case .text = item { return .failure(.init("Free text can't go in a list.")) }
                switch encode(item, inList: true) {
                case .success(let t): out.append(t)
                case .failure(let r): return .failure(r)
                }
            }
            return .success(out.joined(separator: ","))
        case .text(let t):
            guard !t.unicodeScalars.contains(where: isControl) else { return .failure(.init("The text can't contain line breaks or control characters.")) }
            return .success("\"" + t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"")
        }
    }

    static func isControl(_ s: Unicode.Scalar) -> Bool {
        s.properties.generalCategory == .control || s.properties.generalCategory == .format || s == "\u{2028}" || s == "\u{2029}"
    }

    /// `[12:00:00 INFO]: ` as Paper writes to the console, or `[12:00:00] [Server thread/INFO]: ` as in log files.
    /// Only INFO: a plugin's `sendMessage` to the console is logged at INFO.
    static let headerPattern = regex(#"^(?:\[\d{2}:\d{2}:\d{2} INFO\]|\[\d{2}:\d{2}:\d{2}\] \[[^\[\]/]+/INFO\]): ea-result ([a-z0-9-]{1,36}) (\{.*)$"#)

    /// The id and JSON from a console line, if `ea-result ` comes straight after the log header.
    /// Anywhere else in the line, such as after a player's name in chat, it isn't an answer.
    public static func answerLine(_ raw: String) -> (id: String, json: String)? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        guard let m = headerPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), m.numberOfRanges == 3,
              let idRange = Range(m.range(at: 1), in: line), let jsonRange = Range(m.range(at: 2), in: line) else { return nil }
        return (String(line[idRange]), String(line[jsonRange]))
    }
}

public struct CommandRefusal: Error, Sendable, Equatable {
    public let message: String
    init(_ message: String) { self.message = message }
}

public struct CommandError: Sendable, Equatable {
    public let code: String
    public let message: String

    /// The codes every plugin uses where they fit. Plugins can add their own, listed in `describe`.
    public static let baseCodes = ["unknown-command", "bad-argument", "no-permission", "not-found", "needs-online-player", "busy", "internal"]
    /// LeafJuice's own codes, for answers it couldn't use.
    public static let badAnswer = "bad-answer"
    public static let tooLong = "answer-too-long"

    /// What to show. The plugin's own words come first; these only fill in when it gave none.
    public var plainMessage: String {
        let given = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !given.isEmpty { return given }
        switch code {
        case "unknown-command": return "The plugin doesn't know that command. It may be an older version."
        case "bad-argument": return "The plugin couldn't use one of the values."
        case "no-permission": return "The server's console isn't allowed to do that."
        case "not-found": return "The plugin couldn't find that."
        case "needs-online-player": return "That player has to be online."
        case "busy": return "The plugin is busy. Try again in a moment."
        case "internal": return "Something went wrong inside the plugin. Its log may say more."
        case Self.badAnswer: return "The plugin's answer couldn't be read."
        case Self.tooLong: return "The plugin's answer was longer than the format allows."
        default: return "The plugin refused (\(code))."
        }
    }
}

public struct ConfirmQuestion: Sendable, Equatable, Codable {
    public let id: String
    public let question: String
}

/// A successful answer. Fields a caller needs beyond these are in `json`.
public struct CommandAnswer: Sendable {
    public let id: String
    /// The cursor for the next page, when a list goes on.
    public let next: String?
    /// Where a secret was left, relative to the plugin's folder: `once/<id>.json`.
    public let secretFile: String?
    public let json: Data

    public func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: json) }
}

public enum CommandOutcome: Sendable {
    case done(CommandAnswer)
    case failed(CommandError)
    /// Nothing changed. Send it again with `--yes` and every one of these ids to go ahead.
    case needsYes([ConfirmQuestion])
    /// No answer in time. It may still have happened: re-read the state rather than saying it failed.
    case notConfirmed
    /// LeafJuice didn't send it.
    case refused(String)

    /// Decodes one answer's JSON, checking it's for this id.
    static func from(id: String, json: String) -> CommandOutcome {
        guard json.utf8.count <= PluginCommandWire.maxAnswerBytes else {
            return .failed(CommandError(code: CommandError.tooLong, message: ""))
        }
        struct Wire: Decodable {
            let id: String
            let ok: Bool
            let error: Err?
            let needs: [ConfirmQuestion]?
            let next: Cursor?
            let secretFile: String?
            struct Err: Decodable { let code: String; let message: String? }
        }
        /// The spec's cursor is a string. Usher 0.4.0 sends a number, so either is taken, as text.
        struct Cursor: Decodable {
            let text: String
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { text = s } else { text = String(try c.decode(Int.self)) }
            }
        }
        let data = Data(json.utf8)
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data), wire.id == id else {
            return .failed(CommandError(code: CommandError.badAnswer, message: ""))
        }
        if wire.ok { return .done(CommandAnswer(id: id, next: wire.next?.text, secretFile: wire.secretFile, json: data)) }
        if let needs = wire.needs, !needs.isEmpty { return .needsYes(needs) }
        if let err = wire.error, !err.code.isEmpty { return .failed(CommandError(code: err.code, message: err.message ?? "")) }
        return .failed(CommandError(code: CommandError.badAnswer, message: ""))
    }
}

public struct CommandReply: Sendable {
    public let id: String
    public let outcome: CommandOutcome
}

/// Sends commands and matches answers, for one server.
@MainActor
public final class PluginCommandRunner {
    public nonisolated static let defaultTimeout: Duration = .seconds(15)
    public var timeout: Duration
    private let send: (String) -> Bool
    private let isEnabled: () -> Bool
    private var waiting: [String: CheckedContinuation<CommandOutcome, Never>] = [:]
    /// Ids that timed out, oldest first. A late answer to one is passed on once, then forgotten.
    private var late: [String] = []
    private var used: Set<String> = []
    /// Called with a late answer to a command that had timed out.
    public var onLateAnswer: ((CommandReply) -> Void)?
    /// Answer-shaped lines that were ignored: unknown ids, second answers. Counted for the checks.
    public private(set) var ignored = 0

    /// `send` types a line into the console and says whether there was one to type into.
    public init(timeout: Duration = PluginCommandRunner.defaultTimeout, isEnabled: @escaping () -> Bool, send: @escaping (String) -> Bool) {
        self.timeout = timeout
        self.isEnabled = isEnabled
        self.send = send
    }

    public func run(_ plugin: String, _ subcommand: [String], _ args: [CommandArg] = [], yes: [String] = []) async -> CommandReply {
        var id = PluginCommandWire.newID()
        while used.contains(id) { id = PluginCommandWire.newID() }
        guard isEnabled() else { return CommandReply(id: id, outcome: .refused("Plugin commands are switched off in LeafJuice's settings.")) }
        let line: String
        switch PluginCommandWire.line(plugin: plugin, subcommand: subcommand, args: args, yes: yes, id: id) {
        case .success(let l): line = l
        case .failure(let r): return CommandReply(id: id, outcome: .refused(r.message))
        }
        used.insert(id)
        let timeout = self.timeout
        let outcome = await withCheckedContinuation { (done: CheckedContinuation<CommandOutcome, Never>) in
            waiting[id] = done
            guard send(line) else {
                waiting[id] = nil
                done.resume(returning: .refused("LeafJuice can only send plugin commands to a server it started and is running."))
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, let waiter = self.waiting.removeValue(forKey: id) else { return }
                self.late.append(id)
                if self.late.count > 200 { self.late.removeFirst(self.late.count - 200) }
                waiter.resume(returning: .notConfirmed)
            }
        }
        return CommandReply(id: id, outcome: outcome)
    }

    /// Reads one console line. True if it answered a command LeafJuice is waiting on.
    @discardableResult
    public func ingest(_ line: String) -> Bool {
        guard let (id, json) = PluginCommandWire.answerLine(line) else { return false }
        if let waiter = waiting.removeValue(forKey: id) {
            waiter.resume(returning: CommandOutcome.from(id: id, json: json))
            return true
        }
        if let i = late.firstIndex(of: id) {
            late.remove(at: i)
            onLateAnswer?(CommandReply(id: id, outcome: CommandOutcome.from(id: id, json: json)))
            return true
        }
        ignored += 1
        return false
    }

    /// Asks a plugin what it offers.
    public func describe(_ plugin: String) async -> DescribeResult {
        let reply = await run(plugin, ["describe"])
        guard case .done(let answer) = reply.outcome else { return .outcome(reply.outcome) }
        return PluginDescription.read(answer.json)
    }
}

public enum DescribeResult: Sendable {
    case described(PluginDescription)
    /// The plugin speaks a newer format than this LeafJuice. LeafJuice needs updating.
    case newerFormat(Int)
    case unreadable
    case outcome(CommandOutcome)
}

/// What a plugin's `describe` says it offers. Keys LeafJuice doesn't know are ignored.
public struct PluginDescription: Sendable, Equatable {
    public let format: Int
    public let plugin: String
    public let version: String
    public let commands: [Command]
    /// The plugin's own error codes, beyond the base ones.
    public let errors: [String]

    public struct Command: Sendable, Equatable, Decodable {
        public let name: String
        public let permission: String?
        public let args: [Argument]
        public let confirms: [String]
        public let secret: Bool

        enum CodingKeys: String, CodingKey { case name, permission, args, confirms, secret }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            permission = try c.decodeIfPresent(String.self, forKey: .permission)
            args = try c.decodeIfPresent([Argument].self, forKey: .args) ?? []
            confirms = try c.decodeIfPresent([String].self, forKey: .confirms) ?? []
            secret = try c.decodeIfPresent(Bool.self, forKey: .secret) ?? false
        }
        /// The subcommand words, as `run` takes them.
        public var words: [String] { name.split(separator: " ").map(String.init) }
    }

    public struct Argument: Sendable, Equatable, Decodable {
        public let name: String
        public let type: String
        /// For a list: what it holds.
        public let of: String?
        /// For an enum, or a list of enums: the choices.
        public let values: [String]?
        /// May be left out. Optional arguments come only after every required one.
        public let optional: Bool

        enum CodingKeys: String, CodingKey { case name, type, of, values, optional }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            type = try c.decode(String.self, forKey: .type)
            of = try c.decodeIfPresent(String.self, forKey: .of)
            values = try c.decodeIfPresent([String].self, forKey: .values)
            optional = try c.decodeIfPresent(Bool.self, forKey: .optional) ?? false
        }
        public static let types: Set<String> = ["string", "int", "bool", "player", "uuid", "enum", "duration", "list"]
        public var isKnown: Bool {
            guard Self.types.contains(type) else { return false }
            if type == "list" { return of.map { Self.types.contains($0) && $0 != "list" } ?? false }
            return true
        }
    }

    public static func read(_ json: Data) -> DescribeResult {
        struct Format: Decodable { let format: Int }
        struct Wire: Decodable {
            let format: Int
            let plugin: String
            let version: String
            let commands: [Command]?
            let errors: [String]?
        }
        guard let head = try? JSONDecoder().decode(Format.self, from: json) else { return .unreadable }
        guard head.format <= PluginCommandWire.format else { return .newerFormat(head.format) }
        guard head.format >= 1, let wire = try? JSONDecoder().decode(Wire.self, from: json),
              PluginCommandWire.matches(regex(#"^[A-Za-z0-9_-]{1,64}\z"#), wire.plugin) else { return .unreadable }
        // A required argument after an optional one would leave LeafJuice guessing which slot a value fills.
        for command in wire.commands ?? [] {
            guard let firstOptional = command.args.firstIndex(where: \.optional) else { continue }
            if command.args[firstOptional...].contains(where: { !$0.optional }) { return .unreadable }
        }
        return .described(PluginDescription(format: wire.format, plugin: wire.plugin, version: wire.version, commands: wire.commands ?? [], errors: wire.errors ?? []))
    }
}

/// Secrets a plugin left for LeafJuice in `plugins/<Plugin>/once/<id>.json`.
public enum OnceSecrets {
    public struct Secret: Sendable, Equatable {
        public let kind: String
        public let value: String
        public let expires: Date?
    }

    public enum Problem: Error, Sendable, Equatable {
        case badPath, missing, notPrivate, unreadable, wrongRequest, expired

        public var message: String {
            switch self {
            case .badPath: "The plugin named a file LeafJuice won't read."
            case .missing: "The plugin's file wasn't there. It may have been cleared after 5 minutes."
            case .notPrivate: "The plugin's file could be read by others on this Mac, so LeafJuice deleted it without showing it. Ask the plugin again."
            case .unreadable: "The plugin's file couldn't be read."
            case .wrongRequest: "The plugin's file was for a different request."
            case .expired: "That has already expired."
            }
        }
    }

    /// Reads the secret and deletes the file, whether or not it could be used.
    /// `plugin` is the plugin's folder name from `describe`; `secretFile` is the answer's `secretFile`.
    public static func take(serverRoot: URL, plugin: String, requestID: String, secretFile: String, now: Date = Date()) -> Result<Secret, Problem> {
        guard PluginCommandWire.matches(regex(#"^[A-Za-z0-9_-]{1,64}\z"#), plugin),
              PluginCommandWire.matches(PluginCommandWire.idPattern, requestID),
              secretFile == "once/\(requestID).json" else { return .failure(.badPath) }
        let folder = serverRoot.appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(plugin, isDirectory: true).appendingPathComponent("once", isDirectory: true)
        let file = folder.appendingPathComponent("\(requestID).json")

        // The folder itself, not a link to somewhere else, and only its owner's.
        let expected = serverRoot.resolvingSymlinksInPath().appendingPathComponent("plugins/\(plugin)/once").path
        var dir = stat()
        guard lstat(folder.path, &dir) == 0 else { return .failure(.missing) }
        guard folder.resolvingSymlinksInPath().path == expected, (dir.st_mode & S_IFMT) == S_IFDIR else { return .failure(.badPath) }

        var info = stat()
        guard lstat(file.path, &info) == 0 else { return .failure(.missing) }
        // From here on the file goes, whatever happens.
        defer { unlink(file.path) }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_uid == getuid() else { return .failure(.badPath) }
        guard (dir.st_mode & 0o077) == 0, (info.st_mode & 0o077) == 0 else { return .failure(.notPrivate) }
        guard info.st_size <= 64 * 1024 else { return .failure(.unreadable) }

        let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return .failure(.unreadable) }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: true).readDataToEndOfFile()

        struct Wire: Decodable { let id: String; let kind: String; let value: String; let expires: Double? }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data), !wire.value.isEmpty else { return .failure(.unreadable) }
        guard wire.id == requestID else { return .failure(.wrongRequest) }
        let expires = wire.expires.map { Date(timeIntervalSince1970: $0) }
        if let expires, expires <= now { return .failure(.expired) }
        return .success(Secret(kind: wire.kind, value: wire.value, expires: expires))
    }
}
