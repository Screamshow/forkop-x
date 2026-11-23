#!/usr/bin/env python3
"""Build, sign, publish and verify Forkop X and/or Xrust in one command.

Run on the operator computer with gh authentication and mirror SSH access.
Private signing and SSH keys never enter GitHub Actions.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
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
GITHUB_DISPATCH_API_VERSION = '2026-03-10'


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


def verify_mirror_asset(url, size, sha256):
    hasher = hashlib.sha256()
    remaining = size
    with urllib.request.urlopen(url, timeout=60) as response:
        while chunk := response.read(min(1024 * 1024, remaining + 1)):
            remaining -= len(chunk)
            if remaining < 0:
                break
            hasher.update(chunk)
    if remaining != 0 or hasher.hexdigest() != sha256:
        raise ValueError(f'Mirror package size or checksum mismatch: {url.rsplit("/", 1)[-1]}')


def verify_xrust_pin(version, expected_revision=None):
    """Require the immutable mirror archive to match the public Xrust release."""
    tag = f'rust-x-v{version}'
    release = gh('api', f'repos/Screamshow/xrust/releases/tags/{tag}')
    if release.get('draft') or release.get('prerelease') or release.get('tag_name') != tag:
        raise ValueError(f'Pinned Xrust {version} must be a public stable release')
    base = BASE + f'/forkop/rust-x/releases/{version}/'
    manifest = public_json(base + 'manifest.json')
    revision = manifest.get('package_revision')
    if (manifest.get('schema') != 1 or manifest.get('name') != 'rust-x' or manifest.get('apk_signed') is not True or
            manifest.get('version') != version or manifest.get('minimum_forkop_major') != 3 or
            type(revision) is not int or revision <= 0 or
            (expected_revision is not None and revision != expected_revision)):
        raise ValueError(f'Invalid mirror manifest for pinned Xrust {version}')

    github_packages = {asset['name']: asset for asset in release['assets']
                       if re.fullmatch(r'rust-x_[A-Za-z0-9_.+-]+\.(apk|ipk)', asset['name'])}
    seen = set()
    formats = set()
    for asset in manifest['assets']:
        name, fmt, arch = asset['name'], asset['format'], asset['architecture']
        package_version = version + (f'-r{revision}' if fmt == 'apk' else f'-{revision}')
        upstream = github_packages.get(name, {})
        if (fmt not in {'apk', 'ipk'} or name in seen or asset['package'] != 'rust-x' or
                name != f'rust-x_{package_version}_{arch}.{fmt}' or asset['version'] != package_version or
                asset['url'] != base + name or type(asset['size']) is not int or asset['size'] <= 0 or
                not re.fullmatch(r'[a-f0-9]{64}', asset['sha256']) or
                upstream.get('size') != asset['size'] or upstream.get('digest') != 'sha256:' + asset['sha256']):
            raise ValueError(f'Pinned Xrust GitHub/mirror asset mismatch: {name}')
        seen.add(name)
        formats.add(fmt)
    if seen != set(github_packages) or formats != {'apk', 'ipk'}:
        raise ValueError(f'Incomplete mirror archive for pinned Xrust {version}')
    for asset in manifest['assets']:
        verify_mirror_asset(asset['url'], asset['size'], asset['sha256'])


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
        self.xrust_version = args.xrust_version if project == 'forkop' else None
        self.xrust_revision = None
        forkop_version = getattr(args, 'forkop', None)
        self.archive_only = project == 'rust-x' and bool(forkop_version and version_key(forkop_version)[0] >= 3)
        self.repo = 'Screamshow/' + ('forkop-x' if project == 'forkop' else 'xrust')
        self.tag = version if project == 'forkop' else 'rust-x-v' + version
        self.directory = (args.output / project / self.tag).resolve()
        self.build_record = self.directory / '.workflow-run.json'
        self.workflow = 'build.yml' if project == 'forkop' else 'release.yml'
        self.ssh = ['ssh', '-i', str(args.ssh_key), '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', HOST]
        self.scp = ['scp', '-i', str(args.ssh_key), '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10']

    def remote(self, command):
        return run(*self.ssh, command, capture=True)

    def saved_build(self):
        if not self.args.resume or not self.build_record.is_file():
            return None
        record = json.loads(self.build_record.read_text(encoding='utf-8'))
        run_id = record.get('run_id')
        pending_tag_push = run_id is None and record.get('pending_tag_push') is True
        if (record.get('repo') != self.repo or record.get('tag') != self.tag or
                not re.fullmatch(r'[0-9a-f]{40}', record.get('source', '')) or
                (not pending_tag_push and (type(run_id) is not int or run_id <= 0))):
            raise ValueError('Invalid local workflow run record for this release')
        return record

    def save_build(self, run_id, *, pending_tag_push=False):
        if not pending_tag_push and (type(run_id) is not int or run_id <= 0):
            raise ValueError('GitHub dispatch did not return a workflow run ID')
        self.directory.mkdir(parents=True, exist_ok=True)
        descriptor, path = tempfile.mkstemp(dir=self.directory, prefix='.workflow-run-')
        path = Path(path)
        try:
            with os.fdopen(descriptor, 'w', encoding='utf-8') as file:
                json.dump(dict(repo=self.repo, tag=self.tag, source=self.source, run_id=run_id,
                               pending_tag_push=pending_tag_push), file)
            path.replace(self.build_record)
        finally:
            path.unlink(missing_ok=True)

    def exact_tag_exists(self):
        tag_ref = 'refs/tags/' + self.tag
        refs = gh('api', f'repos/{self.repo}/git/matching-refs/tags/{self.tag}')
        if not any(item['ref'] == tag_ref for item in refs):
            return False
        if gh('api', f'repos/{self.repo}/commits/{self.tag}')['sha'] != self.source:
            raise ValueError('Existing release tag points to a different commit')
        return True

    def preflight(self):
        releases = gh('api', '--paginate', f'repos/{self.repo}/releases', '--slurp')
        found = [r for page in releases for r in page if r['tag_name'] == self.tag]
        self.existing = found[0] if found else None
        if self.existing and not self.args.resume:
            raise ValueError(f'{self.tag} already exists; use --resume to continue verification/sync')
        saved = self.saved_build() if not self.existing or self.existing['draft'] else None
        needs_xrust_pin = self.project == 'forkop' and version_key(self.version)[0] >= 3
        if needs_xrust_pin and not self.existing and not saved and self.xrust_version is None:
            raise ValueError('A new Forkop 3.x release requires --xrust-version')
        if self.existing:
            # A draft created by workflow_dispatch may not create its tag until
            # publication. Resume from its pinned build commit in that case.
            ref = release_source_ref(self.existing)
            self.source = gh('api', f'repos/{self.repo}/commits/{ref}')['sha']
            if saved and saved['source'] != self.source:
                raise ValueError('Draft source differs from the local workflow run record')
        else:
            self.source = saved['source'] if saved else gh('api', f'repos/{self.repo}/commits/main')['sha']
        if needs_xrust_pin and (not self.existing or self.existing['draft']):
            self.read_xrust_source_pin()
        if self.project == 'rust-x' and not self.existing:
            content = gh('api', f'repos/{self.repo}/contents/Cargo.toml?ref={self.source}')
            cargo = base64.b64decode(content['content']).decode()
            workspace = cargo.split('[workspace.package]', 1)[1].split('\n[', 1)[0]
            if not re.search(r'^version = "' + re.escape(self.version) + r'"$', workspace, re.MULTILINE):
                raise ValueError('Prepare and push the Xrust workspace version/notes before releasing')
        if not self.existing or self.existing['draft']:
            self.exact_tag_exists()
        channel = ('canary' if '-canary.' in self.version else 'stable')
        pointer = BASE + ('/forkop/rust-x/latest.json' if self.project == 'rust-x' else f'/forkop/updates/{channel}.json')
        if not self.archive_only:
            current = public_json(pointer)
            if version_key(current.get('version', current.get('tag_name'))) > version_key(self.version):
                raise ValueError('Requested release is older than the mirror channel; refusing to move it backward')
        self.remote(f'test -x {APK} && test -r {KEY} && test -r {PUBLIC_KEY}')
        if self.project == 'forkop' and version_key(self.version)[0] >= 3:
            publisher = 'sync-forkop-canary' if channel == 'canary' else 'publish-forkop-feed'
            self.remote('test -r /usr/local/lib/forkop/write-channel-manifest.sh && '
                        f'grep -Fq write-channel-manifest.sh /usr/local/sbin/{publisher} && '
                        'grep -Fq xrust_version /usr/local/lib/forkop/write-release-catalog.py')

    def read_xrust_source_pin(self):
        contents = f'repos/{self.repo}/contents/forkop'
        if self.existing and self.existing['draft']:
            files = gh('api', f'{contents}?ref={self.source}')
            if not any(item['name'] == 'xrust-pin' for item in files):
                if self.xrust_version is None:
                    raise ValueError('Resume this legacy Forkop draft with its exact --xrust-version')
                return
        info = gh('api', f'{contents}/xrust-pin?ref={self.source}')
        pin = re.fullmatch(r'([0-9]+\.[0-9]+\.[0-9]+) ([1-9][0-9]*)\n?',
                           base64.b64decode(info['content']).decode())
        if pin is None or (self.xrust_version is not None and pin[1] != self.xrust_version):
            raise ValueError('The requested Xrust release does not match forkop/xrust-pin at the build source')
        self.xrust_version, self.xrust_revision = pin[1], int(pin[2])

    def draft_has_build_assets(self, release):
        if not release['isDraft']:
            return True
        uploaded = {a['name']: a for a in release['assets']
                    if a.get('size', 0) > 0 and a.get('state', 'uploaded').lower() == 'uploaded'}
        if self.project == 'forkop':
            packages = load(ROOT / 'mirror/sign-forkop-release.py').PACKAGES
            return all(f'{package}_{self.version}.{ext}' in uploaded
                       for package in packages for ext in ('apk', 'ipk'))
        if 'openwrt-manifest.json' not in uploaded:
            return False
        manifest = json.loads(run('gh', 'release', 'download', self.tag, '-R', self.repo,
                                  '-p', 'openwrt-manifest.json', '-O', '-', capture=True))
        if manifest.get('version') != self.version or manifest.get('binary_source_commit') != self.source:
            raise ValueError('Xrust draft manifest does not match the release source or version')
        assets = manifest.get('assets', [])
        pairs = {(a['architecture'], a['format']) for a in assets}
        architectures = {arch for arch, _ in pairs}
        if (not {'x86_64', 'aarch64_cortex-a53'} <= architectures or len(pairs) != len(assets) or
                pairs != {(arch, fmt) for arch in architectures for fmt in ('apk', 'ipk')}):
            return False
        return all(
            a['file'] in uploaded and uploaded[a['file']]['size'] == a['size'] and
            uploaded[a['file']].get('digest') == 'sha256:' + a['sha256'] for a in assets)

    def tag_push_run(self, *, create):
        if create:
            self.save_build(None, pending_tag_push=True)
            run('gh', 'api', f'repos/{self.repo}/git/refs', '-f', 'ref=refs/tags/' + self.tag, '-f', 'sha=' + self.source)
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            runs = gh('run', 'list', '-R', self.repo, '--workflow', self.workflow, '--event', 'push',
                      '--commit', self.source, '--limit', '30',
                      '--json', 'databaseId,headSha,headBranch')
            matches = [r for r in runs if r['headSha'] == self.source and r['headBranch'] == self.tag]
            if len(matches) > 1:
                raise RuntimeError('Multiple exact tag builds appeared; inspect GitHub Actions before resuming')
            if matches:
                return matches[0]['databaseId']
            time.sleep(5)
        raise TimeoutError('No release build appeared; inspect GitHub Actions before retrying')

    def dispatch_build(self, *, pending_tag_push=False):
        if self.exact_tag_exists():
            if pending_tag_push:
                return self.tag_push_run(create=False)
            ref = self.tag
        elif self.project == 'rust-x' or gh('api', f'repos/{self.repo}/commits/main')['sha'] != self.source:
            # A new Xrust tag starts its only build. For an old Forkop draft,
            # a tag also lets recovery use its exact commit after main advances.
            return self.tag_push_run(create=True)
        else:
            ref = 'main'
        inputs = ['-f', 'inputs[tag]=' + self.tag] if self.project == 'rust-x' else [
            '-f', 'inputs[release_tag]=' + self.tag, '-F', 'inputs[publish_release]=true']
        dispatched = gh('api', f'repos/{self.repo}/actions/workflows/{self.workflow}/dispatches',
                        '-H', 'X-GitHub-Api-Version: ' + GITHUB_DISPATCH_API_VERSION,
                        '-f', 'ref=' + ref, *inputs)
        return dispatched.get('workflow_run_id')

    def build(self):
        if self.existing and (not self.existing['draft'] or self.draft_has_build_assets(self.current())):
            return
        saved = self.saved_build()
        if saved and saved['run_id'] is not None:
            run_id = saved['run_id']
            state = gh('run', 'view', str(run_id), '-R', self.repo, '--json', 'status,headSha')
            if state['headSha'] != self.source:
                raise ValueError('Saved workflow run does not match the release source')
            if state['status'] != 'completed':
                wait_run(self.repo, run_id, self.source, self.args.timeout)
                if self.draft_has_build_assets(self.current()):
                    return
        run_id = self.dispatch_build(pending_tag_push=bool(saved and saved.get('pending_tag_push')))
        self.save_build(run_id)
        wait_run(self.repo, run_id, self.source, self.args.timeout)
        if not self.draft_has_build_assets(self.current()):
            raise RuntimeError('The release draft is still missing build assets; resume using --resume')

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
        if self.xrust_version is not None:
            manifest['xrust_version'] = self.xrust_version
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
        if (final['source_commit'] != self.source or final['version'] != self.version or
                final.get('xrust_version') != self.xrust_version):
            raise ValueError('Signing changed the source commit or release versions')
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
                if self.xrust_version is not None and manifest.get('xrust_version') != self.xrust_version:
                    raise ValueError('Published Forkop release has a different Xrust pin')
                if version_key(self.version)[0] >= 3:
                    verify_xrust_pin(manifest['xrust_version'])
            else:
                manifest = load(XRUST_FINALIZE).validate(self.directory, self.version, signed=True)
                if manifest['binary_source_commit'] != self.source:
                    raise ValueError('Public source mismatch')
                self.archive_only |= manifest.get('minimum_forkop_major') == 3
            names = [a['file'] for a in manifest['assets']] + [filename, 'forkop-apk.pem', 'SHA256SUMS']
            verify_uploaded(self.current(), self.directory, names)
            self.verify_signatures()
            return
        if self.project == 'forkop':
            if version_key(self.version)[0] >= 3:
                verify_xrust_pin(self.xrust_version, self.xrust_revision)
            self.finalize_forkop()
        else:
            run(sys.executable, XRUST_FINALIZE, '--tag', self.tag,
                '--ssh-key', self.args.ssh_key, '--output', self.directory)
            manifest = json.loads((self.directory / 'openwrt-manifest.json').read_text())
            self.archive_only |= manifest.get('minimum_forkop_major') == 3
        self.verify_signatures()
        args = ['gh', 'release', 'edit', self.tag, '-R', self.repo, '--draft=false']
        if self.project == 'rust-x':
            args.append('--latest=true')
        run(*args)

    def sync(self):
        if self.project == 'rust-x':
            manifest = json.loads((self.directory / 'openwrt-manifest.json').read_text())
            native_xrust = manifest.get('minimum_forkop_major') == 3
            self.archive_only |= native_xrust
            if not self.archive_only:
                previous = public_json(BASE + '/forkop/rust-x/latest.json')
                if version_key(previous['version']) > version_key(self.version):
                    raise ValueError('Refusing to downgrade the Xrust mirror pointer')
            remote = f'/srv/mirror/build/rust-x-publish/{self.tag}-{self.source[:12]}'
            self.remote(f'umask 077; mkdir -p {remote}')
            names = [a['file'] for a in manifest['assets']] + ['openwrt-manifest.json', 'forkop-apk.pem', 'SHA256SUMS']
            run(*self.scp, ROOT / 'mirror/publish-rust-x.py', *[self.directory / n for n in names], f'{HOST}:{remote}/')
            pointer_option = '' if self.archive_only else ' --latest'
            print(self.remote(f'python3 {remote}/publish-rust-x.py {remote} /srv/mirror/public/forkop/rust-x{pointer_option}'), flush=True)
            archived = public_json(BASE + f'/forkop/rust-x/releases/{self.version}/manifest.json')
            if archived['binary_source_commit'] != self.source:
                raise ValueError('Xrust mirror manifest mismatch')
            if not self.archive_only:
                latest = wait_mirror(BASE + '/forkop/rust-x/latest.json', self.version, self.args.timeout)
                if latest != archived:
                    raise ValueError('Xrust latest pointer differs from the archived manifest')
            if native_xrust:
                if archived.get('minimum_forkop_major') != 3:
                    raise ValueError('Xrust archive lost its minimum Forkop version')
            else:
                catalog = public_json(BASE + '/forkop/rust-x/releases.json')
                entry = next(r for r in catalog['releases'] if r['version'] == self.version)
                if entry['assets'] != archived['assets']:
                    raise ValueError('Xrust release catalog mismatch')
            local = {a['file']: a for a in manifest['assets']}
            for asset in archived['assets']:
                if asset['sha256'] != local[asset['file']]['sha256'] or asset['size'] != local[asset['file']]['size']:
                    raise ValueError('Xrust mirror differs from signed release')
                verify_mirror_asset(asset['url'], asset['size'], asset['sha256'])
        else:
            canary = '-canary.' in self.version
            service = 'forkop-canary-mirror.service' if canary else 'forkop-mirror.service'
            manifest = json.loads((self.directory / 'forkop-manifest.json').read_text())
            if not canary:
                remote = f'/srv/mirror/build/forkop-stable/{self.tag}-{self.source[:12]}'
                self.remote(f'umask 077; mkdir -p {remote}')
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
            if any(item.get('xrust_version') != manifest.get('xrust_version') for item in (latest, entry)):
                raise ValueError('Forkop mirror Xrust version differs from the published release')
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
    parser.add_argument('--xrust-version', metavar='VERSION', help='Exact Xrust release for Forkop 3.x')
    parser.add_argument('--ssh-key', type=Path, default=DEFAULT_SSH)
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/signed-releases')
    parser.add_argument('--timeout', type=int, default=1800)
    parser.add_argument('--resume', action='store_true', help='Continue a draft, or verify and sync an already signed public release')
    args = parser.parse_args()
    if not args.forkop and not args.rust:
        parser.error('Specify --forkop and/or --rust')
    if args.timeout <= 0:
        parser.error('--timeout must be positive')
    projects = [('forkop', args.forkop), ('rust-x', args.rust)]
    for project, version in projects:
        if version:
            pattern = r'\d+\.\d+\.\d+(-canary\.\d+)?' if project == 'forkop' else r'\d+\.\d+\.\d+'
            if not re.fullmatch(pattern, version):
                parser.error(f'Invalid {project} version')
    if args.xrust_version is not None and (not args.forkop or version_key(args.forkop)[0] < 3 or
            not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', args.xrust_version)):
        parser.error('--xrust-version requires Forkop 3.x and an exact x.y.z Xrust release')
    if args.forkop and version_key(args.forkop)[0] >= 3 and args.rust:
        if args.xrust_version is not None and args.xrust_version != args.rust:
            parser.error('--rust must match the Xrust pin when publishing both projects together')
        args.xrust_version = args.rust
        projects.reverse()
    releases = [Release(args, project, version) for project, version in projects if version]
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
