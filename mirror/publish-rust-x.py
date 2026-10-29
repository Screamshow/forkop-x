#!/usr/bin/env python3
"""Publish a verified Rust X release directory to the Forkop mirror."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil

import os
import sys
import tempfile

BASE = 'https://mirror.51343.ru/forkop/rust-x'


def atomic_json(path, data):
    fd, pending = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as output:
            json.dump(data, output, indent=2)
            output.write('\n')
        os.chmod(pending, 0o644)
        os.replace(pending, path)
    finally:
        if os.path.exists(pending):
            os.unlink(pending)


def build_catalog(root):
    releases = []
    for manifest in root.glob('releases/*/manifest.json'):
        try:
            release = json.loads(manifest.read_text(encoding='utf-8'))
            version = release['version']
            if not isinstance(version, str) or not re.fullmatch(r'\d+\.\d+\.\d+', version):
                raise ValueError('Invalid version')
            if manifest.parent.name != version:
                raise ValueError('Directory/version mismatch')
            assets, seen = [], set()
            for asset in release['assets']:
                arch, fmt = asset['architecture'], asset['format']
                name = asset['file']
                if not re.fullmatch(r'[A-Za-z0-9_+-]+', arch) or fmt not in ('apk', 'ipk'):
                    raise ValueError('Invalid architecture/format')
                if (asset['package'] != 'rust-x' or
                        not re.fullmatch(re.escape(version) + r'-(?:r)?[0-9]+', asset['version']) or
                        name != f'rust-x_{asset["version"]}_{arch}.{fmt}' or (arch, fmt) in seen):
                    raise ValueError('Invalid or duplicate package identity')
                package = manifest.parent / name
                if package.is_symlink() or package.resolve().parent != manifest.parent.resolve():
                    raise ValueError('Package escapes release directory')
                if package.stat().st_size != asset['size']:
                    raise ValueError(f'Size mismatch: {name}')
                if hashlib.sha256(package.read_bytes()).hexdigest() != asset['sha256']:
                    raise ValueError(f'Checksum mismatch: {name}')
                seen.add((arch, fmt))
                assets.append({**asset, 'name': name, 'url': f'{BASE}/releases/{version}/{name}'})
            if not assets:
                raise ValueError('No packages')
            releases.append({'version': version,
                'manifest_url': f'{BASE}/releases/{version}/manifest.json',
                'architectures': sorted({a['architecture'] for a in assets}),
                'formats': sorted({a['format'] for a in assets}), 'assets': assets})
        except (OSError, ValueError, KeyError, TypeError) as error:
            print(f'Skipping {manifest}: {error}', file=sys.stderr)
    releases.sort(key=lambda r: tuple(map(int, r['version'].split('.'))), reverse=True)
    return {'schema': 1, 'name': 'rust-x', 'releases': releases}


def write_catalog(root):
    catalog = build_catalog(root)
    if not catalog['releases']:
        raise ValueError('No verified releases; existing catalog preserved')
    atomic_json(root / 'releases.json', catalog)
    print(f'Published {len(catalog["releases"])} verified Rust X releases')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--latest', action='store_true')
    parser.add_argument('--catalog-only', action='store_true')
    args = parser.parse_args()
    if args.catalog_only:
        write_catalog(args.destination)
        return
    source = args.source
    m = json.loads((source / 'openwrt-manifest.json').read_text())
    version = m['version']
    assert re.fullmatch(r'\d+\.\d+\.\d+', version)
    assert m['apk_signed'] is True
    assert hashlib.sha256((source / 'forkop-apk.pem').read_bytes()).hexdigest() == m['signing_public_key_sha256']
    required = {'x86_64', 'aarch64_cortex-a53'}
    supported = required | {'aarch64_cortex-a73', 'aarch64_generic', 'mipsel_24kc'}
    actual = {(a['architecture'], a['format']) for a in m['assets']}
    architectures = {arch for arch, _ in actual}
    complete = {(arch, fmt) for arch in architectures for fmt in ('apk', 'ipk')}
    assert required <= architectures <= supported and actual == complete and len(m['assets']) == len(actual)
    # Canary.2 accepts a cortex-a53 fallback on Beam; place the exact Beam
    # package first so existing installations select it before that fallback.
    m['assets'].sort(key=lambda a: (a['architecture'] != 'aarch64_cortex-a73', a['architecture'], a['format']))
    assets = []
    for a in m['assets']:
        revision = 'r1' if a['format'] == 'apk' else '1'
        assert a['package'] == 'rust-x' and a['version'] == version + '-' + revision
        assert a['file'] == f'rust-x_{a["version"]}_{a["architecture"]}.{a["format"]}'
        p = source / a['file']
        assert p.stat().st_size == a['size']
        assert hashlib.sha256(p.read_bytes()).hexdigest() == a['sha256']
        if a['format'] == 'apk':
            assert a['signed'] is True
        assets.append({**a, 'name': a['file'],
                       'url': f'https://mirror.51343.ru/forkop/rust-x/releases/{version}/{a["file"]}'})
    catalog = {**m, 'schema': 1, 'name': 'rust-x', 'package_revision': 1, 'assets': assets}
    target = args.destination / 'releases' / version
    target.mkdir(parents=True, exist_ok=True)
    for a in assets:
        p = target / a['name']
        if p.exists():
            assert hashlib.sha256(p.read_bytes()).hexdigest() == a['sha256'], 'Refusing to replace existing package'
        else:
            shutil.copyfile(source / a['name'], p)
    for name in ('openwrt-manifest.json', 'forkop-apk.pem', 'SHA256SUMS'):
        shutil.copyfile(source / name, target / name)
    atomic_json(target / 'manifest.json', catalog)
    write_catalog(args.destination)
    if args.latest:
        atomic_json(args.destination / 'latest.json', catalog)
    print(f'Verified Rust X {version}: {len(assets)} packages')


if __name__ == '__main__':
    main()
