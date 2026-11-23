"""Backfill legacy published package assets without changing current pointers."""
import hashlib
import json
from pathlib import Path
import re
import urllib.request

ROOT = Path('/srv/mirror/public/forkop/updates')
API = 'https://api.github.com/repos/Screamshow/forkop-x/releases'


def legacy_release_version(release):
    version = release['tag_name'].lstrip('v')
    match = re.fullmatch(r'([0-9]+)\.[0-9]+\.[0-9]+(?:-canary\.[0-9]+)?', version)
    # 3.x archives carry an exact Xrust pin and are owned by the signed publisher.
    return version if match and int(match[1]) < 3 and not release.get('draft') else None


def fetch(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'Forkop-mirror-backfill'})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def main():
    releases = []
    page = 1
    while True:
        batch = json.loads(fetch(f'{API}?per_page=100&page={page}'))
        if not batch:
            break
        releases.extend(batch)
        page += 1
    releases.sort(key=lambda r: r['tag_name'].lstrip('v') != '1.3.2')
    for release in releases:
        version = legacy_release_version(release)
        if version is None:
            continue
        parent = ROOT / ('canary/releases' if '-canary.' in version else 'releases') / version
        selected = [a for a in release['assets'] if re.fullmatch(
            r'(forkop|luci-app-forkop|luci-i18n-forkop-ru)_' + re.escape(version) + r'\.(apk|ipk)', a['name'])]
        if not selected:
            print(f'No packages: {version}', flush=True)
            continue
        metadata = []
        for asset in selected:
            path = parent / asset['name']
            digest = asset.get('digest') or ''
            expected = digest.removeprefix('sha256:') if digest.startswith('sha256:') else None
            if path.exists() and expected and hashlib.sha256(path.read_bytes()).hexdigest() == expected:
                data = path.read_bytes()
            else:
                data = fetch(asset['browser_download_url'])
            actual = hashlib.sha256(data).hexdigest()
            if expected and actual != expected:
                raise RuntimeError(f'Original digest mismatch: {path}')
            if path.exists() and path.read_bytes() != data:
                backup = Path('/srv/mirror/backups/forkop-pre-backfill') / path.relative_to(ROOT)
                backup.parent.mkdir(parents=True, exist_ok=True)
                if backup.exists() and backup.read_bytes() != path.read_bytes():
                    raise RuntimeError(f'Backup differs: {backup}')
                backup.write_bytes(path.read_bytes())
                print(f'Preserved differing archive: {path}', flush=True)
                temporary = path.with_suffix(path.suffix + '.backfill')
                temporary.write_bytes(data)
                temporary.replace(path)
            parent.mkdir(parents=True, exist_ok=True)
            if not path.exists():
                temporary = path.with_suffix(path.suffix + '.backfill')
                temporary.write_bytes(data)
                temporary.replace(path)
            metadata.append({'name': asset['name'], 'sha256': actual,
                'browser_download_url': '/forkop/updates/' + path.relative_to(ROOT).as_posix()})
        manifest = {'tag_name': version, 'html_url': '/forkop/updates/' + parent.relative_to(ROOT).as_posix() + '/', 'assets': metadata}
        temporary = parent / 'release.json.backfill'
        temporary.write_text(json.dumps(manifest, indent=2) + '\n')
        temporary.replace(parent / 'release.json')
        print(f'Verified {version}: {len(metadata)} packages', flush=True)


if __name__ == '__main__':
    main()
