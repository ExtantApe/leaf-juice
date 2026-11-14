import Foundation

/// A downloadable server jar.
public struct SoftwareBuild: Codable, Equatable, Sendable {
    public var flavor: Flavor
    public var mcVersion: String
    public var build: Int?
    public var channel: String
    public var downloadURL: String
    public var fileName: String

    /// A file name from a download API, used as a path: only its last part, a .jar, and not hidden (K158 audit).
    public static func safeJarName(_ name: String, fallback: String) -> String {
        let last = (name as NSString).lastPathComponent
        guard last == name, last.hasSuffix(".jar"), !last.hasPrefix("."), last.count <= 128 else { return fallback }
        return last
    }
    public var hashes: ExpectedHashes
    public var size: Int64?
    public var published: Date?
    public var changes: [String] = []
    public var javaMinimum: Int?
    public var recommendedFlags: [String] = []
    public var supportStatus: String?

    public var label: String { build.map { "\(mcVersion) build \($0)" } ?? mcVersion }
}

public enum SoftwareCatalog {
    // MARK: Versions

    /// Every published version, newest first.
    public static func versions(_ flavor: Flavor) async throws -> [String] {
        switch flavor {
        case .paper, .folia:
            struct Project: Decodable { let versions: [String: [String]] }
            let project = try await HTTP.decode(Project.self, HTTP.url("https://fill.papermc.io/v3/projects/\(flavor.rawValue)"))
            return sortedNewestFirst(project.versions.values.flatMap { $0 })
        case .purpur:
            struct Project: Decodable { let versions: [String] }
            let project = try await HTTP.decode(Project.self, HTTP.url("https://api.purpurmc.org/v2/purpur"))
            return sortedNewestFirst(project.versions)
        case .vanilla:
            let manifest = try await HTTP.decode(MojangManifest.self, HTTP.url(mojangManifest))
            return manifest.versions.filter { $0.type == "release" }.map(\.id)
        case .custom:
            return []
        }
    }

    public static func sortedNewestFirst(_ versions: [String]) -> [String] {
        versions.compactMap(GameVersion.init).sorted(by: >).map(\.raw)
    }

    // MARK: Builds

    /// The newest build of a version on an accepted channel.
    public static func latestBuild(_ flavor: Flavor, mc: String, channels: [String] = ["STABLE"]) async throws -> SoftwareBuild? {
        switch flavor {
        case .paper, .folia: try await fillLatest(flavor, mc: mc, channels: channels)
        case .purpur: try await purpurLatest(mc: mc)
        case .vanilla: try await vanilla(mc: mc)
        case .custom: nil
        }
    }

    // MARK: Fill (Paper, Folia)

    struct FillVersion: Decodable {
        struct Inner: Decodable {
            struct Support: Decodable { let status: String? }
            struct Java: Decodable {
                struct V: Decodable { let minimum: Int? }
                struct F: Decodable { let recommended: [String]? }
                let version: V?
                let flags: F?
            }
            let support: Support?
            let java: Java?
        }
        let version: Inner
    }

    struct FillBuild: Decodable {
        struct Commit: Decodable { let message: String? }
        struct Download: Decodable {
            struct Sums: Decodable { let sha256: String? }
            let name: String
            let checksums: Sums?
            let size: Int64?
            let url: String
        }
        let id: Int
        let time: Date?
        let channel: String
        let commits: [Commit]?
        let downloads: [String: Download]
    }

    static func fillBuild(from builds: [FillBuild], meta: FillVersion?, flavor: Flavor, mc: String, channels: [String]) -> SoftwareBuild? {
        let accepted = Set(channels.map { $0.uppercased() })
        guard let chosen = builds.filter({ accepted.contains($0.channel.uppercased()) }).max(by: { $0.id < $1.id }),
              let file = chosen.downloads["server:default"] else { return nil }
        return SoftwareBuild(
            flavor: flavor, mcVersion: mc, build: chosen.id, channel: chosen.channel, downloadURL: file.url,
            fileName: SoftwareBuild.safeJarName(file.name, fallback: "\(flavor.rawValue)-\(mc)-\(chosen.id).jar"), hashes: ExpectedHashes(sha256: file.checksums?.sha256), size: file.size,
            published: chosen.time,
            changes: (chosen.commits ?? []).compactMap { $0.message?.components(separatedBy: "\n").first },
            javaMinimum: meta?.version.java?.version?.minimum,
            recommendedFlags: meta?.version.java?.flags?.recommended ?? [],
            supportStatus: meta?.version.support?.status)
    }

    private static func fillLatest(_ flavor: Flavor, mc: String, channels: [String]) async throws -> SoftwareBuild? {
        let base = "https://fill.papermc.io/v3/projects/\(flavor.rawValue)/versions/\(mc)"
        async let meta = HTTP.decode(FillVersion.self, HTTP.url(base))
        async let builds = HTTP.decode([FillBuild].self, HTTP.url(base + "/builds"))
        return try await fillBuild(from: builds, meta: meta, flavor: flavor, mc: mc, channels: channels)
    }

    // MARK: Purpur

    private static func purpurLatest(mc: String) async throws -> SoftwareBuild? {
        struct Latest: Decodable {
            struct Commit: Decodable { let description: String? }
            let build: String
            let md5: String?
            let timestamp: Double?
            let commits: [Commit]?
        }
        let base = "https://api.purpurmc.org/v2/purpur/\(mc)"
        let info = try await HTTP.decode(Latest.self, HTTP.url(base + "/latest"))
        return SoftwareBuild(
            flavor: .purpur, mcVersion: mc, build: Int(info.build), channel: "STABLE",
            downloadURL: base + "/\(info.build)/download", fileName: "purpur-\(mc)-\(info.build).jar",
            hashes: ExpectedHashes(md5: info.md5), size: nil,
            published: info.timestamp.map { Date(timeIntervalSince1970: $0 / 1000) },
            changes: (info.commits ?? []).compactMap { $0.description?.components(separatedBy: "\n").first },
            javaMinimum: GameVersion(mc).map(JavaRequirement.estimated))
    }

    // MARK: Vanilla

    private static let mojangManifest = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"

    struct MojangManifest: Decodable {
        struct Version: Decodable { let id: String; let type: String; let url: String }
        let versions: [Version]
    }

    private static func vanilla(mc: String) async throws -> SoftwareBuild? {
        struct Package: Decodable {
            struct Downloads: Decodable {
                struct File: Decodable { let sha1: String; let size: Int64; let url: String }
                let server: File?
            }
            struct Java: Decodable { let majorVersion: Int? }
            let downloads: Downloads
            let javaVersion: Java?
        }
        let manifest = try await HTTP.decode(MojangManifest.self, HTTP.url(mojangManifest))
        guard let entry = manifest.versions.first(where: { $0.id == mc }) else { return nil }
        let package = try await HTTP.decode(Package.self, HTTP.url(entry.url))
        guard let server = package.downloads.server else { return nil }
        return SoftwareBuild(
            flavor: .vanilla, mcVersion: mc, build: nil, channel: "STABLE", downloadURL: server.url,
            fileName: "minecraft-server-\(mc).jar", hashes: ExpectedHashes(sha1: server.sha1), size: server.size,
            javaMinimum: package.javaVersion?.majorVersion)
    }

    // MARK: Decisions

    /// Minecraft 26.1 reorganized how worlds are stored on disk, so crossing it deserves its own warning.
    public static func crossesWorldLayoutChange(from: String, to: String) -> Bool {
        guard let a = GameVersion(from), let b = GameVersion(to) else { return false }
        let boundary = GameVersion("26.1")!
        return a < boundary && b >= boundary
    }

    public enum Move: Equatable, Sendable {
        case same, newBuild, upgrade, downgrade, switchSoftware
        public var needsBackup: Bool { self == .upgrade || self == .switchSoftware }
    }

    /// How risky a software change is. New builds are routine; versions change the world format.
    public static func classify(current: SoftwareState, flavor: Flavor, mc: String, build: Int?) -> Move {
        if current.mcVersion.isEmpty { return .newBuild }
        guard let from = GameVersion(current.mcVersion), let to = GameVersion(mc) else { return .upgrade }
        if to < from { return .downgrade }
        if to > from { return .upgrade }
        if flavor != current.flavor { return .switchSoftware }
        if let build, let existing = current.build, build == existing { return .same }
        return .newBuild
    }
}

// MARK: - Detecting an existing server

public struct DetectedServer: Sendable {
    public var software = SoftwareState()
    public var launch: LaunchConfig?
    public var candidates: [String] = []
    public var notes: [String] = []
}

public enum ServerFolders {
    /// Subfolders that look like servers. Only looks at names in each folder: nothing is opened or changed.
    public static func find(in parent: URL) -> [URL] {
        FileOps.children(parent).filter { folder in
            guard FileOps.isDirectory(folder), !folder.lastPathComponent.hasPrefix("."),
                  folder.lastPathComponent != AppPaths.ownFolderName else { return false }
            let names = FileOps.children(folder).map { $0.lastPathComponent.lowercased() }
            return names.contains("server.properties") || names.contains(".leafjuice") || names.contains { $0.hasSuffix(".jar") }
        }.sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
    }

    /// A folder name for a new server, or nil if there's nothing usable in the name.
    public static func folderName(for serverName: String) -> String? {
        let cleaned = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !cleaned.isEmpty, !cleaned.hasPrefix(".") else { return nil }
        return cleaned
    }
}

public enum ServerDetector {
    /// The build in "This server is running Paper version 26.3-249-main@1a995d6 (…)". Paper and its forks log this.
    public static func buildFromRunningLine(_ message: String) -> (mc: String, build: Int)? {
        guard let r = message.range(of: #"^This server is running \w+ version (\d+(?:\.\d+){1,2})-(\d+)-"#, options: .regularExpression) else { return nil }
        let parts = message[r].split(separator: " ").last?.split(separator: "-") ?? []
        guard parts.count >= 2, GameVersion(String(parts[0])) != nil, let build = Int(parts[1]) else { return nil }
        return (String(parts[0]), build)
    }

    /// The version in "Starting minecraft server version 26.3", which Paper, Purpur and Vanilla all log as they start.
    public static func versionFromStartLine(_ message: String) -> String? {
        let prefix = "Starting minecraft server version "
        guard message.hasPrefix(prefix) else { return nil }
        let version = String(message.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        guard GameVersion(version) != nil, version.count <= 20 else { return nil }
        return version
    }

    private static let jarName = regex(#"^(paper|purpur|folia)-(.+?)-(\d+)\.jar$"#, .caseInsensitive)
    private static let legacyHistory = regex(#"^git-Paper-(\d+) \(MC: ([^)]+)\)"#)
    private static let historyVersion = regex(#"^(.+?)-(\d+)-[^ ]* \(MC: ([^)]+)\)"#)

    /// Inspects a folder without changing anything in it.
    public static func detect(_ root: URL) async -> DetectedServer {
        var out = DetectedServer()
        let jars = FileOps.children(root).filter { $0.pathExtension.lowercased() == "jar" }
            .sorted { (FileOps.modified($0) ?? .distantPast) > (FileOps.modified($1) ?? .distantPast) }
        out.candidates = jars.map(\.lastPathComponent)

        let script = readStartScript(root)
        // A jar named by the start script wins: that's what actually runs today.
        let chosen = script?.jar.flatMap { name in jars.first { $0.lastPathComponent == name } }
            ?? jars.first { jarName.firstMatch(in: $0.lastPathComponent) != nil }
            ?? jars.first { $0.lastPathComponent.lowercased().contains("server") }
            ?? jars.first
        if let chosen {
            out.software.jarName = chosen.lastPathComponent
            out.software.flavor = .custom
            if let m = jarName.firstMatch(in: chosen.lastPathComponent) {
                let name = chosen.lastPathComponent as NSString
                out.software.flavor = Flavor(rawValue: name.substring(with: m.range(at: 1)).lowercased()) ?? .custom
                out.software.mcVersion = name.substring(with: m.range(at: 2))
                out.software.build = Int(name.substring(with: m.range(at: 3)))
            }
            if let jarInfo = await readJarVersion(chosen) {
                if out.software.mcVersion.isEmpty { out.software.mcVersion = jarInfo.id }
                if out.software.flavor == .custom, jarInfo.isPaper { out.software.flavor = .paper }
                if out.software.flavor == .custom, jarInfo.isVanilla { out.software.flavor = .vanilla }
                out.software.requiredJava = jarInfo.java
            }
        } else {
            out.notes.append("No server jar found. You can download one on the Software page.")
        }

        // Paper's own record of what last ran.
        if let data = try? Data(contentsOf: root.appendingPathComponent("version_history.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let current = object["currentVersion"] as? String,
           let m = historyVersion.firstMatch(in: current) {
            let text = current as NSString
            let mc = text.substring(with: m.range(at: 3))
            if out.software.mcVersion.isEmpty { out.software.mcVersion = mc }
            if out.software.mcVersion == mc, out.software.build == nil { out.software.build = Int(text.substring(with: m.range(at: 2))) }
            if out.software.flavor == .custom { out.software.flavor = .paper }
        } else if let data = try? Data(contentsOf: root.appendingPathComponent("version_history.json")),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = object["currentVersion"] as? String,
                  let m = legacyHistory.firstMatch(in: current) {
            // Older servers: git-Paper-794 (MC: 1.16.5)
            let text = current as NSString
            let mc = text.substring(with: m.range(at: 2))
            if out.software.mcVersion.isEmpty { out.software.mcVersion = mc }
            if out.software.mcVersion == mc, out.software.build == nil { out.software.build = Int(text.substring(with: m.range(at: 1))) }
            if out.software.flavor == .custom { out.software.flavor = .paper }
        }

        if let script {
            out.launch = script.launch
            out.notes.append("Imported memory and flags from \(script.name).")
        }
        if out.software.flavor == .custom, chosen != nil {
            out.notes.append("Couldn't identify \(out.software.jarName). It's treated as a custom jar until you pick the software.")
        }
        return out
    }

    /// `paper-1.21.4-232.jar` → `1.21.4`. Only meaningful for jars named the standard way.
    public static func versionInJarName(_ name: String) -> String? {
        guard let m = jarName.firstMatch(in: name) else { return nil }
        return (name as NSString).substring(with: m.range(at: 2))
    }

    struct JarVersion { let id: String; let java: Int?; let isPaper: Bool; let isVanilla: Bool }

    private static func readJarVersion(_ jar: URL) async -> JarVersion? {
        guard let result = try? await Tool.run("/usr/bin/unzip", ["-p", jar.path, "version.json"]), result.ok,
              let object = try? JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any],
              let id = object["id"] as? String ?? object["name"] as? String else { return nil }
        let listing = (try? await Tool.run("/usr/bin/unzip", ["-l", jar.path]))?.out ?? ""
        let isPaper = listing.contains("io/papermc/paperclip") || listing.contains("META-INF/versions.list")
        return JarVersion(id: id, java: object["java_version"] as? Int, isPaper: isPaper, isVanilla: !isPaper && listing.contains("net/minecraft/bundler"))
    }

    struct StartScript { let name: String; let jar: String?; let launch: LaunchConfig }

    private static func readStartScript(_ root: URL) -> StartScript? {
        for name in ["start.sh", "run.sh", "start.command", "run.command", "launch.sh", "start"] {
            guard let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8),
                  let parsed = parseStartScript(text, name: name) else { continue }
            return parsed
        }
        return nil
    }

    static func parseStartScript(_ text: String, name: String) -> StartScript? {
        let joined = text.replacingOccurrences(of: "\\\n", with: " ")
        guard let line = joined.split(whereSeparator: \.isNewline).first(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !t.hasPrefix("#") && t.contains("java") && t.contains("-jar")
        }) else { return nil }
        let args = ArgumentString.split(String(line))
        guard let jarFlag = args.firstIndex(of: "-jar"), jarFlag + 1 < args.count,
              let javaIndex = args.firstIndex(where: { $0 == "java" || $0.hasSuffix("/java") }), javaIndex < jarFlag else { return nil }
        var launch = LaunchConfig()
        if args[javaIndex].hasPrefix("/") { launch.javaPath = args[javaIndex] }
        var extra: [String] = []
        for arg in args[(javaIndex + 1)..<jarFlag] {
            if arg.hasPrefix("-Xms") { launch.minMemoryMB = parseMemory(String(arg.dropFirst(4))) ?? launch.minMemoryMB }
            else if arg.hasPrefix("-Xmx") { launch.maxMemoryMB = parseMemory(String(arg.dropFirst(4))) ?? launch.maxMemoryMB }
            else { extra.append(arg) }
        }
        launch.preset = extra.isEmpty ? .recommended : .custom
        launch.extraJVMArgs = extra.map(ArgumentString.quote).joined(separator: " ")
        let rest = args[(jarFlag + 2)...].filter { !["nogui", "--nogui"].contains($0) && !$0.hasPrefix("$") && !["&&", "|", ";"].contains($0) }
        launch.serverArgs = rest.map(ArgumentString.quote).joined(separator: " ")
        return StartScript(name: name, jar: args[jarFlag + 1], launch: launch)
    }

    static func parseMemory(_ text: String) -> Int? {
        let lower = text.lowercased()
        guard let number = Int(lower.trimmingCharacters(in: .letters)) else { return nil }
        if lower.hasSuffix("g") { return number * 1024 }
        if lower.hasSuffix("m") { return number }
        if lower.hasSuffix("k") { return number / 1024 }
        return number / (1024 * 1024)
    }
}
