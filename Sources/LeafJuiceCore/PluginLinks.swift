import Foundation

// Where to read about each plugin. LeafJuice keeps a link, not a copy of anyone's documentation. Only a source
// that's already known fills one in. A website field or a match by name can point at the wrong project, so those
// wait until someone chooses them.

public struct PluginLink: Codable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable {
        case modrinthWiki, modrinthCode, updateSource, website, nameMatch, typed

        public var explanation: String {
            switch self {
            case .modrinthWiki: "The wiki link on its Modrinth page."
            case .modrinthCode: "Modrinth lists no wiki for it, so this is its source code."
            case .updateSource: "The page of the source its updates come from."
            case .website: "The website in its plugin.yml, which you chose."
            case .nameMatch: "A match by name, which you chose."
            case .typed: "You added this."
            }
        }
    }
    public var url: String
    public var origin: Origin
    public init(url: String, origin: Origin) {
        self.url = url
        self.origin = origin
    }
    public var host: String { URL(string: url)?.host ?? url }
}

/// A link nobody has agreed to yet. It never shows as the plugin's link until it's chosen.
public struct PluginLinkSuggestion: Identifiable, Equatable, Sendable {
    public var id: String { link.url }
    public let link: PluginLink
    public let reason: String
}

/// What's saved for a server: links someone chose, by plugin, and what Modrinth said, by project.
public struct PluginLinkStore: Codable, Equatable, Sendable {
    public var chosen: [String: PluginLink] = [:]
    public var modrinth: [String: ModrinthLinks] = [:]
    public init() {}
}

public struct ModrinthLinks: Codable, Equatable, Sendable {
    public var wiki: String?
    public var code: String?
    public init(wiki: String? = nil, code: String? = nil) {
        self.wiki = wiki
        self.code = code
    }
}

public struct PluginLinkRow: Identifiable, Equatable, Sendable {
    public var id: String { key }
    public let key: String
    public let name: String
    public let version: String
    public let link: PluginLink?
    public let suggestions: [PluginLinkSuggestion]
}

public enum PluginLinks {
    /// Plain web addresses only. A jar or a project page supplies this text, and it gets opened in a browser.
    public static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 2048, let parts = URLComponents(string: trimmed),
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        return trimmed
    }

    /// The page for a source someone already set, or that matched the jar exactly.
    public static func fromSource(_ source: PluginSource, modrinth: ModrinthLinks?) -> PluginLink? {
        switch source {
        case .none: return nil
        case .modrinth:
            if let wiki = modrinth?.wiki.flatMap(clean) { return .init(url: wiki, origin: .modrinthWiki) }
            if let code = modrinth?.code.flatMap(clean) { return .init(url: code, origin: .modrinthCode) }
        case let .github(repo, _, _):
            return clean("https://github.com/\(repo)").map { .init(url: $0, origin: .updateSource) }
        default: break
        }
        return source.pageURL.flatMap { clean($0.absoluteString) }.map { .init(url: $0, origin: .updateSource) }
    }

    public static func rows(_ plugins: [InstalledPlugin], source: (InstalledPlugin) -> PluginSource, store: PluginLinkStore) -> [PluginLinkRow] {
        plugins.filter(\.enabled).map { plugin in
            let from = source(plugin)
            var known: ModrinthLinks?
            if case let .modrinth(project, _) = from { known = store.modrinth[project] }
            let link = store.chosen[plugin.key] ?? fromSource(from, modrinth: known)
            var suggestions: [PluginLinkSuggestion] = []
            if link == nil, let website = plugin.descriptor?.website.flatMap(clean) {
                suggestions.append(.init(link: .init(url: website, origin: .website), reason: "From the plugin's own plugin.yml."))
            }
            return PluginLinkRow(key: plugin.key, name: plugin.name, version: plugin.version, link: link, suggestions: suggestions)
        }
    }

    /// What Modrinth's project list returns, filed under both its ID and its slug, since a source can hold either.
    static func parseModrinth(_ data: Data) throws -> [String: ModrinthLinks] {
        struct Project: Decodable { let id: String; let slug: String?; let wiki_url: String?; let source_url: String? }
        var out: [String: ModrinthLinks] = [:]
        for project in try HTTP.decodeBody([Project].self, data) {
            let links = ModrinthLinks(wiki: project.wiki_url, code: project.source_url)
            out[project.id] = links
            if let slug = project.slug { out[slug] = links }
        }
        return out
    }

    static func modrinthAddress(_ projects: [String]) throws -> URL {
        let list = String(decoding: try JSONSerialization.data(withJSONObject: projects), as: UTF8.self)
        var parts = URLComponents(string: "https://api.modrinth.com/v2/projects")!
        parts.queryItems = [URLQueryItem(name: "ids", value: list)]
        return try HTTP.url(parts.string ?? "")
    }

    public static func lookUpModrinth(_ projects: [String]) async throws -> [String: ModrinthLinks] {
        guard !projects.isEmpty else { return [:] }
        return try parseModrinth(try await HTTP.data(modrinthAddress(projects)))
    }

    /// Asks Hangar and SpigotMC about this plugin's name. Only ever on request, because a private plugin's name is private.
    public static func searchByName(_ plugin: InstalledPlugin) async -> [PluginLinkSuggestion] {
        var seen = Set<String>()
        return await SourceFinder.suggestions(for: plugin).compactMap { found in
            guard let link = fromSource(found.source, modrinth: nil), seen.insert(link.url).inserted else { return nil }
            return .init(link: .init(url: link.url, origin: .nameMatch), reason: found.reason)
        }
    }
}

extension ServerController {
    private var savedLinks: URL { paths.meta.appendingPathComponent("plugin-links.json") }

    public var pluginLinkStore: PluginLinkStore { JSONStore.load(savedLinks, defaults: PluginLinkStore()) }

    public var pluginLinkRows: [PluginLinkRow] {
        PluginLinks.rows(plugins, source: { record(for: $0).source }, store: pluginLinkStore)
    }

    /// Returns false for anything that isn't a plain web address.
    @discardableResult
    public func chooseLink(_ text: String, origin: PluginLink.Origin, forPlugin key: String) -> Bool {
        guard let url = PluginLinks.clean(text) else { return false }
        var store = pluginLinkStore
        store.chosen[key] = PluginLink(url: url, origin: origin)
        try? JSONStore.save(store, to: savedLinks)
        return true
    }

    public func clearChosenLink(forPlugin key: String) {
        var store = pluginLinkStore
        store.chosen[key] = nil
        try? JSONStore.save(store, to: savedLinks)
    }

    /// Reads wiki links for plugins whose source is on Modrinth. Sends project IDs only, and no plugin names.
    /// With `all` false it only asks about projects it hasn't heard about.
    public func refreshModrinthLinks(all: Bool) async throws {
        var store = pluginLinkStore
        var wanted = Set<String>()
        for plugin in plugins where plugin.enabled {
            if case let .modrinth(project, _) = record(for: plugin).source, !project.isEmpty, all || store.modrinth[project] == nil {
                wanted.insert(project)
            }
        }
        guard !wanted.isEmpty else { return }
        store.modrinth.merge(try await PluginLinks.lookUpModrinth(wanted.sorted())) { _, new in new }
        // Choices may have changed while waiting.
        store.chosen = pluginLinkStore.chosen
        try? JSONStore.save(store, to: savedLinks)
    }
}
