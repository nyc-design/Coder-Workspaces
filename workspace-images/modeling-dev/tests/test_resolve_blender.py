"""Release selection must not mix Blender architectures or unrelated releases."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch, MagicMock
import json

spec = importlib.util.spec_from_file_location(
    'resolve_blender', Path(__file__).resolve().parents[1] / 'scripts/resolve-blender.py'
)
resolver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolver)


def release(version='4.5.3', published='2026-01-01T00:00:00Z', **overrides):
    archive = f'blender-{version}-linux-arm64.tar.xz'
    value = {
        'tag_name': f'blender-{version}', 'id': 123, 'draft': False,
        'prerelease': False, 'published_at': published,
        'assets': [{'name': name, 'state': 'uploaded', 'size': 100,
                    'browser_download_url': f'https://github.com/o/r/releases/download/blender-{version}/{name}'}
                   for name in (archive, archive + '.sha256')],
    }
    value.update(overrides)
    return value


class ReleaseSelectionTests(unittest.TestCase):
    def test_latest_complete_release_ignores_unrelated_and_incomplete(self):
        valid = release()
        releases = [valid, release('4.5.4', '2026-02-01T00:00:00Z', assets=[]),
                    release(tag_name='v99.0.0'), release('5.0.0', draft=True),
                    release('5.0.1', prerelease=True)]
        self.assertEqual(resolver.select_release(releases)['version'], '4.5.3')

    def test_orders_by_publication_not_api_order_or_version(self):
        self.assertEqual(resolver.select_release([
            release('5.0.0'), release('4.5.5', '2026-02-01T00:00:00Z')
        ])['version'], '4.5.5')

    def test_missing_or_empty_checksum_fails_closed(self):
        candidate = release()
        candidate['assets'][1]['size'] = 0
        with self.assertRaises(ValueError):
            resolver.select_release([candidate])
        with self.assertRaises(ValueError):
            resolver.select_release([release(assets=[])])

    def test_nonfinal_versions_and_unpublished_releases_rejected(self):
        for candidate in (release('4.5.3-rc1'), release(published_at=None)):
            with self.assertRaises(ValueError):
                resolver.select_release([candidate])

    @patch.object(resolver.urllib.request, 'urlopen')
    def test_pagination_includes_older_pages(self, urlopen):
        responses = []
        for data in ([release(tag_name='unrelated')] * 100, [release()]):
            response = MagicMock()
            response.__enter__.return_value.read.return_value = json.dumps(data).encode()
            responses.append(response)
        urlopen.side_effect = responses
        self.assertEqual(resolver.resolve('o/r')['version'], '4.5.3')
        self.assertIn('page=2', urlopen.call_args[0][0].full_url)

    @patch.object(resolver.urllib.request, 'urlopen')
    def test_explicit_version_uses_tag_not_latest(self, urlopen):
        urlopen.return_value.__enter__.return_value.read.return_value = json.dumps(release()).encode()
        self.assertEqual(resolver.resolve('o/r', '4.5.3')['version'], '4.5.3')
        self.assertEqual(urlopen.call_args[0][0].full_url, 'https://api.github.com/repos/o/r/releases/tags/blender-4.5.3')

    def test_bad_repository_and_version_rejected(self):
        for repository, version in [('o/r/../x', None), ('o/r', '4.5.3/evil')]:
            with self.assertRaises(ValueError):
                resolver.resolve(repository, version)


if __name__ == '__main__':
    unittest.main()
