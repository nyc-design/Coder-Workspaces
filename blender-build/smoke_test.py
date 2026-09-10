"""GPU-free installed Blender feature and CPU render smoke test."""
import tempfile
from pathlib import Path

import bpy
import numpy

assert numpy.arange(3).sum() == 3
assert bpy.app.build_options.cycles, "Cycles missing"
assert bpy.app.build_options.usd, "USD missing"
assert bpy.app.build_options.alembic, "Alembic missing"
assert bpy.app.build_options.openvdb, "OpenVDB missing"
assert bpy.app.build_options.opencolorio, "OpenColorIO missing"
assert bpy.app.build_options.codec_ffmpeg, "FFmpeg missing"
scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.device = "CPU"
scene.cycles.samples = 1
scene.render.resolution_x = 16
scene.render.resolution_y = 16
scene.render.resolution_percentage = 100
with tempfile.TemporaryDirectory() as directory:
    scene.render.filepath = str(Path(directory) / "smoke.png")
    bpy.ops.render.render(write_still=True)
    assert Path(scene.render.filepath).is_file()
    usd = Path(directory) / "smoke.usdc"
    bpy.ops.wm.usd_export(filepath=str(usd))
    assert usd.is_file()
print("ARM64 installed Blender smoke test passed")
