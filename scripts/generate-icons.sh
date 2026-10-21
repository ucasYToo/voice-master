#!/bin/bash
# Render the editable SVG sources directly at every required pixel size.
# Usage: scripts/generate-icons.sh [output-directory]
set -euo pipefail

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [output-directory]" >&2
    exit 2
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
source_dir="$script_dir/../Resources/Icons"
output_dir="${1:-$source_dir}"

exec /usr/bin/python3 - "$source_dir" "$output_dir" <<'PY'
import copy
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

source_dir = pathlib.Path(sys.argv[1]).resolve()
output_dir = pathlib.Path(sys.argv[2]).expanduser().resolve()
ET.register_namespace('', 'http://www.w3.org/2000/svg')


def run(*arguments):
    result = subprocess.run(arguments, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or 'Command failed')


def render(source, pixel_size, target, scratch, black=False):
    root = copy.deepcopy(source)
    root.set('width', str(pixel_size))
    root.set('height', str(pixel_size))
    if black:
        root.set('color', '#000000')
        for node in root.iter():
            for name, value in list(node.attrib.items()):
                node.set(name, value.replace('currentColor', '#000000'))
    # The vector viewport is set before rendering; no low-resolution PNG is enlarged.
    svg = scratch / f'{target.stem}-{pixel_size}.svg'
    ET.ElementTree(root).write(svg, encoding='utf-8', xml_declaration=True)
    run('/usr/bin/sips', '-s', 'format', 'png', str(svg), '--out', str(target))
    data = target.read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n' or data[12:16] != b'IHDR':
        raise RuntimeError(f'{target.name}: renderer did not produce PNG')
    width, height = struct.unpack('>II', data[16:24])
    if (width, height) != (pixel_size, pixel_size):
        raise RuntimeError(f'{target.name}: expected {pixel_size}px, got {width}x{height}')


try:
    app = ET.parse(source_dir / 'AppIcon.svg').getroot()
    status = ET.parse(source_dir / 'StatusIcon.svg').getroot()
    with tempfile.TemporaryDirectory(prefix='voice-master-icons-') as temporary:
        scratch = pathlib.Path(temporary)
        iconset = scratch / 'AppIcon.iconset'
        iconset.mkdir()
        for points in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                suffix = '@2x' if scale == 2 else ''
                name = f'icon_{points}x{points}{suffix}.png'
                render(app, points * scale, iconset / name, scratch)
        icns = scratch / 'AppIcon.icns'
        run('/usr/bin/iconutil', '--convert', 'icns', '--output', str(icns), str(iconset))
        contents = icns.read_bytes()
        if contents[:4] != b'icns' or struct.unpack('>I', contents[4:8])[0] != len(contents):
            raise RuntimeError('iconutil produced an invalid ICNS container')
        for size, name in ((18, 'StatusIcon.png'), (36, 'StatusIcon@2x.png')):
            render(status, size, scratch / name, scratch, black=True)
        output_dir.mkdir(parents=True, exist_ok=True)
        for name in ('AppIcon.icns', 'StatusIcon.png', 'StatusIcon@2x.png'):
            shutil.copyfile(scratch / name, output_dir / name)
    print(f'Generated AppIcon.icns, StatusIcon.png (18px), StatusIcon@2x.png (36px) in {output_dir}')
except (OSError, ValueError, ET.ParseError, RuntimeError) as error:
    print(f'Icon generation failed: {error}', file=sys.stderr)
    sys.exit(1)
PY
