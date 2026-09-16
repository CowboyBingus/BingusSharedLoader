## loader-v12

- Registers Know Your Constellation through its stable internal module identity.
- Retains API 1, existing module order, callback forwarding and optional-mod isolation.
- The packaged runtime matches the loader used for in-game confirmation of Know Your Constellation.
- Supports Vanilla Plus Megapack v7 with the loader installed separately.

## loader-v11

Registers Controllable Hover Pack and retains the optional Vehicle Stability module, API 1, existing resource identities and callback handling. Controllable Hover Pack's manual cutoff and native landing assistance were confirmed in-game with this loader. Missing optional modules remain isolated.

## loader-v10

- Registers the optional Vehicle Stability module for the Bastion and gunner FRV.
- Keeps API 1 and existing module identities. Checks all 2,048 optional-module combinations.
- This new loader build and the vehicle intervention require in-game validation. previous loader gameplay confirmations do not validate the new module.

## loader-v9

Versioned Arsenal names and ZIP filenames. updated Enemy Collision Synchronized branding and installation guidance for the seven-component megapack. Retains the existing registry, API 1, manager GUID and callback handling. Runtime marker advances to 10.

# Bingus Shared Loader - release notes

## loader-v7 - Vanilla Plus Megapack support

Adds `mods/cowboybingus/vanilla_plus_megapack` to the optional registry. The megapack combines all six current CowboyBingus gameplay modules in one manager entry and keeps this loader as a separate dependency. Existing module startup order, API 1, manager GUID, Wwise callbacks and overlay support are preserved.

Replace the old loader, disable individual gameplay copies when using the megapack, then Purge / Deploy. Use loader-last ordering with Arsenal's default priority. Offline verification covers all 512 registry combinations. live validation of this revision remains pending.

## loader-v6 - module registry update

Registers the optional Sentry Aim Retention module and supports Consistent
Vaulting data-v8 through the existing registry and API 1 interface. The manager
GUID, original Wwise callbacks and existing overlay registration are preserved.
Offline startup checks cover all 256 module-presence combinations. Arsenal
fixture checks with this loader, the sentry module and Better Stratagem Bounce
cover all 48 order/enable combinations and purge. Gameplay validation is pending.
Published as a prerelease while live validation is pending. Download the
installable ZIP from [loader-v6](https://github.com/CowboyBingus/BingusSharedLoader/releases/tag/loader-v6).

## loader-v5 - gameplay module support

Adds startup registration for Consistent Vaulting and Shallow Water Diving.
API 1 and the manager GUID remain unchanged. existing gameplay packages stay
compatible. Missing modules are skipped and failures remain isolated.

Offline tests cover all 128 registered-module combinations, original audio
callbacks, duplicate loads and callback returns. Package checks verify distinct
resource ownership across load orders. In-game validation of loader-v5 remains
pending, so it is published as a prerelease.

Replace the previous loader entry, then Purge and Deploy with the game closed.
[Download loader-v5](https://github.com/CowboyBingus/BingusSharedLoader/releases/tag/loader-v5).

## loader-v3

> [!IMPORTANT]
> **Required dependency for Better Stratagem Bounce, Hellpod Steering Unlocked and Reinforcement Beacons Fixed.** Install with **Arsenal or HD2MM**: import `BingusSharedLoader.zip`, enable it alongside your chosen mods, then click **Deploy**. One loader installation supports all your selected mods.
>
> **Arsenal (default priority): place Bingus Shared Loader LAST, at the bottom of the load order**, then **Purge to Deploy**. If you enabled first-mod priority, place the loader first instead.

Adds built-in startup support for HUD Ballistic Trajectory Overlay v2, released September 11, 2026. Install the original overlay separately and give Bingus Shared Loader the winning priority over it. Arsenal's shared-file warning remains expected. no extra compatibility package is required.

Install `BingusSharedLoader.zip` alongside the chosen gameplay mods. Replace the previous loader entry, then Purge and Deploy with the game closed. Do not install old and renamed copies together.

The manager GUID and API 1 remain unchanged. Existing module-only gameplay packages need no rebuild. The loader preserves original Wwise callbacks, leaves HUD+ and boot unchanged, skips missing modules and isolates load failures. It has no gameplay effect alone.

The maintainer confirmed loader-v3 works in-game with Overlay v2. The published runtime matches that tested build. The overlay also passes 64 offline startup combinations with HUD+ 0.1.3 and the current gameplay packages. Configuration reads, callback forwarding and duplicate initialization are covered. Arsenal import, deployment, removal and purge checks passed for all five packages across 3,840 order and enable-state combinations. These checks do not certify every gameplay mod's behavior.

Download `BingusSharedLoader.zip` for installation. `BingusSharedLoader-source.zip` contains the source, and `SHA256SUMS.txt` covers both ZIPs. Extracted game and third-party resources are excluded from the source package.

**AI disclosure:** GPT-6 Astra assisted with research, implementation, debugging, documentation and artwork.

[Download this release](https://github.com/CowboyBingus/BingusSharedLoader/releases/tag/loader-v3)

## loader-v11 candidate

Adds the optional Hover Pack Cancel resource. Existing module identities and ordering, API 1, manager GUID and Wwise callback preservation remain unchanged. Offline startup and package checks pass. this revision has not been validated in-game.
