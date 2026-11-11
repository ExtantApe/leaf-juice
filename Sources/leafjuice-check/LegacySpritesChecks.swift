import CoreGraphics
import Foundation
import ImageIO
import LeafJuiceCore
import UniformTypeIdentifiers

// K159: old (pre-1.20.2) sheets in a pack become the separate sprite files newer versions read. Offline; every image
// here is made up in code.

private struct RGBA: Equatable, CustomStringConvertible {
    let r, g, b, a: UInt8
    init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) { self.r = r; self.g = g; self.b = b; self.a = a }
    var description: String { "(\(r),\(g),\(b),\(a))" }
    static let clear = RGBA(0, 0, 0, 0)
}

/// A made-up image: a background with filled rectangles, given in a reference size and drawn at `scale`.
private func makePNG(_ url: URL, width: Int, height: Int, scale: Int = 1, background: RGBA, rects: [(Int, Int, Int, Int, RGBA)]) {
    let w = width * scale, h = height * scale
    var px = [UInt8](repeating: 0, count: w * h * 4)
    func fill(_ x: Int, _ y: Int, _ rw: Int, _ rh: Int, _ c: RGBA) {
        for yy in y ..< min(h, y + rh) { for xx in x ..< min(w, x + rw) {
            let i = (yy * w + xx) * 4
            px[i] = c.r; px[i + 1] = c.g; px[i + 2] = c.b; px[i + 3] = c.a
        } }
    }
    fill(0, 0, w, h, background)
    for (x, y, rw, rh, c) in rects { fill(x * scale, y * scale, rw * scale, rh * scale, c) }
    let provider = CGDataProvider(data: Data(px) as CFData)!
    let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    precondition(CGImageDestinationFinalize(dest))
}

/// Size and pixels of a PNG, read independently of the code under test.
private func readPNG(_ url: URL) -> (w: Int, h: Int, at: (Int, Int) -> RGBA)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = cg.width, h = cg.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ok = px.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard ok else { return nil }
    // Only opaque or fully clear pixels are used here, so premultiplying changes nothing.
    return (w, h, { x, y in let i = (y * w + x) * 4; return RGBA(px[i], px[i + 1], px[i + 2], px[i + 3]) })
}

private func listFiles(_ root: URL) -> [String] {
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: []) else { return [] }
    var out: [String] = []
    let base = root.resolvingSymlinksInPath().path
    for case let u as URL in e where !FileOps.isDirectory(u) { out.append(String(u.resolvingSymlinksInPath().path.dropFirst(base.count + 1))) }
    return out.sorted()
}

@MainActor func runLegacySpritesChecks() async {
    section("Old pack sheets become sprites (K159)")
    let gui = "assets/minecraft/textures/gui/"
    let sprites = gui + "sprites/"
    let red = RGBA(220, 20, 20), green = RGBA(20, 200, 40), blue = RGBA(30, 60, 230), yellow = RGBA(240, 220, 10)
    let grey = RGBA(120, 120, 120), purple = RGBA(150, 40, 170), cyan = RGBA(10, 200, 210), mark = RGBA(255, 128, 0)
    // widgets.png regions as the 1.20.2 table reads them (256×256 reference).
    let widgetRects: [(Int, Int, Int, Int, RGBA)] = [
        (0, 0, 182, 22, blue),      // hud/hotbar
        (0, 46, 200, 20, green),    // widget/button_disabled
        (0, 66, 200, 20, red),      // widget/button
        (0, 86, 200, 20, purple),   // widget/button_highlighted
        (0, 146, 20, 20, yellow),   // widget/locked_button
        (182, 24, 15, 15, cyan),    // icon/draft_report
    ]

    // The tables themselves.
    let counts = LegacySprites.mappingCounts
    equal(counts.map(\.step), [.v1_20_2, .v1_20_5, .v26_2], "three steps, in order")
    equal(counts.map(\.inputs), [136, 1, 41], "sheets read per step")
    equal(counts.map(\.outputs), [473, 34, 150], "files made per step")

    // Paths are kept inside the pack.
    let safety = folder("legacy-safety")
    check(LegacySprites.safeTarget("../escape.png", in: safety) == nil, "a leading .. is refused")
    check(LegacySprites.safeTarget("assets/../../escape.png", in: safety) == nil, "a .. in the middle is refused")
    check(LegacySprites.safeTarget("/etc/hosts", in: safety) == nil, "an absolute path is refused")
    check(LegacySprites.safeTarget("assets/./x.png", in: safety) == nil, "a . part is refused")
    check(LegacySprites.safeTarget("assets//x.png", in: safety) == nil, "an empty part is refused")
    check(LegacySprites.safeTarget("assets/minecraft/x.png", in: safety) != nil, "an ordinary path is allowed")

    do {
        // A 256×256 pack with every kind of mapping in it.
        let pack = folder("legacy-pack-1x")
        let widgets = pack.appendingPathComponent(gui + "widgets.png")
        makePNG(widgets, width: 256, height: 256, background: grey, rects: widgetRects)
        let widgetsBefore = try Data(contentsOf: widgets)
        // Something the person made already sits where button_highlighted.png goes.
        let mine = pack.appendingPathComponent(sprites + "widget/button_highlighted.png")
        write("not really a png, but mine", mine)
        // Two animation frames side by side become stacked (flipFrameAxis), with the table's metadata.
        makePNG(pack.appendingPathComponent("assets/realms/textures/gui/realms/expires_soon_icon.png"), width: 40, height: 28,
                background: green, rects: [(20, 0, 20, 28, red)])
        // A whole-file move from realms to minecraft is a byte copy.
        makePNG(pack.appendingPathComponent("assets/realms/textures/gui/realms/adventure.png"), width: 16, height: 16, background: cyan, rects: [])
        // An in-place clip would overwrite the sheet, so it's skipped.
        makePNG(pack.appendingPathComponent(gui + "container/anvil.png"), width: 256, height: 256, background: grey,
                rects: [(176, 0, 28, 21, yellow)])
        // 1.20.5: map_icons.png, 16 icons a row of 8×8.
        makePNG(pack.appendingPathComponent("assets/minecraft/textures/map/map_icons.png"), width: 128, height: 128,
                background: grey, rects: [(72, 0, 8, 8, blue), (64, 8, 8, 8, red)])
        // 26.2: a bed (multipart, rotated) and the black bed's static parts.
        let bedRects: [(Int, Int, Int, Int, RGBA)] = [(6, 6, 16, 16, purple), (0, 28, 6, 16, cyan), (0, 28, 1, 1, mark), (5, 28, 1, 1, yellow),
                                                      (28, 6, 16, 16, green), (28, 6, 1, 1, mark)]
        makePNG(pack.appendingPathComponent("assets/minecraft/textures/entity/bed/red.png"), width: 64, height: 64, background: .clear, rects: bedRects)
        makePNG(pack.appendingPathComponent("assets/minecraft/textures/entity/bed/black.png"), width: 64, height: 64, background: .clear, rects: bedRects)

        let before = listFiles(pack)
        let report = try LegacySprites.migrate(packRoot: pack)
        let written = Set(report.written.map(\.path))
        func reason(_ path: String) -> LegacySprites.SkipReason? { report.skipped.first { $0.path == path }?.reason }

        // The right files at the right paths.
        for name in ["widget/button", "widget/button_disabled", "widget/locked_button", "widget/unlocked_button", "hud/hotbar",
                     "hud/hotbar_selection", "hud/hotbar_offhand_left", "icon/draft_report"] {
            check(written.contains(sprites + name + ".png") && FileOps.exists(pack.appendingPathComponent(sprites + name + ".png")), "\(name).png written")
        }
        check(written.contains(sprites + "widget/button.png.mcmeta"), "button nine-slice metadata written")
        let meta = (try? String(contentsOf: pack.appendingPathComponent(sprites + "widget/button.png.mcmeta"), encoding: .utf8)) ?? ""
        check(meta.contains("\"type\": \"nine_slice\"") && meta.contains("\"width\": 200") && meta.contains("\"left\": 20"), "the metadata is the Java's nine_slice JSON")
        check(meta.hasPrefix("{\n    \"gui\": {"), "with the Java text block's indentation")
        check(!FileOps.exists(pack.appendingPathComponent(sprites + "hud/hotbar.png.mcmeta")), "no metadata where the Java writes none")
        check(report.written.allSatisfy { $0.step != .v1_20_2 || $0.source.hasPrefix("assets/") }, "every write names its sheet")

        // A pixel from each region lands where it should.
        if let p = readPNG(pack.appendingPathComponent(sprites + "widget/button.png")) {
            equal(p.w, 200, "button width"); equal(p.h, 20, "button height")
            equal(p.at(0, 0), red, "button: top-left from its region"); equal(p.at(199, 19), red, "button: bottom-right from its region")
        } else { check(false, "button.png readable") }
        if let p = readPNG(pack.appendingPathComponent(sprites + "widget/button_disabled.png")) { equal(p.at(100, 10), green, "disabled button from its region") }
        else { check(false, "button_disabled.png readable") }
        if let p = readPNG(pack.appendingPathComponent(sprites + "hud/hotbar.png")) {
            equal(p.w, 182, "hotbar width"); equal(p.h, 22, "hotbar height"); equal(p.at(181, 21), blue, "hotbar from its region")
        } else { check(false, "hotbar.png readable") }
        if let p = readPNG(pack.appendingPathComponent(sprites + "widget/locked_button.png")) { equal(p.at(19, 19), yellow, "locked button from its region") }
        else { check(false, "locked_button.png readable") }
        if let p = readPNG(pack.appendingPathComponent(sprites + "widget/unlocked_button.png")) { equal(p.at(0, 0), grey, "unlocked button from the background next to it") }
        else { check(false, "unlocked_button.png readable") }
        if let p = readPNG(pack.appendingPathComponent(sprites + "icon/draft_report.png")) {
            equal(p.w, 15, "draft report width"); equal(p.at(7, 7), cyan, "draft report from its region")
        } else { check(false, "draft_report.png readable") }

        // flipFrameAxis(2) with its animation metadata.
        if let p = readPNG(pack.appendingPathComponent(sprites + "realm_status/expires_soon.png")) {
            equal(p.w, 20, "frames stacked: width is one frame"); equal(p.h, 56, "frames stacked: height is two")
            equal(p.at(10, 10), green, "first frame on top"); equal(p.at(10, 40), red, "second frame below")
        } else { check(false, "expires_soon.png readable") }
        let anim = (try? String(contentsOf: pack.appendingPathComponent(sprites + "realm_status/expires_soon.png.mcmeta"), encoding: .utf8)) ?? ""
        check(anim.contains("\"frametime\": 10") && anim.contains("\"height\": 28"), "animation metadata written")

        // Byte copy for a whole-image move.
        equal(try? Data(contentsOf: pack.appendingPathComponent(gui + "realms/adventure.png")),
              try? Data(contentsOf: pack.appendingPathComponent("assets/realms/textures/gui/realms/adventure.png")), "realms image moved byte for byte")
        equal(reason(gui + "container/anvil.png"), .sameAsSource, "an in-place clip is skipped, not overwritten")
        if let p = readPNG(pack.appendingPathComponent(sprites + "container/anvil/error.png")) {
            equal(p.w, 28, "anvil error width"); equal(p.at(27, 20), yellow, "the anvil's sprites still come out of the same sheet")
        } else { check(false, "anvil error.png readable") }

        // 1.20.5
        if let p = readPNG(pack.appendingPathComponent("assets/minecraft/textures/map/decorations/ocean_monument.png")) {
            equal(p.w, 8, "map decoration size"); equal(p.at(3, 3), blue, "icon 9 from its cell")
        } else { check(false, "ocean_monument.png readable") }
        if let p = readPNG(pack.appendingPathComponent("assets/minecraft/textures/map/decorations/red_banner.png")) { equal(p.at(0, 0), red, "icon 24 from row 2") }
        else { check(false, "red_banner.png readable") }
        check(report.written.contains { $0.step == .v1_20_5 && $0.path.hasSuffix("decorations/player.png") }, "1.20.5 writes are reported as 1.20.5")

        // 26.2: simple, multipart with a rotation, and a rotate180.
        let block = "assets/minecraft/textures/block/"
        if let p = readPNG(pack.appendingPathComponent(block + "red_bed_head_up.png")) {
            equal(p.w, 16, "bed head size"); equal(p.at(8, 8), purple, "bed head from its region")
        } else { check(false, "red_bed_head_up.png readable") }
        if let p = readPNG(pack.appendingPathComponent(block + "red_bed_foot_west.png")) {
            equal(p.w, 16, "multipart canvas width"); equal(p.h, 16, "multipart canvas height")
            // Box (0,28,6,16) turned by rotate270 and drawn at (0,7): source (0,0) lands at (0,12), source (5,0) at (0,7).
            equal(p.at(0, 12), mark, "rotate270 puts the corner where the Java does")
            equal(p.at(0, 7), yellow, "and the other corner")
            equal(p.at(8, 9), cyan, "the rest of the part")
            equal(p.at(8, 2).a, 0, "outside every part stays clear")
        } else { check(false, "red_bed_foot_west.png readable") }
        if let p = readPNG(pack.appendingPathComponent(block + "bed_down.png")) {
            equal(p.at(15, 15), mark, "rotate180 moves the top-left to the bottom-right"); equal(p.at(0, 0), green, "and keeps the rest")
        } else { check(false, "bed_down.png readable") }
        check(written.contains(block + "red_bed_head_east.png") && written.contains(block + "bed_head_north.png"), "every bed part written")
        check(report.written.filter { $0.step == .v26_2 }.allSatisfy { $0.path.hasPrefix("assets/minecraft/") }, "26.2 writes land under assets/")

        // Existing files and the old sheets are left alone.
        equal(try? String(contentsOf: mine, encoding: .utf8), "not really a png, but mine", "an existing sprite isn't overwritten")
        equal(reason(sprites + "widget/button_highlighted.png"), .alreadyExists, "and the report says why")
        check(!FileOps.exists(pack.appendingPathComponent(sprites + "widget/button_highlighted.png.mcmeta")), "nor does it get the Java's metadata")
        equal(try? Data(contentsOf: widgets), widgetsBefore, "the old sheet is unchanged")
        let after = listFiles(pack)
        check(before.allSatisfy(after.contains), "no file was removed")
        equal(after.count, before.count + report.written.count, "every new file is in the report, and only those")
        equal(reason(gui + "icons.png"), .sourceMissing, "a missing sheet is reported")

        // A second run finds everything already there.
        let again = try LegacySprites.migrate(packRoot: pack)
        equal(again.written.count, 0, "a second run writes nothing")
        check(again.skipped.contains { $0.path == sprites + "widget/button.png" && $0.reason == .alreadyExists }, "and says the sprites exist")
        equal(listFiles(pack), after, "and changes nothing")
    } catch { failures.append("legacy sprites (1x) threw: \(error)") }

    do {
        // The same sheet at 512×512: boxes scale with the image.
        let pack = folder("legacy-pack-2x")
        makePNG(pack.appendingPathComponent(gui + "widgets.png"), width: 256, height: 256, scale: 2, background: grey, rects: widgetRects)
        makePNG(pack.appendingPathComponent("assets/minecraft/textures/entity/bed/red.png"), width: 64, height: 64, scale: 2, background: .clear,
                rects: [(0, 28, 6, 16, cyan), (0, 28, 1, 1, mark)])
        let report = try LegacySprites.migrate(packRoot: pack)
        check(!report.written.isEmpty, "a 2x pack is migrated")
        if let p = readPNG(pack.appendingPathComponent(sprites + "widget/button.png")) {
            equal(p.w, 400, "2x button width"); equal(p.h, 40, "2x button height")
            equal(p.at(0, 0), red, "2x button top-left"); equal(p.at(399, 39), red, "2x button bottom-right")
        } else { check(false, "2x button.png readable") }
        if let p = readPNG(pack.appendingPathComponent(sprites + "widget/locked_button.png")) {
            equal(p.w, 40, "2x locked button size"); equal(p.at(39, 39), yellow, "2x locked button from its region")
        } else { check(false, "2x locked_button.png readable") }
        if let p = readPNG(pack.appendingPathComponent(sprites + "hud/hotbar.png")) { equal(p.w, 364, "2x hotbar width"); equal(p.h, 44, "2x hotbar height") }
        else { check(false, "2x hotbar.png readable") }
        if let p = readPNG(pack.appendingPathComponent("assets/minecraft/textures/block/red_bed_foot_west.png")) {
            equal(p.w, 32, "2x multipart canvas"); equal(p.at(0, 24), mark, "2x offsets scale too"); equal(p.at(1, 25), mark, "2x part is 2x")
        } else { check(false, "2x red_bed_foot_west.png readable") }
    } catch { failures.append("legacy sprites (2x) threw: \(error)") }

    do {
        // A pack with no old sheets writes nothing.
        let pack = folder("legacy-pack-new")
        makePNG(pack.appendingPathComponent(sprites + "widget/button.png"), width: 200, height: 20, background: red, rects: [])
        write("{\"pack\":{\"pack_format\":34,\"description\":\"new\"}}", pack.appendingPathComponent("pack.mcmeta"))
        let before = listFiles(pack)
        let report = try LegacySprites.migrate(packRoot: pack)
        equal(report.written.count, 0, "a pack without old sheets writes nothing")
        check(report.skipped.allSatisfy { $0.reason == .sourceMissing }, "every sheet reported missing")
        equal(listFiles(pack), before, "and nothing changes")
        // Not a folder at all.
        var threw = false
        do { _ = try LegacySprites.migrate(packRoot: pack.appendingPathComponent("pack.mcmeta")) } catch { threw = true }
        check(threw, "a file isn't taken for a pack folder")
    } catch { failures.append("legacy sprites (new pack) threw: \(error)") }

    do {
        // Nothing is written outside the pack, even through a link inside it.
        let base = folder("legacy-escape")
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileOps.ensureDir(outside)
        let pack = base.appendingPathComponent("pack", isDirectory: true)
        makePNG(pack.appendingPathComponent(gui + "widgets.png"), width: 256, height: 256, background: grey, rects: widgetRects)
        makePNG(pack.appendingPathComponent("assets/minecraft/textures/map/map_icons.png"), width: 128, height: 128, background: grey, rects: [])
        try FileManager.default.createSymbolicLink(at: pack.appendingPathComponent(sprites), withDestinationURL: outside)
        // A dangling link where one decoration goes, pointing out of the pack.
        try FileOps.ensureDir(pack.appendingPathComponent("assets/minecraft/textures/map/decorations"))
        try FileManager.default.createSymbolicLink(at: pack.appendingPathComponent("assets/minecraft/textures/map/decorations/player.png"),
                                                   withDestinationURL: outside.appendingPathComponent("player.png"))
        let report = try LegacySprites.migrate(packRoot: pack)
        equal(listFiles(outside), [], "nothing written outside the pack")
        check(report.skipped.contains { $0.path == sprites + "widget/button.png" && $0.reason == .unsafePath }, "a sprite behind a link out is refused as unsafe")
        check(report.skipped.contains { $0.path.hasSuffix("decorations/player.png") && $0.reason == .unsafePath }, "a dangling link out isn't written through")
        check(report.written.contains { $0.path.hasSuffix("decorations/frame.png") }, "the rest of the pack is still migrated")
        check(report.written.allSatisfy { LegacySprites.safeTarget($0.path, in: pack) != nil }, "every write is inside the pack")
    } catch { failures.append("legacy sprites (escape) threw: \(error)") }
}
