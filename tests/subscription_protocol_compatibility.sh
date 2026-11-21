#!/bin/sh
# Optional core checks: RUST_X_BINARY and XRUST_XRAY_BINARY.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB=${FORKOP_LIB:-$ROOT/forkop/files/usr/lib}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ucode -L "$LIB" "$ROOT/tests/subscription_protocol_compatibility.uc" "$WORK" "$LIB" \
    "${RUST_X_BINARY:-}"
