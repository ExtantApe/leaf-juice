import AppKit
import LeafJuiceCore
import SwiftUI

/// The LeafJuice palette: cream and sage, with pink grapefruit as the one pop of color.
/// Every pair meets WCAG AA in all four appearances and under common color blindness, checked by leafjuice-check
/// against `Palette` (see docs/ux-audit.md).
/// State is always shown by shape and word as well as color.
enum Juice {
    static let background = dynamic(Palette.background)
    static let surface = dynamic(Palette.surface)
    static let raised = dynamic(Palette.raised)
    /// Card outlines and dividers only. Buttons and fields use controlBorder.
    static let border = dynamic(Palette.border)
    static let controlBorder = dynamic(Palette.controlBorder)
    static let ink = dynamic(Palette.ink)
    static let muted = dynamic(Palette.muted)
    /// Juice green: structure, such as icons, toggles, selection and focus.
    static let pulp = dynamic(Palette.pulp)
    static let pulpWash = dynamic(Palette.pulpWash)
    /// Pink grapefruit: the pop. Only for the main action on a page.
    static let grapefruit = dynamic(Palette.grapefruit)
    static let onGrapefruit = dynamic(Palette.onGrapefruit)
    /// Grapefruit as a text color, and the main button's outline.
    static let grapefruitText = dynamic(Palette.grapefruitText)
    static let warning = dynamic(Palette.warning)
    static let warningWash = dynamic(Palette.warningWash)
    static let danger = dynamic(Palette.danger)
    static let dangerWash = dynamic(Palette.dangerWash)
    static let info = dynamic(Palette.info)
    static let infoWash = dynamic(Palette.infoWash)

    static let controlHeight: CGFloat = 32
    static let controlRadius: CGFloat = 8
    static let cardRadius: CGFloat = 10

    /// The palette's numbers live in LeafJuiceCore, where `leafjuice-check` holds every pair to WCAG AA.
    private static func dynamic(_ swatch: Palette.Swatch) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            switch match {
            case .accessibilityHighContrastAqua: return nsColor(swatch.contrastLight)
            case .accessibilityHighContrastDarkAqua: return nsColor(swatch.contrastDark)
            case .darkAqua: return nsColor(swatch.dark)
            default: return nsColor(swatch.light)
            }
        })
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Buttons

struct JuiceButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger }
    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let kind: Kind
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            configuration.label
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .font(.body.weight(kind == .primary ? .semibold : .regular))
                .foregroundStyle(foreground)
                .padding(.horizontal, 12)
                .frame(minHeight: Juice.controlHeight)
                .background(fill, in: RoundedRectangle(cornerRadius: Juice.controlRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: Juice.controlRadius).strokeBorder(borderColor, lineWidth: 1)
                }
                .overlay {
                    if focused {
                        RoundedRectangle(cornerRadius: Juice.controlRadius + 2).strokeBorder(Juice.pulp, lineWidth: 2).padding(-3)
                    }
                }
                .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hovering)
        }

        private var foreground: Color {
            switch kind {
            case .primary: Juice.onGrapefruit
            case .secondary: Juice.ink
            case .danger: Juice.danger
            }
        }
        private var fill: Color {
            switch kind {
            case .primary: Juice.grapefruit
            case .secondary: hovering && enabled ? Juice.raised : Juice.surface
            case .danger: hovering && enabled ? Juice.dangerWash : Juice.surface
            }
        }
        private var borderColor: Color {
            switch kind {
            case .primary: Juice.grapefruitText
            case .secondary: Juice.controlBorder
            case .danger: Juice.danger
            }
        }
    }
}

extension ButtonStyle where Self == JuiceButtonStyle {
    static var juice: JuiceButtonStyle { JuiceButtonStyle() }
    static var juicePrimary: JuiceButtonStyle { JuiceButtonStyle(kind: .primary) }
    static var juiceDanger: JuiceButtonStyle { JuiceButtonStyle(kind: .danger) }
}

// MARK: - Building blocks

struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Label {
                    Text(title).font(.headline).foregroundStyle(Juice.ink)
                } icon: {
                    if let systemImage { Image(systemName: systemImage).foregroundStyle(Juice.pulp) }
                }
                .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Juice.surface, in: RoundedRectangle(cornerRadius: Juice.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: Juice.cardRadius).strokeBorder(Juice.border, lineWidth: 1) }
    }
}

/// A scrolling page with a consistent title and width.
struct Page<Content: View>: View {
    let title: String
    var subtitle: String?
    var oneLineSubtitle = false
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeading(title: title, subtitle: subtitle, oneLine: oneLineSubtitle)
                content
            }
            .padding(20)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PageHeading: View {
    let title: String
    var subtitle: String?
    var oneLine = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.largeTitle.weight(.semibold)).foregroundStyle(Juice.ink).accessibilityAddTraits(.isHeader)
            if let subtitle {
                if oneLine {
                    Text(subtitle).foregroundStyle(Juice.muted).lineLimit(1).truncationMode(.middle).help(subtitle)
                } else {
                    Text(subtitle).foregroundStyle(Juice.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

enum Tone {
    case good, warning, danger, info, neutral
    var color: Color {
        switch self {
        case .good: Juice.pulp
        case .warning: Juice.warning
        case .danger: Juice.danger
        case .info: Juice.info
        case .neutral: Juice.muted
        }
    }
    var wash: Color {
        switch self {
        case .good: Juice.pulpWash
        case .warning: Juice.warningWash
        case .danger: Juice.dangerWash
        case .info: Juice.infoWash
        case .neutral: Juice.raised
        }
    }
    var icon: String {
        switch self {
        case .good: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        case .info: "info.circle.fill"
        case .neutral: "circle.dashed"
        }
    }
}

/// A short status: icon, word and color together, so it never relies on color alone.
struct Badge: View {
    let text: String
    var tone: Tone = .neutral
    var icon: String?

    var body: some View {
        Label {
            Text(text).font(.caption.weight(.medium)).foregroundStyle(Juice.ink).lineLimit(1).fixedSize()
        } icon: {
            Image(systemName: icon ?? tone.icon).font(.caption).foregroundStyle(tone.color)
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tone.wash, in: Capsule())
    }
}

/// A full-width message with an optional action.
struct Callout<Actions: View>: View {
    let tone: Tone
    let title: String
    var detail: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tone.icon).foregroundStyle(tone.color).font(.title3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(Juice.ink)
                if let detail { Text(detail).foregroundStyle(Juice.ink).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.wash, in: RoundedRectangle(cornerRadius: Juice.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: Juice.cardRadius).strokeBorder(tone.color.opacity(0.6), lineWidth: 1) }
        .accessibilityElement(children: .contain)
    }
}

extension Callout where Actions == EmptyView {
    init(tone: Tone, title: String, detail: String? = nil) {
        self.init(tone: tone, title: title, detail: detail) { EmptyView() }
    }
}

struct EmptyMessage: View {
    let icon: String
    let title: String
    var detail: String?
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(Juice.pulp).accessibilityHidden(true)
            Text(title).font(.headline).foregroundStyle(Juice.ink)
            if let detail { Text(detail).foregroundStyle(Juice.muted).multilineTextAlignment(.center) }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

/// A label and value in a form-like row.
struct Fact: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Juice.muted)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(Juice.ink).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(Juice.muted).fixedSize(horizontal: false, vertical: true)
    }
}

extension ServerState {
    var tone: Tone {
        switch self {
        case .running: .good
        case .starting, .stopping: .info
        case .stopped: .neutral
        case .crashed: .danger
        case .external: .warning
        }
    }
    var icon: String {
        switch self {
        case .running: "play.circle.fill"
        case .starting, .stopping: "hourglass.circle.fill"
        case .stopped: "stop.circle"
        case .crashed: "xmark.octagon.fill"
        case .external: "exclamationmark.triangle.fill"
        }
    }
}

extension Severity {
    var tone: Tone {
        switch self {
        case .critical, .error: .danger
        case .warning: .warning
        case .info: .info
        }
    }
    var icon: String {
        switch self {
        case .critical: "xmark.octagon.fill"
        case .error: "exclamationmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }
}

extension Compatibility.Verdict {
    var tone: Tone {
        switch self {
        case .compatible: .good
        case .likely: .info
        case .unknown: .neutral
        case .incompatible: .danger
        }
    }
    var title: String {
        switch self {
        case .compatible: "Compatible"
        case .likely: "Likely"
        case .unknown: "Unknown"
        case .incompatible: "Incompatible"
        }
    }
}

extension ServerController {
    /// Runs work and surfaces any failure in the page's notice banner.
    func attempt(_ work: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await work() } catch { notice = error.localizedDescription }
        }
    }
}
