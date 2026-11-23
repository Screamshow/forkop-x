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


def github_release(repository, version, source, **metadata):
    return dict(tag_name=version, **metadata, assets=[
        dict(name=path.name, size=path.stat().st_size, digest='sha256:' + asset(path)['sha256'],
             browser_download_url=f'https://github.com/{repository}/releases/download/{version}/{path.name}')
        for path in sorted(source.iterdir())])


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
    https://api.github.com/*'&page='*)
        if [ -n "${FIXTURE_PAGES_DIR:-}" ]; then
            cat "$FIXTURE_PAGES_DIR/${url##*&page=}.json"
        else
            cat "$FIXTURE_API"
        fi;;
    https://api.github.com/*) cat "$FIXTURE_API";;
    https://github.com/*)
        [ -z "${FIXTURE_HTTP_LOG:-}" ] || printf '%s\n' "$url" >> "$FIXTURE_HTTP_LOG"
        cp "$FIXTURE_ASSETS/${url##*/}" "$arg";;
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
        api.write_text(json.dumps([github_release('Screamshow/forkop-x', version, source, prerelease=True)]))
        self.env.update(FIXTURE_API=str(api), FIXTURE_ASSETS=str(source))
        self.run_script('sync-forkop-canary', success=False)
        self.assertFalse((self.updates / 'canary.json').exists())
        broken.write_bytes(package)
        self.run_script('sync-forkop-canary')
        self.verify_published('canary', version)

    def test_canary_selects_highest_published_version_across_pages(self):
        version = '3.10.0-canary.10'
        source = self.forkop(version)
        self.core()
        first_page = [
            dict(tag_name='9.0.0-canary.1', prerelease=True, draft=True),
            dict(tag_name='3.9.99-canary.100', prerelease=True),
            dict(tag_name='8.0.0-canary.1', prerelease=False),
        ]
        first_page.extend(dict(tag_name=f'3.1.{patch}', prerelease=False) for patch in range(97))
        (self.work / '1.json').write_text(json.dumps(first_page))
        second_page = [dict(tag_name='3.10.0-canary.2', prerelease=True),
                       github_release('Screamshow/forkop-x', version, source, prerelease=True, draft=False)]
        (self.work / '2.json').write_text(json.dumps(second_page))
        self.env.update(FIXTURE_API=str(self.work / '1.json'), FIXTURE_PAGES_DIR=str(self.work),
                        FIXTURE_ASSETS=str(source))
        self.run_script('sync-forkop-canary')
        self.verify_published('canary', version)

        pointer = (self.updates / 'canary.json').read_bytes()
        (self.work / '2.json').write_text(json.dumps(second_page[:1]))
        self.run_script('sync-forkop-canary')
        self.assertEqual((self.updates / 'canary.json').read_bytes(), pointer)

    def test_unchanged_canary_avoids_asset_downloads_and_checks_integrity_hourly(self):
        version = '3.0.0-canary.1'
        source = self.forkop(version)
        self.core()
        api = self.work / 'api.json'
        remote_release = github_release('Screamshow/forkop-x', version, source, prerelease=True)
        api.write_text(json.dumps([remote_release]))
        download_log = self.work / 'downloads'
        self.env.update(FIXTURE_API=str(api), FIXTURE_ASSETS=str(source), FIXTURE_HTTP_LOG=str(download_log))
        self.run_script('sync-forkop-canary')
        publish_downloads = download_log.read_text().splitlines()
        self.assertEqual(len(publish_downloads), 7)

        pointer = self.updates / 'canary.json'
        original = pointer.read_bytes()
        inode = pointer.stat().st_ino
        download_log.write_text('')
        for _ in range(12):
            self.run_script('sync-forkop-canary')
        self.assertEqual(download_log.read_text(), '')
        self.assertEqual((pointer.stat().st_ino, pointer.read_bytes()), (inode, original))

        archive = self.updates / 'canary/releases' / version
        damaged = archive / f'forkop_{version}.apk'
        original_body = damaged.read_bytes()
        damaged.write_bytes(b'x' * len(original_body))
        stamp = self.updates / 'canary' / f'.{version}.verified'
        os.utime(stamp, (1, 1))
        self.run_script('sync-forkop-canary', success=False)
        self.assertEqual(download_log.read_text(), '')
        self.assertEqual((pointer.stat().st_ino, pointer.read_bytes()), (inode, original))
        damaged.write_bytes(original_body)
        self.run_script('sync-forkop-canary')
        self.assertGreater(stamp.stat().st_mtime, 1)
        self.assertEqual(download_log.read_text(), '')

        changed = next(a for a in remote_release['assets'] if a['name'] == damaged.name)
        changed['digest'] = 'sha256:' + 'f' * 64
        api.write_text(json.dumps([remote_release]))
        self.run_script('sync-forkop-canary', success=False)
        self.assertEqual(download_log.read_text(), '')
        self.assertEqual(damaged.read_bytes(), original_body)

    def test_unchanged_legacy_canary_skips_downloads_without_a_native_pin(self):
        version = '2.7.6-canary.1'
        source = self.forkop(version)
        # Legacy archives may have unsigned APK and no Forkop manifest.
        (source / 'forkop-manifest.json').unlink()
        api = self.work / 'api.json'
        api.write_text(json.dumps([github_release('Screamshow/forkop-x', version, source, prerelease=True)]))
        download_log = self.work / 'downloads'
        self.env.update(FIXTURE_API=str(api), FIXTURE_ASSETS=str(source), FIXTURE_HTTP_LOG=str(download_log))
        self.run_script('sync-forkop-canary')
        self.assertEqual(len(download_log.read_text().splitlines()), 6)
        download_log.write_text('')
        self.run_script('sync-forkop-canary')
        os.utime(self.updates / 'canary' / f'.{version}.verified', (1, 1))
        self.run_script('sync-forkop-canary')
        self.assertEqual(download_log.read_text(), '')
        self.assertNotIn('xrust_version', json.loads((self.updates / 'canary.json').read_text()))

    def test_extended_archive_stays_immutable_and_survives_failed_new_tag(self):
        version = 'v1.14.2'
        repository = 'shtorm-7/sing-box-extended'
        source = self.work / 'extended'
        source.mkdir()
        names = ['sing-box-extended_1.14.2_openwrt_x86_64.apk',
                 'sing-box-extended_1.14.2_openwrt_x86_64.ipk',
                 'sing-box-1.14.2-linux-arm64-compressed.tar.gz']
        for name in names:
            (source / name).write_text(name)
        release = github_release(repository, version, source)
        api = self.work / 'api.json'
        api.write_text(json.dumps(release))
        self.env.update(FIXTURE_API=str(api), FIXTURE_ASSETS=str(source),
                        SING_BOX_EXTENDED_LOCK_FILE=str(self.work / 'extended.lock'))
        self.run_script('sync-sing-box-extended')

        archive = self.root / 'releases' / version
        self.assertEqual(sorted(path.name for path in archive.iterdir()), sorted(names + ['release.json', 'SHA256SUMS']))
        archive_inode = archive.stat().st_ino
        original = {path.name: path.read_bytes() for path in archive.iterdir()}
        release['body'] = 'Updated upstream notes'
        release['assets'][0]['download_count'] = 10
        release['assets'].reverse()
        api.write_text(json.dumps(release))
        self.run_script('sync-sing-box-extended')

        (source / names[0]).write_text('Changed asset for an existing tag')
        api.write_text(json.dumps(github_release(repository, version, source)))
        self.run_script('sync-sing-box-extended', success=False)

        next_version = 'v1.14.3'
        api.write_text(json.dumps(github_release(repository, next_version, source)))
        (source / names[1]).write_text('Read does not match new release digest')
        self.run_script('sync-sing-box-extended', success=False)
        self.assertFalse((self.root / 'releases' / next_version).exists())
        self.assertFalse(list(self.root.glob('.*.staging.*')))
        self.assertEqual(archive.stat().st_ino, archive_inode)
        self.assertEqual({path.name: path.read_bytes() for path in archive.iterdir()}, original)
        self.assertEqual((self.root / 'latest.json').read_bytes(), original['release.json'])
        self.assertEqual((self.root / 'LATEST').read_text(), version + '\n')

        api.write_text(json.dumps(github_release(repository, next_version, source)))
        self.run_script('sync-sing-box-extended')
        self.assertEqual(archive.stat().st_ino, archive_inode)
        self.assertEqual((self.root / 'latest.json').read_bytes(),
                         (self.root / 'releases' / next_version / 'release.json').read_bytes())
        self.assertEqual((self.root / 'LATEST').read_text(), next_version + '\n')


if __name__ == '__main__':
    unittest.main()
