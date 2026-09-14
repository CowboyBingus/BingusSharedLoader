# Shared startup contract

Bingus Shared Loader owns one Lua resource: `core/wwise/lua/wwise_flow_callbacks`, hash `0x7251FDD9BB62480A`. It runs the supported original callback bytecode and then the authored coordinator. It does not own `boot` or any gameplay resource.

The coordinator exposes `CowboyBingusModLoader.api == 1`. That internal marker remains unchanged from the former Shared Mod Loader package. Its manager GUID is `612eaf70-d682-43c7-9efd-16dcc695f977`.

For each registered module, the coordinator first checks `Application.can_get('lua', name)`. Missing resources are skipped before `require`; lookup and load failures are recorded without preventing later modules from starting. A global state marker prevents duplicate initialization.

## Stable module names

| Display name | Lua resource |
| --- | --- |
| Better Stratagem Bounce | `mods/cowboybingus/better_stratagem_bounce` |
| Hellpod Steering Unlocked | `mods/cowboybingus/hellpod_steering_unlocked` |
| Reinforcement Beacons Fixed | `mods/cowboybingus/reinforcement_beacon_fix_data` |
| Consistent Vaulting | `mods/cowboybingus/consistent_vaulting` |
| Shallow Water Diving | `mods/cowboybingus/shallow_water_dive` |
| Wide Angle Stratagems, reserved | `mods/cowboybingus/wide_angle_stratagems` |
| HUD Ballistic Trajectory Overlay v2 | `mods/codex/gun_calibration` |

The withdrawn native reinforcement module name is deliberately not registered. The loader itself performs no process-memory writes and cannot establish that an optional gameplay mod behaves correctly.

Loader-v4 uses internal coordinator version 5 / API 1 and adds Consistent Vaulting before the overlay. The coordinator covers all 64 installed-module combinations. Consistent Vaulting requires this registration and independently validates the local avatar and query records; teammates' controllers are outside its write scope. Gameplay validation of the new module and loader revision remains pending.

## Maintained overlay support

The supported input is [HUD Ballistic Trajectory Overlay v2](https://www.nexusmods.com/helldivers2/mods/15842), released September 11, 2026 at 11:38 UTC. Its `Overlay/9ba626afa44a3aa3.patch_0` SHA-256 is `59D2F64C5E9312C3CA3BF48CF8410FE87821C6C444AACA11090A1D0CDBB12828`.

That archive contains only the Wwise bridge and `mods/codex/gun_calibration` (`0x9537023F38D32BCD`). The bridge's embedded original Wwise bytecode matches our build input exactly. Our coordinator therefore runs the original callbacks and requires the separately installed overlay module after the registered gameplay modules. It does not execute the overlay's redundant bridge or copy its implementation. The bridge also attempts `mods/codex/pickup_icons`, which is absent from this release and is not registered as a supported mod.

Both packages still declare the same Wwise resource. The manager must deploy our loader as its winning override. A conflict warning is expected; an overlay bridge that wins instead will not start our gameplay modules. No order is required between the separate CowboyBingus gameplay resources.

The overlay wraps and forwards `update` and `shutdown`. Its existing `HUDBTO.ini` reader and defaults are unchanged. The integration fixture supplies a fake executable-path resolver and blocks gameplay memory APIs; no native game code is executed. Checks cover 64 installed-module/HUD+/Wwise combinations, or 128 when the optional Consistent Vaulting package is supplied, along with configuration reads and reloads, callback arguments and return tuples, temporary-memory restoration, missing FFI, cached module loads and repeated coordinator execution. The maintainer separately confirmed loader-v3 works in-game with this overlay; the offline fixture does not simulate live world cleanup or multiplayer.

The build marks `runtime_verified` only when the compiled callback resource matches the maintainer-tested SHA-256 in `TESTED_CALLBACK_SHA`. Changing the runtime makes a subsequent build unverified until it is tested again. Release documentation and provenance can be updated without changing the tested game resource.

The fixture hash pins the reviewed release during verification. Runtime discovery checks the resource name, not a release fingerprint; a future release using that name will also be attempted and is not automatically certified compatible. Reinspect changed releases and update the fixture only after validating the new startup contract.

## Compatibility and publication

Resource tests verify distinct ownership across load orders and removal subsets. Runtime tests exercise missing modules, load failures, repeated initialization and preservation of the original Wwise callbacks. Optional checks cover the unmodified HUD+ boot and actual manager backends with locally supplied fixtures.

Original game scripts are build inputs supplied by the developer, not source-distribution files. Generated archives, manager fixtures, dependency binaries, caches and history are excluded from the source export. The public artwork retains its visible AI disclosure.
