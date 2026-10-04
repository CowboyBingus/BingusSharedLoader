"""The loader's contract with other mods must not change between releases.

Runs tests/contract_snapshot.lua for every scenario against this build and
compares the result with tests/fixtures/loader-contract.json, recorded from the
previous release: the global table's fields and values, module statuses, the
Windows names declared for other mods and their prototypes, what an addon of
that release can call, the update chain, printed lines and log statuses. The
only differences allowed are listed in ADDED_STATE_KEYS, each with its reason.

Usage: test_contract.py <build>                 compare this build
       test_contract.py <build> --record <ZIP>  record the contract of a release ZIP
"""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from archive import ARCHIVE, LUA, make_archive, resource_hash  # noqa: E402

FIXTURE = ROOT / 'tests/fixtures/loader-contract.json'
SCENARIOS = ['none', 'mixed', 'other_loader', 'uses_loader_declarations', 'declares_after', 'no_ffi',
             'no_lookup', 'no_localappdata', 'first_module_declares', 'discovery_copies',
             'discovery_unreadable_copies']
# The discovery_ scenarios run over archives deployed as a manager writes them
# (contract_snapshot.lua names the same modules). discovery_copies: a registry module
# and a declared addon have two copies each; a declared addon is hidden by a higher
# undeclared copy and must not start. discovery_unreadable_copies: reads of two
# hidden copies fail (one envelope, one body) and an entry after them in their
# archive must still start; v18 never read hidden copies.
BOUNCE, ADDON, HIDDEN, LATER = ('mods/cowboybingus/better_stratagem_bounce', 'mods/contract_author/addon',
                                'mods/contract_author/hidden', 'mods/contract_author/later')
ADDED_STATE_KEYS = {
    'after_startup:function': 'v19: after_startup(fn) runs fn once after every module of this startup has started '
                              '(at once when registered later); no scenario registers one, so nothing else changes',
    'capabilities:table': 'v19: what this build supports (api, logs, discovery, jit_budget, health, after_startup), '
                          'read-only, so mods test a feature instead of comparing version, which stays 17',
    'health:table': 'v19: the health report data (header lines and per-module changes)',
    'revision:string': 'v19: the build revision, so tools need not compare version numbers',
}
WWISE = resource_hash('core/wwise/lua/wwise_flow_callbacks')
# Scenarios where the recorded release was broken and this build is not, with the
# reason. The expectation is the recorded contract with exactly this repair.
FIXED = {
    'first_module_declares': 'v18 called CreateDirectoryA through whatever prototype a module declared first, so '
                             'one incompatible declaration disabled every mod log for the session; v19 calls its '
                             'private name. The other mods still see the module\'s prototype, as under v18.',
}


def repaired(name, expected):
    """The recorded contract of a FIXED scenario with its repair applied."""
    expected = json.loads(json.dumps(expected))
    if name == 'first_module_declares':
        state = expected['state']
        state['keys'] = sorted(state['keys'] + ['log_directory:string'])
        state['log_directory'] = '<temp>/CowboyBingus/Helldivers2/Logs'
        state['open_log_valid'] = True
        expected['log'] = {'header': True, 'statuses': dict(state['modules'])}
    return expected


def release_resource(package, target):
    """Writes the Wwise callbacks resource of a loader release ZIP to target."""
    with zipfile.ZipFile(package) as bundle:
        data = bundle.read('data/' + ARCHIVE)
    magic, types, count = struct.unpack_from('<III', data)
    assert magic == 0xF0000011 and types == 1, 'not a loader archive'
    for index in range(count):
        entry = struct.unpack_from('<7Q6I', data, 72 + types * 32 + index * 80)
        if entry[0] == WWISE:
            target.write_bytes(data[entry[2]:entry[2] + entry[7]])
            return target
    raise AssertionError('no Wwise callbacks resource in ' + str(package))


def lua(body):
    return struct.pack('<II', len(body), 2) + body


def declared(name):
    return lua(('-- HD2-Addon: ' + name + '\nreturn true\n').encode())


def resource_offset(data, key):
    """Where the resource with this key starts in an archive (its envelope)."""
    magic, types, count = struct.unpack_from('<III', data)
    for index in range(count):
        entry = struct.unpack_from('<7Q6I', data, 72 + types * 32 + index * 80)
        if entry[0] == key:
            return entry[2]
    raise AssertionError('no resource %016x' % key)


def deploy(temp, archives, failures=()):
    """A game folder for a discovery scenario: bin/ for the executable path, data/ with the
    archives, and failures.txt with an '<archive> <position>' line for each read to fail."""
    game = Path(temp) / 'game'
    (game / 'bin').mkdir(parents=True)
    (game / 'data').mkdir()
    for number, resources in archives.items():
        (game / 'data' / (ARCHIVE[:-1] + str(number))).write_bytes(make_archive(resources))
    lines = []
    for number, name, part in failures:
        offset = resource_offset((game / 'data' / (ARCHIVE[:-1] + str(number))).read_bytes(), resource_hash(name))
        lines.append('%s%d %d\n' % (ARCHIVE[:-1], number, offset + (8 if part == 'body' else 0)))
    (game / 'failures.txt').write_text(''.join(lines), encoding='utf-8', newline='\n')


def deploy_discovery(temp, scenario):
    if scenario == 'discovery_copies':
        deploy(temp, {9: {resource_hash(BOUNCE): declared(BOUNCE)}, 5: {resource_hash(BOUNCE): lua(b'\x1bLJ\x02compiled')},
                      7: {resource_hash(ADDON): declared(ADDON)}, 2: {resource_hash(ADDON): declared(ADDON)},
                      3: {resource_hash(HIDDEN): declared(HIDDEN)}, 12: {resource_hash(HIDDEN): lua(b'return true\n')}})
    elif scenario == 'discovery_unreadable_copies':
        # LATER's row follows both hidden copies in patch_4: rows are sorted by resource hash.
        assert resource_hash(LATER) > max(resource_hash(BOUNCE), resource_hash(ADDON))
        deploy(temp, {9: {resource_hash(BOUNCE): declared(BOUNCE)}, 7: {resource_hash(ADDON): declared(ADDON)},
                      4: {resource_hash(name): declared(name) for name in (BOUNCE, ADDON, LATER)}},
               failures=[(4, BOUNCE, 'envelope'), (4, ADDON, 'body')])


def snapshot(resource, build, scenario):
    env = dict(os.environ, LUA_PATH=str(LUA.parent / '?.lua') + ';;')
    with tempfile.TemporaryDirectory(prefix='loader-contract-') as temp:
        deploy_discovery(temp, scenario)
        result = subprocess.run([str(LUA), str(ROOT / 'tests/contract_snapshot.lua'), str(resource), str(build),
                                 scenario, temp], capture_output=True, text=True, env=env)
    if result.returncode:
        raise RuntimeError(scenario + ': ' + result.stdout + result.stderr)
    return json.loads(result.stdout.strip().splitlines()[-1])


def differences(expected, actual, path=''):
    """Paths whose values differ, with both values."""
    if isinstance(expected, dict) and isinstance(actual, dict):
        found = []
        for key in sorted(set(expected) | set(actual)):
            found += differences(expected.get(key), actual.get(key), path + '/' + key)
        return found
    return [] if expected == actual else ['%s: expected %r, got %r' % (path, expected, actual)]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('build', type=Path)
    parser.add_argument('--record', type=Path, metavar='ZIP')
    args = parser.parse_args()
    if args.record:
        with tempfile.TemporaryDirectory(prefix='loader-release-') as temp:
            resource = release_resource(args.record, Path(temp) / 'callbacks.lua.main')
            scenarios = {name: snapshot(resource, args.build, name) for name in SCENARIOS}
        FIXTURE.parent.mkdir(exist_ok=True)
        FIXTURE.write_text(json.dumps({'release': args.record.name, 'scenarios': scenarios}, indent=1,
                                      sort_keys=True) + '\n', encoding='utf-8', newline='\n')
        print('recorded the contract of ' + args.record.name)
        return
    recorded = json.loads(FIXTURE.read_text(encoding='utf-8'))
    problems = []
    for name in SCENARIOS:
        actual = snapshot(args.build / 'callbacks.lua.main', args.build, name)
        if 'state' in actual:
            actual['state']['keys'] = [key for key in actual['state']['keys'] if key not in ADDED_STATE_KEYS]
        expected = recorded['scenarios'][name]
        if name in FIXED:
            expected = repaired(name, expected)
        problems += [name + ' ' + line for line in differences(expected, actual)]
    if problems:
        raise SystemExit('Contract changed against ' + recorded['release'] + ':\n' + '\n'.join(problems))
    print('PASS: contract unchanged against %s in %d scenarios (fields, statuses, Windows declarations and '
          'prototypes, addon calls, update chain, prints, log statuses); %d added fields and %d repaired scenario '
          'as documented' % (recorded['release'], len(SCENARIOS), len(ADDED_STATE_KEYS), len(FIXED)))


if __name__ == '__main__':
    main()
