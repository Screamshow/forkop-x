#!/bin/sh
# Keep a single installer implementation for both release channels.
set -eu

installer=$(mktemp /tmp/forkop-canary-install.XXXXXX)
trap 'rm -f "$installer"' EXIT HUP INT TERM
base=${FORKOP_MIRROR_BASE_URL:-https://mirror.51343.ru}
base=${base%/}

if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 "$base/forkop/install.sh" -o "$installer"
elif command -v wget >/dev/null 2>&1; then
    wget -O "$installer" "$base/forkop/install.sh"
else
    echo "curl or wget is required to download the Forkop installer" >&2
    exit 1
fi

sh "$installer" --channel canary "$@"
