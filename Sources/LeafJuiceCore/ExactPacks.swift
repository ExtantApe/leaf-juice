import Foundation

// A pack served exactly as it was given, such as one a plugin builds and checks by its own SHA-1. Nothing is
// unzipped, rebuilt or added, so what's served has the same SHA-1 as the file that was chosen.

extension ResourcePacks {
    static let exactMarker = "exact.json"

    /// Names of exact packs, kept beside recipe builds but never built from a recipe.
    public static func exactNames() -> [String] {
        FileOps.children(builds).filter { FileOps.exists($0.appendingPathComponent(exactMarker)) }.map(\.lastPathComponent).sorted()
    }

    public static func isExact(_ name: String) -> Bool {
        FileOps.exists(builds.appendingPathComponent(slug(name), isDirectory: true).appendingPathComponent(exactMarker))
    }

    /// Stores a copy, unchanged, under its own SHA-1. Adding the same file again changes nothing.
    @discardableResult
    public static func addExact(_ file: URL, name: String) async throws -> PackBuild {
        let key = slug(name)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LeafError("Give it a name.") }
        guard !recipeNames().contains(key) else { throw LeafError("A recipe already has that name. Choose another.") }
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw LeafError("That file can't be read.") }
        let magic = try handle.read(upToCount: 4) ?? Data()
        try? handle.close()
        guard magic == Data([0x50, 0x4B, 0x03, 0x04]) else { throw LeafError("That isn't a zip file.") }
        let out = builds.appendingPathComponent(key, isDirectory: true)
        try FileOps.ensureDir(out)
        // Hashed after copying, so the SHA-1 is of the bytes that will be served.
        let part = out.appendingPathComponent(".\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: part) }
        try FileManager.default.copyItem(at: file, to: part)
        let sha1 = try Hashing.digests(of: part).sha1.lowercased()
        let size = FileOps.size(part)
        let final = out.appendingPathComponent("\(sha1).zip")
        if !FileOps.exists(final) { try FileOps.move(part, to: final) }
        var warnings: [String] = []
        let listing = try? await Tool.run("/usr/bin/unzip", ["-Z1", final.path])
        if listing?.ok != true { warnings.append("The zip couldn't be listed, so games may not be able to open it. It's served unchanged anyway.") }
        else if !(listing?.out.components(separatedBy: .newlines).contains("pack.mcmeta") ?? false) {
            warnings.append("There's no pack.mcmeta at the top, so games may not load it as a pack. It's served unchanged anyway.")
        }
        if size > clientLimit { warnings.append("At \(Format.bytes(size)), this may be too large for players' games to accept.") }
        let record = out.appendingPathComponent("\(sha1).build.json")
        if let existing = (try? Data(contentsOf: record)).flatMap({ try? JSONStore.decoder.decode(PackBuild.self, from: $0) }) { return existing }
        let build = PackBuild(sha1: sha1, date: Date(), size: size, fileCount: 0, format: nil, merged: [], warnings: warnings)
        try JSONStore.save(build, to: record)
        try JSONStore.save(["name": name, "kind": "exact"], to: out.appendingPathComponent(exactMarker))
        return build
    }
}

extension PackHosting {
    /// For a plugin that fills in the hash itself, such as one whose setting takes `{sha1}`.
    public static let sha1Placeholder = "{sha1}"
}

extension ServerController {
    /// The per-build address with the hash left as `{sha1}`, for a plugin that fills it in. nil if hosted elsewhere.
    public func packAddressTemplate(recipe name: String) -> String? {
        packBuildAddress(recipe: name, sha1: PackHosting.sha1Placeholder)
    }
}
