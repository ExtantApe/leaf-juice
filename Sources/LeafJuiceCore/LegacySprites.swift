// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT license.
//
// This file is a Swift port of Mojang's resource-pack "slicer" (https://github.com/Mojang/slicer): the library
// (Box, TransformedBox, InputFile, OutputFile, SimpleOutputFile, MultipartOutputFile, Slicer) and the mapping tables
// of its 1.20.2, 1.20.5 and 26.2 migrations. The original's licence follows.
//
// MIT License
//
// Copyright (c) Microsoft Corporation. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Differences from the Java tool, all deliberate:
// - It works in place on an unpacked pack folder, where the Java reads one folder (or zip) and writes another. So a
//   file is never overwritten (the Java replaces), and an output whose path is its own input (the Java's copy() and
//   clip() helpers, which tidy the old sheets in the output pack) is skipped. Inputs are read as they were before the
//   run: a file this run wrote is never read back as an input, as the Java never reads its own output.
// - When the sprite already exists, its .mcmeta is left alone too.
// - The optional "leftover" images (copies of the sheets with migrated areas marked) aren't made.
// - Where the Java would stop with an exception (an unreadable image, a box outside a too-small image), that one
//   output, or that one sheet, is skipped with the reason and the rest go on.
// - The 26.2 table's paths start at "minecraft/...", i.e. that Main expects the pack's assets folder as its input;
//   here they are read and written under <pack>/assets/.
// - Images are decoded to 8-bit RGBA and written as 8-bit RGBA PNGs. Java's drawImage onto a blank ARGB image is
//   treated as an exact copy and overlapping parts are blended source-over, unpremultiplied, rounding to nearest.

public enum LegacySprites {
    public enum Step: String, Sendable, CaseIterable, Equatable {
        case v1_20_2 = "1.20.2"
        case v1_20_5 = "1.20.5"
        case v26_2 = "26.2"
    }

    public enum SkipReason: Sendable, Equatable, CustomStringConvertible {
        /// The old sheet isn't in the pack.
        case sourceMissing
        /// The old sheet is there but isn't an image that could be read.
        case sourceUnreadable
        /// Something is already at the new path. It's kept as it is.
        case alreadyExists
        /// The Java tool rewrites this sheet in its own output pack; done in place, that would overwrite it.
        case sameAsSource
        /// The sheet is too small (or the wrong shape) for this part of it.
        case outsideImage
        /// The path would lead out of the pack folder (a ".." or a link pointing elsewhere).
        case unsafePath
        case failed(String)

        public var description: String {
            switch self {
            case .sourceMissing: return "the old sheet isn't in the pack"
            case .sourceUnreadable: return "the old sheet isn't a readable image"
            case .alreadyExists: return "a file is already there, so it was left alone"
            case .sameAsSource: return "it would overwrite the old sheet itself"
            case .outsideImage: return "the sheet is too small or the wrong shape for this part"
            case .unsafePath: return "the path would lead outside the pack"
            case .failed(let why): return why
            }
        }
    }

    public struct Report: Sendable, Equatable {
        public struct Written: Sendable, Equatable {
            public let step: Step
            /// Relative to the pack folder.
            public let path: String
            /// The old sheet it came from, relative to the pack folder.
            public let source: String
        }
        public struct Skipped: Sendable, Equatable {
            public let step: Step
            /// The path that wasn't written (or, for sheet-level reasons, the sheet's path), relative to the pack folder.
            public let path: String
            public let reason: SkipReason
        }
        public internal(set) var written: [Written] = []
        public internal(set) var skipped: [Skipped] = []
        public init() {}
    }

    /// Mappings per step: old sheets read, and new files they become (not counting .mcmeta files).
    public static var mappingCounts: [(step: Step, inputs: Int, outputs: Int)] {
        Step.allCases.map { step in
            let inputs = table(step)
            return (step, inputs.count, inputs.reduce(0) { $0 + $1.outputs.count })
        }
    }

    /// Reads the old sheets in an unpacked pack folder and writes the separate sprite files newer versions read, in
    /// the order 1.20.2, 1.20.5, 26.2. Nothing that exists is overwritten or deleted, and nothing is written outside
    /// `packRoot`.
    public static func migrate(packRoot: URL) throws -> Report {
        guard FileOps.isDirectory(packRoot) else { throw LeafError("\(packRoot.lastPathComponent) isn't a folder.") }
        guard realPath(packRoot) != nil else { throw LeafError("Couldn't find \(packRoot.path).") }
        var report = Report()
        var createdThisRun = Set<String>()
        for step in Step.allCases {
            let base = step == .v26_2 ? "assets/" : ""
            for input in table(step) {
                process(input, base: base, step: step, packRoot: packRoot, created: &createdThisRun, report: &report)
            }
        }
        return report
    }

    /// The file `relative` names inside `packRoot`, or nil if it could lead anywhere else: an absolute path, a ".." or
    /// "." part, a backslash, or a link (anywhere along the way, or the file itself) pointing outside the pack.
    public static func safeTarget(_ relative: String, in packRoot: URL) -> URL? {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"), !relative.contains("\0") else { return nil }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        guard let root = realPath(packRoot) else { return nil }
        let target = packRoot.appendingPathComponent(relative)
        // The deepest part of the path that exists (the file itself, if it does, even as a dangling link).
        var existing = target
        var rest: [String] = []
        while !lexists(existing) {
            rest.insert(existing.lastPathComponent, at: 0)
            let up = existing.deletingLastPathComponent()
            if up.path == existing.path { return nil }
            existing = up
        }
        guard let resolved = realPath(existing) else { return nil }
        let full = rest.isEmpty ? resolved : resolved + "/" + rest.joined(separator: "/")
        guard full == root || full.hasPrefix(root + "/") else { return nil }
        return target
    }

    // MARK: - The library (Box, TransformedBox, OutputFile, SimpleOutputFile, MultipartOutputFile, InputFile)

    /// A rectangle in a reference image of totalW × totalH, scaled to the real image with integer division.
    struct Box: Sendable {
        let x, y, w, h, totalW, totalH: Int
        init(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ totalW: Int, _ totalH: Int) {
            self.x = x; self.y = y; self.w = w; self.h = h; self.totalW = totalW; self.totalH = totalH
        }
        func scaleX(_ imgWidth: Int) -> Int { x * imgWidth / totalW }
        func scaleY(_ imgHeight: Int) -> Int { y * imgHeight / totalH }
        func scaleW(_ imgWidth: Int) -> Int { w * imgWidth / totalW }
        func scaleH(_ imgHeight: Int) -> Int { h * imgHeight / totalH }
    }

    /// The image operations the Java tables use (TransformedBox's statics and Main's helpers).
    enum Op: Sendable {
        case mirrorVertically, mirrorHorizontally, rotate90, rotate180, rotate270
        /// Main.flipFrameAxis: frames side by side become frames stacked.
        case flipFrameAxis(Int)
        /// Main.spriteExtender(srcWidth, srcHeight, targetX, targetY, targetWidth, targetHeight).
        case spriteExtender(Int, Int, Int, Int, Int, Int)
        /// Main.clip's transformer: everything outside the box made transparent.
        case clip(Box)
    }

    struct Part: Sendable {
        let box: Box
        let ops: [Op]
        let offsetX: Int
        let offsetY: Int
    }

    struct Output: Sendable {
        enum Kind: Sendable {
            case simple(Box)
            case multipart(width: Int, height: Int, parts: [Part])
        }
        let path: String
        let kind: Kind
        var ops: [Op] = []
        var meta: String?

        func apply(_ op: Op) -> Output { var o = self; o.ops.append(op); return o }
        func metadata(_ text: String) -> Output { var o = self; o.meta = text; return o }
    }

    struct Input: Sendable {
        let path: String
        let outputs: [Output]
    }

    static func table(_ step: Step) -> [Input] {
        switch step {
        case .v1_20_2: return Table1_20_2.inputs
        case .v1_20_5: return Table1_20_5.inputs
        case .v26_2: return Table26_2.inputs
        }
    }

    private static func process(_ input: Input, base: String, step: Step, packRoot: URL, created: inout Set<String>, report: inout Report) {
        let sourceRel = base + input.path
        func skip(_ path: String, _ reason: SkipReason) { report.skipped.append(.init(step: step, path: path, reason: reason)) }
        // A file this run wrote wasn't in the pack the Java would have read.
        if created.contains(sourceRel) { skip(sourceRel, .sourceMissing); return }
        guard let source = safeTarget(sourceRel, in: packRoot) else { skip(sourceRel, .unsafePath); return }
        guard isFile(source) else { skip(sourceRel, .sourceMissing); return }
        guard let image = Pixels.read(source) else { skip(sourceRel, .sourceUnreadable); return }
        let sourceMeta = source.deletingLastPathComponent().appendingPathComponent(source.lastPathComponent + ".mcmeta")

        for output in input.outputs {
            let targetRel = base + output.path
            if targetRel == sourceRel { skip(targetRel, .sameAsSource); continue }
            guard let target = safeTarget(targetRel, in: packRoot) else { skip(targetRel, .unsafePath); continue }
            if lexists(target) { skip(targetRel, .alreadyExists); continue }

            // The bytes to write, as SimpleOutputFile / MultipartOutputFile make them.
            let data: Data
            switch output.kind {
            case .simple(let box):
                let x = box.scaleX(image.width), y = box.scaleY(image.height)
                let w = box.scaleW(image.width), h = box.scaleH(image.height)
                if x == 0, y == 0, w == image.width, h == image.height, output.ops.isEmpty {
                    guard let bytes = try? Data(contentsOf: source) else { skip(targetRel, .sourceUnreadable); continue }
                    data = bytes
                } else {
                    guard var sub = image.sub(x, y, w, h) else { skip(targetRel, .outsideImage); continue }
                    var ok = true
                    for op in output.ops { if let next = sub.applying(op) { sub = next } else { ok = false; break } }
                    guard ok else { skip(targetRel, .outsideImage); continue }
                    guard let png = sub.png() else { skip(targetRel, .failed("couldn't encode the PNG")); continue }
                    data = png
                }
            case .multipart(let width, let height, let parts):
                guard let first = parts.first,
                      var canvas = Pixels.blank(width * image.width / first.box.totalW, height * image.height / first.box.totalH, like: image)
                else { skip(targetRel, .outsideImage); continue }
                var ok = true
                for part in parts {
                    // TransformedBox.process
                    let x = part.box.scaleX(image.width), y = part.box.scaleY(image.height)
                    let w = part.box.scaleW(image.width), h = part.box.scaleH(image.height)
                    guard var sub = image.sub(x, y, w, h) else { ok = false; break }
                    for op in part.ops { if let next = sub.applying(op) { sub = next } else { ok = false; break } }
                    guard ok else { break }
                    canvas.draw(sub, at: part.offsetX * image.width / part.box.totalW, part.offsetY * image.height / part.box.totalH)
                }
                guard ok else { skip(targetRel, .outsideImage); continue }
                for op in output.ops { if let next = canvas.applying(op) { canvas = next } else { ok = false; break } }
                guard ok else { skip(targetRel, .outsideImage); continue }
                guard let png = canvas.png() else { skip(targetRel, .failed("couldn't encode the PNG")); continue }
                data = png
            }

            if let why = writeNew(data, targetRel, packRoot: packRoot) { skip(targetRel, why); continue }
            created.insert(targetRel)
            report.written.append(.init(step: step, path: targetRel, source: sourceRel))

            // The sheet's own .mcmeta is copied over if it has one; otherwise the table's metadata is written.
            let metaRel = targetRel + ".mcmeta"
            let metaData: Data?
            if lexists(sourceMeta), isFile(sourceMeta) { metaData = try? Data(contentsOf: sourceMeta) }
            else { metaData = output.meta.map { Data($0.utf8) } }
            guard let metaData else { continue }
            guard let metaTarget = safeTarget(metaRel, in: packRoot) else { skip(metaRel, .unsafePath); continue }
            if lexists(metaTarget) { skip(metaRel, .alreadyExists); continue }
            if let why = writeNew(metaData, metaRel, packRoot: packRoot) { skip(metaRel, why); continue }
            created.insert(metaRel)
            report.written.append(.init(step: step, path: metaRel, source: sourceRel))
        }
    }

    /// Writes a file that must not exist yet, only inside the pack. Returns why not, or nil when written.
    private static func writeNew(_ data: Data, _ relative: String, packRoot: URL) -> SkipReason? {
        guard let target = safeTarget(relative, in: packRoot) else { return .unsafePath }
        do { try FileOps.ensureDir(target.deletingLastPathComponent()) } catch { return .failed("couldn't make the folder: \(error.localizedDescription)") }
        // Checked again now the folders exist, in case one of them turned out to be a link.
        guard safeTarget(relative, in: packRoot) != nil else { return .unsafePath }
        if lexists(target) { return .alreadyExists }
        do { try data.write(to: target, options: .withoutOverwriting) } catch { return .failed("couldn't write it: \(error.localizedDescription)") }
        return nil
    }

    private static func lexists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    private static func isFile(_ url: URL) -> Bool {
        var st = stat()
        return stat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    private static func realPath(_ url: URL) -> String? {
        guard let p = realpath(url.path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    // MARK: - Pixels (BufferedImage, as far as the tables need it)

    /// 8-bit RGBA, not premultiplied, rows top to bottom.
    struct Pixels {
        let width: Int
        let height: Int
        var rgba: [UInt8]
        let space: CGColorSpace

        static func blank(_ width: Int, _ height: Int, like other: Pixels) -> Pixels? {
            guard width > 0, height > 0 else { return nil }
            return Pixels(width: width, height: height, rgba: [UInt8](repeating: 0, count: width * height * 4), space: other.space)
        }

        static func read(_ url: URL) -> Pixels? {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil), cg.width > 0, cg.height > 0 else { return nil }
            // Keep the image's own RGB space so no colour is converted; others become sRGB.
            var space = CGColorSpace(name: CGColorSpace.sRGB)!
            if let own = cg.colorSpace {
                if own.model == .rgb { space = own }
                else if own.model == .indexed, let base = own.baseColorSpace, base.model == .rgb { space = base }
            }
            guard let format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: space,
                                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)),
                  var buffer = try? vImage_Buffer(cgImage: cg, format: format) else { return nil }
            defer { buffer.free() }
            let w = Int(buffer.width), h = Int(buffer.height), rowBytes = buffer.rowBytes
            var out = [UInt8](repeating: 0, count: w * h * 4)
            let base = buffer.data.assumingMemoryBound(to: UInt8.self)
            out.withUnsafeMutableBufferPointer { dst in
                for row in 0..<h { (dst.baseAddress! + row * w * 4).update(from: base + row * rowBytes, count: w * 4) }
            }
            return Pixels(width: w, height: h, rgba: out, space: space)
        }

        func png() -> Data? {
            guard let provider = CGDataProvider(data: Data(rgba) as CFData),
                  let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                   space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { return nil }
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, cg, nil)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return data as Data
        }

        /// BufferedImage.getSubimage: nil where Java would throw (outside the image, or empty).
        func sub(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Pixels? {
            guard x >= 0, y >= 0, w > 0, h > 0, x + w <= width, y + h <= height else { return nil }
            var out = [UInt8](repeating: 0, count: w * h * 4)
            for row in 0..<h {
                let from = ((y + row) * width + x) * 4
                out.replaceSubrange(row * w * 4 ..< (row + 1) * w * 4, with: rgba[from ..< from + w * 4])
            }
            return Pixels(width: w, height: h, rgba: out, space: space)
        }

        /// Graphics.drawImage(src, x, y): source-over, clipped to this image.
        mutating func draw(_ src: Pixels, at x: Int, _ y: Int) {
            for sy in 0..<src.height {
                let dy = y + sy
                guard dy >= 0, dy < height else { continue }
                for sx in 0..<src.width {
                    let dx = x + sx
                    guard dx >= 0, dx < width else { continue }
                    let s = (sy * src.width + sx) * 4, d = (dy * width + dx) * 4
                    let sa = Int(src.rgba[s + 3])
                    if sa == 0 { continue }
                    let da = Int(rgba[d + 3])
                    if sa == 255 || da == 0 {
                        for c in 0..<4 { rgba[d + c] = src.rgba[s + c] }
                        continue
                    }
                    // Unpremultiplied source-over.
                    let sa1 = Double(sa) / 255, da1 = Double(da) / 255
                    let oa = sa1 + da1 * (1 - sa1)
                    for c in 0..<3 {
                        let v = (Double(src.rgba[s + c]) * sa1 + Double(rgba[d + c]) * da1 * (1 - sa1)) / oa
                        rgba[d + c] = UInt8(max(0, min(255, v.rounded())))
                    }
                    rgba[d + 3] = UInt8(max(0, min(255, (oa * 255).rounded())))
                }
            }
        }

        /// A new image of the given size where each output pixel (dx, dy) takes the source pixel `from(dx, dy)`.
        private func remapped(_ w: Int, _ h: Int, _ from: (Int, Int) -> (Int, Int)) -> Pixels {
            var out = [UInt8](repeating: 0, count: w * h * 4)
            for dy in 0..<h {
                for dx in 0..<w {
                    let (sx, sy) = from(dx, dy)
                    let s = (sy * width + sx) * 4, d = (dy * w + dx) * 4
                    out[d] = rgba[s]; out[d + 1] = rgba[s + 1]; out[d + 2] = rgba[s + 2]; out[d + 3] = rgba[s + 3]
                }
            }
            return Pixels(width: w, height: h, rgba: out, space: space)
        }

        func applying(_ op: Op) -> Pixels? {
            let w = width, h = height
            switch op {
            case .mirrorVertically:
                // drawImage(image, 0, h, w, -h): rows reversed.
                return remapped(w, h) { dx, dy in (dx, h - 1 - dy) }
            case .mirrorHorizontally:
                return remapped(w, h) { dx, dy in (w - 1 - dx, dy) }
            case .rotate90:
                // quadrantRotate(1) after translate(0, -h): source (sx, sy) lands at (h - 1 - sy, sx). Clockwise.
                return remapped(h, w) { dx, dy in (dy, h - 1 - dx) }
            case .rotate180:
                return remapped(w, h) { dx, dy in (w - 1 - dx, h - 1 - dy) }
            case .rotate270:
                // quadrantRotate(3) after translate(-w, 0): source (sx, sy) lands at (sy, w - 1 - sx). Anticlockwise.
                return remapped(h, w) { dx, dy in (w - 1 - dy, dx) }
            case .flipFrameAxis(let frameCount):
                let frameWidth = w / frameCount, frameHeight = h
                guard var out = Pixels.blank(frameWidth, frameHeight * frameCount, like: self) else { return nil }
                for frame in 0..<frameCount {
                    guard let piece = sub(frame * frameWidth, 0, frameWidth, frameHeight) else { return nil }
                    out.draw(piece, at: 0, frame * frameHeight)
                }
                return out
            case let .spriteExtender(srcWidth, srcHeight, targetX, targetY, targetWidth, targetHeight):
                let x = targetX * w / srcWidth, y = targetY * h / srcHeight
                guard var out = Pixels.blank(targetWidth * w / srcWidth, targetHeight * h / srcHeight, like: self) else { return nil }
                out.draw(self, at: x, y)
                return out
            case .clip(let box):
                let x = box.scaleX(w), y = box.scaleY(h)
                guard let piece = sub(x, y, box.scaleW(w), box.scaleH(h)), var out = Pixels.blank(w, h, like: self) else { return nil }
                out.draw(piece, at: x, y)
                return out
            }
        }
    }
}

// MARK: - The mapping tables, translated mechanically from each version's Main.java

/// The helpers each Main.java defines, shared by the three tables.
private protocol SlicerTable {}

extension SlicerTable {
    typealias Box = LegacySprites.Box
    typealias Input = LegacySprites.Input
    typealias Output = LegacySprites.Output

    static func input(_ path: String, _ outputs: Output...) -> Input { Input(path: path, outputs: outputs) }
    static func simple(_ path: String, _ box: Box) -> Output { Output(path: path, kind: .simple(box)) }
    static func multipart(_ path: String, _ width: Int, _ height: Int, _ parts: LegacySprites.Part...) -> Output {
        Output(path: path, kind: .multipart(width: width, height: height, parts: parts))
    }
    static func part(_ box: Box, _ ops: [LegacySprites.Op], _ offsetX: Int, _ offsetY: Int) -> LegacySprites.Part {
        LegacySprites.Part(box: box, ops: ops, offsetX: offsetX, offsetY: offsetY)
    }

    // 1.20.2's helpers.
    static var standardContainerBox: Box { Box(0, 0, 176, 166, 256, 256) }
    static func nameToPath(_ namespace: String, _ name: String) -> String { "assets/" + namespace + "/textures/gui/" + name + ".png" }
    static func copy(_ name: String) -> Input {
        let path = nameToPath("minecraft", name)
        return move(path, path)
    }
    static func clip(_ name: String, _ box: Box) -> Input { clip(name, name, box) }
    static func clip(_ inputName: String, _ outputName: String, _ box: Box) -> Input {
        let imageBox = Box(0, 0, box.totalW, box.totalH, box.totalW, box.totalH)
        return Input(path: nameToPath("minecraft", inputName),
                     outputs: [simple(nameToPath("minecraft", outputName), imageBox).apply(.clip(box))])
    }
    static func move(_ inputPath: String, _ outputPath: String) -> Input {
        Input(path: inputPath, outputs: [simple(outputPath, Box(0, 0, 1, 1, 1, 1))])
    }
    static func moveRealmsToMinecraft(_ name: String) -> Input { move(nameToPath("realms", name), nameToPath("minecraft", name)) }

    // 1.20.5's helper.
    static func mapDecoration(_ path: String, _ index: Int) -> Output {
        let x = index % 16, y = index / 16
        return simple("assets/minecraft/textures/map/decorations/" + path + ".png", Box(x * 8, y * 8, 8, 8, 128, 128))
    }
}

// From 1.20.2/src/main/java/com/mojang/slicer/Main.java: interface sheets become separate sprites.
private enum Table1_20_2: SlicerTable {
    static let buttonWidgetMetadata = "{\n    \"gui\": {\n        \"scaling\": {\n            \"type\": \"nine_slice\",\n            \"width\": 200,\n            \"height\": 20,\n            \"border\": {\n                \"left\": 20,\n                \"top\": 4,\n                \"right\": 20,\n                \"bottom\": 4\n            }\n        }\n    }\n}\n"
    static let tabWidgetMetadata = "{\n    \"gui\": {\n        \"scaling\": {\n            \"type\": \"nine_slice\",\n            \"width\": 130,\n            \"height\": 24,\n            \"border\": {\n                \"left\": 2,\n                \"top\": 2,\n                \"right\": 2,\n                \"bottom\": 0\n            }\n        }\n    }\n}\n"

    static let inputs: [Input] = [
        input("assets/minecraft/textures/gui/chat_tags.png",
            simple("assets/minecraft/textures/gui/sprites/icon/chat_modified.png", Box(0, 0, 9, 9, 32, 32))
        ),
        input("assets/minecraft/textures/gui/container/creative_inventory/tabs.png",
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/scroller.png", Box(232, 0, 12, 15, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/scroller_disabled.png", Box(244, 0, 12, 15, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_top_unselected_1.png", Box(0, 0, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_top_unselected_2.png", Box(26, 0, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_top_unselected_3.png", Box(52, 0, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_top_unselected_4.png", Box(78, 0, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_top_unselected_5.png", Box(104, 0, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_top_unselected_6.png", Box(130, 0, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_top_unselected_7.png", Box(156, 0, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_top_selected_1.png", Box(0, 32, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_top_selected_2.png", Box(26, 32, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_top_selected_3.png", Box(52, 32, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_top_selected_4.png", Box(78, 32, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_top_selected_5.png", Box(104, 32, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_top_selected_6.png", Box(130, 32, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_top_selected_7.png", Box(156, 32, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_bottom_unselected_1.png", Box(0, 64, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_bottom_unselected_2.png", Box(26, 64, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_bottom_unselected_3.png", Box(52, 64, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_bottom_unselected_4.png", Box(78, 64, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_bottom_unselected_5.png", Box(104, 64, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_bottom_unselected_6.png", Box(130, 64, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_bottom_unselected_7.png", Box(156, 64, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_bottom_selected_1.png", Box(0, 96, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_bottom_selected_2.png", Box(26, 96, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_bottom_selected_3.png", Box(52, 96, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_bottom_selected_4.png", Box(78, 96, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_bottom_selected_5.png", Box(104, 96, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_bottom_selected_6.png", Box(130, 96, 26, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/creative_inventory/tab_bottom_selected_7.png", Box(156, 96, 26, 32, 256, 256))
        ),
        input("assets/minecraft/textures/gui/advancements/tabs.png",
            simple("assets/minecraft/textures/gui/sprites/advancements/tab_above_left_selected.png", Box(0, 32, 28, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/tab_above_middle_selected.png", Box(28, 32, 28, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/tab_above_right_selected.png", Box(56, 32, 28, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/tab_above_left.png", Box(0, 0, 28, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/tab_above_middle.png", Box(28, 0, 28, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/tab_above_right.png", Box(56, 0, 28, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/tab_below_left_selected.png", Box(84, 32, 28, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/tab_below_middle_selected.png", Box(112, 32, 28, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/tab_below_right_selected.png", Box(140, 32, 28, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/tab_below_left.png", Box(84, 0, 28, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/tab_below_middle.png", Box(112, 0, 28, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/tab_below_right.png", Box(140, 0, 28, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/tab_left_top_selected.png", Box(0, 92, 32, 28, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/tab_left_middle_selected.png", Box(32, 92, 32, 28, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/tab_left_bottom_selected.png", Box(64, 92, 32, 28, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/tab_left_top.png", Box(0, 64, 32, 28, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/tab_left_middle.png", Box(32, 64, 32, 28, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/tab_left_bottom.png", Box(64, 64, 32, 28, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/tab_right_top_selected.png", Box(96, 92, 32, 28, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/tab_right_middle_selected.png", Box(128, 92, 32, 28, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/tab_right_bottom_selected.png", Box(160, 92, 32, 28, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/tab_right_top.png", Box(96, 64, 32, 28, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/tab_right_middle.png", Box(128, 64, 32, 28, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/tab_right_bottom.png", Box(160, 64, 32, 28, 256, 256))
        ),
        input("assets/minecraft/textures/gui/checkbox.png",
            simple("assets/minecraft/textures/gui/sprites/widget/checkbox_selected_highlighted.png", Box(20, 20, 20, 20, 64, 64)),
            simple("assets/minecraft/textures/gui/sprites/widget/checkbox_selected.png", Box(0, 20, 20, 20, 64, 64)),
            simple("assets/minecraft/textures/gui/sprites/widget/checkbox_highlighted.png", Box(20, 0, 20, 20, 64, 64)),
            simple("assets/minecraft/textures/gui/sprites/widget/checkbox.png", Box(0, 0, 20, 20, 64, 64))
        ),
        input("assets/minecraft/textures/gui/container/blast_furnace.png",
            simple("assets/minecraft/textures/gui/sprites/container/blast_furnace/lit_progress.png", Box(176, 0, 14, 14, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/blast_furnace/burn_progress.png", Box(176, 14, 24, 16, 256, 256))
        ),
        input("assets/realms/textures/gui/realms/expired_icon.png",
            simple("assets/minecraft/textures/gui/sprites/realm_status/expired.png", Box(0, 0, 10, 28, 10, 28))
        ),
        input("assets/minecraft/textures/gui/server_selection.png",
            simple("assets/minecraft/textures/gui/sprites/server_list/join_highlighted.png", Box(0, 32, 32, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/server_list/join.png", Box(0, 0, 32, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/server_list/move_up_highlighted.png", Box(96, 32, 32, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/server_list/move_up.png", Box(96, 0, 32, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/server_list/move_down_highlighted.png", Box(64, 32, 32, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/server_list/move_down.png", Box(64, 0, 32, 32, 256, 256))
        ),
        input("assets/minecraft/textures/gui/widgets.png",
            simple("assets/minecraft/textures/gui/sprites/widget/button.png", Box(0, 66, 200, 20, 256, 256)).metadata(buttonWidgetMetadata),
            simple("assets/minecraft/textures/gui/sprites/widget/button_disabled.png", Box(0, 46, 200, 20, 256, 256)).metadata(buttonWidgetMetadata),
            simple("assets/minecraft/textures/gui/sprites/widget/button_highlighted.png", Box(0, 86, 200, 20, 256, 256)).metadata(buttonWidgetMetadata),
            simple("assets/minecraft/textures/gui/sprites/widget/locked_button.png", Box(0, 146, 20, 20, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/widget/locked_button_highlighted.png", Box(0, 166, 20, 20, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/widget/locked_button_disabled.png", Box(0, 186, 20, 20, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/widget/unlocked_button.png", Box(20, 146, 20, 20, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/widget/unlocked_button_highlighted.png", Box(20, 166, 20, 20, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/widget/unlocked_button_disabled.png", Box(20, 186, 20, 20, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/hotbar.png", Box(0, 0, 182, 22, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/hotbar_selection.png", Box(0, 22, 24, 23, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/hotbar_offhand_left.png", Box(24, 22, 29, 24, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/hotbar_offhand_right.png", Box(53, 22, 29, 24, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/icon/draft_report.png", Box(182, 24, 15, 15, 256, 256))
        ),
        input("assets/realms/textures/gui/realms/cross_icon.png",
            simple("assets/minecraft/textures/gui/sprites/widget/cross_button_highlighted.png", Box(0, 14, 14, 14, 14, 28)),
            simple("assets/minecraft/textures/gui/sprites/widget/cross_button.png", Box(0, 0, 14, 14, 14, 28))
        ),
        input("assets/minecraft/textures/gui/info_icon.png",
            simple("assets/minecraft/textures/gui/sprites/icon/info.png", Box(0, 0, 20, 20, 20, 20))
        ),
        input("assets/minecraft/textures/gui/advancements/widgets.png",
            simple("assets/minecraft/textures/gui/sprites/advancements/title_box.png", Box(0, 52, 200, 26, 256, 256)).metadata("{\n    \"gui\": {\n        \"scaling\": {\n            \"type\": \"nine_slice\",\n            \"width\": 200,\n            \"height\": 26,\n            \"border\": 10\n        }\n    }\n}\n"),
            simple("assets/minecraft/textures/gui/sprites/advancements/box_obtained.png", Box(0, 0, 200, 26, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/task_frame_obtained.png", Box(0, 128, 26, 26, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/challenge_frame_obtained.png", Box(26, 128, 26, 26, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/goal_frame_obtained.png", Box(52, 128, 26, 26, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/box_unobtained.png", Box(0, 26, 200, 26, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/task_frame_unobtained.png", Box(0, 154, 26, 26, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/challenge_frame_unobtained.png", Box(26, 154, 26, 26, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/advancements/goal_frame_unobtained.png", Box(52, 154, 26, 26, 256, 256))
        ),
        input("assets/minecraft/textures/gui/tab_button.png",
            simple("assets/minecraft/textures/gui/sprites/widget/tab_selected.png", Box(0, 0, 130, 24, 256, 256)).metadata(tabWidgetMetadata),
            simple("assets/minecraft/textures/gui/sprites/widget/tab.png", Box(0, 48, 130, 24, 256, 256)).metadata(tabWidgetMetadata),
            simple("assets/minecraft/textures/gui/sprites/widget/tab_selected_highlighted.png", Box(0, 24, 130, 24, 256, 256)).metadata(tabWidgetMetadata),
            simple("assets/minecraft/textures/gui/sprites/widget/tab_highlighted.png", Box(0, 72, 130, 24, 256, 256)).metadata(tabWidgetMetadata)
        ),
        input("assets/minecraft/textures/gui/container/furnace.png",
            simple("assets/minecraft/textures/gui/sprites/container/furnace/lit_progress.png", Box(176, 0, 14, 14, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/furnace/burn_progress.png", Box(176, 14, 24, 16, 256, 256))
        ),
        input("assets/minecraft/textures/gui/container/brewing_stand.png",
            simple("assets/minecraft/textures/gui/sprites/container/brewing_stand/fuel_length.png", Box(176, 29, 18, 4, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/brewing_stand/brew_progress.png", Box(176, 0, 9, 28, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/brewing_stand/bubbles.png", Box(185, 0, 12, 29, 256, 256))
        ),
        input("assets/minecraft/textures/gui/sprites/language.png",
            simple("assets/minecraft/textures/gui/sprites/icon/language.png", Box(0, 0, 15, 15, 15, 15))
        ),
        input("assets/realms/textures/gui/realms/off_icon.png",
            simple("assets/minecraft/textures/gui/sprites/realm_status/closed.png", Box(0, 0, 10, 28, 10, 28))
        ),
        input("assets/minecraft/textures/gui/resource_packs.png",
            simple("assets/minecraft/textures/gui/sprites/transferable_list/select_highlighted.png", Box(0, 32, 32, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/transferable_list/select.png", Box(0, 0, 32, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/transferable_list/unselect_highlighted.png", Box(32, 32, 32, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/transferable_list/unselect.png", Box(32, 0, 32, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/transferable_list/move_up_highlighted.png", Box(96, 32, 32, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/transferable_list/move_up.png", Box(96, 0, 32, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/transferable_list/move_down_highlighted.png", Box(64, 32, 32, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/transferable_list/move_down.png", Box(64, 0, 32, 32, 256, 256))
        ),
        input("assets/realms/textures/gui/realms/user_icon.png",
            simple("assets/minecraft/textures/gui/sprites/player_list/make_operator.png", Box(0, 0, 8, 7, 8, 14)),
            simple("assets/minecraft/textures/gui/sprites/player_list/make_operator_highlighted.png", Box(0, 7, 8, 7, 8, 14))
        ),
        input("assets/minecraft/textures/gui/container/beacon.png",
            simple("assets/minecraft/textures/gui/sprites/container/beacon/button_disabled.png", Box(44, 219, 22, 22, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/beacon/button_selected.png", Box(22, 219, 22, 22, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/beacon/button_highlighted.png", Box(66, 219, 22, 22, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/beacon/button.png", Box(0, 219, 22, 22, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/beacon/confirm.png", Box(90, 220, 18, 18, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/beacon/cancel.png", Box(112, 220, 18, 18, 256, 256))
        ),
        input("assets/minecraft/textures/gui/container/bundle_background.png",
            simple("assets/minecraft/textures/gui/sprites/container/bundle/background.png", Box(0, 0, 32, 32, 256, 256)).metadata("{\n    \"gui\": {\n        \"scaling\": {\n            \"type\": \"nine_slice\",\n            \"width\": 32,\n            \"height\": 32,\n            \"border\": 4\n        }\n    }\n}\n")
        ),
        input("assets/minecraft/textures/gui/toasts.png",
            simple("assets/minecraft/textures/gui/sprites/toast/advancement.png", Box(0, 0, 160, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/toast/recipe.png", Box(0, 32, 160, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/toast/system.png", Box(0, 64, 160, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/toast/tutorial.png", Box(0, 96, 160, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/toast/movement_keys.png", Box(176, 0, 20, 20, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/toast/mouse.png", Box(196, 0, 20, 20, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/toast/tree.png", Box(216, 0, 20, 20, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/toast/recipe_book.png", Box(176, 20, 20, 20, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/toast/wooden_planks.png", Box(196, 20, 20, 20, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/toast/social_interactions.png", Box(216, 20, 20, 20, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/toast/right_click.png", Box(236, 20, 20, 20, 256, 256))
        ),
        input("assets/realms/textures/gui/realms/reject_icon.png",
            simple("assets/minecraft/textures/gui/sprites/pending_invite/reject_highlighted.png", Box(19, 0, 18, 18, 37, 18)),
            simple("assets/minecraft/textures/gui/sprites/pending_invite/reject.png", Box(0, 0, 18, 18, 37, 18))
        ),
        input("assets/minecraft/textures/gui/book.png",
            simple("assets/minecraft/textures/gui/sprites/widget/page_forward_highlighted.png", Box(23, 192, 23, 13, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/widget/page_forward.png", Box(0, 192, 23, 13, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/widget/page_backward_highlighted.png", Box(23, 205, 23, 13, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/widget/page_backward.png", Box(0, 205, 23, 13, 256, 256))
        ),
        input("assets/realms/textures/gui/realms/accept_icon.png",
            simple("assets/minecraft/textures/gui/sprites/pending_invite/accept_highlighted.png", Box(19, 0, 18, 18, 37, 18)),
            simple("assets/minecraft/textures/gui/sprites/pending_invite/accept.png", Box(0, 0, 18, 18, 37, 18))
        ),
        input("assets/realms/textures/gui/realms/world_icon.png",
            simple("assets/minecraft/textures/gui/sprites/icon/new_realm.png", Box(0, 0, 40, 20, 40, 20))
        ),
        input("assets/realms/textures/gui/realms/expires_soon_icon.png",
            simple("assets/minecraft/textures/gui/sprites/realm_status/expires_soon.png", Box(0, 0, 20, 28, 20, 28))
                .metadata("{\n    \"animation\": {\n        \"frametime\": 10,\n        \"height\": 28\n    }\n}\n")
                .apply(.flipFrameAxis(2))
        ),
        input("assets/minecraft/textures/gui/report_button.png",
            simple("assets/minecraft/textures/gui/sprites/social_interactions/report_button.png", Box(0, 0, 20, 20, 64, 64)),
            simple("assets/minecraft/textures/gui/sprites/social_interactions/report_button_disabled.png", Box(0, 40, 20, 20, 64, 64)),
            simple("assets/minecraft/textures/gui/sprites/social_interactions/report_button_highlighted.png", Box(0, 20, 20, 20, 64, 64))
        ),
        input("assets/realms/textures/gui/realms/news_notification_mainscreen.png",
            simple("assets/minecraft/textures/gui/sprites/icon/news.png", Box(0, 0, 40, 40, 40, 40))
        ),
        input("assets/realms/textures/gui/realms/trial_icon.png",
            simple("assets/minecraft/textures/gui/sprites/icon/trial_available.png", Box(0, 0, 8, 16, 8, 16)).metadata("{\n    \"animation\": {\n        \"frametime\": 20\n    }\n}\n")
        ),
        input("assets/minecraft/textures/gui/container/grindstone.png",
            simple("assets/minecraft/textures/gui/sprites/container/grindstone/error.png", Box(176, 0, 28, 21, 256, 256))
        ),
        input("assets/realms/textures/gui/realms/restore_icon.png",
            simple("assets/minecraft/textures/gui/sprites/backup/restore.png", Box(0, 0, 17, 10, 17, 20)),
            simple("assets/minecraft/textures/gui/sprites/backup/restore_highlighted.png", Box(0, 10, 17, 10, 17, 20))
        ),
        input("assets/minecraft/textures/gui/container/villager2.png",
            simple("assets/minecraft/textures/gui/sprites/container/villager/out_of_stock.png", Box(311, 0, 28, 21, 512, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/villager/experience_bar_background.png", Box(0, 186, 102, 5, 512, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/villager/experience_bar_current.png", Box(0, 191, 102, 5, 512, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/villager/experience_bar_result.png", Box(0, 181, 102, 5, 512, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/villager/scroller.png", Box(0, 199, 6, 27, 512, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/villager/scroller_disabled.png", Box(6, 199, 6, 27, 512, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/villager/trade_arrow_out_of_stock.png", Box(25, 171, 10, 9, 512, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/villager/trade_arrow.png", Box(15, 171, 10, 9, 512, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/villager/discount_strikethrough.png", Box(0, 176, 9, 2, 512, 256))
        ),
        input("assets/realms/textures/gui/realms/link_icons.png",
            simple("assets/minecraft/textures/gui/sprites/icon/link_highlighted.png", Box(15, 0, 15, 15, 30, 15)),
            simple("assets/minecraft/textures/gui/sprites/icon/link.png", Box(0, 0, 15, 15, 30, 15))
        ),
        input("assets/realms/textures/gui/realms/trailer_icons.png",
            simple("assets/minecraft/textures/gui/sprites/icon/video_link_highlighted.png", Box(15, 0, 15, 15, 30, 15)),
            simple("assets/minecraft/textures/gui/sprites/icon/video_link.png", Box(0, 0, 15, 15, 30, 15))
        ),
        input("assets/realms/textures/gui/realms/slot_frame.png",
            simple("assets/minecraft/textures/gui/sprites/widget/slot_frame.png", Box(0, 0, 80, 80, 80, 80))
        ),
        input("assets/minecraft/textures/gui/bars.png",
            simple("assets/minecraft/textures/gui/sprites/boss_bar/pink_background.png", Box(0, 0, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/boss_bar/blue_background.png", Box(0, 10, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/boss_bar/red_background.png", Box(0, 20, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/boss_bar/green_background.png", Box(0, 30, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/boss_bar/yellow_background.png", Box(0, 40, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/boss_bar/purple_background.png", Box(0, 50, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/boss_bar/white_background.png", Box(0, 60, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/boss_bar/pink_progress.png", Box(0, 5, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/boss_bar/blue_progress.png", Box(0, 15, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/boss_bar/red_progress.png", Box(0, 25, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/boss_bar/green_progress.png", Box(0, 35, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/boss_bar/yellow_progress.png", Box(0, 45, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/boss_bar/purple_progress.png", Box(0, 55, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/boss_bar/white_progress.png", Box(0, 65, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/boss_bar/notched_6_background.png", Box(0, 80, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/boss_bar/notched_10_background.png", Box(0, 90, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/boss_bar/notched_12_background.png", Box(0, 100, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/boss_bar/notched_20_background.png", Box(0, 110, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/boss_bar/notched_6_progress.png", Box(0, 85, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/boss_bar/notched_10_progress.png", Box(0, 95, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/boss_bar/notched_12_progress.png", Box(0, 105, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/boss_bar/notched_20_progress.png", Box(0, 115, 182, 5, 256, 256))
        ),
        input("assets/minecraft/textures/gui/container/smithing.png",
            simple("assets/minecraft/textures/gui/sprites/container/smithing/error.png", Box(176, 0, 28, 21, 256, 256))
        ),
        input("assets/minecraft/textures/gui/container/stonecutter.png",
            simple("assets/minecraft/textures/gui/sprites/container/stonecutter/scroller.png", Box(176, 0, 12, 15, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/stonecutter/scroller_disabled.png", Box(188, 0, 12, 15, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/stonecutter/recipe_selected.png", Box(0, 184, 16, 18, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/stonecutter/recipe_highlighted.png", Box(0, 202, 16, 18, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/stonecutter/recipe.png", Box(0, 166, 16, 18, 256, 256))
        ),
        input("assets/minecraft/textures/gui/slider.png",
            simple("assets/minecraft/textures/gui/sprites/widget/slider_highlighted.png", Box(0, 20, 200, 20, 256, 256)).metadata(buttonWidgetMetadata),
            simple("assets/minecraft/textures/gui/sprites/widget/slider.png", Box(0, 0, 200, 20, 256, 256)).metadata(buttonWidgetMetadata),
            simple("assets/minecraft/textures/gui/sprites/widget/slider_handle_highlighted.png", Box(0, 60, 200, 20, 256, 256)).metadata(buttonWidgetMetadata),
            simple("assets/minecraft/textures/gui/sprites/widget/slider_handle.png", Box(0, 40, 200, 20, 256, 256)).metadata(buttonWidgetMetadata)
        ),
        input("assets/minecraft/textures/gui/container/gamemode_switcher.png",
            simple("assets/minecraft/textures/gui/sprites/gamemode_switcher/slot.png", Box(0, 75, 26, 26, 128, 128)),
            simple("assets/minecraft/textures/gui/sprites/gamemode_switcher/selection.png", Box(26, 75, 26, 26, 128, 128))
        ),
        input("assets/minecraft/textures/gui/world_selection.png",
            simple("assets/minecraft/textures/gui/sprites/world_list/error_highlighted.png", Box(96, 32, 32, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/world_list/error.png", Box(96, 0, 32, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/world_list/marked_join_highlighted.png", Box(32, 32, 32, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/world_list/marked_join.png", Box(32, 0, 32, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/world_list/warning_highlighted.png", Box(64, 32, 32, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/world_list/warning.png", Box(64, 0, 32, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/world_list/join_highlighted.png", Box(0, 32, 32, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/world_list/join.png", Box(0, 0, 32, 32, 256, 256))
        ),
        input("assets/realms/textures/gui/realms/op_icon.png",
            simple("assets/minecraft/textures/gui/sprites/player_list/remove_operator.png", Box(0, 0, 8, 7, 8, 14)),
            simple("assets/minecraft/textures/gui/sprites/player_list/remove_operator_highlighted.png", Box(0, 7, 8, 7, 8, 14))
        ),
        input("assets/realms/textures/gui/realms/plus_icon.png",
            simple("assets/minecraft/textures/gui/sprites/backup/changes.png", Box(0, 0, 9, 9, 9, 18)),
            simple("assets/minecraft/textures/gui/sprites/backup/changes_highlighted.png", Box(0, 9, 9, 9, 9, 18))
        ),
        input("assets/minecraft/textures/gui/container/enchanting_table.png",
            simple("assets/minecraft/textures/gui/sprites/container/enchanting_table/level_1.png", Box(0, 223, 16, 16, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/enchanting_table/level_2.png", Box(16, 223, 16, 16, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/enchanting_table/level_3.png", Box(32, 223, 16, 16, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/enchanting_table/level_1_disabled.png", Box(0, 239, 16, 16, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/enchanting_table/level_2_disabled.png", Box(16, 239, 16, 16, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/enchanting_table/level_3_disabled.png", Box(32, 239, 16, 16, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/enchanting_table/enchantment_slot_disabled.png", Box(0, 185, 108, 19, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/enchanting_table/enchantment_slot_highlighted.png", Box(0, 204, 108, 19, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/enchanting_table/enchantment_slot.png", Box(0, 166, 108, 19, 256, 256))
        ),
        input("assets/minecraft/textures/gui/checkmark.png",
            simple("assets/minecraft/textures/gui/sprites/icon/checkmark.png", Box(0, 0, 9, 8, 9, 8))
        ),
        input("assets/minecraft/textures/gui/container/bundle.png",
            simple("assets/minecraft/textures/gui/sprites/container/bundle/blocked_slot.png", Box(0, 40, 18, 20, 128, 128)),
            simple("assets/minecraft/textures/gui/sprites/container/bundle/slot.png", Box(0, 0, 18, 20, 128, 128))
        ),
        input("assets/minecraft/textures/gui/container/horse.png",
            simple("assets/minecraft/textures/gui/sprites/container/horse/chest_slots.png", Box(0, 166, 90, 54, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/horse/saddle_slot.png", Box(18, 220, 18, 18, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/horse/llama_armor_slot.png", Box(36, 220, 18, 18, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/horse/armor_slot.png", Box(0, 220, 18, 18, 256, 256))
        ),
        input("assets/realms/textures/gui/realms/on_icon.png",
            simple("assets/minecraft/textures/gui/sprites/realm_status/open.png", Box(0, 0, 10, 28, 10, 28))
        ),
        input("assets/minecraft/textures/gui/container/anvil.png",
            simple("assets/minecraft/textures/gui/sprites/container/anvil/text_field.png", Box(0, 166, 110, 16, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/anvil/text_field_disabled.png", Box(0, 182, 110, 16, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/anvil/error.png", Box(176, 0, 28, 21, 256, 256))
        ),
        input("assets/realms/textures/gui/realms/news_icon.png",
            simple("assets/minecraft/textures/gui/sprites/widget/news_button_highlighted.png", Box(20, 0, 20, 20, 40, 20)),
            simple("assets/minecraft/textures/gui/sprites/widget/news_button.png", Box(0, 0, 20, 20, 40, 20))
        ),
        input("assets/realms/textures/gui/realms/invitation_icons.png",
            simple("assets/minecraft/textures/gui/sprites/notification/1.png", Box(0, 0, 8, 8, 48, 16)),
            simple("assets/minecraft/textures/gui/sprites/notification/2.png", Box(8, 0, 8, 8, 48, 16)),
            simple("assets/minecraft/textures/gui/sprites/notification/3.png", Box(16, 0, 8, 8, 48, 16)),
            simple("assets/minecraft/textures/gui/sprites/notification/4.png", Box(24, 0, 8, 8, 48, 16)),
            simple("assets/minecraft/textures/gui/sprites/notification/5.png", Box(32, 0, 8, 8, 48, 16)),
            simple("assets/minecraft/textures/gui/sprites/notification/more.png", Box(40, 0, 8, 8, 48, 16))
        ),
        input("assets/minecraft/textures/gui/recipe_book.png",
            simple("assets/minecraft/textures/gui/sprites/recipe_book/furnace_filter_enabled.png", Box(180, 182, 26, 16, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/furnace_filter_disabled.png", Box(152, 182, 26, 16, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/furnace_filter_enabled_highlighted.png", Box(180, 200, 26, 16, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/furnace_filter_disabled_highlighted.png", Box(152, 200, 26, 16, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/overlay_recipe.png", Box(82, 208, 32, 32, 256, 256)).metadata("{\n    \"gui\": {\n        \"scaling\": {\n            \"type\": \"nine_slice\",\n            \"width\": 32,\n            \"height\": 32,\n            \"border\": 4\n        }\n    }\n}\n"),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/furnace_overlay_highlighted.png", Box(152, 156, 24, 24, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/furnace_overlay.png", Box(152, 130, 24, 24, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/crafting_overlay_highlighted.png", Box(152, 104, 24, 24, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/crafting_overlay.png", Box(152, 78, 24, 24, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/furnace_overlay_disabled_highlighted.png", Box(178, 156, 24, 24, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/furnace_overlay_disabled.png", Box(178, 130, 24, 24, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/crafting_overlay_disabled_highlighted.png", Box(178, 104, 24, 24, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/crafting_overlay_disabled.png", Box(178, 78, 24, 24, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/filter_enabled.png", Box(180, 41, 26, 16, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/filter_disabled.png", Box(152, 41, 26, 16, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/filter_enabled_highlighted.png", Box(180, 59, 26, 16, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/filter_disabled_highlighted.png", Box(152, 59, 26, 16, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/page_forward.png", Box(1, 208, 12, 17, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/page_forward_highlighted.png", Box(1, 226, 12, 17, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/page_backward.png", Box(14, 208, 12, 17, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/page_backward_highlighted.png", Box(14, 226, 12, 17, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/tab.png", Box(153, 2, 35, 27, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/tab_selected.png", Box(188, 2, 35, 27, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/slot_many_craftable.png", Box(29, 231, 25, 25, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/slot_craftable.png", Box(29, 206, 25, 25, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/slot_many_uncraftable.png", Box(54, 231, 25, 25, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/slot_uncraftable.png", Box(54, 206, 25, 25, 256, 256))
        ),
        input("assets/minecraft/textures/gui/social_interactions.png",
            simple("assets/minecraft/textures/gui/sprites/social_interactions/mute_button.png", Box(0, 38, 20, 20, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/social_interactions/mute_button_highlighted.png", Box(0, 58, 20, 20, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/social_interactions/unmute_button.png", Box(20, 38, 20, 20, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/social_interactions/unmute_button_highlighted.png", Box(20, 58, 20, 20, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/social_interactions/background.png", Box(1, 1, 236, 34, 256, 256)).metadata("{\n    \"gui\": {\n        \"scaling\": {\n            \"type\": \"nine_slice\",\n            \"width\": 236,\n            \"height\": 34,\n            \"border\": 8\n        }\n    }\n}\n"),
            simple("assets/minecraft/textures/gui/sprites/icon/search.png", Box(243, 1, 12, 12, 256, 256))
        ),
        input("assets/minecraft/textures/gui/spectator_widgets.png",
            simple("assets/minecraft/textures/gui/sprites/spectator/teleport_to_player.png", Box(0, 0, 16, 16, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/spectator/teleport_to_team.png", Box(16, 0, 16, 16, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/spectator/close.png", Box(128, 0, 16, 16, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/spectator/scroll_left.png", Box(144, 0, 16, 16, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/spectator/scroll_right.png", Box(160, 0, 16, 16, 256, 256))
        ),
        input("assets/minecraft/textures/gui/container/smoker.png",
            simple("assets/minecraft/textures/gui/sprites/container/smoker/lit_progress.png", Box(176, 0, 14, 14, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/smoker/burn_progress.png", Box(176, 14, 24, 16, 256, 256))
        ),
        input("assets/minecraft/textures/gui/recipe_button.png",
            simple("assets/minecraft/textures/gui/sprites/recipe_book/button.png", Box(0, 0, 20, 18, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/recipe_book/button_highlighted.png", Box(0, 19, 20, 18, 256, 256))
        ),
        input("assets/minecraft/textures/gui/icons.png",
            simple("assets/minecraft/textures/gui/sprites/icon/ping_unknown.png", Box(0, 216, 10, 8, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/icon/ping_5.png", Box(0, 176, 10, 8, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/icon/ping_4.png", Box(0, 184, 10, 8, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/icon/ping_3.png", Box(0, 192, 10, 8, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/icon/ping_2.png", Box(0, 200, 10, 8, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/icon/ping_1.png", Box(0, 208, 10, 8, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/container_blinking.png", Box(25, 0, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/container.png", Box(16, 0, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/full_blinking.png", Box(70, 0, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/half_blinking.png", Box(79, 0, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/absorbing_full_blinking.png", Box(160, 0, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/full.png", Box(52, 0, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/absorbing_half_blinking.png", Box(169, 0, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/half.png", Box(61, 0, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/crosshair.png", Box(0, 0, 15, 15, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/crosshair_attack_indicator_full.png", Box(68, 94, 16, 16, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/crosshair_attack_indicator_background.png", Box(36, 94, 16, 4, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/crosshair_attack_indicator_progress.png", Box(52, 94, 16, 4, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/hotbar_attack_indicator_background.png", Box(0, 94, 18, 18, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/hotbar_attack_indicator_progress.png", Box(18, 94, 18, 18, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/jump_bar_background.png", Box(0, 84, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/jump_bar_cooldown.png", Box(0, 74, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/jump_bar_progress.png", Box(0, 89, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/experience_bar_background.png", Box(0, 64, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/experience_bar_progress.png", Box(0, 69, 182, 5, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/armor_full.png", Box(34, 9, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/armor_half.png", Box(25, 9, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/armor_empty.png", Box(16, 9, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/food_empty_hunger.png", Box(133, 27, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/food_half_hunger.png", Box(97, 27, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/food_full_hunger.png", Box(88, 27, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/food_empty.png", Box(16, 27, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/food_half.png", Box(61, 27, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/food_full.png", Box(52, 27, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/air.png", Box(16, 18, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/air_bursting.png", Box(25, 18, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/container_hardcore.png", Box(16, 45, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/container_hardcore_blinking.png", Box(25, 45, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/hardcore_full.png", Box(52, 45, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/hardcore_full_blinking.png", Box(70, 45, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/hardcore_half.png", Box(61, 45, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/hardcore_half_blinking.png", Box(79, 45, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/poisoned_full.png", Box(88, 0, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/poisoned_full_blinking.png", Box(106, 0, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/poisoned_half.png", Box(97, 0, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/poisoned_half_blinking.png", Box(115, 0, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/poisoned_hardcore_full.png", Box(88, 45, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/poisoned_hardcore_full_blinking.png", Box(106, 45, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/poisoned_hardcore_half.png", Box(97, 45, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/poisoned_hardcore_half_blinking.png", Box(115, 45, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/withered_full.png", Box(124, 0, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/withered_full_blinking.png", Box(142, 0, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/withered_half.png", Box(133, 0, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/withered_half_blinking.png", Box(151, 0, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/withered_hardcore_full.png", Box(124, 45, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/withered_hardcore_full_blinking.png", Box(142, 45, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/withered_hardcore_half.png", Box(133, 45, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/withered_hardcore_half_blinking.png", Box(151, 45, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/absorbing_full.png", Box(160, 0, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/absorbing_half.png", Box(169, 0, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/absorbing_hardcore_full.png", Box(160, 45, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/absorbing_hardcore_full_blinking.png", Box(160, 45, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/absorbing_hardcore_half.png", Box(169, 45, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/absorbing_hardcore_half_blinking.png", Box(169, 45, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/frozen_full.png", Box(178, 0, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/frozen_full_blinking.png", Box(178, 0, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/frozen_half.png", Box(187, 0, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/frozen_half_blinking.png", Box(187, 0, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/frozen_hardcore_full.png", Box(178, 45, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/frozen_hardcore_full_blinking.png", Box(178, 45, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/frozen_hardcore_half.png", Box(187, 45, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/frozen_hardcore_half_blinking.png", Box(187, 45, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/vehicle_container.png", Box(52, 9, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/vehicle_full.png", Box(88, 9, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/heart/vehicle_half.png", Box(97, 9, 9, 9, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/server_list/incompatible.png", Box(0, 216, 10, 8, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/server_list/unreachable.png", Box(0, 216, 10, 8, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/server_list/ping_5.png", Box(0, 176, 10, 8, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/server_list/ping_4.png", Box(0, 184, 10, 8, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/server_list/ping_3.png", Box(0, 192, 10, 8, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/server_list/ping_2.png", Box(0, 200, 10, 8, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/server_list/ping_1.png", Box(0, 208, 10, 8, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/server_list/pinging_1.png", Box(10, 176, 10, 8, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/server_list/pinging_2.png", Box(10, 184, 10, 8, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/server_list/pinging_3.png", Box(10, 192, 10, 8, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/server_list/pinging_4.png", Box(10, 200, 10, 8, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/server_list/pinging_5.png", Box(10, 208, 10, 8, 256, 256))
        ),
        input("assets/minecraft/textures/gui/container/inventory.png",
            simple("assets/minecraft/textures/gui/sprites/hud/effect_background_ambient.png", Box(165, 166, 24, 24, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/hud/effect_background.png", Box(141, 166, 24, 24, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/inventory/effect_background_large.png", Box(0, 166, 120, 32, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/inventory/effect_background_small.png", Box(0, 198, 32, 32, 256, 256))
        ),
        input("assets/minecraft/textures/gui/unseen_notification.png",
            simple("assets/minecraft/textures/gui/sprites/icon/unseen_notification.png", Box(0, 0, 10, 10, 10, 10))
        ),
        input("assets/minecraft/textures/gui/container/loom.png",
            simple("assets/minecraft/textures/gui/sprites/container/loom/banner_slot.png", Box(176, 0, 16, 16, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/loom/dye_slot.png", Box(192, 0, 16, 16, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/loom/pattern_slot.png", Box(208, 0, 16, 16, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/loom/scroller.png", Box(232, 0, 12, 15, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/loom/scroller_disabled.png", Box(244, 0, 12, 15, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/loom/pattern_selected.png", Box(0, 180, 14, 14, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/loom/pattern_highlighted.png", Box(0, 194, 14, 14, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/loom/pattern.png", Box(0, 166, 14, 14, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/loom/error.png", Box(176, 17, 17, 16, 256, 256)).apply(.spriteExtender(17, 16, 3, 4, 26, 26))
        ),
        input("assets/realms/textures/gui/realms/invite_icon.png",
            simple("assets/minecraft/textures/gui/sprites/icon/invite.png", Box(0, 0, 18, 15, 18, 30)),
            simple("assets/minecraft/textures/gui/sprites/icon/invite_highlighted.png", Box(0, 15, 18, 15, 18, 30))
        ),
        input("assets/minecraft/textures/gui/container/cartography_table.png",
            simple("assets/minecraft/textures/gui/sprites/container/cartography_table/error.png", Box(226, 132, 28, 21, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/cartography_table/scaled_map.png", Box(176, 66, 66, 66, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/cartography_table/duplicated_map.png", Box(176, 132, 50, 66, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/cartography_table/map.png", Box(176, 0, 66, 66, 256, 256)),
            simple("assets/minecraft/textures/gui/sprites/container/cartography_table/locked.png", Box(52, 214, 10, 14, 256, 256))
        ),
        input("assets/realms/textures/gui/realms/cross_player_icon.png",
            simple("assets/minecraft/textures/gui/sprites/player_list/remove_player.png", Box(0, 0, 8, 7, 8, 14)),
            simple("assets/minecraft/textures/gui/sprites/player_list/remove_player_highlighted.png", Box(0, 7, 8, 7, 8, 14))
        ),
        input("assets/minecraft/textures/gui/sprites/accessibility.png",
            simple("assets/minecraft/textures/gui/sprites/icon/accessibility.png", Box(0, 0, 15, 15, 15, 15))
        ),
        input("assets/minecraft/textures/gui/container/stats_icons.png",
            simple("assets/minecraft/textures/gui/sprites/container/slot.png", Box(0, 0, 18, 18, 128, 128)),
            simple("assets/minecraft/textures/gui/sprites/statistics/block_mined.png", Box(54, 18, 18, 18, 128, 128)),
            simple("assets/minecraft/textures/gui/sprites/statistics/item_broken.png", Box(72, 18, 18, 18, 128, 128)),
            simple("assets/minecraft/textures/gui/sprites/statistics/item_crafted.png", Box(18, 18, 18, 18, 128, 128)),
            simple("assets/minecraft/textures/gui/sprites/statistics/item_used.png", Box(36, 18, 18, 18, 128, 128)),
            simple("assets/minecraft/textures/gui/sprites/statistics/item_picked_up.png", Box(90, 18, 18, 18, 128, 128)),
            simple("assets/minecraft/textures/gui/sprites/statistics/item_dropped.png", Box(108, 18, 18, 18, 128, 128)),
            simple("assets/minecraft/textures/gui/sprites/statistics/header.png", Box(0, 18, 18, 18, 128, 128)),
            simple("assets/minecraft/textures/gui/sprites/statistics/sort_up.png", Box(36, 0, 18, 18, 128, 128)),
            simple("assets/minecraft/textures/gui/sprites/statistics/sort_down.png", Box(18, 0, 18, 18, 128, 128))
        ),
        moveRealmsToMinecraft("realms/adventure"),
        moveRealmsToMinecraft("realms/darken"),
        moveRealmsToMinecraft("realms/empty_frame"),
        moveRealmsToMinecraft("realms/experience"),
        moveRealmsToMinecraft("realms/inspiration"),
        moveRealmsToMinecraft("realms/new_world"),
        moveRealmsToMinecraft("realms/popup"),
        moveRealmsToMinecraft("realms/survival_spawn"),
        moveRealmsToMinecraft("realms/upload"),
        moveRealmsToMinecraft("title/realms"),
        copy("advancements/backgrounds/adventure"),
        copy("advancements/backgrounds/end"),
        copy("advancements/backgrounds/husbandry"),
        copy("advancements/backgrounds/nether"),
        copy("advancements/backgrounds/stone"),
        copy("advancements/backgrounds/window"),
        copy("advancements/window"),
        copy("container/creative_inventory/tab_inventory"),
        copy("container/creative_inventory/tab_item_search"),
        copy("container/creative_inventory/tab_items"),
        clip("container/anvil", standardContainerBox),
        clip("container/beacon", Box(0, 0, 230, 219, 256, 256)),
        clip("container/blast_furnace", standardContainerBox),
        clip("container/brewing_stand", standardContainerBox),
        clip("container/cartography_table", standardContainerBox),
        clip("container/crafting_table", standardContainerBox),
        clip("container/dispenser", standardContainerBox),
        clip("container/enchanting_table", standardContainerBox),
        clip("container/furnace", standardContainerBox),
        clip("container/gamemode_switcher", Box(0, 0, 125, 75, 128, 128)),
        copy("container/generic_54"),
        clip("container/grindstone", standardContainerBox),
        clip("container/hopper", Box(0, 0, 176, 133, 256, 256)),
        clip("container/horse", standardContainerBox),
        clip("container/inventory", standardContainerBox),
        clip("container/loom", standardContainerBox),
        clip("container/shulker_box", standardContainerBox),
        clip("container/smithing", standardContainerBox),
        clip("container/smoker", standardContainerBox),
        clip("container/stonecutter", standardContainerBox),
        clip("container/villager2", "container/villager", Box(0, 0, 276, 166, 512, 256)),
        copy("hanging_signs/acacia"),
        copy("hanging_signs/bamboo"),
        copy("hanging_signs/birch"),
        copy("hanging_signs/cherry"),
        copy("hanging_signs/crimson"),
        copy("hanging_signs/dark_oak"),
        copy("hanging_signs/jungle"),
        copy("hanging_signs/mangrove"),
        copy("hanging_signs/oak"),
        copy("hanging_signs/spruce"),
        copy("hanging_signs/warped"),
        copy("presets/isles"),
        copy("title/background/panorama_0"),
        copy("title/background/panorama_1"),
        copy("title/background/panorama_2"),
        copy("title/background/panorama_3"),
        copy("title/background/panorama_4"),
        copy("title/background/panorama_5"),
        copy("title/background/panorama_overlay"),
        copy("title/edition"),
        copy("title/minceraft"),
        copy("title/minecraft"),
        copy("title/mojangstudios"),
        clip("book", Box(20, 1, 146, 180, 256, 256)),
        copy("demo_background"),
        copy("footer_separator"),
        copy("header_separator"),
        copy("light_dirt_background"),
        copy("options_background"),
        clip("recipe_book", Box(0, 0, 149, 168, 256, 256))
    ]
}

// From 1.20.5/src/main/java/com/mojang/slicer/Main.java: map_icons.png becomes separate map decorations.
private enum Table1_20_5: SlicerTable {
    static let inputs: [Input] = [
        input("assets/minecraft/textures/map/map_icons.png",
            mapDecoration("player", 0),
            mapDecoration("frame", 1),
            mapDecoration("red_marker", 2),
            mapDecoration("blue_marker", 3),
            mapDecoration("target_x", 4),
            mapDecoration("target_point", 5),
            mapDecoration("player_off_map", 6),
            mapDecoration("player_off_limits", 7),
            mapDecoration("woodland_mansion", 8),
            mapDecoration("ocean_monument", 9),
            mapDecoration("white_banner", 10),
            mapDecoration("orange_banner", 11),
            mapDecoration("magenta_banner", 12),
            mapDecoration("light_blue_banner", 13),
            mapDecoration("yellow_banner", 14),
            mapDecoration("lime_banner", 15),
            mapDecoration("pink_banner", 16),
            mapDecoration("gray_banner", 17),
            mapDecoration("light_gray_banner", 18),
            mapDecoration("cyan_banner", 19),
            mapDecoration("purple_banner", 20),
            mapDecoration("blue_banner", 21),
            mapDecoration("brown_banner", 22),
            mapDecoration("green_banner", 23),
            mapDecoration("red_banner", 24),
            mapDecoration("black_banner", 25),
            mapDecoration("red_x", 26),
            mapDecoration("desert_village", 27),
            mapDecoration("plains_village", 28),
            mapDecoration("savanna_village", 29),
            mapDecoration("snowy_village", 30),
            mapDecoration("taiga_village", 31),
            mapDecoration("jungle_temple", 32),
            mapDecoration("swamp_hut", 33)
        )
    ]
}

// From 26.2/src/main/java/com/mojang/slicer/Main.java: bed, sign and hanging sign textures split and rearranged.
// Its paths are relative to the pack's assets folder.
private enum Table26_2: SlicerTable {
    static let inputs: [Input] = [
            makeStaticBedPartProcessor(),
            makeBedProcessor("black"),
            makeBedProcessor("blue"),
            makeBedProcessor("brown"),
            makeBedProcessor("cyan"),
            makeBedProcessor("gray"),
            makeBedProcessor("green"),
            makeBedProcessor("light_blue"),
            makeBedProcessor("light_gray"),
            makeBedProcessor("lime"),
            makeBedProcessor("magenta"),
            makeBedProcessor("orange"),
            makeBedProcessor("pink"),
            makeBedProcessor("purple"),
            makeBedProcessor("red"),
            makeBedProcessor("white"),
            makeBedProcessor("yellow"),
            makeStandingSignProcessor("acacia"),
            makeStandingSignProcessor("birch"),
            makeStandingSignProcessor("crimson"),
            makeStandingSignProcessor("mangrove"),
            makeStandingSignProcessor("pale_oak"),
            makeStandingSignProcessor("warped"),
            makeStandingSignProcessor("bamboo"),
            makeStandingSignProcessor("cherry"),
            makeStandingSignProcessor("dark_oak"),
            makeStandingSignProcessor("jungle"),
            makeStandingSignProcessor("oak"),
            makeStandingSignProcessor("spruce"),
            makeHangingSignProcessor("acacia"),
            makeHangingSignProcessor("birch"),
            makeHangingSignProcessor("crimson"),
            makeHangingSignProcessor("mangrove"),
            makeHangingSignProcessor("pale_oak"),
            makeHangingSignProcessor("warped"),
            makeHangingSignProcessor("bamboo"),
            makeHangingSignProcessor("cherry"),
            makeHangingSignProcessor("dark_oak"),
            makeHangingSignProcessor("jungle"),
            makeHangingSignProcessor("oak"),
            makeHangingSignProcessor("spruce")
    ]

    static func makeStaticBedPartProcessor() -> Input {
        return input("minecraft/textures/entity/bed/black.png",
                simple("minecraft/textures/block/bed_down.png", Box(28, 6, 16, 16, 64, 64)).apply(.rotate180),
                multipart("minecraft/textures/block/bed_head_north.png", 16, 16,
                        part(
                                Box(6, 0, 16, 6, 64, 64),
                                [.rotate180],
                                0,
                                7
                        ),
                        part(
                                Box(53, 21, 3, 3, 64, 64),
                                [],
                                0,
                                13
                        ),
                        part(
                                Box(56, 21, 3, 3, 64, 64),
                                [],
                                3,
                                13
                        ),
                        part(
                                Box(59, 9, 3, 3, 64, 64),
                                [],
                                10,
                                13
                        ),
                        part(
                                Box(50, 9, 3, 3, 64, 64),
                                [],
                                13,
                                13
                        )
                )
        )
    }

    static func makeBedProcessor(_ color: String) -> Input {
        return input("minecraft/textures/entity/bed/" + color + ".png",
                simple("minecraft/textures/block/" + color + "_bed_head_up.png", Box(6, 6, 16, 16, 64, 64)),
                simple("minecraft/textures/block/" + color + "_bed_foot_up.png", Box(6, 28, 16, 16, 64, 64)),
                multipart("minecraft/textures/block/" + color + "_bed_foot_south.png", 16, 16,
                        part(
                                Box(22, 22, 16, 6, 64, 64),
                                [.mirrorVertically],
                                0,
                                7
                        ),
                        part(
                                Box(53, 3, 3, 3, 64, 64),
                                [],
                                0,
                                13
                        ),
                        part(
                                Box(56, 3, 3, 3, 64, 64),
                                [],
                                3,
                                13
                        ),
                        part(
                                Box(59, 15, 3, 3, 64, 64),
                                [],
                                10,
                                13
                        ),
                        part(
                                Box(50, 15, 3, 3, 64, 64),
                                [],
                                13,
                                13
                        )
                ),
                multipart("minecraft/textures/block/" + color + "_bed_foot_west.png", 16, 16,
                        part(
                                Box(0, 28, 6, 16, 64, 64),
                                [.rotate270],
                                0,
                                7
                        ),
                        part(
                                Box(56, 0, 3, 3, 64, 64),
                                [.mirrorVertically],
                                7,
                                13
                        ),
                        part(
                                Box(59, 3, 3, 3, 64, 64),
                                [],
                                10,
                                13
                        ),
                        part(
                                Box(50, 3, 3, 3, 64, 64),
                                [],
                                13,
                                13
                        )
                ),
                multipart("minecraft/textures/block/" + color + "_bed_foot_east.png", 16, 16,
                        part(
                                Box(22, 28, 6, 16, 64, 64),
                                [.rotate90],
                                0,
                                7
                        ),
                        part(
                                Box(53, 15, 3, 3, 64, 64),
                                [],
                                0,
                                13
                        ),
                        part(
                                Box(56, 15, 3, 3, 64, 64),
                                [],
                                3,
                                13
                        ),
                        part(
                                Box(56, 12, 3, 3, 64, 64),
                                [.rotate270, .mirrorVertically],
                                6,
                                13
                        )
                ),
                multipart("minecraft/textures/block/" + color + "_bed_head_east.png", 16, 16,
                        part(
                                Box(22, 6, 6, 16, 64, 64),
                                [.rotate90],
                                0,
                                7
                        ),
                        part(
                                Box(56, 18, 3, 3, 64, 64),
                                [.rotate180, .mirrorVertically],
                                7,
                                13
                        ),
                        part(
                                Box(59, 21, 3, 3, 64, 64),
                                [],
                                10,
                                13
                        ),
                        part(
                                Box(50, 21, 3, 3, 64, 64),
                                [],
                                13,
                                13
                        )
                ),
                multipart("minecraft/textures/block/" + color + "_bed_head_west.png", 16, 16,
                        part(
                                Box(0, 6, 6, 16, 64, 64),
                                [.rotate270],
                                0,
                                7
                        ),
                        part(
                                Box(53, 9, 3, 3, 64, 64),
                                [],
                                0,
                                13
                        ),
                        part(
                                Box(56, 9, 3, 3, 64, 64),
                                [],
                                3,
                                13
                        ),
                        part(
                                Box(56, 6, 3, 3, 64, 64),
                                [.rotate90, .mirrorVertically],
                                6,
                                13
                        )
                )
        )
    }

    static func makeStandingSignProcessor(_ woodType: String) -> Input {
        return input("minecraft/textures/entity/signs/" + woodType + ".png",
                multipart("minecraft/textures/gui/signs/" + woodType + ".png", 24, 26,
                        part(
                                Box(2, 2, 24, 12, 64, 32),
                                [],
                                0,
                                0
                        ),
                        part(
                                Box(2, 16, 2, 14, 64, 32),
                                [],
                                11,
                                12
                        )
                ),
                multipart("minecraft/textures/block/" + woodType + "_sign.png", 32, 32,
                        part(
                                Box(2, 0, 24, 14, 64, 32),
                                [],
                                0,
                                0
                        ),
                        part(
                                Box(26, 2, 2, 12, 64, 32),
                                [],
                                24,
                                2
                        ),
                        part(
                                Box(28, 2, 24, 12, 64, 32),
                                [],
                                0,
                                16
                        ),
                        part(
                                Box(0, 2, 2, 12, 64, 32),
                                [],
                                24,
                                16
                        ),
                        part(
                                Box(26, 0, 24, 2, 64, 32),
                                [.mirrorVertically],
                                0,
                                28
                        ),
                        part(
                                Box(2, 16, 4, 14, 64, 32),
                                [],
                                28,
                                0
                        ),
                        part(
                                Box(6, 16, 2, 14, 64, 32),
                                [],
                                28,
                                16
                        ),
                        part(
                                Box(0, 16, 2, 14, 64, 32),
                                [],
                                30,
                                16
                        ),
                        part(
                                Box(4, 14, 2, 2, 64, 32),
                                [.mirrorVertically],
                                28,
                                30
                        )
                )
        )
    }

    static func makeHangingSignProcessor(_ woodType: String) -> Input {
        return input("minecraft/textures/entity/signs/hanging/" + woodType + ".png",
                multipart("minecraft/textures/block/" + woodType + "_hanging_sign.png", 32, 32,
                        part(
                                // west - front - east - back
                                Box(0, 14, 32, 10, 64, 32),
                                [],
                                0,
                                16
                        ),
                        part(
                                // up
                                Box(2, 12, 14, 2, 64, 32),
                                [],
                                2,
                                14
                        ),
                        part(
                                // down
                                Box(16, 12, 14, 2, 64, 32),
                                [.mirrorVertically],
                                2,
                                26
                        ),
                        part(
                                // bar: up - front
                                Box(4, 0, 16, 6, 64, 32),
                                [],
                                0,
                                0
                        ),
                        part(
                                // bar: down
                                Box(20, 0, 16, 4, 64, 32),
                                [.rotate180],
                                0,
                                9
                        ),
                        part(
                                // bar: east
                                Box(20, 4, 4, 2, 64, 32),
                                [],
                                16,
                                4
                        ),
                        part(
                                // bar: back
                                Box(24, 4, 16, 2, 64, 32),
                                [],
                                0,
                                7
                        ),
                        part(
                                // bar: west
                                Box(0, 4, 4, 2, 64, 32),
                                [],
                                16,
                                7
                        ),
                        part(
                                // chain angled
                                Box(14, 6, 12, 6, 64, 32),
                                [],
                                20,
                                0
                        ),
                        part(
                                // chain straight
                                Box(0, 6, 9, 6, 64, 32),
                                [],
                                22,
                                7
                        )
                )
        )
    }
}
