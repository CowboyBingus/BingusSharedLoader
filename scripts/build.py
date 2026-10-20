"""Build the separately installed Wwise coordinator and verify it offline."""
import json
import os
from pathlib import Path
import struct
import subprocess
import sys

sys.dont_write_bytecode = True

from archive import ARCHIVE, BOOT, BOOT_SHA, LUA, EXE_SHA, GAME_DLL_SHA, make_archive, resource_hash, sha
from package import package_release

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build'
CALLBACK_SHA = '05BBF52978028758B39F5B91A30A695D20069CEABD774D88755F0582A296BEC9'
CALLBACK_PATH = 'core/wwise/lua/wwise_flow_callbacks'
# The SHA-256 of the Wwise callbacks resource the maintainer played, or None
# while no played build is pinned. Only scripts/pin_tested.py writes it, from a
# clean TestHarness run that deployed the release ZIP holding that resource;
# runtime_verified is true only for it.
# Cleared for v21: the resource changed with the supported game build, so nothing is
# pinned until a clean run plays this build.
TESTED_CALLBACK_SHA = None


def run(args, **kwargs):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


# Development-only variant, never published: --probe embeds src/frame_probe.lua. Its hooks
# are inserted into the coordinator text here, so the public build's sources and resource
# stay as they are.
PROBE_REVISION = 'loader-v21-probe4'
PROBE_HOOKS = [
    # Before the first module starts: the probe wraps the game's update and render,
    # and the loader log names the probe on its second line (the study checks the first).
    ("for _, name in ipairs(names) do\n    local other = rawget(_G, 'HD2ModLoader')",
     "local probe\nif frame_probe then\n"
     "    local ok, value = pcall(frame_probe.start, state)\n"
     "    if ok then probe = value; state.frame_probe = value else state.frame_probe_failure = tostring(value) end\n"
     "    state.revision = '" + PROBE_REVISION + "'\n"
     "    table.insert(header, 1, 'Development build " + PROBE_REVISION + ": frame probe schema 4 '\n"
     "        .. (ok and 'running' or 'not running') .. '; never publish')\n"
     "end\n", 'before'),
    # After each module's require: a changed update or render becomes that module's layer.
    ("            local loaded, reason = observed_require(name)\n",
     "            if probe then pcall(probe.after, name) end\n", 'after'),
]


def probe_coordinator(coordinator):
    """The coordinator with the frame probe's hooks; each anchor must occur exactly once."""
    for anchor, hook, where in PROBE_HOOKS:
        if coordinator.count(anchor) != 1:
            raise ValueError('probe anchor not found exactly once: ' + anchor.splitlines()[0])
        coordinator = coordinator.replace(anchor, hook + anchor if where == 'before' else anchor + hook)
    return coordinator


# Bingus Shared Runtime v1 files (github.com/CowboyBingus/BingusSharedRuntime), vendored
# byte-identical for the build gate; never edit a copy. The loader only reads module
# files, so it never vendors bingus_write.lua.
VENDORED = {
    'src/bingus_runtime.lua': 'C4450F555F697E583916D18F876412CA96F6963EB1BF4CDAD451EBB906C2F988',
    'src/bingus_memory.lua': '3973924B1C009CC4E6C863A4EAF87F166899A16DDCB579C3D77AB5465172B416',
}


def vendored(relative):
    """A vendored runtime file's text, after checking it is the pinned copy."""
    data = (ROOT / relative).read_bytes()
    if sha(data) != VENDORED[relative]:
        raise ValueError(f'{relative} differs from its Bingus Shared Runtime copy (SHA-256 {sha(data)})')
    return data.decode('utf-8')


def build_gate():
    """The build gate chunk: src/build_gate.lua over the vendored runtime and this release's
    supported build. The runtime's require is the builtin one, never a game resource; the
    pins are locals, so nothing outside the resource can change them."""
    return ('local build_gate = (function(require)\n'
            'local bingus_runtime = (function()\n' + vendored('src/bingus_runtime.lua') + '\nend)()\n'
            'local bingus_memory = (function()\n' + vendored('src/bingus_memory.lua') + '\nend)()\n'
            'local gate = (function()\n' + (ROOT / 'src/build_gate.lua').read_text(encoding='utf-8') + '\nend)()\n'
            f"local builds = {{{{exe_sha256 = '{EXE_SHA}', game_sha256 = '{GAME_DLL_SHA}'}}}}\n"
            'return {check = function() return gate.check(bingus_runtime, bingus_memory, builds) end}\n'
            'end)(function(name)\n'
            '    local loaded = package and package.loaded and package.loaded[name]\n'
            '    if loaded then return loaded end\n'
            "    if not (package and package.preload and package.preload[name]) then error(name .. ' builtin unavailable', 0) end\n"
            '    return require(name)\n'
            'end)\n')


def bootstrap(stock_bytes, probe=False):
    literal = '"' + ''.join(f'\\{byte:03d}' for byte in stock_bytes) + '"'
    discovery = (ROOT / 'src/discover.lua').read_text(encoding='utf-8')
    budget = (ROOT / 'src/jit_budget.lua').read_text(encoding='utf-8')
    churn_guard = (ROOT / 'src/jit_guard.lua').read_text(encoding='utf-8')
    health = (ROOT / 'src/health.lua').read_text(encoding='utf-8')
    coordinator = (ROOT / 'src/shared_loader.lua').read_text(encoding='utf-8')
    timing = ''
    if probe:
        coordinator = probe_coordinator(coordinator)
        timing = ('local frame_probe = (function()\n' + (ROOT / 'src/frame_probe.lua').read_text(encoding='utf-8')
                  + '\nend)()\n')
    # Preserve startup arguments and all results, including trailing nils. A stock
    # runtime error propagates: native initialization must never be retried.
    # discover.lua and health.lua turn the JIT off for the function each runs in: keep their wrappers.
    return ('local function initialize_addons()\n'
            + build_gate() +
            'local addon_discovery = (function()\n' + discovery + '\nend)()\n'
            'local jit_guard = (function()\n' + churn_guard + '\nend)()\n'
            'local jit_budget = (function()\n' + budget + '\nend)()\n'
            'local loader_health = (function()\n' + health + '\nend)()\n'
            + timing + coordinator + '\nend\n'
            'return (function(...) initialize_addons(); return ... end)'
            f'(assert(loadstring({literal}, "@vanilla_wwise_callbacks"))(...))\n')


def vanilla_inputs():
    """The supported game's boot and Wwise callbacks resources, checked by hash and header."""
    boot = BOOT.read_bytes()
    callback = Path(os.environ.get('HD2_CALLBACK_RESOURCE',
        ROOT / 'artifacts/vanilla/wwise_flow_callbacks.lua.main')).read_bytes()
    if sha(boot) != BOOT_SHA or struct.unpack('<II', boot[:8]) != (326, 2):
        raise ValueError('Unsupported vanilla boot fixture')
    if sha(callback) != CALLBACK_SHA or struct.unpack('<II', callback[:8]) != (10263, 2):
        raise ValueError('Unsupported vanilla Wwise callbacks')
    return boot, callback


def compile_resource(callback, folder, probe=False):
    """The loader's Wwise callbacks resource (header and bytecode) built from the current
    sources in folder; also leaves callbacks.wrapper.lua and callbacks.ljbc there."""
    source = folder / 'callbacks.wrapper.lua'
    source.write_text(bootstrap(callback[8:], probe), encoding='utf-8', newline='\n')
    env = dict(os.environ, LUA_PATH=str(LUA.parent / '?.lua') + ';;')
    run([LUA, '-bsdW', source, folder / 'callbacks.ljbc'], env=env)
    bytecode = (folder / 'callbacks.ljbc').read_bytes()
    if bytecode[:5] != callback[8:13]:
        raise ValueError('LuaJIT bytecode mode differs from the game')
    return struct.pack('<II', len(bytecode), 2) + bytecode


def release_tests(folder, env):
    """The suites that pin the release resource built in folder: its log, contract and pin."""
    # The build gate: unknown builds and failed checks start nothing; the supported build shares its hashes.
    tests = run([LUA, ROOT / 'tests/test_build_gate.lua', ROOT / 'src', folder], env=env)
    tests += run([sys.executable, ROOT / 'tests/game_lua.py', ROOT / 'tests/test_build_gate.lua', ROOT / 'src', folder],
                 env=env)
    tests += run([LUA, ROOT / 'tests/test_shared_loader.lua', ROOT / 'src', folder], env=env)
    tests += run([LUA, ROOT / 'tests/test_health.lua', ROOT / 'src', folder], env=env)
    tests += run([LUA, ROOT / 'tests/test_after_startup.lua', ROOT / 'src', folder], env=env)
    tests += run([sys.executable, ROOT / 'tests/game_lua.py', ROOT / 'tests/test_health.lua', ROOT / 'src', folder],
                 env=env)
    tests += run([sys.executable, ROOT / 'tests/game_lua.py', ROOT / 'tests/test_after_startup.lua', ROOT / 'src',
                  folder], env=env)
    # Other mods' view of the loader must match the previous release (tests/fixtures/loader-contract.json).
    tests += run([sys.executable, ROOT / 'tests/test_contract.py', folder], env=env)
    # runtime_verified: only scripts/pin_tested.py pins a resource, from a played run.
    tests += run([sys.executable, ROOT / 'tests/test_pin_tested.py', folder], env=env)
    return tests


def probe_tests(folder, env):
    """The frame probe through the hooked coordinator in both VMs, and its log header."""
    coordinator = folder / 'shared_loader.probe.lua'
    coordinator.write_text(probe_coordinator((ROOT / 'src/shared_loader.lua').read_text(encoding='utf-8')),
                           encoding='utf-8', newline='\n')
    tests = ''
    for prefix in ([LUA], [sys.executable, ROOT / 'tests/game_lua.py']):
        tests += run(prefix + [ROOT / 'tests/test_frame_probe.lua', ROOT / 'src', coordinator], env=env)
    tests += run([sys.executable, ROOT / 'tests/test_probe_header.py', folder / 'probe-header-lines.txt'], env=env)
    return tests


def main():
    # --probe builds the development-only frame probe loader into build-probe/; never publish it.
    # --dev NAME (e.g. jitguard1) builds the release sources as revision loader-v21-NAME into
    # build-<NAME without its number>/, ZIP included, for harness runs; never publish it.
    probe = '--probe' in sys.argv[1:]
    dev = sys.argv[sys.argv.index('--dev') + 1] if '--dev' in sys.argv[1:] else None
    BUILD, revision = (ROOT / 'build-probe', PROBE_REVISION) if probe else (ROOT / 'build', 'loader-v21')
    if dev:
        BUILD, revision = ROOT / ('build-' + dev.rstrip('0123456789')), 'loader-v21-' + dev
    BUILD.mkdir(exist_ok=True)
    boot, callback = vanilla_inputs()
    (BUILD / 'vanilla-boot.ljbc').write_bytes(boot[8:])
    (BUILD / 'vanilla-callbacks.ljbc').write_bytes(callback[8:])
    (BUILD / 'vanilla-callbacks.lua.main').write_bytes(callback)
    resource = compile_resource(callback, BUILD, probe)
    (BUILD / 'callbacks.lua.main').write_bytes(resource)
    env = dict(os.environ, LUA_PATH=str(LUA.parent / '?.lua') + ';;')
    tests = run([LUA, ROOT / 'tests/test_logging.lua', ROOT / 'src'], env=env)
    tests += run([LUA, ROOT / 'tests/test_discovery.lua', ROOT / 'src'], env=env)
    tests += run([LUA, ROOT / 'tests/test_jit_budget.lua', ROOT / 'src'], env=env)
    # The installed game's own LuaJIT 2.1.0-alpha, in this process only; skipped without the game.
    tests += run([sys.executable, ROOT / 'tests/test_jit_budget_game.py', ROOT / 'src'], env=env)
    # The churn guard: fake events in both VMs, then real aborting starts in the game's LuaJIT.
    tests += run([LUA, ROOT / 'tests/test_jit_guard.lua', ROOT / 'src'], env=env)
    tests += run([sys.executable, ROOT / 'tests/game_lua.py', ROOT / 'tests/test_jit_guard.lua', ROOT / 'src'], env=env)
    tests += run([sys.executable, ROOT / 'tests/game_lua.py', ROOT / 'tests/test_jit_guard_game.lua', ROOT / 'src'],
                 env=env)
    tests += run([sys.executable, ROOT / 'tests/game_lua.py', ROOT / 'tests/test_discovery.lua', ROOT / 'src'], env=env)
    tests += run([sys.executable, ROOT / 'tests/test_addon_package.py'], env=env)
    tests += run([sys.executable, ROOT / 'tests/test_discovery_integration.py'], env=env)
    tests += probe_tests(BUILD, env) if probe else release_tests(BUILD, env)
    (BUILD / 'offline-tests.txt').write_text(tests, encoding='utf-8')
    (BUILD / ARCHIVE).write_bytes(make_archive({resource_hash(CALLBACK_PATH): resource}))
    for suffix in ('.stream', '.gpu_resources'):
        (BUILD / (ARCHIVE + suffix)).write_bytes(b'')
    files = {f'data/{ARCHIVE}{suffix}': f'{BUILD.name}/{ARCHIVE}{suffix}'
             for suffix in ('', '.stream', '.gpu_resources')}
    report = {
        'name': 'Bingus Shared Loader', 'slug': 'BingusSharedLoader',
        'guid': '612eaf70-d682-43c7-9efd-16dcc695f977', 'revision': revision,
        'description': 'ARSENAL: place this loader LAST (bottom of the list) with default priority, or FIRST if first-mod priority is enabled. Required by Armory Preview Cache, Know Your Constellation, Controllable Hover Pack, Vehicle Stability, Enemy Collision Synchronized, Vanilla Plus Megapack or the separate Better Stratagem Bounce, Hellpod Steering Unlocked, Reinforcement Beacons Fixed, Consistent Vaulting, Shallow Water Diving and Sentry Aim Retention mods. Import this ZIP through Arsenal or HD2MM, enable it alongside the megapack or your chosen mods, then Deploy. Also supports HUD Ballistic Trajectory Overlay v2.',
        'provides': {'shared_loader_api': 1, 'addon_discovery': 1},
        'game_exe_sha256': EXE_SHA, 'game_dll_sha256': GAME_DLL_SHA,
        'deployment_files': files, 'files': {p: sha((ROOT / p).read_bytes()) for p in files.values()},
        'original_callbacks_sha256': CALLBACK_SHA, 'boot_replaced': False,
        'gameplay_changes': False,
        'runtime_verified': not probe and not dev and sha(resource) == TESTED_CALLBACK_SHA,
        'offline_tests': tests.strip(),
    }
    report['source_sha256'] = {p.relative_to(ROOT).as_posix(): sha(p.read_bytes())
        for folder, glob in [('src', '*.lua'), ('tests', '*.lua'), ('scripts', '*.py')]
        for p in (ROOT / folder).glob(glob)}
    # Probe ZIPs go straight to their own folder, never to a releases folder.
    release = package_release(ROOT, BUILD, report, BUILD if probe or dev else None)
    tests += run([sys.executable, ROOT / 'tests/test_package.py', release] + ([revision] if probe or dev else []))
    report['offline_tests'] = tests.strip()
    report['release'] = {'path': Path(os.path.relpath(release, ROOT)).as_posix(), 'sha256': sha(release.read_bytes())}
    (BUILD / 'build-report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(tests.strip())
    print('Built ' + str(release) + '; ' + ('matches the maintainer-tested runtime.'
        if report['runtime_verified'] else 'in-game testing pending for this runtime.'))


if __name__ == '__main__':
    main()
