import Foundation

enum Regexes {
    static func make(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    static let token = make(PrivacyKey.tokenPattern)
    static let ansi = make(#"\x1B\[[0-9;?]*[ -/]*[@-~]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)?|\x1B[@-_]"#)
    /// Minecraft's own colour codes, which would otherwise hide the start of a name.
    static let colour = make("[§&][0-9a-fk-orx]", [.caseInsensitive])

    static let url = make(#"\b[a-z][a-z0-9+.\-]{0,20}(?::[a-z][a-z0-9+.\-]{0,20}){0,3}://[^\s"'<>]{0,4000}"#, [.caseInsensitive])
    static let bearer = make(#"\b(?:bearer|basic)\s+[A-Za-z0-9._~+/=\-]{1,4000}"#, [.caseInsensitive])
    static let keyValue = make(
        #"((?<![A-Za-z])(?:password|passwd|pwd|passphrase|pass|secret|api[-_ ]?key|authorization|private[-_ ]?key|license[-_ ]?key|token|credential|webhook|cookie)[\w.\-]{0,40}["']?\s{0,4}(?:=>?|:)\s{0,4})(?:"[^"]{0,4000}"|'[^']{0,4000}'|[^\n.;,]{0,300})"#,
        [.caseInsensitive])
    static let flagValue = make(#"(--?(?:password|passwd|pwd|pass|token|secret|api[-_]?key)[ =])\S{1,4000}"#, [.caseInsensitive])
    static let email = make(#"\b[A-Z0-9._%+\-]{1,64}@[A-Z0-9.\-]{1,255}\.[A-Z]{2,24}\b"#, [.caseInsensitive])
    static let knownPrefixes = make(#"\b(?:sk[-_][A-Za-z0-9_\-]{6,}|gh[pousr]_[A-Za-z0-9]{8,}|github_pat_[A-Za-z0-9_]{8,}|xox[a-z]-[A-Za-z0-9\-]{8,}|AKIA[0-9A-Z]{8,}|eyJ[A-Za-z0-9_\-]{8,}(?:\.[A-Za-z0-9_\-]+)*)"#)
    static let homePath = make(#"(?:/Users/|/home/|[A-Za-z]:\\+Users\\+)[^\n"']{0,200}"#)
    static let uuid = make(#"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#, [.caseInsensitive])
    static let bareUUID = make(#"\b[0-9a-f]{32}\b"#, [.caseInsensitive])
    /// A sentence's full stop may follow, so only another digit group rules a match out.
    static let ipv4 = make(#"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?!\d)(?!\.\d)"#)
    /// Eight groups, or any form with `::`. Clock times never match.
    static let ipv6 = make(#"(?<![\w:.])(?:(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}|(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4}){0,6})?::(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4}){0,6})?)(?![\w])"#, [.caseInsensitive])
    /// Long unbroken text, which is how most keys look when their format is unknown.
    /// Stricter than the ones above: inside code, a dot or underscore next to these is no excuse.
    /// Any four dotted numbers, or an address written with dashes or underscores, as real code holds neither.
    static let codeIP = make(#"(?<![0-9])[0-9]{1,5}(?:\.[0-9]{1,5}){3}(?![0-9])|(?<![0-9])0*(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(?:[\-_$/+]0*(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){3}(?![0-9])"#)
    /// 32 hex digits or more, however they're split up.
    static let codeUUID = make(#"(?:[0-9a-f][.\-_$/+]?){32}"#, [.caseInsensitive])
    /// A module version such as `java.base@21.0.1` has no letters after its dot, so it isn't caught.
    static let codeEmail = make(#"@[A-Za-z0-9\-]{1,63}[.$][A-Za-z]{2,}"#)
    /// Key formats beyond the ones `knownPrefixes` looks for, including with dots for dashes.
    static let codeKey = make(#"AIza[A-Za-z0-9_\-]{16,}|glpat-[A-Za-z0-9_\-]{8,}|sk[-_.]ant[-_.]"#)
    /// Long and full of digits, which a real name in code isn't.
    static let digitHeavy = make(#"(?<![A-Za-z0-9])(?=(?:[A-Za-z]*[0-9]){8})[A-Za-z0-9]{24,}"#)
    static let identifier = make("[A-Za-z0-9_]+")
    static let longOpaque = make(#"[A-Za-z0-9_+/=.\-]{24,4000}"#)
}

/// Text cleaning shared by everything that goes out or comes back in.
public enum Scrub {
    static func replace(_ text: String, _ regex: NSRegularExpression, _ with: (String) throws -> String) rethrows -> String {
        let source = text as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            out += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += try with(source.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        return out + source.substring(from: cursor)
    }

    private static func sub(_ text: String, _ regex: NSRegularExpression, _ template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Removes anything that could steer a terminal, or that a model could read but a person couldn't see. Newlines and tabs stay.
    public static func controls(_ text: String) -> String {
        let plain = sub(sub(text, Regexes.ansi, ""), Regexes.colour, "")
        var out = String.UnicodeScalarView()
        for scalar in plain.unicodeScalars {
            if scalar == "\n" || scalar == "\t" { out.append(scalar); continue }
            // Variation selectors and blank fillers, which are invisible without being marked as format characters.
            if scalar.properties.isDefaultIgnorableCodePoint { continue }
            switch scalar.properties.generalCategory {
            case .control, .format, .privateUse, .unassigned, .surrogate: continue
            case .lineSeparator, .paragraphSeparator: out.append("\n")
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    static func capped(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + " [cut]"
    }

    /// Secrets, with no knowledge of who's who. This runs before names are swapped, so a name can't hide the word that gives a secret away.
    static func secrets(_ text: String) -> String {
        var out = sub(text, Regexes.url, "[address removed]")
        out = sub(out, Regexes.bearer, Sanitizer.removed)
        out = sub(out, Regexes.flagValue, "$1\(Sanitizer.removed)")
        out = sub(out, Regexes.keyValue, "$1\(Sanitizer.removed)")
        out = sub(out, Regexes.knownPrefixes, Sanitizer.removed)
        out = sub(out, Regexes.email, Sanitizer.removed)
        return sub(out, Regexes.homePath, "~")
    }
}

/// Text the AI writes, and the record of who's who on one server.
public final class Sanitizer {
    public static let removed = "[removed]"
    static let maxNames = 100_000
    static let maxNamesInCode = 5000
    private let key: PrivacyKey
    /// By exact name: on an offline server, `Alice` and `alice` can be different people.
    private var uuidOf: [String: String] = [:]
    private var nameOf: [String: String] = [:]
    private var displayOf: [String: String] = [:]
    private var namePattern: NSRegularExpression?
    private var identifierMatches: [String: String?] = [:]

    public init(key: PrivacyKey) { self.key = key }

    static let validName = Regexes.make(#"^[.*]?[A-Za-z0-9_]{2,16}$"#)
    /// Takes names only from sources chat can't spoof. See `ProblemLog` and `ServerReader`.
    public func learnPlayer(name: String, uuid: String? = nil) {
        guard Self.validName.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil else { return }
        let lower = name.lowercased()
        if displayOf[lower] == nil { namePattern = nil; identifierMatches = [:] }
        displayOf[lower] = name
        // A Bedrock name's marker isn't part of an identifier, so code holds the name without it.
        if lower.hasPrefix(".") || lower.hasPrefix("*") { displayOf[String(lower.dropFirst())] = name }
        if let uuid, Regexes.uuid.firstMatch(in: uuid, range: NSRange(uuid.startIndex..., in: uuid))?.range.length == uuid.utf16.count {
            uuidOf[name] = uuid.lowercased()
            nameOf[uuid.lowercased()] = name
        }
    }

    func playerToken(name: String, uuid: String? = nil) throws -> String {
        try key.player(name: name, uuid: uuid ?? uuidOf[name])
    }

    func ipToken(_ address: String) throws -> String {
        // These say nothing about anyone, and help when reading a bind failure.
        if ["127.0.0.1", "0.0.0.0", "::1"].contains(address) { return address }
        return try key.ip(address)
    }

    private func learnKnownNames() throws {
        // Names from the key too, so someone who has left the server's own files is still recognised.
        for name in try key.knownPlayerNames() where displayOf[name] == nil { learnPlayer(name: name) }
    }

    private func swapNames(_ text: String) throws -> String {
        guard let pattern = try names() else { return text }
        return try Scrub.replace(text, pattern) { match in
            let lower = match.lowercased()
            return try key.knownPlayerToken(lookup: "name:\(lower)") ?? playerToken(name: displayOf[lower] ?? match)
        }
    }

    /// A jar's name with any player's name in it swapped, or nil if it doesn't look like a plugin's: it holds an address,
    /// key or UUID, or reads like a sentence.
    func cleanFileName(_ name: String) throws -> String? {
        try learnKnownNames()
        guard name.hasSuffix(".jar"), name.count <= 64 else { return nil }
        let stem = String(name.dropLast(4))
        let words = stem.split(whereSeparator: { "-_.+".contains($0) }).filter { $0.count >= 2 && $0.allSatisfy(\.isLetter) }
        guard words.count <= 5 else { return nil }
        return try codeText(stem).map { $0 + ".jar" }
    }

    /// Before a run of `codeText` calls, so it doesn't have to read the key for each one.
    func prepareForCode() throws { try learnKnownNames() }

    /// Words every stack trace is full of. A player who takes one as a name stays hidden, as the word says nothing about
    /// them, and swapping it would both garble the trace and show where the name sits.
    static let codeWords: Set<String> = ["java", "javax", "jdk", "sun", "kotlin", "kt", "groovy", "scala", "net", "org", "com", "io", "minecraft", "mojang", "bukkit", "craftbukkit", "spigotmc", "papermc", "paper", "server", "level", "world", "player", "entity", "block", "item", "thread", "run", "main", "lang", "util", "base", "app", "init", "clinit", "native", "method", "unknown", "source", "plugin", "plugins", "reflect", "invoke", "event", "command", "exception", "error", "get", "set", "tick", "load", "enable", "disable", "core", "api", "internal", "impl", "common", "network", "jar"]

    /// The player whose name is in an identifier: all of it, any run of its `_` parts, or spliced into a longer word.
    private func nameInside(_ word: String) -> String? {
        let lower = word.lowercased()
        if let known = identifierMatches[word] { return known }
        var found: String?
        if !Self.codeWords.contains(lower) {
            if displayOf[lower] != nil { found = lower }
            let parts = lower.split(separator: "_").map(String.init)
            search: for length in stride(from: parts.count, through: 1, by: -1) {
                guard found == nil else { break }
                for start in 0...(parts.count - length) {
                    let run = parts[start..<(start + length)].joined(separator: "_")
                    if displayOf[run] != nil, !Self.codeWords.contains(run) { found = run; break search }
                }
            }
            // Short names turn up inside ordinary words, so these only count from five letters.
            if found == nil {
                found = displayOf.keys.filter { $0.count >= 5 && !Self.codeWords.contains($0) && lower.contains($0) }.max { $0.count < $1.count }
            }
            // `EmmaHandler` holds `Emma` as one whole word of its own, which is safe to look for at any length.
            if found == nil {
                let words = word.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression).lowercased().split(separator: " ").map(String.init)
                found = words.first { $0.count >= 3 && displayOf[$0] != nil && !Self.codeWords.contains($0) }
            }
        }
        identifierMatches[word] = .some(found)
        return found
    }

    /// Code-shaped text with any player's name swapped, or nil if it holds an address, UUID, email or key, which real
    /// code wouldn't. Swapped rather than dropped, so a player who takes a word found in code as a name can't hide evidence.
    func codeText(_ text: String) throws -> String? {
        let range = NSRange(text.startIndex..., in: text)
        for regex in [Regexes.codeUUID, Regexes.codeIP, Regexes.codeEmail, Regexes.email, Regexes.knownPrefixes, Regexes.codeKey, Regexes.digitHeavy] where regex.firstMatch(in: text, range: range) != nil { return nil }
        // Past this the name checks below would take too long, so nothing is shared rather than less being checked.
        guard displayOf.count <= Self.maxNamesInCode else { throw AdvisorError("There are too many player names to check, so nothing was shared.") }
        let swapped = try Scrub.replace(text, Regexes.identifier) { word in
            guard let name = nameInside(word) else { return word }
            return try key.knownPlayerToken(lookup: "name:\(name)") ?? playerToken(name: displayOf[name] ?? name)
        }
        // A name split across parts, as in `Mary.Jane` or `FakeKid$Alice`, can only be dropped.
        let joined = swapped.lowercased().filter { $0.isLetter || $0.isNumber }
        let splitName = displayOf.keys.contains { key in
            let squashed = key.filter { $0.isLetter || $0.isNumber }
            return squashed.count >= 6 && !Self.codeWords.contains(key) && joined.contains(squashed)
        }
        return splitName ? nil : swapped
    }

    /// For suggestions. Nothing new is recorded unless it's a known player: an address or ID the AI made up isn't shared
    /// data, and a key-shaped UUID shouldn't end up in the key file.
    public func clean(_ raw: String, limit: Int) throws -> String {
        try learnKnownNames()
        var text = Scrub.capped(Scrub.controls(raw), limit)
        text = Scrub.secrets(text)
        text = try Scrub.replace(text, Regexes.uuid) { try known(uuid: $0.lowercased()) }
        text = try Scrub.replace(text, Regexes.bareUUID) { try known(uuid: Self.dashed($0.lowercased())) }
        text = Scrub.replace(text, Regexes.longOpaque) { match in
            // A jar or a lowercase class path is fine to mention. Anything else this long is probably a key.
            if match.hasSuffix(".jar") || match.range(of: #"^[a-z]+(\.[A-Za-z][\w$]*){2,}$"#, options: .regularExpression) != nil { return match }
            return match.contains(where: \.isNumber) || match.count >= 40 ? Self.removed : match
        }
        text = try Scrub.replace(text, Regexes.ipv4) { try knownIP($0) }
        text = try Scrub.replace(text, Regexes.ipv6) { try $0 == "::" ? $0 : knownIP($0.lowercased()) }
        return try swapNames(text)
    }

    private static func dashed(_ bare: String) -> String {
        let c = Array(bare)
        return String(c[0..<8]) + "-" + String(c[8..<12]) + "-" + String(c[12..<16]) + "-" + String(c[16..<20]) + "-" + String(c[20...])
    }

    private func names() throws -> NSRegularExpression? {
        if let namePattern { return namePattern }
        guard !displayOf.isEmpty else { return nil }
        guard displayOf.count <= Self.maxNames else { throw AdvisorError("There are too many player names to check, so nothing was shared.") }
        let alternatives = displayOf.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        // A failure here would print every name if it were allowed to crash.
        guard let pattern = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_])(?:\(alternatives))(?![A-Za-z0-9_])(?!-[0-9a-f]{8}\\b)", options: [.caseInsensitive]) else {
            throw AdvisorError("There are too many player names to check, so nothing was shared.")
        }
        namePattern = pattern
        return pattern
    }

    private func known(uuid: String) throws -> String {
        if let token = try key.knownPlayerToken(lookup: "uuid:\(uuid)") { return token }
        guard let name = nameOf[uuid] else { return Self.removed }
        return try playerToken(name: name)
    }

    private func knownIP(_ address: String) throws -> String {
        if ["127.0.0.1", "0.0.0.0", "::1"].contains(address) { return address }
        return try key.knownIP(address) ?? Self.removed
    }
}

/// What the AI may learn from a log. Each line either matches a fixed shape and is rewritten from the parts it
/// recognised, or its text is withheld and only counted. Code-shaped text in stack traces is the one thing a plugin
/// author still controls: see docs/ADVISOR-SECURITY.md.
public final class ProblemLog {
    public struct Report {
        public var events: [String]
        /// Lines whose text wasn't sent, of any level.
        public var withheld: Int
    }

    static let maxLine = 2000
    static let maxReportCharacters = 60_000
    static let maxFramesPerTrace = 20
    private let sanitizer: Sanitizer
    private let pluginNames: Set<String>
    private let jars: Set<String>

    /// A plugin name is only trusted if it's the whole name part of an installed jar, so a two-letter chat prefix doesn't count.
    public init(sanitizer: Sanitizer, installedJars: [String]) {
        self.sanitizer = sanitizer
        jars = Set(installedJars)
        var names: Set<String> = []
        for jar in installedJars {
            let stem = jar.hasSuffix(".jar") ? String(jar.dropLast(4)) : jar
            var parts: [String] = []
            for part in stem.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init) {
                if part.first?.isNumber == true || part.range(of: #"^[vV][0-9]"#, options: .regularExpression) != nil { break }
                parts.append(part)
                names.insert(Self.squash(parts.joined()))
            }
        }
        pluginNames = names
    }

    private static func squash(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }

    func trustedPlugin(_ tag: String) throws -> String? {
        let squashed = Self.squash(tag)
        guard squashed.count >= 3, tag.count <= 40, tag.utf8.allSatisfy({ $0 < 128 }),
              tag.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        guard pluginNames.contains(squashed) else { return nil }
        // A tag that's also a player's name could be that player using `/say`.
        guard let clean = try sanitizer.codeText(tag), clean == tag else { return nil }
        return clean
    }

    // MARK: Shapes

    /// The format of `logs/latest.log`. The thread is part of what's checked, because chat has its own.
    private static let logLine = Regexes.make(#"^\[\d\d:\d\d:\d\d\] \[([^\]]{1,80})/(INFO|WARN|WARNING|ERROR|FATAL|SEVERE|DEBUG|TRACE)\](?: \[[^\]]{0,80}\])?: (?:System chat: )?(.*)$"#)
    private static let authenticatorThread = Regexes.make(#"^User Authenticator #\d{1,9}$"#)
    private static let name = #"([.*]?[A-Za-z0-9_]{2,16})"#
    private static let version = #"([0-9][A-Za-z0-9.+\-]{0,23})"#
    private static let minecraftVersion = #"([0-9]{1,2}(?:\.[0-9]{1,2}){1,2}(?:-(?:pre|rc)[0-9]{1,2})?|[0-9]{2}w[0-9]{2}[a-z])"#
    private static let plugin = #"([A-Za-z0-9_\-]{1,40})"#

    private static let authenticated = Regexes.make("^UUID of player \(name) is ([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$")
    private static let loggedIn = Regexes.make("^\(name)\\[/(?:\\[([0-9a-fA-F:.]{2,45})\\]|([0-9.]{7,15})):\\d{1,5}\\] logged in with entity id \\d+ at .{0,120}$")
    private static let joined = Regexes.make("^\(name) (joined|left) the game$")
    private static let lostConnection = Regexes.make("^\(name) lost connection: .{0,300}$")
    private static let movedTooFast = Regexes.make("^\(name) moved (too quickly|wrongly)!.{0,60}$")
    private static let behind = Regexes.make(#"^Can't keep up! Is the server overloaded\? Running ([0-9]{1,9})ms or ([0-9]{1,9}) ticks behind$"#)
    private static let done = Regexes.make(#"^Done \(([0-9]{1,4}[.,][0-9]{1,3})s\)! For help, type "help"$"#)
    private static let starting = Regexes.make("^Starting minecraft server version \(minecraftVersion)$")
    private static let stopping = Regexes.make(#"^Stopping (?:the )?server$"#)
    private static let lifecycle = Regexes.make("^\\[\(plugin)\\] (Enabling|Disabling|Loading) \(plugin) v?\(version)(?: \\(build [0-9]{1,9}\\))?$")
    private static let enableFailed = Regexes.make("^Error occurred while enabling \(plugin) v?\(version) \\(Is it up to date\\?\\)$")
    private static let loadFailed = Regexes.make(#"^Could not load '?plugins[/\\]([A-Za-z0-9_.+\-]{1,80}\.jar)'? in folder '?plugins'?$"#)
    private static let eventFailed = Regexes.make("^Could not pass event ([A-Z][A-Za-z0-9]{0,36}Event) to \(plugin) v?\(version)$")
    private static let taskFailed = Regexes.make("^Task #[0-9]{1,12} for \(plugin) v?\(version) generated an exception$")
    private static let loadFailedModern = Regexes.make(#"^\[ModernPluginLoadingStrategy\] Could not load (?:plugin )?'(?:plugins/(?:\.paper-remapped/)?)?([A-Za-z0-9_.+\-]{1,80}\.jar)' in (?:folder )?'plugins(?:/\.paper-remapped)?'$"#)
    private static let damagedJar = Regexes.make(#"^\[DirectoryProviderSource\] Error preparing plugin context: Directory 'plugins/([A-Za-z0-9_.+\-]{1,80}\.jar)' failed to update!$"#)
    private static let configFailed = Regexes.make(#"^Cannot load plugins/([A-Za-z0-9_\-]{1,40})/([A-Za-z0-9_\-]{1,40}\.yml)$"#)
    private static let worldFailed = Regexes.make(#"^\[([A-Za-z0-9_\-]{1,40})\] Failed to autoload world ([a-z0-9_.:\-]{1,60}): Failure\{reason=([A-Z_]{1,40})\}$"#)
    private static let watchdogMain = Regexes.make(#"^Current Thread: Server thread$"#)
    /// Anchored to the whole line, so a message that only quotes these words doesn't match. The closing sentence isn't sent.
    private static let exceptionPrefix = #"^\s*(?:Caused by: )?(?:[A-Za-z_][A-Za-z0-9_$]{0,40}\.){0,8}"#
    private static let missingDependency = Regexes.make(exceptionPrefix + #"UnknownDependencyException: Unknown/missing dependency plugins: \[([A-Za-z0-9_\-]{1,40}(?:, ?[A-Za-z0-9_\-]{1,40}){0,9})\](?:\. Please download and install these plugins to run '[^']{1,80}'\.)?$"#)
    private static let unsupportedAPI = Regexes.make(exceptionPrefix + #"InvalidPluginException: Unsupported API version ([0-9]{1,2}(?:\.[0-9]{1,2}){0,2})$"#)
    private static let newerJava = Regexes.make(#"UnsupportedClassVersionError: .{1,200}class file version ([0-9.]{1,6})\)?, this version of the Java Runtime only recognizes class file versions up to ([0-9.]{1,6})"#)
    private static let tag = Regexes.make(#"^\[([A-Za-z0-9_\-]{1,40})\] "#)

    /// A real stack frame is code, with nowhere to put a sentence. ASCII only, as `\w` would allow any language. The jar suffix is dropped.
    private static let frame = Regexes.make(#"^\s*at ((?:[A-Za-z0-9_.$@\-]{0,80}/{1,2}){0,3}[A-Za-z0-9_$\-]{1,80}(?:\.[A-Za-z0-9_$\-]{1,80}){1,24}(?:\.<(?:init|clinit)>)?)\(([A-Za-z0-9_$\-]{1,80}\.(?:java|kt|kts|groovy|scala)(?::[0-9]{1,7})?|Native Method|Unknown Source)\)(?:\s{0,4}[~?]?\[[^\]]{0,160}\])?$"#)
    /// Only the exception's class. Its message can hold anything, including what a player typed.
    private static let exception = Regexes.make(#"^\s*(Caused by: |Suppressed: )?((?:[a-zA-Z_][A-Za-z0-9_$]{0,80}\.){1,12}[A-Za-z0-9_$]{0,80}(?:Exception|Error|Throwable))(?::.*)?$"#)
    private static let moreFrames = Regexes.make(#"^\s*\.\.\. ([0-9]{1,6}) (?:more|common frames omitted)$"#)

    private static func groups(_ regex: NSRegularExpression, _ text: String) -> [String]? {
        guard let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
    }

    static func looksLikeRule(_ rule: String) -> Bool { looksLikeCode(rule) }

    /// Small words that join a sentence, and never sit side by side as parts of a real class path.
    private static let sentenceWords: Set<String> = ["is", "the", "my", "and", "to", "at", "me", "please", "ignore", "previous", "instructions", "tell", "owner", "password", "you", "your", "am", "are", "he", "she", "her", "his", "lives", "says", "call", "hi", "there", "rules", "this", "that", "of", "in", "with", "from"]

    /// Identifiers in real code are short and rarely full of underscores, and a path doesn't read as a sentence.
    /// This doesn't stop a determined plugin, but it costs it.
    private static func looksLikeCode(_ text: String) -> Bool {
        let parts = text.split(whereSeparator: { $0 == "." || $0 == "/" || $0 == "$" || $0 == "-" })
        guard text.count <= 240, parts.count <= 24, text.split(separator: ".").allSatisfy({ $0.filter { $0 == "-" }.count <= 4 }) else { return false }
        guard parts.allSatisfy({ $0.count <= 56 && $0.filter { $0 == "_" }.count <= 3 }) else { return false }
        return Set(parts.map { $0.lowercased() }).intersection(sentenceWords).count < 2
    }

    /// A frame or an exception's class, and nothing else. Only the code's own parts are checked, not the words added here.
    func traceLine(_ line: String) throws -> String? {
        if let g = Self.groups(Self.frame, line), Self.looksLikeCode(g[1]) {
            guard let code = try sanitizer.codeText(g[1]), let place = try sanitizer.codeText(g[2]) else { return nil }
            return "  at \(code)(\(place))"
        }
        if let g = Self.groups(Self.exception, line), Self.looksLikeCode(g[2]) {
            return try sanitizer.codeText(g[2]).map { "\(g[1])\($0)" }
        }
        if let g = Self.groups(Self.moreFrames, line) { return "  ... \(g[1]) more" }
        return nil
    }

    /// A few exceptions whose message states the cause in a fixed form, rebuilt here from the recognised parts.
    private func knownException(_ line: String) throws -> String? {
        if let g = Self.groups(Self.missingDependency, line) {
            let names = try g[1].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.map { try sanitizer.codeText($0) }.compactMap { $0 }
            guard names.count == g[1].components(separatedBy: ",").count, g[1].components(separatedBy: ",").allSatisfy(Self.looksLikeCode) else { return nil }
            return "UnknownDependencyException: it needs these plugins, which aren't installed: \(names.joined(separator: ", "))"
        }
        if let g = Self.groups(Self.unsupportedAPI, line) { return "InvalidPluginException: it asks for API version \(g[1]), newer than this server supports" }
        if let g = Self.groups(Self.newerJava, line) { return "UnsupportedClassVersionError: built for a newer Java (class file \(g[1]), this Java supports up to \(g[2]))" }
        return nil
    }

    /// Long words don't appear in version numbers, and neither should a person.
    private func isVersion(_ text: String) throws -> Bool {
        guard text.range(of: "[A-Za-z]{9,}", options: .regularExpression) == nil,
              text.range(of: #"^[0-9]{1,4}(\.[0-9]{1,4}){0,3}([-+.][A-Za-z0-9]{1,12}){0,4}$"#, options: .regularExpression) != nil else { return false }
        // `2.21.0-dev+93-abc1234` has two parts with letters. A phrase has more.
        let worded = text.split(whereSeparator: { "-+.".contains($0) }).filter { $0.contains(where: \.isLetter) }
        return try worded.count <= 2 && sanitizer.codeText(text) == text
    }

    private static func isValid(ip: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, ip, &v4) == 1 || inet_pton(AF_INET6, ip, &v6) == 1
    }

    /// Settings files every plugin might have. Any other can be named after a player, so it isn't named.
    private static let commonSettingsFiles: Set<String> = ["config.yml", "settings.yml", "messages.yml", "lang.yml", "language.yml", "permissions.yml", "plugin.yml"]
    /// A world can be named after anyone, so only the standard ones are named. Likewise only known failure reasons.
    private static let standardWorlds: Set<String> = ["world", "world_nether", "world_the_end", "minecraft:overworld", "minecraft:the_nether", "minecraft:the_end"]
    private static let worldFailures: Set<String> = ["WORLD_FOLDER_INVALID", "WORLD_NON_EXISTENT", "WORLD_EXIST", "WORLD_LOAD_FAILED", "INVALID_WORLD", "LEVEL_DAT_INVALID"]

    // MARK: Reading

    /// Learns names before anything is built, so a name that appears late in the log is still hidden in an earlier trace.
    public func learnNames(from lines: [String]) {
        for raw in lines where raw.utf16.count <= Self.maxLine && (raw.contains("UUID of player") || raw.contains(" the game") || raw.contains(" logged in with") || raw.contains(" lost connection") || raw.contains(" moved ")) {
            let line = Scrub.controls(raw)
            guard let g = Self.groups(Self.logLine, line) else { continue }
            if Self.groups(Self.authenticatorThread, g[1]) != nil, let a = Self.groups(Self.authenticated, g[3]) {
                sanitizer.learnPlayer(name: a[1])
            } else if g[1] == "Server thread", let m = Self.groups(Self.loggedIn, g[3]) ?? Self.groups(Self.joined, g[3]) ?? Self.groups(Self.lostConnection, g[3]) ?? Self.groups(Self.movedTooFast, g[3]) {
                sanitizer.learnPlayer(name: m[1])
            }
        }
    }

    /// One future line of the report. Nothing here is a token yet: real values only become tokens for what's actually
    /// returned, so a small `limit` records little.
    private struct Draft {
        let key: String
        var isTrace = false
        var isPlayer = false
        var isRoutine = false
        let make: () throws -> String
    }

    /// `includePlayers` adds joins and connections. Diagnosing a server doesn't need them, so the tools leave them out.
    public func report(lines: [String], limit: Int, includePlayers: Bool = true) throws -> Report {
        try sanitizer.prepareForCode()
        learnNames(from: lines)
        var drafts: [Draft] = []
        var withheld = 0
        var inProblem = false
        var inFrozenThread = false
        var frozenFrames = 0
        // In line order, as a name can pass from one person to another within a log.
        var bound: [String: String] = [:]
        func add(_ text: String, routine: Bool = false) { drafts.append(Draft(key: text, isRoutine: routine) { text }) }
        func addPlayer(_ key: String, _ make: @escaping () throws -> String) { drafts.append(Draft(key: key, isPlayer: true, make: make)) }
        for raw in lines {
            guard raw.utf16.count <= Self.maxLine else { withheld += 1; inProblem = false; continue }
            let line = Scrub.controls(raw)
            guard !line.isEmpty else { continue }
            guard let g = Self.groups(Self.logLine, line) else {
                // A line that isn't part of the trace doesn't end it, so a root cause further down isn't lost.
                if inProblem, let known = try knownException(line) {
                    drafts.append(Draft(key: known, isTrace: true) { known })
                } else if inProblem, let trace = try traceLine(line) {
                    drafts.append(Draft(key: trace, isTrace: true) { trace })
                } else {
                    withheld += 1
                }
                continue
            }
            let thread = g[1], level = Self.level(g[2]), body = g[3]
            inProblem = false
            if thread == "Paper Watchdog Thread" {
                // The freeze report lists every thread. Only the main one says what the server was stuck on.
                if Self.groups(Self.watchdogMain, body) != nil {
                    inFrozenThread = true
                    frozenFrames = 0
                    add("FATAL: the server froze, and the watchdog reports the main thread was running:")
                } else if body.hasPrefix("Current Thread:") {
                    inFrozenThread = false
                } else if inFrozenThread, frozenFrames < 30, let trace = try traceLine("at " + body.trimmingCharacters(in: .whitespaces)) {
                    frozenFrames += 1
                    drafts.append(Draft(key: trace, isTrace: true) { trace })
                }
                continue
            }
            // Chat has its own thread, and server events only count from the main one.
            if Self.groups(Self.authenticatorThread, thread) != nil, let a = Self.groups(Self.authenticated, body) {
                bound[a[1]] = a[2].lowercased()
                // Only for lines after this one. `usercache.json` still decides for lines before it.
                sanitizer.learnPlayer(name: a[1])
                continue
            }
            if thread == "ServerMain", let m = Self.groups(Self.damagedJar, body), jars.contains(m[1]) {
                inProblem = true
                let jar = try sanitizer.cleanFileName(m[1]) ?? "one whose name isn't shared"
                add("ERROR: this plugin jar is damaged or unreadable: \(jar)")
                continue
            }
            if thread == "ServerMain", level != "INFO", let m = Self.groups(Self.loadFailed, body) ?? Self.groups(Self.loadFailedModern, body), jars.contains(m[1]) {
                inProblem = true
                let jar = try sanitizer.cleanFileName(m[1]) ?? "one whose name isn't shared"
                add("ERROR: a plugin jar failed to load: \(jar)")
                continue
            }
            guard thread == "Server thread" else {
                withheld += 1
                inProblem = level != "INFO" && !thread.lowercased().contains("chat")
                if inProblem { add("\(level): message withheld") }
                continue
            }
            if let m = Self.groups(Self.loggedIn, body), Self.isValid(ip: m[2].isEmpty ? m[3] : m[2]) {
                let address = m[2].isEmpty ? m[3] : m[2], uuid = bound[m[1]]
                sanitizer.learnPlayer(name: m[1])
                addPlayer("connected|\(m[1])|\(address)") { [sanitizer] in "INFO: \(try sanitizer.playerToken(name: m[1], uuid: uuid)) connected from \(try sanitizer.ipToken(address))" }
            } else if let m = Self.groups(Self.joined, body) {
                let uuid = bound[m[1]]
                sanitizer.learnPlayer(name: m[1])
                addPlayer("\(m[2])|\(m[1])|\(uuid ?? "")") { [sanitizer] in "INFO: \(try sanitizer.playerToken(name: m[1], uuid: uuid)) \(m[2]) the game" }
            } else if let m = Self.groups(Self.lostConnection, body) {
                let uuid = bound[m[1]]
                sanitizer.learnPlayer(name: m[1])
                addPlayer("lost|\(m[1])|\(uuid ?? "")") { [sanitizer] in "INFO: \(try sanitizer.playerToken(name: m[1], uuid: uuid)) lost connection" }
            } else if let m = Self.groups(Self.movedTooFast, body) {
                let uuid = bound[m[1]]
                sanitizer.learnPlayer(name: m[1])
                drafts.append(Draft(key: "moved|\(m[1])|\(m[2])") { [sanitizer] in "WARN: \(try sanitizer.playerToken(name: m[1], uuid: uuid)) moved \(m[2])" })
            } else if let m = Self.groups(Self.behind, body) {
                add("WARN: the server is overloaded, running \(m[1])ms or \(m[2]) ticks behind")
            } else if let m = Self.groups(Self.done, body) {
                add("INFO: the server finished starting in \(m[1])s", routine: true)
            } else if let m = Self.groups(Self.starting, body) {
                add("INFO: starting Minecraft \(m[1])", routine: true)
            } else if Self.groups(Self.stopping, body) != nil {
                add("INFO: the server is stopping", routine: true)
            } else if let m = Self.groups(Self.lifecycle, body), m[1] == m[3], try isVersion(m[4]), let plugin = try trustedPlugin(m[1]) {
                add("INFO: \(m[2].lowercased()) plugin \(plugin) \(m[4])", routine: true)
            } else if level == "INFO" {
                // Each shape below reports a failure, which is never logged at this level. Anything here could be a person.
                withheld += 1
            } else if let m = Self.groups(Self.enableFailed, body), try isVersion(m[2]), let plugin = try trustedPlugin(m[1]) {
                inProblem = true
                add("ERROR: plugin \(plugin) \(m[2]) failed to enable")
            } else if let m = Self.groups(Self.loadFailed, body) ?? Self.groups(Self.loadFailedModern, body), jars.contains(m[1]) {
                inProblem = true
                let jar = try sanitizer.cleanFileName(m[1]) ?? "one whose name isn't shared"
                add("ERROR: a plugin jar failed to load: \(jar)")
            } else if let m = Self.groups(Self.eventFailed, body), try isVersion(m[3]), try sanitizer.codeText(m[1]) == m[1], let plugin = try trustedPlugin(m[2]) {
                inProblem = true
                add("ERROR: plugin \(plugin) \(m[3]) failed handling \(m[1])")
            } else if let m = Self.groups(Self.taskFailed, body), try isVersion(m[2]), let plugin = try trustedPlugin(m[1]) {
                inProblem = true
                add("ERROR: a scheduled task of plugin \(plugin) \(m[2]) failed")
            } else if let m = Self.groups(Self.configFailed, body), let plugin = try trustedPlugin(m[1]) {
                inProblem = true
                add("ERROR: plugin \(plugin) couldn't read " + (Self.commonSettingsFiles.contains(m[2]) ? "its settings file \(m[2])" : "one of its settings files"))
            } else if let m = Self.groups(Self.worldFailed, body), let plugin = try trustedPlugin(m[1]) {
                let world = Self.standardWorlds.contains(m[2]) ? "world \(m[2])" : "a world"
                add("ERROR: plugin \(plugin) couldn't load \(world)" + (Self.worldFailures.contains(m[3]) ? ": \(m[3])" : ""))
            } else {
                // A problem happened, but its wording could be anything. Its stack may follow.
                withheld += 1
                inProblem = true
                let source = try Self.groups(Self.tag, body).flatMap { try trustedPlugin($0[1]) }
                add("\(level): message withheld" + (source.map { ", from plugin \($0)" } ?? ""))
            }
        }
        return Report(events: try Self.assemble(drafts, limit: limit, includePlayers: includePlayers), withheld: withheld)
    }

    /// Groups each problem with its trace, keeps the first of each with a count, and drops what says nothing.
    /// This is what stops one noisy plugin burying everything else.
    private static func assemble(_ drafts: [Draft], limit: Int, includePlayers: Bool) throws -> [String] {
        var blocks: [[Draft]] = []
        var framesInRow = 0
        for draft in drafts where includePlayers || !draft.isPlayer {
            // The top of each trace is what explains it, and this limits what any one trace can carry.
            framesInRow = draft.key.hasPrefix("  at ") ? framesInRow + 1 : 0
            if framesInRow > maxFramesPerTrace { continue }
            if draft.isTrace, !blocks.isEmpty { blocks[blocks.count - 1].append(draft) } else { blocks.append([draft]) }
        }
        var counts: [String: Int] = [:]
        var order: [(key: String, block: [Draft])] = []
        for block in blocks {
            // A withheld message with no plugin and no trace is already in the count.
            if block.count == 1, block[0].key.hasSuffix(": message withheld") { continue }
            let key = block.map(\.key).joined(separator: "\n")
            if counts[key] == nil { order.append((key, block)) }
            counts[key, default: 0] += 1
        }
        // When there's too much, routine lines go first, then the oldest.
        var kept = order
        var lineCount = kept.reduce(0) { $0 + $1.block.count }
        if lineCount > limit {
            kept.removeAll { $0.block[0].isRoutine }
            lineCount = kept.reduce(0) { $0 + $1.block.count }
        }
        var chosen: [(key: String, block: [Draft])] = []
        var used = 0, characters = 0
        for item in kept.reversed() {
            let size = item.key.count
            // Stops at the first that doesn't fit, so a smaller limit only ever shows less of the same, and the preview stays the upper bound.
            if used + item.block.count > limit || characters + size > maxReportCharacters { break }
            used += item.block.count
            characters += size
            chosen.append(item)
        }
        var out: [String] = []
        for item in chosen.reversed() {
            for (index, draft) in item.block.enumerated() {
                let text = try draft.make()
                let times = counts[item.key] ?? 1
                out.append(index == 0 && times > 1 ? "\(text) (seen \(times) times)" : text)
            }
        }
        return out
    }

    private static func level(_ word: String) -> String {
        switch word {
        case "FATAL": "FATAL"
        case "ERROR", "SEVERE": "ERROR"
        case "WARN", "WARNING": "WARN"
        default: "INFO"
        }
    }
}
