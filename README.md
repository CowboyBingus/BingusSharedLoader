![Bingus Shared Loader](assets/banner.png)

# Bingus Shared Loader

> [!IMPORTANT]
> **Required dependency for Better Stratagem Bounce, Hellpod Steering Unlocked and Reinforcement Beacons Fixed.** Download `BingusSharedLoader.zip` separately and enable it alongside your chosen mods in Arsenal or HD2MM. **Those mods will not activate without this loader.** Managers do not install it automatically. Install the loader once, even when using several supported mods.

[Download loader-v3](https://github.com/CowboyBingus/BingusSharedLoader/releases/tag/loader-v3)

Starts your installed CowboyBingus mods and supported third-party mods together. The loader has no gameplay effect by itself.

**Install:** Close Helldivers 2. Import `BingusSharedLoader.zip` and your chosen gameplay ZIPs into **HDArsenal** or **HD2MM**, enable them, and deploy. Managers do not install this dependency automatically. Keep the loader enabled while any dependent mod is enabled.

This is **loader-v3 / API 1**. Replace the previous loader entry, then **Purge → Deploy**. The manager GUID and runtime API marker are unchanged, so existing module-only gameplay packages remain compatible. Do not install old and new loader copies together. See [installation](INSTALL.txt).

## Supported modules

- Better Stratagem Bounce.
- Hellpod Steering Unlocked.
- Reinforcement Beacons Fixed, formerly Reinforcement Beacon Fix.
- HUD Ballistic Trajectory Overlay **v2**, released September 11, 2026.
- The reserved Wide Angle Stratagems module, if separately installed.

Each gameplay package owns its own Lua resource and is optional. A missing or failed module does not prevent later modules from loading. A registered name does not mean a release exists or establish that module's gameplay compatibility.

The loader owns `core/wwise/lua/wwise_flow_callbacks`, preserves the original audio callbacks and leaves `boot` unchanged. HUD+ **0.1.3** can coexist through its existing startup script; the loader does not start HUD+ a second time.

## HUD Ballistic Trajectory Overlay v2

Install the original overlay separately and give **Bingus Shared Loader the winning priority over the overlay** in your manager, then Purge and Deploy. Arsenal still reports their shared startup file as a conflict; this overlap is expected for the supported pair. The loader starts the installed overlay automatically. No extra compatibility mod is required, and other gameplay mods are optional.

The overlay keeps its own configuration and defaults. Its optional `HUDBTO.ini` belongs beside the game's `bin` and `data` folders, as directed by the original package. The loader neither changes nor installs that file.

The maintainer confirmed loader-v3 works in-game with the v2 overlay linked in [technical notes](docs/TECHNICAL.md). Offline checks also cover startup, configuration reads and callback forwarding with HUD+ and the gameplay modules. Future releases need revalidation if their startup changes. Other startup replacements can still conflict; this loader does not merge arbitrary scripts.

Supported: Steam build **24826606** / EXE **1.8.45317.0**. Callback preservation, missing-module behavior and manager deployment are checked independently of each gameplay mod's behavior.

The runtime log is `%LOCALAPPDATA%/BingusSharedLoader.log`.

## Source

- `src/`: the shared coordinator.
- `tests/`: callback, package and optional HUD compatibility checks.
- `scripts/`: build, strict packaging and optional Arsenal validation.
- `assets/`: banner and square Arsenal artwork.

[Build instructions](CONTRIBUTING.md) · [Technical notes](docs/TECHNICAL.md) · [Third-party inputs](THIRD_PARTY.md) · [Release notes](docs/RELEASE_NOTES.md)

**AI disclosure:** GPT-6 Astra assisted with research, implementation, debugging, documentation and artwork.
