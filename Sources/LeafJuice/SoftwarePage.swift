import AppKit
import LeafJuiceCore
import SwiftUI

struct SoftwarePage: View {
    @Bindable var model: AppModel
    @Bindable var server: ServerController
    @State private var checking = false

    var body: some View {
        Page(title: "Software", subtitle: "The server itself: what's running, updates, and changing version.") {
            UpgradeBanner(server: server)
            currentCard
            if server.profile.software.flavor.canDownload { updatesCard }
            ChangeVersionCard(server: server)
            IdentifyCard(server: server)
            if !server.archivedJars.isEmpty { rollbackCard }
        }
        .task {
            guard server.profile.software.flavor.canDownload else { return }
            await server.checkSoftwareUpdate()
        }
    }

    private var currentCard: some View {
        Card(title: "Running", systemImage: "shippingbox") {
            Fact(label: "Software", value: server.profile.software.label)
            Fact(label: "Jar", value: server.profile.software.jarName.isEmpty ? "None" : server.profile.software.jarName)
            Fact(label: "Needs", value: "Java \(server.javaRequirement) or newer")
            if server.profile.software.supportStatus == "UNSUPPORTED" {
                Callout(tone: .warning, title: "This Minecraft version no longer gets updates", detail: "It still works, but Paper has moved on. Security and bug fixes only reach supported versions.")
            }
            if server.profile.software.mcVersion.isEmpty {
                Callout(tone: .warning, title: "The Minecraft version isn't known", detail: "Plugin compatibility can't be checked until it's set below.")
            }
        }
    }

    private var updatesCard: some View {
        Card(title: "Updates", systemImage: "arrow.down.circle") {
            if let update = server.softwareUpdate {
                Callout(tone: .info, title: "\(update.flavor.title) \(update.label) is available", detail: update.changes.prefix(4).joined(separator: "\n")) {
                    Button(server.state.canStart ? "Install" : "Install at Restart") {
                        server.attempt { try await server.installSoftware(update) }
                    }
                    .buttonStyle(.juicePrimary).disabled(server.activity != nil)
                }
            } else {
                Text("This is the newest build.").foregroundStyle(Juice.ink)
            }
            if server.profile.software.flavor == .paper || server.profile.software.flavor == .folia {
                HStack(spacing: 16) {
                    Text("Accept").foregroundStyle(Juice.muted)
                    Toggle("Stable", isOn: .constant(true)).disabled(true)
                    channelToggle("Beta", "BETA")
                    channelToggle("Alpha", "ALPHA")
                }
                .toggleStyle(.checkbox)
                Hint("Paper recommends stable builds for real servers.")
            }
            Toggle("Install new builds automatically at the next restart", isOn: $server.profile.software.autoInstallBuilds)
            Hint("Only for builds of the same Minecraft version. Changing Minecraft version is always your call.")
            HStack {
                Button("Check Now") { Task { await server.checkSoftwareUpdate() } }.buttonStyle(.juice)
                if let last = server.profile.software.lastCheck {
                    Hint("Checked \(last.formatted(.relative(presentation: .named)))")
                }
            }
        }
    }

    private func channelToggle(_ title: String, _ channel: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { server.profile.software.channels.contains(channel) },
            set: { on in
                server.profile.software.channels.removeAll { $0 == channel }
                if on { server.profile.software.channels.append(channel) }
                Task { await server.checkSoftwareUpdate() }
            }))
    }

    private var rollbackCard: some View {
        Card(title: "Earlier jars", systemImage: "clock.arrow.circlepath") {
            ForEach(server.archivedJars, id: \.self) { jar in
                HStack {
                    Text(jar).foregroundStyle(Juice.ink)
                    Spacer()
                    Button("Roll Back") { server.attempt { try await server.rollbackJar(jar) } }
                        .buttonStyle(.juice).disabled(!server.state.canStart)
                }
            }
            Hint(server.state.canStart ? "Only within the same Minecraft version. To go back further, restore a backup." : "Stop the server to roll back.")
        }
    }
}

/// Moving to another Minecraft version, with a check that plugins will come along.
struct ChangeVersionCard: View {
    let server: ServerController
    @State private var flavor: Flavor = .paper
    @State private var versions: [String] = []
    @State private var target = ""
    @State private var showPre = false
    @State private var build: SoftwareBuild?
    @State private var readiness: [ReadinessRow]?
    @State private var checking = false
    @State private var loadError: String?
    @State private var confirming = false

    var body: some View {
        Card(title: "Change version", systemImage: "arrow.up.circle") {
            HStack {
                Picker("Software", selection: $flavor) {
                    ForEach(Flavor.allCases.filter(\.canDownload)) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 220)
                Picker("Minecraft", selection: $target) {
                    ForEach(shown, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 220).disabled(versions.isEmpty)
                Toggle("Pre-releases", isOn: $showPre).toggleStyle(.checkbox)
            }
            Hint(flavor.blurb)
            if let loadError { Callout(tone: .warning, title: "Couldn't load versions", detail: loadError) }
            if !target.isEmpty { moveMessage }
            HStack {
                Button("Check Plugins") { checkReadiness() }.buttonStyle(.juice).disabled(target.isEmpty || checking || server.plugins.isEmpty)
                Button(server.state.canStart ? "Install…" : "Install at Restart…") { prepare() }
                    .buttonStyle(.juicePrimary)
                    .disabled(target.isEmpty || move == .downgrade || move == .same || server.activity != nil)
                if checking { ProgressView().controlSize(.small).accessibilityLabel("Checking plugins") }
            }
            if let readiness { readinessList(readiness) }
        }
        .task(id: flavor) { await load() }
        .onChange(of: target) { readiness = nil }
        .onAppear { if server.profile.software.flavor.canDownload { flavor = server.profile.software.flavor } }
        .confirmationDialog(confirmTitle, isPresented: $confirming) {
            Button("Install") {
                guard let build else { return }
                server.attempt { try await server.installSoftware(build) }
            }
        } message: {
            Text(confirmMessage)
        }
    }

    private var shown: [String] {
        showPre ? versions : versions.filter { GameVersion($0)?.isStableRelease ?? false }
    }

    private var move: SoftwareCatalog.Move {
        SoftwareCatalog.classify(current: server.profile.software, flavor: flavor, mc: target, build: nil)
    }

    @ViewBuilder private var moveMessage: some View {
        switch move {
        case .same, .newBuild:
            Hint("Same Minecraft version. This installs the newest build.")
        case .upgrade:
            Callout(tone: .warning, title: "This upgrades your world", detail: "A world that has run on \(target) can't open on \(server.profile.software.mcVersion) again. Leaf Juice first saves the whole server as a restore point and checks it can be read back. If that fails, the upgrade doesn't happen. Afterwards you can roll back in one step.")
            if SoftwareCatalog.crossesWorldLayoutChange(from: server.profile.software.mcVersion, to: target) {
                Callout(tone: .warning, title: "Minecraft 26 stores worlds differently", detail: "Worlds are reorganized on first run, and Nether and End folders move inside the main world. Plugins that work with world folders directly may need updates, so check them below first.")
            }
        case .downgrade:
            Callout(tone: .danger, title: "Worlds can't move to an older version", detail: "Opening a world on an older version can destroy it. To go back to \(target), restore a backup made on that version.")
        case .switchSoftware:
            Callout(tone: .info, title: "Switching to \(flavor.title)", detail: "The same Minecraft version, on different software. A verified restore point is made first, so you can roll back in one step.")
        }
    }

    private func readinessList(_ rows: [ReadinessRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Plugins on \(target)").font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
            let blocked = rows.filter { $0.verdict == .incompatible }.count
            if blocked > 0 { Callout(tone: .warning, title: "\(blocked) plugin\(blocked == 1 ? " has" : "s have") no release for \(target) yet") }
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Badge(text: row.verdict?.title ?? "Unknown", tone: row.verdict?.tone ?? .neutral).frame(width: 130, alignment: .leading)
                    VStack(alignment: .leading) {
                        Text(row.plugin).foregroundStyle(Juice.ink)
                        Hint(row.detail)
                    }
                }
            }
        }
    }

    private var confirmTitle: String { "Install \(flavor.title) \(build?.label ?? target)?" }

    private var confirmMessage: String {
        var text = server.state.canStart ? "" : "It waits for the next restart. "
        if let java = build?.javaMinimum, let current = server.resolvedJava(), current.major < java, current.major > 0 {
            text += "It needs Java \(java); this server is set to Java \(current.major). You'll be offered a download when you start it. "
        }
        if move.needsBackup { return text + "A restore point of the whole server is made and verified first. If that fails, nothing changes." }
        return text + "Your current jar is kept so you can roll back within this version."
    }

    private func load() async {
        loadError = nil
        do {
            versions = try await SoftwareCatalog.versions(flavor)
            target = shown.first ?? ""
        } catch { loadError = error.localizedDescription }
    }

    private func checkReadiness() {
        guard let version = GameVersion(target) else { return }
        checking = true
        Task {
            readiness = await server.readiness(for: version, flavor: flavor)
            checking = false
        }
    }

    private func prepare() {
        Task {
            do {
                let channels = showPre ? ["STABLE", "BETA", "ALPHA"] : server.profile.software.channels
                guard let found = try await SoftwareCatalog.latestBuild(flavor, mc: target, channels: channels) else {
                    loadError = "No build of \(target) on the channels you accept. Try enabling pre-releases or beta builds."
                    return
                }
                build = found
                confirming = true
            } catch { loadError = error.localizedDescription }
        }
    }
}

/// Lets you correct what Leaf Juice detected, or point it at your own jar.
struct IdentifyCard: View {
    @Bindable var server: ServerController
    @State private var open = false

    var body: some View {
        Card {
            DisclosureGroup("Correct the details, or use your own jar", isExpanded: $open) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Software", selection: $server.profile.software.flavor) {
                        ForEach(Flavor.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Jar to run", selection: $server.profile.software.jarName) {
                        if !jars.contains(server.profile.software.jarName) {
                            Text(server.profile.software.jarName.isEmpty ? "None" : server.profile.software.jarName).tag(server.profile.software.jarName)
                        }
                        ForEach(jars, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Minecraft version", text: $server.profile.software.mcVersion, prompt: Text("1.21.11"))
                    TextField("Build", value: $server.profile.software.build, format: .number.grouping(.never), prompt: Text("Optional"))
                    Hint("This only changes what Leaf Juice believes is installed. Plugin compatibility and updates rely on it.")
                }
                .padding(.top, 8)
            }
            .foregroundStyle(Juice.ink)
        }
    }

    private var jars: [String] {
        FileOps.children(server.paths.root).filter { $0.pathExtension.lowercased() == "jar" }.map(\.lastPathComponent).sorted()
    }
}
