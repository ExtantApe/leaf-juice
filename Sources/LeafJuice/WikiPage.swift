import AppKit
import LeafJuiceCore
import SwiftUI
import WebKit

/// Shows a generated page inside the app. Links to other sites open in the browser.
struct WikiPreview: NSViewRepresentable {
    let html: String

    final class Coordinator: NSObject, WKNavigationDelegate {
        var shown = ""
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    /// Only when it really changed, so redrawing the app doesn't reload the page and lose your place.
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.shown != html else { return }
        context.coordinator.shown = html
        view.loadHTMLString(html, baseURL: nil)
    }
}

/// A wiki generated from what's installed, with your own words kept separately.
struct WikiPage: View {
    @Bindable var server: ServerController
    @State private var settings = WikiSettings()
    @State private var content: WikiContent?
    @State private var working = false
    @State private var error: String?

    @State private var audience = 0

    @State private var previewHTML = ""

    private func rebuildPreview() {
        guard var current = content else { return }
        current.settings = settings
        let name = current.serverName
        previewHTML = Wiki.html(current, admin: audience == 1) { plugin in
            try? String(contentsOf: Wiki.notesFile(name, plugin: plugin), encoding: .utf8)
        }
    }

    var body: some View {
        Page(title: "Wiki", subtitle: "Pages for your players, generated from this server's plugins, ranks and worlds.") {
            if let error { Callout(tone: .danger, title: error) }
            HStack {
                Picker("View", selection: $audience) {
                    Text("Player view").tag(0)
                    Text("Admin view").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
                Button(working ? "Updating…" : "Update") { update() }.buttonStyle(.juicePrimary).disabled(working)
                Spacer()
                Button("Export…") { export() }.buttonStyle(.juice).disabled(content == nil)
            }
            if audience == 1 { Hint("The admin view lists permissions, so keep any export of it private.") }
            WikiPreview(html: previewHTML)
                .frame(minHeight: 460)
                .clipShape(RoundedRectangle(cornerRadius: Juice.cardRadius))
                .overlay { RoundedRectangle(cornerRadius: Juice.cardRadius).strokeBorder(Juice.border, lineWidth: 1) }
                .accessibilityLabel("Wiki preview")
            wordsCard
            if let content { includedCard(content) }
            Hint("It never includes plugin settings, player names, operators, passwords or secrets.")
        }
        .task(id: server.id) {
            settings = Wiki.loadSettings(server.profile.name)
            await preview()
        }
        .onChange(of: audience) { rebuildPreview() }
        .onChange(of: content) { rebuildPreview() }
        // Typing shouldn't rebuild the page on every key.
        .task(id: settings) {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { rebuildPreview() }
        }
    }

    private var wordsCard: some View {
        Card(title: "Your words", systemImage: "pencil") {
            TextField("Server address", text: $settings.address, prompt: Text("play.example.com")).onChange(of: settings.address) { saveSettings() }
            Text("Welcome").font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
            editor($settings.welcome, label: "Welcome text")
            Text("Rules").font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
            editor($settings.rules, label: "Rules")
            Toggle("List commands whose plugin doesn't say who can use them", isOn: $settings.showUnconfirmed)
                .toggleStyle(.checkbox).onChange(of: settings.showUnconfirmed) { saveSettings() }
            Hint("Off by default, because they may be staff commands. Your words are kept when the wiki updates. For notes on one plugin, put a text file named after it in the notes folder.")
        }
    }

    private func editor(_ text: Binding<String>, label: String) -> some View {
        TextEditor(text: text)
            .font(.body).frame(minHeight: 70).scrollContentBackground(.hidden).padding(6)
            .background(Juice.background, in: RoundedRectangle(cornerRadius: Juice.controlRadius))
            .overlay { RoundedRectangle(cornerRadius: Juice.controlRadius).strokeBorder(Juice.border, lineWidth: 1) }
            .accessibilityLabel(label)
            .onChange(of: text.wrappedValue) { saveSettings() }
    }

    private func includedCard(_ content: WikiContent) -> some View {
        Card(title: "What's in it", systemImage: "list.bullet") {
            Fact(label: "Commands for players", value: "\(content.publicCommandCount) of \(content.commandCount)")
            Fact(label: "Worlds", value: "\(content.worlds.filter { !$0.hidden }.count)")
            if content.ranksKnown {
                Fact(label: "Ranks", value: "\(content.ranks.count)")
                if let date = server.wikiRanksDate { Hint("Ranks last read \(date.formatted(.relative(presentation: .named))).") }
            } else if server.plugins.contains(where: { $0.key == "luckperms" }) {
                Callout(tone: .info, title: "Ranks aren't included yet", detail: "LuckPerms is asked for them while the server runs, so press Update once with the server running.")
            }
            Text("Plugins in the player wiki").font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(content.plugins.filter { !$0.entries.isEmpty }) { plugin in
                    Toggle(isOn: Binding(get: { !settings.hiddenPlugins.contains(plugin.manual.name) }, set: { on in
                        if on { settings.hiddenPlugins.remove(plugin.manual.name) } else { settings.hiddenPlugins.insert(plugin.manual.name) }
                        saveSettings()
                    })) {
                        Text("\(plugin.manual.name) (\(plugin.entries.filter(\.who.isPublic).count))").foregroundStyle(Juice.ink).lineLimit(1)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            Hint("The number is how many of its commands players can use.")
        }
    }

    private func saveSettings() { Wiki.saveSettings(settings, server.profile.name) }

    private func preview() async { content = await server.wikiContent(settings: settings) }

    /// Reads the server again, asking LuckPerms for its ranks if it's running.
    private func update() {
        working = true
        error = nil
        Task {
            await server.refreshWikiRanks()
            content = await server.wikiContent(settings: settings)
            working = false
        }
    }

    /// Only here do files get written: both views, as web pages and Markdown.
    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder. A player folder and an admin folder go inside it."
        guard panel.runModal() == .OK, let folder = panel.url, var current = content else { return }
        current.settings = settings
        do { try Wiki.write(current, to: folder) } catch { self.error = error.localizedDescription }
    }
}
