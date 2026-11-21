import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PACKAGES = ('forkop', 'luci-app-forkop', 'luci-i18n-forkop-ru')


def asset(path):
    data = path.read_bytes()
    return {'file': path.name, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}


@unittest.skipUnless(shutil.which('bash') and shutil.which('jq') and shutil.which('flock'), 'requires Linux publisher tools')
class ChannelPublisherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.root = self.work / 'public'
        self.updates = self.root / 'updates'
        self.updates.mkdir(parents=True)
        (self.root / 'mirror').mkdir()
        (self.root / 'mirror/current').symlink_to('legacy-feed')
        (self.root / 'MIRROR_LATEST').write_text('2.7.6\n')
        (self.root / 'forkop-apk.pem').write_bytes(b'fixture verification key')
        self.bin = self.work / 'bin'
        self.bin.mkdir()
        self.executable('apk', '#!/bin/sh\n[ "$1" = --keys-dir ] && [ "$2" = "$MIRROR_ROOT" ] && [ "$3" = verify ]\n')
        self.executable('curl', '''#!/bin/sh
for arg do
    case "$arg" in https://*) url="$arg";; esac
done
case "$url" in
    https://api.github.com/*) cat "$FIXTURE_API";;
    https://github.com/*) cp "$FIXTURE_ASSETS/${url##*/}" "$arg";;
    *) exit 1;;
esac
''')
        self.env = {**os.environ, 'MIRROR_ROOT': str(self.root), 'APK_BIN': str(self.bin / 'apk'),
                    'FORKOP_CANARY_LOCK_FILE': str(self.work / 'canary.lock'),
                    'FORKOP_CHANNEL_MANIFEST_WRITER': str(ROOT / 'scripts/write-channel-manifest.sh'),
                    'FORKOP_RELEASE_CATALOG_WRITER': str(ROOT / 'scripts/write-release-catalog.py'),
                    'PATH': str(self.bin) + os.pathsep + os.environ['PATH']}

    def executable(self, name, contents):
        path = self.bin / name
        path.write_text(contents)
        path.chmod(0o755)

    def core(self):
        pin = '0.0.45'
        folder = self.root / 'rust-x/releases' / pin
        folder.mkdir(parents=True)
        assets = []
        for arch in ('x86_64', 'aarch64_cortex-a53'):
            for fmt, revision in (('apk', 'r1'), ('ipk', '1')):
                version = f'{pin}-{revision}'
                path = folder / f'rust-x_{version}_{arch}.{fmt}'
                path.write_text(path.name)
                assets.append({**asset(path), 'name': path.name, 'architecture': arch, 'format': fmt,
                               'version': version, 'package': 'rust-x',
                               'url': f'https://mirror.51343.ru/forkop/rust-x/releases/{pin}/{path.name}'})
        (folder / 'manifest.json').write_text(json.dumps(
            dict(schema=1, name='rust-x', version=pin, package_revision=1,
                 minimum_forkop_major=3, apk_signed=True, assets=assets)))
        return folder

    def forkop(self, version):
        folder = self.work / version
        folder.mkdir()
        assets = []
        for package in PACKAGES:
            for fmt in ('apk', 'ipk'):
                path = folder / f'{package}_{version}.{fmt}'
                path.write_text(path.name)
                assets.append(asset(path))
        (folder / 'forkop-apk.pem').write_bytes((self.root / 'forkop-apk.pem').read_bytes())
        (folder / 'SHA256SUMS').write_text('')
        (folder / 'forkop-manifest.json').write_text(json.dumps(
            dict(version=version, xrust_version='0.0.45', apk_signed=True, assets=assets)))
        return folder

    def run_script(self, script, *args, success=True):
        result = subprocess.run(['bash', str(ROOT / 'mirror' / script), *map(str, args)],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stderr)

    def verify_published(self, channel, version):
        pointer = json.loads((self.updates / f'{channel}.json').read_text())
        self.assertEqual(pointer['tag_name'], version)
        self.assertEqual(pointer['xrust_version'], '0.0.45')
        catalog = json.loads((self.updates / 'releases.json').read_text())
        self.assertEqual(catalog['releases'][0]['xrust_version'], pointer['xrust_version'])
        self.assertEqual(os.readlink(self.root / 'mirror/current'), 'legacy-feed')
        self.assertEqual((self.root / 'MIRROR_LATEST').read_text(), '2.7.6\n')

    def test_stable_needs_exact_archive_and_preserves_legacy_apk_feed(self):
        source = self.forkop('3.0.0')
        self.run_script('publish-forkop-feed', source, '3.0.0', success=False)
        self.assertFalse((self.updates / 'stable.json').exists())
        self.core()
        self.run_script('publish-forkop-feed', source, '3.0.0')
        self.verify_published('stable', '3.0.0')
        self.run_script('publish-forkop-feed', source, '3.0.0')
        self.assertEqual((self.updates / 'latest.json').read_bytes(), (self.updates / 'stable.json').read_bytes())

    def test_canary_checks_core_assets_before_switching_pointer(self):
        version = '3.0.0-canary.1'
        source = self.forkop(version)
        folder = self.core()
        broken = next(folder.glob('*.apk'))
        package = broken.read_bytes()
        broken.write_bytes(package + b'bad')
        api = self.work / 'api.json'
        api.write_text(json.dumps([dict(tag_name=version, prerelease=True, assets=[
            dict(name=p.name, size=p.stat().st_size, digest='sha256:' + asset(p)['sha256'],
                 browser_download_url=f'https://github.com/Screamshow/forkop-x/releases/download/{version}/{p.name}')
            for p in source.iterdir()])]))
        self.env.update(FIXTURE_API=str(api), FIXTURE_ASSETS=str(source))
        self.run_script('sync-forkop-canary', success=False)
        self.assertFalse((self.updates / 'canary.json').exists())
        broken.write_bytes(package)
        self.run_script('sync-forkop-canary')
        self.verify_published('canary', version)


if __name__ == '__main__':
    unittest.main()
