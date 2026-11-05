# What real servers actually do

Everything here was observed by running real server software, not read from documentation. To repeat any of it:

```
.build/debug/leafjuice-check --experiments versions,failures,multiverse,players,renames,restore --i-accept-the-minecraft-eula
```

The flag is your own acceptance of the Minecraft EULA. Raw results go to `.lab-sandbox/findings/`, which isn't committed.

Tested in November 2026: Paper 1.21.11 and 26.3, Purpur, Folia, vanilla, Multiverse-Core 5.8.2 and 4.3.16, Multiverse-Inventories 5.3.6, LuckPerms 5.5.71. Behavior on other versions is an assumption until it's been run.

## Differences between versions and software

| What | Observed | What Leaf Juice does |
|---|---|---|
| Allowlist | A new 26.3 server has it on, and an empty list locks everyone out | Overview says so |
| Console on 26.x | Prefixes lines with `System chat: ` and echoes commands as `> cmd` | Strips both before reading a line |
| First start on 26.x | `[WorldFolderMigration]` waits 30 seconds, then moves worlds | Explained in Issues |
| Purpur `tps` | Four figures, including 5 seconds | The parser accepts three or four |
| Folia | No `save-all` or `tick`. `mspt` reads 0.0 and `tps` is per region. No `level.dat` while running | Backs up only while stopped, and doesn't chart TPS |
| Vanilla | `tick query` answers in four lines, and has no UUID line on join | Extra lines are hidden from the console |
| Paper banners | One warning arrives as many lines | Each banner groups into one issue |
| Bots on 1.20.x | The data generator has no `packets.json`, so bots can't be built for it | The Lab marks those checks as skipped, not passed |

## Things that go wrong

- **A clean exit can be a failure.** A tab in `bukkit.yml`, broken `spigot.yml` or `paper-global.yml`, too old a Java, or a garbage `level.dat` all quit with **code 0** before `Done`. Leaf Juice treats exiting while starting as a failed start, and doesn't auto-restart it.
- **A deleted `level.dat` isn't fatal to the server.** With no `level.dat_old` either, it starts anyway and writes new world data. Leaf Juice blocks the start and points to Backups.
- **`stop` is ignored while starting.** It sat unread until the two-minute escalation, so Leaf Juice terminates the process instead.
- **A broken jar can stop others loading.** `[PluginRemapper] Encountered exception remapping plugins`. Fabric mods and files with no `plugin.yml` both come through `[DirectoryProviderSource]`.
- **Plugin load errors name the remapped path:** `plugins/.paper-remapped/X.jar`. Rules read the plugin's name from it.
- **Silent until loaded.** A damaged region file and a garbage player file produce no error at start.
- **Worked fine:** forced kills reboot cleanly, an orphaned server is detected, port clashes are caught, and Java 26 runs 1.21.11.

## Multiverse

- `/mvinv group` is conversational from a console. It prompts "What would you like to do?", so `mvinv group create ...` does nothing, and `mvinv group list` starts that prompt (send `##` to cancel). Groups are best set by editing `groups.yml` while stopped.
- `mvnp link nether mining deep` works from a console. `mvnp show` doesn't exist.
- Switching game mode keeps one `SURVIVAL` section by default.
- 4.3.16 on 1.16.5 with Java 11 accepts create, load, unload, modify and delete using plain names. 5.x uses keys like `minecraft:overworld`, even before 26.
- 5.x finds folders through `read-only.legacy-world-name`.

## Player data

- **Staleness:** an item given 2 seconds ago isn't in the file yet. `save-all` writes it within about 3 seconds, without needing `flush`. Live snapshots ask for a save first.
- **Armor** is under `equipment` on 1.21.11, and ender chests under `EnderItems`.
- **Old to new is fine.** A 1.21.11 snapshot (DataVersion 4671) restored and loaded on 26.3 (5023). The reverse can't work, so Leaf Juice refuses it.
- **Inventory-only restores are placed where the player is now.** A snapshot taken in `mining`, restored to someone now in `world`, puts `mining`'s items in `world`. Leaf Juice warns about this before restoring.
- **Capitalization collides on a Mac.** In offline mode `Alice` and `alice` are different players with different UUIDs, but Multiverse-Inventories files are named by player, and APFS treats `Alice.json` and `alice.json` as one file. `alice`'s items overwrote `Alice`'s. Online-mode servers can't have two names differing only by case, so this only matters for offline servers. Leaf Juice doesn't guard against it yet.

## Renames

- A folder rename with `level.dat`, `worlds.yml`, `groups.yml` and per-world inventories updated boots cleanly and keeps inventories, for extra worlds, grouped worlds, linked Nether worlds, the main world, and worlds set not to load (they stay unloaded).
- **`players/<uuid>.json` keeps a `lastWorld`,** which a rename left stale. It's now part of the plan.
- **`mvnp link` writes `plugins/Multiverse-NetherPortals/links.yml`** (`mining:` then `  nether: deep`), which a rename also left stale. It's now part of the plan too.
- A player who logged out in a renamed world rejoins in it under the new name.

## Backups

- A whole-folder backup boots with no internet, through a dead proxy. Paper logs `[PaperVersionFetcher]` errors, and nothing else is affected.
- With internet, `libraries`, `versions` and `cache` come back by themselves. Worlds were about 20 MB of a 270 MB backup, so those folders are most of its size. They're kept anyway, because that's what makes a restore work offline.
- A backup taken with a player online and blocks changing read back and booted in a drill.

## The Lab's checks

Checks that can't fail prove nothing, so rehearsals were also run against things broken on purpose:

- Alice's player data deleted before the upgrade path: the upgrade failed on "Inventory came through", fresh passed, and the verdict said so.
- A junk file named `Broken.jar` in the plugins folder: both paths failed, naming the plugin error.
- On good software, Paper 1.21.11 to 26.3 with Multiverse and LuckPerms passed every check on both paths. The upgrade path took about 40 seconds to start because of the world migration wait, and the fresh one 6.

## A real server's plugins

A real 35-plugin server found what a 3-plugin test server couldn't:

- **Leaf Juice hung for good.** Dozens of `unzip` calls each held a shared system thread while waiting on another one, so all 64 were stuck. Tools now run on their own threads, and scans go a few plugins at a time.
- **Copying "settings" isn't simple.** Plugin folders mix behavior, world lists and player data. Multiverse-Inventories keeps inventories in `worlds/` and `groups/`, and Multiverse-Core's `worlds.yml` names folders the Lab doesn't have. Those stay behind.
- **Settings change data.** With `apply-playerdata-on-join: true` and `default-ungrouped-worlds: true`, a join loads a different profile, so a seed made under fresh settings looks empty. Under real settings, the checks hand out items first, restart, and look for them. Each group starts from a clean copy.
- **Flat worlds spawn slimes,** and one killed a bot, which looked like lost items. The Lab is peaceful.
- **Paper's stack frames name the jar:** `at ActionHealth-3.5.9-all.jar//com.example...`. That's how an error reaches the right plugin.
- **Multiverse 5 keeps `environment` inside `read-only:`.**
- **Saved issues need a second look.** Ones stored before a rule existed stayed uncategorized, so they're read again on opening.

## Resource packs

Tested with real Modrinth packs, including the official TARDIS packs, and a real Paper 1.21.11 server, with bots as the client. **No real game client has loaded a combined pack yet.**

- **Read-only folders:** real packs can store them in the zip. A cached copy then couldn't be cleared, and unpacking it again silently lost files, so the same recipe built something different. Unpacked copies are now made writable, and file counts are checked against the zip.
- **Format fields:** the TARDIS pack gives `min_format` and no `pack_format`, while older packs do the reverse.
- **Version tags:** the TARDIS packs aren't tagged for 1.21.11 on Modrinth. Leaf Juice takes the newest release and says so.
- **Loose files:** packs commonly ship `LICENSE` and `README.md` at the top. They aren't ranked, and each is kept in `credits/<pack>/`.
- **Real overlap:** in these packs, `assets/minecraft/sounds.json` merged between the TARDIS packs. Otherwise they barely overlapped, so most ranking has only been proven on made-up packs.
- **Repeatable:** building twice gives the same SHA-1, and so does rebuilding from an exported recipe in an empty library.
- **Not always clean:** one pack shipped an empty `assets/sodium/lang/test.json`.
- **A required pack:** accepting gets in, declining is kicked with Minecraft's own message, and saying nothing never finishes joining.
- **An optional pack:** declining gets in, but saying nothing still never finishes joining.
- **A malformed SHA-1:** it doesn't stop the server. It only logs `Invalid sha1 for resource-pack-sha1`.

## Not known yet

- Whether stale `lastKnownName` and `playernames.json` entries cause any harm after a player merge. They aren't handled yet.
- The Server Management Protocol. `management-server-port=0` in 1.21.11's properties shows it exists, and nothing here uses it.
- Anything about plugins beyond Multiverse and LuckPerms, in play.
