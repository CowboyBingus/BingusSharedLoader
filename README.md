![Bingus Shared Loader](assets/banner.png)

# Bingus Shared Loader

[Download loader-v2](https://github.com/CowboyBingus/BingusSharedLoader/releases/tag/loader-v2)

Starts your installed CowboyBingus mods through one shared startup resource. The loader has no gameplay effect by itself.

**Install:** Close Helldivers 2. Import `BingusSharedLoader.zip` and your chosen gameplay ZIPs into **HDArsenal** or **HD2MM**, enable them, and deploy. Managers do not install this dependency automatically. Keep the loader enabled while any dependent mod is enabled.

This is **loader-v2 / API 1**, renamed from Shared Mod Loader. Replace the previous entry, then **Purge → Deploy**. The manager GUID and runtime API marker are unchanged, so existing module-only gameplay packages remain compatible. Do not install both names together. See [installation](INSTALL.txt).

## Supported modules

- Better Stratagem Bounce.
- Hellpod Steering Unlocked.
- Reinforcement Beacons Fixed, formerly Reinforcement Beacon Fix.
- The reserved Wide Angle Stratagems module, if separately installed.

Each gameplay package owns its own Lua resource and is optional. A missing or failed module does not prevent later modules from loading. A registered name does not mean a release exists or establish that module's gameplay compatibility.

The loader owns `core/wwise/lua/wwise_flow_callbacks`, preserves the original audio callbacks and leaves `boot` unchanged. The tested HUD+ boot script can coexist. Another Wwise resource replacement can still conflict; this loader does not merge arbitrary script mods.

Supported: Steam build **24826606** / EXE **1.8.45317.0**. Startup was observed with the current module family. Callback preservation, missing-module behavior and manager deployment are checked independently of gameplay behavior.

The runtime log is `%LOCALAPPDATA%/BingusSharedLoader.log`.

## Source

- `src/`: the shared coordinator.
- `tests/`: callback, package and optional HUD compatibility checks.
- `scripts/`: build, strict packaging and optional Arsenal validation.
- `assets/`: banner and square Arsenal artwork.

[Build instructions](CONTRIBUTING.md) · [Technical notes](docs/TECHNICAL.md) · [Third-party inputs](THIRD_PARTY.md) · [Release notes](docs/RELEASE_NOTES.md)

**AI disclosure:** GPT-6 Astra assisted with research, implementation, debugging, documentation and artwork.
