import AppKit
import LeafJuiceCore
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        // Without the sheets: adding or setting up a server writes to its folder.
        if AdvisorTrial.isOn {
            AdvisorTrialView(model: model)
        } else {
            Group {
                if let server = model.selected {
                    ServerWindow(model: model, server: server).id(server.id)
                } else {
                    WelcomeView(model: model)
                }
            }
            .sheet(isPresented: $model.showAddServer) { AddServerSheet(model: model) }
            .sheet(item: $model.labSetup) { request in LabSetupSheet(model: model, then: request.then) }
            .sheet(isPresented: $model.showFolderSetup, onDismiss: offerServers) { ServersFolderSheet() }
        }
    }

    /// If the chosen folder already holds servers, go straight to picking from them. Nothing is imported until you do.
    private func offerServers() {
        guard !AppPaths.needsServersFolderChoice, model.servers.isEmpty,
              !ServerFolders.find(in: AppPaths.servers).isEmpty else { return }
        model.showAddServer = true
    }
}

// MARK: - First launch

struct ServersFolderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    private var home: URL { AppPaths.defaultServers }
    private var homeLabel: String { (home.path as NSString).abbreviatingWithTildeInPath }
    private var homeExists: Bool { FileOps.isDirectory(home) }
    private var found: Int { ServerFolders.find(in: home).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64).accessibilityHidden(true)
            Text("Where should your servers live?").font(.title2.weight(.semibold)).foregroundStyle(Juice.ink)
            Text(message).foregroundStyle(Juice.ink).fixedSize(horizontal: false, vertical: true)
            if let error { Callout(tone: .danger, title: error) }
            VStack(alignment: .leading, spacing: 8) {
                Button(homeExists ? "Use \(homeLabel)" : "Create \(homeLabel)") { use(home) }
                    .buttonStyle(.juicePrimary).keyboardShortcut(.defaultAction)
                Button("Choose a Different Location…") { pick(prompt: "Use This Folder", message: "Choose or create a folder for your servers.") }
                    .buttonStyle(.juice)
                if !homeExists {
                    Button("Use an Existing Minecraft Folder…") { pick(prompt: "Use This Folder", message: "Choose the folder that holds your server folders.") }
                        .buttonStyle(.juice)
                }
            }
            Hint("Each server gets its own folder inside. Choosing a folder doesn't import or change the servers in it, and you can change this later in Settings.")
            HStack {
                Spacer()
                Button("Not Now") { dismiss() }.buttonStyle(.juice).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var message: String {
        guard homeExists else { return "Leaf Juice keeps servers together in one folder. It can make one for you, or use a folder you already have." }
        switch found {
        case 0: return "You already have a \(homeLabel) folder. Leaf Juice can keep your servers there."
        case 1: return "You already have a \(homeLabel) folder, with what looks like 1 server in it."
        default: return "You already have a \(homeLabel) folder, with what look like \(found) servers in it."
        }
    }

    private func use(_ folder: URL) {
        do {
            try AppPaths.chooseServers(folder)
            dismiss()
        } catch { self.error = "Couldn't use that folder: \(error.localizedDescription)" }
    }

    private func pick(prompt: String, message: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        panel.message = message
        if panel.runModal() == .OK, let url = panel.url { use(url) }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    let model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96).accessibilityHidden(true)
            Text("Leaf Juice").font(.largeTitle.weight(.semibold)).foregroundStyle(Juice.ink)
            Text("A lean home for your Minecraft server.").foregroundStyle(Juice.muted)
            Button("Add a Server") { model.showAddServer = true }.buttonStyle(.juicePrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Juice.background)
    }
}

// MARK: - Main window

struct ServerWindow: View {
    @Bindable var model: AppModel
    let server: ServerController
    @State private var renaming = false

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model, server: server, renaming: $renaming)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                banners
                pageView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ActivityBar(server: server)
            }
            .background(Juice.background)
            .navigationTitle(server.profile.name)
            .navigationSubtitle(server.profile.software.label)
            .toolbar { ServerToolbar(model: model, server: server) }
            .toolbarBackground(Juice.background, for: .windowToolbar)
            .inspector(isPresented: $model.showIssues) {
                IssuesPanel(model: model, server: server)
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
            }
        }
        .sheet(isPresented: blockersShown) { BlockersSheet(model: model, server: server) }
        .sheet(isPresented: $renaming) { RenameSheet(model: model, server: server) }
    }

    private var blockersShown: Binding<Bool> {
        Binding(get: { !server.blockers.isEmpty }, set: { if !$0 { server.blockers = [] } })
    }

    @ViewBuilder private var banners: some View {
        VStack(spacing: 8) {
            if let warning = server.diskWarning { Callout(tone: .warning, title: warning) }
            TrialBanner(server: server)
            if let notice = server.notice {
                Callout(tone: .info, title: notice) {
                    Button("Dismiss") { server.notice = nil }.buttonStyle(.juice)
                }
            }
            if case let .external(pid) = server.state {
                Callout(tone: .warning, title: "This server is already running outside Leaf Juice", detail: "Process \(pid) is using this folder. Its console isn't available here. Stop it here to take over.") {
                    Button("Stop It") { Task { await server.stopExternalServer() } }.buttonStyle(.juice)
                }
            }
            if let update = model.appUpdate {
                Callout(tone: .info, title: "Leaf Juice \(update.version) is available") {
                    Link("Open on GitHub", destination: update.url).buttonStyle(.juice)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, server.notice == nil && model.appUpdate == nil && !isExternal && server.diskWarning == nil && server.trialPhase == nil ? 0 : 12)
    }

    private var isExternal: Bool {
        if case .external = server.state { return true }
        return false
    }

    @ViewBuilder private var pageView: some View {
        switch model.visiblePage {
        case .resourcePacks: ResourcePacksPage(server: server)
        case .links: LinksPage(server: server)
        case .advisor: AdvisorPage(model: model, server: server)
        case .overview: OverviewPage(model: model, server: server, renaming: $renaming)
        case .console: ConsolePage(server: server)
        case .history: HistoryPage(server: server)
        case .players: PlayersPage(server: server)
        case .allowlist: AllowlistPage(server: server)
        case .worlds: WorldsPage(model: model, server: server)
        case .cleanup: CleanupPage(server: server)
        case .plugins: PluginsPage(model: model, server: server)
        case .software: SoftwarePage(model: model, server: server)
        case .configs: ConfigsPage(model: model, server: server)
        case .launch: LaunchPage(server: server)
        case .backups: BackupsPage(server: server)
        case .changes: ChangesPage(server: server)
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Bindable var model: AppModel
    let server: ServerController
    @Binding var renaming: Bool

    var body: some View {
        List(selection: pageBinding) {
            ForEach(PageID.visible) { page in
                Label(page.title, systemImage: page.icon)
                    .badge(badge(for: page))
                    .tag(page)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Juice.raised)
        .safeAreaInset(edge: .top, spacing: 0) { switcher }
        .toolbarBackground(Juice.raised, for: .windowToolbar)
    }

    private var pageBinding: Binding<PageID?> {
        Binding(get: { model.visiblePage }, set: { if let p = $0 { model.page = p } })
    }

    private func badge(for page: PageID) -> Int {
        switch page {
        case .plugins: server.plugins.filter { server.record(for: $0).available != nil }.count
        case .software: server.softwareUpdate == nil ? 0 : 1
        case .changes: server.pending.count
        case .advisor: AdvisorCenter.shared.count(server)
        default: 0
        }
    }

    private var switcher: some View {
        Menu {
            ForEach(model.listed) { other in
                Button {
                    model.selectedID = other.id
                } label: {
                    if other.id == server.id { Label(other.profile.name, systemImage: "checkmark") } else if other.isLab { Label(other.profile.name, systemImage: "flask") } else { Text(other.profile.name) }
                }
            }
            Divider()
            Button("Add Server…") { model.showAddServer = true }
            if model.lab.server == nil, Modules.shared.isOn(.lab) {
                Button("Set Up the Lab…") { model.setUpLab() }.disabled(model.lab.isBusy)
            }
            if !server.isLab { Button("Rename \(server.profile.name)…") { renaming = true } }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: server.state.icon).foregroundStyle(server.state.tone.color).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(server.profile.name).font(.headline).foregroundStyle(Juice.ink).lineLimit(1)
                    Text(server.state.title).font(.caption).foregroundStyle(Juice.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(Juice.muted).accessibilityHidden(true)
            }
            .padding(8)
            .background(Juice.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: Juice.controlRadius))
            .overlay { RoundedRectangle(cornerRadius: Juice.controlRadius).strokeBorder(Juice.border, lineWidth: 1) }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityLabel("Server: \(server.profile.name), \(server.state.title). Switch server.")
    }
}

// MARK: - Toolbar

struct ServerToolbar: ToolbarContent {
    @Bindable var model: AppModel
    let server: ServerController

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if server.state.canStart {
                Button { Task { await server.start() } } label: { Label("Start", systemImage: "play.fill") }
                    .disabled(!server.canStartNow)
                    .help(server.busyWith.map { "Wait: \($0)…" } ?? "Start the server (⌘R)")
            } else {
                Button { server.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .disabled(server.state != .running && server.state != .starting)
                    .help("Stop the server (⌘.)")
            }
            Button { server.restart() } label: { Label("Restart", systemImage: "arrow.clockwise") }
                .disabled(server.state != .running)
                .help("Restart the server (⇧⌘R)")
            if server.state == .stopping {
                Button(role: .destructive) { server.forceStop() } label: { Label("Force Stop", systemImage: "bolt.slash.fill") }
                    .help("Stop immediately without waiting for a clean save")
            }
            Button { model.showIssues.toggle() } label: {
                Label("Issues", systemImage: openIssues > 0 ? "exclamationmark.bubble.fill" : "exclamationmark.bubble")
            }
            .help("Show or hide the Issues panel (⌥⌘I)")
            .accessibilityValue("\(openIssues) open")
        }
    }

    private var openIssues: Int { server.issues.filter { $0.status == .open }.count }
}

struct ActivityBar: View {
    let server: ServerController
    var body: some View {
        if let activity = server.activity {
            HStack(spacing: 10) {
                if let progress = server.activityProgress {
                    ProgressView(value: progress).frame(width: 140).accessibilityLabel(activity)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(activity).font(.callout).foregroundStyle(Juice.ink)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Juice.raised)
        }
    }
}

// MARK: - Before starting

struct BlockersSheet: View {
    let model: AppModel
    let server: ServerController
    @Environment(\.dismiss) private var dismiss
    @State private var acceptedEULA = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Before this server can start").font(.title2.weight(.semibold)).foregroundStyle(Juice.ink)
            ForEach(server.blockers) { blocker in
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(blocker.title).font(.headline).foregroundStyle(Juice.ink)
                        Text(blocker.detail).foregroundStyle(Juice.muted).fixedSize(horizontal: false, vertical: true)
                        fix(for: blocker)
                    }
                }
            }
            HStack {
                Button("Close") { server.blockers = [] }.buttonStyle(.juice).keyboardShortcut(.cancelAction)
                Spacer()
                Button(needsEULA ? "Accept and Start" : "Try Again") {
                    if needsEULA {
                        do { try EULA.accept(server.paths) } catch {
                            server.notice = error.localizedDescription
                            server.blockers = []
                            return
                        }
                    }
                    server.blockers = []
                    Task { await server.start() }
                }
                .buttonStyle(.juicePrimary)
                .disabled((needsEULA && !acceptedEULA) || !server.canStartNow)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var needsEULA: Bool { server.blockers.contains { $0.kind == .eula } }

    @ViewBuilder private func fix(for blocker: Blocker) -> some View {
        switch blocker.kind {
        case .eula:
            Link("Read the Minecraft EULA", destination: EULA.url)
            // Ticking this records nothing. Acceptance is only written by the button below.
            Toggle("I have read and agree to the Minecraft EULA", isOn: $acceptedEULA)
        case let .java(required):
            HStack {
                Button("Download Java \(required)") {
                    server.attempt { try await server.installJava(major: required) }
                }
                .buttonStyle(.juicePrimary).disabled(server.activity != nil)
                Button("Choose on Launch Page") { server.blockers = []; model.page = .launch }.buttonStyle(.juice)
            }
            Hint("Downloads Eclipse Temurin into Leaf Juice's own folder. Nothing else on your Mac changes.")
            if let activity = server.activity { Hint(activity) }
        case .noJar:
            Button("Open Software Page") { server.blockers = []; model.page = .software }.buttonStyle(.juice)
        case .portBusy:
            Button("Open Configs") { server.blockers = []; model.page = .configs }.buttonStyle(.juice)
        case .worldData:
            Button("Open Backups") { server.blockers = []; model.page = .backups }.buttonStyle(.juice)
        case .other:
            Button("Open Launch Page") { server.blockers = []; model.page = .launch }.buttonStyle(.juice)
        }
    }
}

// MARK: - Rename

struct RenameSheet: View {
    let model: AppModel
    let server: ServerController
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folder = ""
    @State private var message = ""
    @State private var originalMessage = ""
    @State private var error: String?
    @State private var deep = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Server").font(.title2.weight(.semibold)).foregroundStyle(Juice.ink)
            Form {
                TextField("Name in Leaf Juice", text: $name)
                TextField("Server message", text: $message)
                TextField("Folder name", text: $folder).disabled(!server.state.canStart)
            }
            .formStyle(.columns)
            if !server.state.canStart { Hint("Stop the server to rename its folder.") }
            Hint("The name is your label in Leaf Juice. The server message (motd) is what players see in their server list\(server.state.canStart ? "." : ", and a change to it applies at the next restart.")")
            if let error { Callout(tone: .danger, title: error) }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.juice).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename Everywhere…") { deep = true }.buttonStyle(.juice)
                    .help("Also updates the folder, start scripts and other places the name is used, with a preview first")
                Button("Rename") { rename() }.buttonStyle(.juicePrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .sheet(isPresented: $deep) { ServerRenameSheet(model: model, server: server, onDone: { dismiss() }) }
        .onAppear {
            name = server.profile.name
            folder = server.paths.root.lastPathComponent
            let file = server.configs.first { $0.path == "server.properties" } ?? ConfigCatalog.serverProperties
            originalMessage = PropertiesDocument(server.configText(file)).value("motd") ?? ""
            message = originalMessage
        }
    }

    private func rename() {
        do {
            let moved = try server.rename(to: name, moveFolderTo: server.state.canStart ? folder : nil)
            if moved != nil { model.pathsChanged() }
            if message != originalMessage { try server.setServerMessage(message) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Add a server

struct AddServerSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case existing = "Use an Existing Folder"
        case new = "Create a New Server"
        var id: String { rawValue }
    }
    @State private var mode: Mode = .existing
    @State private var folder: URL?
    @State private var found: [URL] = []
    @State private var name = ""
    @State private var flavor: Flavor = .paper
    @State private var versions: [String] = []
    @State private var version = ""
    @State private var includePrereleases = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Server").font(.title2.weight(.semibold)).foregroundStyle(Juice.ink)
            Picker("How", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            if mode == .existing, !available.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("In \(serversPath)").font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
                    ForEach(available, id: \.path) { candidate in
                        Button {
                            folder = candidate
                        } label: {
                            HStack {
                                Image(systemName: folder == candidate ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(Juice.pulp).accessibilityHidden(true)
                                Text(candidate.lastPathComponent).foregroundStyle(Juice.ink)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(folder == candidate ? .isSelected : [])
                    }
                }
            }

            HStack {
                Text(folderText)
                    .foregroundStyle(targetFolder == nil ? Juice.muted : Juice.ink).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(mode == .existing ? "Choose Another…" : "Change…") { chooseFolder() }.buttonStyle(.juice)
            }

            TextField("Name", text: $name, prompt: Text(folder?.lastPathComponent ?? "My Server"))
                .textFieldStyle(.roundedBorder)

            if mode == .existing {
                Hint("Leaf Juice reads what's there and detects the software, version and start script settings. Everything it adds goes in a .leafjuice folder inside; your server files aren't touched.")
            } else {
                newServerFields
            }

            if let error { Callout(tone: .danger, title: error) }

            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.juice).keyboardShortcut(.cancelAction)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Add Server") { add() }
                    .buttonStyle(.juicePrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(targetFolder == nil || working || (mode == .new && version.isEmpty && flavor != .custom))
            }
        }
        .padding(20)
        .frame(width: 560)
        .task(id: "\(flavor.rawValue)\(mode)") { await loadVersions() }
        .onAppear { found = ServerFolders.find(in: AppPaths.servers) }
        .onChange(of: mode) { folder = nil }
    }

    private var serversPath: String { (AppPaths.servers.path as NSString).abbreviatingWithTildeInPath }

    /// Servers in the servers folder that aren't already in Leaf Juice.
    private var available: [URL] {
        let known = Set(model.servers.map { $0.paths.root.standardizedFileURL.path })
        return found.filter { !known.contains($0.standardizedFileURL.path) }
    }

    /// New servers go in the servers folder, named after the server, unless another folder was chosen.
    private var targetFolder: URL? {
        if let folder { return folder }
        guard mode == .new, let folderName = ServerFolders.folderName(for: name) else { return nil }
        return AppPaths.servers.appendingPathComponent(folderName, isDirectory: true)
    }

    private var folderText: String {
        if let target = targetFolder { return (target.path as NSString).abbreviatingWithTildeInPath }
        return mode == .existing ? "Pick a server, or choose its folder" : "Name the server to create its folder in \(serversPath)"
    }

    private var shownVersions: [String] {
        includePrereleases ? versions : versions.filter { GameVersion($0)?.isStableRelease ?? false }
    }

    @ViewBuilder private var newServerFields: some View {
        Picker("Software", selection: $flavor) {
            ForEach(Flavor.allCases) { Text($0.title).tag($0) }
        }
        Hint(flavor.blurb)
        if flavor.canDownload {
            Picker("Minecraft version", selection: $version) {
                ForEach(shownVersions, id: \.self) { Text($0).tag($0) }
            }
            .disabled(versions.isEmpty)
            Toggle("Show pre-releases", isOn: $includePrereleases)
        } else {
            Hint("Put your jar in the folder, then pick it on the Software page.")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        // Only open there if it exists: it may not yet on a new setup.
        if FileOps.isDirectory(AppPaths.servers) { panel.directoryURL = AppPaths.servers }
        if panel.runModal() == .OK { folder = panel.url }
    }

    private func loadVersions() async {
        guard mode == .new, flavor.canDownload else { return }
        versions = []
        version = ""
        do {
            versions = try await SoftwareCatalog.versions(flavor)
            version = shownVersions.first ?? ""
        } catch { self.error = "Couldn't load versions: \(error.localizedDescription)" }
    }

    private func add() {
        guard let folder = targetFolder else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                if mode == .new {
                    if !FileOps.children(folder).filter({ !$0.lastPathComponent.hasPrefix(".") }).isEmpty {
                        throw LeafError("\(folder.lastPathComponent) already has files in it. To use a server that's already there, choose Use an Existing Folder.")
                    }
                    try FileOps.ensureDir(folder)
                }
                let controller = try await ServerController.adopt(root: folder, name: name)
                if mode == .new {
                    controller.profile.software.flavor = flavor
                    if flavor.canDownload {
                        guard let build = try await SoftwareCatalog.latestBuild(flavor, mc: version, channels: GameVersion(version)?.isStableRelease == true ? ["STABLE"] : ["STABLE", "BETA", "ALPHA"]) else {
                            throw LeafError("No download is available for \(flavor.title) \(version) yet.")
                        }
                        model.add(controller)
                        dismiss()
                        controller.attempt { try await controller.installSoftware(build) }
                        return
                    }
                }
                model.add(controller)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
