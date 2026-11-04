import AppKit
import LeafJuiceCore
import SwiftUI

// MARK: - The preview every deep change gets

struct RenamePlanView: View {
    @Binding var plan: RenamePlan

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach($plan.items) { $item in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(isOn: $item.selected) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.description).foregroundStyle(Juice.ink)
                                Text(item.location).font(.caption).foregroundStyle(Juice.muted).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .toggleStyle(.checkbox)
                        ForEach(item.changes.prefix(6), id: \.self) { change in
                            Text(change).font(.system(.caption, design: .monospaced)).foregroundStyle(Juice.ink).padding(.leading, 22)
                        }
                        if item.changes.count > 6 { Hint("and \(item.changes.count - 6) more").padding(.leading, 22) }
                        if let warning = item.warning { Callout(tone: .warning, title: warning) }
                    }
                }
                if !plan.notes.isEmpty {
                    Divider()
                    Text("Can't be changed from here").font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
                    ForEach(plan.notes, id: \.self) { Hint($0) }
                }
                if !plan.mentions.isEmpty {
                    Divider()
                    Text("Also mention this name, and won't be changed").font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
                    ForEach(plan.mentions, id: \.self) {
                        Text($0).font(.system(.caption, design: .monospaced)).foregroundStyle(Juice.muted)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 320)
    }
}

struct WorldRenameSheet: View {
    let server: ServerController
    let world: WorldEntry
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var plan: RenamePlan?

    private var problem: String? { WorldRename.problem(with: name, world: world, existing: server.worlds) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(world.title)").font(.title2.weight(.semibold)).foregroundStyle(Juice.ink)
            TextField("New name", text: $name).textFieldStyle(.roundedBorder)
                .onChange(of: name) { plan = problem == nil ? server.worldRenamePlan(world, to: name) : nil }
            if !name.isEmpty, let problem { Callout(tone: .warning, title: problem) }
            if plan != nil {
                RenamePlanView(plan: Binding(get: { plan! }, set: { plan = $0 }))
                Hint("The server stops while this happens. A restore point is made and verified first, and you can undo it afterwards.")
            }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.juice).keyboardShortcut(.cancelAction)
                Spacer()
                if Modules.shared.isOn(.testCopies) {
                    Button("Try on a Test Copy") {
                        let target = name
                        dismiss()
                        Task { await server.startTrial(.worldRename(worldName: world.name, to: target)) }
                    }
                    .buttonStyle(.juicePrimary).disabled(plan == nil || server.trialPhase != nil)
                }
                Button("Rename") {
                    guard let plan else { return }
                    dismiss()
                    let target = name
                    server.attempt { try await server.applyRename(plan, rebuild: { server.worldRenamePlan(world, to: target) }) }
                }
                .buttonStyle(.juice).disabled(plan == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

struct ServerRenameSheet: View {
    let model: AppModel
    let server: ServerController
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folder = ""
    @State private var plan: RenamePlan?

    private var formats: [String] { ServerRename.folderFormats(for: name) }
    private var folderChanges: Bool { !folder.isEmpty && folder != server.paths.root.lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Everywhere").font(.title2.weight(.semibold)).foregroundStyle(Juice.ink)
            TextField("New server name", text: $name, prompt: Text("Sonoran Realms")).textFieldStyle(.roundedBorder)
                .onChange(of: name) { _, _ in
                    if !formats.contains(folder) { folder = formats.first ?? "" }
                    rebuild()
                }
            if !formats.isEmpty {
                Picker("Folder name", selection: $folder) {
                    ForEach(formats, id: \.self) { Text($0).tag($0) }
                    Text("Keep \(server.paths.root.lastPathComponent)").tag(server.paths.root.lastPathComponent)
                }
                .onChange(of: folder) { rebuild() }
            }
            if plan != nil {
                RenamePlanView(plan: Binding(get: { plan! }, set: { plan = $0 }))
                Hint("The backup folder follows too. The server stops while this happens. A restore point is made and verified first.")
            }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.juice).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename Everywhere") { apply() }
                    .buttonStyle(.juicePrimary).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || plan == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func rebuild() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { plan = nil; return }
        plan = server.serverRenamePlan(name: name, folder: folderChanges ? folder : nil)
    }

    private func apply() {
        guard let plan else { return }
        let (newName, newFolder) = (name, folderChanges ? folder : nil)
        dismiss()
        onDone()
        server.attempt {
            try await server.applyRename(plan, rebuild: { server.serverRenamePlan(name: newName, folder: newFolder) }, afterwards: {
                if try server.rename(to: newName, moveFolderTo: newFolder) != nil { model.pathsChanged() }
            })
        }
    }
}

// MARK: - Test copies

struct TrialBanner: View {
    let server: ServerController

    var body: some View {
        if let phase = server.trialPhase, let change = server.trialChange {
            switch phase {
            case .finished:
                finished(change)
            case .open:
                Callout(tone: .info, title: "The test copy is running", detail: "Connect at localhost:\(server.trialController?.serverPort ?? 0) to try \(change.title). It's a copy: nothing here reaches the real server.") {
                    Button("Finish Testing") { Task { await server.finishOpenTrial() } }.buttonStyle(.juice)
                }
            default:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text("\(phase.title) \(change.title)").foregroundStyle(Juice.ink)
                    Spacer()
                    Button("Cancel") { Task { await server.collapseTrial() } }.buttonStyle(.juice)
                }
                .padding(12)
                .background(Juice.infoWash, in: RoundedRectangle(cornerRadius: Juice.cardRadius))
            }
        }
    }

    @ViewBuilder private func finished(_ change: TrialChange) -> some View {
        let report = server.trialReport ?? TrialReport()
        Callout(tone: report.passed ? .good : .danger, title: report.passed ? "\(change.title) worked on the test copy" : "\(change.title) had problems on the test copy", detail: detail(report)) {
            VStack(alignment: .trailing, spacing: 6) {
                if report.passed {
                    Button("Back Up and Proceed") { server.attempt { try await server.proceedAfterTrial() } }.buttonStyle(.juicePrimary)
                }
                Button(report.passed ? "Not Now" : "Discard the Copy") { Task { await server.collapseTrial() } }.buttonStyle(.juice)
                if !report.passed, report.culprit == nil, report.booted || report.failure != nil {
                    Button("Find Which Plugin") { Task { await server.findTrialCulprit() } }.buttonStyle(.juice)
                }
                if !report.passed {
                    Button("Proceed Anyway") { server.attempt { try await server.proceedAfterTrial() } }.buttonStyle(.juiceDanger)
                }
            }
        }
    }

    private func detail(_ report: TrialReport) -> String {
        var lines: [String] = []
        if let seconds = report.seconds { lines.append("It started in \(Int(seconds)) seconds.") }
        if let failure = report.failure { lines.append(failure) }
        if !report.blockers.isEmpty { lines.append("It couldn't start: " + report.blockers.joined(separator: ", ") + ".") }
        if !report.failedPlugins.isEmpty { lines.append("Plugins with problems: " + report.failedPlugins.joined(separator: ", ") + ".") }
        if let culprit = report.culprit { lines.append(culprit) }
        lines += report.problems.prefix(5)
        lines += report.notes
        if report.passed { lines.append("It doesn't prove every feature works, but it loaded cleanly. Proceeding removes the copy, makes a restore point and makes the change for real.") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Players

struct PlayersPage: View {
    let server: ServerController
    @State private var selected: PlayerInfo?
    @State private var merging: MergeSuggestion?

    var body: some View {
        HSplitView {
            list.frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
            Group {
                if let selected {
                    PlayerDetail(server: server, player: selected).id(selected.id)
                } else {
                    overview
                }
            }
            .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await server.refreshPlayers() }
        .sheet(item: $merging) { MergeSheet(server: server, suggestion: $0) }
    }

    private var list: some View {
        List(server.knownPlayers, selection: Binding(
            get: { selected?.id },
            set: { id in selected = server.knownPlayers.first { $0.id == id } })) { player in
            HStack(spacing: 6) {
                Image(systemName: server.players.contains(player.title) ? "circle.fill" : "circle")
                    .font(.caption2).foregroundStyle(Juice.pulp)
                    .accessibilityLabel(server.players.contains(player.title) ? "Online" : "Offline")
                Text(player.title).foregroundStyle(Juice.ink).lineLimit(1)
            }
            .tag(player.id)
        }
        .scrollContentBackground(.hidden)
        .overlay {
            if server.knownPlayers.isEmpty {
                EmptyMessage(icon: "person.2", title: "No players yet", detail: "Players appear here after they've joined.")
            }
        }
    }

    private var overview: some View {
        Page(title: "Players", subtitle: "Snapshots, inventory restores, name changes and who was on.") {
            if !server.mergeSuggestions.isEmpty {
                Card(title: "Possibly the same person", systemImage: "person.2.badge.gearshape") {
                    ForEach(server.mergeSuggestions) { suggestion in
                        HStack {
                            Text(suggestion.reason).foregroundStyle(Juice.ink).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Review…") { merging = suggestion }.buttonStyle(.juice)
                        }
                    }
                }
            }
            if !server.failedJoins.isEmpty {
                Card(title: "Couldn't get in", systemImage: "person.fill.xmark") {
                    ForEach(server.failedJoins.prefix(12)) { failure in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(failure.name), \(failure.date.formatted(.relative(presentation: .named)))").foregroundStyle(Juice.ink)
                            Hint(failure.meaning)
                        }
                    }
                }
            }
            LeaderboardCard(server: server)
            RegularsCard(server: server)
            SnapshotSettings(server: server)
            Card(title: "Who was on", systemImage: "clock") {
                if server.playerHistory.isEmpty { Hint("Nothing in the server's logs yet.") }
                ForEach(server.playerHistory.prefix(40)) { session in
                    HStack {
                        Text(session.name).foregroundStyle(Juice.ink)
                        Spacer()
                        Text(when(session)).font(.callout).foregroundStyle(Juice.muted)
                    }
                }
            }
        }
    }

    private func when(_ session: PlayerSession) -> String {
        let start = session.start.formatted(date: .abbreviated, time: .shortened)
        guard let end = session.end else { return "\(start), no recorded end" }
        return "\(start) to \(end.formatted(date: .omitted, time: .shortened))"
    }
}

struct SnapshotSettings: View {
    @Bindable var server: ServerController

    var body: some View {
        Card(title: "Automatic snapshots", systemImage: "camera") {
            Toggle("Snapshot each player's inventory while they play", isOn: $server.profile.playerSnapshots.enabled)
            Stepper("Every \(server.profile.playerSnapshots.intervalMinutes) minutes of play", value: $server.profile.playerSnapshots.intervalMinutes, in: 5...120, step: 5)
                .disabled(!server.profile.playerSnapshots.enabled)
            Stepper("Keep the latest \(server.profile.playerSnapshots.keep) per player", value: $server.profile.playerSnapshots.keep, in: 4...1000, step: 4)
                .disabled(!server.profile.playerSnapshots.enabled)
            Hint("Also taken as a player leaves. Includes each world and group's inventory when Multiverse-Inventories is in use. The server saves players about every 5 minutes, so a snapshot can be up to that old. It costs players nothing: files are only copied.")
        }
    }
}

struct PlayerDetail: View {
    let server: ServerController
    let player: PlayerInfo
    @State private var snapshots: [PlayerSnapshot] = []
    @State private var restoring: PlayerSnapshot?
    @State private var viewing: PlayerSnapshot?
    @State private var backupChoice: String = ""

    var body: some View {
        Page(title: player.title, subtitle: subtitle) {
            HStack {
                Button("Take Snapshot Now") {
                    server.attempt {
                        try server.snapshotPlayer(player)
                        reload()
                    }
                }
                .buttonStyle(.juicePrimary)
                if !server.backups.isEmpty {
                    Menu("Get from a Backup") {
                        ForEach(server.backups.prefix(30)) { record in
                            Button(record.date.formatted(date: .abbreviated, time: .shortened)) {
                                server.attempt {
                                    _ = try await PlayerSnapshots.fromBackup(record, uuid: player.uuid, name: player.title, paths: server.paths, profile: server.profile)
                                    reload()
                                }
                            }
                        }
                    }
                    .fixedSize()
                }
            }
            if let summary = PlayerFiles.summary(of: PlayerPaths(server.paths).data(player.uuid)) {
                Card(title: "Saved now", systemImage: "backpack") { InventoryView(summary: summary) }
            }
            if let stats = server.playerStats.first(where: { $0.uuid.lowercased() == player.uuid.lowercased() }) {
                PlayerStatsCard(stats: stats)
            }
            Card(title: "Snapshots", systemImage: "camera") {
                if snapshots.isEmpty { Hint("None yet. They're taken every 15 minutes of play by default, and as players leave.") }
                ForEach(snapshots) { snapshot in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(snapshot.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(Juice.ink)
                            Hint(describe(snapshot))
                        }
                        Spacer()
                        Button("View") { viewing = viewing == snapshot ? nil : snapshot }.buttonStyle(.juice)
                        Button("Restore…") { restoring = snapshot }.buttonStyle(.juice)
                    }
                    if viewing == snapshot {
                        let folder = PlayerSnapshots.location(snapshot, profile: server.profile)
                        if let summary = PlayerFiles.summary(of: folder.appendingPathComponent("player.dat")) {
                            InventoryView(summary: summary)
                        }
                        ForEach(snapshot.containers.filter { $0.hasPrefix("worlds/") }, id: \.self) { container in
                            if let summary = PlayerFiles.summary(ofInventoryFile: folder.appendingPathComponent("inventories/\(container)")) {
                                Text("In \(container.components(separatedBy: "/")[1])").font(.callout.weight(.semibold)).foregroundStyle(Juice.ink).padding(.top, 4)
                                InventoryView(summary: summary)
                            }
                        }
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .task { await server.refreshStats() }
        .sheet(item: $restoring) { PlayerRestoreSheet(server: server, snapshot: $0, onDone: reload) }
    }

    private func reload() { snapshots = server.playerSnapshots(player) }

    private var subtitle: String {
        var parts = [player.uuid]
        if let time = player.playTime { parts.append("\(Int(time / 3600)) hours played") }
        if let last = player.lastSeen { parts.append("last saved \(last.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: " · ")
    }

    private func describe(_ s: PlayerSnapshot) -> String {
        let kind = ["playing": "While playing", "left": "As they left", "manual": "Taken by hand", "backup": "From a backup", "before-restore": "Before a restore"][s.trigger] ?? s.trigger
        return s.containers.isEmpty ? kind : "\(kind) · \(s.containers.count) world or group inventories"
    }
}

struct InventoryView: View {
    let summary: InventorySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if summary.items.isEmpty { Hint("Inventory is empty.") }
            ForEach(summary.items) { row($0) }
            if !summary.enderItems.isEmpty {
                Text("Ender chest").font(.callout.weight(.semibold)).foregroundStyle(Juice.ink).padding(.top, 4)
                ForEach(summary.enderItems) { row($0) }
            }
            if let level = summary.level { Hint("Level \(level)" + (summary.dimension.map { " · in \($0.replacingOccurrences(of: "minecraft:", with: ""))" } ?? "")) }
        }
    }

    private func row(_ item: InventoryItem) -> some View {
        HStack {
            Text(item.title).foregroundStyle(Juice.ink)
            Spacer()
            Text("× \(item.count)").foregroundStyle(Juice.muted)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

struct PlayerRestoreSheet: View {
    let server: ServerController
    let snapshot: PlayerSnapshot
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var inventoryOnly = true
    @State private var chosen: Set<String> = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Restore \(snapshot.name)").font(.title2.weight(.semibold)).foregroundStyle(Juice.ink)
            Hint("From \(snapshot.date.formatted(date: .abbreviated, time: .shortened)). The world isn't touched, and their current state is snapshotted first.")
            Picker("What to restore", selection: $inventoryOnly) {
                Text("Inventory and ender chest").tag(true)
                Text("Everything: position, XP, health too").tag(false)
            }
            if !snapshot.containers.isEmpty {
                Text("Worlds and groups (Multiverse-Inventories)").font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
                ForEach(snapshot.containers, id: \.self) { container in
                    Toggle(title(container), isOn: Binding(
                        get: { chosen.contains(container) },
                        set: { if $0 { chosen.insert(container) } else { chosen.remove(container) } }))
                    .toggleStyle(.checkbox)
                }
                Hint("Leave all of these on unless you have a reason not to: the plugin can put a world's saved inventory back when a player joins. If the server is running, this applies at the next restart.")
            }
            if inventoryOnly, let worlds = PlayerSnapshots.crossWorld(snapshot, paths: server.paths, profile: server.profile) {
                Callout(tone: .warning, title: "This was taken in \(worlds.taken), and \(snapshot.name) is now in \(worlds.now)", detail: "Restoring only the inventory puts the \(worlds.taken) items in \(worlds.now). Choose Everything to send them back to \(worlds.taken) as well.")
            }
            if server.players.contains(snapshot.name) { Callout(tone: .warning, title: "\(snapshot.name) is online, so this applies at the next restart.") }
            if let error { Callout(tone: .danger, title: error) }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.juice).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Restore") { restore() }.buttonStyle(.juicePrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { chosen = Set(snapshot.containers) }
    }

    private func title(_ container: String) -> String {
        let parts = container.components(separatedBy: "/")
        guard parts.count >= 2 else { return container }
        return "\(parts[1]) (\(parts[0] == "groups" ? "group" : "world"))"
    }

    private func restore() {
        do {
            let outcome = try server.restorePlayer(snapshot, inventoryOnly: inventoryOnly, containers: Array(chosen))
            if outcome == .staged { server.notice = "\(snapshot.name)'s restore applies at the next restart." }
            onDone()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct MergeSheet: View {
    let server: ServerController
    let suggestion: MergeSuggestion
    @Environment(\.dismiss) private var dismiss
    @State private var plan: MergePlan?
    @State private var targetID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge \(suggestion.from.title)").font(.title2.weight(.semibold)).foregroundStyle(Juice.ink)
            Text(suggestion.reason).foregroundStyle(Juice.ink).fixedSize(horizontal: false, vertical: true)
            if suggestion.to.uuid.isEmpty {
                Picker("Merge into", selection: $targetID) {
                    Text("Choose a player").tag("")
                    ForEach(server.knownPlayers) { Text($0.title).tag($0.uuid) }
                }
                .onChange(of: targetID) { _, id in
                    plan = server.knownPlayers.first { $0.uuid == id }.map {
                        MergePlan(from: suggestion.from, to: PlayerRef(uuid: $0.uuid, name: $0.name))
                    }
                }
            }
            if let current = plan {
                if !suggestion.from.uuid.isEmpty {
                    Picker("Inventory, position and XP from", selection: Binding(get: { current.keepFromSource }, set: { plan?.keepFromSource = $0 })) {
                        Text("\(current.to.title) (kept profile)").tag(false)
                        Text("\(current.from.title) (old profile)").tag(true)
                    }
                    comparison(current)
                    Hint("Statistics are added together, and advancements from both are kept.")
                }
                let conflicts = PlayerMerge.conflicts(current, paths: server.paths)
                if !conflicts.isEmpty {
                    Text("Both have an inventory in these worlds or groups").font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
                    ForEach(conflicts, id: \.self) { container in
                        Picker(container, selection: Binding(get: { current.useOldContainer[container] ?? false }, set: { plan?.useOldContainer[container] = $0 })) {
                            Text("Keep \(current.to.title)'s").tag(false)
                            Text("Use \(current.from.title)'s").tag(true)
                        }
                    }
                }
                let others = PlayerMerge.otherFiles(uuid: current.from.uuid, paths: server.paths)
                if !others.isEmpty {
                    Text("Plugin files for the old profile, not changed").font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
                    ForEach(others.prefix(8), id: \.self) { Text($0).font(.system(.caption, design: .monospaced)).foregroundStyle(Juice.muted) }
                }
                Hint("The server stops while this happens. A restore point is made and verified first, and what's replaced is kept beside the backups. Permissions in LuckPerms and data in plugin databases can't be merged from here.")
            }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.juice).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Merge") {
                    guard let plan else { return }
                    dismiss()
                    server.attempt { try await server.mergePlayers(plan) }
                }
                .buttonStyle(.juicePrimary).disabled(plan == nil)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            if !suggestion.to.uuid.isEmpty { plan = MergePlan(from: suggestion.from, to: suggestion.to) }
        }
    }

    private func comparison(_ current: MergePlan) -> some View {
        let p = PlayerPaths(server.paths)
        func text(_ ref: PlayerRef) -> String {
            guard let s = PlayerFiles.summary(of: p.data(ref.uuid)) else { return "\(ref.title): no saved data" }
            return "\(ref.title): \(s.items.count) inventory stacks, \(s.enderItems.count) in ender chest, level \(s.level ?? 0)"
        }
        return VStack(alignment: .leading) { Hint(text(current.from)); Hint(text(current.to)) }
    }
}

// MARK: - Cleanup

struct CleanupPage: View {
    let server: ServerController
    @State private var selected: Set<String> = []
    @State private var scanned = false
    @State private var discarding: CleanupBatch?

    var body: some View {
        Page(title: "Cleanup", subtitle: "Leftovers from a server that's been running a long time. Nothing is deleted: items move beside your backups, where you can bring them back.") {
            HStack {
                Button("Scan Again") { Task { await scan() } }.buttonStyle(.juice)
                Button("Move \(selected.count) Selected Aside") {
                    let items = server.cleanupItems.filter { selected.contains($0.path) }
                    server.attempt { try await server.cleanUp(items); selected = defaults }
                }
                .buttonStyle(.juicePrimary).disabled(selected.isEmpty || !server.state.canStart)
            }
            if !server.state.canStart { Hint("Stop the server to clean up its folder.") }
            group("Known leftovers", icon: "checkmark.seal", items: server.cleanupItems.filter { $0.confidence == .safe }, empty: "Nothing obvious to clean up.")
            group("Worth a look", icon: "questionmark.circle", items: server.cleanupItems.filter { $0.confidence == .review }, empty: "Nothing here.")
            if !server.cleanupBatches.isEmpty {
                Card(title: "Moved aside", systemImage: "tray.full") {
                    ForEach(server.cleanupBatches) { batch in
                        HStack {
                            Text("\(batch.date.formatted(date: .abbreviated, time: .shortened)): \(batch.items.count) items, \(Format.bytes(batch.size))").foregroundStyle(Juice.ink)
                            Spacer()
                            Button("Bring Back") { server.attempt { try await server.undoCleanup(batch) } }.buttonStyle(.juice).disabled(!server.state.canStart)
                            Button("Delete…") { discarding = batch }.buttonStyle(.juiceDanger)
                        }
                    }
                }
            }
        }
        .task {
            if !scanned { await scan() }
        }
        .confirmationDialog("Permanently delete these?", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }), presenting: discarding) { batch in
            Button("Delete", role: .destructive) { server.attempt { try await server.discardCleanup(batch) } }
        } message: { batch in
            Text("\(batch.items.count) items, \(Format.bytes(batch.size)), will be permanently deleted. This can't be undone.")
        }
    }

    private var defaults: Set<String> { Set(server.cleanupItems.filter { $0.confidence == .safe }.map(\.path)) }

    private func scan() async {
        await server.scanForCleanup()
        selected = defaults
        scanned = true
    }

    private func group(_ title: String, icon: String, items: [CleanupItem], empty: String) -> some View {
        Card(title: title, systemImage: icon) {
            if items.isEmpty { Hint(empty) }
            ForEach(items) { item in
                Toggle(isOn: Binding(
                    get: { selected.contains(item.path) },
                    set: { if $0 { selected.insert(item.path) } else { selected.remove(item.path) } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(item.path) (\(Format.bytes(item.size)))").foregroundStyle(Juice.ink)
                        Hint(item.reason)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }
}

// MARK: - Comparing backups

struct BackupDiffSheet: View {
    let server: ServerController
    let record: BackupRecord
    @Environment(\.dismiss) private var dismiss
    @State private var otherName = ""
    @State private var diff: BackupDiff?
    @State private var working = false
    @State private var error: String?

    private var others: [BackupRecord] { server.backups.filter { $0.id != record.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compare Backups").font(.title2.weight(.semibold)).foregroundStyle(Juice.ink)
            Picker("Compare \(record.date.formatted(date: .abbreviated, time: .shortened)) with", selection: $otherName) {
                Text("Choose a backup").tag("")
                ForEach(others) { Text($0.date.formatted(date: .abbreviated, time: .shortened)).tag($0.fileName) }
            }
            .onChange(of: otherName) { run() }
            if working { HStack { ProgressView().controlSize(.small); Text("Unpacking and comparing…").foregroundStyle(Juice.ink) } }
            if let error { Callout(tone: .danger, title: error) }
            if let diff {
                ScrollView { results(diff).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 420)
            }
            HStack { Spacer(); Button("Close") { dismiss() }.buttonStyle(.juice).keyboardShortcut(.cancelAction) }
        }
        .padding(20)
        .frame(width: 620)
    }

    private func run() {
        guard let other = others.first(where: { $0.fileName == otherName }) else { return }
        diff = nil
        error = nil
        working = true
        let (older, newer) = other.date < record.date ? (other, record) : (record, other)
        Task {
            defer { working = false }
            do { diff = try await BackupCompare.compare(older, newer, profile: server.profile, paths: server.paths) }
            catch { self.error = error.localizedDescription }
        }
    }

    @ViewBuilder private func results(_ d: BackupDiff) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if d.isEmpty { Hint("No differences in settings, plugins, worlds or players.") }
            if let jar = d.serverJar { section("Server") { row(jar.name, jar.before, jar.after) } }
            if !d.plugins.isEmpty {
                section("Plugins") { ForEach(d.plugins) { row($0.name, $0.before, $0.after) } }
            }
            if !d.settings.isEmpty {
                section("Settings") {
                    ForEach(d.settings) { setting in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(setting.file): \(setting.key)").font(.callout).foregroundStyle(Juice.muted)
                            Text("\(setting.before ?? "(not set)") → \(setting.after ?? "(removed)")").font(.system(.caption, design: .monospaced)).foregroundStyle(Juice.ink)
                        }
                    }
                }
            }
            if !d.otherSettingsFiles.isEmpty {
                section("Other files that changed") { ForEach(d.otherSettingsFiles, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)).foregroundStyle(Juice.ink) } }
            }
            if !d.worlds.isEmpty {
                section("Worlds") { ForEach(d.worlds) { Text(describe($0)).foregroundStyle(Juice.ink) } }
            }
            if !d.players.isEmpty {
                section("Players") {
                    ForEach(d.players) { player in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(player.name ?? player.uuid).foregroundStyle(Juice.ink)
                            if player.added { Hint("New player") } else if player.removed { Hint("No longer present") }
                            else if player.items.isEmpty { Hint("Position or stats changed. Same items.") }
                            ForEach(player.items) { item in
                                Hint("\(ConfigForm.humanize(item.item.replacingOccurrences(of: "minecraft:", with: ""))): \(item.before) → \(item.after)")
                            }
                        }
                    }
                }
            }
            if d.otherFilesChanged > 0 { Hint("\(d.otherFilesChanged) other files changed, such as logs and libraries.") }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).foregroundStyle(Juice.ink).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func row(_ name: String, _ before: String?, _ after: String?) -> some View {
        Text("\(name): \(before ?? "(none)") → \(after ?? "(removed)")").foregroundStyle(Juice.ink)
    }

    private func describe(_ w: BackupDiff.WorldChange) -> String {
        if w.added { return "\(w.name): new world" }
        if w.removed { return "\(w.name): world removed" }
        var parts: [String] = []
        if w.chunksChanged > 0 { parts.append("\(w.chunksChanged) chunks saved again") }
        if w.regionsAdded > 0 { parts.append("\(w.regionsAdded) new regions explored") }
        if w.regionsRemoved > 0 { parts.append("\(w.regionsRemoved) regions removed") }
        return "\(w.name): " + parts.joined(separator: ", ")
    }
}
