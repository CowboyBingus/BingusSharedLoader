# Making a discoverable mod

Bingus Shared Loader v15 adds startup discovery while keeping API 1. Existing
registered mods still work without repackaging. See [validation coverage](DISCOVERY_VALIDATION.md).
What the CowboyBingus mods already use in the shared game (log and settings
files, menus, input actions, native lists) is in the
[third-party reference](THIRD_PARTY_REFERENCE.md).

## Quick start

Write an initialization script, for example `flashlight.lua`. Choose a unique
resource name such as `mods/spacecowboy/better_flashlight`; it has no `.lua`
extension. Each segment uses only ASCII letters, digits and underscores. Nested
paths work. Author namespaces are not restricted to `cowboybingus`.

From the loader source checkout, package that script:

```powershell
python -B scripts/build_addon.py --name mods/spacecowboy/better_flashlight --entry flashlight.lua --guid YOUR-STABLE-UUID --display-name "Better Flashlight" --output Better-Flashlight.zip
```

Generate your UUID once (`python -c "import uuid; print(uuid.uuid4())"`) and reuse
it for every update to that mod. Do not reuse the loader's GUID or an example
mod's GUID. The helper accepts a single plaintext UTF-8 script, inserts its
declaration, calculates its resource hash and emits the archive, empty sidecars
and manager manifest. It does not compile, install or execute your script.
Keep supporting code in that script for this simple packaging route.

Distribute your ZIP with a requirement for **Bingus Shared Loader v15 or newer /
API 1**. Players import both packages into Arsenal or HD2MM, enable them, and
deploy. Managers do not automatically install the dependency. Keep the loader
as the winning Wwise startup replacement; in default Arsenal order and HD2MM,
put it below other startup replacements. Purge and redeploy after updates.

## Using an existing archive builder

The archived Lua body must begin with this first line, with no BOM or preceding
whitespace:

```lua
-- HD2-Addon: mods/spacecowboy/better_flashlight
-- Initialize your mod here, preserving any callbacks you extend.
```

Package it as that exact resource name using seed-zero MurmurHash64A. The normal
Lua envelope is a little-endian body length followed by version 2, then the
source. The declaration, including LF or CRLF, must fit in the first 256 bytes.
Empty path segments, trailing slashes and `mods/codex/loader` are not eligible.

Keep this entry **plaintext**: compilation removes the discovery comment.
To retain compiled implementation code, package a separate resource and forward
to it from the plaintext entry:

```lua
-- HD2-Addon: mods/spacecowboy/better_flashlight
return require('mods/spacecowboy/better_flashlight_impl')
```

Your archive builder must include both resources. The single-script helper does
not collect dependencies. Do not also ship a Wwise or boot replacement just to
start your addon. A ZIP directory named `mods/...` alone is not a game resource.

## Optional throwable launch service

`src/throwable_launch.lua` can be packaged as the unmarked Lua resource
`mods/cowboybingus/throwable_launch` and explicitly required by a gameplay addon.
It is not included or started by the standard loader build. The addon owns its
service instance and calls it from its normal Lua update:

```lua
local helper = require('mods/cowboybingus/throwable_launch')
local service = helper.new(reader, game_base, executable_base)
local supported, reason = service.prove()
assert(supported, reason)
service.step(launcher_hashes, grenade_hashes)
-- Call service.step(launcher_hashes, grenade_hashes) on subsequent updates.
```

`reader.read(address, size)` must return exactly that many bytes or nil. Module
bases are numeric addresses; the hash tables are sets of uppercase 16-digit hex
entity hashes. The first snapshot baselines existing objects. Later updates only
release new, inactive, locally owned grenades from listed launchers in solo missions,
after verifying the weapon's selected entity, owner, unit pose and launch speed.
Initialization is retried for up to eight updates. Each eligible object is released
once through existing throwable and explosive routines. Native signatures must
match the supported game build. No engine instructions are patched.

The optional `native` fourth argument to `helper.new` supplies `query`, `release`,
`start` and `arm` callbacks for offline testing. Run service regression tests with:

```powershell
uv run --with lupa python -m unittest discover -s tests -p test_throwable_launch.py -v
```

## Startup and compatibility

Discovery reads deployed `data/9ba626afa44a3aa3.patch_<number>` files once, using
the game executable's location rather than the working directory. It ignores
sidecars and directories. Higher numeric patch indices win; an unmarked
override also hides an older declaration with the same resource identity.
Only explicitly declared entries with matching hashes become startup candidates.

Startup runs in this order:

1. The original Wwise startup.
2. The loader's registry, always in this order:

   ```text
   mods/cowboybingus/vanilla_plus_megapack
   mods/cowboybingus/better_stratagem_bounce
   mods/cowboybingus/hellpod_steering_unlocked
   mods/cowboybingus/wide_angle_stratagems
   mods/cowboybingus/reinforcement_beacon_fix_data
   mods/cowboybingus/consistent_vaulting
   mods/cowboybingus/shallow_water_dive
   mods/cowboybingus/sentry_aim_retention
   mods/cowboybingus/corpse_collision_repair
   mods/cowboybingus/vehicle_stability
   mods/cowboybingus/hover_pack_cancel
   mods/cowboybingus/enemy_intelligence
   mods/codex/gun_calibration
   mods/cowboybingus/armory_preview_cache
   ```

3. Discovered entries, archive by archive from the highest patch number to the
   lowest, and within one archive in the order of its resource table (the
   helper sorts that table by resource hash, not by name).

Full resource names are deduplicated: a declared entry that is also a registry
name starts once, in its registry place. Unavailable entries are skipped;
lookup and initialization failures are logged and do not stop later addons.
There is no automatic retry, hot reload or dependency ordering. Require your
dependencies explicitly and keep your initialization guarded if other code can
start it. Patch numbers follow the order of the mod manager's list, so do not
depend on discovery order between unrelated mods: to act once every mod has
started, use [`after_startup`](#running-code-once-every-mod-has-started) (v19).

`HD2ModLoader` entries already marked `loaded` or `loading` are respected without
merging the two state tables. In-progress entries remain `loading`.

Check `%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/BingusSharedLoader.log` for the
discovery result and each module's status. From v19 each loaded module also gets
a `changes` line listing the globals, library functions, metatables and
collector or JIT settings it changed while loading; keep that line short. Missing built-in FFI or failed
enumeration falls back to the legacy registry. Discovery never executes raw
archive contents; the game's availability check and `require` load the winner.

Manager resource-conflict handling is unchanged. Discovery does not detect
gameplay incompatibilities, authenticate authors or sandbox addon code. Test
your callbacks alongside other mods and document known incompatibilities.

## Copies of the same entry

Two packages can ship the same resource name: a standalone mod and the same mod
inside a pack, or an old and a new release of one mod. The game loads only the
copy in the highest patch, and the module's status reads `loaded` whichever
copy that is. From v19 the line after the status names the copy the game loads
and the hidden ones (six by name, then how many more):

```text
mods/spacecowboy/better_flashlight: loaded
  copies: 9ba626afa44a3aa3.patch_12 (declared) used; hidden: 9ba626afa44a3aa3.patch_7 (compiled)
```

`declared` is a plaintext copy whose first line declares this resource,
`compiled` is LuaJIT bytecode, and `undeclared` is any other copy, including
one whose declaration names another resource. A hidden copy that cannot be
read is listed as `unreadable`; it never changes which entries start. Registry names start whichever
copy wins, but only a declared winning copy starts a discovered entry, so a
declaration below a compiled or undeclared copy of the same resource is not
started. From v19 the log says so after the `Discovery:` line:

```text
Discovery: 6 declared entries
  not started: mods/spacecowboy/better_flashlight, declared in 9ba626afa44a3aa3.patch_3, is hidden by 9ba626afa44a3aa3.patch_12 (compiled)
```

To choose a copy, disable the other package or change the order in your mod
manager, then Purge / Deploy. Both lines are only diagnostics: which entries
start, module statuses and `CowboyBingusModLoader.discovery` are the same as
under v18.

## Testing for loader features

`CowboyBingusModLoader.api` remains exactly `1`. The internal `version` does
not follow the release number (`17` for releases v18 and v19, `16` for v15 to
v17), so never compare it. From v19, test the read-only `capabilities` table:

```lua
local loader = rawget(_G, 'CowboyBingusModLoader')
local caps = loader and loader.capabilities
if caps and caps.jit_budget then
    -- the loader manages the shared LuaJIT code cache
end
```

| Field | The loader supports |
| --- | --- |
| `api` | API `1` (the same number as `loader.api`) |
| `logs` | `open_log` and the shared log folder |
| `discovery` | declared addon entries |
| `jit_budget` | the shared LuaJIT code cache limits and `loader.jit` |
| `health` | the health report in the log and in `loader.health` |
| `after_startup` | `loader.after_startup(fn)`, [below](#running-code-once-every-mod-has-started) |

Without the table the loader is v18 or older; test the fields themselves:
`type(loader.open_log) == 'function'` for logs, `type(loader.discovery) ==
'string'` for discovery (v15+) and `type(loader.jit) == 'table'` for the code
cache (v18+). Capabilities say what the loader supports, not how it went this
session: `loader.discovery` reads `failed: ...` when discovery could not run,
and `loader.jit.managed` is false when the cache limits could not be raised.
The table is read-only and assigning a field raises an error. Its fields are
looked up through its metatable, so `pairs()` lists none of them: test the
names you need. `revision` (`'loader-v19'`) names the build for logs and tools.
Existing globals, module statuses and `open_log` remain.

## Running code once every mod has started

From v19, `CowboyBingusModLoader.after_startup(fn)` runs `fn` once, after every
module of this startup has started (the registry, then the discovered entries)
and before the first game update. Register with Mod Options Menu or Mod Bindings
Menu there, or look for any other mod, instead of polling on your first updates:
the manager's order decides whether they start before or after you.

```lua
local loader = rawget(_G, 'CowboyBingusModLoader')

local function register_options()
    local menu = rawget(_G, 'ModOptionsMenu')
    if not menu then return end  -- not installed
    -- menu.register_option(...)
end

if loader and loader.capabilities and loader.capabilities.after_startup then
    loader.after_startup(register_options)
else
    -- Loader v18 or older: keep retrying on your first updates as before.
end
```

- Callbacks run one at a time, in registration order. One registered while
  another runs (from inside it) waits until that one returns, then runs in the
  same pass, still before the first update.
- Once startup has finished, `after_startup(fn)` runs `fn` at once, before it
  returns.
- Each callback runs under `pcall`. Its error never reaches your code or the
  other callbacks; the loader logs it once, with the module that registered the
  callback, after the `Startup finished` line:

  ```text
  Startup finished: 12 loaded, 0 failed
  After startup: 3 callbacks run, 1 failed
  After startup: callback of mods/spacecowboy/better_flashlight failed: attempt to index a nil value
  ```

  A callback registered after startup is logged as `callback registered after
  startup`. While the callbacks run, the summary reads `After startup: running 3
  callbacks`, so a session that stops inside one shows that in the next
  session's `Previous session:` line.
- It returns `true`, or `false` and a reason when `fn` is not a function or 256
  callbacks were already registered this session. The limit stops a callback
  that registers itself again from holding the game in its startup forever; the
  log says so once.
- A module that registers a callback and then fails to start still gets its
  callback run: check your own state there.
- There is no per-frame work: callbacks run when startup ends, or when they are
  registered later, never on a frame.
- Only modules this loader starts are covered. A mod started some other way, by
  another loader or a boot script, may start after the callbacks ran.

## Windows functions and C types

Every mod runs in the game's single LuaJIT VM, which keeps one set of C
declarations for the game and every mod. The first `ffi.cdef` of a function
name or a `typedef` name wins for the whole session: a later declaration of
the same name is silently ignored, even with a different prototype or layout,
and every call uses the first one. Defining a `struct`, `union` or `enum` tag a
second time raises `attempt to redefine`.

For compatibility with mods written for v18, the loader (v18 and v19) declares
these six functions under their plain Windows names, with exactly this text:

```c
int CreateDirectoryA(const char *path, void *security);
uint32_t GetLastError(void);
uint32_t GetModuleFileNameA(void *module, char *filename, uint32_t size);
void *FindFirstFileA(const char *pattern, void *data);
int FindNextFileA(void *handle, void *data);
int FindClose(void *handle);
```

`GetModuleFileNameA`, `FindFirstFileA`, `FindNextFileA`, `FindClose` and
`GetLastError` are declared before any mod loads, whenever the FFI is
available. `CreateDirectoryA` follows the first time a log is opened (when a
mod calls `open_log`, once the first registry entry is reported, or when a
LuaJIT cache flush is logged), and only if `LOCALAPPDATA` is set. A mod that
declares one of these names later gets the loader's prototype instead of its
own; a mod that declares one first, for example from a boot script, gives its
prototype to every mod after it. From v19 the loader itself calls only private
names, so neither case affects it.

Declare your own functions under private names bound to the Windows symbol
with `__asm__`, and your types under private names too, with a prefix that
names your mod and the version of its declarations:

```lua
local ffi = require('ffi')
ffi.cdef [[
    typedef struct flashlight1_filetime { uint32_t low, high; } flashlight1_filetime;
    void flashlight1_GetSystemTimeAsFileTime(flashlight1_filetime *time) __asm__("GetSystemTimeAsFileTime");
]]
local kernel32 = ffi.load('kernel32')
local now = ffi.new('flashlight1_filetime')
kernel32.flashlight1_GetSystemTimeAsFileTime(now)
```

Never declare types under shared names such as `MEMORY_BASIC_INFORMATION` or
`WIN32_FIND_DATAA`: if another mod declared the name first, your `typedef` is
silently ignored, and sizes and offsets come from the first mod's layout.
Declare once, when your mod loads. When a release changes a private prototype
or layout, change the prefix too (for example `flashlight2_`), because an older
copy of your mod that loaded first keeps its declarations for the session.

## Shared LuaJIT code cache

Every addon runs in the game's single LuaJIT 2.1.0-alpha VM, so they all share
one code cache. Loader v18 raises its limits before any addon starts and
reports its state in `CowboyBingusModLoader.jit` (`managed`, `expanded`,
`mcode_kb`, `traces`, `flushes`, `growths`, `watcher`). Please:

- Do not call `jit.opt.start` with lower `maxmcode` or `maxtrace` values, or
  `jit.flush()`: a flush discards the compiled code of the game and every mod.
- Do not attach a `trace` handler with `jit.attach`. LuaJIT keeps one handler
  per event, so yours would replace the loader's watcher.
- Keep per-frame code lean and free of new closures and errors used for
  control flow: code that cannot compile runs slower, and code that compiles
  into many traces fills the shared cache for everyone.
