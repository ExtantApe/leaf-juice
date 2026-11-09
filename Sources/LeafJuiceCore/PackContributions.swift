import Foundation

/// What one pack adds to a recipe, counted from the same lock file a build uses, so it can't disagree with the build.
public struct PackContribution: Identifiable, Equatable, Sendable {
    public var id: String { pack }
    public var pack: String
    public var title: String
    /// Files this pack supplies to the build, including those nobody else has.
    public var wins = 0
    /// Of those, the ones only this pack has.
    public var only = 0
    /// Files where another pack's different copy is used instead.
    public var loses = 0
    /// Files where the winner's copy is byte for byte the same, so it makes no difference.
    public var same = 0
    /// Files combined from several packs, this one included.
    public var merged = 0
    public var winsByCategory: [String: Int] = [:]
    public var images = 0

    public init(pack: String, title: String) {
        self.pack = pack
        self.title = title
    }
}

public enum PackFileRole: Equatable, Sendable { case wins, only, loses, same, merged }

public enum PackFileFilter: String, CaseIterable, Identifiable, Sendable {
    case all, wins, loses, only
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: "All files"
        case .wins: "Used in the build"
        case .loses: "Replaced by another pack"
        case .only: "Only in one pack"
        }
    }
}

/// Finds the real file behind a copy, so two copies can be looked at side by side.
public struct PackFileLocator: Sendable {
    var places: [String: (root: URL, renamed: [String: String])] = [:]

    public func url(path: String, pack: String) -> URL? {
        guard let place = places[pack] else { return nil }
        return place.root.appendingPathComponent(place.renamed[path] ?? path)
    }
}

extension LockedFile {
    /// nil when this pack has no copy.
    public func role(of pack: String) -> PackFileRole? {
        guard let copy = copies.first(where: { $0.pack == pack }) else { return nil }
        if reason == .merged { return .merged }
        if winner == pack { return copies.count == 1 ? .only : .wins }
        return copy.sha1 == sha1 ? .same : .loses
    }

    /// Whether choosing another pack here would change anything.
    public var canChoose: Bool { reason != .merged && reason != .mine && Set(copies.map(\.sha1)).count > 1 }

    public var isImage: Bool { path.lowercased().hasSuffix(".png") }

    public var reasonText: String {
        switch reason {
        case .only: "Only this pack has it"
        case .rank: "Highest in the ranking"
        case .category: "Chosen for this kind of file"
        case .picked: "You chose it for this file"
        case .merged: "Combined from these packs"
        case .mine: "Your own change"
        }
    }
}

extension ResourcePacks {
    /// In the order given, which is the ranking, so the list reads the same as the recipe.
    public static func contributions(_ lock: PackLock, order: [(id: String, title: String)]) -> [PackContribution] {
        var counts = order.map { PackContribution(pack: $0.id, title: $0.title) }
        var position: [String: Int] = [:]
        for (index, item) in counts.enumerated() { position[item.pack] = index }
        for file in lock.files {
            for copy in file.copies {
                guard let index = position[copy.pack] else {
                    // "My changes" isn't in the recipe's own list, but it does contribute.
                    position[copy.pack] = counts.count
                    counts.append(PackContribution(pack: copy.pack, title: copy.pack == mineID ? "My changes" : copy.pack))
                    tally(file, copy.pack, &counts[counts.count - 1])
                    continue
                }
                tally(file, copy.pack, &counts[index])
            }
        }
        return counts
    }

    private static func tally(_ file: LockedFile, _ pack: String, _ count: inout PackContribution) {
        guard let role = file.role(of: pack) else { return }
        switch role {
        case .wins, .only:
            count.wins += 1
            if role == .only { count.only += 1 }
            count.winsByCategory[category(of: file.path), default: 0] += 1
            if file.isImage { count.images += 1 }
        case .loses: count.loses += 1
        case .same: count.same += 1
        case .merged: count.merged += 1
        }
    }

    /// `pack` nil means across every pack: "replaced" is then any file whose copies differ.
    public static func files(_ lock: PackLock, pack: String? = nil, show: PackFileFilter = .all, category wanted: String? = nil, search: String = "", imagesOnly: Bool = false) -> [LockedFile] {
        lock.files.filter { file in
            if imagesOnly, !file.isImage { return false }
            if let wanted, category(of: file.path) != wanted { return false }
            if !search.isEmpty, !file.path.localizedCaseInsensitiveContains(search) { return false }
            if let pack {
                guard let role = file.role(of: pack) else { return false }
                switch show {
                case .all: return true
                case .wins: return role == .wins || role == .only || role == .merged
                case .loses: return role == .loses
                case .only: return role == .only
                }
            }
            switch show {
            case .all, .wins: return true
            case .loses: return file.canChoose
            case .only: return file.copies.count == 1
            }
        }
    }

    public static func locator(_ recipe: PackRecipe) async throws -> PackFileLocator {
        var out = PackFileLocator()
        for source in try await sources(recipe) { out.places[source.id] = (source.root, source.renamed) }
        return out
    }
}
