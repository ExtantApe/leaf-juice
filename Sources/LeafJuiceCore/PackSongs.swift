import Foundation

// Songs a pack lists in songs.json at its top, so a server can leave any one out and hear Minecraft's own track in
// its place. Each song is a set of plain files at vanilla paths, so leaving it out is just not copying them.

public struct PackSong: Codable, Equatable, Identifiable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public var path: String
        /// The vanilla sound it stands in for, such as music/game/calm1.
        public var replaces: String
        public var bytes: Int64?
        public init(path: String, replaces: String, bytes: Int64? = nil) {
            self.path = path
            self.replaces = replaces
            self.bytes = bytes
        }
    }
    /// Never changes once released, because each server's choice is saved by it.
    public var id: String
    public var title: String
    public var credit: String?
    public var files: [File]
    public init(id: String, title: String, credit: String? = nil, files: [File]) {
        self.id = id
        self.title = title
        self.credit = credit
        self.files = files
    }
    /// The short names of the vanilla tracks, for showing which ones it stands in for.
    public var standsInFor: [String] { files.map { $0.replaces.split(separator: "/").last.map(String.init) ?? $0.replaces } }
}

/// What a pack's songs.json says, after checking it against the files the pack really has.
public struct PackSongList: Equatable, Sendable {
    /// Empty when there's a problem, so nothing is left out on a guess.
    public var songs: [PackSong] = []
    /// Why the songs can't be switched off one by one.
    public var problems: [String] = []
    /// Worth knowing, but the songs still work.
    public var notes: [String] = []
    /// Each song's real size in the pack.
    public var sizes: [String: Int64] = [:]
    public var usable: Bool { problems.isEmpty && !songs.isEmpty }
    public init() {}

    /// The files to leave out for these songs. Nothing if the list can't be trusted.
    public func files(off: Set<String>) -> Set<String> {
        guard usable else { return [] }
        return Set(songs.filter { off.contains($0.id) }.flatMap { $0.files.map(\.path) })
    }
}

extension ResourcePacks {
    public static let songListName = "songs.json"

    private struct SongFile: Codable {
        var format: Int
        var songs: [PackSong]
    }

    /// nil when the pack has no song list.
    public static func songList(root: URL) -> PackSongList? {
        let url = root.appendingPathComponent(songListName)
        guard FileOps.exists(url) else { return nil }
        var out = PackSongList()
        guard let data = try? Data(contentsOf: url), let parsed = try? JSONDecoder().decode(SongFile.self, from: data) else {
            out.problems.append("Its songs.json couldn't be read, so its songs can't be switched off one by one.")
            return out
        }
        guard parsed.format == 1 else {
            out.problems.append("Its songs.json is format \(parsed.format), which this version of Leaf Juice doesn't know. Look for a Leaf Juice update.")
            return out
        }
        let idShape = try! NSRegularExpression(pattern: "^[a-z0-9]+(-[a-z0-9]+)*$")
        var ids = Set<String>(), owner: [String: String] = [:]
        for song in parsed.songs {
            let range = NSRange(song.id.startIndex..., in: song.id)
            if idShape.firstMatch(in: song.id, range: range) == nil { out.problems.append("“\(song.id)” isn't a usable song id. Ids are lowercase letters, digits and hyphens.") }
            if !ids.insert(song.id).inserted { out.problems.append("Two songs share the id “\(song.id)”.") }
            if song.files.isEmpty { out.problems.append("“\(song.title)” lists no files.") }
            var size: Int64 = 0
            for file in song.files {
                let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
                guard file.path.hasPrefix("assets/"), !parts.contains(".."), !parts.contains("") else {
                    out.problems.append("“\(song.title)” lists \(file.path), which isn't a path inside assets/.")
                    continue
                }
                if let other = owner[file.path] { out.problems.append("\(file.path) is claimed by both “\(other)” and “\(song.title)”.") }
                owner[file.path] = song.title
                let on = root.appendingPathComponent(file.path)
                guard FileOps.exists(on) else {
                    out.problems.append("“\(song.title)” lists \(file.path), but the pack doesn't have it.")
                    continue
                }
                let actual = FileOps.size(on)
                size += actual
                if let said = file.bytes, said != actual { out.notes.append("songs.json gives \(file.path) as \(said) bytes, but it's \(actual).") }
            }
            out.sizes[song.id] = size
        }
        if out.problems.isEmpty { out.songs = parsed.songs } else { out.sizes = [:] }
        return out
    }

    /// The song list of the version a recipe entry uses.
    public static func songList(for entry: PackRecipe.Entry) async -> PackSongList? {
        guard let pack = list().first(where: { $0.id == entry.pack }),
              let version = pack.versions.first(where: { $0.sha1 == entry.version }) ?? pack.latest,
              let root = try? await read(zip(pack, version), version: version.version).root else { return nil }
        return songList(root: root)
    }

    /// Credits for the songs a build includes, since they may come from someone other than the pack's author.
    static func songCredits(_ sources: [Source]) -> String {
        var lines: [String] = []
        for source in sources {
            let included = source.songs?.songs.filter { song in song.files.contains { source.files.contains($0.path) } } ?? []
            guard !included.isEmpty else { continue }
            lines.append("Songs in \(source.title)")
            for song in included { lines.append("  \(song.title)" + (song.credit.map { ": \($0)" } ?? "")) }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
