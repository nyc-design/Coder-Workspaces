import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("blender_runtime", Path(__file__).with_name("check_runtime.py"))
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class RuntimeTests(unittest.TestCase):
    def test_elf_architecture_and_missing_library_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            elf = Path(directory) / "blender"
            for machine, output, success in [(183, "libc.so => /lib/libc.so", True),
                                              (62, "", False),
                                              (183, "libexample.so => not found", False)]:
                header = bytearray(20)
                header[:6] = b"\x7fELF\x02\x01"
                header[18:20] = struct.pack("<H", machine)
                elf.write_bytes(header)
                with patch.object(runtime.subprocess, "run", return_value=SimpleNamespace(
                    stdout=output, stderr="", returncode=0,
                )):
                    if success:
                        runtime.check(directory)
                    else:
                        with self.assertRaises(RuntimeError):
                            runtime.check(directory)

    def test_empty_payload_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(RuntimeError):
                runtime.check(directory)


if __name__ == "__main__":
    unittest.main()
