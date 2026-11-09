import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Server icons to rotate between. Choices live in <server>/server-icons/, and the one in use is the file Paper reads,
// <server>/server-icon.png, which must be a 64×64 PNG and is only read when the server starts. Picking copies over
// server-icon.png. Nothing in server-icons/ is ever moved or deleted.

public struct ServerIconChoice: Identifiable, Equatable, Sendable {
    public var id: String { file.lastPathComponent }
    public let file: URL
    public let width: Int
    public let height: Int
    /// Same bytes as server-icon.png. There's no other record of which one is in use.
    public let inUse: Bool
    public var name: String { file.deletingPathExtension().lastPathComponent }
    public var fits: Bool { width == ServerIcons.size && height == ServerIcons.size }
}

public enum ServerIcons {
    public static let size = 64
    public static let folderName = "server-icons"

    public static func folder(_ paths: ServerPaths) -> URL { paths.root.appendingPathComponent(folderName, isDirectory: true) }
    public static func active(_ paths: ServerPaths) -> URL { paths.root.appendingPathComponent("server-icon.png") }

    /// The PNGs in the icon folder, by name.
    public static func list(_ paths: ServerPaths) -> [ServerIconChoice] {
        let current = try? Data(contentsOf: active(paths))
        return FileOps.children(folder(paths))
            .filter { $0.pathExtension.lowercased() == "png" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { file in
                guard let (w, h) = dimensions(file) else { return nil }
                return ServerIconChoice(file: file, width: w, height: h, inUse: current != nil && (try? Data(contentsOf: file)) == current)
            }
    }

    /// True when server-icon.png exists but matches nothing in the folder, so picking another would lose it.
    public static func activeIsUnsaved(_ paths: ServerPaths) -> Bool {
        FileOps.exists(active(paths)) && !list(paths).contains(where: \.inUse)
    }

    /// Makes the chosen icon the one Paper reads. The one in use is kept in the folder first if it isn't there yet.
    public static func use(_ choice: ServerIconChoice, paths: ServerPaths) throws {
        guard choice.fits else { throw LeafError("\(choice.file.lastPathComponent) is \(choice.width)×\(choice.height). Minecraft needs a 64×64 PNG.") }
        guard choice.file.deletingLastPathComponent().standardizedFileURL == folder(paths).standardizedFileURL else { throw LeafError("That icon isn't in this server's icon folder.") }
        try keepCurrent(paths)
        let data = try Data(contentsOf: choice.file)
        try data.write(to: active(paths), options: .atomic)
    }

    /// Saves the icon in use into the folder, if it isn't already there, so it can be picked again.
    @discardableResult
    public static func keepCurrent(_ paths: ServerPaths) throws -> URL? {
        guard activeIsUnsaved(paths), let data = try? Data(contentsOf: active(paths)) else { return nil }
        try FileOps.ensureDir(folder(paths))
        let target = unusedName("previous-icon", in: folder(paths))
        try data.write(to: target, options: .atomic)
        return target
    }

    public enum Added: Equatable, Sendable {
        case added(URL)
        case scaled(URL, from: Int)
        case alreadyThere(URL)
    }

    /// Adds an image to the folder as a 64×64 PNG. A square image of another size is scaled with nearest-neighbour,
    /// so pixel art stays sharp. Anything else is refused with the reason.
    public static func add(_ source: URL, paths: ServerPaths) throws -> Added {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(image, 0, nil) else {
            throw LeafError("\(source.lastPathComponent) isn't an image Leaf Juice can read.")
        }
        guard cg.width == cg.height else {
            throw LeafError("\(source.lastPathComponent) is \(cg.width)×\(cg.height). A server icon has to be square; crop it first, then add it.")
        }
        try FileOps.ensureDir(folder(paths))
        let isPNG = (CGImageSourceGetType(image) as String?) == UTType.png.identifier
        let data: Data
        if cg.width == size, isPNG {
            data = try Data(contentsOf: source)
        } else {
            data = try png(cg.width == size ? cg : nearest(cg, to: size))
        }
        if let same = list(paths).first(where: { (try? Data(contentsOf: $0.file)) == data }) { return .alreadyThere(same.file) }
        let base = slug(source.deletingPathExtension().lastPathComponent)
        let target = unusedName(base.isEmpty ? "icon" : base, in: folder(paths))
        try data.write(to: target, options: .atomic)
        return cg.width == size ? .added(target) : .scaled(target, from: cg.width)
    }

    static func dimensions(_ file: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    static func nearest(_ image: CGImage, to side: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw LeafError("The image couldn't be resized.")
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let out = context.makeImage() else { throw LeafError("The image couldn't be resized.") }
        return out
    }

    static func png(_ image: CGImage) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { throw LeafError("The PNG couldn't be written.") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw LeafError("The PNG couldn't be written.") }
        return out as Data
    }

    static func slug(_ text: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        var out = ""
        for ch in text.lowercased() { out.append(allowed.contains(ch) ? ch : "-") }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func unusedName(_ base: String, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent("\(base).png")
        var n = 2
        while FileOps.exists(candidate) {
            candidate = folder.appendingPathComponent("\(base)-\(n).png")
            n += 1
        }
        return candidate
    }
}
