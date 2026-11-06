import AppKit
import Foundation
import LeafJuiceAdvisor
import LeafJuiceCore
import Observation
import SwiftUI

/// Runs checks for the optional Advisor. The AI only ever talks to `leafjuice-mcp`, a separate read-only program, and is
/// started with every other tool removed. See docs/ADVISOR-SECURITY.md. Nothing here can change a server.
@MainActor @Observable
final class AdvisorCenter {
    static let shared = AdvisorCenter()

    enum Phase: Equatable { case idle, checking, failed(String) }
    struct Item: Identifiable, Equatable {
        let id: String
        let severity: Suggestion.Severity
        let title: String
        let details: String
        let rawTitle: String
    }

    private(set) var phases: [String: Phase] = [:]
    private(set) var items: [String: [Item]] = [:]
    private(set) var previews: [String: String] = [:]
    private(set) var claudePath: String?
    private var running: [String: Process] = [:]
    private var watching = false
    private let defaults = UserDefaults.standard

    private init() { findClaude() }

    // MARK: Choices, which all default to off

    private func set(_ key: String) -> Set<String> { Set(defaults.stringArray(forKey: key) ?? []) }
    private func write(_ value: Bool, _ path: String, _ key: String) {
        var current = set(key)
        if value { current.insert(path) } else { current.remove(path) }
        defaults.set(Array(current), forKey: key)
    }
    func isShared(_ server: ServerController) -> Bool { set("advisorShared").contains(server.paths.root.path) }
    func share(_ server: ServerController, _ on: Bool) {
        write(on, server.paths.root.path, "advisorShared")
        if !on { write(false, server.paths.root.path, "advisorAutomatic") }
        refresh(server)
    }
    func isAutomatic(_ server: ServerController) -> Bool { set("advisorAutomatic").contains(server.paths.root.path) }
    func setAutomatic(_ server: ServerController, _ on: Bool) { write(on, server.paths.root.path, "advisorAutomatic") }
    func lastCheck(_ server: ServerController) -> Date? { defaults.object(forKey: "advisorLast:\(server.paths.root.path)") as? Date }
    private func signature(_ server: ServerController) -> String {
        server.issues.filter { $0.status == .open && $0.severity >= .warning }.map(\.id).sorted().joined(separator: "|")
    }

    // MARK: Finding the AI client

    /// A Mac app doesn't get your shell's PATH, so the usual places are checked directly.
    func findClaude() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        claudePath = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Beside this app's own program, whether it's in an app bundle or a build folder.
    private var advisorProgram: String? {
        guard let own = Bundle.main.executableURL else { return nil }
        let path = own.deletingLastPathComponent().appendingPathComponent("leafjuice-mcp").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    // MARK: Reading

    func refresh(_ server: ServerController) {
        let path = server.paths.root.path
        do {
            let key = try PrivacyKey()
            let inbox = try SuggestionInbox(sanitizer: nil)
            let token = try key.server(path: path, display: server.profile.name)
            items[path] = try inbox.all().suggestions.filter { $0.server == token }.map { suggestion in
                let readable = try SuggestionInbox.readable(suggestion, key: key)
                return Item(id: suggestion.id, severity: suggestion.severity, title: readable.title, details: readable.details, rawTitle: suggestion.title)
            }.sorted { $0.severity.rank > $1.severity.rank }
        } catch {
            items[path] = []
            phases[path] = .failed((error as? AdvisorError)?.description ?? "The Advisor's private folder couldn't be read.")
        }
    }

    func count(_ server: ServerController) -> Int { items[server.paths.root.path]?.count ?? 0 }

    func phase(_ server: ServerController) -> Phase { phases[server.paths.root.path] ?? .idle }

    func dismiss(_ item: Item, server: ServerController, forGood: Bool) {
        guard let inbox = try? SuggestionInbox(sanitizer: nil) else { return }
        inbox.remove(id: item.id)
        if forGood { inbox.neverRaiseAgain(item.rawTitle, server: server.paths.root.path) }
        refresh(server)
    }

    /// Runs here, and sends nothing: this is the same text a check would give the AI.
    func loadPreview(_ server: ServerController) async {
        let root = server.paths.root
        let text = await Task.detached(priority: .userInitiated) { () -> String in
            do {
                let reader = ServerReader(root: root, sanitizer: Sanitizer(key: try PrivacyKey()))
                let report = try reader.recentProblems(limit: 500)
                let all: [String: Any] = ["summary": try reader.summary(), "openIssues": try reader.openIssues(limit: 100), "logEvents": report.events, "messagesWithheld": report.withheld]
                let data = try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                return String(decoding: data, as: UTF8.self)
            } catch {
                return (error as? AdvisorError)?.description ?? "This server's files couldn't be read safely, so nothing would be shared."
            }
        }.value
        previews[root.path] = text
    }

    func forgetEverything(servers: [ServerController]) {
        for server in servers { cancel(server); share(server, false) }
        SuggestionInbox.forgetEverything()
        previews.removeAll()
        for server in servers {
            defaults.removeObject(forKey: "advisorLast:\(server.paths.root.path)")
            items[server.paths.root.path] = []
            phases[server.paths.root.path] = .idle
        }
    }

    // MARK: Checking

    func cancel(_ server: ServerController) {
        running[server.paths.root.path]?.terminate()
    }

    func check(_ server: ServerController) async {
        let path = server.paths.root.path
        guard Modules.shared.isOn(.advisor), isShared(server), phase(server) != .checking else { return }
        findClaude()
        guard let claude = claudePath else { phases[path] = .failed("Claude Code isn't installed on this Mac."); return }
        guard let program = advisorProgram else { phases[path] = .failed("This build of Leaf Juice is missing its Advisor program."); return }
        phases[path] = .checking
        do {
            let inbox = try SuggestionInbox(sanitizer: nil)
            let key = try PrivacyKey()
            let token = try key.server(path: path, display: server.profile.name)
            let earlier = inbox.all().suggestions.filter { $0.server == token }.map(\.id)
            let work = AdvisorPaths.home.appendingPathComponent("run", isDirectory: true)
            try FileOps.ensureDir(work)
            let config = work.appendingPathComponent("client.json")
            let client: [String: Any] = ["mcpServers": ["leafjuice": ["command": program, "args": ["--server", path]]]]
            try JSONSerialization.data(withJSONObject: client).write(to: config)
            chmod(config.path, 0o600)

            let outcome = try await Self.run(claude: claude, config: config, folder: work, prompt: Self.prompt(ignoring: inbox.neverRaised(server: path))) { [weak self] process in
                self?.running[path] = process
            }
            running[path] = nil
            switch outcome {
            case .finished:
                // A new check replaces the last one, so its advice never piles up.
                earlier.forEach { inbox.remove(id: $0) }
                defaults.set(Date(), forKey: "advisorLast:\(path)")
                defaults.set(signature(server), forKey: "advisorSeen:\(path)")
                phases[path] = .idle
            case .cancelled:
                phases[path] = .idle
            case let .failed(message):
                phases[path] = .failed(message)
            }
        } catch {
            running[path] = nil
            phases[path] = .failed((error as? AdvisorError)?.description ?? "The check couldn't start.")
        }
        refresh(server)
    }

    /// While the app is open. Only checks when a new warning or error has appeared, at most once every six hours,
    /// so it costs nothing while the server is quiet.
    func watch(_ model: AppModel) {
        guard !watching else { return }
        watching = true
        Task { [weak self] in
            while let self {
                try? await Task.sleep(for: .seconds(600))
                guard Modules.shared.isOn(.advisor) else { continue }
                for server in model.servers where self.isShared(server) && self.isAutomatic(server) {
                    let path = server.paths.root.path
                    let last = self.lastCheck(server) ?? .distantPast
                    guard Date().timeIntervalSince(last) > 6 * 3600,
                          self.signature(server) != self.defaults.string(forKey: "advisorSeen:\(path)") ?? "" else { continue }
                    await self.check(server)
                    if self.items[path]?.contains(where: { $0.severity == .important }) == true {
                        server.raiseAlert("The Advisor has something for \(server.profile.name)", "Open Leaf Juice to read it.")
                    }
                }
            }
        }
    }

    private static func prompt(ignoring: [String]) -> String {
        var text = "You look after this Minecraft server for its owner, who isn't a developer. Check for problems worth raising, and use suggest once for each real problem, most important first. Say what's wrong, which plugin or setting is responsible, and what to do, in plain words. Say what you're unsure of. If nothing is worth raising, leave no suggestion."
        if !ignoring.isEmpty {
            text += "\n\nThe owner has decided these aren't worth raising, so don't raise them again unless they've clearly become worse:\n" + ignoring.map { "- \($0)" }.joined(separator: "\n")
        }
        return text
    }

    private enum Outcome: Sendable { case finished, cancelled, failed(String) }

    /// The one place the AI client is started. `--tools ""` is what takes away its shell and files.
    private static func run(claude: String, config: URL, folder: URL, prompt: String, started: @MainActor (Process) -> Void) async throws -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.currentDirectoryURL = folder
        let allowed = ["list_servers", "server_summary", "open_issues", "recent_problems", "suggest"].map { "mcp__leafjuice__\($0)" }.joined(separator: ",")
        process.arguments = ["-p", prompt, "--model", "sonnet", "--output-format", "json", "--settings", #"{"disableAllHooks":true}"#, "--mcp-config", config.path, "--strict-mcp-config", "--tools", "", "--allowedTools", allowed]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        started(process)
        let timeout = Task.detached { try await Task.sleep(for: .seconds(300)); process.terminate() }
        let data = await Task.detached(priority: .utility) { output.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        timeout.cancel()
        if process.terminationReason == .uncaughtSignal { return .cancelled }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if body?["is_error"] as? Bool == true || body == nil {
            let said = (body?["result"] as? String)?.lowercased() ?? ""
            if said.contains("not logged in") || said.contains("login") { return .failed("Claude Code isn't signed in. Open Terminal, run claude, and sign in.") }
            if said.contains("limit") { return .failed("Your Claude account has reached a usage limit. Try again later.") }
            return .failed("The check didn't finish. Nothing on your server changed.")
        }
        return .finished
    }
}

private extension Suggestion.Severity {
    var rank: Int { [.info: 0, .warning: 1, .important: 2][self] ?? 0 }
    var label: String { [.info: "Good to know", .warning: "Worth a look", .important: "Needs attention"][self] ?? "" }
    var tone: Tone { [.info: Tone.info, .warning: .warning, .important: .danger][self] ?? .info }
}

/// A second opinion, on request. Off until you turn it on, for each server separately.
struct AdvisorPage: View {
    @Bindable var model: AppModel
    let server: ServerController
    private var center: AdvisorCenter { AdvisorCenter.shared }
    @State private var showingPreview = false
    @State private var confirmingForget = false

    var body: some View {
        Page(title: "Advisor", subtitle: "Looks over \(server.profile.name) with AI and suggests what to do. It can't change anything.") {
            if center.isShared(server) { working } else { introduction }
        }
        .onAppear { center.findClaude(); center.refresh(server); center.watch(model) }
        .onChange(of: server.id) { center.refresh(server) }
        .sheet(isPresented: $showingPreview) { AdvisorPreview(server: server) }
        .confirmationDialog("Forget everything the Advisor has stored?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Forget Everything", role: .destructive) { center.forgetEverything(servers: model.servers) }
        } message: {
            Text("This deletes its suggestions and its list of who each code name stands for, and stops sharing every server. Your servers aren't touched.")
        }
    }

    // MARK: Before anything is shared

    @ViewBuilder private var introduction: some View {
        Card(title: "A second pair of eyes", systemImage: "sparkle.magnifyingglass") {
            Text("When something goes wrong on a busy server, it can be hard to tell what matters. The Advisor reads what Leaf Juice has noticed and tells you, in plain words, what's wrong and what to do first.")
                .foregroundStyle(Juice.ink).fixedSize(horizontal: false, vertical: true)
        }
        HStack(alignment: .top, spacing: 14) {
            Card(title: "What it sees", systemImage: "eye") {
                AdvisorBullet("Plugin file names, and your Minecraft version")
                AdvisorBullet("Errors Leaf Juice recognises, with their technical traces")
                AdvisorBullet("Speed, memory and crash numbers")
                AdvisorBullet("Players as code names, only if a problem involves them")
            }
            Card(title: "What it never sees", systemImage: "eye.slash") {
                AdvisorBullet("Chat, or the commands players type")
                AdvisorBullet("Passwords, and plugin settings files")
                AdvisorBullet("Player names, or addresses")
                AdvisorBullet("Anything from your other servers, unless you share them too")
            }
        }
        Button("See Exactly What Would Be Shared") { showingPreview = true }.buttonStyle(.juice)
        if center.claudePath == nil {
            Callout(tone: .info, title: "This needs Claude Code", detail: "The Advisor uses your own Claude account through Claude Code, a free program from Anthropic. Leaf Juice stays free, and has no AI of its own.") {
                HStack {
                    Link("Get Claude Code", destination: URL(string: "https://claude.com/claude-code")!).buttonStyle(.juice)
                    Button("Check Again") { center.findClaude() }.buttonStyle(.juice)
                }
            }
        } else {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("What's shared goes to Anthropic through your own Claude account. Each check takes about half a minute. If you pay per use, each cost about 8 cents in testing.")
                        .foregroundStyle(Juice.ink).fixedSize(horizontal: false, vertical: true)
                    Button("Share \(server.profile.name) with the Advisor") { center.share(server, true) }.buttonStyle(.juicePrimary)
                    Hint("Nothing is sent until you press Check Now. You can stop sharing at any time.")
                }
            }
        }
    }

    // MARK: In use

    @ViewBuilder private var working: some View {
        statusRow
        if case let .failed(message) = center.phase(server) {
            Callout(tone: .warning, title: "That didn't work", detail: message)
        }
        let items = center.items[server.paths.root.path] ?? []
        if center.phase(server) == .checking, items.isEmpty {
            EmptyMessage(icon: "sparkle.magnifyingglass", title: "Looking things over", detail: "This usually takes about half a minute.")
        } else if items.isEmpty {
            if center.lastCheck(server) == nil {
                EmptyMessage(icon: "sparkle.magnifyingglass", title: "No checks yet", detail: "Press Check Now, and suggestions will appear here.")
            } else {
                EmptyMessage(icon: "leaf", title: "Nothing to raise", detail: "The last check found nothing worth your time.")
            }
        } else {
            ForEach(items) { item in AdvisorCard(item: item, server: server) }
            Hint("Written by AI from filtered logs. It can be wrong, and a plugin could try to mislead it. Check before acting, and don't punish a player on this alone.")
        }
        settings
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            if center.phase(server) == .checking {
                Button("Stop") { center.cancel(server) }.buttonStyle(.juice)
                ProgressView().controlSize(.small).accessibilityLabel("Checking")
                Text("Checking…").foregroundStyle(Juice.muted)
            } else {
                Button("Check Now") { Task { await center.check(server) } }.buttonStyle(.juicePrimary)
                if let last = center.lastCheck(server) {
                    Text("Last checked \(last.formatted(.relative(presentation: .named)))").foregroundStyle(Juice.muted)
                }
            }
            Spacer()
        }
    }

    private var settings: some View {
        Card(title: "Sharing", systemImage: "hand.raised") {
            Toggle(isOn: Binding(get: { center.isAutomatic(server) }, set: { center.setAutomatic(server, $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check by itself when something new goes wrong").foregroundStyle(Juice.ink)
                    Text("At most every six hours, while Leaf Juice is open. Quiet servers cost nothing.").font(.caption).foregroundStyle(Juice.muted)
                }
            }
            HStack {
                Button("See What's Shared") { showingPreview = true }.buttonStyle(.juice)
                Button("Stop Sharing This Server") { center.share(server, false) }.buttonStyle(.juice)
                Spacer()
                Button("Forget Everything…") { confirmingForget = true }.buttonStyle(.juiceDanger)
            }
        }
    }
}

private struct AdvisorBullet: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(Juice.muted).accessibilityHidden(true)
            Text(text).foregroundStyle(Juice.ink).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// `verbatim` throughout, so what the AI writes is only ever text: never a link, formatting or anything to run.
private struct AdvisorCard: View {
    let item: AdvisorCenter.Item
    let server: ServerController
    @State private var expanded = true

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.severity.tone.icon).foregroundStyle(item.severity.tone.color).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: item.title).font(.body.weight(.semibold)).foregroundStyle(Juice.ink).textSelection(.enabled)
                        Text(item.severity.label).font(.caption).foregroundStyle(Juice.muted)
                    }
                    Spacer(minLength: 0)
                }
                Text(verbatim: item.details).foregroundStyle(Juice.ink).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                HStack {
                    Button("Done") { AdvisorCenter.shared.dismiss(item, server: server, forGood: false) }.buttonStyle(.juice)
                        .help("Removes this. If the problem is still there, a later check may raise it again.")
                    Button("Don't Raise This Again") { AdvisorCenter.shared.dismiss(item, server: server, forGood: true) }.buttonStyle(.juice)
                        .help("Tells future checks you've decided this isn't worth raising.")
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(item.title)\n\n\(item.details)", forType: .string)
                    }
                    .buttonStyle(.juice)
                    Spacer()
                }
            }
        }
    }
}

/// The real text, generated here without contacting anyone, so you can judge it for yourself.
private struct AdvisorPreview: View {
    let server: ServerController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What the Advisor would see").font(.title3.weight(.semibold)).foregroundStyle(Juice.ink).accessibilityAddTraits(.isHeader)
            Hint("Nothing has been sent. This is what \(server.profile.name) would share if a check ran now. Names like Player-1a2b3c4d are code names that only this Mac can translate.")
            ScrollView {
                Text(verbatim: AdvisorCenter.shared.previews[server.paths.root.path] ?? "Reading…")
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(Juice.ink)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(10)
            }
            .background(Juice.surface, in: RoundedRectangle(cornerRadius: Juice.controlRadius))
            .overlay { RoundedRectangle(cornerRadius: Juice.controlRadius).strokeBorder(Juice.border, lineWidth: 1) }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(.juicePrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 480)
        .background(Juice.background)
        .task { await AdvisorCenter.shared.loadPreview(server) }
    }
}
