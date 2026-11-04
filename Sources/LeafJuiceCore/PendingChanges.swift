import Foundation

/// A change waiting for the server to stop. Files wait in `.leafjuice/staged`, never in the live folder.
public struct PendingChange: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case config(path: String)
        case software(stagedFile: String, build: SoftwareBuild, needsBackup: Bool)
        case pluginInstall(name: String, stagedFile: String, finalName: String, replaces: String?, upstreamID: String?)
        case pluginRemove(fileName: String)
        case pluginToggle(fileName: String, enable: Bool)
    }
    public var id = UUID()
    public var kind: Kind
    public var summary: String
    public var created = Date()
    /// Why this change was held back, if it was.
    public var conflict: String?

    public init(kind: Kind, summary: String) { self.kind = kind; self.summary = summary }

    /// Only one change per target at a time: a newer edit replaces an older one.
    public var target: String {
        switch kind {
        case let .config(path): "config:\(path)"
        case .software: "software"
        case let .pluginInstall(name, _, _, _, _): "plugin:\(name.lowercased())"
        case let .pluginRemove(file): "file:\(file)"
        case let .pluginToggle(file, _): "file:\(file)"
        }
    }

    public var needsBackup: Bool {
        switch kind {
        case let .software(_, _, needsBackup): needsBackup
        case .pluginInstall, .pluginRemove: true
        default: false
        }
    }
}

/// A version change waiting for your verdict, and the verified restore point that can undo it.
public struct UpgradeRecord: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var from: SoftwareState
    public var toLabel: String
    public var toFileName: String
    public var backupFile: String
    /// Stored in full: the backup folder setting may change before this is needed.
    public var backupFolder: String
    public var worlds: [String]
    public var size: Int64
}

/// The server as it stood after an upgrade you rolled back. Not a backup: it's kept apart,
/// retention never touches it, and it stays until you resume or delete it.
public struct ShelvedUpgrade: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var label: String
    public var software: SoftwareState
    public var fromLabel: String
    public var fileName: String
    public var size: Int64
}

/// Staged config files. `<path>` holds the edit and `<path>.base` what the file held when editing began.
public struct ConfigStage {
    let paths: ServerPaths
    public init(paths: ServerPaths) { self.paths = paths }

    private func stagedURL(_ rel: String) -> URL { paths.staged.appendingPathComponent("config/\(rel)") }
    private func baseURL(_ rel: String) -> URL { paths.staged.appendingPathComponent("config/\(rel).base") }

    public func stagedText(_ rel: String) -> String? { try? String(contentsOf: stagedURL(rel), encoding: .utf8) }

    public func stage(_ rel: String, text: String) throws {
        let live = (try? String(contentsOf: paths.root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
        // Keep the first base, so repeated edits merge against what the file held originally.
        if !FileOps.exists(baseURL(rel)) { try FileOps.writeAtomic(live, to: baseURL(rel)) }
        try FileOps.writeAtomic(text, to: stagedURL(rel))
    }

    public func discard(_ rel: String) {
        try? FileManager.default.removeItem(at: stagedURL(rel))
        try? FileManager.default.removeItem(at: baseURL(rel))
    }

    /// Writes a staged edit to the live file. Returns a conflict message if it was held back.
    public func apply(_ rel: String, format: ConfigFile.Format, history: (String, String) -> Void) throws -> String? {
        guard let mine = stagedText(rel) else { return nil }
        let liveURL = paths.root.appendingPathComponent(rel)
        let live = (try? String(contentsOf: liveURL, encoding: .utf8)) ?? ""
        let base = (try? String(contentsOf: baseURL(rel), encoding: .utf8)) ?? live
        var final = mine
        if live != base {
            guard format == .properties else {
                return "\(rel) changed on disk after you edited it, so your edit was kept aside. Open it to compare and save again."
            }
            final = PropertiesDocument.merge(base: base, mine: mine, theirs: live)
        }
        if !live.isEmpty { history(rel, live) }
        try FileOps.writeAtomic(final, to: liveURL)
        discard(rel)
        return nil
    }
}

public enum ConfigHistory {
    /// Keeps the last few versions of an edited file.
    public static func record(_ rel: String, text: String, paths: ServerPaths, keep: Int = 5) {
        let name = rel.replacingOccurrences(of: "/", with: "__")
        let dir = paths.configHistory
        let stamp = Int(Date().timeIntervalSince1970)
        try? FileOps.writeAtomic(text, to: dir.appendingPathComponent("\(name).\(stamp)"))
        let copies = FileOps.children(dir).filter { $0.lastPathComponent.hasPrefix(name + ".") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in copies.dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
    }
}
