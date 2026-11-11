import Foundation

// MARK: - Log lines

public struct ParsedLogLine: Sendable {
    public let level: LogLevel
    public let message: String
    /// `[LuckPerms] Loading…` → LuckPerms
    public let tag: String?
    public let isStackFrame: Bool
    /// False for raw output with no `[time LEVEL]:` prefix, like JVM errors and exception headers.
    public let hasPrefix: Bool
    /// A player's chat line (`<Name> text`). Never read as the server's own output: a player could type anything
    /// (the K158 audit found six places where chat could pass for a server answer).
    public let isChat: Bool
    static let chatPattern = try! NSRegularExpression(pattern: #"^(?:\[Not Secure\] )?<\.?[A-Za-z0-9_]{1,16}> "#)

    private static let levels: [(String, LogLevel)] = [
        ("FATAL", .error), ("SEVERE", .error), ("ERROR", .error), ("WARNING", .warn), ("WARN", .warn), ("INFO", .info), ("DEBUG", .debug),
    ]

    public init(_ raw: String) {
        var level = LogLevel.info, message = raw, prefixed = false
        // `[12:00:00 WARN]: text` (Paper console) or `[12:00:00] [Server thread/WARN]: text` (log files).
        if raw.hasPrefix("["), let close = raw.range(of: "]: ") ?? raw.range(of: "]:") {
            let head = raw[raw.startIndex..<close.lowerBound]
            for (word, value) in Self.levels where head.hasSuffix(word) {
                level = value
                message = String(raw[close.upperBound...])
                prefixed = true
                break
            }
        }
        // Minecraft 26.x labels command output and game messages like this.
        if message.hasPrefix("System chat: ") { message = String(message.dropFirst(13)) }
        self.level = level
        self.message = message
        hasPrefix = prefixed
        isChat = prefixed && Self.chatPattern.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) != nil
        let trimmed = message.drop { $0 == " " || $0 == "\t" }
        isStackFrame = trimmed.hasPrefix("at ") || trimmed.hasPrefix("Caused by:") || (trimmed.hasPrefix("... ") && trimmed.hasSuffix(" more"))
        if message.hasPrefix("["), let end = message.firstIndex(of: "]") {
            let inside = message[message.index(after: message.startIndex)..<end]
            tag = inside.isEmpty || inside.contains(" ") ? nil : String(inside)
        } else {
            tag = nil
        }
    }
}

// MARK: - Rules

public struct IssueRule: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let severity: Severity
    public let category: String
    /// Case-insensitive text to find. Cheap, so it runs on every line.
    public var contains: [String]?
    /// Optional refinement. A named group `(?<subject>…)` separates issues per subject (one per plugin, say).
    public var regex: String?
    public let explanation: String
    public let steps: [String]
    public var action: IssueAction?
    public var docs: String?
    /// Lines this rule must match. Checked by the test suite.
    public var samples: [String]?
}

public enum Severity: String, Codable, Comparable, CaseIterable, Sendable {
    case info, warning, error, critical
    private var rank: Int { [.info: 0, .warning: 1, .error: 2, .critical: 3][self]! }
    public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    public var title: String { rawValue.capitalized }
}

/// Where a suggestion's button takes you.
public struct IssueAction: Codable, Equatable, Sendable {
    public let page: String
    public let label: String
}

public enum RuleBook {
    public static let builtIn: [IssueRule] = {
        do { return try JSONDecoder().decode([IssueRule].self, from: Data(builtInRulesJSON.utf8)) }
        catch { fatalError("Built-in rules are invalid: \(error)") }
    }()

    /// Built-ins plus the user's own JSON files. A user rule with the same id replaces a built-in.
    public static func load() -> [IssueRule] {
        var byID = Dictionary(uniqueKeysWithValues: builtIn.map { ($0.id, $0) })
        var order = builtIn.map(\.id)
        for file in FileOps.children(AppPaths.rules) where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let rules = try? JSONDecoder().decode([IssueRule].self, from: data) else { continue }
            for rule in rules {
                if byID[rule.id] == nil { order.append(rule.id) }
                byID[rule.id] = rule
            }
        }
        return order.compactMap { byID[$0] }
    }
}

// MARK: - Catalogued issues

public struct IssueRecord: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case open, ignored, resolved }
    public var id: String
    public var ruleID: String?
    public var title: String
    public var severity: Severity
    public var category: String
    public var explanation: String?
    public var steps: [String] = []
    public var action: IssueAction?
    public var docs: String?
    public var sample: String
    public var stack: [String] = []
    public var plugin: String?
    public var count = 1
    public var firstSeen: Date
    public var lastSeen: Date
    public var status: Status = .open
    public var attachment: String?

    public var isKnown: Bool { ruleID != nil }

    public var report: String {
        var text = "## \(title)\n\n"
        text += "- Severity: \(severity.title)\n- Seen: \(count) time\(count == 1 ? "" : "s"), last \(ISO8601DateFormatter().string(from: lastSeen))\n"
        if let plugin { text += "- Plugin: \(plugin)\n" }
        if let attachment { text += "- File: \(attachment)\n" }
        text += "\n```\n\(sample)\n"
        if !stack.isEmpty { text += stack.joined(separator: "\n") + "\n" }
        text += "```\n"
        if let explanation { text += "\n\(explanation)\n" }
        if !steps.isEmpty { text += "\n" + steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") + "\n" }
        return text
    }

    /// A search query free of anything specific to this server.
    public var searchQuery: String {
        "minecraft paper server " + IssueAnalyzer.normalize(sample).replacingOccurrences(of: "#", with: "").prefix(140)
    }
}

// MARK: - Analyzer

public final class IssueAnalyzer {
    private struct CompiledRule {
        let rule: IssueRule
        let needles: [String]
        let pattern: NSRegularExpression?
    }

    public private(set) var records: [String: IssueRecord] = [:]
    public private(set) var dirty = false
    private let rules: [CompiledRule]
    private var lastRecordID: String?
    /// Maps a plugin's main package to its name, to attribute stack traces.
    private var pluginPackages: [(prefix: String, name: String)] = []
    private var pluginNames: Set<String> = []
    private let maxUnknown = 400
    private let maxStack = 40

    public init(rules: [IssueRule] = RuleBook.load(), records: [IssueRecord] = []) {
        self.rules = rules.compactMap { rule in
            var pattern: NSRegularExpression?
            if let source = rule.regex {
                guard let compiled = try? NSRegularExpression(pattern: source, options: .caseInsensitive) else { return nil }
                pattern = compiled
            }
            guard pattern != nil || rule.contains?.isEmpty == false else { return nil }
            return CompiledRule(rule: rule, needles: (rule.contains ?? []).map { $0.lowercased() }, pattern: pattern)
        }
        self.records = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func setPlugins(_ plugins: [InstalledPlugin]) {
        pluginNames = Set(plugins.map(\.name))
        pluginPackages = plugins.compactMap { p in
            guard let main = p.descriptor?.main, let dot = main.lastIndex(of: ".") else { return nil }
            return (String(main[..<dot]), p.name)
        }
    }

    public func markClean() { dirty = false }
    public var sorted: [IssueRecord] {
        records.values.sorted { ($0.severity, $0.lastSeen) > ($1.severity, $1.lastSeen) }
    }

    /// Feeds one log line. `at` is overridable for scanning old logs.
    /// Whether any rule recognizes this line now.
    public func ruleMatches(_ raw: String) -> Bool {
        let line = ParsedLogLine(raw)
        let lower = line.message.lowercased()
        return rules.contains { compiled in
            guard compiled.needles.isEmpty || compiled.needles.contains(where: lower.contains) else { return false }
            return compiled.pattern.map { $0.firstMatch(in: line.message) != nil } ?? true
        }
    }

    public func ingest(_ raw: String, at date: Date = Date()) {
        let line = ParsedLogLine(raw)
        if line.isStackFrame || !line.hasPrefix { attach(line, raw: raw) } else { lastRecordID = nil }
        // Frames say which code ran, not what went wrong, and rules on them cost the most during an error flood.
        // `Caused by:` lines count as stack too, but those do say what went wrong, so they still get read.
        if line.isStackFrame, !line.message.contains("Caused by:") { return }
        let lower = line.message.lowercased()

        for compiled in rules {
            guard compiled.needles.isEmpty || compiled.needles.contains(where: lower.contains) else { continue }
            var subject: String?
            if let pattern = compiled.pattern {
                guard let m = pattern.firstMatch(in: line.message) else { continue }
                if compiled.rule.regex?.contains("(?<subject>") == true, let r = Range(m.range(withName: "subject"), in: line.message) {
                    subject = String(line.message[r]).replacingOccurrences(of: ".jar", with: "")
                }
            }
            record(rule: compiled.rule, subject: subject, line: line, date: date)
            return
        }

        guard !line.isStackFrame, line.level >= .warn else { return }
        recordUnknown(line, date: date)
    }

    private func attach(_ line: ParsedLogLine, raw: String) {
        guard let id = lastRecordID, var record = records[id] else { return }
        if record.count == 1 || record.stack.isEmpty, record.stack.count < maxStack { record.stack.append(line.message) }
        if record.plugin == nil { record.plugin = pluginFromStack(line.message) }
        records[id] = record
        dirty = true
    }

    private func pluginFromStack(_ frame: String) -> String? {
        let trimmed = frame.drop { $0 == " " || $0 == "\t" }
        guard trimmed.hasPrefix("at ") else { return nil }
        var symbol = trimmed.dropFirst(3)
        // Observed on Paper: `at ActionHealth-3.5.9-all.jar//com.zeshanaslam.actionhealth.LookThread.run(...)`.
        if let split = symbol.range(of: "//") { symbol = symbol[split.upperBound...] }
        return pluginPackages.first { symbol.hasPrefix($0.prefix + ".") }?.name
    }

    private func plugin(for line: ParsedLogLine, subject: String?) -> String? {
        if let subject, pluginNames.contains(subject) { return subject }
        if let tag = line.tag, pluginNames.contains(tag) { return tag }
        return nil
    }

    private func record(rule: IssueRule, subject: String?, line: ParsedLogLine, date: Date) {
        let id = "rule:\(rule.id)" + (subject.map { ":\($0)" } ?? "")
        lastRecordID = id
        upsert(id: id, date: date) {
            let name = subject ?? "A plugin"
            func fill(_ text: String) -> String { text.replacingOccurrences(of: "{subject}", with: name) }
            return IssueRecord(
                id: id, ruleID: rule.id, title: fill(rule.title), severity: rule.severity, category: rule.category,
                explanation: fill(rule.explanation), steps: rule.steps.map(fill), action: rule.action, docs: rule.docs, sample: line.message,
                plugin: self.plugin(for: line, subject: subject), firstSeen: date, lastSeen: date)
        }
    }

    private func recordUnknown(_ line: ParsedLogLine, date: Date) {
        let id = "log:" + Hashing.sha256(Self.normalize(line.message)).prefix(16)
        if records[id] == nil, records.values.filter({ !$0.isKnown }).count >= maxUnknown { return }
        lastRecordID = id
        upsert(id: id, date: date) {
            IssueRecord(
                id: id, ruleID: nil, title: String(line.message.prefix(110)), severity: line.level == .error ? .error : .warning,
                category: "Uncategorized", sample: line.message, plugin: self.plugin(for: line, subject: nil),
                firstSeen: date, lastSeen: date)
        }
    }

    private func upsert(id: String, date: Date, create: () -> IssueRecord) {
        dirty = true
        if var existing = records[id] {
            existing.count += 1
            existing.lastSeen = max(existing.lastSeen, date)
            // A resolved problem that returns is open again. Ignored stays ignored.
            if existing.status == .resolved { existing.status = .open }
            records[id] = existing
        } else {
            records[id] = create()
        }
    }

    /// For events the wrapper itself observes, such as crashes.
    public func report(_ record: IssueRecord) {
        dirty = true
        if var existing = records[record.id] {
            existing.count += 1
            existing.lastSeen = record.lastSeen
            existing.status = existing.status == .ignored ? .ignored : .open
            existing.attachment = record.attachment ?? existing.attachment
            existing.sample = record.sample
            records[record.id] = existing
        } else {
            records[record.id] = record
        }
    }

    /// Restores a saved record exactly as it was.
    public func restore(_ record: IssueRecord) { records[record.id] = record }

    public func setStatus(_ status: IssueRecord.Status, id: String) {
        records[id]?.status = status
        dirty = true
    }
    public func remove(id: String) { records[id] = nil; dirty = true }
    public func clear() { records = [:]; dirty = true; lastRecordID = nil }

    private static let normalizers: [(NSRegularExpression, String)] = [
        (regex(#"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#), "UUID"),
        (regex(#"(?:/[\w.\-]+){2,}"#), "PATH"),
        (regex(#"\b\d+\.\d+\.\d+\.\d+(:\d+)?\b"#), "ADDR"),
        (regex(#"@[0-9a-fA-F]{4,}\b"#), "@HEX"),
        (regex(#"\b0x[0-9a-fA-F]+\b"#), "HEX"),
        (regex(#"-?\d+(\.\d+)?"#), "#"),
    ]

    /// Removes the parts of a message that vary between occurrences, so repeats group together.
    public static func normalize(_ message: String) -> String {
        var out = message
        for (pattern, replacement) in normalizers {
            out = pattern.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: replacement)
        }
        return out
    }
}
