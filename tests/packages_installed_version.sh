#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="${FORKOP_TEST_LIB:-$ROOT/forkop/files/usr/lib}"
UCODE="$(command -v ucode)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# One package manager per directory: the module picks APK over opkg, so the
# search path decides which host the module believes it runs on. The stubs use
# shell builtins only, because that path holds nothing else.
mkdir -p "$work/opkg-bin" "$work/apk-bin" "$work/empty-bin"

cat >"$work/opkg-bin/opkg" <<'STUB'
#!/bin/sh
if [ "${STUB_OPKG_LOCK:-0}" = 1 ]; then
  echo "opkg_conf_load: Could not lock /var/lock/opkg.lock: Resource temporarily unavailable." >&2
  exit 255
fi
[ "$1" = list-installed ] || exit 1
while IFS= read -r line; do echo "$line"; done <"$STUB_OPKG_LIST"
STUB

cat >"$work/apk-bin/apk" <<'STUB'
#!/bin/sh
if [ "${STUB_APK_LOCK:-0}" = 1 ]; then
  echo "ERROR: Unable to lock database: temporary error" >&2
  exit 1
fi
[ "$1" = list ] || exit 1
while IFS= read -r line; do echo "$line"; done <"$STUB_APK_LIST"
STUB
chmod 755 "$work/opkg-bin/opkg" "$work/apk-bin/apk"

printf 'forkop - 2.5.0\nluci-app-forkop - 2.5.0\n' >"$work/installed.txt"
printf 'forkop-2.5.0 noarch {forkop} (GPL-2.0-or-later) [installed]\n' >"$work/apk-list.txt"
cat >"$work/status" <<'STATUS'
Package: forkop
Version: 2.5.0
Status: install user installed

Package: luci-app-forkop
Version: 2.4.3
Status: deinstall hold not-installed
STATUS
cat >"$work/apk-db" <<'APKDB'
C:Q1dc1b01cf2e2a02a1d4e2fb3c0d5a6b7c8
P:forkop
V:2.5.0
A:noarch
APKDB

# $1 search path, $2 expected exit code, $3 expected output prefix,
# $4 package, rest: environment of the module
run() {
  path="$work/$1"
  expected_status="$2"
  expected_text="$3"
  package="$4"
  shift 4
  set +e
  output="$(env PATH="$path" "$@" "$UCODE" -L "$LIB" "$LIB/core/packages.uc" installed-version "$package" 2>&1)"
  status=$?
  set -e
  [ "$status" = "$expected_status" ] ||
    fail "$package on $1: exit code $status, expected $expected_status ($output)"
  case "$output" in
    $expected_text*) ;;
    *) fail "$package on $1: output '$output', expected '$expected_text'" ;;
  esac
}

opkg_env="STUB_OPKG_LIST=$work/installed.txt"
apk_env="STUB_APK_LIST=$work/apk-list.txt"

# An answered query reports the version, or that the package is not installed.
run opkg-bin 0 "found 2.5.0" forkop "$opkg_env" FORKOP_OPKG_STATUS_PATH="$work/status"
run opkg-bin 3 "missing" luci-i18n-forkop-ru "$opkg_env" FORKOP_OPKG_STATUS_PATH="$work/status"

# A busy opkg lock must not hide an installed version: the status database
# answers without the lock.
run opkg-bin 0 "found 2.5.0" forkop STUB_OPKG_LOCK=1 "$opkg_env" \
  FORKOP_OPKG_STATUS_PATH="$work/status"
run opkg-bin 3 "missing" luci-app-forkop STUB_OPKG_LOCK=1 "$opkg_env" \
  FORKOP_OPKG_STATUS_PATH="$work/status"
run opkg-bin 3 "missing" luci-i18n-forkop-ru STUB_OPKG_LOCK=1 "$opkg_env" \
  FORKOP_OPKG_STATUS_PATH="$work/status"

# Without a usable database the failure is reported as a failure, never as a
# version, and keeps the package manager error for the log.
run opkg-bin 2 "error opkg_conf_load: Could not lock" forkop STUB_OPKG_LOCK=1 "$opkg_env" \
  FORKOP_OPKG_STATUS_PATH="$work/absent-status"

# The same three answers on APK hosts.
run apk-bin 0 "found 2.5.0" forkop "$apk_env" FORKOP_APK_DB_PATH="$work/apk-db"
run apk-bin 3 "missing" luci-app-forkop "$apk_env" FORKOP_APK_DB_PATH="$work/apk-db"
run apk-bin 0 "found 2.5.0" forkop STUB_APK_LOCK=1 "$apk_env" FORKOP_APK_DB_PATH="$work/apk-db"
run apk-bin 3 "missing" luci-app-forkop STUB_APK_LOCK=1 "$apk_env" FORKOP_APK_DB_PATH="$work/apk-db"
run apk-bin 2 "error ERROR: Unable to lock database" forkop STUB_APK_LOCK=1 "$apk_env" \
  FORKOP_APK_DB_PATH="$work/absent-apk-db"

# No package manager at all is a failed query, not a missing package.
run empty-bin 2 "error no supported package manager" forkop

printf 'installed version state tests passed\n'
