import Foundation

// leafjuice-session: asks a running LeafJuice for a server's status or recent log, or runs a command from the
// owner's list. It reads the token from the login Keychain with /usr/bin/security, so the first time macOS asks the
// owner to allow it. LEAFJUICE_SESSION_TOKEN and LEAFJUICE_HOME override the token and the folder, for checks.

let usage = """
Usage:
  leafjuice-session --as "Your name" status [--server NAME]
  leafjuice-session --as "Your name" log [--lines 50] [--server NAME]
  leafjuice-session --as "Your name" run "save-all" [--server NAME]

Prints LeafJuice's answer as JSON. Exits 0 when ok is true, 1 when refused, 2 when LeafJuice can't be reached.
Only commands on the owner's list in LeafJuice's Settings are sent.
"""

var args = Array(CommandLine.arguments.dropFirst())
func take(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...i + 1)
    return value
}
let caller = take("--as")
let server = take("--server")
let lines = take("--lines").flatMap(Int.init)
guard let caller, let call = args.first, ["status", "log", "run"].contains(call) else {
    FileHandle.standardError.write(Data((usage + "\n").utf8)); exit(64)
}
let command = call == "run" ? args.dropFirst().joined(separator: " ") : nil
if call == "run", command?.isEmpty != false { FileHandle.standardError.write(Data("run needs a command.\n".utf8)); exit(64) }

func token() -> String? {
    if let t = ProcessInfo.processInfo.environment["LEAFJUICE_SESSION_TOKEN"], !t.isEmpty { return t }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", "LeafJuice session access", "-a", "token", "-w"]
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

let home = ProcessInfo.processInfo.environment["LEAFJUICE_HOME"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Leaf Juice")
let path = ProcessInfo.processInfo.environment["LEAFJUICE_SESSION_SOCKET"] ?? home.appendingPathComponent("session.sock").path

guard let secret = token() else {
    FileHandle.standardError.write(Data("No token: turn on session access in LeafJuice's Settings, and allow the Keychain prompt if one appears.\n".utf8)); exit(2)
}
var request: [String: Any] = ["token": secret, "caller": caller, "call": call]
if let server { request["server"] = server }
if let lines { request["lines"] = lines }
if let command { request["command"] = command }
var body = try! JSONSerialization.data(withJSONObject: request)
body.append(0x0A)

let s = socket(AF_UNIX, SOCK_STREAM, 0)
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
guard path.utf8.count < 104 else { FileHandle.standardError.write(Data("The socket path is too long.\n".utf8)); exit(2) }
withUnsafeMutableBytes(of: &address.sun_path) { raw in
    let bytes = Array(path.utf8)
    for (i, b) in bytes.enumerated() { raw[i] = b }
    raw[bytes.count] = 0
}
let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
guard connected == 0 else { FileHandle.standardError.write(Data("LeafJuice isn't listening. Is it open, with session access on?\n".utf8)); exit(2) }
_ = body.withUnsafeBytes { write(s, $0.baseAddress, $0.count) }
var reply = Data()
var buffer = [UInt8](repeating: 0, count: 4096)
while true {
    let n = read(s, &buffer, buffer.count)
    if n <= 0 { break }
    reply.append(contentsOf: buffer[0..<n])
}
close(s)
FileHandle.standardOutput.write(reply)
let ok = ((try? JSONSerialization.jsonObject(with: reply)) as? [String: Any])?["ok"] as? Bool == true
exit(ok ? 0 : 1)
