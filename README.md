<p align="center"><img src="brand/icon-1024.png" width="128" alt="Leaf Juice icon: a glass of green juice with a leaf on it"></p>

# Leaf Juice

A free, native Mac app for running a Minecraft Java server. It's the easy step up from
`java -jar paper.jar`: about 40 MB and no measurable CPU at idle, with no web panel, daemon or container.

> **Status: early.** Works against real APIs and real plugin downloads, but it's young. Keep your own
> backups of anything you can't replace until it has more miles on it.

Not affiliated with Mojang or Microsoft.

## What it does

- **Runs your server**: start, stop, a real console with history, CPU and memory, automatic restart after a
  crash (with a limit, so it can't loop), and keeps your Mac awake while running.
- **Keeps servers together**: on first launch it offers to create `~/Minecraft`, or to use another or an existing
  folder (changeable in Settings). Add Server lists what's there, and new servers are created there.
- **Uses your existing server**: pick one from the list, or point it at a folder. It detects the software, version, and the memory and
  flags in your start script. Everything it adds goes in `.leafjuice/`; your files aren't touched. Delete that
  folder and you have a normal server again. Works with servers from before Minecraft 26 and after.
- **Keeps server software current**: Paper (recommended), Folia, Purpur, Vanilla, or your own jar. Hashes are
  checked, and it uses the Java version and flags Paper recommends for that exact Minecraft version.
- **Knows which plugins fit**: each plugin has a source you can edit (Modrinth, Hangar, SpigotMC, GitHub
  Releases, Jenkins, or any web address). Releases tagged for another Minecraft version are skipped, and every
  download is checked before it replaces anything.
- **Settings screens built from your files**: `server.properties`, Bukkit, Spigot, Paper and every installed plugin's
  config get a form generated from the file itself, so they can't go out of date and new plugins just work. Comments become
  help text, and edits change only that line. Ops, allowlist and bans have their own screen.
- **Never changes a running server underneath its players**: edits wait for a restart you choose: now, when
  the last player leaves, or at a set time with in-game warnings.
- **Protects you on upgrades**: see below.
- **Manages worlds with Multiverse-Core**: create, import, load, unload, copy and delete worlds from the app.
- **Backs up safely while running**: the whole server folder by default, to `LeafJuice/backups/<server>/` beside your
  servers, or anywhere you choose. A whole-folder restore comes back exactly as it was and ready to start, even offline.
  Scheduled, with retention and pinning.
- **Tries changes on a test copy first**: clones the server, applies an upgrade, plugin update or rename there, boots it and reports back, with
  nothing reaching the real server. If a plugin is the problem, it can find which one.
- **Renames deeply**: a world or the whole server, across known config files, with a preview, a restore point and undo.
- **Looks after players**: inventory snapshots every 15 minutes of play, per world with Multiverse-Inventories, restored without touching the world. Merges
  duplicate profiles, and shows who was on and when.
- **Compares backups**: settings, plugins, chunks and player inventories, between any two.
- **Cleans up old servers**: finds leftovers and moves them aside, where they can be brought back.
- **Watches health**: TPS, low disk warnings, and a check that friends can connect.
- **Explains problems**: warnings and errors are catalogued in a side panel, grouped and counted, with
  suggestions for common ones. It's all built-in rules: no AI, and nothing leaves your Mac unless you click.

## Your server stays yours

**No telemetry, no analytics, no accounts.** Everything Leaf Juice measures stays on your Mac. It only goes online to
do something you can see: checking for server, plugin and Java updates, and looking for a new Leaf Juice release (which you can turn off in Settings).
A few things happen only when you click them, such as the connection check and web searches for an error, and they say what they share.

## Upgrades can't quietly break your server

Changing Minecraft version can't be undone just by swapping the jar back, because a world that has run on a
newer version won't open on an older one. So any version change or software switch works like this:

1. **Restore point.** The whole server is archived, then read back to prove every world is inside. This isn't
   optional. If it fails, the upgrade doesn't happen and nothing changes.
2. **You try it.** Leaf Juice asks whether to keep the upgrade, and holds on to the restore point until you say.
3. **Roll back in one step**, if you need to: server, plugins, settings and jar all return to how they were.
4. **The upgraded state isn't thrown away.** It moves to the **Shelf**, which is separate from backups:
   retention leaves it alone, and you can resume that upgrade later, for example once a plugin has caught up.

Before upgrading, **Check Plugins** on the Software page shows which plugins have a release for the target version.

## The Lab: rehearse before you upgrade

The Lab is a practice server in `~/Minecraft/lab`, with its own worlds and bot players that really join and hold items. It
only listens on your Mac, and it can't be removed or renamed in the app. **Save This Lab** keeps it under a readable name like
`2026-11-03_20-15_paper-1.21.11-build132_before-26-upgrade.tar.gz`, you can restore any save, and **Wipe and Start Fresh** rebuilds it.

The Lab's **status board** runs its tests one switch at a time. Flick a switch, wait for its light, and a green light unlocks the
switch below. Optional rows can stay off, and a red light offers **Continue Anyway**. If you have several servers, you pick which one the Lab models.

1. **Plugins load:** your version and exact jars, added a few at a time in groups by theme, with fresh settings, so a failure names its group.
2. **Your plugin settings** (optional): the same plugins with your real settings, so a plugin problem and a settings problem are different answers.
3. **Upgrade:** the Lab's data moved to the new version, with updated plugins.
4. **Fresh install:** wiped and installed new on that version, with the same checks.
5. **New version with your settings** (optional).

Plugins that reach outside your Mac, such as map web servers and cloud backups, don't run in the Lab, and one using an outside database
keeps fresh settings. Lights go out of date if your plugins or version change. Upgrade and Fresh together suggest:

| Upgrade | Fresh | What it suggests |
|---|---|---|
| Pass | Pass | Nothing here stands in the way |
| Fail | Pass | The version and plugins are fine, but moving data across isn't |
| Pass | Fail | Something relies on a setup only older data had |
| Fail | Fail | A real incompatibility |

Your server's plugin list and jars are read, and nothing else: its worlds, players and settings aren't copied, and it keeps
running. A pass means these checks passed, and the board lists what they don't cover. The upgrade itself still makes a restore point.

## Features you can turn off

Worlds and Multiverse, Players, History, Cleanup, Test copies, Backup drills, the Lab, Resource packs and Plugin links are all switches in **Settings**, and all
on by default. Off hides the feature and stops its background work. Nothing it saved is deleted, and turning it back on picks up where it left off.
These are built in: Leaf Juice doesn't load third-party code.

## Resource packs

Add packs by file, or from a Modrinth or GitHub page. Every version is kept, unchanged, and the page lets you look through a pack's textures.

A **recipe** ranks packs into one, with the top winning as in Minecraft's own list. You can put a pack first for one kind of file, such as blocks, pick a winner for a single file, or leave out parts of a pack. Languages, sounds, fonts, atlases and item model overrides merge rather than replace. A **My changes** folder always wins, and updates never touch it.

The recipe shows how much of your Minecraft version's textures it covers, measured against Mojang's own file list, so you can see what falls back to the game's art and what's ignored.

Each build keeps a lock file of every copy of every file, so an update can show exactly what would change before you accept it, and older builds stay available. The same recipe builds the same file, byte for byte, so nothing needs uploading again unless something changed.

**Sharing:** a recipe exports as a small JSON file that holds no pack contents, and others download the packs from their authors. A combined pack exports with credits and each pack's license, after a review that flags any license worth checking. That review is a guide, not legal advice.

**What each pack contributes:** for each pack in a recipe, how many files it supplies, how many another pack replaces, and which only it has, by kind of file. The list below shows every copy of a file side by side, marks the one used, and lets you choose another. These counts come from the same lock file the build uses.

**Getting a pack to players:** their games download it from the web, so a build needs an address. There are two ways:

- **Serve it from Leaf Juice.** Off until you start it. Each recipe gets its own address with a long random path, so different worlds can have different packs. Leaf Juice only listens on this Mac, so something like Caddy has to carry it through your tunnel, on a different hostname from any sign-in page. The game can't sign in, so that random path is all that hides a pack, and every player's game is given it. It runs only while Leaf Juice is open, uses your upload speed, and keeps no record of who downloads. Serving a combined pack gives players a copy of other people's work, so Leaf Juice shows each pack's license first.
- **Host it elsewhere,** such as mc-packs.net, and enter the address.

**Check** downloads from the address as a game would and compares the SHA-1. Setting another host's address on a server runs this first, and you can still go ahead if it fails, say if you haven't uploaded yet.

Leaf Juice sets the address on your server through the usual Change Queue. A change staged for the next restart keeps the running server's file and hash together until that restart, then switches both. If Resource Pack Butler or WorldResourcepacks is on the server, Leaf Juice won't write its pack settings. You copy each build's own address and SHA-1 into that plugin's config instead. That address only ever gives that build, so the hash can't go stale. This has only been tested with stand-in jars of those names.

A real game client hasn't loaded a served pack yet. Bots have shown a real Paper server offering the address and hash, and that a download from it matches. The 250 MB warning hasn't been checked against a real client either.

## Staying safe when you're not looking

Every backup can also be copied to a **second location**, ideally another drive, with each copy checked against the original. If the main backups are lost, they can be copied back. Leaf Juice also sends a **Mac notification** for crashes, failed backups and low disk space, and you can turn that off in Settings.

## Plugin links

One page listing each enabled plugin, its version and a link to its documentation, with the server's version at the top. It only shows in the app for now.

A link is filled in only when the plugin's source is already known: its jar matched a file on Modrinth, or you set the source yourself. Modrinth's wiki link comes first, then its source code link. A `plugin.yml` website or a match by name stays a suggestion until you press Use, because a name can match the wrong project. Searching by name sends that plugin's name to Hangar and SpigotMC, so it only happens when you ask, one plugin at a time. You can also type your own link.

## Install

1. Download the `.dmg` from [Releases](https://github.com/mgilardi/leaf-juice/releases) and drag Leaf Juice to Applications.
2. Leaf Juice is free and unsigned (Apple charges for signing), so macOS blocks the first launch. Allow it one of two ways:

   **Terminal (quickest):**

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Leaf Juice.app"
   ```

   **Or System Settings:** open the app and dismiss the warning, then go to **System Settings → Privacy &
   Security**, scroll down, and choose **Open Anyway**.

You only need to do this once per download. Requires macOS 14 or later, on Apple silicon or Intel.

Unsure about running an unsigned app? It's reasonable to be. You can read the code and build it yourself:

```bash
git clone https://github.com/mgilardi/leaf-juice.git
```

```bash
cd leaf-juice && scripts/build-app.sh
```

That needs only Apple's Command Line Tools (`xcode-select --install`), and the app appears in `dist/`.

## Good to know

- **Accepting the EULA is yours to do.** A new server asks you to read Minecraft's EULA and accept it yourself.
- **Java** is found automatically (`java_home`, Homebrew, SDKMAN). If you don't have the version a server needs,
  Leaf Juice offers to download Eclipse Temurin into its own folder, leaving your system's Java alone.
- **Scheduled backups and restarts only happen while the app is open.** Closing the window is fine: it stays
  in the menu bar. Quitting stops your servers cleanly first, after asking.
- **Premium SpigotMC plugins** can't be downloaded automatically, so Leaf Juice can only tell you an update exists.
- **SpigotMC's version tags** are set per plugin rather than per release and are maintained by hand, so
  Leaf Juice calls them "likely" at best. Modrinth and Hangar list versions per release, so those are exact.
- **Other people on the internet** need your router to forward the server's port. Leaf Juice doesn't do this for you.

## Adding your own issue rules

Open **Settings → Show Folder** and add a JSON file. A rule with the same `id` as a built-in one replaces it.

```json
[{
  "id": "my-plugin-db",
  "title": "MyPlugin lost its database",
  "severity": "error",
  "category": "Plugins",
  "contains": ["myplugin: connection lost"],
  "explanation": "What this means, in plain words.",
  "steps": ["The first thing to try."],
  "action": {"page": "configs", "label": "Open Configs"}
}]
```

`severity` is `info`, `warning`, `error` or `critical`. Use `regex` instead of, or as well as, `contains`; a named
group `(?<subject>…)` separates issues by subject and fills `{subject}` in the text. `action.page` can be
`overview`, `console`, `worlds`, `plugins`, `software`, `configs`, `launch`, `backups` or `changes`.

Better still, send built-in rules as a pull request: they live in
[`BuiltInRules.swift`](Sources/LeafJuiceCore/BuiltInRules.swift). Add `samples`, real log lines the tests check it against.

## Development

SwiftUI and Swift Package Manager, with no dependencies. `LeafJuiceCore` holds all the logic and `LeafJuice` is the interface.

```bash
swift run leafjuice-check
```

Runs the tests, including a server's full lifecycle against a small stand-in jar. Add `--live` to also call the real
Paper, Modrinth, Hangar, Spiget, GitHub and Jenkins services (downloads a few hundred MB).

To boot real Paper with real Multiverse in a temporary folder, add `--real-paper --i-accept-the-minecraft-eula`.
That second flag is your own acceptance of the [Minecraft EULA](https://aka.ms/MinecraftEULA).

`--sandbox` keeps a longer-lived test server with bot players in `.lab-sandbox/`, `--lab` runs the Lab and a real rehearsal there,
and `--experiments` tries things on real servers and writes down what happened. All three need that same flag, and what
they've found so far is in [docs/FINDINGS.md](docs/FINDINGS.md).

The design is explained in [docs/PLAN.md](docs/PLAN.md) and [brand/README.md](brand/README.md).

## Releasing

Set the version in `Sources/LeafJuiceCore/Support.swift`, then push a tag such as `v0.1.0`. GitHub Actions tests it,
builds a universal app and publishes the `.dmg` and `.zip`.

## License

MIT
