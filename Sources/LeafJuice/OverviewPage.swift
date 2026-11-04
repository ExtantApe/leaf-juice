import AppKit
import LeafJuiceCore
import SwiftUI

struct OverviewPage: View {
    @Bindable var model: AppModel
    let server: ServerController
    @Binding var renaming: Bool
    @State private var confirmRemove = false

    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 14, alignment: .top)]

    var body: some View {
        Page(title: server.profile.name, subtitle: (server.paths.root.path as NSString).abbreviatingWithTildeInPath, oneLineSubtitle: true) {
            HStack(spacing: 8) {
                Badge(text: server.state.title, tone: server.state.tone, icon: server.state.icon)
                if server.state.isLive, let startedAt = server.startedAt {
                    Text("since \(startedAt.formatted(date: .omitted, time: .shortened))").font(.callout).foregroundStyle(Juice.muted)
                }
                Spacer()
                Button("Rename…") { renaming = true }.buttonStyle(.juice)
                Button("Show in Finder") { NSWorkspace.shared.open(server.paths.root) }.buttonStyle(.juice)
                Menu {
                    Button("Remove from Leaf Juice…") { confirmRemove = true }.disabled(server.state.isLive)
                } label: {
                    Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More actions").help("More actions")
            }

            UpgradeBanner(server: server)
            if server.needsRestart {
                Callout(tone: .warning, title: "Restart needed", detail: pendingDetail) {
                    Button("Review") { model.page = .changes }.buttonStyle(.juice)
                }
            }
            if let plan = server.restartPlan {
                Callout(tone: .info, title: planTitle(plan)) {
                    Button("Cancel Restart") { server.cancelRestart() }.buttonStyle(.juice)
                }
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                connectCard
                performanceCard
                softwareCard
                pluginsCard
                backupsCard
                issuesCard
            }
        }
        .confirmationDialog("Remove \(server.profile.name) from Leaf Juice?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { model.remove(server) }
        } message: {
            Text("The server's folder stays where it is, with all its files and worlds. Backups aren't deleted either.")
        }
    }

    private var pendingDetail: String {
        var parts: [String] = []
        if !server.pending.isEmpty { parts.append("\(server.pending.count) change\(server.pending.count == 1 ? "" : "s") waiting") }
        if server.launchChangedSinceStart { parts.append("launch settings changed") }
        return parts.joined(separator: " and ") + "."
    }

    private func planTitle(_ plan: RestartPlan) -> String {
        if plan.whenEmpty { return "Restarting when the last player leaves" }
        if let at = plan.at { return "Restarting at \(at.formatted(date: .omitted, time: .shortened))" }
        return "Restart planned"
    }

    private var connectCard: some View {
        Card(title: "Connect", systemImage: "network") {
            let port = server.serverPort
            let local = SystemInfo.lanAddress().map { port == 25565 ? $0 : "\($0):\(port)" }
            Fact(label: "On this Mac", value: port == 25565 ? "localhost" : "localhost:\(port)")
            if let local { Fact(label: "On your network", value: local) }
            Fact(label: "Players online", value: server.state == .running ? "\(server.players.count)" : "None")
            if !server.players.isEmpty {
                Text(server.players.sorted().joined(separator: ", ")).font(.callout).foregroundStyle(Juice.ink)
            }
            if let local {
                Button("Copy Network Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(local, forType: .string)
                }
                .buttonStyle(.juice)
            }
        }
    }

    private var performanceCard: some View {
        Card(title: "Performance", systemImage: "speedometer") {
            if let m = server.metrics {
                Fact(label: "Memory in use", value: Format.bytes(m.memoryBytes))
                ProgressView(value: min(1, Double(m.memoryBytes) / Double(server.profile.launch.maxMemoryMB * 1_048_576)))
                    .accessibilityLabel("Memory used, out of the \(Format.memory(mb: server.profile.launch.maxMemoryMB)) maximum")
                Fact(label: "CPU", value: "\(Int(m.cpuPercent))%")
                Fact(label: "Heap limit", value: Format.memory(mb: server.profile.launch.maxMemoryMB))
                Hint("100% is one CPU core. Memory includes Java's own overhead, so it can exceed the heap limit.")
            } else {
                Fact(label: "Heap limit", value: Format.memory(mb: server.profile.launch.maxMemoryMB))
                Fact(label: "This Mac", value: Format.memory(mb: SystemInfo.memoryMB))
                Hint("Live figures appear while the server runs.")
            }
        }
    }

    private var softwareCard: some View {
        Card(title: "Software", systemImage: "shippingbox") {
            Fact(label: "Running", value: server.profile.software.label)
            if let java = server.resolvedJava() { Fact(label: "Java", value: java.major > 0 ? String(java.major) : "Custom") }
            if let update = server.softwareUpdate {
                Badge(text: "Build \(update.build.map(String.init) ?? "") available", tone: .info, icon: "arrow.down.circle.fill")
            } else if server.profile.software.supportStatus == "UNSUPPORTED" {
                Badge(text: "This version no longer gets updates", tone: .warning)
            }
            Button("Open Software") { model.page = .software }.buttonStyle(.juice)
        }
    }

    private var pluginsCard: some View {
        Card(title: "Plugins", systemImage: "puzzlepiece.extension") {
            let updates = server.plugins.filter { server.record(for: $0).available != nil }.count
            Fact(label: "Installed", value: "\(server.plugins.filter(\.enabled).count)")
            Fact(label: "Updates available", value: "\(updates)")
            Fact(label: "Without a source", value: "\(server.plugins.filter { !server.record(for: $0).source.isSet }.count)")
            Button("Open Plugins") { model.page = .plugins }.buttonStyle(.juice)
        }
    }

    private var backupsCard: some View {
        Card(title: "Backups", systemImage: "externaldrive") {
            if let latest = server.backups.first {
                Fact(label: "Latest", value: latest.date.formatted(.relative(presentation: .named)))
                Fact(label: "Size", value: Format.bytes(latest.size))
            } else {
                Fact(label: "Latest", value: "None yet")
            }
            Fact(label: "Automatic", value: server.profile.backup.enabled ? "Every \(server.profile.backup.intervalHours) h" : "Off")
            Button("Back Up Now") { server.attempt { try await server.backupNow() } }
                .buttonStyle(.juice).disabled(server.isBackingUp)
        }
    }

    private var issuesCard: some View {
        Card(title: "Issues", systemImage: "exclamationmark.bubble") {
            let open = server.issues.filter { $0.status == .open }
            Fact(label: "Open", value: "\(open.count)")
            Fact(label: "Needing attention", value: "\(open.filter { $0.severity >= .error }.count)")
            Button(model.showIssues ? "Hide Panel" : "Show Panel") { model.showIssues.toggle() }.buttonStyle(.juice)
        }
    }
}
