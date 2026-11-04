import AppKit
import LeafJuiceCore
import SwiftUI

struct BackupsPage: View {
    @Bindable var server: ServerController
    @State private var restoring: BackupRecord?
    @State private var deleting: BackupRecord?

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
            settingsCard
            listCard
            ShelfCard(server: server)
        }
        .onAppear { server.refreshBackups() }
        .confirmationDialog("Restore this backup?", isPresented: restoreShown, presenting: restoring) { record in
            Button("Restore") { server.attempt { try await server.restoreBackup(record) } }
        } message: { record in
            Text("The items in this backup replace the current ones. A safety copy of the current state is saved and pinned first.\n\nMade \(record.date.formatted()) on \(record.software).")
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
            Stepper("Always keep the latest \(server.profile.backup.keepLast)", value: $server.profile.backup.keepLast, in: 1...100)
            Stepper(keepDaysLabel, value: $server.profile.backup.keepDays, in: 0...365)
            Hint("Older backups are deleted automatically. Pinned ones never are, including restore points for upgrades you haven't decided on.")
            Toggle("Back up before plugin and server updates", isOn: $server.profile.backup.beforeUpdates)
            Divider()
            LabeledContent("Saved to") {
                HStack {
                    Text(Backups.destination(server.profile).path).foregroundStyle(Juice.ink).lineLimit(1).truncationMode(.middle)
                    Button("Change…") { chooseDestination() }.buttonStyle(.juice)
                    if server.profile.backup.destination != nil {
                        Button("Use Default") {
                            server.profile.backup.destination = nil
                            server.refreshBackups()
                        }
                        .buttonStyle(.juice)
                    }
                }
            }
            Hint("A backup on another drive survives that drive failing. The default location is on this Mac.")
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
            server.profile.backup.destination = url.path
            server.refreshBackups()
        }
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
        case "before-upgrade": "Restore point before an upgrade"
        default: record.trigger
        }
    }
}
