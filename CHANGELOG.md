# v19

- The shared LuaJIT code cache now starts at 64 MB of machine code instead of 16 MB and can grow to 256 MB after a flush; code space is only used as code is compiled, so this costs nothing until it is needed.
- The loader log now starts with the time the game started, the game's build stamps, and the Lua heap, garbage collector and JIT settings before any mod loads.
- The log reports how the previous session's log ended, including the module that was still loading if the game stopped during startup.
- The log names the newest crash dump's time, exception code and faulting module offset, never its file name, which contains the computer name.
- Each loaded module gets a "changes" line with its load time and heap growth, plus any globals, library functions, metatables, garbage collector or JIT settings it added, replaced or removed.
- The log is written before each module starts, so a session that stops inside a module's startup leaves that module marked "loading".
- The log ends with "Startup finished: N loaded, N failed".
- The "LuaJIT cache" line says "watcher replaced" when another mod's `jit.attach` has replaced the loader's trace watcher.
- The loader calls its Windows functions under private names, so another mod's declarations of the same functions can no longer disable the loader's logs or discovery.
- The plain Windows declarations v18 made for other mods are kept, at the same moments, so mods see the same functions and prototypes as under v18.
- The loader keeps its own copies of the Lua builtins it uses, so a mod that replaces `tostring`, `print` or `io.open` cannot change how later mods are loaded or reported.
- Discovery warnings name the archive file only, not its full path.
- When more than one deployed archive holds the same mod entry, the log now names the archive whose copy the game loads and up to six hidden ones, under that module's status, which still reads `loaded`.
- A declared addon hidden by a higher compiled or undeclared copy is still not started, but the log now says so and names both archives.
- Hidden copies are read only for those log lines: if such a read fails, the copy is listed as unreadable and discovery goes on exactly as before.
- `CowboyBingusModLoader.version` stays 17, because nothing other mods rely on changed; the new `revision` field reads `loader-v19`.
- New read-only `CowboyBingusModLoader.capabilities` (`api`, `logs`, `discovery`, `jit_budget`, `health`) lets mods test for a loader feature instead of comparing `version`.
- The author guide now lists the six Windows functions the loader declares under plain names for v18 compatibility, the rule to declare functions and types under private names, the startup order, the copies lines and `capabilities`.
- A new test compares what other mods can observe (fields, module statuses, declared Windows functions and prototypes, update chain, printed lines, log statuses) with the published v18 package in eleven scenarios, two with discovery working over copies of the same entries, one of them with unreadable copies.
- The health report is never JIT-compiled, so it adds no machine code to the code cache that the game and every mod share.
- Discovery is never JIT-compiled either; in a test with 22 archives its startup scan had left about 3 KB of machine code in that cache.
- All of this runs once while the game starts; there is still no per-frame work. Unmeasured in game.
- New `CowboyBingusModLoader.after_startup(fn)`: `fn` runs once after every mod of this startup has started, registry and discovered addons alike, and before the first game update; registered later, it runs at once.
- Mods can now register with Mod Options Menu or Mod Bindings Menu from `after_startup` once, instead of polling, whatever the manager's order; `capabilities.after_startup` says the loader supports it.
- Callbacks run one at a time in registration order, each under pcall; a callback's error is logged once with the mod that registered it and never reaches other code.
- A callback registered from inside another waits for it to finish; at most 256 callbacks run per session, so a callback that keeps registering itself cannot hold the game in its startup.
- When callbacks were registered, the log adds "After startup: N callbacks run, N failed" and one line per error, and the next session's "Previous session" line says if the game stopped inside a callback.
- The contract test lists `after_startup` as an added field; the eleven v18 scenarios are otherwise unchanged.
- The build's `runtime_verified` flag is now set only by `scripts/pin_tested.py`, from a clean TestHarness run that deployed the exact release ZIP, and only for the resource the current sources build.
- New third-party reference for other mod authors: the loader contract, start order, every CowboyBingus log, settings file and global (retired names included), and the shared menus, input and game state each mod uses.
- Development-only `--probe` build (frame probe schema 4) for the real-play study; it is never published and the release build is unchanged.
- Licensed under the Zero-Clause BSD license (0BSD): use, change and share it without conditions.

# v18

- Raise the game's shared LuaJIT code cache before any mod starts: 16 MB of machine code and 8,000 traces instead of the game's 512 KB and 1,000, shared by the game and every mod. Filling either limit made LuaJIT discard all compiled code at once and recompile it during play.
- If a flush still happens, double both limits, up to 64 MB and 16,000 traces; the trace limit only grows while the Lua heap is under 24 MB.
- Measured in recorded real play with every Vanilla Plus Megapack mod enabled (19 minutes aboard the ship and an 11-minute mission): the old 512 KB was already full aboard the ship, the session ended at 960 KB of machine code in 946 traces, and the cache never flushed.
- The loader log shows one "LuaJIT cache" line with the limits, flushes and growth steps; mods can read the same state from `CowboyBingusModLoader.jit`.
- Required update for every CowboyBingus mod: replace the previous loader entry, then Purge / Deploy. No per-frame work and no gameplay change; API 1, addon discovery and the original audio callbacks are unchanged. This removes repeated recompilation, not a promised frame-rate change, which depends on the machine.

# v17

- Support Steam build 25480438 with updated game-module fingerprints.
- Preserve API 1, addon discovery and the original audio callbacks.
- Offline builds and package checks pass; live gameplay validation remains pending.

# v16

- Update compatibility for game build 25327279.
- Keep existing addon discovery, shared logs and audio callbacks working.

# v15

- Discovers explicitly declared addon entries across author namespaces without registry edits.
- Preserves API 1, legacy module order, shared logs and manager package identity.
- Adds a single-script author packaging helper and discovery regression coverage.
- Includes a minimal example mod and author documentation.

# v14

- Creates one shared folder for all updated CowboyBingus mod logs.
- Keeps mod startup working if the log folder or a log file cannot be written.
- Stores logs in `%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs`.
