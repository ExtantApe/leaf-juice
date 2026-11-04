import AppKit
import LeafJuiceCore
import Observation
import SwiftUI

enum PageID: String, CaseIterable, Identifiable, Hashable {
    case overview, console, worlds, plugins, software, configs, launch, backups, changes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .console: "Console"
        case .worlds: "Worlds"
        case .plugins: "Plugins"
        case .software: "Software"
        case .configs: "Configs"
        case .launch: "Launch"
        case .backups: "Backups"
        case .changes: "Changes"
        }
    }
    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .console: "terminal"
        case .worlds: "globe.americas"
        case .plugins: "puzzlepiece.extension"
        case .software: "shippingbox"
        case .configs: "slider.horizontal.3"
        case .launch: "bolt"
        case .backups: "externaldrive"
        case .changes: "clock.arrow.2.circlepath"
        }
    }
}

/// The list of servers and app-wide state.
@MainActor @Observable
final class AppModel {
    private(set) var servers: [ServerController] = []
    var selectedID: UUID? { didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: "selectedServer") } }
    var page: PageID = .overview
    var showIssues = UserDefaults.standard.object(forKey: "showIssues") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showIssues, forKey: "showIssues") }
    }
    var showAddServer = false
    var showFolderSetup = AppPaths.needsServersFolderChoice
    var appUpdate: (version: String, url: URL)?
    var checkAppUpdates = UserDefaults.standard.object(forKey: "checkAppUpdates") as? Bool ?? true {
        didSet { UserDefaults.standard.set(checkAppUpdates, forKey: "checkAppUpdates") }
    }

    var selected: ServerController? { servers.first { $0.id == selectedID } ?? servers.first }
    var anyLive: Bool { servers.contains { $0.state.isLive } }

    init() {
        let paths: [String] = JSONStore.load(AppPaths.registry, defaults: [])
        servers = paths.compactMap { ServerController.open(root: URL(fileURLWithPath: $0, isDirectory: true)) }
        selectedID = UserDefaults.standard.string(forKey: "selectedServer").flatMap(UUID.init) ?? servers.first?.id
        for server in servers where server.profile.launch.startWithApp {
            Task { await server.start() }
        }
        if checkAppUpdates { Task { await lookForAppUpdate() } }
    }

    private func saveRegistry() {
        try? JSONStore.save(servers.map(\.paths.root.path), to: AppPaths.registry)
    }

    func add(_ controller: ServerController) {
        if !servers.contains(where: { $0.id == controller.id }) { servers.append(controller) }
        selectedID = controller.id
        page = .overview
        saveRegistry()
    }

    /// Forgets a server. Its folder stays exactly where it is.
    func remove(_ controller: ServerController) {
        controller.stopTicker()
        servers.removeAll { $0.id == controller.id }
        if selectedID == controller.id { selectedID = servers.first?.id }
        saveRegistry()
    }

    func pathsChanged() { saveRegistry() }

    func stopAll() async {
        for server in servers where server.state.isLive { server.stop() }
        for _ in 0..<(180 * 4) where anyLive { try? await Task.sleep(for: .milliseconds(250)) }
    }

    /// Unsigned apps can't update themselves safely, so this only tells you where the new build is.
    func lookForAppUpdate() async {
        struct Release: Decodable { let tag_name: String; let html_url: String }
        guard let url = URL(string: "https://api.github.com/repos/\(LeafJuice.repository)/releases/latest"),
              let release = try? await HTTP.decode(Release.self, url),
              let latest = LooseVersion(release.tag_name), let current = LooseVersion(LeafJuice.version),
              latest > current, let page = URL(string: release.html_url) else { return }
        appUpdate = (release.tag_name, page)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A running server must get the chance to save before the app goes away.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, model.anyLive else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Stop running servers and quit?"
        alert.informativeText = "Players will be disconnected and worlds saved first. This can take a moment."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task { @MainActor in
            await model.stopAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct LeafJuiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    @AppStorage("appearance") private var appearance = "auto"

    init() {
        let model = AppModel()
        AppDelegate.model = model
        _model = State(initialValue: model)
    }

    private var scheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some Scene {
        Window("Leaf Juice", id: "main") {
            RootView(model: model)
                .frame(minWidth: 1120, minHeight: 640)
                .tint(Juice.pulp)
                .preferredColorScheme(scheme)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { ServerCommands(model: model) }

        Settings {
            SettingsView(model: model).tint(Juice.pulp).preferredColorScheme(scheme)
        }

        MenuBarExtra {
            StatusMenu(model: model)
        } label: {
            Image(systemName: model.anyLive ? "leaf.fill" : "leaf")
                .accessibilityLabel(model.anyLive ? "Leaf Juice, server running" : "Leaf Juice")
        }
    }
}

struct ServerCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Server…") { model.showAddServer = true }.keyboardShortcut("n")
        }
        CommandMenu("Server") {
            Button("Start") { if let s = model.selected { Task { await s.start() } } }
                .keyboardShortcut("r").disabled(model.selected?.state.canStart != true)
            Button("Stop") { model.selected?.stop() }
                .keyboardShortcut(".").disabled(model.selected?.state != .running && model.selected?.state != .starting)
            Button("Restart") { model.selected?.restart() }
                .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.selected?.state != .running)
            Divider()
            Button("Back Up Now") {
                if let s = model.selected { s.attempt { try await s.backupNow() } }
            }
            .keyboardShortcut("b", modifiers: [.command, .shift]).disabled(model.selected == nil)
        }
        CommandGroup(after: .sidebar) {
            Button(model.showIssues ? "Hide Issues" : "Show Issues") { model.showIssues.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            ForEach(Array(PageID.allCases.enumerated()), id: \.element) { index, page in
                Button(page.title) { model.page = page }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
            }
        }
    }
}

struct StatusMenu: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(model.servers) { server in
            Text("\(server.profile.name): \(server.state.title)")
            if server.state.canStart {
                Button("Start \(server.profile.name)") { Task { await server.start() } }
            } else if server.state == .running {
                Button("Stop \(server.profile.name)") { server.stop() }
            }
            Divider()
        }
        Button("Open Leaf Juice") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit") { NSApp.terminate(nil) }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var serversFolder = AppPaths.servers.path
    @AppStorage("appearance") private var appearance = "auto"
    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                Text("Match System").tag("auto")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            Toggle("Tell me when a new Leaf Juice is on GitHub", isOn: $model.checkAppUpdates)
            LabeledContent("Version", value: LeafJuice.version)
            LabeledContent("Servers folder") {
                HStack {
                    Text((serversFolder as NSString).abbreviatingWithTildeInPath).foregroundStyle(Juice.ink).lineLimit(1).truncationMode(.middle)
                    Button("Change…") { chooseServersFolder() }
                }
            }
            LabeledContent("Custom issue rules") {
                Button("Show Folder") {
                    try? FileOps.ensureDir(AppPaths.rules)
                    NSWorkspace.shared.open(AppPaths.rules)
                }
            }
            Hint("Add your own log rules as JSON files in that folder. See the README for the format.")
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 320)
    }

    private func chooseServersFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = AppPaths.servers
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            try? AppPaths.chooseServers(url)
            serversFolder = url.path
        }
    }
}
