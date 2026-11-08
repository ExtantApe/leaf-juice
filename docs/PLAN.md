# Leaf Juice: plan

A free, unsigned, native Mac wrapper for Minecraft Java servers. It should be the obvious step
up from `java -jar paper.jar`, and cost about as little to run.

## What's out there, and where this fits

| Tool | Shape | Takeaway |
|---|---|---|
| [Pterodactyl](https://pterodactyl.io) | Web panel + Docker daemon | Great for hosts; far too heavy for one Mac |
| [Crafty Controller](https://craftycontrol.com) | Python web panel, plain Java processes | Scheduled backups and in-browser config; still a web server you babysit |
| [MCSManager](https://mcsmanager.com) | Web panel + daemons | Multi-machine; no plugin catalog |
| AMP | Paid, proprietary, Windows/Linux | Polished, but not free and not on Mac |
| A `start.sh` | One line of shell | Lean; no backups, no updates, no safety |

The panels solve *remote multi-tenant hosting*. None is a native Mac app, and none makes
plugin compatibility its central concern. Leaf Juice takes those two gaps as its job. It stays
a single local app with no web server, no daemon and no container.

## Decisions

| Decision | Why |
|---|---|
| **SwiftUI + SwiftPM, zero dependencies** | Truly native and accessible; idle cost near zero; builds with just the Command Line Tools. OnePedigree's Tauri stack would add Rust and a web view for no gain here. |
| **macOS 14+** | `@Observable`, `.inspector`, `Table` are all solid there. |
| **The server folder stays yours** | Everything we add lives in `<server>/.leafjuice/`. Deleting it (or Leaf Juice) leaves a normal server. Importing changes nothing else. |
| **The Change Queue is the core idea** | Nothing that needs a restart touches disk while the server runs. See below. |
| **No AI at runtime** | Rules are a data table with a tested sample per rule. Anything unmatched is still catalogued and grouped. "Copy report" lets a person paste it wherever they like. |
| **Unsigned, GitHub Releases only** | Ad-hoc signed; the README explains first launch. In-app "update available" notice links to the release; no self-updater. |

### Owner decisions

Settled by the owner. Follow them without asking again.

| Date | Decision |
|---|---|
| 2026-11-07 | The repo lives at `ExtantApe/leaf-juice`, MIT, "Copyright (c) 2026 EXTANT APE". The bundle identifier stays `io.github.mgilardi.leafjuice`. |
| 2026-11-07 | v0.1.0 is the plugin links work only. Everything else was merged into `main` after it. |
| 2026-11-07 | Three commit messages pushed by mistake (`cb44c87`, `afd4ce8`, `b345332`) stay. No history rewrite, no force-push. A pre-push hook checks messages from now on. |
| 2026-11-07 | Plugins target Paper 26.1 and later only, so the real tests boot 26.x. 1.21.11 is only for tests that upgrade from it. |
| 2026-11-07 | One test server per session at a time, stopped when the run ends, with no copies left between runs. |
| Before 2026-11-07 | A player sees a world's map only if they can enter that world. If that can't be read reliably, they see no maps. |
| Before 2026-11-07 | The map stays open directly until the gateway ships on a real server. That server's BlueMap change is made separately. |
| Before 2026-11-07 | An exact pack can be served unchanged under its own SHA-1. The screen states both risks: it's offline while Leaf Juice is closed, and New Address breaks the address. |
| Before 2026-11-07 | Real servers wait for the owner's go. The allowlist screen stays off real servers for children's and adults' groups until Stationmaster exists and Leaf Juice calls it. Children's safety and privacy come first. |
| 2026-11-08 | Per-song toggles: a pack can list its songs in `songs.json`, and each recipe can leave any song out so Minecraft's own track plays. Each choice is a new build with its own SHA-1 and per-build address. A private pack that uses this stays unserved until the owner's in-game test. |
| 2026-11-08 | Plugins on upgrade: build it, after the per-song toggles. It shows the plan and asks for a yes, works only on a stopped server with a backup, and every step can be undone. Which plugins don't fit comes from Preflight's report on a throwaway copy booted on the target version, not from version metadata. Tested on throwaway copies only. |
| 2026-11-08 | The upgrade helper's logic moves into Preflight, as a command-line tool in its jar (plan, apply, restore, with JSON output), so people without Leaf Juice can use it. Leaf Juice keeps the screens and the test-copy boot, and calls the tool once Preflight 0.3.0 is out. Its own planning code is then removed, and the real 26.3 run happens against the tool. Done with Preflight 0.3.0 the same day. |
| 2026-11-08 | Server icons can be rotated: choices live in `<server>/server-icons/`, picking one copies it over `server-icon.png`, and nothing in the folder is ever moved or deleted. The one in use is found by its contents. Added images must be square, and are scaled to 64×64 with nearest-neighbour. A change shows after the next restart. |

## The Change Queue

Every change falls into one of two cases, decided by whether the server is running:

- **Stopped:** applied immediately (with a config history copy).
- **Running:** staged in `.leafjuice/staged/` and listed as a pending change. They are applied in the
  gap between stop and start, by a restart the user picks: *now*, *when the last player leaves*, or
  *at a set time*, with in-game countdown warnings. A daily restart can be scheduled too.

Config files have a per-file policy:

- **Staged while running:** `server.properties`, `bukkit.yml`, `spigot.yml`, `paper-*.yml`, plugin configs.
- **Locked while running:** `ops.json`, `whitelist.json`, `banned-*.json`, which the server rewrites
  itself and would clobber. The editor points at the console command instead.

If a file changes on disk after staging, `.properties` files merge key by key. Others are held back and
flagged as a conflict rather than overwriting anything.

## Settings screens

Forms are generated from the file, not from a schema that could go stale. Whatever keys the file has become rows; the control
comes from the value (true/false, number, text). A small table adds friendly titles, help, limits and sections for well-known
settings, but anything else still works with a plain label. Comments in the file become help text, which is where plugin
authors already document things.

Edits replace one value on one line, so comments and layout survive. Anything the simple reader isn't sure of (lists, inline
maps, multi-line text) is shown read-only and edited in the Full File view. Rows show "Not saved yet" and "Applies at next
restart". JSON, TOML and HOCON files use the Full File view. Each installed plugin gets its own group, discovered from its
folder, skipping data folders such as `userdata` and `lang`; folders with no installed plugin are listed separately.

## Software

`Paper` (default), `Folia`, `Purpur`, `Vanilla`, or a custom jar (Spigot and Bukkit, which can't be
downloaded directly).

- Paper and Folia use the Fill v3 API, which also supplies the **minimum Java version** and **recommended
  JVM flags** for each version. Channels: `STABLE` by default; `BETA` and `ALPHA` opt-in.
- Every download's hash is verified.
- **Same-version builds** are routine and can install automatically at the next restart.
- **Minecraft version changes** always take a backup first. **Downgrades are blocked**: a world can't be
  opened by an older version, so the route back is restoring a backup.
- Replaced jars are archived for rollback.
- **Upgrade readiness:** before changing version, check every plugin against the *target* version.

Year-based versions (`26.3`) and old ones (`1.21.11`) compare correctly.

**Java:** detects installed runtimes (`java_home`, Homebrew, SDKMAN), picks one that meets the
requirement, and can download Temurin into Leaf Juice's own folder with a checksum check.

## Plugins

Reads each jar's `plugin.yml` / `paper-plugin.yml`, and tracks by plugin *name* since filenames change.
Each plugin has an editable **source**. Paste a URL and it's recognised:

| Source | Version-awareness | Evidence |
|---|---|---|
| Modrinth | Per version, exact | `game_versions` + `loaders` |
| Hangar | Per version, exact | `platformDependencies` for the platform |
| SpigotMC (via Spiget) | Per *resource*, author-maintained | `testedVersions`, so "likely" at best. Premium/external: notify only |
| GitHub Releases | Only when tags say so | `mc1.21.4`-style tags in tag, title or asset name |
| Jenkins | None up front | `lastSuccessfulBuild`, filtered by artifact pattern |
| Other site | None up front | Direct URL (ETag/Last-Modified) or page + link regex |

**Every downloaded jar gets the same final check**, whatever the source:
hash matches, `plugin.yml` declares the expected plugin name (catches the wrong artifact from a
multi-module Jenkins job), and `api-version` isn't newer than the server. This is what makes "no
metadata" sources safe to watch.

Per plugin policy: **notify** (default), **auto-install** (only with `compatible` or `likely`
evidence), or **pinned**.

Sources are auto-detected: an exact Modrinth hash match is applied. Other matches (the plugin's
website field, Hangar and Spigot name search) are only suggested.

## Upgrade safety

A world that has run on a newer Minecraft can't open on an older one, so swapping the jar back is no undo. Any Minecraft
version change or software switch therefore goes through these steps:

1. **Restore point:** a whole-folder archive, read back to prove every world's `level.dat` is inside, then pinned. It
   ignores the "back up before updates" setting. If it fails, the upgrade is held back and the server stays as it was.
2. **Decision:** the app asks you to keep or roll back until you answer, and remembers across relaunches.
3. **Roll back:** rechecks the restore point first, so a missing or damaged one refuses without changing anything. Then
   it restores server, plugins, settings and jar.
4. **Shelf:** rolling back moves the upgraded state here. It isn't a backup: it's stored apart, retention never touches
   it, and it stays until you resume or delete it. Resuming makes a fresh restore point, so you can go back and forth.

Routine builds of the same Minecraft version skip all this, since they don't change the world format. A start check also
refuses a jar whose name says it's for another version, so a restored world can't be upgraded again by accident.

## Worlds and Multiverse

The Worlds page lists worlds from disk merged with Multiverse's `worlds.yml`, and offers to install Multiverse-Core
through the normal vetted plugin path. Actions are sent as Multiverse's own console commands while the server runs.

Syntax comes from Multiverse's source:

| | 4.x | 5.x |
|---|---|---|
| `worlds.yml` | nested under `worlds:` | worlds at top level |
| Create flags | `-s`, `-t`, `-a` | `--seed`, `--world-type`, `--no-structures` |
| Modify | `mv modify set <prop> <value> <world>` | `mv modify <world> set <prop> <value>` |
| Success messages | older wording | newer wording |

`--remove-players` is only used from 5.2, the earliest tag confirmed to have it. `/mv confirm` needs the one-time code in
its prompt, so the app reads it from there. World and seed names are validated, because a newline in a console
command could run something else.

**Both world layouts are supported.** Before 26.1: `world`, `world_nether`, `world_the_end` and other worlds as top-level
folders. From 26.1: inside `<level>/dimensions/<namespace>/<key>`. The server's own worlds can't be unloaded or deleted.
Deleting any other world takes a backup first and requires typing its name.

## Backups

- Compressed `.tar.gz` with a sidecar JSON (version, build, trigger, scope, pinned).
- While running: `save-off` → `save-all flush` → wait for confirmation → archive → `save-on`, always.
- Interval schedule, retention (keep last N, and anything newer than D days), pinning, free-space check.
- Default scope is the whole server folder, jars, libraries and caches included, so a restore can start straight away, even offline. Only `.leafjuice` stays out. Restoring removes anything added since, and returns the jar and launch settings.
- Default location is beside the servers: `<servers folder>/LeafJuice/backups/<server name>/`. The path is stored when
  first used, so changing the servers folder can't lose track of backups. Renaming a server moves its folder, and servers with the same
  name get separate ones. Any other folder or external drive can be chosen instead.
- Restore: stopped only, takes a safety backup first, extracts to a temp folder, then swaps.

## Issues (the side panel)

A rule engine over console output and `logs/latest.log`:

- Built-in rules for Java, memory, ports, EULA, lag, world corruption, plugin load failures, and so on.
  Each has an explanation, steps to try and optionally a button to the relevant page.
- Users can add rules as JSON in the app's `rules/` folder.
- **Unmatched warnings and errors are still catalogued**, normalised (numbers, UUIDs and paths removed)
  so repeats group with a count, with stack traces attached.
- Plugins are identified from the `[Name]` log tag or from stack frames against each plugin's `main` package.
- Crashes add an entry with exit code and the newest crash report.
- Open / ignored / resolved state, saved per server. Copy as Markdown, or search the web by click.

## Scaling

- Several servers side by side, with port conflict checks.
- Presets (friends, community, large) that set heap, view and simulation distance, shown as staged changes.
- Warns if the heap crowds out the Mac's memory.
- Keeps the Mac awake while running. Menu bar status stays when the window is closed.
- Live CPU and memory from `proc_pidinfo`; console is a capped ring buffer.

## Design

See [brand/README.md](../brand/README.md). Takes the *construction* from OnePedigree and OneTaxonomy
(tile geometry, 8/10 radii, icon with label, shape as well as color, 3:1 strokes), with its own pastel palette:
cream and sage surfaces, juice green for structure, pink grapefruit as the single pop of color.

## Deep changes

These change many files at once, so they share one engine: **scan, preview every change, make a verified restore point, apply with the
server stopped, offer undo**. If a step fails, everything is put back. Only files on a finite list are edited; anything else that mentions
a name is listed, never changed. The plan is worked out again after the server stops, because plugins save files on the way down.

**World rename:** folders (or `dimensions/` keys from 26.1), `level-name`, `level.dat`, `bukkit.yml`, `spigot.yml`, `purpur.yml`; Multiverse `worlds.yml`
keys, `read-only.legacy-world-name` (which Multiverse uses to find the folder), config and anchors; Portals, NetherPortals, Inventories groups and
folders; WorldGuard folders; Essentials spawn, warps, jails and homes; Citizens; Dynmap. The list lives in `WorldRename.knownFiles`. Plugin databases
such as CoreProtect's can't be changed, so a note says so.

**Server rename:** offers `sonoran-realms`, `sonoranrealms`, `SonoranRealms`, `sonoran_realms`. Covers the folder, backup folder, motd, start scripts and absolute paths.
LuckPerms' `server:` value decides which permissions apply, so it's opt-in with that explanation.

**Test copies:** an APFS clone of the server on its own port, with outward-facing plugins (Discord, votes, web maps, proxies) off and outside databases flagged. The change
is applied and booted there, then reported. On success the copy is removed and the app offers to back up and proceed. Plugins can't be switched on reliably in
a running server, so **Find Which Plugin** boots the copy with half of them at a time, along with their dependencies.

**Player snapshots:** every 15 minutes of play and as players leave, copying the saved data (the server saves about every 5 minutes), including each
Multiverse-Inventories world and group. Can also pull one player out of any backup. Restoring leaves the world alone, and waits for a restart whenever the server could overwrite it.

**Player merge:** player data paths differ by version (`world/playerdata` before 26.1, `world/players/data` after). Online-mode name changes keep the UUID, so a second
profile usually comes from offline mode or a mode switch. Multiverse-Inventories keys files by *name*, so a rename can orphan them even in online mode. Inventory and position
come from the chosen side, advancements combine, stats add up, and each conflicting world or group is chosen separately.

**Cleanup:** known leftovers are preselected; orphan plugin folders and unmanaged worlds need a decision. Anything a current config mentions is left out. Items move
to `CleanedUp` beside the backups and can be brought back.

**Backup diff:** settings key by key, plugins, server jar, chunks changed per world (from region file timestamps) and each player's item changes.

**Testing limit:** tests have no Minecraft client, so no real player data exists in them. Player features are tested against generated files only.

## History and analytics

Only what leads to a decision, kept in `.leafjuice` as small append-only files, and **never sent anywhere**. Five-minute rows of TPS, MSPT, memory, CPU, players and the
longest Java pause; one row a day of world, backup and free disk sizes; a timeline of starts, crashes, updates, config changes, backups, restores, renames and lag.

**Backup drill:** unpacks a backup to a throwaway folder and boots it. Weekly when nobody's on, skipped if a plugin uses an outside database.

**Players:** failed joins explained in plain words, regulars from the logs, and leaderboards and per-player stats from Minecraft's own stats files.

## The Lab

`~/Minecraft/lab`, marked `isLab` in its profile. Wiping needs both that mark, read from disk, and that exact folder, so a server merely named `lab` is moved aside rather than deleted. The seed is a script, not bundled files: any version, nothing of Mojang's shipped. Offline mode lets bots in, so it binds to `127.0.0.1`. Saves live in `LeafJuice/rehearsals/`.

The screen is a status board: one switch and light per station, in order, each green unlocking the next. Runs are fingerprinted by version and plugin hashes, so a light goes out of date when they change. Stations: plugins (exact jars in themed groups, fresh settings), settings (optional), upgrade, fresh, new version with settings (optional). The upgrade and fresh lights are independent of each other's result, because the pair is the diagnosis.

Rehearsal runs an upgrade path (the Lab's existing data if it's older than the target, otherwise a new seed on the current version) and then a wiped fresh install, with the same checks on each. Both always run, because the pair of results says more than either alone. It ends on the new version, so the next rehearsal has last time's data to migrate. EULA acceptance is asked for in the app, once, for the Lab and its rebuilds.

Bots make it practical: `Bot.swift` speaks just enough of the protocol to log in and stay connected, with packet numbers from Mojang's own data generator for each version.

What's been learned from real runs is in [FINDINGS.md](FINDINGS.md).

## Modules

Built-in features with an on/off switch, not a plugin system. An unsigned app loading third-party code would be a real risk, and Swift has no stable way to do it. `modules.json` stores only what's off, so anything added later starts on. A module going off hides its pages and buttons and stops its background work, and keeps its data. Lifecycle, console, plugins, software, configs, backups, issues and the Change Queue are the base and can't be turned off.

Plugin links is one: `PluginLinks.swift` lists each plugin with a link to its documentation, in the app only. It replaced a generated wiki before the first release, because tables of commands and ranks were more to maintain and more to leak than a link.

Ideas for later modules: scheduled announcements, a player whitelist manager, a Discord webhook for crashes and restarts (off by default, since it reaches outside), offsite backup targets, chunk pre-generation, a world map preview.

## Resource packs

`LeafJuice/resource-packs/`: `library/<pack>/<version>.zip` with a `pack.json`, `recipes/`, `my-changes/` and `combined/<recipe>/<sha1>.zip` with its lock file. Packs have stable ids, and recipes pin a version by hash, so an update is always a choice and never loses your ranking.

Most specific wins: My changes, then a pick for one file, then a pack for a category, then rank. Builds fix file times, order and permissions so identical inputs give an identical SHA-1. A git submodule was considered and left out: many packs aren't in git, binaries don't diff, and every user would need git. Lock files give the history that was wanted, and a GitHub source covers packs that are in git.

Zip work uses the system's `unzip` and `zip`, so there are still no dependencies. 
Serving is a separate read-only listener on loopback, with settings per server in `.leafjuice/pack-hosting.json`, not in the recipe, so an exported recipe never carries an address. It answers `GET` and `HEAD` for `/<token>/pack.zip` and `/<token>/pack.zip.sha1`, and 404 for everything else. It streams in 256 KiB pieces, allows 32 connections, drops a connection that sends nothing for 10 seconds or stalls for 60, and doesn't log addresses. It works out the build per request: `resource-pack-sha1` if `server.properties` points at this address and Butler isn't installed, otherwise the build chosen with Serve This Build. A tunnel and Caddy aren't part of Leaf Juice and haven't been tested.

### Handoff to per-world pack plugins

Resource Pack Butler isn't built yet, and its config format is undecided. WorldResourcepacks is treated the same way. What Leaf Juice offers either one:

- **An address per build,** `/<token>/<sha1>.zip`, which only ever gives that build. A config holding that address and its SHA-1 can't fall out of step, because publishing a new build doesn't change what the old address gives. Old builds stay reachable while their file is kept. This is what the Hosting card shows when one of these plugins is installed.
- **A stable address,** `/<token>/pack.zip`, plus `pack.zip.sha1`, a plain text file with the current hash. This one switches when you press Serve This Build, so a plugin using it has to re-read the hash.
- With a plugin named `ResourcePackButler` or `WorldResourcepacks` present, enabled or not, Leaf Juice refuses to write the pack settings, and warns if `server.properties` still sets a pack.

For the Butler session: per-build addresses are the suggested format. A new build then means changing the address and the hash in Butler's config together.

## Later

- Login item (`SMAppService` is unreliable when unsigned).
- Remote/offsite backup targets.
- Velocity proxy networks.
- Log history scan across rotated `.log.gz` files.
- Proper YAML validation (only basic checks today, to stay dependency-free).
