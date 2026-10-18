> Supports Steam build 25480438 / EXE 1.8.46015.0. Tested in game aboard the ship and in a mission.

![Bingus Shared Loader](assets/banner.png)

# Bingus Shared Loader

> [!IMPORTANT]
> **Required dependency for Armory Preview Cache, Know Your Constellation, Controllable Hover Pack, Vehicle Stability, Enemy Collision Synchronized, Vanilla Plus Megapack or the separate Better Stratagem Bounce, Hellpod Steering Unlocked, Reinforcement Beacons Fixed, Consistent Vaulting, Shallow Water Diving and Sentry Aim Retention mods.** Install with **Arsenal or HD2MM**: import `Bingus-Shared-Loader-v20.zip`, enable it alongside the megapack or your chosen mods, then click **Deploy**. One loader installation supports all your selected mods.
>
> **Arsenal (default priority): place Bingus Shared Loader LAST, at the bottom of the load order**, then **Purge / Deploy**. If you enabled first-mod priority, place the loader first instead.

**v20 / API 1** starts no mods on a game build it does not support (see [below](#game-updates)) and adds the LuaJIT churn guard: code that keeps failing to compile is no longer retried all session (see [below](#luajit-churn-guard)). Since v19 the loader starts the game's shared LuaJIT code cache at 64 MB of machine code (see [below](#shared-luajit-code-cache)), lets mods run their setup once after every mod has started (`after_startup`), protects loading, logs and discovery from other mods' changes to Lua builtins and Windows declarations, and writes a fuller startup log. It keeps automatic discovery for declared addon entries, all existing module registrations and shared logging. In two recorded missions of real play the cache never flushed (peak 1,344 KB of machine code). See [mod author instructions](docs/AUTHORING.md). Current standalone copies may remain installed alongside the pack. shared resource identities and per-mod guards prevent duplicate initialization. The loader remains a separate package.

Starts your installed CowboyBingus mods and supported third-party mods together. The loader has no gameplay effect by itself.

**Install:** Close Helldivers 2. Import `Bingus-Shared-Loader-v20.zip` and your chosen gameplay ZIPs into **HDArsenal** or **HD2MM**, enable them, and deploy. Keep the loader enabled while any dependent mod is enabled.

This is **v20 / API 1**, the recommended loader for every CowboyBingus mod (they need v18 or newer). Replace the previous loader entry, then **Purge / Deploy**. The manager GUID and runtime API marker are unchanged and `CowboyBingusModLoader.version` stays 17, so existing gameplay packages remain compatible. Do not install old and new loader copies together. See [installation](INSTALL.txt). This build passed a clean in-game run to the ship and a mission with every Vanilla Plus Megapack v42 option.

## Game updates

From v20 the loader checks the game build before it starts anything. On a build this release does not support, it starts no mods at all, third-party ones included, and the loader log says so with both game hashes. After a game update your mods stay off until a loader release adds the new build; then update the loader. Nothing turns this check off. Mod authors: see [Startup and compatibility](docs/AUTHORING.md#supported-game-builds-v20).

## Shared LuaJIT code cache

Helldivers 2 runs every Lua mod in the game's own LuaJIT 2.1.0-alpha, which keeps its 2015 limits: 512 KB of compiled machine code and 1,000 traces, shared by the game and all mods. When either fills up, LuaJIT discards all compiled code at once and recompiles it during play. Before any mod starts, the loader raises the limits to 64 MB and 8,000 traces. If a flush still happens, it doubles them, up to 256 MB and 16,000 traces. Traces only grow while the Lua heap is under 24 MB, because this LuaJIT keeps its heap in scarce memory below 2 GB. This adds no work to any frame.

The loader log shows one line such as `LuaJIT cache: expanded 65536 KB / 8000 traces; flushes 0, growth 0; watcher on`.

## LuaJIT churn guard

LuaJIT remembers only 64 places in the code that failed to compile. After about ten failures it stops trying such a place for good. When more than 64 keep failing, they push each other out of that list and are retried for the whole session, and every retry is wasted work. With Vanilla Plus Megapack v42 this happened in every recorded session (13-36 places came back per 2 minutes). From v20 the loader notices a place that came back after it was pushed out and lets LuaJIT stop trying it, as LuaJIT would have done with room to remember it. In game, no place came back with the guard. It runs only when LuaJIT starts or abandons compiling, never on a normal frame, writes no game code and changes no JIT setting.

The loader log adds a `LuaJIT churn:` line, for example `LuaJIT churn: 12 starts kept failing (handled 12); top owners: ...; guard on`, followed by the places it handled, with the mod file and line. Mod authors: see [Keep hot code compilable](docs/AUTHORING.md#keep-hot-code-compilable).

To switch the guard off, create an empty file `BingusSharedLoader-jit-guard.off` in `%LOCALAPPDATA%/CowboyBingus/Helldivers2` and restart the game. The loader then only counts and logs, and the line ends with `guard watch only (switched off)`. Details: [technical notes](docs/TECHNICAL.md#luajit-churn-guard-v20).

## Supported modules

- Armory Preview Cache, for retained equipment thumbnails, asset preloading and learned startup preparation in Armory and mission briefing.

- Vanilla Plus Megapack, including the CowboyBingus gameplay modules below.
- Better Stratagem Bounce.
- Hellpod Steering Unlocked.
- Reinforcement Beacons Fixed, formerly Reinforcement Beacon Fix.
- Consistent Vaulting, for local manual-vault candidate processing.
- Shallow Water Diving, for local airborne water-reference handling.
- Sentry Aim Retention, for experimental autonomous-sentry target-loss handling.
- Enemy Collision Synchronized, for compatible large enemy corpses across all three factions.
- Know Your Constellation, for local enemy forecasts on mission previews and briefing.
- Controllable Hover Pack, for manual hover cutoff with native landing assistance using the Jump Pack control (default Space).
- Vehicle Stability, for experimental local-driver yaw assistance on the Bastion and gunner FRV.
- HUD Ballistic Trajectory Overlay **v2**, released September 11, 2026.
- The reserved Wide Angle Stratagems module, if separately installed.

Each gameplay package owns its own Lua resource and is optional. A missing or failed module does not prevent later modules from loading. A registered name does not mean a release exists or establish that module's gameplay compatibility.

The loader owns `core/wwise/lua/wwise_flow_callbacks`, preserves the original audio callbacks and leaves `boot` unchanged. HUD+ **0.1.3** can coexist through its existing startup script. the loader does not start HUD+ a second time.

## HUD Ballistic Trajectory Overlay v2

Install the original overlay separately and give **Bingus Shared Loader the winning priority over the overlay** in your manager, then Purge and Deploy. Arsenal still reports their shared startup file as a conflict. this overlap is expected for the supported pair. The loader starts the installed overlay automatically. No extra compatibility mod is required, and other gameplay mods are optional.

The overlay keeps its own configuration and defaults. Its optional `HUDBTO.ini` belongs beside the game's `bin` and `data` folders, as directed by the original package. The loader neither changes nor installs that file.

The maintainer confirmed v3 works in-game with the v2 overlay linked in [technical notes](docs/TECHNICAL.md). Offline checks also cover startup, configuration reads and callback forwarding with HUD+ and the gameplay modules. Future releases need revalidation if their startup changes. Other startup replacements can still conflict. this loader does not merge arbitrary scripts.

Supported: Steam build **25480438** / EXE **1.8.46015.0**. Callback preservation, missing-module behavior and manager deployment are checked independently of each gameplay mod's behavior.

Loader v14 creates `%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs` for its own log and all updated CowboyBingus mod logs. Each mod retains its existing filename.

## Source

- `src/`: the shared coordinator.
- `tests/`: callback, package and optional HUD compatibility checks.
- `scripts/`: build, strict packaging and optional Arsenal validation.
- `assets/`: banner and square Arsenal artwork.

[Build instructions](CONTRIBUTING.md) | [Technical notes](docs/TECHNICAL.md) | [Mod author guide](docs/AUTHORING.md) | [Third-party reference](docs/THIRD_PARTY_REFERENCE.md): what the CowboyBingus mods use in the shared game | [Third-party inputs](THIRD_PARTY.md) | [Release notes](docs/RELEASE_NOTES.md)

**AI disclosure:** GPT-6 Astra assisted with research, implementation, debugging, documentation and artwork; Claude Opus 5.5 assisted with research, implementation, tests and documentation.

Current version: **v20**, for game build **25480438**. See [changes](CHANGELOG.md) and [validation coverage](docs/MIGRATION_VALIDATION.md).

## License

Zero-Clause BSD (0BSD): use, copy, modify and distribute for any purpose, with no conditions. See `LICENSE`.
