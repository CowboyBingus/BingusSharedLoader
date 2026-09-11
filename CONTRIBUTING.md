# Build from source

Use Windows x64, Python 3.10+ and the LuaJIT revision pinned in `dependencies.json`. Build LuaJIT in an x64 Visual Studio Native Tools prompt with `msvcbuild.bat nogc64` and set `HD2_LUAJIT` to that executable.

Export the supported game's raw `boot` and `core/wwise/lua/wwise_flow_callbacks` Lua resources from your own installation. Supply them through `HD2_BOOT_RESOURCE` and `HD2_CALLBACK_RESOURCE`. They include the eight-byte resource header. Exact hashes and resource sizes are checked by the builder. Do not commit or include extracted resources in a source export.

```powershell
$env:HD2_LUAJIT = (Resolve-Path 'tools/src/LuaJIT/src/luajit.exe').Path
$env:HD2_BOOT_RESOURCE = (Resolve-Path 'artifacts/vanilla/boot.lua.main').Path
$env:HD2_CALLBACK_RESOURCE = (Resolve-Path 'artifacts/vanilla/wwise_flow_callbacks.lua.main').Path
python -B scripts/build.py
```

The result is `releases/BingusSharedLoader.zip`; intermediate files and reports go into `build/`. The original callback bytecode is wrapped with the authored coordinator. The boot resource is a test fixture and is not placed in the mod archive. The builder does not install mods or launch the game.

## Optional integration checks

After building the loader, Bounce, Steering and reinforcement projects:

```text
python -B tests/test_shared_packages.py <Loader-ZIP> <Bounce-ZIP> <Steering-ZIP> <Reinforcement-ZIP>
<LuaJIT> tests/test_hud_compatibility.lua <Loader-build> <Bounce-build> <Steering-build> <HUD-resources> <Reinforcement-build>
```

The HUD resources must be supplied locally from the tested HUD+ package. The check runs actual bytecode in an isolated environment that rejects gameplay memory writes.

`scripts/test_arsenal_packages.cjs` accepts an unpacked HDArsenal application and an isolated output directory; inspect its argument documentation before use. Application sources, user profiles, game data and test outputs are not publication inputs.

Keep the manager GUID, `CowboyBingusModLoader` API marker and existing module resource names stable. Preserve original callbacks, one-time startup, missing-module checks and failure isolation. No repository-wide license has been selected.
