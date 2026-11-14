import AppKit
import LeafJuiceCore
import SwiftUI

/// The owner's switch, list of commands, and record of every call for session access. See SessionAccess.swift.
struct SessionAccessSection: View {
    @State private var settings = SessionAccess.loadSettings()
    @State private var adding = ""
    @State private var problem: String?
    @State private var log: [SessionAccess.LogEntry] = []
    @State private var confirmNewToken = false
    private let service = SessionAccessService.shared

    var body: some View {
        Section {
            Toggle("Let sessions on this Mac check status and run listed commands", isOn: Binding(get: { settings.enabled }, set: { on in
                settings.enabled = on
                save()
            }))
            if let error = service.error { Text(error).foregroundStyle(Juice.danger).font(.callout) }
            if settings.enabled {
                Text(service.isListening ? "Listening on this Mac only." : "Not listening yet.").font(.callout).foregroundStyle(Juice.muted)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Commands sessions may run, exactly as written").font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
                if settings.commands.isEmpty { Text("None. Sessions can still read status and the log.").font(.callout).foregroundStyle(Juice.muted) }
                ForEach(settings.commands, id: \.self) { command in
                    HStack {
                        Text(command).font(.body.monospaced()).foregroundStyle(Juice.ink).textSelection(.enabled)
                        Spacer()
                        Button("Remove") { settings.commands.removeAll { $0 == command }; save() }
                            .accessibilityLabel("Remove \(command) from the list")
                    }
                }
                HStack {
                    TextField("Add a command, such as save-all", text: $adding).textFieldStyle(.roundedBorder)
                        .onSubmit(add).accessibilityLabel("Command to add")
                    Button("Add", action: add).disabled(adding.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let problem { Text(problem).foregroundStyle(Juice.danger).font(.callout) }
            }
            Button("Make a New Token…") { confirmNewToken = true }
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent calls").font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
                if log.isEmpty { Text("None yet.").font(.callout).foregroundStyle(Juice.muted) }
                ForEach(log.prefix(30)) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: entry.allowed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(entry.allowed ? Juice.pulp : Juice.danger).accessibilityHidden(true)
                        Text(describe(entry)).font(.callout).foregroundStyle(Juice.ink).textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel((entry.allowed ? "Allowed: " : "Refused: ") + describe(entry))
                }
            }
        } header: {
            Text("Session access")
        } footer: {
            Text("For assistant sessions on this Mac, through leafjuice-session. They can read each server's status and its recent log, with chat, addresses and player names taken out, and run only the commands listed here. Anything running as your macOS account could use it, so keep the list short. Every call is recorded here, allowed or not.")
                .font(.caption).foregroundStyle(Juice.muted)
        }
        .onAppear(perform: reload)
        .onChange(of: service.calls) { reload() }
        .confirmationDialog("Make a new token?", isPresented: $confirmNewToken) {
            Button("Make New Token") { _ = try? SessionAccess.newToken() }
        } message: {
            Text("Anything holding the old token is refused from now on. Sessions read the new one from the Keychain, and macOS may ask you to allow that again.")
        }
    }

    private func describe(_ e: SessionAccess.LogEntry) -> String {
        var text = "\(e.at.formatted(date: .omitted, time: .shortened)) \(e.caller): \(e.call)"
        if let c = e.command { text += " \(c)" }
        if let s = e.server, !s.isEmpty { text += " on \(s)" }
        if !e.allowed || !e.note.isEmpty { text += ". \(e.note)" }
        return text
    }

    private func add() {
        if let why = SessionAccess.problem(adding: adding) { problem = why; return }
        let command = SessionAccess.normalize(adding)
        if !settings.commands.contains(command) { settings.commands.append(command) }
        adding = ""; problem = nil
        save()
    }

    private func save() {
        do { try SessionAccess.saveSettings(settings); problem = nil } catch { problem = error.localizedDescription }
        service.apply(settings)
    }

    private func reload() { log = SessionAccess.recentLog(30) }
}
