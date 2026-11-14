<picture>
  <source media="(prefers-color-scheme: dark)" srcset="brand/readme-header-dark-1280x320.png">
  <img src="brand/readme-header-light-1280x320.png" width="640" alt="LeafJuice: a pixel-art glass of green juice with a leaf and a grapefruit wedge. A little pulp goes a long way.">
</picture>

# LeafJuice

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
- **Backs up when the world has changed**: after people have played, once the server has been empty for 10
  minutes; during a session longer than six hours; and at most once a day when it changes with nobody on. Never two
  within an hour. It keeps everything from the last day, then one a day for a week, then one a week for eight weeks,
  and never deletes a pinned backup or the server's first one. Each routine backup goes to the first storage on your
  list that's connected and has room, then to the server's own folder (`LeafJuice/backups/<server>/` beside your servers, or one you choose), and every
  backup shows where it lives.
  Backups and test restores never fill a disk: each one first checks it would leave 20 GB free. Servers set up before this keep their old schedule until you switch. Saving is paused while it runs, and
  a whole-folder restore comes back exactly as it was and ready to start, even offline.
- **Tries changes on a test copy first**: clones the server, applies an upgrade, plugin update or rename there, boots it and reports back, with
  nothing reaching the real server. If a plugin is the problem, it can find which one.
- **Switches off plugins that won't start on a new version**, using Preflight's upgrade tool
  ([`preflight-upgrade`](https://github.com/ExtantApe/Preflight/blob/main/docs/upgrade.md), downloaded once and checked against a
  pinned SHA-256; it needs Java 25, and works for Paper only). Check with Preflight copies the server with saving paused, and the tool
  boots the copy on the new version. It lists the plugins that didn't load, didn't start or failed a critical check, plus everything
  that needs them. Warnings, and plugins that couldn't be checked in the copy, are only listed. Never-off rules and things to check by hand live in
  `plugins/Preflight/upgrade/rules.json`, the tool's own file, so they work without LeafJuice too. If a never-off plugin would have to go,
  the plan says to wait. Switching off happens only after you confirm, only while the server is stopped, and only after LeafJuice's
  verified whole-server restore point; the tool keeps its own copy of the jars too. Each plugin can be switched back on from the
  Software page. A pass means a plugin starts, not that it works.
- **Rotates server icons**: keep icons in the server's `server-icons` folder and pick one on the Overview page. It's copied over `server-icon.png`, which Minecraft reads at the next start. Added images must be square, and are scaled to 64×64 with nearest-neighbour so pixel art stays sharp. Nothing in the folder is moved or deleted, and an icon in use that isn't in the folder yet is saved there first.
- **Renames deeply**: a world or the whole server, across known config files, with a preview, a restore point and undo.
- **Looks after players**: inventory snapshots every 15 minutes of play, per world with Multiverse-Inventories, restored without touching the world. Merges
  duplicate profiles, and shows who was on and when.
- **Compares backups**: settings, plugins, chunks and player inventories, between any two.
- **Cleans up old servers**: finds leftovers and moves them aside, where they can be brought back.
- **Watches health**: TPS, low disk warnings, and a check that friends can connect.
- **Explains problems**: warnings and errors are catalogued in a side panel, grouped and counted, with
  suggestions for common ones. It's all built-in rules: no AI, and nothing leaves your Mac unless you click.

## Your server stays yours

**No telemetry, no analytics, no accounts.** Everything LeafJuice measures stays on your Mac. It only goes online to
do something you can see: checking for server, plugin and Java updates, and looking for a new LeafJuice release (which you can turn off in Settings).
A few things happen only when you click them, such as the connection check and web searches for an error, and they say what they share.

## Upgrades can't quietly break your server

Changing Minecraft version can't be undone just by swapping the jar back, because a world that has run on a
newer version won't open on an older one. So any version change or software switch works like this:

1. **Restore point.** The whole server is archived, then read back to prove every world is inside. This isn't
   optional. If it fails, the upgrade doesn't happen and nothing changes.
2. **You try it.** LeafJuice asks whether to keep the upgrade, and holds on to the restore point until you say.
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
These are built in: LeafJuice doesn't load third-party code.

## Advisor (optional, uses AI)

Off until you turn it on in **Settings**, unlike everything above, because it sends data outside your Mac. It reads what LeafJuice has noticed about a server you choose and suggests, in plain words, what's wrong and what to do first. It uses your own Claude account through [Claude Code](https://claude.com/claude-code), and in testing a check took about half a minute and about 8 cents if you pay per use.

It can't change anything. Chat, log messages, passwords, player names and addresses aren't shared, and **See Exactly What Would Be Shared** shows the real text before you decide. [ADVISOR-SECURITY.md](docs/ADVISOR-SECURITY.md) explains what this does and doesn't protect against.

## Resource packs

Add packs by file, or from a Modrinth or GitHub page. Every version is kept, unchanged, and the page lets you look through a pack's textures.

A **recipe** ranks packs into one, with the top winning as in Minecraft's own list. You can put a pack first for one kind of file, such as blocks, pick a winner for a single file, or leave out parts of a pack. Languages, sounds, fonts, atlases and item model overrides merge rather than replace. A **My changes** folder always wins, and updates never touch it.

The recipe shows how much of your Minecraft version's textures it covers, measured against Mojang's own file list, so you can see what falls back to the game's art and what's ignored.

Each build keeps a lock file of every copy of every file, so an update can show exactly what would change before you accept it, and older builds stay available. The same recipe builds the same file, byte for byte, so nothing needs uploading again unless something changed.

**Sharing:** a recipe exports as a small JSON file that holds no pack contents, and others download the packs from their authors. A combined pack exports with credits and each pack's license, after a review that flags any license worth checking. That review is a guide, not legal advice.

**What each pack contributes:** for each pack in a recipe, how many files it supplies, how many another pack replaces, and which only it has, by kind of file. The list below shows every copy of a file side by side, marks the one used, and lets you choose another. These counts come from the same lock file the build uses.

**Getting a pack to players:** their games download it from the web, so a build needs an address. There are two ways:

- **Serve it from LeafJuice.** Off until you start it. Each recipe gets its own address with a long random path, so different worlds can have different packs. LeafJuice only listens on this Mac, so something like Caddy has to carry it through your tunnel, on a different hostname from any sign-in page. **Only players joining** is on by default: a pack goes only to a request carrying the game's own `X-Minecraft-Username`, `X-Minecraft-UUID` and `X-Minecraft-Version` headers, for a player listed in the server's whitelist whom the server's log shows connecting in the last 5 minutes, or online now. Everyone else, a browser included, gets the same 404 as a wrong address. Headers can be faked, so this stops casual downloads and shared links, not someone who knows a whitelisted player's name and UUID and asks while that player is joining. The address's long random path still hides it too. It runs only while LeafJuice is open, uses your upload speed, and keeps no record of who downloads. Serving a combined pack gives players a copy of other people's work, so LeafJuice shows each pack's license first.
- **Host it elsewhere,** such as mc-packs.net, and enter the address.
- **Serve an exact file,** such as BlueMinimap's `/blueminimap pack export` (BlueMapHUD's `/bmhud pack export` before 0.2.0). Add an Exact Pack stores the zip unchanged under its own SHA-1, with nothing unzipped, rebuilt or added. Each version gets its own address, and there's also an address with `{sha1}` left in for a plugin that fills in the hash itself. Adding a new export gives it a new address, and old ones keep serving their own file. Two risks, both shown in the app: players can't get the pack while LeafJuice is closed, so a required pack stops them joining, and New Address breaks a plugin's `public-url` until you paste in the new one.
- **Leave out a song.** A pack can list its songs in `songs.json` at its top: `{"format": 1, "songs": [{"id": "calm", "title": "Calm", "credit": "…", "files": [{"path": "assets/minecraft/sounds/music/game/calm1.ogg", "replaces": "music/game/calm1", "bytes": 123}]}]}`. Under Songs, untick one and that recipe's builds leave its files out, so Minecraft's own track plays. Each choice makes a new build, with its own SHA-1 and address. If the list has a problem, such as a file claimed twice or one the pack doesn't have, every song stays in and the build says why. Songs are credited in `CREDITS.txt`.

**Check** downloads from the address as a game would and compares the SHA-1. It carries a one-time pass that only LeafJuice's own pack server issues, valid for one download within two minutes, so it works with only players joining on. Setting another host's address on a server runs this first, and you can still go ahead if it fails, say if you haven't uploaded yet.

LeafJuice sets the address on your server through the usual Change Queue. A change staged for the next restart keeps the running server's file and hash together until that restart, then switches both. If Packmule (called ResourcePackButler before 0.2.0) or WorldResourcepacks is on the server, LeafJuice won't write its pack settings. You copy each build's own address and SHA-1 into that plugin's config instead. That address only ever gives that build, so the hash can't go stale. This has only been tested with stand-in jars of those names.

A real game client hasn't loaded a served pack yet. Bots have shown a real Paper 26.3 server offering the address and hash, and that a download from it matches. With only players joining on, a download sent with the game's headers for a whitelisted bot that just joined succeeded, without them or for an unlisted UUID it got 404, and the bot stayed on. That the 26.x game sends those headers is taken from how the game has worked since 1.20.3, and hasn't been seen yet. If it doesn't, every player would be refused the pack, and kept out if it's required. The 250 MB warning hasn't been checked against a real client either.

### Publishing to your web server

If a web server such as Caddy serves a folder on this Mac, LeafJuice can publish each build there: choose the folder
and its https address on the Resource Packs page, then **Publish the Newest Build**. Each build goes in under a new
random 64-character folder, named by its SHA-1, so Packmule reads the hash straight from the link. The copy is checked
against the build before it's used. The build before stays until everyone who was online at the switch has left, and
at least 10 minutes have passed, then LeafJuice removes it. It only ever removes folders it made, holding nothing but
that build, so anything else in the served folder is left alone. Its record of what it published stays in the
server's `.leafjuice` folder, never in the served folder.

With **Packmule 0.2.1** or later and **Plugin commands** on, LeafJuice tells Packmule each new link itself, by typing
`packmule pack set <pack> <link>` into the console of a server it runs. Set the pack's name from Packmule's
`config.yml` beside each recipe. Packmule downloads the file and checks its SHA-1 before it switches; if that fails, it
keeps the old link and LeafJuice says why. Without that, copy the link into Packmule's config, run `/packmule reload`
and press **Updated by Hand**. Either way, the old build is kept until Packmule uses the new link.

## Connections: tunnels and services

The **Connections** card on the Overview page lists how people reach the server: the address players type, and each
tunnel or service that carries players or web traffic. Each one has a type, an on or off switch, a check and a status
in plain words: Ready, Needs a look, Not ready, Not checked, or Off.

- **playit.gg:** asks the playit agent on this Mac whether it's running and has its secret, reads its log for recent
  failures to reach the local address, and checks something answers there. A tunnel that forwards somewhere the server
  doesn't listen, such as another address when the server only listens on 127.0.0.1, is not ready, with the fix.
- **Anything else:** a port forward or tunnel for players, a web service (the map, a sign-in page, a reverse proxy, a
  pack address, an outside API), or a domain name. These get the same address and secret checks.

**Check** stays on this Mac. **Check From Outside** also connects to each public address over the internet, the way a
player would: a status ping for players, an HTTP request for web addresses, and a lookup for names. It only runs when
you click it. When a piece is missing, the check says which one and shows the service as not ready.

The settings are in the server's `.leafjuice/connections.json`. Secrets are never saved there. A service's secret
either goes in your login Keychain (Edit Connections, paste it into the secure field), or stays in the service's own
file, which LeafJuice only checks is there and readable by you alone, or is kept by the provider's own agent. If a
field that looks like a secret turns up in the file, it's ignored and named on the card. The fields, with made-up
values:

```json
{
  "playerAddress": "play.example.test",
  "mapURL": "https://map.example.test",
  "signInURL": "https://example.test/signin",
  "services": [
    { "id": "play", "name": "Game tunnel", "provider": "playit", "traffic": "game", "enabled": true,
      "localAddress": "127.0.0.1:25565", "publicAddress": "play.example.test", "secret": { "agent": {} } },
    { "id": "site", "name": "Web tunnel", "provider": "playit", "traffic": "web", "enabled": true,
      "localAddress": "127.0.0.1:8443", "publicAddress": "https://example.test" },
    { "id": "status-api", "name": "Status page", "provider": "other", "traffic": "web", "enabled": false,
      "publicAddress": "https://status.example.test", "secret": { "keychain": { "account": "status-api" } } },
    { "id": "dns", "name": "Domain name", "provider": "other", "traffic": "dns", "enabled": true,
      "publicAddress": "example.test" }
  ]
}
```

| Field | Meaning |
|---|---|
| `playerAddress` | What players type in Minecraft. Shown on the card, with a Copy button. |
| `mapURL` | The web map players open. Checked from outside like any web address; a sign-in prompt counts as answering. |
| `signInURL` | The sign-in page that goes with an invite code. Shown beside the code, with Copy Both, so whoever hands it over can read out both. If it's empty, Latchkey's own address is shown and labelled as such, and with neither the screen says so and still shows the code. |
| `id` | Short name: lowercase letters, numbers and hyphens. Also names its Keychain item. |
| `provider` | `playit` or `other`. An unknown one, such as an older `tailscale` entry, reads as `other`. |
| `traffic` | `game` (status ping), `web` (HTTP), `dns` (lookup) or `access` (nothing checked end to end). |
| `enabled` | Off unless the file says `true`. |
| `localAddress` | What a tunnel forwards to on this Mac, as host:port. |
| `publicAddress` | What people outside use: a name, a name with a port, or a web address. |
| `secret` | Where the secret lives: `{"keychain":{"account":"…"}}`, `{"file":{"path":"…"}}` or `{"agent":{}}`. Never the secret. |
| `note` | Free text for your own reference. |

Limits: names are looked up as plain address records, so a game address that only works through an SRV record shows as
not answering. A web tunnel that expects a PROXY header still answers a plain connection, which is all the local check
does. Checked against the real playit agent on one Mac, read-only. Not yet run against the real servers.

## Session access

For assistant sessions, or your own scripts, on the same Mac. Off until you turn it on in **Settings > Session
access**. A session can:

- read each server's status: running or not, software, how many players are online (never who), TPS, tick time,
  plugins and open issues;
- read the recent log, with chat left out, and player names, UUIDs and network addresses replaced;
- run the commands on your list, exactly as written. It starts with `latchkey reload`, `save-all` and `list`. You can
  add and remove commands in Settings. `stop` can't be added, so stopping stays in the app.

Anything else is refused: commands off the list, extra words after a listed command, a second command after a line
break, unknown calls, a wrong token. Every call, allowed or refused, is listed in Settings with who said they were
calling and when, and a command a session runs shows in the console too.

How it's reached: a Unix socket at `~/Library/Application Support/Leaf Juice/session.sock`, private to your macOS
account, plus a random token in your login Keychain. The first time something other than LeafJuice reads the token,
macOS asks you. **Make a New Token** cuts off anything holding the old one. Anything running as your account could
use it once allowed, so keep the list to commands you'd be happy for any of them to run.

The client is inside the app:

```bash
"/Applications/LeafJuice.app/Contents/MacOS/leafjuice-session" --as "Server lead" status
```

```bash
"/Applications/LeafJuice.app/Contents/MacOS/leafjuice-session" --as "Server lead" log --lines 50 --server "Made-up Server"
```

```bash
"/Applications/LeafJuice.app/Contents/MacOS/leafjuice-session" --as "Server lead" run "save-all"
```

It prints LeafJuice's answer as JSON and exits 0 when it was allowed, 1 when refused, and 2 when LeafJuice can't be
reached. A command only runs on a server LeafJuice started; output is what the server printed in the next second and a
half. `--as` is what the caller says about itself; it's recorded, not checked.

## Staying safe when you're not looking

Every backup can also be copied to a **second location**, ideally another drive, with each copy checked against the original. If the main backups are lost, they can be copied back. LeafJuice also sends a **Mac notification** for crashes, failed backups and low disk space, and you can turn that off in Settings.

## Allowlist

Add someone before they've ever joined. Type their name in any capitals and LeafJuice asks Mojang for the real account, then shows you its spelling and ID. If there's no such account, or Mojang can't be reached, nothing is added. Java accounts only, and it needs `online-mode=true`.

With LuckPerms you can choose their groups too. Groups go on first, then the allowlist, and both are read back, so nobody can join with only the default access while it's half done. While the server is stopped the whole thing waits, shows under **Not finished**, and happens when the server is running. Each server is its own list.

A group is only offered once you've ticked it, so a new or admin group never appears by itself. You can mark pairs of groups as **Don't combine**, and choosing both warns you before saving. It doesn't stop you. Group names only come from your server and your choices.

Taking someone off the allowlist leaves their groups alone. Changing someone's groups needs the server running.

**Tested:** real Paper 1.21.11 and LuckPerms on throwaway servers, including a bot's first join on offline mode. **Not tested:** a real first join on online mode, or the screen being clicked through.

### With Sheriff and Latchkey

These need **Plugin commands**, which is off by default, and the server running in LeafJuice, because LeafJuice types the plugins' commands into its console and reads their answers.

- **Sheriff:** when it's installed, approving someone goes through Sheriff's profiles, its questions show on the page and each needs a tick, and changes land in Sheriff's own log. LeafJuice then never changes groups or the whitelist around Sheriff. If it can't reach Sheriff, the page refuses rather than doing it another way. People the whitelist turned away are listed, with an Approve button.
- **Invites (Latchkey):** an invite is a six-character code for one Minecraft name, lasting 1 to 30 days, with the Sheriff profiles you pick. The code is shown once and LeafJuice keeps no copy. It never goes through the console or the server log. Invites can be listed and revoked. With Latchkey 0.3, the card also shows whether Latchkey's lobby is on.
- **Printed tickets:** with Latchkey 0.5, **Print Ticket…** makes a card with the server's name, where to go, the code
  in groups of three, when it runs out, and a QR code that opens the page with the code filled in. The code sits after
  `#` in that link, so it never reaches a web server's logs. It prints black on white, saves as a PDF, or copies as
  plain text, and VoiceOver reads it as a list of steps. LeafJuice keeps no copy. If Latchkey's ticket looks wrong,
  such as a link to another site or one that isn't https, there's no ticket and the code is shown as usual.
- **Web sign-ins:** where Latchkey offers it (0.3 and later), each player's sheet shows how many browsers they're signed in on, with **Sign Out Everywhere**. Their allowlist place and profiles stay.

**Tested:** throwaway Paper 26.3 with the allowlist plugin's 0.4.0 and 0.4.1 releases, before it was renamed Sheriff (not yet with Sheriff 0.5.0), Latchkey 0.2.0 and an unreleased 0.3.0 build, LuckPerms and made-up offline accounts: an invite made here, redeemed on Latchkey's page, profiles applied by Sheriff, a bot signed in, signed out again. **Not tested:** a real server, a real game client, or the screens with a keyboard and VoiceOver.

## Plugin links

One page listing each enabled plugin, its version and a link to its documentation, with the server's version at the top.

A link is filled in only when the plugin's source is already known: its jar matched a file on Modrinth, or you set the source yourself. Modrinth's wiki link comes first, then its source code link. A `plugin.yml` website or a match by name stays a suggestion until you press Use, because a name can match the wrong project. Searching by name sends that plugin's name to Hangar and SpigotMC, so it only happens when you ask, one plugin at a time. You can also type your own link.

### A page for people on the server

Off by default. Turn it on and the same list is served as a web page that only people provisioned on your server can read. Each plugin is left off it until you tick it, and server and plugin versions each have a switch, because versions help anyone looking for a server with a known weakness.

**Who gets in:** a player types `/signin` in game and clicks the one-time link they're sent, so there's no password. That takes the Latchkey plugin, the `latchkey.signin` permission (ops have it by default), a place on the allowlist, and `online-mode=true`. A server behind a proxy has `online-mode` off, so it isn't supported yet.

- With Latchkey 0.2 or later, LeafJuice also accepts Latchkey's own browser sessions, reading Latchkey's session file on every request, so they last as long as Latchkey says and survive LeafJuice quitting. LeafJuice's older sign-in still works alongside it for now: a session lasts 12 hours and lives in memory, so quitting LeafJuice ends it. Losing the permission takes effect at the next sign-in. Leaving the allowlist or being banned ends access at once.
- Nothing has an age or account type of its own: children's accounts follow the same permission.
- The app shows who's signed in, and can sign anyone out. It keeps the account, the time and what happened for 30 days, in `.leafjuice/sign-in-log.json`, with no addresses, browsers or pages visited.
- The page only exists while LeafJuice is open.

**Reaching it from outside:** LeafJuice only listens on this Mac, over plain HTTP, and only answers to the address you enter. HTTPS has to end on this Mac too, or whoever carries the traffic could read sign-in links and cookies. The plan is [Caddy](https://caddyserver.com) behind a [playit.gg](https://playit.gg) HTTPS tunnel, which playit says needs Premium and which it doesn't decrypt. Any public certificate puts its hostname in public logs, so pick a name that doesn't say who the server is for.

```
links.example.com {
    reverse_proxy localhost:8765
}
```

**Tested:** a bot typed `/signin` on a throwaway Paper 1.21.11 server, and a real browser signed in and out on localhost with made-up data. **Not tested:** a real tunnel, Caddy, a real game client clicking the link, a permission granted through LuckPerms rather than op, and Bedrock players, who may not be able to click a chat link.

**The map:** the same sign-in can also cover BlueMap's web map, at `/map/` on the same address. Off until you tick it. A player sees a world's map only if Multiverse lets them enter that world:

- With Multiverse's `enforce-access` on, each world is checked with LuckPerms against `multiverse.access.<world>`, every few minutes per person. Only a plain yes counts. That includes the world players spawn in, so give that permission for any world whose map should show.
- With `enforce-access` off, Multiverse lets everyone into every world, so everyone signed in sees every map. The app says so.
- No Multiverse, no LuckPerms, a server that's stopped, or any setting that can't be read means no maps, and the app shows why.
- Hidden maps are refused, not just left off the list: their tiles, live player positions and markers all return "not found", and BlueMap is never asked for them.
- An op who isn't given the permission through LuckPerms sees fewer maps than they can enter, because op status isn't part of the check.
- Teleports from the console or by another plugin can move someone into a world they don't have access to. The map follows the permission, not where they happen to be.

BlueMap's own web server must stop answering anyone else, or the sign-in can be skipped. Set `ip: "127.0.0.1"` in `plugins/BlueMap/webserver.conf`. By default it's every network interface, and the app warns until it's changed. LeafJuice reads BlueMap's port and web folder from the same file.

**Map tested:** real BlueMap 5.16, Multiverse-Core 5.8.2 and LuckPerms 5.5.71 on a throwaway Paper 1.21.11 server with bots and made-up worlds. A real tile came through byte for byte, each player saw only their own worlds, and taking the permission away took the map away. On Minecraft 26, where Paper moves every world inside the level folder, BlueMap's map settings name the level folder and a dimension instead. LeafJuice reads which world that is from the dimension. That form comes from a 26.2 trial with BlueMap 5.29 and is only covered by tests on made-up files.

**Not tested:** a real browser drawing the map through the gate, a real tunnel, Caddy, or BlueMap's live updates over time.

## Install

1. Download the `.dmg` from [Releases](https://github.com/ExtantApe/LeafJuice/releases) and drag LeafJuice to Applications.
2. LeafJuice is free and unsigned (Apple charges for signing), so macOS blocks the first launch. Allow it one of two ways:

   **Terminal (quickest):**

   ```bash
   xattr -dr com.apple.quarantine "/Applications/LeafJuice.app"
   ```

   **Or System Settings:** try to open the app once, then go to **System Settings → Privacy &
   Security**, scroll down, click **Open Anyway**, and click **Open** when the warning comes back. Apple
   says to do this only for an app you trust.

You only need to do this once per download. Requires macOS 14 or later, on Apple silicon or Intel.

Unsure about running an unsigned app? It's reasonable to be. You can read the code and build it yourself:

```bash
git clone https://github.com/ExtantApe/LeafJuice.git
```

```bash
cd LeafJuice && scripts/build-app.sh
```

That needs only Apple's Command Line Tools (`xcode-select --install`), and the app appears in `dist/`.

## Good to know

- **Accepting the EULA is yours to do.** A new server asks you to read Minecraft's EULA and accept it yourself.
- **Java** is found automatically (`java_home`, Homebrew, SDKMAN). If you don't have the version a server needs,
  LeafJuice offers to download Eclipse Temurin into its own folder, leaving your system's Java alone.
- **Scheduled backups and restarts only happen while the app is open.** Closing the window is fine: it stays
  in the menu bar. Quitting stops your servers cleanly first, after asking.
- **Premium SpigotMC plugins** can't be downloaded automatically, so LeafJuice can only tell you an update exists.
- **SpigotMC's version tags** are set per plugin rather than per release and are maintained by hand, so
  LeafJuice calls them "likely" at best. Modrinth and Hangar list versions per release, so those are exact.
- **Other people on the internet** need your router to forward the server's port. LeafJuice doesn't do this for you.

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

MIT. Code adapted from other projects is credited, with its license, in [NOTICE](NOTICE).
