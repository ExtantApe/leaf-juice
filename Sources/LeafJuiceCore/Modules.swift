import Foundation
import Observation

/// Major features that can be switched off. All compiled in and all on by default: there's no third-party code here.
/// Off hides a feature and stops its background work. Its data stays where it is.
public enum LeafModule: String, CaseIterable, Identifiable, Sendable {
    case worlds, players, history, cleanup, testCopies, backupDrill, lab, resourcePacks, links, advisor, pluginCommands

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .worlds: "Worlds and Multiverse"
        case .players: "Players"
        case .history: "History"
        case .cleanup: "Cleanup"
        case .testCopies: "Test copies"
        case .backupDrill: "Backup drills"
        case .lab: "Lab"
        case .resourcePacks: "Resource packs"
        case .links: "Plugin links"
        case .advisor: "Advisor"
        case .pluginCommands: "Plugin commands"
        }
    }
    /// The Advisor sends data to an outside service, and plugin commands wait for plugins that speak the
    /// shared format, so unlike everything else these stay off until you turn them on.
    public var startsOff: Bool { self == .advisor || self == .pluginCommands }
    public var summary: String {
        switch self {
        case .worlds: "Create, rename and manage worlds, with Multiverse built in."
        case .players: "Inventory snapshots, restores, merging names, stats and leaderboards."
        case .history: "Charts of performance and size over time, and the timeline."
        case .cleanup: "Find leftover folders and old files, with undo."
        case .testCopies: "Try a change on a throwaway copy of a server first."
        case .backupDrill: "Prove a backup restores by booting it somewhere safe."
        case .lab: "A practice server with bot players, the status board and upgrade rehearsals."
        case .resourcePacks: "Look through resource packs, and combine them into one."
        case .links: "Each plugin, its version and a link to its documentation."
        case .advisor: "Optional AI suggestions, using your own Claude account. Off until you turn it on, and shares nothing until you choose a server."
        case .pluginCommands: "Lets Leaf Juice talk to plugins through the shared command format, on servers it started. A preview: off until plugins support it."
        }
    }
    public var icon: String {
        switch self {
        case .worlds: "globe.americas"
        case .players: "person.2"
        case .history: "chart.xyaxis.line"
        case .cleanup: "sparkles"
        case .testCopies: "doc.on.doc"
        case .backupDrill: "checkmark.shield"
        case .lab: "flask"
        case .resourcePacks: "photo.stack"
        case .links: "link"
        case .advisor: "sparkle.magnifyingglass"
        case .pluginCommands: "terminal"
        }
    }
}

@MainActor @Observable
public final class Modules {
    public static let shared = Modules()
    /// Stored as what's off, so a module added later starts on.
    public private(set) var off: Set<String>
    private var file: URL { AppPaths.home.appendingPathComponent("modules.json") }

    init() { off = JSONStore.load(AppPaths.home.appendingPathComponent("modules.json"), defaults: []) }

    public func isOn(_ module: LeafModule) -> Bool {
        // The trial shares this file with the real app, so it doesn't save its own choice here.
        if module == .advisor, AdvisorTrial.isOn { return true }
        return module.startsOff ? off.contains("on:\(module.rawValue)") : !off.contains(module.rawValue)
    }

    public func set(_ module: LeafModule, on: Bool) {
        if module.startsOff {
            if on { off.insert("on:\(module.rawValue)") } else { off.remove("on:\(module.rawValue)") }
        } else if on {
            off.remove(module.rawValue)
        } else {
            off.insert(module.rawValue)
        }
        try? JSONStore.save(off, to: file)
    }

    /// Reads the file again. Tests move where it lives.
    func reload() { off = JSONStore.load(file, defaults: []) }
}
