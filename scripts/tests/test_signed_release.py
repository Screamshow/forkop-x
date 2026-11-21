import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


signer = module('signer', ROOT / 'mirror/sign-forkop-release.py')
release = module('release', ROOT / 'scripts/release.py')
stable = module('stable', ROOT / 'mirror/publish-forkop-stable.py')


def archive(name, data):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w:gz') as tar:
        member = tarfile.TarInfo(name)
        member.size = len(data)
        tar.addfile(member, io.BytesIO(data))
    return output.getvalue()


class SignatureGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.manifest = self.make_manifest('2.2.3')

    def make_manifest(self, version):
        manifest = dict(version=version, source_commit='a' * 40, apk_signed=False, assets=[])
        for package in signer.PACKAGES:
            for ext in ('apk', 'ipk'):
                name = f'{package}_{version}.{ext}'
                data = b'unsigned-test-apk'
                if ext == 'ipk':
                    control = f'Package: {package}\nVersion: {version}\nArchitecture: all\n'.encode()
                    data = archive('./control.tar.gz', archive('./control', control))
                (self.directory / name).write_bytes(data)
                manifest['assets'].append(dict(file=name, package=package, format=ext,
                    architecture='noarch' if ext == 'apk' else 'all', version=signer.apk_version(version) if ext == 'apk' else version,
                    size=len(data), sha256=hashlib.sha256(data).hexdigest()))
        return manifest

    def test_accepts_complete_release_with_correct_ipk_identity(self):
        signer.validate(self.directory, self.manifest)

    def test_forkop_3_manifest_requires_an_exact_xrust_release(self):
        manifest = self.make_manifest('3.0.0')
        with self.assertRaisesRegex(ValueError, 'exact Xrust'):
            signer.validate(self.directory, manifest)
        manifest['xrust_version'] = 'latest'
        with self.assertRaisesRegex(ValueError, 'exact Xrust'):
            signer.validate(self.directory, manifest)
        manifest['xrust_version'] = '0.0.44'
        signer.validate(self.directory, manifest)

    def test_rejects_corruption(self):
        (self.directory / self.manifest['assets'][0]['file']).write_bytes(b'corrupted')
        with self.assertRaisesRegex(ValueError, 'Checksum'):
            signer.validate(self.directory, self.manifest)

    def test_rejects_missing_duplicate_or_traversal_asset(self):
        for kind in ('missing', 'duplicate', 'traversal'):
            with self.subTest(kind=kind):
                manifest = copy.deepcopy(self.manifest)
                if kind == 'missing':
                    manifest['assets'].pop()
                elif kind == 'duplicate':
                    manifest['assets'][-1] = manifest['assets'][0]
                else:
                    manifest['assets'][0]['file'] = '../foreign.apk'
                with self.assertRaisesRegex(ValueError, 'six'):
                    signer.validate(self.directory, manifest)

    def test_rejects_wrong_ipk_control_even_with_matching_hash(self):
        asset = next(a for a in self.manifest['assets'] if a['format'] == 'ipk')
        data = archive('control.tar.gz', archive('control', b'Package: foreign\nVersion: 2.2.3-canary.1\nArchitecture: all\n'))
        (self.directory / asset['file']).write_bytes(data)
        asset.update(size=len(data), sha256=hashlib.sha256(data).hexdigest())
        with self.assertRaisesRegex(ValueError, 'IPK metadata'):
            signer.validate(self.directory, self.manifest)

    def test_signed_flag_required_for_each_apk(self):
        self.manifest['apk_signed'] = True
        with self.assertRaisesRegex(ValueError, 'Unsigned APK'):
            signer.validate(self.directory, self.manifest, signed=True)

    def test_signed_key_hash_checked(self):
        for asset in self.manifest['assets']:
            asset['signed'] = True
        self.manifest.update(apk_signed=True, signing_public_key_sha256='0' * 64)
        (self.directory / 'forkop-apk.pem').write_bytes(b'public-key')
        with self.assertRaisesRegex(ValueError, 'Public key'):
            signer.validate(self.directory, self.manifest, signed=True)

    def test_mismatched_uploaded_digest_rejected(self):
        asset = self.manifest['assets'][0]
        uploaded = dict(assets=[dict(name=asset['file'], size=asset['size'], digest='sha256:' + '0' * 64)])
        with self.assertRaisesRegex(ValueError, 'GitHub asset'):
            release.verify_uploaded(uploaded, self.directory, [asset['file']])

    def test_failed_build_stops_gate(self):
        with patch.object(release, 'gh', return_value=dict(headSha='a' * 40, status='completed', conclusion='failure')):
            with self.assertRaisesRegex(RuntimeError, 'Build failed'):
                release.wait_run('example/repo', 1, 'a' * 40, 1)

    def test_build_from_changed_main_rejected(self):
        with patch.object(release, 'gh', return_value=dict(headSha='b' * 40, status='completed', conclusion='success')):
            with self.assertRaisesRegex(ValueError, 'source changed'):
                release.wait_run('example/repo', 1, 'a' * 40, 1)

    def test_canary_version_order(self):
        self.assertLess(release.version_key('2.2.3-canary.2'), release.version_key('2.2.3-canary.10'))
        self.assertLess(release.version_key('2.2.3-canary.10'), release.version_key('2.2.3'))

    def test_draft_resume_uses_pinned_source_before_tag_exists(self):
        self.assertEqual(release.release_source_ref({'draft': True, 'target_commitish': 'a' * 40}), 'a' * 40)
        with self.assertRaisesRegex(ValueError, 'exact source commit'):
            release.release_source_ref({'draft': True, 'target_commitish': 'main'})
        self.assertEqual(release.release_source_ref({'draft': False, 'tag_name': '2.2.3-canary.1'}), '2.2.3-canary.1')

    def operation(self):
        return release.Release(SimpleNamespace(output=self.directory, ssh_key=Path('test-key'), timeout=1, resume=True, xrust_version=None), 'forkop', '2.2.3-canary.1')

    def test_paired_xrust_release_preserves_legacy_latest(self):
        operation = release.Release(SimpleNamespace(
            forkop='3.0.0-canary.1', xrust_version='0.0.45', output=self.directory,
            ssh_key=Path('test-key'), timeout=1, resume=False), 'rust-x', '0.0.45')
        operation.source = 'a' * 40
        operation.directory.mkdir(parents=True)
        (operation.directory / 'openwrt-manifest.json').write_text('{"assets": []}')
        archive_url = release.BASE + '/forkop/rust-x/releases/0.0.45/manifest.json'
        catalog_url = release.BASE + '/forkop/rust-x/releases.json'
        endpoints = {archive_url: {'assets': [], 'binary_source_commit': operation.source},
                     catalog_url: {'releases': [{'version': operation.version, 'assets': []}]}}
        with patch.object(operation, 'current', return_value={'isDraft': True}), \
                patch.object(operation, 'verify_signatures'), patch.object(operation, 'remote') as remote, \
                patch.object(release, 'run') as commands, \
                patch.object(release, 'public_json', side_effect=endpoints.__getitem__) as query:
            operation.finalize()
            self.assertEqual(commands.call_args.args[-1], '--latest=false')
            operation.sync()
            self.assertNotIn('--latest', remote.call_args.args[0])
            self.assertEqual([call.args[0] for call in query.call_args_list], [archive_url, catalog_url])

    def test_xrust_pin_requires_complete_matching_mirror_assets(self):
        version = '0.0.44'
        data = b'fixture core archive'
        checksum = hashlib.sha256(data).hexdigest()
        manifest = dict(schema=1, name='rust-x', version=version, package_revision=1,
                        minimum_forkop_major=3, apk_signed=True, assets=[])
        uploaded = dict(tag_name='rust-x-v0.0.44', draft=False, prerelease=False, assets=[])
        for fmt, revision in (('apk', 'r1'), ('ipk', '1')):
            name = f'rust-x_{version}-{revision}_x86_64.{fmt}'
            manifest['assets'].append(dict(name=name, format=fmt, architecture='x86_64',
                version=f'{version}-{revision}', package='rust-x', size=len(data), sha256=checksum,
                url=f'{release.BASE}/forkop/rust-x/releases/{version}/{name}'))
            uploaded['assets'].append(dict(name=name, size=len(data), digest='sha256:' + checksum))
        with patch.object(release, 'gh', return_value=uploaded), \
                patch.object(release, 'public_json', return_value=manifest), \
                patch.object(release.urllib.request, 'urlopen', side_effect=lambda *_a, **_kw: io.BytesIO(data)) as fetch_file:
            release.verify_xrust_pin(version)
            self.assertEqual([call.args[0] for call in fetch_file.call_args_list], [a['url'] for a in manifest['assets']])
            fetch_file.side_effect = FileNotFoundError
            with self.assertRaises(FileNotFoundError):
                release.verify_xrust_pin(version)
            for corrupted in (data[:-1], data + b'extra', b'x' * len(data)):
                fetch_file.side_effect = lambda *_a, **_kw: io.BytesIO(corrupted)
                with self.assertRaisesRegex(ValueError, 'size or checksum'):
                    release.verify_xrust_pin(version)
            manifest.pop('minimum_forkop_major')
            with self.assertRaisesRegex(ValueError, 'Invalid mirror manifest'):
                release.verify_xrust_pin(version)
            manifest['minimum_forkop_major'] = 3
            manifest['assets'][0]['sha256'] = 'b' * 64
            with self.assertRaisesRegex(ValueError, 'asset mismatch'):
                release.verify_xrust_pin(version)
            manifest['assets'].pop(0)
            with self.assertRaisesRegex(ValueError, 'Incomplete mirror archive'):
                release.verify_xrust_pin(version)

    def test_public_release_cannot_be_resigned(self):
        operation = self.operation()
        with patch.object(operation, 'current', return_value={'isDraft': False}), patch.object(release, 'run') as mutate:
            with self.assertRaisesRegex(ValueError, 'public Forkop'):
                operation.finalize_forkop()
            mutate.assert_not_called()

    def test_unsigned_public_release_resume_cannot_modify_github(self):
        operation = self.operation()
        operation.source = 'a' * 40
        operation.directory.mkdir(parents=True)
        (operation.directory / 'forkop-manifest.json').write_text(json.dumps(self.manifest))
        for asset in self.manifest['assets']:
            (operation.directory / asset['file']).write_bytes((self.directory / asset['file']).read_bytes())
        with patch.object(operation, 'current', return_value={'isDraft': False}), patch.object(release, 'run') as commands:
            with self.assertRaisesRegex(ValueError, 'Unsigned APK'):
                operation.finalize()
            self.assertTrue(all(call.args[:3] == ('gh', 'release', 'download') for call in commands.call_args_list))

    def stable_setup(self):
        root = self.directory / 'public'
        root.mkdir()
        (root / 'forkop-apk.pem').write_bytes(b'public-key')
        (self.directory / 'forkop-apk.pem').write_bytes(b'public-key')
        self.manifest.update(apk_signed=True, signing_public_key_sha256=hashlib.sha256(b'public-key').hexdigest())
        for asset in self.manifest['assets']:
            if asset['format'] == 'apk':
                asset['signed'] = True
        (self.directory / 'forkop-manifest.json').write_text(json.dumps(self.manifest))
        (self.directory / 'SHA256SUMS').write_text('')
        return root

    def test_stable_publisher_refuses_changed_existing_archive(self):
        root = self.stable_setup()
        archive_dir = root / 'updates/releases/2.2.3'
        archive_dir.mkdir(parents=True)
        (archive_dir / self.manifest['assets'][0]['file']).write_bytes(b'different-old-package')
        with patch('sys.argv', ['publisher', str(self.directory), '--root', str(root)]), patch.object(stable.subprocess, 'run') as commands:
            with self.assertRaisesRegex(ValueError, 'existing stable archive'):
                stable.main()
            self.assertEqual(commands.call_count, 1)  # signature check, no publication

    def test_stable_publisher_checks_result_and_updates_catalog(self):
        root = self.stable_setup()
        def command(args, **kwargs):
            if args[0] == '/usr/local/sbin/publish-forkop-feed':
                archive_dir = root / 'updates/releases/2.2.3'
                archive_dir.mkdir(parents=True)
                for asset in self.manifest['assets']:
                    (archive_dir / asset['file']).write_bytes((self.directory / asset['file']).read_bytes())
        with patch('sys.argv', ['publisher', str(self.directory), '--root', str(root)]), patch.object(stable.subprocess, 'run', side_effect=command) as commands:
            stable.main()
            self.assertIn('/usr/local/lib/forkop/write-release-catalog.py', commands.call_args.args[0])
        self.assertTrue((root / 'updates/releases/2.2.3/forkop-manifest.json').is_file())


if __name__ == '__main__':
    unittest.main()
