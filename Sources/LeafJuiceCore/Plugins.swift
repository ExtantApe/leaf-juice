import Foundation

// MARK: - What a jar says about itself

public struct PluginDescriptor: Codable, Equatable, Sendable {
    public var name: String
    public var version: String = ""
    public var main: String?
    public var apiVersion: String?
    public var description: String?
    public var website: String?
    public var authors: [String] = []
    public var depend: [String] = []
    public var softDepend: [String] = []
    public var isPaperPlugin = false
}

public enum PluginYAML {
    /// Reads the flat fields of `plugin.yml`. Nested sections (`commands:`, `permissions:`) are skipped.
    public static func parse(_ text: String, paper: Bool = false) -> PluginDescriptor? {
        var scalars: [String: String] = [:], lists: [String: [String]] = [:]
        var currentKey: String?
        for rawLine in text.components(separatedBy: .newlines) {
            guard !rawLine.trimmingCharacters(in: .whitespaces).isEmpty,
                  !rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("#") else { continue }
            if rawLine.first == " " || rawLine.first == "\t" || rawLine.first == "-" {
                let t = rawLine.trimmingCharacters(in: .whitespaces)
                if let key = currentKey, t.hasPrefix("- ") { lists[key, default: []].append(clean(String(t.dropFirst(2)))) }
                continue
            }
            guard let colon = rawLine.firstIndex(of: ":") else { continue }
            let key = rawLine[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = rawLine[rawLine.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            currentKey = key
            if value.isEmpty { continue }
            if value.hasPrefix("[") {
                lists[key] = value.dropFirst().prefix { $0 != "]" }.split(separator: ",").map { clean(String($0)) }
            } else {
                scalars[key] = clean(value)
            }
        }
        guard let name = scalars["name"], !name.isEmpty else { return nil }
        var d = PluginDescriptor(name: name)
        d.version = scalars["version"] ?? ""
        d.main = scalars["main"]
        d.apiVersion = scalars["api-version"]
        d.description = scalars["description"]
        d.website = scalars["website"]
        d.authors = (scalars["author"].map { [$0] } ?? []) + (lists["authors"] ?? [])
        d.depend = lists["depend"] ?? []
        d.softDepend = (lists["softdepend"] ?? []) + (lists["loadbefore"] ?? [])
        d.isPaperPlugin = paper
        return d
    }

    private static func clean(_ text: String) -> String {
        let out = text.trimmingCharacters(in: .whitespaces)
        if let quote = out.first, quote == "\"" || quote == "'" {
            let body = out.dropFirst()
            return String(body.prefix { $0 != quote })
        }
        if let hash = out.range(of: " #") { return String(out[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return out
    }

    /// Reads the descriptor inside a jar. Paper's own format wins when both exist.
    public static func read(jar: URL) async -> PluginDescriptor? {
        for (file, paper) in [("paper-plugin.yml", true), ("plugin.yml", false)] {
            if let r = try? await Tool.run("/usr/bin/unzip", ["-p", jar.path, file], maxOutput: 1 << 20, timeout: 30), r.ok,
               let d = parse(r.out, paper: paper) { return d }
        }
        return nil
    }
}

public struct InstalledPlugin: Identifiable, Equatable, Sendable {
    public var id: String { fileName }
    public let fileName: String
    public let enabled: Bool
    public let descriptor: PluginDescriptor?
    public let digests: Hashing.Digests?
    public let size: Int64
    public var name: String { descriptor?.name ?? (fileName as NSString).deletingPathExtension }
    public var key: String { name.lowercased() }
    public var version: String { descriptor?.version ?? "" }
}

public enum PluginScanner {
    public static func scan(_ paths: ServerPaths) async -> [InstalledPlugin] {
        let files = FileOps.children(paths.plugins).filter {
            let n = $0.lastPathComponent.lowercased()
            return n.hasSuffix(".jar") || n.hasSuffix(".jar.disabled")
        }
        let plugins = await withTaskGroup(of: InstalledPlugin.self, returning: [InstalledPlugin].self) { group in
            var out: [InstalledPlugin] = []
            // A few at a time: big servers have dozens of plugins, and each one starts tools and reads a whole jar.
            for (index, file) in files.enumerated() {
                if index >= 8, let done = await group.next() { out.append(done) }
                group.addTask {
                    let enabled = file.pathExtension.lowercased() == "jar"
                    return InstalledPlugin(
                        fileName: file.lastPathComponent, enabled: enabled,
                        descriptor: await PluginYAML.read(jar: file),
                        digests: try? Hashing.digests(of: file), size: FileOps.size(file))
                }
            }
            for await p in group { out.append(p) }
            return out
        }
        return plugins.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Problems visible without starting the server.
    public static func staticProblems(_ plugins: [InstalledPlugin], mc: GameVersion?) -> [String: String] {
        var out: [String: String] = [:]
        let enabled = plugins.filter(\.enabled)
        let names = Set(enabled.map(\.key))
        for p in enabled {
            if p.descriptor == nil { out[p.fileName] = "No plugin.yml found. This may be a library or a mod, not a plugin." }
            if let missing = p.descriptor?.depend.first(where: { !names.contains($0.lowercased()) }) {
                out[p.fileName] = "Needs \(missing), which isn't installed."
            }
            if let mc, let raw = p.descriptor?.apiVersion, let api = GameVersion(raw), api > mc {
                out[p.fileName] = "Built for Minecraft \(raw) or newer. This server runs \(mc)."
            }
            if enabled.filter({ $0.key == p.key }).count > 1 { out[p.fileName] = "Another jar also claims to be \(p.name)." }
        }
        return out
    }
}

// MARK: - Sources

public enum PluginSource: Codable, Equatable, Sendable {
    case none
    case modrinth(project: String, allowBeta: Bool)
    case hangar(project: String, channel: String)
    case spigot(resourceID: Int)
    case github(repo: String, assetPattern: String, prereleases: Bool)
    case jenkins(jobURL: String, artifactPattern: String)
    case web(url: String, linkPattern: String)

    public var kind: SourceKind {
        switch self {
        case .none: .none
        case .modrinth: .modrinth
        case .hangar: .hangar
        case .spigot: .spigot
        case .github: .github
        case .jenkins: .jenkins
        case .web: .web
        }
    }

    public var isSet: Bool { self != .none }

    public var summary: String {
        switch self {
        case .none: "Not set"
        case let .modrinth(project, _): "Modrinth: \(project)"
        case let .hangar(project, _): "Hangar: \(project)"
        case let .spigot(id): "SpigotMC: #\(id)"
        case let .github(repo, _, _): "GitHub: \(repo)"
        case let .jenkins(url, _): "Jenkins: \(URL(string: url)?.host ?? url)"
        case let .web(url, _): "Web: \(URL(string: url)?.host ?? url)"
        }
    }

    public var pageURL: URL? {
        switch self {
        case .none: nil
        case let .modrinth(project, _): URL(string: "https://modrinth.com/plugin/\(project)")
        case let .hangar(project, _): URL(string: "https://hangar.papermc.io/\(project)")
        case let .spigot(id): URL(string: "https://www.spigotmc.org/resources/\(id)/")
        case let .github(repo, _, _): URL(string: "https://github.com/\(repo)/releases")
        case let .jenkins(url, _): URL(string: url)
        case let .web(url, _): URL(string: url)
        }
    }
}

public enum SourceKind: String, CaseIterable, Identifiable, Sendable {
    case none, modrinth, hangar, spigot, github, jenkins, web
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: "None"
        case .modrinth: "Modrinth"
        case .hangar: "Hangar"
        case .spigot: "SpigotMC"
        case .github: "GitHub Releases"
        case .jenkins: "Jenkins"
        case .web: "Other website"
        }
    }
    public var evidence: String {
        switch self {
        case .none: "Leaf Juice won't look for updates."
        case .modrinth, .hangar: "Each release lists its Minecraft versions, so compatibility is exact."
        case .spigot: "Authors tag the whole resource rather than each release, so this is a good guess at best. Premium plugins can only notify."
        case .github: "Only knows the Minecraft version if releases are tagged (mc1.21.4). The jar is still checked after download."
        case .jenkins: "Watches the last successful build. The jar's plugin name and api-version are checked after download."
        case .web: "Watches a direct link for changes, or finds a link on a page. The jar is checked after download."
        }
    }
}

public enum SourceParser {
    /// Recognises a pasted address.
    public static func parse(_ text: String) -> PluginSource? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)"), let host = url.host?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        if host.hasSuffix("modrinth.com"), parts.count >= 2, ["plugin", "mod", "project"].contains(parts[0]) {
            return .modrinth(project: parts[1], allowBeta: false)
        }
        if host == "hangar.papermc.io", parts.count >= 2 {
            return .hangar(project: "\(parts[0])/\(parts[1])", channel: "Release")
        }
        if host.hasSuffix("spigotmc.org"), parts.count >= 2, parts[0] == "resources" {
            if let id = Int(parts[1].split(separator: ".").last ?? "") { return .spigot(resourceID: id) }
        }
        if host == "github.com", parts.count >= 2 {
            return .github(repo: "\(parts[0])/\(parts[1])", assetPattern: "", prereleases: false)
        }
        if let jobIndex = parts.firstIndex(of: "job"), jobIndex + 1 < parts.count {
            // Keep every /job/x pair and drop what follows (lastSuccessfulBuild, artifact paths).
            var path: [String] = [], i = jobIndex
            while i + 1 < parts.count, parts[i] == "job" { path += ["job", parts[i + 1]]; i += 2 }
            let prefix = parts[..<jobIndex].map { "/\($0)" }.joined()
            var base = "\(url.scheme ?? "https")://\(host)"
            if let port = url.port { base += ":\(port)" }
            return .jenkins(jobURL: base + prefix + "/" + path.joined(separator: "/") + "/", artifactPattern: "")
        }
        guard trimmed.contains("://") || trimmed.contains(".") else { return nil }
        return .web(url: url.absoluteString, linkPattern: "")
    }
}

public enum JarPicker {
    private static let excluded = regex(
        #"(sources|javadoc|fabric|forge|neoforge|quilt|sponge|velocity|bungee|waterfall|nukkit|legacy|-api[-.]|-dev\.jar|mod\.jar)"#,
        .caseInsensitive)
    private static let preferred = regex(#"(paper|bukkit|spigot|purpur)"#, .caseInsensitive)

    /// Chooses the jar for a Paper server from a list, or follows the user's own pattern.
    public static func pick(_ names: [String], pattern: String) -> String? {
        let jars = names.filter { $0.lowercased().hasSuffix(".jar") }
        if !pattern.isEmpty {
            guard let custom = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
            return jars.first { custom.firstMatch(in: $0) != nil }
        }
        let candidates = jars.filter { excluded.firstMatch(in: $0) == nil }
        return candidates.first { preferred.firstMatch(in: $0) != nil } ?? candidates.first
    }
}

// MARK: - Compatibility

public struct Compatibility: Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Sendable {
        /// The source explicitly lists this Minecraft version for this release.
        case compatible
        /// Reasonable evidence, but not a per-release statement.
        case likely
        /// Nothing to go on yet.
        case unknown
        /// Evidence says this won't work.
        case incompatible
    }
    public var verdict: Verdict
    public var reason: String
    public init(_ verdict: Verdict, _ reason: String) { self.verdict = verdict; self.reason = reason }
    /// Only evidence-backed candidates may install without asking.
    public var allowsAutoInstall: Bool { verdict == .compatible || verdict == .likely }
}

public struct UpdateCandidate: Codable, Equatable, Sendable {
    public var version: String
    /// Identifies this release at the source, so it isn't offered twice.
    public var upstreamID: String
    /// nil when the source can't be downloaded from (premium plugins).
    public var downloadURL: String?
    public var fileName: String?
    public var hashes = ExpectedHashes()
    public var pageURL: String?
    public var published: Date?
    public var compatibility: Compatibility
}

public struct SourceCheck: Equatable, Sendable {
    /// Newest release that isn't known to be incompatible.
    public var candidate: UpdateCandidate?
    /// Set when the newest release was passed over because of its tags.
    public var skippedNote: String?
}

public struct PluginRecord: Codable, Equatable, Sendable {
    public enum Policy: String, Codable, CaseIterable, Identifiable, Sendable {
        case notify, auto, pinned
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .notify: "Notify me"
            case .auto: "Install automatically"
            case .pinned: "Keep this version"
            }
        }
    }
    public var source: PluginSource = .none
    public var policy: Policy = .notify
    public var installedUpstreamID: String?
    public var available: UpdateCandidate?
    public var lastCheck: Date?
    public var lastError: String?
    public var note: String?
    public init() {}
}

// MARK: - Checking sources

public enum PluginSources {
    public static func check(_ source: PluginSource, mc: GameVersion?, flavor: Flavor) async throws -> SourceCheck {
        switch source {
        case .none: return SourceCheck()
        case let .modrinth(project, beta): return try await modrinth(project, beta, mc, flavor)
        case let .hangar(project, channel): return try await hangar(project, channel, mc, flavor)
        case let .spigot(id): return try await spigot(id, mc)
        case let .github(repo, pattern, pre): return try await github(repo, pattern, pre, mc)
        case let .jenkins(job, pattern): return try await jenkins(job, pattern, mc)
        case let .web(url, pattern): return try await web(url, pattern, mc)
        }
    }

    // MARK: Modrinth

    struct ModrinthVersion: Decodable {
        struct File: Decodable {
            struct Hashes: Decodable { let sha1: String?; let sha512: String? }
            let hashes: Hashes
            let url: String
            let filename: String
            let primary: Bool
        }
        let id: String
        let project_id: String
        let version_number: String
        let version_type: String
        let game_versions: [String]
        let loaders: [String]
        let date_published: Date?
        let files: [File]
    }

    static func modrinthChoose(_ versions: [ModrinthVersion], project: String, allowBeta: Bool, mc: GameVersion?, flavor: Flavor) -> SourceCheck {
        let loaders = Set(flavor.modrinthLoaders)
        let usable = versions
            .filter { !Set($0.loaders).isDisjoint(with: loaders) }
            .filter { $0.version_type == "release" || (allowBeta && $0.version_type == "beta") }
            .sorted { ($0.date_published ?? .distantPast) > ($1.date_published ?? .distantPast) }
        guard let newest = usable.first else {
            return SourceCheck(skippedNote: "No \(flavor.title) release on Modrinth.")
        }
        func candidate(_ v: ModrinthVersion, _ c: Compatibility) -> UpdateCandidate? {
            guard let file = v.files.first(where: \.primary) ?? v.files.first else { return nil }
            return UpdateCandidate(
                version: v.version_number, upstreamID: v.id, downloadURL: file.url, fileName: file.filename,
                hashes: ExpectedHashes(sha1: file.hashes.sha1, sha512: file.hashes.sha512),
                pageURL: "https://modrinth.com/plugin/\(project)/version/\(v.id)", published: v.date_published, compatibility: c)
        }
        guard let mc else {
            return SourceCheck(candidate: candidate(newest, Compatibility(.unknown, "This server's Minecraft version isn't known.")))
        }
        let match = usable.first { $0.game_versions.compactMap(GameVersion.init).contains(mc) }
        if let match {
            return SourceCheck(candidate: candidate(match, Compatibility(.compatible, "Modrinth lists this release for \(mc)."))
                , skippedNote: match.id == newest.id ? nil : "Newest release \(newest.version_number) doesn't list \(mc).")
        }
        return SourceCheck(skippedNote: "No release lists \(mc). Newest is \(newest.version_number), for \(newest.game_versions.suffix(2).joined(separator: ", ")).")
    }

    private static func modrinth(_ project: String, _ beta: Bool, _ mc: GameVersion?, _ flavor: Flavor) async throws -> SourceCheck {
        let encoded = project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? project
        let url = try HTTP.url("https://api.modrinth.com/v2/project/\(encoded)/version?include_changelog=false")
        let versions = try await HTTP.decode([ModrinthVersion].self, url)
        return modrinthChoose(versions, project: project, allowBeta: beta, mc: mc, flavor: flavor)
    }

    // MARK: Hangar

    struct HangarVersions: Decodable {
        struct Version: Decodable {
            struct Channel: Decodable { let name: String }
            struct Download: Decodable {
                struct FileInfo: Decodable { let name: String?; let sha256Hash: String? }
                let fileInfo: FileInfo?
                let externalUrl: String?
                let downloadUrl: String?
            }
            let name: String
            let createdAt: Date?
            let channel: Channel
            let downloads: [String: Download]
            let platformDependencies: [String: [String]]
        }
        let result: [Version]
    }

    static func hangarChoose(_ versions: [HangarVersions.Version], project: String, mc: GameVersion?, platform: String) -> SourceCheck {
        let usable = versions.filter { $0.downloads[platform] != nil }
        guard let newest = usable.first else { return SourceCheck(skippedNote: "No release for this platform on Hangar.") }
        func candidate(_ v: HangarVersions.Version, _ c: Compatibility) -> UpdateCandidate? {
            guard let d = v.downloads[platform] else { return nil }
            // External-only releases can't be fetched and verified directly.
            return UpdateCandidate(
                version: v.name, upstreamID: v.name, downloadURL: d.downloadUrl, fileName: d.fileInfo?.name,
                hashes: ExpectedHashes(sha256: d.fileInfo?.sha256Hash),
                pageURL: d.externalUrl ?? "https://hangar.papermc.io/\(project)/versions/\(v.name)",
                published: v.createdAt, compatibility: c)
        }
        guard let mc else { return SourceCheck(candidate: candidate(newest, Compatibility(.unknown, "This server's Minecraft version isn't known."))) }
        func supports(_ v: HangarVersions.Version) -> Bool {
            (v.platformDependencies[platform] ?? []).compactMap(GameVersion.init).contains(mc)
        }
        if let match = usable.first(where: supports) {
            return SourceCheck(candidate: candidate(match, Compatibility(.compatible, "Hangar lists this release for \(mc).")),
                               skippedNote: match.name == newest.name ? nil : "Newest release \(newest.name) doesn't list \(mc).")
        }
        return SourceCheck(skippedNote: "No recent release lists \(mc). Newest is \(newest.name).")
    }

    private static func hangar(_ project: String, _ channel: String, _ mc: GameVersion?, _ flavor: Flavor) async throws -> SourceCheck {
        let slug = project.split(separator: "/").last.map(String.init) ?? project
        let platform = flavor.hangarPlatform
        var query = "limit=25&platform=\(platform)"
        if !channel.isEmpty { query += "&channel=\(channel.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? channel)" }
        let url = try HTTP.url("https://hangar.papermc.io/api/v1/projects/\(slug)/versions?\(query)")
        let versions = try await HTTP.decode(HangarVersions.self, url)
        return hangarChoose(versions.result, project: project, mc: mc, platform: platform)
    }

    // MARK: SpigotMC via Spiget

    struct SpigetResource: Decodable {
        let name: String?
        let premium: Bool?
        let external: Bool?
        let testedVersions: [String]?
    }
    struct SpigetVersion: Decodable { let id: Int; let name: String?; let releaseDate: Double? }

    /// Spigot tags describe the whole resource and are maintained by hand.
    public static func spigotCompatibility(tested: [String], mc: GameVersion?) -> Compatibility {
        let tags = tested.compactMap(GameVersion.init)
        guard let mc else { return Compatibility(.unknown, "This server's Minecraft version isn't known.") }
        guard !tags.isEmpty else { return Compatibility(.unknown, "The author lists no tested versions.") }
        if mc.isCovered(by: tags) || tags.contains(where: { $0.line == mc.line }) {
            return Compatibility(.likely, "The author lists \(mc.line) as tested on this resource.")
        }
        if let oldest = tags.min(), mc < oldest {
            return Compatibility(.incompatible, "The oldest tested version is \(oldest). This server runs \(mc).")
        }
        return Compatibility(.unknown, "Tested up to \(tags.max()!.raw), not \(mc). It may still work.")
    }

    private static func spigot(_ id: Int, _ mc: GameVersion?) async throws -> SourceCheck {
        async let resourceCall = HTTP.decode(SpigetResource.self, HTTP.url("https://api.spiget.org/v2/resources/\(id)"))
        async let latestCall = HTTP.decode(SpigetVersion.self, HTTP.url("https://api.spiget.org/v2/resources/\(id)/versions/latest"))
        let (resource, latest) = try await (resourceCall, latestCall)
        let compat = spigotCompatibility(tested: resource.testedVersions ?? [], mc: mc)
        let page = "https://www.spigotmc.org/resources/\(id)/"
        let notifyOnly = resource.premium == true || resource.external == true
        let candidate = UpdateCandidate(
            version: latest.name ?? "#\(latest.id)", upstreamID: String(latest.id),
            downloadURL: notifyOnly ? nil : "https://api.spiget.org/v2/resources/\(id)/download",
            fileName: nil, pageURL: page, published: latest.releaseDate.map { Date(timeIntervalSince1970: $0) },
            compatibility: compat)
        if compat.verdict == .incompatible { return SourceCheck(skippedNote: compat.reason) }
        return SourceCheck(candidate: candidate, skippedNote: notifyOnly ? "Premium or externally hosted: download it from SpigotMC yourself." : nil)
    }

    // MARK: GitHub

    struct GitHubRelease: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String; let digest: String? }
        let tag_name: String
        let name: String?
        let draft: Bool
        let prerelease: Bool
        let html_url: String?
        let published_at: Date?
        let assets: [Asset]
    }

    static func githubChoose(_ releases: [GitHubRelease], pattern: String, prereleases: Bool, mc: GameVersion?) -> SourceCheck {
        var skipped: String?
        for release in releases where !release.draft && (prereleases || !release.prerelease) {
            guard let assetName = JarPicker.pick(release.assets.map(\.name), pattern: pattern),
                  let asset = release.assets.first(where: { $0.name == assetName }) else { continue }
            let tags = GameVersion.mentioned(in: "\(release.tag_name) \(release.name ?? "") \(asset.name)")
            var compat = Compatibility(.unknown, "This release doesn't state a Minecraft version. The jar is checked after download.")
            if let mc, !tags.isEmpty {
                if mc.isCovered(by: tags) {
                    compat = Compatibility(.compatible, "This release is tagged for \(mc).")
                } else {
                    if skipped == nil { skipped = "\(release.tag_name) is tagged for \(tags.map(\.raw).joined(separator: ", ")), not \(mc)." }
                    continue
                }
            }
            var hashes = ExpectedHashes()
            if let digest = asset.digest, digest.hasPrefix("sha256:") { hashes.sha256 = String(digest.dropFirst(7)) }
            return SourceCheck(candidate: UpdateCandidate(
                version: release.tag_name, upstreamID: release.tag_name, downloadURL: asset.browser_download_url,
                fileName: asset.name, hashes: hashes, pageURL: release.html_url, published: release.published_at,
                compatibility: compat), skippedNote: skipped)
        }
        return SourceCheck(skippedNote: skipped ?? "No release has a matching jar. Try setting an asset pattern.")
    }

    private static func github(_ repo: String, _ pattern: String, _ prereleases: Bool, _ mc: GameVersion?) async throws -> SourceCheck {
        let releases = try await HTTP.decode([GitHubRelease].self, HTTP.url("https://api.github.com/repos/\(repo)/releases?per_page=20"))
        return githubChoose(releases, pattern: pattern, prereleases: prereleases, mc: mc)
    }

    // MARK: Jenkins

    struct JenkinsBuild: Decodable {
        struct Artifact: Decodable { let fileName: String; let relativePath: String }
        let number: Int
        let url: String?
        let timestamp: Double?
        let artifacts: [Artifact]
    }

    static func jenkinsChoose(_ build: JenkinsBuild, jobURL: String, pattern: String, mc: GameVersion?) -> SourceCheck {
        guard let name = JarPicker.pick(build.artifacts.map(\.fileName), pattern: pattern),
              let artifact = build.artifacts.first(where: { $0.fileName == name }) else {
            return SourceCheck(skippedNote: "Build #\(build.number) has no matching jar. Set an artifact pattern.")
        }
        let job = jobURL.hasSuffix("/") ? jobURL : jobURL + "/"
        let tags = GameVersion.mentioned(in: artifact.fileName)
        var compat = Compatibility(.unknown, "Jenkins doesn't state a Minecraft version. The jar is checked after download.")
        if let mc, !tags.isEmpty {
            if mc.isCovered(by: tags) {
                compat = Compatibility(.compatible, "The artifact is tagged for \(mc).")
            } else {
                return SourceCheck(skippedNote: "Build #\(build.number) is tagged for \(tags.map(\.raw).joined(separator: ", ")), not \(mc).")
            }
        }
        return SourceCheck(candidate: UpdateCandidate(
            version: "\((artifact.fileName as NSString).deletingPathExtension) (#\(build.number))",
            upstreamID: "build-\(build.number)", downloadURL: "\(job)\(build.number)/artifact/\(artifact.relativePath)",
            fileName: artifact.fileName, pageURL: "\(job)\(build.number)/",
            published: build.timestamp.map { Date(timeIntervalSince1970: $0 / 1000) }, compatibility: compat))
    }

    private static func jenkins(_ job: String, _ pattern: String, _ mc: GameVersion?) async throws -> SourceCheck {
        let base = job.hasSuffix("/") ? job : job + "/"
        let url = try HTTP.url(base + "lastSuccessfulBuild/api/json?tree=number,url,timestamp,artifacts%5BfileName,relativePath%5D")
        return jenkinsChoose(try await HTTP.decode(JenkinsBuild.self, url), jobURL: base, pattern: pattern, mc: mc)
    }

    // MARK: Other sites

    private static func web(_ page: String, _ pattern: String, _ mc: GameVersion?) async throws -> SourceCheck {
        var target = try HTTP.url(page)
        if !pattern.isEmpty {
            let html = String(decoding: try await HTTP.data(target), as: UTF8.self)
            guard let link = WebLinkFinder.find(in: html, pattern: pattern, base: target) else {
                return SourceCheck(skippedNote: "No link on that page matches the pattern.")
            }
            target = link
        }
        let head = try await HTTP.head(target)
        let id = head.value(forHTTPHeaderField: "ETag") ?? head.value(forHTTPHeaderField: "Last-Modified")
            ?? head.value(forHTTPHeaderField: "Content-Length").map { "size-\($0)" } ?? target.absoluteString
        let name = head.suggestedFilename ?? target.lastPathComponent
        let tags = GameVersion.mentioned(in: name)
        var compat = Compatibility(.unknown, "This site doesn't state a Minecraft version. The jar is checked after download.")
        if let mc, !tags.isEmpty {
            if mc.isCovered(by: tags) { compat = Compatibility(.compatible, "The file is tagged for \(mc).") }
            else { return SourceCheck(skippedNote: "The file is tagged for \(tags.map(\.raw).joined(separator: ", ")), not \(mc).") }
        }
        return SourceCheck(candidate: UpdateCandidate(
            version: (name as NSString).deletingPathExtension, upstreamID: "\(target.absoluteString)|\(id)",
            downloadURL: target.absoluteString, fileName: name.lowercased().hasSuffix(".jar") ? name : nil,
            pageURL: page, compatibility: compat))
    }
}

public enum WebLinkFinder {
    private static let href = regex(#"href\s*=\s*["']([^"']+)["']"#, .caseInsensitive)

    public static func find(in html: String, pattern: String, base: URL) -> URL? {
        guard let custom = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        for match in href.matches(in: html, range: range) {
            guard let r = Range(match.range(at: 1), in: html) else { continue }
            let link = String(html[r])
            if custom.firstMatch(in: link) != nil { return URL(string: link, relativeTo: base)?.absoluteURL }
        }
        return nil
    }
}

// MARK: - Decisions

public enum UpdateDecision {
    /// Is this candidate really newer than what's installed?
    public static func isUpdate(_ c: UpdateCandidate, installed: InstalledPlugin, record: PluginRecord) -> Bool {
        if let digests = installed.digests, c.hashes.matches(digests) { return false }
        if let known = record.installedUpstreamID, known == c.upstreamID { return false }
        let new = LooseVersion(c.version), old = LooseVersion(installed.version)
        // Build-number and link sources move on even when the jar's version doesn't.
        let tracksBuilds: Bool
        switch record.source {
        case .jenkins, .web: tracksBuilds = true
        default: tracksBuilds = false
        }
        if tracksBuilds {
            if case .web = record.source, record.installedUpstreamID == nil { return false } // first sighting sets a baseline
            if let new, let old, new < old { return false }
            return true
        }
        if let new, let old { return new > old }
        return record.installedUpstreamID != nil
    }

    /// The check every download goes through, whatever its source.
    public static func inspect(_ d: PluginDescriptor?, expectedName: String?, mc: GameVersion?, compat: Compatibility) throws -> Compatibility {
        guard let d else { throw LeafError("That jar has no plugin.yml, so it isn't a Bukkit or Paper plugin.") }
        if let expectedName, d.name.lowercased() != expectedName.lowercased() {
            throw LeafError("That jar calls itself \(d.name), not \(expectedName). It may be the wrong file; check the source's pattern.")
        }
        guard let mc else { return compat }
        if let raw = d.apiVersion, let api = GameVersion(raw) {
            if api > mc { throw LeafError("\(d.name) \(d.version) needs Minecraft \(raw) or newer. This server runs \(mc), so it wasn't installed.") }
            if compat.verdict == .unknown { return Compatibility(.likely, "Its api-version (\(raw)) suits this server.") }
        }
        return compat
    }
}

// MARK: - Finding sources automatically

public struct SourceSuggestion: Identifiable, Equatable, Sendable {
    public var id: String { source.summary }
    public let source: PluginSource
    public let reason: String
    /// Exact hash matches are safe to apply without asking.
    public let exact: Bool
}

public enum SourceFinder {
    /// Batch lookup: which installed jars are byte-identical to a Modrinth file? Keys are sha1.
    public static func modrinthMatches(sha1s: [String]) async -> [String: String] {
        guard !sha1s.isEmpty,
              let body = try? JSONSerialization.data(withJSONObject: ["hashes": sha1s, "algorithm": "sha1"]),
              let url = URL(string: "https://api.modrinth.com/v2/version_files"),
              let object = try? await HTTP.json(url, method: "POST", body: body) as? [String: [String: Any]] else { return [:] }
        return object.compactMapValues { $0["project_id"] as? String }
    }

    /// A Modrinth project's slug and title, for checking a hash match against the plugin's own name.
    public static func modrinthNames(project: String) async -> [String] {
        guard project.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
              let url = URL(string: "https://api.modrinth.com/v2/project/\(project)"),
              let object = try? await HTTP.json(url) as? [String: Any] else { return [] }
        return [object["slug"] as? String, object["title"] as? String].compactMap { $0 }
    }

    public static func suggestions(for plugin: InstalledPlugin) async -> [SourceSuggestion] {
        var out: [SourceSuggestion] = []
        if let website = plugin.descriptor?.website, let source = SourceParser.parse(website) {
            if case .web = source {} else { out.append(.init(source: source, reason: "From the plugin's website field.", exact: false)) }
        }
        let name = plugin.name
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        struct HangarSearch: Decodable {
            struct P: Decodable { struct N: Decodable { let owner: String; let slug: String }; let name: String; let namespace: N }
            let result: [P]
        }
        if let url = URL(string: "https://hangar.papermc.io/api/v1/projects?query=\(encoded)&limit=5"),
           let found = try? await HTTP.decode(HangarSearch.self, url),
           let hit = found.result.first(where: { $0.name.lowercased() == name.lowercased() }) {
            out.append(.init(source: .hangar(project: "\(hit.namespace.owner)/\(hit.namespace.slug)", channel: "Release"), reason: "Same name on Hangar.", exact: false))
        }
        struct SpigetHit: Decodable { let id: Int; let name: String? }
        if let url = URL(string: "https://api.spiget.org/v2/search/resources/\(encoded)?field=name&size=10&fields=id,name"),
           let found = try? await HTTP.decode([SpigetHit].self, url),
           let hit = found.first(where: { ($0.name ?? "").lowercased().hasPrefix(name.lowercased()) }) {
            out.append(.init(source: .spigot(resourceID: hit.id), reason: "\"\(hit.name ?? name)\" on SpigotMC. Check that it's the right one.", exact: false))
        }
        return out
    }
}
