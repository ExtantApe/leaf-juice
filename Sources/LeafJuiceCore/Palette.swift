import Foundation

/// LeafJuice's colors, as plain numbers, so the checks can hold every pair to WCAG without the app.
/// The app's Theme builds its colors from these. Change a value here and `leafjuice-check` (run by CI) fails
/// if any pair below drops under its minimum, in any appearance or under any of the color-vision simulations.
public enum Palette {
    public struct Swatch: Sendable, Equatable {
        public let light: UInt32, dark: UInt32, contrastLight: UInt32, contrastDark: UInt32
        init(_ light: UInt32, _ dark: UInt32, contrast: (UInt32, UInt32)? = nil) {
            self.light = light; self.dark = dark
            contrastLight = contrast?.0 ?? light; contrastDark = contrast?.1 ?? dark
        }
        public func hex(_ mode: Mode) -> UInt32 {
            switch mode {
            case .light: light
            case .dark: dark
            case .contrastLight: contrastLight
            case .contrastDark: contrastDark
            }
        }
    }

    /// The four appearances macOS can ask for: light, dark, and each with Increase Contrast on.
    public enum Mode: String, CaseIterable, Sendable { case light, dark, contrastLight = "light, increased contrast", contrastDark = "dark, increased contrast" }

    public static let background = Swatch(0xF8F6E9, 0x2A3225)
    public static let surface = Swatch(0xFFFEF8, 0x343E2E)
    public static let raised = Swatch(0xECF1DA, 0x414D39)
    /// Outlines of cards and dividers. Decoration only: anything a person clicks or types in uses controlBorder.
    public static let border = Swatch(0xCDD5B6, 0x5A6950, contrast: (0x5F6E50, 0xA3B292))
    /// Outlines of buttons and fields: 3:1 against every surface, so a control can be found without its fill.
    public static let controlBorder = Swatch(0x76845F, 0x95A487, contrast: (0x5F6E50, 0xA3B292))
    public static let ink = Swatch(0x2A3520, 0xF4F6E9, contrast: (0x000000, 0xFFFFFF))
    public static let muted = Swatch(0x55614A, 0xCBD4BC, contrast: (0x2F3926, 0xE6ECDA))
    public static let pulp = Swatch(0x4A6E22, 0xC3E491)
    public static let pulpWash = Swatch(0xE2EEC6, 0x43552F)
    public static let grapefruit = Swatch(0xF4846B, 0xFF9E86)
    public static let onGrapefruit = Swatch(0x3A140B, 0x3A140B)
    public static let grapefruitText = Swatch(0xA33C25, 0xFFB8A6)
    public static let warning = Swatch(0x85540A, 0xF8CC72)
    public static let warningWash = Swatch(0xFBEFD0, 0x524223)
    public static let danger = Swatch(0xA8202E, 0xFFB3B0)
    public static let dangerWash = Swatch(0xFBE0E0, 0x572C2E)
    public static let info = Swatch(0x1C6478, 0x9ADAEE)
    public static let infoWash = Swatch(0xDDF0F5, 0x274650)

    // MARK: Pairs and their minimums

    public enum Use: String, Sendable {
        /// WCAG 1.4.3: body text needs 4.5:1. All text is held to this, large or not.
        case text = "text"
        /// WCAG 1.4.11: icons, outlines and focus rings a person needs to see need 3:1.
        case ui = "control or icon"
        public var minimum: Double { self == .text ? 4.5 : 3 }
    }

    public struct Pair: Sendable {
        public let foreground: String, background: String, use: Use
        let fg: Swatch, bg: Swatch
    }

    static let surfaces: [(String, Swatch)] = [("background", background), ("surface", surface), ("raised", raised)]

    /// Every way the app puts one color on another.
    public static let pairs: [Pair] = {
        var list: [Pair] = []
        func add(_ f: String, _ fg: Swatch, _ b: String, _ bg: Swatch, _ use: Use) { list.append(Pair(foreground: f, background: b, use: use, fg: fg, bg: bg)) }
        for (name, swatch) in [("ink", ink), ("muted", muted), ("pulp", pulp), ("grapefruitText", grapefruitText), ("warning", warning), ("danger", danger), ("info", info)] {
            for (s, bg) in surfaces { add(name, swatch, s, bg, .text) }
        }
        for (w, wash) in [("pulpWash", pulpWash), ("warningWash", warningWash), ("dangerWash", dangerWash), ("infoWash", infoWash)] {
            add("ink", ink, w, wash, .text)
            add("muted", muted, w, wash, .text)
        }
        add("onGrapefruit", onGrapefruit, "grapefruit", grapefruit, .text)
        add("danger", danger, "dangerWash", dangerWash, .text)
        for (t, tone, w, wash) in [("pulp", pulp, "pulpWash", pulpWash), ("warning", warning, "warningWash", warningWash), ("danger", danger, "dangerWash", dangerWash), ("info", info, "infoWash", infoWash)] {
            add(t, tone, w, wash, .ui)
        }
        for (s, bg) in surfaces {
            add("controlBorder", controlBorder, s, bg, .ui)
            add("grapefruitText", grapefruitText, s, bg, .ui)  // the main button's outline
            add("danger", danger, s, bg, .ui)                  // the danger button's outline
            add("pulp", pulp, s, bg, .ui)                      // focus rings, toggles, icons
        }
        return list
    }()

    // MARK: Contrast

    static func linear(_ c: UInt32) -> Double {
        let v = Double(c) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    static func rgb(_ hex: UInt32) -> (Double, Double, Double) { (linear(hex >> 16 & 0xFF), linear(hex >> 8 & 0xFF), linear(hex & 0xFF)) }

    public static func luminance(_ hex: UInt32) -> Double {
        let (r, g, b) = rgb(hex)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// WCAG's contrast ratio, from 1 to 21.
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    // MARK: Color vision

    /// The common kinds of color blindness, simulated with Machado, Oliveira and Fernandes (2009) at full strength,
    /// and achromatopsia as luminance only.
    public enum Vision: String, CaseIterable, Sendable {
        case typical, protanopia, deuteranopia, tritanopia, achromatopsia
    }

    static let matrices: [Vision: [[Double]]] = [
        .protanopia: [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]],
        .deuteranopia: [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]],
        .tritanopia: [[1.255528, -0.076749, -0.178779], [-0.078411, 0.930809, 0.147602], [0.004733, 0.691367, 0.303900]],
    ]

    static func encode(_ v: Double) -> UInt32 {
        let c = min(max(v, 0), 1)
        let s = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        return UInt32((s * 255).rounded())
    }

    /// How a color looks with that kind of color vision.
    public static func simulate(_ hex: UInt32, _ vision: Vision) -> UInt32 {
        let (r, g, b) = rgb(hex)
        let out: (Double, Double, Double)
        switch vision {
        case .typical: return hex
        case .achromatopsia:
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            out = (y, y, y)
        default:
            let m = matrices[vision]!
            out = (m[0][0] * r + m[0][1] * g + m[0][2] * b, m[1][0] * r + m[1][1] * g + m[1][2] * b, m[2][0] * r + m[2][1] * g + m[2][2] * b)
        }
        return encode(out.0) << 16 | encode(out.1) << 8 | encode(out.2)
    }

    // MARK: The audit

    public struct Finding: Sendable {
        public let pair: Pair, mode: Mode, vision: Vision, ratio: Double
        public var line: String {
            "\(pair.foreground) on \(pair.background) (\(pair.use.rawValue)), \(mode.rawValue)\(vision == .typical ? "" : ", \(vision.rawValue)"): \(String(format: "%.2f", ratio)):1, needs \(pair.use.minimum):1"
        }
    }

    /// Every pair, in every appearance and with every kind of color vision, that falls under its minimum. Empty means it all passes.
    public static func failures() -> [Finding] {
        var out: [Finding] = []
        for pair in pairs {
            for mode in Mode.allCases {
                for vision in Vision.allCases {
                    let r = contrast(simulate(pair.fg.hex(mode), vision), simulate(pair.bg.hex(mode), vision))
                    if r < pair.use.minimum { out.append(Finding(pair: pair, mode: mode, vision: vision, ratio: r)) }
                }
            }
        }
        return out
    }

    /// The lowest ratio for each pair across everything, for the written audit.
    public static func lowest() -> [(Pair, Double, Mode, Vision)] {
        pairs.map { pair in
            var low = (Double.infinity, Mode.light, Vision.typical)
            for mode in Mode.allCases {
                for vision in Vision.allCases {
                    let r = contrast(simulate(pair.fg.hex(mode), vision), simulate(pair.bg.hex(mode), vision))
                    if r < low.0 { low = (r, mode, vision) }
                }
            }
            return (pair, low.0, low.1, low.2)
        }
    }
}
