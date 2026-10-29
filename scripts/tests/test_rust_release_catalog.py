import importlib.util
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    'publisher', Path(__file__).resolve().parents[2] / 'mirror/publish-rust-x.py')
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class RustCatalogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def release(self, version, beam=False, generic=False):
        folder = self.root / 'releases' / version
        folder.mkdir(parents=True)
        assets = []
        architectures = ('aarch64_cortex-a73', 'aarch64_cortex-a53', 'x86_64') if beam else ('x86_64', 'aarch64_cortex-a53')
        if generic:
            architectures += ('aarch64_generic',)
        for arch in architectures:
            for fmt in ('apk', 'ipk'):
                revision = 'r1' if fmt == 'apk' else '1'
                package_version = version + '-' + revision
                name = f'rust-x_{package_version}_{arch}.{fmt}'
                data = name.encode()
                (folder / name).write_bytes(data)
                assets.append(dict(file=name, package='rust-x', version=package_version,
                                   architecture=arch, format=fmt, size=len(data),
                                   sha256=hashlib.sha256(data).hexdigest()))
        manifest = folder / 'manifest.json'
        manifest.write_text(json.dumps(dict(version=version, assets=assets)))
        return folder, assets

    def test_multiple_versions_numeric_order_and_availability(self):
        for version in ('0.0.9', '0.0.26', '0.0.25'):
            self.release(version)
        publisher.write_catalog(self.root)
        catalog = json.loads((self.root / 'releases.json').read_text())
        self.assertEqual([r['version'] for r in catalog['releases']],
                         ['0.0.26', '0.0.25', '0.0.9'])
        release = catalog['releases'][0]
        self.assertEqual(release['formats'], ['apk', 'ipk'])
        self.assertEqual(release['architectures'], ['aarch64_cortex-a53', 'x86_64'])
        self.assertEqual(len(release['assets']), 4)

    def test_beam_architecture_is_available_without_replacing_old_packages(self):
        self.release('0.0.27', beam=True)
        entry = publisher.build_catalog(self.root)['releases'][0]
        self.assertEqual(len(entry['assets']), 6)
        self.assertEqual(entry['assets'][0]['architecture'], 'aarch64_cortex-a73')
        self.assertEqual(entry['architectures'], ['aarch64_cortex-a53', 'aarch64_cortex-a73', 'x86_64'])

    def test_generic_preserves_historical_availability(self):
        self.release('0.0.28', beam=True)
        self.release('0.0.29', beam=True, generic=True)
        entries = publisher.build_catalog(self.root)['releases']
        self.assertEqual(len(entries[0]['assets']), 8)
        self.assertIn('aarch64_generic', entries[0]['architectures'])
        self.assertNotIn('aarch64_generic', entries[1]['architectures'])

    def test_publish_generic_pair_and_keep_historical_archives(self):
        source, assets = self.release('0.0.29', beam=True, generic=True)
        public_key = b'public test key'
        (source / 'forkop-apk.pem').write_bytes(public_key)
        for asset in assets:
            if asset['format'] == 'apk':
                asset['signed'] = True
        manifest = dict(version='0.0.29', assets=assets, apk_signed=True,
                        signing_public_key_sha256=hashlib.sha256(public_key).hexdigest())
        (source / 'openwrt-manifest.json').write_text(json.dumps(manifest))
        (source / 'SHA256SUMS').write_text(''.join(
            f'{a["sha256"]}  {a["file"]}\n' for a in assets))
        destination = self.root / 'published'
        with patch('sys.argv', ['publish-rust-x.py', str(source), str(destination), '--latest']):
            publisher.main()
        latest = json.loads((destination / 'latest.json').read_text())
        self.assertEqual(len(latest['assets']), 8)
        catalog = json.loads((destination / 'releases.json').read_text())
        self.assertIn('aarch64_generic', catalog['releases'][0]['architectures'])
        # Re-running the publisher is idempotent; changing an archived package fails.
        with patch('sys.argv', ['publish-rust-x.py', str(source), str(destination), '--latest']):
            publisher.main()
        package = destination / 'releases' / '0.0.29' / assets[0]['file']
        package.write_bytes(b'changed')
        with patch('sys.argv', ['publish-rust-x.py', str(source), str(destination), '--latest']):
            with self.assertRaises(AssertionError):
                publisher.main()

    def test_missing_size_and_hash_failures_excluded(self):
        self.release('0.0.26')
        for version, failure in (('0.0.23', 'missing'), ('0.0.24', 'size'), ('0.0.25', 'hash')):
            folder, assets = self.release(version)
            package = folder / assets[0]['file']
            if failure == 'missing':
                package.unlink()
            elif failure == 'size':
                package.write_bytes(b'bad')
            else:
                package.write_bytes(b'x' * assets[0]['size'])
        self.assertEqual([r['version'] for r in publisher.build_catalog(self.root)['releases']],
                         ['0.0.26'])

    def test_empty_preserves_previous_catalog(self):
        previous = self.root / 'releases.json'
        previous.write_text('previous')
        with self.assertRaises(ValueError):
            publisher.write_catalog(self.root)
        self.assertEqual(previous.read_text(), 'previous')

    def test_atomic_failure_preserves_previous_and_cleans_temp(self):
        self.release('0.0.26')
        previous = self.root / 'releases.json'
        previous.write_text('previous')
        with patch.object(publisher.os, 'replace', side_effect=OSError('fixture')):
            with self.assertRaises(OSError):
                publisher.write_catalog(self.root)
        self.assertEqual(previous.read_text(), 'previous')
        self.assertEqual(list(self.root.glob('.releases.json-*')), [])

    def test_duplicate_and_path_escape_rejected(self):
        folder, assets = self.release('0.0.26')
        for invalid in ({**assets[0], 'file': '../outside.apk'}, assets[0]):
            (folder / 'manifest.json').write_text(json.dumps(
                dict(version='0.0.26', assets=assets + [invalid])))
            self.assertEqual(publisher.build_catalog(self.root)['releases'], [])


if __name__ == '__main__':
    unittest.main()
