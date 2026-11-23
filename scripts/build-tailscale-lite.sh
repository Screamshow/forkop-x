#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source_dir=${1:-$root/artifacts/tailscale-lite-source}
output=${2:-$root/artifacts/tailscale-lite/1.98.3}
mkdir -p -- "$output"
output=$(CDPATH= cd -- "$output" && pwd -P)
cd "$source_dir"
test "$(git rev-parse HEAD)" = 8f2c8d6a14419e95fb9d02d6bf6113893daef5c3
tags=$(./tool/go run ./cmd/featuretags --min --add=cli,netstack,unixsocketidentity,ipnbus,health,osrouter,portlist,portmapper,tailnetlock)
for arch in amd64 arm64; do
    CGO_ENABLED=0 GOOS=linux GOARCH=$arch ./tool/go build -trimpath -tags "$tags" \
        -ldflags '-s -w -X tailscale.com/version.shortStamp=1.98.3 -X tailscale.com/version.longStamp=1.98.3-forkop-lite' \
        -o "$output/tailscale-lite-linux-$arch" ./cmd/tailscaled
done
sha256sum "$output"/tailscale-lite-linux-*
wc -c "$output"/tailscale-lite-linux-*
