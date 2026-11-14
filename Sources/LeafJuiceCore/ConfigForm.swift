import Foundation

/// One setting, read from a config file. The file decides what exists, so a setting added by a future
/// version appears by itself and a removed one disappears. `PropertySpec` only adds friendlier words.
public struct ConfigField: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case bool
        case int(ClosedRange<Int>?)
        case number
        case choice([String])
        case text
        /// Lists and multi-line values: shown, but edited in the full file.
        case readOnly
    }
    public var id: String { path.joined(separator: "\u{1F}") }
    public let path: [String]
    public let title: String
    public let help: String?
    public let section: String
    public let kind: Kind
    public let value: String
    let line: Int

    /// Why the current value won't do, if it won't.
    public var problem: String? {
        switch kind {
        case let .int(range):
            guard let number = Int(value) else { return value.isEmpty ? nil : "This needs to be a whole number." }
            if let range, !range.contains(number) { return "This needs to be from \(range.lowerBound) to \(range.upperBound)." }
            return nil
        case .number:
            return value.isEmpty || Double(value) != nil ? nil : "This needs to be a number."
        default:
            return nil
        }
    }
}

public enum ConfigForm {
    public static func supports(_ format: ConfigFile.Format) -> Bool { format == .properties || format == .yaml }

    public static func fields(_ text: String, format: ConfigFile.Format) -> [ConfigField] {
        switch format {
        case .properties: properties(text)
        case .yaml: yaml(text)
        default: []
        }
    }

    /// Changes one value, touching nothing else in the file.
    public static func set(_ field: ConfigField, to value: String, in text: String, format: ConfigFile.Format) -> String {
        guard field.kind != .readOnly else { return text }
        switch format {
        case .properties:
            var doc = PropertiesDocument(text)
            doc.set(field.path[0], value)
            return doc.text
        case .yaml:
            var lines = text.components(separatedBy: "\n")
            guard field.line < lines.count else { return text }
            lines[field.line] = yamlLine(lines[field.line], value: value, kind: field.kind)
            return lines.joined(separator: "\n")
        default:
            return text
        }
    }

    /// `view-distance` → `View distance`
    public static func humanize(_ key: String) -> String {
        let spaced = key.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        // camelCase and dotted keys too.
        let words = spaced.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: ".", with: " ").lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func inferred(_ value: String) -> ConfigField.Kind {
        let lower = value.lowercased()
        if lower == "true" || lower == "false" { return .bool }
        if Int(value) != nil { return .int(nil) }
        if !value.isEmpty, Double(value) != nil { return .number }
        return .text
    }

    // MARK: .properties

    private static func properties(_ text: String) -> [ConfigField] {
        let specs = Dictionary(uniqueKeysWithValues: PropertySpec.known.map { ($0.key, $0) })
        var out: [ConfigField] = []
        let doc = PropertiesDocument(text)
        for (index, line) in doc.lines.enumerated() {
            guard case let .pair(key, raw) = line else { continue }
            let value = PropertiesDocument.unescape(raw)
            let spec = specs[key]
            var kind = inferred(value)
            if let spec {
                switch spec.kind {
                case .bool: if kind == .bool { kind = .bool }
                case let .int(range): if case .int = kind { kind = .int(range) } else if value.isEmpty { kind = .text }
                case let .choice(options): kind = .choice(options.contains(value) ? options : options + [value])
                case .text: kind = .text
                }
            }
            out.append(ConfigField(
                path: [key], title: spec?.title ?? humanize(key), help: spec?.help.isEmpty == false ? spec?.help : nil,
                section: spec?.group ?? "Other settings", kind: kind, value: value, line: index))
        }
        let order = PropertySpec.groupOrder
        func rank(_ s: String) -> Int { order.firstIndex(of: s) ?? order.count }
        return out.enumerated().sorted {
            let (a, b) = (rank($0.element.section), rank($1.element.section))
            if a != b { return a < b }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    // MARK: YAML

    private static let keyPattern = regex(#"^( *)("[^"]*"|'[^']*'|[^\s#'"\-][^#]*?|-[^\s][^#]*?):(?:\s+(.*))?$"#)

    /// Reads settings from YAML by indentation. Deliberately small: anything it isn't sure of is
    /// shown read-only, so a form edit can only ever replace the value on one simple line.
    private static func yaml(_ text: String) -> [ConfigField] {
        var out: [ConfigField] = []
        var stack: [(indent: Int, key: String)] = []
        var comment: [String] = []
        var blockIndent: Int?       // Inside a `|` or `>` block.
        let lines = text.components(separatedBy: "\n")

        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix { $0 == " " }.count
            if let block = blockIndent {
                if trimmed.isEmpty || indent > block { continue }
                blockIndent = nil
            }
            if trimmed.isEmpty { comment = []; continue }
            if trimmed.hasPrefix("#") {
                let note = String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                // Skip banner lines made of nothing but symbols.
                if note.contains(where: \.isLetter) { comment.append(note) }
                continue
            }
            // `---`, tags and tabs aren't for a form.
            if trimmed == "---" || trimmed == "..." || raw.hasPrefix("\t") { comment = []; continue }
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                comment = []
                // A list under a key that looked like a section until now.
                while let top = stack.last, top.indent > indent { stack.removeLast() }
                if let top = stack.last, top.indent <= indent {
                    let path = stack.map(\.key)
                    if !out.contains(where: { $0.path == path }) { out.append(field(path: path, value: "List", kind: .readOnly, help: nil, line: index)) }
                }
                continue
            }
            guard let m = keyPattern.firstMatch(in: raw), let keyRange = Range(m.range(at: 2), in: raw) else { comment = []; continue }
            let key = unquote(String(raw[keyRange]))
            while let top = stack.last, top.indent >= indent { stack.removeLast() }
            let path = stack.map(\.key) + [key]
            // Plugin authors document settings in comments. Very long blocks are file headers, not help.
            let joined = comment.joined(separator: " ")
            let help = comment.isEmpty || joined.count > 500 ? nil : joined
            comment = []
            let rawValue = Range(m.range(at: 3), in: raw).map { String(raw[$0]) } ?? ""
            let (value, quoted) = yamlValue(rawValue)

            if value.isEmpty, !quoted {
                stack.append((indent, key))   // A section, unless a list turns up beneath it.
                continue
            }
            if value.hasPrefix("|") || value.hasPrefix(">") {
                blockIndent = indent
                out.append(field(path: path, value: "Multi-line text", kind: .readOnly, help: help, line: index))
            } else if value.hasPrefix("[") || value.hasPrefix("{") || value.hasPrefix("&") || value.hasPrefix("*") || value.hasPrefix("!") {
                out.append(field(path: path, value: value, kind: .readOnly, help: help, line: index))
            } else {
                out.append(field(path: path, value: value, kind: quoted ? .text : inferred(value), help: help, line: index))
            }
        }
        return out
    }

    private static func field(path: [String], value: String, kind: ConfigField.Kind, help: String?, line: Int) -> ConfigField {
        let joined = path.joined(separator: ".")
        let known = YAMLNotes.known[joined] ?? YAMLNotes.known[path.suffix(2).joined(separator: ".")]
        return ConfigField(
            path: path, title: humanize(path.last ?? ""), help: known ?? help,
            section: path.count > 1 ? path.dropLast().map(humanize).joined(separator: " › ") : "General",
            kind: kind, value: value, line: line)
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2, let q = text.first, q == "'" || q == "\"", text.last == q else { return text }
        return String(text.dropFirst().dropLast())
    }

    /// Splits a YAML value from any comment after it.
    private static func yamlValue(_ raw: String) -> (value: String, quoted: Bool) {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if let q = t.first, q == "'" || q == "\"" {
            guard let close = closingQuote(in: t) else { return (t, false) }
            let inner = String(t[t.index(after: t.startIndex)..<close])
            if q == "'" { return (inner.replacingOccurrences(of: "''", with: "'"), true) }
            return (inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\"), true)
        }
        if t.hasPrefix("#") { return ("", false) }
        if let hash = t.range(of: " #") { return (String(t[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces), false) }
        return (t, false)
    }

    /// Finds where a quoted value ends: `''` is an escaped quote in single quotes, `\\"` in double.
    private static func closingQuote(in t: String) -> String.Index? {
        guard let q = t.first else { return nil }
        var i = t.index(after: t.startIndex)
        while i < t.endIndex {
            let ch = t[i]
            if q == "\"", ch == "\\" {
                i = t.index(after: i)
                if i < t.endIndex { i = t.index(after: i) }
                continue
            }
            if ch == q {
                let next = t.index(after: i)
                if q == "'", next < t.endIndex, t[next] == "'" { i = t.index(after: next); continue }
                return i
            }
            i = t.index(after: i)
        }
        return nil
    }

    /// Rewrites only the value, keeping the key, indentation, quoting style and any trailing comment.
    private static func yamlLine(_ line: String, value: String, kind: ConfigField.Kind) -> String {
        guard let m = keyPattern.firstMatch(in: line), let keyRange = Range(m.range(at: 2), in: line) else { return line }
        let head = String(line[..<keyRange.upperBound]) + ":"
        let rest = Range(m.range(at: 3), in: line).map { String(line[$0]) } ?? ""
        let t = rest.trimmingCharacters(in: .whitespaces)
        var comment = ""
        var oldQuote: Character?
        if let q = t.first, q == "'" || q == "\"" {
            oldQuote = q
            if let close = closingQuote(in: t) {
                let after = t[t.index(after: close)...]
                if after.contains("#") { comment = String(after) }
            }
        } else if let hash = t.range(of: " #") {
            comment = String(t[hash.lowerBound...])
        }
        return "\(head) \(yamlScalar(value, quote: oldQuote, kind: kind))\(comment)"
    }

    private static func yamlScalar(_ value: String, quote: Character?, kind: ConfigField.Kind) -> String {
        if quote == "\"" {
            return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let single = "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        if quote == "'" { return single }
        switch kind {
        case .bool, .int, .number:
            return value
        default:
            // Plain unless YAML would read it as something else.
            let risky = value.isEmpty || value.contains(": ") || value.contains(" #") || value.hasSuffix(":")
                || value != value.trimmingCharacters(in: .whitespaces)
                || "!&*-?|>@`%{}[]#,'\"".contains(value.first ?? " ")
                || inferred(value) != .text
                || ["null", "~", "yes", "no", "on", "off"].contains(value.lowercased())
            return risky ? single : value
        }
    }

    // MARK: The message players see

    /// A motd as plain text: without `§a` or `&a` color codes, and on one line.
    public static func plainMOTD(_ motd: String) -> String {
        regex("[§&][0-9a-fk-orA-FK-OR]").stringByReplacingMatches(in: motd, range: NSRange(motd.startIndex..., in: motd), withTemplate: "")
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }
}

/// Friendlier words for well-known YAML settings. Purely additive: unknown ones still work.
enum YAMLNotes {
    static let known: [String: String] = [
        "settings.allow-end": "Whether The End exists on this server.",
        "settings.connection-throttle": "Milliseconds a player must wait between connection attempts. -1 turns this off, which is what you want behind a proxy.",
        "settings.shutdown-message": "Shown to players when the server stops.",
        "spawn-limits.monsters": "Hostile mobs allowed per player. The biggest gameplay-side lag factor; lower it if the server struggles.",
        "spawn-limits.animals": "Animals allowed per player.",
        "ticks-per.autosave": "Ticks between automatic saves. 6000 is five minutes.",
        "settings.restart-on-crash": "LeafJuice handles crash restarts itself, so leave Spigot's turned off.",
        "settings.restart-script": "Not needed with LeafJuice.",
        "settings.bungeecord": "Only turn on behind a BungeeCord or Waterfall proxy.",
        "world-settings.default.view-distance": "default follows server.properties.",
        "proxies.velocity.enabled": "Only turn on behind a Velocity proxy.",
        "anticheat.anti-xray.enabled": "Hides ores from cheating clients, at some CPU cost.",
        "chunks.delay-chunk-unloads-by": "How long empty chunks stay loaded. Short values save memory but can cause more disk work.",
    ]
}

// MARK: - Player lists

/// `ops.json`, `whitelist.json` and the ban lists. The server owns these while it runs, so changes go
/// through its own commands, which also look up the account for you.
public enum PlayerList {
    /// Why the raw allowlist or op command mustn't be used here, if it mustn't (the K158 audit). With Usher installed,
    /// players are added through it, so they get their profile and groups; without online-mode, a name isn't an
    /// account, so a name-based op or allowlist entry could be anyone.
    public static func rawAddRefusal(path: String, hasUsher: Bool, onlineMode: Bool) -> String? {
        guard path == "whitelist.json" || path == "ops.json" else { return nil }
        if !onlineMode { return "This server isn't in online mode, so a name here could be anyone. Change online-mode first." }
        if path == "whitelist.json", hasUsher { return "Usher looks after the allowlist here. Add players from Players → Add, so they get their profile and groups." }
        return nil
    }

    public struct Commands: Sendable {
        public let add: String
        public let remove: String
        public let addLabel: String
        public let isAddress: Bool
    }

    public static func commands(for path: String) -> Commands? {
        switch path {
        case "ops.json": Commands(add: "op", remove: "deop", addLabel: "Make Operator", isAddress: false)
        case "whitelist.json": Commands(add: "whitelist add", remove: "whitelist remove", addLabel: "Add to Allowlist", isAddress: false)
        case "banned-players.json": Commands(add: "ban", remove: "pardon", addLabel: "Ban Player", isAddress: false)
        case "banned-ips.json": Commands(add: "ban-ip", remove: "pardon-ip", addLabel: "Ban Address", isAddress: true)
        default: nil
        }
    }

    public static func entries(_ text: String) -> [String] {
        guard let items = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else { return [] }
        return items.compactMap { ($0["name"] ?? $0["ip"]) as? String }.sorted { $0.lowercased() < $1.lowercased() }
    }

    /// Goes into a console command, so it must be exactly one harmless word.
    public static func isValid(_ text: String, isAddress: Bool) -> Bool {
        let pattern = isAddress ? #"^[0-9a-fA-F:.]{2,45}$"# : #"^\.?[A-Za-z0-9_]{1,16}$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
