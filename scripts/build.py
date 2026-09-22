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
TESTED_CALLBACK_SHA = 'BF0D10CC329270FC704C841A41EF4D0D27407155989F3B9CFCB6E5A0424EFBBA'


def run(args, **kwargs):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


def bootstrap(stock_bytes):
    literal = '"' + ''.join(f'\\{byte:03d}' for byte in stock_bytes) + '"'
    discovery = (ROOT / 'src/discover.lua').read_text(encoding='utf-8')
    coordinator = (ROOT / 'src/shared_loader.lua').read_text(encoding='utf-8')
    # Preserve startup arguments and all results, including trailing nils. A stock
    # runtime error propagates: native initialization must never be retried.
    return ('local function initialize_addons()\n'
            'local addon_discovery = (function()\n' + discovery + '\nend)()\n'
            + coordinator + '\nend\n'
            'return (function(...) initialize_addons(); return ... end)'
            f'(assert(loadstring({literal}, "@vanilla_wwise_callbacks"))(...))\n')


def main():
    BUILD.mkdir(exist_ok=True)
    boot = BOOT.read_bytes()
    callback = Path(os.environ.get('HD2_CALLBACK_RESOURCE',
        ROOT / 'artifacts/vanilla/wwise_flow_callbacks.lua.main')).read_bytes()
    if sha(boot) != BOOT_SHA or struct.unpack('<II', boot[:8]) != (326, 2):
        raise ValueError('Unsupported vanilla boot fixture')
    if sha(callback) != CALLBACK_SHA or struct.unpack('<II', callback[:8]) != (10263, 2):
        raise ValueError('Unsupported vanilla Wwise callbacks')
    (BUILD / 'vanilla-boot.ljbc').write_bytes(boot[8:])
    (BUILD / 'vanilla-callbacks.ljbc').write_bytes(callback[8:])
    (BUILD / 'vanilla-callbacks.lua.main').write_bytes(callback)
    wrapper = bootstrap(callback[8:])
    source = BUILD / 'callbacks.wrapper.lua'
    source.write_text(wrapper, encoding='utf-8', newline='\n')
    env = dict(os.environ, LUA_PATH=str(LUA.parent / '?.lua') + ';;')
    run([LUA, '-bsdW', source, BUILD / 'callbacks.ljbc'], env=env)
    bytecode = (BUILD / 'callbacks.ljbc').read_bytes()
    if bytecode[:5] != callback[8:13]:
        raise ValueError('LuaJIT bytecode mode differs from the game')
    resource = struct.pack('<II', len(bytecode), 2) + bytecode
    (BUILD / 'callbacks.lua.main').write_bytes(resource)
    tests = run([LUA, ROOT / 'tests/test_shared_loader.lua', ROOT / 'src', BUILD], env=env)
    tests += run([LUA, ROOT / 'tests/test_logging.lua', ROOT / 'src'], env=env)
    tests += run([LUA, ROOT / 'tests/test_discovery.lua', ROOT / 'src'], env=env)
    tests += run([sys.executable, ROOT / 'tests/test_addon_package.py'], env=env)
    tests += run([sys.executable, ROOT / 'tests/test_discovery_integration.py'], env=env)
    (BUILD / 'offline-tests.txt').write_text(tests, encoding='utf-8')
    (BUILD / ARCHIVE).write_bytes(make_archive({resource_hash(CALLBACK_PATH): resource}))
    for suffix in ('.stream', '.gpu_resources'):
        (BUILD / (ARCHIVE + suffix)).write_bytes(b'')
    files = {f'data/{ARCHIVE}{suffix}': f'build/{ARCHIVE}{suffix}'
             for suffix in ('', '.stream', '.gpu_resources')}
    report = {
        'name': 'Bingus Shared Loader', 'slug': 'BingusSharedLoader',
        'guid': '612eaf70-d682-43c7-9efd-16dcc695f977', 'revision': 'loader-v16',
        'description': 'ARSENAL: place this loader LAST (bottom of the list) with default priority, or FIRST if first-mod priority is enabled. Required by Armory Preview Cache, Know Your Constellation, Controllable Hover Pack, Vehicle Stability, Enemy Collision Synchronized, Vanilla Plus Megapack or the separate Better Stratagem Bounce, Hellpod Steering Unlocked, Reinforcement Beacons Fixed, Consistent Vaulting, Shallow Water Diving and Sentry Aim Retention mods. Import this ZIP through Arsenal or HD2MM, enable it alongside the megapack or your chosen mods, then Deploy. Also supports HUD Ballistic Trajectory Overlay v2.',
        'provides': {'shared_loader_api': 1, 'addon_discovery': 1},
        'game_exe_sha256': EXE_SHA, 'game_dll_sha256': GAME_DLL_SHA,
        'deployment_files': files, 'files': {p: sha((ROOT / p).read_bytes()) for p in files.values()},
        'original_callbacks_sha256': CALLBACK_SHA, 'boot_replaced': False,
        'gameplay_changes': False, 'runtime_verified': sha(resource) == TESTED_CALLBACK_SHA,
        'offline_tests': tests.strip(),
    }
    report['source_sha256'] = {p.relative_to(ROOT).as_posix(): sha(p.read_bytes())
        for folder, glob in [('src', '*.lua'), ('tests', '*.lua'), ('scripts', '*.py')]
        for p in (ROOT / folder).glob(glob)}
    release = package_release(ROOT, BUILD, report)
    tests += run([sys.executable, ROOT / 'tests/test_package.py', release])
    report['offline_tests'] = tests.strip()
    report['release'] = {'path': Path(os.path.relpath(release, ROOT)).as_posix(), 'sha256': sha(release.read_bytes())}
    (BUILD / 'build-report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(tests.strip())
    print('Built ' + str(release) + '; ' + ('matches the maintainer-tested runtime.'
        if report['runtime_verified'] else 'in-game testing pending for this runtime.'))


if __name__ == '__main__':
    main()
