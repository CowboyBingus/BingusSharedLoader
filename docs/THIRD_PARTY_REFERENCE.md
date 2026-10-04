# Third-party reference

For authors of Helldivers 2 mods that run beside the CowboyBingus mods. Every Lua
mod shares the game's one LuaJIT VM, its globals, its files and its native UI.
This page lists what the CowboyBingus mods use, so that your mod can stay clear
of it. It describes the sources released with Bingus Shared Loader v19, for Steam
build 25480438 (October 2026). Each mod's README documents its own API in full.

## Loader contract (API 1)

Bingus Shared Loader replaces `core/wwise/lua/wwise_flow_callbacks`. That resource
runs the game's original callbacks, then starts the mods and creates one global,
`CowboyBingusModLoader`. A second copy of the loader finds the table and does
nothing.

| Field | Meaning |
| --- | --- |
| `api` | `1`. |
| `version` | `17` in v18 and v19; it does not follow the release number. Never compare it. |
| `revision` | `'loader-v19'`, for logs and tools. |
| `capabilities` | Read-only: `api`, `logs`, `discovery`, `jit_budget`, `health`, `after_startup`. Test these, not `version`. v18 and older have no table. |
| `modules` | Resource name to status: `loaded`, `loading`, `not installed`, `load failed: ...` or `lookup failed: ...`. |
| `discovery` | `N declared entries` (plus archive warnings) or `failed: ...`. |
| `open_log(name)` | A file open for writing in `%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs`, or nil. `name` must match `^[%w_-]+%.log$`. Each call empties the file. |
| `log_directory` | That folder, once it exists. |
| `after_startup(fn)` | Runs `fn` once, after every module of this startup has started and before the first game update; at once when startup is over. See [AUTHORING.md](AUTHORING.md#running-code-once-every-mod-has-started). |
| `jit` | The shared LuaJIT code cache: `managed`, `expanded`, `mcode_kb`, `traces`, `flushes`, `growths`, `watcher`. |
| `health` | The health report in the loader log (`header`, `changes`). |
| `megapack` | Set by Vanilla Plus Megapack: `name`, `revision`, `modules`. |

For mods written against v18, the loader declares six Windows functions under
their plain names, with exactly these prototypes, at the same moments as v18.
They will not change:

```c
int CreateDirectoryA(const char *path, void *security);
uint32_t GetLastError(void);
uint32_t GetModuleFileNameA(void *module, char *filename, uint32_t size);
void *FindFirstFileA(const char *pattern, void *data);
int FindNextFileA(void *handle, void *data);
int FindClose(void *handle);
```

The first `ffi.cdef` of a name wins for the whole game, so declare your own
functions and types under private names (`yourmod1_Name(...) __asm__("Name")`),
never shared ones such as `MEMORY_BASIC_INFORMATION`. Every CowboyBingus mod does.

Before any mod starts, the loader raises the shared LuaJIT code cache limits.
Do not lower `maxmcode` or `maxtrace`, and do not call `jit.flush()`. Do not
attach a `trace` handler either: yours would replace the loader's watcher.
`jit.off(fn)` on your own functions is fine.

## Discovery and start order

1. The game's original Wwise callbacks.
2. The registry, in this order:
   - under `mods/cowboybingus/`: `vanilla_plus_megapack`,
     `better_stratagem_bounce`, `hellpod_steering_unlocked`,
     `wide_angle_stratagems` (reserved), `reinforcement_beacon_fix_data`,
     `consistent_vaulting`, `shallow_water_dive`, `sentry_aim_retention`,
     `corpse_collision_repair`, `vehicle_stability`, `hover_pack_cancel`,
     `enemy_intelligence`;
   - `mods/codex/gun_calibration` (HUD Ballistic Trajectory Overlay v2);
   - `mods/cowboybingus/armory_preview_cache`.
3. Declared entries in the deployed `data/9ba626afa44a3aa3.patch_<n>` archives:
   - highest patch number first;
   - within one archive, in the order of its resource table (sorted by
     resource hash, not by name).

   A declared entry is plaintext Lua whose first line, within the first 256
   bytes, is `-- HD2-Addon: mods/<author>/<entry>`. Each segment uses only
   letters, digits and underscores. A higher compiled or undeclared copy of the
   same resource hides the entry.
4. The `after_startup` callbacks, in registration order.
5. The first game update.

Each name starts once. A failure is logged, and the next module starts anyway.
Patch numbers follow the mod manager's list, so the player decides the order of
unrelated mods. Use `after_startup` to act once everything has started.

Mod Options Menu, Mod Bindings Menu, Better Lobby Management, Clickable
Scrollbars, Ship Station Hotkeys, Flame Damage Fixed and Arc Thrower Revamped
are discovered entries; the other CowboyBingus mods start from the registry.
Packaging details are in [AUTHORING.md](AUTHORING.md). Vehicle Stability and
Wide Angle Stratagems hold registry names but are not covered here.

## Files, logs and globals

All logs live in one flat folder, `%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs`,
and each is rewritten every session. Do not reuse these file or global names.
Several mods keep a retired name so that existing files and tools keep working.

| Mod | Resource under `mods/cowboybingus/` | Files | Global |
| --- | --- | --- | --- |
| Bingus Shared Loader | (`core/wwise/lua/wwise_flow_callbacks`) | `BingusSharedLoader.log` | `CowboyBingusModLoader` |
| Vanilla Plus Megapack | `vanilla_plus_megapack`, plus each component's own name | none; components keep their own file names | `CowboyBingusModLoader.megapack` |
| Arc Thrower Revamped | `arc_thrower_auto` (retired) | `ArcThrowerAuto.log` (retired) | `ArcThrowerRevampedInstalled` |
| Armory Preview Cache | `armory_preview_cache` | `ArmoryPreviewCache.log`; in `%LOCALAPPDATA%` itself: `ArmoryPreviewCache.ini` (read only), `ArmoryPreviewCache.profile` (with `.profile.tmp`, `.profile.bak`) | `ArmoryPreviewCache` |
| Better Lobby Management | `better_lobby_management` | `BetterLobbyManagement.log` | `BetterLobbyManagement` |
| Better Stratagem Bounce | `better_stratagem_bounce` | `BetterStratagemBounce.log` | `BetterStratagemBounce` |
| Clickable Scrollbars | `clickable_scrollbars` | `ClickableScrollbars.log`; `%LOCALAPPDATA%/ClickableScrollbars/ClickableScrollbars.ini` (read only) | `ClickableScrollbars` |
| Consistent Vaulting | `consistent_vaulting` | `ConsistentVaulting.log` | `ConsistentVaulting` |
| Controllable Hover Pack | `hover_pack_cancel` (retired) | `ControllableHoverPack.log` | `HoverPackCancel` (retired) |
| Enemy Collision Synchronized | `corpse_collision_repair` (retired) | `CorpseCollisionRepair.log` (retired); `EnemyCollisionSynchronized-Performance.log` (diagnostics only) | `CorpseCollisionRepair` (retired) |
| Flame Damage Fixed | `flame_damage_fixed` | `FlameDamageFixed.log` | `FlameDamageFixedInstalled` |
| Hellpod Steering Unlocked | `hellpod_steering_unlocked` | `HellpodSteeringUnlocked.log` | `HellpodSteeringUnlocked` |
| Know Your Constellation | `enemy_intelligence` (retired) | `EnemyIntelligence.log` (retired) | `EnemyIntelligence` (retired) |
| Mod Bindings Menu | `mod_bindings_menu`, plus `content/input.config` | `ModBindingsMenu.log`; `ModBindingsMenu.assignments` (with `.tmp`, `.bak`) | `ModBindingsMenu` |
| Mod Options Menu | `mod_options_menu` | `ModOptionsMenu.log`; `ModOptionsMenu.values` (with `.tmp`, `.bak`) | `ModOptionsMenu` |
| Reinforcement Beacons Fixed | `reinforcement_beacon_fix_data` | `ReinforcementBeaconsFixed.log` | `ReinforcementBeaconFixData` (retired) |
| Sentry Aim Retention | `sentry_aim_retention` | `SentryAimRetention.log` | `SentryAimRetention` |
| Shallow Water Diving | `shallow_water_dive` (retired) | `ShallowWaterDiving.log` | `ShallowWaterDive` (retired) |
| Ship Station Hotkeys | `galactic_menu_hotkey` (retired) | `GalacticMenuHotkey.log` (retired) | `GalacticMenuHotkeyInstalled` (retired) |

The values and assignments files sit in the Logs folder. When the loader has no
log folder, Mod Bindings Menu falls back to `%LOCALAPPDATA%/CowboyBingus/Helldivers2`.

Shared tables:
- `BingusRuntime`: the runtime's session cache of module hashes and guard
  statuses (see the last section).
- `BingusTranslations`: the translation registry used by Mod Options Menu, Mod
  Bindings Menu, Better Lobby Management, Ship Station Hotkeys, Know Your
  Constellation and Shallow Water Diving.

Global switches they read:
- `CowboyBingusDiagnostics = true` makes Armory Preview Cache, Consistent
  Vaulting, Controllable Hover Pack, Enemy Collision Synchronized, Sentry Aim
  Retention and Shallow Water Diving log more.
- `ArcThrowerDiagnostics` does the same for Arc Thrower Revamped.

## Menus, input and UI

- **Escape menu tabs.** Mod Options Menu adds a fourth tab, MODS, after GAME,
  SOCIAL and OPTIONS. If another mod has already added a fourth tab, it adds
  none. It uses the game's APPLY button and UNAPPLIED CHANGES prompt.
- **Mod Options Menu limits.**
  - Mods: 8, one category button each, shown alphabetically. The 9th mod's
    `register_option` returns `false, 'all 8 mod categories are in use'`.
  - Options: 32 per mod, of type `toggle`, `choice` (2 to 16 choices, each at
    most 48 characters) or `slider`.
  - Text: id at most 96 bytes; label 64, mod name 40, description 400 characters.
  - Category key: a mod's options stay together by `mod_id` (at most 64
    characters of `[%w_.-/:]`). Without one, they stay together by the
    registering addon and the name it gave first.
  - API (`api = 1`, `version = 3`): `register_option`, `get`, `set`,
    `on_change`, `ready`.
- **Escape menu GAME list.** The list holds at most 5 native buttons, and the
  game uses button types 0 to 4. Better Lobby Management:
  - adds its buttons, types 5, 6 and 7, only while fewer than 5 buttons are
    present (other mods' buttons count);
  - treats any button of type 5 to 7 as its own;
  - calls the game's list rebuild when one of its actions is no longer offered.
    The game also runs that rebuild when the host or mode changes, and it drops
    every button the game did not add (Better Lobby Management's TECHNICAL.md);
  - fills the game's shared confirm dialog while one of its buttons has focus;
  - runs its own searches in the game's lobby browser: it waits while a game
    search runs, then clears the browser's filters before searching.
- **Binding pages: Mod Bindings Menu.**
  - It adds a fourth tab, MODS, to both binding pages, and treats any fourth tab
    there as its own. It adds none if the title slot it borrows is taken.
  - It replaces the whole `content/input.config`, pinned to build 25480438.
    Another input.config replacement conflicts with it, and its replacement
    stays deployed even while the mod is inactive.
  - It repurposes 36 dormant developer actions in input groups 9 to 12
    (Freeflight, CinematicCamera, DebugAvatar, Debugmenu): 7 fixed slots and 29
    assigned automatically. Past those 29, registration fails with
    `all 29 automatic binding actions in use`.
  - It relabels an action only for a registered binding, only while its page is
    built, and leaves alone a label another mod changed.
  - Every 2 seconds with no binding page open, it sweeps the mappings of the
    actions that bindings use this session; other dormant actions are left
    alone. Inherited developer defaults are cleared once, and the player's
    choices are kept.
  - Labels and section headers borrow empty entries of a 65-slot localization
    pool while the page is open. Labels can have up to 127 characters,
    categories 64.
  - An id keeps its action until it has not registered for 30 sessions.
  - API: `register_binding(id, label, slot, options)`, `is_down(id)`, `ready()`,
    `revision`. When `is_down` returns nil, native input is not ready: use your
    own default key.
- **Ship Station Hotkeys** takes fixed slots 1 and 3 to 7 (Tab, F1, F5 to F8;
  slot 2 is left for other mods). It polls those keys with `GetAsyncKeyState`
  while the game has focus.
- **Clickable Scrollbars** consumes the game's UI_SELECT input action ("until
  release") on the settings page's list. It does so from a press on the
  scrollbar until the physical mouse button comes up, and only while the game is
  in the foreground. It reads the left mouse button and the cursor itself,
  writes the list's scroll position through the game's own setters, and sends
  no input.
- **Armory Preview Cache** owns the equipment thumbnails on the armory grid, the
  weapon and cosmetic preselect screens and the mission briefing while it shows
  a cached image there:
  - it sets their texture, uv, size and alpha;
  - when it keeps an image, it swaps the image manager's working atlas, and puts
    the original back when it stops.

  Leave those elements and the working atlas alone. It also leases up to 128
  asset packages through the game's own acquire and release.
- **Know Your Constellation** never changes native widgets. It draws its own
  screen GUI on layers 1011 to 1015 over the galactic map and the mission
  briefing; squad nameplates draw between 1000 and 1011.

## Game state the gameplay mods change

Each mod restores a value only while it still holds what the mod wrote, and
leaves alone a value someone else set.

| Mod | What it changes | Rule for other mods |
| --- | --- | --- |
| Better Stratagem Bounce | Bit 0x02 (deploy on navmesh only) of the navigation flags at +0x170, in 103 of the 149 stratagem records, once per session | It leaves the other bits as it found them. |
| Hellpod Steering Unlocked | The hellpod avoidance flag byte. It writes 0 only over the game's 1, checking about 10 times a second | It leaves any other value alone, and puts 1 back on pause or stop if the byte still holds 0. |
| Flame Damage Fixed | Havok system groups 2040 to 2047 (bits 21-31 of the collision filter info) on its weapons' bodies and flames. The groups are not reserved in the allocator | Take groups from 2039 downward; see its README. |
| Arc Thrower Revamped | The Arc Thrower charge record's `auto_fire_in_safety` byte (+184), through a page protection change, checked again every 15 updates. Also the charge entry's charging flag while Fire is held | It puts the byte back on pause, stop and shutdown. |
| Consistent Vaulting | Vault query fields; slope angles, climb height, speed cap and slope cosine | It acts only on the default slide settings. It can make the engine create a local settings override for the avatar. |
| Controllable Hover Pack | The worn pack's hover duration; a per-pack settings override in free storage | It restores only its own value. |
| Sentry Aim Retention | Retention bit, turret speeds, aim fields, fire mode and reselection deadline, only for sentries this machine controls | It restores each one only while it still holds the mod's value. |
| Reinforcement Beacons Fixed | The pending spawn position at player manager +0x10C | It restores it only while it still holds the mod's bytes. |
| Shallow Water Diving | The water record's reference height (+8) | It takes it only from the prone default. |
| Enemy Collision Synchronized | No memory writes; engine commands for ragdolls this machine does not own | None. |

## Update chain

Most CowboyBingus mods wrap the global `update` (some also `shutdown`) and call
the previous one outside `pcall`, so an error your update raises reaches the game
as your error.

It still affects them:
- After an error below it, a mod that can put its game state back does so and
  pauses until the updates below have returned on 60 frames in a row.
- 8 errors in one burst, its own or below it, stop a mod for the session. The
  count starts again after 3600 frames without an error.

So keep your update from raising, and when you wrap it, pass every argument and
return value through.

## Bingus Shared Runtime

The shared code most of these mods vendor byte-identical is published as the
[Bingus Shared Runtime](https://github.com/CowboyBingus/BingusSharedRuntime):
- private, versioned FFI names;
- checked memory reads and writes;
- one module hash per session;
- the update guard described above.

It creates the `BingusRuntime` table.
