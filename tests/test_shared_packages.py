"""Check distinct owners across every load order and removal subset."""
from pathlib import Path
import struct
import sys
import zipfile
import itertools
import json

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from archive import resource_hash


def resources(path):
    with zipfile.ZipFile(path) as package:
        data = package.read('data/9ba626afa44a3aa3.patch_0')
        manager = json.loads(package.read('manifest.json'))
        provenance = json.loads(package.read(next(n for n in package.namelist() if n.endswith('-manifest.json'))))
        name = provenance['name']
        assert manager['Name'] == name + ' - ' + provenance['display_version']
    owners = {'Bingus Shared Loader': 'core/wwise/lua/wwise_flow_callbacks',
              'Better Stratagem Bounce': 'mods/cowboybingus/better_stratagem_bounce',
              'Hellpod Steering Unlocked': 'mods/cowboybingus/hellpod_steering_unlocked',
              'Wide Angle Stratagems': 'mods/cowboybingus/wide_angle_stratagems',
              'Reinforcement Beacons Fixed': 'mods/cowboybingus/reinforcement_beacon_fix_data',
              'Consistent Vaulting': 'mods/cowboybingus/consistent_vaulting',
              'Shallow Water Diving': 'mods/cowboybingus/shallow_water_dive',
              'Sentry Aim Retention': 'mods/cowboybingus/sentry_aim_retention',
              'Enemy Collision Synchronized': 'mods/cowboybingus/corpse_collision_repair'}
    assert struct.unpack_from('<III', data) == (0xF0000011, 1, 1)
    result = {}
    for index in range(1):
        entry = struct.unpack_from('<7Q6I', data, 104 + index * 80)
        assert entry[1] == 0xA14E8DFA2CD117E2 and entry[0] not in result
        result[entry[0]] = data[entry[2]:entry[2] + entry[7]]
    assert set(result) == {resource_hash(owners[name])}
    return name, result


def main():
    entries = list(map(resources, sys.argv[1:]))
    assert 3 <= len(entries) <= 8
    names = {name for name, _ in entries}
    assert len(names) == len(entries)
    assert {'Bingus Shared Loader', 'Better Stratagem Bounce', 'Hellpod Steering Unlocked'} <= names
    packages = [data for _, data in entries]
    assert resource_hash('boot') == 0xF476DF93691895FA
    shared = resource_hash('core/wwise/lua/wwise_flow_callbacks')
    assert shared == 0x7251FDD9BB62480A
    for first, second in itertools.combinations(packages, 2):
        assert not first.keys() & second.keys(), 'Packages must not replace one another\'s resources'
    expected = {}
    for package in packages: expected.update(package)
    for installed in itertools.permutations(packages):
        active = {}
        for package in installed:
            active.update(package)
        assert active == expected
    for count in range(len(packages) + 1):
        for remaining in itertools.combinations(entries, count):
            active = {}
            for _, package in remaining: active.update(package)
            assert len(active) == count
            assert (shared in active) == any(name == 'Bingus Shared Loader' for name, _ in remaining)
            assert resource_hash('boot') not in active
    print('PASS: distinct resource owners, zero mutual conflicts, every load order and removal subset')


if __name__ == '__main__':
    main()
