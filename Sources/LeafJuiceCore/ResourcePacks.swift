import Foundation

// Resource packs are zip files of pack.mcmeta and assets. The library keeps every version of every source untouched.
// A recipe says how to rank them. A build applies the recipe and writes the winners, plus a lock file recording
// every copy of every file, so two builds can be compared. Nothing reaches a server until you apply it.

// MARK: - Sources and licenses

public enum PackSource: Codable, Equatable, Sendable {
    case none
    case modrinth(project: String)
    case github(repo: String)
    case url(String)

    public var title: String {
        switch self {
        case .none: "Added by hand"
        case let .modrinth(project): "Modrinth: \(project)"
        case let .github(repo): "GitHub: \(repo)"
        case let .url(link): URL(string: link)?.host ?? link
        }
    }
    public var canCheckForUpdates: Bool {
        switch self {
        case .modrinth, .github: true
        case .none, .url: false
        }
    }

    /// Understands a pasted Modrinth or GitHub page, or a direct link to a zip.
    public static func parse(_ text: String) -> PackSource? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: clean), let host = url.host?.lowercased(), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        if host.hasSuffix("modrinth.com"), parts.count >= 2, ["resourcepack", "project", "shader", "datapack"].contains(parts[0]) { return .modrinth(project: parts[1]) }
        if host == "github.com", parts.count >= 2 { return .github(repo: "\(parts[0])/\(parts[1].replacingOccurrences(of: ".git", with: ""))") }
        return .url(clean)
    }
}

public struct PackLicense: Codable, Equatable, Sendable {
    public var id: String
    public var url: String?
    public init(id: String, url: String? = nil) { self.id = id; self.url = url }

    /// `LicenseRef-All-Rights-Reserved` reads as "All Rights Reserved".
    public var title: String { id.replacingOccurrences(of: "LicenseRef-", with: "").replacingOccurrences(of: id.hasPrefix("LicenseRef-") ? "-" : "\u{0}", with: " ") }

    public enum Sharing: Equatable, Sendable {
        case allowed
        /// Fine to share, on conditions worth repeating.
        case conditions(String)
        case ask(String)
    }

    /// A prompt to check, not legal advice: authors can grant more, and terms can say more, than an id does.
    public var sharing: Sharing {
        let lower = id.lowercased()
        if lower.contains("-nd") { return .ask("Its license doesn't allow changed versions, which a combined pack may be.") }
        if lower.contains("-nc") { return .conditions("Its license doesn't allow selling it.") }
        if lower.hasPrefix("cc-by") { return .conditions("Its license requires crediting the author, which the credits file does.") }
        for known in ["mit", "apache", "bsd", "cc0", "unlicense", "mpl", "isc", "zlib", "gpl", "lgpl", "agpl"] where lower.hasPrefix(known) { return .allowed }
        return .ask(lower.contains("all-rights-reserved") || lower.contains("arr") ? "All rights reserved, so sharing it needs the author's permission." : "Its terms aren't clear from here, so check with the author.")
    }
}

// MARK: - Library

public struct PackVersion: Codable, Identifiable, Equatable, Sendable {
    public var id: String { sha1 }
    public var file: String
    public var version: String
    public var sha1: String
    public var added: Date
    public var size: Int64
    public var format: Int?
    public var description: String
    public var fileCount: Int
    public var imageCount: Int
    /// Something worth knowing, such as not being made for your Minecraft version.
    public var note: String?

    public init(file: String, version: String, sha1: String, added: Date, size: Int64, format: Int?, description: String, fileCount: Int, imageCount: Int, note: String? = nil) {
        self.file = file; self.version = version; self.sha1 = sha1; self.added = added; self.size = size
        self.format = format; self.description = description; self.fileCount = fileCount; self.imageCount = imageCount; self.note = note
    }
}

public struct LibraryPack: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var source: PackSource = .none
    public var license: PackLicense?
    public var authors: [String] = []
    /// Oldest first. Versions are kept, so going back is always possible.
    public var versions: [PackVersion] = []
    public init(id: String, title: String, source: PackSource = .none, license: PackLicense? = nil, authors: [String] = [], versions: [PackVersion] = []) {
        self.id = id; self.title = title; self.source = source; self.license = license; self.authors = authors; self.versions = versions
    }
    public var latest: PackVersion? { versions.last }
    public func version(_ sha1: String?) -> PackVersion? { versions.first { $0.sha1 == sha1 } ?? latest }
}

protocol VersionTagged { var taggedVersions: [String] { get } }

public struct PackUpdate: Equatable, Sendable {
    public var version: String
    public var url: String
    public var sha1: String?
    public var fileName: String
    /// Set when no release was tagged for the version asked for, so this is just the newest.
    public var untaggedFor: String?
}

// MARK: - Recipes

public struct PackRecipe: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var pack: String
        /// Pinned, so an update is always a choice.
        public var version: String
        public var enabled = true
        public var excluded: Set<String> = []
        /// Song ids from the pack's songs.json to leave out, so Minecraft's own track plays. Optional, so older recipes still load.
        public var songsOff: Set<String>?
        public init(pack: String, version: String) { self.pack = pack; self.version = version }
    }
    public var name = "combined"
    /// Highest priority first, as in Minecraft's own list.
    public var entries: [Entry] = []
    /// A pack to put first for one kind of file, such as "Blocks".
    public var categoryWinners: [String: String] = [:]
    /// The most specific choice: a pack for one path.
    public var winners: [String: String] = [:]
    public init() {}
}

/// One path across every pack that has it.
public struct LockedFile: Codable, Equatable, Identifiable, Sendable {
    public struct Copy: Codable, Equatable, Sendable {
        public var pack: String
        public var sha1: String
    }
    public enum Reason: String, Codable, Sendable { case only, rank, category, picked, merged, mine }
    public var id: String { path }
    public var path: String
    public var copies: [Copy]
    public var winner: String
    public var reason: Reason
    /// Differs from every copy's when the file was merged.
    public var sha1: String
}

public struct PackLock: Codable, Equatable, Sendable {
    public var recipe: String
    public var date: Date
    public var versions: [String: String]
    public var files: [LockedFile]
}

public struct PackChanges: Equatable, Sendable {
    public struct Change: Identifiable, Equatable, Sendable {
        public var id: String { path }
        public var path: String
        public var detail: String
        public init(path: String, detail: String) { self.path = path; self.detail = detail }
    }
    public init() {}
    public var added: [Change] = []
    public var removed: [Change] = []
    /// What players would see differently.
    public var changed: [Change] = []
    /// Copies that changed but lost anyway, so nothing visible happens.
    public var hidden: [Change] = []
    /// A pick you made that no longer applies, because its file is gone.
    public var lostPicks: [String] = []
    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty && hidden.isEmpty && lostPicks.isEmpty }
    public var summary: String {
        if isEmpty { return "No changes." }
        var parts: [String] = []
        if !added.isEmpty { parts.append("\(added.count) new") }
        if !changed.isEmpty { parts.append("\(changed.count) changed") }
        if !removed.isEmpty { parts.append("\(removed.count) removed") }
        if !hidden.isEmpty { parts.append("\(hidden.count) changed but hidden by a higher pack") }
        if !lostPicks.isEmpty { parts.append("\(lostPicks.count) of your picks gone") }
        return parts.joined(separator: ", ")
    }
}

public struct PackBuild: Codable, Identifiable, Equatable, Sendable {
    public var id: String { sha1 }
    public var sha1: String
    public var date: Date
    public var size: Int64
    public var fileCount: Int
    public var format: Int?
    public var merged: [String]
    public var warnings: [String]
}

/// A recipe to hand to someone else: where to get each pack, and how to rank them. No pack contents.
public struct RecipeExport: Codable, Equatable, Sendable {
    public struct Pack: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var source: PackSource
        public var version: String
        public var sha1: String
        public var fileName: String
    }
    public var kind = "leaf-juice-pack-recipe"
    public var formatVersion = 1
    public var recipe: PackRecipe
    public var packs: [Pack]
}

public struct RecipeImport: Equatable, Sendable {
    public var recipe: PackRecipe
    public var fetched: [String] = []
    /// Packs with no way to get them, which someone has to supply.
    public var missing: [RecipeExport.Pack] = []
}

// MARK: - The engine

public enum ResourcePacks {
    public static let mineID = "my-changes"
    public static var folder: URL { AppPaths.servers.appendingPathComponent(AppPaths.ownFolderName, isDirectory: true).appendingPathComponent("resource-packs", isDirectory: true) }
    public static var library: URL { folder.appendingPathComponent("library", isDirectory: true) }
    public static var builds: URL { folder.appendingPathComponent("combined", isDirectory: true) }
    public static var recipes: URL { folder.appendingPathComponent("recipes", isDirectory: true) }
    public static var mine: URL { folder.appendingPathComponent("my-changes", isDirectory: true) }
    static var unpacked: URL { folder.appendingPathComponent(".unpacked", isDirectory: true) }
    static let unpackLimit: Int64 = 4_000_000_000
    public static let clientLimit: Int64 = 250_000_000

    public static func slug(_ text: String) -> String {
        let mapped = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : " " }
        let joined = String(mapped).split(separator: " ").joined(separator: "-")
        return joined.isEmpty ? "pack" : String(joined.prefix(60))
    }

    // MARK: Recipes on disk

    public static func recipeNames() -> [String] {
        FileOps.children(recipes).filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }
    public static func loadRecipe(_ name: String) -> PackRecipe {
        var recipe: PackRecipe = (try? Data(contentsOf: recipes.appendingPathComponent("\(slug(name)).json"))).flatMap { try? JSONStore.decoder.decode(PackRecipe.self, from: $0) } ?? PackRecipe()
        recipe.name = name
        return recipe
    }
    public static func saveRecipe(_ recipe: PackRecipe) { try? JSONStore.save(recipe, to: recipes.appendingPathComponent("\(slug(recipe.name)).json")) }
    public static func deleteRecipe(_ name: String) { try? FileManager.default.removeItem(at: recipes.appendingPathComponent("\(slug(name)).json")) }

    /// Newly added packs join at the bottom on their newest version, and removed ones drop out.
    public static func reconcile(_ recipe: PackRecipe, with packs: [LibraryPack]) -> PackRecipe {
        var out = recipe
        out.entries.removeAll { e in !packs.contains { $0.id == e.pack } }
        for pack in packs where !out.entries.contains(where: { $0.pack == pack.id }) {
            if let latest = pack.latest { out.entries.append(PackRecipe.Entry(pack: pack.id, version: latest.sha1)) }
        }
        return out
    }

    // MARK: Reading a zip

    /// Packs are often zipped inside a top folder, so the root is wherever pack.mcmeta is.
    static func root(of paths: [String]) -> String? {
        let found = paths.filter { ($0 == "pack.mcmeta" || $0.hasSuffix("/pack.mcmeta")) && !$0.hasPrefix("__MACOSX") }
            .sorted { $0.components(separatedBy: "/").count < $1.components(separatedBy: "/").count }.first
        return found.map { String($0.dropLast("pack.mcmeta".count)) }
    }

    public static func category(of path: String) -> String {
        let parts = path.components(separatedBy: "/")
        guard parts.count >= 3, parts[0] == "assets" else { return "Pack files" }
        let area = parts[2]
        if area == "textures", parts.count >= 4 {
            switch parts[3] {
            case "block", "blocks": return "Blocks"
            case "item", "items": return "Items"
            case "entity": return "Entities"
            case "gui": return "Interface"
            case "painting": return "Paintings"
            case "environment": return "Sky and weather"
            case "particle": return "Particles"
            default: return "Other textures"
            }
        }
        switch area {
        case "sounds", "sounds.json": return "Sounds"
        case "lang": return "Languages"
        case "font": return "Fonts"
        case "models", "blockstates", "items", "atlases", "equipment": return "Models"
        case "shaders", "post_effect": return "Shaders"
        default: return "Other"
        }
    }
    public static let categories = ["Blocks", "Items", "Entities", "Interface", "Paintings", "Sky and weather", "Particles", "Other textures", "Models", "Sounds", "Languages", "Fonts", "Shaders", "Other"]

    /// Removes a folder even if a pack left parts of it read-only.
    static func clear(_ folder: URL) async throws {
        guard FileOps.exists(folder) else { return }
        _ = try await Tool.run("/bin/chmod", ["-R", "u+rwX", folder.path])
        try FileManager.default.removeItem(at: folder)
    }

    static func bytes(inSummary text: String) -> Int64? {
        guard let r = text.range(of: #"[\d,]+ bytes uncompressed"#, options: .regularExpression) else { return nil }
        return Int64(text[r].prefix { $0.isNumber || $0 == "," }.replacingOccurrences(of: ",", with: ""))
    }

    /// Unpacked once per contents, and kept for browsing and building.
    public static func unpack(_ zip: URL) async throws -> URL {
        let digest = try Hashing.digests(of: zip).sha1
        let target = unpacked.appendingPathComponent(digest, isDirectory: true)
        if FileOps.exists(target.appendingPathComponent(".done")) { return target }
        let sizes = try await Tool.run("/usr/bin/unzip", ["-Zt", zip.path])
        guard sizes.ok else { throw LeafError("\(zip.lastPathComponent) isn't a zip file that can be read.") }
        if let total = bytes(inSummary: sizes.out), total > unpackLimit {
            throw LeafError("\(zip.lastPathComponent) would unpack to \(Format.bytes(total)), which is more than a resource pack should be.")
        }
        try await clear(target)
        try FileOps.ensureDir(target)
        let result = try await Tool.run("/usr/bin/unzip", ["-q", "-o", zip.path, "-d", target.path, "-x", "__MACOSX/*"])
        // unzip exits 1 for warnings such as odd path separators, which still unpack.
        guard result.code <= 1 else { throw LeafError("Couldn't unpack \(zip.lastPathComponent). \(result.err.prefix(200))") }
        // Observed: real packs can store read-only folders, which then can't be cleared or rebuilt from.
        _ = try await Tool.run("/bin/chmod", ["-R", "u+rwX", target.path])
        // Nothing may go missing quietly, because a build from this would be wrong without saying so.
        let names = try await Tool.run("/usr/bin/unzip", ["-Z1", zip.path])
        let wanted = names.out.split(separator: "\n").filter { !$0.hasSuffix("/") && !$0.hasPrefix("__MACOSX") && !$0.hasSuffix(".DS_Store") && !$0.contains("../") }.count
        let found = listing(target).count
        guard found >= wanted else { throw LeafError("\(zip.lastPathComponent) only partly unpacked: \(found) of \(wanted) files.") }
        try FileOps.writeAtomic("ok", to: target.appendingPathComponent(".done"))
        return target
    }

    static func listing(_ root: URL) -> [String] {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [String] = []
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(base + "/") else { continue }
            let rel = String(full.dropFirst(base.count + 1))
            if rel == ".done" || rel.hasSuffix(".DS_Store") || rel.hasPrefix("__MACOSX") { continue }
            out.append(rel)
        }
        return out.sorted()
    }

    static func describe(_ value: Any?) -> String {
        if let text = value as? String { return text.replacingOccurrences(of: #"§."#, with: "", options: .regularExpression) }
        if let parts = value as? [Any] { return parts.map(describe).joined() }
        if let object = value as? [String: Any] { return describe(object["text"]) + describe(object["extra"]) }
        return ""
    }

    /// Observed in real packs: `75`, `[75, 0]`, `[97.1]` and `88.0` all mean a format. The whole number is what counts.
    static func formatNumber(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let list = value as? [Any] { return formatNumber(list.first) }
        return nil
    }

    /// The pack's real root, and what it says about itself.
    static func read(_ zip: URL, version: String) async throws -> (info: PackVersion, root: URL) {
        let top = try await unpack(zip)
        let files = listing(top)
        guard let prefix = root(of: files) else { throw LeafError("\(zip.lastPathComponent) has no pack.mcmeta, so it isn't a resource pack.") }
        // Observed: a source project can hold many packs side by side, and picking one would quietly drop the rest.
        let roots = files.filter { ($0 == "pack.mcmeta" || $0.hasSuffix("/pack.mcmeta")) && !$0.hasPrefix("__MACOSX") }.map { String($0.dropLast("pack.mcmeta".count)) }
        let shallowest = roots.map { $0.components(separatedBy: "/").count }.min() ?? 0
        let level = roots.filter { $0.components(separatedBy: "/").count == shallowest }
        if level.count > 1 {
            let names = level.prefix(4).compactMap { $0.split(separator: "/").last.map(String.init) }.joined(separator: ", ")
            throw LeafError("\(zip.lastPathComponent) holds \(level.count) separate packs (\(names)…), so it looks like a project's source rather than one pack. Use its built pack, or zip just the one you want.")
        }
        let packRoot = prefix.isEmpty ? top : top.appendingPathComponent(prefix, isDirectory: true)
        let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: packRoot.appendingPathComponent("pack.mcmeta")))) as? [String: Any]
        guard let pack = meta?["pack"] as? [String: Any] else { throw LeafError("\(zip.lastPathComponent) has a pack.mcmeta that can't be read.") }
        let format = formatNumber(pack["pack_format"]) ?? formatNumber(pack["min_format"])
        let own = listing(packRoot)
        return (PackVersion(file: zip.lastPathComponent, version: version, sha1: try Hashing.digests(of: zip).sha1, added: Date(), size: FileOps.size(zip), format: format, description: describe(pack["description"]), fileCount: own.count, imageCount: own.filter { $0.lowercased().hasSuffix(".png") && $0.hasPrefix("assets/") }.count), packRoot)
    }

    // MARK: Library

    static func folder(of pack: String) -> URL { library.appendingPathComponent(pack, isDirectory: true) }
    public static func zip(_ pack: LibraryPack, _ version: PackVersion) -> URL { folder(of: pack.id).appendingPathComponent(version.file) }

    public static func list() -> [LibraryPack] {
        FileOps.children(library).filter(FileOps.isDirectory).compactMap { folder in
            (try? Data(contentsOf: folder.appendingPathComponent("pack.json"))).flatMap { try? JSONStore.decoder.decode(LibraryPack.self, from: $0) }
        }.sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    static func save(_ pack: LibraryPack) throws { try JSONStore.save(pack, to: folder(of: pack.id).appendingPathComponent("pack.json")) }

    /// Keeps a zip in the library. The same pack gets a new version, never a new entry, so a recipe's choices survive updates.
    @discardableResult
    public static func add(_ source: URL, title: String? = nil, id: String? = nil, from: PackSource = .none, version: String? = nil, license: PackLicense? = nil, authors: [String] = [], note: String? = nil) async throws -> LibraryPack {
        let base = source.deletingPathExtension().lastPathComponent
        let name = version ?? base
        var info = try await read(source, version: name).info
        info.note = note
        let packs = list()
        var existing = packs.first { $0.versions.contains { $0.sha1 == info.sha1 } }
        if existing == nil, from != .none { existing = packs.first { $0.source == from } }
        if existing == nil, let id { existing = packs.first { $0.id == id } }
        if var pack = existing {
            if pack.versions.contains(where: { $0.sha1 == info.sha1 }) { return pack }
            info.file = uniqueFile(source.lastPathComponent, in: pack.id)
            try FileManager.default.copyItem(at: source, to: folder(of: pack.id).appendingPathComponent(info.file))
            pack.versions.append(info)
            if let license { pack.license = license }
            if !authors.isEmpty { pack.authors = authors }
            try save(pack)
            return pack
        }
        var newID = id ?? slug(title ?? base)
        var n = 2
        while packs.contains(where: { $0.id == newID }) || newID == mineID { newID = "\(id ?? slug(title ?? base))-\(n)"; n += 1 }
        try FileOps.ensureDir(folder(of: newID))
        try FileManager.default.copyItem(at: source, to: folder(of: newID).appendingPathComponent(info.file))
        let pack = LibraryPack(id: newID, title: title ?? base, source: from, license: license, authors: authors, versions: [info])
        try save(pack)
        return pack
    }

    private static func uniqueFile(_ name: String, in pack: String) -> String {
        var candidate = name
        var n = 2
        while FileOps.exists(folder(of: pack).appendingPathComponent(candidate)) {
            candidate = "\((name as NSString).deletingPathExtension)-\(n).zip"
            n += 1
        }
        return candidate
    }

    /// Takes a pack and all its versions out of the library. Builds already made aren't affected.
    public static func remove(_ pack: LibraryPack) async throws {
        try FileManager.default.removeItem(at: folder(of: pack.id))
        for version in pack.versions { try await clear(unpacked.appendingPathComponent(version.sha1)) }
    }

    public static func images(in pack: LibraryPack, _ version: PackVersion) async throws -> [(path: String, url: URL)] {
        let root = try await read(zip(pack, version), version: version.version).root
        return listing(root).filter { $0.lowercased().hasSuffix(".png") && $0.hasPrefix("assets/") }.map { ($0, root.appendingPathComponent($0)) }
    }

    // MARK: Online sources

    private struct ModrinthProject: Decodable {
        struct License: Decodable { let id: String; let url: String? }
        let title: String; let slug: String; let license: License?
    }
    private struct ModrinthMember: Decodable { struct User: Decodable { let username: String }; let user: User }
    private struct ModrinthVersion: Decodable, VersionTagged {
        struct File: Decodable { struct Hashes: Decodable { let sha1: String? }; let url: String; let filename: String; let primary: Bool; let hashes: Hashes }
        let version_number: String; let files: [File]; let project_id: String
        let game_versions: [String]?
        var taggedVersions: [String] { game_versions ?? [] }
    }

    /// Observed: the TARDIS pack has no 1.21.11 release, and its newest is for a later Minecraft. The closest release
    /// that isn't newer than the server is the better bet, and the newest is only for when there's nothing older.
    static func bestForVersion<T: VersionTagged>(_ releases: [T], mc: String) -> [T] {
        guard let target = GameVersion(mc) else { return releases }
        let older = releases.filter { release in release.taggedVersions.contains { GameVersion($0).map { $0 <= target } ?? false } }
        return older.sorted { a, b in
            func top(_ r: T) -> GameVersion? { r.taggedVersions.compactMap(GameVersion.init).filter { $0 <= target }.max() }
            guard let x = top(a), let y = top(b) else { return false }
            return x > y
        } + releases.filter { release in !older.contains { $0.taggedVersions == release.taggedVersions } }
    }
    private struct GitHubRelease: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let tag_name: String; let assets: [Asset]; let zipball_url: String?
    }
    private struct GitHubRepo: Decodable { struct License: Decodable { let spdx_id: String? }; let name: String; let license: License?; let owner: Owner; struct Owner: Decodable { let login: String } }

    /// The newest release at a source, for this Minecraft version if the source can say.
    public static func latest(_ source: PackSource, mc: String?) async throws -> PackUpdate? {
        switch source {
        case .none: return nil
        case let .url(link):
            return PackUpdate(version: URL(string: link)?.deletingPathExtension().lastPathComponent ?? "download", url: link, sha1: nil, fileName: URL(string: link)?.lastPathComponent ?? "pack.zip")
        case let .modrinth(project):
            var address = "https://api.modrinth.com/v2/project/\(project)/version"
            if let mc, let encoded = "[\"\(mc)\"]".addingPercentEncoding(withAllowedCharacters: .alphanumerics) { address += "?game_versions=\(encoded)" }
            var versions = try await HTTP.decode([ModrinthVersion].self, HTTP.url(address))
            var nearest = false
            // Observed: packs often aren't tagged for every version, and the newest usually still works.
            // Its format is compared at build time, so a mismatch gets mentioned.
            var untagged: String?
            if versions.isEmpty, mc != nil {
                let all = try await HTTP.decode([ModrinthVersion].self, HTTP.url("https://api.modrinth.com/v2/project/\(project)/version"))
                versions = bestForVersion(all, mc: mc ?? "")
                nearest = true
                untagged = mc
            }
            guard let version = versions.first, let file = version.files.first(where: \.primary) ?? version.files.first else { return nil }
            _ = nearest
            return PackUpdate(version: version.version_number, url: file.url, sha1: file.hashes.sha1, fileName: file.filename, untaggedFor: untagged)
        case let .github(repo):
            let release = try await HTTP.decode(GitHubRelease.self, HTTP.url("https://api.github.com/repos/\(repo)/releases/latest"))
            if let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }) {
                return PackUpdate(version: release.tag_name, url: asset.browser_download_url, sha1: nil, fileName: asset.name)
            }
            guard let ball = release.zipball_url else { return nil }
            return PackUpdate(version: release.tag_name, url: ball, sha1: nil, fileName: "\(repo.components(separatedBy: "/").last ?? "pack")-\(release.tag_name).zip")
        }
    }

    /// Whether a source has something newer than the newest version kept here.
    public static func checkUpdate(_ pack: LibraryPack, mc: String?) async throws -> PackUpdate? {
        guard pack.source.canCheckForUpdates, let found = try await latest(pack.source, mc: mc) else { return nil }
        if let sha1 = found.sha1, pack.versions.contains(where: { $0.sha1 == sha1 }) { return nil }
        if pack.versions.contains(where: { $0.version == found.version }) { return nil }
        return found
    }

    /// Who made it and on what terms, where the source can say.
    private static func details(_ source: PackSource) async -> (title: String?, id: String?, license: PackLicense?, authors: [String]) {
        switch source {
        case let .modrinth(project):
            let info = try? await HTTP.decode(ModrinthProject.self, HTTP.url("https://api.modrinth.com/v2/project/\(project)"))
            let members = (try? await HTTP.decode([ModrinthMember].self, HTTP.url("https://api.modrinth.com/v2/project/\(project)/members"))) ?? []
            return (info?.title, info?.slug, info?.license.map { PackLicense(id: $0.id, url: $0.url) }, members.map(\.user.username))
        case let .github(repo):
            let info = try? await HTTP.decode(GitHubRepo.self, HTTP.url("https://api.github.com/repos/\(repo)"))
            let license = info?.license?.spdx_id.flatMap { $0 == "NOASSERTION" ? nil : PackLicense(id: $0) }
            return (info?.name, nil, license, info.map { [$0.owner.login] } ?? [])
        default:
            return (nil, nil, nil, [])
        }
    }

    /// Downloads a release into the library, keeping any earlier ones.
    @discardableResult
    public static func download(_ source: PackSource, update: PackUpdate? = nil, mc: String?) async throws -> LibraryPack {
        guard let found = try await (update != nil ? update : latest(source, mc: mc)) else {
            throw LeafError("No release found at \(source.title)\(mc.map { " for Minecraft \($0)" } ?? ""). Try one made for another version, or add the file by hand.")
        }
        let work = folder.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        try FileOps.ensureDir(work)
        defer { try? FileManager.default.removeItem(at: work) }
        let safeName = (found.fileName as NSString).lastPathComponent
        let target = work.appendingPathComponent(safeName.lowercased().hasSuffix(".zip") ? safeName : "\(safeName).zip")
        try await HTTP.download(HTTP.url(found.url), to: target, expect: ExpectedHashes(sha1: found.sha1))
        let about = await details(source)
        let note = found.untaggedFor.map { "Not marked as made for Minecraft \($0), so this is the closest release. It may not suit that version." }
        return try await add(target, title: about.title, id: about.id, from: source, version: found.version, license: about.license, authors: about.authors, note: note)
    }

    // MARK: Resolving

    /// Which JSON files can be merged rather than one replacing the other.
    static func mergeKind(_ path: String) -> MergeKind? {
        let parts = path.components(separatedBy: "/")
        guard let assets = parts.firstIndex(of: "assets"), parts.count > assets + 2, path.hasSuffix(".json") else { return nil }
        let rest = Array(parts[(assets + 2)...])
        if rest == ["sounds.json"] { return .sounds }
        switch rest.first {
        case "lang": return .keys
        case "atlases": return .list("sources")
        case "font": return .list("providers")
        case "models" where rest.count >= 2 && rest[1] == "item": return .list("overrides")
        default: return nil
        }
    }

    enum MergeKind: Equatable { case keys, sounds, list(String) }

    /// Merges JSON, highest priority first. Nil if any of it can't be read, so the winner's copy is used instead.
    static func merge(_ kind: MergeKind, _ documents: [Data]) -> Data? {
        var parsed: [[String: Any]] = []
        for data in documents {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            parsed.append(object)
        }
        guard var result = parsed.first else { return nil }
        switch kind {
        case .keys:
            for lower in parsed.dropFirst() { for (key, value) in lower where result[key] == nil { result[key] = value } }
        case .sounds:
            // As Minecraft does across a stack: sounds add up, unless the higher one says to replace.
            for lower in parsed.dropFirst() {
                for (event, value) in lower {
                    guard let above = result[event] as? [String: Any] else {
                        if result[event] == nil { result[event] = value }
                        continue
                    }
                    if above["replace"] as? Bool == true { continue }
                    var combined = above
                    combined["sounds"] = ((above["sounds"] as? [Any]) ?? []) + (((value as? [String: Any])?["sounds"] as? [Any]) ?? [])
                    if (value as? [String: Any])?["replace"] as? Bool == true { combined["replace"] = true }
                    result[event] = combined
                }
            }
        case let .list(key):
            var all: [Any] = []
            for document in parsed { all += (document[key] as? [Any]) ?? [] }
            if !all.isEmpty { result[key] = all }
        }
        return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    struct Source {
        var id: String; var title: String; var root: URL; var files: [String]; var meta: [String: Any]?; var icon: URL?
        /// A file under today's name, read from where an older pack keeps it.
        var renamed: [String: String] = [:]
        var songs: PackSongList?
        /// For the build's warnings.
        var notes: [String] = []
        func url(_ path: String) -> URL { root.appendingPathComponent(renamed[path] ?? path) }
    }

    /// Textures Minecraft moved without changing their layout, so older art still fits under the new name.
    /// Only one-to-one moves: sheets that were split up can't be rescued by renaming.
    static let renames: [String: String] = {
        var out = [
            "block/chain": "block/iron_chain", "item/chain": "item/iron_chain", "block/grass": "block/short_grass", "item/scute": "item/turtle_scute",
            "item/broken_elytra": "item/broken_elytra", "entity/elytra": "entity/equipment/wings/elytra",
            "entity/pig/pig_saddle": "entity/equipment/pig_saddle/saddle", "entity/strider/strider_saddle": "entity/equipment/strider_saddle/saddle",
            "entity/horse/armor/horse_armor_diamond": "entity/equipment/horse_body/diamond", "entity/horse/armor/horse_armor_gold": "entity/equipment/horse_body/gold",
            "entity/horse/armor/horse_armor_iron": "entity/equipment/horse_body/iron", "entity/horse/armor/horse_armor_leather": "entity/equipment/horse_body/leather",
            "entity/llama/decor/trader_llama": "entity/equipment/llama_body/trader_llama",
            "item/empty_armor_slot_helmet": "gui/sprites/container/slot/helmet", "item/empty_armor_slot_chestplate": "gui/sprites/container/slot/chestplate",
            "item/empty_armor_slot_leggings": "gui/sprites/container/slot/leggings", "item/empty_armor_slot_boots": "gui/sprites/container/slot/boots",
            "item/empty_armor_slot_shield": "gui/sprites/container/slot/shield",
        ]
        for color in ["black", "blue", "brown", "cyan", "gray", "green", "light_blue", "light_gray", "lime", "magenta", "orange", "pink", "purple", "red", "white", "yellow"] {
            out["entity/llama/decor/\(color)"] = "entity/equipment/llama_body/\(color)"
        }
        out["item/broken_elytra"] = nil
        return out
    }()

    /// Today's paths this pack can supply from older names, without overriding anything it already has under the new name.
    static func rescued(_ files: [String]) -> [String: String] {
        let have = Set(files)
        var out: [String: String] = [:]
        for (old, new) in renames {
            let from = "assets/minecraft/textures/\(old).png", to = "assets/minecraft/textures/\(new).png"
            if have.contains(from), !have.contains(to) { out[to] = from }
        }
        return out
    }

    /// Each pack in rank order, with "My changes" always first.
    static func sources(_ recipe: PackRecipe) async throws -> [Source] {
        var out: [Source] = []
        let edits = listing(mine)
        if !edits.isEmpty { out.append(Source(id: mineID, title: "My changes", root: mine, files: edits, meta: nil, icon: nil)) }
        let packs = list()
        for entry in recipe.entries where entry.enabled {
            guard let pack = packs.first(where: { $0.id == entry.pack }), let version = pack.versions.first(where: { $0.sha1 == entry.version }) ?? pack.latest else { continue }
            let root = try await read(zip(pack, version), version: version.version).root
            // Loose files at the top are a pack's license or readme, not something a game reads, so they aren't ranked.
            let songs = songList(root: root)
            let off = entry.songsOff ?? []
            let dropped = songs?.files(off: off) ?? []
            var notes: [String] = []
            if !off.isEmpty {
                if let songs, !songs.usable {
                    notes.append("Songs were switched off in \(pack.title), but its song list has a problem, so every song is included. \(songs.problems.first ?? "")")
                } else if songs == nil {
                    notes.append("Songs were switched off in \(pack.title), but this version has no song list, so every song is included.")
                } else if let songs {
                    let gone = off.subtracting(songs.songs.map(\.id)).sorted()
                    if !gone.isEmpty { notes.append("\(pack.title) no longer lists these switched-off songs: \(gone.joined(separator: ", ")).") }
                }
            }
            let files = listing(root).filter { $0.contains("/") && !entry.excluded.contains(category(of: $0)) && !dropped.contains($0) }
            let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("pack.mcmeta")))) as? [String: Any]
            let icon = root.appendingPathComponent("pack.png")
            let renamed = rescued(files).filter { !entry.excluded.contains(category(of: $0.key)) }
            out.append(Source(id: pack.id, title: pack.title, root: root, files: files + renamed.keys, meta: meta, icon: FileOps.exists(icon) ? icon : nil, renamed: renamed, songs: songs, notes: notes))
        }
        return out
    }

    /// Most specific wins: your edits, then a pick for this file, then a pack for this category, then rank.
    static func winner(path: String, candidates: [String], recipe: PackRecipe) -> (String, LockedFile.Reason) {
        if candidates.contains(mineID) { return (mineID, .mine) }
        if candidates.count == 1 { return (candidates[0], .only) }
        if let picked = recipe.winners[path], candidates.contains(picked) { return (picked, .picked) }
        if let top = recipe.categoryWinners[category(of: path)], candidates.contains(top) { return (top, .category) }
        return (candidates[0], .rank)
    }

    /// Every path, every copy, and who wins. Doesn't write anything.
    public static func resolve(_ recipe: PackRecipe) async throws -> PackLock {
        let sources = try await sources(recipe)
        return try await lock(recipe, sources: sources)
    }

    private static func lock(_ recipe: PackRecipe, sources: [Source]) async throws -> PackLock {
        var providers: [String: [String]] = [:]
        var locations: [String: [String: URL]] = [:]
        for source in sources {
            for file in source.files {
                providers[file, default: []].append(source.id)
                locations[file, default: [:]][source.id] = source.url(file)
            }
        }
        let mapped = providers
        let places = locations
        var files: [LockedFile] = []
        files.reserveCapacity(mapped.count)
        for (path, who) in mapped {
            let copies = who.compactMap { id -> LockedFile.Copy? in
                guard let url = places[path]?[id], let data = try? Data(contentsOf: url) else { return nil }
                return LockedFile.Copy(pack: id, sha1: Hashing.sha1(data))
            }
            var (top, reason) = winner(path: path, candidates: who, recipe: recipe)
            var sha1 = copies.first { $0.pack == top }?.sha1 ?? ""
            if who.count > 1, top != mineID, let kind = mergeKind(path) {
                let ordered = ([top] + who.filter { $0 != top }).compactMap { places[path]?[$0] }.compactMap { try? Data(contentsOf: $0) }
                if let merged = merge(kind, ordered) {
                    reason = .merged
                    sha1 = Hashing.sha1(merged)
                }
            }
            files.append(LockedFile(path: path, copies: copies, winner: top, reason: reason, sha1: sha1))
        }
        let list = self.list()
        var versions: [String: String] = [:]
        for entry in recipe.entries where entry.enabled {
            if let pack = list.first(where: { $0.id == entry.pack }) { versions[entry.pack] = pack.version(entry.version)?.version ?? "" }
        }
        return PackLock(recipe: recipe.name, date: Date(), versions: versions, files: files.sorted { $0.path < $1.path })
    }

    /// Files more than one pack has and which can't be merged, so one has to win.
    public static func conflicts(_ lock: PackLock) -> [LockedFile] {
        lock.files.filter { $0.copies.count > 1 && $0.reason != .merged && $0.reason != .mine && Set($0.copies.map(\.sha1)).count > 1 }
    }

    /// What differs between two states, in terms of what players would see.
    public static func changes(from old: PackLock, to new: PackLock, recipe: PackRecipe? = nil) -> PackChanges {
        var out = PackChanges()
        var titles = Dictionary(uniqueKeysWithValues: list().map { ($0.id, $0.title) })
        titles[mineID] = "My changes"
        func name(_ id: String) -> String { titles[id] ?? id }
        let before = Dictionary(uniqueKeysWithValues: old.files.map { ($0.path, $0) })
        let after = Dictionary(uniqueKeysWithValues: new.files.map { ($0.path, $0) })
        for file in new.files {
            guard let was = before[file.path] else {
                out.added.append(.init(path: file.path, detail: "From \(name(file.winner))"))
                continue
            }
            if was.sha1 != file.sha1 {
                out.changed.append(.init(path: file.path, detail: was.winner == file.winner ? "\(name(file.winner)) updated it" : "Now from \(name(file.winner)), was \(name(was.winner))"))
            } else if was.copies != file.copies {
                let differing = file.copies.filter { c in !was.copies.contains(c) }.map { name($0.pack) }
                out.hidden.append(.init(path: file.path, detail: "\(differing.joined(separator: ", ")) changed, but \(name(file.winner)) still wins"))
            }
        }
        for file in old.files where after[file.path] == nil { out.removed.append(.init(path: file.path, detail: "Was from \(name(file.winner))")) }
        if let recipe { out.lostPicks = recipe.winners.keys.filter { after[$0] == nil }.sorted() }
        return out
    }

    // MARK: Building

    private static func folder(forBuildsOf recipe: String) -> URL { builds.appendingPathComponent(slug(recipe), isDirectory: true) }
    public static func buildFile(_ build: PackBuild, recipe: String) -> URL { buildFile(sha1: build.sha1, recipe: recipe) }
    public static func buildFile(sha1: String, recipe: String) -> URL { folder(forBuildsOf: recipe).appendingPathComponent("\(sha1).zip") }
    public static func lockFile(sha1: String, recipe: String) -> URL { folder(forBuildsOf: recipe).appendingPathComponent("\(sha1).lock.json") }

    /// Newest first. Kept so going back is only a matter of pointing the server at an older file.
    public static func history(_ recipe: String) -> [PackBuild] {
        FileOps.children(folder(forBuildsOf: recipe)).filter { $0.lastPathComponent.hasSuffix(".build.json") }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONStore.decoder.decode(PackBuild.self, from: $0) } }
            .sorted { $0.date > $1.date }
    }

    public static func loadLock(sha1: String, recipe: String) -> PackLock? {
        (try? Data(contentsOf: lockFile(sha1: sha1, recipe: recipe))).flatMap { try? JSONStore.decoder.decode(PackLock.self, from: $0) }
    }

    public static func credits(_ recipe: PackRecipe) -> String {
        let packs = list()
        var lines = ["Combined with Leaf Juice from these packs. Their authors made them, so please credit them.", "Shared for free, not for sale.", ""]
        for entry in recipe.entries where entry.enabled {
            guard let pack = packs.first(where: { $0.id == entry.pack }) else { continue }
            lines.append(pack.title)
            lines.append("  Version: \(pack.version(entry.version)?.version ?? "unknown")")
            if !pack.authors.isEmpty { lines.append("  By: \(pack.authors.joined(separator: ", "))") }
            lines.append("  License: \(pack.license?.id ?? "unknown")")
            lines.append("  From: \(pack.source.title)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Builds one pack from a recipe. The same recipe and sources give a byte-identical file, and so the same SHA-1.
    public static func combine(_ recipe: PackRecipe) async throws -> PackBuild {
        let sources = try await sources(recipe)
        guard !sources.isEmpty else { throw LeafError("Choose at least one pack to include.") }
        let lock = try await lock(recipe, sources: sources)
        let work = folder.appendingPathComponent(".building-\(UUID().uuidString)", isDirectory: true)
        try FileOps.ensureDir(work)
        defer { try? FileManager.default.removeItem(at: work) }
        var merged: [String] = [], warnings: [String] = sources.flatMap(\.notes)
        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        for file in lock.files {
            let target = work.appendingPathComponent(file.path)
            try FileOps.ensureDir(target.deletingLastPathComponent())
            guard let source = byID[file.winner] else { continue }
            if file.reason == .merged, let kind = mergeKind(file.path) {
                let others = file.copies.map(\.pack).filter { $0 != file.winner }
                let documents = ([file.winner] + others).compactMap { byID[$0]?.url(file.path) }.compactMap { try? Data(contentsOf: $0) }
                if let data = merge(kind, documents) {
                    try data.write(to: target)
                    merged.append(file.path)
                    continue
                }
                warnings.append("\(file.path) couldn't be read, so the top pack's copy was used.")
            }
            try FileManager.default.copyItem(at: source.url(file.path), to: target)
        }

        // pack.mcmeta: wide enough for everything included.
        let metas = sources.compactMap(\.meta)
        let bodies = metas.compactMap { $0["pack"] as? [String: Any] }
        func number(_ value: Any?) -> Int? { formatNumber(value) }
        let formats = bodies.compactMap { formatNumber($0["pack_format"]) }
        let distinct = Set(bodies.compactMap { number($0["pack_format"]) ?? number($0["min_format"]) })
        if distinct.count > 1 {
            warnings.append("These packs were made for different Minecraft versions (formats \(distinct.sorted().map(String.init).joined(separator: ", "))). Some files may not work on your version.")
        }
        var body: [String: Any] = ["description": "Combined by Leaf Juice: " + sources.filter { $0.id != mineID }.map(\.title).joined(separator: " + ")]
        // Newer packs give min_format instead, and it counts just the same.
        let top = distinct.max()
        if let top { body["pack_format"] = top }
        var low: [Int] = [], high: [Int] = []
        for b in bodies {
            if let n = number(b["pack_format"]) { low.append(n); high.append(n) }
            if let s = b["supported_formats"] as? [Int], s.count == 2 { low.append(s[0]); high.append(s[1]) }
            if let s = b["supported_formats"] as? [String: Int], let a = s["min_inclusive"], let z = s["max_inclusive"] { low.append(a); high.append(z) }
            if let a = number(b["min_format"]) { low.append(a) }
            if let z = number(b["max_format"]) { high.append(z) }
        }
        if let a = low.min(), let z = high.max() {
            if bodies.contains(where: { $0["min_format"] != nil }) { body["min_format"] = a; body["max_format"] = z }
            if a != z { body["supported_formats"] = [a, z] }
        }
        var meta: [String: Any] = ["pack": body]
        let overlays = metas.compactMap { ($0["overlays"] as? [String: Any])?["entries"] as? [Any] }.flatMap { $0 }
        if !overlays.isEmpty { meta["overlays"] = ["entries": overlays] }
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: work.appendingPathComponent("pack.mcmeta"))
        if let icon = sources.compactMap(\.icon).first { try FileManager.default.copyItem(at: icon, to: work.appendingPathComponent("pack.png")) }
        let songCredits = songCredits(sources)
        try FileOps.writeAtomic(credits(recipe) + (songCredits.isEmpty ? "" : "\n\n" + songCredits), to: work.appendingPathComponent("CREDITS.txt"))
        // Each pack keeps its own license and readme, since many licenses require them to travel with the work.
        for source in sources where source.id != mineID {
            for loose in listing(source.root) where !loose.contains("/") && loose != "pack.mcmeta" && loose != "pack.png" && loose != songListName {
                let target = work.appendingPathComponent("credits/\(source.id)/\(loose)")
                try FileOps.ensureDir(target.deletingLastPathComponent())
                try FileManager.default.copyItem(at: source.root.appendingPathComponent(loose), to: target)
            }
        }

        let out = folder(forBuildsOf: recipe.name)
        try FileOps.ensureDir(out)
        let part = out.appendingPathComponent(".\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: part) }
        // Fixed times and a fixed order: nothing changed means the same SHA-1, so nobody uploads for nothing.
        let script = #"chmod -R u=rwX,go=rX . && find . -exec touch -t 200001010000 {} + && find . -type f | LC_ALL=C sort | zip -X -q "$0" -@"#
        let zipped = try await Tool.run("/bin/sh", ["-c", script, part.path], cwd: work)
        guard zipped.ok else { throw LeafError("Couldn't make the zip. \(zipped.err.prefix(200))") }
        let sha1 = try Hashing.digests(of: part).sha1
        let size = FileOps.size(part)
        if size > clientLimit { warnings.append("At \(Format.bytes(size)), this may be too large for players' games to accept.") }
        let final = out.appendingPathComponent("\(sha1).zip")
        try? FileManager.default.removeItem(at: final)
        try FileOps.move(part, to: final)
        let build = PackBuild(sha1: sha1, date: Date(), size: size, fileCount: lock.files.count, format: top, merged: merged.sorted(), warnings: warnings)
        try JSONStore.save(lock, to: lockFile(sha1: sha1, recipe: recipe.name))
        try JSONStore.save(build, to: out.appendingPathComponent("\(sha1).build.json"))
        return build
    }

    // MARK: Sharing

    /// Everything to check before sharing a combined pack.
    public static func licenseReview(_ recipe: PackRecipe) -> [(pack: LibraryPack, sharing: PackLicense.Sharing)] {
        let packs = list()
        return recipe.entries.filter(\.enabled).compactMap { entry in
            packs.first { $0.id == entry.pack }.map { pack in
                (pack, pack.license?.sharing ?? .ask("No license is on record, so check with the author."))
            }
        }
    }

    public static func exportRecipe(_ recipe: PackRecipe) throws -> Data {
        let packs = list()
        let listed = recipe.entries.compactMap { entry -> RecipeExport.Pack? in
            guard let pack = packs.first(where: { $0.id == entry.pack }), let version = pack.version(entry.version) else { return nil }
            return RecipeExport.Pack(id: pack.id, title: pack.title, source: pack.source, version: version.version, sha1: version.sha1, fileName: version.file)
        }
        return try JSONStore.compactEncoder.encode(RecipeExport(recipe: recipe, packs: listed))
    }

    /// Fetches what it can and verifies it. A pack already here by hash needs no download.
    public static func importRecipe(_ data: Data, mc: String?) async throws -> RecipeImport {
        guard let file = try? JSONStore.decoder.decode(RecipeExport.self, from: data), file.kind == "leaf-juice-pack-recipe" else {
            throw LeafError("That isn't a Leaf Juice recipe.")
        }
        guard file.formatVersion <= 1 else { throw LeafError("That recipe was made by a newer Leaf Juice.") }
        var out = RecipeImport(recipe: file.recipe)
        var idMap: [String: String] = [:]
        for wanted in file.packs {
            if let here = list().first(where: { $0.versions.contains { $0.sha1 == wanted.sha1 } }) {
                idMap[wanted.id] = here.id
                continue
            }
            do {
                guard wanted.source != .none, let found = try await exactRelease(wanted) else {
                    out.missing.append(wanted)
                    continue
                }
                let pack = try await download(wanted.source, update: found, mc: mc)
                guard pack.versions.contains(where: { $0.sha1 == wanted.sha1 }) else {
                    // It's a real pack, but not the same bytes the recipe was made from.
                    out.missing.append(wanted)
                    idMap[wanted.id] = pack.id
                    continue
                }
                idMap[wanted.id] = pack.id
                out.fetched.append(pack.title)
            } catch {
                out.missing.append(wanted)
            }
        }
        out.recipe.entries = file.recipe.entries.map { entry in
            var copy = entry
            copy.pack = idMap[entry.pack] ?? entry.pack
            return copy
        }
        out.recipe.categoryWinners = file.recipe.categoryWinners.mapValues { idMap[$0] ?? $0 }
        out.recipe.winners = file.recipe.winners.mapValues { idMap[$0] ?? $0 }
        return out
    }

    private static func exactRelease(_ wanted: RecipeExport.Pack) async throws -> PackUpdate? {
        switch wanted.source {
        case .none: return nil
        case .modrinth:
            let version = try await HTTP.decode(ModrinthVersion.self, HTTP.url("https://api.modrinth.com/v2/version_file/\(wanted.sha1)?algorithm=sha1"))
            guard let file = version.files.first(where: { $0.hashes.sha1 == wanted.sha1 }) else { return nil }
            return PackUpdate(version: version.version_number, url: file.url, sha1: wanted.sha1, fileName: file.filename)
        case .github, .url:
            guard var found = try await latest(wanted.source, mc: nil) else { return nil }
            found.sha1 = wanted.sha1
            return found
        }
    }

    // MARK: Server settings

    public struct ServerPack: Equatable, Sendable {
        public var url = ""
        public var sha1 = ""
        public var required = false
        public var isSet: Bool { !url.isEmpty }
    }

    public static func current(_ properties: String) -> ServerPack {
        let doc = PropertiesDocument(properties)
        return ServerPack(url: doc.value("resource-pack") ?? "", sha1: doc.value("resource-pack-sha1") ?? "", required: doc.value("require-resource-pack") == "true")
    }

    /// The new text of server.properties. A new pack needs a new id too, or players may keep the old one.
    public static func applying(url: String, sha1: String, required: Bool, to properties: String) throws -> String {
        guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else {
            throw LeafError("That needs to be a full web address, starting with https://, that players' games can download from.")
        }
        guard sha1.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil else { throw LeafError("That SHA-1 doesn't look right. It should be 40 characters.") }
        var doc = PropertiesDocument(properties)
        doc.set("resource-pack", url)
        doc.set("resource-pack-sha1", sha1.lowercased())
        doc.set("resource-pack-id", UUID().uuidString.lowercased())
        doc.set("require-resource-pack", required ? "true" : "false")
        return doc.text
    }
}

// MARK: - Measuring a pack against a Minecraft version

/// What a version of the game actually uses, from Mojang's own client jar. Only the list of names is kept.
public struct VanillaAssets: Codable, Equatable, Sendable {
    public var mc: String
    public var format: Int?
    public var files: [String]
    public init(mc: String, format: Int?, files: [String]) { self.mc = mc; self.format = format; self.files = files }

    static var cache: URL { AppPaths.home.appendingPathComponent("vanilla-assets", isDirectory: true) }

    private struct Manifest: Decodable { struct Version: Decodable { let id: String; let url: String }; let versions: [Version] }
    private struct Details: Decodable { struct Downloads: Decodable { struct File: Decodable { let url: String; let sha1: String }; let client: File }; let downloads: Downloads }

    public static func load(mc: String) async throws -> VanillaAssets {
        let file = cache.appendingPathComponent("\(mc).json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONStore.decoder.decode(VanillaAssets.self, from: data) { return saved }
        let manifest = try await HTTP.decode(Manifest.self, HTTP.url("https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"))
        guard let version = manifest.versions.first(where: { $0.id == mc }) else { throw LeafError("Mojang doesn't list Minecraft \(mc).") }
        let details = try await HTTP.decode(Details.self, HTTP.url(version.url))
        let work = cache.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        try FileOps.ensureDir(work)
        defer { try? FileManager.default.removeItem(at: work) }
        let jar = work.appendingPathComponent("client.jar")
        try await HTTP.download(HTTP.url(details.downloads.client.url), to: jar, expect: ExpectedHashes(sha1: details.downloads.client.sha1))
        let names = try await Tool.run("/usr/bin/unzip", ["-Z1", jar.path])
        guard names.ok else { throw LeafError("Couldn't read Minecraft \(mc)'s file list.") }
        let info = try await Tool.run("/usr/bin/unzip", ["-p", jar.path, "version.json"])
        let parsed = (try? JSONSerialization.jsonObject(with: Data(info.out.utf8))) as? [String: Any]
        let packVersion = parsed?["pack_version"] as? [String: Any]
        let format = ResourcePacks.formatNumber(packVersion?["resource_major"]) ?? ResourcePacks.formatNumber(packVersion?["resource"]) ?? ResourcePacks.formatNumber(parsed?["pack_version"])
        let assets = VanillaAssets(mc: mc, format: format, files: names.out.split(separator: "\n").map(String.init).filter { $0.hasPrefix("assets/") && !$0.hasSuffix("/") && !$0.hasPrefix("assets/.") })
        try JSONStore.save(assets, to: file)
        return assets
    }
}

/// How well a set of files fits a version: what it covers, what falls back to the game's own art, and what's ignored.
public struct PackCoverage: Equatable, Sendable {
    public struct Row: Identifiable, Equatable, Sendable {
        public var id: String { category }
        public var category: String
        public var covered: Int
        public var total: Int
        public var examplesMissing: [String]
        public var percent: Int { total == 0 ? 0 : covered * 100 / total }
    }
    public var mc: String
    public var serverFormat: Int?
    public var rows: [Row]
    /// Textures for things this version doesn't have, which the game never reads.
    public var unused: Int
    public var unusedExamples: [String]
    public var covered: Int { rows.reduce(0) { $0 + $1.covered } }
    public var total: Int { rows.reduce(0) { $0 + $1.total } }
    public var percent: Int { total == 0 ? 0 : covered * 100 / total }
}

extension ResourcePacks {
    static let measured = ["Blocks", "Items", "Entities", "Interface", "Paintings", "Sky and weather", "Particles", "Other textures"]

    /// Compares paths with what a version uses. Only textures are measured, since they're what a player sees.
    public static func coverage(of paths: [String], against vanilla: VanillaAssets) -> PackCoverage {
        func isTexture(_ path: String) -> Bool { path.hasPrefix("assets/minecraft/textures/") && path.hasSuffix(".png") }
        let wanted = vanilla.files.filter(isTexture)
        let wantedSet = Set(wanted)
        let have = Set(paths.filter(isTexture))
        var rows: [PackCoverage.Row] = []
        for name in measured {
            let inCategory = wanted.filter { category(of: $0) == name }
            guard !inCategory.isEmpty else { continue }
            let missing = inCategory.filter { !have.contains($0) }
            rows.append(.init(category: name, covered: inCategory.count - missing.count, total: inCategory.count, examplesMissing: Array(missing.prefix(6)).map { ($0 as NSString).lastPathComponent }))
        }
        let unused = have.subtracting(wantedSet).sorted()
        return PackCoverage(mc: vanilla.mc, serverFormat: vanilla.format, rows: rows, unused: unused.count, unusedExamples: Array(unused.prefix(6)))
    }

    /// The whole recipe as it would build.
    public static func coverage(_ recipe: PackRecipe, mc: String) async throws -> PackCoverage {
        async let vanilla = VanillaAssets.load(mc: mc)
        let lock = try await resolve(recipe)
        return coverage(of: lock.files.map(\.path), against: try await vanilla)
    }
}
