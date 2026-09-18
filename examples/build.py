"""Build the minimal example with its readable source and ZIP layout guide."""
from pathlib import Path
import sys
import zipfile

EXAMPLE = Path(__file__).resolve().parent
ROOT = EXAMPLE.parent
sys.path.insert(0, str(ROOT / 'scripts'))
from build_addon import build_addon
from package import release_directory

MODULE = 'mods/example_author/example_mod'
GUID = 'd8651e9e-dc8e-4eaa-a5e7-7b3a8c3e1d1f'

if __name__ == '__main__':
    source = (EXAMPLE / (MODULE + '.lua')).read_bytes()
    output = release_directory(ROOT) / 'Bingus-Example-Mod-v2.zip'
    build_addon(MODULE, source, GUID, output, 'Bingus Example Mod - v2')
    with zipfile.ZipFile(output, 'a') as archive:
        for name, data in [('README.md', (EXAMPLE / 'README.md').read_bytes()),
                           ('Source/' + MODULE + '.lua', source)]:
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data)
    print('Built ' + str(output))
