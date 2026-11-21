#!/bin/sh
set -eu

PACKAGE_UC="${1:-/usr/lib/forkop/service/package.uc}"
FORKOP_LIB="${FORKOP_LIB:-$(cd "$(dirname "$PACKAGE_UC")/.." && pwd)}"
FORKOP_INIT="${FORKOP_INIT:-/etc/init.d/forkop}"
FORKOP_CONFIG_SOURCE="${FORKOP_CONFIG_SOURCE:-/etc/config/forkop}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/forkop-package-upgrade-wait-test.XXXXXX")"
WAS_RUNNING=0
export FORKOP_XRUST_BIN="$WORK_DIR/xrust"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

cleanup() {
    pkill -f "$FORKOP_XRUST_BIN" >/dev/null 2>&1 || true
    if [ "${FORKOP_TEST_KEEP_WORK_DIR:-0}" = 1 ]; then
        printf 'Retained test directory: %s\n' "$WORK_DIR" >&2
        return
    fi
    rm -rf "$WORK_DIR"
    if [ "$WAS_RUNNING" = 1 ]; then
        "$FORKOP_INIT" start >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

command -v ucode >/dev/null 2>&1 || fail "ucode is required"
UCODE_BIN="$(command -v ucode)"
[ -f "$PACKAGE_UC" ] || fail "package.uc was not supplied"

if "$FORKOP_INIT" status >/dev/null 2>&1; then
    WAS_RUNNING=1
    "$FORKOP_INIT" stop >/dev/null 2>&1 || fail "unable to stop Forkop test runtime"
    sleep 2
fi

mkdir -p "$WORK_DIR/cache"
cp "$UCODE_BIN" "$FORKOP_XRUST_BIN"
chmod 0755 "$FORKOP_XRUST_BIN"
cp "$FORKOP_CONFIG_SOURCE" "$WORK_DIR/forkop.conf"
printf 'forkop.settings=settings\n' >"$WORK_DIR/uci.state"
export FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
export FORKOP_BYTECODE_CACHE_DIR="$WORK_DIR/bytecode"
export FORKOP_RT_TABLES="$WORK_DIR/rt_tables"
export FORKOP_UI_STATE_DIR="$WORK_DIR/ui-state"
export FORKOP_UI_COMPONENT_ACTION_DIR="$WORK_DIR/ui-state/component-actions"
export FORKOP_UI_SUBSCRIPTION_ACTION_DIR="$WORK_DIR/ui-state/subscription-actions"

cat >"$WORK_DIR/init" <<'EOF_INIT'
#!/bin/sh
printf '%s\n' "$1" >>"$FORKOP_TEST_INIT_LOG"
exit 0
EOF_INIT
chmod 0755 "$WORK_DIR/init"

run_postinst() {
    FORKOP_INIT="$WORK_DIR/init" \
    FORKOP_CONFIG_PATH="$WORK_DIR/forkop.conf" \
    FORKOP_PACKAGE_UPGRADE_STATE="$WORK_DIR/was-running" \
    FORKOP_PACKAGE_UPGRADE_QUIESCE_FILE="$WORK_DIR/quiesce" \
    FORKOP_COMPONENT_UPDATE_CHECK_CACHE_DIR="$WORK_DIR/cache" \
    FORKOP_COMPONENT_UPDATE_CHECK_STATE_FILE="$WORK_DIR/component-state" \
    FORKOP_TEST_INIT_LOG="$WORK_DIR/init.log" \
    FORKOP_LIB="$FORKOP_LIB" \
    FORKOP_UI_UC="${FORKOP_UI_UC:-$FORKOP_LIB/service/ui.uc}" \
    FORKOP_UPGRADE_SING_BOX_WAIT_SECONDS="${1:-15}" \
    FORKOP_UPGRADE_RESTORE_WAIT_SECONDS="${FORKOP_UPGRADE_RESTORE_WAIT_SECONDS:-10}" \
    ucode -L "$FORKOP_LIB" "$PACKAGE_UC" postinst
}

# A normal upgrade must wait for the old executable to disappear and then
# perform exactly one start.
touch "$WORK_DIR/was-running" "$WORK_DIR/quiesce"
("$FORKOP_XRUST_BIN" -e 'system("sleep 3")' &)
started="$(date +%s)"
run_postinst 10 || fail "postinst rejected a normally exiting old Xrust"
elapsed="$(( $(date +%s) - started ))"
[ "$elapsed" -ge 2 ] || fail "postinst did not wait for the old Xrust"
[ "$elapsed" -le 6 ] || fail "postinst wait exceeded the expected bound"
[ "$(grep -c '^start$' "$WORK_DIR/init.log")" = 1 ] || fail "postinst did not start exactly once"
[ ! -e "$WORK_DIR/was-running" ] || fail "successful postinst retained the upgrade marker"
[ ! -e "$WORK_DIR/quiesce" ] || fail "successful postinst retained the quiesce marker"

# OpenWrt 24 may omit the prerm action during an upgrade. The package-manager
# parent must still own a live quiesce marker for the remainder of the
# transaction.
cat >"$WORK_DIR/status-init" <<'EOF_STATUS_INIT'
#!/bin/sh
[ "$1" = status ] && exit 0
exit 0
EOF_STATUS_INIT
chmod 0755 "$WORK_DIR/status-init"
FORKOP_PACKAGE_TEST_MODE=1 \
FORKOP_INIT="$WORK_DIR/status-init" \
FORKOP_CONFIG_PATH="$WORK_DIR/forkop.conf" \
FORKOP_PACKAGE_UPGRADE_STATE="$WORK_DIR/was-running" \
FORKOP_PACKAGE_UPGRADE_QUIESCE_FILE="$WORK_DIR/quiesce" \
FORKOP_LIB="$FORKOP_LIB" \
ucode -L "$FORKOP_LIB" "$PACKAGE_UC" prerm || fail "empty-action prerm failed"
[ -s "$WORK_DIR/quiesce" ] || fail "empty-action prerm did not preserve upgrade quiesce"
read -r owner ticks <"$WORK_DIR/quiesce"
kill -0 "$owner" 2>/dev/null && [ "$ticks" = "$(awk '{print $22}' "/proc/$owner/stat")" ] ||
    fail "upgrade quiesce is not owned by the live package-manager parent"
rm -f "$WORK_DIR/was-running" "$WORK_DIR/quiesce"

# Reproduce the real procd path: init start returns immediately, a detached
# worker stays in the explicit `start` action, and runtime readiness appears
# before the action is complete. postinst must wait for the terminal action,
# so the updater cannot launch a concurrent fallback restart.
cat >"$WORK_DIR/ui.uc" <<'EOF_UI'
#!/usr/bin/env ucode
let fs = require("fs");
let value = fs.readfile(getenv("FORKOP_TEST_ACTIVE"));
exit(ARGV[0] == "service-action-idle" && value == null ? 0 : 1);
EOF_UI
cat >"$WORK_DIR/detached-worker" <<'EOF_DETACHED_WORKER'
#!/bin/sh
sleep 2
: >"$1"
sleep 2
rm -f "$2"
EOF_DETACHED_WORKER
cat >"$WORK_DIR/detached-init" <<'EOF_DETACHED_INIT'
#!/bin/sh
base="$(dirname "$0")"
case "$1" in
start)
    printf 'start\n' >>"$base/init.log"
    printf 'start\n' >"$base/active"
    "$base/detached-worker" "$base/running" "$base/active" </dev/null >/dev/null 2>&1 &
    exit 0
    ;;
status)
    [ -e "$base/running" ]
    exit $?
    ;;
restart)
    printf 'restart\n' >>"$base/init.log"
    exit 0
    ;;
esac
exit 1
EOF_DETACHED_INIT
chmod 0755 "$WORK_DIR/detached-worker" "$WORK_DIR/detached-init"
: >"$WORK_DIR/init.log"
touch "$WORK_DIR/was-running" "$WORK_DIR/quiesce"
started="$(date +%s)"
FORKOP_INIT="$WORK_DIR/detached-init" \
FORKOP_CONFIG_PATH="$WORK_DIR/forkop.conf" \
FORKOP_PACKAGE_UPGRADE_STATE="$WORK_DIR/was-running" \
FORKOP_PACKAGE_UPGRADE_QUIESCE_FILE="$WORK_DIR/quiesce" \
FORKOP_COMPONENT_UPDATE_CHECK_CACHE_DIR="$WORK_DIR/cache" \
FORKOP_COMPONENT_UPDATE_CHECK_STATE_FILE="$WORK_DIR/component-state" \
FORKOP_TEST_INIT_LOG="$WORK_DIR/init.log" \
FORKOP_TEST_ACTIVE="$WORK_DIR/active" \
FORKOP_TEST_RUNNING="$WORK_DIR/running" \
FORKOP_TEST_WORKER="$WORK_DIR/detached-worker" \
FORKOP_UI_UC="$WORK_DIR/ui.uc" \
FORKOP_UPGRADE_RESTORE_WAIT_SECONDS=10 \
FORKOP_LIB="$FORKOP_LIB" \
ucode -L "$FORKOP_LIB" "$PACKAGE_UC" postinst || fail "detached postinst start failed"
elapsed="$(( $(date +%s) - started ))"
# This is the component updater's post-package fallback decision. It runs only
# after the simulated package-manager/postinst transaction has returned.
if ! "$WORK_DIR/detached-init" status; then
    "$WORK_DIR/detached-init" restart
fi
[ "$elapsed" -ge 4 ] || fail "postinst returned while the detached start action was still running"
[ "$(grep -c '^start$' "$WORK_DIR/init.log")" = 1 ] || fail "detached upgrade did not perform exactly one start"
if grep -q '^restart$' "$WORK_DIR/init.log"; then
    fail "component updater raced detached postinst with a fallback restart"
fi
[ ! -e "$WORK_DIR/was-running" ] || fail "detached restore retained the upgrade marker"
[ ! -e "$WORK_DIR/quiesce" ] || fail "detached restore retained the quiesce marker"

# A stuck executable must fail closed: do not start a replacement and retain
# the hand-off markers so the failed upgrade remains diagnosable/recoverable.
: >"$WORK_DIR/init.log"
touch "$WORK_DIR/was-running" "$WORK_DIR/quiesce"
("$FORKOP_XRUST_BIN" -e 'system("sleep 4")' &)
started="$(date +%s)"
if run_postinst 1 >/dev/null 2>&1; then
    fail "postinst accepted an Xrust process that exceeded the wait timeout"
fi
elapsed="$(( $(date +%s) - started ))"
[ "$elapsed" -ge 1 ] || fail "timeout path returned before its configured bound"
[ ! -s "$WORK_DIR/init.log" ] || fail "timeout path attempted to start Forkop"
[ -e "$WORK_DIR/was-running" ] || fail "timeout path lost the upgrade marker"
[ -e "$WORK_DIR/quiesce" ] || fail "timeout path lost the quiesce marker"

printf 'package upgrade Xrust wait checks passed\n'
