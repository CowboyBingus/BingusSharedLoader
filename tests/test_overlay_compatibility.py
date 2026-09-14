"""Check the locally supplied Overlay v2 release without redistributing it."""
import argparse
import json
from pathlib import Path
import re
import struct
import subprocess
import sys
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from archive import LUA, TYPE, resource_hash, sha
from package import release_directory

OVERLAY_SHA = '59D2F64C5E9312C3CA3BF48CF8410FE87821C6C444AACA11090A1D0CDBB12828'
WWISE = resource_hash('core/wwise/lua/wwise_flow_callbacks')
OVERLAY = resource_hash('mods/codex/gun_calibration')


def resources(data):
    magic, types, count = struct.unpack_from('<III', data)
    assert magic == 0xF0000011 and types == 1
    end = 72 + types * 32 + count * 80
    assert end <= len(data)
    result = {}
    for index in range(count):
        entry = struct.unpack_from('<7Q6I', data, 72 + types * 32 + index * 80)
        name, kind, offset = entry[:3]
        size = entry[7]
        assert kind == TYPE and name not in result
        assert end <= offset <= offset + size <= len(data)
        assert entry[8:10] == (0, 0)
        resource = data[offset:offset + size]
        assert struct.unpack_from('<II', resource) == (size - 8, 2)
        result[name] = resource
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('overlay', type=Path)
    parser.add_argument('hud', type=Path)
    parser.add_argument('bounce', type=Path)
    parser.add_argument('steering', type=Path)
    parser.add_argument('reinforcement', type=Path)
    parser.add_argument('--vaulting', type=Path)
    args = parser.parse_args()
    build = ROOT / 'build'
    fixture = build / 'overlay-compatibility'
    fixture.mkdir(exist_ok=True)
    archive = args.overlay / 'Overlay/9ba626afa44a3aa3.patch_0'
    data = archive.read_bytes()
    assert sha(data) == OVERLAY_SHA, 'Unreviewed overlay release; inspect before updating the fixture hash'
    manifest = json.loads((args.overlay / 'manifest.json').read_text(encoding='utf-8-sig'))
    assert manifest['Guid'] == '3384ebde-4b93-4d36-9717-168b3b5ff983'
    assert manifest['Options'][0]['Include'] == ['Overlay']
    original = resources(data)
    assert set(original) == {WWISE, OVERLAY}
    bridge = original[WWISE][8:].decode('utf-8')
    literal = re.search(r'"((?:\\\d{3})+)"', bridge)
    assert literal, 'Original Wwise callback payload missing'
    vanilla = bytes(int(n) for n in re.findall(r'\\(\d{3})', literal[1]))
    assert vanilla == (build / 'vanilla-callbacks.ljbc').read_bytes()
    assert "'mods/codex/gun_calibration'" in bridge
    (fixture / 'overlay.lua.main').write_bytes(original[OVERLAY])
    (fixture / 'overlay-bridge.lua.main').write_bytes(original[WWISE])

    loader_zip = release_directory(ROOT) / 'BingusSharedLoader.zip'
    with zipfile.ZipFile(loader_zip) as package:
        loader = resources(package.read('data/9ba626afa44a3aa3.patch_0'))
    assert set(loader) == {WWISE} and loader[WWISE] == (build / 'callbacks.lua.main').read_bytes()
    assert set(loader) & set(original) == {WWISE}
    gameplay = [
        (args.bounce, 'better_stratagem_bounce', 'bounce'),
        (args.steering, 'hellpod_steering_unlocked', 'steering'),
        (args.reinforcement, 'reinforcement_beacon_fix_data', 'reinforcement'),
    ]
    if args.vaulting:
        gameplay.append((args.vaulting, 'consistent_vaulting', 'vaulting'))
    for path, name, filename in gameplay:
        with zipfile.ZipFile(path) as package:
            entries = resources(package.read('data/9ba626afa44a3aa3.patch_0'))
        key = resource_hash('mods/cowboybingus/' + name)
        assert set(entries) == {key} and not set(entries) & set(original)
        (fixture / (filename + '.lua.main')).write_bytes(entries[key])

    command=[str(LUA), str(ROOT / 'tests/test_overlay_compatibility.lua'),str(build),str(fixture),str(args.hud)]
    if args.vaulting:
        command.append(str(fixture / 'vaulting.lua.main'))
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    report = {'overlay_archive_sha256': OVERLAY_SHA, 'overlay_resource_sha256': sha(original[OVERLAY]),
        'loader_archive_sha256': sha(loader_zip.read_bytes()),
        'only_overlap': 'core/wwise/lua/wwise_flow_callbacks', 'tests': result.stdout.strip(),
        'game_launched': False, 'rendering_verified': False}
    (build / 'overlay-compatibility.json').write_text(json.dumps(report, indent=2) + '\n')
    print(result.stdout.strip())
    print('PASS: supplied Overlay v2, original Wwise payload, release resource ownership and unchanged third-party module')


if __name__ == '__main__':
    main()
