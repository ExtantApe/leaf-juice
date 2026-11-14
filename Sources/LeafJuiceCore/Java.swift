import Foundation

public struct JavaRuntime: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let version: String
    public let major: Int
    public let vendor: String?
    public let managed: Bool

    public var label: String {
        var text = "Java \(major)"
        if let vendor { text += " (\(vendor))" }
        if managed { text += ", installed by LeafJuice" }
        return text
    }
}

public enum JavaManager {
    /// `openjdk version "21.0.11"` → 21; `java version "1.8.0_392"` → 8.
    public static func parseVersionOutput(_ text: String) -> (version: String, major: Int)? {
        guard let version = regex(#"version "([^"]+)""#).firstGroup(in: text) else { return nil }
        let parts = version.split(whereSeparator: { ".-_+".contains($0) })
        guard let first = parts.first, let number = Int(first) else { return nil }
        if number == 1, parts.count > 1, let legacy = Int(parts[1]) { return (version, legacy) }
        return (version, number)
    }

    public static func discover() async -> [JavaRuntime] {
        var paths: [String] = []
        // Avoid /usr/bin/java: without a JDK it's a stub that opens an install dialog.
        if let result = try? await Tool.run("/usr/libexec/java_home", ["-X"]), result.ok,
           let plist = try? PropertyListSerialization.propertyList(from: Data(result.out.utf8), format: nil) as? [[String: Any]] {
            paths += plist.compactMap { ($0["JVMHomePath"] as? String).map { $0 + "/bin/java" } }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for base in ["/opt/homebrew/opt", "/usr/local/opt"] {
            paths += FileOps.children(URL(fileURLWithPath: base))
                .filter { $0.lastPathComponent.hasPrefix("openjdk") }
                .map { $0.appendingPathComponent("bin/java").path }
        }
        paths += FileOps.children(home.appendingPathComponent(".sdkman/candidates/java"))
            .map { $0.appendingPathComponent("bin/java").path }
        let managed = FileOps.children(AppPaths.runtimes).map { $0.appendingPathComponent("Contents/Home/bin/java").path }
        paths += managed

        var seen = Set<String>()
        var found: [JavaRuntime] = []
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard seen.insert(real).inserted, let runtime = await inspect(path: path, managed: managed.contains(path)) else { continue }
            found.append(runtime)
        }
        return found.sorted { ($0.major, $0.managed ? 1 : 0) > ($1.major, $1.managed ? 1 : 0) }
    }

    public static func inspect(path: String, managed: Bool = false) async -> JavaRuntime? {
        guard let result = try? await Tool.run(path, ["-version"]),
              let parsed = parseVersionOutput(result.err + result.out) else { return nil }
        let text = result.err + result.out
        let vendor = ["Temurin", "Homebrew", "Corretto", "Zulu", "GraalVM", "Oracle"].first { text.contains($0) }
        return JavaRuntime(path: path, version: parsed.version, major: parsed.major, vendor: vendor, managed: managed)
    }

    /// The lowest LTS-friendly match: the smallest runtime that meets the requirement.
    /// Minecraft is only tested against recent Javas, so a far newer one isn't preferred.
    public static func best(for required: Int, in runtimes: [JavaRuntime]) -> JavaRuntime? {
        runtimes.filter { $0.major >= required }.min { $0.major < $1.major }
    }

    /// Downloads an Eclipse Temurin runtime into LeafJuice's own folder.
    public static func installTemurin(major: Int, progress: (@Sendable (Double) -> Void)? = nil) async throws -> JavaRuntime {
        #if arch(arm64)
        let arch = "aarch64"
        #else
        let arch = "x64"
        #endif
        struct Asset: Decodable {
            struct Binary: Decodable {
                struct Package: Decodable { let link: String; let checksum: String }
                let package: Package
            }
            let binary: Binary
        }
        let api = "https://api.adoptium.net/v3/assets/latest/\(major)/hotspot?architecture=\(arch)&image_type=jre&os=mac&vendor=eclipse"
        let assets = try await HTTP.decode([Asset].self, HTTP.url(api))
        guard let asset = assets.first else { throw LeafError("Temurin has no Java \(major) for this Mac.") }

        let work = AppPaths.runtimes.appendingPathComponent(".install-\(major)-\(UUID().uuidString)", isDirectory: true)
        try FileOps.ensureDir(work)
        defer { try? FileManager.default.removeItem(at: work) }
        let archive = work.appendingPathComponent("jre.tar.gz")
        try await HTTP.download(HTTP.url(asset.binary.package.link), to: archive, expect: ExpectedHashes(sha256: asset.binary.package.checksum), progress: progress)
        let result = try await Tool.run("/usr/bin/tar", ["-xzf", archive.path, "-C", work.path])
        guard result.ok else { throw LeafError("Couldn't unpack Java \(major): \(result.err)") }
        guard let bundle = FileOps.children(work).first(where: { FileOps.exists($0.appendingPathComponent("Contents/Home/bin/java")) }) else {
            throw LeafError("The Java \(major) download wasn't laid out as expected.")
        }
        let target = AppPaths.runtimes.appendingPathComponent("temurin-\(major)", isDirectory: true)
        try FileOps.move(bundle, to: target)
        guard let runtime = await inspect(path: target.appendingPathComponent("Contents/Home/bin/java").path, managed: true) else {
            throw LeafError("Java \(major) was installed but didn't run.")
        }
        return runtime
    }
}
