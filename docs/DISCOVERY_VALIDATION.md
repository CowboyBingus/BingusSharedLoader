# v15 validation

Offline validation completed on 2026-09-18. API remains exactly 1, the internal
coordinator version is 16, and the manager GUID remains
`612eaf70-d682-43c7-9efd-16dcc695f977`.

The built main archive SHA-256 is
`8312B06178AD1E63F0F07444920F5E1F61A69ADF1E62770786DA09AF70337E18`.
`build/build-report.json` records source and ZIP hashes and `runtime_verified: false`.

| Check | Result |
| --- | --- |
| Existing coordinator regression suite | All 16,384 installed-mod combinations, with lookup/module failure variants and original callback comparisons, passed. |
| Shared logging | Existing folder, filename and nonfatal I/O/FFI failure checks passed. |
| Discovery | Hash vectors, declarations, archive bounds, numeric priority, unmarked/mismatched shadowing, bounded reads and handle cleanup passed. |
| Author helper | Finished ZIP manifest, GUID, resource hash, envelope, plaintext entry and invalid input checks passed. |
| Assembled runtime | Compiled bootstrap with toy stock bytecode and independent addon packages passed real Windows enumeration, legacy order, API 1, deduplication, reentry/failure isolation and dispatcher coexistence checks. Stock arguments and nil-containing return tuples were preserved. |
| Existing HUD/overlay integration | 128 combinations passed with the locally supplied HUD+ and Overlay v2 fixtures. |
| Arsenal 0.36.0 backend fixture | Loader plus two addon ZIPs: all 48 load-order/removal combinations preserved deployed bytes and clean purge. |
| HD2MM backend fixture (pinned below) | Loader plus two addon ZIPs: 34 deployment/profile cases passed, including patch numbering, Skip List offset, resource ownership, option disabling and explicit purge. |

Manager checks used the existing locally supplied backend fixtures and fresh
isolated profiles. The HD2MM source fixture is pinned to
`21838c31a77a6b459da93d224e1827f1f3998f91`; its settings host confines writes to
the fixture. Results are in `build/discovery-managers/arsenal-final/pair-compatibility.json`
and `build/discovery-managers/hd2mm-final/report.json`. Test packages contain
only generic example addons. No installed game or user profile was changed.

HD2MM retains its previously observed behavior: deploying with zero enabled
mods leaves existing patches until explicit Purge. This change does not modify
that manager behavior.

The maintainer reported preliminary in-game success and confirmed that the
example addon loaded. That report does not cover every gameplay combination,
audio/HUD interaction or engine override order. Offline tests cannot establish
those results. The build retains `runtime_verified: false` because this archive
does not match the older hash recorded as fully verified; that older verification
claim is not reused.
