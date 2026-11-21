#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK/persistent"
export TMP_SUBSCRIPTION_FOLDER="$WORK/runtime"
export FORKOP_UCI_STATE_FILE="$WORK/uci.state"
ucode -L "$ROOT/forkop/files/usr/lib" "$ROOT/tests/subscription_filter_selection.uc"
ucode -L "$ROOT/forkop/files/usr/lib" "$ROOT/forkop/files/usr/lib/xrust/generator.uc" \
    generate-config-fixture "$TMP_SUBSCRIPTION_FOLDER/fixture.json" "$WORK/config.json" 127.0.0.1
ucode -e '
let fs=require("fs"); let config=json(fs.readfile(ARGV[0])); let found=false;
for (let outbound in config.outbounds || [])
    if (outbound.tag == "test-urltest-group-out") {
        assert(sprintf("%J", outbound.outbounds) == sprintf("%J", ["Moscow #2"]), "generator follows identity instead of reused name");
        found=true;
    }
assert(found, "generated pinned group exists");
assert(index(fs.readfile(ARGV[0]), "filter-bindings") < 0, "private binding state omitted from runtime config");
print("PASS: generated URLTest follows pinned connection\n");
' "$WORK/config.json"
sh "$ROOT/tests/urltest_name_filter.sh"
