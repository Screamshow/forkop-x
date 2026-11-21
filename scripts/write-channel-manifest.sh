#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: write-channel-manifest.sh <stable|canary> <version> <artifact-dir> <public-release-url> <output-dir>

Writes <output-dir>/stable.json or canary.json. Writing stable.json also
atomically refreshes latest.json as its backwards-compatible stable alias.
EOF
}

channel="${1:-}"
version="${2:-}"
artifact_dir="${3:-}"
release_url="${4:-}"
output_dir="${5:-}"

if [[ $# -ne 5 ]]; then
  usage >&2
  exit 2
fi

case "$channel" in stable|canary) ;; *) usage >&2; exit 2 ;; esac
if [[ "$channel" == stable && ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
   [[ "$channel" == canary && ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-canary\.[0-9]+$ ]]; then
  echo "Version does not belong to channel $channel: $version" >&2
  exit 2
fi

release_url="${release_url%/}"
xrust_version=""
major="${version%%.*}"
if (( 10#$major >= 3 )); then
  xrust_version="$(python3 - "$artifact_dir" "$version" "${MIRROR_ROOT:-/srv/mirror/public/forkop}/rust-x/releases" <<'PY'
import hashlib
import json
from pathlib import Path
import re
import sys

artifacts = Path(sys.argv[1])
version = sys.argv[2]
manifest = json.loads((artifacts / 'forkop-manifest.json').read_text())
pin = manifest.get('xrust_version')
if (manifest.get('version') != version or manifest.get('apk_signed') is not True or
        not isinstance(pin, str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', pin)):
    sys.exit('Expected a signed Forkop manifest with an exact Xrust version')

def verify_file(directory, name, asset):
    path = directory / name
    if path.is_symlink() or path.stat().st_size != asset['size']:
        sys.exit(f'Invalid release asset size or path: {name}')
    if hashlib.sha256(path.read_bytes()).hexdigest() != asset['sha256']:
        sys.exit(f'Invalid release asset checksum: {name}')

packages = ('forkop', 'luci-app-forkop', 'luci-i18n-forkop-ru')
expected = {f'{name}_{version}.{fmt}' for name in packages for fmt in ('apk', 'ipk')}
assets = manifest['assets']
if len(assets) != len(expected) or {asset['file'] for asset in assets} != expected:
    sys.exit('Expected all six Forkop packages')
for asset in assets:
    verify_file(artifacts, asset['file'], asset)

archive = Path(sys.argv[3]) / pin
core = json.loads((archive / 'manifest.json').read_text())
revision = core.get('package_revision')
if (core.get('schema') != 1 or core.get('name') != 'rust-x' or core.get('version') != pin or
        core.get('minimum_forkop_major') != 3 or core.get('apk_signed') is not True or
        type(revision) is not int or revision <= 0):
    sys.exit('Expected the signed native Xrust archive')
seen = set()
for asset in core['assets']:
    arch, fmt = asset['architecture'], asset['format']
    package_version = f'{pin}-{"r" if fmt == "apk" else ""}{revision}'
    name = f'rust-x_{package_version}_{arch}.{fmt}'
    if (not re.fullmatch(r'[A-Za-z0-9_-]+', arch) or fmt not in ('apk', 'ipk') or
            (arch, fmt) in seen or asset['package'] != 'rust-x' or asset['version'] != package_version or
            asset['name'] != name or asset['file'] != name or
            asset['url'] != f'https://mirror.51343.ru/forkop/rust-x/releases/{pin}/{name}'):
        sys.exit(f'Invalid Xrust archive asset: {name}')
    verify_file(archive, name, asset)
    seen.add((arch, fmt))
arches = {arch for arch, _ in seen}
if not {'x86_64', 'aarch64_cortex-a53'} <= arches or seen != {(arch, fmt) for arch in arches for fmt in ('apk', 'ipk')}:
    sys.exit('Incomplete Xrust archive')
print(pin)
PY
)"
fi
mkdir -p "$output_dir"

asset_json=()
for package in forkop luci-app-forkop luci-i18n-forkop-ru; do
  for extension in ipk apk; do
    filename="${package}_${version}.${extension}"
    path="$artifact_dir/$filename"
    [[ -f "$path" ]] || { echo "Missing artifact: $path" >&2; exit 1; }
    digest="$(sha256sum "$path" | awk '{print $1}')"
    asset_json+=("    {\"name\": \"$filename\", \"browser_download_url\": \"$release_url/$filename\", \"sha256\": \"$digest\"}")
  done
done

tmp="$output_dir/.${channel}.json.$$"
{
  printf '{\n  "channel": "%s",\n  "tag_name": "%s",\n  "html_url": "%s/",\n' "$channel" "$version" "$release_url"
  if [[ -n "$xrust_version" ]]; then
    printf '  "xrust_version": "%s",\n' "$xrust_version"
  fi
  printf '  "assets": [\n'
  for i in "${!asset_json[@]}"; do
    printf '%s' "${asset_json[$i]}"
    [[ "$i" -lt $((${#asset_json[@]} - 1)) ]] && printf ','
    printf '\n'
  done
  printf '  ]\n}\n'
} >"$tmp"
mv "$tmp" "$output_dir/$channel.json"

if [[ "$channel" == stable ]]; then
  alias_tmp="$output_dir/.latest.json.$$"
  cp "$output_dir/stable.json" "$alias_tmp"
  mv "$alias_tmp" "$output_dir/latest.json"
fi
