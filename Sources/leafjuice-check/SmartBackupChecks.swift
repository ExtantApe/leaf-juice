import Foundation
@testable import LeafJuiceCore

/// Smart backups (D186): when to back up, what to keep, where it goes, and the disk guard.
@MainActor func smartBackupChecks() async {
    section("Smart backups: when")
    let now = Date()
    var c = SmartBackupConfig()
    func act(_ players: Int = 0, empty: Double? = nil, played: Bool = false, changed: Double? = nil, last: Double? = nil) -> SmartBackup.Activity {
        SmartBackup.Activity(now: now, playersOnline: players, emptySince: empty.map { now.addingTimeInterval(-$0 * 60) }, playedSinceBackup: played,
                             worldChangedAt: changed.map { now.addingTimeInterval(-$0 * 60) }, lastBackup: last.map { now.addingTimeInterval(-$0 * 60) })
    }
    func backs(_ a: SmartBackup.Activity, _ cfg: SmartBackupConfig = c) -> String? {
        if case let .backUp(trigger, _) = SmartBackup.decide(cfg, a) { return trigger }
        return nil
    }
    equal(backs(act(2, played: true, last: 120)), nil, "people playing, last backup two hours ago: waits")
    equal(backs(act(2, played: true, last: 6 * 60 + 1)), "during-play", "a session past six hours since the last backup: backs up")
    equal(backs(act(empty: 5, played: true, last: 300)), nil, "everyone left five minutes ago: waits for a quick reconnect")
    equal(backs(act(empty: 11, played: true, last: 300)), "after-play", "empty for eleven minutes after play: backs up")
    equal(backs(act(empty: 30, played: true, last: 30)), nil, "but never within the minimum gap of the last one")
    equal(backs(act(empty: 30, played: true)), "after-play", "no backup yet at all: backs up after play")
    equal(backs(act(played: true, last: 300)), nil, "played, but not seen empty yet: waits")
    equal(backs(act(empty: 600, played: false, changed: 10, last: 25 * 60)), "world-changed", "nobody played, but the world changed and the last backup is a day old")
    equal(backs(act(empty: 600, played: false, changed: 10, last: 5 * 60)), nil, "changed with nobody on, five hours ago: waits for the daily limit")
    equal(backs(act(empty: 600, played: false, changed: 30 * 60, last: 25 * 60)), nil, "nothing changed since the last backup: waits, however old it is")
    equal(backs(act(empty: 600, played: false, changed: nil, last: 48 * 60)), nil, "no sign of change: waits")
    c.minimumGapMinutes = 0
    equal(backs(act(empty: 30, played: true, last: 1)), nil, "a gap set below five minutes is treated as five")
    c = SmartBackupConfig()
    if case let .wait(why) = SmartBackup.decide(c, act(empty: 5, played: true, last: 300)) { check(why.contains("10"), "waiting says why, in words: \(why)") }

    section("Smart backups: settings")
    let old = try? JSONStore.decoder.decode(BackupConfig.self, from: Data(#"{"enabled":true,"intervalHours":6,"scope":"everything","keepLast":3,"keepDays":14,"autoDrill":false,"beforeUpdates":true}"#.utf8))
    check(old?.smart.timing == .interval && old?.smart.tiered == false && old?.intervalHours == 6 && old?.keepLast == 3,
          "a server from before smart backups keeps its schedule and keeping rules until the owner switches")
    check(BackupConfig().smart.timing == .afterPlay && BackupConfig().smart.tiered, "a new server starts with smart backups and tiered keeping")
    let partial = try? JSONStore.decoder.decode(SmartBackupConfig.self, from: Data(#"{"timing":"afterPlay","idleMinutes":20}"#.utf8))
    check(partial?.idleMinutes == 20 && partial?.minimumGapMinutes == 60 && partial?.targets == [], "missing fields take their defaults")
    var roundTrip = BackupConfig(); roundTrip.smart.targets = ["/Volumes/MadeUp/Backups"]; roundTrip.playedSinceBackup = true
    let again = try? JSONStore.decoder.decode(BackupConfig.self, from: JSONStore.encoder.encode(roundTrip))
    check(again?.smart.targets == ["/Volumes/MadeUp/Backups"] && again?.playedSinceBackup == true, "targets and who-played survive a save")

    section("Smart backups: keeping a spread")
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let base = cal.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12))!
    func record(_ hoursAgo: Double, pinned: Bool = false) -> BackupRecord {
        let d = base.addingTimeInterval(-hoursAgo * 3600)
        var r = BackupRecord(fileName: "b-\(Int(hoursAgo)).tar.gz", date: d, size: 1, scope: .everything, trigger: "after-play", software: "Paper", mcVersion: "26.3", serverName: "Made-up")
        r.pinned = pinned
        return r
    }
    // Four backups a day for 120 days.
    var records = stride(from: 1.0, through: 120 * 24, by: 6).map { record($0) }
    records.append(record(100 * 24 + 3, pinned: true))
    let doomed = Set(SmartBackup.tieredPrunable(records, config: SmartBackupConfig(), now: base, protecting: "b-1.tar.gz", calendar: cal).map(\.fileName))
    let kept = records.filter { !doomed.contains($0.fileName) }
    check(kept.filter { $0.date >= base.addingTimeInterval(-24 * 3600) }.count == 4, "everything from the last day is kept")
    let dailyBand = kept.filter { $0.date < base.addingTimeInterval(-24 * 3600) && $0.date >= base.addingTimeInterval(-7 * 86_400) }
    check(Set(dailyBand.map { cal.dateComponents([.year, .month, .day], from: $0.date) }).count == dailyBand.count && dailyBand.count >= 6, "then one a day for a week (\(dailyBand.count))")
    let weeklyBand = kept.filter { $0.date < base.addingTimeInterval(-7 * 86_400) && $0.date >= base.addingTimeInterval(-56 * 86_400) && !$0.pinned }
    check(Set(weeklyBand.map { cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: $0.date) }).count == weeklyBand.count && (7...9).contains(weeklyBand.count), "then one a week for eight weeks (\(weeklyBand.count))")
    check(kept.contains { $0.pinned }, "a pinned backup is never deleted, however old")
    let oldest = records.min { $0.date < $1.date }!
    check(kept.contains { $0.fileName == oldest.fileName }, "nor the server's very first backup")
    check(!kept.contains { $0.date < base.addingTimeInterval(-60 * 86_400) && !$0.pinned && $0.fileName != oldest.fileName }, "everything else past the weekly band goes")
    check(SmartBackup.tieredPrunable([], config: SmartBackupConfig(), now: base).isEmpty, "nothing to keep, nothing to delete")
    check(SmartBackup.tieredPrunable([record(5000)], config: SmartBackupConfig(), now: base).isEmpty, "a single old backup is the first one, so it stays")

    section("Smart backups: the disk guard")
    let GB: Int64 = 1 << 30
    check(DiskGuard.refusal(free: nil, capacity: 500 * GB, needed: 1) != nil, "unknown free space: refused")
    check(DiskGuard.refusal(free: 50 * GB, capacity: 500 * GB, needed: 47 * GB) != nil, "the 2026-11-14 case: 47 GB into 50 GB free is refused")
    check(DiskGuard.refusal(free: 50 * GB, capacity: 500 * GB, needed: 20 * GB) == nil, "leaving 30 GB free is fine")
    check(DiskGuard.refusal(free: 47 * GB, capacity: 926 * GB, needed: 1 * GB) == nil, "a normal Mac with 47 GB free still backs up: the floor is a flat 20 GB")
    check(DiskGuard.refusal(free: 25 * GB, capacity: 100 * GB, needed: 6 * GB) != nil, "20 GB is always kept, even on a small disk")
    equal(DiskGuard.unpackedEstimate(archive: 47 * GB), 94 * GB, "a drill plans for twice the archive")
    let roomy: (URL) -> (free: Int64?, capacity: Int64?) = { _ in (300 * GB, 1000 * GB) }
    let tight: (URL) -> (free: Int64?, capacity: Int64?) = { $0.path.contains("tight") ? (25 * GB, 1000 * GB) : (300 * GB, 1000 * GB) }
    let d1 = folder("drill-tight"), d2 = folder("drill-roomy")
    var (pick, why) = DiskGuard.drillFolder(candidates: [d1, d2], needed: 47 * GB, space: tight)
    check(pick == d2 && why.count == 1, "a drill skips the full disk and unpacks on the one with room")
    (pick, why) = DiskGuard.drillFolder(candidates: [d1], needed: 47 * GB, space: tight)
    check(pick == nil && why.first?.contains("Not enough room") == true, "with no disk that has room, nothing is unpacked")

    section("Disk safety: every refusal (2026-11-14)")
    let live = folder("live-server"), otherDisk = URL(fileURLWithPath: "/Volumes/MadeUp/LeafJuice")
    let sameDisk: (URL, URL) -> Bool = { a, _ in !a.path.hasPrefix("/Volumes/") }
    var (dk, dx) = DiskGuard.drillCandidates([d1, otherDisk], serverRoot: live, serverRunning: true, sameDisk: sameDisk)
    check(dk == [otherDisk] && dx.count == 1 && dx[0].contains("running server's disk"), "while the server runs, a drill never unpacks onto its disk")
    (dk, dx) = DiskGuard.drillCandidates([d1], serverRoot: live, serverRunning: true, sameDisk: sameDisk)
    check(dk.isEmpty, "with only that disk, there's nowhere: the drill is skipped")
    (dk, dx) = DiskGuard.drillCandidates([d1, otherDisk], serverRoot: live, serverRunning: false, sameDisk: sameDisk)
    check(dk == [d1, otherDisk] && dx.isEmpty, "stopped, any disk with room will do")
    let stopping = try? await Tool.run("/bin/sleep", ["20"], stopIf: { "made-up reason" })
    check(stopping?.stoppedBecause == "made-up reason" && stopping?.ok == false, "a running job is stopped when its watch says so, and doesn't count as done")
    let unstopped = try? await Tool.run("/bin/echo", ["hi"], stopIf: { nil })
    check(unstopped?.ok == true && unstopped?.stoppedBecause == nil, "and isn't when it doesn't")
    DiskGuard.standIn = { _ in (4 * GB, 500 * GB) }
    check(DiskGuard.watch(folder("watched"))()?.contains("Stopped to keep the disk from filling") == true, "under the in-flight floor (5 GB here), the watch says stop")
    DiskGuard.standIn = { _ in (40 * GB, 500 * GB) }
    check(DiskGuard.watch(folder("watched"))() == nil, "above it, it doesn't")
    DiskGuard.standIn = { _ in (nil, nil) }
    check(DiskGuard.watch(folder("watched"))() != nil, "and free space it can't read stops the job too")
    // A real backup refused before it starts, with nothing written.
    let refusedRoot = folder("refused-server")
    write("level-name=world\n", refusedRoot.appendingPathComponent("server.properties"))
    write("made up level", refusedRoot.appendingPathComponent("world/level.dat"))
    if let refused = try? await ServerController.adopt(root: refusedRoot, name: "Made-up Refused") {
        refused.profile.backup.mirror = nil
        DiskGuard.standIn = { _ in (19 * GB, 300 * GB) }
        do { _ = try await refused.backupNow(trigger: "before-update"); check(false, "a restore point that would breach the floor should be refused") }
        catch { check(error.localizedDescription.contains("wasn't started"), "a restore point is refused too, before anything is written: \(error.localizedDescription)") }
        check(Backups.listAll(refused.profile).isEmpty && !FileOps.children(Backups.destination(refused.profile)).contains { $0.lastPathComponent.hasSuffix(".partial") || $0.lastPathComponent.hasSuffix(".tar.gz") },
              "and no archive or partial file is left behind")
        DiskGuard.standIn = { _ in (300 * GB, 1000 * GB) }
        if let made = try? await refused.backupNow(trigger: "manual") {
            DiskGuard.standIn = { _ in (19 * GB, 300 * GB) }
            do { try await Backups.mirror(made, profile: refused.profile, to: folder("refused-mirror")); check(false, "a mirror copy past the floor should be refused") }
            catch { check(error.localizedDescription.contains("Not copied"), "a copy to the second location is refused the same way") }
        } else { check(false, "the roomy backup should have worked") }
    } else { check(false, "couldn't adopt the refused server") }
    DiskGuard.standIn = nil

    section("Smart backups: where they go")
    let root = folder("smart-targets")
    let unplugged = "/Volumes/MadeUp-\(UUID().uuidString.prefix(6))/Backups"
    let fileInWay = root.appendingPathComponent("a-file"); write("x", fileInWay)
    let good = root.appendingPathComponent("good", isDirectory: true)
    try? FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
    let checked = SmartBackup.check([unplugged, fileInWay.path, good.path], needed: 1 * GB, space: roomy)
    check(!checked[0].usable && checked[0].reason.contains("Not connected"), "an unplugged drive isn't used, and its folder isn't made on this Mac")
    check(!FileManager.default.fileExists(atPath: unplugged), "nothing was created where the drive should be")
    check(!checked[1].usable, "a file where a folder should be isn't used")
    check(checked[2].usable, "a writable folder with room is")
    let full = SmartBackup.check([good.path], needed: 1 * GB, space: { _ in (15 * GB, 500 * GB) })
    check(!full[0].usable && full[0].reason.contains("Not enough room"), "a folder on a nearly full disk isn't")
    let fallback = SmartBackup.Target(path: "/own", usable: true, reason: "Ready.")
    equal(SmartBackup.choose(checked, fallback: fallback)?.path, good.path, "the first usable target in order wins")
    equal(SmartBackup.choose(Array(checked.prefix(2)), fallback: fallback)?.path, "/own", "none usable: the server's own folder")
    check(SmartBackup.choose(Array(checked.prefix(2)), fallback: SmartBackup.Target(path: "/own", usable: false, reason: "")) == nil, "and nowhere at all: nil, so nothing is written")

    // A real made-up server backing up to a target, with a stand-in for a roomy disk.
    let server = folder("smart-server")
    write("server-port=25594\nlevel-name=world\n", server.appendingPathComponent("server.properties"))
    write("made up level", server.appendingPathComponent("world/level.dat"))
    write("made up region", server.appendingPathComponent("world/region/r.0.0.mca"))
    guard let c1 = try? await ServerController.adopt(root: server, name: "Made-up Smart") else { check(false, "couldn't adopt a made-up server"); return }
    DiskGuard.standIn = roomy
    defer { DiskGuard.standIn = nil }
    c1.profile.backup.smart.targets = [unplugged, good.path]
    c1.profile.backup.mirror = nil
    do {
        let made = try await c1.backupNow(trigger: "manual")
        let expected = Backups.targetFolder(good.path, for: c1.profile).path
        equal(made.location, expected, "a routine backup skips the unplugged drive and goes to the next target, in its own server folder")
        check(c1.lastBackupWhere?.contains("Passed over") == true, "and says which it passed over")
        check(FileManager.default.fileExists(atPath: expected + "/" + made.fileName), "the archive is there")
        c1.refreshBackups()
        check(c1.backups.contains { $0.fileName == made.fileName && $0.location == expected }, "the list shows it, with where it lives")
        let point = try await c1.backupNow(trigger: "before-update")
        equal(point.location, Backups.destination(c1.profile).path, "a restore point stays in the server's own folder")
        try c1.deleteBackup(made)
        check(!FileManager.default.fileExists(atPath: expected + "/" + made.fileName), "deleting removes it from the target, where it lives")
        // A second server with the same name sharing the target gets its own folder, and never sees the first one's backups.
        let other = folder("smart-server-2")
        write("level-name=world\n", other.appendingPathComponent("server.properties"))
        write("made up level", other.appendingPathComponent("world/level.dat"))
        let c2 = try await ServerController.adopt(root: other, name: "Made-up Smart")
        c2.profile.backup.smart.targets = [good.path]
        let theirs = try await c2.backupNow(trigger: "manual")
        check(theirs.location != expected, "a second server sharing the drive gets a folder of its own (\(theirs.location ?? ""))")
        c1.refreshBackups()
        check(!c1.backups.contains { $0.fileName == theirs.fileName && $0.location == theirs.location }, "and the first server never lists its backups")
    } catch { check(false, "smart backup to a target threw: \(error)") }
    DiskGuard.standIn = { _ in (12 * GB, 900 * GB) }
    do {
        _ = try await c1.backupNow(trigger: "manual")
        check(false, "a backup with no disk to spare should be refused")
    } catch {
        check(error.localizedDescription.contains("No storage has room"), "with every disk nearly full, the backup is refused and says why")
    }
}

/// The owner asked to try stronger compression and incremental copies on a throwaway server before adopting either
/// (2026-11-14). Prints a table; changes nothing about how LeafJuice backs up. The server and copies are deleted after.
@MainActor func runBackupTrial() async {
    section("BACKUP TRIAL (EULA accepted by the person running this)")
    do {
        let root = folder("backup-trial")
        write("server-port=25595\nserver-ip=127.0.0.1\nonline-mode=false\nview-distance=6\nsimulation-distance=4\nmotd=made up\nspawn-protection=0\n", root.appendingPathComponent("server.properties"))
        let c = try await ServerController.adopt(root: root, name: "Backup trial")
        defer { c.forceStop(); c.stopTicker() }
        try EULA.accept(c.paths)
        try await c.installSoftware(try await SoftwareCatalog.latestBuild(.paper, mc: realMC)!)
        c.profile.lastPluginCheck = Date(); c.profile.software.lastCheck = Date()
        await c.start()
        await checkUntil(240, "trial server up: \(c.state)") { c.state == .running }
        // Generate a made-up world of a few regions by force-loading areas, as exploring would.
        func generate(_ x: Int, _ z: Int) async {
            c.send("forceload add \(x) \(z) \(x + 255) \(z + 255)")
            try? await Task.sleep(for: .seconds(25))
            c.send("forceload remove all")
        }
        for (x, z) in [(0, 0), (256, 0), (0, 256), (256, 256), (-256, 0), (0, -256)] { await generate(x, z) }
        c.send("save-all flush")
        try? await Task.sleep(for: .seconds(8))
        c.stop()
        await checkUntil(90, "stopped: \(c.state)") { c.state == .stopped }

        let worldSize = FileOps.directorySize(root.appendingPathComponent("world"))
        // 26.x keeps region files deeper (under dimensions/), so they're counted wherever they are.
        let regions = (FileManager.default.enumerator(at: root.appendingPathComponent("world"), includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "mca" }.count
        print("  world: \(Format.bytes(worldSize)) in \(regions) region files")
        let out = folder("backup-trial-out")
        var rows: [String] = []
        let variants: [(String, [String], String)] = [
            ("gzip (today)", ["-czf"], "tar.gz"),
            ("gzip level 9", ["--options", "gzip:compression-level=9", "-czf"], "tar.gz"),
            ("xz", ["-cJf"], "tar.xz"),
            ("xz level 9", ["--options", "xz:compression-level=9", "-cJf"], "tar.xz"),
            ("zstd (needs Homebrew's zstd)", ["--zstd", "-cf"], "tar.zst"),
            ("lz4 (needs Homebrew's lz4)", ["--lz4", "-cf"], "tar.lz4"),
        ]
        for (name, flags, ext) in variants {
            let file = out.appendingPathComponent("w-\(rows.count).\(ext)")
            let started = Date()
            let r = try await Tool.run("/usr/bin/tar", flags + [file.path, "-C", root.path, "world"])
            let seconds = Date().timeIntervalSince(started)
            let size = FileOps.size(file)
            rows.append(r.ok ? String(format: "  %-30@ %10@  %5.1f%% of the world  %6.1f s", name as NSString, Format.bytes(size) as NSString, Double(size) / Double(worldSize) * 100, seconds)
                             : "  \(name): failed: \(r.err.prefix(120))")
            try? FileManager.default.removeItem(at: file)
        }
        rows.forEach { print($0) }

        // Incremental: a full copy, then a session that explores one new area, then a copy that links unchanged files.
        let snap1 = out.appendingPathComponent("snap1", isDirectory: true), snap2 = out.appendingPathComponent("snap2", isDirectory: true)
        let first = try await Tool.run("/usr/bin/rsync", ["-a", root.appendingPathComponent("world").path + "/", snap1.path + "/"])
        check(first.ok, "rsync made the first copy: \(first.err.prefix(120))")
        await c.start()
        await checkUntil(240, "trial server up again: \(c.state)") { c.state == .running }
        await generate(512, 512)
        try? await Task.sleep(for: .seconds(60))
        c.send("save-all flush")
        try? await Task.sleep(for: .seconds(8))
        c.stop()
        await checkUntil(90, "stopped again: \(c.state)") { c.state == .stopped }
        let started = Date()
        let second = try await Tool.run("/usr/bin/rsync", ["-a", "--link-dest=\(snap1.path)", root.appendingPathComponent("world").path + "/", snap2.path + "/"])
        let seconds = Date().timeIntervalSince(started)
        check(second.ok, "rsync made the linked copy: \(second.err.prefix(120))")
        // Files with one link are new in the second copy; files with two are shared with the first.
        var newBytes: Int64 = 0, shared = 0, changed = 0
        if let walker = FileManager.default.enumerator(at: snap2, includingPropertiesForKeys: [.linkCountKey, .fileSizeKey, .isRegularFileKey]) {
            for case let f as URL in walker {
                let v = try? f.resourceValues(forKeys: [.linkCountKey, .fileSizeKey, .isRegularFileKey])
                guard v?.isRegularFile == true else { continue }
                if (v?.linkCount ?? 1) > 1 { shared += 1 } else { changed += 1; newBytes += Int64(v?.fileSize ?? 0) }
            }
        }
        let after = FileOps.directorySize(root.appendingPathComponent("world"))
        print(String(format: "  incremental copy after a session: %@ new of %@ (%.1f%%), %d files changed, %d shared, %.1f s",
                     Format.bytes(newBytes) as NSString, Format.bytes(after) as NSString, Double(newBytes) / Double(max(after, 1)) * 100, changed, shared, seconds))
        // A restore from a linked copy is a plain copy back; prove it's whole by comparing the two trees.
        let compare = try await Tool.run("/usr/bin/diff", ["-rq", root.appendingPathComponent("world").path, snap2.path])
        check(compare.ok, "the linked copy matches the world exactly: \(compare.out.prefix(200))")
        try? FileManager.default.removeItem(at: out)
    } catch { failures.append("backup trial: \(error)") }
}
