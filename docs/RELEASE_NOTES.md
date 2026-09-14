# Bingus Shared Loader — release notes

## loader-v5 — gameplay module support

Adds startup registration for Consistent Vaulting and Shallow Water Diving.
API 1 and the manager GUID remain unchanged; existing gameplay packages stay
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
> **Arsenal (default priority): place Bingus Shared Loader LAST, at the bottom of the load order**, then **Purge → Deploy**. If you enabled first-mod priority, place the loader first instead.

Adds built-in startup support for HUD Ballistic Trajectory Overlay v2, released September 11, 2026. Install the original overlay separately and give Bingus Shared Loader the winning priority over it. Arsenal's shared-file warning remains expected; no extra compatibility package is required.

Install `BingusSharedLoader.zip` alongside the chosen gameplay mods. Replace the previous loader entry, then Purge and Deploy with the game closed. Do not install old and renamed copies together.

The manager GUID and API 1 remain unchanged. Existing module-only gameplay packages need no rebuild. The loader preserves original Wwise callbacks, leaves HUD+ and boot unchanged, skips missing modules and isolates load failures. It has no gameplay effect alone.

The maintainer confirmed loader-v3 works in-game with Overlay v2. The published runtime matches that tested build. The overlay also passes 64 offline startup combinations with HUD+ 0.1.3 and the current gameplay packages. Configuration reads, callback forwarding and duplicate initialization are covered. Arsenal import, deployment, removal and purge checks passed for all five packages across 3,840 order and enable-state combinations. These checks do not certify every gameplay mod's behavior.

Download `BingusSharedLoader.zip` for installation. `BingusSharedLoader-source.zip` contains the source, and `SHA256SUMS.txt` covers both ZIPs. Extracted game and third-party resources are excluded from the source package.

**AI disclosure:** GPT-6 Astra assisted with research, implementation, debugging, documentation and artwork.

[Download this release](https://github.com/CowboyBingus/BingusSharedLoader/releases/tag/loader-v3)
