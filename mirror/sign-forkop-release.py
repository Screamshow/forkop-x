#!/usr/bin/env python3
"""Sign a complete Forkop release on the existing signing host."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

PACKAGES = ('forkop', 'luci-app-forkop', 'luci-i18n-forkop-ru')


def apk_version(version):
    return version.replace('-canary.', '_rc')


def validate(directory, manifest, signed=False):
    version = manifest['version']
    if not re.fullmatch(r'\d+\.\d+\.\d+(-canary\.\d+)?', version):
        raise ValueError('Invalid Forkop version')
    if int(version.split('.', 1)[0]) >= 3:
        xrust_version = manifest.get('xrust_version')
        if not isinstance(xrust_version, str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', xrust_version):
            raise ValueError('Expected an exact Xrust version')
    if not re.fullmatch(r'[0-9a-f]{40}', manifest['source_commit']):
        raise ValueError('Invalid source commit')
    expected = {f'{p}_{version}.{ext}' for p in PACKAGES for ext in ('apk', 'ipk')}
    assets = manifest['assets']
    if len(assets) != 6 or {a['file'] for a in assets} != expected:
        raise ValueError('Expected exactly six Forkop packages')
    for a in assets:
        name = a['file']
        package, ext = name.split('_', 1)[0], name.rsplit('.', 1)[1]
        if a['package'] != package or a['format'] != ext:
            raise ValueError('Unexpected package identity')
        expected_version = apk_version(version) if ext == 'apk' else version
        if a['version'] != expected_version or a['architecture'] != ('noarch' if ext == 'apk' else 'all'):
            raise ValueError('Unexpected package version/architecture')
        data = (directory / name).read_bytes()
        if len(data) != a['size'] or hashlib.sha256(data).hexdigest() != a['sha256']:
            raise ValueError(f'Checksum mismatch: {name}')
        if ext == 'ipk':
            with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as outer:
                controls = [m for m in outer.getmembers() if m.name.removeprefix('./') == 'control.tar.gz']
                if len(controls) != 1:
                    raise ValueError('Missing IPK control archive')
                with tarfile.open(fileobj=io.BytesIO(outer.extractfile(controls[0]).read()), mode='r:gz') as control:
                    entries = [m for m in control.getmembers() if m.name.lstrip('./') == 'control']
                    if len(entries) != 1:
                        raise ValueError('Missing IPK control')
                    fields = dict(line.split(': ', 1) for line in control.extractfile(entries[0]).read().decode().splitlines() if ': ' in line)
                    if (fields.get('Package'), fields.get('Version'), fields.get('Architecture')) != (package, version, 'all'):
                        raise ValueError('IPK metadata mismatch')
        if signed and ext == 'apk' and a.get('signed') is not True:
            raise ValueError('Unsigned APK')
    if signed:
        if manifest.get('apk_signed') is not True:
            raise ValueError('Unsigned manifest')
        if hashlib.sha256((directory / 'forkop-apk.pem').read_bytes()).hexdigest() != manifest['signing_public_key_sha256']:
            raise ValueError('Public key hash mismatch')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--apk-tool', required=True)
    parser.add_argument('--sign-key', required=True)
    parser.add_argument('--public-key', type=Path, required=True)
    args = parser.parse_args()
    path = args.directory / 'forkop-manifest.json'
    manifest = json.loads(path.read_text())
    validate(args.directory, manifest)
    with tempfile.TemporaryDirectory(prefix='forkop-trusted-keys-') as temporary:
        shutil.copyfile(args.public_key, Path(temporary) / 'forkop-apk.pem')
        for asset in manifest['assets']:
            if asset['format'] != 'apk':
                continue
            package = str((args.directory / asset['file']).resolve())
            dump = subprocess.check_output([args.apk_tool, 'adbdump', '--allow-untrusted', package], text=True)
            for field, value in (('name', asset['package']), ('version', asset['version']), ('arch', 'noarch')):
                if not re.search(r'^  ' + field + ': ' + re.escape(value) + '$', dump, re.MULTILINE):
                    raise ValueError('APK metadata mismatch')
            # Reusing a signed staging directory must not add a second signature.
            verified = subprocess.run([args.apk_tool, '--keys-dir', temporary, 'verify', package], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if verified.returncode:
                subprocess.run([args.apk_tool, 'adbsign', '--allow-untrusted', '--sign-key', args.sign_key, package], check=True)
            subprocess.run([args.apk_tool, '--keys-dir', temporary, 'verify', package], check=True)
            asset.setdefault('unsigned_sha256', asset['sha256'])
            asset['sha256'] = hashlib.sha256(Path(package).read_bytes()).hexdigest()
            asset['size'] = Path(package).stat().st_size
            asset['signed'] = True
    manifest['apk_signed'] = True
    manifest['signing_public_key_sha256'] = hashlib.sha256(args.public_key.read_bytes()).hexdigest()
    shutil.copyfile(args.public_key, args.directory / 'forkop-apk.pem')
    validate(args.directory, manifest, signed=True)
    path.write_text(json.dumps(manifest, indent=2) + '\n')
    (args.directory / 'SHA256SUMS').write_text(''.join(f'{a["sha256"]}  {a["file"]}\n' for a in manifest['assets']))


if __name__ == '__main__':
    main()
