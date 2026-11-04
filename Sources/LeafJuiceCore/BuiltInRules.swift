// The built-in knowledge base. Plain data, so adding a rule never means touching logic.
// `samples` are real-format log messages that the test suite checks each rule against.
// Order matters: the first matching rule wins, so put specific rules before general ones.
let builtInRulesJSON = #"""
[
  {
    "id": "java-class-version", "title": "This Java is too old for the server or a plugin", "severity": "critical", "category": "Java",
    "contains": ["unsupportedclassversionerror", "has been compiled by a more recent version of the java runtime"],
    "explanation": "The jar was built for a newer Java than the one running it. Class file version minus 44 gives the Java version it needs: 65 is Java 21, 69 is Java 25.",
    "steps": ["Open Launch and choose a newer Java, or download one there.", "If this names a single plugin rather than the server, that plugin may need a newer Java than your server does."],
    "action": {"page": "launch", "label": "Open Launch"},
    "samples": ["java.lang.UnsupportedClassVersionError: io/papermc/paperclip/Main has been compiled by a more recent version of the Java Runtime (class file version 69.0), this version of the Java Runtime only recognizes class file versions up to 65.0"]
  },
  {
    "id": "java-required", "title": "The server requires a different Java", "severity": "critical", "category": "Java",
    "regex": "requires running the server with java|unsupported java detected|java version .* (is|are) no longer supported",
    "explanation": "The server refused to start on this Java version.",
    "steps": ["Open Launch and choose the Java it asks for, or download one there."],
    "action": {"page": "launch", "label": "Open Launch"},
    "samples": ["**** Unsupported Java detected (68.0). Only up to Java 25 is supported."]
  },
  {
    "id": "jvm-option", "title": "Java rejected a startup flag", "severity": "critical", "category": "Java",
    "contains": ["unrecognized vm option", "unrecognized option:", "could not create the java virtual machine"],
    "explanation": "One of the JVM flags isn't valid for this Java version. Flags can be removed between releases.",
    "steps": ["Check your extra JVM arguments on the Launch page for typos.", "Switch the flags preset to Recommended to compare."],
    "action": {"page": "launch", "label": "Open Launch"},
    "samples": ["Unrecognized VM option 'UseFooBar'", "Error: Could not create the Java Virtual Machine."]
  },
  {
    "id": "jvm-memory-reserve", "title": "Java couldn't reserve the requested memory", "severity": "critical", "category": "Memory",
    "contains": ["could not reserve enough space", "invalid maximum heap size", "initial heap size set to a larger value"],
    "explanation": "The memory settings can't be met. Maximum memory may exceed what's available, or minimum may be above maximum.",
    "steps": ["Lower maximum memory on the Launch page.", "Make sure minimum memory isn't higher than maximum."],
    "action": {"page": "launch", "label": "Open Launch"},
    "samples": ["Error occurred during initialization of VM: Could not reserve enough space for 33554432KB object heap", "Initial heap size set to a larger value than the maximum heap size"]
  },
  {
    "id": "native-thread", "title": "Java couldn't start a new thread", "severity": "error", "category": "Memory",
    "contains": ["unable to create native thread"],
    "explanation": "The system refused another thread. This usually means a plugin is creating threads without limit.",
    "steps": ["Look for plugins named in the stack trace.", "Disable recently added plugins one at a time."],
    "action": {"page": "plugins", "label": "Open Plugins"},
    "samples": ["java.lang.OutOfMemoryError: unable to create native thread: possibly out of memory or process/resource limits reached"]
  },
  {
    "id": "oom-heap", "title": "The server ran out of memory", "severity": "critical", "category": "Memory",
    "contains": ["java.lang.outofmemoryerror: java heap space", "outofmemoryerror: gc overhead", "java.lang.outofmemoryerror"],
    "explanation": "The game needed more memory than maximum memory allows. The server is usually unstable after this and should be restarted.",
    "steps": ["Raise maximum memory on the Launch page.", "Lower view-distance in server.properties.", "If it keeps rising until it fails no matter the size, a plugin may be leaking memory. Paper's /spark plugin can show which."],
    "action": {"page": "launch", "label": "Open Launch"},
    "samples": ["java.lang.OutOfMemoryError: Java heap space"]
  },
  {
    "id": "jar-missing", "title": "The server jar couldn't be opened", "severity": "critical", "category": "Software",
    "contains": ["unable to access jarfile", "invalid or corrupt jarfile"],
    "explanation": "The jar is missing, or is damaged from an incomplete download.",
    "steps": ["Download it again on the Software page."],
    "action": {"page": "software", "label": "Open Software"},
    "samples": ["Error: Unable to access jarfile paper.jar", "Error: Invalid or corrupt jarfile paper.jar"]
  },
  {
    "id": "eula", "title": "The Minecraft EULA hasn't been accepted", "severity": "critical", "category": "Setup",
    "contains": ["you need to agree to the eula", "failed to load eula.txt"],
    "explanation": "Minecraft servers won't start until their owner accepts Mojang's End User License Agreement.",
    "steps": ["Press Start. Leaf Juice will show the agreement and let you accept it."],
    "samples": ["You need to agree to the EULA in order to run the server. Go to eula.txt for more info."]
  },
  {
    "id": "port-bound", "title": "The server's port is already in use", "severity": "critical", "category": "Network",
    "contains": ["failed to bind to port", "address already in use"],
    "explanation": "Another program, often another server or a leftover copy of this one, is using this port.",
    "steps": ["Stop the other server, or quit whatever is using the port.", "Or change server-port in server.properties."],
    "action": {"page": "configs", "label": "Open Configs"},
    "samples": ["**** FAILED TO BIND TO PORT!", "java.net.BindException: Address already in use"]
  },
  {
    "id": "session-lock", "title": "The world is already open elsewhere", "severity": "critical", "category": "World",
    "regex": "session\\.lock|sessionlock|failed to check session lock|directorylock",
    "explanation": "Another copy of this server is running from this folder, or one stopped uncleanly without releasing the lock.",
    "steps": ["Check Activity Monitor for another java process.", "If none is running, starting again normally clears this."],
    "samples": ["net.minecraft.util.DirectoryLock$LockException: /srv/world/session.lock: already locked (possibly by other Minecraft instance?)"]
  },
  {
    "id": "world-newer", "title": "This world is from a newer Minecraft version", "severity": "critical", "category": "World",
    "regex": "newer version of minecraft|tried to load .*newer|server attempted to load chunk saved with newer version|world (was )?(last )?(saved|played) (in|with|on) .*newer",
    "explanation": "Worlds can't be opened by older versions. Forcing this can destroy data.",
    "steps": ["Switch back to the version the world was last run on, on the Software page.", "Or restore a backup made before the upgrade."],
    "action": {"page": "backups", "label": "Open Backups"},
    "samples": ["Server attempted to load chunk saved with newer version of minecraft! 4671 > 4325"]
  },
  {
    "id": "world-corrupt", "title": "Damaged world data", "severity": "error", "category": "World",
    "regex": "failed to read chunk|couldn't load chunk|couldn't read chunk|chunk file at .* is in the wrong location|region file .*corrupt|recreating region|failed to (read|load) (the )?level\\.dat|exception reading .*level\\.dat|chunk .* (is|was) corrupt",
    "explanation": "Part of a world file couldn't be read. Common causes are a power loss, a forced stop or a failing disk. Minecraft may regenerate the affected chunks.",
    "steps": ["Stop the server and take a backup of the current state.", "Restore an earlier backup if the damage matters to you.", "Check free disk space and drive health."],
    "action": {"page": "backups", "label": "Open Backups"},
    "samples": ["Couldn't load chunk [12, -4]", "Chunk file at [1, 2] is in the wrong location; relocating."]
  },
  {
    "id": "disk-full", "title": "The disk is full", "severity": "critical", "category": "System",
    "contains": ["no space left on device"],
    "explanation": "Without free space the server can't save, which risks losing or damaging the world.",
    "steps": ["Stop the server and free up disk space.", "Lower how many backups are kept, or move them to another drive."],
    "action": {"page": "backups", "label": "Open Backups"},
    "samples": ["java.io.IOException: No space left on device"]
  },
  {
    "id": "open-files", "title": "Too many open files", "severity": "error", "category": "System",
    "contains": ["too many open files"],
    "explanation": "The server hit macOS's limit on open files. This is often caused by a plugin that doesn't close files or connections.",
    "steps": ["Restart the server.", "If it returns, look for a recently added plugin."],
    "samples": ["java.io.FileNotFoundException: plugins/foo.yml (Too many open files)"]
  },
  {
    "id": "watchdog", "title": "The server froze", "severity": "critical", "category": "Performance",
    "regex": "the server has stopped responding|a single server tick took|watchdog thread|paper watchdog",
    "explanation": "The main game thread stopped making progress long enough for the watchdog to step in. The stack trace below this line usually names what it was stuck on.",
    "steps": ["Look in the stack trace for a plugin's package name.", "Slow disks and very large chunk operations can also cause this.", "max-tick-time in server.properties controls when the watchdog acts."],
    "samples": ["The server has stopped responding! This is (probably) not a Paper bug.", "A single server tick took 60.00 seconds (should be max 0.05)"]
  },
  {
    "id": "cant-keep-up", "title": "The server is falling behind", "severity": "warning", "category": "Performance",
    "contains": ["can't keep up!"],
    "explanation": "A tick took longer than it should. An occasional message at startup or during world generation is normal. Frequent ones mean players will feel lag.",
    "steps": ["Lower simulation-distance and view-distance.", "Check the CPU figure on Overview. If it's maxed out, the Mac itself may be busy.", "Install the spark plugin to find what's slow."],
    "action": {"page": "configs", "label": "Open Configs"},
    "samples": ["Can't keep up! Is the server overloaded? Running 5012ms or 100 ticks behind"]
  },
  {
    "id": "plugin-unknown-dependency", "title": "{subject} is missing a plugin it needs", "severity": "error", "category": "Plugins",
    "regex": "could not load '?plugins[/\\\\](?<subject>[^']+?)'?.*(unknown ?dependency|unknown/missing dependency)|unknowndependencyexception",
    "explanation": "This plugin needs another plugin that isn't installed, so it wasn't loaded.",
    "steps": ["Check the plugin's page for what it requires.", "Install the missing plugin on the Plugins page."],
    "action": {"page": "plugins", "label": "Open Plugins"},
    "samples": ["Could not load 'plugins/Foo.jar' in folder 'plugins': Unknown/missing dependency plugins: [Vault]"]
  },
  {
    "id": "plugin-unsupported-api", "title": "{subject} targets a newer Minecraft", "severity": "error", "category": "Plugins",
    "regex": "could not load '?plugins[/\\\\](?<subject>[^']+?)'?.*unsupported api version|unsupported api version",
    "explanation": "This plugin declares an api-version newer than this server, so it won't load.",
    "steps": ["Install an older build of the plugin, or upgrade the server on the Software page."],
    "action": {"page": "plugins", "label": "Open Plugins"},
    "samples": ["Could not load 'plugins/Foo.jar' in folder 'plugins': Unsupported API version 26.3"]
  },
  {
    "id": "plugin-load-failed", "title": "{subject} failed to load", "severity": "error", "category": "Plugins",
    "regex": "could not load '?plugins[/\\\\](?<subject>[^']+?)'? in folder|error loading plugin '?(?<x>[^' ]+)|invalid plugin\\.yml|jar does not contain plugin\\.yml",
    "explanation": "The server couldn't load this jar. It may be damaged, or not a plugin at all. Mods for Fabric or Forge won't load on Paper.",
    "steps": ["Check the error beneath this line for the reason.", "Download the plugin again from its source."],
    "action": {"page": "plugins", "label": "Open Plugins"},
    "samples": ["Could not load 'plugins/Foo.jar' in folder 'plugins'", "org.bukkit.plugin.InvalidDescriptionException: Invalid plugin.yml"]
  },
  {
    "id": "plugin-ambiguous", "title": "Two jars contain the same plugin", "severity": "warning", "category": "Plugins",
    "contains": ["ambiguous plugin name"],
    "explanation": "Two jars declare the same plugin name, usually an old version left behind after an update. Only one will load, and it may not be the one you want.",
    "steps": ["Remove the older jar on the Plugins page."],
    "action": {"page": "plugins", "label": "Open Plugins"},
    "samples": ["Ambiguous plugin name `Foo' for files `plugins/Foo-1.jar' and `plugins/Foo-2.jar' in `plugins'"]
  },
  {
    "id": "plugin-enable-failed", "title": "{subject} crashed while starting", "severity": "error", "category": "Plugins",
    "regex": "error occurred while enabling (?<subject>[^ ]+)",
    "explanation": "The plugin hit an error during startup and was probably disabled. The stack trace shows why. Missing settings and version mismatches are common.",
    "steps": ["Check for an update to this plugin.", "Check its config file for mistakes.", "Report the stack trace to its author."],
    "action": {"page": "plugins", "label": "Open Plugins"},
    "samples": ["Error occurred while enabling Foo v1.2 (Is it up to date?)"]
  },
  {
    "id": "plugin-event", "title": "{subject} threw an error handling an event", "severity": "error", "category": "Plugins",
    "regex": "could not pass event [^ ]+ to (?<subject>[^ ]+)",
    "explanation": "A plugin failed while reacting to something in the game. The server keeps running, but the feature may misbehave.",
    "steps": ["Check for an update to this plugin.", "Report the stack trace to its author."],
    "action": {"page": "plugins", "label": "Open Plugins"},
    "samples": ["Could not pass event PlayerJoinEvent to Foo v1.0"]
  },
  {
    "id": "plugin-task", "title": "{subject} threw an error in a scheduled task", "severity": "error", "category": "Plugins",
    "regex": "task #\\d+ for (?<subject>[^ ]+) .*generated an exception",
    "explanation": "A plugin's background task failed. It may run again and repeat this error.",
    "steps": ["Check for an update to this plugin.", "Report the stack trace to its author."],
    "action": {"page": "plugins", "label": "Open Plugins"},
    "samples": ["Task #1234 for Foo v1.0 generated an exception"]
  },
  {
    "id": "plugin-command", "title": "A plugin command failed", "severity": "error", "category": "Plugins",
    "regex": "unhandled exception executing command|null executing command",
    "explanation": "A command crashed in the plugin that handles it. The stack trace names the plugin.",
    "steps": ["Check for an update to that plugin."],
    "action": {"page": "plugins", "label": "Open Plugins"},
    "samples": ["Unhandled exception executing command 'foo' in plugin Foo v1.0"]
  },
  {
    "id": "plugin-class-mismatch", "title": "A plugin doesn't match this server version", "severity": "error", "category": "Plugins",
    "contains": ["nosuchmethoderror", "nosuchfielderror", "noclassdeffounderror", "classnotfoundexception", "incompatibleclasschangeerror", "abstractmethoderror"],
    "explanation": "Code was looking for something that doesn't exist in this server version. This typically means a plugin built for another Minecraft version, or a missing library plugin.",
    "steps": ["Check the stack trace for the plugin's package name.", "Update that plugin, and its dependencies.", "Run Upgrade Readiness on the Software page before changing versions."],
    "action": {"page": "plugins", "label": "Open Plugins"},
    "samples": ["java.lang.NoSuchMethodError: 'void org.bukkit.Foo.bar()'", "Caused by: java.lang.ClassNotFoundException: net.milkbowl.vault.economy.Economy"]
  },
  {
    "id": "plugin-legacy", "title": "A plugin uses the old Bukkit API", "severity": "info", "category": "Plugins",
    "regex": "legacy plugin .* does not specify an api-version|initializing legacy material support",
    "explanation": "An old plugin doesn't declare an api-version, so the server loads a slower compatibility layer. It usually works, but may be abandoned.",
    "steps": ["Look for an updated version or a maintained alternative."],
    "action": {"page": "plugins", "label": "Open Plugins"},
    "samples": ["Legacy plugin Foo v1.0 does not specify an api-version.", "Initializing Legacy Material Support. Unless you have legacy plugins and/or data this is a bug!"]
  },
  {
    "id": "plugin-nag", "title": "A plugin triggered a developer warning", "severity": "info", "category": "Plugins",
    "regex": "nag author\\(?s?\\)?:|is accessing the main thread|was loaded with an outdated",
    "explanation": "The server spotted something a plugin shouldn't do. It's usually harmless, and meant for the plugin's author.",
    "steps": ["Check for an update to the plugin. Otherwise this is safe to ignore."],
    "samples": ["Nag author(s): '[Someone]' of 'Foo v1.0' about the following: Blah"]
  },
  {
    "id": "reload-used", "title": "/reload was used", "severity": "warning", "category": "Plugins",
    "regex": "are you sure you wish to reload|please note that this command is not supported|the server is being reloaded|server reload complete",
    "explanation": "/reload restarts plugins without restarting the server. Many plugins aren't built for this, which can cause memory leaks and strange errors until the next full restart.",
    "steps": ["Prefer a real restart. Leaf Juice can schedule one when the server is empty."],
    "action": {"page": "changes", "label": "Open Changes"},
    "samples": ["Please note that this command is not supported and may cause issues."]
  },
  {
    "id": "yaml-config", "title": "A config file has a syntax error", "severity": "error", "category": "Configuration",
    "regex": "cannot load .*\\.yml|invalidconfigurationexception|while parsing a block mapping|while scanning (a|an) |mapping values are not allowed|could not find expected|could not load .*\\.yml",
    "explanation": "A YAML file couldn't be read, often because of tabs, bad indentation or an unclosed quote. The server may have fallen back to defaults for it.",
    "steps": ["Open the named file on the Configs page.", "Check the line number in the error."],
    "action": {"page": "configs", "label": "Open Configs"},
    "samples": ["org.bukkit.configuration.InvalidConfigurationException: while parsing a block mapping", "Cannot load plugins/Foo/config.yml"]
  },
  {
    "id": "auth-servers", "title": "Couldn't reach Minecraft's account servers", "severity": "warning", "category": "Network",
    "regex": "authentication servers are down|couldn't verify username|failed to verify username|authentication unavailable|exception verifying",
    "explanation": "Players can't be verified when Mojang's services are down or your connection is. Usually this clears up by itself.",
    "steps": ["Check your internet connection.", "Check whether Minecraft services are having an outage."],
    "samples": ["Authentication servers are down. Please try again later, sorry!", "Exception verifying Notch"]
  },
  {
    "id": "offline-mode", "title": "The server isn't verifying accounts", "severity": "warning", "category": "Security",
    "regex": "server is running in offline/insecure mode|the server will make no attempt to authenticate",
    "explanation": "With online-mode off, anyone can join under any name, including an operator's. This is only safe behind a proxy like Velocity that verifies players itself.",
    "steps": ["Unless you run a proxy, set online-mode to true in server.properties."],
    "action": {"page": "configs", "label": "Open Configs"},
    "samples": ["**** SERVER IS RUNNING IN OFFLINE/INSECURE MODE!"]
  },
  {
    "id": "database", "title": "A database connection failed", "severity": "error", "category": "Network",
    "contains": ["communications link failure", "connection refused", "hikaripool", "access denied for user", "unable to obtain connection"],
    "explanation": "A plugin couldn't reach its database or another network service. The database may be down, or the plugin's settings may be wrong.",
    "steps": ["Check that the database is running.", "Check the address and password in the plugin's config."],
    "action": {"page": "configs", "label": "Open Configs"},
    "samples": ["com.mysql.cj.jdbc.exceptions.CommunicationsException: Communications link failure", "java.net.ConnectException: Connection refused"]
  },
  {
    "id": "version-behind", "title": "A newer server build is available", "severity": "info", "category": "Software",
    "regex": "you are (running )?\\d+ version\\(?s?\\)? behind|this server is running .* version .* is outdated|version is outdated|update your paper",
    "explanation": "The server itself noticed it's out of date.",
    "steps": ["Check the Software page for the latest build."],
    "action": {"page": "software", "label": "Open Software"},
    "samples": ["*** You are 12 version(s) behind ***"]
  },
  {
    "id": "experimental-build", "title": "This is an experimental build", "severity": "info", "category": "Software",
    "regex": "experimental build|this is an experimental|running an unsupported",
    "explanation": "This build hasn't reached the stable channel, so plugins may not support it and bugs are more likely.",
    "steps": ["Take regular backups, or return to the stable channel on the Software page."],
    "action": {"page": "software", "label": "Open Software"},
    "samples": ["This is an experimental build of Paper"]
  },
  {
    "id": "moved-too-quickly", "title": "A player moved too quickly", "severity": "info", "category": "Performance",
    "regex": "moved too quickly|moved wrongly",
    "explanation": "Common with lag or elytra and boats at speed. Rarely a concern unless constant, in which case it's either server lag or a cheat client.",
    "steps": ["If it's constant, check for lag on Overview."],
    "samples": ["Steve moved too quickly! 12.0,0.0,5.0"]
  },
  {
    "id": "entity-duplicate", "title": "Duplicate entity data", "severity": "info", "category": "World",
    "regex": "keeping entity .* that already exists with uuid|entity uuid already exists|uuid of added entity already exists",
    "explanation": "The same mob was found twice in world data, often after a crash. The server handles this by itself.",
    "steps": ["No action needed unless it's frequent."],
    "samples": ["Keeping entity minecraft:cow that already exists with UUID 1234"]
  }
]
"""#
