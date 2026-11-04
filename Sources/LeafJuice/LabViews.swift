import AppKit
import LeafJuiceCore
import SwiftUI

/// Sits on the Lab's Overview: save, restore, wipe, and the last rehearsal.
struct LabPanel: View {
    let model: AppModel
    let server: ServerController
    @State private var note = ""
    @State private var confirmWipe = false
    @State private var confirmRestore: LabSave?
    @State private var confirmDelete: LabSave?

    private var lab: LabController { model.lab }
    private var idle: Bool { !lab.isBusy && server.state.canStart }

    var body: some View {
        Card(title: "Lab", systemImage: "flask") {
            Text("A practice server with its own worlds and bot players. It only listens on this Mac, and it can't be removed or renamed.")
                .foregroundStyle(Juice.ink).fixedSize(horizontal: false, vertical: true)
            LabProgress(lab: lab)
            if !lab.isBusy, !server.state.canStart {
                Hint("Stop the Lab to save, restore or wipe it.")
            }
            HStack {
                TextField("Note for this save", text: $note, prompt: Text("before the 26 upgrade"))
                    .frame(maxWidth: 300).accessibilityLabel("Note for this save")
                Button("Save This Lab") {
                    let text = note
                    note = ""
                    Task { await lab.save(note: text) }
                }
                .buttonStyle(.juice).disabled(!idle)
                Spacer()
                Button("Wipe and Start Fresh…") { confirmWipe = true }.buttonStyle(.juiceDanger).disabled(!idle)
            }
            if !lab.saves.isEmpty {
                Text("Saved Labs").font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
                ForEach(lab.saves) { save in row(save) }
                Button("Show Saves in Finder") { NSWorkspace.shared.open(LabFiles.saves) }.buttonStyle(.juice)
            }
        }
        .confirmationDialog("Wipe the Lab and start fresh?", isPresented: $confirmWipe) {
            Button("Wipe and Start Fresh", role: .destructive) { Task { await lab.wipeAndStartFresh() } }
        } message: {
            Text("Everything in the Lab goes, unless it's saved first. It's then rebuilt with the same version and plugins, new worlds and new bot players.")
        }
        .confirmationDialog("Restore this Lab?", isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } })) {
            Button("Restore", role: .destructive) { if let save = confirmRestore { Task { await lab.restore(save) } } }
        } message: {
            Text("It replaces the Lab as it is now. Save the current one first if you'd like to keep it.")
        }
        .confirmationDialog("Delete this saved Lab?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let save = confirmDelete { try? lab.deleteSave(save) } }
        } message: {
            Text(confirmDelete?.fileName ?? "")
        }
        LabBoard(model: model, lab: lab)
    }

    private func row(_ save: LabSave) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(save.note.isEmpty ? save.software : save.note).foregroundStyle(Juice.ink)
                Hint("\(save.date.formatted(date: .abbreviated, time: .shortened)), \(save.software), \(Format.bytes(save.size))")
            }
            Spacer()
            Button("Restore…") { confirmRestore = save }.buttonStyle(.juice).disabled(!idle)
            Button("Delete…") { confirmDelete = save }.buttonStyle(.juice).disabled(lab.isBusy)
        }
    }
}

struct LabProgress: View {
    let lab: LabController

    var body: some View {
        if let step = lab.step {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text(step).foregroundStyle(Juice.ink)
            }
        }
        if let failure = lab.failure {
            Callout(tone: .danger, title: "The Lab couldn't finish that", detail: failure)
        }
    }
}

/// A switch and a light for each stage. A green light unlocks the switch below it.
struct LabBoard: View {
    let model: AppModel
    let lab: LabController
    @State private var versions: [String] = []
    @State private var chosen = ""

    private var real: [ServerController] { model.servers.filter { !$0.isLab } }

    var body: some View {
        Card(title: "Status board", systemImage: "switch.2") {
            if let current = lab.model(from: model.servers) {
                modelRow(current)
                ForEach(LabStation.allCases) { station in
                    if station == .upgrade { versionRow(current) }
                    LabStationRow(station: station, lab: lab, server: current)
                    if station != LabStation.allCases.last { Divider() }
                }
                ready(current)
            } else {
                Text("Add a server, and the Lab can test its plugins and rehearse its upgrades.").foregroundStyle(Juice.ink)
            }
        }
        .task(id: lab.model(from: model.servers)?.id) { await loadVersions() }
    }

    @ViewBuilder private func modelRow(_ current: ServerController) -> some View {
        HStack {
            Text("Modeled on").foregroundStyle(Juice.muted)
            if real.count > 1 {
                Picker("Server to model", selection: Binding(get: { current.id }, set: { id in
                    if let picked = real.first(where: { $0.id == id }) { lab.chooseModel(picked) }
                })) {
                    ForEach(real) { Text($0.profile.name).tag($0.id) }
                }
                .labelsHidden().frame(maxWidth: 240).disabled(lab.isBusy)
            } else {
                Text(current.profile.name).foregroundStyle(Juice.ink)
            }
            Spacer()
            Text(current.profile.software.label).foregroundStyle(Juice.muted)
        }
    }

    private func versionRow(_ current: ServerController) -> some View {
        HStack {
            Text("Upgrade to").foregroundStyle(Juice.muted)
            Picker("Version to upgrade to", selection: $chosen) {
                Text("Choose…").tag("")
                ForEach(versions, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(maxWidth: 200).disabled(lab.isBusy)
            .onChange(of: chosen) { _, version in pick(version, current) }
            if let target = lab.target { Hint("\(target.flavor.title) \(target.label)") }
        }
    }

    @ViewBuilder private func ready(_ current: ServerController) -> some View {
        if let report = lab.report, lab.result(.fresh) != nil {
            RehearsalVerdict(report: report, model: model, server: current)
        }
    }

    private func loadVersions() async {
        guard let current = lab.model(from: model.servers), current.profile.software.flavor.canDownload else { return }
        let all = (try? await SoftwareCatalog.versions(current.profile.software.flavor)) ?? []
        let now = current.profile.software.gameVersion
        versions = all.filter { version in
            guard let v = GameVersion(version), v.isStableRelease else { return false }
            return now.map { v >= $0 } ?? true
        }
        chosen = lab.target?.mcVersion ?? ""
    }

    private func pick(_ version: String, _ current: ServerController) {
        guard !version.isEmpty, version != lab.target?.mcVersion else { return }
        Task {
            if let build = try? await SoftwareCatalog.latestBuild(current.profile.software.flavor, mc: version, channels: current.profile.software.channels) {
                lab.chooseTarget(build)
            }
        }
    }
}

struct LabStationRow: View {
    let station: LabStation
    let lab: LabController
    let server: ServerController
    @State private var open = false

    private var light: StationLight { lab.light(station, model: server) }
    private var result: StationResult? { lab.result(station) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Toggle(station.title, isOn: Binding(get: { isOn }, set: flick))
                    .toggleStyle(.switch).labelsHidden().disabled(locked)
                    .accessibilityLabel(station.title)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(station.title).font(.body.weight(.semibold)).foregroundStyle(locked ? Juice.muted : Juice.ink)
                        if station.isOptional { Text("Optional").font(.caption).foregroundStyle(Juice.muted) }
                    }
                    Hint(detailLine)
                    if light == .running, let step = lab.step { Text(step).font(.callout).foregroundStyle(Juice.ink) }
                }
                Spacer(minLength: 8)
                StatusLight(light: light)
            }
            if case .failed(acknowledged: false) = light, !station.isOptional {
                Button("Continue Anyway") { lab.continueAnyway(station) }.buttonStyle(.juice)
                    .help("Unlocks the next switch. This light stays red.")
            }
            if let result, !result.checks.isEmpty || !result.groups.isEmpty {
                DisclosureGroup("Details", isExpanded: $open) {
                    StationDetails(result: result).frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(Juice.ink)
            }
        }
    }

    private var locked: Bool {
        if lab.isBusy { return true }
        if case .locked = light { return true }
        return false
    }

    private var isOn: Bool {
        switch light {
        case .running, .passed, .failed, .stale: true
        case .ready, .locked: false
        }
    }

    private var detailLine: String {
        switch light {
        case let .locked(reason): reason
        case .stale: "The plugins or version have changed since this ran. Flick it off and on to run it again."
        case .passed, .failed: result?.note.isEmpty == false ? result!.note : station.summary
        case .ready, .running: station.summary
        }
    }

    private func flick(_ on: Bool) {
        if on {
            Task { await lab.run(station, model: server) }
        } else {
            lab.clear(station)
        }
    }
}

/// The word and shape carry the meaning too, so it never relies on color alone.
struct StatusLight: View {
    let light: StationLight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            if light == .running {
                ProgressView().controlSize(.small).accessibilityHidden(true)
            } else {
                Image(systemName: icon).foregroundStyle(color).accessibilityHidden(true)
            }
            Text(word).font(.callout.weight(.medium)).foregroundStyle(Juice.ink)
        }
        .frame(minWidth: 96, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }

    private var word: String {
        switch light {
        case .locked: "Locked"
        case .ready: "Ready"
        case .running: "Running"
        case .passed: "Passed"
        case .failed(acknowledged: true): "Failed, continued"
        case .failed: "Failed"
        case .stale: "Out of date"
        }
    }

    private var icon: String {
        switch light {
        case .locked: "lock.fill"
        case .ready: "circle"
        case .running: "circle.dotted"
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .stale: "clock.arrow.circlepath"
        }
    }

    private var color: Color {
        switch light {
        case .locked, .ready: Juice.muted
        case .running: Tone.info.color
        case .passed: Tone.good.color
        case .failed: Tone.danger.color
        case .stale: Tone.warning.color
        }
    }
}

struct StationDetails: View {
    let result: StationResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CheckList(checks: result.checks)
            ForEach(result.groups) { group in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(group.title).font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
                        Badge(text: title(group.outcome), tone: tone(group.outcome))
                    }
                    Hint(group.plugins.joined(separator: ", "))
                    CheckList(checks: (group.fresh + (group.withSettings ?? [])).filter { $0.outcome != .passed })
                    ForEach(group.notes, id: \.self) { Hint($0) }
                }
            }
            ForEach(result.leftOut, id: \.self) { Hint($0) }
        }
    }

    private func title(_ outcome: MirrorBatch.Outcome) -> String {
        switch outcome {
        case .passed: "Passed"
        case .pluginProblem: "Plugin problem"
        case .settingsProblem: "Settings problem"
        }
    }

    private func tone(_ outcome: MirrorBatch.Outcome) -> Tone {
        switch outcome {
        case .passed: .good
        case .pluginProblem: .danger
        case .settingsProblem: .warning
        }
    }
}

struct CheckList: View {
    let checks: [LabCheck]

    var body: some View {
        ForEach(checks) { check in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon(check.outcome)).foregroundStyle(color(check.outcome)).accessibilityLabel(check.outcome.rawValue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(check.title).foregroundStyle(Juice.ink).fixedSize(horizontal: false, vertical: true)
                    if !check.detail.isEmpty { Hint(check.detail) }
                }
            }
        }
    }

    private func icon(_ outcome: LabCheck.Outcome) -> String {
        switch outcome {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .skipped: "minus.circle"
        }
    }

    private func color(_ outcome: LabCheck.Outcome) -> Color {
        switch outcome {
        case .passed: Tone.good.color
        case .failed: Tone.danger.color
        case .skipped: Juice.muted
        }
    }
}

/// The last row of the board: what the two paths together suggest.
struct RehearsalVerdict: View {
    let report: RehearsalReport
    let model: AppModel
    let server: ServerController

    private var good: Bool { report.verdict == .bothPassed && !report.settingsProblem }

    var body: some View {
        Divider()
        Callout(tone: good ? .good : .warning, title: report.headline, detail: report.explanation) {
            Button("Open \(server.profile.name)'s Software") {
                model.selectedID = server.id
                model.page = .software
            }
            .buttonStyle(good ? .juicePrimary : .juice)
        }
        DisclosureGroup("What this didn't check") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(RehearsalReport.notChecked, id: \.self) { Text($0).foregroundStyle(Juice.ink) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Juice.ink)
    }
}

/// Explains the Lab and takes the EULA acceptance it needs. Never ticked on anyone's behalf.
struct LabSetupSheet: View {
    let model: AppModel
    /// What to do once accepted.
    let then: @MainActor () -> Void
    @State private var accepted = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Set up the Lab", systemImage: "flask").font(.title2.weight(.semibold)).foregroundStyle(Juice.ink)
            Text("The Lab is a practice server in \((LabFiles.root.path as NSString).abbreviatingWithTildeInPath). Leaf Juice fills it with its own worlds and bot players, and uses it to rehearse upgrades. It never copies your real worlds or players.")
                .foregroundStyle(Juice.ink).fixedSize(horizontal: false, vertical: true)
            Text("Running it means running a Minecraft server, so Mojang's EULA applies. Your acceptance covers the Lab and its rebuilds.")
                .foregroundStyle(Juice.ink).fixedSize(horizontal: false, vertical: true)
            Link("Read the Minecraft EULA", destination: EULA.url)
            Toggle("I accept the Minecraft EULA", isOn: $accepted).toggleStyle(.checkbox).foregroundStyle(Juice.ink)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.juice).keyboardShortcut(.cancelAction)
                Button("Continue") {
                    model.lab.acceptEULA()
                    dismiss()
                    then()
                }
                .buttonStyle(.juicePrimary).disabled(!accepted).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
