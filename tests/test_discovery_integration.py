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
    # after_startup: the registry module and two discovered addons register callbacks. The
    # example addon's counts the modules still loading (the other loader's in-progress entry
    # aside); Example_2's raises.
    after_startup = (b"local loader = CowboyBingusModLoader\n"
                     b"assert(loader.after_startup(function()\n"
                     b"    local loading = 0\n"
                     b"    for name, status in pairs(loader.modules) do\n"
                     b"        if status == 'loading' and name ~= 'mods/new_author/in_progress' then loading = loading + 1 end\n"
                     b"    end\n"
                     b"    after_startup_calls = (after_startup_calls or '') .. 'example:' .. loading .. ';'\n"
                     b"end))\n")
    entries = [
        ('mods/patpatpatrick/example_addon', b"assert(CowboyBingusModLoader.api == 1)\n" + after_startup
         + b"return true\n"),
        ('mods/new_author/group/Example_2',
         b"assert(CowboyBingusModLoader.after_startup(function() error('after startup failure', 0) end))\n"
         b"return true\n"),
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
    legacy_body = (b'assert(CowboyBingusModLoader.api == 1)\n'
                   b"assert(CowboyBingusModLoader.after_startup(function()\n"
                   b"    after_startup_calls = (after_startup_calls or '') .. 'legacy;'\n"
                   b"end))\n"
                   b'return true\n')
    (base / 'legacy.lua').write_bytes(legacy_body)
    resource_files.append(f"['{legacy}'] = '{(base / 'legacy.lua').as_posix()}',")
    legacy_archive = make_archive({resource_hash(legacy): struct.pack('<II', len(legacy_body), 2) + legacy_body})
    (base / 'data' / ARCHIVE).write_bytes(legacy_archive)
    # Copies of one resource in several archives: a second declaration of an addon
    # (hidden), a compiled copy of the registry module (used), and declared addons
    # hidden by a compiled and an undeclared copy, which must not start.
    def lua(body):
        return struct.pack('<II', len(body), 2) + body

    def declared(name, body):
        return lua(('-- HD2-Addon: ' + name + '\n').encode() + body)

    compiled = lua((base / 'stock.ljbc').read_bytes())
    # The archive with the hidden copy of Example_2 also declares two entries whose
    # rows follow that copy (rows are sorted by resource hash): the Lua test fails
    # reads of the hidden copy and checks that these still start.
    example = 'mods/new_author/group/Example_2'
    neighbours = ['mods/new_author/after_a', 'mods/new_author/after_b']
    assert all(resource_hash(name) > resource_hash(example) for name in neighbours)
    for name in neighbours:
        source = base / (name.rsplit('/', 1)[1] + '.lua')
        source.write_bytes(b'return true\n')
        resource_files.append(f"['{name}'] = '{source.as_posix()}',")
    copies = {
        5: {resource_hash(example): declared(example, b'error("hidden copy executed")\n'),
            **{resource_hash(name): declared(name, b'return true\n') for name in neighbours}},
        6: {resource_hash('mods/new_author/hidden'): declared('mods/new_author/hidden', b'error("hidden entry")\n')},
        90: {resource_hash('mods/new_author/hidden'): compiled},
        7: {resource_hash('mods/new_author/shadowed'): declared('mods/new_author/shadowed', b'error("shadowed")\n')},
        91: {resource_hash('mods/new_author/shadowed'): lua(b'return true\n')},
        92: {resource_hash(legacy): compiled},
    }
    for number, resources in copies.items():
        (base / 'data' / (ARCHIVE[:-1] + str(number))).write_bytes(make_archive(resources))
    data = (base / 'data' / (ARCHIVE[:-1] + '5')).read_bytes()
    rows = [struct.unpack_from('<7Q6I', data, 104 + index * 80) for index in range(3)]
    assert [row[0] for row in rows] == sorted(row[0] for row in rows) and rows[0][0] == resource_hash(example)
    (base / 'failures.lua').write_text("return {archive = '%s', unreadable_envelope = %d, unreadable_body = %d}\n"
                                       % (ARCHIVE[:-1] + '5', rows[0][2], rows[0][2] + 8), encoding='utf-8')
    (base / 'local').mkdir()
    (base / 'resources.lua').write_text('return {\n' + '\n'.join(resource_files) + '\n}', encoding='utf-8')
    print(run([LUA, ROOT / 'tests/test_discovery_integration.lua', base, ROOT / 'src'], env=env).strip())
    # The same run in the game's own lua51.dll (skipped without the game).
    print(run([sys.executable, ROOT / 'tests/game_lua.py', ROOT / 'tests/test_discovery_integration.lua', base,
               ROOT / 'src'], env=env).strip())
