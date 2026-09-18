# Example mod

The complete entry script is:

```lua
-- HD2-Addon: mods/example_author/example_mod

-- Put your mod's initialization code here.
print('Hello from Example Mod!')
```

Replace `example_author` and `example_mod` with your names and add your mod code.
Keep the declaration on the first line and save the entry as plaintext UTF-8
without a BOM. Use letters, digits and underscores in each path segment.
Loader v15+ handles discovery and reports whether the entry loaded. You do not
need the old test's API assertions, global diagnostic state, counters or log writer.

## Source path and packaged resource

A convenient source layout is:

```text
mods/
  example_author/
    example_mod.lua
```

That script is packaged as the game resource `mods/example_author/example_mod`
(without `.lua`). The first-line declaration must match this resource name.
The builder calculates the resource's hash and stores the Lua source inside a
patch archive. A loose `mods/...` folder alone will not be loaded by this system.

## Release ZIP folder structure

Your release ZIP must open directly to `manifest.json` and the option folder:

```text
Your-Mod.zip
  manifest.json
  Addon/
    9ba626afa44a3aa3.patch_0
    9ba626afa44a3aa3.patch_0.stream
    9ba626afa44a3aa3.patch_0.gpu_resources
```

`Addon/` is the deployment folder, not your Lua namespace. The manifest's option
must use `"Include": ["Addon"]`. Keep `manifest.json` at the ZIP root; do not put
an extra enclosing project folder around it. The two sidecar files are empty
for this Lua-only example. Arsenal or HD2MM deploys and renumbers the archives
into the game's `data` directory.

This example ZIP also contains these optional, non-deployed reference files:

```text
README.md
Source/
  mods/
    example_author/
      example_mod.lua
```

Authors do not need to ship `Source/` or this README. Editing the reference source
inside the ZIP does not update the archive: rebuild after changing your Lua code.

## Build your mod

From a BingusSharedLoader source checkout, use its packaging helper:

```powershell
python -B scripts/build_addon.py --name mods/your_name/your_mod --entry path/to/your_mod.lua --guid YOUR-STABLE-UUID --display-name "Your Mod" --output Your-Mod.zip
```

The helper creates the four required files above. Generate your own UUID once
with `python -c "import uuid; print(uuid.uuid4())"` and reuse it for updates to
the same mod. Use a matching declaration if your script already includes one;
the helper inserts it if it is absent. List Bingus Shared Loader v15 or newer
as a requirement for players.

To rebuild this exact example from the source checkout, run:

```powershell
python -B examples/build.py
```

## Try this example

With the game closed, replace the earlier Discovery Test with
`Bingus-Example-Mod-v2.zip` in Arsenal or HD2MM. It retains the example package's
GUID. Keep Loader v15+ enabled, then Purge / Deploy and launch the game.

Check the newly written
`%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/BingusSharedLoader.log` for:

```text
mods/example_author/example_mod: loaded
```

The example only prints a greeting. It has no gameplay effect or on-screen
indicator and no longer creates `BingusDiscoveryTest.log`. That older file may
remain on disk; it is not used by this version.
