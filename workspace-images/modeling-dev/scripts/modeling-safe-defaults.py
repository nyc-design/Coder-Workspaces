"""Generate a safe startup.blend; existing user startup files are untouched.

Run with Blender --background --factory-startup --python-exit-code 1 --python.
Loaded projects override these scene defaults. Explicitly disable Cycles
denoising in automated renders, including those using --factory-startup.
"""
import pathlib
import bpy

config = pathlib.Path(bpy.utils.user_resource('CONFIG', create=True))
startup = config / 'startup.blend'
if startup.exists():
    print(f'Preserving existing Blender startup: {startup}')
else:
    scene = bpy.context.scene
    scene.cycles.device = 'CPU'
    scene.cycles.use_denoising = False
    scene.cycles.use_preview_denoising = False
    bpy.ops.wm.save_homefile()
    assert startup.is_file(), f'Startup file was not created: {startup}'
    print(f'Saved safe CPU / no-denoising startup: {startup}')
