import Darwin
import Foundation


/// Packet numbers for one Minecraft version, from Mojang's own data generator, so nothing is hardcoded.
struct ProtocolTable: Sendable {
    let version: Int
    let ids: [String: Int32]

    func id(_ state: String, _ direction: String, _ name: String) -> Int32? { ids["\(state)/\(direction)/minecraft:\(name)"] }

    /// Runs `--reports` on the vanilla server for this version, once.
    static func load(mc: String, cache: URL, java: String) async throws -> ProtocolTable {
        let folder = cache.appendingPathComponent(mc, isDirectory: true)
        let packets = folder.appendingPathComponent("reports/packets.json")
        let versionFile = folder.appendingPathComponent("version.json")
        if !FileOps.exists(packets) || !FileOps.exists(versionFile) {
            try FileOps.ensureDir(folder)
            guard let build = try await SoftwareCatalog.latestBuild(.vanilla, mc: mc) else { throw LeafError("No vanilla \(mc).") }
            let jar = folder.appendingPathComponent("vanilla.jar")
            try await HTTP.download(HTTP.url(build.downloadURL), to: jar, expect: build.hashes)
            // The generator clears its output folder, so it gets one of its own.
            let v = try await Tool.run("/usr/bin/unzip", ["-p", jar.path, "version.json"])
            let output = folder.appendingPathComponent("generated", isDirectory: true)
            let r = try await Tool.run(java, ["-DbundlerMainClass=net.minecraft.data.Main", "-jar", jar.path, "--reports", "--output", output.path], cwd: folder)
            let made = output.appendingPathComponent("reports/packets.json")
            guard FileOps.exists(made) else { throw LeafError("Data generator failed: \(r.err.prefix(300)) \(r.out.suffix(300))") }
            try FileOps.move(made, to: packets)
            try FileOps.writeAtomic(v.out, to: versionFile)
        }
        let version = (try JSONSerialization.jsonObject(with: Data(contentsOf: versionFile)) as? [String: Any])?["protocol_version"] as? Int
        guard let version, let root = try JSONSerialization.jsonObject(with: Data(contentsOf: packets)) as? [String: [String: [String: [String: Any]]]] else {
            throw LeafError("Couldn't read the packet table for \(mc).")
        }
        var ids: [String: Int32] = [:]
        for (state, directions) in root {
            for (direction, packets) in directions {
                for (name, info) in packets { if let n = info["protocol_id"] as? Int { ids["\(state)/\(direction)/\(name)"] = Int32(n) } }
            }
        }
        return ProtocolTable(version: version, ids: ids)
    }
}

/// A player, as far as the server can tell. Logs in to an offline-mode server, stays connected
/// and answers what it must. All its actions come from console commands such as `give` and `mv tp`.
final class Bot: @unchecked Sendable {
    let name: String
    private let table: ProtocolTable
    private let fd: Int32
    private var state = "login"
    private var buffer = [UInt8]()
    private let lock = NSLock()
    private var alive = true
    private(set) var inGame = false
    private(set) var disconnectReason: String?
    /// What the server offered, if it sent a resource pack.
    private(set) var packOffer: (url: String, hash: String, required: Bool)?
    /// How to answer a resource pack: nil says nothing, 0 loaded, 1 declined.
    private let packAnswer: Int32?

    init(name: String, port: Int, table: ProtocolTable, packAnswer: Int32? = 0) throws {
        self.name = name
        self.table = table
        self.packAnswer = packAnswer
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw LeafError("\(name) couldn't connect to port \(port).") }

        // Handshake, then ask to log in.
        var handshake = Self.varInt(Int32(table.version))
        handshake += Self.string("127.0.0.1")
        handshake += [UInt8(port >> 8 & 0xFF), UInt8(port & 0xFF)]
        handshake += Self.varInt(2)
        send(table.id("handshake", "serverbound", "intention") ?? 0, handshake)
        let login = Self.string(name) + Array(repeating: UInt8(0), count: 16)   // The server works out an offline UUID itself.
        send(table.id("login", "serverbound", "hello") ?? 0, login)
        let thread = Thread { [weak self] in self?.run() }
        thread.stackSize = 1 << 20
        thread.start()
    }

    func leave() {
        lock.lock(); defer { lock.unlock() }
        if alive { alive = false; shutdown(fd, SHUT_RDWR); close(fd) }
    }

    deinit { leave() }

    private static func varInt(_ value: Int32) -> [UInt8] {
        var v = UInt32(bitPattern: value)
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    private static func string(_ s: String) -> [UInt8] {
        let bytes = Array(s.utf8)
        return varInt(Int32(bytes.count)) + bytes
    }

    private func send(_ id: Int32, _ body: [UInt8]) {
        let packet = Self.varInt(id) + body
        let frame = Self.varInt(Int32(packet.count)) + packet
        lock.lock(); defer { lock.unlock() }
        guard alive else { return }
        _ = frame.withUnsafeBytes { write(fd, $0.baseAddress, frame.count) }
    }

    private func readVarInt(_ bytes: [UInt8], at index: inout Int) -> Int32? {
        var result: UInt32 = 0, shift: UInt32 = 0
        while index < bytes.count, shift < 35 {
            let b = bytes[index]
            index += 1
            result |= UInt32(b & 0x7F) << shift
            if b & 0x80 == 0 { return Int32(bitPattern: result) }
            shift += 7
        }
        return nil
    }

    private func run() {
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while true {
                var i = 0
                guard let length = readVarInt(buffer, at: &i), buffer.count - i >= Int(length) else { break }
                let packet = Array(buffer[i..<(i + Int(length))])
                buffer.removeFirst(i + Int(length))
                handle(packet)
            }
        }
        lock.lock(); alive = false; lock.unlock()
        inGame = false
    }

    private func handle(_ packet: [UInt8]) {
        var i = 0
        guard let id = readVarInt(packet, at: &i) else { return }
        let body = Array(packet[i...])
        func `is`(_ name: String) -> Bool { table.id(state, "clientbound", name) == id }
        func reply(_ name: String, _ data: [UInt8] = []) {
            if let out = table.id(state, "serverbound", name) { send(out, data) }
        }
        if `is`("resource_pack_push"), body.count > 16 {
            var at = 16
            func text() -> String {
                guard let n = readVarInt(body, at: &at), n >= 0, at + Int(n) <= body.count else { return "" }
                defer { at += Int(n) }
                return String(decoding: body[at..<(at + Int(n))], as: UTF8.self)
            }
            let url = text(), hash = text()
            packOffer = (url, hash, at < body.count && body[at] != 0)
            if let packAnswer { reply("resource_pack", Array(body[0..<16]) + Self.varInt(packAnswer)) }
            return
        }
        switch state {
        case "login":
            if `is`("login_finished") || `is`("game_profile") {
                reply("login_acknowledged")
                state = "configuration"
            } else if `is`("login_disconnect") {
                disconnectReason = String(decoding: body, as: UTF8.self)
            }
        case "configuration":
            if `is`("select_known_packs") {
                reply("select_known_packs", Self.varInt(0))
            } else if `is`("finish_configuration") {
                reply("finish_configuration")
                state = "play"
            } else if `is`("keep_alive") {
                reply("keep_alive", body)
            } else if `is`("ping") {
                reply("pong", body)
            } else if `is`("disconnect") {
                disconnectReason = String(decoding: body, as: UTF8.self)
            }
        default:
            if `is`("keep_alive") {
                reply("keep_alive", body)
            } else if `is`("ping") {
                reply("pong", body)
            } else if `is`("player_position") {
                // The teleport id comes first in current versions.
                var j = 0
                // 26.x changed this reply's layout, and a bot that never moves doesn't need to send it.
                if table.version <= 774, let teleport = readVarInt(body, at: &j) { reply("accept_teleportation", Self.varInt(teleport)) }
                if !inGame {
                    inGame = true
                    reply("player_loaded")
                }
            } else if `is`("chunk_batch_finished") {
                reply("chunk_batch_received", [0x41, 0xA0, 0, 0])   // 20 chunks per tick, a float.
            } else if `is`("start_configuration") {
                reply("configuration_acknowledged")
                state = "configuration"
            } else if `is`("disconnect") {
                disconnectReason = String(decoding: body, as: UTF8.self)
            }
        }
    }
}
