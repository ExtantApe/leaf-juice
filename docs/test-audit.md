# Test audit

Each audit lists what Leaf Juice promises, which checks prove each promise, and the gaps. Run the checks with `swift run leafjuice-check` (offline, made-up data, about 80 seconds). The `--real-*`, `--lab` and `--sandbox` runs boot real Paper and are listed apart.

## 2026-11-14: connections (tunnels and services)

The owner's request of 2026-11-14 (see `docs/PLAN.md`). `leafjuice-check --connections`: 88 passed, also part of the default run.

Covered:

- **The file.** No file means no connections and no complaint. An unreadable file is reported, kept, and moved aside as `connections.json.unreadable` on the next save. Broken entries, a bad id and a repeated id are skipped, each with a reason. An unknown provider reads as Other and unknown traffic as admin access. An entry that doesn't say it's on is off.
- **Secrets pasted into the file.** Fields named like `token` or `authKey` are ignored and named, the value is never repeated, and saving drops them.
- **Addresses.** host:port, IPv6 in brackets and a bare name with the game's port are read. Nine bad shapes are refused.
- **Shown as not ready,** with a plain reason, for each of these: no playit agent, an agent that won't answer or answers garbage, a stopped agent, an agent with no secret, a secret missing from the Keychain, a secret file that isn't there or is empty, addresses that can't be read, a playit tunnel with no local address, a running server that doesn't answer where the tunnel points, Tailscale logged out, not answering or not installed.
- **Unknown, never ready:** an agent that doesn't say whether it has its secret, and a locked Keychain.
- **Needs a look:** a secret file other accounts can read, recent refusals in playit's log for this address (older ones and other addresses don't count), a stopped server, Tailscale running but offline.
- **The 2026-11-10 case:** a tunnel forwarding to a Tailscale address while the server only listens on 127.0.0.1 is not ready, and the summary gives the fix. So is a tunnel to the wrong port.
- **Nothing over the internet unless asked.** The quiet check makes no public ping, HTTP request or lookup. From outside: game addresses get a status ping, web addresses an HTTP request (any answer counts, since pack serving answers strangers 404), names a lookup.
- **Off means off:** nothing about it is checked.
- **Real sockets on 127.0.0.1:** the status ping sees a fake server that answers it, doesn't mistake an HTTP answer for Minecraft, and a closed port isn't seen. The real lookup finds localhost.
- **A real keychain:** a throwaway keychain file, never the login Keychain. Missing, saved, replaced, removed, an empty secret refused, and a locked keychain not mistaken for a missing secret.
- **Mutations:** ignoring a missing Keychain secret, ignoring an agent with no secret, always checking from outside, checking a service that's off, and not flagging pasted secrets each failed at least one check.
- **Read-only against this Mac's real agents** (`--connections --live`): the playit agent was found running with its secret, and its log showed the pack tunnel refused while pack serving was off. Tailscale read as connected.

Gaps skipped:

- **The real servers' values.** The Server lead enters them on this Mac; a check run on them comes after.
- **The editor sheet with a keyboard and VoiceOver.** Labels are set, but nobody has used it that way yet.
- **SRV records and PROXY headers.** Stated as limits in the README rather than handled.

## 2026-11-10: the code audit's fixes

The fixes from `docs/audit-2026-11-10.md` (the Server lead's code audit). Default run: 2742 passed, 0 failed, with 22 new
checks in "One long operation at a time". The real sign-in run (`--real-signin`) is updated for Latchkey 0.2+ (whitelist
on, the bot allowlisted to join and taken off to check the refusal); with the landing page off it waits on Latchkey 0.4.0,
which fixes sign-in-page in that case.

Covered:

- **One long operation at a time.** A held busy mark turns Start off; Start during a rename does nothing and leaves the
  rename's mark; a second long operation is refused; queued changes wait; Start holds the server from its first moment, a
  second Start returns without touching the first, and Start lets go when it's done even when it couldn't start.
  Removing the mark from Start failed 1 check ("Start holds the server from its first moment").
- **No line breaks into the console.** A player name, a world name and a seed with a trailing newline are refused, and a
  newline name never reaches a plugin command; a carriage return is escaped in `server.properties`.
- **Chat is never the server.** Chat lines are recognised in the console and in log files (including "Not Secure"), a
  server line isn't, chat saying "Result: true" isn't LuckPerms' yes, and LuckPerms' own line still is.
  Making `isChat` always false failed 2 checks.
- **Access around Usher.** With Usher, the raw allowlist add is refused; without online mode, a name-based op is refused;
  bans work as before.
- **Files and archives.** A gzip header with no end to its name fails cleanly; a restore swaps the file in whole and
  leaves nothing behind; a server jar name with a path in it isn't used; no checksum, or MD5 alone, isn't a published hash.
- **The web side.** A request with no player headers is refused before any file is read; BlueMap on its default address
  keeps `/map/` off, and with `ip: "127.0.0.1"` it's on.

Gaps:

- Two Starts racing for real, and Start during a real rename, are shown with the busy mark and a stand-in wait, not with
  two real JVMs.
- The pack-check pass staying on its own host, and refusing redirects, have no check yet (they need a second host).
- Map-access checks running one at a time are covered by reading, not by two simultaneous viewers.
- Left as task K386: a Modrinth hash match offered as a suggestion, real-size pack extraction, and a setting for the
  Modrinth checksum lookups.
- Each `leafjuice-check` run leaves a `leafjuice-check-<uuid>` preferences domain behind (about 66 on 2026-11-10).

## 2026-11-10: packs served only to players joining

The owner's request of 2026-11-10 (see `docs/PLAN.md`). Default run: 2710 passed. With `--real-pack` (throwaway Paper 26.3, bots): 2762 passed.

Covered:

- **The game's headers.** A name, a dashed or undashed UUID, and a version are read. Nine bad shapes are refused.
- **The server's log lines.** A UUID counts only from the login thread, and joins and leaves only from the server thread.
  - Chat can't vouch for someone or put them online, and neither can a line from another thread or one with text added.
  - A line from 23:59 read at 00:02 counts as three minutes old.
- **The decision.**
  - A player gets the pack 1 or 4.5 minutes after connecting, and while online.
  - Six minutes after connecting, or once they've left, they don't.
  - None of these get it: another name with that UUID, a UUID not on the whitelist, a player who's joining but isn't on the whitelist, an unreadable or damaged whitelist, an unreadable log, or no headers.
- **The real listener on 127.0.0.1.**
  - A joining player gets the pack.
  - These all get the same 404 as a wrong address: curl with no headers, a browser, a UUID not on the whitelist, the `.sha1` address, a HEAD request, a stale player, and no log to read.
  - A header sent twice is a bad request.
  - The app's one-time pass works once, a made-up pass is refused, and a pass lapses after two minutes.
  - Turned off, anyone with the address gets the pack. Turned back on, it's refused again.
  - Settings saved before this existed keep their addresses and get the check switched on.
- **Real Paper 26.3 with bots,** made-up offline accounts, deleted after. Each whitelisted bot that joined fetched the pack with the game's headers, built from the real server's own log, across a restart and for an exact pack. The same address without the headers, and for an unlisted UUID, got 404. The bot was still on the server three seconds later.
- **The older serving checks** turn the gate off, so they still test serving itself.
- **Mutations:** letting everyone through failed 4 checks, and dropping the time limit failed 4.

Gaps skipped:

- **A real 26.x game client.** That it sends the three headers comes from how the game has worked since 1.20.3. The bots send them because the check does. This is owner test T28, with `--demo-pack`. If the headers turn out different, every player would be refused the pack.
- **Through the playit tunnel.** It's plain TCP, so headers pass unchanged, but that wasn't tried. Pack serving on the real server waits on the owner anyway.

## 2026-11-10: the Advisor's token list, sealed with a key in the Keychain

The owner's decision of 2026-11-10 (see `docs/PLAN.md`). Default run: 2659 passed.

Covered:

- **Every PrivacyKey in the run uses a stand-in vault,** so the login Keychain is never touched. The real helper program and the real Keychain code use throwaway keychain files in the scratch folder, never added to the search list (checked before and after).
- **Sealed at rest.** The file starts `LJAK1`, the planted name and UUID can't be read from it, and there's no plain copy. One key is made, and the same key opens the file after a restart.
- **Failing closed, with a plain reason, and nothing written:**
  - a locked Keychain;
  - a refusal;
  - a key gone from the Keychain (no new key is made over the old file);
  - a different key;
  - one changed byte;
  - no key yet with a locked Keychain, where no token is given out and no file is written.

  Falling back to a fixed key on a Keychain error was tried on purpose and failed 6 checks. That also showed the locked and refused checks were too loose, because any refusal passed them. They now need the right reason, and the same change failed them.
- **The old plain `key.json`.** It isn't used while the Keychain is locked, and stays as it was. Once the key can be reached, its tokens carry over and the plain file is deleted. A plain file left beside a sealed one is never read. One that's a symlink is refused.
- **The real Keychain code, on throwaway keychains,** with prompts off as the helper runs. All of these happen at once, with no prompt:
  - a missing key;
  - a 256-bit key made once and read back;
  - a locked keychain, which says it needs access and makes no new key;
  - a key that doesn't trust this program, which says it was refused.
- **The real helper.** It reaches a key that trusts it. A key the app makes for itself and the helper opens for the helper with no prompt. A key made only for the app is refused to the helper with the denied reason. A locked keychain stops it with the needs-access reason. The helper's answers to an AI client still pass every earlier check, now with a sealed file, opened here to prove it holds no secrets.
- **Where the app may start programs.** Claude Code is started once, with `AdvisorLaunch`'s arguments. The helper is started only with `--keychain-check` or `--allow-keychain`.

Gaps skipped:

- **The login Keychain, macOS's own prompt, and the Allow Keychain Access button.** These need a person and their password. They're in owner test T25, which also seals the existing `key.json` on the owner's Mac.
- **Turning prompts on in the helper by mistake.** That mutation would show a real macOS prompt and stall the run, so it wasn't tried. The source and the check of the helper's two flags cover it.

## 2026-11-10: Latchkey 0.3, web sign-ins, and the Advisor's first audit

Latchkey 0.3's lobby and paging, Sign Out Everywhere on the player sheets, and the Advisor, which merged on 2026-11-09 without an audit entry. Default run: 2614 passed. With `--real-invites` (Usher 0.4.1 and Latchkey 0.3.0): 2579 passed, before the Advisor checks below were added. With Latchkey 0.2.0: 2578 passed.

Covered:

- **Latchkey 0.3's lobby.** Its status shows on the Invites card when Latchkey reports it, and nothing is shown when 0.2.0 doesn't. Real 0.3.0 reported it (off, on the throwaway's default settings).
- **Invite list paging.** Against a fake Latchkey:
  - every invite is read two to a page, none of them twice;
  - each page asks from the last page's cursor, checked word for word;
  - a long list stops at the page limit and says there's more;
  - a cursor shaped like a flag (`--yes`) ends the list and is never typed.

  Loosening the cursor guard failed 1 check: the runner refuses it as a second guard. 0.2.0's single page is still read.
- **Web sign-ins, offered only through `describe`.**
  - With 0.2.0, which doesn't list the session commands, nothing is shown, signing out is refused and no session command is typed.
  - With 0.3.0, the browser count is shown and Sign Out Everywhere ends every session.
  - A bad name is refused before anything is typed.
  - With Plugin commands off, nothing is asked.

  Making the `describe` gate always say yes failed 5 checks.
- **Web sign-ins, for real.** Real Latchkey 0.3.0 on throwaway Paper 26.3: the bot's one browser is counted, and Sign Out Everywhere deletes the session file and ends Leaf Juice's page sign-in. The 0.2.0 run still proves that `whitelist remove` ends a session.
- **The Advisor, against `docs/ADVISOR-SECURITY.md`.** Each threat in its table maps to a section of the run:

  | Threat | Section |
  | --- | --- |
  | Chat or commands reach the AI | what chat can't do; text inside code |
  | Names, UUIDs and IPs | who's who; identity; a whole planted server |
  | Secrets | a whole planted server; the real program |
  | Forged identity | identity |
  | Changing the server, or network and process code | the real program (source rule 4) |
  | Reading other files | files outside the server |
  | Translating tokens | suggestions |
  | Guessable tokens | tokens and the key file |
  | A long line hangs it | a long line can't hang it |
  | Failing silently | failing closed |
  | The two independent reviews' attacks | the two review sections |

Gaps added, with the checks:

- **How Claude Code is started.** The flags that take away its shell and files (`--tools ""`), settings, hooks, slash commands, transcript and other MCP servers, and its short environment list, were only tested by hand when the Advisor was built. They lived in the app's page, which the run can't reach. They're now built in `AdvisorLaunch` and checked:
  - each flag is passed;
  - only the five advisor tools are pre-approved;
  - risky flags are never passed;
  - planted `ANTHROPIC_BASE_URL`, `HTTPS_PROXY`, `NODE_OPTIONS` and `CLAUDE_CONFIG_DIR` never reach it, and `PATH` is fixed;
  - a dismissed title can't carry `@`, a path or code into the prompt;
  - the app starts Claude Code in one place, with exactly these.

  Dropping `--tools ""` failed 1 check. Adding a variable to the list first went uncaught, because the check read the same list. The expected list is now written out in the check, and the same change failed 2 checks.

Gaps skipped:

- **The sheets and cards by hand,** with keyboard and VoiceOver. That's owner test T24.
- **Multi-page invite lists on a real Latchkey.** The throwaway has two invites. The fake covers paging, and real 0.3.0 answered in the spec's shape.
- **The Advisor with real data and Claude Code really running.** That's the trial, which waits for the owner's go on a real server. The flags are checked as data, not by running Claude Code.
- **The key file still isn't encrypted.** Encrypting it only helps with the key in the Keychain, and an unsigned app is asked for Keychain access again after every rebuild. That's a question for the owner.

## 2026-11-10: invites through Latchkey, and Latchkey's session files

The Allowlist page gains an Invites card on servers with Latchkey. It makes an invite with Usher profiles, shows the code once, and lists and revokes invites, all through Latchkey 0.2.0's format-1 commands. The links page and map gateway now also sign people in by Latchkey's session file, read in the agreed format on every request. Default run: 2535 passed. With `--real-invites`: 2559 passed.

Covered:

- **The session file (fail closed).** It's named by the SHA-256 of the cookie as sent, and unknown keys are ignored. No session in each of these cases: no `since`, expiry before sign-in, more than 30 days from sign-in, already run out, signed in in the future, a capitalised uuid, a bad name, not JSON, readable by others, a folder others can look in, a link elsewhere, or no file. Loosening the time checks failed 3 checks, and they were put back.
- **The links page by Latchkey's cookie.** Someone is signed in by it, but not once banned, off the allowlist, or after Latchkey deletes the file. An extended session counts at once.
- **Invites through a fake Latchkey.** It isn't offered without Latchkey, or with plugin commands off. Latchkey not taking invites is shown, with its reason. A bad name, 0 or 31 days, and a profile called "none" are refused before anything is typed. The code comes only from the once-file, which is deleted, and never appears in the console. A risky mix asks first. The typed commands are checked word for word. Invites are listed and revoked.
- **Real Latchkey 0.2.0, Usher 0.4.0 and LuckPerms on throwaway Paper 26.3** (`--real-invites <usher.jar> <latchkey.jar>`, made-up offline accounts, deleted after):
  - The invite code never appears in the console or `latest.log`.
  - Usher's `bridge` question comes back through Latchkey.
  - Invites can be listed and revoked.
  - The code works when typed in lowercase on Latchkey's own page. That whitelists the player, and Usher applies the profile.
  - A bot signs in with `/signin`, after an admin gives `latchkey.signin`, which is op-only by default.
  - Leaf Juice reads the real session file, and its links page signs the player in.
  - `whitelist remove` ends both.
- **Looked at by hand by this session, against `--demo-invites`.** An invite was made through the real screen: the question showed inline, the code appeared once, and the list updated. One fix came from it: the hint under the profiles no longer moves the button.

Gaps skipped:

- **Keyboard, VoiceOver and wording, by a person.** That's owner test T24.
- **A real server, a real browser and a real client.** These wait for the owner's go. Latchkey's HTTPS through a tunnel is Latchkey's own gap.
- **Leaf Juice's own sign-in.** It still works alongside Latchkey's. Retiring it is a later change, after T24.

## 2026-11-10: the Allowlist page goes through Usher

On a server with Usher, the Allowlist page approves people and changes their profiles through Usher's format-1 commands: `profiles`, `show`, `apply` (with its questions) and `attempts`. It never goes around Usher with raw LuckPerms or `whitelist add`. This was decided on 2026-11-07, for kids' and adults' groups. Default run: 2493 passed, 0 failed. With the real run: 2520 passed.

Covered:

- **Never around Usher (fail closed).** With an Usher jar on the server, raw adding, adding a group and removing a group are each refused. Nothing is queued, and no `lp` or `whitelist add` is typed. Taking someone off the allowlist still works. Removing the guard failed 5 checks, and it was put back.
- **Usher can't be reached.** The page says why and changes nothing in each case: plugin commands off, the server not started here, an Usher with no `apply` (it names 0.4.0), or a newer format.
- **Through a fake Usher.** Profiles come with labels and worlds, and Usher's settings problems come through. "none" is refused as a profile. An approval runs, then a question, then nothing changes until the yes. Adding and removing happen in one go. The typed command is checked word for word.
- **Real Usher 0.4.0 and LuckPerms on throwaway Paper 26.3** (`--real-usher <jar> --with-luckperms`):
  - Usher's describe gives format 1 and the optional arguments.
  - Its problems name the missing groups until they exist.
  - An approval gives the profile, the group in LuckPerms and the whitelist entry.
  - A second chat circle asks `bridge`, and nothing changes until it's answered.
  - `grown_sky` asks `confirm-grown-sky`.
  - Adding and removing in one go works.
  - The raw path is refused.
  - Usher's change log names Leaf Juice.
  - Every account is made up and offline.
- **Usher 0.4.0's `attempts`.** It uses `attempts` and a number for `next`, where the spec says `items` and a string. Leaf Juice reads both, and the Plugins Lead has been told.

Gaps skipped:

- **The screen itself.** The wording, layout, keyboard and VoiceOver on the Allowlist page's Usher parts haven't been looked at by hand. They go in owner test T6.
- **A real server.** These are throwaway servers only, until the owner's go.

## 2026-11-10: optional arguments in describe

Signalbox 0.2.0 marks an argument that may be left out with `"optional": true`, and Usher 0.4.0 uses it. Leaf Juice now reads it, and refuses a describe with a required argument after an optional one (fail closed: it couldn't tell which slot a value fills). Two checks added; 2468 passed, 0 failed. Not yet tried against Usher 0.4.0 itself, which isn't released.

## 2026-11-09: plugin commands, format 1

Leaf Juice's side of the shared plugin command format (ops `briefs/plugin-commands-spec.md`), behind a new module, Plugin commands, that starts off. 2463 passed, 0 failed (111 new).

Covered:

- **The wire.** Every type is written the agreed way. Uuids go lowercase. Free text is quoted, escaped and last. `--yes` comes before `--json`. Sixteen bad inputs are refused before anything is typed, among them a word that's a flag (`--yes` could answer a question for you), a line break in free text, and an invisible character.
- **Spoofing (fail closed).** An answer counts only when `ea-result ` comes straight after an INFO log header. Thirteen spoof lines are refused: chat, `[Not Secure]` chat, the chat thread, `/say`, `/me`, a logged player command, a Discord bridge, WARN, no header, and junk before the header. Ids are 32 secure random hex characters and never repeat. A second answer, a reused id, an unknown id, a mismatched id inside the JSON, an answer over 8 KB and a refusal with no reason are each refused.
- **Confirm questions.** Nothing goes ahead until every question id is sent back.
- **Timeouts.** No answer is "not confirmed", not "failed". A late answer is passed on once, under its id.
- **Switched off, or not Leaf Juice's own console.** Nothing is typed, and the refusal says why.
- **describe.** It is read. Unknown keys are ignored, and unknown types are marked rather than guessed. A newer format is refused. No format, format 0 or a plugin name that's a path is unreadable.
- **Once-files (fail closed).** A secret is read once and deleted. These are refused, and the file is still deleted: one others could read, one in a folder others could look in, one for another request, and an expired one. A link to another file isn't followed, and its target is kept. A plugin folder that's a link elsewhere isn't read, and nothing is deleted through it. A path or another request's file named in the answer is refused.
- **End to end.** A fake server in Java with a format-1 plugin runs through Leaf Juice's real console. A player's chat answer with the same id comes first, and the real answer is still read. Free text with quotes and backslashes survives. describe comes through. An invite code reaches only the once-file, never the console. A plugin that never answers gives "not confirmed". Switched off, nothing is typed into a running server.
- **Proved by breaking it.** Loosening the parser to accept the prefix anywhere in a line failed 11 checks, including the end-to-end one. Then it was put back.

Gaps skipped:

- **A real Paper plugin.** None speaks format 1 yet. The console line's shape is settled, though. On throwaway Paper 26.1.2, 26.2 and 26.3, a plugin's plain console reply came out as `[hh:mm:ss INFO]: <text>`, and in `latest.log` as `[hh:mm:ss] [Server thread/INFO]: <text>`, with no `System chat:` label (checked by the Plugins Lead, 2026-11-09). Those exact shapes are now checks, and so is a reply sent through a plugin's logger, which isn't read.
- **Screens.** There are none yet. The Players page invite flow comes after Latchkey 0.2.0.

## 2026-11-09: BlueMinimap rename

BlueMapHUD became BlueMinimap 0.2.0. Leaf Juice never looks for this plugin by name or folder: an exact pack is whatever zip you add, stored under its own SHA-1. So no check changes. Only the README and the Exact Pack hint now name `/blueminimap pack export`. The new export has a new SHA-1, so it needs adding again as a new exact pack. Leaf Juice already handles that (a new export gets a new address, old ones keep serving). Built clean; the default run was not repeated, because no code path changed.

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
