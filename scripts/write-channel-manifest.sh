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
  xrust_version="$(python3 - "$artifact_dir/forkop-manifest.json" "$version" <<'PY'
import json
from pathlib import Path
import re
import sys

manifest = json.loads(Path(sys.argv[1]).read_text())
pin = manifest.get('xrust_version')
if manifest.get('version') != sys.argv[2] or not isinstance(pin, str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', pin):
    sys.exit('Expected a matching Forkop manifest with an exact Xrust version')
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
