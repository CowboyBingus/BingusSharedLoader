"""Verify the loader owns precisely the Wwise resource and ships no native module."""
import hashlib
import json
import re
from pathlib import Path
import struct
import sys
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from archive import ARCHIVE, resource_hash

with zipfile.ZipFile(sys.argv[1]) as package:
    names = package.namelist()
    expected = {f'data/{ARCHIVE}{s}' for s in ('', '.stream', '.gpu_resources')}
    expected |= {'BingusSharedLoader-README.txt', 'BingusSharedLoader-manifest.json', 'manifest.json', 'thumbnail.png'}
    assert len(names) == len(expected) and set(names) == expected
    manager = json.loads(package.read('manifest.json'))
    assert manager['Version'] == 1 and manager['Name'] == 'Bingus Shared Loader - v11'
    assert len(manager['Options']) == 1 and manager['Options'][0]['Include'] == ['data']
    assert manager['Guid'] == '612eaf70-d682-43c7-9efd-16dcc695f977'
    assert manager['IconPath'] == manager['Options'][0]['Image'] == 'thumbnail.png'
    assert package.read('thumbnail.png').startswith(b'\x89PNG\r\n\x1a\n')
    report = json.loads(package.read('BingusSharedLoader-manifest.json'))
    assert report['revision'] == 'loader-v11' and report['provides'] == {'shared_loader_api': 1}
    for name, expected_hash in report['files'].items():
        assert hashlib.sha256(package.read(name)).hexdigest().upper() == expected_hash
    data = package.read('data/' + ARCHIVE)
    assert struct.unpack_from('<III', data) == (0xF0000011, 1, 1)
    entry = struct.unpack_from('<7Q6I', data, 104)
    assert entry[0] == resource_hash('core/wwise/lua/wwise_flow_callbacks')
    assert entry[1] == 0xA14E8DFA2CD117E2 and entry[-1] == 0
    assert entry[2] % 16 == 0 and entry[2] + entry[7] <= len(data)
    assert struct.unpack_from('<II', data, entry[2]) == (entry[7] - 8, 2)
    for suffix in ('.stream', '.gpu_resources'):
        assert package.read('data/' + ARCHIVE + suffix) == b''
    for name in names:
        content = package.read(name).lower()
        assert b'users\\' not in content and b'users/' not in content
        assert b'virtualprotect' not in content and b'writeprocessmemory' not in content
        assert not re.search(rb'mods/cowboybingus/reinforcement_beacon_fix(?!_data)', content)
print('PASS: standalone loader archive, manager option, hashes, privacy and sole Wwise ownership')
