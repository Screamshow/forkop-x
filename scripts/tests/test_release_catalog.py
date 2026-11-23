import importlib.util
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('catalog', Path(__file__).parents[1] / 'write-release-catalog.py')
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)

spec = importlib.util.spec_from_file_location('backfill', Path(__file__).parents[1] / 'backfill-release-archives.py')
backfill = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backfill)


class CatalogTests(unittest.TestCase):
    def release(self, root, version, *, xrust_version=None):
        folder = root / ('canary/releases' if '-canary.' in version else 'releases') / version
        folder.mkdir(parents=True)
        assets = []
        for ext in ('apk', 'ipk'):
            for package in catalog.PACKAGES:
                name = f'{package}_{version}.{ext}'
                (folder / name).write_bytes(name.encode())
                assets.append({'name': name, 'sha256': hashlib.sha256(name.encode()).hexdigest()})
        manifest = {'tag_name': version, 'assets': assets}
        if xrust_version is not None:
            manifest['xrust_version'] = xrust_version
        (folder / 'release.json').write_text(json.dumps(manifest))
        return folder

    def test_integrity_order_and_older_releases(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.release(root, '1.14.7-canary.2')
            self.release(root, '1.14.7-canary.10')
            self.release(root, '1.14.7')
            self.release(root, '1.3.19')
            broken = self.release(root, '1.14.6')
            (broken / 'forkop_1.14.6.apk').write_bytes(b'corrupted')
            releases = catalog.build_catalog(root)['releases']
            self.assertEqual([r['tag_name'] for r in releases], ['1.14.7', '1.14.7-canary.10', '1.14.7-canary.2', '1.3.19'])
            self.assertEqual(len(releases[0]['assets']), 6)
            self.assertEqual(releases[1]['assets'][0]['browser_download_url'], '/forkop/updates/canary/releases/1.14.7-canary.10/forkop_1.14.7-canary.10.apk')

    def test_archived_releases_preserve_their_own_xrust_pin(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.release(root, '2.7.6')
            self.release(root, '3.0.0', xrust_version='0.0.44')
            self.release(root, '3.0.1-canary.1', xrust_version='0.0.45')
            self.release(root, '3.0.1')
            self.release(root, '3.0.2', xrust_version='latest')
            self.release(root, '3.0.3', xrust_version=44)
            releases = catalog.build_catalog(root)['releases']
            self.assertEqual([r['tag_name'] for r in releases], ['3.0.1-canary.1', '3.0.0', '2.7.6'])
            self.assertEqual([r.get('xrust_version') for r in releases], ['0.0.45', '0.0.44', None])
            self.assertNotIn('xrust_version', releases[2])

    def test_missing_translation_excludes_release(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            folder = self.release(root, '1.14.6')
            (folder / 'luci-i18n-forkop-ru_1.14.6.ipk').unlink()
            self.assertEqual(catalog.build_catalog(root)['releases'], [])

    def test_original_apk_only_release(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            folder = self.release(root, '1.1.2')
            manifest = json.loads((folder / 'release.json').read_text())
            manifest['assets'] = [a for a in manifest['assets'] if a['name'].endswith('.apk')]
            (folder / 'release.json').write_text(json.dumps(manifest))
            releases = catalog.build_catalog(root)['releases']
            self.assertEqual(len(releases), 1)
            self.assertEqual(len(releases[0]['assets']), 3)

    def test_legacy_backfill_preserves_native_archives(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            responses = []
            original = {}
            for version, pin in [('2.7.6', None), ('3.0.3', '0.0.46'), ('3.0.4-canary.1', '0.0.46'), ('4.0.0', '0.0.46')]:
                manifest = self.release(root, version, xrust_version=pin) / 'release.json'
                release = json.loads(manifest.read_text())
                for asset in release['assets']:
                    asset['digest'] = 'sha256:' + asset['sha256']
                    asset['browser_download_url'] = 'https://fixture.invalid/package'
                responses.append(release)
                original[version] = manifest, manifest.read_bytes()

            with patch.object(backfill, 'ROOT', root), patch.object(backfill, 'fetch', side_effect=[json.dumps(responses), '[]']):
                backfill.main()

            for version, (manifest, contents) in original.items():
                if version == '2.7.6':
                    self.assertNotEqual(manifest.read_bytes(), contents)
                else:
                    self.assertEqual(manifest.read_bytes(), contents)


if __name__ == '__main__':
    unittest.main()
