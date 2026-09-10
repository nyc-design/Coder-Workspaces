"""Native opt-in integration checks: BLENDER_TEST_BINARY=/path/to/blender."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
BINARY = os.environ.get('BLENDER_TEST_BINARY')


@unittest.skipUnless(BINARY, 'Set BLENDER_TEST_BINARY to run native Blender checks')
class BlenderRuntimeTests(unittest.TestCase):
    def test_safe_startup_and_saved_project_override(self):
        with tempfile.TemporaryDirectory() as directory:
            env = dict(os.environ, BLENDER_USER_CONFIG=directory)
            def run(*args):
                subprocess.run([BINARY, '--background', '--python-exit-code', '1', *args],
                               env=env, check=True, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, timeout=120)
            run('--factory-startup', '--python', str(SCRIPTS / 'modeling-safe-defaults.py'))
            startup = Path(directory) / 'startup.blend'
            original = hashlib.sha256(startup.read_bytes()).digest()
            run('--python-expr', "import bpy; s=bpy.context.scene; assert s.cycles.device == 'CPU'; assert not s.cycles.use_denoising; assert not s.cycles.use_preview_denoising")
            run('--factory-startup', '--python', str(SCRIPTS / 'modeling-safe-defaults.py'))
            self.assertEqual(original, hashlib.sha256(startup.read_bytes()).digest())
            project = str(Path(directory) / 'override.blend')
            run('--python-expr', f"import bpy; bpy.context.scene.cycles.use_denoising=True; bpy.ops.wm.save_as_mainfile(filepath={project!r})")
            run(project, '--python-expr', 'import bpy; assert bpy.context.scene.cycles.use_denoising')

    def test_cpu_render_and_exports(self):
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run([BINARY, '--background', '--factory-startup',
                            '--python-exit-code', '1', '--python',
                            str(SCRIPTS / 'blender-smoke.py'), '--', directory, '--render'],
                           check=True, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=120)
