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

@MainActor func check(_ condition: @autoclosure () -> Bool, _ label: String, line: Int = #line) {
    if condition() { passed += 1 } else { failures.append("line \(line): \(label)"); print("  FAIL \(label) (line \(line))") }
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
    check(!Backups.items(root, scope: .everything).contains("logs"), "skips logs")
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
