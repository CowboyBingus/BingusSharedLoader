"""The probe loader's log header passes the real-play study's checks in both outcomes (probe
running, probe failed to start): none of the first three lines matches perfkit.MOD_FAILURE and the
first does not name a probe build, as PerformanceBaseline/StudyRecorder's test does. A planted
'-probe' first line and a failure line are caught, so the check cannot pass vacuously.

Usage: python tests/test_probe_header.py <build-probe/probe-header-lines.txt> [perfkit.py]
"""
import importlib.util
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
WORKSPACE = Path(os.environ.get('BINGUS_WORKSPACE', Path(__file__).resolve().parents[5]))
PERFKIT = Path(sys.argv[2]) if len(sys.argv) > 2 else WORKSPACE / 'PerformanceBaseline/perfkit.py'


def study_problems(lines, failure):
    """What the study's log checks find in a log's first three lines."""
    found = [line for line in lines[:3] if failure.search(line)]
    if '-probe' in lines[0]:
        found.append('probe build named on the first line')
    return found


spec = importlib.util.spec_from_file_location('perfkit', PERFKIT)
perfkit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(perfkit)
rows = Path(sys.argv[1]).read_text(encoding='utf-8').splitlines()
for outcome in ('running', 'not running'):
    lines = [row.split('\t', 1)[1] for row in rows if row.split('\t', 1)[0] == outcome]
    # The real log's third line is the health report's start time.
    lines = lines[:2] + ['Started: 2026-10-04 12:00:00']
    assert lines[0] == 'Bingus Shared Loader loader-v19; API 1', lines
    assert lines[1].startswith('Development build loader-v19-probe4: frame probe schema 4 ' + outcome), lines
    assert study_problems(lines, perfkit.MOD_FAILURE) == [], (outcome, lines)
    assert study_problems(['Bingus Shared Loader loader-v19-probe4; API 1'] + lines[1:], perfkit.MOD_FAILURE)
    assert study_problems(lines[:1] + ['Frame probe failed to start'] + lines[2:], perfkit.MOD_FAILURE)
print('PASS: probe loader log header passes perfkit.MOD_FAILURE and the -probe check in both outcomes')
