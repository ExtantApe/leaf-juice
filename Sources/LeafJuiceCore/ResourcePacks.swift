import Foundation

// Resource packs are zip files of pack.mcmeta and assets. Everything here works on copies:
// the originals in the library are never changed, and nothing reaches a server until you apply it.

public struct ResourcePack: Codable, Identifiable, Equatable, Sendable {
    public var id: String { fileName }
    public var fileName: String
    public var description: String
    public var format: Int?
    public var size: Int64
    public var fileCount: Int
    public var sha1: String
}

/// A file a pack provides, relative to the pack's root.
public struct PackConflict: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var path: String
    /// Highest priority first.
    public var providers: [String]
    public var winner: String
    public var category: String
}

/// How to combine: packs in priority order, top wins, as in Minecraft's own list.
public struct PackRecipe: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var fileName: String
        public var enabled = true
        /// Categories to leave out of this pack, such as "Sounds".
        public var excluded: Set<String> = []
        public init(fileName: String) { self.fileName = fileName }
    }
    public var name = "combined"
    public var entries: [Entry] = []
    /// Picks another pack's copy of a file, by path.
    public var winners: [String: String] = [:]
    public init() {}
}

public struct CombineResult: Equatable, Sendable {
    public var file: URL
    public var sha1: String
    public var size: Int64
    public var format: Int?
    public var fileCount: Int
    public var merged: [String]
    public var warnings: [String]
}

public enum ResourcePacks {
    public static var folder: URL { AppPaths.servers.appendingPathComponent(AppPaths.ownFolderName, isDirectory: true).appendingPathComponent("resource-packs", isDirectory: true) }
    public static var library: URL { folder.appendingPathComponent("library", isDirectory: true) }
    public static var combined: URL { folder.appendingPathComponent("combined", isDirectory: true) }
    static var unpacked: URL { folder.appendingPathComponent(".unpacked", isDirectory: true) }
    static var recipeFile: URL { folder.appendingPathComponent("recipe.json") }
    /// Refuses anything that would unpack larger than this, in case of a malformed or hostile zip.
    static let unpackLimit: Int64 = 4_000_000_000
    /// Clients refuse very large packs, so it's worth saying before someone finds out the hard way.
    public static let clientLimit: Int64 = 250_000_000

    public static func loadRecipe() -> PackRecipe { JSONStore.load(recipeFile, defaults: PackRecipe()) }
    public static func saveRecipe(_ recipe: PackRecipe) { try? JSONStore.save(recipe, to: recipeFile) }

    // MARK: Reading

    /// Packs are often zipped inside a top folder, so the root is wherever pack.mcmeta is.
    static func root(of paths: [String]) -> String? {
        let candidates = paths.filter { $0 == "pack.mcmeta" || $0.hasSuffix("/pack.mcmeta") }
            .filter { !$0.hasPrefix("__MACOSX") }
            .sorted { $0.components(separatedBy: "/").count < $1.components(separatedBy: "/").count }
        guard let found = candidates.first else { return nil }
        return String(found.dropLast("pack.mcmeta".count))
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

    /// Unpacked once per pack contents, and kept for browsing.
    public static func unpack(_ zip: URL) async throws -> URL {
        let digest = try Hashing.digests(of: zip).sha1
        let target = unpacked.appendingPathComponent(digest, isDirectory: true)
        if FileOps.exists(target.appendingPathComponent(".done")) { return target }
        let sizes = try await Tool.run("/usr/bin/unzip", ["-Zt", zip.path])
        guard sizes.ok else { throw LeafError("\(zip.lastPathComponent) isn't a zip file that can be read.") }
        if let total = bytes(inSummary: sizes.out), total > unpackLimit {
            throw LeafError("\(zip.lastPathComponent) would unpack to \(Format.bytes(total)), which is more than a resource pack should be.")
        }
        try? FileManager.default.removeItem(at: target)
        try FileOps.ensureDir(target)
        let result = try await Tool.run("/usr/bin/unzip", ["-q", "-o", zip.path, "-d", target.path, "-x", "__MACOSX/*"])
        // unzip exits 1 for warnings such as odd path separators, which still unpack.
        guard result.code <= 1 else { throw LeafError("Couldn't unpack \(zip.lastPathComponent). \(result.err.prefix(200))") }
        try FileOps.writeAtomic("ok", to: target.appendingPathComponent(".done"))
        return target
    }

    static func bytes(inSummary text: String) -> Int64? {
        // "1234 files, 5678 bytes uncompressed, 910 bytes compressed:  84.0%"
        guard let r = text.range(of: #"[\d,]+ bytes uncompressed"#, options: .regularExpression) else { return nil }
        return Int64(text[r].prefix { $0.isNumber || $0 == "," }.replacingOccurrences(of: ",", with: ""))
    }

    /// Every file under a folder, as relative paths.
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

    /// Reads a pack: what it says about itself, and where its root is.
    public static func inspect(_ zip: URL) async throws -> (pack: ResourcePack, root: URL) {
        let top = try await unpack(zip)
        let files = listing(top)
        guard let prefix = root(of: files) else { throw LeafError("\(zip.lastPathComponent) has no pack.mcmeta, so it isn't a resource pack.") }
        let packRoot = prefix.isEmpty ? top : top.appendingPathComponent(prefix, isDirectory: true)
        let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: packRoot.appendingPathComponent("pack.mcmeta")))) as? [String: Any]
        let pack = meta?["pack"] as? [String: Any]
        guard pack != nil else { throw LeafError("\(zip.lastPathComponent) has a pack.mcmeta that can't be read.") }
        let format = (pack?["pack_format"] as? Int) ?? (pack?["min_format"] as? Int) ?? ((pack?["min_format"] as? [Int])?.first)
        let info = ResourcePack(
            fileName: zip.lastPathComponent, description: describe(pack?["description"]), format: format,
            size: FileOps.size(zip), fileCount: files.filter { $0.hasPrefix(prefix) }.count, sha1: try Hashing.digests(of: zip).sha1)
        return (info, packRoot)
    }

    /// A description can be text, or Minecraft's rich text.
    static func describe(_ value: Any?) -> String {
        if let text = value as? String { return text.replacingOccurrences(of: #"§."#, with: "", options: .regularExpression) }
        if let parts = value as? [Any] { return parts.map(describe).joined() }
        if let object = value as? [String: Any] { return describe(object["text"]) + describe(object["extra"]) }
        return ""
    }

    public static func list() async -> [ResourcePack] {
        var out: [ResourcePack] = []
        for file in FileOps.children(library) where file.pathExtension.lowercased() == "zip" {
            if let info = try? await inspect(file) { out.append(info.pack) }
        }
        return out.sorted { $0.fileName.lowercased() < $1.fileName.lowercased() }
    }

    /// Copies a pack into the library, once it's been shown to be one.
    public static func add(_ source: URL) async throws -> ResourcePack {
        _ = try await inspect(source)
        try FileOps.ensureDir(library)
        var target = library.appendingPathComponent(source.lastPathComponent)
        var n = 2
        while FileOps.exists(target) {
            target = library.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-\(n).zip")
            n += 1
        }
        try FileManager.default.copyItem(at: source, to: target)
        return try await inspect(target).pack
    }

    public static func remove(_ pack: ResourcePack) throws {
        try FileManager.default.removeItem(at: library.appendingPathComponent(pack.fileName))
        try? FileManager.default.removeItem(at: unpacked.appendingPathComponent(pack.sha1))
    }

    /// Image files in a pack, for looking through.
    public static func images(in pack: ResourcePack) async throws -> [(path: String, url: URL)] {
        let root = try await inspect(library.appendingPathComponent(pack.fileName)).root
        return listing(root).filter { $0.lowercased().hasSuffix(".png") && $0.hasPrefix("assets/") }.map { ($0, root.appendingPathComponent($0)) }
    }

    // MARK: Combining

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

    /// Merges JSON texts, highest priority first. Nil if any of them can't be read, so the top one is used instead.
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
                    if let replace = (value as? [String: Any])?["replace"] as? Bool, replace {
                        // The lower pack replaced vanilla, so the combination still should.
                        combined["replace"] = true
                    }
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

    private static func active(_ recipe: PackRecipe) async throws -> [(entry: PackRecipe.Entry, pack: ResourcePack, root: URL, files: [String])] {
        var out: [(entry: PackRecipe.Entry, pack: ResourcePack, root: URL, files: [String])] = []
        for entry in recipe.entries where entry.enabled {
            let info = try await inspect(library.appendingPathComponent(entry.fileName))
            let files = listing(info.root).filter { $0 != "pack.mcmeta" && $0 != "pack.png" && !entry.excluded.contains(category(of: $0)) }
            out.append((entry, info.pack, info.root, files))
        }
        return out
    }

    /// Files more than one pack provides and which can't be merged, so one has to win.
    public static func conflicts(_ recipe: PackRecipe) async throws -> [PackConflict] {
        var providers: [String: [String]] = [:]
        for item in try await active(recipe) {
            for file in item.files { providers[file, default: []].append(item.pack.fileName) }
        }
        return providers.filter { $0.value.count > 1 && mergeKind($0.key) == nil }.map { path, who in
            PackConflict(path: path, providers: who, winner: recipe.winners[path].flatMap { who.contains($0) ? $0 : nil } ?? who[0], category: category(of: path))
        }.sorted { $0.path < $1.path }
    }

    /// Builds one pack from the recipe, into `combined`. The originals aren't touched.
    public static func combine(_ recipe: PackRecipe) async throws -> CombineResult {
        let packs = try await active(recipe)
        guard !packs.isEmpty else { throw LeafError("Choose at least one pack to include.") }
        let work = folder.appendingPathComponent(".building-\(UUID().uuidString)", isDirectory: true)
        try FileOps.ensureDir(work)
        defer { try? FileManager.default.removeItem(at: work) }
        var merged: [String] = [], warnings: [String] = []
        var providers: [String: [(pack: String, url: URL)]] = [:]
        for item in packs { for file in item.files { providers[file, default: []].append((item.pack.fileName, item.root.appendingPathComponent(file))) } }

        for (path, sources) in providers {
            let target = work.appendingPathComponent(path)
            try FileOps.ensureDir(target.deletingLastPathComponent())
            if sources.count > 1, let kind = mergeKind(path) {
                let documents = sources.compactMap { try? Data(contentsOf: $0.url) }
                if let data = merge(kind, documents) {
                    try data.write(to: target)
                    merged.append(path)
                    continue
                }
                warnings.append("\(path) couldn't be read, so the top pack's copy was used.")
            }
            let chosen = sources.first { $0.pack == recipe.winners[path] } ?? sources[0]
            try FileManager.default.copyItem(at: chosen.url, to: target)
        }

        // pack.mcmeta: wide enough for everything included.
        var metas: [[String: Any]] = []
        for item in packs {
            if let object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: item.root.appendingPathComponent("pack.mcmeta")))) as? [String: Any] { metas.append(object) }
        }
        let bodies = metas.compactMap { $0["pack"] as? [String: Any] }
        func number(_ value: Any?, _ pick: ([Int]) -> Int?) -> Int? {
            if let n = value as? Int { return n }
            if let list = value as? [Int] { return pick(list) }
            return nil
        }
        let formats = bodies.compactMap { $0["pack_format"] as? Int }
        let distinct = Set(bodies.compactMap { ($0["pack_format"] as? Int) ?? number($0["min_format"], { $0.first }) })
        if distinct.count > 1 {
            warnings.append("These packs were made for different Minecraft versions (formats \(distinct.sorted().map(String.init).joined(separator: ", "))). Some files may not work on your version.")
        }
        var body: [String: Any] = ["description": "Combined by Leaf Juice: " + packs.map { ($0.pack.fileName as NSString).deletingPathExtension }.joined(separator: " + ")]
        if let top = formats.max() { body["pack_format"] = top }
        var low: [Int] = [], high: [Int] = []
        for b in bodies {
            if let n = b["pack_format"] as? Int { low.append(n); high.append(n) }
            if let s = b["supported_formats"] as? [Int], s.count == 2 { low.append(s[0]); high.append(s[1]) }
            if let s = b["supported_formats"] as? [String: Int], let a = s["min_inclusive"], let z = s["max_inclusive"] { low.append(a); high.append(z) }
            if let a = number(b["min_format"], { $0.first }) { low.append(a) }
            if let z = number(b["max_format"], { $0.first }) { high.append(z) }
        }
        let newStyle = bodies.contains { $0["min_format"] != nil }
        if let a = low.min(), let z = high.max() {
            if newStyle { body["min_format"] = a; body["max_format"] = z }
            if !formats.isEmpty, a != z { body["supported_formats"] = [a, z] }
        }
        var meta: [String: Any] = ["pack": body]
        let overlays = metas.compactMap { ($0["overlays"] as? [String: Any])?["entries"] as? [Any] }.flatMap { $0 }
        if !overlays.isEmpty { meta["overlays"] = ["entries": overlays] }
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]).write(to: work.appendingPathComponent("pack.mcmeta"))
        if let icon = packs.map({ $0.root.appendingPathComponent("pack.png") }).first(where: FileOps.exists) {
            try FileManager.default.copyItem(at: icon, to: work.appendingPathComponent("pack.png"))
        }

        try FileOps.ensureDir(combined)
        let clean = recipe.name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
        let output = combined.appendingPathComponent("\(clean.isEmpty ? "combined" : clean).zip")
        let part = combined.appendingPathComponent(".\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: part) }
        let zipped = try await Tool.run("/usr/bin/zip", ["-q", "-X", "-r", part.path, "."], cwd: work)
        guard zipped.ok else { throw LeafError("Couldn't make the zip. \(zipped.err.prefix(200))") }
        try FileOps.move(part, to: output)
        let size = FileOps.size(output)
        if size > clientLimit { warnings.append("At \(Format.bytes(size)), this may be too large for players' games to accept.") }
        return CombineResult(file: output, sha1: try Hashing.digests(of: output).sha1, size: size, format: formats.max(), fileCount: listing(work).count, merged: merged.sorted(), warnings: warnings)
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
