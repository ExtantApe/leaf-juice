import Compression
import Foundation

/// gzip, done natively: player data and `level.dat` are gzipped.
public enum Gzip {
    public static func isGzip(_ data: Data) -> Bool { data.count > 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B }

    public static func decompress(_ input: Data) throws -> Data {
        let data = Data(input)
        guard isGzip(data), data.count >= 18 else { throw LeafError("That file isn't gzip data.") }
        let flags = data[3]
        var offset = 10
        if flags & 4 != 0 { guard offset + 1 < data.count else { throw LeafError("That gzip data is damaged.") }; offset += 2 + Int(data[offset]) + Int(data[offset + 1]) << 8 }
        if flags & 8 != 0 { while offset < data.count, data[offset] != 0 { offset += 1 }; offset += 1 }
        if flags & 16 != 0 { while offset < data.count, data[offset] != 0 { offset += 1 }; offset += 1 }
        if flags & 2 != 0 { offset += 2 }
        let size = Int(data[data.count - 4]) | Int(data[data.count - 3]) << 8 | Int(data[data.count - 2]) << 16 | Int(data[data.count - 1]) << 24
        // A crafted header can point past the end, or claim a huge size (K158 audit).
        guard offset <= data.count - 8 else { throw LeafError("That gzip data is damaged.") }
        var capacity = min(max(size, 1024), 512 << 20)
        let body = data[offset..<(data.count - 8)]
        for _ in 0..<2 {
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { dst in
                body.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity, src.bindMemory(to: UInt8.self).baseAddress!, body.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written == size || (written > 0 && written < capacity) { return out.prefix(written) }
            capacity = min(max(capacity * 8, 1 << 24), 512 << 20)   // ISIZE wraps at 4 GB; a hint only, and capped.
        }
        throw LeafError("That file's compressed data is damaged.")
    }

    public static func compress(_ data: Data) throws -> Data {
        let capacity = data.count + data.count / 8 + 1024
        var body = Data(count: capacity)
        let written = body.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw LeafError("Couldn't compress that data.") }
        var out = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF])
        out.append(body.prefix(written))
        func le(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        out.append(contentsOf: le(crc32(data)))
        out.append(contentsOf: le(UInt32(truncatingIfNeeded: data.count)))
        return out
    }

    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}

/// Minecraft's binary data format. Order and exact values are preserved, so whatever isn't
/// deliberately changed is written back byte for byte.
public indirect enum NBT: Equatable, Sendable {
    case byte(Int8), short(Int16), int(Int32), long(Int64), float(UInt32), double(UInt64)
    case byteArray([Int8]), string(String), list(UInt8, [NBT])
    case compound([Entry]), intArray([Int32]), longArray([Int64])

    public struct Entry: Equatable, Sendable {
        public var name: String
        public var value: NBT
        public init(_ name: String, _ value: NBT) { self.name = name; self.value = value }
    }

    var typeID: UInt8 {
        switch self {
        case .byte: 1
        case .short: 2
        case .int: 3
        case .long: 4
        case .float: 5
        case .double: 6
        case .byteArray: 7
        case .string: 8
        case .list: 9
        case .compound: 10
        case .intArray: 11
        case .longArray: 12
        }
    }

    public subscript(_ name: String) -> NBT? {
        get {
            guard case let .compound(entries) = self else { return nil }
            return entries.first { $0.name == name }?.value
        }
        set {
            guard case var .compound(entries) = self else { return }
            if let i = entries.firstIndex(where: { $0.name == name }) {
                if let newValue { entries[i].value = newValue } else { entries.remove(at: i) }
            } else if let newValue {
                entries.append(Entry(name, newValue))
            }
            self = .compound(entries)
        }
    }

    public var stringValue: String? { if case let .string(s) = self { s } else { nil } }
    public var intValue: Int? {
        switch self {
        case let .byte(v): Int(v)
        case let .short(v): Int(v)
        case let .int(v): Int(v)
        case let .long(v): Int(v)
        default: nil
        }
    }
    public var listValue: [NBT]? { if case let .list(_, items) = self { items } else { nil } }

    /// A UUID as stored in modern files.
    public static func uuid(_ id: UUID) -> NBT {
        let b = id.uuid
        func word(_ a: UInt8, _ c: UInt8, _ d: UInt8, _ e: UInt8) -> Int32 {
            Int32(bitPattern: UInt32(a) << 24 | UInt32(c) << 16 | UInt32(d) << 8 | UInt32(e))
        }
        return .intArray([word(b.0, b.1, b.2, b.3), word(b.4, b.5, b.6, b.7), word(b.8, b.9, b.10, b.11), word(b.12, b.13, b.14, b.15)])
    }

    // MARK: Files

    /// The root's name, almost always empty, and its value.
    public struct Document: Equatable, Sendable {
        public var name: String
        public var root: NBT
        public var compressed: Bool
        public init(name: String = "", root: NBT, compressed: Bool = true) { self.name = name; self.root = root; self.compressed = compressed }
    }

    public static func read(_ url: URL) throws -> Document { try decode(Data(contentsOf: url)) }

    public static func decode(_ input: Data) throws -> Document {
        let compressed = Gzip.isGzip(input)
        var reader = Reader(data: compressed ? try Gzip.decompress(input) : Data(input))
        let type = try reader.u8()
        guard type == 10 else { throw LeafError("That isn't a Minecraft data file.") }
        let name = try reader.string()
        let root = try reader.tag(type, depth: 0)
        return Document(name: name, root: root, compressed: compressed)
    }

    public static func encode(_ document: Document) throws -> Data {
        var w = Writer()
        w.u8(document.root.typeID)
        w.string(document.name)
        w.tag(document.root)
        return document.compressed ? try Gzip.compress(w.data) : w.data
    }

    /// Writes beside the target first, so a failure can't leave half a file.
    public static func write(_ document: Document, to url: URL) throws {
        try FileOps.ensureDir(url.deletingLastPathComponent())
        try encode(document).write(to: url, options: .atomic)
    }

    private struct Reader {
        let data: Data
        var at = 0
        init(data: Data) { self.data = Data(data) }

        mutating func take(_ n: Int) throws -> Data {
            guard n >= 0, at + n <= data.count else { throw LeafError("That data file is cut short or damaged.") }
            defer { at += n }
            return data[at..<(at + n)]
        }
        mutating func u8() throws -> UInt8 { try take(1).first! }
        mutating func be<T: FixedWidthInteger>(_: T.Type) throws -> T {
            try take(MemoryLayout<T>.size).reduce(T(0)) { ($0 << 8) | T(truncatingIfNeeded: $1) }
        }
        mutating func string() throws -> String {
            let length = Int(try be(UInt16.self))
            return String(decoding: try take(length), as: UTF8.self)
        }
        mutating func count() throws -> Int {
            let n = Int(try be(Int32.self))
            guard n >= 0, n <= data.count else { throw LeafError("That data file is cut short or damaged.") }
            return n
        }
        mutating func tag(_ type: UInt8, depth: Int) throws -> NBT {
            guard depth < 512 else { throw LeafError("That data file is nested too deeply.") }
            switch type {
            case 1: return .byte(Int8(bitPattern: try u8()))
            case 2: return .short(try be(Int16.self))
            case 3: return .int(try be(Int32.self))
            case 4: return .long(try be(Int64.self))
            case 5: return .float(try be(UInt32.self))
            case 6: return .double(try be(UInt64.self))
            case 7: return .byteArray(try take(try count()).map { Int8(bitPattern: $0) })
            case 8: return .string(try string())
            case 9:
                let inner = try u8()
                let n = Int(try be(Int32.self))
                guard n <= data.count else { throw LeafError("That data file is cut short or damaged.") }
                var items: [NBT] = []
                for _ in 0..<max(n, 0) { items.append(try tag(inner, depth: depth + 1)) }
                return .list(inner, items)
            case 10:
                var entries: [Entry] = []
                while true {
                    let t = try u8()
                    if t == 0 { break }
                    let name = try string()
                    entries.append(Entry(name, try tag(t, depth: depth + 1)))
                }
                return .compound(entries)
            case 11:
                var out: [Int32] = []
                for _ in 0..<(try count()) { out.append(try be(Int32.self)) }
                return .intArray(out)
            case 12:
                var out: [Int64] = []
                for _ in 0..<(try count()) { out.append(try be(Int64.self)) }
                return .longArray(out)
            default:
                throw LeafError("That data file has an unknown kind of value.")
            }
        }
    }

    private struct Writer {
        var data = Data()
        mutating func u8(_ v: UInt8) { data.append(v) }
        mutating func be<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
        mutating func string(_ s: String) {
            let bytes = Array(s.utf8)
            be(UInt16(min(bytes.count, 65535)))
            data.append(contentsOf: bytes.prefix(65535))
        }
        mutating func tag(_ t: NBT) {
            switch t {
            case let .byte(v): u8(UInt8(bitPattern: v))
            case let .short(v): be(v)
            case let .int(v): be(v)
            case let .long(v): be(v)
            case let .float(v): be(v)
            case let .double(v): be(v)
            case let .byteArray(v): be(Int32(v.count)); data.append(contentsOf: v.map { UInt8(bitPattern: $0) })
            case let .string(v): string(v)
            case let .list(type, items): u8(type); be(Int32(items.count)); items.forEach { tag($0) }
            case let .compound(entries):
                for e in entries { u8(e.value.typeID); string(e.name); tag(e.value) }
                u8(0)
            case let .intArray(v): be(Int32(v.count)); v.forEach { be($0) }
            case let .longArray(v): be(Int32(v.count)); v.forEach { be($0) }
            }
        }
    }
}
