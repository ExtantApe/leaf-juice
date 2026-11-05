import Foundation

// A wiki for each server, generated from what's installed. It only ever includes what's on an allowlist below:
// never plugin settings, player names, operator lists or anything from server.properties that isn't named here.

// MARK: - What a plugin says about itself

public struct PluginManual: Equatable, Sendable {
    public struct Command: Equatable, Identifiable, Sendable {
        public var id: String { name }
        public var name: String
        public var description = ""
        public var usage = ""
        public var aliases: [String] = []
        public var permission: String?
    }
    public struct Permission: Equatable, Identifiable, Sendable {
        public var id: String { node }
        public var node: String
        public var description = ""
        /// `true`, `false`, `op` or `not op`. Bukkit's default is `op`.
        public var defaultValue = "op"
        public var children: [String: Bool] = [:]
    }
    public var name: String
    public var version = ""
    public var description = ""
    public var website = ""
    public var authors: [String] = []
    public var commands: [Command] = []
    public var permissions: [Permission] = []
}

public enum PluginManualReader {
    private static func clean(_ raw: Substring) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.first == "\"" || text.first == "'", let quote = text.first, let close = text.dropFirst().firstIndex(of: quote) {
            text = String(text[text.index(after: text.startIndex)..<close])
        } else if let hash = text.range(of: " #") {
            text = String(text[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    private static func list(_ value: String) -> [String] {
        let body = value.hasPrefix("[") ? String(value.dropFirst().prefix { $0 != "]" }) : value
        return body.split(separator: ",").map { clean($0) }.filter { !$0.isEmpty }
    }

    private struct Line { let indent: Int; let key: String; let value: String; let isItem: Bool }

    private static func lines(_ text: String) -> [Line] {
        text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n").compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let indent = raw.prefix { $0 == " " }.count
            if trimmed.hasPrefix("- ") { return Line(indent: indent, key: "", value: clean(trimmed.dropFirst(2)), isItem: true) }
            guard let colon = trimmed.range(of: #":(\s|$)"#, options: .regularExpression) else {
                return Line(indent: indent, key: "", value: trimmed, isItem: false)
            }
            return Line(indent: indent, key: clean(trimmed[..<colon.lowerBound]), value: clean(trimmed[trimmed.index(after: colon.lowerBound)...]), isItem: false)
        }
    }

    /// Reads `plugin.yml` text. Only the shapes plugin.yml really uses, so one odd file can't stop the rest.
    public static func parse(_ text: String) -> PluginManual? {
        let all = lines(text)
        var manual = PluginManual(name: "")
        var i = 0
        func section(_ start: Int) -> (items: [Line], next: Int) {
            var j = start + 1
            var out: [Line] = []
            while j < all.count, all[j].indent > 0 { out.append(all[j]); j += 1 }
            return (out, j)
        }
        /// Text for a key: on its line, or continued on deeper lines after `>` or `|`.
        func scalar(_ items: [Line], _ at: Int, _ indent: Int) -> (String, Int) {
            var value = items[at].value
            var j = at + 1
            if value == ">" || value == "|" || value == ">-" || value == "|-" || value.isEmpty {
                var parts: [String] = []
                while j < items.count, items[j].indent > indent, !items[j].isItem, items[j].key.isEmpty {
                    parts.append(items[j].value)
                    j += 1
                }
                value = parts.joined(separator: " ")
            }
            return (value, j)
        }
        while i < all.count {
            let line = all[i]
            guard line.indent == 0, !line.key.isEmpty else { i += 1; continue }
            switch line.key.lowercased() {
            case "name": manual.name = line.value
            case "version": manual.version = line.value
            case "description": manual.description = line.value
            case "website": manual.website = line.value
            case "author": manual.authors = [line.value]
            case "authors":
                if !line.value.isEmpty { manual.authors = list(line.value) } else {
                    let (items, _) = section(i)
                    manual.authors = items.filter(\.isItem).map(\.value)
                }
            case "commands":
                let (items, next) = section(i)
                let top = items.first?.indent ?? 2
                var j = 0
                while j < items.count {
                    guard items[j].indent == top, !items[j].key.isEmpty else { j += 1; continue }
                    var command = PluginManual.Command(name: items[j].key)
                    let start = j
                    j += 1
                    while j < items.count, items[j].indent > top {
                        let field = items[j]
                        switch field.key.lowercased() {
                        case "description": let r = scalar(items, j, field.indent); command.description = r.0; j = r.1
                        case "usage": let r = scalar(items, j, field.indent); command.usage = r.0; j = r.1
                        case "permission": command.permission = field.value; j += 1
                        case "aliases":
                            if field.value.isEmpty {
                                j += 1
                                while j < items.count, items[j].isItem { command.aliases.append(items[j].value); j += 1 }
                            } else { command.aliases = list(field.value); j += 1 }
                        default: j += 1
                        }
                    }
                    _ = start
                    manual.commands.append(command)
                }
                i = next
                continue
            case "permissions":
                let (items, next) = section(i)
                let top = items.first?.indent ?? 2
                var j = 0
                while j < items.count {
                    guard items[j].indent == top, !items[j].key.isEmpty else { j += 1; continue }
                    var permission = PluginManual.Permission(node: items[j].key)
                    j += 1
                    while j < items.count, items[j].indent > top {
                        let field = items[j]
                        switch field.key.lowercased() {
                        case "description": let r = scalar(items, j, field.indent); permission.description = r.0; j = r.1
                        case "default": permission.defaultValue = field.value.lowercased(); j += 1
                        case "children":
                            j += 1
                            while j < items.count, items[j].indent > field.indent {
                                if items[j].isItem { permission.children[items[j].value] = true }
                                else if !items[j].key.isEmpty { permission.children[items[j].key] = items[j].value.lowercased() != "false" }
                                j += 1
                            }
                        default: j += 1
                        }
                    }
                    manual.permissions.append(permission)
                }
                i = next
                continue
            default: break
            }
            i += 1
        }
        return manual.name.isEmpty ? nil : manual
    }

    public static func read(jar: URL) async -> PluginManual? {
        guard let result = try? await Tool.run("/usr/bin/unzip", ["-p", jar.path, "plugin.yml"]), result.ok else { return nil }
        return parse(result.out)
    }
}

// MARK: - Ranks, from a LuckPerms export

public struct WikiRank: Equatable, Identifiable, Sendable {
    public struct Grant: Equatable, Sendable {
        public var node: String
        public var value: Bool
        /// Empty when it applies everywhere.
        public var context: String
    }
    public var id: String { name }
    public var name: String
    public var weight = 0
    public var prefix = ""
    public var parents: [String] = []
    public var grants: [Grant] = []
}

public enum WikiRanks {
    /// `lp export <file> --without-users`, which holds no players.
    public static func parse(_ data: Data) -> [WikiRank] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let groups = root["groups"] as? [String: Any] else { return [] }
        var out: [WikiRank] = []
        for (name, value) in groups {
            var rank = WikiRank(name: name)
            for node in ((value as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [] {
                guard let key = node["key"] as? String else { continue }
                let on = node["value"] as? Bool ?? true
                let context = (node["context"] as? [String: Any])?.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") ?? ""
                switch node["type"] as? String {
                case "weight": rank.weight = Int(key.split(separator: ".").last ?? "") ?? 0
                case "prefix":
                    let parts = key.split(separator: ".", maxSplits: 2).map(String.init)
                    if parts.count == 3 { rank.prefix = parts[2].replacingOccurrences(of: #"&[0-9a-fk-orA-FK-OR]"#, with: "", options: .regularExpression) }
                case "inheritance":
                    if on { rank.parents.append(key.replacingOccurrences(of: "group.", with: "")) }
                case "permission": rank.grants.append(.init(node: key, value: on, context: context))
                default: break
                }
            }
            out.append(rank)
        }
        return out.sorted { ($0.weight, $0.name) < ($1.weight, $1.name) }
    }

    static func matches(_ pattern: String, _ node: String) -> Bool {
        let p = pattern.lowercased(), n = node.lowercased()
        if p == n || p == "*" { return true }
        return p.hasSuffix(".*") && n.hasPrefix(p.dropLast())
    }

    /// Whether a rank has a node, directly, by wildcard, through a parent, or through a plugin's permission children.
    /// Nil means it says nothing either way. Most specific wins, and an exact `false` beats a wildcard.
    public static func has(_ rank: WikiRank, node: String, ranks: [WikiRank], permissions: [PluginManual.Permission], seen: Set<String> = []) -> Bool? {
        guard !seen.contains(rank.name) else { return nil }
        let exact = rank.grants.first { $0.node.lowercased() == node.lowercased() }
        if let exact { return exact.value }
        if let wild = rank.grants.filter({ matches($0.node, node) }).max(by: { $0.node.count < $1.node.count }) { return wild.value }
        for owner in permissions where owner.children[node] != nil {
            if rank.grants.contains(where: { $0.value && matches($0.node, owner.node) }) { return owner.children[node] }
        }
        let parents = rank.parents.compactMap { name in ranks.first { $0.name == name } }.sorted { $0.weight > $1.weight }
        for parent in parents {
            if let value = has(parent, node: node, ranks: ranks, permissions: permissions, seen: seen.union([rank.name])) { return value }
        }
        return nil
    }
}

// MARK: - What goes in the wiki

public struct WikiSettings: Codable, Equatable, Sendable {
    public var address = ""
    public var welcome = ""
    public var rules = ""
    /// Plugins left out of the player wiki.
    public var hiddenPlugins: Set<String> = []
    /// Lists commands whose plugin doesn't say who can use them.
    public var showUnconfirmed = false
    public init() {}
}

public struct WikiContent: Equatable, Sendable {
    public struct Who: Equatable, Sendable {
        public var everyone = false
        public var ranks: [String] = []
        /// The plugin doesn't say, and nothing grants it.
        public var unconfirmed = false
        public var isPublic: Bool { everyone || !ranks.isEmpty }
    }
    public struct Entry: Equatable, Identifiable, Sendable {
        public var id: String { command.name }
        public var command: PluginManual.Command
        public var who: Who
    }
    public struct Plugin: Equatable, Identifiable, Sendable {
        public var id: String { manual.name }
        public var manual: PluginManual
        public var entries: [Entry]
    }
    public struct World: Equatable, Identifiable, Sendable {
        public var id: String { name }
        public var name: String
        public var environment: String
        public var gameMode: String
        public var difficulty: String
        public var hidden: Bool
    }
    public var serverName: String
    public var message = ""
    public var software = ""
    public var facts: [(label: String, value: String)] = []
    public var plugins: [Plugin] = []
    public var ranks: [WikiRank] = []
    public var ranksKnown = false
    public var worlds: [World] = []
    public var packRequired: Bool?
    public var settings = WikiSettings()
    public var generated = Date()

    public static func == (a: WikiContent, b: WikiContent) -> Bool {
        a.serverName == b.serverName && a.plugins == b.plugins && a.ranks == b.ranks && a.worlds == b.worlds && a.settings == b.settings
    }

    public var commandCount: Int { plugins.reduce(0) { $0 + $1.entries.count } }
    public var publicCommandCount: Int { plugins.reduce(0) { $0 + $1.entries.filter(\.who.isPublic).count } }
}

public enum Wiki {
    /// The only server.properties settings a wiki may show. Everything else, passwords and secrets included, can't reach it.
    public static let allowedProperties: [(key: String, label: String)] = [
        ("difficulty", "Difficulty"), ("gamemode", "Game mode"), ("max-players", "Player limit"), ("pvp", "Player combat"), ("hardcore", "Hardcore"),
    ]

    public static func folder(_ serverName: String) -> URL {
        AppPaths.servers.appendingPathComponent(AppPaths.ownFolderName, isDirectory: true).appendingPathComponent("wiki", isDirectory: true).appendingPathComponent(ResourcePacks.slug(serverName), isDirectory: true)
    }
    static func settingsFile(_ serverName: String) -> URL { folder(serverName).appendingPathComponent("settings.json") }

    public static func loadSettings(_ serverName: String) -> WikiSettings {
        (try? Data(contentsOf: settingsFile(serverName))).flatMap { try? JSONStore.decoder.decode(WikiSettings.self, from: $0) } ?? WikiSettings()
    }
    public static func saveSettings(_ settings: WikiSettings, _ serverName: String) { try? JSONStore.save(settings, to: settingsFile(serverName)) }

    /// Who can use a command, going by the permission it declares.
    public static func who(_ command: PluginManual.Command, permissions: [PluginManual.Permission], ranks: [WikiRank]) -> WikiContent.Who {
        var out = WikiContent.Who()
        guard let node = command.permission, !node.isEmpty else {
            out.unconfirmed = true
            return out
        }
        let declared = permissions.first { $0.node.lowercased() == node.lowercased() }?.defaultValue
        let everyoneByDefault = declared == "true"
        let base = ranks.first { $0.name == "default" }
        let baseSays = base.flatMap { WikiRanks.has($0, node: node, ranks: ranks, permissions: permissions) }
        out.everyone = baseSays ?? everyoneByDefault
        if !out.everyone {
            for rank in ranks where rank.name != "default" {
                if WikiRanks.has(rank, node: node, ranks: ranks, permissions: permissions) == true { out.ranks.append(rank.name) }
            }
        }
        return out
    }

    public static func assemble(serverName: String, message: String, software: String, properties: String, manuals: [PluginManual], ranks: [WikiRank], ranksKnown: Bool, worlds: [WikiContent.World], settings: WikiSettings) -> WikiContent {
        let doc = PropertiesDocument(properties)
        var content = WikiContent(serverName: serverName, message: message, software: software)
        content.facts = allowedProperties.compactMap { item in doc.value(item.key).flatMap { $0.isEmpty ? nil : (item.label, friendly($0)) } }
        content.ranks = ranks
        content.ranksKnown = ranksKnown
        content.worlds = worlds
        content.settings = settings
        if let pack = doc.value("resource-pack"), !pack.isEmpty { content.packRequired = doc.value("require-resource-pack") == "true" }
        let allPermissions = manuals.flatMap(\.permissions)
        content.plugins = manuals.map { manual in
            WikiContent.Plugin(manual: manual, entries: manual.commands.map { command in
                WikiContent.Entry(command: command, who: who(command, permissions: allPermissions, ranks: ranks))
            })
        }.sorted { $0.manual.name.lowercased() < $1.manual.name.lowercased() }
        return content
    }

    private static func friendly(_ value: String) -> String {
        switch value.lowercased() {
        case "true": "On"
        case "false": "Off"
        default: value.prefix(1).uppercased() + value.dropFirst()
        }
    }

    // MARK: Writing it out

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    /// `/<command>` in a usage line means the command's own name. Color codes aren't for reading.
    static func tidyUsage(_ usage: String, _ command: String) -> String {
        usage.replacingOccurrences(of: "<command>", with: command).replacingOccurrences(of: #"[§&][0-9a-fk-orA-FK-OR]"#, with: "", options: .regularExpression)
    }

    private static func paragraphs(_ text: String) -> String {
        text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .map { "<p>\(escape($0).replacingOccurrences(of: "\n", with: "<br>"))</p>" }.joined(separator: "\n")
    }

    /// Hand-written notes for a plugin, kept outside what's generated so they survive every rebuild.
    public static func notesFile(_ serverName: String, plugin: String) -> URL {
        folder(serverName).appendingPathComponent("notes/\(ResourcePacks.slug(plugin)).txt")
    }

    private static func whoText(_ who: WikiContent.Who) -> String {
        if who.everyone { return "Everyone" }
        if !who.ranks.isEmpty { return who.ranks.joined(separator: ", ") }
        return who.unconfirmed ? "Not stated" : "Operators"
    }

    private static let style = """
    :root{--bg:#F8F6E9;--card:#FFFEF8;--ink:#2B3322;--muted:#5C6650;--line:#DCE3C8;--leaf:#4A6E22;--pop:#F4846B;--wash:#EEF3DC}
    @media(prefers-color-scheme:dark){:root{--bg:#2A3225;--card:#343E2E;--ink:#F1F4E6;--muted:#C2CBB0;--line:#4C5843;--leaf:#C3E491;--pop:#FF9E86;--wash:#3B4634}}
    *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
    header{padding:36px 24px 20px;max-width:980px;margin:auto}h1{margin:0;font-size:2.1rem}.motd{color:var(--muted);margin:.25rem 0 0}
    .join{display:inline-block;margin-top:14px;padding:8px 14px;background:var(--pop);color:#3A140B;border-radius:9px;font-weight:600}
    nav{max-width:980px;margin:auto;padding:0 24px 8px;display:flex;flex-wrap:wrap;gap:6px}nav a{padding:5px 11px;border:1px solid var(--line);border-radius:99px;color:var(--ink);text-decoration:none;background:var(--card)}
    main{max-width:980px;margin:auto;padding:8px 24px 60px}section{margin-top:22px}h2{color:var(--leaf);margin:0 0 8px;font-size:1.35rem}h3{margin:18px 0 4px}
    .card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px;margin-top:10px}
    table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:7px 8px;border-top:1px solid var(--line);vertical-align:top}th{font-size:.85rem;color:var(--muted);border-top:0}
    code{background:var(--wash);padding:1px 5px;border-radius:5px;font-size:.92em;overflow-wrap:anywhere}.muted{color:var(--muted);font-size:.9rem}
    input[type=search]{width:100%;padding:9px 12px;border:1px solid var(--line);border-radius:9px;background:var(--card);color:var(--ink);font:inherit;margin-top:8px}
    .tag{display:inline-block;padding:1px 8px;border-radius:99px;background:var(--wash);font-size:.82rem;margin:1px 3px 1px 0}
    a{color:var(--leaf)}footer{max-width:980px;margin:auto;padding:0 24px 40px;color:var(--muted);font-size:.85rem}
    """

    private static let script = """
    const box=document.getElementById('find');if(box)box.addEventListener('input',()=>{const q=box.value.toLowerCase();document.querySelectorAll('[data-find]').forEach(e=>{e.hidden=q&&!e.textContent.toLowerCase().includes(q)})});
    """

    /// One self-contained page, so it can be opened or hosted anywhere.
    public static func html(_ content: WikiContent, admin: Bool, notes: (String) -> String? = { _ in nil }) -> String {
        let settings = content.settings
        var nav: [(String, String)] = []
        var body: [String] = []
        func section(_ id: String, _ title: String, _ html: String) {
            nav.append((id, title))
            body.append("<section id=\"\(id)\"><h2>\(escape(title))</h2>\n\(html)\n</section>")
        }
        if !settings.welcome.isEmpty { section("welcome", "Welcome", "<div class=\"card\">\(paragraphs(settings.welcome))</div>") }
        if !settings.rules.isEmpty { section("rules", "Rules", "<div class=\"card\">\(paragraphs(settings.rules))</div>") }

        var facts = content.facts.map { (label: $0.label, value: $0.value) }
        if admin, !content.software.isEmpty { facts.insert((label: "Software", value: content.software), at: 0) }
        if let required = content.packRequired { facts.append((label: "Resource pack", value: required ? "Required. Accept it when you join." : "Offered when you join.")) }
        if !facts.isEmpty {
            section("server", "The server", "<div class=\"card\"><table>" + facts.map { "<tr><th scope=\"row\">\(escape($0.label))</th><td>\(escape($0.value))</td></tr>" }.joined() + "</table></div>")
        }

        let worlds = content.worlds.filter { admin || !$0.hidden }
        if !worlds.isEmpty {
            let rows = worlds.map { w in "<tr><td>\(escape(w.name))\(w.hidden ? " <span class=\"tag\">Hidden from players</span>" : "")</td><td>\(escape(w.environment))</td><td>\(escape(w.gameMode))</td><td>\(escape(w.difficulty))</td></tr>" }.joined()
            section("worlds", "Worlds", "<div class=\"card\"><table><thead><tr><th>World</th><th>Type</th><th>Game mode</th><th>Difficulty</th></tr></thead><tbody>\(rows)</tbody></table></div>")
        }

        if content.ranksKnown, !content.ranks.isEmpty {
            let rows = content.ranks.sorted { $0.weight > $1.weight }.map { rank -> String in
                var cells = "<td>\(escape(rank.prefix.isEmpty ? rank.name : "\(rank.name) (\(rank.prefix))"))</td><td>\(rank.parents.isEmpty ? "" : "Also has everything from " + escape(rank.parents.joined(separator: ", ")))</td>"
                if admin {
                    let grants = rank.grants.map { g in "<code>\(escape((g.value ? "" : "not ") + g.node))</code>\(g.context.isEmpty ? "" : " <span class=\"muted\">\(escape(g.context))</span>")" }.joined(separator: " ")
                    cells += "<td>\(grants)</td>"
                }
                return "<tr>\(cells)</tr>"
            }.joined()
            section("ranks", "Ranks", "<div class=\"card\"><table><thead><tr><th>Rank</th><th>Includes</th>\(admin ? "<th>Permissions</th>" : "")</tr></thead><tbody>\(rows)</tbody></table></div>")
        }

        var blocks: [String] = []
        var withheld = 0
        for plugin in content.plugins where admin || !settings.hiddenPlugins.contains(plugin.manual.name) {
            let shown = plugin.entries.filter { admin || $0.who.isPublic || (settings.showUnconfirmed && $0.who.unconfirmed) }
            withheld += plugin.entries.count - shown.count
            let note = notes(plugin.manual.name)
            guard !shown.isEmpty || note != nil else { continue }
            let rows = shown.map { entry -> String in
                let usage = tidyUsage(entry.command.usage.isEmpty ? "/\(entry.command.name)" : entry.command.usage, entry.command.name)
                var who = "<td>\(escape(whoText(entry.who)))</td>"
                if admin { who += "<td>\(entry.command.permission.map { "<code>\(escape($0))</code>" } ?? "")</td>" }
                let aliases = entry.command.aliases.isEmpty ? "" : "<div class=\"muted\">Also /\(entry.command.aliases.map(escape).joined(separator: ", /"))</div>"
                return "<tr data-find><td><code>\(escape(usage))</code>\(aliases)</td><td>\(escape(entry.command.description))</td>\(who)</tr>"
            }.joined()
            let head = "<h3>\(escape(plugin.manual.name))</h3>" + (plugin.manual.description.isEmpty ? "" : "<p class=\"muted\">\(escape(plugin.manual.description))</p>") + (note.map { "<div>\(paragraphs($0))</div>" } ?? "")
            let table = shown.isEmpty ? "" : "<table><thead><tr><th>Command</th><th>What it does</th><th>Who</th>\(admin ? "<th>Permission</th>" : "")</tr></thead><tbody>\(rows)</tbody></table>"
            blocks.append("<div class=\"card\">\(head)\(table)</div>")
        }
        if !blocks.isEmpty {
            let more = !admin && withheld > 0 ? "<p class=\"muted\">Only commands known to be open to players are listed.</p>" : ""
            section("commands", "Commands", "<input id=\"find\" type=\"search\" placeholder=\"Find a command\" aria-label=\"Find a command\">\(more)\(blocks.joined())")
        }

        if admin {
            let rows = content.plugins.map { p in "<tr data-find><td>\(escape(p.manual.name))</td><td>\(escape(p.manual.version))</td><td>\(escape(p.manual.authors.joined(separator: ", ")))</td><td>\(p.entries.count)</td><td>\(p.manual.permissions.count)</td></tr>" }.joined()
            section("plugins", "Plugins", "<div class=\"card\"><table><thead><tr><th>Plugin</th><th>Version</th><th>By</th><th>Commands</th><th>Permissions</th></tr></thead><tbody>\(rows)</tbody></table></div>")
            let perms = content.plugins.filter { !$0.manual.permissions.isEmpty }.map { p -> String in
                let rows = p.manual.permissions.map { "<tr data-find><td><code>\(escape($0.node))</code></td><td>\(escape($0.description))</td><td>\(escape($0.defaultValue))</td></tr>" }.joined()
                return "<div class=\"card\"><h3>\(escape(p.manual.name))</h3><table><thead><tr><th>Permission</th><th>What it allows</th><th>Default</th></tr></thead><tbody>\(rows)</tbody></table></div>"
            }.joined()
            if !perms.isEmpty { section("permissions", "Permissions", perms) }
        }

        let navHTML = nav.map { "<a href=\"#\($0.0)\">\(escape($0.1))</a>" }.joined()
        let join = settings.address.isEmpty ? "" : "<div class=\"join\">Join: \(escape(settings.address))</div>"
        let title = admin ? "\(content.serverName) admin wiki" : content.serverName
        return """
        <!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>\(escape(title))</title><style>\(style)</style></head>
        <body><header><h1>\(escape(title))</h1><p class="motd">\(escape(content.message))</p>\(join)</header><nav aria-label="Sections">\(navHTML)</nav><main>\(body.joined(separator: "\n"))</main>
        <footer>Made with Leaf Juice on \(content.generated.formatted(date: .abbreviated, time: .omitted)).\(admin ? " This page lists permissions, so keep it private." : "")</footer><script>\(script)</script></body></html>
        """
    }

    /// The same content for pasting elsewhere.
    public static func markdown(_ content: WikiContent, admin: Bool) -> String {
        var out = ["# \(content.serverName)\(admin ? " admin wiki" : "")", ""]
        if !content.message.isEmpty { out += [content.message, ""] }
        if !content.settings.address.isEmpty { out += ["**Join:** `\(content.settings.address)`", ""] }
        if !content.settings.welcome.isEmpty { out += ["## Welcome", "", content.settings.welcome, ""] }
        if !content.settings.rules.isEmpty { out += ["## Rules", "", content.settings.rules, ""] }
        if !content.facts.isEmpty { out += ["## The server", ""] + content.facts.map { "- **\($0.label):** \($0.value)" } + [""] }
        let worlds = content.worlds.filter { admin || !$0.hidden }
        if !worlds.isEmpty { out += ["## Worlds", ""] + worlds.map { "- **\($0.name):** \($0.environment), \($0.gameMode), \($0.difficulty)" } + [""] }
        if content.ranksKnown, !content.ranks.isEmpty { out += ["## Ranks", ""] + content.ranks.sorted { $0.weight > $1.weight }.map { "- **\($0.name)**\($0.parents.isEmpty ? "" : ", also has everything from \($0.parents.joined(separator: ", "))")" } + [""] }
        out += ["## Commands", ""]
        for plugin in content.plugins where admin || !content.settings.hiddenPlugins.contains(plugin.manual.name) {
            let shown = plugin.entries.filter { admin || $0.who.isPublic || (content.settings.showUnconfirmed && $0.who.unconfirmed) }
            guard !shown.isEmpty else { continue }
            out += ["### \(plugin.manual.name)", ""]
            for entry in shown {
                let usage = tidyUsage(entry.command.usage.isEmpty ? "/\(entry.command.name)" : entry.command.usage, entry.command.name).replacingOccurrences(of: "\n", with: " ")
                out.append("- `\(usage)`: \(entry.command.description) (\(whoText(entry.who)))")
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    /// Writes both views to a folder you choose. Nothing is written unless you export.
    public static func write(_ content: WikiContent, to destination: URL) throws {
        let name = content.serverName
        func notes(_ plugin: String) -> String? { try? String(contentsOf: notesFile(name, plugin: plugin), encoding: .utf8) }
        try FileOps.writeAtomic(html(content, admin: false, notes: notes), to: destination.appendingPathComponent("player/index.html"))
        try FileOps.writeAtomic(markdown(content, admin: false), to: destination.appendingPathComponent("player/wiki.md"))
        try FileOps.writeAtomic(html(content, admin: true, notes: notes), to: destination.appendingPathComponent("admin/index.html"))
        try FileOps.writeAtomic(markdown(content, admin: true), to: destination.appendingPathComponent("admin/wiki.md"))
    }
}

extension ServerController {
    private var savedRanks: URL { paths.meta.appendingPathComponent("wiki-ranks.json") }

    /// Asks LuckPerms for its groups while the server runs, without any players. Keeps a copy for when it's stopped.
    public func refreshWikiRanks() async {
        guard state == .running, plugins.contains(where: { $0.enabled && $0.key == "luckperms" }) else { return }
        let name = "leafjuice-wiki"
        let export = paths.plugins.appendingPathComponent("LuckPerms/\(name).json.gz")
        try? FileManager.default.removeItem(at: export)
        send("lp export \(name) --without-users")
        for _ in 0..<(20 * 4) where !FileOps.exists(export) || FileOps.size(export) == 0 { try? await Task.sleep(for: .milliseconds(250)) }
        try? await Task.sleep(for: .milliseconds(500))
        guard let result = try? await Tool.run("/usr/bin/gunzip", ["-c", export.path]), result.ok, !WikiRanks.parse(Data(result.out.utf8)).isEmpty else { return }
        try? FileOps.writeAtomic(result.out, to: savedRanks)
        try? FileManager.default.removeItem(at: export)
    }

    public var wikiRanks: [WikiRank] { (try? Data(contentsOf: savedRanks)).map(WikiRanks.parse) ?? [] }
    public var wikiRanksDate: Date? { FileOps.modified(savedRanks) }

    public func wikiContent(settings: WikiSettings) async -> WikiContent {
        await refreshPlugins()
        await refreshWorlds()
        var manuals: [PluginManual] = []
        for plugin in plugins where plugin.enabled {
            let jar = paths.plugins.appendingPathComponent(plugin.fileName)
            if let manual = await PluginManualReader.read(jar: jar) { manuals.append(manual) }
        }
        let properties = (try? String(contentsOf: paths.properties, encoding: .utf8)) ?? ""
        let ranks = wikiRanks
        let doc = PropertiesDocument(properties)
        func nice(_ text: String?) -> String { (text ?? "").isEmpty ? "" : text!.prefix(1).uppercased() + text!.dropFirst().lowercased() }
        let listed = worlds.map { world in
            WikiContent.World(
                name: world.title, environment: nice(world.multiverse?.environment ?? WorldEnvironment.guess(from: world.name).rawValue),
                gameMode: nice(world.multiverse?.gamemode ?? doc.value("gamemode")), difficulty: nice(world.multiverse?.difficulty ?? doc.value("difficulty")),
                hidden: world.multiverse?.hidden ?? false)
        }
        return Wiki.assemble(serverName: profile.name, message: serverMessage ?? "", software: profile.software.label, properties: properties, manuals: manuals, ranks: ranks, ranksKnown: !ranks.isEmpty, worlds: listed, settings: settings)
    }
}
