"""Integration tests: run after npm ci --prefix /opt/modeling-tools."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

CLI = Path(__file__).resolve().parents[1] / 'scripts/gltf-validate.cjs'


@unittest.skipUnless(Path('/opt/modeling-tools/node_modules/gltf-validator').exists(),
                     'Install modeling package-lock.json dependencies in /opt/modeling-tools first')
class GltfValidationTests(unittest.TestCase):
    def test_valid_gltf(self):
        with tempfile.TemporaryDirectory() as directory:
            asset = Path(directory) / 'valid.gltf'
            asset.write_text(json.dumps({'asset': {'version': '2.0'}, 'scenes': [{'nodes': [0]}], 'nodes': [{}]}))
            result = subprocess.run(['node', str(CLI), str(asset)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['issues']['numErrors'], 0)

    def test_invalid_gltf(self):
        with tempfile.TemporaryDirectory() as directory:
            asset = Path(directory) / 'invalid.gltf'
            asset.write_text('{"asset":{"version":"1.0"}}')
            result = subprocess.run(['node', str(CLI), str(asset)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertGreater(json.loads(result.stdout)['issues']['numErrors'], 0)

    def test_external_buffer(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'data.bin').write_bytes(bytes(4))
            asset = root / 'buffer.gltf'
            asset.write_text(json.dumps({'asset': {'version': '2.0'},
                                        'buffers': [{'byteLength': 4, 'uri': 'data.bin'}]}))
            result = subprocess.run(['node', str(CLI), str(asset)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_external_resource_escape_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'secret.bin').write_bytes(bytes(4))
            (root / 'assets').mkdir()
            asset = root / 'assets' / 'escape.gltf'
            asset.write_text(json.dumps({'asset': {'version': '2.0'},
                                        'buffers': [{'byteLength': 4, 'uri': '../secret.bin'}]}))
            result = subprocess.run(['node', str(CLI), str(asset)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('Resource escapes asset directory', result.stdout)

    def test_missing_file_and_bad_arguments(self):
        for args in ([], ['/nonexistent/asset.glb']):
            result = subprocess.run(['node', str(CLI), *args], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)


if __name__ == '__main__':
    unittest.main()
