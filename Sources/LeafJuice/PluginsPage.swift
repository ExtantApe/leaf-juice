import AppKit
import LeafJuiceCore
import SwiftUI

struct PluginsPage: View {
    @Bindable var model: AppModel
    let server: ServerController
    @State private var selection: InstalledPlugin.ID?
    @State private var adding = false
    @State private var findingSources = false
    @State private var editing: InstalledPlugin?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            if !server.profile.software.flavor.supportsPlugins {
                Callout(tone: .info, title: "Vanilla servers don't run plugins", detail: "Switch to Paper on the Software page to use them.")
                    .padding(.horizontal, 20)
                Spacer()
            } else if server.plugins.isEmpty {
                EmptyMessage(icon: "puzzlepiece.extension", title: "No plugins yet", detail: "Add one from Modrinth, Hangar, SpigotMC, GitHub, Jenkins or any web address.")
                Spacer()
            } else {
                table
                if let plugin = selected {
                    PluginDetail(model: model, server: server, plugin: plugin, editing: $editing)
                        .id(plugin.id)
                }
            }
        }
        .sheet(isPresented: $adding) { AddPluginSheet(server: server) }
        .sheet(isPresented: $findingSources) { FindSourcesSheet(server: server) }
        .sheet(item: $editing) { SourceEditor(server: server, plugin: $0) }
    }

    private var selected: InstalledPlugin? { server.plugins.first { $0.id == selection } }
    private var updatable: [InstalledPlugin] {
        server.plugins.filter { server.record(for: $0).available?.downloadURL != nil }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            PageHeading(title: "Plugins", subtitle: "\(server.plugins.filter(\.enabled).count) enabled, for \(server.profile.software.label)")
            FlowRow(spacing: 8) {
                Button("Add Plugin…") { adding = true }.buttonStyle(.juicePrimary)
                Button("Check for Updates") { Task { await server.checkPluginUpdates() } }
                    .buttonStyle(.juice).disabled(server.checkingPlugins)
                if !server.pluginsWithoutSource.isEmpty {
                    Button("Find Sources (\(server.pluginsWithoutSource.count))…") { findingSources = true }.buttonStyle(.juice)
                        .help("Looks up where the plugins with no source come from, so they can get update checks.")
                }
                if !updatable.isEmpty {
                    Button("Update All (\(updatable.count))") {
                        server.attempt { for plugin in updatable { try await server.installUpdate(for: plugin) } }
                    }
                    .buttonStyle(.juice)
                }
                if server.checkingPlugins {
                    ProgressView().controlSize(.small).frame(height: Juice.controlHeight).accessibilityLabel("Checking for updates")
                }
            }
        }
    }

    private var table: some View {
        let problems = PluginScanner.staticProblems(server.plugins, mc: server.profile.software.gameVersion)
        return Table(server.plugins, selection: $selection) {
            TableColumn("Name") { p in
                VStack(alignment: .leading) {
                    Text(p.name).foregroundStyle(p.enabled ? Juice.ink : Juice.muted)
                    if !p.enabled { Text("Disabled").font(.caption).foregroundStyle(Juice.muted) }
                }
            }
            TableColumn("Version") { p in Text(p.version).foregroundStyle(Juice.ink) }.width(min: 70, ideal: 110)
            TableColumn("Source") { p in
                let source = server.record(for: p).source
                Text(source.summary).foregroundStyle(source.isSet ? Juice.ink : Juice.muted)
            }
            TableColumn("Status") { p in statusBadge(p, problem: problems[p.fileName]) }.width(min: 150, ideal: 190)
        }
        .scrollContentBackground(.hidden)
        .frame(minHeight: 200)
    }

    @ViewBuilder private func statusBadge(_ p: InstalledPlugin, problem: String?) -> some View {
        let record = server.record(for: p)
        if let problem {
            Badge(text: "Problem", tone: .danger).help(problem)
        } else if record.policy == .pinned {
            Badge(text: "Kept at this version", tone: .neutral, icon: "pin.fill")
        } else if server.pending.contains(where: { $0.target == "plugin:\(p.key)" || $0.target == "file:\(p.fileName)" }) {
            Badge(text: "Waiting for restart", tone: .warning, icon: "clock.fill")
        } else if let available = record.available {
            Badge(text: "\(available.version)", tone: available.compatibility.verdict == .unknown ? .neutral : .info, icon: "arrow.down.circle.fill")
                .help("\(available.compatibility.verdict.title): \(available.compatibility.reason)")
        } else if record.lastError != nil {
            Badge(text: "Check failed", tone: .warning).help(record.lastError ?? "")
        } else if record.note != nil, record.lastCheck != nil {
            Badge(text: "See details", tone: .info).help(record.note ?? "")
        } else if record.lastCheck != nil {
            Badge(text: "Up to date", tone: .good)
        } else if record.source.isSet {
            Badge(text: "Not checked yet", tone: .neutral)
        } else {
            Badge(text: "No source", tone: .neutral)
        }
    }
}

struct PluginDetail: View {
    @Bindable var model: AppModel
    let server: ServerController
    let plugin: InstalledPlugin
    @Binding var editing: InstalledPlugin?
    @State private var suggestions: [SourceSuggestion]?
    @State private var confirmRemove = false

    var body: some View {
        let record = server.record(for: plugin)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(plugin.name) \(plugin.version)").font(.title3.weight(.semibold)).foregroundStyle(Juice.ink)
                    Spacer()
                    Picker("When updates appear", selection: policyBinding(record)) {
                        ForEach(PluginRecord.Policy.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                }
                if let description = plugin.descriptor?.description { Text(description).foregroundStyle(Juice.muted).fixedSize(horizontal: false, vertical: true) }
                Hint(metadata)
                if let problem = PluginScanner.staticProblems(server.plugins, mc: server.profile.software.gameVersion)[plugin.fileName] {
                    Callout(tone: .danger, title: problem)
                }
                if let available = record.available { updateCallout(available) }
                if let error = record.lastError { Callout(tone: .warning, title: "The last check failed", detail: error) }
                if let note = record.note { Callout(tone: .info, title: note) }
                if record.policy == .auto {
                    Hint("Installs by itself only when the source gives evidence it fits this Minecraft version. The jar is always checked before it replaces anything.")
                }
                sourceRow(record)
                settingsRow
                if let suggestions { suggestionList(suggestions) }
                FlowRow {
                    Button(plugin.enabled ? "Disable" : "Enable") {
                        server.attempt { try await server.setEnabled(!plugin.enabled, plugin: plugin) }
                    }
                    .buttonStyle(.juice)
                    Button("Remove…") { confirmRemove = true }.buttonStyle(.juiceDanger)
                    if !versionsToRestore.isEmpty { restoreMenu }
                    Button("Show Jar") {
                        NSWorkspace.shared.activateFileViewerSelecting([server.paths.plugins.appendingPathComponent(plugin.fileName)])
                    }
                    .buttonStyle(.juice)
                }
            }
            .padding(16)
        }
        .frame(maxHeight: 300)
        .background(Juice.surface)
        .overlay(alignment: .top) { Rectangle().fill(Juice.border).frame(height: 1) }
        .confirmationDialog("Remove \(plugin.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await server.removePlugin(plugin) } }
        } message: {
            Text("The jar moves to an archive you can restore from. The plugin's settings folder is left alone.")
        }
    }

    private var metadata: String {
        var parts = [plugin.fileName, Format.bytes(plugin.size)]
        if let d = plugin.descriptor {
            if let api = d.apiVersion { parts.append("api-version \(api)") }
            if !d.authors.isEmpty { parts.append("by \(d.authors.joined(separator: ", "))") }
            if !d.depend.isEmpty { parts.append("needs \(d.depend.joined(separator: ", "))") }
        }
        return parts.joined(separator: " · ")
    }

    private func policyBinding(_ record: PluginRecord) -> Binding<PluginRecord.Policy> {
        Binding(get: { record.policy }, set: { value in
            var updated = record
            updated.policy = value
            server.setRecord(updated, for: plugin)
        })
    }

    private func updateCallout(_ c: UpdateCandidate) -> some View {
        Callout(tone: c.compatibility.verdict.tone, title: "\(c.version) is available: \(c.compatibility.verdict.title.lowercased())", detail: c.compatibility.reason) {
            HStack {
                if let page = c.pageURL.flatMap(URL.init(string:)) { Link("View", destination: page).buttonStyle(.juice) }
                if c.downloadURL != nil {
                    if Modules.shared.isOn(.testCopies) {
                        Button("Test First") {
                            Task { await server.startTrial(.pluginUpdate(name: plugin.name)) }
                        }
                        .buttonStyle(.juice).disabled(server.trialPhase != nil)
                        .help("Tries this update on a throwaway copy of the server first")
                    }
                    Button("Install") { server.attempt { try await server.installUpdate(for: plugin) } }
                        .buttonStyle(.juicePrimary).disabled(server.activity != nil)
                }
            }
        }
    }

    /// Built from what's in the plugin's folder, so it's right for any plugin.
    @ViewBuilder private var settingsRow: some View {
        let files = server.configs(for: plugin)
        HStack(spacing: 8) {
            Text("Settings").foregroundStyle(Juice.muted)
            if files.isEmpty {
                Text("Its settings files appear once it has run on this server.").foregroundStyle(Juice.ink)
                Spacer()
            } else {
                Text(files.count == 1 ? files[0].listTitle : "\(files.count) files").foregroundStyle(Juice.ink)
                Spacer()
                Button(files.count == 1 ? "Open Settings" : "Open Settings") {
                    model.configPath = files[0].path
                    model.page = .configs
                }
                .buttonStyle(.juice)
            }
        }
    }

    private func sourceRow(_ record: PluginRecord) -> some View {
        HStack(spacing: 8) {
            Text("Source").foregroundStyle(Juice.muted)
            if let page = record.source.pageURL {
                Link(record.source.summary, destination: page)
            } else {
                Text(record.source.summary).foregroundStyle(Juice.ink)
            }
            Spacer()
            if record.source.isSet {
                Button("Check Now") { Task { await server.checkPlugin(plugin) } }.buttonStyle(.juice)
            } else {
                Button("Find a Source") { Task { suggestions = await SourceFinder.suggestions(for: plugin) } }.buttonStyle(.juice)
            }
            Button("Edit Source…") { editing = plugin }.buttonStyle(.juice)
        }
    }

    @ViewBuilder private func suggestionList(_ list: [SourceSuggestion]) -> some View {
        if list.isEmpty {
            Hint("Nothing found by name. Paste the plugin's page into Edit Source.")
        }
        ForEach(list) { suggestion in
            HStack {
                VStack(alignment: .leading) {
                    Text(suggestion.source.summary).foregroundStyle(Juice.ink)
                    Hint(suggestion.reason)
                }
                Spacer()
                Button("Use This") {
                    var record = server.record(for: plugin)
                    record.source = suggestion.source
                    server.setRecord(record, for: plugin)
                    suggestions = nil
                    Task { await server.checkPlugin(plugin) }
                }
                .buttonStyle(.juice)
            }
        }
    }

    private var versionsToRestore: [String] { server.archivedPlugins }

    private var restoreMenu: some View {
        Menu("Restore Archived Jar") {
            ForEach(versionsToRestore, id: \.self) { name in
                Button(name) { server.attempt { try await server.restorePlugin(fileName: name) } }
            }
        }
        .fixedSize()
        .disabled(!server.state.canStart)
        .help(server.state.canStart ? "Put an earlier jar back" : "Stop the server first")
    }
}

// MARK: - Editing where a plugin comes from

struct SourceForm: View {
    @Binding var source: PluginSource
    @State private var paste = ""
    @State private var didParse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Paste a web address", text: $paste, prompt: Text("https://… a Modrinth, Hangar, SpigotMC, GitHub or Jenkins page"))
                .textFieldStyle(.roundedBorder)
                .onChange(of: paste) { _, text in
                    if let parsed = SourceParser.parse(text), text.contains(".") {
                        source = parsed
                        didParse = true
                    }
                }
            Picker("Watch", selection: kindBinding) {
                ForEach(SourceKind.allCases) { Text($0.title).tag($0) }
            }
            fields
            Hint(source.kind.evidence)
        }
    }

    private var kindBinding: Binding<SourceKind> {
        Binding(get: { source.kind }, set: { kind in
            guard kind != source.kind else { return }
            switch kind {
            case .none: source = .none
            case .modrinth: source = .modrinth(project: "", allowBeta: false)
            case .hangar: source = .hangar(project: "", channel: "Release")
            case .spigot: source = .spigot(resourceID: 0)
            case .github: source = .github(repo: "", assetPattern: "", prereleases: false)
            case .jenkins: source = .jenkins(jobURL: "", artifactPattern: "")
            case .web: source = .web(url: "", linkPattern: "")
            }
        })
    }

    @ViewBuilder private var fields: some View {
        switch source {
        case .none:
            EmptyView()
        case let .modrinth(project, beta):
            TextField("Project", text: Binding(get: { project }, set: { source = .modrinth(project: $0, allowBeta: beta) }), prompt: Text("luckperms"))
            Toggle("Include beta releases", isOn: Binding(get: { beta }, set: { source = .modrinth(project: project, allowBeta: $0) }))
        case let .hangar(project, channel):
            TextField("Project", text: Binding(get: { project }, set: { source = .hangar(project: $0, channel: channel) }), prompt: Text("Owner/Project"))
            TextField("Channel", text: Binding(get: { channel }, set: { source = .hangar(project: project, channel: $0) }), prompt: Text("Release"))
        case let .spigot(id):
            TextField("Resource number", value: Binding(get: { id }, set: { source = .spigot(resourceID: $0) }), format: .number.grouping(.never))
        case let .github(repo, pattern, pre):
            TextField("Repository", text: Binding(get: { repo }, set: { source = .github(repo: $0, assetPattern: pattern, prereleases: pre) }), prompt: Text("owner/name"))
            TextField("File pattern (optional)", text: Binding(get: { pattern }, set: { source = .github(repo: repo, assetPattern: $0, prereleases: pre) }), prompt: Text("Regular expression, such as Bukkit"))
            Toggle("Include pre-releases", isOn: Binding(get: { pre }, set: { source = .github(repo: repo, assetPattern: pattern, prereleases: $0) }))
        case let .jenkins(url, pattern):
            TextField("Job address", text: Binding(get: { url }, set: { source = .jenkins(jobURL: $0, artifactPattern: pattern) }), prompt: Text("https://ci.example.com/job/Plugin/"))
            TextField("File pattern (optional)", text: Binding(get: { pattern }, set: { source = .jenkins(jobURL: url, artifactPattern: $0) }), prompt: Text("Regular expression, such as Bukkit"))
        case let .web(url, pattern):
            TextField("Address", text: Binding(get: { url }, set: { source = .web(url: $0, linkPattern: pattern) }), prompt: Text("A direct link to a jar, or a downloads page"))
            TextField("Link pattern (for pages)", text: Binding(get: { pattern }, set: { source = .web(url: url, linkPattern: $0) }), prompt: Text("Regular expression, such as foo-.*\\.jar"))
        }
    }
}

private struct TestResult: View {
    let result: Result<SourceCheck, Error>
    var body: some View {
        switch result {
        case let .failure(error):
            Callout(tone: .danger, title: "That source didn't work", detail: error.localizedDescription)
        case let .success(check):
            if let c = check.candidate {
                Callout(tone: c.compatibility.verdict.tone, title: "Found \(c.version): \(c.compatibility.verdict.title.lowercased())", detail: [c.compatibility.reason, check.skippedNote].compactMap { $0 }.joined(separator: " "))
            } else {
                Callout(tone: .warning, title: "Nothing suitable found", detail: check.skippedNote)
            }
        }
    }
}

struct SourceEditor: View {
    let server: ServerController
    let plugin: InstalledPlugin
    @Environment(\.dismiss) private var dismiss
    @State private var source: PluginSource = .none
    @State private var tested: Result<SourceCheck, Error>?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where \(plugin.name) comes from").font(.title2.weight(.semibold)).foregroundStyle(Juice.ink)
            SourceForm(source: $source).formStyle(.columns)
            if let tested { TestResult(result: tested) }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.juice).keyboardShortcut(.cancelAction)
                Spacer()
                if testing { ProgressView().controlSize(.small) }
                Button("Test") { test() }.buttonStyle(.juice).disabled(!source.isSet || testing)
                Button("Save") {
                    var record = server.record(for: plugin)
                    record.source = source
                    server.setRecord(record, for: plugin)
                    dismiss()
                    Task { await server.checkPlugin(plugin) }
                }
                .buttonStyle(.juicePrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { source = server.record(for: plugin).source }
    }

    private func test() {
        testing = true
        Task {
            defer { testing = false }
            do {
                tested = .success(try await PluginSources.check(source, mc: server.profile.software.gameVersion, flavor: server.profile.software.flavor))
            } catch { tested = .failure(error) }
        }
    }
}

/// Suggestions for every plugin with no source. Nothing is set until you choose, since a name can match the wrong project.
struct FindSourcesSheet: View {
    let server: ServerController
    @Environment(\.dismiss) private var dismiss
    @State private var proposals: [SourceProposal]?
    @State private var chosen: [String: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find plugin sources").font(.title2.weight(.semibold)).foregroundStyle(Juice.ink)
            Hint("A source is where a plugin's updates come from. These matches are by name, so check any that look wrong before using them.")
            if let proposals {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(proposals) { proposal in row(proposal) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 420)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text("Looking up \(server.pluginsWithoutSource.count) plugins…").foregroundStyle(Juice.ink)
                }
            }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.juice).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use \(chosen.count) Source\(chosen.count == 1 ? "" : "s")") { apply() }.buttonStyle(.juicePrimary).disabled(chosen.isEmpty).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .task { proposals = await server.proposeSources() }
    }

    @ViewBuilder private func row(_ proposal: SourceProposal) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(proposal.plugin.name).font(.body.weight(.semibold)).foregroundStyle(Juice.ink)
                Hint("You have \(proposal.plugin.version)")
            }
            if proposal.options.isEmpty {
                Hint("Nothing found by name. Paste its page into Edit Source on the plugin.")
            } else {
                Picker("Source for \(proposal.plugin.name)", selection: Binding(get: { chosen[proposal.id] ?? -1 }, set: { chosen[proposal.id] = $0 < 0 ? nil : $0 })) {
                    Text("Don't set").tag(-1)
                    ForEach(Array(proposal.options.enumerated()), id: \.offset) { index, option in
                        Text("\(option.suggestion.source.summary)\(option.newest.map { ", newest \($0)" } ?? "")").tag(index)
                    }
                }
                .labelsHidden().frame(maxWidth: 420)
            }
            if let index = chosen[proposal.id], proposal.options.indices.contains(index) {
                let option = proposal.options[index]
                if option.looksWrong {
                    Callout(tone: .warning, title: "This looks like a different project", detail: "Its newest release is older than yours, so an update from here could replace your plugin with something else.")
                } else {
                    Hint(option.suggestion.reason)
                }
            }
        }
    }

    private func apply() {
        for proposal in proposals ?? [] {
            if let index = chosen[proposal.id], proposal.options.indices.contains(index) {
                server.useSource(proposal.options[index].suggestion.source, for: proposal.plugin)
            }
        }
        Task { await server.checkPluginUpdates() }
        dismiss()
    }
}

struct AddPluginSheet: View {
    let server: ServerController
    @Environment(\.dismiss) private var dismiss
    @State private var source: PluginSource = .modrinth(project: "", allowBeta: false)
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Plugin").font(.title2.weight(.semibold)).foregroundStyle(Juice.ink)
            SourceForm(source: $source).formStyle(.columns)
            Hint(server.state.canStart ? "It will be installed straight away." : "Plugins can't be added to a running server safely, so this waits for the next restart.")
            if let error { Callout(tone: .danger, title: error) }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.juice).keyboardShortcut(.cancelAction)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Add") { add() }.buttonStyle(.juicePrimary).keyboardShortcut(.defaultAction).disabled(!source.isSet || working)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func add() {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await server.addPlugin(source: source)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
