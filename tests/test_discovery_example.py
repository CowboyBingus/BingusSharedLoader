"""Run the packaged discovery example through the packaged loader, off-game."""
from pathlib import Path
import json
import os
import struct
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from archive import ARCHIVE, LUA, resource_hash

name = 'mods/example_author/example_mod'
assert name not in (ROOT / 'src/shared_loader.lua').read_text()
with tempfile.TemporaryDirectory(prefix='bingus-example-') as temporary:
    base = Path(temporary)
    (base / 'data').mkdir()
    with zipfile.ZipFile(sys.argv[1]) as package:
        manifest = json.loads(package.read('manifest.json'))
        assert manifest['Guid'] == 'd8651e9e-dc8e-4eaa-a5e7-7b3a8c3e1d1f'
        assert manifest['Options'][0]['Include'] == ['Addon']
        data = package.read('Addon/' + ARCHIVE)
        assert struct.unpack_from('<III', data) == (0xf0000011, 1, 1)
        row = struct.unpack_from('<7Q6I', data, 104)
        assert row[0] == resource_hash(name) and row[1] == resource_hash('lua')
        assert struct.unpack_from('<II', data, row[2]) == (row[7] - 8, 2)
        body = data[row[2] + 8:row[2] + row[7]]
        assert body.startswith(('-- HD2-Addon: ' + name + '\n').encode())
        assert package.read('Source/' + name + '.lua') == body
        assert b'Addon/' in package.read('README.md')
        (base / 'entry.lua').write_bytes(body)
        (base / 'data' / (ARCHIVE[:-1] + '10')).write_bytes(data)
        for suffix in ('.stream', '.gpu_resources'):
            assert package.read('Addon/' + ARCHIVE + suffix) == b''
    with zipfile.ZipFile(sys.argv[2]) as package:
        data = package.read('data/' + ARCHIVE)
        row = struct.unpack_from('<7Q6I', data, 104)
        assert row[0] == resource_hash('core/wwise/lua/wwise_flow_callbacks')
        (base / 'startup.ljbc').write_bytes(data[row[2] + 8:row[2] + row[7]])
    env = dict(os.environ, LUA_PATH=str(LUA.parent / '?.lua') + ';;')
    result = subprocess.run([str(LUA), str(ROOT / 'tests/test_discovery_example.lua'), str(base)],
                            capture_output=True, text=True, env=env, check=True)
    print(result.stdout.strip())
