# Shared startup contract

Loader v15 adds [declared addon discovery](AUTHORING.md) after the legacy
registry, retaining API 1 and using internal coordinator version 16. The builder
embeds `src/discover.lua` into the compiled startup chunk. It scans deployed
patches once, validates bounded Lua envelopes and exact resource-name hashes,
and respects numeric patch precedence including unmarked overrides. Enumeration
failure leaves legacy startup available. See [validation coverage](DISCOVERY_VALIDATION.md) for test scope.
From v19 discovery is never compiled: like the health report (below),
`src/discover.lua` turns the JIT off for its own function and the functions
defined in it, so its startup loops leave no machine code in the code cache
shared by the game and every mod.

From v19 discovery also records every copy of each Lua resource, not only the
winning one. When more than one deployed archive holds a resource the loader
starts (a registry name or a declared entry), the log names the archive whose
copy the game loads (the highest patch) and the hidden ones, each with its kind:
`declared`, `compiled` (LuaJIT bytecode) or `undeclared` (any other source).
Lists name six archives and count the rest: Vanilla Plus Megapack carries its
own entry in every option, so its line has one copy per enabled option. A
declared entry whose winning copy is compiled or undeclared is still not started,
and the log now says so and names both archives. Which entries start is
unchanged, and so are module statuses, `CowboyBingusModLoader.discovery` and the
printed lines. A hidden copy is read only for this report (v18 never read it),
so those reads cannot stop the scan: a copy whose envelope or body cannot be
read is listed as `unreadable`, adds no warning, and the rest of its archive is
scanned exactly as before. The winning copy's own reads stop its archive's scan
on failure, as they always have. Cost, once at startup: two more small reads (8
bytes and at most 256) and one `pcall` for each hidden copy, and, only when some
resource has copies, one hash per registry name; one small table per Lua
resource. No per-frame work. Unmeasured in game.

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

The build marks `runtime_verified` only when the compiled callback resource matches `TESTED_CALLBACK_SHA` in `scripts/build.py`, and only `scripts/pin_tested.py` writes that constant. It takes a TestHarness run and the release ZIP that run deployed, and pins the ZIP's resource only when the run was clean (it reached the ship, quit through the engine with exit code 0 with the test agent seeing the shutdown, left no crash dump, restored the install, and ran the supported game build), the run record holds the ZIP's SHA-256 (`facts.package_sha256`, or `{"name", "sha256"}` entries in `facts.packages`), the run's loader log starts with the ZIP's revision and reaches `Startup finished`, and the resource equals the one the current sources build, compiled again in a temporary folder. Otherwise it lists every reason and writes nothing; `--check` only reports. A run record that names its packages without their hashes is refused, because it cannot show which bytes were deployed. Changing the runtime makes a subsequent build unverified until it is played and pinned again. The value in place before v19 was set by hand on 2026-09-17 and matched none of the v16, v17 or v18 resources, so those builds reported `runtime_verified: false`. v19 cleared it, and the v19 release pins the resource played in a clean ship run on 2026-10-04 (`7A071358...`), so the release build reports `runtime_verified: true`. Release documentation and provenance can be updated without changing the tested game resource. `tests/test_pin_tested.py` covers each refusal with synthetic runs and ZIPs and never writes the real build script.

The fixture hash pins the reviewed release during verification. Runtime discovery checks the resource name, not a release fingerprint. a future release using that name will also be attempted and is not automatically certified compatible. Reinspect changed releases and update the fixture only after validating the new startup contract.

## Compatibility and publication

Resource tests verify distinct ownership across load orders and removal subsets. Runtime tests exercise missing modules, load failures, repeated initialization and preservation of the original Wwise callbacks. Optional checks cover the unmodified HUD+ boot and actual manager backends with locally supplied fixtures.

Original game scripts are build inputs supplied by the developer, not source-distribution files. Generated archives, manager fixtures, dependency binaries, caches and history are excluded from the source export. The public artwork retains its visible AI disclosure.

Armory Preview Cache is registered as `mods/cowboybingus/armory_preview_cache`. Its builder does not generate a separate loader variant.

## Shared log directory

Loader v14 (internal marker 15, API 1) provides `CowboyBingusModLoader.open_log(filename)` before loading gameplay modules. It creates `%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs` once per session through the Windows directory API. Each mod keeps its existing log filename, including the collision profiler. Only plain `.log` filenames are accepted; paths and traversal are rejected.

The helper returns a writable file or nil. Missing environment variables, unavailable FFI, directory permissions and file-open errors cannot interrupt module discovery. Each caller also isolates its write/close operation. Modules running with an older loader continue their existing gameplay startup but skip logging; install v14 to use the new directory. Configuration and profile files are not logs and retain their existing locations.

The focused logging suite covers existing directories, setup failures, file-open failures and one-time initialization. A native Windows filesystem smoke check also verifies actual directory creation without attaching to the game.

## Shared LuaJIT code cache (v18)

The game's `bin/lua51.dll` is LuaJIT 2.1.0-alpha (non-GC64) with its default
limits: `maxmcode=512` KB of machine code and `maxtrace=1000` traces, read from
the live `jit_State`. The game never raises them, and the game and every addon
share them. On the ship, about 320 traces and 200 KB of machine code were
live, about 94% of it from mods. When a new trace would exceed either limit,
LuaJIT calls `lj_trace_flushall`: every compiled trace is discarded and
recompiled as code runs hot again, with the code interpreted in between.

`src/jit_budget.lua` is embedded in the startup chunk like discovery. Before
any module loads, it calls `jit.opt.start('maxmcode=65536', 'maxtrace=8000')`
and attaches one `jit.attach(handler, 'trace')` watcher. The watcher counts
compiled traces. After a flush it doubles both limits up to 256 MB and 16,000
traces; the trace limit only grows while `collectgarbage('count')` is below
24 MB. Machine code is placed within the jump range of `lua51.dll`, where 1.86
GB of address space was free. Each trace also keeps about 1 KB of records in
the Lua heap, which a non-GC64 LuaJIT must place below 2 GB, where about 48 MB
was free; hence the heap guard.

Cost: nothing per frame and no update hook. The handler runs only on trace
events. A flush adds one `jit.opt.start` call and at most one log rewrite per
30 seconds, plus one per growth step. The log gets one line, for example
`LuaJIT cache: expanded 65536 KB / 8000 traces; flushes 0, growth 0; watcher on`.
Since v19 machine code starts at 64 MB (v18: 16 MB): LuaJIT commits code space only
as code is compiled, so the higher limit costs nothing until it is used. In the game's
`lua51.dll` the trace count stops at 65,535 whatever `maxtrace` says (16-bit trace
numbers), and each trace keeps its records in the Lua heap below 2 GB, so the trace
limit, not machine code, is what bounds the cache.
`CowboyBingusModLoader.jit` exposes the same state; Vanilla Plus Megapack v31
uses its presence to leave the cache to the loader. The raised limits are always
on; there is no switch back to the game's own limits.

In recorded real play with every Vanilla Plus Megapack mod enabled (19 minutes
aboard the ship and an 11-minute mission), machine code reached the old 512 KB
aboard the ship and 960 KB in 946 traces by the end, with no flush. The Lua heap
peaked at 3.9 MB, well below the 24 MB guard.

`tests/test_jit_budget.lua` covers limits, growth, ceilings, the heap guard,
the log interval and failures with a stand-in `jit` table.
`tests/test_jit_budget_game.py` runs `tests/test_jit_budget_game.lua` inside
the installed game's own `lua51.dll`, in the test process only. There, real
overflows of a deliberately tiny cache flush, the watcher grows the limits, and
later code compiles without a flush. The check is skipped when the game is not
installed.

## Health report (v19)

`src/health.lua` is embedded in the startup chunk like discovery. It adds no
update, render or shutdown hook; everything runs once while the game starts.
The log `BingusSharedLoader.log` then reads, in order:

- `Started:` local time, and `Game build stamps:` the PE timestamps of the
  running executable and `game.dll`, read from their mapped headers.
- `Lua at start:` heap size, garbage collector pause and step multiplier, and
  whether the JIT is on, before any module loads.
- `Previous session:` the previous log's start time and how it ended: either
  its `Startup finished` line, or the module that was still marked `loading`.
  The log is rewritten just before each module's `require`, so a session that
  stops inside a module's startup ends with that module marked `loading`. A log
  that still reads `After startup: running` after `Startup finished` ended while
  the `after_startup` callbacks ran (below).
- `Newest crash dump:` the write time, exception code and faulting
  `module+offset` (with module and executable stamps) of the newest `.dmp` in
  `%APPDATA%/Arrowhead/Helldivers2/dumps`, and the number of dumps. Dump file
  names contain the computer name and module paths can contain the Windows user
  name, so the report keeps neither. `Newest GPU crash report:` the write time
  of the newest `gpu_dump_*` file, when there is one.
- `Discovery:` and `LuaJIT cache:` as before. The cache line says `watcher
  replaced` when the registry's `_VMEVENTS` table no longer holds the loader's
  trace handler. After `Discovery:`, one line per declared entry that a higher
  compiled or undeclared copy hides, for example `  not started:
  mods/author/addon, declared in 9ba626afa44a3aa3.patch_3, is hidden by
  9ba626afa44a3aa3.patch_12 (compiled)`.
- One `<module>: <status>` line per registered module, unchanged. When more
  than one archive holds the module, `  copies: 9ba626afa44a3aa3.patch_9
  (declared) used; hidden: 9ba626afa44a3aa3.patch_4 (compiled)` follows, and for
  each loaded module `  changes: heap +N KB, N ms; ...`. The changes are
  what that module added, replaced or removed in the globals, the standard
  library tables, `package.loaded` (replaced or removed only), the string
  metatable and the globals' metatable, and any change to the garbage
  collector pause or step multiplier, JIT on/off and options, JIT flushes, or
  the loader's trace watcher.
- `Startup finished: N loaded, N failed`.
- Only when `after_startup` callbacks were registered: `After startup: N
  callbacks run, N failed`, then one `After startup: callback of <module>
  failed: <message>` line per error.

The observer compares by identity (`rawequal`) and walks tables with `next`,
so a mod's metamethods never run; nil checks also avoid `__eq` on cdata. It
reads the collector settings by setting a value and restoring the old one at
once, with no allocation in between. The same data is available in game as
`CowboyBingusModLoader.health` (`header`, `changes`).

The report is never compiled. `health.lua` turns the JIT off for the function
it runs in and every function defined in it (`jit.off(f, true)`, with `f` found
through `debug.getinfo` under `pcall`), and for nothing else. Its walks and
helpers run hot during startup. Compiled, they would keep machine code that never
runs again in the shared cache. `build.py` therefore keeps the wrapper function
around it. `tests/test_health.lua` checks in both VMs that no trace starts in the
report and that a loop in another chunk still compiles.

Windows functions are declared once under private names
(`bsl_CreateDirectoryA ... __asm__("CreateDirectoryA")`) and passed to
discovery: `ffi.cdef` keeps the first prototype for a name in the whole
process, so plain names would bind to whatever another mod declared first. The
coordinator also keeps its own copies of `pcall`, `tostring`, `io.open` and the
other builtins it uses before any module runs.

Compatibility with mods written for v18: v18 also declared six plain names for
every mod, `CreateDirectoryA` and `GetLastError` the first time a log was
opened (with `LOCALAPPDATA` set) and `GetModuleFileNameA`, `FindFirstFileA`,
`FindNextFileA`, `FindClose` and `GetLastError` before any mod loaded. v19 makes
the same declarations at the same moments, so a mod sees the same functions and
prototypes as under v18, whether it calls them without declaring them or
declares them itself later. `version` stays `17`; mods test the read-only
`CowboyBingusModLoader.capabilities` instead (`api = 1`, `logs`, `discovery`,
`jit_budget`, `health`). It says what the build supports, not how it went this
session: the bare source used by some tests has only `api` and `logs`, and a
failed discovery or an unmanaged cache shows in `discovery` and `jit.managed`.
The fields live in the metatable's `__index` table, so an assignment raises
and `pairs()` sees none of them. `tests/test_contract.py`
records what other mods can observe from a release ZIP
(`tests/fixtures/loader-contract.json`, from the published v18 package) and
compares every build with it in eleven scenarios: the global table's fields and
values, module statuses, declared Windows names and their prototypes, calls an
addon makes through them, the update chain, printed lines and log statuses. In
two scenarios discovery works over archives that hold copies of the same
entries: one includes a declared entry hidden by an undeclared copy, and in the
other the reads of two hidden copies fail (one envelope, one body) while an
entry after them in their archive must still start.
`tests/test_discovery_integration.py` runs the same kind of failures through the
compiled startup with real files, in the workspace LuaJIT and in the game's
`lua51.dll`, and compares the statuses and start order with a run without them.
Allowed differences are listed in the test with their reasons: the added
`capabilities`, `health` and `revision` fields, and one repaired scenario
(under v18, a module that declared `CreateDirectoryA` with an incompatible
prototype before the first log write disabled every mod log for the session).

Startup cost: one read of the previous log, one listing of the dump folder, a
few small reads from the newest dump, and per installed module two walks over
the shared tables. `next` is not compiled by this LuaJIT, so the walks add no
machine code to the shared cache. Unmeasured in game.

`tests/test_health.lua` runs in the workspace LuaJIT and in the game's own
`lua51.dll` (`tests/game_lua.py`). It covers the observer, the previous-session
summary, the PE stamp against the executable file, the dump folder listing,
synthetic minidumps, and the whole log written by the built coordinator with
clashing global prototypes declared first.

## after_startup (v19)

`CowboyBingusModLoader.after_startup(fn)` queues `fn` with the module being
started at that moment: the coordinator notes the name around each module's
`require`. A callback registered from inside another callback gets that
callback's module; one registered after startup gets none. Author guidance is in
[AUTHORING.md](AUTHORING.md#running-code-once-every-mod-has-started).

When the last module has started, the coordinator writes the log as before,
ending with `Startup finished`, plus `After startup: running N callbacks` when
any are queued. Then it runs the queue: one callback at a time, in registration
order, each under `pcall`. A registration made while the queue runs joins its
end, so callbacks never nest and the order holds. Afterwards it writes the log
once more, with `After startup: N callbacks run, N failed` in place of the note
and one line per error: `After startup: callback of <module> failed: <message>`.
Line breaks in the message become spaces, and an error value whose `tostring`
fails reads `an error value without text`. Each error line is also printed once.
From then on `after_startup(fn)` runs `fn` at once, and the log is rewritten
only when that adds a line. A late callback's error reads `callback registered
after startup`.

The queue accepts 256 callbacks a session. A callback that registers itself
again would otherwise keep the game in its startup forever. The 257th
registration returns `false` and a reason, and the log says so once. A value
that is not a function returns `false, 'after_startup needs a function'`.

Cost: nothing per frame and no update hook. At startup, one `pcall` per callback
and, when any callback was registered, one more log write; a session without
callbacks writes its log exactly as before. The queue's loop is kept out of the
JIT (`jit.off` on that one function), so even a long queue leaves no machine
code in the shared cache. In the game's `lua51.dll` (a test process, 10 fresh
starts each), a startup of the 14 registry modules compiled no coordinator trace
before or after this change, with 0, 15 or 215 callbacks. Unmeasured in game.

`tests/test_after_startup.lua` runs the built coordinator in the workspace
LuaJIT and in the game's `lua51.dll`. It covers:
- no callbacks: the same log, writes and prints as before;
- order and timing: after every module (failed ones included), before the first
  update, once each;
- errors, including error values without text;
- registrations during a callback and after startup;
- refused arguments and the limit;
- no trace starting in the queue's loop.

`tests/test_discovery_integration.py` registers callbacks from the registry
module and two discovered addons under real discovery, in both VMs.
`tests/test_contract.py` lists `after_startup` as an added field; the eleven v18
scenarios are otherwise unchanged.

## Frame probe build (development only, never published)

`scripts/build.py --probe` makes a loader for the maintainer's real-play performance study; it is never released. It embeds `src/frame_probe.lua` and adds two hooks to the coordinator text at build time: before the first module starts, the probe wraps the game's `update`, `render` and `shutdown`; after each module's require, a changed `update` or `render` becomes that module's timed layer. Hooks installed later, including from `after_startup` callbacks, become a `late hook` layer on the next frame. It writes `BingusFrameProbe.log` and `BingusFrameProbe-seconds.csv` (schema 4) to the shared log folder. Revision `loader-v19-probe4`; the loader log's second line names it; `runtime_verified` is false. The public build is byte-identical with or without these files. Every 40 s the probe skips all mod hooks for 10 s and Enemy Collision Synchronized for another 10 s.
