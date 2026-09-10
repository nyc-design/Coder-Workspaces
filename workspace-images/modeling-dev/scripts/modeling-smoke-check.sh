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
blender --background --factory-startup --python-exit-code 1 \
    --python /usr/local/share/modeling-tools/blender-smoke.py -- "$work" "${1:-}"
gltf-validate "$work/scene.glb" >/dev/null
echo '[modeling-dev] Modeling smoke checks passed'
