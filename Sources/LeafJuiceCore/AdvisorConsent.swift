import Foundation

/// The Advisor's yeses. Each one starts as no, and a check sends only when all of them are there:
/// the Advisor turned on in Settings, this server shared, and for checks nobody pressed a button for, automatic checks on.
/// A yes belongs to one server in one folder, so moving it, or putting a different server there, needs a new one.
public struct AdvisorConsent {
    public static let sharedList = "advisorShared"
    public static let automaticList = "advisorAutomatic"

    let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public static func key(id: UUID, folder: URL) -> String { "\(id.uuidString)|\(folder.path)" }

    public func list(_ name: String) -> Set<String> { Set(defaults.stringArray(forKey: name) ?? []) }

    public func set(_ name: String, _ key: String, _ on: Bool) {
        var current = list(name)
        if on { current.insert(key) } else { current.remove(key) }
        defaults.set(Array(current), forKey: name)
    }

    public func isShared(id: UUID, folder: URL) -> Bool { list(Self.sharedList).contains(Self.key(id: id, folder: folder)) }
    public func isAutomatic(id: UUID, folder: URL) -> Bool { list(Self.automaticList).contains(Self.key(id: id, folder: folder)) }

    /// When this server in this folder was last checked. Kept per server, so a different server in the same folder
    /// gets the first-check question again.
    public func lastCheck(id: UUID, folder: URL) -> Date? { defaults.object(forKey: "advisorLast:" + Self.key(id: id, folder: folder)) as? Date }
    public func recordCheck(id: UUID, folder: URL, at date: Date = Date()) { defaults.set(date, forKey: "advisorLast:" + Self.key(id: id, folder: folder)) }
    public func forgetCheck(id: UUID, folder: URL) { defaults.removeObject(forKey: "advisorLast:" + Self.key(id: id, folder: folder)) }

    /// Why a check may not send anything, or nil when every yes is there. Every check asks this first.
    @MainActor public func refusal(id: UUID, folder: URL, name: String, automatic: Bool, modules: Modules? = nil) -> String? {
        let modules = modules ?? .shared
        let shown = (folder.path as NSString).abbreviatingWithTildeInPath
        if !modules.isOn(.advisor) { return "The Advisor is turned off, so nothing was sent." }
        if !isShared(id: id, folder: folder) { return "This server isn't shared, so nothing was sent." }
        if automatic, !isAutomatic(id: id, folder: folder) { return "Automatic checks are off for this server, so nothing was sent." }
        // The first send is always one the person confirmed by pressing Check Now.
        if automatic, lastCheck(id: id, folder: folder) == nil { return "Automatic checks start after you've sent the first check yourself, so nothing was sent." }
        if !FileManager.default.fileExists(atPath: folder.path) { return "\(name) isn't in \(shown) any more, so nothing was sent." }
        return nil
    }
}
