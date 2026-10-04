"""Pin the loader resource the maintainer played (TESTED_CALLBACK_SHA in scripts/build.py).

Usage: python scripts/pin_tested.py <TestHarness run.json, or its run folder> <loader release ZIP> [--check]

The build report's runtime_verified is true only for the Wwise callbacks resource whose
SHA-256 is TESTED_CALLBACK_SHA. This script writes that constant, and only when all of this
holds; otherwise it prints every reason and changes nothing:

1. The run was clean. Its run.json says clean with no reasons, the game reached the ship, it
   quit through the engine with exit code 0 and the test agent saw the shutdown, no crash dump
   appeared, the install was restored, and the game was the build this loader supports (the
   executable and game.dll SHA-256 in scripts/archive.py).
2. The run deployed this exact ZIP. It ran the packages condition and its record holds the ZIP's
   SHA-256: in facts.package_sha256 ({ZIP name: SHA-256}), or as {"name", "sha256"} entries in
   facts.packages. A list of names alone cannot show which bytes were deployed.
3. This loader ran. The run's logs/BingusSharedLoader.log starts with the ZIP's revision and
   reached "Startup finished".
4. The resource inside the ZIP is the one the current sources build. The script compiles them
   again in a temporary folder (the same inputs as scripts/build.py: HD2_LUAJIT and
   HD2_CALLBACK_RESOURCE).

--check reports without writing. After pinning, rebuild and commit scripts/build.py.
"""
import argparse
import json
from pathlib import Path
import re
import sys
import tempfile
import zipfile

sys.dont_write_bytecode = True

from archive import ARCHIVE, EXE_SHA, GAME_DLL_SHA, read_resource, resource_hash, sha  # noqa: E402
from build import CALLBACK_PATH, compile_resource, vanilla_inputs  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / 'scripts/build.py'
# The pin in scripts/build.py: None until a played build is pinned, then the hash
# and the comment naming its run.
PIN = re.compile(r"^(?:# Pinned by scripts/pin_tested\.py from TestHarness run [^\n]*\n)?"
                 r"TESTED_CALLBACK_SHA = (?:'[0-9A-F]{64}'|None)\n", re.MULTILINE)


def load_run(path):
    """(run.json contents, run folder) for a run.json path or a run folder."""
    path = Path(path)
    record_path = path / 'run.json' if path.is_dir() else path
    return json.loads(record_path.read_text(encoding='utf-8')), record_path.parent


def run_problems(record):
    """Why the run does not count as a clean, played session of the supported game."""
    exit_info = record.get('exit') or {}
    facts = record.get('facts') or {}
    checks = [
        (record.get('clean') is True, 'the run is not marked clean'),
        (record.get('not_clean_because') == [], 'the run lists reasons it is not clean: %s'
         % record.get('not_clean_because')),
        (bool(record.get('reached_ship')), 'the run never reached the ship'),
        (record.get('outcome') == 'clean-quit', 'the run did not end with a clean quit (outcome %r)'
         % record.get('outcome')),
        (exit_info.get('how') == 'quit' and exit_info.get('code') == 0,
         'the game did not quit through the engine with exit code 0 (%r)' % exit_info),
        (record.get('agent_bye') is True, 'the test agent did not see the shutdown'),
        (record.get('dumps') == [], 'the run left crash dumps: %s' % record.get('dumps')),
        (record.get('restore_problems') == [], 'the install was not restored: %s' % record.get('restore_problems')),
        (facts.get('exe_sha256') == EXE_SHA and facts.get('game_dll_sha256') == GAME_DLL_SHA,
         'the run used another game build than the one this loader supports'),
    ]
    return [reason for passed, reason in checks if not passed]


def recorded_hashes(facts):
    """{SHA-256: ZIP name} of the packages a run record holds hashes for."""
    found = {}
    for name, digest in (facts.get('package_sha256') or {}).items():
        found[str(digest).upper()] = name
    for entry in facts.get('packages') or []:
        if isinstance(entry, dict) and entry.get('sha256'):
            found[str(entry['sha256']).upper()] = entry.get('name')
    return found


def deployment_problems(record, zip_path, zip_sha):
    """Why the record does not show that this exact ZIP was deployed."""
    facts = record.get('facts') or {}
    if record.get('condition') != 'packages':
        return ['the run did not deploy package ZIPs (condition %r, not packages)' % record.get('condition')]
    hashes = recorded_hashes(facts)
    if zip_sha in hashes:
        return []
    names = [entry if isinstance(entry, str) else (entry or {}).get('name') for entry in facts.get('packages') or []]
    if not hashes:
        return ['the run record lists its packages by name only (%s); it needs their SHA-256 '
                '(facts.package_sha256) to show which bytes were deployed' % ', '.join(map(str, names))]
    if zip_path.name in names:
        return ['%s in the run had other bytes than this ZIP (SHA-256 %s)' % (zip_path.name, zip_sha)]
    return ['the run did not deploy this ZIP (SHA-256 %s)' % zip_sha]


def zip_contents(zip_path):
    """(the Wwise callbacks resource, the provenance revision) of a loader release ZIP."""
    with zipfile.ZipFile(zip_path) as bundle:
        data = bundle.read('data/' + ARCHIVE)
        provenance = next(name for name in bundle.namelist() if name.endswith('-manifest.json'))
        revision = json.loads(bundle.read(provenance)).get('revision')
    resource = read_resource(data, resource_hash(CALLBACK_PATH))
    if resource is None:
        raise ValueError('no Wwise callbacks resource in ' + zip_path.name)
    return resource, revision


def log_problems(run_dir, revision):
    """Why the run's loader log does not show this loader starting."""
    log = run_dir / 'logs' / 'BingusSharedLoader.log'
    if not log.is_file():
        return ['the run kept no loader log (logs/BingusSharedLoader.log)']
    lines = log.read_text(encoding='utf-8', errors='replace').splitlines()
    problems = []
    if not lines or lines[0] != 'Bingus Shared Loader %s; API 1' % revision:
        problems.append('the run\'s loader log is not from %s: %r' % (revision, lines[0] if lines else ''))
    if not any(line.startswith('Startup finished') for line in lines):
        problems.append('the run\'s loader log never reached "Startup finished"')
    return problems


def check(run_path, zip_path, current):
    """(problems, resource SHA-256, run name) for a run, a ZIP and the current build's resource."""
    record, run_dir = load_run(run_path)
    zip_path = Path(zip_path)
    resource, revision = zip_contents(zip_path)
    problems = run_problems(record)
    problems += deployment_problems(record, zip_path, sha(zip_path.read_bytes()))
    problems += log_problems(run_dir, revision)
    if resource != current:
        problems.append('the ZIP holds another loader resource than the current sources build (%s, current %s)'
                        % (sha(resource), sha(current)))
    return problems, sha(resource), run_dir.name


def pin(script, digest, run_name):
    """Writes TESTED_CALLBACK_SHA (and the run it came from) into a build script."""
    text = script.read_text(encoding='utf-8')
    replacement = ("# Pinned by scripts/pin_tested.py from TestHarness run %s.\nTESTED_CALLBACK_SHA = '%s'\n"
                   % (run_name, digest))
    updated, count = PIN.subn(lambda _: replacement, text)
    if count != 1:
        raise ValueError('expected exactly one TESTED_CALLBACK_SHA line in ' + str(script))
    script.write_text(updated, encoding='utf-8', newline='\n')


def current_resource():
    """The Wwise callbacks resource the current sources build, compiled in a temporary folder."""
    _, callback = vanilla_inputs()
    with tempfile.TemporaryDirectory(prefix='loader-pin-') as temp:
        return compile_resource(callback, Path(temp))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('run', type=Path, help='TestHarness run.json or run folder')
    parser.add_argument('zip', type=Path, help='the loader release ZIP that run deployed')
    parser.add_argument('--check', action='store_true', help='report only; write nothing')
    args = parser.parse_args(argv)
    problems, digest, run_name = check(args.run, args.zip, current_resource())
    if problems:
        raise SystemExit('Not pinned:\n- ' + '\n- '.join(problems))
    if args.check:
        print('Would pin %s from TestHarness run %s.' % (digest, run_name))
        return
    pin(BUILD_SCRIPT, digest, run_name)
    print('Pinned %s from TestHarness run %s in scripts/build.py; rebuild, then commit it.' % (digest, run_name))


if __name__ == '__main__':
    main()
