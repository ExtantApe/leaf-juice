# Advisor: security rules

`leafjuice-mcp` lets an AI client look at a server and leave suggestions. It's a separate read-only program. In the app, the
optional **Advisor** page runs it with Claude Code. That page is off until you turn it on in Settings, each server has to be
shared separately, and nothing is sent until you press Check Now and confirm. Automatic checks need their own yes per server,
and only start after you've sent a first check yourself. Turning the Advisor off stops a check that's running. With it off,
the app contains no AI and starts none. A test checks each of these yeses. The separate trial build
(`scripts/build-advisor-trial.sh`) has the page on, as that's all it does, but each server still has to be shared. The app starts Claude Code with every other tool removed, so the shell-access warning below doesn't apply to
checks started there.

## The main rule

**Log wording isn't passed on.** The first version filtered free text, and an independent review broke it easily: chat
in many formats, secrets in many formats, and one chat message that switched off the password filter. So filtering isn't the
design any more. Each log line either matches a fixed shape and is rewritten from the parts that were recognised, or its
text is withheld and only counted.

**The exception is code-shaped text**, which a plugin's author controls. Stack frames, exception classes, plugin, event and
rule names, versions, and jar names are limited in form, but not to what's true. See below.

The cost is real: the AI can see *that* a plugin logged an error and its stack trace, but not the message. New shapes can
be added as they prove useful, each with a test.

## What the AI receives

| Tool | Contents |
|---|---|
| `list_servers` | Server tokens |
| `server_summary` | Software, version, a fixed list of settings if their values are plain numbers, booleans or known words, and plain plugin file names |
| `open_issues` | Rule ID, severity, category, installed plugin, count, times and stack trace. Never a title or sample, because those can be raw chat |
| `recent_problems` | Recognised events with tokens for players and addresses, stack frames, exception class names, and a count of what was withheld |
| `suggest` | Writes plain text to a private inbox. This is the only tool that takes free text |

Reads also write to the key file, when a player or address is first shared. Looking at the Advisor page, or its preview of
what would be sent, records nothing: the preview uses a throwaway token list, sealed with a key held only in memory and deleted straight after, so its code names
differ from a real check's.

## What it protects against

| Threat | Defence |
|---|---|
| Chat or commands reach the AI | Log wording isn't sent, from either the log or stored issues. Something that can write several lines into the log, such as a chat bridge or a message quoted in an error, can shape its text like a trace. So a frame or exception line also has to follow Java's own naming: lowercase packages, one class, a method, and a `.java` file named after its class. That stops ordinary text, but carefully written text in that form still passes, from any thread, to `recent_problems` and `open_issues` |
| Player names, UUIDs and IPs reach the AI | Tokens in fixed shapes. In code-shaped text, a known player's name becomes a token wherever it sits, except for common code words such as `server`, which say nothing about anyone. An address, UUID, email or known key format drops the line in its usual spellings. See "Odd spellings" below for ones that get through. Jars and frames with sentence words are dropped too, though that only catches wording it knows. World and settings file names are sent only if they're standard |
| Secrets reach the AI | No free text is sent, and plugin configs aren't readable. `server.properties` is an allowlist of keys and values |
| Chat forges an identity or changes a filter | Names come only from the server's own player files and from exact line shapes on the right thread. Only the authenticator thread and `usercache.json` can tie a name to a UUID. A plugin can forge that thread: see below |
| The AI changes or breaks the server | There's no tool for it, and the program doesn't link `LeafJuiceCore` or use network or process APIs. A test checks the source |
| The AI reads files it shouldn't | No tool takes a path. Only servers named at launch are visible, and a symlink anywhere inside a server folder, or a hard link, is refused. The folder you name may itself be reached through a link |
| The AI recovers a real name from a token | No tool translates tokens. Only `--suggestions` does, for a person at a terminal |
| Tokens are reversed by guessing | They're random, not derived from the value |
| A long line hangs the program | Over-long lines are withheld before any pattern runs, and suggestions are refused or cut to a fixed length first. A flood of new players can still make an answer take many seconds |
| The token list is read from disk | It's sealed with a key in the Keychain. The helper never lets macOS ask for it: a locked Keychain, a refusal or a missing key stops every answer with a plain reason, and nothing is written. A missing key never replaces a sealed file. Allow Keychain Access on the Advisor page is the only place macOS may ask, and it says why first. Until LeafJuice is signed, macOS asks again after each update |
| A safeguard fails silently | A damaged, oversized or linked key stops every answer. So does a damaged, oversized or linked player or issues file when that answer reads it, and a server folder that's gone. A key deleted while running is treated as a fresh start, so players get new tokens |

## What it does not protect against

- **An agent that also has shell or file access.** This is the big one. Claude Code running as you can read `~/Minecraft`
  directly, and could ask the Keychain for the Advisor's key, which macOS would show you. Nothing in this program can stop that. **Without the restriction shown below, the privacy
  layer is not a security boundary.**
- **Other programs running as you.** The token list is sealed with a key in your Keychain, and macOS only hands that key to LeafJuice and its helper, or to a program you allow. A program running as you can still ask for it, and macOS shows you that request. Something that can read your memory or your unlocked Keychain can read it too.
- **A malicious or careless plugin.** Plugin code runs inside your server, so it's already trusted with far more than this.
  It can write fake frames up to the limits, and quite long phrases fit in hyphenated or dotted identifiers such as
  `Ignore.previous.rules.now`. A name it splices into a word, or that isn't a known player's, wouldn't be recognised. It can
  also forge a login line, and rename a player's token to something else. Each report is limited to about 60,000 characters.
- **Bad advice.** The AI may be wrong, or tricked by the above. A suggestion can name a real player and can say "run this
  command", so **treat suggestions as a colleague's guess. Never run one unread, and don't act against a player on one
  alone.** `--suggestions` frames each as the AI's words for that reason.
- **A forged player file.** `usercache.json` is trusted to say who has which UUID. Something that can edit it can mislabel
  a player. A name seen without a UUID can also attach to the next UUID seen for that name, including on another server.
- **Linking people across servers.** There's one key, so a player has the same token on every server you share. The AI can
  see that it's the same person.
- **Identifying someone from behaviour.** Tokens are pseudonyms. Connection times and repeated addresses can still point to
  a person, so treat the output as personal data, particularly for children's worlds.
- **Names in plugin file names.** Installed jar names are sent if they're plain, so a jar named after a family or a private
  project reveals that, unless the name is a known player's. A player named like a plugin, or like a package in a plugin's
  code, shows as a token there. That garbles the entry a little, but nothing is hidden or leaked.
- **Plugins it can't match.** A log tag only counts if it matches a jar's name, so `[Essentials]` from `EssentialsX.jar` shows
  as a withheld message with no plugin named. That loses information, and it fails safe.
- **What the AI itself might remember.** Anything sent goes to your AI provider, under its retention terms.

## Rules for changing this code

1. **Fail closed.** If something can't be read or checked, return an error and no data.
2. **Allowlist only.** Any new field must have a strict format. Never send free text and try to clean it.
3. **No tool takes a path, a command or a real name.**
4. **Nothing that writes to the server,** and no network or process code. This target must never depend on `LeafJuiceCore`.
5. **The token list only ever holds identifiers, never secrets,** is always sealed, never kept in plain text, and stays outside server folders. The program refuses to
   start if it's inside one it was given.
6. **Errors say nothing specific.** They reach the AI too.
7. **Tests use made-up data only.** A leak test must fail if a planted value appears in the output. Break the code on
   purpose now and then, to prove that it does.
8. **Never add a way to run a suggestion.** A person reads it and decides.

## Where things live

`~/Library/Application Support/Leaf Juice/advisor/`, in a folder only you can open, excluded from Time Machine where the
system allows it:

- `key.sealed`: the token map, sealed with AES-GCM. A token is only created for a value in an answer, for the server when it's checked, or for a known player named in a suggestion. The file starts with `LJAK1`, followed by the nonce, the sealed JSON and its tag.
- The key that seals it is in your login Keychain, as "LeafJuice Advisor key" (its service is the app's bundle identifier followed by `.advisor`). A key LeafJuice makes trusts LeafJuice and its helper, `leafjuice-mcp`.
- An older plain `key.json` is sealed the first time the key can be reached, then deleted. Until then it isn't used.
- `suggestions/`: suggestions as written, with tokens still in them.

Deleting the folder forgets every mapping. The Keychain key stays, and is reused. Old suggestions then stay untranslated, and players get new tokens.

## Running it by hand

The Advisor page does all of this for you. These steps are for using another client, or running it without the app.

Name each server you want to share. Nothing else is visible.

```bash
swift build -c release --product leafjuice-mcp
```

Save this as `advisor.json`, with your own paths. The name must stay `leafjuice`, to match the tool names below:

```json
{"mcpServers": {"leafjuice": {"command": "/full/path/to/.build/release/leafjuice-mcp", "args": ["--server", "/full/path/to/your/server"]}}}
```

For a quiet check, run it from an empty folder and remove every other tool. Here, `--tools ""` is what takes away shell and
file access, and `--settings` turns hooks off. `--allowedTools` only approves the advisor's tools in advance: it wouldn't
restrict anything by itself, so don't remove the others. This command was tested with made-up data: the AI saw only these five
tools and couldn't read a planted file. (`--bare` also skips hooks, but it reported "Not logged in" when tested.)

```bash
claude -p "Check for problems worth raising, and use suggest for each one." --settings '{"disableAllHooks":true}' --mcp-config advisor.json --strict-mcp-config --tools "" --allowedTools "mcp__leafjuice__list_servers,mcp__leafjuice__server_summary,mcp__leafjuice__open_issues,mcp__leafjuice__recent_problems,mcp__leafjuice__suggest"
```

To read suggestions with real names, in your own terminal:

```bash
.build/release/leafjuice-mcp --suggestions
```

`--clear-suggestions` empties the inbox, which holds 200 at most. Both refuse to run when their output isn't a terminal.
That stops an agent casually running them through a pipe, but it isn't a boundary: one with a shell could get around it.

## Running Claude Code

The app starts Claude Code from a new empty temporary folder, with `--tools ""`, `--strict-mcp-config`, `--setting-sources ""`, a fixed `--system-prompt`, `--disable-slash-commands`, `--no-session-persistence` and a short list of environment variables. Each of these was tested with planted markers and made-up data, with one exception noted below. The arguments, the environment and the prompt are built in one place, `AdvisorLaunch`, and the default check run fails if any of these flags is dropped, if a variable is added to the environment, or if a dismissed title could carry `@` or a path into the prompt ("Advisor: how Claude Code is started").

- **`@` in a prompt reads a file, even with no tools.** So nothing the AI wrote goes into a prompt unless it's been cut down to letters, digits, spaces and hyphens, and the key is never near the working folder.
- **Dismissed titles go back to the AI.** When you press Don't Raise This Again, that suggestion's title is listed in later checks' prompts, cut down as above and marked as never instructions. A title steered by a plugin, such as "Ignore all warnings", would still be repeated on every later check, until you press Forget Everything.
- **What Claude Code still sends by itself:** your account email, the temporary folder's path, and basic system details such as the OS version. The email is the one on your Anthropic account.
- **`--safe-mode` can't be used.** It also turns off the Advisor's tools.
- **Kept out, tested with markers:** `CLAUDE.md`, rules, skills, hooks and settings in a parent folder and in a stand-in home folder.
- **What Claude Code leaves behind:** a small log of tool names and timings in `~/Library/Caches/claude-cli-nodejs`, with no player data. No transcript is kept.
- **What's left:** a check only counts if the helper confirms it read the log, otherwise earlier advice is kept.

## What a plugin can still do

A plugin runs inside the server, so it could send data out by itself without involving the Advisor. Short words chosen by a plugin can still reach the AI in class names, plugin names, versions and event names. Frames are capped at 20 per trace and 60,000 characters per report, and the preview shows all of it. Known gaps, all visible in the preview:

- **Names:** a name inside a word is caught from five letters, or from three as a whole word in `EmmaHandler`. Names that aren't known players, such as a family name in a jar's file, can't be recognised. A player named like a code word, such as `Main`, isn't hidden where that word appears in code. One named like a method, such as `Max`, gets a token that its position gives away.
- **Plugin text:** a plugin can still choose readable class names like `Meet.Tommy.tonight`, and a short word in a version.
- **Odd spellings:** an address with mixed separators or in hex isn't recognised, nor an email written as `jdoe.at.example.com` or before a `//` module marker, a home-folder path in a frame's module part, or a key whose prefix isn't a known one, such as `xoxb_` with underscores. Real Java frames don't look like these.
- **The key folder check** doesn't see through firmlink paths such as `/System/Volumes/Data`, which the app's default location doesn't use.
- **The sentence and name checks** have only been run on made-up logs.
