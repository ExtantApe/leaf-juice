import AppKit
import LeafJuiceCore
import SwiftUI

/// Each recipe's own address and hash, and the small web server behind them.
struct PackHostingCard: View {
    let server: ServerController
    let recipeNames: [String]
    let live: ResourcePacks.ServerPack
    let changed: () -> Void

    @State private var address = ""
    @State private var port = 8766
    @State private var error: String?
    @State private var results: [String: PackURLCheck] = [:]
    @State private var checking: String?
    @State private var replacing: String?
    @State private var elsewhere: String?
    @State private var elsewhereText = ""
    @State private var refresh = 0

    private var settings: PackHostSettings { server.packHostSettings }
    private var built: [String] { recipeNames.filter { !ResourcePacks.history($0).isEmpty } }

    var body: some View {
        Card(title: "Hosting", systemImage: "antenna.radiowaves.left.and.right") {
            if let error { Callout(tone: .danger, title: error) }
            if let problem = server.packHostError { Callout(tone: .danger, title: "Serving stopped", detail: problem) }
            if server.hasPackButler {
                Callout(tone: .info, title: "Resource Pack Butler is on this server", detail: "It sends the pack for each world, so Leaf Juice won't change this server's pack settings. Give Butler each recipe's address and SHA-1 from here.")
                if live.isSet { Callout(tone: .warning, title: "server.properties still sets a pack", detail: "Butler's brief says this should be empty. Clear it on the Configs page if Butler is meant to send every pack.") }
            }
            serving
            if built.isEmpty {
                Hint("Build a recipe, and its address shows here.")
            } else {
                ForEach(built, id: \.self) { name in
                    Divider()
                    row(name)
                }
            }
        }
        .id(refresh)
        .onAppear {
            address = settings.address
            port = settings.port
        }
        .confirmationDialog("Replace this address?", isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } })) {
            Button("Replace", role: .destructive) {
                if let name = replacing { server.newPackPath(recipe: name) }
                results = [:]
                reload()
            }
        } message: {
            Text("The old address stops working straight away. Anything using it, including this server or Butler, needs the new one, or players can't load the pack.")
        }
    }

    private var serving: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Address", text: $address, prompt: Text("https://packs.example.net"))
                    .accessibilityLabel("Address players reach this Mac at")
                TextField("Port", value: $port, format: .number.grouping(.never)).frame(width: 70).accessibilityLabel("Port on this Mac")
                if server.packHostIsListening {
                    Badge(text: "Serving", tone: .good)
                    Button("Save") { saveAddress() }.buttonStyle(.juice)
                    Button("Stop") {
                        server.stopPackHost()
                        reload()
                    }
                    .buttonStyle(.juice)
                } else {
                    Button("Start Serving") { start() }.buttonStyle(.juicePrimary)
                }
            }
            if PackHosting.isOnlyThisMac(settings.address) { Hint("This address only works on this Mac, so it's good for testing and no use to players.") }
            Hint("Leaf Juice listens on this Mac only, so something like Caddy has to carry it through your tunnel. Use a different hostname from any sign-in page.")
            Hint("The game can't sign in, so a long random path is all that hides a pack, and every player's game is given it. It runs only while Leaf Juice is open, uses your upload speed, and keeps no record of who downloads.")
        }
    }

    private func row(_ name: String) -> some View {
        let url = server.packAddress(recipe: name)
        let isElsewhere = settings.recipes[ResourcePacks.slug(name)]?.elsewhere != nil
        let newest = ResourcePacks.history(name).first?.sha1
        let sha1 = isElsewhere ? newest : server.servedPackSHA1(recipe: name)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(name).font(.body.weight(.semibold)).foregroundStyle(Juice.ink)
                if isElsewhere { Badge(text: "Hosted elsewhere", tone: .info) }
                Spacer()
            }
            Fact(label: "Address", value: url ?? "Enter an address above")
            Fact(label: "SHA-1", value: sha1 ?? (isElsewhere ? "Build it first" : "Nothing served yet"))
            if let result = results[name] { Callout(tone: result.ok ? .good : .danger, title: result.summary) }
            HStack {
                Button("Copy Address") { copy(url) }.buttonStyle(.juice).disabled(url == nil)
                Button("Copy SHA-1") { copy(sha1) }.buttonStyle(.juice).disabled(sha1 == nil)
                Button(checking == name ? "Checking…" : "Check") { check(name, url: url, sha1: sha1) }
                    .buttonStyle(.juice).disabled(url == nil || sha1 == nil || checking != nil)
                    .help("Downloads it from the address, as a player's game would, and compares its SHA-1.")
                Button("Host Elsewhere…") {
                    elsewhereText = settings.recipes[ResourcePacks.slug(name)]?.elsewhere ?? ""
                    elsewhere = name
                }
                .buttonStyle(.juice)
                if !isElsewhere {
                    Button("New Address…") { replacing = name }.buttonStyle(.juice).accessibilityLabel("Replace the address for \(name)")
                }
            }
            if elsewhere == name {
                HStack {
                    TextField("Full address", text: $elsewhereText, prompt: Text("https://download.mc-packs.net/pack/….zip"))
                        .accessibilityLabel("Full address of this pack on another host")
                    Button("Save") {
                        do {
                            try server.setPackElsewhere(elsewhereText, recipe: name)
                            elsewhere = nil
                            results[name] = nil
                            reload()
                        } catch { self.error = error.localizedDescription }
                    }
                    .buttonStyle(.juice)
                    Button("Cancel") { elsewhere = nil }.buttonStyle(.juice)
                }
                Hint("Leave it empty to serve it from here again.")
            }
        }
    }

    private func reload() {
        refresh += 1
        changed()
    }

    private func saveAddress() {
        do {
            let restart = server.packHostIsListening && port != settings.port
            try server.setPackHost(address: address, port: port)
            address = settings.address
            if restart { try server.startPackHost() }
            error = nil
            reload()
        } catch { self.error = error.localizedDescription }
    }

    private func start() {
        do {
            try server.setPackHost(address: address, port: port)
            address = settings.address
            try server.startPackHost()
            error = nil
            Task {
                // The listener takes a moment to come up, or to report that the port is taken.
                try? await Task.sleep(for: .milliseconds(400))
                reload()
            }
        } catch { self.error = error.localizedDescription }
    }

    private func check(_ name: String, url: String?, sha1: String?) {
        guard let url, let sha1 else { return }
        checking = name
        Task {
            results[name] = await PackHosting.check(url: url, expected: sha1)
            checking = nil
        }
    }

    private func copy(_ text: String?) {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
