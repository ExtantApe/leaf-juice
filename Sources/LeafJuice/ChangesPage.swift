import LeafJuiceCore
import SwiftUI

/// What's waiting for a restart, and when that restart happens.
struct ChangesPage: View {
    @Bindable var server: ServerController
    @State private var restartTime = Date().addingTimeInterval(1800)

    var body: some View {
        Page(title: "Changes", subtitle: "Anything that needs a restart waits here, so a running server is never changed underneath its players.") {
            pendingCard
            if server.state == .running { restartNowCard }
            scheduleCard
        }
        .onChange(of: server.profile.restart) { _, _ in server.refreshSchedule() }
    }

    private var pendingCard: some View {
        Card(title: "Waiting for a restart", systemImage: "tray.full") {
            if server.pending.isEmpty, !server.launchChangedSinceStart {
                EmptyMessage(icon: "checkmark.circle", title: "Nothing waiting")
            }
            if server.launchChangedSinceStart {
                HStack {
                    Image(systemName: "bolt").foregroundStyle(Juice.warning).accessibilityHidden(true)
                    Text("Launch settings changed").foregroundStyle(Juice.ink)
                }
            }
            ForEach(server.pending) { change in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: icon(change)).foregroundStyle(Juice.pulp).accessibilityHidden(true)
                        Text(change.summary).foregroundStyle(Juice.ink)
                        Spacer()
                        Button("Discard") { server.discard(change) }.buttonStyle(.juice)
                    }
                    if let conflict = change.conflict { Callout(tone: .warning, title: conflict) }
                }
            }
            if server.state.canStart, !server.pending.isEmpty {
                Button("Apply Now") { Task { await server.applyPending() } }.buttonStyle(.juicePrimary)
            }
        }
    }

    private func icon(_ change: PendingChange) -> String {
        switch change.kind {
        case .config: "doc.text"
        case .software: "shippingbox"
        case .pluginInstall, .pluginRemove, .pluginToggle: "puzzlepiece.extension"
        }
    }

    private var restartNowCard: some View {
        Card(title: "Restart", systemImage: "arrow.clockwise") {
            if let plan = server.restartPlan {
                Callout(tone: .info, title: planText(plan)) {
                    Button("Cancel") { server.cancelRestart() }.buttonStyle(.juice)
                }
            } else {
                FlowRow(spacing: 8) {
                    Button("Restart Now") { server.restart() }.buttonStyle(.juicePrimary)
                    Button("In 5 Minutes, with Warnings") {
                        server.scheduleRestart(RestartPlan(at: Date().addingTimeInterval(300), reason: "Scheduled restart"))
                    }
                    .buttonStyle(.juice)
                    Button("When the Last Player Leaves") {
                        server.scheduleRestart(RestartPlan(whenEmpty: true, reason: "Server empty"))
                    }
                    .buttonStyle(.juice)
                }
                HStack {
                    DatePicker("At a set time", selection: $restartTime, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .fixedSize()
                    Button("Schedule") {
                        server.scheduleRestart(RestartPlan(at: restartTime, reason: "Scheduled restart"))
                    }
                    .buttonStyle(.juice)
                }
            }
        }
    }

    private func planText(_ plan: RestartPlan) -> String {
        if plan.whenEmpty { return server.players.isEmpty ? "Restarting shortly" : "Waiting for \(server.players.count) player\(server.players.count == 1 ? "" : "s") to leave" }
        if let at = plan.at { return "Restarting at \(at.formatted(date: .omitted, time: .shortened)), with warnings in game" }
        return "Restart planned"
    }

    private var scheduleCard: some View {
        Card(title: "Regular restart", systemImage: "calendar.badge.clock") {
            Toggle("Restart on a schedule", isOn: $server.profile.restart.enabled)
            if server.profile.restart.enabled {
                DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute).fixedSize()
                HStack(spacing: 10) {
                    Text("Days").foregroundStyle(Juice.muted)
                    ForEach(Array(Calendar.current.shortWeekdaySymbols.enumerated()), id: \.offset) { index, name in
                        Toggle(name, isOn: dayBinding(index + 1)).toggleStyle(.checkbox)
                    }
                }
                Hint(server.profile.restart.weekdays.isEmpty ? "No days ticked means every day." : "Only on the days ticked.")
                Toggle("Skip if there's nothing to apply", isOn: $server.profile.restart.onlyIfPending)
                TextField("In-game warning", text: $server.profile.restart.message, prompt: Text("Server restarting in {time}."))
                    .textFieldStyle(.roundedBorder)
                Hint("{time} becomes how long is left. Players are warned at \(warningList).")
                if let next = server.nextScheduledRestart {
                    Fact(label: "Next restart", value: next.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
    }

    private var warningList: String {
        server.profile.restart.warnings.sorted(by: >).map(RestartSchedule.describe).joined(separator: ", ")
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(from: DateComponents(hour: server.profile.restart.hour, minute: server.profile.restart.minute)) ?? Date() },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                server.profile.restart.hour = parts.hour ?? 5
                server.profile.restart.minute = parts.minute ?? 0
            })
    }

    private func dayBinding(_ day: Int) -> Binding<Bool> {
        Binding(
            get: { server.profile.restart.weekdays.contains(day) },
            set: { on in
                server.profile.restart.weekdays.removeAll { $0 == day }
                if on { server.profile.restart.weekdays.append(day) }
            })
    }
}
