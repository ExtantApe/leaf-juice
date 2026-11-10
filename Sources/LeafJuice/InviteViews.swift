import AppKit
import LeafJuiceCore
import SwiftUI

/// Invites through Latchkey: make one with Usher profiles, see the code once, and list or revoke them.
struct InvitesCard: View {
    let server: ServerController
    /// Usher's profiles, when Usher can be reached. Without them an invite gives lobby-only access.
    let profiles: [UsherProfile]?
    @State private var status: LatchkeyStatus?
    @State private var name = ""
    @State private var chosen = Set<String>()
    @State private var days = 14
    @State private var questions: [ConfirmQuestion] = []
    @State private var answered = Set<String>()
    @State private var made: NewInvite?
    @State private var copied = false
    @State private var problem: String?
    @State private var working = false
    @State private var invites: [LatchkeyInvite] = []
    @State private var more = false
    @State private var revoking: LatchkeyInvite?
    @State private var modules = Modules.shared

    private var nameIsValid: Bool { AccountLookup.isValidName(name.trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        Card(title: "Invites", systemImage: "envelope.badge.person.crop") {
            Hint("An invite is a six-character code for one Minecraft name. They type it on your sign-up page, and they're on the allowlist with the profiles you chose. Invites from Leaf Juice only work while Leaf Juice runs this server.")
            switch status {
            case nil: Hint("Checking Latchkey…")
            case .notInstalled?: EmptyView()
            case .unavailable(let why)?:
                Callout(tone: .warning, title: "Invites can't be made right now", detail: why) {
                    if !modules.isOn(.pluginCommands) {
                        Button("Turn On Plugin Commands") { modules.set(.pluginCommands, on: true) }.buttonStyle(.juice)
                    }
                }
            case .ready(let version, let invitesWork, let publicURL, let problems, let lobby)?:
                ForEach(problems, id: \.self) { Callout(tone: .warning, title: "Latchkey's settings", detail: $0) }
                if let lobby {
                    Fact(label: "Lobby", value: lobby ? "On: new players arrive in Latchkey's lobby" : "Off: players arrive at the usual spawn")
                }
                if !invitesWork {
                    Callout(tone: .warning, title: "Latchkey \(version) isn't taking invites", detail: "Until its settings pass its checks, it won't make any. The problems above say what to change.")
                } else {
                    if let publicURL, !publicURL.isEmpty { Fact(label: "Sign-up page", value: publicURL) }
                    Hint("Signing in to the web pages with /signin needs the latchkey.signin permission, which only operators have until you give it to a group in LuckPerms.")
                    if let made { codeView(made) } else { form }
                }
                listView
            }
        }
        .task(id: "\(server.state)-\(modules.isOn(.pluginCommands))") { await refresh() }
        .confirmationDialog("Revoke the invite for \(revoking?.name ?? "")?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
            Button("Revoke", role: .destructive) { revoke() }
        } message: {
            Text("Its code stops working at once. You can make a new one afterwards.")
        }
    }

    @ViewBuilder private var form: some View {
        HStack {
            TextField("Minecraft username", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                .onChange(of: name) { questions = []; answered = []; problem = nil }
            Stepper("Lasts \(days) day\(days == 1 ? "" : "s")", value: $days, in: 1...30)
                .accessibilityValue("\(days) days")
        }
        Hint("Latchkey checks the name with Mojang when the invite is made.")
        if let profiles {
            Text("Profiles").font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
            if profiles.isEmpty { Hint("Usher has no profiles set up, so the invite gives lobby-only access.") }
            ForEach(profiles) { profile in
                Toggle(profile.label, isOn: Binding(get: { chosen.contains(profile.id) }, set: { on in
                    if on { chosen.insert(profile.id) } else { chosen.remove(profile.id) }
                    questions = []; answered = []
                }))
                .toggleStyle(.checkbox)
            }
            // Always one line here, so the button below doesn't jump as boxes are ticked.
            if !profiles.isEmpty {
                Hint(chosen.isEmpty ? "With no profiles ticked, they get lobby-only access until an admin adds more." : "Usher checks these now, and gives them when the code is used.")
            }
        } else {
            Hint("Without Usher, an invite gives lobby-only access.")
        }
        if !questions.isEmpty {
            Callout(tone: .warning, title: "Usher asks first", detail: "No invite has been made yet. Tick each one to go ahead.")
            ForEach(questions, id: \.id) { q in
                Toggle(q.question, isOn: Binding(get: { answered.contains(q.id) }, set: { on in
                    if on { answered.insert(q.id) } else { answered.remove(q.id) }
                }))
                .toggleStyle(.checkbox)
            }
        }
        if let problem { Callout(tone: .danger, title: problem) }
        Button(working ? "Making…" : questions.isEmpty ? "Make Invite" : "Go Ahead", action: create)
            .buttonStyle(.juicePrimary)
            .disabled(working || !nameIsValid || questions.contains { !answered.contains($0.id) })
    }

    @ViewBuilder private func codeView(_ new: NewInvite) -> some View {
        Callout(tone: .good, title: "Invite for \(new.invite.name)", detail: "Shown once. Send it to them privately. It works once, until \(new.invite.expires.formatted(date: .abbreviated, time: .shortened)).") { EmptyView() }
        if let warning = new.warning { Callout(tone: .warning, title: warning) }
        HStack(spacing: 12) {
            Text(new.code)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .foregroundStyle(Juice.ink)
                .textSelection(.enabled)
                .accessibilityLabel("Invite code: \(new.code.map(String.init).joined(separator: " "))")
            Button(copied ? "Copied" : "Copy Code") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(new.code, forType: .string)
                copied = true
            }
            .buttonStyle(.juice)
        }
        Button("Done") { made = nil; copied = false; name = ""; chosen = [] }
            .buttonStyle(.juicePrimary).keyboardShortcut(.defaultAction)
        Hint("After Done, the code can't be shown again. Leaf Juice keeps no copy.")
    }

    @ViewBuilder private var listView: some View {
        let open = invites.filter { $0.isOpen() }
        Text("Invites (\(open.count) waiting)").font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
        if invites.isEmpty { Hint("None yet.") }
        if more { Hint("Showing the newest \(invites.count). Older invites are in Latchkey's own list: /latchkey invite list.") }
        ForEach(invites) { invite in
            HStack {
                Text(invite.name).foregroundStyle(Juice.ink).textSelection(.enabled)
                Hint(invite.stateText() + (invite.profiles.isEmpty ? ", lobby only" : ", " + labels(invite.profiles)))
                Spacer()
                if invite.isOpen() {
                    Hint("until \(invite.expires.formatted(date: .abbreviated, time: .omitted))")
                    Button("Revoke…") { revoking = invite }.buttonStyle(.juice)
                        .accessibilityLabel("Revoke the invite for \(invite.name)")
                }
            }
        }
    }

    private func labels(_ ids: [String]) -> String {
        ids.map { id in profiles?.first { $0.id == id }?.label ?? id }.joined(separator: ", ")
    }

    private func refresh() async {
        await server.refreshPlugins()
        guard server.hasLatchkey else { status = .notInstalled; return }
        status = nil
        status = await server.latchkeyStatus()
        if case .ready = status { await reloadList() } else { invites = []; more = false }
    }

    private func reloadList() async {
        if case .success(let list) = await server.listInvites() { invites = list.invites; more = list.more }
    }

    private func create() {
        working = true
        problem = nil
        let yes = questions.map(\.id)
        Task {
            defer { working = false }
            switch await server.createInvite(name: name.trimmingCharacters(in: .whitespaces), profiles: chosen.sorted(), days: days, yes: yes) {
            case .made(let new):
                made = new; questions = []; answered = []
                await reloadList()
            case .questions(let qs): questions = qs; answered = []
            case .failed(let why): problem = why
            case .notConfirmed:
                problem = "Latchkey didn't answer in 15 seconds. An invite may still have been made, so check the list below and revoke anything you don't want."
                await reloadList()
            }
        }
    }

    private func revoke() {
        guard let invite = revoking else { return }
        revoking = nil
        Task {
            problem = await server.revokeInvite(invite.invite)
            await reloadList()
        }
    }
}
