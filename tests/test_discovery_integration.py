"""Exercise compiled, assembled startup with real Windows enumeration and toy addons."""
import os
from pathlib import Path
import struct
import sys
import tempfile
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from archive import ARCHIVE, LUA, make_archive, resource_hash
from build import ROOT, bootstrap, run
from build_addon import build_addon

env = dict(os.environ, LUA_PATH=str(LUA.parent / '?.lua') + ';;')
with tempfile.TemporaryDirectory(prefix='bingus-discovery-') as temporary:
    base = Path(temporary)
    (base / 'data').mkdir()
    (base / 'bin').mkdir()
    stock = base / 'stock.lua'
    stock.write_text("stock_calls = (stock_calls or 0) + 1\n"
                     "assert(select('#', ...) == 3 and (...) == 'argument')\n"
                     "if stock_error then error('native startup failed') end\n"
                     "return 'first', nil, 3, nil\n", encoding='utf-8')
    run([LUA, '-bsdW', stock, base / 'stock.ljbc'], env=env)
    (base / 'startup.lua').write_text(bootstrap((base / 'stock.ljbc').read_bytes()), encoding='utf-8')
    run([LUA, '-bsdW', base / 'startup.lua', base / 'startup.ljbc'], env=env)
    entries = [
        ('mods/patpatpatrick/example_addon', b"assert(CowboyBingusModLoader.api == 1); return true\n"),
        ('mods/new_author/group/Example_2', b'return true\n'),
        ('mods/new_author/unavailable', b'error("unavailable entry executed")\n'),
        ('mods/new_author/owned', b'error("already loaded entry executed")\n'),
        ('mods/new_author/in_progress', b'error("in-progress entry executed")\n'),
        ('mods/cowboybingus/better_stratagem_bounce', b'return true\n'),
        ('mods/new_author/broken', b'error("intentional addon failure")\n'),
    ]
    resource_files = []
    for index, (name, source) in enumerate(entries):
        package = base / ('addon' + str(index) + '.zip')
        build_addon(name, source, f'be46d41e-5294-4db2-a67c-{index:012d}', package)
        with zipfile.ZipFile(package) as archive:
            data = archive.read('Addon/' + ARCHIVE)
        # Exercise manager-style renumbering, including numeric 10 > 2.
        (base / 'data' / (ARCHIVE[:-1] + str(index * 10 + 2))).write_bytes(data)
        row = struct.unpack_from('<7Q6I', data, 104)
        body = data[row[2] + 8:row[2] + row[7]]
        filename = base / (str(index) + '.lua')
        filename.write_bytes(body)
        resource_files.append(f"['{name}'] = '{filename.as_posix()}',")
    legacy = 'mods/cowboybingus/vanilla_plus_megapack'
    legacy_body = b'assert(CowboyBingusModLoader.api == 1); return true\n'
    (base / 'legacy.lua').write_bytes(legacy_body)
    resource_files.append(f"['{legacy}'] = '{(base / 'legacy.lua').as_posix()}',")
    legacy_archive = make_archive({resource_hash(legacy): struct.pack('<II', len(legacy_body), 2) + legacy_body})
    (base / 'data' / ARCHIVE).write_bytes(legacy_archive)
    (base / 'resources.lua').write_text('return {\n' + '\n'.join(resource_files) + '\n}', encoding='utf-8')
    print(run([LUA, ROOT / 'tests/test_discovery_integration.lua', base, ROOT / 'src'], env=env).strip())
