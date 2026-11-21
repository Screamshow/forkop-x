#!/usr/bin/env python3
"""Publish verified signed stable packages through the existing feed publisher.

Caller must hold /run/lock/forkop-git-build.lock, shared with the Git updater.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--root', type=Path, default=Path('/srv/mirror/public/forkop'))
    parser.add_argument('--apk-tool', default='/root/.cache/forkop/openwrt-sdk/extracted/apk/staging_dir/host/bin/apk')
    parser.add_argument('--publisher', default='/usr/local/sbin/publish-forkop-feed')
    args = parser.parse_args()
    manifest = json.loads((args.directory / 'forkop-manifest.json').read_text())
    version = manifest['version']
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Stable x.y.z version required')
    spec = importlib.util.spec_from_file_location('signer', Path(__file__).with_name('sign-forkop-release.py'))
    signer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(signer)
    signer.validate(args.directory, manifest, signed=True)
    trusted = args.root / 'forkop-apk.pem'
    if trusted.read_bytes() != (args.directory / 'forkop-apk.pem').read_bytes():
        raise ValueError('Unexpected signing public key')
    apks = [str((args.directory / a['file']).resolve()) for a in manifest['assets'] if a['format'] == 'apk']
    subprocess.run([args.apk_tool, '--keys-dir', str(args.root), 'verify', *apks], check=True)
    destination = args.root / 'updates/releases' / version
    if destination.exists():
        for asset in manifest['assets']:
            path = destination / asset['file']
            if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != asset['sha256']:
                raise ValueError('Refusing to replace an existing stable archive')
    subprocess.run([args.publisher, str(args.directory.resolve()), version], check=True,
                   env={**os.environ, 'MIRROR_ROOT': str(args.root), 'APK_BIN': args.apk_tool})
    for asset in manifest['assets']:
        if hashlib.sha256((destination / asset['file']).read_bytes()).hexdigest() != asset['sha256']:
            raise ValueError('Stable publisher changed package bytes')
    for name in ('forkop-manifest.json', 'forkop-apk.pem', 'SHA256SUMS'):
        if int(version.split('.', 1)[0]) >= 3:
            if (args.directory / name).read_bytes() != (destination / name).read_bytes():
                raise ValueError(f'Stable publisher changed release metadata: {name}')
        else:
            shutil.copyfile(args.directory / name, destination / name)
    if int(version.split('.', 1)[0]) < 3:
        subprocess.run(['python3', '/usr/local/lib/forkop/write-release-catalog.py', str(args.root / 'updates')], check=True)


if __name__ == '__main__':
    main()
