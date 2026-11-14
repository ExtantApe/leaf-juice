import AppKit
import LeafJuiceCore
import SwiftUI

extension ConnectionHealth {
    var tone: Tone {
        switch self {
        case .ready: .good
        case .warning: .warning
        case .notReady: .danger
        case .off, .unknown: .neutral
        }
    }
}

/// How players and admins reach this server: the address players type, and each tunnel or service, with its health.
/// Secrets are never shown here; the card only says whether one is in place.
struct ConnectionsCard: View {
    let server: ServerController
    @State private var loaded: ConnectionStore.Loaded?
    @State private var statuses: [String: ConnectionStatus] = [:]
    @State private var checking = false
    @State private var editing = false
    @State private var expanded: Set<String> = []

    var body: some View {
        Card(title: "Connections", systemImage: "point.3.connected.trianglepath.dotted") {
            if let loaded {
                ForEach(loaded.problems, id: \.self) { Callout(tone: .warning, title: "Connections file", detail: $0) }
                let address = loaded.settings.playerAddress
                Fact(label: "Players join with", value: address.isEmpty ? "Not set" : address)
                if loaded.settings.services.isEmpty {
                    Hint("No tunnels or services yet. Add playit, Tailscale or anything else that carries players or web traffic, so Leaf Juice can say whether each is working.")
                }
                ForEach(loaded.settings.services) { service in row(service) }
                HStack {
                    Button("Check") { check(outside: false) }.buttonStyle(.juice).disabled(checking || loaded.settings.services.isEmpty)
                        .help("Checks each agent and what it forwards to on this Mac. Nothing goes over the internet.")
                    Button("Check From Outside") { check(outside: true) }.buttonStyle(.juice).disabled(checking || loaded.settings.services.isEmpty)
                        .help("Also connects to each public address over the internet, through the tunnel, as a player would.")
                    if checking { ProgressView().controlSize(.small).accessibilityLabel("Checking") }
                }
                HStack {
                    Button("Edit Connections…") { editing = true }.buttonStyle(.juice)
                    if !address.isEmpty {
                        Button("Copy Address") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(address, forType: .string)
                        }
                        .buttonStyle(.juice)
                    }
                }
            } else {
                ProgressView().accessibilityLabel("Loading connections")
            }
        }
        .task { reload(); check(outside: false) }
        .sheet(isPresented: $editing, onDismiss: { reload(); check(outside: false) }) {
            if let loaded { ConnectionsEditor(server: server, loaded: loaded) }
        }
    }

    @ViewBuilder private func row(_ service: ConnectionService) -> some View {
        let status = statuses[service.id] ?? (service.enabled ? ConnectionStatus(.unknown, "Not checked yet.") : ConnectionStatus(.off, "Turned off."))
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(service.name).font(.body.weight(.semibold)).foregroundStyle(Juice.ink)
                Text(service.provider.title).font(.caption).foregroundStyle(Juice.muted)
                Spacer(minLength: 8)
                Badge(text: status.health.title, tone: status.health.tone)
            }
            Text(status.summary).font(.callout).foregroundStyle(Juice.ink).fixedSize(horizontal: false, vertical: true)
            if !status.details.isEmpty {
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(service.id) }, set: { if $0 { expanded.insert(service.id) } else { expanded.remove(service.id) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(status.details.enumerated()), id: \.offset) { Text("• \($0.element)").font(.callout).foregroundStyle(Juice.muted) }
                    }
                } label: { Text("What was checked").font(.callout) }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(service.name), \(status.health.title)")
    }

    private func reload() { loaded = server.savedConnections }

    private func check(outside: Bool) {
        guard let services = loaded?.settings.services, !services.isEmpty, !checking else { return }
        checking = true
        let context = server.connectionContext
        Task {
            var results: [String: ConnectionStatus] = [:]
            await withTaskGroup(of: (String, ConnectionStatus).self) { group in
                for service in services {
                    group.addTask { (service.id, await ConnectionCheck.run(service, context: context, probe: SystemConnectionProbe(), outside: outside)) }
                }
                for await (id, status) in group { results[id] = status }
            }
            statuses = results
            checking = false
        }
    }
}

/// Edits connections.json. Secrets go straight to the Keychain from a secure field and are never written to the file.
struct ConnectionsEditor: View {
    let server: ServerController
    let loaded: ConnectionStore.Loaded
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ConnectionSettings()
    @State private var error: String?
    @State private var removing: ConnectionService?

    init(server: ServerController, loaded: ConnectionStore.Loaded) {
        self.server = server
        self.loaded = loaded
        _settings = State(initialValue: loaded.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connections").font(.title2.weight(.semibold))
            Hint("Addresses and names are saved in this server's .leafjuice/connections.json. Secrets are never saved there: they go in your Keychain, or stay in the service's own file.")
            if loaded.unreadable {
                Callout(tone: .warning, title: "The old file couldn't be read", detail: "Saving moves it aside as connections.json.unreadable, so nothing is lost.")
            }
            LabeledContent("Players join with") {
                TextField("play.example.net", text: $settings.playerAddress).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Address players join with")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach($settings.services) { $service in
                        ServiceEditor(service: $service, isNew: !loaded.settings.services.contains { $0.id == service.id }) { removing = service }
                    }
                }
            }
            .frame(minHeight: 260)
            HStack {
                Menu("Add Connection") {
                    Button("playit tunnel for players") { add(.playit, .game) }
                    Button("playit tunnel for web (packs, sign-in)") { add(.playit, .web) }
                    Button("Tailscale") { add(.tailscale, .access) }
                    Button("Other: players (port forward or tunnel)") { add(.other, .game) }
                    Button("Other: web service (map, sign-in page, proxy, API)") { add(.other, .web) }
                    Button("Domain name (DNS)") { add(.other, .dns) }
                }
                .fixedSize()
                Spacer()
                if let error { Text(error).foregroundStyle(Juice.danger).font(.callout) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.juicePrimary)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 480)
        .confirmationDialog("Remove \(removing?.name ?? "this connection")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let r = removing { settings.services.removeAll { $0.id == r.id } }
                removing = nil
            }
        } message: {
            Text("Only Leaf Juice's entry is removed, when you save. The tunnel itself, and any secret in the Keychain, stay as they are.")
        }
    }

    private func add(_ provider: ConnectionProvider, _ traffic: ConnectionTraffic) {
        let base = provider == .other ? (traffic == .web ? "web" : traffic == .dns ? "dns" : "forward") : "\(provider.rawValue)\(traffic == .access ? "" : "-\(traffic.rawValue)")"
        var id = base, n = 2
        while settings.services.contains(where: { $0.id == id }) { id = "\(base)-\(n)"; n += 1 }
        settings.services.append(.preset(provider, traffic, id: id))
    }

    private func save() {
        for s in settings.services where !ConnectionService.isUsableID(s.id) {
            error = "\(s.name)'s short name must be lowercase letters, numbers and hyphens."
            return
        }
        guard Set(settings.services.map(\.id)).count == settings.services.count else { error = "Two connections have the same short name."; return }
        do {
            try server.saveConnections(settings, replacingUnreadable: loaded.unreadable)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ServiceEditor: View {
    @Binding var service: ConnectionService
    let isNew: Bool
    let remove: () -> Void
    @State private var secretText = ""
    @State private var presence: SecretPresence?
    @State private var secretError: String?

    private enum SecretKind: String, CaseIterable { case none, keychain, file, agent }
    private var secretKind: Binding<SecretKind> {
        Binding(get: {
            switch service.secret {
            case nil: .none
            case .keychain?: .keychain
            case .file?: .file
            case .agent?: .agent
            }
        }, set: {
            switch $0 {
            case .none: service.secret = nil
            case .keychain: service.secret = .keychain(account: service.id)
            case .file: service.secret = .file(path: "")
            case .agent: service.secret = .agent
            }
            refreshPresence()
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: $service.enabled) { Text(service.name.isEmpty ? service.id : service.name).font(.headline) }
                    .toggleStyle(.switch)
                    .accessibilityLabel("Check \(service.name)")
                Spacer()
                Button("Remove…", role: .destructive, action: remove).buttonStyle(.juice)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Name").foregroundStyle(Juice.muted)
                    TextField("Name", text: $service.name).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Short name").foregroundStyle(Juice.muted)
                    if isNew { TextField("play", text: $service.id).textFieldStyle(.roundedBorder).accessibilityLabel("Short name") }
                    else { Text(service.id).textSelection(.enabled) }
                }
                GridRow {
                    Text("Provider").foregroundStyle(Juice.muted)
                    Picker("Provider", selection: $service.provider) { ForEach(ConnectionProvider.allCases, id: \.self) { Text($0.title) } }.labelsHidden()
                }
                GridRow {
                    Text("Carries").foregroundStyle(Juice.muted)
                    Picker("Carries", selection: $service.traffic) { ForEach(ConnectionTraffic.allCases, id: \.self) { Text($0.title) } }.labelsHidden()
                }
                if (service.traffic != .access && service.traffic != .dns) || service.provider == .playit {
                    GridRow {
                        Text("Forwards to").foregroundStyle(Juice.muted)
                        TextField("127.0.0.1:25565", text: $service.localAddress).textFieldStyle(.roundedBorder).accessibilityLabel("Address on this Mac it forwards to")
                    }
                }
                if service.traffic != .access {
                    GridRow {
                        Text("Public address").foregroundStyle(Juice.muted)
                        TextField(service.traffic == .web ? "https://pack.example.net" : service.traffic == .dns ? "example.net" : "play.example.net", text: $service.publicAddress)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("Public address")
                    }
                }
                GridRow {
                    Text("Secret").foregroundStyle(Juice.muted)
                    Picker("Secret", selection: secretKind) {
                        Text("None needed").tag(SecretKind.none)
                        Text("In the Keychain").tag(SecretKind.keychain)
                        Text("In a file").tag(SecretKind.file)
                        Text("Kept by its agent").tag(SecretKind.agent)
                    }
                    .labelsHidden()
                }
            }
            switch service.secret {
            case .keychain(let account)?:
                HStack {
                    SecureField("Paste the secret", text: $secretText).textFieldStyle(.roundedBorder).accessibilityLabel("Secret for \(service.name)")
                    Button("Save to Keychain") {
                        do { try ConnectionSecrets.save(secretText, account: account); secretError = nil } catch { secretError = error.localizedDescription }
                        secretText = ""
                        refreshPresence()
                    }
                    .buttonStyle(.juice).disabled(secretText.isEmpty)
                }
                Hint(presenceText(presence) + (secretError.map { " \($0)" } ?? ""))
            case .file(let path)?:
                TextField("~/Library/Application Support/<service>/secret", text: Binding(get: { path }, set: { service.secret = .file(path: $0) }))
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Path of the secret file")
                Hint("Leaf Juice only checks the file is there and private. It never reads or copies it.")
            case .agent?:
                Hint("The provider's own agent keeps it. Leaf Juice asks the agent whether it has one.")
            case nil:
                EmptyView()
            }
        }
        .padding(12)
        .background(Juice.raised, in: RoundedRectangle(cornerRadius: Juice.cardRadius))
        .onAppear(perform: refreshPresence)
    }

    private func refreshPresence() {
        if case .keychain(let account)? = service.secret { presence = ConnectionSecrets.presence(account: account) } else { presence = nil }
    }

    private func presenceText(_ p: SecretPresence?) -> String {
        switch p {
        case .present?: "A secret is in the Keychain. Saving a new one replaces it."
        case .missing?: "No secret in the Keychain yet. Until there is, this shows as not ready."
        case .unavailable(let why)?: "Couldn't look in the Keychain. \(why)"
        case nil: ""
        }
    }
}
