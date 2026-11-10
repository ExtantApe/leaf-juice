import LeafJuiceCore
import SwiftUI

/// Choose someone's profiles and approve them, through Usher. Usher's questions appear here, and each needs a tick.
struct UsherApproval: View {
    let server: ServerController
    let uuid: String
    let name: String
    let profiles: [UsherProfile]
    /// Called after Usher confirms a change.
    var done: (String) -> Void = { _ in }
    @State private var current: UsherPlayer?
    @State private var reading = true
    @State private var chosen = Set<String>()
    @State private var questions: [ConfirmQuestion] = []
    @State private var answered = Set<String>()
    @State private var problem: String?
    @State private var result: String?
    @State private var working = false

    private var before: Set<String> { Set(current?.profiles ?? []) }
    private var adding: [String] { chosen.subtracting(before).sorted() }
    private var removing: [String] { before.subtracting(chosen).sorted() }
    private var nothingToDo: Bool { adding.isEmpty && removing.isEmpty && (current?.whitelisted ?? false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if reading {
                Hint("Asking Usher what \(name) has…")
            } else {
                if let current {
                    Fact(label: "On the whitelist", value: current.whitelisted ? "Yes" : "Not yet")
                    if !current.throughOtherGroups.isEmpty {
                        Hint("Also gets \(labels(current.throughOtherGroups)) through another group, which Usher can't change here.")
                    }
                }
                Text("Profiles").font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
                if profiles.isEmpty { Hint("Usher has no profiles set up. Approving gives lobby-only access until an admin adds some.") }
                ForEach(profiles) { profile in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(profile.label, isOn: Binding(get: { chosen.contains(profile.id) }, set: { on in
                            if on { chosen.insert(profile.id) } else { chosen.remove(profile.id) }
                            questions = []; answered = []; result = nil
                        }))
                        .toggleStyle(.checkbox)
                        .accessibilityHint(detail(profile))
                        Hint(detail(profile)).padding(.leading, 20)
                    }
                }
                if !questions.isEmpty {
                    Callout(tone: .warning, title: "Usher asks first", detail: "Nothing has changed yet. Tick each one to go ahead.")
                    ForEach(questions, id: \.id) { q in
                        Toggle(q.question, isOn: Binding(get: { answered.contains(q.id) }, set: { on in
                            if on { answered.insert(q.id) } else { answered.remove(q.id) }
                        }))
                        .toggleStyle(.checkbox)
                    }
                }
                if let problem { Callout(tone: .danger, title: problem) }
                if let result { Callout(tone: .good, title: result) }
                HStack {
                    Button(working ? "Working…" : buttonTitle, action: apply)
                        .buttonStyle(.juicePrimary)
                        .disabled(working || current == nil || nothingToDo || questions.contains { !answered.contains($0.id) })
                    Hint("Goes through Usher, with its own checks, and is logged in Usher's change log.")
                }
            }
        }
        .task(id: uuid) { await read() }
    }

    private var buttonTitle: String {
        if !questions.isEmpty { return "Go Ahead" }
        if current?.whitelisted == false { return "Approve \(name)" }
        return "Save Profiles"
    }

    private func detail(_ p: UsherProfile) -> String {
        var parts: [String] = []
        if !p.worlds.isEmpty { parts.append("Worlds: \(p.worlds.joined(separator: ", "))") }
        if let circle = p.circle { parts.append("Chat circle: \(circle)") }
        if let first = p.description.first { parts.append(first) }
        return parts.isEmpty ? "No worlds or circle of its own." : parts.joined(separator: ". ")
    }

    private func labels(_ ids: [String]) -> String {
        ids.map { id in profiles.first { $0.id == id }?.label ?? id }.joined(separator: ", ")
    }

    private func read() async {
        reading = true
        problem = nil
        switch await server.usherShow(uuid: uuid) {
        case .success(let p):
            current = p
            chosen = Set(p.profiles)
        case .failure(let e):
            current = nil
            problem = e.message
        }
        reading = false
    }

    private func apply() {
        working = true
        problem = nil
        result = nil
        let yes = questions.map(\.id)
        Task {
            defer { working = false }
            switch await server.usherApply(uuid: uuid, name: name, add: adding, remove: removing, yes: yes) {
            case .done(let message):
                questions = []; answered = []
                result = message
                await read()
                done(message)
            case .questions(let qs):
                questions = qs; answered = []
            case .failed(let why):
                problem = why
            case .notConfirmed:
                problem = "Usher didn't answer in 15 seconds. The change may still have happened, so this shows what Usher has now."
                await read()
            }
        }
    }
}

/// The same, in a sheet, for someone already on the list.
struct UsherProfileSheet: View {
    let server: ServerController
    let entry: AllowlistEntry
    let profiles: [UsherProfile]
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Profiles for \(entry.name)").font(.title2.weight(.semibold)).foregroundStyle(Juice.ink)
            UsherApproval(server: server, uuid: entry.uuid, name: entry.name, profiles: profiles) { _ in changed() }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(.juice).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}
