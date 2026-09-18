# Making a discoverable mod

Bingus Shared Loader v15 adds startup discovery while keeping API 1. Existing
registered mods still work without repackaging. See [validation coverage](DISCOVERY_VALIDATION.md).

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

## Startup and compatibility

Discovery reads deployed `data/9ba626afa44a3aa3.patch_<number>` files once, using
the game executable's location rather than the working directory. It ignores
sidecars and directories. Higher numeric patch indices win; an unmarked
override also hides an older declaration with the same resource identity.
Only explicitly declared entries with matching hashes become startup candidates.

Original Wwise startup runs before addons. The existing registry runs in its
original order, followed by discovered entries in archive priority/resource
table order. Full resource names are deduplicated. Unavailable entries are
skipped; lookup and initialization failures are logged and do not stop later
addons. There is no automatic retry, hot reload or dependency ordering. Require
your dependencies explicitly and keep your initialization guarded if other code
can start it. Do not depend on discovery order between unrelated mods.

`CowboyBingusModLoader.api` remains exactly `1`; the internal version is `16`
for release v15. Existing globals, module statuses and `open_log` remain.
`HD2ModLoader` entries already marked `loaded` or `loading` are respected without
merging the two state tables. In-progress entries remain `loading`.

Check `%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/BingusSharedLoader.log` for the
discovery result and each module's status. Missing built-in FFI or failed
enumeration falls back to the legacy registry. Discovery never executes raw
archive contents; the game's availability check and `require` load the winner.

Manager resource-conflict handling is unchanged. Discovery does not detect
gameplay incompatibilities, authenticate authors or sandbox addon code. Test
your callbacks alongside other mods and document known incompatibilities.
