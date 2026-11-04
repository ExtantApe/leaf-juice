import Charts
import LeafJuiceCore
import SwiftUI

/// What happened and how the server has been. Stored on this Mac and never sent anywhere.
struct HistoryPage: View {
    let server: ServerController
    @State private var range: Range = .day

    enum Range: String, CaseIterable, Identifiable {
        case day = "Day", week = "Week", month = "Month"
        var id: String { rawValue }
        var seconds: TimeInterval {
            switch self {
            case .day: 86_400
            case .week: 7 * 86_400
            case .month: 30 * 86_400
            }
        }
    }

    private var samples: [MetricSample] {
        let cutoff = Date().addingTimeInterval(-range.seconds)
        return server.metricHistory.filter { $0.date >= cutoff }
    }

    var body: some View {
        Page(title: "History", subtitle: "How the server has been, and what changed when. Kept on this Mac only.") {
            HealthSummary(server: server)
            Picker("Range", selection: $range) {
                ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
            if samples.isEmpty {
                EmptyMessage(icon: "chart.xyaxis.line", title: "Nothing recorded yet", detail: "Readings are kept every five minutes while the server runs.")
            } else {
                MetricChart(title: "Ticks per second", detail: "20 is perfect. Below about 18, players notice.", samples: samples, value: \.tps, tone: .good, domain: 0...21)
                MetricChart(title: "Time per tick", detail: "Milliseconds, out of a 50 budget. This warns you before ticks per second drops.", samples: samples, value: \.mspt, tone: .info, domain: nil)
                MetricChart(title: "Memory in use", detail: "Megabytes, the peak in each period.", samples: samples, value: \.memoryMB, tone: .neutral, domain: nil)
                PlayersChart(samples: samples)
                if samples.contains(where: { $0.gcPauseMS != nil }) {
                    MetricChart(title: "Longest Java pause", detail: "Milliseconds. Pauses over about 200 are felt as stutters, and often mean memory settings need a look.", samples: samples, value: \.gcPauseMS, tone: .warning, domain: nil)
                }
            }
            TimelineCard(events: server.timeline)
        }
        .task { await server.refreshHistory() }
    }
}

struct HealthSummary: View {
    let server: ServerController
    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 12, alignment: .top)]

    var body: some View {
        let month = Date().addingTimeInterval(-30 * 86_400)
        let counts = Trend.uptime(server.timeline, since: month)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            tile("Crashes, 30 days", "\(counts.crashes)", counts.crashes > 0 ? .warning : .good)
            tile("Starts, 30 days", "\(counts.restarts)", .neutral)
            if let days = Trend.daysUntilFull(server.sizeHistory) {
                tile("Disk full in", "\(days) days", days < 30 ? .warning : .neutral)
            }
            if let hour = Trend.quietestHour(server.metricHistory) {
                tile("Quietest hour", Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())?.formatted(date: .omitted, time: .shortened) ?? "", .neutral)
            }
            if let last = server.sizeHistory.last {
                tile("Worlds", Format.bytes(last.worldBytes), .neutral)
                tile("Backups", Format.bytes(last.backupBytes), .neutral)
            }
        }
    }

    private func tile(_ label: String, _ value: String, _ tone: Tone) -> some View {
        Card {
            Text(label).font(.callout).foregroundStyle(Juice.muted)
            HStack(spacing: 6) {
                if tone == .warning { Image(systemName: tone.icon).foregroundStyle(tone.color).accessibilityHidden(true) }
                Text(value).font(.title2.weight(.semibold)).foregroundStyle(Juice.ink)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct MetricChart: View {
    let title: String
    let detail: String
    let samples: [MetricSample]
    let value: KeyPath<MetricSample, Double?>
    let tone: Tone
    let domain: ClosedRange<Double>?

    var body: some View {
        Card(title: title) {
            Hint(detail)
            let points = samples.compactMap { s in s[keyPath: value].map { (s.date, $0) } }
            Chart(points, id: \.0) { point in
                LineMark(x: .value("Time", point.0), y: .value(title, point.1))
                    .foregroundStyle(tone.color)
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: domain ?? 0...max(1, (points.map(\.1).max() ?? 1) * 1.15))
            .frame(height: 120)
            .accessibilityLabel(title)
            .accessibilityValue(summary(points.map(\.1)))
        }
    }

    private func summary(_ values: [Double]) -> String {
        guard let low = values.min(), let high = values.max(), let last = values.last else { return "No data" }
        return String(format: "Latest %.1f, lowest %.1f, highest %.1f", last, low, high)
    }
}

struct PlayersChart: View {
    let samples: [MetricSample]
    var body: some View {
        Card(title: "Players online") {
            Chart(samples) { s in
                AreaMark(x: .value("Time", s.date), y: .value("Players", s.players))
                    .foregroundStyle(Juice.pulp.opacity(0.35))
                    .interpolationMethod(.stepEnd)
            }
            .frame(height: 100)
            .accessibilityLabel("Players online")
            .accessibilityValue("Highest \(samples.map(\.players).max() ?? 0)")
        }
    }
}

struct TimelineCard: View {
    let events: [ServerEvent]
    @State private var showAll = false

    var body: some View {
        Card(title: "Timeline", systemImage: "list.bullet.rectangle") {
            if events.isEmpty { Hint("Starts, crashes, updates, config changes and backups appear here as they happen.") }
            ForEach(events.prefix(showAll ? 500 : 30)) { event in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon(event.kind)).foregroundStyle(tone(event.kind).color).frame(width: 18).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title).foregroundStyle(Juice.ink)
                        if let detail = event.detail { Hint(detail) }
                    }
                    Spacer()
                    Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(.callout).foregroundStyle(Juice.muted)
                }
                .accessibilityElement(children: .combine)
            }
            if events.count > 30, !showAll { Button("Show More") { showAll = true }.buttonStyle(.juice) }
        }
    }

    private func tone(_ kind: ServerEvent.Kind) -> Tone {
        switch kind {
        case .crash, .lag: .warning
        case .start, .backup, .drill: .good
        default: .neutral
        }
    }

    private func icon(_ kind: ServerEvent.Kind) -> String {
        switch kind {
        case .start: "play.circle"
        case .stop: "stop.circle"
        case .crash: "xmark.octagon"
        case .software: "shippingbox"
        case .plugin: "puzzlepiece.extension"
        case .config: "slider.horizontal.3"
        case .backup: "externaldrive"
        case .restore: "arrow.uturn.backward.circle"
        case .rename: "pencil"
        case .player: "person"
        case .cleanup: "sparkles"
        case .drill: "checkmark.shield"
        case .lag: "tortoise"
        }
    }
}

struct LeaderboardCard: View {
    let server: ServerController
    @State private var stat = PlayerStat.all[0]

    var body: some View {
        Card(title: "Leaderboards", systemImage: "trophy") {
            Picker("Stat", selection: $stat) {
                ForEach(PlayerStat.all) { Text($0.title).tag($0) }
            }
            .frame(maxWidth: 280)
            let board = PlayerStatsReader.leaderboard(server.playerStats, stat: stat)
            if board.isEmpty { Hint("Nobody's on this board yet.") }
            ForEach(Array(board.prefix(10).enumerated()), id: \.element.id) { index, player in
                HStack {
                    Text("\(index + 1).").foregroundStyle(Juice.muted).frame(width: 24, alignment: .trailing)
                    Text(player.name).foregroundStyle(Juice.ink)
                    Spacer()
                    Text(stat.display(player.value(stat))).foregroundStyle(Juice.ink)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .task { await server.refreshStats() }
    }
}

struct RegularsCard: View {
    let server: ServerController

    var body: some View {
        if !server.playerActivity.isEmpty {
            Card(title: "Regulars", systemImage: "person.2") {
                ForEach(server.playerActivity.prefix(25)) { player in
                    HStack {
                        Text(player.name).foregroundStyle(Juice.ink)
                        Badge(text: player.status.rawValue, tone: tone(player.status))
                        Spacer()
                        Text("\(player.sessions) visit\(player.sessions == 1 ? "" : "s"), last \(player.lastSeen.formatted(.relative(presentation: .named)))").font(.callout).foregroundStyle(Juice.muted)
                    }
                }
                Hint("From the server's logs, so it only goes back as far as they do.")
            }
        }
    }

    private func tone(_ status: PlayerActivity.Status) -> Tone {
        switch status {
        case .new: .info
        case .regular: .good
        case .occasional: .neutral
        case .drifted: .warning
        }
    }
}

/// One player's numbers, for their detail page.
struct PlayerStatsCard: View {
    let stats: PlayerStats

    var body: some View {
        Card(title: "Stats", systemImage: "chart.bar") {
            ForEach(PlayerStat.all) { stat in
                Fact(label: stat.title, value: stat.display(stats.value(stat)))
            }
        }
    }
}
