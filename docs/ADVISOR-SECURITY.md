# Advisor: security rules

`leafjuice-mcp` lets an AI client look at a server and leave suggestions. It's a separate program. The Leaf Juice app
doesn't load it, link it or know it exists, so the app's "no AI at runtime" rule still holds.

## The main rule

**Log wording isn't passed on.** The first version filtered free text, and an independent review broke it easily: chat
in many formats, secrets in many formats, and one chat message that switched off the password filter. So filtering isn't the
design any more. Each log line either matches a fixed shape and is rewritten from the parts that were recognised, or its
text is withheld and only counted.

**The exception is code-shaped text**, which a plugin's author controls. Stack frames, exception classes, plugin names and
versions, and jar names are limited in form, but not to what's true. See below.

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
| Chat or commands reach the AI | Log wording isn't sent at all, from either the log or stored issues |
| Player names, UUIDs and IPs reach the AI | Tokens, used only in fixed shapes where the value's position is known |
| Secrets reach the AI | No free text is sent, and plugin configs aren't readable. `server.properties` is an allowlist of keys and values |
| Chat forges an identity or changes a filter | Names come only from the server's own player files and from exact line shapes on the right thread. Only the authenticator thread and `usercache.json` can tie a name to a UUID |
| The AI changes or breaks the server | There's no tool for it, and the program doesn't link `LeafJuiceCore` or use network or process APIs. A test checks the source |
| The AI reads files it shouldn't | No tool takes a path. Only servers named at launch are visible, and a symlink anywhere inside a server folder, or a hard link, is refused. The folder you name may itself be reached through a link |
| The AI recovers a real name from a token | No tool translates tokens. Only `--suggestions` does, for a person at a terminal |
| Tokens are reversed by guessing | They're random, not derived from the value |
| A long line hangs the program | Over-long lines are withheld before any pattern runs, and suggestions are cut to a fixed length first |
| A safeguard fails silently | A damaged, oversized or linked key, player or issues file stops the answer, and so does a server folder that's gone. A key deleted while running is treated as a fresh start, so players get new tokens |

## What it does not protect against

- **An agent that also has shell or file access.** This is the big one. Claude Code running as you can read `~/Minecraft`
  and the key file directly, and nothing in this program can stop that. **Without the restriction shown below, the privacy
  layer is not a security boundary.**
- **Other programs running as you.** The key file is readable only by your user, but it isn't encrypted.
- **A malicious or careless plugin.** Plugin code runs inside your server, so it's already trusted with far more than this.
  It can write fake frames, up to the limits, and short phrases fit in identifiers such as `Ignore.previous.rules.now`.
  Frames holding a known player's name, a UUID, an IP or an email are dropped, but other identifying text in code form would
  pass, and an unknown player's name wouldn't be recognised. A report is limited to 60,000 characters.
- **Bad advice.** The AI may be wrong, or tricked by the above. A suggestion can name a real player and can say "run this
  command", so **treat suggestions as a colleague's guess. Never run one unread, and don't act against a player on one
  alone.** `--suggestions` frames each as the AI's words for that reason.
- **A forged player file.** `usercache.json` is trusted to say who has which UUID. Something that can edit it can mislabel
  a player. A name seen without a UUID can also attach to the next UUID seen for that name.
- **Identifying someone from behaviour.** Tokens are pseudonyms. Connection times and repeated addresses can still point to
  a person, so treat the output as personal data, particularly for children's worlds.
- **Names in plugin file names.** Installed jar names are sent if they're plain, so a jar named after a family or a private
  project reveals that, unless the name is a known player's. A player named like a plugin garbles that plugin's entry.
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

## Running it

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
