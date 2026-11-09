# Test audit

Each audit lists what Leaf Juice promises, which checks prove each promise, and the gaps. Run the checks with `swift run leafjuice-check` (offline, made-up data, about 80 seconds). The `--real-*`, `--lab` and `--sandbox` runs boot real Paper and are listed apart.

## 2026-11-09: Packmule rename

Resource Pack Butler became Packmule 0.2.0. Serving packs now checks that Packmule is noticed under both names, `Packmule` and `ResourcePackButler` (0.1.x), and that the pack settings are refused under each. Nothing else needed: Leaf Juice reads only the plugin's name, never its folder, so the window where both `plugins/ResourcePackButler/` and `plugins/Packmule/` exist doesn't matter here. 1829 passed, 0 failed.

## 2026-11-08: first audit

At `a2b3cf6` plus this change. Default run before: 1807 passed. After the checks added below: 1826 passed, 0 failed.

### Covered

The README's promises, mapped to the sections that prove them (section names as printed by the run):

| Promise | Checks |
| --- | --- |
| Runs your server: start, stop, restart, console | Server lifecycle (stand-in jar), Launch; real: `--real-paper` |
| Uses an existing server, keeps servers together | Importing an existing server, Servers folder, Pre-26 servers |
| Keeps server software current, with hashes | Versions, Software moves, Jar picking, Update decisions; live: `--live` (real APIs) |
| Knows which plugins fit | Plugin descriptors, Source parsing, Tag-aware compatibility, Plugin scanning |
| Settings screens from your files | Properties, Config validation, Config forms |
| Never changes a running server underneath its players | The change queue (edits wait for a restart) |
| Protects you on upgrades, rollback in one step | Upgrade safety (a mismatched jar blocks start), Server lifecycle; real: `--real-paper` upgrade 1.21.11 → 26.3 and back |
| Switches off plugins that won't start, through Preflight's tool | Plugins on upgrade; real: `--real-upgrade-plugins` |
| Worlds with Multiverse | Multiverse |
| **Backs up safely while running** | Backups, Backup location, Comparing backups, Schedule |
| Tries changes on a test copy first | Server lifecycle, Serving packs ("a test copy never serves"); real: test copy to 26.3 |
| Rotates server icons | Server icons |
| **Renames deeply, with a restore point and undo** | Renames: the text, Renames: whole servers; real: `--real-paper` (its "REAL RENAMES" part) |
| **Looks after players: snapshots, restores** | Player data format, Players; sandbox: player features on real data, on 1.21.11 and 26.3 |
| **Cleans up old servers, and can bring them back** | Cleanup |
| Watches health, explains problems | Issue rules, Issue catalog, Analytics, Storage |
| **The Lab: wiping only the real Lab** | Analytics (the wipe guard, added today); real: `--lab` (a plain folder called lab is moved aside whole, never deleted; no Lab without the EULA) |
| **Resource packs, builds byte for byte** | Resource packs, What each pack contributes, Exact packs, Songs in a pack |
| **Serving packs** | Serving packs: off by default, needs an address, long random paths, 404 for everything else, no climbing out, read only, no cookies, big files streamed, a full house turns newcomers away, a test copy never serves, a taken port is reported, addresses never leave in an exported recipe; real: `--real-pack` (a bot gets the pack) |
| **Allowlist** | Analytics (access changes: unsafe group names, groups without LuckPerms and empty changes are refused), the links page; real: `--real-signin`, `--real-prejoin` |
| **Map behind sign-in** | Map behind sign-in; real: `--real-map` |
| **Plugin links page** | The links page checks (printed without their own header, ending "checked unreachable from N other local addresses"): loopback only, sign-in, what each person can see, a privileged port refused |
| EULA is yours to accept | The change queue ("false isn't accepted"); every real run asks for `--i-accept-the-minecraft-eula` |

### Gaps added, with the checks

- **A download that fails its hash.** Nothing proved it is thrown away. Every server jar, plugin, pack and the upgrade tool depends on this. Added to Plugins on upgrade: a wrong hash is refused and nothing is saved, and the right one is saved unchanged. It uses a stand-in web server on 127.0.0.1.
- **The whole upgrade check, end to end.** The tool was tested, but not the path that fetches Paper, copies the server and cleans up. Added, with the tool stood in for, checking that:
  - the tool gets a copy, never the server;
  - Paper must pass its hash first;
  - a bad Paper stops the check before the tool runs;
  - the shared-database allowance is sent only after Check Anyway;
  - nothing is left in `test-copies`.
- **Pack serving reaches only this Mac.** The listener binds to 127.0.0.1, but nothing checked it. Added: while serving, every other address on the Mac is tried and refused (two tried on this run).
- **A pack address survives a folder rename.** The fix in `913e383` had no check. Added: the same address before and after a rename that moves the folder.
- **The Lab's wipe guard.** It was only checked in the real `--lab` run, which needs Paper downloads. Added to the default run: a wipe needs both the mark and the exact folder, and a folder inside the Lab or one elsewhere never qualifies.

### Gaps skipped, and why

- **Pack serving starting when the app opens** (`AppModel`, `913e383`). The app layer isn't in the check harness. `startPackHostIfWanted()` itself is checked ("comes back"). The launch itself is in owner test T6 and the pack-hosting check (plan 1.6).
- **SwiftUI screens:** wording, layout, keyboard and VoiceOver. These are by-hand checks, in owner test T6. No UI test harness, and adding one would cost more than it catches for now.
- **Upstreams that publish no hash.** A download with no expected hash is accepted. That's deliberate: some sources publish none, and the file is still hashed and recorded. It's not a gap in a fail-closed check.
- **Real game clients.** Bots cover joining, packs and sign-in. A real client is on the "Needs a real client" list (the pack prompt, how the icon looks in the server list).
- **Overkill, left out:** Codable round-trips of plain settings structs, and SwiftUI view bodies. Stronger checks already save, reload and use these settings.

### Next audit

After the next feature or fix, or by 2026-11-22.
