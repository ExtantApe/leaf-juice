# Changelog

## Unreleased

- **Connections:** a card on the Overview page for the address players type and each tunnel or service: playit,
  Tailscale, and anything else that carries players or web traffic, or a domain name. Each has an on or off switch,
  a check and a plain-language status. Settings live in `.leafjuice/connections.json`; secrets stay in the Keychain
  or the service's own file, and a missing one shows as not ready. Checking from outside only runs when you click it.
  Tested with made-up answers, a throwaway keychain and local sockets, and read-only against a real playit agent and
  Tailscale. Not yet run against the real servers.
- **Map and sign-in addresses** in the same file, each with a check. The invite code screen shows the sign-in page
  beside the code, with Copy Both. If none is set, it says so and still shows the code.

## 0.2.0

Tested against real Paper 26.x servers started for the tests, with made-up players, and with the real plugins named
below. Not yet tested by anyone running it on a server people play on. The new screens haven't been checked with a
keyboard and VoiceOver yet. Plugin commands and the Advisor are off until you turn them on.

**Opening it:** Leaf Juice is unsigned, so macOS blocks the first launch. Allow it one of two ways:

- **System Settings:** try to open the app once, then go to System Settings > Privacy & Security, scroll down, click
  **Open Anyway**, and click **Open** when the warning comes back. Apple says to do this only for an app you trust.
- **Terminal:** `xattr -dr com.apple.quarantine "/Applications/Leaf Juice.app"`

Players and sign-in:

- Add someone to the allowlist before they've ever joined, with their LuckPerms groups. Groups you haven't ticked are
  never offered, and you can mark pairs of groups that shouldn't be combined.
- With Usher installed, approving someone goes through Usher's profiles and its questions, and never around it. People
  the whitelist turned away are listed. Needs Plugin commands, which is off by default.
- With Latchkey, make six-character invites for one Minecraft name with Usher profiles, see the code once, and list or
  revoke them. With Latchkey 0.3, the card shows whether its lobby is on, and each player's sheet can sign them out of
  the web pages everywhere.
- A page listing your plugins for people on the server, and BlueMap's web map behind the same sign-in. Players sign
  in with `/signin` in the game, through Latchkey. Both are off by default.

Resource packs:

- See what each pack contributes, serve packs from this Mac with their own address per build, and serve an exact pack
  file unchanged. Serving comes back when the app opens.
- Leave out any song a pack lists in its `songs.json`, so Minecraft's own track plays.

Upgrades and the rest:

- Before an upgrade, check plugins with Preflight's own tool on a copy, and offer to switch off ones that won't start.
- Pick the server icon from a folder of choices in `server-icons/`.
- The Advisor, an optional page that asks Claude Code for suggestions about a server, using your own Claude account.
  It's off until you turn it on in Settings, each server has to be shared, and the first check asks before sending.
  Only recognised log lines, stack traces and a fixed list of settings are sent, with players and addresses replaced
  by code names. The list of who each code name stands for is sealed with a key in your Keychain. macOS asks for
  that key once, and again after each update until Leaf Juice is signed. See `docs/ADVISOR-SECURITY.md`. Tested with
  made-up servers. It hasn't been run on a real server yet.

## 0.1.0

The first release. Tested against real Paper servers started for the tests, with made-up data. Not yet tested by
anyone running it on a server people play on.

- Runs a Minecraft Java server from a Mac app: console, CPU and memory, restart after a crash with a limit, and
  keeps the Mac awake while running.
- Finds the server software, version, memory and flags of an existing server, and keeps everything it adds in
  `.leafjuice/`.
- Keeps Paper, Folia, Purpur, Vanilla or your own jar current, with hashes checked.
- Updates plugins from Modrinth, Hangar, SpigotMC, GitHub Releases, Jenkins or any web address, skipping
  releases tagged for another Minecraft version.
- Settings forms generated from `server.properties`, Bukkit, Spigot, Paper and each plugin's config.
- The Lab, a practice server with bot players for rehearsing an upgrade before doing it for real.
- Resource pack recipes: version, rank, build and share packs.
- A plugin links page listing each plugin, its version and where to read about it. It replaces the wiki.
