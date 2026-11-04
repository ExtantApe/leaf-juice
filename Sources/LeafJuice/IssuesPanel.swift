import AppKit
import LeafJuiceCore
import SwiftUI

/// The side panel: everything worth knowing from the server's output, grouped and explained.
struct IssuesPanel: View {
    @Bindable var model: AppModel
    let server: ServerController
    @State private var showing: Filter = .open
    @State private var expanded: Set<String> = []

    enum Filter: String, CaseIterable, Identifiable {
        case open = "Open", ignored = "Ignored", all = "All"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Issues").font(.title3.weight(.semibold)).foregroundStyle(Juice.ink).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Menu {
                        Button("Scan latest.log") { server.scanLatestLog() }
                        Button("Copy All as Markdown") { copy(items.map(\.report).joined(separator: "\n")) }.disabled(items.isEmpty)
                        Divider()
                        Button("Clear Catalog") { server.clearIssues() }
                    } label: {
                        Label("Issue actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton).fixedSize().help("Issue actions")
                }
                Picker("Show", selection: $showing) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            .padding(12)

            if items.isEmpty {
                EmptyMessage(
                    icon: "leaf",
                    title: showing == .open ? "Nothing to report" : "Nothing here",
                    detail: "Warnings and errors from the server are catalogued here as they appear.")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(items) { issue in
                            IssueRow(model: model, server: server, issue: issue, expanded: binding(for: issue.id))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(Juice.background)
    }

    private var items: [IssueRecord] {
        switch showing {
        case .open: server.issues.filter { $0.status == .open }
        case .ignored: server.issues.filter { $0.status == .ignored }
        case .all: server.issues
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct IssueRow: View {
    @Bindable var model: AppModel
    let server: ServerController
    let issue: IssueRecord
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                expanded.toggle()
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: issue.severity.icon).foregroundStyle(issue.severity.tone.color).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.title).font(.body.weight(.medium)).foregroundStyle(Juice.ink)
                            .multilineTextAlignment(.leading).lineLimit(expanded ? nil : 3)
                        Text(meta).font(.caption).foregroundStyle(Juice.muted)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(Juice.muted).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(issue.severity.title): \(issue.title). \(meta)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded { details }
        }
        .padding(10)
        .background(Juice.surface, in: RoundedRectangle(cornerRadius: Juice.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: Juice.cardRadius).strokeBorder(Juice.border, lineWidth: 1) }
    }

    private var meta: String {
        var parts = [issue.category]
        if let plugin = issue.plugin { parts.append(plugin) }
        parts.append(issue.count == 1 ? "Once" : "\(issue.count) times")
        parts.append(issue.lastSeen.formatted(.relative(presentation: .named)))
        if issue.status != .open { parts.append(issue.status.rawValue.capitalized) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var details: some View {
        if let explanation = issue.explanation {
            Text(explanation).foregroundStyle(Juice.ink).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        } else {
            Hint("There's no built-in advice for this one. It's kept here so you can see how often it happens and share it with the plugin's author.")
        }
        if !issue.steps.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("What to try").font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
                ForEach(Array(issue.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1).").foregroundStyle(Juice.muted)
                        Text(step).foregroundStyle(Juice.ink).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
            }
        }
        DisclosureGroup("Log output") {
            ScrollView(.horizontal) {
                Text(([issue.sample] + issue.stack).joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Juice.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Juice.raised, in: RoundedRectangle(cornerRadius: 6))
        }
        .font(.callout)
        .foregroundStyle(Juice.ink)
        if let attachment = issue.attachment {
            Button("Open Crash Report") { NSWorkspace.shared.open(URL(fileURLWithPath: attachment)) }.buttonStyle(.juice)
        }
        actions
    }

    private var actions: some View {
        FlowRow {
            if let action = issue.action, let page = PageID(rawValue: action.page) {
                Button(action.label) { model.page = page }.buttonStyle(.juicePrimary)
            }
            if issue.status == .open {
                Button("Mark Resolved") { server.setIssueStatus(.resolved, id: issue.id) }.buttonStyle(.juice)
                    .help("Hide this until it happens again")
                Button("Ignore") { server.setIssueStatus(.ignored, id: issue.id) }.buttonStyle(.juice)
                    .help("Keep counting, but stop showing it as open")
            } else {
                Button("Reopen") { server.setIssueStatus(.open, id: issue.id) }.buttonStyle(.juice)
            }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(issue.report, forType: .string)
            }
            .buttonStyle(.juice)
            .help("Copy this issue as Markdown")
            if let url = searchURL { Link("Search the Web", destination: url).buttonStyle(.juice) }
        }
    }

    /// Only happens when clicked, and the query carries no addresses, paths or numbers.
    private var searchURL: URL? {
        var parts = URLComponents(string: "https://duckduckgo.com/")
        parts?.queryItems = [URLQueryItem(name: "q", value: issue.searchQuery)]
        return parts?.url
    }
}

/// Wraps its children onto new lines as needed.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(subviews, width: bounds.width)
        for (subview, origin) in zip(subviews, result.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func layout(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), origins)
    }
}
