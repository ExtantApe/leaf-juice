import Foundation

/// The sidebar's groups, in the order people use them, with each group's pages alphabetical by title (2026-11-14).
/// Kept here, as page keys and titles, so the checks can hold the order and coverage; the app maps keys to pages.
public enum SidebarGroups {
    public struct Group: Equatable, Sendable {
        public let id: String
        public let title: String
        /// (page key, page title), alphabetical by title.
        public let pages: [(key: String, title: String)]
        public static func == (a: Group, b: Group) -> Bool { a.id == b.id && a.pages.map(\.key) == b.pages.map(\.key) }
    }

    /// Overview stays on its own at the top, outside any group.
    public static let top = (key: "overview", title: "Overview")

    public static let groups: [Group] = [
        Group(id: "server", title: "Server", pages: [("configs", "Configs"), ("console", "Console"), ("launch", "Launch"), ("software", "Software")]),
        Group(id: "content", title: "Content", pages: [("links", "Plugin Links"), ("plugins", "Plugins"), ("resourcePacks", "Resource Packs"), ("worlds", "Worlds")]),
        Group(id: "people", title: "People", pages: [("allowlist", "Allowlist"), ("players", "Players")]),
        Group(id: "upkeep", title: "Upkeep", pages: [("advisor", "Advisor"), ("backups", "Backups"), ("changes", "Changes"), ("cleanup", "Cleanup"), ("history", "History")]),
    ]

    /// Every page key, once, in sidebar order.
    public static var allKeys: [String] { [top.key] + groups.flatMap { $0.pages.map(\.key) } }

    /// What a collapsed group's heading shows: the sum of its pages' badges.
    public static func rollUp(_ group: Group, badges: [String: Int]) -> Int {
        group.pages.reduce(0) { $0 + (badges[$1.key] ?? 0) }
    }

    /// The remembered collapsed groups, as stored in one string.
    public static func decodeCollapsed(_ text: String) -> Set<String> {
        Set(text.split(separator: ",").map(String.init).filter { id in groups.contains { $0.id == id } })
    }
    public static func encodeCollapsed(_ ids: Set<String>) -> String { ids.sorted().joined(separator: ",") }
}
