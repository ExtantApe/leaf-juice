import Darwin
import Foundation

/// A running `java` child process, with line-buffered output.
public final class ServerProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let queue = DispatchQueue(label: "leafjuice.process.output", qos: .utility)
    private var buffer = Data()
    public var pid: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    /// Called on a background queue.
    public var onLine: (@Sendable (String) -> Void)?
    public var onExit: (@Sendable (Int32) -> Void)?

    public init(java: String, arguments: [String], directory: URL) {
        process.executableURL = URL(fileURLWithPath: java)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        process.environment = env
    }

    public func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.queue.async { self.consume(data) }
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.output.fileHandleForReading.readabilityHandler = nil
            let rest = self.output.fileHandleForReading.readDataToEndOfFileSafely()
            self.queue.async {
                self.consume(rest)
                if !self.buffer.isEmpty { self.emit(self.buffer); self.buffer.removeAll() }
                self.onExit?(p.terminationStatus)
            }
        }
        try process.run()
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            emit(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        // A runaway line without a newline shouldn't grow forever.
        if buffer.count > 1 << 20 { emit(buffer); buffer.removeAll() }
    }

    private func emit(_ data: Data) {
        if let line = ConsoleText.clean(String(decoding: data, as: UTF8.self)) { onLine?(line) }
    }

    public func send(_ command: String) {
        guard process.isRunning else { return }
        try? input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
    }

    /// Asks the JVM to shut down. Its shutdown hook saves the world.
    public func terminate() { if process.isRunning { process.terminate() } }
    public func kill() { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
}

private extension FileHandle {
    func readDataToEndOfFileSafely() -> Data { (try? readToEnd()) ?? Data() }
}

public enum ConsoleText {
    /// Paper redraws its `> ` prompt around each line, so output arrives as `> \\r  \\r[12:00:00 INFO]: text`.
    /// A carriage return means "overwrite this line", so only what follows the last one is real.
    /// Returns nil for a line that's only the prompt.
    public static func clean(_ raw: String) -> String? {
        var line = ANSI.strip(raw)
        while line.hasSuffix("\r") { line.removeLast() }
        if let last = line.lastIndex(of: "\r") { line = String(line[line.index(after: last)...]) }
        if line == ">" || line == "> " { return nil }
        // Newer servers echo console commands back. Real output always starts with a timestamp.
        if line.hasPrefix("> ") { return nil }
        return line
    }
}

public enum ANSI {
    private static let pattern = regex(#"\x1B\[[0-9;?]*[ -/]*[@-~]|\x1B[@-_]"#)
    public static func strip(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
}

// MARK: - System facts

public enum SystemInfo {
    public static var memoryMB: Int { Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024)) }

    /// Is something already listening on this port?
    /// The folder a process is running in, which tells a server apart from whatever else has its number.
    public static func workingDirectory(pid: Int32) -> URL? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    public static func isPortBusy(_ port: Int) -> Bool {
        // Observed: on a Mac, binding to every address succeeds even while something holds the port on 127.0.0.1 alone,
        // as the Lab does. So both are tried.
        for host in [INADDR_ANY, INADDR_LOOPBACK] {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var yes: Int32 = 1
            // Ignores connections still in TIME_WAIT, but a live listener still blocks the bind.
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port).bigEndian
            address.sin_addr.s_addr = host.bigEndian
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if result != 0 { return true }
        }
        return false
    }

    public static func isAlive(pid: Int32) -> Bool { pid > 0 && kill(pid, 0) == 0 }

    public static func commandLine(pid: Int32) async -> String? {
        (try? await Tool.run("/bin/ps", ["-o", "command=", "-p", String(pid)]))?.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The Mac's addresses on the local network, for telling friends where to connect.
    public static func lanAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en"), let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}

/// Samples CPU and memory for a process from the kernel, without spawning anything.
public final class MetricsSampler {
    private var lastCPU: UInt64?
    private var lastTime: Date?
    private static let timebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (info.numer, info.denom)
    }()

    public init() {}

    public func sample(pid: Int32) -> ProcessMetrics? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        let ticks = info.pti_total_user + info.pti_total_system
        let nanos = ticks &* UInt64(Self.timebase.numer) / UInt64(Self.timebase.denom)
        let now = Date()
        var cpu = 0.0
        if let lastCPU, let lastTime, nanos >= lastCPU {
            let elapsed = now.timeIntervalSince(lastTime)
            if elapsed > 0 { cpu = Double(nanos - lastCPU) / 1e9 / elapsed * 100 }
        }
        lastCPU = nanos
        lastTime = now
        return ProcessMetrics(memoryBytes: Int64(info.pti_resident_size), cpuPercent: cpu)
    }
}
