import LeafJuiceCore
import SwiftUI

/// Shown until you decide what to do about a version change.
struct UpgradeBanner: View {
    let server: ServerController
    @State private var confirmRollBack = false
    @State private var confirmKeep = false

    var body: some View {
        if let upgrade = server.activeUpgrade {
            Callout(
                tone: .warning,
                title: "Upgraded to \(upgrade.toLabel). Happy with it?",
                detail: "A verified restore point of \(upgrade.from.label) is saved (\(Format.bytes(upgrade.size))). Try the server, then keep the upgrade or roll back."
            ) {
                HStack {
                    Button("Roll Back…") { confirmRollBack = true }
                        .buttonStyle(.juice).disabled(server.activity != nil || server.isBackingUp)
                    Button("Keep This Upgrade…") { confirmKeep = true }.buttonStyle(.juice)
                }
            }
            .confirmationDialog("Roll back to \(upgrade.from.label)?", isPresented: $confirmRollBack) {
                Button("Roll Back") { server.attempt { try await server.rollBackUpgrade() } }
            } message: {
                Text("The server stops if it's running and returns to how it was before the upgrade. Anything players did since then isn't in the restored world, but it isn't lost: the upgraded server moves to the Shelf on the Backups page, and you can resume it later.")
            }
            .confirmationDialog("Keep \(upgrade.toLabel)?", isPresented: $confirmKeep) {
                Button("Keep") { server.keepUpgrade() }
            } message: {
                Text("This removes the roll back option. The restore point becomes an ordinary backup, so your retention settings will eventually delete it. You can pin it on the Backups page to hold on to it.")
            }
        }
    }
}

/// Upgraded servers you stepped back from. Deliberately apart from backups.
struct ShelfCard: View {
    let server: ServerController
    @State private var resuming: ShelvedUpgrade?
    @State private var deleting: ShelvedUpgrade?

    var body: some View {
        if !server.shelved.isEmpty {
            Card(title: "Shelf", systemImage: "tray.2") {
                Hint("Upgrades you rolled back, kept exactly as they were. These aren't backups: retention leaves them alone and they stay until you resume or delete them.")
                ForEach(server.shelved) { entry in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.label).foregroundStyle(Juice.ink)
                            Hint("Rolled back \(entry.date.formatted(date: .abbreviated, time: .shortened)) to \(entry.fromLabel) · \(Format.bytes(entry.size))")
                        }
                        Spacer()
                        Button("Resume…") { resuming = entry }.buttonStyle(.juice).disabled(server.activity != nil)
                        Button("Delete…") { deleting = entry }.buttonStyle(.juiceDanger)
                    }
                }
            }
            .confirmationDialog("Resume \(resuming?.label ?? "")?", isPresented: resumingShown, presenting: resuming) { entry in
                Button("Resume") { server.attempt { try await server.resumeShelved(entry) } }
            } message: { _ in
                Text("The server stops if it's running, and this upgraded state replaces it. What's running now is saved as a verified restore point first, so you can roll back again.")
            }
            .confirmationDialog("Delete this shelved upgrade?", isPresented: deletingShown, presenting: deleting) { entry in
                Button("Delete", role: .destructive) { server.attempt { try server.deleteShelved(entry) } }
            } message: { entry in
                Text("\(entry.label), \(Format.bytes(entry.size)), will be permanently deleted. This can't be undone.")
            }
        }
    }

    private var resumingShown: Binding<Bool> {
        Binding(get: { resuming != nil }, set: { if !$0 { resuming = nil } })
    }
    private var deletingShown: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }
}
