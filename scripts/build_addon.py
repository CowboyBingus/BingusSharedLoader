"""Package a single plaintext addon entry for Bingus Shared Loader v15+."""
import argparse
import json
from pathlib import Path
import re
import struct
import uuid
import zipfile

from archive import ARCHIVE, make_archive, resource_hash


def entry_source(name, source):
    if not re.fullmatch(r'mods/[A-Za-z0-9_]+/[A-Za-z0-9_]+(?:/[A-Za-z0-9_]+)*', name):
        raise ValueError('Use mods/<author>/<entry> with letters, digits and underscores')
    if name == 'mods/codex/loader':
        raise ValueError('mods/codex/loader is reserved for the compatibility dispatcher')
    if source.startswith((b'\xef\xbb\xbf', b'\x1b')) or b'\0' in source:
        raise ValueError('Entry must be plaintext UTF-8 Lua without a BOM or bytecode')
    source.decode('utf-8')
    marker = ('-- HD2-Addon: ' + name + '\n').encode('utf-8')
    if len(marker) > 256:
        raise ValueError('Entry declaration must fit within 256 bytes including newline')
    if source.startswith(b'-- HD2-Addon:'):
        line, separator, remainder = source.partition(b'\n')
        if not separator or line.rstrip(b'\r') != marker[:-1]:
            raise ValueError('Existing declaration must match the resource name')
        source = remainder
    return marker + source


def build_addon(name, source, guid, output, display_name=None):
    guid = str(uuid.UUID(guid))
    body = entry_source(name, source)
    resource = struct.pack('<II', len(body), 2) + body
    archive = make_archive({resource_hash(name): resource})
    title = display_name or name
    description = 'Requires Bingus Shared Loader v15 or newer / API 1. Enable both and deploy.'
    manifest = {'Version': 1, 'Guid': guid, 'Name': title, 'Description': description,
                'Options': [{'Name': title, 'Description': description, 'Include': ['Addon']}]}
    files = {'manifest.json': (json.dumps(manifest, indent=2) + '\n').encode(),
             'Addon/' + ARCHIVE: archive,
             'Addon/' + ARCHIVE + '.stream': b'',
             'Addon/' + ARCHIVE + '.gpu_resources': b''}
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as package:
        for path, content in sorted(files.items()):
            info = zipfile.ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            package.writestr(info, content)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--name', required=True, help='Game resource path, without .lua')
    parser.add_argument('--entry', required=True, type=Path, help='Plain UTF-8 Lua initialization script')
    parser.add_argument('--guid', required=True, help='Your mod UUID; reuse it for subsequent releases')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--display-name')
    args = parser.parse_args()
    if args.entry.resolve() == args.output.resolve():
        parser.error('Output must not overwrite the entry source')
    result = build_addon(args.name, args.entry.read_bytes(), args.guid, args.output, args.display_name)
    print('Built ' + str(result))


if __name__ == '__main__':
    main()
