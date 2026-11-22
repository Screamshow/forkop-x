#!/bin/sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

TMP_DIR="$work"
INSTALL_MODE=update
FORKOP_RELEASE_TAG=3.0.0
FORKOP_XRUST_VERSION=0.0.45
MIRROR_BASE_URL=https://mirror.example.test
UPDATES_LOCK_DIR="$work/lock"
export TEST_WORK="$work" TEST_FORKOP="$work/forkop" TEST_HOOK="$work/boot-hook"

sed -n '/^install_json_helper_path() {/,/^install_json_ucode() {/ { /^install_json_ucode() {/d; p; }' \
    "$ROOT/install.sh" > "$work/functions.sh"
sed -n '/^forkop_component_action_in_progress() {/,/^}/p; /^upgrade_forkop_with_pinned_xrust() {/,/^}/p' \
    "$ROOT/install.sh" | sed 's@/usr/bin/forkop@${TEST_FORKOP}@g; s@/etc/rc.d/S98forkop-upgrade-recovery@${TEST_HOOK}@g' >> "$work/functions.sh"
. "$work/functions.sh"

fail() { printf '%s\n' "$1" >&2; exit 1; }
warn() { printf '%s\n' "$1" >&2; }
msg() { printf '%s\n' "$1"; }
installed_forkop_package_version() { printf '2.7.6\n'; }
pkg_is_installed() { [ "$1" = rust-x ]; }
prepare_bridge_xrust() { :; }
install_json_ucode() { ucode "$(install_json_helper_path)" "$@"; }
prepare_legacy_upgrade_recovery() {
    printf 'prepare\n' >> "$work/events"
    ln -s "$work/recover" "$TEST_HOOK"
}
sleep() {
    [ "$1" = 2 ] && [ ! -L "$TEST_HOOK" ] || fail 'Unexpected wait or journal retained while waiting'
    printf 'wait\n' >> "$work/events"
}

cat > "$work/recover" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >> "$TEST_WORK/events"
[ "$1" = commit ] && rm "$TEST_HOOK"
SH
cat > "$work/forkop" <<'SH'
#!/bin/sh
set -eu
[ "$*" = 'component_action forkop install_pinned_xrust 3.0.0' ]
[ "$FORKOP_COMPONENT_BACKGROUND" = 0 ] && [ -L "$TEST_HOOK" ]
printf 'action\n' >> "$TEST_WORK/events"
case "$TEST_CASE:$(grep -c '^action$' "$TEST_WORK/events")" in
    late:1) changed=0 ;;
    actual-error:1) changed=1 ;;
    late:2) echo '{"success":true}'; exit 0 ;;
    *) exit 1 ;;
esac
printf '{"success":false,"kind":"component","component":"forkop","action":"install_pinned_xrust","changed":%s,"message":"Another component action is already running"}\n' "$changed"
exit 1
SH
chmod 0700 "$work/recover" "$work/forkop"

export TEST_CASE=timeout
mkdir "$UPDATES_LOCK_DIR"
printf '%s\n' "$$" > "$UPDATES_LOCK_DIR/pid"
if (upgrade_forkop_with_pinned_xrust) > "$work/output" 2>&1; then exit 1; fi
grep -Fq 'Another Forkop component action is still running' "$work/output"
[ "$(grep -c '^wait$' "$work/events")" -eq 15 ]
if grep -Eq '^(action|prepare)$' "$work/events"; then fail 'Timeout entered the package transaction'; fi
[ ! -L "$TEST_HOOK" ]
rm "$UPDATES_LOCK_DIR/pid"
rmdir "$UPDATES_LOCK_DIR"

export TEST_CASE=late
: > "$work/events"
upgrade_forkop_with_pinned_xrust > "$work/output"
printf 'prepare\naction\ncommit\nwait\nprepare\naction\ncommit\n' | cmp - "$work/events"
[ ! -L "$TEST_HOOK" ]

export TEST_CASE=actual-error
: > "$work/events"
if (upgrade_forkop_with_pinned_xrust) > "$work/output" 2>&1; then exit 1; fi
printf 'prepare\naction\ncommit-restored\n' | cmp - "$work/events"
[ -L "$TEST_HOOK" ]
grep -Fq 'remains available for boot recovery' "$work/output"
grep -Fq "Forkop update to 3.0.0 failed. See the result above and run 'logread -e forkop' for package manager details." "$work/output"

echo 'Installer component contention, retry and real recovery failure checks passed'
