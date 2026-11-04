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
- Default location is outside the server folder; can point to an external drive.
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

## Later

- Login item (`SMAppService` is unreliable when unsigned).
- Remote/offsite backup targets.
- Velocity proxy networks.
- Log history scan across rotated `.log.gz` files.
- Proper YAML validation (only basic checks today, to stay dependency-free).
