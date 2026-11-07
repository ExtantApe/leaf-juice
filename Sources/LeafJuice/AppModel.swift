import AppKit
import LeafJuiceCore
import Observation
import SwiftUI
import UserNotifications

enum PageID: String, CaseIterable, Identifiable, Hashable {
    case overview, console, history, players, worlds, plugins, software, configs, resourcePacks, links, launch, backups, changes, cleanup
    var id: String { rawValue }
    /// The module a page belongs to. Nil for the essentials, which are always there.
    var module: LeafModule? {
        switch self {
        case .worlds: .worlds
        case .players: .players
        case .history: .history
        case .cleanup: .cleanup
        case .resourcePacks: .resourcePacks
        case .links: .links
        default: nil
        }
    }
    @MainActor static var visible: [PageID] { allCases.filter { $0.module.map(Modules.shared.isOn) ?? true } }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .console: "Console"
        case .history: "History"
        case .players: "Players"
        case .worlds: "Worlds"
        case .cleanup: "Cleanup"
        case .plugins: "Plugins"
        case .resourcePacks: "Resource Packs"
        case .links: "Plugin Links"
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
        case .history: "chart.xyaxis.line"
        case .players: "person.2"
        case .worlds: "globe.americas"
        case .cleanup: "sparkles"
        case .plugins: "puzzlepiece.extension"
        case .resourcePacks: "photo.stack"
        case .links: "link"
        case .software: "shippingbox"
        case .configs: "slider.horizontal.3"
        case .launch: "bolt"
        case .backups: "externaldrive"
        case .changes: "clock.arrow.2.circlepath"
        }
    }
}

struct LabSetupRequest: Identifiable {
    let id = UUID()
    let then: @MainActor () -> Void
}

/// The list of servers and app-wide state.
@MainActor @Observable
final class AppModel {
    private(set) var servers: [ServerController] = []
    let lab: LabController
    /// Asks for the EULA before something that needs the Lab, then carries on with it.
    var labSetup: LabSetupRequest?
    var selectedID: UUID? { didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: "selectedServer") } }
    var page: PageID = .overview
    var showIssues = UserDefaults.standard.object(forKey: "showIssues") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showIssues, forKey: "showIssues") }
    }
    var showAddServer = false
    /// The file open on the Configs page, so other pages can jump to one.
    var configPath: String?
    var showFolderSetup = AppPaths.needsServersFolderChoice
    var appUpdate: (version: String, url: URL)?
    var checkAppUpdates = UserDefaults.standard.object(forKey: "checkAppUpdates") as? Bool ?? true {
        didSet { UserDefaults.standard.set(checkAppUpdates, forKey: "checkAppUpdates") }
    }

    var selected: ServerController? { listed.first { $0.id == selectedID } ?? listed.first }
    /// The Lab stays on disk when its module is off, but isn't shown.
    var listed: [ServerController] { Modules.shared.isOn(.lab) ? servers : servers.filter { !$0.isLab } }
    /// The page to show, in case the one asked for belongs to a module that's off.
    var visiblePage: PageID { page.module.map(Modules.shared.isOn) ?? true ? page : .overview }
    var anyLive: Bool { servers.contains { $0.state.isLive || $0.trialIsLive } }

    init() {
        let paths: [String] = JSONStore.load(AppPaths.registry, defaults: [])
        var opened = paths.compactMap { ServerController.open(root: URL(fileURLWithPath: $0, isDirectory: true)) }
        let lab = LabController(existing: opened.first(where: \.isLab))
        self.lab = lab
        if let found = lab.server, !opened.contains(where: { $0.id == found.id }) { opened.append(found) }
        servers = opened
        selectedID = UserDefaults.standard.string(forKey: "selectedServer").flatMap(UUID.init) ?? servers.first?.id
        for server in servers where server.profile.launch.startWithApp {
            Task { await server.start() }
        }
        // Its own switch, off until someone turns it on. A snapshot only draws screens.
        if ProcessInfo.processInfo.environment["LEAFJUICE_SNAPSHOT"] == nil {
            servers.forEach { $0.tidySignInLog() }
            for server in servers where server.linksPageSettings.on && !server.isLab {
                do { try server.startLinksPage() } catch { server.linksPageError = error.localizedDescription }
            }
        }
        servers.forEach(Alerts.connect)
        Alerts.ask()
        if checkAppUpdates { Task { await lookForAppUpdate() } }
        // A wipe or restore makes a new controller for the Lab's folder.
        lab.onServerChanged = { [weak self] old, new in
            guard let self else { return }
            let wasSelected = self.selectedID == old?.id
            self.servers.removeAll { $0.id == old?.id || $0.id == new?.id }
            if let new { self.servers.append(new) }
            if wasSelected || self.selectedID == nil { self.selectedID = new?.id }
            self.saveRegistry()
        }
    }

    /// Runs something that needs the Lab, asking for the EULA first if it hasn't been accepted.
    func withLab(_ work: @escaping @MainActor () -> Void) {
        if lab.eulaAccepted { work() } else { labSetup = LabSetupRequest(then: work) }
    }

    /// The board lives on the Lab's Overview. If there's no Lab yet, it's made first.
    func openLabBoard() {
        if let found = lab.server {
            selectedID = found.id
            page = .overview
        } else {
            setUpLab()
        }
    }

    func setUpLab() {
        withLab { [self] in
            Task {
                if let real = lab.model(from: servers) { await lab.setUp(modeledOn: real) } else { await lab.setUpWithDefaults() }
                if let found = lab.server { selectedID = found.id; page = .overview }
            }
        }
    }

    private func saveRegistry() {
        try? JSONStore.save(servers.map(\.paths.root.path), to: AppPaths.registry)
    }

    func add(_ controller: ServerController) {
        Alerts.connect(controller)
        if !servers.contains(where: { $0.id == controller.id }) { servers.append(controller) }
        selectedID = controller.id
        page = .overview
        saveRegistry()
    }

    /// Forgets a server. Its folder stays exactly where it is.
    func remove(_ controller: ServerController) {
        guard !controller.isLab else { return }
        controller.stopTicker()
        servers.removeAll { $0.id == controller.id }
        if selectedID == controller.id { selectedID = servers.first?.id }
        saveRegistry()
    }

    func pathsChanged() { saveRegistry() }

    func stopAll() async {
        for server in servers {
            server.stopTrialCopy()
            if server.isLab, lab.isBusy { server.forceStop() }
            if server.state.isLive { server.stop() }
        }
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

/// Tells you when something goes wrong and Leaf Juice isn't in front of you.
@MainActor enum Alerts {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "macAlerts") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "macAlerts") }
    }

    static func connect(_ server: ServerController) {
        server.onAlert = { title, detail in show(title, detail) }
    }

    static func ask() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func show(_ title: String, _ detail: String) {
        guard enabled, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = detail
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    #if DEBUG
    /// Debug builds only: draws every page of every listed server to images, off screen, then quits.
    /// `LEAFJUICE_SNAPSHOT=<folder>`, for checking screens nobody has clicked yet. Starts nothing.
    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        guard let folder = ProcessInfo.processInfo.environment["LEAFJUICE_SNAPSHOT"], let model = Self.model else { return }
        NSApp.setActivationPolicy(.accessory)
        NSApp.windows.forEach { $0.close() }
        Task { @MainActor in
            model.showFolderSetup = false
            try? FileOps.ensureDir(URL(fileURLWithPath: folder))
            var windows: [NSWindow] = []   // Kept until the end: closing them while SwiftUI settles isn't safe.
            for server in model.servers where ProcessInfo.processInfo.environment["LEAFJUICE_SNAPSHOT_DIALOGS_ONLY"] == nil {
                for page in PageID.allCases {
                    model.selectedID = server.id
                    model.page = page
                    let host = NSHostingView(rootView: RootView(model: model).tint(Juice.pulp))
                    if ProcessInfo.processInfo.environment["LEAFJUICE_SNAPSHOT_LIGHT"] != nil { host.appearance = NSAppearance(named: .aqua) }
                    let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1280, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    window.orderBack(nil)
                    try? await Task.sleep(for: .seconds(page == .overview ? 5 : page == .resourcePacks ? 12 : 2.5))
                    host.layoutSubtreeIfNeeded()
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        let name = "\(server.profile.name.replacingOccurrences(of: " ", with: "-"))-\(page.rawValue).png"
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
                    }
                    window.orderOut(nil)
                    windows.append(window)
                }
            }
            // The dialogs too, which otherwise only appear after a click.
            if let server = model.servers.first(where: { !$0.isLab }) {
                let build = PackVersion(file: "new.zip", version: "2.0", sha1: "abc", added: Date(), size: 1000, format: 75, description: "", fileCount: 3, imageCount: 1)
                let pack = LibraryPack(id: "zig-zag", title: "Zig Zag", license: PackLicense(id: "LicenseRef-All-Rights-Reserved"), authors: ["Jamizzle"], versions: [build])
                var changes = PackChanges()
                changes.changed = [.init(path: "assets/minecraft/textures/block/stone.png", detail: "zig-zag updated it")]
                changes.added = [.init(path: "assets/minecraft/textures/block/pale_oak_planks.png", detail: "From zig-zag")]
                changes.hidden = [.init(path: "assets/minecraft/items/bricks.json", detail: "zig-zag changed, but tardis-resource-pack still wins")]
                changes.lostPicks = ["assets/minecraft/textures/block/old.png"]
                let recipe = ResourcePacks.loadRecipe(ResourcePacks.recipeNames().first ?? "combined")
                let dialogs: [(String, AnyView)] = [
                    ("settings", AnyView(SettingsView(model: model))),
                    ("lab-setup", AnyView(LabSetupSheet(model: model, then: {}))),
                    ("share", AnyView(ShareSheet(recipe: recipe, history: []))),
                    ("update-review", AnyView(UpdateReviewSheet(pending: .init(pack: pack, version: build, changes: changes), onAccept: {}, onCancel: {}))),
                    ("servers-folder", AnyView(ServersFolderSheet())),
                    ("add-server", AnyView(AddServerSheet(model: model))),
                    ("rename", AnyView(RenameSheet(model: model, server: server))),
                    ("server-rename", AnyView(ServerRenameSheet(model: model, server: server, onDone: {}))),
                    ("add-plugin", AnyView(AddPluginSheet(server: server))),
                    ("welcome", AnyView(WelcomeView(model: model).frame(width: 1000, height: 700))),
                ]
                for (name, view) in dialogs {
                    let host = NSHostingView(rootView: view.tint(Juice.pulp).background(Juice.background))
                    if ProcessInfo.processInfo.environment["LEAFJUICE_SNAPSHOT_LIGHT"] != nil { host.appearance = NSAppearance(named: .aqua) }
                    let size = host.fittingSize
                    host.frame = NSRect(origin: .zero, size: NSSize(width: max(size.width, 320), height: max(min(size.height, 1100), 200)))
                    let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: host.frame.width, height: host.frame.height), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    window.orderBack(nil)
                    try? await Task.sleep(for: .seconds(2))
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("dialog-\(name).png"))
                    }
                    window.orderOut(nil)
                    windows.append(window)
                }
            }
            exit(0)
        }
    }
    #endif

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
            ForEach(Array(PageID.visible.prefix(9).enumerated()), id: \.element) { index, page in
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
        ForEach(model.listed) { server in
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
            Toggle("Notify me about crashes, failed backups and low disk space", isOn: Binding(get: { Alerts.enabled }, set: { Alerts.enabled = $0 }))
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
            Section {
                ForEach(LeafModule.allCases) { module in
                    Toggle(isOn: Binding(get: { Modules.shared.isOn(module) }, set: { Modules.shared.set(module, on: $0) })) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(module.title).foregroundStyle(Juice.ink)
                                Text(module.summary).font(.caption).foregroundStyle(Juice.muted)
                            }
                        } icon: {
                            Image(systemName: module.icon).foregroundStyle(Juice.pulp)
                        }
                    }
                }
            } header: {
                Text("Features")
            } footer: {
                Text("Turning one off hides it and stops its background work. Nothing it has saved is deleted, and turning it back on picks up where it left off.")
                    .font(.caption).foregroundStyle(Juice.muted)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
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
