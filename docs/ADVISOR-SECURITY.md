# Advisor: security rules

`leafjuice-mcp` lets an AI client look at a server and leave suggestions. It's a separate read-only program. In the app, the
optional **Advisor** page runs it with Claude Code. That page is off until you turn it on in Settings, each server has to be
shared separately, and nothing is sent until you check or turn on automatic checks. With it off, the app contains no AI and
starts none. The app starts Claude Code with every other tool removed, so the shell-access warning below doesn't apply to
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

Reads also write to the key file, when a player or address is first shared.

## What it protects against

| Threat | Defence |
|---|---|
| Chat or commands reach the AI | Log wording isn't sent, from either the log or stored issues. One gap: the app stores a stack line from any thread, so unusual chat formatted exactly like a frame could reach `open_issues`, limited to that shape |
| Player names, UUIDs and IPs reach the AI | Tokens in fixed shapes. In code-shaped text, a known player's name becomes a token wherever it sits, except for common code words such as `server`, which say nothing about anyone. An address, UUID, email or known key format drops the line, however it's written. Jars and frames that read like sentences are dropped too. World and settings file names are sent only if they're standard |
| Secrets reach the AI | No free text is sent, and plugin configs aren't readable. `server.properties` is an allowlist of keys and values |
| Chat forges an identity or changes a filter | Names come only from the server's own player files and from exact line shapes on the right thread. Only the authenticator thread and `usercache.json` can tie a name to a UUID. A plugin can forge that thread: see below |
| The AI changes or breaks the server | There's no tool for it, and the program doesn't link `LeafJuiceCore` or use network or process APIs. A test checks the source |
| The AI reads files it shouldn't | No tool takes a path. Only servers named at launch are visible, and a symlink anywhere inside a server folder, or a hard link, is refused. The folder you name may itself be reached through a link |
| The AI recovers a real name from a token | No tool translates tokens. Only `--suggestions` does, for a person at a terminal |
| Tokens are reversed by guessing | They're random, not derived from the value |
| A long line hangs the program | Over-long lines are withheld before any pattern runs, and suggestions are refused or cut to a fixed length first. A flood of new players can still make an answer take many seconds |
| A safeguard fails silently | A damaged, oversized or linked key stops every answer. So does a damaged, oversized or linked player or issues file when that answer reads it, and a server folder that's gone. A key deleted while running is treated as a fresh start, so players get new tokens |

## What it does not protect against

- **An agent that also has shell or file access.** This is the big one. Claude Code running as you can read `~/Minecraft`
  and the key file directly, and nothing in this program can stop that. **Without the restriction shown below, the privacy
  layer is not a security boundary.**
- **Other programs running as you.** The key file is readable only by your user, but it isn't encrypted.
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
5. **The key file only ever holds identifiers, never secrets,** and stays outside server folders. The program refuses to
   start if it's inside one it was given.
6. **Errors say nothing specific.** They reach the AI too.
7. **Tests use made-up data only.** A leak test must fail if a planted value appears in the output. Break the code on
   purpose now and then, to prove that it does.
8. **Never add a way to run a suggestion.** A person reads it and decides.

## Where things live

`~/Library/Application Support/Leaf Juice/advisor/`, in a folder only you can open, excluded from Time Machine where the
system allows it:

- `key.json`: the token map. A token is only created for a value in an answer, or for a known player named in a suggestion.
- `suggestions/`: suggestions as written, with tokens still in them.

Deleting the folder forgets every mapping. Old suggestions then stay untranslated, and players get new tokens.

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

The app starts Claude Code from a new empty temporary folder, with `--tools ""`, `--strict-mcp-config`, `--setting-sources ""`, a fixed `--system-prompt`, `--disable-slash-commands`, `--no-session-persistence` and a short list of environment variables. Each of these was tested with planted markers and made-up data, with one exception noted below.

- **`@` in a prompt reads a file, even with no tools.** So nothing the AI wrote goes into a prompt unless it's been cut down to letters, digits, spaces and hyphens, and the key is never near the working folder.
- **What Claude Code still sends by itself:** your account email, the temporary folder's path, and basic system details such as the OS version. The email is the one on your Anthropic account.
- **`--safe-mode` can't be used.** It also turns off the Advisor's tools.
- **Not tested:** a `CLAUDE.md` in `~/.claude` under `--setting-sources ""`. A planted one in a parent folder was kept out.
- **What's left:** a check only counts if the helper confirms it read the log, otherwise earlier advice is kept.

## What a plugin can still do

A plugin runs inside the server, so it could send data out by itself without involving the Advisor. Short words chosen by a plugin can still reach the AI in class names, plugin names, versions and event names. Frames are capped at 20 per trace and 60,000 characters per report, and the preview shows all of it. A name spliced into a word is only caught from five letters, and a player named exactly like a plugin or a code word shows up as a token in that position, or not at all.
