import AppKit
import LeafJuiceCore
import SwiftUI

struct ConfigsPage: View {
    @Bindable var model: AppModel
    let server: ServerController
    @State private var selectedPath: String?

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
            if selectedPath == nil { selectedPath = server.configs.first?.path }
        }
    }

    private var groups: [String] {
        var seen = Set<String>()
        return server.configs.map(\.group).filter { seen.insert($0).inserted }
    }

    private var fileList: some View {
        List(selection: $selectedPath) {
            ForEach(groups, id: \.self) { group in
                Section(group) {
                    ForEach(server.configs.filter { $0.group == group }) { file in
                        HStack(spacing: 6) {
                            Text(file.title).foregroundStyle(Juice.ink).lineLimit(1)
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
    }
}

struct ConfigEditor: View {
    @Bindable var model: AppModel
    let server: ServerController
    let file: ConfigFile

    private enum Mode: String, CaseIterable, Identifiable {
        case common = "Common Settings", full = "Full File"
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
            if file.path == "server.properties" {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
            }
            if file.path == "server.properties", mode == .common {
                PropertiesForm(text: $text, isLocked: locked)
            } else {
                PlainTextEditor(text: $text, isEditable: !locked)
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Juice.border, lineWidth: 1) }
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

    private var locked: Bool {
        if case .lockedWhileRunning = file.policy { return !server.state.canStart }
        return false
    }

    private var problems: [ConfigProblem] { ConfigValidator.problems(text, format: file.format) }

    @ViewBuilder private var stateCallout: some View {
        if case let .lockedWhileRunning(hint) = file.policy, !server.state.canStart {
            Callout(tone: .info, title: "Read-only while the server runs", detail: "The server rewrites this file itself, so edits now would be lost. \(hint)")
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
            Button(server.state.canStart ? "Save" : "Save for Next Restart") { save() }
                .buttonStyle(.juicePrimary)
                .keyboardShortcut("s")
                .disabled(text == saved || locked || !problems.isEmpty)
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

/// Friendly controls over the same text as the full file view, so both always agree.
struct PropertiesForm: View {
    @Binding var text: String
    let isLocked: Bool

    var body: some View {
        Form {
            ForEach(PropertySpec.common) { spec in
                row(spec)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .disabled(isLocked)
    }

    private func value(_ key: String) -> String { PropertiesDocument(text).value(key) ?? "" }

    private func stringBinding(_ key: String) -> Binding<String> {
        Binding(get: { value(key) }, set: { new in
            var doc = PropertiesDocument(text)
            doc.set(key, new)
            text = doc.text
        })
    }

    @ViewBuilder private func row(_ spec: PropertySpec) -> some View {
        Group {
            switch spec.kind {
            case .bool:
                Toggle(spec.title, isOn: Binding(
                    get: { value(spec.key) == "true" },
                    set: { stringBinding(spec.key).wrappedValue = $0 ? "true" : "false" }))
            case let .int(range):
                TextField(spec.title, value: Binding<Int>(
                    get: { Int(value(spec.key)) ?? range.lowerBound },
                    set: { stringBinding(spec.key).wrappedValue = String(min(max($0, range.lowerBound), range.upperBound)) }
                ), format: .number.grouping(.never))
            case let .choice(options):
                Picker(spec.title, selection: stringBinding(spec.key)) {
                    if !options.contains(value(spec.key)) { Text(value(spec.key).isEmpty ? "Default" : value(spec.key)).tag(value(spec.key)) }
                    ForEach(options, id: \.self) { Text($0.capitalized).tag($0) }
                }
            case .text:
                TextField(spec.title, text: stringBinding(spec.key))
            }
            if !spec.help.isEmpty { Hint(spec.help) }
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
