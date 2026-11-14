import AppKit
import LeafJuiceCore
import SwiftUI

struct ConfigsPage: View {
    @Bindable var model: AppModel
    let server: ServerController
    @State private var filter = ""

    private var selectedPath: String? { model.configPath }

    var body: some View {
        HSplitView {
            fileList.frame(minWidth: 190, idealWidth: 230, maxWidth: 340)
            Group {
                if let file = server.configs.first(where: { $0.path == selectedPath }) {
                    ConfigEditor(model: model, server: server, file: file).id(file.path)
                } else {
                    EmptyMessage(icon: "slider.horizontal.3", title: "Choose a file", detail: server.configs.isEmpty ? "Config files appear here after the server has run once." : "Important settings are grouped on the left.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            server.refreshConfigs()
            if model.configPath == nil { model.configPath = server.configs.first?.path }
        }
    }

    private var shownConfigs: [ConfigFile] {
        let needle = filter.lowercased()
        guard !needle.isEmpty else { return server.configs }
        return server.configs.filter { $0.title.lowercased().contains(needle) || $0.group.lowercased().contains(needle) }
    }

    private var groups: [String] {
        var seen = Set<String>()
        return shownConfigs.map(\.group).filter { seen.insert($0).inserted }
    }

    private var fileList: some View {
        List(selection: $model.configPath) {
            ForEach(groups, id: \.self) { group in
                Section(group) {
                    ForEach(shownConfigs.filter { $0.group == group }) { file in
                        HStack(spacing: 6) {
                            Text(file.listTitle).foregroundStyle(Juice.ink).lineLimit(1).truncationMode(.middle).help(file.path)
                            Spacer(minLength: 0)
                            if server.hasStagedEdit(file) {
                                Image(systemName: "clock.fill").foregroundStyle(Juice.warning)
                                    .help("Edited, waiting for a restart")
                                    .accessibilityLabel("Edited, waiting for a restart")
                            } else if case .lockedWhileRunning = file.policy, !server.state.canStart {
                                Image(systemName: "lock.fill").foregroundStyle(Juice.muted)
                                    .help("Locked while the server runs")
                                    .accessibilityLabel("Locked while the server runs")
                            }
                        }
                        .tag(file.path)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            if server.configs.count > 10 {
                TextField("Filter files", text: $filter, prompt: Text("Filter files or plugins"))
                    .textFieldStyle(.roundedBorder).padding(8)
            }
        }
    }
}

struct ConfigEditor: View {
    @Bindable var model: AppModel
    let server: ServerController
    let file: ConfigFile

    private enum Mode: String, CaseIterable, Identifiable {
        case common = "Settings", full = "Full File"
        var id: String { rawValue }
    }
    @State private var mode: Mode = .common
    @State private var text = ""
    @State private var saved = ""
    @State private var message: (tone: Tone, text: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.title).font(.title2.weight(.semibold)).foregroundStyle(Juice.ink).accessibilityAddTraits(.isHeader)
                Hint(file.summary.isEmpty ? file.path : "\(file.summary) (\(file.path))")
            }
            stateCallout
            if hasForm {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
            }
            if let commands = PlayerList.commands(for: file.path) {
                PlayerListForm(server: server, file: file, text: $text, commands: commands)
            } else if hasForm, mode == .common {
                DynamicConfigForm(
                    text: $text, saved: saved, live: server.liveConfigText(file), format: file.format,
                    isLocked: locked, running: !server.state.canStart)
            } else {
                PlainTextEditor(text: $text, isEditable: !locked)
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Juice.controlBorder, lineWidth: 1) }
                    .accessibilityLabel("Contents of \(file.title)")
            }
            ForEach(Array(problems.prefix(3).enumerated()), id: \.offset) { _, problem in
                Callout(tone: .danger, title: problem.description)
            }
            if let message { Callout(tone: message.tone, title: message.text) }
            footer
        }
        .padding(16)
        .onAppear(perform: load)
        .onChange(of: server.state) { _, _ in
            // Only reload what hasn't been touched: never throw away someone's typing.
            if text == saved { load() }
        }
    }

    private var hasForm: Bool { ConfigForm.supports(file.format) && PlayerList.commands(for: file.path) == nil }

    /// Problems in the form's values, as well as the file's own.
    private var fieldProblems: Bool {
        ConfigForm.fields(text, format: file.format).contains { $0.problem != nil }
    }

    private var locked: Bool {
        if case .lockedWhileRunning = file.policy { return !server.state.canStart }
        return false
    }

    private var problems: [ConfigProblem] { ConfigValidator.problems(text, format: file.format) }

    @ViewBuilder private var stateCallout: some View {
        if case let .lockedWhileRunning(hint) = file.policy, !server.state.canStart {
            if PlayerList.commands(for: file.path) == nil {
                Callout(tone: .info, title: "Read-only while the server runs", detail: "The server rewrites this file itself, so edits now would be lost. \(hint)")
            }
        } else if server.hasStagedEdit(file) {
            Callout(tone: .warning, title: "You're seeing your edit, not the live file", detail: "It applies at the next restart.") {
                HStack {
                    Button("Discard Edit") {
                        server.discardStagedEdit(file)
                        load()
                    }
                    .buttonStyle(.juice)
                    Button("Schedule Restart") { model.page = .changes }.buttonStyle(.juice)
                }
            }
        } else if !server.state.canStart {
            Callout(tone: .info, title: "The server is running", detail: "You can edit this now. Your changes wait until the next restart.")
        }
    }

    private var footer: some View {
        HStack {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([server.paths.root.appendingPathComponent(file.path)])
            }
            .buttonStyle(.juice)
            Spacer()
            if text != saved {
                Button("Revert") {
                    text = saved
                    message = nil
                }
                .buttonStyle(.juice)
            }
            if PlayerList.commands(for: file.path) == nil {
            Button(server.state.canStart ? "Save" : "Save for Next Restart") { save() }
                .buttonStyle(.juicePrimary)
                .keyboardShortcut("s")
                .disabled(text == saved || locked || !problems.isEmpty || fieldProblems)
            }
        }
    }

    private func load() {
        text = server.configText(file)
        saved = text
    }

    private func save() {
        do {
            let outcome = try server.saveConfig(file, text: text)
            saved = text
            message = outcome == .staged ? (.warning, "Saved. It applies at the next restart.") : (.good, "Saved.")
            server.refreshConfigs()
        } catch {
            message = (.danger, error.localizedDescription)
        }
    }
}

/// Controls built from the file itself, editing the same text the full file view shows.
struct DynamicConfigForm: View {
    @Binding var text: String
    /// As last saved or staged, and as on disk, to mark what's changed.
    let saved: String
    let live: String
    let format: ConfigFile.Format
    let isLocked: Bool
    let running: Bool
    @State private var filter = ""
    @State private var collapsed: Set<String>?

    var body: some View {
        let all = ConfigForm.fields(text, format: format)
        let needle = filter.lowercased()
        let shown = needle.isEmpty ? all : all.filter {
            $0.title.lowercased().contains(needle) || $0.path.joined(separator: ".").lowercased().contains(needle)
                || ($0.help?.lowercased().contains(needle) ?? false)
        }
        let savedValues = values(saved), liveValues = values(live)
        VStack(alignment: .leading, spacing: 8) {
            if all.count > 12 {
                TextField("Filter settings", text: $filter, prompt: Text("Filter \(all.count) settings"))
                    .textFieldStyle(.roundedBorder)
            }
            if all.isEmpty {
                EmptyMessage(icon: "doc.text", title: "No settings to show here", detail: "This file may be empty or only have a layout the form can't read. Use the Full File view.")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(sections(shown), id: \.name) { section in
                            sectionView(section, savedValues: savedValues, liveValues: liveValues)
                        }
                    }
                    .padding(.trailing, 12)
                }
            }
        }
        .disabled(isLocked)
        .onAppear {
            // Long files start folded, so the structure is visible at a glance.
            if collapsed == nil {
                let names = sections(all).map(\.name)
                collapsed = all.count > 40 ? Set(names.dropFirst()) : []
            }
        }
    }

    private struct FieldSection { let name: String; let fields: [ConfigField] }

    private func sections(_ fields: [ConfigField]) -> [FieldSection] {
        var order: [String] = [], grouped: [String: [ConfigField]] = [:]
        for field in fields {
            if grouped[field.section] == nil { order.append(field.section) }
            grouped[field.section, default: []].append(field)
        }
        return order.map { FieldSection(name: $0, fields: grouped[$0] ?? []) }
    }

    private func values(_ text: String) -> [String: String] {
        Dictionary(ConfigForm.fields(text, format: format).map { ($0.id, $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    @ViewBuilder private func sectionView(_ section: FieldSection, savedValues: [String: String], liveValues: [String: String]) -> some View {
        // A filter shows every match, so folding doesn't hide them.
        let open = !filter.isEmpty || !(collapsed ?? []).contains(section.name)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                var current = collapsed ?? []
                if current.contains(section.name) { current.remove(section.name) } else { current.insert(section.name) }
                collapsed = current
            } label: {
                HStack {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(Juice.muted).accessibilityHidden(true)
                    Text(section.name).font(.headline).foregroundStyle(Juice.ink).multilineTextAlignment(.leading)
                    Text("\(section.fields.count)").font(.caption).foregroundStyle(Juice.muted)
                    Spacer()
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open {
                ForEach(section.fields) { field in
                    Divider()
                    ConfigFieldRow(
                        field: field, status: status(field, savedValues: savedValues, liveValues: liveValues),
                        onChange: { text = ConfigForm.set(field, to: $0, in: text, format: format) })
                        .padding(10)
                }
            }
        }
        .background(Juice.surface, in: RoundedRectangle(cornerRadius: Juice.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: Juice.cardRadius).strokeBorder(Juice.border, lineWidth: 1) }
    }

    private func status(_ field: ConfigField, savedValues: [String: String], liveValues: [String: String]) -> ConfigFieldRow.Status {
        if savedValues[field.id] != field.value { return .unsaved }
        if running || liveValues[field.id] != field.value, liveValues[field.id] != field.value { return .waitingForRestart }
        return .current
    }
}

struct ConfigFieldRow: View {
    enum Status { case current, unsaved, waitingForRestart }
    let field: ConfigField
    let status: Status
    let onChange: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(field.title).foregroundStyle(Juice.ink)
                switch status {
                case .current: EmptyView()
                case .unsaved: Badge(text: "Not saved yet", tone: .info, icon: "pencil")
                case .waitingForRestart: Badge(text: "Applies at next restart", tone: .warning, icon: "clock.fill")
                }
                Spacer(minLength: 8)
                control
            }
            if let help = field.help, !help.isEmpty { Hint(help) }
            if let problem = field.problem { Callout(tone: .warning, title: problem) }
        }
    }

    @ViewBuilder private var control: some View {
        switch field.kind {
        case .bool:
            Toggle(field.title, isOn: Binding(
                get: { field.value.lowercased() == "true" },
                set: { onChange($0 ? "true" : "false") }))
                .labelsHidden().toggleStyle(.switch)
        case let .choice(options):
            Picker(field.title, selection: Binding(get: { field.value }, set: { onChange($0) })) {
                ForEach(options, id: \.self) { Text($0.isEmpty ? "Default" : $0.capitalized).tag($0) }
            }
            .labelsHidden().fixedSize()
        case .readOnly:
            Text(field.value).font(.callout).foregroundStyle(Juice.muted).lineLimit(1)
                .help("Edit this in the Full File view")
        case .int, .number:
            TextField(field.title, text: Binding(get: { field.value }, set: { onChange($0) }))
                .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 110).multilineTextAlignment(.trailing)
        case .text:
            TextField(field.title, text: Binding(get: { field.value }, set: { onChange($0) }))
                .labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 280)
        }
    }
}

/// Ops, the allowlist and bans. The server owns these files, so changes go through its own commands.
struct PlayerListForm: View {
    let server: ServerController
    let file: ConfigFile
    @Binding var text: String
    let commands: PlayerList.Commands
    @State private var entry = ""

    private var running: Bool { server.state == .running }
    private var refusal: String? {
        PlayerList.rawAddRefusal(path: file.path, hasUsher: server.hasUsher,
                                 onlineMode: PropertiesDocument((try? String(contentsOf: server.paths.properties, encoding: .utf8)) ?? "").value("online-mode") == "true")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let refusal { Hint(refusal) }
            HStack {
                TextField(commands.isAddress ? "Address" : "Player name", text: $entry)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260).onSubmit(add)
                Button(commands.addLabel, action: add).buttonStyle(.juicePrimary).disabled(!running || !valid || refusal != nil)
            }
            if !entry.isEmpty, !valid { Hint(commands.isAddress ? "That doesn't look like an address." : "Player names are up to 16 letters, numbers or underscores.") }
            if !running { Hint("Start the server to change this list. It looks up accounts for you, and takes effect straight away with no restart.") }
            let entries = PlayerList.entries(text)
            if entries.isEmpty {
                EmptyMessage(icon: "person.2", title: "Nobody on this list")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries, id: \.self) { name in
                            HStack {
                                Text(name).foregroundStyle(Juice.ink)
                                Spacer()
                                Button("Remove") { run("\(commands.remove) \(name)") }.buttonStyle(.juice).disabled(!running).accessibilityLabel("Remove \(name)")
                            }
                            .padding(.vertical, 5)
                            Divider()
                        }
                    }
                    .padding(.trailing, 12)
                }
            }
        }
    }

    private var valid: Bool { PlayerList.isValid(entry, isAddress: commands.isAddress) }

    private func add() {
        guard valid, running, refusal == nil else { return }
        run("\(commands.add) \(entry)")
        entry = ""
    }

    private func run(_ command: String) {
        server.send(command)
        // The server writes the file just after handling the command.
        Task {
            try? await Task.sleep(for: .seconds(1))
            text = server.configText(file)
        }
    }
}

/// A plain code editor: no smart quotes, dashes or autocorrect, which would quietly break config files.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        init(_ parent: PlainTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.textContainerInset = NSSize(width: 6, height: 6)
        view.backgroundColor = NSColor(Juice.surface)
        view.textColor = NSColor(Juice.ink)
        view.insertionPointColor = NSColor(Juice.pulp)
        view.string = text
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        view.isEditable = isEditable
        if view.string != text {
            let selection = view.selectedRanges
            view.string = text
            view.selectedRanges = selection
        }
    }
}
