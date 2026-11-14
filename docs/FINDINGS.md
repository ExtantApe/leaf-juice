# What real servers actually do

Everything here was observed by running real server software, not read from documentation. To repeat any of it:

```
.build/debug/leafjuice-check --experiments versions,failures,multiverse,players,renames,restore --i-accept-the-minecraft-eula
```

The flag is your own acceptance of the Minecraft EULA. Raw results go to `.lab-sandbox/findings/`, which isn't committed.

Tested in November 2026: Paper 1.21.11 and 26.3, Purpur, Folia, vanilla, Multiverse-Core 5.8.2 and 4.3.16, Multiverse-Inventories 5.3.6, LuckPerms 5.5.71. Behavior on other versions is an assumption until it's been run.

## Differences between versions and software

| What | Observed | What LeafJuice does |
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

- **A clean exit can be a failure.** A tab in `bukkit.yml`, broken `spigot.yml` or `paper-global.yml`, too old a Java, or a garbage `level.dat` all quit with **code 0** before `Done`. LeafJuice treats exiting while starting as a failed start, and doesn't auto-restart it.
- **A deleted `level.dat` isn't fatal to the server.** With no `level.dat_old` either, it starts anyway and writes new world data. LeafJuice blocks the start and points to Backups.
- **`stop` is ignored while starting.** It sat unread until the two-minute escalation, so LeafJuice terminates the process instead.
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
- **Old to new is fine.** A 1.21.11 snapshot (DataVersion 4671) restored and loaded on 26.3 (5023). The reverse can't work, so LeafJuice refuses it.
- **Inventory-only restores are placed where the player is now.** A snapshot taken in `mining`, restored to someone now in `world`, puts `mining`'s items in `world`. LeafJuice warns about this before restoring.
- **Capitalization collides on a Mac.** In offline mode `Alice` and `alice` are different players with different UUIDs, but Multiverse-Inventories files are named by player, and APFS treats `Alice.json` and `alice.json` as one file. `alice`'s items overwrote `Alice`'s. Online-mode servers can't have two names differing only by case, so this only matters for offline servers, and the Players page warns when it finds them.

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

- **LeafJuice hung for good.** Dozens of `unzip` calls each held a shared system thread while waiting on another one, so all 64 were stuck. Tools now run on their own threads, and scans go a few plugins at a time.
- **Copying "settings" isn't simple.** Plugin folders mix behavior, world lists and player data. Multiverse-Inventories keeps inventories in `worlds/` and `groups/`, and Multiverse-Core's `worlds.yml` names folders the Lab doesn't have. Those stay behind.
- **Settings change data.** With `apply-playerdata-on-join: true` and `default-ungrouped-worlds: true`, a join loads a different profile, so a seed made under fresh settings looks empty. Under real settings, the checks hand out items first, restart, and look for them. Each group starts from a clean copy.
- **Flat worlds spawn slimes,** and one killed a bot, which looked like lost items. The Lab is peaceful.
- **Paper's stack frames name the jar:** `at ActionHealth-3.5.9-all.jar//com.example...`. That's how an error reaches the right plugin.
- **Multiverse 5 keeps `environment` inside `read-only:`.**
- **Saved issues need a second look.** Ones stored before a rule existed stayed uncategorized, so they're read again on opening.

## Checking a plugin's fix before trusting it

ActionHealth logged `ClassNotFoundException: org.bukkit.craftbukkit.craftbukkit.entity.CraftPlayer` thousands of times on a real server. A bot took real damage on each combination:

| ActionHealth | Paper | Errors | Action bars received |
|---|---|---|---|
| 3.5.9, fresh settings | 1.21.11 | 5 | 0 |
| 3.5.9, real settings | 26.3 | 2 | 0 |
| 3.9.0, real or fresh settings | 1.21.11 | 0 | 6 and 4 |
| 3.9.0, real or fresh settings | 26.3 | 0 | 4 and 5 |

So the old version shows players nothing at all, on either Minecraft version, and a stable update fixes it. Upgrading the server alone doesn't. The update kept every existing setting and added new ones. Newer plugins can show the action bar through system chat marked as overlay, so a bot has to count both routes.

## Resource packs

Tested with real Modrinth packs, including the official TARDIS packs, and a real Paper 1.21.11 server, with bots as the client. **No real game client has loaded a combined pack yet.**

- **Read-only folders:** real packs can store them in the zip. A cached copy then couldn't be cleared, and unpacking it again silently lost files, so the same recipe built something different. Unpacked copies are now made writable, and file counts are checked against the zip.
- **Format fields:** the TARDIS pack gives `min_format` and no `pack_format`, while older packs do the reverse.
- **Version tags:** the TARDIS packs aren't tagged for 1.21.11 on Modrinth. LeafJuice takes the newest release and says so.
- **Loose files:** packs commonly ship `LICENSE` and `README.md` at the top. They aren't ranked, and each is kept in `credits/<pack>/`.
- **Real merging:** `assets/minecraft/sounds.json` merged between the two TARDIS packs. Other merge types have only been proven on made-up packs.
- **Source projects:** a zip can hold many packs side by side, as a plugin's pack project does. LeafJuice refuses these and says why, rather than picking one.
- **Different layouts:** a 1.19 pack and the TARDIS pack shared no paths at all. TARDIS keeps its content in `assets/tardis/` and `assets/minecraft/items/`, which older packs don't use. Sharing no paths means nothing is overwritten, not that an older pack's files all still apply.
- **Format numbers come in many forms:** `75`, `[75, 0]`, `[97.1]` and `88.0` all appear in real packs.
- **A real overlap:** a 1.19 pack over Lithos and the TARDIS pack gave 19,961 files in 4 seconds, with 2,067 differing. Ranking and category picks behaved as designed. 37 of them were `assets/minecraft/items/*.json` files between TARDIS and Lithos, which can't merge, so TARDIS needs ranking above Lithos to keep its custom models.
- **Repeatable:** building twice gives the same SHA-1, and so does rebuilding from an exported recipe in an empty library.
- **Not always clean:** one pack shipped an empty `assets/sodium/lang/test.json`.
- **A required pack:** accepting gets in, declining is kicked with Minecraft's own message, and saying nothing never finishes joining.
- **An optional pack:** declining gets in, but saying nothing still never finishes joining.
- **A malformed SHA-1:** it doesn't stop the server. It only logs `Invalid sha1 for resource-pack-sha1`.

## Serving packs

Tested with made-up packs, on throwaway servers with a real Paper 1.21.11 and bots. **No real game client has downloaded a served pack, and no real tunnel or Caddy has carried one.**

- **Memory:** 4 downloads of a 300 MB file at once, by another process, added about 2 MB at the peak, and all 4 matched.
- **A staged update:** with a required pack on a running server, a new build stays staged, and new joiners are still offered the old hash and get the old file. After a restart they're offered the new hash and get the new file. The bot's offered address and hash matched the download each time.
- **Starting a server** starts serving if it was left on, so a required pack doesn't point at nothing after the app reopens.
- **Clicked through in the built app,** on a throwaway folder: the contributions list with both copies side by side, starting serving, Serve This Build with its license warning, Check, and Use on This Server. Choosing a winner from the list's menu is only covered by tests on the core, because the menu can't be opened from the background.
- **Exact packs:** a made-up plugin export, with a zip comment LeafJuice would never write, was stored and served byte for byte under its own SHA-1. On a throwaway Paper 1.21.11, a bot was offered its own address and hash, and the download matched. BlueMapHUD itself hasn't been tried with it.
- **Size limit:** the app warns at 250,000,000 bytes, a number not confirmed against a real client.

## How much of a pack a version uses

Mojang's client jar lists every texture a version uses, so fit can be measured rather than guessed. Measured on 1.21.11 (format 75, 3,682 textures) and 26.3 (format 97, 4,182 textures):

| Pack | 1.21.11 | 26.3 |
|---|---|---|
| ZigZag 1.19, alone | 57% (Blocks 76%, Interface 8%), 352 textures ignored | 48% |
| Lithos 1.76, alone | 94% | |
| ZigZag over Lithos | 96% (Blocks 99%) | |

Some ignored files look like renames rather than removals, such as `chain.png` for today's `iron_chain.png`. Nothing converts those yet.

## Server Management Protocol

Tested on Paper and vanilla 1.21.11 and Paper 26.3. Set `management-server-enabled=true`, a port, and `management-server-tls-enabled=false` for local use.

- It's a WebSocket with JSON-RPC, and `Authorization: Bearer <management-server-secret>`. A wrong secret is refused at connection.
- 1.21.11 offers 85 methods and 26.3 offers 89: players, allowlist, bans, operators, game rules, server settings, save and more. `rpc.discover` lists them.
- It pushes notifications such as `minecraft:notification/players/joined`.
- Paper keeps it working. The secret is generated even while it's off, and it lives in `server.properties`.

LeafJuice doesn't use it yet. It would be sturdier than reading console text, but needs a setting changed on each server and another open port. Test copies turn it off, because the real server would already hold the port.

## Player merges

Merging two offline profiles left `playernames.json` and the old `players/<uuid>.json` in place. It did no harm: the new name kept its items in every world, and the old name returning started clean. A real online-mode name change, with one UUID and a new name, can't be tested with offline bots.

## LuckPerms

`lp export <name> --without-users` writes groups, weights, prefixes, inheritance and contexts to `plugins/LuckPerms/<name>.json.gz`, with no players in it. Its default H2 database can't be read directly, so the wiki asks while the server runs and keeps a copy.

On 1.21.11 with LuckPerms 5.5, `lp user <uuid> parent add <group>` works for an account that has never joined, with or without dashes, while `lp user <name>` says the user can't be found. Groups set that way survive a restart. A bot's first join on an offline-mode server kept them too. A real first join on online mode hasn't been seen, because bots can't do one. `whitelist add` matches any capitals and stores the account's own spelling and ID, and says "That player does not exist" for a name with no account. Mojang's `users/profiles/minecraft/<name>` does the same, with a 404 for no account.

## An audit of what deletes things

Reading every delete, move and shell call found these, all now fixed and tested:

- **An empty jar name:** `root.appendingPathComponent("")` is the server folder, and rollback code deleted or moved that path by name.
- **Restoring the oldest backup:** the safety copy's retention could delete the backup being restored.
- **Retention counting:** pinned backups used up "keep the latest", and a same-second tie could delete a new backup. A flaky test revealed this.
- **A linked folder:** `tar` stores the link, not its contents. Backups now say so.
- **A reused process number:** "running elsewhere" trusted any Java process with the saved PID, and Stop would signal it. It now also checks the process's folder.
- **`isPortBusy`:** binding to all addresses succeeds on a Mac even while a port is held on `127.0.0.1` alone.

Scanning stack frames for rules was the slowest part of an error flood, and skipping them made it 12 times faster. `Caused by:` lines are still read.

## Passing has to mean something

A test that stops triggering a bug looks the same as a fix. After the Lab went peaceful, a real plugin bug that only fires on damage stopped showing up, and every check passed. The Lab's checks now include combat, and it's caught again.

Also found while verifying:
- **Links in test copies:** `cp -R` keeps a linked world as a link, so a test copy would have opened and changed the real world. Copies now follow links.
- **Switched-off databases:** a plugin's config can name a database in a section marked `enabled: false`, which isn't using one.
- **Name matches for plugin sources:** searching by name finds the wrong project often. On 17 real plugins, 7 had a likely wrong match, and a "newest release older than yours" check caught them.
- **Reused backup names:** a name can come round again within a second after pruning, so a copy can't be judged by name and size.
- **Pack versions:** the TARDIS pack is tagged for 1.21.10 and declares format 84, higher than 1.21.11's 75, so a format number alone doesn't settle whether a pack suits a version.

## Real servers need more room

Real plugins can have 68 settings files, past an earlier limit of 40. `bStats` and `spark` folders belong to no plugin of that name, so they aren't leftovers. Plugin files that are only comments, such as Magic's templates, give no form fields, which is expected.

## World access and BlueMap

Observed on a throwaway Paper 1.21.11 with Multiverse-Core 5.8.2, LuckPerms 5.5.71 and BlueMap 5.16, with made-up worlds and bots:

- **`enforce-access`** is off by default. `mv config enforce-access true` writes `enforce-access: true` into `plugins/Multiverse-Core/config.yml`.
- **The permission** is `multiverse.access.<world>`. `lp user <uuid> permission check` gives `Result: true` when set, and `Result: false` for someone without it, through Bukkit's default rather than `undefined`.
- **Enforced:** with it on, a player without the permission is refused by `mv tp` with "You do not have permissions to access the world". The same command from the console moves them anyway.
- **BlueMap's maps:** BlueMap writes one `plugins/BlueMap/maps/<id>.conf` per world when it first starts, with `world: "<folder>"`. A world created afterwards gets no map until a file is added.
- **BlueMap's web server:** it binds to every interface by default. Adding `ip: "127.0.0.1"` to `webserver.conf` binds it to loopback, and BlueMap logs `WebServer bound to: /127.0.0.1:<port>`.
- **The map list:** `settings.json` in the web root lists map ids under `maps`, with `mapDataRoot` and `liveDataRoot` both `"maps"`.
- **Tiles and live data:** each map has `textures.json.gz`, `settings.json`, `tiles/`, `live/` and `rstate`. Tiles are served chunked, with `Cache-Control: public, max-age=86400`. Live player positions come from `/maps/<id>/live/players.json` and include names and coordinates.
- **Downloads:** BlueMap downloads Mojang's client jar once its `accept-download` is set to true.

## Paper 26.x for the real tests

- **The allowlist:** with no `white-list` line in `server.properties`, Paper 26.3 refused a bot that wasn't on the allowlist ("You are not whitelisted on this server!"). On 1.21.11 the same file let it in. The real tests now set `white-list=false` themselves. Not checked: whether 26.1.2 and 26.2 do the same, or what 26.3 wrote into the file.
- **Latchkey on 26.x:** the `--real-signin` test passed on Paper 26.1.2, 26.2 and 26.3 with Latchkey built for 26.1, with `paper-plugin.yml` and a Brigadier `/signin`. `/execute as` from the console or an op made no link for another player.
- **Restarting the pack server:** a restart on the same port sometimes found the old socket still open, and failed in 3 of 6 test runs. It now tries again every 0.2 s for up to 2 s. It passed 6 of 6 runs after that.

## Not known yet

- Anything about plugins beyond Multiverse and LuckPerms, in play.
