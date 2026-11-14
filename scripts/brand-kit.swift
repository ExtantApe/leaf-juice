#!/usr/bin/env swift
// Builds the LeafJuice brand kit from one master file: a pixel-art mark in `mark.txt`.
//   swift scripts/brand-kit.swift brand/drafts/2026-11-14
// Writes into <folder>/out: the mark as SVG, circle and square profile marks in light and dark, the app icon at
// 1024 and 32, the GitHub social preview, README headers, and X, Bluesky and LinkedIn banners.
// Every text and outline pair is checked against WCAG first (D149): large text 3:1, small text 4.5:1, outlines
// 3:1. If any pair fails, nothing is written and the script exits 1.
import AppKit

// MARK: The master

struct Mark {
    var size: Int
    var cells: [[UInt32?]]
    var palette: [Character: UInt32]
}

func readMark(_ url: URL) -> Mark {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { fail("Can't read \(url.path).") }
    var palette: [Character: UInt32] = [:]
    var rows: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("#") || line.isEmpty { continue }
        if line.hasPrefix("palette ") {
            let parts = line.split(separator: " ")
            guard parts.count >= 3, parts[1].count == 1, let hex = UInt32(parts[2].dropFirst(), radix: 16) else { fail("Bad palette line: \(line)") }
            palette[parts[1].first!] = hex
        } else {
            rows.append(String(line))
        }
    }
    guard !rows.isEmpty, rows.allSatisfy({ $0.count == rows.count }) else { fail("The mark must be square: every row as long as there are rows.") }
    let cells = rows.map { row in row.map { c -> UInt32? in
        if c == "." { return nil }
        guard let hex = palette[c] else { fail("\"\(c)\" isn't in the palette.") }
        return hex
    } }
    return Mark(size: rows.count, cells: cells, palette: palette)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("brand-kit: \(message)\n".utf8))
    exit(1)
}

// MARK: Colors and WCAG

let ink: UInt32 = 0x2A3520, cream: UInt32 = 0xF8F6E9, surface: UInt32 = 0xFFFEF8, muted: UInt32 = 0x55614A
let darkBack: UInt32 = 0x2A3225, darkInk: UInt32 = 0xF4F6E9, darkMuted: UInt32 = 0xCBD4BC
let tileTop: UInt32 = 0xEDF5D6, tileBottom: UInt32 = 0xCDE3A5, darkTileTop: UInt32 = 0x414D39, darkTileBottom: UInt32 = 0x343E2E
let grapefruit: UInt32 = 0xF4846B

func linear(_ c: UInt32) -> Double { let v = Double(c) / 255; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
func luminance(_ h: UInt32) -> Double { 0.2126 * linear(h >> 16 & 0xFF) + 0.7152 * linear(h >> 8 & 0xFF) + 0.0722 * linear(h & 0xFF) }
func contrast(_ a: UInt32, _ b: UInt32) -> Double { let x = luminance(a), y = luminance(b); return (max(x, y) + 0.05) / (min(x, y) + 0.05) }

struct Pair { let what: String; let fg: UInt32; let bg: UInt32; let minimum: Double }

func checkPairs(_ pairs: [Pair]) -> [String] {
    pairs.compactMap { p in
        let r = contrast(p.fg, p.bg)
        return r < p.minimum ? "\(p.what): \(String(format: "%.2f", r)):1, needs \(p.minimum):1" : nil
    }
}

// MARK: Drawing

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func cg(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func canvas(_ w: Int, _ h: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .none
    ctx.setShouldAntialias(true)
    return ctx
}

/// Draws the mark with its top-left at (x, y) in top-down coordinates, each pixel `cell` points wide.
func drawMark(_ m: Mark, in ctx: CGContext, x: CGFloat, y: CGFloat, cell: CGFloat, height: Int) {
    ctx.setShouldAntialias(false)
    for (row, cells) in m.cells.enumerated() {
        for (col, hex) in cells.enumerated() {
            guard let hex else { continue }
            ctx.setFillColor(cg(hex))
            let top = y + CGFloat(row) * cell
            ctx.fill(CGRect(x: (x + CGFloat(col) * cell).rounded(), y: (CGFloat(height) - top - cell).rounded(), width: cell.rounded(), height: cell.rounded()))
        }
    }
    ctx.setShouldAntialias(true)
}

func gradient(_ ctx: CGContext, _ top: UInt32, _ bottom: UInt32, _ rect: CGRect) {
    let g = CGGradient(colorsSpace: sRGB, colors: [cg(top), cg(bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
}

/// A profile mark: the mark centred on a disc or a rounded square, with clear space all round.
func profile(_ m: Mark, size: Int, circle: Bool, dark: Bool) -> CGImage {
    let ctx = canvas(size, size)
    let s = CGFloat(size)
    let shape = circle ? CGPath(ellipseIn: CGRect(x: 0, y: 0, width: s, height: s), transform: nil)
                       : CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s), cornerWidth: s * 0.2, cornerHeight: s * 0.2, transform: nil)
    ctx.addPath(shape); ctx.clip()
    gradient(ctx, dark ? darkTileTop : tileTop, dark ? darkTileBottom : tileBottom, CGRect(x: 0, y: 0, width: s, height: s))
    // A circle needs more clear space than a square for the corners of the art to stay inside.
    let cell = (s * (circle ? 0.62 : 0.72) / CGFloat(m.size)).rounded(.down)
    let art = cell * CGFloat(m.size)
    drawMark(m, in: ctx, x: (s - art) / 2, y: (s - art) / 2, cell: cell, height: size)
    return ctx.makeImage()!
}

/// The macOS app icon: the square mark on a 824-point tile inside a 1024 canvas, as Apple's grid has it.
func appIcon(_ m: Mark, size: Int) -> CGImage {
    let ctx = canvas(size, size)
    let s = CGFloat(size)
    let inset = size <= 64 ? s * 0.04 : s * 0.0977
    let tile = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)); ctx.clip()
    gradient(ctx, tileTop, tileBottom, tile)
    let cell = max(1, (tile.width * 0.78 / CGFloat(m.size)).rounded(.down))
    let art = cell * CGFloat(m.size)
    drawMark(m, in: ctx, x: (s - art) / 2, y: (s - art) / 2, cell: cell, height: size)
    return ctx.makeImage()!
}

func text(_ ctx: CGContext, _ string: String, size: CGFloat, weight: NSFont.Weight, color: UInt32, x: CGFloat, baseline: CGFloat, height: Int) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font(size, weight), .foregroundColor: NSColor(cgColor: cg(color))!]))
    ctx.textPosition = CGPoint(x: x, y: CGFloat(height) - baseline)
    CTLineDraw(line, ctx)
}

let tagline = "Run your Minecraft server from your Mac."

func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}

func width(_ string: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font(size, weight)]))
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
}

/// A wide image: the mark on the left and the name and tagline beside it, centred as a group.
func banner(_ m: Mark, w: Int, h: Int, dark: Bool, showTagline: Bool = true) -> CGImage {
    let ctx = canvas(w, h)
    ctx.setFillColor(cg(dark ? darkBack : cream)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    // A band of grapefruit along the bottom: the one pop of colour, as in the app.
    ctx.setFillColor(cg(grapefruit)); ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: max(4, CGFloat(h) * 0.025)))
    let H = CGFloat(h)
    let cell = (H * 0.5 / CGFloat(m.size)).rounded(.down)
    let art = cell * CGFloat(m.size)
    let nameSize = H * 0.22, tagSize = H * 0.075
    let nameWidth = width("LeafJuice", size: nameSize, weight: .bold)
    let tagWidth = showTagline ? width(tagline, size: tagSize, weight: .medium) : 0
    let group = art + H * 0.08 + max(nameWidth, tagWidth)
    let left = (CGFloat(w) - group) / 2
    drawMark(m, in: ctx, x: left, y: (H - art) / 2, cell: cell, height: h)
    let textX = left + art + H * 0.08
    text(ctx, "LeafJuice", size: nameSize, weight: .bold, color: dark ? darkInk : ink, x: textX, baseline: H * (showTagline ? 0.53 : 0.58), height: h)
    if showTagline {
        text(ctx, tagline, size: tagSize, weight: .medium, color: dark ? darkMuted : muted, x: textX, baseline: H * 0.68, height: h)
    }
    return ctx.makeImage()!
}

func svg(_ m: Mark, scale: Int) -> String {
    var out = #"<svg xmlns="http://www.w3.org/2000/svg" width="\#(m.size * scale)" height="\#(m.size * scale)" viewBox="0 0 \#(m.size) \#(m.size)" shape-rendering="crispEdges" role="img" aria-label="LeafJuice: a glass of green juice with a leaf and a grapefruit slice">"#
    out += "\n<title>LeafJuice</title>\n"
    for (y, row) in m.cells.enumerated() {
        var x = 0
        while x < row.count {
            guard let hex = row[x] else { x += 1; continue }
            var run = 1
            while x + run < row.count, row[x + run] == hex { run += 1 }
            let fill = "#" + String(format: "%06X", hex)
            out += "<rect x=\"\(x)\" y=\"\(y)\" width=\"\(run)\" height=\"1\" fill=\"\(fill)\"/>\n"
            x += run
        }
    }
    return out + "</svg>\n"
}

func save(_ image: CGImage, _ url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { fail("Couldn't encode \(url.lastPathComponent).") }
    do { try data.write(to: url) } catch { fail("Couldn't write \(url.path).") }
}

// MARK: Run

guard CommandLine.arguments.count >= 2 else { fail("Usage: swift scripts/brand-kit.swift <folder with mark.txt>") }
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let mark = readMark(folder.appendingPathComponent("mark.txt"))

// Checked first, and fails closed: nothing is written if any pair is short.
var pairs: [Pair] = [
    Pair(what: "name on cream (large text)", fg: ink, bg: cream, minimum: 3),
    Pair(what: "name on dark (large text)", fg: darkInk, bg: darkBack, minimum: 3),
    Pair(what: "tagline on cream (small text)", fg: muted, bg: cream, minimum: 4.5),
    Pair(what: "tagline on dark (small text)", fg: darkMuted, bg: darkBack, minimum: 4.5),
]
// The mark's outline has to stand off every background it's put on, so its shape reads.
let outline = mark.palette["o"] ?? ink
for (name, bg) in [("light tile top", tileTop), ("light tile bottom", tileBottom), ("cream", cream)] {
    pairs.append(Pair(what: "mark outline on \(name)", fg: outline, bg: bg, minimum: 3))
}
// On the dark tile the outline is dark too, so the glass and juice carry the shape there: they must stand off it.
for (key, name) in [(Character("g"), "glass"), (Character("j"), "juice")] {
    if let hex = mark.palette[key] {
        pairs.append(Pair(what: "mark \(name) on the dark tile", fg: hex, bg: darkTileBottom, minimum: 3))
        pairs.append(Pair(what: "mark \(name) on dark", fg: hex, bg: darkBack, minimum: 3))
    }
}
let failures = checkPairs(pairs)
guard failures.isEmpty else { fail("WCAG check failed, nothing written:\n  " + failures.joined(separator: "\n  ")) }

let out = folder.appendingPathComponent("out")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try! svg(mark, scale: 64).write(to: out.appendingPathComponent("mark.svg"), atomically: true, encoding: .utf8)
for dark in [false, true] {
    let tone = dark ? "dark" : "light"
    for circle in [true, false] {
        save(profile(mark, size: 1024, circle: circle, dark: dark), out.appendingPathComponent("mark-\(circle ? "circle" : "square")-\(tone)-1024.png"))
        save(profile(mark, size: 400, circle: circle, dark: dark), out.appendingPathComponent("mark-\(circle ? "circle" : "square")-\(tone)-400.png"))
    }
    save(banner(mark, w: 1280, h: 640, dark: dark), out.appendingPathComponent("github-social-preview-\(tone)-1280x640.png"))
    save(banner(mark, w: 1280, h: 320, dark: dark), out.appendingPathComponent("readme-header-\(tone)-1280x320.png"))
    save(banner(mark, w: 1500, h: 500, dark: dark), out.appendingPathComponent("x-header-\(tone)-1500x500.png"))
    save(banner(mark, w: 3000, h: 1000, dark: dark), out.appendingPathComponent("bluesky-banner-\(tone)-3000x1000.png"))
    save(banner(mark, w: 1584, h: 396, dark: dark), out.appendingPathComponent("linkedin-banner-\(tone)-1584x396.png"))
    save(banner(mark, w: 1128, h: 191, dark: dark, showTagline: false), out.appendingPathComponent("linkedin-company-banner-\(tone)-1128x191.png"))
}
save(appIcon(mark, size: 1024), out.appendingPathComponent("app-icon-1024.png"))
save(appIcon(mark, size: 32), out.appendingPathComponent("app-icon-32.png"))
// Bluesky refuses images over 1,000,000 bytes (its lexicon limit), so a banner that grows past it fails the build.
for name in ["bluesky-banner-light-3000x1000.png", "bluesky-banner-dark-3000x1000.png"] {
    let size = (try? FileManager.default.attributesOfItem(atPath: out.appendingPathComponent(name).path)[.size] as? Int) ?? 0
    if size > 1_000_000 { fail("\(name) is \(size) bytes, over Bluesky's 1,000,000-byte limit.") }
}
print("Wrote the kit to \(out.path). WCAG: \(pairs.count) pairs passed.")
for p in pairs { print("  \(p.what): \(String(format: "%.2f", contrast(p.fg, p.bg))):1") }
