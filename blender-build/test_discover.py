import importlib.util
import io
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("blender_discover", Path(__file__).with_name("discover.py"))
discover = importlib.util.module_from_spec(spec)
spec.loader.exec_module(discover)


class DiscoveryTests(unittest.TestCase):
    def test_version_validation(self):
        for version in ["5.2.1-rc", "v5.2.1", "5.2", "5.2.1\noutput=true", "$(whoami)"]:
            with self.assertRaises(ValueError):
                discover.version_key(version)
        self.assertGreater(discover.version_key("5.2.10"), discover.version_key("5.2.9"))

    def test_latest_published_not_development_series(self):
        pages = {
            discover.DOWNLOAD_ROOT: '<a href="Blender5.3/">dev</a><a href="Blender5.2/">stable</a>',
            discover.DOWNLOAD_ROOT + "Blender5.3/": '<a href="blender-5.3.0-alpha.sha256">alpha</a>',
            discover.DOWNLOAD_ROOT + "Blender5.2/": '<a href="blender-5.2.9.sha256">9</a><a href="blender-5.2.10.sha256">10</a>',
        }
        with patch.object(discover, "fetch", side_effect=pages.__getitem__):
            self.assertEqual(discover.select_version(""), "5.2.10")
            self.assertEqual(discover.select_version("5.2.9"), "5.2.9")
            with self.assertRaises(ValueError):
                discover.select_version("5.2.1")

    def test_release_states_and_errors(self):
        with patch.object(discover, "fetch", return_value='{"draft":false}'):
            self.assertEqual(discover.release_state("o/r", "blender-5.2.1", None), "published")
        with patch.object(discover, "fetch", return_value='{"draft":true}'):
            self.assertEqual(discover.release_state("o/r", "blender-5.2.1", None), "draft")
        for code in [404, 403, 500]:
            error = urllib.error.HTTPError("https://example.org", code, "error", {}, io.BytesIO())
            with patch.object(discover, "fetch", side_effect=error):
                if code == 404:
                    self.assertEqual(discover.release_state("o/r", "blender-5.2.1", None), "missing")
                else:
                    with self.assertRaises(urllib.error.HTTPError):
                        discover.release_state("o/r", "blender-5.2.1", None)

    def test_annotated_tag_is_peeled(self):
        tag = "refs/tags/v5.2.1"
        result = type("Result", (), {"stdout": f"{'a' * 40}\t{tag}\n{'b' * 40}\t{tag}^{{}}\n"})()
        with patch.object(discover.subprocess, "run", return_value=result):
            self.assertEqual(discover.source_commit("5.2.1"), "b" * 40)

    def test_lightweight_tag(self):
        result = type("Result", (), {"stdout": f"{'a' * 40}\trefs/tags/v5.2.1\n"})()
        with patch.object(discover.subprocess, "run", return_value=result):
            self.assertEqual(discover.source_commit("5.2.1"), "a" * 40)
        with patch.object(discover.subprocess, "run", return_value=type("Result", (), {"stdout": ""})()):
            with self.assertRaises(RuntimeError):
                discover.source_commit("5.2.1")


if __name__ == "__main__":
    unittest.main()
