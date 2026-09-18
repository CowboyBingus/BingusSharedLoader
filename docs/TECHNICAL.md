# Shared startup contract

Loader v15 adds [declared addon discovery](AUTHORING.md) after the legacy
registry, retaining API 1 and using internal coordinator version 16. The builder
embeds `src/discover.lua` into the compiled startup chunk. It scans deployed
patches once, validates bounded Lua envelopes and exact resource-name hashes,
and respects numeric patch precedence including unmarked overrides. Enumeration
failure leaves legacy startup available. See [validation coverage](DISCOVERY_VALIDATION.md) for test scope.

Startup arguments and all stock return values are preserved. Stock runtime
errors propagate without retrying initialization. The loader's own registry,
logs and manager GUID remain compatible; discovery adds no Wwise replacement
outside the existing loader package.

Bingus Shared Loader owns one Lua resource: `core/wwise/lua/wwise_flow_callbacks`, hash `0x7251FDD9BB62480A`. It runs the supported original callback bytecode and then the authored coordinator. It does not own `boot` or any gameplay resource.

The coordinator exposes `CowboyBingusModLoader.api == 1`. That internal marker remains unchanged from the former Shared Mod Loader package. Its manager GUID is `612eaf70-d682-43c7-9efd-16dcc695f977`.

For each registered module, the coordinator first checks `Application.can_get('lua', name)`. Missing resources are skipped before `require`. lookup and load failures are recorded without preventing later modules from starting. A global state marker prevents duplicate initialization.

## Stable module names

| Display name | Lua resource |
| --- | --- |
| Vanilla Plus Megapack | `mods/cowboybingus/vanilla_plus_megapack` |
| Better Stratagem Bounce | `mods/cowboybingus/better_stratagem_bounce` |
| Hellpod Steering Unlocked | `mods/cowboybingus/hellpod_steering_unlocked` |
| Reinforcement Beacons Fixed | `mods/cowboybingus/reinforcement_beacon_fix_data` |
| Consistent Vaulting | `mods/cowboybingus/consistent_vaulting` |
| Shallow Water Diving | `mods/cowboybingus/shallow_water_dive` |
| Sentry Aim Retention | `mods/cowboybingus/sentry_aim_retention` |
| Enemy Collision Synchronized | `mods/cowboybingus/corpse_collision_repair` |
| Vehicle Stability, optional experimental module | `mods/cowboybingus/vehicle_stability` |
| Controllable Hover Pack | `mods/cowboybingus/hover_pack_cancel` |
| Know Your Constellation | `mods/cowboybingus/enemy_intelligence` |
| Wide Angle Stratagems, reserved | `mods/cowboybingus/wide_angle_stratagems` |
| HUD Ballistic Trajectory Overlay v2 | `mods/codex/gun_calibration` |

The withdrawn native reinforcement module name is deliberately not registered. The loader itself performs no process-memory writes and cannot establish that an optional gameplay mod behaves correctly.

Loader-v13 uses internal coordinator version 14 / API 1 and checks the megapack identity before the existing gameplay registry. Megapack v7 publishes its nine-component inventory. The normal registry starts each resource once in the existing order. The pack owns its identity and component resources, while this loader owns only Wwise callbacks. The exhaustive coordinator test covers all 16,384 registry combinations with lookup and module failures. Pack and standalone copies may coexist through their shared resource identities and per-mod guards. Manager priority determines which version wins.

## Maintained overlay support

The supported input is [HUD Ballistic Trajectory Overlay v2](https://www.nexusmods.com/helldivers2/mods/15842), released September 11, 2026 at 11:38 UTC. Its `Overlay/9ba626afa44a3aa3.patch_0` SHA-256 is `59D2F64C5E9312C3CA3BF48CF8410FE87821C6C444AACA11090A1D0CDBB12828`.

That archive contains only the Wwise bridge and `mods/codex/gun_calibration` (`0x9537023F38D32BCD`). The bridge's embedded original Wwise bytecode matches our build input exactly. Our coordinator therefore runs the original callbacks and requires the separately installed overlay module after the registered gameplay modules. It does not execute the overlay's redundant bridge or copy its implementation. The bridge also attempts `mods/codex/pickup_icons`, which is absent from this release and is not registered as a supported mod.

Both packages still declare the same Wwise resource. The manager must deploy our loader as its winning override. A conflict warning is expected. an overlay bridge that wins instead will not start our gameplay modules. No order is required between the separate CowboyBingus gameplay resources.

The overlay wraps and forwards `update` and `shutdown`. Its existing `HUDBTO.ini` reader and defaults are unchanged. The integration fixture supplies a fake executable-path resolver and blocks gameplay memory APIs. no native game code is executed. Checks cover 64 installed-module/HUD+/Wwise combinations, or 128 when the optional Consistent Vaulting package is supplied, along with configuration reads and reloads, callback arguments and return tuples, temporary-memory restoration, missing FFI, cached module loads and repeated coordinator execution. The maintainer separately confirmed loader-v3 works in-game with this overlay. the offline fixture does not simulate live world cleanup or multiplayer.

The build marks `runtime_verified` only when the compiled callback resource matches the maintainer-tested SHA-256 in `TESTED_CALLBACK_SHA`. Changing the runtime makes a subsequent build unverified until it is tested again. Release documentation and provenance can be updated without changing the tested game resource.

The fixture hash pins the reviewed release during verification. Runtime discovery checks the resource name, not a release fingerprint. a future release using that name will also be attempted and is not automatically certified compatible. Reinspect changed releases and update the fixture only after validating the new startup contract.

## Compatibility and publication

Resource tests verify distinct ownership across load orders and removal subsets. Runtime tests exercise missing modules, load failures, repeated initialization and preservation of the original Wwise callbacks. Optional checks cover the unmodified HUD+ boot and actual manager backends with locally supplied fixtures.

Original game scripts are build inputs supplied by the developer, not source-distribution files. Generated archives, manager fixtures, dependency binaries, caches and history are excluded from the source export. The public artwork retains its visible AI disclosure.

Armory Preview Cache is registered as `mods/cowboybingus/armory_preview_cache`. Its builder does not generate a separate loader variant.

## Shared log directory

Loader v14 (internal marker 15, API 1) provides `CowboyBingusModLoader.open_log(filename)` before loading gameplay modules. It creates `%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs` once per session through the Windows directory API. Each mod keeps its existing log filename, including the collision profiler. Only plain `.log` filenames are accepted; paths and traversal are rejected.

The helper returns a writable file or nil. Missing environment variables, unavailable FFI, directory permissions and file-open errors cannot interrupt module discovery. Each caller also isolates its write/close operation. Modules running with an older loader continue their existing gameplay startup but skip logging; install v14 to use the new directory. Configuration and profile files are not logs and retain their existing locations.

The focused logging suite covers existing directories, setup failures, file-open failures and one-time initialization. A native Windows filesystem smoke check also verifies actual directory creation without attaching to the game.
