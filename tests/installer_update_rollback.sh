#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d /tmp/forkop-update-rollback.XXXXXX)"
trap 'rm -rf "$work"' EXIT
fail() { printf '%s\n' "$1" >&2; exit 1; }
warn() { :; }
msg() { :; }
prepare_package_init_adapter() { :; }
sed -n '/^rollback_current_update() {/,/^}/p; /^prepare_current_update_rollback() {/,/^}/p' \
  "$ROOT/install.sh" > "$work/functions.sh"
sed -n '/^install_json_helper_path() {/,/^install_json_ucode() {/ { /^install_json_ucode() {/d; p; }' \
  "$ROOT/install.sh" >> "$work/functions.sh"
. "$work/functions.sh"
eval "$(sed -n '/^opkg_with_lock_retry() (/,/^)/p' "$ROOT/install.sh")"
TMP_DIR="$work"
mkdir -p "$work/rollback" "$work/config"
export FORKOP_INSTALLER_CONFIG_DIR="$work/config"
printf 'old configuration\n' > "$work/config/forkop"
tar -czf "$work/original.tar.gz" -C "$work/config" forkop
UPDATE_ROLLBACK_MANIFEST="$work/rollback/packages.tsv"
printf 'luci-app-forkop\t1.2.3\tapp.ipk\nforkop\t1.2.3\tbackend.ipk\n' > "$UPDATE_ROLLBACK_MANIFEST"
installed_forkop_package_version() { printf '1.2.3\n'; }
install_json_ucode() {
    case "$1" in
        installer-stop-current) printf 'stop\n' >> "$work/events"; [ "$STOP_OK" = 1 ] ;;
        installer-restore-previous-service)
            [ "$(cat "$work/config/forkop")" = 'old configuration' ] || fail 'postinst changed restored configuration'
            printf 'service:%s:%s\n' "$FORKOP_WAS_ENABLED" "$FORKOP_WAS_RUNNING" >> "$work/events" ;;
    esac
}
apk() {
    [ "$(cat "$work/config/forkop")" = 'old configuration' ] || fail 'packages restored before configuration'
    printf 'apk:%s\n' "$*" >> "$work/events"
    printf 'configuration rewritten by old postinst\n' > "$work/config/forkop"
    [ "$PKG_OK" = 1 ]
}
opkg() {
    [ "$(cat "$work/config/forkop")" = 'old configuration' ] || fail 'packages restored before configuration'
    printf 'opkg:%s\n' "$*" >> "$work/events"
    printf 'configuration rewritten by old postinst\n' > "$work/config/forkop"
    [ "$PKG_OK" = 1 ]
}
pkg_is_installed() { [ "$NEW_I18N" = 1 ]; }
pkg_remove_name() { printf 'remove:%s\n' "$1" >> "$work/events"; }
reset() {
    UPDATE_TRANSACTION_ACTIVE=1
    UPDATE_ROLLBACK_ATTEMPTED=0
    UPDATE_ROLLBACK_FAILED=0
    UPDATE_HAD_I18N=0
    FORKOP_WAS_ENABLED=0
    FORKOP_WAS_RUNNING=0
    STOP_OK=1
    PKG_OK=1
    NEW_I18N=1
    : > "$work/events"
    cp "$work/original.tar.gz" "$work/rollback/configuration.tar.gz"
    printf 'migrated configuration\n' > "$work/config/forkop"
}
for PKG_IS_APK in 0 1; do
    reset
    FORKOP_WAS_ENABLED=1
    FORKOP_WAS_RUNNING=1
    rollback_current_update
    [ "$UPDATE_ROLLBACK_FAILED" = 0 ] || fail 'valid rollback failed'
    [ "$(tail -n 1 "$work/events")" = service:1:1 ] || fail 'service state not restored'
    grep -q '^remove:luci-i18n-forkop-ru$' "$work/events" || fail 'new translation retained'
    [ "$(grep -c 'app.ipk backend.ipk' "$work/events")" = 1 ] || fail 'package set not restored together'
    before="$(wc -l < "$work/events")"
    rollback_current_update
    [ "$(wc -l < "$work/events")" = "$before" ] || fail 'rollback repeated from cleanup'
    reset
    PKG_OK=0
    rollback_current_update
    [ "$UPDATE_ROLLBACK_FAILED" = 1 ] || fail 'package restore failure ignored'
    if grep -q '^service:' "$work/events"; then fail 'started mismatched backend'; fi
    reset
    printf invalid > "$work/rollback/configuration.tar.gz"
    rollback_current_update
    [ "$UPDATE_ROLLBACK_FAILED" = 1 ] || fail 'corrupt archive accepted'
    [ "$(cat "$work/config/forkop")" = 'migrated configuration' ] || fail 'corrupt archive destroyed configuration'
    [ "$(wc -l < "$work/events")" = 1 ] || fail 'packages changed after archive failure'
    reset
    STOP_OK=0
    rollback_current_update
    [ "$UPDATE_ROLLBACK_FAILED" = 1 ] || fail 'unsafe service stop accepted'
    [ "$(cat "$work/config/forkop")" = 'migrated configuration' ] || fail 'configuration overwritten without stop'
    reset
    UPDATE_HAD_I18N=1
    rollback_current_update
    if grep -q '^remove:' "$work/events"; then fail 'existing translation removed'; fi
    [ "$(tail -n 1 "$work/events")" = service:0:0 ] || fail 'stopped service state not preserved'
    reset
    UPDATE_TRANSACTION_ACTIVE=0
    rollback_current_update
    [ ! -s "$work/events" ] || fail 'committed update rolled back'
done
# Exercise the actual embedded catalog reader and canary asset matching.
helper="$(install_json_helper_path)"
printf '{"releases":[{"tag_name":"1.2.3-canary.7","assets":[{"name":"forkop_1.2.3-canary.7.apk","browser_download_url":"/old.apk"}]}]}' > "$work/catalog.json"
entry="$(ucode "$helper" release-catalog-entry 1.2.3-canary.7 < "$work/catalog.json")"
[ "$(printf '%s' "$entry" | ucode "$helper" release-asset-url backend apk)" = /old.apk ] || fail 'canary APK rollback metadata'
if ucode "$helper" release-catalog-entry 9.9.9 < "$work/catalog.json"; then fail 'missing release accepted'; fi
# Stage exact rollback versions through the real catalog/asset reader.
INSTALL_MODE=update
PKG_IS_APK=1
MIRROR_BASE_URL=https://mirror.test
export FORKOP_INSTALLER_BACKUP_DIR="$work/backups"
mkdir -p "$work/backups"
cp "$work/original.tar.gz" "$work/backups/configuration.tar.gz"
digest="$(printf archive | sha256sum | awk '{print $1}')"
printf '{"releases":[{"tag_name":"1.2.3-canary.7","assets":[{"name":"forkop_1.2.3-canary.7.apk","sha256":"%s","browser_download_url":"/backend.apk"},{"name":"luci-app-forkop_1.2.3-canary.7.apk","sha256":"%s","browser_download_url":"/app.apk"}]}]}' "$digest" "$digest" > "$work/catalog.json"
http_get() { cat "$work/catalog.json"; }
installed_forkop_package_version() {
    [ "$1" = luci-i18n-forkop-ru ] || printf '1.2.3_rc7\n'
}
service_capture_failures=0
install_json_ucode() {
    if [ "$1" = installer-capture-service ]; then
        printf 'capture\n' >> "$work/service-captures"
        [ "$(wc -l < "$work/service-captures")" -gt "$service_capture_failures" ] || return 1
        printf 'FORKOP_WAS_ENABLED=0\nFORKOP_WAS_RUNNING=0\n'
    else
        ucode "$helper" "$@"
    fi
}
mirror_asset_url() { printf '%s%s\n' "$MIRROR_BASE_URL" "$1"; }
download_with_retry() { printf archive > "$2"; }
verify_download_sha256() {
    [ "$(sha256sum "$1" | awk '{print $1}')" = "$2" ] || fail 'rollback hash mismatch'
}
UPDATE_TRANSACTION_ACTIVE=0
UPDATE_HAD_I18N=0
prepare_current_update_rollback
[ "$(wc -l < "$UPDATE_ROLLBACK_MANIFEST")" = 2 ] || fail 'incorrect rollback package set'
[ "$UPDATE_TRANSACTION_ACTIVE" = 0 ] || fail 'staging started mutation transaction'
[ "$(wc -l < "$work/service-captures")" = 1 ] || fail 'successful service probe was repeated'
sleep() { printf '%s\n' "$1" >> "$work/service-retry-delays"; }

service_capture_failures=1
: > "$work/service-captures"
prepare_current_update_rollback
[ "$(wc -l < "$work/service-captures")" = 2 ] || fail 'transient service probe was not retried once'
[ "$(cat "$work/service-retry-delays")" = 1 ] || fail 'unexpected delay before retry'

service_capture_failures=2
: > "$work/service-captures"
: > "$work/service-retry-delays"
if (prepare_current_update_rollback) > "$work/service-error" 2>&1; then
    fail 'persistent service probe failure was accepted'
fi
[ "$(wc -l < "$work/service-captures")" = 2 ] || fail 'persistent service failure did not stop after retry'
[ "$(cat "$work/service-retry-delays")" = 1 ] || fail 'persistent service probe retried more than once'
grep -Fq 'Cannot capture service state for update rollback after retry' "$work/service-error"
[ "$UPDATE_TRANSACTION_ACTIVE" = 0 ] || fail 'failed service preflight started package changes'
service_capture_failures=0

printf '{"releases":[]}' > "$work/catalog.json"
if (prepare_current_update_rollback); then fail 'update accepted without exact rollback packages'; fi
# Original packages are resolved separately, with the same hash checks.
printf '{"releases":[{"tag_name":"1.0.5","assets":[' > "$work/original-catalog.json"
for name in luci-app-forkop luci-i18n-forkop-ru forkop; do
    [ "$name" = luci-app-forkop ] || printf ',' >> "$work/original-catalog.json"
    printf '{"name":"%s_1.0.5.ipk","sha256":"%s","browser_download_url":"/original/%s.ipk"}' "$name" "$digest" "$name" >> "$work/original-catalog.json"
done
printf ']}]}' >> "$work/original-catalog.json"
http_get() {
    case "$1" in
        */original/releases.json) cat "$work/original-catalog.json" ;;
        *) cat "$work/catalog.json" ;;
    esac
}
installed_forkop_package_version() { printf '1.0.5\n'; }
PKG_IS_APK=0
prepare_current_update_rollback
[ "$(wc -l < "$UPDATE_ROLLBACK_MANIFEST")" = 3 ] || fail 'original rollback package set incomplete'
[ "$UPDATE_HAD_I18N" = 1 ] || fail 'original translation not preserved'
printf '{"releases":[]}' > "$work/original-catalog.json"
if (prepare_current_update_rollback); then fail 'unknown original release accepted'; fi
printf 'Installer update rollback checks passed\n'
