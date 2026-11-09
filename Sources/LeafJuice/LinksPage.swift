import LeafJuiceCore
import SwiftUI

/// Each plugin, its version and where to read about it. A link nobody has confirmed stays a suggestion.
struct LinksPage: View {
    @Bindable var server: ServerController
    @State private var rows: [PluginLinkRow] = []
    @State private var searched: [String: [PluginLinkSuggestion]] = [:]
    @State private var searching: String?
    @State private var refreshing = false
    @State private var error: String?
    @State private var editing: PluginLinkRow?
    @State private var pageSettings = LinksPageSettings()
    @State private var log: [SignInEvent] = []

    var body: some View {
        Page(title: "Plugin Links", subtitle: "What's on this server, and where to read about each plugin.") {
            if let error { Callout(tone: .warning, title: "Modrinth couldn't be reached", detail: error) }
            Card(title: "This server", systemImage: "server.rack") {
                Fact(label: "Runs", value: server.profile.software.label)
                Fact(label: "Plugins with a link", value: "\(rows.filter { $0.link != nil }.count) of \(rows.count)")
                HStack {
                    Hint("Only a known source fills in a link. Everything else waits for you to choose it.")
                    Spacer()
                    Button(refreshing ? "Checking…" : "Check Modrinth Again") { refresh(all: true) }.buttonStyle(.juice).disabled(refreshing)
                }
            }
            playerPageCard
            if rows.isEmpty {
                Hint("No enabled plugins on this server.")
            } else {
                Card(title: "Plugins", systemImage: "link") {
                    ForEach(rows) { row in
                        rowView(row)
                        if row.id != rows.last?.id { Divider() }
                    }
                }
            }
        }
        .task {
            await server.refreshPlugins()
            reload()
            refresh(all: false)
            // Who's signed in changes from outside this screen.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                reload()
            }
        }
        .sheet(item: $editing) { row in
            LinkEditor(row: row, server: server) { reload() }
        }
    }

    @ViewBuilder private func rowView(_ row: PluginLinkRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Toggle(isOn: Binding(get: { pageSettings.shared.contains(row.key) }, set: { on in
                    if on { pageSettings.shared.insert(row.key) } else { pageSettings.shared.remove(row.key) }
                    savePage()
                })) { EmptyView() }
                .toggleStyle(.checkbox).labelsHidden().accessibilityLabel("Show \(row.name) to players")
                Text(row.name).font(.body.weight(.semibold)).foregroundStyle(Juice.ink).textSelection(.enabled)
                Hint(row.version.isEmpty ? "Version unknown" : row.version)
                Spacer()
                if let link = row.link, let url = URL(string: link.url) {
                    Link(destination: url) { Label(link.host, systemImage: "arrow.up.right.square") }
                        .help(link.url)
                } else {
                    Text("No link").foregroundStyle(Juice.muted)
                }
                Button(row.link == nil ? "Add…" : "Change…") { editing = row }.buttonStyle(.juice)
            }
            if let link = row.link { Hint(link.origin.explanation) }
            if row.link == nil {
                ForEach(row.suggestions + (searched[row.key] ?? []).filter { found in !row.suggestions.contains { $0.id == found.id } }) { suggestion in
                    suggestionView(suggestion, row)
                }
                if searched[row.key]?.isEmpty == true { Hint("Nothing found by that name.") }
                if searched[row.key] == nil {
                    HStack {
                        Button(searching == row.key ? "Searching…" : "Search by Name") { search(row) }
                            .buttonStyle(.juice).disabled(searching != nil)
                        Hint("Sends this plugin's name to Hangar and SpigotMC.")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func suggestionView(_ suggestion: PluginLinkSuggestion, _ row: PluginLinkRow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Badge(text: "Suggestion", tone: .info)
            if let url = URL(string: suggestion.link.url) {
                Link(suggestion.link.host, destination: url).help(suggestion.link.url)
            }
            Hint(suggestion.reason)
            Spacer()
            Button("Use") {
                server.chooseLink(suggestion.link.url, origin: suggestion.link.origin, forPlugin: row.key)
                reload()
            }
            .buttonStyle(.juice)
            .accessibilityLabel("Use \(suggestion.link.host) for \(row.name)")
        }
    }

    private func reload() {
        rows = server.pluginLinkRows
        pageSettings = server.linksPageSettings
        log = Array(server.signInLog.suffix(8).reversed())
    }

    private func savePage() { server.linksPageSettings = pageSettings }

    private var serving: Bool { server.linksListener != nil }

    private var playerPageCard: some View {
        Card(title: "Page for players", systemImage: "person.badge.key") {
            Hint("Only people on the allowlist with the latchkey.signin permission can sign in and see it. Tick each plugin below to share it.")
            if let problem = server.linksPageError { Callout(tone: .danger, title: problem) }
            if !server.hasLatchkey { Callout(tone: .warning, title: "The Latchkey plugin isn't installed", detail: "Without it nobody can sign in, because it's what proves who a player is.") }
            if !server.onlineModeIsOn { Callout(tone: .warning, title: "online-mode is off", detail: "A name proves nothing on this server, so sign-in refuses everyone.") }
            LabeledContent("Address players use") {
                TextField("Address players use", text: $pageSettings.address, prompt: Text("https://links.example.com"))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 320).disabled(serving).onChange(of: pageSettings.address) { savePage() }
            }
            LabeledContent("Port on this Mac") {
                TextField("Port on this Mac", value: $pageSettings.port, format: .number.grouping(.never))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 90).disabled(serving).onChange(of: pageSettings.port) { savePage() }
            }
            Toggle("Show the server's version", isOn: $pageSettings.showServerVersion).onChange(of: pageSettings.showServerVersion) { savePage() }
            Toggle("Show plugin versions", isOn: $pageSettings.showPluginVersions).onChange(of: pageSettings.showPluginVersions) { savePage() }
            Hint("Versions help anyone looking for a server with a known weakness, so turn them off if you don't need them.")
            HStack {
                Button(serving ? "Stop Serving" : "Start Serving") { toggleServing() }.buttonStyle(serving ? .juice : .juicePrimary)
                Badge(text: serving ? "On, this Mac only" : "Off", tone: serving ? .good : .neutral)
                Spacer()
            }
            Hint("Leaf Juice only listens on this Mac. Getting it to players needs HTTPS that ends on this Mac, set up in Caddy with a tunnel. See the README.")
            mapSection
            if let web = server.linksWeb, !web.signedIn.isEmpty {
                Text("Signed in now").font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
                ForEach(web.signedIn) { session in
                    HStack {
                        Text(session.name).foregroundStyle(Juice.ink)
                        Hint("Until \(session.expires.formatted(date: .omitted, time: .shortened))")
                        Spacer()
                        Button("Sign Out") {
                            web.signOut(uuid: session.uuid)
                            reload()
                        }
                        .buttonStyle(.juice)
                        .accessibilityLabel("Sign out \(session.name)")
                    }
                }
            }
            if !log.isEmpty {
                Text("Recent sign-ins").font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
                ForEach(log) { event in
                    Hint("\(event.date.formatted(date: .abbreviated, time: .shortened)): \(event.name), \(event.kind.title)")
                }
                Hint("Keeps the account, the time and what happened, for 30 days. No addresses or browsing.")
            }
        }
    }

    @ViewBuilder private var mapSection: some View {
        let hasBlueMap = server.plugins.contains { $0.key == "bluemap" }
        Divider()
        Toggle("Put BlueMap's web map behind this sign-in, at /map/", isOn: Binding(get: { pageSettings.map?.on == true }, set: { on in
            var map = pageSettings.map ?? MapGatewaySettings()
            map.on = on
            pageSettings.map = map
            server.forgetMapAccess()
            savePage()
        }))
        .disabled(!hasBlueMap)
        if !hasBlueMap { Hint("BlueMap isn't on this server.") }
        if hasBlueMap {
            let blueMap = server.blueMapServer
            Hint("A player sees a world's map only if Multiverse lets them enter that world. Checked every few minutes, and anything that can't be read shows no maps.")
            switch server.multiverseEnforcesAccess {
            case .some(true): Hint("Multiverse enforces world access, so each world is checked against multiverse.access.<world>.")
            case .some(false): Callout(tone: .warning, title: "Multiverse lets everyone into every world", detail: "enforce-access is off, so everyone signed in sees every map.")
            case .none: Callout(tone: .warning, title: "Multiverse's enforce-access can't be read", detail: "Until it can, nobody sees any maps.")
            }
            if pageSettings.map?.on == true, !blueMap.onlyThisMac {
                Callout(tone: .warning, title: "The map is still open directly", detail: "BlueMap listens on \(blueMap.ip), port \(blueMap.port), so anyone who can reach that port skips the sign-in. Set ip: \"127.0.0.1\" in BlueMap's webserver.conf to close it.")
            }
            if let note = server.mapAccessNote { Hint("Last time someone saw no maps: \(note)") }
        }
    }

    private func toggleServing() {
        if serving {
            server.stopLinksPage()
            pageSettings.on = false
        } else {
            do {
                try server.startLinksPage()
                pageSettings.on = true
            } catch {
                server.linksPageError = error.localizedDescription
                pageSettings.on = false
            }
        }
        savePage()
        reload()
    }

    private func refresh(all: Bool) {
        refreshing = true
        Task {
            defer { refreshing = false }
            do {
                try await server.refreshModrinthLinks(all: all)
                error = nil
            } catch let failure {
                error = failure.localizedDescription
            }
            reload()
        }
    }

    private func search(_ row: PluginLinkRow) {
        guard let plugin = server.plugins.first(where: { $0.key == row.key }) else { return }
        searching = row.key
        Task {
            searched[row.key] = await PluginLinks.searchByName(plugin)
            searching = nil
        }
    }
}

private struct LinkEditor: View {
    let row: PluginLinkRow
    let server: ServerController
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Link for \(row.name)").font(.title2.weight(.semibold)).foregroundStyle(Juice.ink)
            TextField("Web address", text: $text, prompt: Text("https://example.com/docs"))
                .textFieldStyle(.roundedBorder)
            if invalid { Callout(tone: .danger, title: "That isn't a web address", detail: "It needs to start with https:// or http://.") }
            if server.pluginLinkStore.chosen[row.key] != nil {
                Hint("Removing your choice goes back to the plugin's known source, if it has one.")
            }
            HStack {
                if server.pluginLinkStore.chosen[row.key] != nil {
                    Button("Remove My Choice") {
                        server.clearChosenLink(forPlugin: row.key)
                        changed()
                        dismiss()
                    }
                    .buttonStyle(.juice)
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.juice).keyboardShortcut(.cancelAction)
                Button("Save") {
                    if server.chooseLink(text, origin: .typed, forPlugin: row.key) {
                        changed()
                        dismiss()
                    } else {
                        invalid = true
                    }
                }
                .buttonStyle(.juicePrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { text = row.link?.url ?? "" }
    }
}
