"""Fail-closed Blender CPU and exchange-format image smoke test."""
import pathlib
import struct
import sys
import zipfile
import bpy

args = sys.argv[sys.argv.index('--') + 1:]
work = pathlib.Path(args[0])
assert bpy.app.version == (5, 1, 0), bpy.app.version_string
assert bpy.app.build_options.usd, 'Blender was built without USD support'
scene = bpy.context.scene
scene.render.engine = 'CYCLES'
scene.cycles.device = 'CPU'
scene.cycles.use_denoising = False
scene.cycles.use_preview_denoising = False
scene.cycles.samples = 1
scene.render.resolution_x = 32
scene.render.resolution_y = 32
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'PNG'
if '--render' in args:
    scene.render.filepath = str(work / 'cpu.png')
    assert bpy.ops.render.render(write_still=True) == {'FINISHED'}
    assert (work / 'cpu.png').read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
assert bpy.ops.export_scene.gltf(filepath=str(work / 'scene.glb'), export_format='GLB') == {'FINISHED'}
glb = (work / 'scene.glb').read_bytes()
assert struct.unpack('<4sII', glb[:12]) == (b'glTF', 2, len(glb))
assert bpy.ops.wm.usd_export(filepath=str(work / 'scene.usdz')) == {'FINISHED'}
assert zipfile.is_zipfile(work / 'scene.usdz'), 'USDZ is not a ZIP archive'
with zipfile.ZipFile(work / 'scene.usdz') as archive:
    assert archive.namelist(), 'USDZ is empty'
    assert archive.testzip() is None, 'USDZ CRC verification failed'
    assert any(name.endswith(('.usd', '.usdc', '.usda')) for name in archive.namelist())
print('PASS: Blender 5.1.0, CPU no-denoising, GLB, USDZ ZIP integrity')
