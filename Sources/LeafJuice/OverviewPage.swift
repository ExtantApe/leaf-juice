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
                if !server.isLab { Button("Rename…") { renaming = true }.buttonStyle(.juice) }
                Button("Show in Finder") { NSWorkspace.shared.open(server.paths.root) }.buttonStyle(.juice)
                if !server.isLab {
                    Menu {
                        Button("Remove from Leaf Juice…") { confirmRemove = true }.disabled(server.state.isLive)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More actions").help("More actions")
                }
            }

            if server.isLab, Modules.shared.isOn(.lab) { LabPanel(model: model, server: server) }
            UpgradeBanner(server: server)
            if server.allowlistSurprise {
                Callout(tone: .info, title: "The allowlist is on", detail: "New servers on Minecraft 26 start with it on, so only players you add can join. Turn it off in Configs under Players, or add people to the allowlist there.")
            }
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
                if !server.isLab { ConnectionsCard(server: server) }
                performanceCard
                softwareCard
                pluginsCard
                backupsCard
                issuesCard
                if !server.isLab { ServerIconCard(server: server) }
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
            // The Lab only listens on this Mac, so a network address would just fail.
            let local = server.isLab ? nil : SystemInfo.lanAddress().map { port == 25565 ? $0 : "\($0):\(port)" }
            Fact(label: "On this Mac", value: port == 25565 ? "localhost" : "localhost:\(port)")
            if let local { Fact(label: "On your network", value: local) }
            Fact(label: "Server message", value: server.serverMessage ?? "Not set")
            Fact(label: "Players online", value: server.state == .running ? "\(server.players.count)" : "None")
            if !server.players.isEmpty {
                Text(server.players.sorted().joined(separator: ", ")).font(.callout).foregroundStyle(Juice.ink)
            }
            if !server.isLab { ConnectCheckRow(server: server) }
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
            if let tps = server.tps, server.state == .running {
                HStack(alignment: .firstTextBaseline) {
                    Text("Ticks per second").foregroundStyle(Juice.muted)
                    Spacer()
                    Badge(text: String(format: "%.1f", tps.oneMinute), tone: tps.isHealthy ? .good : .warning)
                }
                .accessibilityElement(children: .combine)
                .help("20 is perfect. Below about 18, players start to notice lag. Last 5 and 15 minutes: \(String(format: "%.1f", tps.fiveMinutes)), \(String(format: "%.1f", tps.fifteenMinutes)).")
            }
            if let mspt = server.mspt, server.state == .running {
                Fact(label: "Time per tick", value: String(format: "%.1f ms of 50", mspt))
            }
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
            if let drill = server.profile.lastDrill {
                Fact(label: drill.passed ? "Last proven" : "Last drill", value: drill.passed ? drill.date.formatted(.relative(presentation: .named)) : "Failed")
            }
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

/// Only runs when pressed, because it sends this Mac's public address to outside services.
struct ConnectCheckRow: View {
    let server: ServerController
    @State private var checking = false

    var body: some View {
        if let result = server.connectResult {
            Callout(tone: result.reachable ? .good : .warning, title: result.reachable ? "Reachable from the internet" : "Not reachable from the internet", detail: result.detail)
        }
        HStack {
            Button("Can Friends Connect?") { run() }.buttonStyle(.juice).disabled(server.state != .running || checking)
            if checking { ProgressView().controlSize(.small).accessibilityLabel("Checking") }
        }
        .help("Asks an outside service to try connecting. This shares your public address with api.ipify.org and api.mcsrvstat.us.")
    }

    private func run() {
        checking = true
        server.attempt {
            defer { checking = false }
            try await server.checkConnection()
        }
    }
}


/// Icons to rotate between: the ones in the server's server-icons folder, with the one in use marked.
struct ServerIconCard: View {
    let server: ServerController
    @State private var icons: [ServerIconChoice] = []
    @State private var unsaved = false
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        Card(title: "Server icon", systemImage: "photo") {
            if icons.isEmpty {
                Text(unsaved ? "The icon in use isn't in the icon folder yet." : "No icons in the icon folder yet.").foregroundStyle(Juice.ink)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), alignment: .top)], alignment: .leading, spacing: 10) {
                    ForEach(icons) { icon in tile(icon) }
                }
            }
            if unsaved {
                HStack {
                    Hint("The icon in use isn't one of these. It's saved into the folder before another is picked.")
                    Button("Keep It Now") { act { _ = try ServerIcons.keepCurrent(server.paths) } }.buttonStyle(.juice)
                }
            }
            Hint("Minecraft reads the icon when the server starts, so a new one shows in players' server lists after the next restart. Icons are 64×64 PNGs.")
            if let message { Callout(tone: .good, title: message) }
            if let error { Callout(tone: .warning, title: error) }
            HStack {
                Button("Add Icon…") { add() }.buttonStyle(.juice)
                Button("Open Icon Folder") {
                    try? FileOps.ensureDir(ServerIcons.folder(server.paths))
                    NSWorkspace.shared.open(ServerIcons.folder(server.paths))
                }
                .buttonStyle(.juice)
                Button("Refresh") { reload() }.buttonStyle(.juice)
            }
        }
        .onAppear { reload() }
    }

    private func tile(_ icon: ServerIconChoice) -> some View {
        Button {
            act {
                try ServerIcons.use(icon, paths: server.paths)
                message = "\(icon.name) is the icon now" + (server.state.isLive ? ". Players see it after the next restart." : ".")
            }
        } label: {
            VStack(spacing: 4) {
                Group {
                    if let image = NSImage(contentsOf: icon.file) {
                        Image(nsImage: image).interpolation(.none).resizable().frame(width: 64, height: 64)
                    } else {
                        Color.clear.frame(width: 64, height: 64)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(icon.inUse ? Juice.pulp : Juice.muted.opacity(0.3), lineWidth: icon.inUse ? 3 : 1))
                Text(icon.name).font(.caption).foregroundStyle(Juice.ink).lineLimit(2).multilineTextAlignment(.center).frame(width: 76)
                if icon.inUse { Text("In use").font(.caption.weight(.semibold)).foregroundStyle(Juice.pulp) }
                else if !icon.fits { Text("\(icon.width)×\(icon.height)").font(.caption).foregroundStyle(Juice.warning) }
            }
        }
        .buttonStyle(.plain)
        .disabled(icon.inUse || !icon.fits)
        .accessibilityLabel("\(icon.name)\(icon.inUse ? ", in use" : "")\(icon.fits ? "" : ", \(icon.width) by \(icon.height), not usable")")
        .accessibilityHint(icon.inUse || !icon.fits ? "" : "Makes this the server icon")
        .help(icon.fits ? (icon.inUse ? "In use" : "Use this icon") : "Minecraft needs 64×64. Add it again to have it scaled.")
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .gif, .bmp, .tiff, .heic]
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        act {
            var notes: [String] = []
            for url in panel.urls {
                switch try ServerIcons.add(url, paths: server.paths) {
                case let .added(file): notes.append("Added \(file.deletingPathExtension().lastPathComponent).")
                case let .scaled(file, from): notes.append("Added \(file.deletingPathExtension().lastPathComponent), scaled from \(from)×\(from) to 64×64.")
                case let .alreadyThere(file): notes.append("\(url.lastPathComponent) is already there as \(file.deletingPathExtension().lastPathComponent).")
                }
            }
            message = notes.joined(separator: " ")
        }
    }

    private func act(_ work: () throws -> Void) {
        error = nil
        message = nil
        do { try work() } catch { self.error = error.localizedDescription }
        reload()
    }

    private func reload() {
        icons = ServerIcons.list(server.paths)
        unsaved = ServerIcons.activeIsUnsaved(server.paths)
    }
}
