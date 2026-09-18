"""Verify the author helper's finished ZIP and independent resource identity."""
from pathlib import Path
import json
import struct
import sys
import tempfile
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from archive import ARCHIVE
from build_addon import build_addon, entry_source

with tempfile.TemporaryDirectory() as temporary:
    output = Path(temporary) / 'addon.zip'
    name = 'mods/example_author/example_addon'
    guid = 'be46d41e-5294-4db2-a67c-6ea342fb8cb3'
    build_addon(name, b'return true\n', guid, output, 'Example Addon')
    first = output.read_bytes()
    with zipfile.ZipFile(output) as package:
        manifest = json.loads(package.read('manifest.json'))
        assert manifest['Version'] == 1 and manifest['Guid'] == guid
        assert manifest['Options'][0]['Include'] == ['Addon']
        data = package.read('Addon/' + ARCHIVE)
        row = struct.unpack_from('<7Q6I', data, 104)
        assert row[0] == 0x835db1516ca1e1ca and row[1] == 0xa14e8dfa2cd117e2
        assert struct.unpack_from('<II', data, row[2]) == (row[7] - 8, 2)
        body = data[row[2] + 8:row[2] + row[7]]
        assert body == b'-- HD2-Addon: mods/example_author/example_addon\nreturn true\n'
        assert package.read('Addon/' + ARCHIVE + '.stream') == b''
        assert package.read('Addon/' + ARCHIVE + '.gpu_resources') == b''
        assert len(package.namelist()) == 4
    build_addon(name, b'return true\n', guid, output, 'Example Addon')
    assert output.read_bytes() == first
    assert entry_source(name, body) == body
    assert entry_source(name, body.replace(b'\n', b'\r\n', 1)) == body
    for bad_name, bad_source in [(name, b'\x1bLJ'), (name, b'\xef\xbb\xbfreturn true'),
        (name, b'-- HD2-Addon: mods/other/name\n'), (name, b'\xff'),
        ('mods//entry', b''), ('mods/a//b', b''), ('mods/a/b/', b''),
        ('mods/codex/loader', b''), ('mods/a/b-c', b''), ('mods/a/' + 'b' * 256, b'')]:
        try:
            entry_source(bad_name, bad_source)
        except (ValueError, UnicodeDecodeError):
            pass
        else:
            raise AssertionError('Invalid addon entry accepted')
print('PASS: author ZIP, stable GUID, exact hash/envelope, plaintext declaration and invalid input rejection')
