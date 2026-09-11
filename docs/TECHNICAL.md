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
| Wide Angle Stratagems, reserved | `mods/cowboybingus/wide_angle_stratagems` |

The withdrawn native reinforcement module name is deliberately not registered. The loader itself performs no process-memory writes and cannot establish that an optional gameplay mod behaves correctly.

## Compatibility and publication

Resource tests verify distinct ownership across load orders and removal subsets. Runtime tests exercise missing modules, load failures, repeated initialization and preservation of the original Wwise callbacks. Optional checks cover the unmodified HUD+ boot and actual manager backends with locally supplied fixtures.

Original game scripts are build inputs supplied by the developer, not source-distribution files. Generated archives, manager fixtures, dependency binaries, caches and history are excluded from the source export. The public artwork retains its visible AI disclosure.
