#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
UI_UC="$FORKOP_LIB/service/ui.uc"
WORK_DIR="$(mktemp -d)"
PROBE_BIN="$WORK_DIR/sing-box"
PROBE_COUNT="$WORK_DIR/probe-count"
PROBE_PIDS="$WORK_DIR/probe-pids"
CACHE_FILE="$WORK_DIR/sing-box-version-cache"

cleanup() {
  if [ -f "$PROBE_PIDS" ]; then
    while IFS= read -r pid; do
      kill -9 "$pid" 2>/dev/null || true
    done <"$PROBE_PIDS"
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cat >"$PROBE_BIN" <<'SH'
#!/bin/sh
printf '%s\n' "$$" >>"$FORKOP_TEST_SING_BOX_PROBE_PIDS"
printf 'probe\n' >>"$FORKOP_TEST_SING_BOX_PROBE_COUNT"
if [ "${FORKOP_TEST_SING_BOX_PROBE_MODE:-fast}" = "slow" ]; then
  exec sleep 30
fi
printf 'sing-box version 1.13.14\n\n'
printf 'Tags: %s\n' "${FORKOP_TEST_SING_BOX_PROBE_TAGS:-with_quic,with_tailscale}"
SH
chmod 755 "$PROBE_BIN"
cat >"$WORK_DIR/apk" <<'SH'
#!/bin/sh
if [ "$1" = "list" ] && [ "$2" = "--installed" ] && [ "$3" = "--manifest" ]; then
  if [ "${FORKOP_TEST_SING_BOX_REGULAR_PACKAGE:-0}" = "1" ]; then
    printf '%s\n' 'sing-box 1.13.14-r1'
  elif [ "${FORKOP_TEST_SING_BOX_EXTENDED_PACKAGE:-0}" = "1" ]; then
    printf '%s\n' 'sing-box-extended 1.13.14-r1'
  elif [ "${FORKOP_TEST_SING_BOX_TINY_PACKAGE:-0}" = "1" ]; then
    printf '%s\n' 'sing-box-tiny 1.13.14-r1'
  fi
  exit 0
fi
exit 1
SH
chmod 755 "$WORK_DIR/apk"
cat >"$WORK_DIR/opkg" <<'SH'
#!/bin/sh
exit 0
SH
chmod 755 "$WORK_DIR/opkg"

ui_capabilities() {
  PATH="$WORK_DIR:$PATH" \
  FORKOP_CONFIG_NAME=forkop-ui-probe-test \
  FORKOP_UI_STATE_DIR="$WORK_DIR/state" \
  FORKOP_UI_COMPONENT_ACTION_DIR="$WORK_DIR/components" \
  FORKOP_UI_SING_BOX_VERSION_CACHE_FILE="$CACHE_FILE" \
  FORKOP_UI_SING_BOX_VARIANT_STATE_FILE="$WORK_DIR/missing-variant" \
  FORKOP_UI_SING_BOX_BIN_PATH="$PROBE_BIN" \
  FORKOP_UI_SING_BOX_VERSION_PROBE_TIMEOUT_SECONDS=1 \
  FORKOP_UI_SING_BOX_VERSION_PROBE_FAILURE_TTL_SECONDS=30 \
  FORKOP_TEST_SING_BOX_PROBE_COUNT="$PROBE_COUNT" \
  FORKOP_TEST_SING_BOX_PROBE_PIDS="$PROBE_PIDS" \
  ucode -L "$FORKOP_LIB" "$UI_UC" get-ui-capabilities
}

fast_first="$(FORKOP_TEST_SING_BOX_PROBE_MODE=fast ui_capabilities)"
fast_second="$(FORKOP_TEST_SING_BOX_PROBE_MODE=fast ui_capabilities)"
[ "$(wc -l <"$PROBE_COUNT")" -eq 1 ] ||
  fail "successful sing-box capability detection must be cached by binary signature"

JSON_VALUE="$fast_first" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (value.sing_box_extended !== 0 || value.sing_box_tiny !== 0 || value.sing_box_tailscale !== 1) {
  console.error('cached sing-box capability flags mismatch');
  process.exit(1);
}
NODE
[ "$fast_first" = "$fast_second" ] ||
  fail "cached sing-box capabilities must match the initial detection"

: >"$PROBE_COUNT"
: >"$PROBE_PIDS"
rm -rf "$CACHE_FILE" "$CACHE_FILE.lock"

start_seconds=$SECONDS
workers=""
for index in $(seq 1 10); do
  FORKOP_TEST_SING_BOX_PROBE_MODE=slow ui_capabilities >"$WORK_DIR/slow-$index.json" &
  workers="$workers $!"
done
for worker in $workers; do
  wait "$worker"
done
elapsed_seconds=$((SECONDS - start_seconds))

[ "$elapsed_seconds" -le 4 ] ||
  fail "bounded sing-box probes took ${elapsed_seconds}s"
[ "$(wc -l <"$PROBE_COUNT")" -eq 1 ] ||
  fail "parallel UI requests must share one sing-box probe"

for output in "$WORK_DIR"/slow-*.json; do
  JSON_FILE="$output" node - <<'NODE'
const fs = require('fs');
const value = JSON.parse(fs.readFileSync(process.env.JSON_FILE, 'utf8'));
if (value.sing_box_extended !== 0 || value.sing_box_tiny !== 0 || value.sing_box_tailscale !== 0) {
  console.error('failed sing-box probe must produce conservative capability flags');
  process.exit(1);
}
NODE
done

FORKOP_TEST_SING_BOX_PROBE_MODE=slow ui_capabilities >/dev/null
[ "$(wc -l <"$PROBE_COUNT")" -eq 1 ] ||
  fail "failed sing-box probe must be cached during the retry cooldown"

while IFS= read -r pid; do
  if kill -0 "$pid" 2>/dev/null; then
    fail "timed-out sing-box probe process $pid is still running"
  fi
done <"$PROBE_PIDS"
: >"$PROBE_PIDS"

[ ! -e "$CACHE_FILE.lock" ] ||
  fail "completed probe left its single-flight lock behind"

# A completed probe may be requested again after its cache is invalidated.
# This is not a second concurrent probe: the previous timeout process has
# already been verified dead above.
rm -f "$CACHE_FILE"
FORKOP_TEST_SING_BOX_PROBE_MODE=fast ui_capabilities >/dev/null
[ "$(wc -l <"$PROBE_COUNT")" -eq 2 ] ||
  fail "a new probe was not allowed after the previous probe completed"

# A caller crash must not permanently suppress future probes. The lock owner
# is deliberately non-existent; acquire_dir_lock() must reap it atomically
# before the next bounded probe begins.
rm -f "$CACHE_FILE"
mkdir "$CACHE_FILE.lock"
printf '%s\n' 999999 >"$CACHE_FILE.lock/pid"
FORKOP_TEST_SING_BOX_PROBE_MODE=fast ui_capabilities >/dev/null
[ "$(wc -l <"$PROBE_COUNT")" -eq 3 ] ||
  fail "stale probe lock prevented a subsequent probe"
[ ! -e "$CACHE_FILE.lock" ] ||
  fail "stale probe lock was not cleaned after the subsequent probe"

# A manually installed regular APK package has neither the Tiny package name
# nor the Tailscale build tag. A stale Tiny marker from the previous managed
# installation must not override its package-manager identity.
rm -f "$CACHE_FILE"
printf 'tiny\n' >"$WORK_DIR/missing-variant"
regular_package="$(FORKOP_TEST_SING_BOX_PROBE_MODE=fast FORKOP_TEST_SING_BOX_PROBE_TAGS=with_quic FORKOP_TEST_SING_BOX_REGULAR_PACKAGE=1 ui_capabilities)"
JSON_VALUE="$regular_package" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (value.sing_box_package !== 'sing-box' || value.sing_box_extended !== 0 || value.sing_box_tiny !== 0 || value.sing_box_tailscale !== 0) {
  console.error('regular sing-box package must not be labelled tiny or extended');
  process.exit(1);
}
NODE
rm -f "$WORK_DIR/missing-variant"

# Tiny provides the virtual sing-box dependency in APK, so its exact package
# name must be checked instead of `apk info -e sing-box`.
rm -f "$CACHE_FILE"
tiny_package="$(FORKOP_TEST_SING_BOX_PROBE_MODE=fast FORKOP_TEST_SING_BOX_TINY_PACKAGE=1 ui_capabilities)"
JSON_VALUE="$tiny_package" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (value.sing_box_package !== 'sing-box-tiny' || value.sing_box_extended !== 0 || value.sing_box_tiny !== 1 || value.sing_box_tailscale !== 0) {
  console.error('tiny sing-box package must be labelled tiny');
  process.exit(1);
}
NODE

rm -f "$CACHE_FILE"
extended_package="$(FORKOP_TEST_SING_BOX_PROBE_MODE=fast FORKOP_TEST_SING_BOX_EXTENDED_PACKAGE=1 ui_capabilities)"
JSON_VALUE="$extended_package" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (value.sing_box_package !== 'sing-box-extended' || value.sing_box_extended !== 1 || value.sing_box_tiny !== 0) {
  console.error('extended sing-box package must be labelled extended');
  process.exit(1);
}
NODE

printf 'UI sing-box probe checks passed\n'
