import AppKit
import LeafJuiceCore
import SwiftUI

struct BackupsPage: View {
    @Bindable var server: ServerController
    @State private var restoring: BackupRecord?
    @State private var deleting: BackupRecord?
    @State private var comparing: BackupRecord?

    var body: some View {
        Page(title: "Backups", subtitle: "Worlds and settings, saved safely even while the server runs.") {
            HStack {
                Button("Back Up Now") { server.attempt { try await server.backupNow() } }
                    .buttonStyle(.juicePrimary).disabled(server.isBackingUp || server.state == .starting || server.state == .stopping)
                Button("Show Folder") {
                    let folder = Backups.destination(server.profile)
                    try? FileOps.ensureDir(folder)
                    NSWorkspace.shared.open(folder)
                }
                .buttonStyle(.juice)
                if server.isBackingUp { ProgressView().controlSize(.small).accessibilityLabel("Backing up") }
            }
            UpgradeBanner(server: server)
            if Modules.shared.isOn(.backupDrill) { drillCard }
            settingsCard
            listCard
            ShelfCard(server: server)
        }
        .onAppear { server.refreshBackups() }
        .sheet(item: $comparing) { BackupDiffSheet(server: server, record: $0) }
        .confirmationDialog("Restore this backup?", isPresented: restoreShown, presenting: restoring) { record in
            Button("Restore") { server.attempt { try await server.restoreBackup(record) } }
        } message: { record in
            Text("\(record.scope == .everything ? "The whole server returns to this state, and anything added since is removed." : "The items in this backup replace the current ones.") A safety copy of the current state is saved and pinned first.\n\nMade \(record.date.formatted()) on \(record.software).")
        }
        .confirmationDialog("Delete this backup?", isPresented: deleteShown, presenting: deleting) { record in
            Button("Delete", role: .destructive) { server.attempt { try server.deleteBackup(record) } }
        } message: { record in
            Text("\(record.fileName) will be permanently deleted. This can't be undone.")
        }
    }

    private var restoreShown: Binding<Bool> {
        Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })
    }
    private var deleteShown: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var drillCard: some View {
        Card(title: "Backup drill", systemImage: "checkmark.shield") {
            if let drill = server.profile.lastDrill {
                Callout(tone: drill.passed ? .good : .danger, title: drill.passed ? "Last proven \(drill.date.formatted(.relative(presentation: .named)))" : "The last drill failed", detail: "Backup from \(drill.backupDate.formatted(date: .abbreviated, time: .shortened)). \(drill.detail)")
            } else {
                Hint("A backup you've never restored is a backup you hope works. A drill unpacks one to a throwaway folder, starts it on its own port, then removes it.")
            }
            HStack {
                Button(server.drillRunning ? "Testing…" : "Test Latest Backup") { Task { await server.runBackupDrill() } }
                    .buttonStyle(.juice).disabled(server.drillRunning || server.trialPhase != nil || server.backups.isEmpty)
                if server.drillRunning { ProgressView().controlSize(.small).accessibilityLabel("Testing the backup") }
                Toggle("Test automatically each week, when nobody's on", isOn: $server.profile.backup.autoDrill).toggleStyle(.checkbox)
            }
            Hint("Your real server keeps running. Plugins that reach outside are off in the test, and it won't run automatically if a plugin uses an outside database.")
        }
    }

    private var settingsCard: some View {
        Card(title: "Schedule", systemImage: "calendar") {
            Toggle("Back up automatically while the server runs", isOn: $server.profile.backup.enabled)
            Picker("How often", selection: $server.profile.backup.intervalHours) {
                Text("Every hour").tag(1)
                Text("Every 3 hours").tag(3)
                Text("Every 6 hours").tag(6)
                Text("Every 12 hours").tag(12)
                Text("Every day").tag(24)
                Text("Every week").tag(168)
            }
            .disabled(!server.profile.backup.enabled)
            Picker("What to include", selection: $server.profile.backup.scope) {
                ForEach(BackupScope.allCases) { Text($0.title).tag($0) }
            }
            if server.profile.backup.scope == .everything {
                Hint("Restoring puts the server back exactly as it was, ready to start, even without internet: jar, libraries, plugins, worlds, settings and logs. Anything added since is removed.")
            }
            Stepper("Always keep the latest \(server.profile.backup.keepLast)", value: $server.profile.backup.keepLast, in: 1...100)
            Stepper(keepDaysLabel, value: $server.profile.backup.keepDays, in: 0...365)
            Hint("Older backups are deleted automatically. Pinned ones never are, including restore points for upgrades you haven't decided on.")
            Toggle("Back up before plugin and server updates", isOn: $server.profile.backup.beforeUpdates)
            Divider()
            mirrorSection
            LabeledContent("Saved to") {
                HStack {
                    Text(Backups.destination(server.profile).path).foregroundStyle(Juice.ink).lineLimit(1).truncationMode(.middle)
                    Button("Change…") { chooseDestination() }.buttonStyle(.juice)
                    if !Backups.isDefaultLocation(Backups.destination(server.profile)) {
                        Button("Use Default") { server.useDefaultBackupFolder() }.buttonStyle(.juice)
                    }
                }
            }
            Hint("By default, backups sit beside your servers in LeafJuice/backups. That's the same drive, so a copy on another drive is what protects you if that one fails. Changing this doesn't move backups you've already made.")
        }
    }

    private var keepDaysLabel: String {
        server.profile.backup.keepDays == 0 ? "Don't keep extras by age" : "Also keep anything newer than \(server.profile.backup.keepDays) days"
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            try? Backups.claim(url, for: server.profile.id)
            server.profile.backup.destination = url.path
            server.refreshBackups()
        }
    }

    @ViewBuilder private var mirrorSection: some View {
        LabeledContent("Also copy to") {
            HStack {
                Text(server.profile.backup.mirror ?? "Nowhere yet").foregroundStyle(Juice.ink).lineLimit(1).truncationMode(.middle)
                Button("Choose…") { chooseMirror() }.buttonStyle(.juice)
                if server.profile.backup.mirror != nil { Button("Stop") { server.profile.backup.mirror = nil }.buttonStyle(.juice) }
            }
        }
        if server.profile.backup.mirror == nil {
            Hint("If the drive holding your server fails, the backups beside it go too. A second location, on another drive, protects against that. Each copy is checked against the original.")
        } else if let last = server.profile.backup.lastMirrored {
            Hint("Last copied \(last.formatted(.relative(presentation: .named))). It keeps the same number of backups as the main folder.")
        }
        if let path = server.profile.backup.mirror {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            let missing = Backups.onlyInMirror(server.profile, folder: folder)
            if !missing.isEmpty {
                Callout(tone: .info, title: "\(missing.count) backup\(missing.count == 1 ? " is" : "s are") only at your second location") {
                    Button("Copy Back") {
                        server.attempt {
                            for record in missing { try await Backups.copyBack(record, profile: server.profile, from: folder) }
                            server.refreshBackups()
                        }
                    }
                    .buttonStyle(.juice)
                }
            }
        }
    }

    private func chooseMirror() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Copy Backups Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let main = Backups.destination(server.profile).standardizedFileURL.path
        if url.standardizedFileURL.path == main { server.notice = "That's the main backup folder, so it wouldn't add any protection."; return }
        server.profile.backup.mirror = url.appendingPathComponent(server.paths.root.lastPathComponent, isDirectory: true).path
        if !FileOps.sameVolume(url, Backups.destination(server.profile)) { return }
        server.notice = "That's on the same drive as your main backups, so it won't help if the drive fails. Another drive is better."
    }

    private var listCard: some View {
        Card(title: "Saved backups", systemImage: "archivebox") {
            if server.backups.isEmpty {
                EmptyMessage(icon: "archivebox", title: "No backups yet")
            }
            ForEach(server.backups) { record in
                BackupRow(record: record, canRestore: server.state.canStart && !server.isBackingUp) {
                    restoring = record
                } onDelete: {
                    deleting = record
                } onPin: {
                    server.setPinned(record, pinned: !record.pinned)
                } onCompare: {
                    comparing = record
                }
                if record.id != server.backups.last?.id { Divider() }
            }
            if !server.state.canStart, !server.backups.isEmpty {
                Hint("Stop the server to restore a backup.")
            }
        }
    }
}

private struct BackupRow: View {
    let record: BackupRecord
    let canRestore: Bool
    let onRestore: () -> Void
    let onDelete: () -> Void
    let onPin: () -> Void
    let onCompare: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(Juice.ink)
                    if record.pinned { Badge(text: "Pinned", tone: .info, icon: "pin.fill") }
                    if let warning = record.warning { Badge(text: "Note", tone: .warning).help(warning) }
                }
                Hint("\(Format.bytes(record.size)) · \(record.scope.title) · \(record.software) · \(triggerTitle)")
            }
            Spacer()
            Button("Compare…", action: onCompare).buttonStyle(.juice)
            Button(record.pinned ? "Unpin" : "Pin", action: onPin).buttonStyle(.juice)
            Button("Restore…", action: onRestore).buttonStyle(.juice).disabled(!canRestore)
            Button("Delete…", action: onDelete).buttonStyle(.juiceDanger)
        }
    }

    private var triggerTitle: String {
        switch record.trigger {
        case "manual": "Manual"
        case "scheduled": "Scheduled"
        case "before-update": "Before an update"
        case "before-restore": "Before a restore"
        case "before-world-delete": "Before deleting a world"
        case "before-upgrade": "Restore point before a change"
        default: record.trigger
        }
    }
}
