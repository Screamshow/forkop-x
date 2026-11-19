#!/bin/sh
# Use a staged library on an existing OpenWrt VM.
set -eu
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
FORKOP_LIB=${FORKOP_LIB:-$ROOT_DIR/forkop/files/usr/lib}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export FORKOP_LIB
export FORKOP_RUNTIME_STATE_DIR="$WORK/runtime"
export FORKOP_SECTION_CACHE_DIR="$WORK/live"
export FORKOP_UCI_STATE_FILE="$WORK/uci.state"
export FORKOP_UCI_LOG_FILE="$WORK/uci.log"
RUNTIME="$FORKOP_LIB/singbox/runtime.uc"
mkdir -p "$WORK/live" "$WORK/stage.section-cache"
printf '%s' '{"generation":"old"}' > "$WORK/live/a.json"
printf '%s' '{"generation":"old-dns"}' > "$WORK/live/.dns-failover.json"
printf '%s' '{"removed":true}' > "$WORK/live/removed.json"
cp -R "$WORK/live" "$WORK/before"
printf '%s' '{"generation":"new"}' > "$WORK/stage.section-cache/a.json"
printf '%s' '{"generation":"new-dns"}' > "$WORK/stage.section-cache/.dns-failover.json"
printf '%s' '{"added":true}' > "$WORK/stage.section-cache/b.json"
unchanged() {
    cmp "$WORK/before/a.json" "$WORK/live/a.json"
    cmp "$WORK/before/removed.json" "$WORK/live/removed.json"
    cmp "$WORK/before/.dns-failover.json" "$WORK/live/.dns-failover.json"
    test ! -e "$WORK/live/b.json"
    test -f "$WORK/stage.section-cache/a.json"
    test -f "$WORK/stage.section-cache/b.json"
}
publish() {
    ucode -L "$FORKOP_LIB" "$RUNTIME" publish-section-cache-fixture "$WORK/stage"
}
for phase in cache-publish cache-after-publish; do
    if FORKOP_SINGBOX_CONFIG_FAIL_PHASE="$phase" publish; then
        echo "FAIL: $phase was accepted" >&2; exit 1
    fi
    unchanged
done
# A real preparation failure after a valid entry cannot publish a partial set.
mkdir "$WORK/stage.section-cache/unreadable.json"
if publish; then echo 'FAIL: unreadable source accepted' >&2; exit 1; fi
unchanged
rmdir "$WORK/stage.section-cache/unreadable.json"
publish
test ! -e "$WORK/live/removed.json"
test ! -e "$WORK/stage.section-cache"
grep -q 'new' "$WORK/live/a.json"
grep -q 'new-dns' "$WORK/live/.dns-failover.json"
test -f "$WORK/live/b.json"
ucode -e '
    let fs = require("fs");
    for (let entry in [[ARGV[0], 0700], [ARGV[0] + "/a.json", 0600], [ARGV[0] + "/b.json", 0600]])
        if ((fs.stat(entry[0]).mode & 0777) != entry[1])
            die("Incorrect private-cache permissions");
' "$WORK/live"
# Failed first publication restores the absence of a cache, too.
rm -rf "$WORK/live"
mkdir "$WORK/stage.section-cache"
printf '{}' > "$WORK/stage.section-cache/a.json"
if FORKOP_SINGBOX_CONFIG_FAIL_PHASE=cache-after-publish publish; then
    echo 'FAIL: first publication failure accepted' >&2; exit 1
fi
test ! -e "$WORK/live"
test -f "$WORK/stage.section-cache/a.json"
test -z "$(find "$WORK" -maxdepth 1 -name '.section-cache.*' -print)"
# A reload can reject the candidate after publication. Retain the previous
# directory until the lifecycle commits the whole config and nft transition.
transaction="$WORK/live.reload.test"
for prior in existing absent; do
    if [ "$prior" = existing ]; then
        mkdir "$WORK/live"
        printf '%s' '{"original":true}' >"$WORK/live/original.json"
    fi
    ucode -L "$FORKOP_LIB" "$RUNTIME" publish-section-cache "$WORK/stage" "$transaction"
    test -f "$WORK/live/a.json"
    test -d "$transaction"
    ucode -L "$FORKOP_LIB" "$RUNTIME" finish-section-cache "$transaction" restore
    test ! -e "$transaction"
    if [ "$prior" = existing ]; then
        grep -Fxq '{"original":true}' "$WORK/live/original.json"
        test ! -e "$WORK/live/a.json"
        rm -r "$WORK/live"
    else
        test ! -e "$WORK/live"
    fi
    mkdir "$WORK/stage.section-cache"
    printf '%s' '{"candidate":true}' >"$WORK/stage.section-cache/a.json"
done
ucode -L "$FORKOP_LIB" "$RUNTIME" publish-section-cache "$WORK/stage" "$transaction"
ucode -L "$FORKOP_LIB" "$RUNTIME" finish-section-cache "$transaction" commit
test -f "$WORK/live/a.json"
test ! -e "$transaction"

echo 'Section-cache rollback checks passed'
