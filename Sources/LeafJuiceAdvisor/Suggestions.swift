import Darwin
import Foundation

/// Advice left for a person. Plain text only: there's deliberately no field for a command or anything to run.
public struct Suggestion: Codable, Equatable, Sendable {
    public enum Severity: String, Codable, CaseIterable, Sendable { case info, warning, important }
    public var id: String
    public var created: Date
    public var server: String
    public var severity: Severity
    public var title: String
    public var details: String
}

public final class SuggestionInbox {
    public static let maxPending = 200
    public static let maxTitle = 120
    public static let maxDetails = 4000
    private let folder: URL
    private let sanitizer: Sanitizer?

    public init(home: URL = AdvisorPaths.home, sanitizer: Sanitizer?) throws {
        try PrivateFiles.ensureDirectory(home)
        folder = home.appendingPathComponent("suggestions", isDirectory: true)
        try PrivateFiles.ensureDirectory(folder)
        // A folder that can't be listed would look like an empty inbox.
        guard access(folder.path, R_OK | W_OK | X_OK) == 0 else { throw AdvisorError("The suggestion inbox can't be read.") }
        self.sanitizer = sanitizer
    }

    private var files: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// What the AI writes is untrusted, because a trick could have reached it. It's cleaned like anything else.
    public func add(server: String, severity: Suggestion.Severity, title: String, details: String, using other: Sanitizer? = nil) throws -> Suggestion {
        // Measured in bytes and before any processing: a character can be millions of combining marks.
        guard title.utf8.count <= Self.maxTitle * 4, details.utf8.count <= Self.maxDetails * 4 else { throw AdvisorError("That suggestion is too long.") }
        guard let sanitizer = other ?? sanitizer else { throw AdvisorError("This inbox can't accept suggestions.") }
        guard files.count < Self.maxPending else { throw AdvisorError("The suggestion inbox is full. A person needs to review it first.") }
        let oneLine = title.components(separatedBy: .newlines).joined(separator: " ")
        let cleanTitle = try sanitizer.clean(oneLine, limit: Self.maxTitle)
        let cleanDetails = try sanitizer.clean(details, limit: Self.maxDetails)
        guard !cleanTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AdvisorError("A suggestion needs a title.") }
        let now = Date()
        let id = UUID().uuidString.lowercased()
        let suggestion = Suggestion(id: id, created: now, server: server, severity: severity, title: cleanTitle, details: cleanDetails)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // The time first, so names sort oldest to newest.
        let name = "\(Int(now.timeIntervalSince1970))-\(id).json"
        try PrivateFiles.write(try encoder.encode(suggestion), to: folder.appendingPathComponent(name))
        return suggestion
    }

    /// One bad file doesn't hide the rest. It's counted so a person knows it's there.
    public func all() -> (suggestions: [Suggestion], unreadable: Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [Suggestion] = [], unreadable = 0
        for file in files {
            if let data = try? PrivateFiles.read(file), let suggestion = try? decoder.decode(Suggestion.self, from: data) {
                out.append(suggestion)
            } else {
                unreadable += 1
            }
        }
        return (out, unreadable)
    }

    public func clear() { files.forEach { try? FileManager.default.removeItem(at: $0) } }

    /// For a person to read, with real names back in. Each one is framed as the AI's words, and its body is marked line
    /// by line so it can't forge a second entry. Cleaned afterwards too, because a stored file could have been edited.
    public static func render(_ suggestion: Suggestion, key: PrivacyKey) throws -> String {
        func show(_ text: String) throws -> String { Scrub.controls(try key.reveal(Scrub.controls(text))) }
        let server = try show(suggestion.server).components(separatedBy: .newlines).joined(separator: " ")
        let title = try show(suggestion.title).components(separatedBy: .newlines).joined(separator: " ")
        let body = try show(suggestion.details).components(separatedBy: .newlines).map { "  | \($0)" }.joined(separator: "\n")
        return "AI suggestion, \(suggestion.severity.rawValue), for \(server): \(title)\n\(body)\n"
    }
}
