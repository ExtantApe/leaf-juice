// Self-tests, runnable with just the Command Line Tools.
//   swift run leafjuice-check          Offline suite, plus the full server lifecycle against a small
//                                      stand-in jar (compiled here if a JDK is available). No Minecraft.
//   ... --live                         Also calls the real Paper, Modrinth, Hangar, Spiget, GitHub APIs.
//   ... --real-paper --i-accept-the-minecraft-eula
//                                      Boots real Paper. The second flag is your own acceptance of
//                                      https://aka.ms/MinecraftEULA, for a throwaway server in a temp folder.
import Foundation
@testable import LeafJuiceCore

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
    let pages = Set(["launch", "plugins", "configs", "software", "backups", "changes", "console", "overview"])
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

await runLifecycleWithStandIn()
if CommandLine.arguments.contains("--live") { await runLiveAPIs() }
if CommandLine.arguments.contains("--real-paper") {
    if CommandLine.arguments.contains("--i-accept-the-minecraft-eula") {
        await runRealPaper()
    } else {
        print("Skipping --real-paper: it needs --i-accept-the-minecraft-eula, your own acceptance of \(EULA.url).")
    }
}

@MainActor func runLiveAPIs() async {
    section("LIVE: APIs")
    do {
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
            await c.startTrial(.custom(title: "Throws", { _ in throw LeafError("It went wrong") }))
            equal(c.trialReport?.failure, "It went wrong", "failure reported"); await c.collapseTrial()
            check(c.state == .running, "real server ran throughout")
            try? FileManager.default.removeItem(at: c.paths.plugins.appendingPathComponent("DiscordSRV.jar"))
            await c.refreshPlugins()
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
