# Build from source

Use Windows x64, Python 3.10+ and the LuaJIT revision pinned in `dependencies.json`. Build LuaJIT in an x64 Visual Studio Native Tools prompt with `msvcbuild.bat nogc64` and set `HD2_LUAJIT` to that executable.

Export the supported game's raw `boot` and `core/wwise/lua/wwise_flow_callbacks` Lua resources from your own installation. Supply them through `HD2_BOOT_RESOURCE` and `HD2_CALLBACK_RESOURCE`. They include the eight-byte resource header. Exact hashes and resource sizes are checked by the builder. Do not commit or include extracted resources in a source export.

```powershell
$env:HD2_LUAJIT = (Resolve-Path 'tools/src/LuaJIT/src/luajit.exe').Path
$env:HD2_BOOT_RESOURCE = (Resolve-Path 'artifacts/vanilla/boot.lua.main').Path
$env:HD2_CALLBACK_RESOURCE = (Resolve-Path 'artifacts/vanilla/wwise_flow_callbacks.lua.main').Path
python -B scripts/build.py
```

The result is `releases/Bingus-Shared-Loader-v14.zip` under the base workspace, shared with the gameplay packages. A standalone checkout uses its own base directory. Intermediate files and reports remain in this project's `build/`. The original callback bytecode is wrapped with the authored coordinator. The boot resource is a test fixture and is not placed in the mod archive. The builder does not install mods or launch the game.

## Optional integration checks

After building the loader, Bounce, Steering, reinforcement and vaulting projects:

```text
python -B tests/test_shared_packages.py <Loader-ZIP> <Bounce-ZIP> <Steering-ZIP> <Reinforcement-ZIP> <Vaulting-ZIP>
<LuaJIT> tests/test_hud_compatibility.lua <Loader-build> <Bounce-build> <Steering-build> <HUD-resources> <Reinforcement-build>
```

The HUD resources must be supplied locally from the tested HUD+ package. The check runs actual bytecode in an isolated environment that rejects gameplay memory writes.

For HUD Ballistic Trajectory Overlay v2, supply the original extracted package, the HUD+ fixtures and current gameplay ZIPs:

```text
python -B tests/test_overlay_compatibility.py <Overlay-v2-folder> <HUD-resources> <Bounce-ZIP> <Steering-ZIP> <Reinforcement-ZIP> --vaulting <Vaulting-ZIP>
```

This verifies the pinned overlay archive and runs its unchanged Lua module with the compiled loader and gameplay modules. The harness substitutes the overlay's executable-path resolver and configuration file, and blocks gameplay memory APIs. It does not launch the game. Keep third-party fixtures and generated reports under ignored build directories.

`scripts/test_arsenal_packages.cjs` accepts an unpacked HDArsenal application and an isolated output directory. inspect its argument documentation before use. Its optional final ZIP can be the original overlay package, including its `Overlay` option folder. Application sources, user profiles, game data and test outputs are not publication inputs.

For the two-package megapack installation, pass only the loader ZIP and megapack ZIP after the fixture arguments. This exercises both load orders and all enable/disable subsets, including title, description, icon, archive renumbering and purge behavior. The megapack repository also supplies `tests/test_loader.lua` to run its compiled identity and its gameplay resources against this loader build.

After the overlay fixture has been prepared by `test_overlay_compatibility.py`, its Lua harness accepts a fifth argument pointing to the megapack build directory (after the optional vaulting resource). This checks the bundled modules and the pack identity alongside Overlay v2 and HUD+ across 1,024 startup combinations.

Keep the manager GUID, `CowboyBingusModLoader` API marker and existing module resource names stable. Preserve original callbacks, one-time startup, missing-module checks and failure isolation. No repository-wide license has been selected.
