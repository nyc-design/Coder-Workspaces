#!/usr/bin/env bash
set -euo pipefail

# Fast by default for workspace startup. Image builds use --render to exercise
# a real, tiny Cycles CPU render without a display server or GPU.
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != '--render' ) ]]; then
    echo 'Usage: modeling-smoke-check [--render]' >&2
    exit 2
fi
assimp version >/dev/null
python3 - <<'PY'
import io
import cadquery as cq
import OCP
from pxr import Usd, UsdGeom
from pypdf import PdfWriter
import pypdfium2 as pdfium
assert cq.Workplane('XY').box(1, 1, 1).val().Volume() > 0
stage = Usd.Stage.CreateInMemory()
UsdGeom.Cube.Define(stage, '/Cube')
assert stage.GetPrimAtPath('/Cube')
writer = PdfWriter()
writer.add_blank_page(width=72, height=72)
buffer = io.BytesIO()
writer.write(buffer)
with pdfium.PdfDocument(buffer.getvalue()) as document:
    page = document[0]
    bitmap = page.render(scale=0.25)
    assert bitmap.width > 0
    bitmap.close()
    page.close()
PY
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf '%s\n' '{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{}]}' > "$work/smoke.gltf"
gltf-validate "$work/smoke.gltf" > /dev/null
if [[ "${1:-}" == '--render' ]]; then
    blender --background --factory-startup --python-exit-code 1 --python-expr \
        "import bpy; s=bpy.context.scene; s.render.engine='CYCLES'; s.cycles.device='CPU'; s.cycles.samples=1; s.render.resolution_x=32; s.render.resolution_y=32; s.render.resolution_percentage=100; s.render.image_settings.file_format='PNG'; s.render.filepath='$work/cpu.png'; bpy.ops.render.render(write_still=True)"
    test -s "$work/cpu.png"
else
    blender --background --factory-startup --python-exit-code 1 --python-expr \
        "import bpy; assert bpy.app.build_options.cycles; print('Blender bundled Python OK')"
fi
echo '[modeling-smoke-check] OK'
