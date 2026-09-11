# Third-party inputs

LuaJIT (MIT) compiles the runtime Lua sources and runs isolated checks. Supply a Windows x64 non-GC64 build matching the supported game's bytecode mode.

The loader embeds the supported game's original Wwise callbacks in its generated archive. Developers extract that resource and the test boot resource from their own installation; extracted game resources and compiled releases are excluded from source control.

Optional integration tests use locally supplied HDArsenal, HD2MM and HUD+ fixtures. Those applications and mod resources are not bundled with this source project. No repository-wide license has been selected.

Artwork was generated with GPT-6 Astra assistance using the existing mod artwork as style references, and includes a visible AI disclosure.
