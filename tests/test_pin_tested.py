"""scripts/pin_tested.py pins a resource only from a clean run that deployed that exact ZIP.

Usage: test_pin_tested.py <build>. Uses build/callbacks.lua.main as the current resource,
synthetic TestHarness run folders and ZIPs in a temporary folder, and a temporary copy of
scripts/build.py; the real build script is never written.
"""
import contextlib
import copy
import io
import json
from pathlib import Path
import sys
import tempfile
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from archive import ARCHIVE, EXE_SHA, GAME_DLL_SHA, make_archive, resource_hash, sha  # noqa: E402
import pin_tested  # noqa: E402

BUILD = Path(sys.argv[1])
CURRENT = (BUILD / 'callbacks.lua.main').read_bytes()
WWISE = resource_hash('core/wwise/lua/wwise_flow_callbacks')
LOG = 'Bingus Shared Loader loader-v19; API 1\nStarted: 2026-10-04 00:14:30\nStartup finished: 18 loaded, 0 failed\n'
checks = 0


def expect(name, condition, detail=''):
    global checks
    if not condition:
        raise AssertionError(name + (': ' + str(detail) if detail != '' else ''))
    checks += 1


def make_zip(path, resource, revision='loader-v19'):
    with zipfile.ZipFile(path, 'w') as bundle:
        bundle.writestr('data/' + ARCHIVE, make_archive({WWISE: resource}))
        bundle.writestr('BingusSharedLoader-manifest.json', json.dumps({'revision': revision}))
    return path


def clean_record(name, digest):
    return {'session': '0123456789ab', 'condition': 'packages', 'preset': 'light',
            'exit': {'at': '2026-10-04T00:15:05-07:00', 'code': 0, 'how': 'quit'}, 'outcome': 'clean-quit',
            'clean': True, 'not_clean_because': [], 'reached_ship': '2026-10-04T00:15:00-07:00', 'agent_bye': True,
            'dumps': [], 'logs': ['BingusSharedLoader.log'], 'restore_problems': [],
            'facts': {'build': '25480438', 'exe_sha256': EXE_SHA, 'game_dll_sha256': GAME_DLL_SHA,
                      'packages': ['Other-Mod-v1.zip', name],
                      'package_sha256': {'Other-Mod-v1.zip': '0' * 64, name: digest}}}


def make_run(folder, record, log=LOG):
    folder.mkdir(parents=True)
    (folder / 'run.json').write_text(json.dumps(record, indent=2), encoding='utf-8')
    if log is not None:
        (folder / 'logs').mkdir()
        (folder / 'logs/BingusSharedLoader.log').write_text(log, encoding='utf-8')
    return folder


def main():
    real_script = (ROOT / 'scripts/build.py').read_bytes()
    with tempfile.TemporaryDirectory(prefix='loader-pin-test-') as temp:
        base = Path(temp)
        package = make_zip(base / 'Bingus-Shared-Loader-v19.zip', CURRENT)
        digest = sha(package.read_bytes())
        clean = clean_record(package.name, digest)
        runs = 0

        def problems(record=clean, log=LOG, zip_path=package):
            nonlocal runs
            runs += 1
            folder = make_run(base / ('run%d' % runs), record, log)
            return pin_tested.check(folder / 'run.json', zip_path, CURRENT)

        # A clean run that deployed this ZIP: pinned, with the run's name.
        found, resource_sha, run_name = problems()
        expect('clean run accepted', found == [], found)
        expect('the resource hash is pinned, not the ZIP hash', resource_sha == sha(CURRENT) != digest)
        # The build script as it is before any pin (None), whatever the real one holds now.
        unpinned, found_pins = pin_tested.PIN.subn('TESTED_CALLBACK_SHA = None\n', real_script.decode('utf-8'))
        expect('the real build script holds one pin, set or empty', found_pins == 1, found_pins)
        script = base / 'build.py'
        script.write_text(unpinned, encoding='utf-8', newline='\n')
        pin_tested.pin(script, resource_sha, run_name)
        pinned = script.read_text(encoding='utf-8')
        expect('constant written', "\nTESTED_CALLBACK_SHA = '%s'\n" % resource_sha in pinned)
        expect('run named', '# Pinned by scripts/pin_tested.py from TestHarness run %s.\n' % run_name in pinned)
        before, after = unpinned.splitlines(), pinned.splitlines()
        changed = [line for line in after if line not in before]
        expect('only the pin lines change', len(after) == len(before) + 1 and len(changed) == 2, changed)
        pin_tested.pin(script, '0' * 64, 'later-run')
        repinned = script.read_text(encoding='utf-8')
        expect('a second pin replaces the first', repinned.count('# Pinned by') == 1 and resource_sha not in repinned
               and "TESTED_CALLBACK_SHA = '%s'" % ('0' * 64) in repinned)
        # The other accepted shape: hashes inside the package list.
        listed = copy.deepcopy(clean)
        del listed['facts']['package_sha256']
        listed['facts']['packages'] = [{'name': package.name, 'sha256': digest.lower()}]
        expect('hashes in the package list accepted', problems(listed)[0] == [])

        # Every reason to refuse, one at a time.
        def variant(change):
            record = copy.deepcopy(clean)
            change(record)
            return record

        refusals = {
            'not marked clean': variant(lambda r: r.update(clean=False)),
            'lists reasons it is not clean': variant(lambda r: r.update(not_clean_because=['never reached the ship'])),
            'never reached the ship': variant(lambda r: r.update(reached_ship=None)),
            'did not end with a clean quit': variant(lambda r: r.update(outcome='crash')),
            'exit code 0': variant(lambda r: r['exit'].update(code=3221225477)),
            'did not see the shutdown': variant(lambda r: r.update(agent_bye=False)),
            'left crash dumps': variant(lambda r: r.update(dumps=[{'file': 'x.dmp', 'kind': 'crash'}])),
            'install was not restored': variant(lambda r: r.update(restore_problems=['data/ differs'])),
            'another game build': variant(lambda r: r['facts'].update(game_dll_sha256='F' * 64)),
            'did not deploy package ZIPs': variant(lambda r: r.update(condition='mods')),
            'by name only': variant(lambda r: r['facts'].pop('package_sha256')),
            'had other bytes than this ZIP': variant(lambda r: r['facts']['package_sha256'].update({package.name: 'A' * 64})),
            'did not deploy this ZIP': variant(lambda r: r['facts'].update(packages=['Other-Mod-v1.zip'],
                                                                            package_sha256={'Other-Mod-v1.zip': 'B' * 64})),
        }
        for reason, record in refusals.items():
            found = problems(record)[0]
            expect('refused: ' + reason, len(found) == 1 and reason in found[0], found)
        expect('the exit must be a quit', any('exit code 0' in item for item in problems(
            variant(lambda r: r['exit'].update(how='kill')))[0]))
        for reason, log in {'kept no loader log': None,
                            'is not from loader-v19': LOG.replace('loader-v19', 'loader-v18'),
                            'never reached "Startup finished"': LOG.replace('Startup finished', 'mods/a/b: loading')}.items():
            found = problems(log=log)[0]
            expect('refused: ' + reason, len(found) == 1 and reason in found[0], found)
        # A ZIP the run deployed, but built from other sources.
        other = make_zip(base / 'Bingus-Shared-Loader-v19-old.zip', CURRENT[:-1] + bytes([CURRENT[-1] ^ 1]))
        found = problems(clean_record(other.name, sha(other.read_bytes())), zip_path=other)[0]
        expect('refused: another resource', len(found) == 1 and 'another loader resource' in found[0], found)
        expect('several reasons listed together', len(problems(variant(lambda r: r.update(
            clean=False, dumps=[{'file': 'y.dmp'}], condition='vanilla')))[0]) == 3)

        # The command line compiles the current sources again (deterministic) and, with
        # --check, writes nothing; a refused run exits with every reason.
        folder = make_run(base / 'cli', clean)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            pin_tested.main([str(folder), str(package), '--check'])
        expect('--check reports the pin', output.getvalue().startswith('Would pin %s from TestHarness run cli.'
                                                                       % sha(CURRENT)), output.getvalue())
        folder = make_run(base / 'cli-refused', variant(lambda r: r.update(reached_ship=None)))
        try:
            pin_tested.main([str(folder), str(package)])
            refused = None
        except SystemExit as stop:
            refused = str(stop)
        expect('a refused run exits with its reasons', refused is not None and refused.startswith('Not pinned:')
               and 'never reached the ship' in refused, refused)
    expect('the real build script is never written', (ROOT / 'scripts/build.py').read_bytes() == real_script)
    print('PASS: pin_tested.py (%d checks): pins only the resource of a clean, supported-build run that deployed '
          'that exact ZIP and ran this loader, from the current sources; refuses with every reason otherwise'
          % checks)


if __name__ == '__main__':
    main()
