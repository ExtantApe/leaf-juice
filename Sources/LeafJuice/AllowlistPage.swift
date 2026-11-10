import LeafJuiceCore
import SwiftUI

/// Add someone before they've joined, with their groups. Each server is its own list.
struct AllowlistPage: View {
    @Bindable var server: ServerController
    @State private var typed = ""
    @State private var looking = false
    @State private var outcome: AccountLookup.Outcome?
    @State private var chosen = Set<String>()
    @State private var settings = PlayerAccessSettings()
    @State private var waiting: [AccessChange] = []
    @State private var entries: [AllowlistEntry] = []
    @State private var message: String?
    @State private var working = false
    @State private var pendingWarnings: [String] = []
    @State private var removing: AllowlistEntry?
    @State private var editing: AllowlistEntry?
    @State private var conflictA = ""
    @State private var conflictB = ""
    @State private var usher: UsherStatus?
    @State private var attempts: [UsherAttempt] = []
    @State private var usherEditing: AllowlistEntry?
    @State private var modules = Modules.shared

    private var running: Bool { server.state == .running }

    var body: some View {
        Page(title: "Allowlist", subtitle: "Who can join \(server.profile.name). This only changes this server.") {
            if let blocked = server.playerAccessBlocked { Callout(tone: .warning, title: "Adding players is off here", detail: blocked) }
            if let message { Callout(tone: .danger, title: message) }
            if server.hasUsher { usherNote }
            addCard
            if !waiting.isEmpty { waitingCard }
            if usherProfiles != nil, !attempts.isEmpty { attemptsCard }
            listCard
            if server.hasLuckPerms, !server.hasUsher { groupsCard }
        }
        .task(id: "\(server.state)-\(modules.isOn(.pluginCommands))") { await readUsher() }
        .task {
            await server.refreshPlugins()
            reload()
            await server.refreshGroups()
            reload()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                entries = server.allowlist
                waiting = server.waitingAccess
            }
        }
        .sheet(item: $usherEditing) { entry in
            UsherProfileSheet(server: server, entry: entry, profiles: usherProfiles ?? []) { reload() }
        }
        .sheet(item: $editing) { entry in
            GroupEditor(server: server, entry: entry, settings: settings) { reload() }
        }
        .confirmationDialog("Take \(removing?.name ?? "") off the allowlist?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) { remove() }
        } message: {
            Text("They can't join after this, and any page sign-in ends. Their groups stay, so adding them back restores what they had.")
        }
    }

    private var addCard: some View {
        Card(title: "Add a player", systemImage: "person.badge.plus") {
            Hint("Java accounts only. Capitals don't matter, but the name has to belong to a real account. Looking it up sends the name to Mojang.")
            HStack {
                TextField("Minecraft username", text: $typed).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    .onChange(of: typed) { outcome = nil; pendingWarnings = [] }
                    .onSubmit(lookUp)
                Button(looking ? "Looking…" : "Look Up", action: lookUp).buttonStyle(.juice)
                    .disabled(looking || !AccountLookup.isValidName(typed.trimmingCharacters(in: .whitespaces)) || server.playerAccessBlocked != nil)
            }
            switch outcome {
            case let .found(account): found(account)
            case .noAccount: Callout(tone: .danger, title: "No Minecraft account has that name", detail: "Check the spelling. Nothing was added.")
            case .invalid: Callout(tone: .danger, title: "That can't be a Minecraft name", detail: "Names are 1 to 16 letters, numbers or underscores.")
            case let .unreachable(why): Callout(tone: .warning, title: "Couldn't check that name", detail: "Nothing was added. \(why)")
            case nil: EmptyView()
            }
        }
    }

    @ViewBuilder private func found(_ account: MojangAccount) -> some View {
        Fact(label: "Account", value: account.name)
        Fact(label: "ID", value: account.uuid)
        if server.hasUsher {
            if let profiles = usherProfiles {
                UsherApproval(server: server, uuid: account.uuid, name: account.name, profiles: profiles) { _ in
                    reload()
                    Task { await readAttempts() }
                }
            } else {
                Hint("Usher looks after who can join this server, so they can be approved once Leaf Juice can reach it.")
            }
        } else {
            rawFound(account)
        }
    }

    @ViewBuilder private func rawFound(_ account: MojangAccount) -> some View {
        if server.hasLuckPerms {
            let offered = settings.knownGroups.filter(settings.grantable.contains)
            if offered.isEmpty {
                Hint("No groups can be chosen yet. Mark some below. Without one they get what the default group gives.")
            } else {
                Text("Groups").font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
                ForEach(offered, id: \.self) { group in
                    Toggle(group, isOn: Binding(get: { chosen.contains(group) }, set: { on in
                        if on { chosen.insert(group) } else { chosen.remove(group) }
                        pendingWarnings = []
                    }))
                    .toggleStyle(.checkbox)
                }
            }
        }
        ForEach(pendingWarnings, id: \.self) { Callout(tone: .warning, title: $0) }
        HStack {
            Button(working ? "Working…" : pendingWarnings.isEmpty ? "Add \(account.name)" : "Add Anyway") { add(account) }
                .buttonStyle(.juicePrimary).disabled(working)
            Hint(running ? "Happens now, with the groups first." : "The server isn't running, so this waits until it is. They can't join until then.")
        }
    }

    private var waitingCard: some View {
        Card(title: "Not finished", systemImage: "clock") {
            ForEach(waiting) { change in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(change.name).font(.body.weight(.semibold)).foregroundStyle(Juice.ink)
                        Hint(change.summary)
                        Spacer()
                        if change.problem != nil {
                            Button("Try Again") { Task { await server.retryAccess(change.id); reload() } }.buttonStyle(.juice).disabled(!running)
                        }
                        Button("Cancel") { server.cancelAccess(change.id); reload() }.buttonStyle(.juice)
                    }
                    if let problem = change.problem {
                        Callout(tone: .danger, title: problem)
                    } else {
                        Hint("Waiting for the server to be running.")
                    }
                }
            }
            Hint("Anything already done stays done, and doing it again is safe.")
        }
    }

    private var listCard: some View {
        Card(title: "On the allowlist (\(entries.count))", systemImage: "list.bullet") {
            if entries.isEmpty { Hint("Nobody yet.") }
            ForEach(entries) { entry in
                HStack {
                    Text(entry.name).foregroundStyle(Juice.ink).textSelection(.enabled)
                    Spacer()
                    if server.hasUsher {
                        Button("Profiles…") { usherEditing = entry }.buttonStyle(.juice).disabled(usherProfiles == nil)
                            .accessibilityLabel("Profiles for \(entry.name)")
                    } else if server.hasLuckPerms {
                        Button("Groups…") { editing = entry }.buttonStyle(.juice).disabled(!running || server.playerAccessBlocked != nil)
                            .accessibilityLabel("Groups for \(entry.name)")
                    }
                    Button("Remove…") { removing = entry }.buttonStyle(.juice).disabled(server.state.isLive && !running)
                        .accessibilityLabel("Remove \(entry.name)")
                }
            }
            if server.hasUsher, usherProfiles == nil { Hint("Profiles can be changed once Leaf Juice can reach Usher.") }
            else if server.hasLuckPerms, !server.hasUsher, !running { Hint("Groups can only be changed while the server runs.") }
        }
    }

    private var groupsCard: some View {
        Card(title: "Groups", systemImage: "person.3") {
            Hint("Tick the groups this screen may hand out. A new group stays off until you tick it, so leave staff and admin groups off.")
            if settings.knownGroups.isEmpty {
                Hint(running ? "Reading groups from the server…" : "Start the server once to read its groups.")
            }
            ForEach(settings.knownGroups, id: \.self) { group in
                Toggle(group, isOn: Binding(get: { settings.grantable.contains(group) }, set: { on in
                    if on { settings.grantable.insert(group) } else { settings.grantable.remove(group) }
                    save()
                }))
                .toggleStyle(.checkbox)
            }
            if settings.knownGroups.count >= 2 {
                Text("Don't combine").font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
                Hint("Choosing both groups in a pair warns you before saving. It doesn't stop you.")
                ForEach(settings.conflicts, id: \.self) { pair in
                    HStack {
                        Text(pair.joined(separator: " and ")).foregroundStyle(Juice.ink)
                        Spacer()
                        Button("Remove") {
                            settings.conflicts.removeAll { $0 == pair }
                            save()
                        }
                        .buttonStyle(.juice)
                        .accessibilityLabel("Remove the pair \(pair.joined(separator: " and "))")
                    }
                }
                HStack {
                    Picker("First group", selection: $conflictA) {
                        Text("Choose…").tag("")
                        ForEach(settings.knownGroups, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Second group", selection: $conflictB) {
                        Text("Choose…").tag("")
                        ForEach(settings.knownGroups, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Add Pair") {
                        let pair = [conflictA, conflictB].sorted()
                        if !settings.conflicts.contains(pair) { settings.conflicts.append(pair) }
                        conflictA = ""; conflictB = ""
                        save()
                    }
                    .buttonStyle(.juice).disabled(conflictA.isEmpty || conflictB.isEmpty || conflictA == conflictB)
                }
            }
        }
    }

    private var usherProfiles: [UsherProfile]? {
        if case .ready(_, let profiles, _, _) = usher { profiles } else { nil }
    }

    @ViewBuilder private var usherNote: some View {
        switch usher {
        case .unavailable(let why)?:
            Callout(tone: .warning, title: "Usher can't be reached", detail: why + " Leaf Juice won't add anyone or change groups around it.") {
                if !modules.isOn(.pluginCommands) {
                    Button("Turn On Plugin Commands") { modules.set(.pluginCommands, on: true) }.buttonStyle(.juice)
                }
            }
        case .ready(let version, _, let luckPerms, let problems)?:
            Callout(tone: .info, title: "Approvals go through Usher \(version)", detail: "Profiles, questions and the change log are Usher's. This works only while Leaf Juice runs this server, because it types Usher's commands into the console.") {
                EmptyView()
            }
            if !luckPerms { Callout(tone: .warning, title: "LuckPerms isn't running", detail: "Usher refuses every change without it, saying why.") }
            ForEach(problems, id: \.self) { Callout(tone: .warning, title: "Usher's settings", detail: $0) }
        default:
            Hint("Checking Usher…")
        }
    }

    private var attemptsCard: some View {
        Card(title: "Turned away recently (\(attempts.count))", systemImage: "hand.raised") {
            Hint("People the whitelist stopped, newest first in Usher's list. Approving still looks the name up first.")
            ForEach(attempts) { attempt in
                HStack {
                    Text(attempt.name).foregroundStyle(Juice.ink).textSelection(.enabled)
                    Hint(attempt.count == 1 ? "once" : "\(attempt.count) times")
                    Spacer()
                    Button("Approve…") { typed = attempt.name; lookUp() }.buttonStyle(.juice)
                        .accessibilityLabel("Approve \(attempt.name)")
                }
            }
        }
    }

    private func readUsher() async {
        await server.refreshPlugins()
        guard server.hasUsher else { usher = .notInstalled; return }
        usher = nil
        usher = await server.usherStatus()
        await readAttempts()
    }

    private func readAttempts() async {
        guard usherProfiles != nil, case .success(let list) = await server.usherAttempts() else { attempts = []; return }
        attempts = list
    }

    private func reload() {
        settings = server.playerAccessSettings
        waiting = server.waitingAccess
        entries = server.allowlist
    }

    private func save() { server.playerAccessSettings = settings }

    private func lookUp() {
        guard server.playerAccessBlocked == nil, !looking else { return }
        looking = true
        message = nil
        chosen = []
        Task {
            outcome = await AccountLookup.lookUp(typed)
            looking = false
        }
    }

    private func add(_ account: MojangAccount) {
        working = true
        message = nil
        Task {
            defer { working = false }
            // Warned once. Pressing again means they've read it.
            if pendingWarnings.isEmpty {
                let existing = await server.currentGroups(uuid: account.uuid) ?? []
                let warnings = settings.warnings(adding: chosen, alreadyHas: existing)
                if !warnings.isEmpty {
                    pendingWarnings = warnings
                    return
                }
            }
            message = await server.requestAccess(AccessChange(uuid: account.uuid, name: account.name, addGroups: chosen.sorted()))
            if message == nil {
                typed = ""
                outcome = nil
                chosen = []
                pendingWarnings = []
            }
            reload()
        }
    }

    private func remove() {
        guard let entry = removing else { return }
        removing = nil
        Task {
            message = await server.removeFromAllowlist(entry)
            reload()
        }
    }
}

private struct GroupEditor: View {
    let server: ServerController
    let entry: AllowlistEntry
    let settings: PlayerAccessSettings
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var current: Set<String>?
    @State private var chosen = Set<String>()
    @State private var signIn = SignInAccess.unknown
    @State private var warnings: [String] = []
    @State private var problem: String?
    @State private var working = false

    private var offered: [String] { settings.knownGroups.filter(settings.grantable.contains) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Groups for \(entry.name)").font(.title2.weight(.semibold)).foregroundStyle(Juice.ink)
            if let current {
                ForEach(offered, id: \.self) { group in
                    Toggle(group, isOn: Binding(get: { chosen.contains(group) }, set: { on in
                        if on { chosen.insert(group) } else { chosen.remove(group) }
                        warnings = []
                    }))
                    .toggleStyle(.checkbox)
                }
                let others = current.subtracting(offered).sorted()
                if !others.isEmpty { Hint("Also has \(others.joined(separator: ", ")), which this screen doesn't change.") }
                if offered.isEmpty { Hint("No groups are marked as ones this screen can change.") }
            } else {
                Hint("Reading from the server…")
            }
            Fact(label: "Can sign in to the plugin page", value: signInText)
            ForEach(warnings, id: \.self) { Callout(tone: .warning, title: $0) }
            if let problem { Callout(tone: .danger, title: problem) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.juice).keyboardShortcut(.cancelAction)
                Button(warnings.isEmpty ? "Save" : "Save Anyway", action: save).buttonStyle(.juicePrimary).disabled(current == nil || working)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            current = await server.currentGroups(uuid: entry.uuid)
            if let current { chosen = current.intersection(offered) } else { problem = "LuckPerms didn't answer." }
            signIn = await server.signInAccess(uuid: entry.uuid)
        }
    }

    private var signInText: String {
        switch signIn {
        case .yes: "Yes"
        case .no: "No"
        case .noGroupGivesIt: "No group gives it. Operators still can."
        case .unknown: "Unknown"
        }
    }

    private func save() {
        guard let current else { return }
        let before = current.intersection(offered)
        let adding = chosen.subtracting(before), removing = before.subtracting(chosen)
        if warnings.isEmpty {
            warnings = settings.warnings(adding: adding, alreadyHas: current.subtracting(removing))
            if !warnings.isEmpty { return }
        }
        working = true
        Task {
            defer { working = false }
            problem = await server.requestAccess(AccessChange(uuid: entry.uuid, name: entry.name, addGroups: adding.sorted(), removeGroups: removing.sorted(), addToAllowlist: false))
            changed()
            if problem == nil { dismiss() }
        }
    }
}
