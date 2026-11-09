import Foundation

/// Everything a check would share, laid out for a person. Whatever the tools return appears here, with nothing shortened,
/// as this is what the owner judges before saying yes. A test compares the two.
public enum SharedPreview {
    public static func text(serverToken: String, summary: [String: Any], issues: [[String: Any]], report: ProblemLog.Report, dismissed: [String] = []) -> String {
        var out = "THIS SERVER'S CODE NAME\n  \(serverToken)\n\nTHE SERVER\n"
        out += lines(summary, indent: "  ").joined(separator: "\n")
        out += "\n\nPROBLEMS LEAF JUICE HAS NOTICED\n"
        out += issues.isEmpty ? "  None" : issues.map { lines($0, indent: "  ").joined(separator: "\n") }.joined(separator: "\n\n")
        out += "\n\nFROM THE LOG\n" + (report.events.isEmpty ? "  Nothing recognised" : report.events.joined(separator: "\n"))
        out += "\n\nLOG MESSAGES KEPT BACK, AND NEVER SHARED: \(report.withheld)\n"
        let titles = dismissed.compactMap(SuggestionInbox.promptTitle)
        if !titles.isEmpty { out += "\nSUGGESTIONS YOU DISMISSED, SENT SO THEY AREN'T RAISED AGAIN\n" + titles.map { "  \($0)" }.joined(separator: "\n") + "\n" }
        out += "\nCLAUDE CODE ALSO SENDS, BY ITSELF\n  Your Claude account's email, a temporary folder's path, and your Mac's system version.\n"
        return out
    }

    private static func lines(_ value: [String: Any], indent: String) -> [String] {
        value.keys.sorted().flatMap { key -> [String] in
            switch value[key] {
            case let nested as [String: Any]: return ["\(indent)\(key):"] + lines(nested, indent: indent + "  ")
            case let list as [Any]: return ["\(indent)\(key):"] + list.map { "\(indent)  \($0)" }
            case let other?: return ["\(indent)\(key): \(other)"]
            case nil: return []
            }
        }
    }
}
