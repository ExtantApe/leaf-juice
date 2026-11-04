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
- **Never changes a running server underneath its players**: edits wait for a restart you choose: now, when
  the last player leaves, or at a set time with in-game warnings.
- **Protects you on upgrades**: see below.
- **Manages worlds with Multiverse-Core**: create, import, load, unload, copy and delete worlds from the app.
- **Backs up safely while running**: scheduled, with retention, pinning, and any destination.
- **Explains problems**: warnings and errors are catalogued in a side panel, grouped and counted, with
  suggestions for common ones. It's all built-in rules: no AI, and nothing leaves your Mac unless you click.

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

The design is explained in [docs/PLAN.md](docs/PLAN.md) and [brand/README.md](brand/README.md).

## Releasing

Set the version in `Sources/LeafJuiceCore/Support.swift`, then push a tag such as `v0.1.0`. GitHub Actions tests it,
builds a universal app and publishes the `.dmg` and `.zip`.

## License

MIT
