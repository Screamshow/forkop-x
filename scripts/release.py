#!/usr/bin/env python3
"""Build, sign, publish and verify Forkop X and/or Xrust in one command.

Run on the operator computer with gh authentication and mirror SSH access.
Private signing and SSH keys never enter GitHub Actions.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
XRUST_FINALIZE = ROOT / 'artifacts/xrust/scripts/finalize_release.py'
HOST = 'root@192.168.200.138'
APK = '/root/.cache/forkop/openwrt-sdk/extracted/apk/staging_dir/host/bin/apk'
KEY = '/srv/mirror/keys/forkop-apk.pem'
PUBLIC_KEY = '/srv/mirror/public/forkop/forkop-apk.pem'
DEFAULT_SSH = Path.home() / '.ssh/codex_forkop_mt6000'
BASE = 'https://mirror.51343.ru'


def run(*args, capture=False):
    if capture:
        return subprocess.check_output([str(a) for a in args], text=True, encoding='utf-8').strip()
    subprocess.run([str(a) for a in args], check=True)


def gh(*args):
    return json.loads(run('gh', *args, capture=True))


def load(path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fetch(url):
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read()


def public_json(url):
    return json.loads(fetch(url))


def version_key(version):
    match = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)(?:-canary\.(\d+))?', version)
    if not match:
        raise ValueError('Invalid catalog version')
    return (*map(int, match.groups()[:3]), match[4] is None, int(match[4] or 0))


def release_source_ref(value):
    if not value.get('draft'):
        return value['tag_name']
    ref = value.get('target_commitish', '')
    if not re.fullmatch(r'[0-9a-f]{40}', ref):
        raise ValueError('Draft release must pin its exact source commit')
    return ref


def verify_uploaded(release, directory, names):
    assets = {a['name']: a for a in release['assets']}
    for name in names:
        path = directory / name
        asset = assets.get(name, {})
        if asset.get('size') != path.stat().st_size or asset.get('digest') != 'sha256:' + digest(path):
            raise ValueError(f'GitHub asset mismatch: {name}')


def wait_run(repo, run_id, source, timeout):
    deadline = time.monotonic() + timeout
    previous = None
    while time.monotonic() < deadline:
        state = gh('run', 'view', str(run_id), '-R', repo, '--json', 'status,conclusion,headSha')
        if state['headSha'] != source:
            raise ValueError('Build source changed; refusing to publish')
        if state['status'] != previous:
            print(f'{repo} build {run_id}: {state["status"]}', flush=True)
            previous = state['status']
        if state['status'] == 'completed':
            if state['conclusion'] != 'success':
                raise RuntimeError(f'Build failed: {state["conclusion"]}')
            return
        time.sleep(10)
    raise TimeoutError(f'Build {run_id} timed out; resume using --resume')


def wait_mirror(url, expected, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        data = public_json(url)
        if data.get('tag_name', data.get('version')) == expected:
            return data
        time.sleep(10)
    raise TimeoutError('Mirror did not select the requested release')


class Release:
    def __init__(self, args, project, version):
        self.args, self.project, self.version = args, project, version
        self.repo = 'Screamshow/' + ('forkop-x' if project == 'forkop' else 'xrust')
        self.tag = version if project == 'forkop' else 'rust-x-v' + version
        self.directory = (args.output / project / self.tag).resolve()
        self.ssh = ['ssh', '-i', str(args.ssh_key), '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', HOST]
        self.scp = ['scp', '-i', str(args.ssh_key), '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10']

    def remote(self, command):
        return run(*self.ssh, command, capture=True)

    def preflight(self):
        releases = gh('api', '--paginate', f'repos/{self.repo}/releases', '--slurp')
        found = [r for page in releases for r in page if r['tag_name'] == self.tag]
        self.existing = found[0] if found else None
        if self.existing and not self.args.resume:
            raise ValueError(f'{self.tag} already exists; use --resume to continue verification/sync')
        self.source = gh('api', f'repos/{self.repo}/commits/main')['sha']
        if self.existing:
            # A draft created by workflow_dispatch may not create its tag until
            # publication. Resume from its pinned build commit in that case.
            ref = release_source_ref(self.existing)
            self.source = gh('api', f'repos/{self.repo}/commits/{ref}')['sha']
        if self.project == 'rust-x' and not self.existing:
            import base64
            content = gh('api', f'repos/{self.repo}/contents/Cargo.toml?ref={self.source}')
            cargo = base64.b64decode(content['content']).decode()
            workspace = cargo.split('[workspace.package]', 1)[1].split('\n[', 1)[0]
            if not re.search(r'^version = "' + re.escape(self.version) + r'"$', workspace, re.MULTILINE):
                raise ValueError('Prepare and push the Xrust workspace version/notes before releasing')
            tagged = subprocess.run(['gh', 'api', f'repos/{self.repo}/git/ref/tags/{self.tag}'], capture_output=True, text=True)
            if tagged.returncode == 0 and gh('api', f'repos/{self.repo}/commits/{self.tag}')['sha'] != self.source:
                raise ValueError('Existing Xrust tag points to a different commit')
        if self.project == 'forkop' and not self.existing:
            tagged = subprocess.run(['gh', 'api', f'repos/{self.repo}/git/ref/tags/{self.tag}'], capture_output=True, text=True)
            if tagged.returncode == 0 and gh('api', f'repos/{self.repo}/commits/{self.tag}')['sha'] != self.source:
                raise ValueError('Existing Forkop tag points to a different commit')
        channel = ('canary' if '-canary.' in self.version else 'stable')
        pointer = BASE + ('/forkop/rust-x/latest.json' if self.project == 'rust-x' else f'/forkop/updates/{channel}.json')
        current = public_json(pointer)
        if version_key(current.get('version', current.get('tag_name'))) > version_key(self.version):
            raise ValueError('Requested release is older than the mirror channel; refusing to move it backward')
        self.remote(f'test -x {APK} && test -r {KEY} && test -r {PUBLIC_KEY}')

    def build(self):
        if self.existing:
            return
        workflow = 'build.yml' if self.project == 'forkop' else 'release.yml'
        seen = {r['databaseId'] for r in gh('run', 'list', '-R', self.repo, '--workflow', workflow, '--limit', '100', '--json', 'databaseId')}
        if self.project == 'rust-x':
            # Dispatch against an existing tag to avoid tag-push + dispatch duplicates.
            # A missing lightweight tag is created through API; its push starts one run.
            tagged = subprocess.run(['gh', 'api', f'repos/{self.repo}/git/ref/tags/{self.tag}'], capture_output=True, text=True)
            if tagged.returncode:
                run('gh', 'api', f'repos/{self.repo}/git/refs', '-f', 'ref=refs/tags/' + self.tag, '-f', 'sha=' + self.source)
                event = 'push'
            else:
                run('gh', 'workflow', 'run', workflow, '-R', self.repo, '--ref', 'main', '-f', 'tag=' + self.tag)
                event = 'workflow_dispatch'
        else:
            run('gh', 'workflow', 'run', workflow, '-R', self.repo, '--ref', 'main', '-f', 'release_tag=' + self.tag, '-f', 'publish_release=true')
            event = 'workflow_dispatch'
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            runs = gh('run', 'list', '-R', self.repo, '--workflow', workflow, '--event', event, '--limit', '30', '--json', 'databaseId,headSha,headBranch,status')
            matches = [r for r in runs if r['databaseId'] not in seen and r['headSha'] == self.source and (event != 'push' or r['headBranch'] == self.tag)]
            if len(matches) > 1:
                raise RuntimeError('Multiple new builds appeared; inspect GitHub Actions before resuming')
            if matches:
                wait_run(self.repo, matches[0]['databaseId'], self.source, self.args.timeout)
                return
            time.sleep(5)
        raise TimeoutError('No release build appeared; inspect GitHub Actions before retrying')

    def current(self):
        return gh('release', 'view', self.tag, '-R', self.repo, '--json', 'isDraft,databaseId,assets')

    def finalize_forkop(self):
        release = self.current()
        if not release['isDraft']:
            raise ValueError('Refusing to replace a public Forkop release')
        value = gh('api', f'repos/{self.repo}/releases/{release["databaseId"]}')
        if gh('api', f'repos/{self.repo}/commits/{release_source_ref(value)}')['sha'] != self.source:
            raise ValueError('Release does not match build source')
        refs = gh('api', f'repos/{self.repo}/git/matching-refs/tags/{self.tag}')
        if any(r['ref'] == 'refs/tags/' + self.tag for r in refs):
            if gh('api', f'repos/{self.repo}/commits/{self.tag}')['sha'] != self.source:
                raise ValueError('Release tag does not match build source')
        self.directory.mkdir(parents=True, exist_ok=True)
        signer = load(ROOT / 'mirror/sign-forkop-release.py')
        assets = []
        for package in signer.PACKAGES:
            for ext in ('apk', 'ipk'):
                name = f'{package}_{self.version}.{ext}'
                run('gh', 'release', 'download', self.tag, '-R', self.repo, '-p', name, '-D', self.directory, '--clobber')
                path = self.directory / name
                assets.append(dict(file=name, package=package, format=ext, version=signer.apk_version(self.version) if ext == 'apk' else self.version,
                                   architecture='noarch' if ext == 'apk' else 'all', size=path.stat().st_size, sha256=digest(path)))
        verify_uploaded(release, self.directory, [a['file'] for a in assets])
        manifest = dict(version=self.version, source_commit=self.source, apk_signed=False, assets=assets)
        signer.validate(self.directory, manifest)
        (self.directory / 'forkop-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        remote = f'/srv/mirror/build/forkop-finalize/{self.tag}-{self.source[:12]}'
        self.remote(f'umask 077; mkdir -p {shlex.quote(remote)}')
        run(*self.scp, ROOT / 'mirror/sign-forkop-release.py', *[self.directory / a['file'] for a in assets],
            self.directory / 'forkop-manifest.json', f'{HOST}:{remote}/')
        print(self.remote(f'python3 {remote}/sign-forkop-release.py {remote} --apk-tool {APK} --sign-key {KEY} --public-key {PUBLIC_KEY}'), flush=True)
        names = [a['file'] for a in assets] + ['forkop-manifest.json', 'forkop-apk.pem', 'SHA256SUMS']
        for name in names:
            run(*self.scp, f'{HOST}:{remote}/{name}', self.directory / name)
        final = json.loads((self.directory / 'forkop-manifest.json').read_text())
        signer.validate(self.directory, final, signed=True)
        if final['source_commit'] != self.source or final['version'] != self.version:
            raise ValueError('Signing changed the source commit/version')
        if not self.current()['isDraft']:
            raise ValueError('Release became public during signing; refusing to replace assets')
        run('gh', 'release', 'upload', self.tag, '-R', self.repo, '--clobber', *[self.directory / n for n in names])
        verify_uploaded(self.current(), self.directory, names)
        return names

    def verify_signatures(self):
        manifest_name = 'forkop-manifest.json' if self.project == 'forkop' else 'openwrt-manifest.json'
        manifest = json.loads((self.directory / manifest_name).read_text())
        trusted = self.remote(f'sha256sum {PUBLIC_KEY}').split()[0]
        if digest(self.directory / 'forkop-apk.pem') != trusted:
            raise ValueError('Release public key differs from the trusted mirror key')
        remote = f'/srv/mirror/build/release-verify/{self.project}-{self.tag}-{self.source[:12]}'
        self.remote(f'umask 077; mkdir -p {remote}')
        packages = [a['file'] for a in manifest['assets'] if a['format'] == 'apk']
        run(*self.scp, *[self.directory / n for n in packages], f'{HOST}:{remote}/')
        print(self.remote(f'{APK} --keys-dir /srv/mirror/public/forkop verify ' + ' '.join(f'{remote}/{n}' for n in packages)), flush=True)

    def finalize(self):
        if not self.current()['isDraft']:
            # Public assets are immutable. Resume can only verify them and sync.
            self.directory.mkdir(parents=True, exist_ok=True)
            run('gh', 'release', 'download', self.tag, '-R', self.repo, '-D', self.directory, '--clobber')
            filename = 'forkop-manifest.json' if self.project == 'forkop' else 'openwrt-manifest.json'
            if self.project == 'forkop':
                manifest = json.loads((self.directory / filename).read_text())
                load(ROOT / 'mirror/sign-forkop-release.py').validate(self.directory, manifest, signed=True)
                if manifest['source_commit'] != self.source or manifest['version'] != self.version:
                    raise ValueError('Public source/version mismatch')
            else:
                manifest = load(XRUST_FINALIZE).validate(self.directory, self.version, signed=True)
                if manifest['binary_source_commit'] != self.source:
                    raise ValueError('Public source mismatch')
            names = [a['file'] for a in manifest['assets']] + [filename, 'forkop-apk.pem', 'SHA256SUMS']
            verify_uploaded(self.current(), self.directory, names)
            self.verify_signatures()
            return
        if self.project == 'forkop':
            self.finalize_forkop()
        else:
            run(sys.executable, XRUST_FINALIZE, '--tag', self.tag,
                '--ssh-key', self.args.ssh_key, '--output', self.directory)
        self.verify_signatures()
        run('gh', 'release', 'edit', self.tag, '-R', self.repo, '--draft=false')

    def sync(self):
        if self.project == 'rust-x':
            previous = public_json(BASE + '/forkop/rust-x/latest.json')
            if version_key(previous['version']) > version_key(self.version):
                raise ValueError('Refusing to downgrade the Xrust mirror pointer')
            remote = f'/srv/mirror/build/rust-x-publish/{self.tag}-{self.source[:12]}'
            self.remote(f'umask 077; mkdir -p {remote}')
            manifest = json.loads((self.directory / 'openwrt-manifest.json').read_text())
            names = [a['file'] for a in manifest['assets']] + ['openwrt-manifest.json', 'forkop-apk.pem', 'SHA256SUMS']
            run(*self.scp, ROOT / 'mirror/publish-rust-x.py', *[self.directory / n for n in names], f'{HOST}:{remote}/')
            print(self.remote(f'python3 {remote}/publish-rust-x.py {remote} /srv/mirror/public/forkop/rust-x --latest'), flush=True)
            url = BASE + '/forkop/rust-x/latest.json'
            latest = wait_mirror(url, self.version, self.args.timeout)
            archived = public_json(BASE + f'/forkop/rust-x/releases/{self.version}/manifest.json')
            if latest != archived or latest['binary_source_commit'] != self.source:
                raise ValueError('Xrust mirror manifest mismatch')
            catalog = public_json(BASE + '/forkop/rust-x/releases.json')
            entry = next(r for r in catalog['releases'] if r['version'] == self.version)
            if entry['assets'] != latest['assets']:
                raise ValueError('Xrust release catalog mismatch')
            local = {a['file']: a for a in manifest['assets']}
            for asset in latest['assets']:
                if asset['sha256'] != local[asset['file']]['sha256'] or asset['size'] != local[asset['file']]['size']:
                    raise ValueError('Xrust mirror differs from signed release')
                data = fetch(asset['url'])
                if len(data) != asset['size'] or hashlib.sha256(data).hexdigest() != asset['sha256']:
                    raise ValueError('Xrust mirror package mismatch')
        else:
            canary = '-canary.' in self.version
            service = 'forkop-canary-mirror.service' if canary else 'forkop-mirror.service'
            if not canary:
                remote = f'/srv/mirror/build/forkop-stable/{self.tag}-{self.source[:12]}'
                self.remote(f'umask 077; mkdir -p {remote}')
                manifest = json.loads((self.directory / 'forkop-manifest.json').read_text())
                names = [a['file'] for a in manifest['assets']] + ['forkop-manifest.json', 'forkop-apk.pem', 'SHA256SUMS']
                run(*self.scp, ROOT / 'mirror/sign-forkop-release.py', ROOT / 'mirror/publish-forkop-stable.py',
                    *[self.directory / n for n in names], f'{HOST}:{remote}/')
                print(self.remote(f'flock /run/lock/forkop-git-build.lock python3 {remote}/publish-forkop-stable.py {remote}'), flush=True)
            url = BASE + '/forkop/updates/' + ('canary.json' if canary else 'stable.json')
            # GitHub's anonymous release-list cache can lag behind publication.
            # Re-run the existing service until its public pointer agrees.
            deadline = time.monotonic() + self.args.timeout
            while time.monotonic() < deadline:
                self.remote(f'systemctl start --no-block {service}')
                time.sleep(10)
                latest = public_json(url)
                if latest.get('tag_name') == self.tag:
                    break
            else:
                raise TimeoutError('Mirror did not select the requested release; use --resume')
            prefix = 'canary/releases' if canary else 'releases'
            archived = public_json(BASE + f'/forkop/updates/{prefix}/{self.tag}/release.json')
            catalog = public_json(BASE + '/forkop/updates/releases.json')
            entry = next(r for r in catalog['releases'] if r['tag_name'] == self.tag)
            if latest != archived or len(latest['assets']) != 6:
                raise ValueError('Forkop mirror manifest mismatch')
            for asset in latest['assets']:
                data = fetch(BASE + asset['browser_download_url'])
                if hashlib.sha256(data).hexdigest() != asset['sha256'] or asset['sha256'] != digest(self.directory / asset['name']):
                    raise ValueError('Forkop mirror package mismatch')
                if next(a for a in entry['assets'] if a['name'] == asset['name'])['sha256'] != asset['sha256']:
                    raise ValueError('Forkop catalog mismatch')
        print(f'{self.repo} {self.tag}: signed, published, mirror verified', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--forkop', metavar='VERSION')
    parser.add_argument('--rust', metavar='VERSION')
    parser.add_argument('--ssh-key', type=Path, default=DEFAULT_SSH)
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/signed-releases')
    parser.add_argument('--timeout', type=int, default=1800)
    parser.add_argument('--resume', action='store_true', help='Continue a draft, or verify and sync an already signed public release')
    args = parser.parse_args()
    if not args.forkop and not args.rust:
        parser.error('Specify --forkop and/or --rust')
    if args.timeout <= 0:
        parser.error('--timeout must be positive')
    releases = []
    for project, version in (('forkop', args.forkop), ('rust-x', args.rust)):
        if version:
            pattern = r'\d+\.\d+\.\d+(-canary\.\d+)?' if project == 'forkop' else r'\d+\.\d+\.\d+'
            if not re.fullmatch(pattern, version):
                parser.error(f'Invalid {project} version')
            releases.append(Release(args, project, version))
    if args.rust and not XRUST_FINALIZE.is_file():
        parser.error('Xrust main checkout required at artifacts/xrust')
    for release in releases:
        release.preflight()
    for release in releases:
        release.build()
        release.finalize()
        release.sync()


if __name__ == '__main__':
    main()
