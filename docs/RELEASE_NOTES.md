# Bingus Shared Loader — loader-v2

Renamed from Shared Mod Loader, with matching banner and square Arsenal artwork. The manager GUID, API marker and module resource names are preserved for compatibility with current module-only gameplay packages.

Install `BingusSharedLoader.zip` alongside the chosen gameplay mods. Replace the previous loader entry, then Purge and Deploy with the game closed. Do not install old and renamed copies together.

The loader preserves the original Wwise callbacks, leaves boot unchanged, skips missing modules and isolates load failures. It has no gameplay effect alone. A successful module load does not establish that module's gameplay correctness.

Callback, resource ownership, HUD compatibility and isolated Arsenal/HD2MM deployment checks passed. Source publication excludes extracted game resources, manager profiles, binaries, local captures and repository history.

[Download this release](https://github.com/CowboyBingus/BingusSharedLoader/releases/tag/loader-v2)
