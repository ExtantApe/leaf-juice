// Self-tests, runnable with just the Command Line Tools.
//   swift run leafjuice-check          Offline suite, plus the full server lifecycle against a small
//                                      stand-in jar (compiled here if a JDK is available). No Minecraft.
//   ... --live                         Also calls the real Paper, Modrinth, Hangar, Spiget, GitHub APIs.
//   ... --real-prejoin --i-accept-the-minecraft-eula
//   ... --real-signin <Latchkey.jar> --i-accept-the-minecraft-eula
//   ... --sandbox --i-accept-the-minecraft-eula
//                                      A lasting test server in .lab-sandbox/, seeded with bot players and several worlds.
//                                      Each run tests a throwaway clone. Add --sandbox-wipe to start it afresh.
//   ... --lab --i-accept-the-minecraft-eula
//   ... --experiments <versions,failures,multiverse,players,renames,restore|all> --i-accept-the-minecraft-eula
//                                      Tries things and writes down what really happened, in .lab-sandbox/findings/.
//   ... --real-map --i-accept-the-minecraft-eula
//                                      Real BlueMap, Multiverse and LuckPerms behind the sign-in page, on a throwaway server.
//   ... --real-pack --i-accept-the-minecraft-eula
//                                      A throwaway Paper server and bots, with made-up packs served by Leaf Juice.
//   ... --real-paper --i-accept-the-minecraft-eula
//                                      Boots real Paper. The second flag is your own acceptance of
//                                      https://aka.ms/MinecraftEULA, for a throwaway server in a temp folder.
import CryptoKit
import Foundation
import Network
@testable import LeafJuiceCore

// ... --demo-packs <folder> <zip>...  Fills a throwaway folder with these packs and a server, for clicking through the app.
if let flag = CommandLine.arguments.firstIndex(of: "--demo-packs") {
    let demo = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    setenv("LEAFJUICE_HOME", demo.appendingPathComponent("home").path, 1)
    setenv("LEAFJUICE_SERVERS", demo.appendingPathComponent("servers").path, 1)
    var added: [LibraryPack] = []
    for zip in CommandLine.arguments[(flag + 2)...] { added.append(try await ResourcePacks.add(URL(fileURLWithPath: zip))) }
    var recipe = ResourcePacks.reconcile(PackRecipe(), with: added)
    recipe.name = "world-one"
    ResourcePacks.saveRecipe(recipe)
    _ = try await ResourcePacks.combine(recipe)
    recipe.name = "world-two"
    recipe.entries.reverse()
    ResourcePacks.saveRecipe(recipe)
    _ = try await ResourcePacks.combine(recipe)
    let root = demo.appendingPathComponent("servers/demo-server", isDirectory: true)
    try FileOps.writeAtomic("server-port=25592\nmotd=made up\n", to: root.appendingPathComponent("server.properties"))
    _ = try await ServerController.adopt(root: root, name: "demo-server")
    print("Demo folder ready: \(demo.path)")
    exit(0)
}

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("leafjuice-check-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
setenv("LEAFJUICE_HOME", scratch.appendingPathComponent("home").path, 1)
setenv("LEAFJUICE_SERVERS", scratch.appendingPathComponent("servers").path, 1)
defer { try? FileManager.default.removeItem(at: scratch) }

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failures: [String] = []

@MainActor func check(_ condition: @autoclosure () throws -> Bool, _ label: String, line: Int = #line) {
    if (try? condition()) == true { passed += 1 } else { failures.append("line \(line): \(label)"); print("  FAIL \(label) (line \(line))") }
}
@MainActor func equal<T: Equatable>(_ a: T, _ b: T, _ label: String, line: Int = #line) {
    if a == b { passed += 1 } else { failures.append("line \(line): \(label): \(a) != \(b)"); print("  FAIL \(label): got \(a), want \(b) (line \(line))") }
}
func section(_ name: String) { print("• \(name)") }
func gv(_ s: String) -> GameVersion { GameVersion(s)! }
extension NewWorld { static func named(_ n: String) -> NewWorld { var w = NewWorld(); w.name = n; return w } }
func folder(_ name: String) -> URL {
    let url = scratch.appendingPathComponent(name, isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
func write(_ text: String, _ url: URL) { try! FileOps.writeAtomic(text, to: url) }

/// Builds a minimal plugin jar with the system zip tool.
func makeJar(_ url: URL, yaml: String) {
    let work = folder("jar-\(UUID().uuidString)")
    write(yaml, work.appendingPathComponent("plugin.yml"))
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    p.arguments = ["-q", url.path, "plugin.yml"]
    p.currentDirectoryURL = work
    try! p.run()
    p.waitUntilExit()
}

// MARK: Versions

section("Versions")
check(gv("1.21.11") > gv("1.21.9"), "numeric, not lexical")
check(gv("26.3") > gv("1.21.11"), "year-based versions sort after 1.x")
check(gv("26.3-rc-3") < gv("26.3"), "prerelease before release")
check(gv("1.21.11-pre5") < gv("1.21.11-rc1"), "pre before rc")
check(gv("1.21") == gv("1.21.0"), "padding")
equal(gv("1.21.4").line, "1.21", "line")
equal(gv("26.1.2").line, "26.1", "year line")
check(!gv("26.3-rc-3").isStableRelease, "rc isn't stable")
equal(GameVersion.mentioned(in: "Foo-mc1.21.4.jar").map(\.raw), ["1.21.4"], "mc tag")
equal(GameVersion.mentioned(in: "Foo-for-26.3-b2.jar").map(\.raw), ["26.3"], "for tag")
equal(GameVersion.mentioned(in: "LuckPerms-Bukkit-5.5.90.jar").map(\.raw), [], "plugin version isn't a Minecraft version")
equal(GameVersion.mentioned(in: "Foo-1.21.4.jar").map(\.raw), [], "bare version is ambiguous")
check(gv("1.21.4").isCovered(by: [gv("1.21")]), "line tag covers patch")
check(!gv("1.21.4").isCovered(by: [gv("1.21.3")]), "other patch doesn't")
check(LooseVersion("v5.5.71-bukkit")! > LooseVersion("5.5.9")!, "loose compare")
equal(LooseVersion("2.1-SNAPSHOT-b44")!.parts, [2, 1], "loose first run")
equal(JavaRequirement.estimated(for: gv("26.1")), 25, "java 26.x")
equal(JavaRequirement.estimated(for: gv("1.20.6")), 21, "java 1.20.6")
equal(JavaRequirement.estimated(for: gv("1.20.4")), 17, "java 1.20.4")
equal(JavaManager.parseVersionOutput(#"openjdk version "21.0.11" 2026-04-21"#)?.major, 21, "java parse")
equal(JavaManager.parseVersionOutput(#"java version "1.8.0_392""#)?.major, 8, "legacy java parse")
do {
    let rt = [JavaRuntime(path: "a", version: "17", major: 17, vendor: nil, managed: false),
              JavaRuntime(path: "b", version: "21", major: 21, vendor: nil, managed: false),
              JavaRuntime(path: "c", version: "25", major: 25, vendor: nil, managed: false)]
    equal(JavaManager.best(for: 21, in: rt)?.path, "b", "smallest suitable java")
    check(JavaManager.best(for: 26, in: rt) == nil, "no suitable java")
}

// MARK: Software moves

section("Software moves")
do {
    var s = SoftwareState()
    s.flavor = .paper; s.mcVersion = "1.21.4"; s.build = 100
    equal(SoftwareCatalog.classify(current: s, flavor: .paper, mc: "1.21.4", build: 101), .newBuild, "new build")
    equal(SoftwareCatalog.classify(current: s, flavor: .paper, mc: "1.21.4", build: 100), .same, "same")
    equal(SoftwareCatalog.classify(current: s, flavor: .paper, mc: "1.21.11", build: 1), .upgrade, "upgrade")
    equal(SoftwareCatalog.classify(current: s, flavor: .paper, mc: "1.20.6", build: 1), .downgrade, "downgrade")
    equal(SoftwareCatalog.classify(current: s, flavor: .purpur, mc: "1.21.4", build: 1), .switchSoftware, "switch")
    check(SoftwareCatalog.classify(current: s, flavor: .paper, mc: "26.3", build: 1).needsBackup, "upgrades need backup")
    check(!SoftwareCatalog.classify(current: s, flavor: .paper, mc: "1.21.4", build: 101).needsBackup, "builds don't")
    equal(SoftwareCatalog.sortedNewestFirst(["1.21.9", "26.1", "1.21.11", "bogus"]), ["26.1", "1.21.11", "1.21.9"], "sort")
    let builds = #"[{"id":5,"channel":"BETA","downloads":{"server:default":{"name":"b.jar","url":"u"}}},{"id":4,"channel":"STABLE","time":"2026-11-03T22:50:53Z","downloads":{"server:default":{"name":"a.jar","url":"u","checksums":{"sha256":"ab"},"size":1}}}]"#
    let decoded = try! HTTP.decodeBody([SoftwareCatalog.FillBuild].self, Data(builds.utf8))
    equal(SoftwareCatalog.fillBuild(from: decoded, meta: nil, flavor: .paper, mc: "26.3", channels: ["STABLE"])?.build, 4, "stable only")
    equal(SoftwareCatalog.fillBuild(from: decoded, meta: nil, flavor: .paper, mc: "26.3", channels: ["STABLE", "BETA"])?.build, 5, "beta opt-in")
    check(SoftwareCatalog.fillBuild(from: decoded, meta: nil, flavor: .paper, mc: "26.3", channels: ["ALPHA"]) == nil, "no alpha")
}

// MARK: Launch

section("Launch")
do {
    equal(ArgumentString.split(#"-Dfoo="a b" --x 'c d' e\ f"#), ["-Dfoo=a b", "--x", "c d", "e f"], "split")
    equal(ArgumentString.quote("a b"), "'a b'", "quote")
    var s = SoftwareState(); s.jarName = "paper.jar"
    var l = LaunchConfig(); l.minMemoryMB = 1024; l.maxMemoryMB = 2048; l.preset = .none; l.serverArgs = "--port 1234"
    equal(LaunchCommand.arguments(l, software: s), ["-Xms1024M", "-Xmx2048M", "-jar", "paper.jar", "--port", "1234", "--nogui"], "args")
    l.preset = .recommended
    check(LaunchCommand.arguments(l, software: s).contains("-XX:+UseG1GC"), "fallback flags")
    s.recommendedFlags = ["-XX:+Mine"]
    check(LaunchCommand.arguments(l, software: s).contains("-XX:+Mine"), "API flags win")
    let script = "#!/bin/sh\n# start\njava -Xms2G -Xmx6G -XX:+UseG1GC -Dfoo=bar -jar paper-1.21.4-100.jar --port 1 nogui\n"
    let parsed = ServerDetector.parseStartScript(script, name: "start.sh")
    equal(parsed?.jar, "paper-1.21.4-100.jar", "script jar")
    equal(parsed?.launch.maxMemoryMB, 6144, "script memory")
    equal(parsed?.launch.minMemoryMB, 2048, "script min")
    equal(parsed?.launch.extraJVMArgs, "-XX:+UseG1GC -Dfoo=bar", "script flags")
    equal(parsed?.launch.serverArgs, "--port 1", "script args")
    equal(parsed?.launch.preset, .custom, "script flags keep their own preset")
    equal(ServerDetector.parseMemory("4096M"), 4096, "M")
}

// MARK: Properties

section("Properties")
do {
    let text = "# Minecraft server properties\nmotd=A Server\\: Hello\nmax-players=20\n\nview-distance=10\n"
    var doc = PropertiesDocument(text)
    equal(doc.value("motd"), "A Server: Hello", "unescape")
    equal(doc.text, text, "untouched round trip")
    doc.set("max-players", "5")
    check(doc.text.contains("# Minecraft server properties\n"), "comments survive")
    check(doc.text.contains("max-players=5\n"), "set")
    doc.set("new-key", "x")
    check(doc.text.contains("new-key=x"), "insert")
    let base = "a=1\nb=2\nc=3\n", mine = "a=9\nb=2\nc=3\n", theirs = "a=1\nb=7\nc=3\nd=4\n"
    let merged = PropertiesDocument(PropertiesDocument.merge(base: base, mine: mine, theirs: theirs))
    equal(merged.value("a"), "9", "my edit kept"); equal(merged.value("b"), "7", "their edit kept"); equal(merged.value("d"), "4", "their addition kept")
}

// MARK: Config validation

section("Config validation")
check(!ConfigValidator.problems("a:\n\tb: 1\n", format: .yaml).isEmpty, "tab indent")
check(!ConfigValidator.problems("a: \"unclosed\n", format: .yaml).isEmpty, "unclosed quote")
check(ConfigValidator.problems("a: it's fine\nb: 'x' # c\n# 'odd\n", format: .yaml).isEmpty, "apostrophes fine")
check(!ConfigValidator.problems("{nope", format: .json).isEmpty, "bad json")
check(ConfigValidator.problems("[]", format: .json).isEmpty, "good json")
check(!ConfigValidator.problems("just words\n", format: .properties).isEmpty, "bad properties")

// MARK: Plugin descriptors

section("Plugin descriptors")
do {
    let yaml = """
    name: 'Foo'   # comment
    version: "1.2.3"
    main: com.acme.foo.Main
    api-version: 1.21
    author: Pat
    authors: [Sam, Lee]
    website: https://github.com/acme/foo
    depend: [Vault]
    softdepend:
      - PlaceholderAPI
      - WorldGuard
    commands:
      foo:
        description: 'nested name: ignored'
    """
    let d = PluginYAML.parse(yaml)
    equal(d?.name, "Foo", "name"); equal(d?.version, "1.2.3", "version"); equal(d?.apiVersion, "1.21", "api")
    equal(d?.authors ?? [], ["Pat", "Sam", "Lee"], "authors"); equal(d?.depend ?? [], ["Vault"], "depend")
    equal(d?.softDepend ?? [], ["PlaceholderAPI", "WorldGuard"], "softdepend")
    check(PluginYAML.parse("version: 1") == nil, "name required")
}

// MARK: Source parsing

section("Source parsing")
equal(SourceParser.parse("https://modrinth.com/plugin/luckperms/versions"), .modrinth(project: "luckperms", allowBeta: false), "modrinth")
equal(SourceParser.parse("modrinth.com/plugin/luckperms"), .modrinth(project: "luckperms", allowBeta: false), "no scheme")
equal(SourceParser.parse("https://hangar.papermc.io/ViaVersion/ViaVersion"), .hangar(project: "ViaVersion/ViaVersion", channel: "Release"), "hangar")
equal(SourceParser.parse("https://www.spigotmc.org/resources/luckperms.28140/"), .spigot(resourceID: 28140), "spigot")
equal(SourceParser.parse("https://github.com/ViaVersion/ViaVersion/releases"), .github(repo: "ViaVersion/ViaVersion", assetPattern: "", prereleases: false), "github")
equal(SourceParser.parse("https://ci.lucko.me/job/LuckPerms/lastSuccessfulBuild/artifact/x.jar"), .jenkins(jobURL: "https://ci.lucko.me/job/LuckPerms/", artifactPattern: ""), "jenkins")
equal(SourceParser.parse("https://ci.acme.org/jenkins/job/Team/job/Foo/42/"), .jenkins(jobURL: "https://ci.acme.org/jenkins/job/Team/job/Foo/", artifactPattern: ""), "jenkins folders")
equal(SourceParser.parse("https://acme.org/foo.jar"), .web(url: "https://acme.org/foo.jar", linkPattern: ""), "web")
check(SourceParser.parse("   ") == nil, "blank")

section("Jar picking")
do {
    let luckperms = ["LuckPerms-Bukkit-5.5.90.jar", "LuckPerms-Bukkit-Legacy-5.5.90.jar", "LuckPerms-Bungee-5.5.90.jar", "LuckPerms-Fabric-5.5.90.jar", "LuckPerms-Forge-5.5.90.jar"]
    equal(JarPicker.pick(luckperms, pattern: ""), "LuckPerms-Bukkit-5.5.90.jar", "Bukkit over others")
    equal(JarPicker.pick(["foo-sources.jar", "foo-javadoc.jar", "foo-1.0.jar"], pattern: ""), "foo-1.0.jar", "skip sources")
    equal(JarPicker.pick(luckperms, pattern: "Legacy"), "LuckPerms-Bukkit-Legacy-5.5.90.jar", "pattern wins")
    check(JarPicker.pick(["a.txt"], pattern: "") == nil, "no jars")
    check(JarPicker.pick(luckperms, pattern: "(") == nil, "bad pattern is harmless")
}

// MARK: Compatibility

section("Tag-aware compatibility")
do {
    let json = #"""
    [{"id":"new","project_id":"p","version_number":"3.0","version_type":"release","game_versions":["26.3"],"loaders":["paper"],"date_published":"2026-10-01T00:00:00.000000Z","files":[{"hashes":{"sha1":"aa","sha512":"bb"},"url":"u3","filename":"foo-3.jar","primary":true}]},
     {"id":"fab","project_id":"p","version_number":"2.9","version_type":"release","game_versions":["1.21.4"],"loaders":["fabric"],"date_published":"2026-09-15T00:00:00Z","files":[{"hashes":{},"url":"f","filename":"f.jar","primary":true}]},
     {"id":"beta","project_id":"p","version_number":"2.8b","version_type":"beta","game_versions":["1.21.4"],"loaders":["paper"],"date_published":"2026-09-10T00:00:00Z","files":[{"hashes":{},"url":"b","filename":"b.jar","primary":true}]},
     {"id":"old","project_id":"p","version_number":"2.0","version_type":"release","game_versions":["1.21.4","1.21.3"],"loaders":["spigot","paper"],"date_published":"2026-01-01T00:00:00Z","files":[{"hashes":{},"url":"u2","filename":"foo-2.jar","primary":true}]}]
    """#
    let v = try! HTTP.decodeBody([PluginSources.ModrinthVersion].self, Data(json.utf8))
    var r = PluginSources.modrinthChoose(v, project: "p", allowBeta: false, mc: gv("26.3"), flavor: .paper)
    equal(r.candidate?.version, "3.0", "newest match"); equal(r.candidate?.compatibility.verdict, .compatible, "exact")
    r = PluginSources.modrinthChoose(v, project: "p", allowBeta: false, mc: gv("1.21.4"), flavor: .paper)
    equal(r.candidate?.version, "2.0", "falls back to version that lists this game version; not fabric or beta")
    check(r.skippedNote?.contains("3.0") == true, "mentions what was passed over")
    r = PluginSources.modrinthChoose(v, project: "p", allowBeta: true, mc: gv("1.21.4"), flavor: .paper)
    equal(r.candidate?.version, "2.8b", "beta opt-in")
    r = PluginSources.modrinthChoose(v, project: "p", allowBeta: false, mc: gv("1.20.1"), flavor: .paper)
    check(r.candidate == nil, "never offers an incompatible version")
    check(r.skippedNote != nil, "explains why")
    r = PluginSources.modrinthChoose(v, project: "p", allowBeta: false, mc: gv("26.3"), flavor: .folia)
    check(r.candidate == nil, "loader respected")

    equal(PluginSources.spigotCompatibility(tested: ["1.20", "1.21"], mc: gv("1.21.4")).verdict, .likely, "spigot line tag")
    equal(PluginSources.spigotCompatibility(tested: ["1.20", "1.21"], mc: gv("26.3")).verdict, .unknown, "spigot newer")
    equal(PluginSources.spigotCompatibility(tested: ["1.20", "1.21"], mc: gv("1.16.5")).verdict, .incompatible, "spigot older")
    equal(PluginSources.spigotCompatibility(tested: [], mc: gv("1.21")).verdict, .unknown, "spigot none")

    func release(_ tag: String, pre: Bool = false, asset: String = "foo.jar") -> PluginSources.GitHubRelease {
        let j = #"{"tag_name":"\#(tag)","draft":false,"prerelease":\#(pre),"assets":[{"name":"\#(asset)","browser_download_url":"u"}]}"#
        return try! HTTP.decodeBody(PluginSources.GitHubRelease.self, Data(j.utf8))
    }
    var g = PluginSources.githubChoose([release("v2-mc26.3"), release("v1-mc1.21.4")], pattern: "", prereleases: false, mc: gv("1.21.4"))
    equal(g.candidate?.version, "v1-mc1.21.4", "skips releases tagged for other versions")
    equal(g.candidate?.compatibility.verdict, .compatible, "tagged match")
    g = PluginSources.githubChoose([release("v2", pre: true), release("v1")], pattern: "", prereleases: false, mc: gv("1.21.4"))
    equal(g.candidate?.version, "v1", "no prereleases by default"); equal(g.candidate?.compatibility.verdict, .unknown, "untagged")
    g = PluginSources.githubChoose([release("v2-mc26.3")], pattern: "", prereleases: false, mc: gv("1.21.4"))
    check(g.candidate == nil, "all wrong tags"); check(g.skippedNote != nil, "explained")

    let jb = try! HTTP.decodeBody(PluginSources.JenkinsBuild.self, Data(#"{"number":77,"timestamp":1000,"artifacts":[{"fileName":"Foo-Bukkit-1.jar","relativePath":"b/Foo-Bukkit-1.jar"},{"fileName":"Foo-Fabric-1.jar","relativePath":"f/Foo-Fabric-1.jar"}]}"#.utf8))
    let j = PluginSources.jenkinsChoose(jb, jobURL: "https://ci/job/Foo/", pattern: "", mc: gv("1.21"))
    equal(j.candidate?.downloadURL, "https://ci/job/Foo/77/artifact/b/Foo-Bukkit-1.jar", "pins the build number")
    equal(j.candidate?.upstreamID, "build-77", "id")

    let html = #"<a href="/dl/foo-1.0-sources.jar">x</a><a href='/dl/foo-1.0.jar'>y</a>"#
    equal(WebLinkFinder.find(in: html, pattern: #"foo-[\d.]+\.jar"#, base: URL(string: "https://a.org/p/")!)?.absoluteString, "https://a.org/dl/foo-1.0.jar", "web link")
}

section("Update decisions")
do {
    let digests = Hashing.Digests(sha1: "aa", sha256: "bb", sha512: "cc", md5: "dd")
    let d = PluginDescriptor(name: "Foo", version: "5.5.71")
    let installed = InstalledPlugin(fileName: "foo.jar", enabled: true, descriptor: d, digests: digests, size: 1)
    func cand(_ v: String, id: String = "x", sha1: String? = nil) -> UpdateCandidate {
        UpdateCandidate(version: v, upstreamID: id, downloadURL: "u", hashes: ExpectedHashes(sha1: sha1), compatibility: Compatibility(.compatible, ""))
    }
    var rec = PluginRecord(); rec.source = .modrinth(project: "p", allowBeta: false)
    check(UpdateDecision.isUpdate(cand("v5.5.72-bukkit"), installed: installed, record: rec), "newer")
    check(!UpdateDecision.isUpdate(cand("v5.5.71-bukkit"), installed: installed, record: rec), "same")
    check(!UpdateDecision.isUpdate(cand("v5.5.70"), installed: installed, record: rec), "never downgrades")
    check(!UpdateDecision.isUpdate(cand("9.9", sha1: "aa"), installed: installed, record: rec), "same hash is the same file")
    rec.installedUpstreamID = "x"
    check(!UpdateDecision.isUpdate(cand("9.9"), installed: installed, record: rec), "known upstream id")
    rec.source = .jenkins(jobURL: "j", artifactPattern: "")
    rec.installedUpstreamID = "build-1"
    check(UpdateDecision.isUpdate(cand("Foo-5.5.71 (#2)", id: "build-2"), installed: installed, record: rec), "new build same version")
    check(!UpdateDecision.isUpdate(cand("Foo-5.5.1 (#2)", id: "build-2"), installed: installed, record: rec), "older build number run")
    rec = PluginRecord(); rec.source = .web(url: "u", linkPattern: "")
    check(!UpdateDecision.isUpdate(cand("whatever", id: "etag1"), installed: installed, record: rec), "first web sighting is a baseline")

    let unknown = Compatibility(.unknown, "")
    var err = ""
    do { _ = try UpdateDecision.inspect(PluginDescriptor(name: "Other"), expectedName: "Foo", mc: gv("1.21"), compat: unknown) } catch { err = error.localizedDescription }
    check(err.contains("Other"), "wrong artifact refused")
    err = ""
    var tooNew = PluginDescriptor(name: "Foo"); tooNew.apiVersion = "26.3"
    do { _ = try UpdateDecision.inspect(tooNew, expectedName: "Foo", mc: gv("1.21.4"), compat: unknown) } catch { err = error.localizedDescription }
    check(err.contains("26.3"), "api-version too new refused")
    err = ""
    do { _ = try UpdateDecision.inspect(nil, expectedName: nil, mc: nil, compat: unknown) } catch { err = error.localizedDescription }
    check(!err.isEmpty, "not a plugin refused")
    var okApi = PluginDescriptor(name: "Foo"); okApi.apiVersion = "1.21"
    equal(try! UpdateDecision.inspect(okApi, expectedName: "foo", mc: gv("1.21.4"), compat: unknown).verdict, .likely, "api-version gives evidence")
    check(!Compatibility(.unknown, "").allowsAutoInstall, "unknown never auto-installs")
    check(Compatibility(.likely, "").allowsAutoInstall, "likely may")
}

// MARK: Issues

section("Issue rules")
do {
    let rules = RuleBook.builtIn
    check(rules.count >= 30, "a useful number of rules")
    equal(Set(rules.map(\.id)).count, rules.count, "unique ids")
    for rule in rules {
        check(rule.regex.map { (try? NSRegularExpression(pattern: $0)) != nil } ?? true, "\(rule.id) regex compiles")
        check(!(rule.samples ?? []).isEmpty, "\(rule.id) has samples")
        check(!rule.steps.isEmpty, "\(rule.id) has steps")
        for sample in rule.samples ?? [] {
            let a = IssueAnalyzer(rules: rules)
            a.ingest(sample)
            equal(a.sorted.first?.ruleID, rule.id, "sample routes to \(rule.id): \(sample)")
        }
    }
    let pages = Set(["resourcePacks", "links", "allowlist", "launch", "plugins", "configs", "software", "backups", "changes", "console", "overview", "worlds", "players", "history", "cleanup"])
    for rule in rules { if let a = rule.action { check(pages.contains(a.page), "\(rule.id) action page") } }
    check(rules.allSatisfy { !$0.title.isEmpty && !$0.explanation.isEmpty }, "rules have text")
}

section("Issue catalog")
do {
    var p = ParsedLogLine("[12:00:00 WARN]: [Foo] hello")
    equal(p.level, .warn, "paper level"); equal(p.message, "[Foo] hello", "message"); equal(p.tag, "Foo", "tag")
    p = ParsedLogLine("[12:00:00] [Server thread/ERROR]: boom")
    equal(p.level, .error, "log file level"); equal(p.message, "boom", "log file message")
    check(ParsedLogLine("\tat com.foo.Bar.baz(Bar.java:1)").isStackFrame, "stack frame")
    equal(ANSI.strip("\u{1B}[33mhi\u{1B}[0m"), "hi", "ansi")
    equal(ConsoleText.clean("> \r  \r[18:28:21 WARN]: hello"), "[18:28:21 WARN]: hello", "real Paper prompt removed")
    equal(ConsoleText.clean("\u{1B}[K> \r  \r[18:28:21 INFO]: Done (3.2s)!\r"), "[18:28:21 INFO]: Done (3.2s)!", "with ANSI and trailing return")
    equal(ConsoleText.clean("plain"), "plain", "plain line untouched")
    check(ConsoleText.clean("> ") == nil && ConsoleText.clean(">") == nil, "bare prompt dropped")
    equal(ConsoleText.clean(""), "", "blank line kept")

    let a = IssueAnalyzer(rules: RuleBook.builtIn)
    var d = PluginDescriptor(name: "Foo"); d.main = "com.acme.foo.Main"
    a.setPlugins([InstalledPlugin(fileName: "f.jar", enabled: true, descriptor: d, digests: nil, size: 0)])
    a.ingest("[12:00:00 WARN]: Thing 12 failed at 10.0.0.1:5000")
    a.ingest("[12:00:05 WARN]: Thing 99 failed at 10.0.0.2:6000")
    equal(a.records.count, 1, "unknown warnings group"); equal(a.sorted.first?.count, 2, "count")
    check(a.sorted.first?.isKnown == false, "catalogued without a rule")
    a.ingest("[12:00:06 INFO]: plain info")
    equal(a.records.count, 1, "info isn't an issue")

    a.clear()
    a.ingest("[12:00:00 ERROR]: Error occurred while enabling Foo v1.2 (Is it up to date?)")
    a.ingest("java.lang.NullPointerException: oops")
    a.ingest("\tat com.acme.foo.Main.onEnable(Main.java:10)")
    a.ingest("\tat org.bukkit.Thing.go(Thing.java:1)")
    let r = a.sorted.first!
    equal(r.title, "Foo crashed while starting", "subject fills title")
    equal(r.plugin, "Foo", "attributed"); equal(r.stack.count, 3, "stack attached across exception line")
    check(r.report.contains("Main.java:10"), "report includes stack")

    a.clear()
    a.ingest("[12:00:00 WARN]: [Foo] unmatched from a plugin")
    equal(a.sorted.first?.plugin, "Foo", "tag attributes")
    let id = a.sorted.first!.id
    a.setStatus(.resolved, id: id)
    a.ingest("[12:00:00 WARN]: [Foo] unmatched from a plugin")
    equal(a.sorted.first?.status, .open, "resolved reopens")
    a.setStatus(.ignored, id: id)
    a.ingest("[12:00:00 WARN]: [Foo] unmatched from a plugin")
    equal(a.sorted.first?.status, .ignored, "ignored stays")
    check(!a.sorted.first!.searchQuery.contains("10.0.0"), "query is generic")
    equal(IssueAnalyzer.normalize("a 12 at /Users/me/x/y.jar 123e4567-e89b-12d3-a456-426614174000"), "a # at PATH UUID", "normalize")
}

// MARK: Backups

section("Backups")
do {
    func rec(_ days: Double, pinned: Bool = false) -> BackupRecord {
        BackupRecord(fileName: "\(days)", date: Date().addingTimeInterval(-days * 86_400), size: 1, scope: .worlds, trigger: "t", software: "", mcVersion: "", serverName: "", pinned: pinned)
    }
    let set = [rec(0), rec(1), rec(2), rec(40), rec(50, pinned: true), rec(60)]
    equal(Backups.prunable(set, keepLast: 2, keepDays: 30).map(\.fileName), ["40.0", "60.0"], "retention spares recent and pinned")
    equal(Backups.prunable(set, keepLast: 1, keepDays: 0).map(\.fileName), ["1.0", "2.0", "40.0", "60.0"], "0 days keeps only the last N")

    let root = folder("backup-server")
    let world = root.appendingPathComponent("world")
    write("level", world.appendingPathComponent("level.dat"))
    write("lock", world.appendingPathComponent("session.lock"))
    write("region v1", world.appendingPathComponent("region/r.0.0.mca"))
    write("motd=one\n", root.appendingPathComponent("server.properties"))
    write("log", root.appendingPathComponent("logs/latest.log"))
    write("jar", root.appendingPathComponent("plugins/foo.jar"))
    write("meta", root.appendingPathComponent(".leafjuice/x"))
    equal(Backups.worldFolders(root), ["world"], "finds worlds")
    for needed in ["logs", "libraries", "versions", "cache"] { write("x", root.appendingPathComponent("\(needed)/f")) }
    for needed in ["logs", "libraries", "versions", "cache", "plugins", "world"] {
        check(Backups.items(root, scope: .everything).contains(needed), "whole folder has \(needed)")
    }
    check(!Backups.items(root, scope: .everything).contains(".leafjuice"), "skips own metadata")
    check(Backups.items(root, scope: .standard).contains("plugins"), "standard has plugins")

    var profile = ServerProfile()
    profile.name = "Test"
    let made = try await Backups.create(profile, root: root, trigger: "manual")
    check(made.size > 0, "archive written")
    equal(Backups.list(profile).map(\.fileName), [made.fileName], "listed")

    write("region v2", world.appendingPathComponent("region/r.0.0.mca"))
    write("motd=two\n", root.appendingPathComponent("server.properties"))
    write("new", world.appendingPathComponent("extra.txt"))
    try await Backups.restore(made, profile: profile, root: root)
    equal(try! String(contentsOf: world.appendingPathComponent("region/r.0.0.mca"), encoding: .utf8), "region v1", "world restored")
    equal(try! String(contentsOf: root.appendingPathComponent("server.properties"), encoding: .utf8), "motd=one\n", "settings restored")
    check(!FileOps.exists(world.appendingPathComponent("extra.txt")), "world replaced, not merged")
    check(!FileOps.exists(world.appendingPathComponent("session.lock")), "lock not restored")
    check(FileOps.exists(root.appendingPathComponent("logs/latest.log")), "logs untouched")
    equal(try! String(contentsOf: root.appendingPathComponent("libraries/f"), encoding: .utf8), "x", "libraries come back")

    // Anything added since goes, so it's exactly as it was. Leaf Juice's own records stay.
    let wholeBackup = try await Backups.create(profile, root: root, trigger: "manual")
    write("new", root.appendingPathComponent("paper-99.jar"))
    write("new", root.appendingPathComponent("extra_world/level.dat"))
    write("new", root.appendingPathComponent("plugins/added.jar"))
    try? FileManager.default.removeItem(at: root.appendingPathComponent("libraries"))
    try await Backups.restore(wholeBackup, profile: profile, root: root)
    check(!FileOps.exists(root.appendingPathComponent("paper-99.jar")), "jar added since is gone")
    check(!FileOps.exists(root.appendingPathComponent("extra_world")), "world added since is gone")
    check(!FileOps.exists(root.appendingPathComponent("plugins/added.jar")), "plugin added since is gone")
    check(FileOps.exists(root.appendingPathComponent("libraries/f")), "deleted libraries are back")
    check(FileOps.exists(root.appendingPathComponent(".leafjuice/x")), "own records kept")
    equal(wholeBackup.softwareState, profile.software, "records what was running")
    // A partial backup still leaves everything else alone.
    let partial = try await Backups.create(profile, root: root, trigger: "manual", scope: .worlds)
    write("keep", root.appendingPathComponent("keepme.txt"))
    try await Backups.restore(partial, profile: profile, root: root)
    check(FileOps.exists(root.appendingPathComponent("keepme.txt")), "partial restore removes nothing")
    try FileManager.default.removeItem(at: root.appendingPathComponent("keepme.txt"))
    check(wholeBackup.fileName != partial.fileName, "same-second backups get different names")
    try Backups.delete(wholeBackup, profile: profile); try Backups.delete(partial, profile: profile)
    check(FileOps.children(ServerPaths(root: root).meta).allSatisfy { !$0.lastPathComponent.hasPrefix("restore-") }, "temp cleaned")

    try Backups.setPinned(made, pinned: true, profile: profile)
    equal(Backups.list(profile).first?.pinned, true, "pin persists")
    Backups.prune(profile)
    equal(Backups.list(profile).count, 1, "pruning keeps it")
    try Backups.delete(Backups.list(profile)[0], profile: profile)
    equal(Backups.list(profile).count, 0, "deleted")
}

// MARK: Detect and adopt

section("Importing an existing server")
do {
    let root = folder("existing")
    write("x", root.appendingPathComponent("paper-1.21.4-232.jar"))
    write("x", root.appendingPathComponent("other.jar"))
    write(#"{"currentVersion":"1.21.4-232-abc (MC: 1.21.4)"}"#, root.appendingPathComponent("version_history.json"))
    write("#!/bin/bash\njava -Xmx8G -Xms8G -jar paper-1.21.4-232.jar nogui\n", root.appendingPathComponent("start.sh"))
    write("motd=keep me\nserver-port=25571\n", root.appendingPathComponent("server.properties"))
    write("[12:00:00] [Server thread/WARN]: Can't keep up! Is the server overloaded? Running 5012ms or 100 ticks behind\n", root.appendingPathComponent("logs/latest.log"))
    let before = FileOps.children(root).map(\.lastPathComponent).sorted()

    let c = try await ServerController.adopt(root: root, name: "Survival")
    defer { c.stopTicker() }
    equal(c.profile.software.flavor, .paper, "flavor"); equal(c.profile.software.mcVersion, "1.21.4", "mc")
    equal(c.profile.software.build, 232, "build"); equal(c.profile.software.jarName, "paper-1.21.4-232.jar", "jar")
    check(c.profile.launch.maxMemoryMB <= 8192, "memory from script")
    equal(c.serverPort, 25571, "port read")
    equal(c.issues.first?.ruleID, "cant-keep-up", "old log scanned")
    let after = FileOps.children(root).map(\.lastPathComponent).filter { $0 != ".leafjuice" }.sorted()
    equal(after, before, "import adds nothing outside .leafjuice")
    equal(try! String(contentsOf: root.appendingPathComponent("server.properties"), encoding: .utf8), "motd=keep me\nserver-port=25571\n", "properties untouched")

    let reopened = ServerController.open(root: root)
    defer { reopened?.stopTicker() }
    equal(reopened?.profile.name, "Survival", "reopens by folder")
    equal(reopened?.issues.first?.ruleID, "cant-keep-up", "issues persist")

    // Rename
    let moved = try c.rename(to: "Creative", moveFolderTo: "existing-renamed")
    equal(moved?.lastPathComponent, "existing-renamed", "folder moved")
    equal(c.profile.name, "Creative", "renamed")
    check(FileOps.exists(c.paths.profile), "profile follows the folder")
    equal(ServerController.open(root: moved!).map { let n = $0.profile.name; $0.stopTicker(); return n }, "Creative", "persisted")
    var err = ""
    do { _ = try c.rename(to: "   ", moveFolderTo: nil) } catch { err = error.localizedDescription }
    check(!err.isEmpty, "empty name refused")
}

// MARK: Staging

section("The change queue")
do {
    let root = folder("staging")
    let paths = ServerPaths(root: root)
    write("a=1\nb=2\n", paths.properties)
    let stage = ConfigStage(paths: paths)
    try stage.stage("server.properties", text: "a=9\nb=2\n")
    equal(try! String(contentsOf: paths.properties, encoding: .utf8), "a=1\nb=2\n", "staged edit doesn't touch the live file")
    equal(stage.stagedText("server.properties"), "a=9\nb=2\n", "staged text readable")
    // The server rewrote the file meanwhile: properties merge.
    write("a=1\nb=7\n", paths.properties)
    let conflict = try stage.apply("server.properties", format: .properties) { _, _ in }
    check(conflict == nil, "properties merge")
    let merged = PropertiesDocument(try! String(contentsOf: paths.properties, encoding: .utf8))
    equal(merged.value("a"), "9", "mine"); equal(merged.value("b"), "7", "theirs")
    check(stage.stagedText("server.properties") == nil, "stage cleared")

    write("x: 1\n", root.appendingPathComponent("bukkit.yml"))
    try stage.stage("bukkit.yml", text: "x: 2\n")
    write("x: 3\n", root.appendingPathComponent("bukkit.yml"))
    let held = try stage.apply("bukkit.yml", format: .yaml) { _, _ in }
    check(held != nil, "yaml conflict held back")
    equal(try! String(contentsOf: root.appendingPathComponent("bukkit.yml"), encoding: .utf8), "x: 3\n", "server's copy wins")
    equal(stage.stagedText("bukkit.yml"), "x: 2\n", "my edit is kept")

    ConfigHistory.record("a/b.yml", text: "1", paths: paths)
    check(FileOps.children(paths.configHistory).count == 1, "history written")

    write("[]", root.appendingPathComponent("ops.json"))
    let files = ConfigCatalog.scan(paths)
    check(files.contains { $0.path == "server.properties" }, "known file found")
    if case .lockedWhileRunning = files.first(where: { $0.path == "ops.json" })!.policy { passed += 1 } else { failures.append("ops.json should lock") }
    check(!files.contains { $0.path == "whitelist.json" }, "missing files aren't listed")

    write("k: v", root.appendingPathComponent("plugins/Foo/config.yml"))
    write("bin", root.appendingPathComponent("plugins/Foo/data.db"))
    let scanned = ConfigCatalog.scan(paths)
    check(scanned.contains { $0.path == "plugins/Foo/config.yml" }, "plugin configs surface")
    check(!scanned.contains { $0.path == "plugins/Foo/data.db" }, "data files don't")

    check(!EULA.isAccepted(paths), "eula default")
    write("eula=false\n", paths.eula); check(!EULA.isAccepted(paths), "false isn't accepted")
    try EULA.accept(paths); check(EULA.isAccepted(paths), "accepted")
}

section("Multiverse")
do {
    var w = NewWorld(); w.name = "mining"; w.environment = .nether; w.type = .flat; w.seed = "42"; w.structures = false
    equal(Multiverse.createCommand(w, major: 5), "mv create mining nether --seed 42 --world-type FLAT --no-structures", "v5 create")
    check(Multiverse.createCommand(w, major: 4).contains("-s 42 -t FLAT"), "v4 create")
    equal(Multiverse.createCommand(NewWorld.named("a"), major: 5), "mv create a normal", "plain create")
    equal(Multiverse.modifyCommand("a", property: "alias", value: "Hi", major: 5), "mv modify a set alias Hi", "v5 modify")
    equal(Multiverse.modifyCommand("a", property: "alias", value: "Hi", major: 4), "mv modify set alias Hi a", "v4 modify")
    equal(Multiverse.deleteCommand("a", removePlayers: true), "mv delete a --remove-players", "delete with flag")
    equal(Multiverse.deleteCommand("a", removePlayers: false), "mv delete a", "delete without flag")
    check(Multiverse.supportsRemovePlayers(LooseVersion("5.8.2")), "5.8 has the flag")
    check(!Multiverse.supportsRemovePlayers(LooseVersion("5.0.1")), "5.0 isn't assumed to")
    check(!Multiverse.supportsRemovePlayers(LooseVersion("4.3.16")), "4.x hasn't")
    equal(Multiverse.successText(.clone, major: 5), "world cloned to", "v5 clone wording")
    equal(Multiverse.successText(.delete, major: 4), "was deleted!", "v4 delete wording")
    equal(Multiverse.successText(.create, major: 4), "complete!", "v4 create wording")
    equal(Multiverse.confirmCommand(fromPrompt: "Run /mv confirm 726 to continue. This will expire in 30 seconds."), "mv confirm 726", "otp read")
    equal(Multiverse.confirmCommand(fromPrompt: "Run /mv confirm to continue."), "mv confirm", "no otp")
    check(Multiverse.confirmCommand(fromPrompt: "Deleting world 'a'...") == nil, "not a prompt")
    check(Multiverse.isValidName("my_world-2"), "valid"); check(Multiverse.isValidName("minecraft:resource"), "namespaced")
    check(!Multiverse.isValidName("a b"), "no spaces"); check(!Multiverse.isValidName("a\nstop"), "no injected commands"); check(!Multiverse.isValidName(""), "not empty")
    check(!Multiverse.isValidSeed("1 2"), "seed space"); check(Multiverse.isValidSeed(""), "seed optional")
    equal(WorldEnvironment.guess(from: "world_nether"), .nether, "nether guess"); equal(WorldEnvironment.guess(from: "foo_the_end"), .theEnd, "end guess"); equal(WorldEnvironment.guess(from: "town"), .normal, "default guess")

    let v5 = """
    # comment
    world:
      adjust-spawn: false
      alias: 'Home'
      auto-load: true
      difficulty: HARD
      entry-fee:
        amount: 0.0
        alias: 'nested, ignored'
      environment: NORMAL
      gamemode: SURVIVAL
    mining:
      alias: ''
      auto-load: false
      environment: NETHER
      hidden: true
    """
    let p5 = Multiverse.parseWorlds(v5)
    equal(p5.map(\.name), ["world", "mining"], "v5 names"); equal(p5[0].alias, "Home", "alias, not the nested one")
    equal(p5[0].difficulty, "HARD", "difficulty"); equal(p5[1].autoLoad, false, "auto-load"); equal(p5[1].hidden, true, "hidden")
    let v4 = "worlds:\n  world:\n    ==: MVWorld\n    alias: Old\n    environment: NORMAL\n    gameMode: CREATIVE\n    autoLoad: false\n  a[dot]b:\n    environment: THE_END\n"
    let p4 = Multiverse.parseWorlds(v4)
    equal(p4.map(\.name), ["world", "a.b"], "v4 names"); equal(p4[0].gamemode, "CREATIVE", "v4 gamemode"); equal(p4[0].autoLoad, false, "v4 autoload")
    check(Multiverse.parseWorlds("").isEmpty, "empty file")

    // Old layout, new layout, a world Multiverse knows with no folder, and one it doesn't know.
    let root = folder("worlds-server")
    let paths = ServerPaths(root: root)
    write("level-name=survival\n", paths.properties)
    for name in ["survival", "survival_nether", "creative", "stray"] { write("x", root.appendingPathComponent("\(name)/level.dat")) }
    write("data", root.appendingPathComponent("survival/dimensions/minecraft/overworld/r.mca"))
    write("data", root.appendingPathComponent("survival/dimensions/minecraft/resource/r.mca"))
    write("data", root.appendingPathComponent("survival/dimensions/acme/moon/r.mca"))
    write("survival:\n  environment: NORMAL\ncreative:\n  alias: Build\n  gamemode: CREATIVE\ngone:\n  environment: NORMAL\nresource:\n  environment: NORMAL\n", paths.plugins.appendingPathComponent("Multiverse-Core/worlds.yml"))
    let found = WorldScanner.scan(paths)
    let named = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0) })
    equal(found.first?.name, "survival", "main world first")
    check(named["survival"]?.isMain == true && named["survival"]?.isCore == true, "main flagged")
    check(named["survival_nether"]?.isCore == true, "built-in nether protected")
    check(named["minecraft:overworld"] == nil, "built-in dimension isn't its own world")
    check(named["acme:moon"]?.relativePath == "survival/dimensions/acme/moon", "26.1 custom dimension found")
    check(named["acme:moon"]?.isCore == false, "custom dimension is removable")
    check(named["resource"]?.isManaged == true && named["resource"]?.relativePath == "survival/dimensions/minecraft/resource", "bare Multiverse name matches its dimension")
    equal(named["creative"]?.title, "Build", "alias is the title"); check(named["creative"]?.isCore == false, "extra world removable")
    check(named["gone"]?.folderMissing == true, "missing folder noted")
    check(named["stray"]?.isManaged == false, "unknown folder can be imported")
    check((named["survival"]?.size ?? 0) > 0, "size measured")
    let locked = ConfigCatalog.scan(paths).first { $0.path == "plugins/Multiverse-Core/worlds.yml" }
    if case .lockedWhileRunning = locked?.policy { passed += 1 } else { failures.append("worlds.yml should lock while running") }
}

section("Pre-26 servers")
do {
    // The layout most servers have today: world, world_nether, world_the_end, extra Multiverse worlds alongside.
    let root = folder("pre26-server")
    let paths = ServerPaths(root: root)
    for name in ["world", "world_nether", "world_the_end", "creative", "mining_nether"] { write("x", root.appendingPathComponent("\(name)/level.dat")) }
    write("x", root.appendingPathComponent("paper-1.21.4-232.jar"))
    write("level-name=world\nserver-port=25570\n", paths.properties)
    write("worlds:\n  world:\n    ==: MVWorld\n    environment: NORMAL\n    gameMode: SURVIVAL\n  creative:\n    ==: MVWorld\n    alias: Build\n    environment: NORMAL\n    gameMode: CREATIVE\n  mining_nether:\n    ==: MVWorld\n    environment: NETHER\n", paths.plugins.appendingPathComponent("Multiverse-Core/worlds.yml"))
    let found = WorldScanner.scan(paths)
    equal(found.map(\.name), ["world", "world_nether", "world_the_end", "creative", "mining_nether"], "core worlds first, then extras")
    let named = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0) })
    check(named["world_nether"]?.isCore == true && named["world_the_end"]?.isCore == true, "built-in dimension folders protected")
    equal(named["world_nether"]?.relativePath, "world_nether", "top-level folder kept")
    check(named["creative"]?.isCore == false, "extra world manageable"); equal(named["creative"]?.title, "Build", "v4 alias")
    equal(named["creative"]?.multiverse?.gamemode, "CREATIVE", "v4 gamemode")
    equal(Backups.items(root, scope: .worlds), ["creative", "mining_nether", "world", "world_nether", "world_the_end"], "backups see every old-style world")
    check(Backups.items(root, scope: .everything).contains("paper-1.21.4-232.jar"), "whole-folder backup holds the jar")

    // Exactly what real Multiverse 5.8.2 wrote on real Paper 1.21.11.
    let real = folder("real-mv58-1.21")
    let realPaths = ServerPaths(root: real)
    write("level-name=world\n", realPaths.properties)
    for n in ["world", "world_nether", "world_the_end"] { write("x", real.appendingPathComponent("\(n)/level.dat")) }
    write("x", real.appendingPathComponent("ljtest/region/r.mca"))   // Just created: no level.dat yet.
    write("x", real.appendingPathComponent("stray/level.dat"))
    let realYml = "minecraft:ljtest:\n  alias: ''\n  auto-load: true\n  difficulty: easy\n  gamemode: survival\nminecraft:overworld:\n  alias: ''\n  difficulty: easy\n  gamemode: survival\nminecraft:the_end:\n  alias: ''\nminecraft:the_nether:\n  alias: ''\n"
    write(realYml, realPaths.plugins.appendingPathComponent("Multiverse-Core/worlds.yml"))
    let r = WorldScanner.scan(realPaths)
    equal(r.count, 5, "no ghost entries: \(r.map(\.name))")
    equal(r.first?.name, "minecraft:overworld", "main world first, under Multiverse's key"); equal(r.first?.title, "world", "shown by folder")
    check(r.first?.isMain == true && r.first?.isManaged == true && r.first?.relativePath == "world", "main world is managed, with its folder")
    let rn = Dictionary(uniqueKeysWithValues: r.map { ($0.name, $0) })
    equal(rn["minecraft:the_nether"]?.relativePath, "world_nether", "key maps to old-style Nether folder"); check(rn["minecraft:the_nether"]?.isCore == true, "and it's protected")
    equal(rn["minecraft:the_end"]?.relativePath, "world_the_end", "key maps to old-style End folder")
    equal(rn["minecraft:ljtest"]?.relativePath, "ljtest", "new world finds its folder without level.dat"); equal(rn["minecraft:ljtest"]?.title, "ljtest", "plain title"); check(rn["minecraft:ljtest"]?.isCore == false, "and can be managed")
    check(rn["stray"]?.isManaged == false, "unmanaged folder still offered for import")

    // And on real Paper 26.3, after migration.
    let real26 = folder("real-mv58-26")
    let real26Paths = ServerPaths(root: real26)
    write("level-name=world\n", real26Paths.properties)
    write("x", real26.appendingPathComponent("world/level.dat"))
    for n in ["overworld", "the_end", "the_nether", "ljnew"] { write("x", real26.appendingPathComponent("world/dimensions/minecraft/\(n)/r.mca")) }
    write("minecraft:ljnew:\n  alias: ''\nminecraft:overworld:\n  alias: ''\nminecraft:the_end:\n  alias: ''\nminecraft:the_nether:\n  alias: ''\n", real26Paths.plugins.appendingPathComponent("Multiverse-Core/worlds.yml"))
    let r26 = Dictionary(uniqueKeysWithValues: WorldScanner.scan(real26Paths).map { ($0.name, $0) })
    equal(r26.count, 4, "26.x: no duplicates: \(Array(r26.keys))")
    equal(r26["minecraft:overworld"]?.relativePath, "world", "26.x main"); check(r26["minecraft:overworld"]?.isMain == true, "26.x main flagged")
    equal(r26["minecraft:the_nether"]?.relativePath, "world/dimensions/minecraft/the_nether", "26.x Nether found"); check(r26["minecraft:the_nether"]?.isCore == true, "26.x Nether protected")
    equal(r26["minecraft:ljnew"]?.relativePath, "world/dimensions/minecraft/ljnew", "26.x custom world"); check(r26["minecraft:ljnew"]?.isCore == false, "26.x custom world manageable"); equal(r26["minecraft:ljnew"]?.title, "ljnew", "26.x title")

    check(SoftwareCatalog.crossesWorldLayoutChange(from: "1.21.11", to: "26.1"), "crossing is flagged")
    check(!SoftwareCatalog.crossesWorldLayoutChange(from: "1.21.4", to: "1.21.11"), "within 1.x isn't")
    check(!SoftwareCatalog.crossesWorldLayoutChange(from: "26.1", to: "26.3"), "within 26 isn't")
    equal(ServerDetector.versionInJarName("paper-1.21.4-232.jar"), "1.21.4", "jar version"); check(ServerDetector.versionInJarName("server.jar") == nil, "unnamed jar")

    let legacy = folder("legacy-server")
    write("x", legacy.appendingPathComponent("server.jar"))
    write(#"{"currentVersion":"git-Paper-794 (MC: 1.16.5)"}"#, legacy.appendingPathComponent("version_history.json"))
    write("x", legacy.appendingPathComponent("paper.yml"))
    let d = await ServerDetector.detect(legacy)
    equal(d.software.mcVersion, "1.16.5", "old history format"); equal(d.software.build, 794, "old build"); equal(d.software.flavor, .paper, "old flavor")
    check(ConfigCatalog.scan(ServerPaths(root: legacy)).contains { $0.path == "paper.yml" }, "old paper.yml surfaces")
}

section("Servers folder")
do {
    let parent = folder("servers-folder")
    write("x", parent.appendingPathComponent("Alpha/server.properties"))
    write("x", parent.appendingPathComponent("beta/paper.jar"))
    write("x", parent.appendingPathComponent("Adopted/.leafjuice/server.json"))
    write("x", parent.appendingPathComponent("Photos/cat.png"))
    write("x", parent.appendingPathComponent(".hidden/server.properties"))
    write("x", parent.appendingPathComponent("notes.txt"))
    equal(ServerFolders.find(in: parent).map(\.lastPathComponent), ["Adopted", "Alpha", "beta"], "finds servers, ignores other folders")
    check(ServerFolders.find(in: parent.appendingPathComponent("missing")).isEmpty, "no folder is fine")
    equal(ServerFolders.folderName(for: " My Realm "), "My Realm", "name kept"); equal(ServerFolders.folderName(for: "a/b"), "a-b", "no subfolders")
    check(ServerFolders.folderName(for: "  ") == nil && ServerFolders.folderName(for: ".x") == nil, "unusable names refused")
    check(!AppPaths.defaultServers.path.hasSuffix("/Minecraft"), "tests can't see the real ~/Minecraft")
    setenv("LEAFJUICE_SERVERS", parent.path, 1)
    equal(AppPaths.servers.path, parent.path, "tests never use the real folder")
    equal(AppPaths.defaultServers.path, parent.path, "nor does the first-launch default")
}

section("Config forms")
do {
    // Properties: the file decides, and the table only adds words.
    let props = "#Minecraft server properties\nmotd=\\u00A7aHello\\: World\nview-distance=10\npvp=true\ndifficulty=easy\nbrand-new-setting=7\nanother.future-flag=true\nmystery=abc\nlevel-seed=\n"
    var f = ConfigForm.fields(props, format: .properties)
    let by = Dictionary(uniqueKeysWithValues: f.map { ($0.path.joined(separator: "."), $0) })
    equal(by["view-distance"]?.title, "View distance", "known title"); equal(by["view-distance"]?.kind, .int(2...32), "known range")
    equal(by["view-distance"]?.section, "Performance", "known group")
    equal(by["brand-new-setting"]?.kind, .int(nil), "unknown number still gets a control"); equal(by["brand-new-setting"]?.title, "Brand new setting", "and a readable title")
    equal(by["brand-new-setting"]?.section, "Other settings", "in its own section")
    equal(by["another.future-flag"]?.kind, .bool, "unknown true/false gets a toggle")
    equal(by["mystery"]?.kind, .text, "unknown text")
    check(by["hardcore"] == nil, "a setting not in the file isn't shown")
    equal(f.first?.section, "Basics", "known groups first")
    equal(by["motd"]?.value, "\u{A7}aHello: World", "unicode escape read")
    equal(ConfigForm.plainMOTD("\u{A7}aHello &lWorld\nTwo"), "Hello World Two", "motd cleaned")
    if case let .choice(options)? = by["difficulty"]?.kind { check(options.contains("hard"), "choices") } else { failures.append("difficulty choice") }
    var edited = ConfigForm.set(by["view-distance"]!, to: "6", in: props, format: .properties)
    check(edited.contains("view-distance=6\n") && edited.contains("#Minecraft server properties"), "one line changes, comments stay")
    edited = ConfigForm.set(by["brand-new-setting"]!, to: "9", in: edited, format: .properties)
    check(edited.contains("brand-new-setting=9"), "unknown setting edits too")
    equal(ConfigForm.fields("view-distance=99", format: .properties).first?.problem, "This needs to be from 2 to 32.", "known range enforced")
    check(ConfigForm.fields("brand-new-setting=99", format: .properties).first?.problem == nil, "unknown has no invented limit")
    check(ConfigForm.fields("view-distance=abc", format: .properties).first?.problem == nil, "odd values aren't forced into a number")

    // YAML, shaped like real Bukkit and Paper files.
    let yaml = """
    # This is the main configuration file for Bukkit.
    settings:
      allow-end: true # keep
      warn-on-overload: true
      shutdown-message: Server closed
      quoted: 'it''s here'
      dquoted: "a \\"b\\""
    spawn-limits:
      monsters: 70
    # Ticks between saves
    ticks-per:
      autosave: 6000
    aliases: now-in-commands.yml
    worlds:
    - alpha
    - beta
    nested:
      list:
        - one
        - two
      inline: [a, b]
      empty: {}
      block: |
        line one
        key: not real
      after-block: 3
      ratio: 0.5
      fallback: default
    top-level: yes-please

    """
    f = ConfigForm.fields(yaml, format: .yaml)
    let y = Dictionary(uniqueKeysWithValues: f.map { ($0.path.joined(separator: "."), $0) })
    equal(y["settings.allow-end"]?.kind, .bool, "yaml bool"); equal(y["settings.allow-end"]?.value, "true", "comment isn't part of the value")
    equal(y["settings.allow-end"]?.section, "Settings", "section from nesting")
    equal(y["spawn-limits.monsters"]?.kind, .int(nil), "yaml int"); check(y["spawn-limits.monsters"]?.help?.isEmpty == false, "known help")
    equal(y["settings.quoted"]?.value, "it's here", "single quotes read"); equal(y["settings.quoted"]?.kind, .text, "quoted is text")
    equal(y["ticks-per.autosave"]?.value, "6000", "after a comment")
    equal(y["worlds"]?.kind, .readOnly, "top-level list is read-only"); equal(y["nested.list"]?.kind, .readOnly, "nested list is read-only")
    equal(y["nested.inline"]?.kind, .readOnly, "inline list read-only"); equal(y["nested.empty"]?.kind, .readOnly, "inline map read-only")
    equal(y["nested.block"]?.kind, .readOnly, "block read-only"); check(y["nested.key"] == nil && y["nested.block.key"] == nil, "block contents aren't settings")
    equal(y["nested.after-block"]?.value, "3", "continues after a block"); equal(y["nested.ratio"]?.kind, .number, "decimal")
    equal(y["nested.fallback"]?.kind, .text, "the word default is text, as in Paper's files")
    equal(y["aliases"]?.section, "General", "top-level scalar")

    // Every edit changes exactly one line, and same-value edits change nothing.
    for field in f where field.kind != .readOnly && !field.path.contains("quoted") && !field.path.contains("dquoted") {
        equal(ConfigForm.set(field, to: field.value, in: yaml, format: .yaml), yaml, "same value is a no-op: \(field.id)")
    }
    let on = ConfigForm.set(y["settings.allow-end"]!, to: "false", in: yaml, format: .yaml)
    check(on.contains("  allow-end: false # keep\n"), "comment and indent kept")
    equal(zip(on.split(separator: "\n", omittingEmptySubsequences: false), yaml.split(separator: "\n", omittingEmptySubsequences: false)).filter { $0 != $1 }.count, 1, "exactly one line changed")
    let q = ConfigForm.set(y["settings.quoted"]!, to: "bob's", in: yaml, format: .yaml)
    check(q.contains("quoted: 'bob''s'"), "single quoting kept and escaped")
    let dq = ConfigForm.set(y["settings.dquoted"]!, to: "x\"y", in: yaml, format: .yaml)
    check(dq.contains(#"dquoted: "x\"y""#), "double quoting kept and escaped")
    // Text that YAML would misread gets quoted, and reads back as written.
    for risky in ["a: b", "true", "123", "", "#hash", "no", "- dash", "ends:", "x #y", "1.5"] {
        let out = ConfigForm.set(y["settings.shutdown-message"]!, to: risky, in: yaml, format: .yaml)
        let back = ConfigForm.fields(out, format: .yaml).first { $0.path == ["settings", "shutdown-message"] }
        equal(back?.value, risky, "text round trip: \(risky)"); equal(back?.kind, .text, "stays text: \(risky)")
    }
    check(ConfigForm.set(y["worlds"]!, to: "x", in: yaml, format: .yaml) == yaml, "read-only can't be edited")
    check(ConfigForm.fields("", format: .yaml).isEmpty && ConfigForm.fields("[]", format: .json).isEmpty, "empty and unsupported are fine")
    check(ConfigForm.fields("\tbad: tabs\n", format: .yaml).isEmpty, "tabs are left alone")
    check(!ConfigForm.supports(.json) && ConfigForm.supports(.yaml), "supported formats")

    // Player lists.
    equal(PlayerList.entries(#"[{"uuid":"1","name":"Zed","level":4},{"uuid":"2","name":"amy"}]"#), ["amy", "Zed"], "names")
    equal(PlayerList.entries(#"[{"ip":"1.2.3.4","reason":"x"}]"#), ["1.2.3.4"], "addresses"); check(PlayerList.entries("nope").isEmpty, "bad file")
    equal(PlayerList.commands(for: "ops.json")?.remove, "deop", "op commands"); equal(PlayerList.commands(for: "banned-ips.json")?.add, "ban-ip", "ip commands"); check(PlayerList.commands(for: "bukkit.yml") == nil, "others aren't lists")
    check(PlayerList.isValid("Steve_1", isAddress: false) && PlayerList.isValid(".BedrockKid", isAddress: false), "valid names")
    check(!PlayerList.isValid("a b", isAddress: false) && !PlayerList.isValid("x\nstop", isAddress: false) && !PlayerList.isValid("this_name_is_far_too_long", isAddress: false), "unsafe names refused")
    check(PlayerList.isValid("10.0.0.1", isAddress: true) && !PlayerList.isValid("1.1.1.1 stop", isAddress: true), "addresses")

    // Per-world files, in both layouts.
    let root = folder("perworld"); let paths = ServerPaths(root: root)
    write("level-name=world\n", paths.properties)
    write("x", root.appendingPathComponent("world/level.dat")); write("a: 1", root.appendingPathComponent("world/paper-world.yml"))
    write("a: 1", root.appendingPathComponent("world/dimensions/minecraft/the_nether/paper-world.yml"))
    let cfg = ConfigCatalog.scan(paths).map(\.path)
    check(cfg.contains("world/paper-world.yml"), "pre-26 per-world file"); check(cfg.contains("world/dimensions/minecraft/the_nether/paper-world.yml"), "26.x per-dimension file")

    // Plugin pages come from what's installed and what's in each folder.
    let pl = folder("plugin-pages"); let plp = ServerPaths(root: pl)
    for f in ["LuckPerms/config.yml", "LuckPerms/extra.yml", "Essentials/config.yml", "Essentials/kits.yml", "Essentials/userdata/abc.yml", "Essentials/nested/more/deep.yml", "Essentials/nested/more/too/deep.yml", "Essentials/lang/fr.yml", "Essentials/data.db", "Gone/config.yml", "Off/config.yml", "update/x.yml"] {
        write("a: 1\n", plp.plugins.appendingPathComponent(f))
    }
    func installed(_ name: String, enabled: Bool = true) -> InstalledPlugin {
        InstalledPlugin(fileName: "\(name).jar", enabled: enabled, descriptor: PluginDescriptor(name: name), digests: nil, size: 0)
    }
    let scanned = ConfigCatalog.scan(plp, plugins: [installed("LuckPerms"), installed("essentials"), installed("Off", enabled: false), installed("NoFiles")])
    func files(_ group: String) -> [String] { scanned.filter { $0.group == group }.map(\.listTitle) }
    equal(files("LuckPerms"), ["config.yml", "extra.yml"], "plugin gets its own group, main file first")
    equal(files("essentials"), ["config.yml", "kits.yml", "nested/more/deep.yml"], "folder matched regardless of case; data folders and very deep files skipped")
    equal(files("Off (disabled)"), ["config.yml"], "disabled plugins labelled")
    equal(files("Leftover plugin folders"), ["config.yml"], "no installed plugin: listed apart")
    check(!scanned.contains { $0.path.contains("/update/") }, "the update folder isn't a plugin")
    check(!scanned.contains { $0.group == "NoFiles" }, "a plugin with no files has no empty group")
    equal(scanned.last?.group, "Leftover plugin folders", "leftovers last")
    equal(ConfigCatalog.format(for: "x.toml"), .text, "other formats open as text")

    // Plugin comments become help; banners and huge headers don't.
    let commented = "##########\n# Plugin header\n##########\n\n# How often to save, in minutes.\n# Lower is safer.\nsave-interval: 5\n# \(String(repeating: "x", count: 600))\nlong: 1\n"
    let cf = ConfigForm.fields(commented, format: .yaml)
    equal(cf.first?.help, "How often to save, in minutes. Lower is safer.", "comment is help")
    check(cf.last?.help == nil, "a huge comment isn't help")

    // Controller: motd goes the usual way.
    write("server-port=25589\nmotd=old\n", root.appendingPathComponent("server.properties"))
    let c = try await ServerController.adopt(root: root, name: "Forms")
    defer { c.stopTicker() }
    c.profile.lastPluginCheck = Date(); c.profile.software.lastCheck = Date()
    equal(c.serverMessage, "old", "message read")
    equal(try c.setServerMessage("new"), .saved, "saved while stopped"); equal(c.serverMessage, "new", "message updated")
    check((try! String(contentsOf: paths.properties, encoding: .utf8)).contains("motd=new"), "on disk")
}

section("Player data format")
do {
    let sample: NBT = .compound([
        .init("DataVersion", .int(4671)), .init("XpLevel", .int(7)), .init("Health", .float(0x41A00000)), .init("Pos", .list(6, [.double(1), .double(2), .double(3)])),
        .init("Dimension", .string("minecraft:overworld")), .init("UUID", .intArray([1, 2, 3, 4])), .init("big", .long(-5)), .init("s", .short(-2)), .init("b", .byte(-1)),
        .init("bytes", .byteArray([-1, 2])), .init("longs", .longArray([9, -9])), .init("emptyList", .list(0, [])),
        .init("Inventory", .list(10, [.compound([.init("Slot", .byte(0)), .init("id", .string("minecraft:diamond")), .init("count", .int(3))]), .compound([.init("Slot", .byte(1)), .init("id", .string("minecraft:stone")), .init("Count", .byte(64))])])),
        .init("EnderItems", .list(10, [.compound([.init("Slot", .byte(0)), .init("id", .string("minecraft:elytra")), .init("count", .int(1))])])),
        .init("bukkit", .compound([.init("lastKnownName", .string("Steve"))])),
    ])
    let doc = NBT.Document(root: sample)
    let bytes = try NBT.encode(doc)
    check(Gzip.isGzip(bytes), "written gzipped")
    let back = try NBT.decode(bytes)
    equal(back, doc, "round trip keeps everything, in order")
    equal(try Gzip.decompress(try Gzip.compress(Data("hello hello hello".utf8))), Data("hello hello hello".utf8), "gzip round trip")
    // Checked against the system's gzip, so this isn't only agreeing with itself.
    let gzFile = scratch.appendingPathComponent("t.gz"); try bytes.write(to: gzFile)
    let tool = try await Tool.run("/usr/bin/gzip", ["-t", gzFile.path]); check(tool.ok, "valid gzip to the system tool: \(tool.err)")
    let summary = PlayerFiles.summary(sample)
    equal(summary.items.map(\.count), [3, 64], "both item count formats"); equal(summary.enderItems.first?.item, "minecraft:elytra", "ender chest"); equal(summary.level, 7, "level")
    equal(summary.items.first?.title, "Diamond", "readable item")
    equal(PlayerFiles.offlineUUID(name: "Notch"), "b50ad385-829d-3141-a216-7e7d7539ba7f", "offline UUID matches the known value")
    var f = sample; f["XpLevel"] = .int(9); equal(f["XpLevel"]?.intValue, 9, "edit"); f["gone"] = nil; f["new"] = .string("x"); equal(f["new"]?.stringValue, "x", "add")
    var threw = false
    do { _ = try NBT.decode(Data([10, 0])) } catch { threw = true }
    check(threw, "cut-short file refused, not crashed")
}

section("Players")
do {
    // Both layouts, Multiverse-Inventories included.
    for modern in [false, true] {
        let root = folder("players-\(modern)"); let paths = ServerPaths(root: root)
        write("level-name=world\n", paths.properties)
        write("x", root.appendingPathComponent("world/level.dat"))
        let base = modern ? "world/players" : "world"
        let dataDir = modern ? "\(base)/data" : "world/playerdata"
        let id = "069a79f4-44e9-4726-a5be-fca90e38aaf5", oldID = PlayerFiles.offlineUUID(name: "Steve")
        func dat(_ items: [(String, Int)], level: Int, name: String) throws -> NBT.Document {
            var stacks: [NBT] = []
            for (i, item) in items.enumerated() {
                let entries: [NBT.Entry] = [.init("Slot", .byte(Int8(i))), .init("id", .string(item.0)), .init("count", .int(Int32(item.1)))]
                stacks.append(.compound(entries))
            }
            let top: [NBT.Entry] = [
                .init("UUID", .intArray([0, 0, 0, 0])), .init("XpLevel", .int(Int32(level))), .init("Pos", .list(6, [.double(UInt64(level))])),
                .init("Inventory", .list(10, stacks)), .init("bukkit", .compound([.init("lastKnownName", .string(name))])),
            ]
            return NBT.Document(root: .compound(top))
        }
        try FileOps.ensureDir(root.appendingPathComponent(dataDir))
        let p = PlayerPaths(paths)
        if modern { equal(p.dataFolder.path.hasSuffix("players/data"), true, "26.x data path") } else { equal(p.dataFolder.lastPathComponent, "playerdata", "old data path") }
        try NBT.write(try dat([("minecraft:diamond", 5)], level: 10, name: "Steve"), to: p.data(id))
        write(#"[{"name":"Steve","uuid":"\#(id)","expiresOn":"2030-01-01"}]"#, root.appendingPathComponent("usercache.json"))
        write(#"{"stats":{"minecraft:custom":{"minecraft:play_time":72000,"minecraft:jump":5}},"DataVersion":1}"#, p.stats(id))
        write(#"{"minecraft:story/root":{"criteria":{"a":"2026-02-01"},"done":true},"DataVersion":1}"#, p.advancements(id))
        write(#"{"SURVIVAL":{"inventoryContents":{"0":"nether"}}}"#, p.inventories.appendingPathComponent("worlds/mining/Steve.json"))
        write(#"{"SURVIVAL":{"inventoryContents":{"0":"group"}}}"#, p.inventories.appendingPathComponent("groups/default/Steve.json"))

        let list = PlayerFiles.list(paths)
        equal(list.first?.name, "Steve", "named from usercache"); equal(list.first?.playTime, 3600, "play time")
        equal(p.inventoryContainers(name: "Steve"), ["groups/default/Steve.json", "worlds/mining/Steve.json"], "world and group inventories found")

        var profile = ServerProfile(); profile.name = "players \(modern)"
        profile.backup.destination = folder("players-backups-\(modern)").path
        // Snapshot, griefed, restored.
        let snap = try PlayerSnapshots.take(uuid: id, name: "Steve", trigger: "playing", paths: paths, profile: profile)
        equal(snap.containers.count, 2, "snapshot holds per-world data")
        try NBT.write(try dat([("minecraft:dirt", 1)], level: 99, name: "Steve"), to: p.data(id))
        write(#"{"griefed":true}"#, p.inventories.appendingPathComponent("worlds/mining/Steve.json"))
        write(#"{"griefed":true}"#, p.inventories.appendingPathComponent("groups/default/Steve.json"))
        try PlayerSnapshots.restore(snap, inventoryOnly: true, containers: ["worlds/mining/Steve.json"], paths: paths, profile: profile)
        var restored = PlayerFiles.summary(of: p.data(id))
        equal(restored?.items.first?.item, "minecraft:diamond", "inventory back"); equal(restored?.level, 99, "inventory-only keeps current XP")
        check((try String(contentsOf: p.inventories.appendingPathComponent("worlds/mining/Steve.json"), encoding: .utf8)).contains("nether"), "chosen world restored")
        check((try String(contentsOf: p.inventories.appendingPathComponent("groups/default/Steve.json"), encoding: .utf8)).contains("griefed"), "unchosen group left alone")
        try PlayerSnapshots.restore(snap, inventoryOnly: false, containers: [], paths: paths, profile: profile)
        restored = PlayerFiles.summary(of: p.data(id)); equal(restored?.level, 10, "full restore brings everything")
        // Rolling retention spares what you asked for.
        for _ in 0..<3 { try PlayerSnapshots.take(uuid: id, name: "Steve", trigger: "playing", paths: paths, profile: profile) }
        try PlayerSnapshots.take(uuid: id, name: "Steve", trigger: "manual", paths: paths, profile: profile)
        PlayerSnapshots.prune(uuid: id, keep: 2, profile: profile)
        let left = PlayerSnapshots.list(uuid: id, profile: profile)
        equal(left.filter { $0.trigger == "playing" }.count, 2, "automatic ones roll off"); equal(left.filter { $0.trigger == "manual" }.count, 1, "manual stays")

        // From a backup, without touching the world.
        let backup = try await Backups.create(profile, root: root, trigger: "manual")
        try NBT.write(try dat([("minecraft:dirt", 1)], level: 1, name: "Steve"), to: p.data(id))
        let world = try Data(contentsOf: root.appendingPathComponent("world/level.dat"))
        let extracted = try await PlayerSnapshots.fromBackup(backup, uuid: id, name: "Steve", paths: paths, profile: profile)
        equal(extracted.containers.count, 2, "per-world data from a backup")
        equal(PlayerFiles.summary(of: PlayerSnapshots.location(extracted, profile: profile).appendingPathComponent("player.dat"))?.items.first?.item, "minecraft:diamond", "the backup's inventory")
        equal(try Data(contentsOf: root.appendingPathComponent("world/level.dat")), world, "world untouched")
        check(FileOps.children(paths.meta).allSatisfy { !$0.lastPathComponent.hasPrefix("extract-") }, "temp folder removed")

        // Merge: an offline twin, with stats, advancements and a name change.
        try NBT.write(try dat([("minecraft:gold_ingot", 2)], level: 3, name: "Steve"), to: p.data(oldID))
        try NBT.write(try dat([("minecraft:diamond", 5)], level: 10, name: "Steve"), to: p.data(id))
        write(#"{"stats":{"minecraft:custom":{"minecraft:play_time":100,"minecraft:new":1}},"DataVersion":1}"#, p.stats(oldID))
        write(#"{"minecraft:story/root":{"criteria":{"a":"2020-01-01","b":"2020-01-02"},"done":false},"minecraft:other":{"criteria":{"c":"2021"},"done":true},"DataVersion":1}"#, p.advancements(oldID))
        let suggestions = PlayerMerge.suggestions(paths)
        check(suggestions.contains { $0.from.uuid == oldID && $0.to.uuid == id }, "offline twin suggested: \(suggestions.map(\.reason))")
        var plan = MergePlan(from: PlayerRef(uuid: oldID, name: "Steve"), to: PlayerRef(uuid: id, name: "Steve"))
        plan.keepFromSource = true
        let archive = scratch.appendingPathComponent("merge-archive-\(modern)")
        try PlayerMerge.apply(plan, paths: paths, archive: archive)
        check(!FileOps.exists(p.data(oldID)), "old profile merged away"); check(FileOps.exists(archive.appendingPathComponent("\(oldID).dat")), "and kept aside")
        let merged = try NBT.read(p.data(id))
        equal(PlayerFiles.summary(merged.root).items.first?.item, "minecraft:gold_ingot", "chosen inventory kept")
        equal(merged.root["UUID"], NBT.uuid(UUID(uuidString: id)!), "identifies as the profile that stays")
        let stats = try JSONSerialization.jsonObject(with: Data(contentsOf: p.stats(id))) as! [String: Any]
        let custom = (stats["stats"] as! [String: Any])["minecraft:custom"] as! [String: Int]
        equal(custom["minecraft:play_time"], 72100, "stats add up"); equal(custom["minecraft:new"], 1, "new stats kept"); equal(custom["minecraft:jump"], 5, "existing stats kept")
        let adv = try JSONSerialization.jsonObject(with: Data(contentsOf: p.advancements(id))) as! [String: Any]
        let root1 = adv["minecraft:story/root"] as! [String: Any]
        equal(root1["done"] as? Bool, true, "earned stays earned"); equal((root1["criteria"] as! [String: String])["a"], "2020-01-01", "earlier date wins"); check(adv["minecraft:other"] != nil, "both profiles' advancements")

        // Merge: a name change, which only Multiverse-Inventories notices.
        write(#"{"old":"true"}"#, p.inventories.appendingPathComponent("worlds/mining/OldName.json"))
        write(#"{"old":"only"}"#, p.inventories.appendingPathComponent("worlds/other/OldName.json"))
        let orphan = PlayerMerge.suggestions(paths).first { $0.from.name == "OldName" }
        check(orphan != nil, "orphaned name suggested")
        var rename = MergePlan(from: PlayerRef(uuid: "", name: "OldName"), to: PlayerRef(uuid: id, name: "Steve"))
        equal(PlayerMerge.conflicts(rename, paths: paths), ["worlds/mining"], "conflict found")
        rename.useOldContainer["worlds/mining"] = true
        try PlayerMerge.apply(rename, paths: paths, archive: archive)
        check((try String(contentsOf: p.inventories.appendingPathComponent("worlds/mining/Steve.json"), encoding: .utf8)).contains("true"), "chosen side of the conflict")
        check((try String(contentsOf: p.inventories.appendingPathComponent("worlds/other/Steve.json"), encoding: .utf8)).contains("only"), "no conflict, just renamed")
        check(!FileOps.exists(p.inventories.appendingPathComponent("worlds/mining/OldName.json")), "old name gone")
    }

    // Who was on.
    var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
    let day = cal.date(from: DateComponents(year: 2026, month: 3, day: 1))!
    let log = "[23:50:00] [Server thread/INFO]: Steve joined the game\n[23:50:05] [Server thread/INFO]: <Steve> Bob joined the game\n[00:10:00] [Server thread/INFO]: Steve left the game\n[01:00:00] [Server thread/INFO]: Alex joined the game\n"
    let sessions = PlayerHistory.sessions(inLog: log, day: day, calendar: cal)
    equal(sessions.count, 2, "chat can't fake a session"); equal(sessions.first?.name, "Steve", "session name")
    equal(cal.component(.day, from: sessions.first!.end!), 2, "crosses midnight"); check(sessions.last?.end == nil, "still on")
    let logRoot = folder("history"); try FileOps.ensureDir(logRoot.appendingPathComponent("logs"))
    try Gzip.compress(Data(log.utf8)).write(to: logRoot.appendingPathComponent("logs/2026-03-01-1.log.gz"))
    equal(PlayerHistory.read(ServerPaths(root: logRoot)).count, 2, "reads compressed logs")

    // Small helpers.
    equal(TPS.parse("TPS from last 1m, 5m, 15m: *20.0, 19.5, 18.25")?.fiveMinutes, 19.5, "tps parse"); check(TPS.parse("nope") == nil, "not tps")
    check(TPS.parse("TPS from last 1m, 5m, 15m: 15.0, 19, 19")?.isHealthy == false, "lag noticed")
    check(ConnectCheck.parse(Data(#"{"online":true}"#.utf8), address: "1.2.3.4:25565").reachable, "reachable"); check(!ConnectCheck.parse(Data(#"{"online":false}"#.utf8), address: "x").reachable, "not reachable")
    check(!ConnectCheck.parse(Data("garbage".utf8), address: "x").reachable, "garbage isn't reachable")
    check(DiskCheck.warning(free: 1 << 30, name: "x")?.critical == true, "critical disk"); check(DiskCheck.warning(free: 5 << 30, name: "x")?.critical == false, "low disk"); check(DiskCheck.warning(free: 100 << 30, name: "x") == nil, "plenty")
}

section("Renames: the text")
do {
    let bukkit = "settings:\n  allow-end: true\nworlds:\n  creative:\n    generator: x\n  other:\n    generator: y\nspawn-limits:\n  creative: 5\n"
    var r = RenameText.renameKey(bukkit, section: "worlds", names: ["creative": "build"])
    check(r.0.contains("worlds:\n  build:\n    generator: x"), "section key renamed"); check(r.0.contains("spawn-limits:\n  creative: 5"), "same word elsewhere untouched"); equal(r.1.count, 1, "one change")
    r = RenameText.renameKey("minecraft:creative:\n  alias: ''\nminecraft:overworld:\n  alias: ''\n", section: nil, names: ["minecraft:creative": "minecraft:build"])
    check(r.0.hasPrefix("minecraft:build:\n"), "namespaced top-level key"); check(r.0.contains("minecraft:overworld:"), "others kept")
    r = RenameText.renameKey("worlds:\n  'creative':\n    x: 1\n", section: "worlds", names: ["creative": "build"])
    check(r.0.contains("'build':"), "quoted key keeps its quotes")
    let values = "world: creative # home\nname: creative\nother-world: 'creative'\nworlds:\n- creative\n- keep\nlist: [creative, keep]\nnested:\n  world: \"creative\"\ntext: world creative here\n"
    var v = RenameText.replaceValues(values, keys: ["world", "worlds", "list"], names: ["creative": "build"])
    check(v.0.contains("world: build # home"), "comment kept"); check(v.0.contains("name: creative"), "other keys untouched")
    check(v.0.contains("other-world: 'creative'"), "similar key untouched"); check(v.0.contains("- build\n- keep"), "list item"); check(v.0.contains("[build, keep]"), "inline list")
    check(v.0.contains(#"world: "build""#), "quoted value keeps quotes"); check(v.0.contains("text: world creative here"), "prose untouched")
    v = RenameText.replaceValues("world: creative2\nworld: mycreative\n", keys: ["world"], names: ["creative": "build"])
    check(v.1.isEmpty, "partial matches never change")
    var d = RenameText.replaceDestinations("destination: 'w:creative'\ndest: e:creative:1,2,3\nnope: w:creative2\nurl: http://creative\n", names: ["creative": "build"])
    check(d.0.contains("'w:build'") && d.0.contains("e:build:1,2,3"), "destinations"); check(d.0.contains("w:creative2") && d.0.contains("http://creative"), "lookalikes untouched")
    d = RenameText.replaceAnchors("anchors:\n  home: creative:1.0,2.0,3.0:0.0:0.0\n  note: creative:notes\n", names: ["creative": "build"])
    check(d.0.contains("home: build:1.0"), "anchor"); check(d.0.contains("note: creative:notes"), "not an anchor")
    equal(RenameText.replaceToken("cd /srv/my-server && screen -S my-server; my-server2", old: "my-server", new: "x").1, 2, "whole tokens only")
    equal(ServerRename.folderFormats(for: "Sonoran Realms"), ["sonoran-realms", "sonoranrealms", "SonoranRealms", "sonoran_realms"], "name formats")
    equal(ServerRename.folderFormats(for: "sonoranRealms").first, "sonoran-realms", "from camel case"); check(ServerRename.folderFormats(for: "!!").isEmpty, "nothing usable")
    check(WorldRename.problem(with: "Build", world: nil, existing: []) != nil, "uppercase refused"); check(WorldRename.problem(with: "a b", world: nil, existing: []) != nil, "spaces refused"); check(WorldRename.problem(with: "build", world: nil, existing: []) == nil, "fine")
    check(WorldRename.problem(with: "world", world: nil, existing: [WorldEntry(name: "minecraft:world")]) != nil, "taken")
}

section("Renames: whole servers")
do {
    // A pre-26 server, with the plugins that hold world names.
    let root = folder("rename-old"); let paths = ServerPaths(root: root)
    write("level-name=main\nmotd=Hello\n", paths.properties)
    for f in ["main", "main_nether", "main_the_end", "creative"] { write("x", root.appendingPathComponent("\(f)/region/r.0.0.mca")) }
    try NBT.write(NBT.Document(root: .compound([.init("Data", .compound([.init("LevelName", .string("creative")), .init("Keep", .int(1))]))])), to: root.appendingPathComponent("creative/level.dat"))
    try NBT.write(NBT.Document(root: .compound([.init("Data", .compound([.init("LevelName", .string("main"))]))])), to: root.appendingPathComponent("main/level.dat"))
    for f in ["main_nether", "main_the_end"] { write("x", root.appendingPathComponent("\(f)/level.dat")) }
    write("worlds:\n  creative:\n    generator: VoidGen\n", root.appendingPathComponent("bukkit.yml"))
    write("world-settings:\n  default:\n    a: 1\n  creative:\n    a: 2\n", root.appendingPathComponent("spigot.yml"))
    write("minecraft:creative:\n  alias: ''\n  respawn-world: minecraft:creative\n  read-only:\n    legacy-world-name: creative\nminecraft:overworld:\n  alias: ''\n  read-only:\n    legacy-world-name: main\n", paths.plugins.appendingPathComponent("Multiverse-Core/worlds.yml"))
    write("spawn:\n  first-spawn-location: creative\n  join-destination: w:creative\n", paths.plugins.appendingPathComponent("Multiverse-Core/config.yml"))
    write("anchors:\n  home: creative:1,2,3:0:0\n", paths.plugins.appendingPathComponent("Multiverse-Core/anchors.yml"))
    write("portals:\n  p1:\n    world: creative\n    destination: w:creative\n", paths.plugins.appendingPathComponent("Multiverse-Portals/portals.yml"))
    write("groups:\n  g:\n    worlds:\n    - creative\n    - main\n", paths.plugins.appendingPathComponent("Multiverse-Inventories/groups.yml"))
    write("{}", paths.plugins.appendingPathComponent("Multiverse-Inventories/worlds/creative/Steve.json"))
    write("regions: {}", paths.plugins.appendingPathComponent("WorldGuard/worlds/creative/regions.yml"))
    write("home:\n  world: creative\n  world-name: creative\n  x: 1\n", paths.plugins.appendingPathComponent("Essentials/warps/home.yml"))
    write("homes:\n  a:\n    world: creative\nname: creative-fan\n", paths.plugins.appendingPathComponent("Essentials/userdata/abc.yml"))
    write("mention: creative\n", paths.plugins.appendingPathComponent("SomeOther/config.yml"))
    write("x", paths.plugins.appendingPathComponent("CoreProtect/config.yml"))
    let unrelated = "creative-mode: true\ncreative: 3\n"
    write(unrelated, paths.plugins.appendingPathComponent("Essentials/config.yml"))

    let c = try await ServerController.adopt(root: root, name: "Rename Test")
    defer { c.stopTicker() }
    c.profile.lastPluginCheck = Date(); c.profile.software.lastCheck = Date(); c.profile.backup.destination = folder("rename-backups").path
    await c.refreshWorlds()
    let world = c.worlds.first { $0.name == "minecraft:creative" }!
    let plan = c.worldRenamePlan(world, to: "build")
    let described = plan.items.map(\.description)
    check(plan.mentions.contains("plugins/SomeOther/config.yml"), "others are listed: \(plan.mentions)")
    check(!plan.items.contains { if case let .replaceFile(path, _) = $0.action { path == "plugins/SomeOther/config.yml" } else { false } }, "and not changed")
    check(plan.notes.contains { $0.contains("CoreProtect") }, "database limits explained")
    check(described.contains("Multiverse world list") && described.contains("WorldGuard regions and flags"), "known places found: \(described)")
    let unchangedFile = paths.plugins.appendingPathComponent("SomeOther/config.yml")

    try await c.applyRename(plan)
    func text(_ rel: String) throws -> String { try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) }
    check(FileOps.exists(root.appendingPathComponent("build/region/r.0.0.mca")) && !FileOps.exists(root.appendingPathComponent("creative")), "folder moved")
    check(try text("bukkit.yml").contains("  build:\n    generator: VoidGen"), "bukkit")
    check(try text("spigot.yml").contains("  build:\n    a: 2"), "spigot"); check(try text("spigot.yml").contains("  default:"), "spigot default kept")
    let ymlNow = try text("plugins/Multiverse-Core/worlds.yml")
    check(ymlNow.contains("minecraft:build:\n") && ymlNow.contains("respawn-world: minecraft:build"), "multiverse: \(ymlNow)"); check(ymlNow.contains("minecraft:overworld:"), "main key kept")
    check(ymlNow.contains("legacy-world-name: build"), "the name Multiverse finds the folder by"); check(ymlNow.contains("legacy-world-name: main"), "other worlds' left alone")
    check(try text("plugins/Multiverse-Core/config.yml").contains("first-spawn-location: build") && text("plugins/Multiverse-Core/config.yml").contains("w:build"), "multiverse config")
    check(try text("plugins/Multiverse-Core/anchors.yml").contains("home: build:1,2,3"), "anchors")
    check(try text("plugins/Multiverse-Portals/portals.yml").contains("world: build") && text("plugins/Multiverse-Portals/portals.yml").contains("w:build"), "portals")
    check(try text("plugins/Multiverse-Inventories/groups.yml").contains("- build\n    - main"), "groups")
    check(FileOps.exists(paths.plugins.appendingPathComponent("Multiverse-Inventories/worlds/build/Steve.json")), "inventories folder")
    check(FileOps.exists(paths.plugins.appendingPathComponent("WorldGuard/worlds/build/regions.yml")), "worldguard folder")
    check(try text("plugins/Essentials/warps/home.yml").contains("world: build\n  world-name: build"), "warps")
    let home = try text("plugins/Essentials/userdata/abc.yml"); check(home.contains("world: build") && home.contains("name: creative-fan"), "homes changed, lookalike not")
    equal(try text("plugins/Essentials/config.yml"), unrelated, "a file not on the list isn't touched")
    equal(try String(contentsOf: unchangedFile, encoding: .utf8), "mention: creative\n", "mention left alone")
    equal(try NBT.read(root.appendingPathComponent("build/level.dat")).root["Data"]?["LevelName"]?.stringValue, "build", "name in the world")
    equal(try NBT.read(root.appendingPathComponent("build/level.dat")).root["Data"]?["Keep"]?.intValue, 1, "rest of level.dat kept")
    check(c.activeUpgrade?.isRename == true, "offers undo"); check(c.backups.contains { $0.trigger == "before-upgrade" && $0.pinned }, "restore point first")
    await c.refreshWorlds()
    check(c.worlds.contains { $0.name == "minecraft:build" && $0.relativePath == "build" }, "world list agrees: \(c.worlds.map(\.name))")

    // Undo puts it all back.
    try await c.rollBackUpgrade()
    check(FileOps.exists(root.appendingPathComponent("creative/level.dat")) && !FileOps.exists(root.appendingPathComponent("build")), "undo restores the folder")
    check(try text("bukkit.yml").contains("  creative:"), "undo restores configs")
    equal(c.shelved.count, 1, "renamed state on the shelf"); try c.deleteShelved(c.shelved[0])

    // The main world, which has companions and a setting of its own.
    await c.refreshWorlds()
    let main = c.worlds.first { $0.isMain }!
    let mainPlan = c.worldRenamePlan(main, to: "home")
    try await c.applyRename(mainPlan)
    equal(PropertiesDocument(try text("server.properties")).value("level-name"), "home", "level-name")
    check(FileOps.exists(root.appendingPathComponent("home/level.dat")) && FileOps.exists(root.appendingPathComponent("home_nether")) && FileOps.exists(root.appendingPathComponent("home_the_end")), "companions move too")
    check(!FileOps.exists(root.appendingPathComponent("main")), "old main gone")
    check(try text("plugins/Multiverse-Inventories/groups.yml").contains("- home"), "group follows")
    equal(try NBT.read(root.appendingPathComponent("home/level.dat")).root["Data"]?["LevelName"]?.stringValue, "home", "main's stored name")
    check(try text("plugins/Multiverse-Core/worlds.yml").contains("minecraft:overworld:"), "minecraft:overworld stays: it isn't a name")
    check(try text("plugins/Multiverse-Core/worlds.yml").contains("legacy-world-name: home"), "main's folder name follows")
    await c.refreshWorlds()
    check(c.worlds.first { $0.isMain }?.relativePath == "home", "main world found again")
    c.keepUpgrade()

    // A failed rename leaves everything as it was.
    write("exists", root.appendingPathComponent("taken/level.dat"))
    await c.refreshWorlds()
    var doomed = RenamePlan(title: "Doomed")
    doomed.items = [
        RenameItem(action: .replaceFile(path: "bukkit.yml", text: "changed"), description: "first"),
        RenameItem(action: .moveFolder(from: "home", to: "taken"), description: "blocked"),
    ]
    let bukkitBefore = try text("bukkit.yml")
    var failure = ""
    do { try await c.applyRename(doomed) } catch { failure = error.localizedDescription }
    check(failure.contains("put back"), "reports the undo: \(failure)")
    equal(try text("bukkit.yml"), bukkitBefore, "first step undone")
    check(FileOps.exists(root.appendingPathComponent("home/level.dat")), "world still there")

    // Server rename: scripts, motd, formats, opt-in warning.
    let server = folder("My Realm"); let sp = ServerPaths(root: server)
    write("motd=Welcome to My Realm!\nlevel-name=world\n", sp.properties)
    write("x", server.appendingPathComponent("world/level.dat"))
    write("#!/bin/sh\ncd \"\(server.path)\"\nscreen -S my-realm java -jar paper.jar\n", server.appendingPathComponent("start.sh"))
    write("server: my-realm\nother: my-realm\n", sp.plugins.appendingPathComponent("LuckPerms/config.yml"))
    write("data: \(server.path)/plugins/x\n", sp.plugins.appendingPathComponent("Thing/config.yml"))
    let sc = try await ServerController.adopt(root: server, name: "My Realm")
    defer { sc.stopTicker() }
    sc.profile.lastPluginCheck = Date(); sc.profile.software.lastCheck = Date(); sc.profile.backup.destination = folder("server-rename-backups").path
    let sPlan = sc.serverRenamePlan(name: "Sonoran Realms", folder: "sonoran-realms")
    let lp = sPlan.items.first { $0.description == "LuckPerms server name" }
    check(lp?.optional == true && lp?.selected == false && lp?.warning != nil, "permissions-sensitive name is opt-in")
    try await sc.applyRename(sPlan, afterwards: { _ = try sc.rename(to: "Sonoran Realms", moveFolderTo: "sonoran-realms") })
    let moved = server.deletingLastPathComponent().appendingPathComponent("sonoran-realms")
    check(FileOps.exists(moved.appendingPathComponent("world/level.dat")), "folder renamed"); equal(sc.profile.name, "Sonoran Realms", "name")
    let script = try String(contentsOf: moved.appendingPathComponent("start.sh"), encoding: .utf8)
    check(script.contains("screen -S sonoran-realms") && script.contains("/sonoran-realms\"") , "script updated: \(script)")
    check((try String(contentsOf: moved.appendingPathComponent("server.properties"), encoding: .utf8)).contains("Welcome to Sonoran Realms!"), "motd follows")
    check((try String(contentsOf: moved.appendingPathComponent("plugins/LuckPerms/config.yml"), encoding: .utf8)).contains("server: my-realm"), "opt-in left alone unless chosen")
    check((try String(contentsOf: moved.appendingPathComponent("plugins/Thing/config.yml"), encoding: .utf8)).contains("/sonoran-realms/plugins/x"), "absolute path updated")
}

section("Cleanup")
do {
    let root = folder("cleanup"); let paths = ServerPaths(root: root)
    write("level-name=world\n", paths.properties)
    write("x", root.appendingPathComponent("world/level.dat"))
    write("x", root.appendingPathComponent("paper-1.21.11-5.jar"))
    write("x", root.appendingPathComponent("paper-1.20.1-1.jar"))
    write("x", root.appendingPathComponent("script-uses-this.jar")); write("java -jar script-uses-this.jar", root.appendingPathComponent("start.sh"))
    write("x", root.appendingPathComponent("hs_err_pid123.log")); write("x", root.appendingPathComponent("bukkit.yml.old")); write("x", root.appendingPathComponent("paper.yml")); write("x", root.appendingPathComponent("config/paper-global.yml"))
    write("x", root.appendingPathComponent("versions/1.20.1/a.jar")); write("x", root.appendingPathComponent("versions/1.21.11/a.jar"))
    write("x", root.appendingPathComponent("logs/2020-01-01-1.log.gz")); write("x", root.appendingPathComponent("logs/2026-11-01-1.log.gz")); write("x", root.appendingPathComponent("logs/latest.log"))
    write("x", root.appendingPathComponent("crash-reports/old.txt"))
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -400 * 86400)], ofItemAtPath: root.appendingPathComponent("logs/2020-01-01-1.log.gz").path)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -400 * 86400)], ofItemAtPath: root.appendingPathComponent("crash-reports/old.txt").path)
    write("x", paths.plugins.appendingPathComponent("Gone/data.yml")); write("x", paths.plugins.appendingPathComponent("Kept/data.yml"))
    write("x", paths.plugins.appendingPathComponent("old.jar.old"))
    makeJar(paths.plugins.appendingPathComponent("Kept.jar"), yaml: "name: Kept\nversion: 1\nmain: a.B\n")
    write("x", root.appendingPathComponent("abandoned_world/level.dat")); write("x", root.appendingPathComponent("loaded_world/level.dat"))
    makeJar(paths.plugins.appendingPathComponent("mv.jar"), yaml: "name: Multiverse-Core\nversion: 5.8.2\nmain: a.C\n")
    write("loaded_world:\n  alias: ''\n", paths.plugins.appendingPathComponent("Multiverse-Core/worlds.yml"))
    var profile = ServerProfile(); profile.software.jarName = "paper-1.21.11-5.jar"; profile.software.mcVersion = "1.21.11"; profile.backup.destination = folder("cleanup-backups").path
    let plugins = await PluginScanner.scan(paths)
    let items = Cleanup.scan(profile, paths: paths, plugins: plugins)
    func item(_ p: String) -> CleanupItem? { items.first { $0.path == p } }
    for safe in ["paper-1.20.1-1.jar", "hs_err_pid123.log", "bukkit.yml.old", "paper.yml", "versions/1.20.1", "logs/2020-01-01-1.log.gz", "crash-reports/old.txt", "plugins/old.jar.old"] {
        equal(item(safe)?.confidence, .safe, "known leftover: \(safe)")
    }
    equal(item("plugins/Gone")?.confidence, .review, "orphan plugin folder needs a look"); equal(item("abandoned_world")?.confidence, .review, "unmanaged world needs a look")
    for kept in ["paper-1.21.11-5.jar", "script-uses-this.jar", "versions/1.21.11", "logs/2026-11-01-1.log.gz", "logs/latest.log", "plugins/Kept", "plugins/Multiverse-Core", "world", "loaded_world", "bukkit.yml", "server.properties"] {
        check(item(kept) == nil, "protected: \(kept)")
    }
    // A leftover a config still mentions isn't suggested.
    write("groups:\n  - abandoned_world\n", paths.plugins.appendingPathComponent("Multiverse-Inventories/groups.yml"))
    check(Cleanup.scan(profile, paths: paths, plugins: plugins).first { $0.path == "abandoned_world" } == nil, "a world a config mentions stays")
    // Aside, not deleted, and it comes back.
    let moving = items.filter { $0.confidence == .safe }
    let batch = try Cleanup.apply(moving, profile: profile, paths: paths)
    check(!FileOps.exists(root.appendingPathComponent("paper-1.20.1-1.jar")), "moved"); check(FileOps.exists(Cleanup.holdingArea(profile).appendingPathComponent("\(batch.folder)/versions/1.20.1/a.jar")), "kept, with its path")
    equal(Cleanup.batches(profile).count, 1, "listed")
    try Cleanup.undo(batch, profile: profile, paths: paths)
    check(FileOps.exists(root.appendingPathComponent("versions/1.20.1/a.jar")), "brought back"); check(Cleanup.batches(profile).isEmpty, "nothing left aside")
    let again = try Cleanup.apply(Array(moving.prefix(1)), profile: profile, paths: paths)
    try Cleanup.discard(again, profile: profile); check(Cleanup.batches(profile).isEmpty, "discarded")
    var traversal = 0
    let evil = CleanupItem(path: "../outside", reason: "", size: 0, confidence: .safe)
    write("safe", root.deletingLastPathComponent().appendingPathComponent("outside"))
    traversal = try Cleanup.apply([evil], profile: profile, paths: paths).items.count
    equal(traversal, 0, "can't reach outside the server folder"); check(FileOps.exists(root.deletingLastPathComponent().appendingPathComponent("outside")), "outside untouched")
}

section("Comparing backups")
do {
    let root = folder("diff"); let paths = ServerPaths(root: root)
    write("level-name=world\nmax-players=10\nmotd=a\n", paths.properties)
    write("x", root.appendingPathComponent("world/level.dat"))
    let region = root.appendingPathComponent("world/region/r.0.0.mca")
    try FileOps.ensureDir(region.deletingLastPathComponent())
    var table = Data(count: 8192 + 100)
    try table.write(to: region)
    write("settings:\n  a: 1 # note\n", root.appendingPathComponent("bukkit.yml"))
    write("# only a comment\nb: 1\n", root.appendingPathComponent("spigot.yml"))
    write("x", root.appendingPathComponent("paper-1.21.4-1.jar"))
    try FileOps.ensureDir(paths.plugins)
    makeJar(paths.plugins.appendingPathComponent("Keep.jar"), yaml: "name: Keep\nversion: 1.0\nmain: a.B\n")
    makeJar(paths.plugins.appendingPathComponent("Gone.jar"), yaml: "name: Gone\nversion: 1.0\nmain: a.C\n")
    let id = "069a79f4-44e9-4726-a5be-fca90e38aaf5"
    func inv(_ items: [(String, Int)]) -> NBT.Document {
        var stacks: [NBT] = []
        for (i, item) in items.enumerated() {
            let entries: [NBT.Entry] = [.init("Slot", .byte(Int8(i))), .init("id", .string(item.0)), .init("count", .int(Int32(item.1)))]
            stacks.append(.compound(entries))
        }
        let top: [NBT.Entry] = [.init("Inventory", .list(10, stacks))]
        return NBT.Document(root: .compound(top))
    }
    try NBT.write(inv([("minecraft:diamond", 5), ("minecraft:stone", 1)]), to: root.appendingPathComponent("world/playerdata/\(id).dat"))
    write(#"[{"name":"Steve","uuid":"\#(id)"}]"#, root.appendingPathComponent("usercache.json"))
    var profile = ServerProfile(); profile.backup.destination = folder("diff-backups").path
    let older = try await Backups.create(profile, root: root, trigger: "manual")

    write("level-name=world\nmax-players=20\nmotd=a\nnew-one=1\n", paths.properties)
    write("settings:\n  a: 2 # note\n", root.appendingPathComponent("bukkit.yml"))
    write("# a different comment\nb: 1\n", root.appendingPathComponent("spigot.yml"))
    table.replaceSubrange(4096..<4104, with: [0, 0, 0, 9, 0, 0, 0, 7])
    try table.write(to: region)
    write("x", root.appendingPathComponent("world/region/r.1.0.mca"))
    write("x", root.appendingPathComponent("extra/level.dat"))
    try FileManager.default.removeItem(at: root.appendingPathComponent("paper-1.21.4-1.jar")); write("x", root.appendingPathComponent("paper-1.21.11-2.jar"))
    try FileManager.default.removeItem(at: paths.plugins.appendingPathComponent("Gone.jar")); try FileManager.default.removeItem(at: paths.plugins.appendingPathComponent("Keep.jar"))
    makeJar(paths.plugins.appendingPathComponent("Keep.jar"), yaml: "name: Keep\nversion: 2.0\nmain: a.B\n")
    makeJar(paths.plugins.appendingPathComponent("New.jar"), yaml: "name: New\nversion: 1.0\nmain: a.D\n")
    try NBT.write(inv([("minecraft:diamond", 2), ("minecraft:dirt", 9)]), to: root.appendingPathComponent("world/playerdata/\(id).dat"))
    let newer = try await Backups.create(profile, root: root, trigger: "manual")

    let diff = try await BackupCompare.compare(older, newer, profile: profile, paths: paths)
    func setting(_ file: String, _ key: String) -> BackupDiff.Setting? { diff.settings.first { $0.file == file && $0.key == key } }
    equal(setting("server.properties", "max-players")?.after, "20", "setting changed"); equal(setting("server.properties", "new-one")?.before, nil, "setting added")
    check(setting("server.properties", "motd") == nil, "unchanged setting not listed"); equal(setting("bukkit.yml", "settings.a")?.before, "1", "yaml setting")
    check(diff.otherSettingsFiles.contains("spigot.yml"), "comment-only change still noted")
    equal(diff.plugins.map(\.name), ["Gone", "Keep", "New"], "plugins"); equal(diff.plugins[1].after, "2.0", "upgrade"); check(diff.plugins[0].after == nil && diff.plugins[2].before == nil, "removed and added")
    check(diff.serverJar != nil, "server jar change")
    let w = diff.worlds.first { $0.name == "world" }; equal(w?.chunksChanged, 2, "chunks counted from region timestamps"); equal(w?.regionsAdded, 1, "new region")
    check(diff.worlds.contains { $0.name == "extra" && $0.added }, "new world")
    let pl = diff.players.first; equal(pl?.name, "Steve", "player named")
    equal(pl?.items.map { "\($0.item):\($0.before)>\($0.after)" }, ["minecraft:diamond:5>2", "minecraft:dirt:0>9", "minecraft:stone:1>0"], "inventory changes")
    check(FileOps.children(paths.meta).allSatisfy { !$0.lastPathComponent.hasPrefix("compare-") }, "temp folder removed")
    let none = try await BackupCompare.compare(older, older, profile: profile, paths: paths); check(none.isEmpty, "same backup: no differences")
}

section("Analytics")
do {
    equal(TickTimes.parse("◴ 1.2/0.9/3.1, 1.5/0.8/4.0, 2.5/0.7/9.9"), 2.5, "Paper's minute average")
    do {
        var soft = SoftwareState(); soft.flavor = .paper; soft.mcVersion = "1.21.11"; soft.build = 132
        var parts = DateComponents(); parts.year = 2026; parts.month = 11; parts.day = 3; parts.hour = 20; parts.minute = 15
        let when = Calendar.current.date(from: parts)!
        equal(LabFiles.saveName(date: when, software: soft, note: "Before 26 upgrade!"), "2026-11-03_20-15_paper-1.21.11-build132_before-26-upgrade.tar.gz", "save names read well")
        equal(LabFiles.saveName(date: when, software: soft, note: "../../etc"), "2026-11-03_20-15_paper-1.21.11-build132_etc.tar.gz", "notes can't reach outside the folder")
        equal(LabFiles.saveName(date: when, software: soft, note: ""), "2026-11-03_20-15_paper-1.21.11-build132.tar.gz", "the note is optional")
        func path(_ title: String, _ outcomes: [LabCheck.Outcome]) -> RehearsalPath {
            var p = RehearsalPath(title: title, route: ""); p.checks = outcomes.enumerated().map { LabCheck("c\($0.offset)", $0.element) }; return p
        }
        func verdict(_ a: [LabCheck.Outcome], _ b: [LabCheck.Outcome]) -> RehearsalReport.Verdict {
            RehearsalReport(date: Date(), serverName: "s", from: "a", to: "b", migrated: path("m", a), fresh: path("f", b)).verdict
        }
        equal(verdict([.passed, .skipped], [.passed]), .bothPassed, "pass and pass; skipped isn't failed")
        equal(verdict([.failed], [.passed]), .upgradeFailed, "only the upgrade fails")
        equal(verdict([.passed], [.failed]), .freshFailed, "only fresh fails")
        equal(verdict([.failed], [.failed]), .bothFailed, "both fail")
        equal(verdict([], [.passed]), .upgradeFailed, "no checks run is not a pass")
    }
    do { // A rename reaches Multiverse-Inventories' last world, and only exact matches.
        let r = folder("last-world")
        let players = r.appendingPathComponent("plugins/Multiverse-Inventories/players")
        write(#"{"playerData":{"lastWorld":"mining","lastKnownName":"Bob"}}"#, players.appendingPathComponent("a.json"))
        write(#"{"playerData":{"lastWorld":"mining2","lastKnownName":"mining"}}"#, players.appendingPathComponent("b.json"))
        write("x", r.appendingPathComponent("mining/level.dat"))
        let entry = WorldEntry(name: "mining", relativePath: "mining")
        let plan = WorldRename.plan(world: entry, to: "quarry", paths: ServerPaths(root: r))
        let edits = plan.items.filter { $0.description == "A player's last world" }
        equal(edits.count, 1, "only the player who was there")
        if case let .replaceFile(path, text)? = edits.first?.action {
            check(path.hasSuffix("a.json"), "the right file"); check(text.contains(#""lastWorld":"quarry""#) && text.contains("Bob"), "the last world changes: \(text)")
        } else { failures.append("no file edit") }
    }
    do { // Nether links, both as the world linked from and the world linked to.
        let r = folder("nether-links")
        let links = "plugins/Multiverse-NetherPortals/links.yml"
        write("mining:\n  nether: deep\nother:\n  nether: deep2\n", r.appendingPathComponent(links))
        write("x", r.appendingPathComponent("mining/level.dat")); write("x", r.appendingPathComponent("deep/level.dat"))
        func edited(_ plan: RenamePlan) -> String? {
            for item in plan.items { if case let .replaceFile(path, text) = item.action, path == links { return text } }
            return nil
        }
        equal(edited(WorldRename.plan(world: WorldEntry(name: "mining", relativePath: "mining"), to: "quarry", paths: ServerPaths(root: r))), "quarry:\n  nether: deep\nother:\n  nether: deep2\n", "linked from")
        let to = WorldRename.plan(world: WorldEntry(name: "deep", relativePath: "deep"), to: "abyss", paths: ServerPaths(root: r))
        equal(edited(to), "mining:\n  nether: abyss\nother:\n  nether: deep2\n", "linked to, and only that name")
        check(!to.mentions.contains(links), "no longer just a mention")
    }
    do { // Observed hanging for good with 37 plugins: blocked pool threads waiting on the pool.
        let finished = await withTimeLimit(seconds: 60) {
            await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for _ in 0..<200 { group.addTask { (try? await Tool.run("/bin/echo", ["hi"]))?.ok == true } }
                var count = 0
                for await ok in group where ok { count += 1 }
                return count
            }
        }
        equal(finished, 200, "far more tools at once than the system's shared threads")
        let many = folder("many-plugins")
        for n in 0..<120 { write("not really a jar \(n)", ServerPaths(root: many).plugins.appendingPathComponent("P\(n).jar")) }
        let scanned = await withTimeLimit(seconds: 60) { await PluginScanner.scan(ServerPaths(root: many)).count }
        equal(scanned, 120, "scanning a very large plugins folder finishes")
    }
    do { // The form Multiverse 5 really writes.
        let yaml = "minecraft:deep:\n  alias: ''\n  auto-load: true\n  difficulty: easy\n  entry-fee:\n    enabled: false\n  read-only:\n    environment: nether\n    legacy-world-name: deep\n  version: 1.3\nminecraft:mining:\n  alias: ''\n  read-only:\n    environment: normal\n"
        let worlds = Multiverse.parseWorlds(yaml)
        equal(worlds.first { $0.name == "minecraft:deep" }?.environment, "nether", "a Nether world is read as one, from read-only")
        equal(worlds.first { $0.name == "minecraft:mining" }?.environment, "normal", "and the next world keeps its own")
    }
    do { // Issues saved before a rule existed are read again when opened.
        let r = folder("old-issues"); let paths = ServerPaths(root: r)
        let now = Date()
        let old = [
            IssueRecord(id: "unknown:a", ruleID: nil, title: "No key layers in MapLike[{}]", severity: .critical, category: "Uncategorized", explanation: "", steps: [], action: nil, sample: "[10:00:00 ERROR]: No key layers in MapLike[{}]", firstSeen: now, lastSeen: now),
            IssueRecord(id: "unknown:b", ruleID: nil, title: "Something else entirely", severity: .warning, category: "Uncategorized", explanation: "", steps: [], action: nil, sample: "[10:00:00 WARN]: Something else entirely", firstSeen: now, lastSeen: now),
        ]
        try! FileOps.ensureDir(paths.meta)
        try! JSONStore.save(old, to: paths.issues)
        let c = ServerController(root: r, profile: ServerProfile())
        defer { c.stopTicker() }
        equal(c.issues.first { $0.title.contains("Routine") }?.severity, .info, "an old uncategorized issue now matches its rule")
        check(!c.issues.contains { $0.title.contains("MapLike") }, "and isn't listed twice")
        check(c.issues.contains { $0.title == "Something else entirely" }, "others are kept")
    }
    do { // Naming the plugin from a stack trace, in the form Paper really prints.
        let a = IssueAnalyzer(rules: RuleBook.builtIn)
        var d = PluginDescriptor(name: "ActionHealth"); d.main = "com.zeshanaslam.actionhealth.Main"
        a.setPlugins([InstalledPlugin(fileName: "ActionHealth-3.5.9-all.jar", enabled: true, descriptor: d, digests: nil, size: 1)])
        a.ingest("[01:19:35] [Server thread/WARN]: java.lang.ClassNotFoundException: org.bukkit.craftbukkit.craftbukkit.entity.CraftPlayer")
        a.ingest("[01:19:35] [Server thread/WARN]: \tat java.base/java.lang.Class.forName(Class.java:1)")
        a.ingest("[01:19:35] [Server thread/WARN]: \tat ActionHealth-3.5.9-all.jar//com.zeshanaslam.actionhealth.utils.HealthUtil.sendHealth(HealthUtil.java:1)")
        equal(a.sorted.first?.plugin, "ActionHealth", "the plugin in the stack trace gets the blame")
    }
    do { // Modules: on by default, remembered, and off means off.
        let store = Modules.shared
        store.reload()
        check(LeafModule.allCases.allSatisfy(store.isOn), "everything starts on")
        store.set(.history, on: false)
        check(!store.isOn(.history), "off"); check(store.isOn(.players), "only that one")
        store.reload()
        check(!store.isOn(.history), "remembered")
        let raw = try? String(contentsOf: AppPaths.home.appendingPathComponent("modules.json"), encoding: .utf8)
        check(raw?.contains("history") == true && raw?.contains("players") == false, "only what's off is stored, so a new module starts on")
        let c = ServerController(root: folder("module-history"), profile: ServerProfile())
        defer { c.stopTicker() }
        let oldCheck = Date().addingTimeInterval(-90_000)
        c.lastSizeCheck = oldCheck
        c.tickAnalytics(now: Date())
        equal(c.lastSizeCheck, oldCheck, "history off stops its background work")
        store.set(.history, on: true)
        c.tickAnalytics(now: Date())
        check(c.lastSizeCheck != oldCheck, "and on starts it")
    }
    await resourcePackChecks()
    do {
        // Names that collide on a Mac.
        let collide = folder("case-collide")
        write("online-mode=false\n", collide.appendingPathComponent("server.properties"))
        check(PlayerMerge.caseCollisions(ServerPaths(root: collide), players: []).isEmpty, "nothing to warn about with no players")
    }
    do { // Plugin links: a known source fills one in, and nothing else does.
        for bad in ["javascript:alert(1)", "file:///etc/passwd", "ftp://example.com", "https://", "not a link", "https://user:pass@example.com/", "https://me@example.com/", "https://example.com/" + String(repeating: "a", count: 3000), ""] {
            equal(PluginLinks.clean(bad), nil, "not a link: \(bad.prefix(40))")
        }
        equal(PluginLinks.clean("  https://example.com/docs \n"), "https://example.com/docs", "spaces trimmed"); equal(PluginLinks.clean("http://example.com"), "http://example.com", "plain http allowed")
        equal(PluginLink(url: "https://docs.example.com/a", origin: .typed).host, "docs.example.com", "the host is what gets shown")

        let modrinth: PluginSource = .modrinth(project: "abc", allowBeta: false)
        equal(PluginLinks.fromSource(modrinth, modrinth: ModrinthLinks(wiki: "https://w.example.com", code: "https://c.example.com")), PluginLink(url: "https://w.example.com", origin: .modrinthWiki), "wiki first")
        equal(PluginLinks.fromSource(modrinth, modrinth: ModrinthLinks(code: "https://c.example.com")), PluginLink(url: "https://c.example.com", origin: .modrinthCode), "then its source code")
        equal(PluginLinks.fromSource(modrinth, modrinth: ModrinthLinks(wiki: "javascript:alert(1)", code: "https://c.example.com"))?.origin, .modrinthCode, "a bad wiki link is skipped")
        equal(PluginLinks.fromSource(modrinth, modrinth: nil)?.url, "https://modrinth.com/plugin/abc", "before Modrinth answers, its page")
        equal(PluginLinks.fromSource(.github(repo: "o/r", assetPattern: "", prereleases: false), modrinth: nil)?.url, "https://github.com/o/r", "a GitHub repo, not its releases")
        equal(PluginLinks.fromSource(.spigot(resourceID: 7), modrinth: nil)?.url, "https://www.spigotmc.org/resources/7/", "SpigotMC page")
        equal(PluginLinks.fromSource(.hangar(project: "o/p", channel: "Release"), modrinth: nil)?.url, "https://hangar.papermc.io/o/p", "Hangar page")
        equal(PluginLinks.fromSource(.web(url: "javascript:alert(1)", linkPattern: ""), modrinth: nil), nil, "a bad source gives no link")
        equal(PluginLinks.fromSource(.none, modrinth: nil), nil, "no source, no link")

        func plugin(_ name: String, website: String? = nil, enabled: Bool = true) -> InstalledPlugin {
            var d = PluginDescriptor(name: name); d.version = "1.2"; d.website = website
            return InstalledPlugin(fileName: "\(name).jar\(enabled ? "" : ".disabled")", enabled: enabled, descriptor: d, digests: nil, size: 1)
        }
        var store = PluginLinkStore()
        store.modrinth["abc"] = ModrinthLinks(wiki: "https://w.example.com")
        let sources: [String: PluginSource] = ["known": modrinth, "typed": modrinth]
        store.chosen["typed"] = PluginLink(url: "https://mine.example.com", origin: .typed)
        let rows = PluginLinks.rows([plugin("Known"), plugin("Typed"), plugin("Site", website: "https://site.example.com"), plugin("BadSite", website: "javascript:alert(1)"), plugin("Private"), plugin("Off", enabled: false)], source: { sources[$0.key] ?? .none }, store: store)
        func row(_ key: String) -> PluginLinkRow? { rows.first { $0.key == key } }
        equal(row("known")?.link?.origin, .modrinthWiki, "a known source fills in the link"); equal(row("known")?.version, "1.2", "with its version")
        equal(row("typed")?.link?.url, "https://mine.example.com", "your choice wins")
        equal(row("site")?.link, nil, "a website field is never the link by itself"); equal(row("site")?.suggestions.first?.link.origin, .website, "it's a suggestion")
        equal(row("badsite")?.suggestions.count, 0, "a bad website isn't even suggested")
        equal(row("private")?.link, nil, "nothing known, no link"); check(row("off") == nil, "a disabled plugin isn't listed")

        let answer = #"[{"id":"AAA","slug":"some-plugin","wiki_url":"https://w.example.com","source_url":null},{"id":"BBB","wiki_url":null,"source_url":"https://c.example.com"}]"#
        let parsed = try PluginLinks.parseModrinth(Data(answer.utf8))
        equal(parsed["AAA"]?.wiki, "https://w.example.com", "by ID"); equal(parsed["some-plugin"]?.wiki, "https://w.example.com", "and by slug"); equal(parsed["BBB"]?.code, "https://c.example.com", "no slug is fine")
        let asked = try PluginLinks.modrinthAddress(["a b", "c"]).absoluteString
        check(asked.hasPrefix("https://api.modrinth.com/v2/projects?ids=") && !asked.contains(" "), "project IDs go in the address, encoded")

        let c = ServerController(root: folder("links"), profile: ServerProfile())
        equal(c.chooseLink("javascript:alert(1)", origin: .typed, forPlugin: "x"), false, "a bad link is refused"); equal(c.pluginLinkStore.chosen["x"], nil, "and not saved")
        equal(c.chooseLink("https://mine.example.com", origin: .typed, forPlugin: "x"), true, "a good one is saved"); equal(c.pluginLinkStore.chosen["x"]?.origin, .typed, "and survives reading back")
        c.clearChosenLink(forPlugin: "x"); equal(c.pluginLinkStore.chosen["x"], nil, "and can be removed")
        try await c.refreshModrinthLinks(all: true)  // No plugins, so this must not reach for the network or fail.
        c.stopTicker()
    } catch { failures.append("plugin links threw: \(error)") }
    do { // Adding players before they've joined.
        let id = "069a79f444e94726a5befca90e38aaf5", full = "069a79f4-44e9-4726-a5be-fca90e38aaf5"
        func look(_ typed: String, _ status: Int, _ body: String) -> AccountLookup.Outcome { AccountLookup.interpret(typed: typed, status: status, data: Data(body.utf8)) }
        equal(look("mAdEuP", 200, #"{"id":"\#(id)","name":"MadeUp"}"#), .found(MojangAccount(name: "MadeUp", uuid: full)), "any capitals find the real spelling and ID")
        equal(look("other", 200, #"{"id":"\#(id)","name":"MadeUp"}"#), .noAccount, "an answer for another name isn't a match")
        equal(look("x", 404, #"{"errorMessage":"Couldn't find"}"#), .noAccount, "no such account"); equal(look("x", 204, ""), .noAccount, "the older way of saying so")
        if case .unreachable = look("x", 429, "") {} else { check(false, "being rate limited isn't the same as no account") }
        if case .unreachable = look("x", 500, "") {} else { check(false, "an outage isn't the same as no account") }
        if case .unreachable = look("x", 200, "nonsense") {} else { check(false, "an unreadable answer isn't a match") }
        if case .unreachable = look("x", 200, #"{"id":"nope","name":"x"}"#) {} else { check(false, "a bad ID isn't a match") }
        for bad in ["", "a b", "semi;colon", "seventeen_letters", "new\nline", "../x"] { check(!AccountLookup.isValidName(bad), "not a name: \(bad.debugDescription)") }
        check(AccountLookup.isValidName("Made_Up1"), "a real name"); equal(AccountLookup.dashed(full), full, "an ID stays the same"); equal(AccountLookup.dashed("no"), nil, "or isn't one")
        let invalid = await AccountLookup.lookUp("bad name;")
        equal(invalid, .invalid, "a bad name is never sent")

        // What LuckPerms prints, as observed.
        equal(LuckPermsText.groupList(["[11:10:12 INFO]: [LP] Showing group entries:    (page 1 of 1 - 3 entries)", "[11:10:12 INFO]: [LP] Groups: (name, weight, tracks)", "[11:10:12 INFO]: [LP] -  default - 0", "[11:10:12 INFO]: [LP] -  made-up_one - 10"]), ["default", "made-up_one"], "groups read")
        equal(LuckPermsText.parents(["[11:10:30 INFO]: [LP] x's Parents:  (page 1 of 1 - 3 entries)", "[11:10:30 INFO]: > default ", "[11:10:30 INFO]: > madeup-one ", "[11:10:30 INFO]: Saved the game"]), ["default", "madeup-one"], "parents read, and nothing after them")
        equal(LuckPermsText.parents(["[LP] A user for x could not be found."]), nil, "no header means not known, rather than none")
        equal(LuckPermsText.pageCount(["[LP] x's Parents:  (page 2 of 3 - 40 entries)"]), 3, "pages counted")
        equal(LuckPermsText.checkResult(["[LP]     Result: true"]), .yes, "can sign in"); equal(LuckPermsText.checkResult(["[LP]     Result: false"]), .no, "can't"); equal(LuckPermsText.checkResult(["[LP]     Result: undefined"]), .noGroupGivesIt, "left to the default"); equal(LuckPermsText.checkResult(["whatever"]), .unknown, "unknown stays unknown")
        for bad in ["", "a b", "A;op me", "../x", "UPPER"] { check(!LuckPermsText.isValidGroup(bad), "not a group: \(bad)") }

        // Don't combine.
        var rules = PlayerAccessSettings()
        rules.conflicts = [["group-a", "group-b"]]
        equal(rules.warnings(adding: ["group-a", "group-b"]).count, 1, "choosing both warns")
        equal(rules.warnings(adding: ["group-a"], alreadyHas: ["group-b"]).count, 1, "and so does adding to someone who has the other")
        equal(rules.warnings(adding: ["group-a"]).count, 0, "one alone doesn't")
        equal(rules.warnings(adding: [], alreadyHas: ["group-a", "group-b"]).count, 0, "and a change that doesn't add to the pair doesn't nag")
        check(PlayerAccessSettings().grantable.isEmpty, "no group is offered until ticked")

        // Refusals, before anything reaches a console.
        let root = folder("access"), paths = ServerPaths(root: root)
        write("online-mode=true\n", paths.properties)
        write(#"[{"uuid":"\#(full)","name":"MadeUp"}]"#, root.appendingPathComponent("whitelist.json"))
        let c = ServerController(root: root, profile: ServerProfile())
        defer { c.stopTicker() }
        equal(c.playerAccessBlocked, nil, "online mode can add players")
        check(c.accessRefusal(AccessChange(uuid: "not-an-id", name: "MadeUp")) != nil, "a bad ID is refused")
        check(c.accessRefusal(AccessChange(uuid: full, name: "a; stop")) != nil, "a name can't carry a command")
        check(c.accessRefusal(AccessChange(uuid: full, name: "MadeUp", addGroups: ["group-a"])) != nil, "an unticked group is refused")
        var ticked = PlayerAccessSettings(); ticked.grantable = ["group-a", "BAD;GROUP"]; c.playerAccessSettings = ticked
        check(c.accessRefusal(AccessChange(uuid: full, name: "MadeUp", addGroups: ["BAD;GROUP"])) != nil, "even a ticked group needs a safe name")
        check(c.accessRefusal(AccessChange(uuid: full, name: "MadeUp", addGroups: ["group-a"])) != nil, "groups need LuckPerms")
        equal(c.accessRefusal(AccessChange(uuid: full, name: "MadeUp")), nil, "the allowlist alone doesn't")
        check(c.accessRefusal(AccessChange(uuid: full, name: "MadeUp", addToAllowlist: false)) != nil, "an empty change is refused")

        // A stopped server: additions wait, and removals don't have to.
        equal(c.allowlist.map(\.name), ["MadeUp"], "the list reads")
        let other = "00000000-0000-4000-8000-00000000000c"
        let held = await c.requestAccess(AccessChange(uuid: other, name: "MadeUpTwo"))
        equal(held, nil, "stopped, an addition is accepted"); equal(c.waitingAccess.map(\.name), ["MadeUpTwo"], "and waits")
        check(!c.allowlist.contains { $0.uuid == other }, "without touching the allowlist")
        let replaced = await c.requestAccess(AccessChange(uuid: other, name: "MadeUpTwo"))
        equal(replaced, nil, "asking again"); equal(c.waitingAccess.count, 1, "replaces it")
        let reopened = ServerController(root: root, profile: ServerProfile())
        defer { reopened.stopTicker() }
        equal(reopened.waitingAccess.count, 1, "and survives quitting")
        c.cancelAccess(c.waitingAccess[0].id); equal(c.waitingAccess.count, 0, "it can be cancelled")
        let removal = await c.removeFromAllowlist(AllowlistEntry(uuid: full, name: "MadeUp"))
        equal(removal, nil, "stopped, removing works"); equal(c.allowlist.count, 0, "and the file is updated")
        write("online-mode=false\n", paths.properties)
        check(c.playerAccessBlocked != nil, "offline mode can't add players")
        check(c.accessRefusal(AccessChange(uuid: full, name: "MadeUp")) != nil, "and refuses")
    }
    await linksWebChecks()
    await mapGatewayChecks()
    do { // The audit: paths that delete or move by name.
        let r = folder("audit-names")
        equal(FileOps.child("", of: r), nil, "an empty name isn't the folder itself"); equal(FileOps.child(".", of: r), nil, "nor is a dot")
        equal(FileOps.child("..", of: r), nil, "nor its parent"); equal(FileOps.child("../x.jar", of: r), nil, "no climbing out"); equal(FileOps.child("a/b.jar", of: r), nil, "no subfolders")
        equal(FileOps.child("paper.jar", of: r)?.lastPathComponent, "paper.jar", "a real name works")

        // rollbackJar with no current jar must not move the server folder anywhere.
        let server = folder("audit-rollback")
        write("level", server.appendingPathComponent("world/level.dat"))
        write("jar", ServerPaths(root: server).jarArchive.appendingPathComponent("paper-1.21.11-5.jar"))
        var profile = ServerProfile(); profile.software.jarName = ""; profile.software.mcVersion = "1.21.11"
        let c = ServerController(root: server, profile: profile)
        defer { c.stopTicker() }
        try await c.rollbackJar("paper-1.21.11-5.jar")
        check(FileOps.exists(server.appendingPathComponent("world/level.dat")), "rolling back with no jar set leaves the server where it is")
        equal(c.profile.software.jarName, "paper-1.21.11-5.jar", "and uses the jar")
        var refusedName = false
        do { try await c.rollbackJar("../evil.jar") } catch { refusedName = true }
        check(refusedName, "a jar name can't climb out of the archive")

        // Restoring the oldest kept backup: the safety copy's retention mustn't delete it first.
        let keep = folder("audit-restore")
        write("old world", keep.appendingPathComponent("world/level.dat"))
        write("x", keep.appendingPathComponent("server.properties"))
        var kept = ServerProfile()
        kept.backup.destination = keep.appendingPathComponent(".leafjuice/backups").path
        kept.backup.keepLast = 1; kept.backup.keepDays = 0
        let k = ServerController(root: keep, profile: kept)
        defer { k.stopTicker() }
        let oldest = try await Backups.create(kept, root: keep, trigger: "manual", scope: .worlds)
        write("new world", keep.appendingPathComponent("world/level.dat"))
        k.refreshBackups()
        try await k.restoreBackup(oldest)
        equal(try? String(contentsOf: keep.appendingPathComponent("world/level.dat"), encoding: .utf8), "old world", "the oldest kept backup restores, with retention at its tightest")
        check(k.backups.contains { $0.trigger == "before-restore" && $0.pinned }, "and the safety copy is kept")
        check(k.backups.contains { $0.fileName == oldest.fileName && !$0.pinned }, "and it goes back to being unpinned")

        // Retention: pinned backups don't use up the count, and what's just been made is safe.
        func made(_ name: String, daysAgo: Double, pinned: Bool = false) -> BackupRecord {
            var r = BackupRecord(fileName: name, date: Date(timeIntervalSinceNow: -daysAgo * 86_400), size: 1, scope: .worlds, trigger: "t", software: "", mcVersion: "", serverName: "", warning: nil, softwareState: nil, launch: nil)
            r.pinned = pinned
            return r
        }
        let withPins = [made("p1", daysAgo: 1, pinned: true), made("p2", daysAgo: 2, pinned: true), made("a", daysAgo: 30), made("b", daysAgo: 31), made("c", daysAgo: 32)]
        equal(Backups.prunable(withPins, keepLast: 2, keepDays: 0).map(\.fileName), ["c"], "pinned backups don't use up keep-the-latest")
        let sameInstant = Date(timeIntervalSinceNow: -100)
        var first = made("2026_manual", daysAgo: 0), second = made("2026_manual-2", daysAgo: 0)
        first.date = sameInstant; second.date = sameInstant
        equal(Backups.prunable([first, second], keepLast: 1, keepDays: 0).map(\.fileName), ["2026_manual"], "a same-second tie goes to the newer name")
        equal(Backups.prunable([first, second], keepLast: 1, keepDays: 0, protecting: "2026_manual").map(\.fileName), [], "and what's just been made is never removed")

        // Safety copies don't pile up forever.
        let piles = folder("audit-safety"); var pileProfile = ServerProfile(); pileProfile.backup.destination = piles.appendingPathComponent("b").path
        write("x", piles.appendingPathComponent("world/level.dat"))
        var made5: [BackupRecord] = []
        for _ in 0..<5 { let r = try await Backups.create(pileProfile, root: piles, trigger: "before-restore", scope: .worlds); try Backups.setPinned(r, pinned: true, profile: pileProfile); made5.append(r) }
        Backups.trimSafetyCopies(pileProfile)
        equal(Backups.list(pileProfile).filter(\.pinned).count, 3, "only the latest safety copies stay pinned"); equal(Backups.list(pileProfile).count, 5, "the rest go back to retention, not straight to deletion")

        // Databases that are named, but switched off.
        check(!Trial.usesOutsideDatabase("sql:\n  enabled: false\n  type: mysql\n  host: x\n"), "a database section that's off doesn't count")
        check(Trial.usesOutsideDatabase("sql:\n  enabled: true\n  type: mysql\n"), "one that's on does")
        check(Trial.usesOutsideDatabase("storage-method: mysql\n"), "a plain setting does")
        check(Trial.usesOutsideDatabase("storage:\n  type: mysql\nother:\n  enabled: false\n"), "another section's off switch doesn't count")
        check(!Trial.usesOutsideDatabase("storage-method: h2\n"), "local storage doesn't")

        // Test copies mustn't open the real world through a link.
        let linkedServer = folder("audit-linked-server"), realWorld = folder("audit-real-world")
        write("real", realWorld.appendingPathComponent("level.dat"))
        try FileManager.default.createSymbolicLink(at: linkedServer.appendingPathComponent("world"), withDestinationURL: realWorld)
        let cloned = linkedServer.deletingLastPathComponent().appendingPathComponent("audit-linked-copy-\(UUID().uuidString)")
        try await Trial.clone(linkedServer, to: cloned)
        check((try? FileManager.default.destinationOfSymbolicLink(atPath: cloned.appendingPathComponent("world").path)) == nil, "a linked world becomes a real folder in a copy")
        write("changed", cloned.appendingPathComponent("world/level.dat"))
        equal(try? String(contentsOf: realWorld.appendingPathComponent("level.dat"), encoding: .utf8), "real", "so changing the copy leaves the real world alone")

        // Older art under today's names.
        let rescued = ResourcePacks.rescued(["assets/minecraft/textures/block/chain.png", "assets/minecraft/textures/block/grass.png", "assets/minecraft/textures/block/short_grass.png", "assets/minecraft/textures/entity/elytra.png"])
        equal(rescued["assets/minecraft/textures/block/iron_chain.png"], "assets/minecraft/textures/block/chain.png", "a moved texture is found")
        equal(rescued["assets/minecraft/textures/block/short_grass.png"], nil, "and a pack's own copy under the new name wins")
        equal(rescued["assets/minecraft/textures/entity/equipment/wings/elytra.png"], "assets/minecraft/textures/entity/elytra.png", "entity moves too")

        // A linked world goes into the backup as its contents, and a restore leaves the original alone.
        let linkRoot = folder("audit-links"), elsewhere = folder("audit-elsewhere")
        write("real", elsewhere.appendingPathComponent("level.dat"))
        write("x", linkRoot.appendingPathComponent("server.properties"))
        try FileManager.default.createSymbolicLink(at: linkRoot.appendingPathComponent("linked"), withDestinationURL: elsewhere)
        var linkProfile = ServerProfile(); linkProfile.backup.destination = linkRoot.appendingPathComponent(".leafjuice/backups").path
        let linked = try await Backups.create(linkProfile, root: linkRoot, trigger: "manual", scope: .everything)
        check(linked.warning?.contains("linked") == true, "a linked folder is mentioned: \(linked.warning ?? "no warning")")
        let listedLink = try await Tool.run("/usr/bin/tar", ["-tzf", Backups.destination(linkProfile).appendingPathComponent(linked.fileName).path])
        check(listedLink.out.contains("linked/level.dat"), "and its contents are in the archive: \(listedLink.out.prefix(200))")
        try await Backups.restore(linked, profile: linkProfile, root: linkRoot)
        equal(try? String(contentsOf: linkRoot.appendingPathComponent("linked/level.dat"), encoding: .utf8), "real", "a restore brings them back")
        check(FileOps.exists(elsewhere.appendingPathComponent("level.dat")), "and leaves the original where it was")

        // A process with this server's old number isn't this server unless it's in this folder.
        let live = folder("audit-pid")
        let liar = ServerController(root: live, profile: ServerProfile())
        defer { liar.stopTicker() }
        equal(SystemInfo.workingDirectory(pid: getpid())?.standardizedFileURL.resolvingSymlinksInPath().path, URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.resolvingSymlinksInPath().path, "a process's folder can be read")

        // Unreadable settings are said out loud.
        let broken = folder("audit-corrupt")
        write("{ this is not json", ServerPaths(root: broken).profile)
        let reopened = ServerController.open(root: broken)
        defer { reopened?.stopTicker() }
        check(reopened?.notice?.contains("couldn't be read") == true, "corrupt settings get a notice: \(reopened?.notice ?? "none")")
        check(FileOps.exists(ServerPaths(root: broken).profile.appendingPathExtension("corrupt")), "and the file is kept")

        // Stack lines are attached to their issue, without being scanned as issues themselves.
        let a = IssueAnalyzer(rules: RuleBook.builtIn)
        a.ingest("[10:00:00 ERROR]: Something broke")
        a.ingest("[10:00:00 ERROR]: \tat org.bukkit.craftbukkit.Could.not.load(Fake.java:1)")
        equal(a.sorted.count, 1, "a stack line doesn't become its own issue")
        let cause = IssueAnalyzer(rules: RuleBook.builtIn)
        cause.ingest("[10:00:00 ERROR]: Could not do the thing")
        cause.ingest("[10:00:00 ERROR]: Caused by: java.lang.UnsupportedClassVersionError: Foo has been compiled by a more recent version of the Java Runtime")
        check(cause.sorted.contains { $0.isKnown && $0.category != "Uncategorized" }, "a Caused by line still gets diagnosed: \(cause.sorted.map(\.title))")
    } catch { failures.append("audit threw: \(error)") }
    do { // A second backup location.
        let r = folder("mirror-server"), second = folder("mirror-second").appendingPathComponent("copies", isDirectory: true)
        write("the world", r.appendingPathComponent("world/level.dat"))
        var p = ServerProfile(); p.backup.destination = r.appendingPathComponent(".leafjuice/backups").path; p.backup.mirror = second.path; p.backup.keepLast = 2; p.backup.keepDays = 0
        let c = ServerController(root: r, profile: p)
        defer { c.stopTicker() }
        var alerts: [String] = []
        c.onAlert = { title, _ in alerts.append(title) }
        let first = try await c.backupNow(trigger: "manual", scope: .worlds)
        check(FileOps.exists(second.appendingPathComponent(first.fileName)), "a backup is copied to the second location")
        equal(try Hashing.digests(of: second.appendingPathComponent(first.fileName)).sha1, try Hashing.digests(of: Backups.destination(c.profile).appendingPathComponent(first.fileName)).sha1, "and it's the same file")
        equal(Backups.list(c.profile, in: second).map(\.fileName), [first.fileName], "and it lists there")
        check(c.profile.backup.lastMirrored != nil, "and when is remembered"); check(!FileOps.children(second).contains { $0.lastPathComponent.hasSuffix(".part") }, "with no working files left")
        try await Backups.mirror(first, profile: c.profile, to: second)
        equal(Backups.list(c.profile, in: second).count, 1, "copying again changes nothing")
        for _ in 0..<3 {
            try await Task.sleep(for: .seconds(1.1))
            _ = try await c.backupNow(trigger: "manual", scope: .worlds)
        }
        equal(Backups.list(c.profile, in: second).map(\.fileName).count, 2, "the second location keeps the same number: \(Backups.list(c.profile, in: second).map { "\($0.fileName) \($0.pinned)" }) main \(Backups.list(c.profile).map(\.fileName))")

        // The main drive dying: the copies bring everything back.
        try FileManager.default.removeItem(at: Backups.destination(c.profile))
        let stranded = Backups.onlyInMirror(c.profile, folder: second)
        equal(stranded.count, 2, "copies found when the main ones are gone")
        for record in stranded { try await Backups.copyBack(record, profile: c.profile, from: second) }
        c.refreshBackups()
        equal(c.backups.count, 2, "and copied back"); write("broken", r.appendingPathComponent("world/level.dat"))
        try await Backups.restore(c.backups[0], profile: c.profile, root: r)
        equal(try? String(contentsOf: r.appendingPathComponent("world/level.dat"), encoding: .utf8), "the world", "and they restore")

        // A second location that's gone must not cost the backup.
        c.profile.backup.mirror = "/nonexistent-volume-\(UUID().uuidString)/copies"
        let survived = try await c.backupNow(trigger: "manual", scope: .worlds)
        check(FileOps.exists(Backups.destination(c.profile).appendingPathComponent(survived.fileName)), "a missing second location doesn't fail the backup")
        check(c.issues.contains { $0.ruleID == "wrapper-mirror" }, "it's reported"); equal(alerts, ["A backup wasn't copied"], "and raises an alert")
        check(FileOps.sameVolume(r, second), "same drive is noticed"); check(!FileOps.sameVolume(r, URL(fileURLWithPath: "/dev")), "another isn't")
        var corrupt = survived; corrupt.fileName = "missing.tar.gz"
        var refused = false
        do { try await Backups.mirror(corrupt, profile: c.profile, to: second) } catch { refused = true }
        check(refused, "a missing original is refused")

        // The same name and size must not pass for the same backup.
        let same1 = folder("mirror-same"), sameSecond = folder("mirror-same-second")
        write("aaaa", same1.appendingPathComponent("world/level.dat"))
        var sameProfile = ServerProfile(); sameProfile.backup.destination = same1.appendingPathComponent(".leafjuice/backups").path
        let reused = try await Backups.create(sameProfile, root: same1, trigger: "manual", scope: .worlds)
        write("stale", sameSecond.appendingPathComponent(reused.fileName + ".pad"))
        let pretend = Data(repeating: 7, count: Int(reused.size))
        try pretend.write(to: sameSecond.appendingPathComponent(reused.fileName))
        try await Backups.mirror(reused, profile: sameProfile, to: sameSecond)
        equal(try Hashing.digests(of: sameSecond.appendingPathComponent(reused.fileName)).sha1, try Hashing.digests(of: Backups.destination(sameProfile).appendingPathComponent(reused.fileName)).sha1, "a different file with the same name and size gets replaced")
        func tied(_ name: String) -> BackupRecord { BackupRecord(fileName: name, date: Date(timeIntervalSince1970: 1000), size: 1, scope: .worlds, trigger: "t", software: "", mcVersion: "", serverName: "") }
        equal(Backups.prunable([tied("x_manual.tar.gz"), tied("x_manual-2.tar.gz"), tied("x_manual-3.tar.gz")], keepLast: 1, keepDays: 0).map(\.fileName), ["x_manual-2.tar.gz", "x_manual.tar.gz"], "same-second ties keep the latest attempt")

        // Names that match the wrong project.
        check(SourceProposal.Option.looksWrong(installed: "5.4.0", newest: "1.0"), "a much older release looks wrong")
        check(SourceProposal.Option.looksWrong(installed: "1.7.3-b131", newest: "1.1"), "with a build suffix too")
        check(!SourceProposal.Option.looksWrong(installed: "3.5.9", newest: "3.9.0"), "a newer one doesn't")
        check(!SourceProposal.Option.looksWrong(installed: "1.1.3", newest: "1.1.3"), "nor the same one")
        check(!SourceProposal.Option.looksWrong(installed: "5.4.0", newest: nil), "no answer isn't a verdict")

        // Alerts stay quiet where they'd only be noise.
        let copy = ServerController(root: folder("alert-copy"), profile: ServerProfile())
        defer { copy.stopTicker() }
        copy.isTrialCopy = true
        var noisy = false
        copy.onAlert = { _, _ in noisy = true }
        copy.raiseAlert("x", "y")
        check(!noisy, "test copies and the Lab don't send alerts")
    } catch { failures.append("mirror threw: \(error)") }
    do { // A port held only on 127.0.0.1, as the Lab does.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(25977).bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 1)
        check(SystemInfo.isPortBusy(25977), "a port held only on this Mac's loopback address counts as busy")
        close(fd)
        check(!SystemInfo.isPortBusy(25977), "and is free once released")
    }
    do { // Themed groups.
        func plugin(_ name: String, depends: [String] = []) -> InstalledPlugin {
            var d = PluginDescriptor(name: name); d.depend = depends
            return InstalledPlugin(fileName: "\(name).jar", enabled: true, descriptor: d, digests: nil, size: 1)
        }
        let groups = PluginThemes.batches([plugin("TARDIS"), plugin("Multiverse-Core"), plugin("Multiverse-Portals", depends: ["Multiverse-Core"]), plugin("LuckPerms"), plugin("ChestSort"), plugin("Mystery"), plugin("NeedsMystery", depends: ["Mystery2"]), plugin("Mystery2")])
        equal(groups.first?.title, "Worlds and permissions", "worlds and permissions first, because the seed needs them")
        check(groups.first?.plugins.contains { $0.name == "Multiverse-Core" } == true, "Multiverse is in it")
        equal(groups.map(\.title).last, "Everything else", "unknown plugins go last")
        equal(groups.flatMap(\.plugins).count, 8, "nobody lost or doubled")
        let many = PluginThemes.batches((1...14).map { plugin("Other\($0)") })
        equal(many.map(\.plugins.count), [6, 6, 2], "a few at a time")
        let backwards = PluginThemes.batches([plugin("ChestSort", depends: ["LaterThing"]), plugin("LaterThing")])
        equal(backwards.first?.plugins.map(\.name).sorted(), ["ChestSort", "LaterThing"], "what a plugin needs moves up to it")
        check(LabController.reachesOutside(plugin("DriveBackupV2")), "cloud backups stay out"); check(LabController.reachesOutside(plugin("BlueMap")), "web maps stay out")
        check(!LabController.reachesOutside(plugin("TARDIS")), "others run")
    }
    do { // Settings: copied, but never data, and never for an outside database.
        let from = folder("model-settings"), to = folder("lab-settings")
        let m = ServerPaths(root: from), l = ServerPaths(root: to)
        write("greeting: hi\n", m.plugins.appendingPathComponent("Friendly/config.yml"))
        write("binary", m.plugins.appendingPathComponent("Friendly/data.db"))
        write("storage-method: mysql\n", m.plugins.appendingPathComponent("Shared/config.yml"))
        write("old\n", l.plugins.appendingPathComponent("Friendly/config.yml"))
        let notes = try! LabController.copySettings(from: m, to: l, plugins: ["Friendly", "Shared", "NoFolder"])
        equal(try? String(contentsOf: l.plugins.appendingPathComponent("Friendly/config.yml"), encoding: .utf8), "greeting: hi\n", "settings copied over the fresh ones")
        check(!FileOps.exists(l.plugins.appendingPathComponent("Friendly/data.db")), "data isn't")
        check(!FileOps.exists(l.plugins.appendingPathComponent("Shared/config.yml")), "an outside database's settings aren't")
        check(notes.contains { $0.contains("Shared") }, "and it says so: \(notes)")
        // Observed: copying everything brought real players' inventories and a world list naming folders the Lab doesn't have.
        let inv = folder("inventories-plugin").appendingPathComponent("Multiverse-Inventories")
        for name in ["config.yml", "groups.yml", "playernames.json", "worlds/creative/Steve.json", "groups/default/Steve.json", "players/abc.json"] { write("x", inv.appendingPathComponent(name)) }
        equal(LabController.settingsToCopy(in: inv), ["config.yml"], "only the behavior, not players or worlds")
        let core = folder("core-plugin").appendingPathComponent("Multiverse-Core")
        for name in ["config.yml", "worlds.yml"] { write("x", core.appendingPathComponent(name)) }
        equal(LabController.settingsToCopy(in: core), ["config.yml"], "the real world list stays behind")
        let other = folder("other-plugin").appendingPathComponent("Friendly")
        for name in ["config.yml", "language/en.yml", "worlds.yml", "data/saved.yml"] { write("x", other.appendingPathComponent(name)) }
        equal(Set(LabController.settingsToCopy(in: other)), ["config.yml", "language/en.yml", "worlds.yml"], "another plugin's worlds.yml is only skipped by name for Multiverse")
        func batch(_ fresh: LabCheck.Outcome, _ settings: LabCheck.Outcome?) -> MirrorBatch.Outcome {
            var b = MirrorBatch(title: "t", plugins: []); b.fresh = [LabCheck("a", fresh)]; b.withSettings = settings.map { [LabCheck("a", $0)] }; return b.outcome
        }
        // The board's locks. Runs nothing: results are placed directly.
        do {
            let base = folder("board")
            let earlier = getenv("LEAFJUICE_SERVERS").map { String(cString: $0) }
            setenv("LEAFJUICE_SERVERS", base.path, 1)
            defer { if let earlier { setenv("LEAFJUICE_SERVERS", earlier, 1) } else { unsetenv("LEAFJUICE_SERVERS") } }
            let c = ServerController(root: folder("board-model"), profile: ServerProfile())
            defer { c.stopTicker() }
            let lab = LabController()
            equal(lab.light(.plugins, model: c), .ready, "the first switch is ready")
            if case .locked = lab.light(.settings, model: c) { passed += 1 } else { failures.append("settings should be locked") }
            if case .locked = lab.light(.upgrade, model: c) { passed += 1 } else { failures.append("upgrade should be locked") }
            lab.place(.plugins, outcome: .passed, model: c)
            equal(lab.light(.plugins, model: c), .passed, "green"); equal(lab.light(.settings, model: c), .ready, "green unlocks settings")
            if case let .locked(why) = lab.light(.upgrade, model: c) { equal(why, "Choose a version", "upgrade still needs a version") } else { failures.append("no version chosen") }
            lab.chooseTarget(SoftwareBuild(flavor: .paper, mcVersion: "26.3", build: 1, channel: "STABLE", downloadURL: "https://x", fileName: "p.jar", hashes: ExpectedHashes()))
            equal(lab.light(.upgrade, model: c), .ready, "a version unlocks upgrade")
            lab.place(.upgrade, outcome: .failed, model: c)
            equal(lab.light(.fresh, model: c), .ready, "a failed upgrade still unlocks fresh, because the pair is the diagnosis")
            if case .locked = lab.light(.freshSettings, model: c) { passed += 1 } else { failures.append("fresh settings should wait") }
            lab.place(.plugins, outcome: .failed, model: c)
            equal(lab.light(.plugins, model: c), .failed(acknowledged: false), "red")
            if case .locked = lab.light(.settings, model: c) { passed += 1 } else { failures.append("red locks what's below") }
            lab.continueAnyway(.plugins)
            equal(lab.light(.plugins, model: c), .failed(acknowledged: true), "stays red after continuing")
            equal(lab.light(.settings, model: c), .ready, "but what's below unlocks")
            c.profile.software.mcVersion = "1.21.11"
            equal(lab.light(.plugins, model: c), .stale, "a change makes the light out of date")
            lab.clear(.plugins)
            equal(lab.light(.plugins, model: c), .ready, "flicking off clears it")
            equal(lab.result(.upgrade), nil, "and what relied on it")
        }
        equal(batch(.passed, nil), .passed, "fresh only"); equal(batch(.passed, .passed), .passed, "both")
        equal(batch(.failed, nil), .pluginProblem, "fails fresh is the plugin"); equal(batch(.passed, .failed), .settingsProblem, "fails only with settings is the settings")
    }
    do { // Restores that would surprise.
        let r = folder("snapshot-guards"); let paths = ServerPaths(root: r)
        var profile = ServerProfile(); profile.backup.destination = r.appendingPathComponent("b").path
        let id = "11111111-2222-3333-4444-555555555555"
        func player(_ dim: String, _ version: Int32) -> NBT.Document {
            var root = NBT.compound([]); root["Dimension"] = .string(dim); root["DataVersion"] = .int(version)
            return NBT.Document(root: root)
        }
        let live = PlayerPaths(paths).data(id)
        try! FileOps.ensureDir(live.deletingLastPathComponent())
        try! NBT.write(player("minecraft:overworld", 4671), to: live)
        let snap = PlayerSnapshot(folder: "s", uuid: id, name: "Alice", date: Date(), trigger: "manual", containers: [])
        let at = PlayerSnapshots.location(snap, profile: profile); try! FileOps.ensureDir(at)
        try! NBT.write(player("minecraft:mining", 4671), to: at.appendingPathComponent("player.dat"))
        equal(PlayerSnapshots.crossWorld(snap, paths: paths, profile: profile)?.taken, "mining", "another world is noticed")
        check(!PlayerSnapshots.isFromNewerVersion(snap, paths: paths, profile: profile), "same version is fine")
        try! NBT.write(player("minecraft:overworld", 5023), to: at.appendingPathComponent("player.dat"))
        check(PlayerSnapshots.crossWorld(snap, paths: paths, profile: profile) == nil, "same world isn't")
        check(PlayerSnapshots.isFromNewerVersion(snap, paths: paths, profile: profile), "a snapshot from a newer version is refused")
    }
    equal(TPS.parse("TPS from last 5s, 1m, 5m, 15m: 20.0, 19.9, 19.8, 19.7")?.oneMinute, 19.9, "Purpur's four figures")
    equal(TPS.parse("TPS from last 5s, 1m, 5m, 15m: 20.0, 19.9, 19.8, 19.7")?.fifteenMinutes, 19.7, "Purpur's 15m")
    equal(TPS.parse("TPS from last 1m, 5m, 15m: *20.0, 19.5, 18.25")?.oneMinute, 20, "Paper's three figures")
    equal(ParsedLogLine("[23:01:14 INFO]: System chat: Saved the game").message, "Saved the game", "26.x label removed")
    equal(ParsedLogLine("[23:04:09] [Server thread/INFO]: System chat: Alice joined the game").message, "Alice joined the game", "26.x label, vanilla format")
    check(ConsoleText.clean("> mspt") == nil, "26.x command echo dropped"); equal(ConsoleText.clean("[23:01:25 INFO]: > hello"), "[23:01:25 INFO]: > hello", "real lines kept")
    check(TickTimes.isVanillaExtra("Percentiles: P50: 1.7ms P95: 2.7ms"), "vanilla extras")
    do { let a = IssueAnalyzer(rules: RuleBook.builtIn)
        for line in ["[23:00:00 WARN]: **** SERVER IS RUNNING IN OFFLINE/INSECURE MODE!", "[23:00:00 WARN]: To change this, set \"online-mode\" to \"true\" in the server.properties file.", "[23:00:00 WARN]: While this makes the game possible to play without internet access, it also opens up the ability for hackers to connect", "[23:00:00 WARN]: *************************************************************************************", "[23:00:00 WARN]: You are running the latest build for your Minecraft version (1.21.11)", "[23:00:00 WARN]: However, you are 6 release(s) behind the latest stable release (26.3)!", "[23:00:00 WARN]: It is recommended that you update as soon as possible", "[23:00:00 WARN]: https://papermc.io/downloads/paper"] { a.ingest(line) }
        equal(a.sorted.filter { !$0.isKnown }.map(\.title), [], "banners group into one issue each"); equal(a.sorted.count, 2, "offline-mode and version") }
    do { let a = IssueAnalyzer(rules: RuleBook.builtIn)
        a.ingest("[23:00:00 WARN]: [ModernPluginLoadingStrategy] Could not load plugin 'Hollow.jar' in folder 'plugins/.paper-remapped'")
        equal(a.sorted.first?.title, "Hollow failed to load", "modern plugin error names the plugin") }
    do { let r = folder("folia-world"); write("x", r.appendingPathComponent("world/region/r.0.0.mca")); write("x", r.appendingPathComponent("notes/a.txt"))
        equal(Backups.worldFolders(r), ["world"], "a world with no level.dat yet still counts") }
    equal(TickTimes.parse("Average time per tick: 3.2ms (Target: 50.0ms)"), 3.2, "vanilla tick query"); check(TickTimes.parse("hello 1.2") == nil, "not tick times")
    check(TickTimes.isHeader("Server tick times (avg/min/max) from last 5s, 10s, 1m:"), "header")
    equal(GCLog.longestPause(in: "[2026][1.0s] GC(1) Pause Young (Normal) (G1 Evacuation Pause) 100M->50M(200M) 12.345ms\n[2026][2.0s] GC(2) Pause Young 90M->50M(200M) 250.5ms\n[3s] GC(3) Concurrent Mark 900.0ms\n"), 250.5, "longest pause, not concurrent work")
    check(GCLog.longestPause(in: "nothing") == nil, "no pauses")
    var l = LaunchConfig(); l.preset = .none; var sw = SoftwareState(); sw.jarName = "p.jar"
    check(LaunchCommand.arguments(l, software: sw, javaMajor: 21).contains { $0.hasPrefix("-Xlog:gc") }, "GC log on modern Java")
    check(!LaunchCommand.arguments(l, software: sw, javaMajor: 8).contains { $0.hasPrefix("-Xlog") }, "not on Java 8")
    l.logGC = false; check(!LaunchCommand.arguments(l, software: sw, javaMajor: 21).contains { $0.hasPrefix("-Xlog") }, "can be off")
    equal(JoinFailures.parse("Steve lost connection: You are not whitelisted on this server!")?.name, "Steve", "allowlist")
    check(JoinFailures.parse("Steve lost connection: You are not whitelisted on this server!")?.meaning.contains("allowlist") == true, "explained")
    equal(JoinFailures.parse("Disconnecting Steve (/1.2.3.4:5000): You are banned from this server.")?.name, "Steve", "banned")
    check(JoinFailures.parse("Steve lost connection: Disconnected") == nil, "ordinary leaving isn't a refusal")
    check(JoinFailures.parse("Steve lost connection: Timed out", online: ["Steve"]) == nil, "someone who got in wasn't refused")
    check(JoinFailures.parse("Random line about a banned thing") == nil, "only real disconnects")
    // Storage.
    let hroot = folder("history-files"); let hp = ServerPaths(root: hroot)
    let now = Date()
    History.record(ServerEvent(date: now, kind: .crash, title: "Crashed"), paths: hp)
    History.record(ServerEvent(date: now, kind: .start, title: "Started"), paths: hp)
    equal(History.read(ServerEvent.self, from: History.events(hp)).map(\.kind), [.crash, .start], "timeline persists in order")
    History.record(MetricSample(date: now, tps: 19.5, mspt: 12, memoryMB: 2000, players: 3), paths: hp)
    equal(History.read(MetricSample.self, from: History.samples(hp)).first?.players, 3, "metrics persist")
    let big = hroot.appendingPathComponent("big.jsonl")
    for i in 0..<30 { History.append(ServerEvent(date: now, kind: .stop, title: "\(i)"), to: big, limit: 5) }
    check(History.read(ServerEvent.self, from: big).count < 30, "files trim themselves"); equal(History.read(ServerEvent.self, from: big).last?.title, "29", "newest kept")
    // Trends.
    func day(_ n: Double, free: Int64) -> DailySizes { DailySizes(date: now.addingTimeInterval(n * 86_400), worldBytes: 0, backupBytes: 0, freeBytes: free) }
    let g = Int64(1 << 30)
    equal(Trend.daysUntilFull([day(0, free: 100 * g), day(5, free: 90 * g), day(10, free: 80 * g)]), 40, "forecast"); check(Trend.daysUntilFull([day(0, free: 80 * g), day(5, free: 90 * g), day(10, free: 100 * g)]) == nil, "not falling"); check(Trend.daysUntilFull([day(0, free: 1)]) == nil, "too soon")
    var hourSamples: [MetricSample] = []
    var cal2 = Calendar(identifier: .gregorian); cal2.timeZone = TimeZone(identifier: "UTC")!
    let start = cal2.date(from: DateComponents(year: 2026, month: 1, day: 1))!
    for i in 0..<300 { let d = start.addingTimeInterval(Double(i) * 300); hourSamples.append(MetricSample(date: d, players: cal2.component(.hour, from: d) == 4 ? 0 : 5)) }
    equal(Trend.quietestHour(hourSamples, calendar: cal2), 4, "quiet hour"); check(Trend.quietestHour(Array(hourSamples.prefix(5))) == nil, "needs a day of data")
    let trendEvents = [ServerEvent(date: now, kind: .crash, title: "c"), ServerEvent(date: now, kind: .start, title: "s"), ServerEvent(date: now.addingTimeInterval(-90 * 86_400), kind: .crash, title: "old")]
    equal(Trend.uptime(trendEvents, since: now.addingTimeInterval(-86_400)).crashes, 1, "only the period")
    // Stats and regulars.
    let sroot = folder("stats-files"); let sp2 = ServerPaths(root: sroot)
    write("level-name=world\n", sp2.properties); write("x", sroot.appendingPathComponent("world/level.dat"))
    let aid = "069a79f4-44e9-4726-a5be-fca90e38aaf5", bid = "aaaaaaaa-44e9-4726-a5be-fca90e38aaf5"
    write(#"[{"name":"Ann","uuid":"\#(aid)"},{"name":"Ben","uuid":"\#(bid)"}]"#, sroot.appendingPathComponent("usercache.json"))
    write(#"{"stats":{"minecraft:custom":{"minecraft:play_time":144000,"minecraft:deaths":3,"minecraft:walk_one_cm":100000,"minecraft:sprint_one_cm":100000},"minecraft:mined":{"minecraft:stone":10,"minecraft:dirt":5}},"DataVersion":1}"#, sroot.appendingPathComponent("world/stats/\(aid).json"))
    write(#"{"stats":{"minecraft:custom":{"minecraft:play_one_minute":72000,"minecraft:deaths":9}},"DataVersion":1}"#, sroot.appendingPathComponent("world/stats/\(bid).json"))
    let stats = PlayerStatsReader.read(sp2)
    let play = PlayerStat.all.first { $0.id == "play" }!, deaths = PlayerStat.all.first { $0.id == "deaths" }!, mined = PlayerStat.all.first { $0.id == "mined" }!, walked = PlayerStat.all.first { $0.id == "walked" }!
    equal(PlayerStatsReader.leaderboard(stats, stat: play).map(\.name), ["Ann", "Ben"], "time played, in both file formats"); equal(PlayerStatsReader.leaderboard(stats, stat: deaths).first?.name, "Ben", "deaths")
    equal(stats.first { $0.name == "Ann" }?.value(mined), 15, "a whole category adds up"); equal(PlayerStatsReader.leaderboard(stats, stat: mined).count, 1, "zeroes aren't on the board")
    equal(play.display(144000), "2.0 h", "hours"); equal(walked.display(200000), "2.0 km", "kilometres")
    let ago = { (d: Double) in now.addingTimeInterval(-d * 86_400) }
    let acts = Activity.summarize([
        PlayerSession(name: "New", start: ago(1), end: ago(0.9)),
        PlayerSession(name: "Reg", start: ago(20), end: ago(19.9)), PlayerSession(name: "Reg", start: ago(10), end: ago(9.9)), PlayerSession(name: "Reg", start: ago(2), end: ago(1.9)),
        PlayerSession(name: "Gone", start: ago(90), end: ago(89.9)), PlayerSession(name: "Gone", start: ago(80), end: ago(79.9)), PlayerSession(name: "Gone", start: ago(70), end: ago(69.9)),
        PlayerSession(name: "Once", start: ago(50), end: ago(49.9)),
    ], now: now)
    func status(_ n: String) -> PlayerActivity.Status? { acts.first { $0.name == n }?.status }
    equal(status("New"), .new, "new"); equal(status("Reg"), .regular, "regular"); equal(status("Gone"), .drifted, "drifted"); equal(status("Once"), .occasional, "occasional")
}

section("Backup location")
do {
    let servers = AppPaths.servers
    equal(AppPaths.backups.path, servers.path + "/LeafJuice/backups", "beside the servers")
    check(ServerProfile().backup.scope == .everything, "whole folder by default")
    equal(ServerProfile().backup.keepDays, 14, "two weeks of extras by default")
    write("x", servers.appendingPathComponent("LeafJuice/backups/a/server.properties"))
    write("x", servers.appendingPathComponent("LeafJuice/server.jar"))
    check(!ServerFolders.find(in: servers).contains { $0.lastPathComponent == "LeafJuice" }, "own folder isn't a server")

    func makeServer(_ folderName: String, _ name: String) async throws -> ServerController {
        let root = servers.appendingPathComponent(folderName, isDirectory: true)
        write("x", root.appendingPathComponent("world/level.dat"))
        write("server-port=25590\n", root.appendingPathComponent("server.properties"))
        let c = try await ServerController.adopt(root: root, name: name)
        c.profile.lastPluginCheck = Date(); c.profile.software.lastCheck = Date()
        return c
    }
    let one = try await makeServer("one", "Same/Name")
    defer { one.stopTicker() }
    let first = try await one.backupNow()
    let expected = AppPaths.backups.appendingPathComponent("Same-Name")
    equal(Backups.destination(one.profile).path, expected.path, "named after the server")
    check(FileOps.exists(expected.appendingPathComponent(first.fileName)), "archive is there")
    equal(first.scope, .everything, "whole folder")
    let listing = try await Tool.run("/usr/bin/tar", ["-tzf", expected.appendingPathComponent(first.fileName).path])
    check(listing.out.contains("server.properties") && listing.out.contains("world/level.dat"), "contains the server")

    // A same-named server stays separate, even in the same folder name.
    let two = try await makeServer("two", "Same/Name")
    defer { two.stopTicker() }
    let second = try await two.backupNow()
    equal(Backups.destination(two.profile).lastPathComponent, "Same-Name 2", "same name gets its own folder")
    check(!one.backups.contains { $0.fileName == second.fileName } || first.fileName == second.fileName, "backups don't mix")
    one.refreshBackups(); two.refreshBackups()
    equal(one.backups.count, 1, "first server sees its own"); equal(two.backups.count, 1, "second sees its own")

    // Stored once: changing the servers folder can't lose track of them.
    let pinned = one.profile.backup.destination
    setenv("LEAFJUICE_SERVERS", scratch.appendingPathComponent("elsewhere").path, 1)
    equal(Backups.destination(one.profile).path, pinned, "path stays put when the servers folder changes")
    setenv("LEAFJUICE_SERVERS", servers.path, 1)

    // Renaming takes the backups along, and an open upgrade decision with them.
    _ = try one.rename(to: "Renamed", moveFolderTo: nil)
    equal(Backups.destination(one.profile).lastPathComponent, "Renamed", "folder follows the name")
    check(!FileOps.exists(expected), "old folder gone")
    equal(one.backups.map(\.fileName), [first.fileName], "backups still listed after rename")
    _ = try one.rename(to: "Same-Name 2", moveFolderTo: nil)
    equal(Backups.destination(one.profile).lastPathComponent, "Same-Name 2 2", "rename won't take another server's folder")
    _ = try one.rename(to: "Renamed", moveFolderTo: nil)

    // A folder someone chose is left alone by renames.
    let chosen = folder("external-drive").appendingPathComponent("mc")
    try Backups.claim(chosen, for: two.profile.id)
    two.profile.backup.destination = chosen.path
    _ = try two.rename(to: "Other", moveFolderTo: nil)
    equal(Backups.destination(two.profile).path, chosen.path, "chosen folder unchanged by rename")
    two.useDefaultBackupFolder()
    equal(Backups.destination(two.profile).lastPathComponent, "Other", "use default returns to the named folder")

    // A backup must never swallow itself, if the servers folder is itself a server.
    let selfRoot = folder("self-contained")
    write("x", selfRoot.appendingPathComponent("world/level.dat"))
    write("old", selfRoot.appendingPathComponent("LeafJuice/backups/s/old.tar.gz"))
    var p = ServerProfile(); p.backup.destination = selfRoot.appendingPathComponent("LeafJuice/backups/s").path
    let inside = try await Backups.create(p, root: selfRoot, trigger: "manual")
    let selfListing = try await Tool.run("/usr/bin/tar", ["-tzf", Backups.destination(p).appendingPathComponent(inside.fileName).path])
    check(selfListing.out.contains("world/level.dat"), "the world is in it"); check(!selfListing.out.contains("LeafJuice"), "its own backups aren't")
}

section("Upgrade safety")
do {
    func installJar(_ c: ServerController, name: String, mc: String) -> SoftwareBuild {
        write("new jar \(name)", c.paths.staged.appendingPathComponent("jars/\(name)"))
        return SoftwareBuild(flavor: .paper, mcVersion: mc, build: 9, channel: "STABLE", downloadURL: "https://x", fileName: name, hashes: ExpectedHashes())
    }
    let root = folder("upgrade-server")
    write("level-name=world\nmotd=old\n", root.appendingPathComponent("server.properties"))
    write("old world", root.appendingPathComponent("world/level.dat"))
    write("old nether", root.appendingPathComponent("world_nether/level.dat"))
    write("old jar", root.appendingPathComponent("paper-1.21.4-232.jar"))
    let c = try await ServerController.adopt(root: root, name: "Upgrade")
    defer { c.stopTicker() }
    c.profile.backup.beforeUpdates = false   // A restore point must happen regardless.
    c.profile.lastPluginCheck = Date(); c.profile.software.lastCheck = Date()
    equal(c.profile.software.mcVersion, "1.21.4", "starts old")

    // 1. If the restore point can't be made, the upgrade doesn't happen.
    let blockedFile = folder("not-a-folder-parent").appendingPathComponent("file")
    write("x", blockedFile)
    c.profile.backup.destination = blockedFile.path
    var build = installJar(c, name: "paper-26.3-9.jar", mc: "26.3")
    c.enqueue(PendingChange(kind: .software(stagedFile: "jars/paper-26.3-9.jar", build: build, needsBackup: true), summary: "Up"))
    await c.applyPending()
    equal(c.profile.software.jarName, "paper-1.21.4-232.jar", "failed restore point: jar unchanged")
    check(FileOps.exists(root.appendingPathComponent("paper-1.21.4-232.jar")), "old jar still in place")
    check(c.pending.first?.conflict?.contains("restore point failed") == true, "held back with a reason: \(c.pending.first?.conflict ?? "")")
    check(c.activeUpgrade == nil, "no upgrade recorded")

    // 2. With somewhere to put it, the upgrade goes ahead, with a verified, pinned restore point.
    c.profile.backup.destination = nil
    await c.applyPending()
    equal(c.pending.count, 0, "applied: \(c.pending.map { $0.conflict ?? "" })")
    equal(c.profile.software.mcVersion, "26.3", "upgraded"); equal(c.profile.software.jarName, "paper-26.3-9.jar", "new jar")
    let active = c.activeUpgrade
    check(active != nil, "awaiting a decision")
    equal(active?.from.mcVersion, "1.21.4", "knows where it came from")
    let point = c.backups.first { $0.fileName == active?.backupFile }
    equal(point?.pinned, true, "restore point pinned"); equal(point?.trigger, "before-upgrade", "labelled")
    check(ServerController.open(root: root).map { let u = $0.activeUpgrade; $0.stopTicker(); return u != nil } == true, "decision survives a relaunch")

    // Verification really checks contents.
    var wrong = false
    do { try await Backups.verify(point!, in: Backups.destination(c.profile), expectingWorlds: ["world", "world_nether"]) } catch { wrong = true }
    check(!wrong, "restore point holds every world")
    do { try await Backups.verify(point!, in: Backups.destination(c.profile), expectingWorlds: ["nope"]) } catch { wrong = true }
    check(wrong, "a missing world fails verification")
    let dest = Backups.destination(c.profile)
    let damaged = dest.appendingPathComponent(point!.fileName)
    let good = try Data(contentsOf: damaged)
    try Data(good.prefix(good.count / 2)).write(to: damaged)
    var caught = ""
    do { try await c.rollBackUpgrade() } catch { caught = error.localizedDescription }
    check(caught.contains("damaged"), "damaged restore point refused: \(caught)")
    check(c.activeUpgrade != nil && c.profile.software.mcVersion == "26.3", "refusal changes nothing")
    try good.write(to: damaged)

    // 3. The server moves on, then we roll back: old state returns, new state goes to the Shelf.
    write("upgraded world", root.appendingPathComponent("world/level.dat"))
    try? FileManager.default.removeItem(at: root.appendingPathComponent("world_nether"))  // As 26.x migration does.
    write("data", root.appendingPathComponent("world/dimensions/minecraft/the_nether/r.mca"))
    try await c.rollBackUpgrade()
    equal(c.profile.software.mcVersion, "1.21.4", "version restored"); equal(c.profile.software.jarName, "paper-1.21.4-232.jar", "jar setting restored"); equal(c.profile.software.build, 232, "build restored")
    equal(try! String(contentsOf: root.appendingPathComponent("world/level.dat"), encoding: .utf8), "old world", "world restored")
    equal(try! String(contentsOf: root.appendingPathComponent("world_nether/level.dat"), encoding: .utf8), "old nether", "old-style nether is back")
    equal(try! String(contentsOf: root.appendingPathComponent("paper-1.21.4-232.jar"), encoding: .utf8), "old jar", "old jar back")
    check(!FileOps.exists(root.appendingPathComponent("paper-26.3-9.jar")), "new jar gone from the server")
    check(!FileOps.exists(root.appendingPathComponent("world/dimensions")), "new layout gone")
    check(c.activeUpgrade == nil, "decision closed"); equal(c.shelved.count, 1, "on the Shelf"); equal(c.shelved.first?.label, "Paper 26.3 build 9", "shelf label")
    check(!c.backups.contains { $0.trigger == "shelved" }, "the Shelf isn't listed among backups")
    let kept = c.profile.backup.keepLast
    c.profile.backup.keepLast = 1; c.profile.backup.keepDays = 0
    Backups.prune(c.profile)
    equal(Backups.list(c.profile, in: Backups.shelf(c.profile)).count, 1, "retention leaves the Shelf alone")
    c.profile.backup.keepLast = kept; c.profile.backup.keepDays = 30
    equal((await c.preflight()).contains { $0.title.contains("doesn't match") }, false, "jar and world agree after rollback")

    // 4. Resume: the upgraded server returns, and you can still go back again.
    try await c.resumeShelved(c.shelved[0])
    equal(c.profile.software.mcVersion, "26.3", "resumed"); equal(c.profile.software.jarName, "paper-26.3-9.jar", "resumed jar")
    equal(try! String(contentsOf: root.appendingPathComponent("world/level.dat"), encoding: .utf8), "upgraded world", "upgraded world back")
    check(FileOps.exists(root.appendingPathComponent("paper-26.3-9.jar")), "upgraded jar back")
    check(c.shelved.isEmpty, "off the Shelf"); check(c.activeUpgrade != nil, "can roll back again")
    try await c.rollBackUpgrade()
    equal(c.profile.software.mcVersion, "1.21.4", "rolled back twice"); equal(c.shelved.count, 1, "on the Shelf again")
    try c.deleteShelved(c.shelved[0])
    check(c.shelved.isEmpty && Backups.list(c.profile, in: Backups.shelf(c.profile)).isEmpty, "shelf entry deleted")

    // 5. Keep: the restore point becomes an ordinary backup.
    build = installJar(c, name: "paper-1.21.11-5.jar", mc: "1.21.11")
    c.enqueue(PendingChange(kind: .software(stagedFile: "jars/paper-1.21.11-5.jar", build: build, needsBackup: true), summary: "Up"))
    await c.applyPending()
    let file = c.activeUpgrade?.backupFile
    c.keepUpgrade()
    check(c.activeUpgrade == nil, "kept")
    equal(c.backups.first { $0.fileName == file }?.pinned, false, "restore point unpinned")

    // 6. A new build isn't a major upgrade, so no restore point and no decision.
    let count = c.backups.count
    build = installJar(c, name: "paper-1.21.11-6.jar", mc: "1.21.11")
    c.profile.backup.beforeUpdates = false
    c.enqueue(PendingChange(kind: .software(stagedFile: "jars/paper-1.21.11-6.jar", build: build, needsBackup: false), summary: "Build"))
    await c.applyPending()
    equal(c.backups.count, count, "routine builds don't make restore points"); check(c.activeUpgrade == nil, "or ask for a decision")

    // 7. A jar for another version won't start, so a world can't be upgraded by accident.
    c.profile.software.mcVersion = "1.21.4"
    let mismatch = await c.preflight()
    check(mismatch.contains { $0.title.contains("doesn't match") }, "mismatched jar blocks start")
}

section("Plugin scanning")
do {
    let root = folder("scan")
    let paths = ServerPaths(root: root)
    try FileOps.ensureDir(paths.plugins)
    makeJar(paths.plugins.appendingPathComponent("foo.jar"), yaml: "name: Foo\nversion: 1.0\nmain: a.b.C\napi-version: 26.3\ndepend: [Bar]\n")
    makeJar(paths.plugins.appendingPathComponent("baz.jar.disabled"), yaml: "name: Baz\nversion: 2\nmain: a.b.D\n")
    write("not a zip", paths.plugins.appendingPathComponent("broken.jar"))
    let found = await PluginScanner.scan(paths)
    equal(found.map(\.name), ["Baz", "broken", "Foo"], "all found, sorted")
    equal(found.first { $0.name == "Foo" }?.descriptor?.apiVersion, "26.3", "descriptor read")
    equal(found.first { $0.name == "Baz" }?.enabled, false, "disabled seen")
    check(found.first { $0.name == "Foo" }?.digests != nil, "hashed")
    let problems = PluginScanner.staticProblems(found, mc: gv("1.21.4"))
    check(problems["foo.jar"]?.contains("26.3") == true, "api-version problem"); check(problems["broken.jar"] != nil, "broken flagged")
}

section("Schedule")
do {
    var s = RestartSchedule()
    s.hour = 5; s.minute = 30
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let monday = cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
    equal(cal.component(.day, from: s.next(after: monday, calendar: cal)!), 3, "next day")
    s.weekdays = [6] // Friday
    equal(cal.component(.day, from: s.next(after: monday, calendar: cal)!), 6, "weekday")
    s.weekdays = [6, 3] // Friday, Tuesday
    equal(cal.component(.day, from: s.next(after: monday, calendar: cal)!), 3, "soonest weekday")
    equal(RestartSchedule.describe(seconds: 300), "5 minutes", "describe"); equal(RestartSchedule.describe(seconds: 60), "1 minute", "one"); equal(RestartSchedule.describe(seconds: 10), "10 seconds", "secs")
}

section("Storage")
do {
    struct V1: Codable { var a = 1 }
    struct V2: Codable, Equatable { var a = 0; var b = "default" }
    let url = scratch.appendingPathComponent("store.json")
    try JSONStore.save(V1(a: 5), to: url)
    equal(JSONStore.load(url, defaults: V2()), V2(a: 5, b: "default"), "older files gain new defaults")
    write("{ nope", url)
    equal(JSONStore.load(url, defaults: V2()), V2(), "corrupt falls back")
    check(FileOps.exists(url.appendingPathExtension("corrupt")), "corrupt file set aside")
    var p = ServerProfile(); p.name = "x"; p.launch.maxMemoryMB = 123
    try JSONStore.save(p, to: url)
    equal(JSONStore.load(url, defaults: ServerProfile()), p, "profile round trip")
    let change = PendingChange(kind: .pluginInstall(name: "A", stagedFile: "b", finalName: "c", replaces: nil, upstreamID: nil), summary: "s")
    try JSONStore.save([change], to: url)
    equal(JSONStore.load(url, defaults: [PendingChange]()).first?.target, "plugin:a", "pending round trip")
}

// MARK: Live and lifecycle

if let flag = CommandLine.arguments.firstIndex(of: "--experiments") {
    guard CommandLine.arguments.contains("--i-accept-the-minecraft-eula"), flag + 1 < CommandLine.arguments.count else {
        print("--experiments <groups> needs --i-accept-the-minecraft-eula, your own acceptance of \(EULA.url).")
        exit(2)
    }
    await runExperiments(CommandLine.arguments[flag + 1].components(separatedBy: ","))
    try? FileManager.default.removeItem(at: scratch)
    exit(0)
}

if let flag = CommandLine.arguments.firstIndex(of: "--lab-model") {
    guard CommandLine.arguments.contains("--i-accept-the-minecraft-eula"), flag + 2 < CommandLine.arguments.count else {
        print("--lab-model <server folder> <minecraft version> [--with-settings] needs --i-accept-the-minecraft-eula.")
        exit(2)
    }
    await runLabModel(URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true), mc: CommandLine.arguments[flag + 2], settings: CommandLine.arguments.contains("--with-settings"))
    print("\(passed) passed, \(failures.count) failed")
    for failure in failures { print("  FAIL \(failure)") }
    exit(failures.isEmpty ? 0 : 1)
}
if CommandLine.arguments.contains("--plugin-report") {
    // What the app makes of a big real plugin set, from copies already in the sandbox. Starts nothing.
    let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".lab-sandbox", isDirectory: true)
    setenv("LEAFJUICE_HOME", base.appendingPathComponent("home").path, 1)
    setenv("LEAFJUICE_SERVERS", base.appendingPathComponent("servers").path, 1)
    let paths = ServerPaths(root: base.appendingPathComponent("servers/lab-model", isDirectory: true))
    var at = Date()
    func took(_ what: String) { print("  \(what): \(String(format: "%.2f", Date().timeIntervalSince(at)))s"); at = Date() }
    let plugins = await PluginScanner.scan(paths)
    took("scan \(plugins.count) plugins")
    print("  no descriptor: \(plugins.filter { $0.descriptor == nil }.map(\.fileName))")
    let problems = PluginScanner.staticProblems(plugins, mc: GameVersion("1.21.11"))
    print("  static problems: \(problems)")
    let configs = ConfigCatalog.scan(paths, plugins: plugins)
    took("config catalog \(configs.count) files")
    let grouped = Dictionary(grouping: configs, by: \.group).mapValues(\.count).sorted { $0.value > $1.value }
    print("  biggest groups: \(grouped.prefix(8).map { "\($0.key)=\($0.value)" })")
    print("  leftover: \(configs.filter { $0.group.lowercased().contains("leftover") }.map(\.path).prefix(8))")
    var failedForms = 0, totalFields = 0
    for file in configs where ConfigForm.supports(file.format) {
        let text = (try? String(contentsOf: paths.root.appendingPathComponent(file.path), encoding: .utf8)) ?? ""
        let fields = ConfigForm.fields(text, format: file.format)
        totalFields += fields.count
        if fields.isEmpty, !text.isEmpty { failedForms += 1 }
    }
    took("forms: \(totalFields) fields, \(failedForms) files with none")
    var noFields: [String] = []
    for file in configs where ConfigForm.supports(file.format) {
        let text = (try? String(contentsOf: paths.root.appendingPathComponent(file.path), encoding: .utf8)) ?? ""
        if ConfigForm.fields(text, format: file.format).isEmpty, !text.isEmpty { noFields.append("\(file.path) (\(text.count) chars: \(text.prefix(40).replacingOccurrences(of: "\n", with: " ")))") }
    }
    print("  no fields: \(noFields.prefix(22).joined(separator: " | "))")
    for folder in FileOps.children(paths.plugins) where FileOps.isDirectory(folder) {
        let all = ConfigCatalog.settingsFiles(in: folder, limit: 5000).count
        if all > 40 { print("  \(folder.lastPathComponent): \(all) settings files") }
    }
    let start = Date()
    let matches = await SourceFinder.modrinthMatches(sha1s: plugins.compactMap { $0.digests?.sha1 })
    print("  sources identified by hash: \(matches.count) of \(plugins.count) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
    print("  depend issues: \(plugins.flatMap { p in (p.descriptor?.depend ?? []).filter { d in !plugins.contains { $0.key == d.lowercased() } }.map { "\(p.name)->\($0)" } })")
    do {
        let c = try await ServerController.adopt(root: paths.root, name: "Model")
        await c.refreshPlugins()
        try? await Task.sleep(for: .seconds(2))
        let proposals = await c.proposeSources()
        print("  find sources: \(proposals.count) plugins, \(proposals.filter { !$0.options.isEmpty }.count) with suggestions, \(proposals.filter { $0.options.first.map { !$0.looksWrong && $0.newest != nil } ?? false }.count) with a plausible top match")
        for p in proposals { print("    \(p.plugin.name) \(p.plugin.version): \(p.options.map { "\($0.suggestion.source.summary) \($0.newest ?? "?")\($0.looksWrong ? " WRONG" : "")" })") }
        c.stopTicker()
    } catch { print("  find sources failed: \(error)") }
    print("  groups: \(PluginThemes.batches(plugins.filter { !Trial.disabledInCopies.contains($0.key) }).map { "\($0.title):\($0.plugins.count)" })")
    exit(0)
}
if CommandLine.arguments.contains("--perf") {
    // How the issue scanner copes with a spamming server, on the thread the interface also uses.
    let analyzer = IssueAnalyzer(rules: RuleBook.builtIn)
    let spam = ["[01:19:35] [Server thread/WARN]: java.lang.ClassNotFoundException: org.bukkit.craftbukkit.craftbukkit.entity.CraftPlayer"] + (0..<18).map { "[01:19:35] [Server thread/WARN]: \tat ActionHealth-3.5.9-all.jar//com.zeshanaslam.actionhealth.utils.HealthUtil.line\($0)(HealthUtil.java:\($0))" }
    let chat = ["[01:19:35] [Server thread/INFO]: <Alice> hello there", "[01:19:35] [Server thread/INFO]: Alice issued server command: /home", "[01:19:35] [Async Chat Thread/INFO]: [Multiverse-Core] Something routine happened"]
    for (title, lines) in [("error spam", spam), ("ordinary chatter", chat)] {
        let start = Date()
        var count = 0
        while count < 100_000 { for line in lines { analyzer.ingest(line); count += 1 } }
        let took = Date().timeIntervalSince(start)
        print("  \(title): \(Int(Double(count) / took)) lines a second")
    }
    exit(0)
}
if CommandLine.arguments.contains("--lab-demo") {
    // Fills the status board with example results, for looking at the screen. Never touches a real server folder.
    let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".lab-sandbox/snap", isDirectory: true)
    setenv("LEAFJUICE_HOME", base.appendingPathComponent("home").path, 1)
    setenv("LEAFJUICE_SERVERS", base.appendingPathComponent("servers").path, 1)
    guard let model = ServerController.open(root: base.appendingPathComponent("servers/Demo", isDirectory: true)) else { print("no Demo"); exit(1) }
    await model.refreshPlugins()
    let lab = LabController(existing: nil)
    lab.acceptEULA()
    let ok = ["Starts", "A player can join", "Inventory came through", "Per-world inventory came through", "Stops cleanly", "A change survives a restart"].map { LabCheck($0, .passed) }
    lab.place(.plugins, outcome: .passed, model: model, groups: [MirrorBatch(title: "Worlds and permissions", plugins: ["LuckPerms", "Multiverse-Core", "Multiverse-Inventories"], fresh: ok)], note: "Paper 1.21.11 build 132", leftOut: ["BlueMap reaches outside this Mac, so it doesn't run here."])
    var bad = MirrorBatch(title: "Everyday comforts 1", plugins: ["ActionHealth", "ChestSort"], fresh: [])
    bad.withSettings = [LabCheck("ActionHealth: A plugin doesn't match this server version (235 times)", .failed, "java.lang.ClassNotFoundException: org.bukkit.craftbukkit.craftbukkit.entity.CraftPlayer")]
    lab.place(.settings, outcome: .failed, model: model, groups: [bad], note: "World lists and player data stay the Lab's own.")
    if let build = try? await SoftwareCatalog.latestBuild(.paper, mc: "26.3") { lab.chooseTarget(build) }
    lab.place(.upgrade, outcome: .passed, model: model, checks: ok, note: "Kept the Lab's data from Paper 1.21.11 build 132, then moved it to 26.3 build 240")
    exit(0)
}
if CommandLine.arguments.contains("--lab") {
    guard CommandLine.arguments.contains("--i-accept-the-minecraft-eula") else {
        print("--lab needs --i-accept-the-minecraft-eula, your own acceptance of \(EULA.url).")
        exit(2)
    }
    await runLabScenario()
    print("\(passed) passed, \(failures.count) failed")
    for failure in failures { print("  FAIL \(failure)") }
    exit(failures.isEmpty ? 0 : 1)
}
if CommandLine.arguments.contains("--sandbox") {
    guard CommandLine.arguments.contains("--i-accept-the-minecraft-eula") else {
        print("--sandbox needs --i-accept-the-minecraft-eula, your own acceptance of \(EULA.url).")
        exit(2)
    }
    await runSandbox()
    try? FileManager.default.removeItem(at: scratch)
    print("\n\(passed) passed, \(failures.count) failed")
    for failure in failures { print("  - \(failure)") }
    exit(failures.isEmpty ? 0 : 1)
}

await runLifecycleWithStandIn()
if CommandLine.arguments.contains("--live") { await runLiveAPIs() }
if CommandLine.arguments.contains("--real-prejoin") {
    if CommandLine.arguments.contains("--i-accept-the-minecraft-eula") {
        await runRealPrejoin()
    } else {
        print("Skipping --real-prejoin: it needs --i-accept-the-minecraft-eula, your own acceptance of \(EULA.url).")
    }
}
if let flag = CommandLine.arguments.firstIndex(of: "--links-browser"), flag + 1 < CommandLine.arguments.count {
    // Serves the players' page with made-up data on localhost for two minutes, to try in a real browser.
    let root = folder("links-browser"), paths = ServerPaths(root: root)
    let player = "00000000-0000-4000-8000-00000000000a"
    write("online-mode=true\n", paths.properties)
    write(#"[{"uuid":"\#(player)","name":"MadeUp"}]"#, root.appendingPathComponent("whitelist.json"))
    let token = LinksWeb.randomSecret()
    write(#"{"uuid":"\#(player)","name":"MadeUp","expires":\#(Int(Date().timeIntervalSince1970) + 120)}"#, paths.plugins.appendingPathComponent("Latchkey/pending/\(LinksWeb.hash(token)).json"))
    let web = LinksWeb(paths: paths, settings: { LinksPageSettings() }, content: {
        LinksPageContent(serverVersion: "Paper 1.21.11", plugins: [.init(name: "MadeUpWarps", version: "2.4.1", link: "https://docs.example.com/warps"), .init(name: "MadeUpChat", version: nil, link: nil)])
    })
    web.testOrigin = "http://localhost:25591"
    let listener = LinksListener(web: web)
    try! listener.start(port: 25591)
    try! FileOps.writeAtomic("http://localhost:25591/signin#\(token)\n", to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
    print("  serving")
    try? await Task.sleep(for: .seconds(120))
    print("  log: \(web.log.map(\.kind.rawValue))")
    listener.stop()
    exit(0)
}
if let flag = CommandLine.arguments.firstIndex(of: "--real-signin"), flag + 1 < CommandLine.arguments.count {
    if CommandLine.arguments.contains("--i-accept-the-minecraft-eula") {
        await runRealSignIn(jar: CommandLine.arguments[flag + 1])
    } else {
        print("Skipping --real-signin: it needs --i-accept-the-minecraft-eula, your own acceptance of \(EULA.url).")
    }
}
if CommandLine.arguments.contains("--real-map") {
    if CommandLine.arguments.contains("--i-accept-the-minecraft-eula") {
        await runRealMap()
    } else {
        print("Skipping --real-map: it needs --i-accept-the-minecraft-eula, your own acceptance of \(EULA.url).")
    }
}
if CommandLine.arguments.contains("--real-pack") {
    if CommandLine.arguments.contains("--i-accept-the-minecraft-eula") {
        await runRealPack()
    } else {
        print("Skipping --real-pack: it needs --i-accept-the-minecraft-eula, your own acceptance of \(EULA.url).")
    }
}
if CommandLine.arguments.contains("--real-paper") {
    if CommandLine.arguments.contains("--i-accept-the-minecraft-eula") {
        await runRealPaper()
    } else {
        print("Skipping --real-paper: it needs --i-accept-the-minecraft-eula, your own acceptance of \(EULA.url).")
    }
}

/// Real Paper, LuckPerms, Multiverse and BlueMap on a throwaway server, with bots and made-up worlds: the map
/// through the sign-in page shows each player only the worlds Multiverse lets them enter.
@MainActor func runRealMap() async {
    section("REAL MAP BEHIND SIGN-IN (EULA accepted by the person running this)")
    do {
        let port = 25593, pagePort = 28795, mapPort = 28100
        let root = folder("real-map")
        write("server-port=\(port)\nonline-mode=false\nnetwork-compression-threshold=-1\nview-distance=3\nsimulation-distance=3\nlevel-type=minecraft\\:flat\nspawn-protection=0\n", root.appendingPathComponent("server.properties"))
        let c = try await ServerController.adopt(root: root, name: "real-map")
        try EULA.accept(c.paths)
        try await c.installSoftware(try await SoftwareCatalog.latestBuild(.paper, mc: "1.21.11")!)
        for source in [PluginSource.modrinth(project: "luckperms", allowBeta: false), Multiverse.source, .modrinth(project: "bluemap", allowBeta: false)] { try await c.addPlugin(source: source) }
        c.profile.lastPluginCheck = Date(); c.profile.software.lastCheck = Date()
        defer { c.stopLinksPage(); c.forceStop(); c.stopTicker() }
        await c.start()
        await checkUntil(240, "up: \(c.state)") { c.state == .running }
        await c.refreshPlugins()
        print("    plugins: \(c.plugins.map { "\($0.name) \($0.version)" })")
        func run(_ command: String, until needle: String) async { _ = await c.ask(command, seconds: 30) { $0.contains { $0.contains(needle) } } }
        await run("mv create madeup_magic normal -t flat", until: "created")
        await run("mv create madeup_open normal -t flat", until: "created")
        await run("mv config enforce-access true", until: "enforce-access")
        equal(c.multiverseEnforcesAccess, true, "Multiverse's file says it enforces access")

        // BlueMap: its download accepted, its web server on this Mac only, and a map for each made-up world.
        let bluemap = c.paths.plugins.appendingPathComponent("BlueMap")
        let core = bluemap.appendingPathComponent("core.conf"), webConf = bluemap.appendingPathComponent("webserver.conf")
        try FileOps.writeAtomic(try String(contentsOf: core, encoding: .utf8).replacingOccurrences(of: "accept-download: false", with: "accept-download: true"), to: core)
        try FileOps.writeAtomic(try String(contentsOf: webConf, encoding: .utf8).replacingOccurrences(of: "port: 8100", with: "port: \(mapPort)") + "\nip: \"127.0.0.1\"\n", to: webConf)
        let template = try String(contentsOf: bluemap.appendingPathComponent("maps/world.conf"), encoding: .utf8)
        for world in ["madeup_magic", "madeup_open"] {
            try FileOps.writeAtomic(template.replacingOccurrences(of: "world: \"world\"", with: "world: \"\(world)\"").replacingOccurrences(of: "name: \"World\"", with: "name: \"\(world)\""), to: bluemap.appendingPathComponent("maps/\(world).conf"))
        }
        await run("bluemap reload", until: "reloaded")
        let server = c.blueMapServer
        check(server.onlyThisMac && server.port == mapPort, "BlueMap's settings read back: \(server)")
        equal(MapGateway.mapWorlds(in: bluemap.appendingPathComponent("maps"))?["madeup_magic"], "madeup_magic", "each map's world is read")

        let table = try await ProtocolTable.load(mc: "1.21.11", cache: folder("real-map-protocol"), java: c.resolvedJava()?.path ?? "")
        let viewerBot = try await join("MadeUpViewer", c, table, port: port)
        let otherBot = try await join("MadeUpOther", c, table, port: port)
        guard let viewer = c.playerUUIDs["MadeUpViewer"], let other = c.playerUUIDs["MadeUpOther"] else { throw LeafError("no player ids") }
        write(#"[{"uuid":"\#(viewer)","name":"MadeUpViewer"},{"uuid":"\#(other)","name":"MadeUpOther"}]"#, root.appendingPathComponent("whitelist.json"))
        await run("lp user \(viewer) permission set multiverse.access.madeup_magic true", until: "Set")
        // Let BlueMap draw something of the magic world before asking for it.
        await run("mv tp MadeUpViewer madeup_magic", until: "Teleported")
        let tiles = c.paths.root.appendingPathComponent("bluemap/web/maps/madeup_magic/tiles")
        func anyTile() -> String? {
            FileManager.default.enumerator(at: tiles, includingPropertiesForKeys: nil)?.compactMap { ($0 as? URL)?.path }.first { $0.hasSuffix(".prbm.gz") || $0.hasSuffix(".png") }
        }
        await checkUntil(240, "BlueMap drew a tile of the magic world") { anyTile() != nil }

        // The real sign-in page, with only what a test needs loosened: plain http on localhost, and offline bots.
        var page = c.linksPageSettings
        page.address = "https://map.example.test"; page.port = pagePort
        var map = MapGatewaySettings(); map.on = true; page.map = map
        c.linksPageSettings = page
        try c.startLinksPage()
        c.linksWeb?.testOrigin = "http://localhost:\(pagePort)"
        c.linksWeb?.requireOnlineMode = false
        try? await Task.sleep(for: .milliseconds(300))
        func signIn(_ uuid: String) -> String {
            let token = LinksWeb.randomSecret()
            write(#"{"uuid":"\#(uuid)","name":"MadeUp","expires":\#(Int(Date().timeIntervalSince1970) + 120)}"#, c.paths.plugins.appendingPathComponent("Latchkey/pending/\(LinksWeb.hash(token)).json"))
            let response = c.linksWeb!.handle(.init(method: "POST", path: "/signin", headers: ["host": "localhost:\(pagePort)", "origin": "http://localhost:\(pagePort)"], body: Data("token=\(token)".utf8)))
            return response.headers["Set-Cookie"]?.split(separator: ";").first.map(String.init) ?? ""
        }
        func get(_ path: String, _ cookie: String) async -> Data {
            await rawData(port: pagePort, "GET \(path) HTTP/1.1\r\nHost: localhost:\(pagePort)\r\nCookie: \(cookie)\r\nAccept-Encoding: gzip\r\n\r\n")
        }
        func split(_ data: Data) -> (head: String, body: Data) {
            guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return (String(decoding: data, as: UTF8.self), Data()) }
            return (String(decoding: data[..<range.lowerBound], as: UTF8.self), Data(data[range.upperBound...]))
        }
        func maps(_ cookie: String) async -> [String]? {
            ((try? JSONSerialization.jsonObject(with: split(await get("/map/settings.json", cookie)).body)) as? [String: Any])?["maps"] as? [String]
        }
        let viewerCookie = signIn(viewer), otherCookie = signIn(other)
        let viewerMaps = await maps(viewerCookie)
        equal(viewerMaps, ["madeup_magic"], "the player allowed into one world sees only its map")
        let otherMaps = await maps(otherCookie)
        equal(otherMaps, [], "the player allowed into none sees none")
        let index = split(await get("/map/", viewerCookie))
        check(index.head.contains("200") && String(decoding: index.body, as: UTF8.self).lowercased().contains("<html"), "BlueMap's own page comes through")

        let webPath = c.paths.root.appendingPathComponent("bluemap/web").resolvingSymlinksInPath().path
        let tilePath = String(URL(fileURLWithPath: anyTile()!).resolvingSymlinksInPath().path.dropFirst(webPath.count)).replacingOccurrences(of: ".gz", with: "")
        print("    tile asked for: \(tilePath)")
        // BlueMap may redraw a tile at any moment, so the gate's copy is compared with BlueMap's own just before and after.
        var matched = false, tries: [String] = []
        for _ in 0..<5 where !matched {
            let before = split(await rawData(port: mapPort, "GET \(tilePath) HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept-Encoding: gzip\r\n\r\n"))
            let throughGate = split(await get("/map" + tilePath, viewerCookie))
            let after = split(await rawData(port: mapPort, "GET \(tilePath) HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept-Encoding: gzip\r\n\r\n"))
            tries.append("\(before.body.count)/\(throughGate.body.count)/\(after.body.count)")
            if before.body == after.body {
                check(throughGate.head.contains("200") && throughGate.head.contains("Cache-Control: private") && !throughGate.head.contains("Server: BlueMap"), "a real tile comes through, with its headers made private")
                equal(throughGate.body, before.body, "byte for byte what BlueMap itself sends (\(before.body.count) bytes)")
                matched = true
            }
            try? await Task.sleep(for: .seconds(2))
        }
        check(matched, "BlueMap held the tile still long enough to compare: \(tries)")
        let refused = split(await get("/map" + tilePath, otherCookie))
        check(refused.head.contains("404"), "the other player gets nothing for that map")
        let openTile = split(await get("/map/maps/madeup_open/live/players.json", viewerCookie))
        check(openTile.head.contains("404"), "and the viewer nothing for a world they can't enter")
        let live = split(await get("/map/maps/madeup_magic/live/players.json", viewerCookie))
        print("    live players through the gate: \(live.head.split(separator: "\r\n").first ?? "") \(String(decoding: live.body.prefix(160), as: UTF8.self))")
        check(live.head.contains("200"), "live data for their own map")

        // Taking access away: once the few minutes' memory is cleared, it's gone.
        await run("lp user \(viewer) permission unset multiverse.access.madeup_magic", until: "Unset")
        c.forgetMapAccess()
        let afterUnset = await maps(viewerCookie)
        equal(afterUnset, [], "with the permission gone, so is the map")

        // Multiverse not enforcing access: everyone can enter everything, so everyone sees every map.
        await run("mv config enforce-access false", until: "enforce-access")
        c.forgetMapAccess()
        let everything = await maps(otherCookie)
        equal(Set(everything ?? []), Set(MapGateway.mapWorlds(in: bluemap.appendingPathComponent("maps"))!.keys), "with enforce-access off, every map")

        // Something unreadable: no maps, and a reason in the app.
        try FileOps.writeAtomic("broken: [\n", to: c.paths.plugins.appendingPathComponent("Multiverse-Core/config.yml"))
        c.forgetMapAccess()
        let unreadable = await maps(otherCookie)
        equal(unreadable, [], "an unreadable Multiverse setting shows nothing")
        check(c.mapAccessNote?.contains("enforce-access") == true, "and the app says why: \(c.mapAccessNote ?? "")")
        viewerBot.leave(); otherBot.leave()
        c.stopLinksPage()
        c.stop()
        await checkUntil(90, "stopped") { !c.state.isLive }
    } catch { failures.append("real map threw: \(error)") }
}

/// Real Paper and LuckPerms on throwaway servers: an account that has never joined, through to a first join.
@MainActor func runRealPrejoin() async {
    section("REAL PRE-JOIN (EULA accepted by the person running this)")
    func server(_ name: String, port: Int, online: Bool) async throws -> ServerController {
        let root = folder(name)
        write("server-port=\(port)\nonline-mode=\(online)\nnetwork-compression-threshold=-1\nwhite-list=true\nenforce-whitelist=true\nview-distance=4\nsimulation-distance=4\nlevel-type=minecraft\\:flat\n", root.appendingPathComponent("server.properties"))
        let c = try await ServerController.adopt(root: root, name: name)
        try EULA.accept(c.paths)
        let build = try await SoftwareCatalog.latestBuild(.paper, mc: "1.21.11")!
        try await c.installSoftware(build)
        try await c.addPlugin(source: .modrinth(project: "luckperms", allowBeta: false))
        c.profile.lastPluginCheck = Date(); c.profile.software.lastCheck = Date()
        await c.start()
        await checkUntil(240, "\(name) up: \(c.state)") { c.state == .running }
        await c.refreshPlugins()
        for group in ["madeup-one", "madeup-two", "madeup-staff"] { c.send("lp creategroup \(group)"); try? await Task.sleep(for: .seconds(1)) }
        c.send("lp group madeup-one permission set latchkey.signin true")
        try? await Task.sleep(for: .seconds(2))
        await c.refreshGroups()
        return c
    }
    do {
        // These accounts only ever appear on this temporary server's own lists.
        guard case let .found(first) = await AccountLookup.lookUp("nOtCh"), case let .found(second) = await AccountLookup.lookUp("JEB_") else { throw LeafError("Mojang lookup failed") }
        equal(first.name, "Notch", "the real spelling comes back"); equal(second.name, "jeb_", "for any capitals")
        let afterLookup = try? await SoftwareCatalog.versions(.vanilla)
        check(afterLookup?.isEmpty == false, "a lookup doesn't break Mojang's version list afterwards")
        let missing = await AccountLookup.lookUp("ZzqQmadeUpNoSu9")
        equal(missing, .noAccount, "a made-up name has no account")
        let c = try await server("prejoin-online", port: 25590, online: true)
        defer { c.forceStop(); c.stopTicker() }
        equal(c.playerAccessSettings.knownGroups, ["default", "madeup-one", "madeup-staff", "madeup-two"], "groups read from the server")
        var settings = c.playerAccessSettings
        settings.grantable = ["madeup-one", "madeup-two", "no-such-group"]
        c.playerAccessSettings = settings

        let unknownAtFirst = await c.currentGroups(uuid: first.uuid)
        equal(unknownAtFirst, ["default"], "someone who has never joined has only the default")
        let refused = await c.requestAccess(AccessChange(uuid: first.uuid, name: first.name, addGroups: ["madeup-staff"]))
        check(refused?.contains("isn't marked") == true, "an unticked group is refused: \(refused ?? "")")
        check(!c.allowlist.contains { $0.uuid == first.uuid }, "and they aren't added")

        // A group that's gone stops before the allowlist.
        let stopped = await c.requestAccess(AccessChange(uuid: first.uuid, name: first.name, addGroups: ["madeup-two", "no-such-group"]))
        check(stopped?.contains("doesn't exist") == true, "a missing group stops it: \(stopped ?? "")")
        check(!c.allowlist.contains { $0.uuid == first.uuid }, "before the allowlist")
        equal(c.waitingAccess.first?.problem != nil, true, "and it stays in view")
        c.cancelAccess(c.waitingAccess[0].id)

        let added = await c.requestAccess(AccessChange(uuid: first.uuid, name: first.name, addGroups: ["madeup-one", "madeup-two"]))
        equal(added, nil, "a never-joined account is added: \(added ?? "")")
        equal(c.allowlist.first { $0.uuid == first.uuid }?.name, "Notch", "on the allowlist with its ID")
        let groups = await c.currentGroups(uuid: first.uuid)
        equal(groups, ["default", "madeup-one", "madeup-two"], "with its groups")
        let signIn = await c.signInAccess(uuid: first.uuid)
        equal(signIn, .yes, "a group holding the permission gives sign-in")
        equal(c.waitingAccess.count, 0, "and nothing's left waiting")
        let again = await c.requestAccess(AccessChange(uuid: first.uuid, name: first.name, addGroups: ["madeup-one"]))
        equal(again, nil, "repeating it is safe")
        let trimmed = await c.requestAccess(AccessChange(uuid: first.uuid, name: first.name, removeGroups: ["madeup-one"], addToAllowlist: false))
        equal(trimmed, nil, "a group can be removed")
        let fewer = await c.currentGroups(uuid: first.uuid)
        equal(fewer, ["default", "madeup-two"], "and it's gone")
        let noSignIn = await c.signInAccess(uuid: first.uuid)
        equal(noSignIn, .noGroupGivesIt, "with sign-in")
        _ = await c.requestAccess(AccessChange(uuid: first.uuid, name: first.name, addGroups: ["madeup-one"], addToAllowlist: false))

        // Stopped: everything waits, and happens once it's back.
        await c.stop()
        await checkUntil(60, "stopped") { !c.state.isLive }
        let held = await c.requestAccess(AccessChange(uuid: second.uuid, name: second.name, addGroups: ["madeup-one"]))
        equal(held, nil, "stopped, it's accepted"); equal(c.waitingAccess.count, 1, "and waits")
        check(!c.allowlist.contains { $0.uuid == second.uuid }, "without a half-done allowlist entry")
        await c.start()
        await checkUntil(240, "back up") { c.state == .running }
        await checkUntil(40, "the waiting change applied by itself") { c.waitingAccess.isEmpty }
        equal(c.allowlist.first { $0.uuid == second.uuid }?.name, "jeb_", "on the allowlist after starting")
        let secondGroups = await c.currentGroups(uuid: second.uuid)
        equal(secondGroups, ["default", "madeup-one"], "with its groups")
        let kept = await c.currentGroups(uuid: first.uuid)
        equal(kept, ["default", "madeup-one", "madeup-two"], "and the first account's groups survived the restart")

        let running = await c.removeFromAllowlist(AllowlistEntry(uuid: second.uuid, name: second.name))
        equal(running, nil, "running, removing works"); check(!c.allowlist.contains { $0.uuid == second.uuid }, "and the list agrees")
        let stay = await c.currentGroups(uuid: second.uuid)
        equal(stay, ["default", "madeup-one"], "their groups stay")
        await c.stop()
        await checkUntil(60, "stopped") { !c.state.isLive }
    } catch { failures.append("real pre-join online: \(error)") }
    do {
        // Offline mode, because a bot can't join an online-mode server. Being set by ID is the same either way.
        let name = "MadeUpBot"
        var bytes = Array(Insecure.MD5.hash(data: Data("OfflinePlayer:\(name)".utf8)))
        bytes[6] = (bytes[6] & 0x0F) | 0x30
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString.lowercased()
        let c = try await server("prejoin-offline", port: 25589, online: false)
        defer { c.forceStop(); c.stopTicker() }
        check(c.playerAccessBlocked != nil, "offline mode is refused for real use")
        c.accessAllowsOffline = true
        var settings = c.playerAccessSettings
        settings.grantable = ["madeup-one"]
        c.playerAccessSettings = settings
        let table = try await ProtocolTable.load(mc: "1.21.11", cache: folder("prejoin-protocol"), java: c.resolvedJava()?.path ?? "")
        let early = try Bot(name: name, port: 25589, table: table)
        try? await Task.sleep(for: .seconds(4))
        check(!early.inGame, "before being added, the allowlist keeps them out")
        early.leave()
        let added = await c.requestAccess(AccessChange(uuid: uuid, name: name, addGroups: ["madeup-one"]))
        equal(added, nil, "added before they've ever joined: \(added ?? "")")
        let bot = try Bot(name: name, port: 25589, table: table)
        defer { bot.leave() }
        await checkUntil(60, "they can join: \(bot.disconnectReason ?? "")") { bot.inGame }
        try? await Task.sleep(for: .seconds(2))
        let groups = await c.currentGroups(uuid: uuid)
        equal(groups, ["default", "madeup-one"], "their groups are there on first join")
        bot.leave()
        await c.stop()
        await checkUntil(60, "stopped") { !c.state.isLive }
    } catch { failures.append("real pre-join offline: \(error)") }
}

/// Stands in for BlueMap's web server: canned answers, and a record of what it was asked.
final class FakeBlueMap: @unchecked Sendable {
    let listener: NWListener
    var seen: [String] = []
    var answers: [String: (head: String, body: Data)] = [:]
    let lock = NSLock()
    init(port: Int) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(port))!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                self.lock.lock(); self.seen.append(request); let answer = self.answers[path]; self.lock.unlock()
                let reply = answer.map { Data("HTTP/1.1 200 OK\r\nContent-Length: \($0.body.count)\r\n\($0.head)\r\n".utf8) + $0.body } ?? Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8)
                connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
    }
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return seen }
}

@MainActor func mapGatewayChecks() async {
    print("• Map behind sign-in")
    // Reading what BlueMap and Multiverse say.
    let conf = "# The path to the save folder of the world to render.\nworld: \"madeup_magic\"\n# world: \"commented\"\ndimension: \"minecraft:overworld\"\n"
    equal(MapGateway.setting("world", in: conf), "madeup_magic", "a map's world is read, not its comments")
    equal(MapGateway.setting("world", in: "world: a\nworld: b\n"), nil, "two answers mean none")
    let server = MapGateway.blueMapServer(webserverConf: "enabled: true\nwebroot: \"bluemap/web\"\nport: 8100\n")
    check(!server.onlyThisMac && server.port == 8100, "BlueMap's default is every interface")
    check(MapGateway.blueMapServer(webserverConf: "port: 28100\nip: \"127.0.0.1\"\n").onlyThisMac, "and ip: 127.0.0.1 is this Mac only")
    equal(MapGateway.enforcesAccess(multiverseConfig: "world:\n  # the `mv.access.<worldname>` permission.\n  enforce-access: true\n"), true, "enforce-access read as Multiverse 5 writes it")
    equal(MapGateway.enforcesAccess(multiverseConfig: "  enforce-access: false\n"), false, "off")
    equal(MapGateway.enforcesAccess(multiverseConfig: "nothing here\n"), nil, "missing is unknown"); equal(MapGateway.enforcesAccess(multiverseConfig: nil), nil, "and so is no file")
    equal(MapGateway.enforcesAccess(multiverseConfig: "  enforce-access: maybe\n"), nil, "and anything odd")
    let mapsFolder = folder("map-confs")
    write("world: \"madeup_magic\"\n", mapsFolder.appendingPathComponent("magic.conf"))
    write("world: \"../escape\"\n", mapsFolder.appendingPathComponent("odd.conf"))
    write("dimension: \"x\"\n", mapsFolder.appendingPathComponent("noworld.conf"))
    equal(MapGateway.mapWorlds(in: mapsFolder), ["magic": "madeup_magic"], "maps whose world can't be read safely are left out")
    equal(MapGateway.mapWorlds(in: folder("map-confs-none").appendingPathComponent("missing")), nil, "no BlueMap folder is unknown")
    // Minecraft 26 moves worlds inside the level folder. BlueMap's configs then name the level and a dimension,
    // as seen on a 26.2 trial with BlueMap 5.29. Before 26, a nether map names its own folder.
    let old = folder("map-layout-old"), new = folder("map-layout-26")
    write("x", old.appendingPathComponent("world_nether/DIM-1/region/r.0.0.mca"))
    write("x", new.appendingPathComponent("survival/dimensions/minecraft/overworld/region/r.0.0.mca"))
    let oldMaps = old.appendingPathComponent("plugins/BlueMap/maps"), newMaps = new.appendingPathComponent("plugins/BlueMap/maps")
    write("world: \"world_nether\"\ndimension: \"minecraft:the_nether\"\n", oldMaps.appendingPathComponent("world_nether.conf"))
    write("world: \"madeup_magic\"\ndimension: \"minecraft:overworld\"\n", oldMaps.appendingPathComponent("madeup_magic.conf"))
    equal(MapGateway.mapWorlds(in: oldMaps, serverRoot: old), ["world_nether": "world_nether", "madeup_magic": "madeup_magic"], "before 26, the folder is the world")
    for (id, dimension) in [("survival", "minecraft:overworld"), ("survival_nether", "minecraft:the_nether"), ("survival_the_end", "minecraft:the_end"), ("madeup_magic", "minecraft:madeup_magic"), ("moon", "acme:moon"), ("odd", "minecraft:../x")] {
        write("world: \"survival\"\ndimension: \"\(dimension)\"\n", newMaps.appendingPathComponent("\(id).conf"))
    }
    write("world: \"survival\"\n", newMaps.appendingPathComponent("plain.conf"))
    equal(MapGateway.mapWorlds(in: newMaps, serverRoot: new), ["survival": "survival", "survival_nether": "survival_nether", "survival_the_end": "survival_the_end", "madeup_magic": "madeup_magic", "plain": "survival"],
          "from 26, the dimension says which world, and another namespace or an odd name isn't shown")

    // Which paths get through.
    let allowed: Set<String> = ["world"]
    equal(MapGateway.route(path: "/map", allowed: allowed), .redirect, "the bare address goes to the folder")
    equal(MapGateway.route(path: "/map/", allowed: allowed), .forward("/"), "the page")
    equal(MapGateway.route(path: "/map/assets/index-1.js", allowed: allowed), .forward("/assets/index-1.js"), "its scripts")
    equal(MapGateway.route(path: "/map/settings.json", allowed: allowed), .settings, "the map list is filtered")
    equal(MapGateway.route(path: "/map/maps/world/tiles/0/x9/z-8.prbm", allowed: allowed), .forward("/maps/world/tiles/0/x9/z-8.prbm"), "an allowed map's tiles")
    for blocked in ["/map/maps/hidden/tiles/0/x1/z1.prbm", "/map/maps/hidden/live/players.json", "/map/maps/hidden/settings.json", "/map/maps/world", "/map/maps/world/", "/map/sql.php",
                    "/map/../whitelist.json", "/map/maps/world/../hidden/live/players.json", "/map//etc", "/map/maps/%2e%2e/x", "/mapx", "/map/assets/../../x", "/map/maps/World/live/players.json"] {
        equal(MapGateway.route(path: blocked, allowed: allowed), .notFound, "refused: \(blocked)")
    }
    let real = Data(#"{"version":"5.16","useCookies":true,"mapDataRoot":"maps","liveDataRoot":"maps","maps":["world_the_end","world","hidden"],"scripts":[],"styles":[]}"#.utf8)
    let filtered = (try? JSONSerialization.jsonObject(with: MapGateway.filterSettings(real, allowed: ["world", "world_the_end"]) ?? Data())) as? [String: Any]
    equal(filtered?["maps"] as? [String], ["world_the_end", "world"], "the list keeps its order and loses what's hidden")
    equal(filtered?["version"] as? String, "5.16", "and keeps everything else")
    equal(MapGateway.filterSettings(Data(#"{"mapDataRoot":"https://elsewhere.example.test/maps","maps":["world"]}"#.utf8), allowed: allowed), nil, "map data from elsewhere can't be hidden, so nothing is served")
    equal(MapGateway.filterSettings(Data("nonsense".utf8), allowed: allowed), nil, "an unreadable list isn't served")
    let head = MapGateway.rewriteHead("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nSet-Cookie: bluemap=1\r\nCache-Control: public, max-age=86400\r\nConnection: keep-alive") ?? ""
    check(!head.contains("bluemap=1") && !head.contains("public") && head.contains("Cache-Control: private, no-cache") && head.contains("Content-Type: image/png"), "BlueMap's cookies and public caching are dropped")
    let upstream = String(decoding: MapGateway.upstreamRequest(method: "GET", path: "/x", port: 1, headers: ["cookie": "__Host-leafjuice=secret", "accept-encoding": "gzip", "authorization": "x", "origin": "o"]), as: UTF8.self)
    check(upstream.contains("accept-encoding: gzip") && !upstream.contains("secret") && !upstream.contains("authorization") && !upstream.contains("origin"), "the sign-in cookie never reaches BlueMap")

    // The whole way through, with a stand-in BlueMap.
    do {
        let port = 28790, mapPort = 28791
        let root = folder("map-gateway")
        let paths = ServerPaths(root: root)
        let viewer = "00000000-0000-4000-8000-0000000000a1", nobody = "00000000-0000-4000-8000-0000000000a2"
        write("online-mode=true\n", paths.properties)
        write(#"[{"uuid":"\#(viewer)","name":"MadeUpViewer"},{"uuid":"\#(nobody)","name":"MadeUpNobody"}]"#, root.appendingPathComponent("whitelist.json"))
        write(String(decoding: real, as: UTF8.self), root.appendingPathComponent("web/settings.json"))
        let fake = try FakeBlueMap(port: mapPort)
        defer { fake.listener.cancel() }
        let big = Data((0..<(6 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        fake.answers = [
            "/": ("Content-Type: text/html\r\nSet-Cookie: bluemap=1\r\n", Data("<html>BlueMap</html>".utf8)),
            "/maps/world/tiles/0/x1/z1.prbm": ("Content-Type: application/octet-stream\r\n", big),
            "/maps/hidden/live/players.json": ("Content-Type: application/json\r\n", Data("secret positions".utf8)),
            "/maps/world/live/players.json": ("Content-Type: application/json\r\n", Data(#"{"players":[]}"#.utf8)),
        ]
        var access: [String: MapAccess] = [viewer: .maps(["world"]), nobody: .problem("made up")]
        var mapOn = true
        let web = LinksWeb(paths: paths, settings: { LinksPageSettings() }, content: { LinksPageContent(showMap: mapOn) })
        web.testOrigin = "http://localhost:\(port)"
        let listener = LinksListener(web: web)
        listener.map = MapHooks(on: { mapOn }, access: { access[$0] ?? .problem("unknown") }, server: { BlueMapServer(port: mapPort, ip: "127.0.0.1", webroot: "web") }, root: root)
        try listener.start(port: port)
        defer { listener.stop() }
        try? await Task.sleep(for: .milliseconds(200))
        func signIn(_ uuid: String) -> String {
            let token = LinksWeb.randomSecret()
            write(#"{"uuid":"\#(uuid)","name":"MadeUp","expires":\#(Int(Date().timeIntervalSince1970) + 120)}"#, paths.plugins.appendingPathComponent("Latchkey/pending/\(LinksWeb.hash(token)).json"))
            let response = web.handle(.init(method: "POST", path: "/signin", headers: ["host": "localhost:\(port)", "origin": "http://localhost:\(port)"], body: Data("token=\(token)".utf8)))
            return response.headers["Set-Cookie"]?.split(separator: ";").first.map(String.init) ?? ""
        }
        func get(_ path: String, cookie: String? = nil, method: String = "GET") async -> String {
            await rawRequest(port: port, "\(method) \(path) HTTP/1.1\r\nHost: localhost:\(port)\r\n\(cookie.map { "Cookie: \($0)\r\n" } ?? "")Accept-Encoding: gzip\r\n\r\n")
        }
        func status(_ text: String) -> String { String(text.split(separator: "\r\n").first ?? "") }
        func body(_ text: String) -> String { text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n") }

        // Signed out: nothing from BlueMap.
        let before = fake.requests.count
        let signedOut = await get("/map/")
        check(status(signedOut).contains("200") && signedOut.contains("/signin") && !signedOut.contains("BlueMap"), "signed out, the map page says how to sign in")
        let v1 = await get("/map/maps/world/tiles/0/x1/z1.prbm")
        equal(status(v1), "HTTP/1.1 404 Not Found", "and its tiles aren't there")
        let v2 = await get("/map/settings.json")
        equal(status(v2), "HTTP/1.1 404 Not Found", "nor its list")
        equal(fake.requests.count, before, "BlueMap isn't asked anything for someone signed out")
        let wrongHost = await rawRequest(port: port, "GET /map/ HTTP/1.1\r\nHost: other.example.test\r\n\r\n")
        equal(status(wrongHost), "HTTP/1.1 421 Misdirected Request", "another host is refused")

        let cookie = signIn(viewer)
        check(cookie.hasPrefix("__Host-leafjuice="), "signed in")
        let v3 = await get("/", cookie: cookie)
        check(body(v3).contains("/map/"), "the plugin page links to the map")
        let v4 = await get("/map", cookie: cookie)
        equal(status(v4), "HTTP/1.1 303 See Other", "the bare address goes to the folder")
        let page = await get("/map/", cookie: cookie)
        check(body(page) == "<html>BlueMap</html>", "BlueMap's page comes through")
        check(!page.contains("bluemap=1") && page.contains("Cache-Control: private, no-cache"), "without BlueMap's cookie, and not for shared caches")
        check(fake.requests.last.map { !$0.contains("leafjuice") && $0.contains("accept-encoding: gzip") } == true, "BlueMap never sees the sign-in cookie")
        let list = (try? JSONSerialization.jsonObject(with: Data(body(await get("/map/settings.json", cookie: cookie)).utf8))) as? [String: Any]
        equal(list?["maps"] as? [String], ["world"], "the map list has only their map")
        let tile = await rawData(port: port, "GET /map/maps/world/tiles/0/x1/z1.prbm HTTP/1.1\r\nHost: localhost:\(port)\r\nCookie: \(cookie)\r\n\r\n")
        let tileBody = tile.range(of: Data("\r\n\r\n".utf8)).map { tile[$0.upperBound...] }
        check(tileBody.map { Data($0) == big } == true, "a 6 MB tile comes through unchanged (\(tileBody?.count ?? 0) bytes)")
        let v5 = await get("/map/maps/world/live/players.json", cookie: cookie)
        equal(body(v5), #"{"players":[]}"#, "live data for their map")
        let hidden = await get("/map/maps/hidden/live/players.json", cookie: cookie)
        check(status(hidden) == "HTTP/1.1 404 Not Found" && !hidden.contains("secret positions"), "a map they can't enter is refused, live data included")
        check(!fake.requests.contains { $0.contains("/maps/hidden/") }, "and BlueMap is never asked for it")
        let v6 = await get("/map/sql.php", cookie: cookie)
        equal(status(v6), "HTTP/1.1 404 Not Found", "paths the map doesn't use are refused")
        let posted = await rawRequest(port: port, "POST /map/settings.json HTTP/1.1\r\nHost: localhost:\(port)\r\nCookie: \(cookie)\r\nContent-Length: 0\r\n\r\n")
        equal(status(posted), "HTTP/1.1 405 Method Not Allowed", "only looking")
        let headOnly = await get("/map/", cookie: cookie, method: "HEAD")
        check(status(headOnly).contains("200"), "HEAD works too")

        // Losing access: someone off the allowlist, or a world they can no longer enter.
        access[viewer] = .maps([])
        let none = await get("/map/", cookie: cookie)
        check(body(none).contains("no maps for you"), "with no worlds, the page says so rather than showing an empty map")
        let v7 = await get("/map/maps/world/tiles/0/x1/z1.prbm", cookie: cookie)
        equal(status(v7), "HTTP/1.1 404 Not Found", "and the tiles they saw before are gone")
        access[viewer] = .maps(["world"])
        let nobodyCookie = signIn(nobody)
        let v8 = await get("/map/", cookie: nobodyCookie)
        check(body(v8).contains("no maps for you"), "anything unreadable shows no maps")
        let nobodyList = (try? JSONSerialization.jsonObject(with: Data(body(await get("/map/settings.json", cookie: nobodyCookie)).utf8))) as? [String: Any]
        equal(nobodyList?["maps"] as? [String], [], "and an empty list")
        write(#"[{"uuid":"\#(nobody)","name":"MadeUpNobody"}]"#, root.appendingPathComponent("whitelist.json"))
        let v9 = await get("/map/maps/world/live/players.json", cookie: cookie)
        equal(status(v9), "HTTP/1.1 404 Not Found", "off the allowlist, the map is gone at once")

        // BlueMap down.
        fake.listener.cancel()
        try? await Task.sleep(for: .milliseconds(200))
        let viewerAgain = { write(#"[{"uuid":"\#(viewer)","name":"MadeUpViewer"}]"#, root.appendingPathComponent("whitelist.json")) }
        viewerAgain()
        let down = await get("/map/", cookie: signIn(viewer))
        equal(status(down), "HTTP/1.1 502 Bad Gateway", "BlueMap not running is said plainly")

        // Off means off.
        mapOn = false
        let off = await get("/map/", cookie: signIn(viewer))
        equal(status(off), "HTTP/1.1 404 Not Found", "with the map switched off, /map/ isn't there")
        let v10 = await get("/", cookie: signIn(viewer))
        check(!body(v10).contains("/map/"), "and the plugin page doesn't link to it")
    } catch { failures.append("map gateway threw: \(error)") }
}

/// The page for players, without a real server: who gets in, what they see and what's written down.
@MainActor func linksWebChecks() async {
    do {
        let root = folder("links-web")
        let paths = ServerPaths(root: root)
        let allowed = "00000000-0000-4000-8000-00000000000a", outsider = "00000000-0000-4000-8000-00000000000b"
        write("online-mode=true\n", paths.properties)
        write(#"[{"uuid":"\#(allowed)","name":"MadeUp"}]"#, root.appendingPathComponent("whitelist.json"))
        var settings = LinksPageSettings()
        settings.address = "https://links.example.test/"
        var shown = LinksPageContent(serverVersion: "Paper 1.21.11", plugins: [.init(name: "Shared<Plugin>", version: "1.2", link: "https://docs.example.test/a"), .init(name: "NoLink", version: nil, link: nil)])
        let web = LinksWeb(paths: paths, settings: { settings }, content: { shown })
        let host = ["host": "links.example.test"]
        func get(_ path: String, _ extra: [String: String] = [:], now: Date = Date()) -> LinksWeb.Response {
            web.handle(.init(method: "GET", path: path, headers: host.merging(extra) { $1 }, body: Data()), now: now)
        }
        func post(_ path: String, _ body: String, cookie: String? = nil, origin: String? = "https://links.example.test", now: Date = Date()) -> LinksWeb.Response {
            var headers = host
            headers["origin"] = origin
            headers["cookie"] = cookie
            return web.handle(.init(method: "POST", path: path, headers: headers, body: Data(body.utf8)), now: now)
        }
        func issue(_ uuid: String, name: String = "MadeUp", expires: Date = Date().addingTimeInterval(120), token: String = LinksWeb.randomSecret()) -> String {
            write(#"{"uuid":"\#(uuid)","name":"\#(name)","expires":\#(Int(expires.timeIntervalSince1970))}"#, paths.plugins.appendingPathComponent("Latchkey/pending/\(LinksWeb.hash(token)).json"))
            return token
        }
        func text(_ response: LinksWeb.Response) -> String { String(decoding: response.body, as: UTF8.self) }
        func cookie(_ response: LinksWeb.Response) -> String? { response.headers["Set-Cookie"]?.split(separator: ";").first.map(String.init) }

        // Addresses.
        equal(settings.origin, "https://links.example.test", "an address is tidied")
        for bad in ["", "http://links.example.test", "https://", "https://me@links.example.test", "https://links.example.test/page", "https://links.example.test?a=1", "javascript:alert(1)"] {
            var other = LinksPageSettings(); other.address = bad
            equal(other.origin, nil, "not an address for the page: \(bad)")
        }
        check(LinksPageSettings().on == false, "the page starts off"); check(LinksPageSettings().shared.isEmpty, "with nothing shared")

        // Before signing in, nothing about the server shows.
        let outside = text(get("/"))
        check(outside.contains("/signin") && !outside.contains("Shared") && !outside.contains("Paper"), "signed out, the page says only how to sign in")
        equal(web.handle(.init(method: "GET", path: "/", headers: ["host": "other.example.test"], body: Data())).status, 421, "another host is refused")
        equal(web.handle(.init(method: "GET", path: "/", headers: [:], body: Data())).status, 421, "and so is none")
        equal(get("/.leafjuice/server.json").status, 404, "files can't be asked for"); equal(get("/../whitelist.json").status, 404, "not even by climbing")
        equal(web.handle(.init(method: "PUT", path: "/", headers: host, body: Data())).status, 405, "only the methods it uses")
        let security = get("/").headers
        check(security["Content-Security-Policy"]?.contains("default-src 'none'") == true, "strict content policy"); equal(security["Cache-Control"], "no-store", "never cached"); equal(security["X-Robots-Tag"], "noindex", "not for search engines")
        equal(security["Referrer-Policy"], "same-origin", "a no-referrer policy would make browsers send Origin: null and refuse sign-in")
        check(text(get("/signin")).contains("signin.js"), "the sign-in page reads the link in the browser"); equal(get("/signin.js").status, 200, "from its own script")

        // Signing in.
        let token = issue(allowed)
        let pending = paths.plugins.appendingPathComponent("Latchkey/pending/\(LinksWeb.hash(token)).json")
        equal(post("/signin", "token=\(token)", origin: "https://evil.example.test").status, 403, "another site can't use a link")
        equal(post("/signin", "token=\(token)", origin: nil).status, 403, "or a request with no origin")
        check(FileOps.exists(pending), "and that doesn't burn it")
        equal(post("/signin", "token=short").status, 400, "a malformed link fails"); equal(post("/signin", "token=../../../../whitelist").status, 400, "and can't reach another file")
        let signedIn = post("/signin", "token=\(token)")
        equal(signedIn.status, 303, "a good link signs in"); check(!FileOps.exists(pending), "and is used up")
        let flags = signedIn.headers["Set-Cookie"] ?? ""
        check(flags.hasPrefix("__Host-leafjuice=") && flags.contains("Secure") && flags.contains("HttpOnly") && flags.contains("SameSite=Strict") && flags.contains("Max-Age=43200"), "the cookie is locked down, for 12 hours: \(flags.prefix(20))")
        equal(post("/signin", "token=\(token)").status, 400, "a link works once")
        equal(web.signedIn.map(\.name), ["MadeUp"], "the app knows who's signed in")
        let session = ["cookie": cookie(signedIn) ?? ""]
        let inside = text(get("/", session))
        check(inside.contains("Shared&lt;Plugin&gt;") && !inside.contains("Shared<Plugin>"), "what's shared shows, escaped"); check(inside.contains("Paper 1.21.11"), "with the server's version"); check(inside.contains("docs.example.test"), "and the link"); check(inside.contains("No link yet"), "a plugin without one says so"); check(inside.contains("Signed in as MadeUp"), "and who you are")
        shown.serverVersion = nil; shown.plugins[0].version = nil
        check(!text(get("/", session)).contains("Paper") && !text(get("/", session)).contains("1.2"), "versions can be left out")
        shown.plugins = []
        check(text(get("/", session)).contains("Nothing has been shared"), "nothing shared, nothing shown")
        check(text(get("/", ["cookie": "__Host-leafjuice=made-up"])).contains("/signin") , "a made-up cookie is nobody")
        equal(web.signedIn.count, 1, "and doesn't count")

        // Links that shouldn't work.
        equal(post("/signin", "token=\(issue(allowed, expires: Date().addingTimeInterval(-1)))").status, 400, "an expired link fails")
        equal(post("/signin", "token=\(issue(outsider, name: "Outsider"))").status, 403, "someone not on the allowlist is refused")
        equal(post("/signin", "token=\(issue("not-a-uuid"))").status, 400, "a damaged file is refused")
        check(!web.signedIn.contains { $0.name == "Outsider" }, "and gets no session")

        // Access ends when it should.
        let early = Date()
        let late = post("/signin", "token=\(issue(allowed))", now: early)
        let later = ["cookie": cookie(late) ?? ""]
        equal(web.signedIn.count, 1, "signing in again replaces the old session")
        check(text(get("/", session)).contains("/signin") , "and the old cookie stops working")
        check(text(get("/", later, now: early.addingTimeInterval(LinksWeb.sessionLength - 60))).contains("Signed in as"), "still in, just under 12 hours")
        check(!text(get("/", later, now: early.addingTimeInterval(LinksWeb.sessionLength + 1))).contains("Signed in as"), "out after 12 hours")
        let ban = post("/signin", "token=\(issue(allowed))")
        let banned = ["cookie": cookie(ban) ?? ""]
        write(#"[{"uuid":"\#(allowed)","name":"MadeUp"}]"#, root.appendingPathComponent("banned-players.json"))
        check(!text(get("/", banned)).contains("Signed in as"), "a ban ends it at once")
        try FileManager.default.removeItem(at: root.appendingPathComponent("banned-players.json"))
        let removed = ["cookie": cookie(post("/signin", "token=\(issue(allowed))")) ?? ""]
        write("[]", root.appendingPathComponent("whitelist.json"))
        check(!text(get("/", removed)).contains("Signed in as"), "leaving the allowlist ends it at once")
        write("not json", root.appendingPathComponent("whitelist.json"))
        equal(post("/signin", "token=\(issue(allowed))").status, 403, "an unreadable allowlist is a no")
        write(#"[{"uuid":"\#(allowed)","name":"MadeUp"}]"#, root.appendingPathComponent("whitelist.json"))
        write("online-mode=false\n", paths.properties)
        equal(post("/signin", "token=\(issue(allowed))").status, 403, "with online-mode off, nobody gets in")
        write("online-mode=true\n", paths.properties)

        // Signing out.
        let leaving = post("/signin", "token=\(issue(allowed))")
        let leavingHeaders = ["cookie": cookie(leaving) ?? ""]
        equal(post("/signout", "", cookie: leavingHeaders["cookie"], origin: "https://evil.example.test").status, 403, "another site can't sign you out")
        equal(post("/signout", "", cookie: leavingHeaders["cookie"]).status, 303, "signing out works")
        check(!text(get("/", leavingHeaders)).contains("Signed in as"), "and ends it")
        let kicked = ["cookie": cookie(post("/signin", "token=\(issue(allowed))")) ?? ""]
        web.signOut(uuid: allowed)
        check(!text(get("/", kicked)).contains("Signed in as"), "the app can end a session too")

        // The log holds account, time and event, and nothing else.
        let raw = (try? String(contentsOf: web.logFile, encoding: .utf8)) ?? ""
        check(web.log.contains { $0.kind == .signedIn } && web.log.contains { $0.kind == .refused } && web.log.contains { $0.kind == .removed } && web.log.contains { $0.kind == .signedOut } && web.log.contains { $0.kind == .expired }, "each kind of event is written")
        check(!raw.contains(token) && !raw.contains("token") && !raw.contains("address") && !raw.contains("127.0.0.1"), "no secrets or addresses in the log")
        let keys = Set((try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] ?? []).flatMap(\.keys))
        equal(keys, ["date", "uuid", "name", "kind"], "the log's fields")
        let waiting = post("/signin", "token=\(issue(allowed))")
        check(cookie(waiting) != nil, "one more session")
        web.tidy(now: Date().addingTimeInterval(Double(LinksWeb.logDays + 1) * 24 * 60 * 60))
        equal(web.signedIn.count, 0, "tidying closes what's run out")
        check(web.log.allSatisfy { $0.kind == .expired }, "and forgets entries past 30 days")

        // Reading requests.
        func parsed(_ text: String) -> LinksWeb.Parsed { LinksWeb.parse(Data(text.utf8)) }
        equal(parsed("GET / HTTP/1.1\r\nHost: a\r\n"), .incomplete, "waits for the rest")
        if case let .ok(request) = parsed("POST /signin?x=1 HTTP/1.1\r\nHost: a\r\nContent-Length: 3\r\n\r\nabc") {
            equal(request.path, "/signin", "the query is dropped"); equal(request.body, Data("abc".utf8), "the body is read"); equal(request.headers["host"], "a", "headers are read")
        } else { check(false, "a normal request parses") }
        equal(parsed("POST / HTTP/1.1\r\nContent-Length: 3\r\n\r\nab"), .incomplete, "waits for the body")
        for bad in ["GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n", "POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab", "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", "POST / HTTP/1.1\r\nContent-Length: 2000\r\n\r\n", "POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n", "GET x HTTP/1.1\r\n\r\n", "NONSENSE\r\n\r\n", "GET / HTTP/1.1\r\nno colon\r\n\r\n", "GET / HTTP/1.1\r\nBad Name: a\r\n\r\n", "GET / HTTP/2\r\n\r\n", "GET /" + String(repeating: "a", count: 9000)] {
            equal(parsed(bad), .bad, "refused: \(bad.prefix(40).debugDescription)")
        }

        // Over a real socket, on this Mac only.
        write(#"[{"uuid":"\#(allowed)","name":"MadeUp"}]"#, root.appendingPathComponent("whitelist.json"))
        let listener = LinksListener(web: web)
        try listener.start(port: 25597)
        defer { listener.stop() }
        await checkUntil(5, "listening") { listener.isListening }
        let answer = await rawRequest(port: 25597, "GET / HTTP/1.1\r\nHost: links.example.test\r\n\r\n")
        check(answer.hasPrefix("HTTP/1.1 200") && answer.contains("Connection: close") && answer.contains("/signin"), "a real request gets a real answer: \(answer.prefix(30))")
        let headOnly = await rawRequest(port: 25597, "HEAD / HTTP/1.1\r\nHost: links.example.test\r\n\r\n")
        check(headOnly.hasPrefix("HTTP/1.1 200") && !headOnly.contains("<html"), "HEAD has no body")
        let nonsense = await rawRequest(port: 25597, "NONSENSE\r\n\r\n")
        check(nonsense.hasPrefix("HTTP/1.1 400"), "nonsense is refused")
        let realCheck = await rawRequest(port: 25597, "POST /signin HTTP/1.1\r\nHost: links.example.test\r\nOrigin: https://links.example.test\r\nContent-Length: 49\r\n\r\ntoken=\(issue(allowed))")
        check(realCheck.hasPrefix("HTTP/1.1 303") && realCheck.contains("Set-Cookie: __Host-leafjuice="), "a sign-in works over the socket: \(realCheck.prefix(30))")
        let reachable = localAddresses().filter { $0 != "127.0.0.1" }
        for address in reachable.prefix(3) { check(!canConnect(address, port: 25597), "not reachable from \(address)") }
        print("  checked unreachable from \(reachable.count) other local addresses")
        listener.stop()
        try? await Task.sleep(for: .milliseconds(200))
        check(!canConnect("127.0.0.1", port: 25597), "stopping it closes the port")

        // The switch from Settings stops it too.
        var closing = true
        let switched = LinksListener(web: web, allowed: { closing })
        try switched.start(port: 25595)
        await checkUntil(5, "listening again") { switched.isListening }
        closing = false
        _ = await rawRequest(port: 25595, "GET / HTTP/1.1\r\nHost: links.example.test\r\n\r\n")
        try? await Task.sleep(for: .milliseconds(200))
        check(!switched.isListening, "switching the module off stops it")
        switched.stop()

        // What the controller offers the page.
        let c = ServerController(root: folder("links-controller"), profile: ServerProfile())
        defer { c.stopTicker(); c.stopLinksPage() }
        check(c.linksPageProblem != nil, "no address, no page")
        do { try c.startLinksPage(); check(false, "starting with no address should fail") } catch { check(c.linksListener == nil, "and doesn't listen") }
        var saved = c.linksPageSettings
        saved.address = "https://links.example.test"; saved.port = 80
        c.linksPageSettings = saved
        check(c.linksPageProblem?.contains("port") == true, "a privileged port is refused")
        saved.port = 25594; saved.showPluginVersions = false
        c.linksPageSettings = saved
        equal(c.linksPageContent.plugins.count, 0, "nothing's shared until ticked")
        try c.startLinksPage()
        await checkUntil(5, "the controller's page is up") { c.linksListener?.isListening == true }
        c.stopLinksPage()
        check(c.linksListener == nil, "and stops")
    } catch { failures.append("links page threw: \(error)") }
}

func rawData(port: Int, _ text: String) async -> Data {
    await withCheckedContinuation { (done: CheckedContinuation<Data, Never>) in
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        final class Box: @unchecked Sendable { var data = Data(); var ended = false }
        let box = Box(), queue = DispatchQueue(label: "raw-data")
        @Sendable func end() { guard !box.ended else { return }; box.ended = true; connection.cancel(); done.resume(returning: box.data) }
        @Sendable func pull() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, finished, error in
                if let data { box.data.append(data) }
                if finished || error != nil { end() } else { pull() }
            }
        }
        connection.start(queue: queue)
        connection.send(content: Data(text.utf8), completion: .idempotent)
        pull()
        queue.asyncAfter(deadline: .now() + 30) { end() }
    }
}

func canConnect(_ host: String, port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian; address.sin_addr.s_addr = inet_addr(host)
    return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
}

func localAddresses() -> [String] {
    var out: [String] = []
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0, let start = first else { return out }
    defer { freeifaddrs(first) }
    var next: UnsafeMutablePointer<ifaddrs>? = start
    while let item = next {
        if let found = item.pointee.ifa_addr, found.pointee.sa_family == sa_family_t(AF_INET) {
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(found, socklen_t(found.pointee.sa_len), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 { out.append(String(cString: name)) }
        }
        next = item.pointee.ifa_next
    }
    return out
}

/// Real Paper in a temp folder with the real plugin and a bot: `/signin` in game through to a signed-in page.
@MainActor func runRealSignIn(jar: String) async {
    section("REAL SIGN-IN (EULA accepted by the person running this)")
    do {
        let root = folder("real-signin")
        write("server-port=25593\nonline-mode=false\nnetwork-compression-threshold=-1\nview-distance=4\nsimulation-distance=4\nmotd=made up message\nlevel-type=minecraft\\:flat\n", root.appendingPathComponent("server.properties"))
        let c = try await ServerController.adopt(root: root, name: "Real sign-in test")
        defer { c.forceStop(); c.stopTicker(); c.stopLinksPage() }
        try EULA.accept(c.paths)
        let build = try await SoftwareCatalog.latestBuild(.paper, mc: "1.21.11")!
        try await c.installSoftware(build)
        try FileOps.ensureDir(c.paths.plugins)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: jar), to: c.paths.plugins.appendingPathComponent("Latchkey.jar"))
        write("sign-in-page: \"https://links.example.test\"\n", c.paths.plugins.appendingPathComponent("Latchkey/config.yml"))
        c.profile.lastPluginCheck = Date(); c.profile.software.lastCheck = Date()
        c.profile.launch.extraJVMArgs = "-Dlatchkey.allowOfflineForTesting=true"
        await c.start()
        await checkUntil(240, "real server up: \(c.state)") { c.state == .running }
        check(c.console.contains { $0.text.contains("Enabling Latchkey") }, "the plugin loaded")
        await c.refreshPlugins()
        check(c.hasLatchkey, "the app sees it")

        var saved = LinksPageSettings(); saved.address = "https://links.example.test"; saved.port = 25592
        saved.shared = ["latchkey"]
        c.linksPageSettings = saved
        try c.startLinksPage()
        c.linksWeb?.requireOnlineMode = false
        await checkUntil(5, "page up") { c.linksListener?.isListening == true }

        let java = c.resolvedJava()?.path ?? ""
        let table = try await ProtocolTable.load(mc: "1.21.11", cache: folder("signin-protocol"), java: java)
        let bot = try Bot(name: "MadeUpBot", port: 25593, table: table)
        defer { bot.leave() }
        await checkUntil(60, "bot in game: \(bot.disconnectReason ?? "")") { bot.inGame }
        let tokenPattern = try NSRegularExpression(pattern: #"/signin#([A-Za-z0-9_-]{43})"#)
        func link() -> String? {
            for text in bot.privateMessages.reversed() {
                if let match = tokenPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) { return String(text[range]) }
            }
            return nil
        }
        func sent(_ words: String) -> Bool { bot.privateMessages.contains { $0.contains(words) } }
        func answer(_ cookie: String?) async -> String {
            await rawRequest(port: 25592, "GET / HTTP/1.1\r\nHost: links.example.test\r\n\(cookie.map { "Cookie: \($0)\r\n" } ?? "")\r\n")
        }
        let pending = c.paths.plugins.appendingPathComponent("Latchkey/pending")

        bot.command("signin")
        try? await Task.sleep(for: .seconds(2))
        check(link() == nil, "no permission, no link")
        check(FileOps.children(pending).isEmpty, "and nothing saved")
        c.send("op MadeUpBot")
        try? await Task.sleep(for: .seconds(2))
        bot.command("signin")
        await checkUntil(10, "told it isn't on the allowlist") { sent("allowlist") }
        check(link() == nil, "with permission but off the allowlist, no link")
        c.send("whitelist add MadeUpBot")
        try? await Task.sleep(for: .seconds(2))
        bot.command("signin")
        await checkUntil(10, "a link arrives in game") { link() != nil }
        guard let token = link() else { throw LeafError("no link arrived") }
        check(FileOps.children(pending).first?.lastPathComponent == "\(LinksWeb.hash(token)).json", "its hash is what's saved")
        check(!c.console.contains { $0.text.contains(token) }, "the link isn't in the console")
        let logs = (try? String(contentsOf: c.paths.root.appendingPathComponent("logs/latest.log"), encoding: .utf8)) ?? ""
        check(!logs.isEmpty && !logs.contains(token), "or the server's log")

        let form = "token=\(token)"
        let signIn = await rawRequest(port: 25592, "POST /signin HTTP/1.1\r\nHost: links.example.test\r\nOrigin: https://links.example.test\r\nContent-Length: \(form.utf8.count)\r\n\r\n\(form)")
        check(signIn.hasPrefix("HTTP/1.1 303"), "the real link signs in: \(signIn.prefix(40))")
        check(FileOps.children(pending).isEmpty, "and is used up")
        let again = await rawRequest(port: 25592, "POST /signin HTTP/1.1\r\nHost: links.example.test\r\nOrigin: https://links.example.test\r\nContent-Length: \(form.utf8.count)\r\n\r\n\(form)")
        check(again.hasPrefix("HTTP/1.1 400"), "a second use fails")
        let cookie = signIn.components(separatedBy: "\r\n").first { $0.hasPrefix("Set-Cookie: ") }?.dropFirst("Set-Cookie: ".count).split(separator: ";").first.map(String.init)
        let inside = await answer(cookie)
        check(inside.contains("Signed in as MadeUpBot"), "the page knows who it is")
        check(inside.contains("Latchkey"), "and lists what's shared")
        equal(c.linksWeb?.signedIn.first?.name, "MadeUpBot", "the app shows them signed in")
        equal(c.linksWeb?.signedIn.first?.uuid, (try JSONSerialization.jsonObject(with: Data(contentsOf: c.paths.root.appendingPathComponent("whitelist.json"))) as? [[String: Any]])?.first?["uuid"] as? String, "by the same account the server knows")

        c.send("whitelist remove MadeUpBot")
        await checkUntil(10, "removed from the allowlist on disk") { ((try? String(contentsOf: c.paths.root.appendingPathComponent("whitelist.json"), encoding: .utf8)) ?? "").contains("MadeUpBot") == false }
        let afterRemoval = await answer(cookie)
        check(!afterRemoval.contains("Signed in as"), "taking them off the allowlist ends it at once")
        check(c.signInLog.contains { $0.kind == .removed && $0.name == "MadeUpBot" }, "and that's in the log")
        bot.leave()
        await c.stop()
        await checkUntil(60, "real server stopped: \(c.state)") { !c.state.isLive }
        check(FileOps.children(pending).isEmpty, "no links left waiting after a stop")
    } catch { failures.append("real sign-in: \(error)") }
}

@MainActor func runLiveAPIs() async {
    section("LIVE: APIs")
    do {
        let links = try await PluginLinks.lookUpModrinth(["luckperms", "viaversion"])
        check(PluginLinks.clean(links["luckperms"]?.wiki ?? "") != nil, "Modrinth gives LuckPerms a wiki link")
        check(PluginLinks.clean(links["viaversion"]?.code ?? "") != nil, "and ViaVersion its source code")
        let versions = try await SoftwareCatalog.versions(.paper)
        check(versions.first.map { gv($0) > gv("1.21") } == true, "paper versions newest first: \(versions.prefix(2))")
        let paper = try await SoftwareCatalog.latestBuild(.paper, mc: "1.21.11")
        check(paper?.hashes.sha256 != nil, "paper hash"); equal(paper?.javaMinimum, 21, "paper java from API")
        check(paper?.recommendedFlags.isEmpty == false, "paper flags from API")
        let purpur = try await SoftwareCatalog.latestBuild(.purpur, mc: "1.21.11")
        check(purpur?.build != nil, "purpur build")
        let vanilla = try await SoftwareCatalog.versions(.vanilla)
        let vbuild = try await SoftwareCatalog.latestBuild(.vanilla, mc: vanilla[0])
        check(vbuild?.hashes.sha1 != nil, "vanilla hash")
        let folia = try await SoftwareCatalog.latestBuild(.folia, mc: "1.21.11")
        check(folia != nil, "folia")

        let mc = gv("1.21.11")
        let checks: [(String, PluginSource)] = [
            ("modrinth", .modrinth(project: "luckperms", allowBeta: false)),
            ("hangar", .hangar(project: "ViaVersion/ViaVersion", channel: "Release")),
            ("spigot", .spigot(resourceID: 28140)),
            ("github", .github(repo: "ViaVersion/ViaVersion", assetPattern: "", prereleases: false)),
            ("jenkins", .jenkins(jobURL: "https://ci.lucko.me/job/LuckPerms/", artifactPattern: "")),
        ]
        for (name, source) in checks {
            let result = try await PluginSources.check(source, mc: mc, flavor: .paper)
            check(result.candidate?.downloadURL != nil, "\(name) yields a download")
            print("    \(name): \(result.candidate?.version ?? "-") [\(result.candidate?.compatibility.verdict.rawValue ?? "-")] \(result.candidate?.downloadURL ?? result.skippedNote ?? "")")
        }
        let tooOld = try await PluginSources.check(.modrinth(project: "luckperms", allowBeta: false), mc: gv("1.8"), flavor: .paper)
        print("    modrinth for 1.8: \(tooOld.candidate?.version ?? "none") \(tooOld.skippedNote ?? "")")
        let runtimes = await JavaManager.discover()
        check(!runtimes.isEmpty, "finds java: \(runtimes.map(\.label))")

        // Real downloads through the real vetting path, without running anything.
        let root = folder("live-downloads")
        write("server-port=25598\n", root.appendingPathComponent("server.properties"))
        let c = try await ServerController.adopt(root: root, name: "Downloads")
        defer { c.stopTicker() }
        c.profile.backup.beforeUpdates = false
        c.profile.lastPluginCheck = Date(); c.profile.software.lastCheck = Date()
        c.profile.software.mcVersion = "1.21.11"
        try await c.addPlugin(source: .modrinth(project: "luckperms", allowBeta: false))
        try await c.addPlugin(source: .hangar(project: "ViaVersion/ViaVersion", channel: "Release"))
        try await c.addPlugin(source: .jenkins(jobURL: "https://ci.viaversion.com/job/ViaBackwards/", artifactPattern: ""))
        await c.refreshPlugins()
        print("    installed: \(c.plugins.map { "\($0.name) \($0.version)" })")
        check(c.plugins.contains { $0.name == "LuckPerms" }, "modrinth plugin installed")
        check(c.plugins.contains { $0.name == "ViaVersion" }, "hangar plugin installed")
        check(c.plugins.contains { $0.name == "ViaBackwards" }, "jenkins plugin installed")
        var refused = ""
        do { try await c.addPlugin(source: .modrinth(project: "luckperms", allowBeta: false)) } catch { refused = error.localizedDescription }
        check(refused.contains("already installed"), "no duplicates: \(refused)")

        // Multiverse and its add-ons resolve to real, compatible jars.
        try await c.addPlugin(source: Multiverse.source)
        for addOn in Multiverse.addOns {
            let found = try await PluginSources.check(addOn.source, mc: gv("1.21.11"), flavor: .paper)
            check(found.candidate?.downloadURL != nil, "\(addOn.title) add-on: \(found.skippedNote ?? "")")
        }
        await c.refreshPlugins()
        equal(c.multiverseMajor, 5, "real Multiverse-Core read as major 5")

        // A multi-module Jenkins job is pointed at the wrong artifact: the jar's own name refuses it.
        var wrong = PluginRecord()
        wrong.source = .jenkins(jobURL: "https://ci.viaversion.com/job/ViaBackwards/", artifactPattern: "")
        let lp = c.plugins.first { $0.name == "LuckPerms" }!
        c.setRecord(wrong, for: lp)
        await c.checkPlugin(lp)
        var refusal = ""
        do { try await c.installUpdate(for: lp) } catch { refusal = error.localizedDescription }
        print("    wrong artifact: \(refusal)")
        check(refusal.contains("ViaBackwards") || c.record(for: lp).available == nil, "wrong artifact refused")

        // Real pre-26 jars: detected from their contents, even when renamed. They aren't run.
        for mcOld in ["1.21.4", "1.20.4"] {
            let old = try await SoftwareCatalog.latestBuild(.paper, mc: mcOld)!
            let oldRoot = folder("detect-\(mcOld)")
            try await HTTP.download(HTTP.url(old.downloadURL), to: oldRoot.appendingPathComponent("server.jar"), expect: old.hashes)
            let seen = await ServerDetector.detect(oldRoot)
            print("    server.jar from \(mcOld): \(seen.software.flavor) \(seen.software.mcVersion) java \(seen.software.requiredJava.map(String.init) ?? "-")")
            equal(seen.software.mcVersion, mcOld, "renamed \(mcOld) jar identified"); equal(seen.software.flavor, .paper, "as Paper")
        }
        for mcOld in ["1.21.4", "1.20.4", "1.18.2"] {
            let found = try await PluginSources.check(Multiverse.source, mc: gv(mcOld), flavor: .paper)
            equal(found.candidate?.compatibility.verdict, .compatible, "Multiverse fits \(mcOld)")
        }
        let old = try await PluginSources.check(Multiverse.source, mc: gv("1.16.5"), flavor: .paper)
        print("    Multiverse for 1.16.5: \(old.candidate?.version ?? "none")")
        check(old.candidate.map { $0.version.hasPrefix("4.") } == true, "1.16.5 gets a 4.x release, not a 5.x one")

        // Real server jar download, verified by hash. It isn't run.
        let build = try await SoftwareCatalog.latestBuild(.paper, mc: "1.21.11")!
        c.profile.software.mcVersion = ""
        try await c.installSoftware(build)
        equal(c.profile.software.jarName, build.fileName, "jar installed")
        equal(c.profile.software.requiredJava, 21, "java recorded")
        check(FileOps.exists(root.appendingPathComponent(build.fileName)), "jar in place")
        var blocked = ""
        do {
            let older = try await SoftwareCatalog.latestBuild(.paper, mc: "1.20.6")!
            try await c.installSoftware(older)
        } catch { blocked = error.localizedDescription }
        check(blocked.contains("can't go back"), "downgrade refused: \(blocked)")
    } catch { failures.append("live API: \(error)") }
}

/// Real Paper offering a pack this app serves, through a staged update and a restart. Bots stand in for the game,
/// so this shows the offer and the download agree. It can't show the game accepting the pack.
@MainActor func runRealPack() async {
    section("REAL PACK SERVING (EULA accepted by the person running this)")
    do {
        let port = 25591, hostPort = 28770
        let root = folder("real-pack")
        write("server-port=\(port)\nonline-mode=false\nnetwork-compression-threshold=-1\nview-distance=4\nsimulation-distance=4\nlevel-type=minecraft\\:flat\n", root.appendingPathComponent("server.properties"))
        let c = try await ServerController.adopt(root: root, name: "real-pack")
        try EULA.accept(c.paths)
        try await c.installSoftware(try await SoftwareCatalog.latestBuild(.paper, mc: "1.21.11")!)
        c.profile.lastPluginCheck = Date(); c.profile.software.lastCheck = Date()
        defer { c.stopPackHost(); c.forceStop(); c.stopTicker() }
        let runtimes = await JavaManager.discover()
        guard let java = JavaManager.best(for: 21, in: runtimes) else { failures.append("no Java 21"); return }
        let table = try await ProtocolTable.load(mc: "1.21.11", cache: folder("real-pack-protocol"), java: java.path)

        let first = try await ResourcePacks.add(await makePack("Made Up First", ["pack.mcmeta": #"{"pack":{"pack_format":75,"description":"first"}}"#, "assets/minecraft/textures/block/stone.png": "first"]))
        let second = try await ResourcePacks.add(await makePack("Made Up Second", ["pack.mcmeta": #"{"pack":{"pack_format":75,"description":"second"}}"#, "assets/minecraft/textures/block/stone.png": "second"]))
        var recipe = PackRecipe()
        recipe.name = "real-one"
        recipe.entries = [PackRecipe.Entry(pack: first.id, version: first.latest!.sha1)]
        let oldBuild = try await ResourcePacks.combine(recipe)
        recipe.entries = [PackRecipe.Entry(pack: second.id, version: second.latest!.sha1)]
        let newBuild = try await ResourcePacks.combine(recipe)

        try c.setPackHost(address: "http://127.0.0.1:\(hostPort)", port: hostPort)
        try c.startPackHost()
        await checkUntil(5, "serving") { c.packHostIsListening }
        let url = c.packAddress(recipe: recipe.name)!
        equal(try await c.usePack(url: url, sha1: oldBuild.sha1, required: true, recipe: recipe.name), .saved, "set while stopped")

        // Stopping the host here shows a server start brings it back.
        c.stopPackHost(remember: false)
        await c.start()
        await checkUntil(240, "up: \(c.state)") { c.state == .running }
        check(c.packHostIsListening, "starting the server starts serving")

        func offered(_ name: String, expect sha1: String, _ label: String) async throws {
            let bot = try await join(name, c, table, port: port)
            equal(bot.packOffer?.url, url, "\(label): the server offers this address")
            equal(bot.packOffer?.hash, sha1, "\(label): with this hash")
            check(bot.packOffer?.required == true, "\(label): required")
            let download = await PackHosting.check(url: bot.packOffer?.url ?? "", expected: bot.packOffer?.hash ?? "")
            check(download.ok, "\(label): what the bot was offered downloads and matches: \(download.summary)")
            await leave(bot, c)
        }
        try await offered("PackBotOne", expect: oldBuild.sha1, "first join")

        // A new build while running: staged, and old file and old hash stay together.
        await c.refreshPlugins()
        equal(try await c.usePack(url: url, sha1: newBuild.sha1, required: true, recipe: recipe.name), .staged, "a running server stages it")
        equal(c.servedPackSHA1(recipe: recipe.name), oldBuild.sha1, "the address still gives the old build")
        try await offered("PackBotTwo", expect: oldBuild.sha1, "before the restart")

        // Across the restart they switch together.
        c.stop()
        await checkUntil(90, "stopped: \(c.state)") { !c.state.isLive }
        await c.start()
        await checkUntil(240, "back up: \(c.state)") { c.state == .running }
        equal(c.servedPackSHA1(recipe: recipe.name), newBuild.sha1, "after the restart the address gives the new build")
        try await offered("PackBotThree", expect: newBuild.sha1, "after the restart")

        // A declining bot still gets Minecraft's own answer, and nothing here changes it.
        let decliner = try Bot(name: "PackBotFour", port: port, table: table, packAnswer: 1)
        await checkUntil(30, "a required pack declined disconnects") { decliner.packOffer != nil && !c.players.contains("PackBotFour") }
        decliner.leave()
        c.stop()
        await checkUntil(90, "stopped at the end: \(c.state)") { !c.state.isLive }
    } catch { failures.append("real pack serving threw: \(error)") }
}

@MainActor func runRealPaper() async {
    section("REAL PAPER (EULA accepted by the person running this)")
    do {
        let root = folder("real-server")
        write("server-port=25599\nonline-mode=false\nview-distance=4\nsimulation-distance=4\nmotd=before\nlevel-type=minecraft\\:flat\n", root.appendingPathComponent("server.properties"))
        let c = try await ServerController.adopt(root: root, name: "Real test")
        defer { c.forceStop(); c.stopTicker() }
        try EULA.accept(c.paths)
        let build = try await SoftwareCatalog.latestBuild(.paper, mc: "1.21.11")!
        try await c.installSoftware(build)
        try await c.addPlugin(source: .modrinth(project: "luckperms", allowBeta: false))
        try await c.addPlugin(source: Multiverse.source)
        await scenario(c, startupTimeout: 240, port: 25599)
        check(c.console.contains { $0.text.contains("Enabling LuckPerms") }, "real plugin loaded")
        // Real Multiverse: create, then delete through the one-time code.
        c.profile.launch.extraJVMArgs = ""
        c.profile.launch.restartOnCrash = false
        await c.start()
        await checkUntil(240, "up for Multiverse: \(c.state)") { c.state == .running }
        var w = NewWorld(); w.name = "ljtest"; w.type = .flat
        try await c.createWorld(w)
        equal(c.worldOperation?.succeeded, true, "real world created: \(c.console.suffix(4).map(\.text))")
        print("    worlds: \(c.worlds.map { "\($0.name) managed=\($0.isManaged) path=\($0.relativePath ?? "-")" })")
        dumpLayout(c, "1.21.11 after create")
        let made = c.worlds.first { $0.name.hasSuffix("ljtest") }
        check(made?.isManaged == true, "real world parsed from worlds.yml")
        let mainWorld = c.worlds.first { $0.isMain }
        check(mainWorld?.isManaged == true && mainWorld?.relativePath == "world", "real main world tied to its folder")
        check(c.worlds.allSatisfy { !$0.folderMissing || $0.name.contains("ljtest") }, "no ghost worlds on real Paper")
        if let made {
            try await c.modifyWorld(made, property: "alias", value: "Test")
            equal(c.worldOperation?.succeeded, true, "real modify: \(c.console.suffix(3).map(\.text))")
            try await c.modifyWorld(made, property: "gamemode", value: "CREATIVE")
            equal(c.worldOperation?.succeeded, true, "real modify gamemode: \(c.console.suffix(3).map(\.text))")
            let edited = c.worlds.first { $0.name == made.name }
            equal(edited?.multiverse?.alias, "Test", "alias saved to worlds.yml")
            print("    edited: gamemode=\(edited?.multiverse?.gamemode ?? "-") environment=\(edited?.multiverse?.environment ?? "-")")
            try await c.loadWorld(made.name)
            equal(c.worldOperation?.succeeded, false, "already-loaded reported at once, not as success")
            print("    load already-loaded: \(c.console.suffix(2).map(\.text))")
            try await c.unloadWorld(made)
            equal(c.worldOperation?.succeeded, true, "real unload: \(c.console.suffix(3).map(\.text))")
            try await c.loadWorld(made.name)
            equal(c.worldOperation?.succeeded, true, "real load: \(c.console.suffix(3).map(\.text))")
            try await c.deleteWorld(made)
            equal(c.worldOperation?.succeeded, true, "real delete confirmed: \(c.console.suffix(5).map(\.text))")
        }
        c.stop()
        await checkUntil(90, "stopped after Multiverse") { c.state == .stopped }

        // Real config files, as real Paper wrote them: forms must read them and not damage them.
        c.refreshConfigs()
        var checkedFields = 0
        for file in c.configs where ConfigForm.supports(file.format) {
            let text = c.liveConfigText(file)
            let fields = ConfigForm.fields(text, format: file.format)
            print("    \(file.path): \(fields.count) settings, \(fields.filter { $0.kind == .readOnly }.count) read-only")
            if file.path == "server.properties" || file.path == "bukkit.yml" || file.path == "spigot.yml" || file.path.hasPrefix("config/paper-") {
                check(fields.count > 5, "\(file.path) has settings")
            }
            for field in fields where field.kind != .readOnly {
                checkedFields += 1
                if file.format == .yaml, !text.components(separatedBy: "\n")[field.line].contains("'"), !text.components(separatedBy: "\n")[field.line].contains("\"") {
                    equal(ConfigForm.set(field, to: field.value, in: text, format: .yaml), text, "no-op in \(file.path): \(field.id)")
                }
                let changed = field.kind == .bool ? (field.value.lowercased() == "true" ? "false" : "true") : (field.kind == .text ? "changed" : "7")
                let out = ConfigForm.set(field, to: changed, in: text, format: file.format)
                let after = ConfigForm.fields(out, format: file.format)
                equal(after.count, fields.count, "edit keeps the structure in \(file.path): \(field.id)")
                equal(after.first { $0.id == field.id }?.value, changed, "edit reads back in \(file.path): \(field.id)")
                equal(after.filter { $0.id != field.id }.map(\.value), fields.filter { $0.id != field.id }.map(\.value), "others untouched in \(file.path): \(field.id)")
            }
        }
        print("    round-tripped \(checkedFields) real settings")
        check(checkedFields > 100, "plenty of real settings exercised")

        // A form edit to real files survives a real boot: Paper accepts it, and uses it.
        let bukkit = c.configs.first { $0.path == "bukkit.yml" }!
        let bukkitFields = ConfigForm.fields(c.liveConfigText(bukkit), format: .yaml)
        let monsters = bukkitFields.first { $0.path == ["spawn-limits", "monsters"] }!
        let propsFile = c.configs.first { $0.path == "server.properties" }!
        try c.saveConfig(bukkit, text: ConfigForm.set(monsters, to: "42", in: c.liveConfigText(bukkit), format: .yaml))
        let viewDistance = ConfigForm.fields(c.liveConfigText(propsFile), format: .properties).first { $0.path == ["view-distance"] }!
        try c.saveConfig(propsFile, text: ConfigForm.set(viewDistance, to: "5", in: c.liveConfigText(propsFile), format: .properties))
        await c.start()
        await checkUntil(240, "boots with form edits") { c.state == .running }
        c.send("whitelist add LeafJuiceTest")
        try? await Task.sleep(for: .seconds(3))
        print("    allowlist: \(c.console.suffix(2).map(\.text)) entries=\(PlayerList.entries(c.liveConfigText(ConfigFile(path: "whitelist.json", title: "", summary: "", group: "", format: .json, policy: .stagedWhileRunning))))")
        c.stop()
        await checkUntil(90, "stopped after form edits") { c.state == .stopped }
        let monstersAfter = ConfigForm.fields(c.liveConfigText(bukkit), format: .yaml).first { $0.path == ["spawn-limits", "monsters"] }
        equal(monstersAfter?.value, "42", "Paper kept the form's edit")
        equal(PropertiesDocument(c.liveConfigText(propsFile)).value("view-distance"), "5", "properties edit kept")

        // Demo: rename a real world and boot on it, then the main world, then undo.
        section("REAL RENAMES")
        await c.start()
        await checkUntil(240, "up for rename demo") { c.state == .running }
        var demo = NewWorld(); demo.name = "renameme"
        try await c.createWorld(demo)
        equal(c.worldOperation?.succeeded, true, "world to rename created")
        let levelDat = NBT.Document(root: try NBT.read(c.paths.root.appendingPathComponent("world/level.dat")).root)
        equal(try NBT.encode(NBT.Document(root: levelDat.root)).isEmpty, false, "real level.dat readable"); check(levelDat.root["Data"]?["LevelName"]?.stringValue == "world", "real LevelName read")
        await c.refreshWorlds()
        let target = c.worlds.first { $0.name.hasSuffix("renameme") }!
        let realPlan = c.worldRenamePlan(target, to: "renamed")
        print("    plan: \(realPlan.items.map { "\($0.description): \($0.changes.first ?? "")" })")
        try await c.applyRename(realPlan, rebuild: { c.worldRenamePlan(target, to: "renamed") }, restart: true)
        await checkUntil(240, "boots after world rename") { c.state == .running }
        await c.refreshWorlds()
        print("    after: \(c.worlds.map { "\($0.name)=\($0.relativePath ?? "-")" })")
        check(c.worlds.contains { $0.name == "minecraft:renamed" && $0.relativePath == "renamed" }, "real world renamed and tied to its folder")
        check(!c.worlds.contains { $0.name.hasSuffix("renameme") }, "old name gone")
        check(!c.console.contains { $0.level == .error && $0.text.lowercased().contains("renameme") }, "no errors about the old name")
        c.send("mv list")
        try? await Task.sleep(for: .seconds(2))
        print("    mv list: \(c.console.suffix(6).map(\.text))")
        check(c.console.suffix(10).contains { $0.text.contains("renamed - ") && !$0.text.contains("UNLOADED") }, "Multiverse has it loaded under the new name")
        check(!c.console.suffix(10).contains { $0.text.contains("renameme") }, "and the old name is gone from Multiverse")
        check(FileOps.exists(c.paths.root.appendingPathComponent("renamed/level.dat")), "world folder intact")
        equal(try NBT.read(c.paths.root.appendingPathComponent("renamed/level.dat")).root["Data"]?["LevelName"]?.stringValue, "renamed", "stored name changed")
        print("    worlds.yml keys now: \((try String(contentsOf: c.paths.plugins.appendingPathComponent("Multiverse-Core/worlds.yml"), encoding: .utf8)).split(separator: "\n").filter { $0.contains("legacy-world-name") || !$0.hasPrefix(" ") })")
        c.keepUpgrade()
        // Main world.
        await c.refreshWorlds()
        let mainPlan = c.worldRenamePlan(c.worlds.first { $0.isMain }!, to: "homebase")
        let mainEntry = c.worlds.first { $0.isMain }!
        try await c.applyRename(mainPlan, rebuild: { c.worldRenamePlan(mainEntry, to: "homebase") }, restart: true)
        await checkUntil(240, "boots after main world rename") { c.state == .running }
        check(FileOps.exists(c.paths.root.appendingPathComponent("homebase/level.dat")), "main folder renamed")
        check(!FileOps.exists(c.paths.root.appendingPathComponent("world")), "and no new world generated under the old name")
        check(c.console.contains { $0.text.contains("homebase") }, "server loads it")
        c.send("mv list")
        try? await Task.sleep(for: .seconds(2))
        print("    mv list after main rename: \(c.console.suffix(6).map(\.text))")
        check(c.console.suffix(8).contains { $0.text.contains("homebase - NORMAL") }, "main world loaded under its new name")
        check(c.console.suffix(8).contains { $0.text.contains("homebase_nether - NETHER") }, "its Nether too")
        check(c.console.suffix(8).contains { $0.text.contains("renamed - ") && !$0.text.contains("UNLOADED") }, "earlier renamed world still loads")
        await c.refreshWorlds()
        print("    after main: \(c.worlds.map { "\($0.name)=\($0.relativePath ?? "-")" })")
        // Undo restores the original and it boots.
        try await c.rollBackUpgrade()
        check(FileOps.exists(c.paths.root.appendingPathComponent("world/level.dat")), "undo brings back the name")
        await c.start()
        await checkUntil(240, "boots after undo") { c.state == .running }
        c.requestTPS()
        await checkUntil(10, "real TPS read: \(c.console.suffix(2).map(\.text))") { c.tps != nil }
        print("    tps: \(String(describing: c.tps))")
        if !c.shelved.isEmpty { try c.deleteShelved(c.shelved[0]) }
        // Comparing real backups.
        let before = try await c.backupNow(trigger: "manual")
        c.send("save-all flush")
        try? await Task.sleep(for: .seconds(3))
        c.stop()
        await checkUntil(90, "stopped for compare") { c.state == .stopped }
        var props = PropertiesDocument(c.liveConfigText(c.configs.first { $0.path == "server.properties" }!)); props.set("max-players", "33")
        try FileOps.writeAtomic(props.text, to: c.paths.properties)
        let after = try await c.backupNow(trigger: "manual")
        let realDiff = try await BackupCompare.compare(before, after, profile: c.profile, paths: c.paths)
        check(realDiff.settings.contains { $0.key == "max-players" && $0.after == "33" }, "real diff: \(realDiff.settings.map(\.key).prefix(6))")
        print("    diff: settings=\(realDiff.settings.count) worlds=\(realDiff.worlds.map { "\($0.name):\($0.chunksChanged)" }) other=\(realDiff.otherFilesChanged)")

        // A real test copy of a real upgrade, while keeping the original.
        section("REAL TEST COPY: upgrade to 26.3")
        c.isTrialFast = true
        if !c.runtimes.contains(where: { $0.major >= 25 }) { try await c.installJava(major: 25) }
        let trialBuild = try await SoftwareCatalog.latestBuild(.paper, mc: "26.3")!
        let jarBefore = c.profile.software.jarName
        await c.startTrial(.software(trialBuild))
        print("    report: \(String(describing: c.trialReport))")
        equal(c.trialReport?.booted, true, "real upgrade boots in the copy")
        equal(c.profile.software.jarName, jarBefore, "real server untouched")
        check(FileOps.exists(c.paths.root.appendingPathComponent("world_nether")), "real world still old-style")
        await c.collapseTrial()

        // The riskiest path there is: a real upgrade across the 26.x world layout change, and back.
        section("REAL UPGRADE: 1.21.11 to 26.3 and back")
        let levelBefore = try Data(contentsOf: c.paths.root.appendingPathComponent("world/level.dat"))
        try await c.installJava(major: 25)
        print("    java: \(c.runtimes.map(\.label))")
        check(c.runtimes.contains { $0.major == 25 && $0.managed }, "Temurin 25 installed and runs")
        let newest = try await SoftwareCatalog.latestBuild(.paper, mc: "26.3")!
        try await c.installSoftware(newest)
        equal(c.profile.software.mcVersion, "26.3", "upgraded: \(c.pending.map { $0.conflict ?? "" })")
        check(c.activeUpgrade != nil, "awaiting a decision")
        check(c.backups.contains { $0.trigger == "before-upgrade" && $0.pinned }, "verified restore point pinned")
        equal(c.resolvedJava()?.major, 25, "picks Java 25 for 26.3")
        await c.start()
        await checkUntil(300, "26.3 boots and migrates (blockers: \(c.blockers.map(\.title)), last: \(c.console.suffix(3).map(\.text)))") { c.state == .running }
        await c.refreshWorlds()
        dumpLayout(c, "26.3 after migration")
        var w2 = NewWorld(); w2.name = "ljnew"
        try await c.createWorld(w2)
        equal(c.worldOperation?.succeeded, true, "world created on 26.3: \(c.console.suffix(4).map(\.text))")
        dumpLayout(c, "26.3 after create")
        try await c.rollBackUpgrade()   // Stops the server itself.
        check(c.state == .stopped, "stopped for rollback: \(c.state)")
        equal(c.profile.software.mcVersion, "1.21.11", "back on 1.21.11")
        equal(c.shelved.count, 1, "upgraded server on the Shelf")
        equal(try Data(contentsOf: c.paths.root.appendingPathComponent("world/level.dat")), levelBefore, "pre-upgrade world restored byte for byte")
        check(FileOps.exists(c.paths.root.appendingPathComponent("world_nether")), "old-style Nether folder back")
        let marker = c.console.count
        await c.start()
        await checkUntil(240, "the old world opens again on 1.21.11 (last: \(c.console.suffix(3).map(\.text)))") { c.state == .running }
        check(!c.console.dropFirst(max(0, marker)).contains { $0.text.lowercased().contains("newer version") }, "no newer-world complaints")
        c.stop()
        await checkUntil(90, "stopped after rollback") { c.state == .stopped }
        check(c.issues.contains { $0.ruleID == "offline-mode" }, "rule fires on real output: \(c.issues.map(\.title).prefix(6))")
    } catch { failures.append("real paper: \(error)") }
}

@MainActor func runLifecycleWithStandIn() async {
    section("Server lifecycle (stand-in jar)")
    let runtimes = await JavaManager.discover()
    guard let jdk = runtimes.first(where: { FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: $0.path).deletingLastPathComponent().appendingPathComponent("javac").path) }) else {
        print("  skipped: no JDK found")
        return
    }
    do {
        let root = folder("standin-server")
        try await buildStandIn(jdk: jdk, into: root.appendingPathComponent("standin.jar"))
        write("server-port=25597\nmotd=before\nlevel-name=world\n", root.appendingPathComponent("server.properties"))
        write("{}", root.appendingPathComponent("bukkit.yml"))
        makeJarInPlugins(root, "Foo")
        makeJar(root.appendingPathComponent("plugins/Multiverse-Core.jar"), yaml: "name: Multiverse-Core\nversion: 5.8.2\nmain: org.mvplugins.multiverse.core.MultiverseCore\napi-version: 1.13\n")
        let c = try await ServerController.adopt(root: root, name: "Stand-in")
        c.requiresEULA = false
        c.profile.software.flavor = .custom
        c.profile.software.jarName = "standin.jar"
        c.profile.software.mcVersion = "1.21.11"
        c.profile.software.requiredJava = jdk.major
        c.profile.launch.javaPath = jdk.path
        c.profile.launch.preset = .none
        c.profile.lastPluginCheck = Date()
        c.profile.software.lastCheck = Date()
        c.profile.backup.scope = .standard
        await scenario(c, startupTimeout: 30, port: 25597)
    } catch { failures.append("lifecycle: \(error)") }
}

func makeJarInPlugins(_ root: URL, _ name: String) {
    let plugins = root.appendingPathComponent("plugins", isDirectory: true)
    try! FileOps.ensureDir(plugins)
    makeJar(plugins.appendingPathComponent("\(name).jar"), yaml: "name: \(name)\nversion: 1.0\nmain: com.acme.\(name.lowercased()).Main\napi-version: 1.21\n")
}

/// A tiny program that talks like a Minecraft server, so the lifecycle can be tested without one.
func buildStandIn(jdk: JavaRuntime, into jar: URL) async throws {
    let source = #"""
    import java.io.*; import java.net.*; import java.nio.file.*; import java.util.*;
    public class StandIn {
      static String pending = "";
      static void log(String level, String text) { System.out.println("[12:00:00 " + level + "]: " + text); System.out.flush(); }
      public static void main(String[] args) throws Exception {
        Properties p = new Properties();
        try (var in = Files.newInputStream(Path.of("server.properties"))) { p.load(in); }
        ServerSocket socket = new ServerSocket(Integer.parseInt(p.getProperty("server-port", "25565")));
        Files.createDirectories(Path.of("world/region"));
        Files.writeString(Path.of("world/level.dat"), "level");
        Files.writeString(Path.of("world/region/r.0.0.mca"), "region " + p.getProperty("motd"));
        log("INFO", "Starting minecraft server version 1.21.11");
        log("WARN", "**** SERVER IS RUNNING IN OFFLINE/INSECURE MODE!");
        for (var plugin : Objects.requireNonNull(new File("plugins").list())) if (plugin.endsWith(".jar")) log("INFO", "Enabling " + plugin);
        for (var plugin : Objects.requireNonNull(new File("plugins").list())) if (plugin.equals("Bad.jar")) { log("ERROR", "Error occurred while enabling Bad v1.0 (Is it up to date?)"); }
        if (new File("crash-on-boot").exists()) { log("ERROR", "Simulated boot failure"); System.exit(5); }
        if (new File("quit-on-boot").exists()) { log("ERROR", "Failed to start the minecraft server"); System.exit(0); }
        if (new File("slow-boot").exists()) { Thread.sleep(15000); }
        log("INFO", "Done (1.234s)! For help, type \"help\"");
        var reader = new BufferedReader(new InputStreamReader(System.in));
        String line;
        while ((line = reader.readLine()) != null) {
          switch (line.split(" ")[0]) {
            case "list" -> log("INFO", "There are 0 of a max of 20 players online:");
            case "save-off" -> log("INFO", "Automatic saving is now disabled");
            case "save-on" -> log("INFO", "Automatic saving is now enabled");
            case "save-all" -> { log("INFO", "Saving the game (this may take a moment!)"); log("INFO", "Saved the game"); }
            case "say" -> log("INFO", "[Server] " + line.substring(4));
            case "join" -> log("INFO", "Steve joined the game");
            case "leave" -> log("INFO", "Steve left the game");
            case "boom" -> {
              log("ERROR", "Error occurred while enabling Foo v1.0 (Is it up to date?)");
              System.out.println("java.lang.IllegalStateException: nope");
              System.out.println("\tat com.acme.foo.Main.onEnable(Main.java:10)");
            }
            case "crash" -> { log("ERROR", "Exception in server tick loop"); System.exit(3); }
            case "mv" -> {
              var p2 = line.split(" ");
              var yml = Path.of("plugins/Multiverse-Core/worlds.yml");
              Files.createDirectories(yml.getParent());
              if (p2[1].equals("create")) { Files.writeString(yml, p2[2] + ":\n  environment: " + p2[3].toUpperCase() + "\n"); Files.createDirectories(Path.of(p2[2])); Files.writeString(Path.of(p2[2] + "/level.dat"), "x"); log("INFO", "World '" + p2[2] + "' created!"); }
              else if (p2[1].equals("delete")) { pending = p2[2]; log("INFO", "Are you sure you want to delete world '" + p2[2] + "'?"); log("INFO", "Run /mv confirm 726 to continue. This will expire in 30 seconds."); }
              else if (p2[1].equals("confirm")) {
                if (p2.length < 3 || !p2[2].equals("726")) log("INFO", "Invalid OTP number");
                else { Files.deleteIfExists(Path.of(pending + "/level.dat")); Files.deleteIfExists(Path.of(pending)); Files.writeString(yml, ""); log("INFO", "Deleting world '" + pending + "'..."); log("INFO", "World '" + pending + "' deleted!"); }
              }
              else if (p2[1].equals("load") && p2[2].equals("nosuchworld")) log("INFO", "World 'nosuchworld' not found!");
              else if (p2[1].equals("load")) log("INFO", "World '" + p2[2] + "' loaded!");
              else if (p2[1].equals("unload")) log("INFO", "World '" + p2[2] + "' unloaded!");
            }
            case "tps" -> log("INFO", "TPS from last 1m, 5m, 15m: *20.0, 19.5, 18.25");
            case "mspt" -> { log("INFO", "Server tick times (avg/min/max) from last 5s, 10s, 1m:"); log("INFO", "1.2/0.9/3.1, 1.5/0.8/4.0, 2.5/0.7/9.9"); }
            case "stop" -> { log("INFO", "Stopping the server"); socket.close(); System.exit(0); }
            default -> log("INFO", "Unknown command");
          }
        }
      }
    }
    """#
    let work = folder("standin-src-\(UUID().uuidString)")
    let file = work.appendingPathComponent("StandIn.java")
    write(source, file)
    let bin = URL(fileURLWithPath: jdk.path).deletingLastPathComponent()
    let compile = try await Tool.run(bin.appendingPathComponent("javac").path, ["-d", work.path, file.path])
    guard compile.ok else { throw LeafError("javac: \(compile.err)") }
    let pack = try await Tool.run(bin.appendingPathComponent("jar").path, ["cfe", jar.path, "StandIn", "-C", work.path, "StandIn.class"])
    guard pack.ok else { throw LeafError("jar: \(pack.err)") }
}

/// The whole life of a server, against whichever jar it's given.
@MainActor func scenario(_ c: ServerController, startupTimeout: Int, port: Int) async {
    do {
        c.profile.backup.enabled = false
        c.profile.launch.restartOnCrash = false
        c.profile.launch.maxMemoryMB = 2048
        c.profile.launch.minMemoryMB = 1024
        c.profile.lastPluginCheck = Date()
        c.profile.software.lastCheck = Date()
        await c.refreshPlugins()

        let blockers = await c.preflight()
        equal(blockers.map(\.title), [], "ready to start")

        await c.start()
        check(c.state == .starting, "starting: \(c.state)")
        await checkUntil(startupTimeout, "reached running (last: \(c.console.suffix(3).map(\.text)))") { c.state == .running }
        check(SystemInfo.isPortBusy(port), "port detected as busy")
        let busy = await c.preflight()
        check(busy.contains { if case .portBusy = $0.kind { true } else { false } }, "preflight sees the port")
        await c.tick()
        try? await Task.sleep(for: .seconds(1))
        await c.tick()
        check(c.metrics?.memoryBytes ?? 0 > 5_000_000, "metrics read: \(String(describing: c.metrics))")
        check(c.metrics.map { $0.cpuPercent >= 0 } ?? false, "cpu read")

        // Console round trip, and a slash is forgiven.
        c.send("/list")
        await checkUntil(15, "command answered") { c.console.contains { $0.text.contains("players online") } }

        // Editing while running.
        let props = c.configs.first { $0.path == "server.properties" }!
        var doc = PropertiesDocument(c.configText(props))
        doc.set("motd", "after")
        equal(try c.saveConfig(props, text: doc.text), .staged, "running edit is staged")
        check(!(try! String(contentsOf: c.paths.properties, encoding: .utf8)).contains("motd=after"), "live file untouched")
        check(c.configText(props).contains("motd=after"), "editor sees staged text")
        check(c.hasStagedEdit(props), "marked as staged")
        check(c.needsRestart, "restart wanted")
        let ops = ConfigFile(path: "ops.json", title: "ops", summary: "", group: "", format: .json, policy: .lockedWhileRunning(hint: "use /op"))
        var refused = false
        do { try c.saveConfig(ops, text: "[]") } catch { refused = true }
        check(refused, "locked file refused while running")
        var invalid = false
        do { try c.saveConfig(ConfigFile(path: "x.yml", title: "x", summary: "", group: "", format: .yaml, policy: .stagedWhileRunning), text: "a:\n\tb: 1") } catch { invalid = true }
        check(invalid, "invalid edit refused")

        // Plugin changes are queued while running.
        let plugin = c.plugins[0]
        try await c.setEnabled(false, plugin: plugin)
        check(FileOps.exists(c.paths.plugins.appendingPathComponent(plugin.fileName)), "toggle queued, jar still in place")
        equal(c.pending.count, 2, "two pending changes")
        // A second edit replaces the first rather than stacking.
        doc.set("motd", "after2")
        try c.saveConfig(props, text: doc.text)
        equal(c.pending.count, 2, "edits to one file coalesce")

        // Backup while running pauses saving, then resumes it.
        let backup = try await c.backupNow()
        check(backup.size > 100, "backup while running: \(backup.size)")
        check(c.console.contains { $0.text.lowercased().contains("saved the game") }, "save confirmed before archiving")
        try? await Task.sleep(for: .milliseconds(400))
        check(c.console.contains { $0.text.lowercased().contains("automatic saving is now enabled") }, "saving resumed")
        print("    backup: \(Format.bytes(backup.size))")

        // A restart at a set time warns players, then applies the queue.
        c.profile.restart.warnings = [30, 3]
        c.scheduleRestart(RestartPlan(at: Date().addingTimeInterval(6), reason: "Test restart"))
        check(c.restartPlan != nil, "planned")
        for _ in 0..<40 {
            await c.tick()
            if c.state != .running { break }
            try? await Task.sleep(for: .seconds(1))
        }
        check(c.console.contains { $0.text.contains("restarting in 30 seconds") }, "first warning sent once inside its window")
        check(c.console.contains { $0.text.contains("restarting in 3 seconds") }, "last warning sent")
        await checkUntil(startupTimeout, "came back running: \(c.state)") { c.state == .running }
        equal(c.pending.count, 0, "queue empty after restart: \(c.pending.map { $0.conflict ?? $0.summary })")
        check((try! String(contentsOf: c.paths.properties, encoding: .utf8)).contains("motd=after2"), "staged edit landed")
        check(FileOps.exists(c.paths.plugins.appendingPathComponent(plugin.fileName + ".disabled")), "toggle landed")
        check(c.backups.contains { $0.trigger == "before-update" } == false, "toggles alone don't force a backup")
        check(FileOps.children(c.paths.configHistory).contains { $0.lastPathComponent.hasPrefix("server.properties.") }, "history kept")

        // Restart when empty waits for players to leave. Only the stand-in has this hook.
        if c.profile.software.jarName == "standin.jar" {
            c.send("join")
            await checkUntil(5, "player tracked") { c.players == ["Steve"] }
            c.scheduleRestart(RestartPlan(whenEmpty: true, reason: "Empty"))
            await c.tick()
            check(c.state == .running && c.restartPlan != nil, "waits while someone's online")
            c.send("leave")
            await checkUntil(5, "player left") { c.players.isEmpty }
            await c.tick()
            check(c.restartPlan == nil, "restarts once empty")
            await checkUntil(startupTimeout, "back from empty restart") { c.state == .running }

            // Catalogued with its stack and attributed through the plugin's main package.
            try await c.setEnabled(true, plugin: InstalledPlugin(fileName: plugin.fileName + ".disabled", enabled: false, descriptor: plugin.descriptor, digests: nil, size: 0))
            c.send("boom")
            await checkUntil(5, "error catalogued") { c.issues.contains { $0.ruleID == "plugin-enable-failed" } }
            let issue = c.issues.first { $0.ruleID == "plugin-enable-failed" }
            equal(issue?.title, "Foo crashed while starting", "issue title")
            check(issue?.stack.count == 2, "stack kept: \(issue?.stack ?? [])")
            check(c.issues.contains { $0.ruleID == "offline-mode" }, "rule fired on output")
        }

        // Worlds, through Multiverse's own commands.
        if c.profile.software.jarName == "standin.jar" {
            // TPS is read, and stays out of the console.
            let linesBefore = c.console.count
            c.requestTPS()
            await checkUntil(5, "tps read") { c.tps != nil }
            equal(c.tps?.oneMinute, 20, "tps value"); equal(c.tps?.fifteenMinutes, 18.25, "tps 15m")
            check(!c.console.dropFirst(linesBefore).contains { $0.text.contains("TPS from") }, "the app's own tps check stays out of the console")
            await checkUntil(5, "mspt read") { c.mspt != nil }
            equal(c.mspt, 2.5, "mspt value")
            check(!c.console.dropFirst(linesBefore).contains { $0.text.contains("tick times") || $0.text.contains("1.2/0.9") }, "mspt stays out of the console too")
            check(c.timeline.contains { $0.kind == .start }, "start on the timeline")

            equal(c.multiverseMajor, 5, "multiverse detected")
            var refused = ""
            do { var bad = NewWorld(); bad.name = "x\nstop"; try await c.createWorld(bad) } catch { refused = error.localizedDescription }
            check(!refused.isEmpty, "unsafe world name refused"); check(c.state == .running, "and nothing was sent")
            var moon = NewWorld(); moon.name = "moon"
            try await c.createWorld(moon)
            equal(c.worldOperation?.succeeded, true, "world created: \(c.console.suffix(2).map(\.text))")
            let created = c.worlds.first { $0.name == "moon" }
            check(created?.isManaged == true, "new world appears, managed: \(c.worlds.map(\.name))")
            try await c.loadWorld("moon")
            equal(c.worldOperation?.succeeded, true, "world loaded")
            let quickStart = Date()
            c.send("say unrelated")
            try await c.loadWorld("nosuchworld")
            equal(c.worldOperation?.succeeded, false, "failure reply ends the wait")
            check(Date().timeIntervalSince(quickStart) < 30, "without sitting out the timeout")
            let main = c.worlds.first { $0.isMain }!
            var protected = ""
            do { try await c.deleteWorld(main) } catch { protected = error.localizedDescription }
            check(!protected.isEmpty, "main world can't be deleted")
            try await c.deleteWorld(created!)
            equal(c.worldOperation?.succeeded, true, "delete confirmed with the code from its prompt: \(c.console.suffix(4).map(\.text))")
            check(c.console.contains { $0.text.contains("mv confirm 726") }, "one-time code sent")
            check(c.backups.contains { $0.trigger == "before-world-delete" }, "backed up first")
            check(!c.worlds.contains { $0.name == "moon" }, "gone from the list")
            check(!FileOps.exists(c.paths.root.appendingPathComponent("moon")), "folder gone")
        }

        // Snapshots while playing, from what the server logs. Stand-in only: no real client here.
        if c.profile.software.jarName == "standin.jar" {
            let id = "069a79f4-44e9-4726-a5be-fca90e38aaf5"
            let p = PlayerPaths(c.paths)
            try NBT.write(NBT.Document(root: .compound([.init("Inventory", .list(10, []))])), to: p.data(id))
            write(#"[{"name":"Steve","uuid":"\#(id)"}]"#, c.paths.root.appendingPathComponent("usercache.json"))
            c.profile.playerSnapshots.intervalMinutes = 1
            c.send("join")
            await checkUntil(5, "player online") { c.players.contains("Steve") }
            c.tickPlayerSnapshots(elapsed: 30)
            equal(PlayerSnapshots.list(uuid: id, profile: c.profile).count, 0, "not due yet")
            c.tickPlayerSnapshots(elapsed: 31)
            equal(PlayerSnapshots.list(uuid: id, profile: c.profile).first?.trigger, "playing", "taken after the play time")
            c.tickPlayerSnapshots(elapsed: 30)
            equal(PlayerSnapshots.list(uuid: id, profile: c.profile).count, 1, "counter restarted")
            // Restoring an online player waits for the restart.
            let snap = PlayerSnapshots.list(uuid: id, profile: c.profile)[0]
            equal(try c.restorePlayer(snap, inventoryOnly: true, containers: []), .staged, "online player's restore waits")
            check(c.pending.contains { $0.target == "player:\(id)" }, "queued")
            c.send("leave")
            await checkUntil(5, "player offline") { c.players.isEmpty }
            await checkUntil(8, "snapshot as they left") { PlayerSnapshots.list(uuid: id, profile: c.profile).contains { $0.trigger == "left" } }
            equal(try c.restorePlayer(snap, inventoryOnly: true, containers: []), .saved, "offline player without per-world files restores now")
            c.discard(c.pending.first { $0.target == "player:\(id)" }!)

            // A test copy: the real server keeps running, untouched.
            let portBefore = c.serverPort
            let propsBefore = try! String(contentsOf: c.paths.properties, encoding: .utf8)
            c.isTrialFast = true
            makeJar(c.paths.plugins.appendingPathComponent("DiscordSRV.jar"), yaml: "name: DiscordSRV\nversion: 1\nmain: a.D\n")
            await c.refreshPlugins()
            await c.startTrial(.custom(title: "A good change", { child in write("marker", child.paths.root.appendingPathComponent("changed.txt")) }))
            check(c.trialPhase == .finished, "finished: \(String(describing: c.trialPhase))")
            equal(c.trialReport?.passed, true, "good change passes: \(String(describing: c.trialReport))")
            check(c.state == .running, "real server still running"); equal(c.serverPort, portBefore, "real port unchanged")
            equal(try! String(contentsOf: c.paths.properties, encoding: .utf8), propsBefore, "real settings untouched")
            check(!FileOps.exists(c.paths.root.appendingPathComponent("changed.txt")), "the change stayed in the copy")
            let copyFolder = c.trialController!.paths.root
            check(c.trialController!.serverPort != portBefore, "copy on its own port")
            check(FileOps.exists(copyFolder.appendingPathComponent("plugins/DiscordSRV.jar.disabled")), "outward-facing plugin off in the copy")
            check(c.trialReport!.notes.contains { $0.contains("DiscordSRV") }, "and that's said")
            await c.collapseTrial()
            check(!FileOps.exists(copyFolder), "copy removed"); check(c.trialPhase == nil, "cleared")

            // A bad one fails, and the culprit is found by booting subsets.
            await c.startTrial(.custom(title: "A bad plugin", { child in
                makeJar(child.paths.plugins.appendingPathComponent("Bad.jar"), yaml: "name: Bad\nversion: 1\nmain: a.E\n")
                makeJar(child.paths.plugins.appendingPathComponent("Fine.jar"), yaml: "name: Fine\nversion: 1\nmain: a.F\n")
                await child.refreshPlugins()
            }))
            equal(c.trialReport?.passed, false, "failing plugin caught: \(String(describing: c.trialReport))")
            check(c.trialReport?.failedPlugins.contains { $0.contains("Bad") } == true, "named: \(c.trialReport?.failedPlugins ?? [])")
            await c.findTrialCulprit()
            check(c.trialReport?.culprit?.contains("Bad causes it") == true, "culprit found: \(c.trialReport?.culprit ?? "")")
            await c.collapseTrial()
            await c.startTrial(.custom(title: "Won't boot", { child in write("x", child.paths.root.appendingPathComponent("crash-on-boot")) }))
            equal(c.trialReport?.booted, false, "boot failure caught")
            await c.findTrialCulprit()
            check(c.trialReport?.culprit?.contains("even with no plugins") == true, "not blamed on a plugin: \(c.trialReport?.culprit ?? "")")
            await c.collapseTrial()
            var withManagement = PropertiesDocument(try String(contentsOf: c.paths.properties, encoding: .utf8))
            withManagement.set("management-server-enabled", "true")
            try FileOps.writeAtomic(withManagement.text, to: c.paths.properties)
            await c.startTrial(.custom(title: "Management server off in copies", { child in
                equal(PropertiesDocument(try String(contentsOf: child.paths.properties, encoding: .utf8)).value("management-server-enabled"), "false", "a test copy can't clash with the real server's management port")
            }))
            await c.collapseTrial()
            await c.startTrial(.custom(title: "Quits cleanly while starting", { child in write("x", child.paths.root.appendingPathComponent("quit-on-boot")) }))
            equal(c.trialReport?.booted, false, "a clean exit while starting isn't success")
            check(c.trialController?.issues.contains { $0.ruleID == "server-failed-start" } == true, "and is explained"); if case .crashed = c.trialController?.state { passed += 1 } else { failures.append("giving up should read as a failure: \(String(describing: c.trialController?.state))") }
            await c.collapseTrial()
            await c.startTrial(.custom(title: "Throws", { _ in throw LeafError("It went wrong") }))
            equal(c.trialReport?.failure, "It went wrong", "failure reported"); await c.collapseTrial()
            check(c.state == .running, "real server ran throughout")
            try? FileManager.default.removeItem(at: c.paths.plugins.appendingPathComponent("DiscordSRV.jar"))
            // The drill proves a backup boots, without touching the real server.
            let drillBackup = try await c.backupNow(trigger: "manual", scope: .everything)
            await c.runBackupDrill(drillBackup)
            equal(c.profile.lastDrill?.passed, true, "good backup proven: \(c.profile.lastDrill?.detail ?? "")")
            check(c.state == .running, "real server kept running"); check(c.timeline.contains { $0.kind == .drill }, "on the timeline")
            check(FileOps.children(c.paths.root.deletingLastPathComponent().appendingPathComponent("LeafJuice/test-copies")).isEmpty, "drill folder removed")
            let badArchive = Backups.destination(c.profile).appendingPathComponent(drillBackup.fileName)
            let goodBytes = try Data(contentsOf: badArchive)
            try Data(goodBytes.prefix(goodBytes.count / 2)).write(to: badArchive)
            await c.runBackupDrill(drillBackup)
            equal(c.profile.lastDrill?.passed, false, "damaged backup caught: \(c.profile.lastDrill?.detail ?? "")")
            check(c.issues.contains { $0.id == "wrapper:drill-failed" }, "and raised as an issue")
            try goodBytes.write(to: badArchive)
            await c.refreshPlugins()
        }

        // Stopping while it's still starting mustn't hang.
        if c.profile.software.jarName == "standin.jar" {
            c.stop()
            await checkUntil(30, "stopped first") { c.state == .stopped }
            write("x", c.paths.root.appendingPathComponent("slow-boot"))
            await c.start()
            try? await Task.sleep(for: .seconds(1))
            let stopAt = Date()
            c.stop()
            await checkUntil(12, "stops promptly while starting: \(c.state)") { c.state == .stopped }
            check(Date().timeIntervalSince(stopAt) < 12, "well under the two minute wait")
            try? FileManager.default.removeItem(at: c.paths.root.appendingPathComponent("slow-boot"))
            // A missing level.dat blocks a start rather than quietly making a new one.
            let dat = c.paths.root.appendingPathComponent("world/level.dat")
            let keep = try Data(contentsOf: dat)
            try FileManager.default.removeItem(at: dat)
            let blocked = await c.preflight()
            check(blocked.contains { $0.kind == .worldData }, "missing level.dat blocks starting: \(blocked.map(\.title))")
            try keep.write(to: dat)
            await c.start()
            await checkUntil(startupTimeout, "back up") { c.state == .running }
        }

        // Stop cleanly.
        c.stop()
        check(c.state == .stopping, "stopping")
        await checkUntil(60, "stopped: \(c.state)") { c.state == .stopped }
        check(!SystemInfo.isPortBusy(port), "port released")
        check(!FileOps.exists(c.paths.pid), "pid file cleaned")
        check(c.metrics == nil, "metrics cleared")
        try? await Task.sleep(for: .milliseconds(300))
        check(c.pending.isEmpty, "queue applied on stop: \(c.pending.map(\.summary))")

        // Restore brings back the earlier state and keeps a pinned safety copy.
        let rec = c.backups.first { $0.fileName == backup.fileName }!
        let propsNow = try! String(contentsOf: c.paths.properties, encoding: .utf8)
        check(propsNow.contains("motd=after2"), "before restore")
        try await c.restoreBackup(rec)
        check(c.backups.contains { $0.trigger == "before-restore" && $0.pinned }, "safety copy pinned")
        check((try! String(contentsOf: c.paths.properties, encoding: .utf8)).contains("motd=before"), "restored settings")

        // A crash is noticed and catalogued, and doesn't loop.
        if c.profile.software.jarName == "standin.jar" {
            await c.start()
            await checkUntil(startupTimeout, "up again") { c.state == .running }
            c.send("crash")
            await checkUntil(10, "crash noticed: \(c.state)") { if case .crashed(3) = c.state { return true }; return false }
            check(c.issues.contains { $0.id == "wrapper:crash" }, "crash catalogued")
            check(!FileOps.exists(c.paths.pid), "pid cleaned after crash")
        }

        // Bad flags explain themselves.
        c.profile.launch.extraJVMArgs = "-XX:+NoSuchFlagAtAll"
        await c.start()
        await checkUntil(30, "bad flag fails: \(c.state)") { if case .crashed = c.state { return true }; return false }
        check(c.issues.contains { $0.ruleID == "jvm-option" }, "bad flag explained: \(c.issues.map(\.title).prefix(5))")
        c.stopTicker()
    } catch { failures.append("scenario: \(error)") }
}

@MainActor func dumpLayout(_ c: ServerController, _ label: String) {
    print("    --- \(label)")
    print("    entries: \(c.worlds.map { "\($0.name) managed=\($0.isManaged) core=\($0.isCore) path=\($0.relativePath ?? "-")" })")
    print("    top level: \(FileOps.children(c.paths.root).filter(FileOps.isDirectory).map(\.lastPathComponent).sorted())")
    print("    world/: \(FileOps.children(c.paths.root.appendingPathComponent("world")).map(\.lastPathComponent).sorted())")
    let dims = c.paths.root.appendingPathComponent("world/dimensions")
    for ns in FileOps.children(dims) { print("    dimensions/\(ns.lastPathComponent): \(FileOps.children(ns).map(\.lastPathComponent).sorted())") }
    let yml = (try? String(contentsOf: c.paths.plugins.appendingPathComponent("Multiverse-Core/worlds.yml"), encoding: .utf8)) ?? "(none)"
    print("    worlds.yml keys: \(yml.split(separator: "\n").filter { !$0.hasPrefix(" ") && !$0.hasPrefix("#") })")
    let first = yml.split(separator: "\n").prefix(46).filter { $0.contains("alias") || $0.contains("environment") || $0.contains("gamemode") || $0.contains("difficulty") || $0.contains("auto-load") || !$0.hasPrefix(" ") }
    print("    worlds.yml sample: \(first.prefix(10))")
}

// MARK: The sandbox

@MainActor func runSandbox() async {
    let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".lab-sandbox", isDirectory: true)
    let servers = base.appendingPathComponent("servers", isDirectory: true)
    setenv("LEAFJUICE_HOME", base.appendingPathComponent("home").path, 1)
    setenv("LEAFJUICE_SERVERS", servers.path, 1)
    if CommandLine.arguments.contains("--sandbox-wipe") {
        try? FileManager.default.removeItem(at: servers)
        print("Sandbox wiped.")
    }
    let seed = servers.appendingPathComponent("seed", isDirectory: true)
    do {
        let runtimes = await JavaManager.discover()
        guard let java = JavaManager.best(for: 21, in: runtimes) else { failures.append("no Java 21"); return }
        let cache = base.appendingPathComponent("protocol", isDirectory: true)
        let table = try await ProtocolTable.load(mc: "1.21.11", cache: cache, java: java.path)
        print("    protocol \(table.version): \(table.ids.count) packets")

        if !FileOps.exists(seed.appendingPathComponent("seeded")) {
            section("SEEDING the sandbox")
            try? FileManager.default.removeItem(at: seed)
            try await seedSandbox(seed, table: table)
        } else {
            print("    using the existing seed")
        }

        section("SANDBOX: player features on real data")
        let run = servers.appendingPathComponent("run-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try await Trial.clone(seed, to: run)
        defer { try? FileManager.default.removeItem(at: run) }
        try? FileManager.default.removeItem(at: ServerPaths(root: run).meta)
        try? FileManager.default.removeItem(at: run.appendingPathComponent("seeded"))
        let c = try await ServerController.adopt(root: run, name: "Sandbox run")
        defer { c.forceStop(); c.stopTicker() }
        c.profile.backup.enabled = false
        c.profile.lastPluginCheck = Date(); c.profile.software.lastCheck = Date()
        c.profile.launch.restartOnCrash = false
        c.profile.launch.maxMemoryMB = 2048; c.profile.launch.minMemoryMB = 1024
        c.profile.backup.destination = base.appendingPathComponent("run-backups/\(run.lastPathComponent)").path
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: c.profile.backup.destination ?? "/nonexistent")) }
        await c.refreshPlugins()
        try await playerScenario(c, table: table, port: 25580)
    } catch { failures.append("sandbox: \(error)") }
}

@MainActor func bootOK(_ c: ServerController, _ label: String) async {
    await c.start()
    await checkUntil(240, "\(label): boots (blockers \(c.blockers.map(\.title)), last \(c.console.suffix(3).map(\.text)))") { c.state == .running }
}

@MainActor func shutOK(_ c: ServerController) async {
    c.stop()
    await checkUntil(90, "stops: \(c.state)") { c.state == .stopped }
}

/// Connects a bot and waits until it's really in the game.
@MainActor func join(_ name: String, _ c: ServerController, _ table: ProtocolTable, port: Int) async throws -> Bot {
    let bot = try Bot(name: name, port: port, table: table)
    await checkUntil(40, "\(name) joins (\(bot.disconnectReason ?? "no message"))") { c.players.contains(name) }
    try? await Task.sleep(for: .milliseconds(500))
    return bot
}

@MainActor func leave(_ bot: Bot, _ c: ServerController) async {
    bot.leave()
    await checkUntil(20, "\(bot.name) leaves") { !c.players.contains(bot.name) }
}

/// Sends a console command and returns the line matching `expecting`.
@MainActor func ask(_ c: ServerController, _ command: String, expecting needle: String) async -> String? {
    let start = c.console.last?.id ?? -1
    c.send(command)
    for _ in 0..<40 {
        try? await Task.sleep(for: .milliseconds(250))
        if let line = c.console.first(where: { $0.id > start && $0.origin == .server && $0.text.contains(needle) }) { return line.text }
    }
    return nil
}

@MainActor func expectLine(_ c: ServerController, _ command: String, _ needle: String, _ label: String, line: Int = #line) async {
    let found = await ask(c, command, expecting: needle)
    check(found != nil, "\(label) (last: \(c.console.suffix(3).map(\.text)))", line: line)
}

/// Makes a real zip from a list of files.
func makePack(_ name: String, _ files: [String: String], inside: String? = nil) async -> URL {
    let work = folder("pack-\(name)"), base = inside.map { work.appendingPathComponent($0) } ?? work
    for (path, text) in files { write(text, base.appendingPathComponent(path)) }
    let zip = folder("packs-made").appendingPathComponent("\(name).zip")
    try? FileManager.default.removeItem(at: zip)
    _ = try? await Tool.run("/usr/bin/zip", ["-q", "-r", zip.path, "."], cwd: work)
    return zip
}

@MainActor func resourcePackChecks() async {
    print("• Resource packs")
    func json(_ url: URL) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any]) ?? [:] }
    let stoneA = "assets/minecraft/textures/block/stone.png"
    let top = await makePack("Top", [
        "pack.mcmeta": #"{"pack":{"pack_format":46,"description":"§aTop pack"}}"#,
        stoneA: "top-stone",
        "assets/minecraft/textures/item/apple.png": "top-apple",
        "assets/minecraft/lang/en_us.json": #"{"a":"top","b":"top"}"#,
        "assets/minecraft/sounds.json": #"{"x":{"sounds":["top"]},"y":{"replace":true,"sounds":["top-y"]}}"#,
        "assets/minecraft/atlases/blocks.json": #"{"sources":[{"type":"top"}]}"#,
        "assets/minecraft/models/item/stick.json": #"{"parent":"top","overrides":[{"model":"top"}]}"#,
        "assets/minecraft/models/block/same.json": #"{"same":true}"#,
        "LICENSE": "top license",
    ])
    let lower = await makePack("Lower", [
        "pack.mcmeta": #"{"pack":{"pack_format":34,"supported_formats":[20,34],"description":[{"text":"Lower "},{"text":"pack"}]}}"#,
        "pack.png": "lower-icon",
        stoneA: "lower-stone",
        "assets/minecraft/textures/item/apple.png": "lower-apple",
        "assets/minecraft/textures/block/dirt.png": "lower-dirt",
        "assets/minecraft/lang/en_us.json": #"{"b":"lower","c":"lower"}"#,
        "assets/minecraft/sounds.json": #"{"x":{"sounds":["lower"]},"y":{"sounds":["lower-y"]},"z":{"sounds":["lower-z"]}}"#,
        "assets/minecraft/atlases/blocks.json": #"{"sources":[{"type":"lower"}]}"#,
        "assets/minecraft/models/item/stick.json": #"{"parent":"lower","overrides":[{"model":"lower"}]}"#,
        "assets/minecraft/models/block/same.json": #"{"same":true}"#,
        "assets/custom/textures/entity/thing.png": "lower-thing",
        "LICENSE": "lower license",
    ], inside: "Some Folder")
    let lowerTwo = await makePack("Lower-2.0", [
        "pack.mcmeta": #"{"pack":{"pack_format":34,"description":"Lower pack"}}"#,
        stoneA: "lower-stone-v2",
        "assets/minecraft/textures/block/dirt.png": "lower-dirt-v2",
        "assets/custom/textures/entity/new.png": "lower-new",
    ], inside: "Some Folder")
    let hollow = await makePack("Hollow", ["assets/minecraft/textures/block/stone.png": "x"])
    let notZip = folder("packs-made").appendingPathComponent("NotZip.zip")
    write("this isn't a zip", notZip)
    do {
        var a = try await ResourcePacks.add(top)
        let b = try await ResourcePacks.add(lower, title: "Lower Pack", from: .github(repo: "someone/lower"), license: PackLicense(id: "MIT"), authors: ["Someone"])
        equal(a.latest?.description, "Top pack", "color codes removed"); equal(a.latest?.format, 46, "format read")
        equal(b.latest?.description, "Lower pack", "rich text flattened")
        check((b.latest?.fileCount ?? 0) > 5, "a pack inside a top folder is found")
        var refused = 0
        do { _ = try await ResourcePacks.add(hollow) } catch { refused += 1 }
        do { _ = try await ResourcePacks.add(notZip) } catch { refused += 1 }
        equal(refused, 2, "a zip with no pack.mcmeta, and a non-zip, are refused")
        equal(ResourcePacks.list().count, 2, "only real packs are in the library")
        equal(try await ResourcePacks.add(top).versions.count, 1, "adding the same file again changes nothing")
        equal(ResourcePacks.category(of: stoneA), "Blocks", "category"); equal(ResourcePacks.category(of: "assets/x/sounds/a.ogg"), "Sounds", "sounds")
        equal(try await ResourcePacks.images(in: a, a.latest!).count, 2, "images listed")

        equal(PackSource.parse("https://modrinth.com/resourcepack/fresh-animations/versions"), .modrinth(project: "fresh-animations"), "Modrinth page understood")
        equal(PackSource.parse("https://github.com/someone/pack.git"), .github(repo: "someone/pack"), "GitHub page understood")
        equal(PackSource.parse("https://example.com/p.zip"), .url("https://example.com/p.zip"), "a plain link")
        equal(PackSource.parse("not a link"), nil, "not a link")

        // Ranking.
        var recipe = ResourcePacks.reconcile(PackRecipe(), with: [a, b])
        recipe.name = "My Pack!"
        equal(recipe.entries.map(\.pack), [a.id, b.id], "new packs join in order")
        let lock = try await ResourcePacks.resolve(recipe)
        func file(_ l: PackLock, _ path: String) -> LockedFile? { l.files.first { $0.path == path } }
        equal(file(lock, stoneA)?.winner, a.id, "top ranked wins"); equal(file(lock, stoneA)?.reason, .rank, "because of rank")
        equal(file(lock, stoneA)?.copies.map(\.pack), [a.id, b.id], "and every copy is on record")
        equal(file(lock, "assets/minecraft/textures/block/dirt.png")?.reason, .only, "only one has it")
        equal(file(lock, "assets/minecraft/lang/en_us.json")?.reason, .merged, "languages merge")
        let conflicts = ResourcePacks.conflicts(lock).map(\.path)
        check(conflicts.contains(stoneA), "differing copies are conflicts")
        check(!conflicts.contains("assets/minecraft/lang/en_us.json"), "merged files aren't"); check(!conflicts.contains("assets/minecraft/models/block/same.json"), "identical copies aren't")

        // Who wins, most specific first.
        var byCategory = recipe
        byCategory.categoryWinners["Blocks"] = b.id
        let categorized = try await ResourcePacks.resolve(byCategory)
        equal(file(categorized, stoneA)?.winner, b.id, "a pack can be first for one kind of file"); equal(file(categorized, stoneA)?.reason, .category, "because of category")
        equal(file(categorized, "assets/minecraft/textures/item/apple.png")?.winner, a.id, "others still follow rank")
        byCategory.winners[stoneA] = a.id
        equal(file(try await ResourcePacks.resolve(byCategory), stoneA)?.reason, .picked, "picking one file beats its category")

        // Building.
        let build = try await ResourcePacks.combine(recipe)
        let out = try await ResourcePacks.unpack(ResourcePacks.buildFile(build, recipe: recipe.name))
        func text(_ root: URL, _ path: String) -> String { (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? "" }
        equal(text(out, stoneA), "top-stone", "the winner is what's built")
        equal(text(out, "assets/minecraft/textures/block/dirt.png"), "lower-dirt", "only the lower one has it")
        equal(text(out, "assets/custom/textures/entity/thing.png"), "lower-thing", "from inside the top folder, at the root")
        equal(text(out, "pack.png"), "lower-icon", "an icon is kept")
        check(text(out, "CREDITS.txt").contains("By: Someone") && text(out, "CREDITS.txt").contains("not for sale"), "credits included")
        check(!FileOps.exists(out.appendingPathComponent("Some Folder")), "the folder doesn't come along")
        equal(text(out, "credits/\(a.id)/LICENSE"), "top license", "each pack's license is kept")
        equal(text(out, "credits/\(b.id)/LICENSE"), "lower license", "side by side, not overwritten")
        check(!lock.files.contains { $0.path == "LICENSE" }, "licenses aren't ranked")
        equal(json(out.appendingPathComponent("assets/minecraft/lang/en_us.json")) as? [String: String], ["a": "top", "b": "top", "c": "lower"], "languages merge, top wins each key")
        let sounds = json(out.appendingPathComponent("assets/minecraft/sounds.json"))
        equal((sounds["x"] as? [String: Any])?["sounds"] as? [String], ["top", "lower"], "sounds add up")
        equal((sounds["y"] as? [String: Any])?["sounds"] as? [String], ["top-y"], "unless the higher one replaces")
        equal((sounds["z"] as? [String: Any])?["sounds"] as? [String], ["lower-z"], "others carry over")
        equal((json(out.appendingPathComponent("assets/minecraft/atlases/blocks.json"))["sources"] as? [[String: String]])?.map { $0["type"] ?? "" }, ["top", "lower"], "atlases add up")
        let stick = json(out.appendingPathComponent("assets/minecraft/models/item/stick.json"))
        equal(stick["parent"] as? String, "top", "item model from the top pack"); equal((stick["overrides"] as? [[String: String]])?.count, 2, "with both packs' overrides")
        let meta = json(out.appendingPathComponent("pack.mcmeta"))["pack"] as? [String: Any]
        equal(meta?["pack_format"] as? Int, 46, "newest format"); equal(meta?["supported_formats"] as? [Int], [20, 46], "wide enough for all")
        check(build.warnings.contains { $0.contains("different Minecraft versions") }, "mismatched versions are mentioned")
        equal(try await ResourcePacks.combine(recipe).sha1, build.sha1, "the same recipe builds the same file, byte for byte")
        equal(ResourcePacks.history(recipe.name).count, 1, "and isn't a new build")
        check(ResourcePacks.loadLock(sha1: build.sha1, recipe: recipe.name) != nil, "the lock file is saved with it")

        // My changes always win, and updates can't touch them.
        write("mine-apple", ResourcePacks.mine.appendingPathComponent("assets/minecraft/textures/item/apple.png"))
        let withMine = try await ResourcePacks.resolve(recipe)
        equal(file(withMine, "assets/minecraft/textures/item/apple.png")?.reason, .mine, "my changes win")
        equal(file(withMine, "assets/minecraft/textures/item/apple.png")?.copies.count, 3, "with the others still on record")
        let mineBuild = try await ResourcePacks.combine(recipe)
        equal(text(try await ResourcePacks.unpack(ResourcePacks.buildFile(mineBuild, recipe: recipe.name)), "assets/minecraft/textures/item/apple.png"), "mine-apple", "and get built")
        check(mineBuild.sha1 != build.sha1, "a change makes a new build"); equal(ResourcePacks.history(recipe.name).count, 2, "and the old one is kept")
        try FileManager.default.removeItem(at: ResourcePacks.mine)

        // An update: same pack, new version, and the recipe's choices survive.
        recipe.winners["assets/minecraft/textures/item/apple.png"] = b.id
        let beforeUpdate = try await ResourcePacks.resolve(recipe)
        let updated = try await ResourcePacks.add(lowerTwo, from: b.source, version: "2.0")
        equal(updated.id, b.id, "an update isn't a new pack"); equal(updated.versions.map(\.version), [b.latest!.version, "2.0"], "and the old version stays")
        equal(ResourcePacks.reconcile(recipe, with: ResourcePacks.list()).entries.first { $0.pack == b.id }?.version, b.latest?.sha1, "the recipe stays pinned until you accept")
        var trial = recipe
        trial.entries[1].version = updated.latest!.sha1
        let afterUpdate = try await ResourcePacks.resolve(trial)
        let changes = ResourcePacks.changes(from: beforeUpdate, to: afterUpdate, recipe: trial)
        check(changes.added.contains { $0.path.hasSuffix("new.png") }, "new files are listed")
        check(changes.removed.contains { $0.path.hasSuffix("thing.png") }, "removed files are listed")
        check(changes.changed.contains { $0.path.hasSuffix("dirt.png") }, "changes players would see are listed")
        check(changes.hidden.contains { $0.path == stoneA }, "a change a higher pack hides is told apart")
        equal(changes.lostPicks, [], "the picked file only lost a pack, and still exists")
        check(changes.changed.contains { $0.path.hasSuffix("apple.png") }, "losing the picked pack's copy changes that file")
        trial.winners["assets/gone.png"] = b.id
        equal(ResourcePacks.changes(from: beforeUpdate, to: afterUpdate, recipe: trial).lostPicks, ["assets/gone.png"], "a pick whose file vanished is flagged")
        recipe.entries[1].version = b.latest!.sha1
        equal(file(try await ResourcePacks.resolve(recipe), "assets/minecraft/textures/block/dirt.png")?.sha1, file(beforeUpdate, "assets/minecraft/textures/block/dirt.png")?.sha1, "going back to the old version works")

        // Turning things off, and several recipes.
        var less = recipe
        less.winners = [:]
        less.entries[1].excluded = ["Blocks"]
        let lessLock = try await ResourcePacks.resolve(less)
        check(file(lessLock, "assets/minecraft/textures/block/dirt.png") == nil, "leaving out a category")
        less.entries[1].excluded = []
        less.entries[0].enabled = false
        equal(file(try await ResourcePacks.resolve(less), stoneA)?.winner, b.id, "turning a pack off")
        less.entries[1].enabled = false
        var empty = false
        do { _ = try await ResourcePacks.combine(less) } catch { empty = true }
        check(empty, "nothing chosen is refused")
        ResourcePacks.saveRecipe(recipe)
        var other = PackRecipe(); other.name = "Second One"
        ResourcePacks.saveRecipe(other)
        equal(Set(ResourcePacks.recipeNames()), [ResourcePacks.slug(recipe.name), "second-one"], "several recipes")
        equal(ResourcePacks.loadRecipe(recipe.name).winners, recipe.winners, "each keeps its own choices")

        // Sharing.
        equal(PackLicense(id: "MIT").sharing, .allowed, "permissive license")
        equal(PackLicense(id: "LicenseRef-All-Rights-Reserved").title, "All Rights Reserved", "license names read well"); equal(PackLicense(id: "CC-BY-4.0").title, "CC-BY-4.0", "and standard ones stay as they are")
        check({ if case .conditions = PackLicense(id: "CC-BY-NC-4.0").sharing { return true }; return false }(), "non-commercial has conditions")
        check({ if case .ask = PackLicense(id: "CC-BY-ND-4.0").sharing { return true }; return false }(), "no-derivatives needs asking")
        check({ if case .ask = PackLicense(id: "LicenseRef-All-Rights-Reserved").sharing { return true }; return false }(), "all rights reserved needs asking")
        check({ if case .ask = PackLicense(id: "LicenseRef-Custom").sharing { return true }; return false }(), "unknown needs asking")
        let reviewed = ResourcePacks.licenseReview(recipe)
        check({ if case .ask = reviewed.first { $0.pack.id == a.id }?.sharing { return true }; return false }(), "no license on record needs asking")
        let exported = try ResourcePacks.exportRecipe(recipe)
        let exportText = String(decoding: exported, as: UTF8.self)
        check(exportText.contains("leaf-juice-pack-recipe"), "the export says what it is"); check(!exportText.contains("top-stone"), "no pack contents")
        let imported = try await ResourcePacks.importRecipe(exported, mc: nil)
        equal(imported.recipe.entries.map(\.pack), recipe.entries.map(\.pack), "importing with the packs here restores the ranking")
        equal(imported.recipe.winners, recipe.winners, "and the picks"); equal(imported.missing, [], "nothing to fetch")
        try await ResourcePacks.remove(a)
        let withoutA = try await ResourcePacks.importRecipe(exported, mc: nil)
        equal(withoutA.missing.map(\.id), [a.id], "a pack added by hand can't be fetched, and is named")
        a = try await ResourcePacks.add(top)
        var refusedImport = false
        do { _ = try await ResourcePacks.importRecipe(Data("{}".utf8), mc: nil) } catch { refusedImport = true }
        check(refusedImport, "other JSON isn't a recipe")

        // Observed on a real project: many packs side by side in one zip.
        let many = await makePack("ManyPacks", ["project/src/one/pack.mcmeta": #"{"pack":{"pack_format":6,"description":"a"}}"#, "project/src/two/pack.mcmeta": #"{"pack":{"pack_format":6,"description":"b"}}"#, "project/src/one/assets/x/a.png": "a"])
        var manyMessage = ""
        do { _ = try await ResourcePacks.add(many) } catch { manyMessage = error.localizedDescription }
        check(manyMessage.contains("2 separate packs") && manyMessage.contains("one"), "a project holding many packs is refused, and says why: \(manyMessage)")

        // Measuring a pack against what a version uses.
        let vanilla = VanillaAssets(mc: "9.9", format: 75, files: ["assets/minecraft/textures/block/stone.png", "assets/minecraft/textures/block/dirt.png", "assets/minecraft/textures/block/new_block.png", "assets/minecraft/textures/item/apple.png", "assets/minecraft/lang/en_us.json"])
        let fit = ResourcePacks.coverage(of: ["assets/minecraft/textures/block/stone.png", "assets/minecraft/textures/block/dirt.png", "assets/minecraft/textures/block/removed_long_ago.png", "assets/custom/textures/block/mine.png", "assets/minecraft/lang/en_us.json"], against: vanilla)
        equal(fit.rows.map(\.category), ["Blocks", "Items"], "only categories the version has")
        equal(fit.rows.first?.covered, 2, "blocks covered"); equal(fit.rows.first?.total, 3, "out of what the version uses"); equal(fit.rows.first?.percent, 66, "as a percentage")
        equal(fit.rows.first?.examplesMissing, ["new_block.png"], "what falls back to the game's art"); equal(fit.percent, 50, "overall")
        equal(fit.unused, 1, "files the game never reads are counted"); equal(fit.unusedExamples, ["assets/minecraft/textures/block/removed_long_ago.png"], "and named")

        // Formats as real packs really write them.
        equal(ResourcePacks.formatNumber(75), 75, "a plain format"); equal(ResourcePacks.formatNumber([75, 0]), 75, "major and minor")
        equal(ResourcePacks.formatNumber([97.1]), 97, "a decimal in a list"); equal(ResourcePacks.formatNumber(88.0), 88, "a decimal")
        let decimal = await makePack("Decimal", ["pack.mcmeta": #"{"pack":{"min_format":[97.1],"max_format":[97.1],"description":"new"}}"#, "assets/x/textures/block/d.png": "d"])
        let decimalPack = try await ResourcePacks.add(decimal)
        equal(decimalPack.latest?.format, 97, "read from a real pack's form")
        try await ResourcePacks.remove(decimalPack)

        // Observed on the real TARDIS pack: min_format with no pack_format.
        let modern = await makePack("Modern", ["pack.mcmeta": #"{"pack":{"min_format":84,"max_format":84,"description":"new"}}"#, "assets/x/textures/block/n.png": "n"])
        let modernPack = try await ResourcePacks.add(modern)
        var mixed = PackRecipe(); mixed.name = "Mixed Formats"
        mixed.entries = [PackRecipe.Entry(pack: modernPack.id, version: modernPack.latest!.sha1), PackRecipe.Entry(pack: b.id, version: b.latest!.sha1)]
        let mixedBuild = try await ResourcePacks.combine(mixed)
        equal(mixedBuild.format, 84, "a pack's min_format counts as its format")
        let mixedMeta = json(try await ResourcePacks.unpack(ResourcePacks.buildFile(mixedBuild, recipe: mixed.name)).appendingPathComponent("pack.mcmeta"))["pack"] as? [String: Any]
        equal(mixedMeta?["min_format"] as? Int, 20, "the low end covers everything"); equal(mixedMeta?["max_format"] as? Int, 84, "and the high end")
        try await ResourcePacks.remove(modernPack)

        // Observed on a real pack: read-only folders in the zip left a cached copy that couldn't be cleared.
        let locked = folder("pack-locked")
        write(#"{"pack":{"pack_format":46,"description":"x"}}"#, locked.appendingPathComponent("pack.mcmeta"))
        write("x", locked.appendingPathComponent("assets/minecraft/textures/block/a.png"))
        write("y", locked.appendingPathComponent("Info.txt"))
        let lockedZip = folder("packs-made").appendingPathComponent("Locked.zip")
        _ = try await Tool.run("/bin/chmod", ["-R", "a-w", locked.appendingPathComponent("assets").path])
        _ = try await Tool.run("/usr/bin/zip", ["-q", "-r", lockedZip.path, "."], cwd: locked)
        _ = try await Tool.run("/bin/chmod", ["-R", "u+w", locked.path])
        let lockedPack = try await ResourcePacks.add(lockedZip)
        let firstCount = lockedPack.latest?.fileCount
        try await ResourcePacks.remove(lockedPack)
        check(!FileOps.exists(ResourcePacks.unpacked.appendingPathComponent(lockedPack.latest!.sha1)), "a read-only pack's cached copy can be cleared")
        let again2 = try await ResourcePacks.add(lockedZip)
        equal(again2.latest?.fileCount, firstCount, "and comes back whole")
        var lockedRecipe = PackRecipe(); lockedRecipe.name = "Locked Build"
        lockedRecipe.entries = [PackRecipe.Entry(pack: again2.id, version: again2.latest!.sha1)]
        let lockedBuild = try await ResourcePacks.combine(lockedRecipe)
        check(FileOps.exists(ResourcePacks.buildFile(lockedBuild, recipe: lockedRecipe.name)), "and builds")
        check(!FileOps.children(ResourcePacks.folder).contains { $0.lastPathComponent.hasPrefix(".building") }, "leaving no working files behind")
        try await ResourcePacks.remove(again2)

        // A hostile zip can't write outside its folder.
        let trap = folder("trap"), inner = trap.appendingPathComponent("a/b")
        write(#"{"pack":{"pack_format":46,"description":"x"}}"#, inner.appendingPathComponent("pack.mcmeta"))
        write("escaped", trap.appendingPathComponent("a/evil.txt"))
        let evil = folder("packs-made").appendingPathComponent("Evil.zip")
        _ = try await Tool.run("/usr/bin/zip", ["-q", evil.path, "pack.mcmeta", "../evil.txt"], cwd: inner)
        let unpacked = try await ResourcePacks.unpack(evil)
        check(!FileOps.exists(unpacked.deletingLastPathComponent().appendingPathComponent("evil.txt")), "a path with .. stays inside")
        equal(ResourcePacks.bytes(inSummary: "1,234 files, 5,678 bytes uncompressed, 910 bytes compressed:  84.0%"), 5678, "unpacked size read")

        // Server settings, in the form real files use.
        let real = "resource-pack=https\\://download.mc-packs.net/pack/abc.zip\nresource-pack-sha1=abc\nrequire-resource-pack=true\nmotd=hi\n"
        let current = ResourcePacks.current(real)
        equal(current.url, "https://download.mc-packs.net/pack/abc.zip", "web address unescaped"); check(current.required, "required read")
        let sha = String(repeating: "a", count: 40)
        let applied = try ResourcePacks.applying(url: "https://example.com/p.zip", sha1: sha, required: false, to: real)
        let again = ResourcePacks.current(applied)
        equal(again.url, "https://example.com/p.zip", "address written"); equal(again.sha1, sha, "SHA-1 written"); check(!again.required, "requirement written")
        check(applied.contains("motd=hi"), "other settings left alone"); check(applied.contains("resource-pack-id="), "a new id, so games don't keep the old pack")
        var bad = 0
        for (u, h) in [("not a url", sha), ("ftp://x/y.zip", sha), ("https://x/y.zip", "short")] {
            do { _ = try ResourcePacks.applying(url: u, sha1: h, required: false, to: real) } catch { bad += 1 }
        }
        equal(bad, 3, "bad addresses and hashes are refused")
        await packContributionChecks(recipe: recipe, top: a.id, lower: b.id, stone: stoneA)
    } catch { failures.append("resource packs threw: \(error)") }
    await packHostingChecks()
}

@MainActor func packContributionChecks(recipe: PackRecipe, top: String, lower: String, stone: String) async {
    print("• What each pack contributes")
    do {
        var byRank = recipe
        byRank.winners = [:]; byRank.categoryWinners = [:]
        let lock = try await ResourcePacks.resolve(byRank)
        let counts = ResourcePacks.contributions(lock, order: [(top, "Top"), (lower, "Lower")])
        let topCount = counts.first { $0.pack == top }!, lowerCount = counts.first { $0.pack == lower }!
        equal(counts.first?.pack, top, "listed in ranking order")
        equal(topCount.wins + lowerCount.wins + topCount.merged, lock.files.filter { $0.reason != .merged }.count + topCount.merged, "every file not merged has one winner")
        check(topCount.winsByCategory["Blocks", default: 0] > 0, "wins are counted by kind")
        equal(lock.files.first { $0.path == stone }?.role(of: top), .wins, "the top pack wins a shared file")
        equal(lock.files.first { $0.path == stone }?.role(of: lower), .loses, "and the lower one loses it")
        let lost = ResourcePacks.files(lock, pack: lower, show: .loses)
        equal(lost.count, lowerCount.loses, "the file list and the count agree on what's lost")
        check(lost.contains { $0.path == stone }, "and name it")
        equal(ResourcePacks.files(lock, pack: lower, show: .only).count, lowerCount.only, "and on what only it has")
        check(ResourcePacks.files(lock, show: .loses).allSatisfy(\.canChoose), "across every pack, 'replaced' only lists real choices")
        check(ResourcePacks.files(lock, search: "STONE").contains { $0.path == stone }, "search ignores case")
        check(ResourcePacks.files(lock, imagesOnly: true).allSatisfy(\.isImage), "images only")
        check(ResourcePacks.files(lock, category: "Blocks").allSatisfy { ResourcePacks.category(of: $0.path) == "Blocks" }, "one kind only")
        check(lock.files.filter { $0.reason == .merged }.allSatisfy { !$0.canChoose }, "merged files offer no choice")

        // Over the 200 the old list stopped at.
        var many: [String: String] = ["pack.mcmeta": #"{"pack":{"pack_format":46,"description":"many"}}"#]
        var alsoMany = many
        for index in 0..<260 {
            many["assets/minecraft/textures/block/made_up_\(index).png"] = "one-\(index)"
            alsoMany["assets/minecraft/textures/block/made_up_\(index).png"] = "two-\(index)"
        }
        let first = try await ResourcePacks.add(await makePack("Many One", many))
        let second = try await ResourcePacks.add(await makePack("Many Two", alsoMany))
        var big = ResourcePacks.reconcile(PackRecipe(), with: [first, second])
        big.name = "many-files"
        big.entries = big.entries.filter { $0.pack == first.id || $0.pack == second.id }
        let bigLock = try await ResourcePacks.resolve(big)
        equal(ResourcePacks.files(bigLock, pack: second.id, show: .loses).count, 260, "every differing file is listed, not just 200")

        // A choice in the list changes the count and the build the same way.
        let pickedPath = "assets/minecraft/textures/block/made_up_7.png"
        big.winners[pickedPath] = second.id
        let picked = try await ResourcePacks.resolve(big)
        let pickedCounts = ResourcePacks.contributions(picked, order: [(first.id, "One"), (second.id, "Two")])
        equal(pickedCounts.first { $0.pack == second.id }?.wins, 1, "choosing a file counts for that pack")
        let builtDir = try await ResourcePacks.unpack(ResourcePacks.buildFile(try await ResourcePacks.combine(big), recipe: big.name))
        equal(try? String(contentsOf: builtDir.appendingPathComponent(pickedPath), encoding: .utf8), "two-7", "and the build agrees")
        let locator = try await ResourcePacks.locator(big)
        equal(locator.url(path: pickedPath, pack: first.id).flatMap { try? String(contentsOf: $0, encoding: .utf8) }, "one-7", "each copy can be found to look at")
        equal(locator.url(path: pickedPath, pack: second.id).flatMap { try? String(contentsOf: $0, encoding: .utf8) }, "two-7", "both of them")
        try await ResourcePacks.remove(first)
        try await ResourcePacks.remove(second)
    } catch { failures.append("pack contributions threw: \(error)") }
}

/// A raw request, for things a normal web client won't send.
func rawRequest(port: Int, _ text: String) async -> String {
    await withCheckedContinuation { (done: CheckedContinuation<String, Never>) in
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        let queue = DispatchQueue(label: "raw")
        final class Box: @unchecked Sendable { var data = Data(); var ended = false }
        let box = Box()
        @Sendable func end() {
            guard !box.ended else { return }
            box.ended = true
            connection.cancel()
            done.resume(returning: String(decoding: box.data, as: UTF8.self))
        }
        @Sendable func pull() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, finished, error in
                if let data { box.data.append(data) }
                if finished || error != nil { end() } else { pull() }
            }
        }
        connection.stateUpdateHandler = { state in
            if case .failed = state { end() }
        }
        connection.start(queue: queue)
        if !text.isEmpty { connection.send(content: Data(text.utf8), completion: .idempotent) }
        pull()
        queue.asyncAfter(deadline: .now() + 15) { end() }
    }
}

func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
    return result == KERN_SUCCESS ? info.resident_size : 0
}

@MainActor func packHostingChecks() async {
    print("• Serving packs")
    // The pure parts.
    equal(PackHosting.cleanAddress(" https://Packs.Example.net/ "), "https://packs.example.net", "an address is tidied")
    equal(PackHosting.cleanAddress("http://127.0.0.1:8766"), "http://127.0.0.1:8766", "with its port")
    for bad in ["packs.example.net", "ftp://x", "https://x/path", "https://x?a=1", "https://u:p@x", "https://x#y"] { equal(PackHosting.cleanAddress(bad), nil, "refused: \(bad)") }
    check(PackHosting.isOnlyThisMac("http://localhost:1") && PackHosting.isOnlyThisMac("http://127.0.0.1") && !PackHosting.isOnlyThisMac("https://packs.example.net"), "an address only this Mac can use is noticed")
    let tokens = (0..<20).map { _ in PackHosting.newToken() }
    equal(Set(tokens).count, 20, "paths differ"); check(tokens.allSatisfy { $0.count == 64 }, "and are long")
    equal(PackHosting.parse(Data("GET /a HTTP/1.1\r\nHost: x\r\n\r\n".utf8)), .ok(method: "GET", path: "/a"), "a request is read")
    equal(PackHosting.parse(Data("GET /a HTTP/1.1\r\nHost".utf8)), .incomplete, "a partial one waits")
    equal(PackHosting.parse(Data("GARBAGE\r\n\r\n".utf8)), .bad, "nonsense is refused")
    equal(PackHosting.parse(Data(repeating: 65, count: 9000)), .bad, "so is one that never ends")
    let oneHash = String(repeating: "a", count: 40), twoHash = String(repeating: "b", count: 40), threeHash = String(repeating: "c", count: 40)
    let route = PackRoute(token: "tok", recipe: "r", url: "https://p/tok/pack.zip", published: oneHash, followsProperties: true)
    equal(PackHosting.match(path: "/tok/pack.zip", routes: [route])?.asked, .pack, "the pack's path")
    equal(PackHosting.match(path: "/tok/pack.zip.sha1", routes: [route])?.asked, .hash, "the hash's path")
    equal(PackHosting.match(path: "/tok/\(oneHash).zip", routes: [route])?.asked, .build(oneHash), "a build's own path")
    for wrong in ["/", "/tok", "/tok/", "/tok/other.zip", "/tok/\(oneHash.uppercased()).zip", "/tok/\(oneHash).zip.sha1", "/tok/../\(oneHash).zip", "/nope/pack.zip", "/tok/pack.zip?x=1", "/tok/../tok/pack.zip", "//tok/pack.zip", "/tok/pack.zip/"] { check(PackHosting.match(path: wrong, routes: [route]) == nil, "no match: \(wrong)") }
    let pointing = "resource-pack=https\\://p/tok/pack.zip\nresource-pack-sha1=\(twoHash)\n"
    equal(ResourcePacks.current(pointing).url, "https://p/tok/pack.zip", "properties escape their colons")
    equal(PackHosting.servedSHA1(route, properties: pointing), twoHash, "the server's own hash decides when it points here")
    equal(PackHosting.servedSHA1(route, properties: "resource-pack=https\\://other/x.zip\nresource-pack-sha1=\(twoHash)\n"), oneHash, "not when it points elsewhere")
    equal(PackHosting.servedSHA1(route, properties: "resource-pack=https\\://p/tok/pack.zip\nresource-pack-sha1=../../secret\n"), oneHash, "a hash that isn't one is ignored")
    var butlerRoute = route; butlerRoute.followsProperties = false
    equal(PackHosting.servedSHA1(butlerRoute, properties: pointing), oneHash, "with Butler, server.properties decides nothing")
    var unset = butlerRoute; unset.published = nil
    equal(PackHosting.servedSHA1(unset, properties: pointing), nil, "nothing chosen means nothing served")

    do {
        let root = folder("pack-hosting")
        write("server-port=25599\nmotd=keep\n", root.appendingPathComponent("server.properties"))
        let c = try await ServerController.adopt(root: root, name: "pack-hosting")
        defer { c.stopPackHost() }
        let port = 28766

        // Two recipes, as for two worlds.
        let oneZip = try await ResourcePacks.add(await makePack("World One", ["pack.mcmeta": #"{"pack":{"pack_format":46,"description":"one"}}"#, "assets/minecraft/textures/block/stone.png": "world-one"]))
        let twoZip = try await ResourcePacks.add(await makePack("World Two", ["pack.mcmeta": #"{"pack":{"pack_format":46,"description":"two"}}"#, "assets/minecraft/textures/block/stone.png": "world-two"]))
        func recipe(_ name: String, _ pack: LibraryPack) -> PackRecipe {
            var out = PackRecipe()
            out.name = name
            out.entries = [PackRecipe.Entry(pack: pack.id, version: pack.latest!.sha1)]
            ResourcePacks.saveRecipe(out)
            return out
        }
        let firstBuild = try await ResourcePacks.combine(recipe("world-one", oneZip))
        let otherBuild = try await ResourcePacks.combine(recipe("world-two", twoZip))
        check(firstBuild.sha1 != otherBuild.sha1, "two recipes, two builds")

        // Off by default, and refuses to start without an address.
        check(!c.packHostSettings.enabled && !c.packHostIsListening, "serving is off by default")
        var refusedStart = false
        do { try c.startPackHost() } catch { refusedStart = true }
        check(refusedStart, "it needs an address first")
        try c.setPackHost(address: "http://127.0.0.1:\(port)/", port: port)
        var badPort = false
        do { try c.setPackHost(address: "http://127.0.0.1", port: 80) } catch { badPort = true }
        check(badPort, "a low port is refused")
        try c.startPackHost()
        await checkUntil(5, "listening") { c.packHostIsListening }
        check(c.packHostSettings.enabled, "and it's remembered")

        let oneURL = c.packAddress(recipe: "world-one")!, twoURL = c.packAddress(recipe: "world-two")!
        check(oneURL != twoURL, "each recipe has its own address")
        check(oneURL.hasPrefix("http://127.0.0.1:\(port)/") && oneURL.hasSuffix("/pack.zip"), "in the right form: \(oneURL)")
        let token = c.packHostSettings.recipes["world-one"]!.token
        func status(_ text: String) -> String { String(text.split(separator: "\r\n").first ?? "") }

        // Nothing is served until it's chosen, and the answer gives nothing away.
        let notYet = await PackHosting.check(url: oneURL, expected: firstBuild.sha1)
        equal(notYet.outcome, .status(404), "nothing's served until a build is chosen")
        try c.serveBuild(sha1: firstBuild.sha1, recipe: "world-one")
        try c.serveBuild(sha1: otherBuild.sha1, recipe: "world-two")
        var missing = false
        do { try c.serveBuild(sha1: threeHash, recipe: "world-one") } catch { missing = true }
        check(missing, "a build that isn't there can't be chosen")
        try? await Task.sleep(for: .milliseconds(100))
        let oneCheck = await PackHosting.check(url: oneURL, expected: firstBuild.sha1)
        check(oneCheck.ok, "the first recipe's address gives its own build: \(oneCheck.summary)")
        let twoCheck = await PackHosting.check(url: twoURL, expected: otherBuild.sha1)
        check(twoCheck.ok, "and the second its own: \(twoCheck.summary)")
        let crossed = await PackHosting.check(url: oneURL, expected: otherBuild.sha1)
        check({ if case .differs = crossed.outcome { return true } else { return false } }(), "a wrong file is noticed: \(crossed.summary)")
        let hashText = await rawRequest(port: port, "GET /\(token)/pack.zip.sha1 HTTP/1.1\r\nHost: x\r\n\r\n")
        check(hashText.hasSuffix("\(firstBuild.sha1)\n"), "the hash can be read for Butler's use")

        // Everything else gets the same nothing.
        let wrongPath = await rawRequest(port: port, "GET /\(String(repeating: "0", count: 64))/pack.zip HTTP/1.1\r\nHost: x\r\n\r\n")
        equal(status(wrongPath), "HTTP/1.1 404 Not Found", "a wrong path")
        let listing = await rawRequest(port: port, "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        equal(status(listing), "HTTP/1.1 404 Not Found", "no listing")
        let climbing = await rawRequest(port: port, "GET /\(token)/../../../server.properties HTTP/1.1\r\nHost: x\r\n\r\n")
        equal(status(climbing), "HTTP/1.1 404 Not Found", "no climbing out")
        let posted = await rawRequest(port: port, "POST /\(token)/pack.zip HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n")
        equal(status(posted), "HTTP/1.1 405 Method Not Allowed", "read only")
        let nonsense = await rawRequest(port: port, "NOT HTTP\r\n\r\n")
        equal(status(nonsense), "HTTP/1.1 400 Bad Request", "nonsense is refused")
        let headOnly = await rawRequest(port: port, "HEAD /\(token)/pack.zip HTTP/1.1\r\nHost: x\r\n\r\n")
        check(headOnly.contains("Content-Length: \(firstBuild.size)") && headOnly.hasSuffix("\r\n\r\n"), "HEAD gives the size and no file")
        let getOne = await rawRequest(port: port, "HEAD /\(token)/pack.zip HTTP/1.1\r\nHost: x\r\nCookie: a=b\r\n\r\n")
        check(!getOne.lowercased().contains("set-cookie"), "no cookies either way")
        check(getOne.contains("X-Content-Type-Options: nosniff"), "and the browser isn't left to guess")

        // A connection that never asks gets dropped, and doesn't block others.
        let silent = await rawRequest(port: port, "")
        equal(silent, "", "a silent connection is closed")
        let silentThenFine = await PackHosting.check(url: oneURL, expected: firstBuild.sha1)
        check(silentThenFine.ok, "and others carry on")

        // A large file, several at once, without holding it in memory.
        let largeSHA: String
        do {
            let large = "large-test"
            let temp = folder("large-pack").appendingPathComponent("large.zip")
            FileManager.default.createFile(atPath: temp.path, contents: nil)
            let handle = try FileHandle(forWritingTo: temp)
            let block = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            for _ in 0..<300 { try handle.write(contentsOf: block) }
            try handle.close()
            largeSHA = try Hashing.digests(of: temp).sha1
            let target = ResourcePacks.buildFile(sha1: largeSHA, recipe: large)
            try FileOps.ensureDir(target.deletingLastPathComponent())
            try FileOps.move(temp, to: target)
            try c.serveBuild(sha1: largeSHA, recipe: large)
            try? await Task.sleep(for: .milliseconds(100))
            let url = c.packAddress(recipe: large)!
            // Downloaded by another process, so the memory measured here is only the server's.
            let before = residentBytes()
            let peak = Task { @MainActor () -> UInt64 in
                var most: UInt64 = 0
                while !Task.isCancelled {
                    most = max(most, residentBytes())
                    try? await Task.sleep(for: .milliseconds(50))
                }
                return most
            }
            let curls = await withTaskGroup(of: String.self, returning: [String].self) { group in
                for _ in 0..<4 {
                    group.addTask {
                        let out = try? await Tool.run("/bin/sh", ["-c", "/usr/bin/curl -s --fail \"$0\" | /usr/bin/shasum -a 1", url])
                        return String(out?.out.prefix(40) ?? "")
                    }
                }
                var out: [String] = []
                for await item in group { out.append(item) }
                return out
            }
            peak.cancel()
            let most = await peak.value
            equal(curls, Array(repeating: largeSHA, count: 4), "4 downloads of 300 MB at once all match")
            print("    memory while serving 4 x 300 MB: \((Int64(most) - Int64(before)) / 1_000_000) MB more at its peak")
            check(Int64(most) - Int64(before) < 60_000_000, "the file isn't held in memory")
            let oneLarge = await PackHosting.check(url: url, expected: largeSHA)
            check(oneLarge.ok && oneLarge.summary.contains("may not accept"), "the check warns about the size: \(oneLarge.summary)")
            try? FileManager.default.removeItem(at: target)
            let gone = await PackHosting.check(url: url, expected: largeSHA)
            equal(gone.outcome, .status(404), "a build that's gone is a 404, not another file")
        }

        // More connections than allowed: extras are dropped, nothing breaks.
        var crowd: [NWConnection] = []
        for _ in 0..<(PackHost.maxConnections + 5) {
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
            connection.start(queue: .global())
            crowd.append(connection)
        }
        try? await Task.sleep(for: .milliseconds(300))
        let crowded = await rawRequest(port: port, "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        equal(crowded, "", "a full house turns newcomers away")
        for connection in crowd { connection.cancel() }
        try? await Task.sleep(for: .milliseconds(300))
        let cleared = await PackHosting.check(url: oneURL, expected: firstBuild.sha1)
        check(cleared.ok, "and recovers once they've gone: \(cleared.summary)")

        // The server's own setting decides, so a staged change holds until the restart.
        await c.refreshPlugins()
        let required = try await c.usePack(url: oneURL, sha1: firstBuild.sha1, required: true, recipe: "world-one")
        equal(required, .saved, "a stopped server saves straight away")
        let onServer = ResourcePacks.current(try String(contentsOf: c.paths.properties, encoding: .utf8))
        equal(onServer.url, oneURL, "the address is set"); equal(onServer.sha1, firstBuild.sha1, "with its hash"); check(onServer.required, "and required")
        check((try String(contentsOf: c.paths.properties, encoding: .utf8)).contains("motd=keep"), "other settings stay")

        // A new address means the old one's dead straight away.
        c.newPackPath(recipe: "world-two")
        try? await Task.sleep(for: .milliseconds(100))
        let oldAddress = await PackHosting.check(url: twoURL, expected: otherBuild.sha1)
        equal(oldAddress.outcome, .status(404), "the old address stops working")
        let newAddress = await PackHosting.check(url: c.packAddress(recipe: "world-two")!, expected: otherBuild.sha1)
        check(newAddress.ok, "and the new one gives the same build")

        // Hosted elsewhere: the address is theirs, and nothing's served from here.
        let elsewhereToken = c.packHostSettings.recipes["world-two"]!.token
        try c.setPackElsewhere("https://example.invalid/pack.zip", recipe: "world-two")
        equal(c.packAddress(recipe: "world-two"), "https://example.invalid/pack.zip", "another host's address can be used")
        try? await Task.sleep(for: .milliseconds(100))
        let notHere = await rawRequest(port: port, "GET /\(elsewhereToken)/pack.zip HTTP/1.1\r\nHost: x\r\n\r\n")
        equal(status(notHere), "HTTP/1.1 404 Not Found", "and this Mac stops serving it")
        var badElsewhere = false
        do { try c.setPackElsewhere("not an address", recipe: "world-two") } catch { badElsewhere = true }
        check(badElsewhere, "a bad address is refused")
        try c.setPackElsewhere("", recipe: "world-two")
        check(c.packAddress(recipe: "world-two")?.contains("127.0.0.1") == true, "and it can come back")

        // Butler on the server: Leaf Juice keeps its hands off.
        let before = try String(contentsOf: c.paths.properties, encoding: .utf8)
        try FileOps.ensureDir(c.paths.plugins)
        makeJar(c.paths.plugins.appendingPathComponent("ResourcePackButler.jar"), yaml: "name: ResourcePackButler\nversion: 0.0.1\nmain: x.Y\napi-version: '1.21'\n")
        await c.refreshPlugins()
        equal(c.perWorldPackPlugin, "Resource Pack Butler", "Butler is noticed")
        var butlerRefused = ""
        do { _ = try await c.usePack(url: oneURL, sha1: otherBuild.sha1, required: true, recipe: "world-one") } catch { butlerRefused = error.localizedDescription }
        check(butlerRefused.contains("Butler"), "with Butler, the pack settings can't be written: \(butlerRefused)")
        equal(try String(contentsOf: c.paths.properties, encoding: .utf8), before, "and aren't")
        _ = try await ResourcePacks.combine(recipe("world-one", twoZip))
        try c.serveBuild(sha1: otherBuild.sha1, recipe: "world-one")
        try? await Task.sleep(for: .milliseconds(100))
        equal(c.servedPackSHA1(recipe: "world-one"), otherBuild.sha1, "with Butler, the chosen build is served even though server.properties says otherwise")
        let butlerServed = await PackHosting.check(url: oneURL, expected: otherBuild.sha1)
        check(butlerServed.ok, "and that's what the address gives")
        try FileManager.default.removeItem(at: c.paths.plugins.appendingPathComponent("ResourcePackButler.jar"))
        await c.refreshPlugins()
        try? await Task.sleep(for: .milliseconds(100))
        equal(c.servedPackSHA1(recipe: "world-one"), firstBuild.sha1, "without it, server.properties decides again")

        // WorldResourcepacks, installed on real servers today, gets the same treatment.
        makeJar(c.paths.plugins.appendingPathComponent("WorldResourcepacks.jar"), yaml: "name: WorldResourcepacks\nversion: 2.0\nmain: x.Y\napi-version: '1.21'\n")
        await c.refreshPlugins()
        equal(c.perWorldPackPlugin, "WorldResourcepacks", "WorldResourcepacks is noticed")
        var worldPacksRefused = ""
        do { _ = try await c.usePack(url: oneURL, sha1: otherBuild.sha1, required: true, recipe: "world-one") } catch { worldPacksRefused = error.localizedDescription }
        check(worldPacksRefused.contains("WorldResourcepacks"), "and the pack settings are left alone: \(worldPacksRefused)")
        equal(try String(contentsOf: c.paths.properties, encoding: .utf8), before, "unchanged")

        // Each build has its own address, which keeps giving that build whatever else changes.
        let oldPinned = c.packBuildAddress(recipe: "world-one", sha1: firstBuild.sha1)!
        let newPinned = c.packBuildAddress(recipe: "world-one", sha1: otherBuild.sha1)!
        check(oldPinned.hasSuffix("/\(firstBuild.sha1).zip") && oldPinned != newPinned, "a build's address names its hash: \(oldPinned)")
        try c.serveBuild(sha1: otherBuild.sha1, recipe: "world-one")
        try? await Task.sleep(for: .milliseconds(100))
        let stillOld = await PackHosting.check(url: oldPinned, expected: firstBuild.sha1)
        check(stillOld.ok, "the old build's address still gives the old build after a switch: \(stillOld.summary)")
        let pinnedNew = await PackHosting.check(url: newPinned, expected: otherBuild.sha1)
        check(pinnedNew.ok, "and the new one's the new: \(pinnedNew.summary)")
        let otherRecipe = await rawRequest(port: port, "GET /\(token)/\(String(repeating: "f", count: 40)).zip HTTP/1.1\r\nHost: x\r\n\r\n")
        equal(status(otherRecipe), "HTTP/1.1 404 Not Found", "a hash that isn't this recipe's build is a 404")
        let crossRecipe = await rawRequest(port: port, "GET /\(c.packHostSettings.recipes["world-two"]!.token)/\(firstBuild.sha1).zip HTTP/1.1\r\nHost: x\r\n\r\n")
        equal(status(crossRecipe), "HTTP/1.1 404 Not Found", "and one recipe's path can't reach another's builds")
        try FileManager.default.removeItem(at: c.paths.plugins.appendingPathComponent("WorldResourcepacks.jar"))
        await c.refreshPlugins()
        try c.serveBuild(sha1: firstBuild.sha1, recipe: "world-one")

        // Stopping stops, the module switch stops, and a new start comes back by itself.
        Modules.shared.set(.resourcePacks, on: false)
        var moduleRefused = false
        do { try c.startPackHost() } catch { moduleRefused = true }
        check(moduleRefused, "with the module off it won't start")
        Modules.shared.set(.resourcePacks, on: true)
        try c.startPackHost()
        await checkUntil(5, "listening again") { c.packHostIsListening }
        Modules.shared.set(.resourcePacks, on: false)
        _ = await rawRequest(port: port, "GET /\(token)/pack.zip.sha1 HTTP/1.1\r\nHost: x\r\n\r\n")
        Modules.shared.set(.resourcePacks, on: true)
        await checkUntil(5, "module switch stops it") { c.packHost?.isListening != true }
        c.stopPackHost()
        check(!c.packHostSettings.enabled, "stopping is remembered")
        let afterStop = await PackHosting.check(url: oneURL, expected: firstBuild.sha1)
        check(!afterStop.ok, "and nothing answers")
        var servingOff = ""
        do { _ = try await c.usePack(url: oneURL, sha1: firstBuild.sha1, required: true, recipe: "world-one") } catch { servingOff = error.localizedDescription }
        check(servingOff.contains("serving is off"), "a required pack can't be pointed at a stopped address: \(servingOff)")
        var wanted = c.packHostSettings
        wanted.enabled = true
        c.packHostSettings = wanted
        c.startPackHostIfWanted()
        await checkUntil(5, "comes back") { c.packHostIsListening }
        let trial = try await ServerController.adopt(root: folder("pack-hosting-trial"), name: "trial")
        var trialSettings = trial.packHostSettings
        trialSettings.enabled = true; trialSettings.address = "http://127.0.0.1"; trialSettings.port = port + 1
        trial.packHostSettings = trialSettings
        trial.isTrialCopy = true
        trial.startPackHostIfWanted()
        check(!trial.packHostIsListening && trial.packHost == nil, "a test copy never serves")

        // A port in use is reported rather than silent.
        let rival = try await ServerController.adopt(root: folder("pack-hosting-rival"), name: "rival")
        try rival.setPackHost(address: "http://127.0.0.1", port: port)
        try rival.startPackHost()
        await checkUntil(5, "a taken port is reported") { rival.packHostError != nil || rival.packHostIsListening }
        check(rival.packHostError?.contains("\(port)") == true, "and says which: \(rival.packHostError ?? "listening anyway")")
        rival.stopPackHost()

        // Addresses and paths never travel with a shared recipe.
        let exported = String(decoding: try ResourcePacks.exportRecipe(recipe("world-one", oneZip)), as: UTF8.self)
        check(!exported.contains(token) && !exported.contains("127.0.0.1"), "an exported recipe holds no address")
    } catch { failures.append("serving packs threw: \(error)") }
}

/// A hang should fail a check, not stop the suite forever.
@MainActor func withTimeLimit<T: Sendable>(seconds: Int, _ work: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// The Lab on real software, inside the sandbox folder: protection, seed, saves, and a real rehearsal.
@MainActor func runLabScenario() async {
    let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".lab-sandbox", isDirectory: true)
    setenv("LEAFJUICE_HOME", base.appendingPathComponent("home").path, 1)
    setenv("LEAFJUICE_SERVERS", base.appendingPathComponent("servers").path, 1)
    let root = LabFiles.root
    check(root.path.contains(".lab-sandbox"), "the test Lab is in the sandbox: \(root.path)")
    guard root.path.contains(".lab-sandbox") else { return }
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: LabFiles.saves)
    try? FileManager.default.removeItem(at: LabFiles.state)
    do {
        print("• LAB: someone else's folder called lab is kept")
        try FileOps.ensureDir(root)
        write("mine", root.appendingPathComponent("precious.txt"))
        let lab = LabController()
        check(lab.server == nil, "a plain folder called lab isn't the Lab")
        var didRefuse = false
        await lab.setUpWithDefaults()
        didRefuse = lab.failure?.contains("EULA") == true
        check(didRefuse, "no Lab without the EULA: \(lab.failure ?? "-")")
        check(FileOps.exists(root.appendingPathComponent("precious.txt")), "and nothing moved")
        lab.acceptEULA()

        print("• LAB: set up on 1.21.11 with the built-in seed")
        let old = try await SoftwareCatalog.latestBuild(.paper, mc: "1.21.11")!
        await lab.setUp(LabSpec(build: old))
        check(lab.failure == nil, "set up: \(lab.failure ?? "") \(lab.log.suffix(4))")
        let aside = FileOps.children(root.deletingLastPathComponent()).first { $0.lastPathComponent.hasPrefix("lab-previous-") }
        check(aside.map { FileOps.exists($0.appendingPathComponent("precious.txt")) } == true, "that folder was moved aside, whole")
        if let aside { try? FileManager.default.removeItem(at: aside) }
        guard let c = lab.server else { failures.append("no Lab"); return }
        check(c.isLab, "it's a Lab"); check(c.isTrialCopy, "and has no restore points or schedules")
        equal(c.state, .stopped, "it stops after seeding")
        check(FileOps.isDirectory(root.appendingPathComponent("mining")) || FileOps.isDirectory(root.appendingPathComponent("world/dimensions")), "worlds made")
        equal(Set(PlayerFiles.list(c.paths).compactMap(\.name)), ["Alice", "Bob", "Carol"], "bot players made")
        let props = PropertiesDocument(try String(contentsOf: c.paths.properties, encoding: .utf8))
        equal(props.value("server-ip"), "127.0.0.1", "only listens on this Mac"); equal(props.value("online-mode"), "false", "bots allowed in")
        var refused = false
        do { _ = try c.rename(to: "Other", moveFolderTo: "other") } catch { refused = true }
        check(refused, "the Lab can't be renamed"); check(FileOps.exists(root), "still there")

        print("• LAB: save, change, restore")
        await lab.save(note: "Clean seed")
        check(lab.failure == nil, "saved: \(lab.failure ?? "")")
        equal(lab.saves.count, 1, "one save listed")
        print("    \(lab.saves.first?.fileName ?? "") \(Format.bytes(lab.saves.first?.size ?? 0))")
        check(lab.saves.first?.fileName.hasSuffix("_clean-seed.tar.gz") == true, "named from the note")
        write("scribble", root.appendingPathComponent("scribble.txt"))
        let before = c.id
        await lab.restore(lab.saves[0])
        check(lab.failure == nil, "restored: \(lab.failure ?? "")")
        check(!FileOps.exists(root.appendingPathComponent("scribble.txt")), "later changes are gone")
        equal(lab.server?.id, before, "same server, as far as the app can tell")
        equal(Set(PlayerFiles.list(lab.server!.paths).compactMap(\.name)), ["Alice", "Bob", "Carol"], "players are back")

        print("• LAB: wipe and start fresh")
        await lab.wipeAndStartFresh()
        check(lab.failure == nil, "wiped: \(lab.failure ?? "") \(lab.log.suffix(3))")
        equal(lab.server?.profile.software.mcVersion, "1.21.11", "same version"); check(lab.server?.plugins.contains { $0.key == "multiverse-core" } == true, "same plugins")
        equal(lab.saves.count, 1, "saves survive a wipe")

        print("• LAB: rehearse a stand-in server's upgrade to 26.3, using the seeded Lab as last time's data")
        let targetRoot = base.appendingPathComponent("servers/lab-rehearsal-target", isDirectory: true)
        try? FileManager.default.removeItem(at: targetRoot)
        try FileOps.ensureDir(targetRoot)
        let target = try await ServerController.adopt(root: targetRoot, name: "Pretend")
        defer { target.stopTicker(); try? FileManager.default.removeItem(at: targetRoot) }
        target.profile.software.flavor = .paper; target.profile.software.mcVersion = "1.21.11"
        target.profile.backup.enabled = false; target.profile.lastPluginCheck = Date(); target.profile.software.lastCheck = Date()
        for source in LabRecipe.defaultPlugins { try await target.addPlugin(source: source) }
        await target.refreshPlugins()
        let new = try await SoftwareCatalog.latestBuild(.paper, mc: "26.3")!
        await lab.rehearse(for: target, to: new)
        check(lab.failure == nil, "rehearsal ran: \(lab.failure ?? "") \(lab.log.suffix(4))")
        guard let report = lab.report else { failures.append("no report"); return }
        print("    \(report.headline)")
        for path in [report.migrated, report.fresh] {
            print("    \(path.title): \(path.route)")
            for line in path.checks { print("      [\(line.outcome.rawValue)] \(line.title) \(line.detail.prefix(160))") }
        }
        check(report.migrated.route.contains("Kept the Lab's data"), "it used the data from last time")
        check(report.migrated.passed, "the upgrade path passes on good software: \(report.migrated.failures.map(\.title))")
        check(report.fresh.passed, "and so does the fresh path: \(report.fresh.failures.map(\.title))")
        equal(report.verdict, .bothPassed, "verdict")
        equal(Set(report.migrated.checks.filter { $0.outcome != .failed }.map(\.title)), Set(report.fresh.checks.filter { $0.outcome != .failed }.map(\.title)), "the same checks on both")
        check(!report.migrated.checks.contains { $0.outcome == .skipped }, "nothing skipped")
        equal(lab.server?.profile.software.mcVersion, "26.3", "the Lab ends on the new version, ready for next time")
        equal(Set(FileOps.children(targetRoot).map(\.lastPathComponent)).contains("world"), false, "the target server wasn't started or touched")

        // A check that can't fail proves nothing, so break things on purpose.
        print("• LAB: damaged data on the upgrade path only")
        await lab.restore(lab.saves[0])
        check(lab.failure == nil, "back to the 1.21.11 save: \(lab.failure ?? "")")
        guard let damaged = lab.server else { failures.append("no Lab"); return }
        let alice = PlayerPaths(damaged.paths).data(PlayerFiles.offlineUUID(name: "Alice"))
        check(FileOps.exists(alice), "Alice's file found to damage")
        try FileManager.default.removeItem(at: alice)
        for container in PlayerPaths(damaged.paths).inventoryContainers(name: "Alice") {
            try? FileManager.default.removeItem(at: PlayerPaths(damaged.paths).inventories.appendingPathComponent(container))
        }
        await lab.rehearse(for: target, to: new)
        if let r = lab.report {
            for line in r.migrated.failures { print("      [upgrade failed] \(line.title) \(line.detail.prefix(140))") }
            for line in r.fresh.failures { print("      [fresh failed] \(line.title) \(line.detail.prefix(140))") }
            equal(r.verdict, .upgradeFailed, "lost data fails the upgrade path, not the fresh one")
            check(r.migrated.failures.contains { $0.title == "Inventory came through" }, "and says what was lost")
        } else { failures.append("no report") }

        print("• LAB: a plugin that can't load fails both paths")
        write("not a jar at all", target.paths.plugins.appendingPathComponent("Broken.jar"))
        await target.refreshPlugins()
        print("    target plugins: \(target.plugins.map { "\($0.fileName) enabled=\($0.enabled)" })")
        await lab.rehearse(for: target, to: new)
        if let r = lab.report {
            for line in r.migrated.failures { print("      [upgrade failed] \(line.title) \(line.detail.prefix(140))") }
            for line in r.fresh.failures { print("      [fresh failed] \(line.title) \(line.detail.prefix(140))") }
            equal(r.verdict, .bothFailed, "a bad plugin fails both")
        } else { failures.append("no report") }
        check(lab.failure == nil, "those ran to the end: \(lab.failure ?? "")")
        lab.server?.stopTicker()
    } catch { failures.append("Lab scenario threw: \(error)") }
}

/// Tests a real server's plugins in the sandbox's Lab. The real folder is only read: its jars and settings
/// files are copied to a stand-in folder first, and that's what gets adopted.
@MainActor func runLabModel(_ source: URL, mc: String, settings: Bool) async {
    let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".lab-sandbox", isDirectory: true)
    setenv("LEAFJUICE_HOME", base.appendingPathComponent("home").path, 1)
    setenv("LEAFJUICE_SERVERS", base.appendingPathComponent("servers").path, 1)
    guard LabFiles.root.path.contains(".lab-sandbox") else { failures.append("not in the sandbox"); return }
    let stand = base.appendingPathComponent("servers/lab-model", isDirectory: true)
    try? FileManager.default.removeItem(at: stand)
    do {
        let from = ServerPaths(root: source), to = ServerPaths(root: stand)
        try FileOps.ensureDir(to.plugins)
        for item in FileOps.children(from.plugins) where item.pathExtension == "jar" {
            try FileManager.default.copyItem(at: item, to: to.plugins.appendingPathComponent(item.lastPathComponent))
        }
        for folder in FileOps.children(from.plugins) where FileOps.isDirectory(folder) {
            for rel in LabController.settingsToCopy(in: folder) {
                let target = to.plugins.appendingPathComponent(folder.lastPathComponent).appendingPathComponent(rel)
                try FileOps.ensureDir(target.deletingLastPathComponent())
                try FileManager.default.copyItem(at: folder.appendingPathComponent(rel), to: target)
            }
        }
        let model = try await ServerController.adopt(root: stand, name: "Model")
        defer { model.stopTicker() }
        model.isTrialCopy = true
        model.profile.software.flavor = .paper; model.profile.software.mcVersion = mc
        model.profile.backup.enabled = false; model.profile.lastPluginCheck = Date(); model.profile.software.lastCheck = Date()
        await model.refreshPlugins()
        let lab = LabController()
        lab.acceptEULA()
        func show(_ station: LabStation) {
            guard let result = lab.result(station) else { print("    \(station.title): no result. \(lab.failure ?? "") \(lab.log.suffix(3))"); return }
            print("    \(station.title): \(result.outcome.rawValue)  \(result.note)")
            for line in result.leftOut { print("      \(line)") }
            for line in result.checks where line.outcome != .passed { print("      [\(line.outcome.rawValue)] \(line.title) \(line.detail.prefix(200))") }
            for batch in result.groups {
                print("      [\(batch.outcome.rawValue)] \(batch.title): \(batch.plugins.joined(separator: ", "))")
                for line in batch.fresh where line.outcome != .passed { print("          [\(line.outcome.rawValue)] \(line.title) \(line.detail.prefix(200))") }
                for line in batch.withSettings ?? [] where line.outcome != .passed { print("          [\(line.outcome.rawValue)] \(line.title) \(line.detail.prefix(200))") }
                for note in batch.notes { print("          note: \(note)") }
            }
        }
        await lab.run(.plugins, model: model)
        show(.plugins)
        if settings {
            lab.continueAnyway(.plugins)
            await lab.run(.settings, model: model)
            show(.settings)
        }
        lab.server?.stopTicker()
    } catch { failures.append("threw: \(error)") }
}

@MainActor func seedSandbox(_ root: URL, table: ProtocolTable) async throws {
    try FileOps.ensureDir(root)
    write("server-port=25580\nonline-mode=false\nview-distance=4\nsimulation-distance=4\nmotd=Leaf Juice sandbox\nlevel-type=minecraft\\:flat\nnetwork-compression-threshold=-1\nspawn-protection=0\nmax-tick-time=-1\n", root.appendingPathComponent("server.properties"))
    let c = try await ServerController.adopt(root: root, name: "Sandbox seed")
    defer { c.forceStop(); c.stopTicker() }
    c.profile.backup.enabled = false
    c.profile.backup.destination = root.appendingPathComponent(".leafjuice/backups").path
    c.profile.lastPluginCheck = Date(); c.profile.software.lastCheck = Date()
    c.profile.launch.restartOnCrash = false
    c.profile.launch.maxMemoryMB = 2048; c.profile.launch.minMemoryMB = 1024
    try EULA.accept(c.paths)
    let build = try await SoftwareCatalog.latestBuild(.paper, mc: "1.21.11")!
    try await c.installSoftware(build)
    try await c.addPlugin(source: Multiverse.source)
    try await c.addPlugin(source: .modrinth(project: "multiverse-inventories", allowBeta: false))
    try await c.addPlugin(source: .modrinth(project: "luckperms", allowBeta: false))
    await c.refreshPlugins()
    print("    plugins: \(c.plugins.map { "\($0.name) \($0.version)" })")
    await bootOK(c, "seed")
    for (name, env, type) in [("mining", WorldEnvironment.normal, WorldType.flat), ("creative", .normal, .flat), ("deep", .nether, .normal)] {
        var w = NewWorld(); w.name = name; w.environment = env; w.type = type
        try await c.createWorld(w)
        equal(c.worldOperation?.succeeded, true, "\(name) created: \(c.console.suffix(3).map(\.text))")
    }

    let alice = try await join("Alice", c, table, port: 25580)
    let bob = try await join("Bob", c, table, port: 25580)
    let carol = try await join("Carol", c, table, port: 25580)
    for (who, item, n) in [("Alice", "diamond", 5), ("Alice", "golden_apple", 2), ("Bob", "emerald", 9), ("Carol", "netherite_ingot", 1)] {
        let done = await ask(c, "give \(who) minecraft:\(item) \(n)", expecting: "Gave ")
        check(done != nil, "gave \(who) \(item)")
    }
    // Into another world: Multiverse-Inventories keeps a separate inventory there.
    await expectLine(c, "mv tp Alice mining", "Alice", "Alice sent to mining: \(c.console.suffix(3).map(\.text))")
    try? await Task.sleep(for: .seconds(3))
    let inMining = await ask(c, "data get entity Alice Inventory", expecting: "entity data")
    print("    Alice in mining: \(inMining ?? "-")")
    await expectLine(c, "give Alice minecraft:iron_ingot 7", "Gave ", "gave Alice iron in mining")
    await expectLine(c, "mv tp Bob creative", "Bob", "Bob sent to creative")
    try? await Task.sleep(for: .seconds(3))
    await expectLine(c, "give Bob minecraft:bedrock 3", "Gave ", "gave Bob bedrock in creative")
    await expectLine(c, "mv tp Alice world", "Alice", "Alice back")
    await expectLine(c, "mv tp Bob world", "Bob", "Bob back")
    try? await Task.sleep(for: .seconds(3))
    for bot in [alice, bob, carol] { await leave(bot, c) }
    await shutOK(c)
    let p = PlayerPaths(c.paths)
    print("    data files: \(FileOps.children(p.dataFolder).map(\.lastPathComponent))")
    print("    inventories: \(p.inventoryContainers(name: "Alice"))")
    let sample = FileOps.children(p.inventories.appendingPathComponent("worlds/mining")).first
    if let sample, let text = try? String(contentsOf: sample, encoding: .utf8) { print("    real inventory file \(sample.lastPathComponent): \(text.prefix(500))") }
    check(!PlayerFiles.list(c.paths).isEmpty, "real player data exists")
    write("ok", root.appendingPathComponent("seeded"))
}

@MainActor func playerScenario(_ c: ServerController, table: ProtocolTable, port: Int) async throws {
    let p = PlayerPaths(c.paths)
    let players = PlayerFiles.list(c.paths)
    print("    players: \(players.map { "\($0.title) \(Int($0.playTime ?? 0))s" })")
    let alice = players.first { $0.name == "Alice" }!
    equal(Set(players.compactMap(\.name)), ["Alice", "Bob", "Carol"], "all three players read from real files")
    equal(alice.uuid.lowercased(), PlayerFiles.offlineUUID(name: "Alice"), "offline UUID matches the server's own")
    check((alice.playTime ?? 0) > 0, "play time read from real stats")
    let worldFile = PlayerFiles.summary(ofInventoryFile: p.inventories.appendingPathComponent("worlds/mining/Alice.json"))
    check(worldFile?.items.contains { $0.item == "minecraft:iron_ingot" && $0.count == 7 } == true, "real per-world file previewed: \(worldFile?.items.map(\.item) ?? [])")
    let summary = PlayerFiles.summary(of: p.data(alice.uuid))
    check(summary?.items.contains { $0.item == "minecraft:diamond" && $0.count == 5 } == true, "real inventory read: \(summary?.items.map(\.item) ?? [])")
    let containers = p.inventoryContainers(name: "Alice")
    print("    Alice's containers: \(containers)")
    check(containers.contains { $0.contains("mining") }, "per-world inventory exists: \(containers)")
    check(PlayerHistory.read(c.paths).contains { $0.name == "Alice" }, "real sessions read from real logs")

    // Real file round trip: every real player file survives read and write.
    let doc = try NBT.read(p.data(alice.uuid))
    equal(try NBT.decode(try NBT.encode(doc)), doc, "real player file round trips")
    let level = try NBT.read(p.world.appendingPathComponent("level.dat"))
    equal(try NBT.decode(try NBT.encode(level)), level, "real level.dat round trips")

    // Snapshot while playing, grief both worlds, restore, and ask the game.
    await bootOK(c, "first")
    var aliceBot = try await join("Alice", c, table, port: port)
    c.profile.playerSnapshots.intervalMinutes = 1
    _ = await ask(c, "save-all flush", expecting: "Saved the game")
    c.tickPlayerSnapshots(elapsed: 61)
    let live = PlayerSnapshots.list(uuid: alice.uuid.lowercased(), profile: c.profile) + PlayerSnapshots.list(uuid: alice.uuid, profile: c.profile)
    equal(live.first?.trigger, "playing", "snapshot taken mid-game")
    await expectLine(c, "clear Alice", "Removed", "griefed in the main world")
    await expectLine(c, "mv tp Alice mining", "Alice", "off to mining")
    try? await Task.sleep(for: .seconds(3))
    let mining = await ask(c, "data get entity Alice Inventory", expecting: "entity data")
    check(mining?.contains("iron_ingot") == true, "per-world inventory is really separate: \(mining ?? "-")")
    _ = await ask(c, "clear Alice", expecting: "Removed")
    _ = await ask(c, "mv tp Alice world", expecting: "Alice")
    try? await Task.sleep(for: .seconds(3))
    let emptied = await ask(c, "data get entity Alice Inventory", expecting: "entity data")
    check(emptied?.contains("diamond") == false, "griefed: \(emptied ?? "-")")
    await leave(aliceBot, c)
    await checkUntil(8, "snapshot as she left") { PlayerSnapshots.list(uuid: alice.uuid, profile: c.profile).contains { $0.trigger == "left" } }

    // Multiverse-Inventories is in use, so this waits for a restart.
    let snapshot = live.first!
    print("    snapshot holds: \(snapshot.containers)")
    let outcome = try c.restorePlayer(snapshot, inventoryOnly: true, containers: snapshot.containers)
    equal(outcome, .staged, "restore waits for the restart with per-world data")
    c.restart(reason: "Test")
    await checkUntil(240, "restart applies it: \(c.pending.map { $0.conflict ?? $0.summary })") { c.state == .running && c.pending.isEmpty }
    aliceBot = try await join("Alice", c, table, port: port)
    try? await Task.sleep(for: .seconds(1))
    let back = await ask(c, "data get entity Alice Inventory", expecting: "entity data")
    check(back?.contains("diamond") == true && back?.contains("golden_apple") == true, "IN GAME: main inventory restored: \(back ?? "-")")
    _ = await ask(c, "mv tp Alice mining", expecting: "Alice")
    try? await Task.sleep(for: .seconds(3))
    let minedBack = await ask(c, "data get entity Alice Inventory", expecting: "entity data")
    check(minedBack?.contains("iron_ingot") == true, "IN GAME: per-world inventory restored: \(minedBack ?? "-")")
    _ = await ask(c, "mv tp Alice world", expecting: "Alice")
    try? await Task.sleep(for: .seconds(3))
    await leave(aliceBot, c)

    // Griefed, gone, and the plugin has saved the griefed state. Restoring must still win.
    let carol = players.first { $0.name == "Carol" }!
    var carolBot = try await join("Carol", c, table, port: port)
    _ = await ask(c, "save-all flush", expecting: "Saved the game")
    let carolSnap = try PlayerSnapshots.take(uuid: carol.uuid, name: "Carol", trigger: "manual", paths: c.paths, profile: c.profile)
    _ = await ask(c, "clear Carol", expecting: "Removed")
    await leave(carolBot, c)
    try? await Task.sleep(for: .seconds(1))
    print("    Carol's snapshot holds: \(carolSnap.containers)")
    equal(try c.restorePlayer(carolSnap, inventoryOnly: true, containers: carolSnap.containers), .staged, "with the plugin installed, a restore always waits for the restart")
    c.restart(reason: "Test")
    await checkUntil(240, "restart applies Carol's restore") { c.state == .running && c.pending.isEmpty }
    carolBot = try await join("Carol", c, table, port: port)
    try? await Task.sleep(for: .seconds(1))
    let carolInv = await ask(c, "data get entity Carol Inventory", expecting: "entity data")
    check(carolInv?.contains("netherite_ingot") == true, "IN GAME: restored after griefing: \(carolInv ?? "-")")
    await leave(carolBot, c)
    await shutOK(c)

    // From a backup, without touching the world.
    let backup = try await c.backupNow(trigger: "manual")
    let fromBackup = try await PlayerSnapshots.fromBackup(backup, uuid: alice.uuid, name: "Alice", paths: c.paths, profile: c.profile)
    check(FileOps.exists(PlayerSnapshots.location(fromBackup, profile: c.profile).appendingPathComponent("player.dat")), "player pulled from a real backup")
    check(!fromBackup.containers.isEmpty, "with per-world files: \(fromBackup.containers)")

    // Comparing real backups shows real item changes.
    await bootOK(c, "for compare")
    carolBot = try await join("Carol", c, table, port: port)
    _ = await ask(c, "give Carol minecraft:cake 4", expecting: "Gave ")
    await leave(carolBot, c)
    await shutOK(c)
    let after = try await c.backupNow(trigger: "manual")
    let diff = try await BackupCompare.compare(backup, after, profile: c.profile, paths: c.paths)
    let carolChange = diff.players.first { $0.name == "Carol" }
    check(carolChange?.items.contains { $0.item == "minecraft:cake" && $0.before == 0 && $0.after == 4 } == true, "real diff finds the item: \(diff.players.map { "\($0.name ?? "?"): \($0.items.map(\.item))" })")

    // A real name change: Bob comes back as Robert, on a new profile (as offline mode does).
    await bootOK(c, "for rename")
    let robert = try await join("Robert", c, table, port: port)
    _ = await ask(c, "give Robert minecraft:cookie 8", expecting: "Gave ")
    await leave(robert, c)
    await shutOK(c)
    let bobID = players.first { $0.name == "Bob" }!.uuid
    let robertID = PlayerFiles.offlineUUID(name: "Robert")
    check(FileOps.exists(p.data(robertID)), "new profile was created")
    print("    Bob's containers: \(p.inventoryContainers(name: "Bob")), Robert's: \(p.inventoryContainers(name: "Robert"))")
    var plan = MergePlan(from: PlayerRef(uuid: bobID, name: "Bob"), to: PlayerRef(uuid: robertID, name: "Robert"))
    plan.keepFromSource = true
    print("    conflicts: \(PlayerMerge.conflicts(plan, paths: c.paths))")
    for conflict in PlayerMerge.conflicts(plan, paths: c.paths) { plan.useOldContainer[conflict] = true }
    let oldStats = PlayerFiles.playTicks(p.stats(bobID)) ?? 0, newStats = PlayerFiles.playTicks(p.stats(robertID)) ?? 0
    try await c.mergePlayers(plan)
    check(!FileOps.exists(p.data(bobID)), "old profile merged away")
    equal(PlayerFiles.playTicks(p.stats(robertID)), oldStats + newStats, "play time adds up")
    await bootOK(c, "after merge")
    let merged = try await join("Robert", c, table, port: port)
    try? await Task.sleep(for: .seconds(1))
    let mergedInv = await ask(c, "data get entity Robert Inventory", expecting: "entity data")
    check(mergedInv?.contains("emerald") == true, "IN GAME: Bob's items, as Robert: \(mergedInv ?? "-")")
    let uuidLine = await ask(c, "data get entity Robert UUID", expecting: "entity data")
    print("    Robert's UUID in game: \(uuidLine ?? "-")")
    let want = NBT.uuid(UUID(uuidString: robertID)!)
    if case let .intArray(words) = want { check(uuidLine?.contains("\(words[0])") == true, "IN GAME: identifies as the kept profile") }
    _ = await ask(c, "mv tp Robert creative", expecting: "Robert")
    try? await Task.sleep(for: .seconds(3))
    let creative = await ask(c, "data get entity Robert Inventory", expecting: "entity data")
    check(creative?.contains("bedrock") == true, "IN GAME: Bob's per-world inventory follows the rename: \(creative ?? "-")")
    _ = await ask(c, "mv tp Robert world", expecting: "Robert")
    try? await Task.sleep(for: .seconds(3))
    await leave(merged, c)
    await shutOK(c)
    c.keepUpgrade()

    // Cleanup on a real server: apply everything it's sure of, and the server still runs.
    write("x", c.paths.root.appendingPathComponent("hs_err_pid99.log"))
    write("x", c.paths.root.appendingPathComponent("bukkit.yml.old"))
    await c.refreshPlugins()
    await c.scanForCleanup()
    print("    cleanup: \(c.cleanupItems.map { "\($0.path) [\($0.confidence)]" })")
    let sure = c.cleanupItems.filter { $0.confidence == .safe }
    check(!sure.contains { $0.path.hasPrefix("world") || $0.path == c.profile.software.jarName }, "nothing essential suggested")
    try await c.cleanUp(sure)
    await bootOK(c, "after cleanup")
    let againAlice = try await join("Alice", c, table, port: port)
    await leave(againAlice, c)
    await shutOK(c)

    // Real stats, regulars, failed joins, MSPT and GC.
    await c.refreshStats()
    print("    stats: \(c.playerStats.map { "\($0.name): \(PlayerStat.all[0].display($0.value(PlayerStat.all[0])))" })")
    check(c.playerStats.contains { $0.name == "Alice" && $0.value(PlayerStat.all[0]) > 0 }, "real stats read")
    check(c.playerActivity.contains { $0.name == "Alice" }, "real regulars read")
    await bootOK(c, "for analytics")
    c.requestTPS()
    await checkUntil(10, "real MSPT read: \(c.console.suffix(3).map(\.text))") { c.mspt != nil }
    print("    tps \(String(describing: c.tps?.oneMinute)) mspt \(String(describing: c.mspt))")
    check(!c.console.suffix(6).contains { $0.text.contains("tick times") }, "real MSPT stays out of the console")
    check(FileOps.exists(GCLog.file(c.paths)), "real GC log written")
    print("    gc pause: \(String(describing: GCLog.longestPause(in: (try? String(contentsOf: GCLog.file(c.paths), encoding: .utf8)) ?? "")))")
    _ = await ask(c, "whitelist on", expecting: "white")
    let refused = try Bot(name: "Stranger", port: port, table: table)
    await checkUntil(15, "refused join recorded: \(c.console.suffix(4).map(\.text))") { c.failedJoins.contains { $0.name == "Stranger" } }
    print("    refused: \(String(describing: c.failedJoins.first))")
    refused.leave()
    _ = await ask(c, "whitelist off", expecting: "white")
    let drillRecord = try await c.backupNow(trigger: "manual", scope: .everything)
    await c.runBackupDrill(drillRecord)
    equal(c.profile.lastDrill?.passed, true, "real backup drill: \(c.profile.lastDrill?.detail ?? "")")
    print("    drill: \(c.profile.lastDrill?.detail ?? "")")
    await shutOK(c)
    await c.refreshHistory()
    print("    timeline: \(c.timeline.prefix(8).map(\.title))")
    check(c.timeline.contains { $0.kind == .player && $0.title.contains("Merged") }, "merge on the real timeline")

    // World rename with real per-world inventories.
    await c.refreshWorlds()
    let miningWorld = c.worlds.first { $0.title == "mining" }!
    try await c.applyRename(c.worldRenamePlan(miningWorld, to: "quarry"), rebuild: { c.worldRenamePlan(miningWorld, to: "quarry") })
    check(FileOps.exists(p.inventories.appendingPathComponent("worlds/quarry")), "per-world inventories follow a world rename")
    await bootOK(c, "after world rename")
    let tester = try await join("Alice", c, table, port: port)
    let listing = await ask(c, "mv list", expecting: "quarry")
    check(listing?.contains("UNLOADED") == false, "renamed world loaded: \(listing ?? "-")")
    _ = await ask(c, "mv tp Alice quarry", expecting: "Alice")
    try? await Task.sleep(for: .seconds(3))
    let quarried = await ask(c, "data get entity Alice Inventory", expecting: "entity data")
    check(quarried?.contains("iron_ingot") == true, "IN GAME: inventory followed the world's new name: \(quarried ?? "-")")
    _ = await ask(c, "mv tp Alice world", expecting: "Alice")
    try? await Task.sleep(for: .seconds(3))
    await leave(tester, c)
    await shutOK(c)
    c.keepUpgrade()

    // And all of it on Minecraft 26.x.
    section("SANDBOX: the same on Minecraft 26.3")
    let table26 = try await ProtocolTable.load(mc: "26.3", cache: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".lab-sandbox/protocol"), java: c.runtimes.first { $0.major >= 25 }?.path ?? "/usr/bin/java")
    print("    protocol \(table26.version)")
    if !c.runtimes.contains(where: { $0.major >= 25 }) { try await c.installJava(major: 25) }
    let newest = try await SoftwareCatalog.latestBuild(.paper, mc: "26.3")!
    try await c.installSoftware(newest)
    c.keepUpgrade()
    await bootOK(c, "26.3")
    let p26 = PlayerPaths(c.paths)
    check(p26.dataFolder.path.hasSuffix("players/data"), "player data moved: \(p26.dataFolder.path)")
    let modernAlice = try await join("Alice", c, table26, port: port)
    let invModern = await ask(c, "data get entity Alice Inventory", expecting: "entity data")
    check(invModern?.contains("diamond") == true, "IN GAME on 26.3: inventory survived: \(invModern ?? "-")")
    _ = await ask(c, "save-all flush", expecting: "Saved the game")
    let list26 = PlayerFiles.list(c.paths)
    print("    26.x players: \(list26.map(\.title))")
    check(list26.contains { $0.name == "Alice" }, "players read in the new layout")
    let snap26 = try PlayerSnapshots.take(uuid: PlayerFiles.offlineUUID(name: "Alice"), name: "Alice", trigger: "manual", paths: c.paths, profile: c.profile)
    check(FileOps.exists(PlayerSnapshots.location(snap26, profile: c.profile).appendingPathComponent("player.dat")), "snapshot in the new layout")
    _ = await ask(c, "clear Alice", expecting: "Removed")
    await leave(modernAlice, c)
    await shutOK(c)
    try PlayerSnapshots.restore(snap26, inventoryOnly: true, containers: snap26.containers, paths: c.paths, profile: c.profile)
    await c.refreshWorlds()
    print("    26.x worlds: \(c.worlds.map { "\($0.name)=\($0.relativePath ?? "-")" })")
    let creativeWorld = c.worlds.first { $0.title == "creative" }
    check(creativeWorld != nil, "extra world found on 26.x")
    if let creativeWorld {
        try await c.applyRename(c.worldRenamePlan(creativeWorld, to: "workshop"), rebuild: { c.worldRenamePlan(creativeWorld, to: "workshop") })
        c.keepUpgrade()
    }
    await bootOK(c, "26.3 after rename")
    let last = try await join("Alice", c, table26, port: port)
    try? await Task.sleep(for: .seconds(1))
    let invBack = await ask(c, "data get entity Alice Inventory", expecting: "entity data")
    check(invBack?.contains("diamond") == true, "IN GAME on 26.3: restored: \(invBack ?? "-")")
    let list26b = await ask(c, "mv list", expecting: "workshop")
    check(list26b != nil && list26b?.contains("UNLOADED") == false, "IN GAME on 26.3: renamed world loaded: \(list26b ?? "-"); \(c.console.suffix(8).map(\.text))")
    await leave(last, c)
    await shutOK(c)
}

@MainActor func until(_ seconds: Int, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<(seconds * 4) {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(250))
    }
    return condition()
}

@MainActor func checkUntil(_ seconds: Int, _ label: @autoclosure () -> String, line: Int = #line, _ condition: () -> Bool) async {
    let result = await until(seconds, condition)
    check(result, label(), line: line)
}

try? await Task.sleep(for: .seconds(1))
try? FileManager.default.removeItem(at: scratch)
print("\n\(passed) passed, \(failures.count) failed")
for failure in failures { print("  - \(failure)") }
exit(failures.isEmpty ? 0 : 1)
