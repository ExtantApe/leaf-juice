#!/usr/bin/env swift
// Builds the app icon from the artwork in brand/icon-source.png: brand/icon-1024.png,
// brand/icon-small.png and brand/AppIcon.icns.
// The artwork's black background is removed, the glass goes on a pale pistachio tile (896 x 896 on
// a 1024 canvas, corner radius 200), and a pink grapefruit wheel sits on the rim.
import AppKit

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let outline = (r: 63.0, g: 82.0, b: 54.0)   // The artwork's line color, #3F5236.

/// Makes the black background transparent. Filling inward from the edges leaves any dark pixels
/// inside the glass alone; soft edge pixels become the line color at partial opacity.
func removeBackground(_ image: CGImage) -> CGImage {
    let w = image.width, h = image.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let px = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
    let limit = 78
    func level(_ i: Int) -> Int { max(Int(px[i * 4]), Int(px[i * 4 + 1]), Int(px[i * 4 + 2])) }
    var seen = [Bool](repeating: false, count: w * h)
    var stack: [Int] = []
    for x in 0..<w { stack += [x, (h - 1) * w + x] }
    for y in 0..<h { stack += [y * w, y * w + w - 1] }
    while let i = stack.popLast() {
        if seen[i] || level(i) >= limit { continue }
        seen[i] = true
        let x = i % w, y = i / w
        if x > 0 { stack.append(i - 1) }
        if x < w - 1 { stack.append(i + 1) }
        if y > 0 { stack.append(i - w) }
        if y < h - 1 { stack.append(i + w) }
    }
    for i in 0..<(w * h) where seen[i] {
        let a = min(1, Double(level(i)) / outline.g)
        px[i * 4] = UInt8(outline.r * a); px[i * 4 + 1] = UInt8(outline.g * a); px[i * 4 + 2] = UInt8(outline.b * a); px[i * 4 + 3] = UInt8(255 * a)
    }
    return ctx.makeImage()!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "brand", isDirectory: true)
guard let raw = NSImage(contentsOf: root.appendingPathComponent("icon-source.png"))?
    .cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("brand/icon-source.png is missing") }
let glass = removeBackground(raw)

func draw(size: Int, small: Bool) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let s = CGFloat(size) / 1024
    ctx.scaleBy(x: s, y: s)

    let tile = small ? CGRect(x: 16, y: 16, width: 992, height: 992) : CGRect(x: 64, y: 64, width: 896, height: 896)
    let radius: CGFloat = small ? 220 : 200
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: sRGB, colors: [color(0xEDF5D6), color(0xCDE3A5)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    // In source pixels, the glass and wheel together span x 330-1000, y 165-1065.
    let source = CGFloat(raw.width)
    let scale = tile.height * (small ? 0.88 : 0.74) / (1065 - 165)
    let width = source * scale
    let originX = 512 - 665 * scale, originY = 512 - (source - 615) * scale
    ctx.draw(glass, in: CGRect(x: originX, y: originY, width: width, height: width))

    // The grapefruit wheel, in the artwork's line style.
    let center = CGPoint(x: originX + 870 * scale, y: originY + (source - 290) * scale)
    let r = 130 * scale
    let line = (small ? 22 : 18) * scale
    func disc(_ radius: CGFloat, _ fill: UInt32) {
        ctx.setFillColor(color(fill))
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.fillPath()
    }
    disc(r, 0x3F5236)                 // outline
    disc(r - line, 0xF4846B)          // rind
    disc(r - line * 1.9, 0xFBEFD9)    // pith
    disc(r - line * 2.5, 0xF9A08A)    // flesh
    ctx.setStrokeColor(color(0xFBEFD9))
    ctx.setLineCap(.round)
    ctx.setLineWidth(line * 0.55)
    let spokes = small ? 6 : 8
    for i in 0..<spokes {
        let angle = CGFloat(i) / CGFloat(spokes) * .pi * 2 + .pi / 8
        ctx.move(to: center)
        ctx.addLine(to: CGPoint(x: center.x + cos(angle) * (r - line * 2.5), y: center.y + sin(angle) * (r - line * 2.5)))
    }
    ctx.strokePath()
    ctx.restoreGState()
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

try draw(size: 1024, small: false).write(to: root.appendingPathComponent("icon-1024.png"))
try draw(size: 256, small: true).write(to: root.appendingPathComponent("icon-small.png"))

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("LeafJuice-\(UUID().uuidString).iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try draw(size: pixels, small: pixels <= 32).write(to: iconset.appendingPathComponent(name))
}
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try tool.run()
tool.waitUntilExit()
