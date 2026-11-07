# Changelog

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
