#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sed '/^main "\$@"$/d' "$ROOT/install.sh" > "$work/library.sh"
. "$work/library.sh"
TMP_DIR="$work"
export FORKOP_INSTALLER_LIB="$ROOT/forkop/files/usr/lib"
export FORKOP_INSTALLER_INIT="$work/init"
cat > "$FORKOP_INSTALLER_INIT" <<'SH'
#!/bin/sh
[ "${RUNNING:-0}" = 1 ] || { [ -n "${REPAIR_RUNNING_FILE:-}" ] && [ -f "$REPAIR_RUNNING_FILE" ]; }
SH
chmod 700 "$FORKOP_INSTALLER_INIT"

pkg_is_installed() { [ "$1" = forkop ]; }
installed_forkop_package_version() { printf '%s\n' "$INSTALLED_FORKOP"; }
pinned_xrust_installed_version() { printf '%s\n' "$INSTALLED_XRUST"; }
pinned_xrust_binary_matches() { [ "$BINARY_BUILD" = "$FORKOP_XRUST_VERSION" ]; }
read_openwrt_release_value() { printf '%s\n' x86_64; }
http_get() {
    case "$1" in
        "$MIRROR_BASE_URL/forkop/updates/releases/3.0.3/release.json")
            printf '%s\n' '{"tag_name":"3.0.3","xrust_version":"0.0.45"}' ;;
        "$MIRROR_BASE_URL/forkop/updates/canary/releases/3.0.3-canary.1/release.json")
            printf '%s\n' '{"tag_name":"3.0.3-canary.1","xrust_version":"0.0.45"}' ;;
        "$MIRROR_BASE_URL/forkop/rust-x/releases/0.0.45/manifest.json")
            printf '{"schema":1,"name":"rust-x","version":"0.0.45","minimum_forkop_major":3,"package_revision":1,"assets":['
            name="rust-x_0.0.45-$revision"'_x86_64.'"$format_fixture"
            printf '{"package":"rust-x","version":"0.0.45-%s","architecture":"x86_64","format":"%s","name":"%s","url":"%s/%s","size":1,"installed_size":1,"sha256":"%064d"}]}\n' \
                "$revision" "$format_fixture" "$name" "${1%/*}" "$name" 0 ;;
        *) return 1 ;;
    esac
}

for PKG_IS_APK in 0 1; do
    revision=1 format_fixture=ipk INSTALLED_FORKOP=3.0.3
    [ "$PKG_IS_APK" -eq 0 ] || { revision=r1 format_fixture=apk INSTALLED_FORKOP=3.0.3_rc1; }
    INSTALLED_XRUST="0.0.45-$revision" BINARY_BUILD=0.0.45
    if forkop_needs_xrust_repair; then exit 1; fi
    INSTALLED_XRUST="0.0.45-${revision%1}2"
    forkop_needs_xrust_repair
    INSTALLED_XRUST="0.0.46-$revision" BINARY_BUILD=0.0.46
    forkop_needs_xrust_repair
    if RUNNING=1 forkop_needs_xrust_repair; then exit 1; fi
    INSTALLED_XRUST="0.0.45-$revision" BINARY_BUILD=''
    forkop_needs_xrust_repair
    INSTALLED_XRUST='' BINARY_BUILD=''
    forkop_needs_xrust_repair
done

lock="$work/runtime/component-action.lock"
mkdir -p "$lock"
if acquire_xrust_repair_lock "$lock"; then exit 1; fi
printf '%s\n' "$$" > "$lock/pid"
if acquire_xrust_repair_lock "$lock"; then exit 1; fi
printf '%s\n' 99999999 > "$lock/pid"
acquire_xrust_repair_lock "$lock"
[ "$REPAIR_XRUST_LOCK" = "$lock" ]
[ "$(cat "$lock/pid")" = "$$" ]
component_status=0
FORKOP_LIB="$FORKOP_INSTALLER_LIB" FORKOP_RUNTIME_STATE_DIR="$work/runtime" UPDATES_LOCK_DIR="$lock" \
    FORKOP_COMPONENT_BACKGROUND=1 FORKOP_SERVICE_INIT="$work/missing" FORKOP_BIN="$work/missing" \
    ucode -L "$FORKOP_INSTALLER_LIB" "$FORKOP_INSTALLER_LIB/components/action.uc" component-action fixture fixture ||
    component_status=$?
[ "$component_status" -eq 75 ]
release_xrust_repair_locks
[ ! -d "$lock" ]

(
    export UPDATES_LOCK_DIR="$lock" FORKOP_RELOAD_LOCK_DIR="$work/runtime/reload.lock"
    export FORKOP_INSTALLER_CONFIG_DIR="$work/config" FORKOP_INSTALLER_BACKUP_DIR="$work/backup"
    export REPAIR_RUNNING_FILE="$work/running"
    mkdir "$FORKOP_INSTALLER_CONFIG_DIR"
    printf 'fixture\n' > "$FORKOP_INSTALLER_CONFIG_DIR/forkop"
    INSTALLED_FORKOP=3.0.3
    INSTALLED_XRUST=0.0.45-1
    xrust_pin_for_installed_release() { printf '%s\n' 0.0.45; }
    prepare_core_package_plan() { core_url=https://test.invalid/rust-x_0.0.45-1_x86_64.ipk; }
    download_xrust_archive() {
        printf 'fixture\n' > "$1"
        if [ "${START_DURING_DOWNLOAD:-0}" -eq 1 ]; then touch "$REPAIR_RUNNING_FILE"; fi
    }
    package_payload_size_kb() { printf '%s\n' 1; }
    pinned_xrust_binary_matches() { [ -e "$work/installed-binary" ]; }
    repair_service_module() {
        case "$1:$2" in
            ui:begin-package-upgrade-quiesce) touch "$work/quiesced" ;;
            ui:service-action-idle) [ -f "$work/quiesced" ] ;;
            ui:clear-package-upgrade-quiesce-if-owner) rm -f "$work/quiesced" ;;
            state:sing-box-process-count) printf '%s\n' 0 ;;
            *) return 1 ;;
        esac
    }
    install_repair_xrust_archive() {
        [ -f "$work/quiesced" ] &&
            [ "$(cat "$UPDATES_LOCK_DIR/pid")" = "$$" ] &&
            [ "$(cat "$FORKOP_RELOAD_LOCK_DIR/pid")" = "$$" ] &&
            touch "$work/installed-binary"
    }
    install_json_ucode() {
        case "$1" in
            installer-start-forkop)
                [ ! -d "$FORKOP_RELOAD_LOCK_DIR" ] && touch "$REPAIR_RUNNING_FILE" ;;
            installer-wait-forkop-ready) [ -f "$REPAIR_RUNNING_FILE" ] ;;
            *) return 1 ;;
        esac
    }

    repair_xrust
    [ -f "$work/installed-binary" ]
    [ ! -f "$REPAIR_RUNNING_FILE" ]
    release_xrust_repair_locks
    [ ! -d "$UPDATES_LOCK_DIR" ]
    [ ! -f "$work/quiesced" ]

    rm "$work/installed-binary"
    if (
        trap release_xrust_repair_locks EXIT
        START_DURING_DOWNLOAD=1 repair_xrust
    ); then exit 1; fi
    [ -f "$REPAIR_RUNNING_FILE" ]
    [ ! -f "$work/installed-binary" ]
    [ ! -d "$UPDATES_LOCK_DIR" ]
    [ ! -d "$FORKOP_RELOAD_LOCK_DIR" ]
    [ ! -f "$work/quiesced" ]

    rm "$REPAIR_RUNNING_FILE"
    REPAIR_XRUST=1 repair_xrust
    [ -f "$work/installed-binary" ]
    [ -f "$REPAIR_RUNNING_FILE" ]
    release_xrust_repair_locks
)

trace="$work/repair-trace"
check_root() { :; }
init_tmp_dir() { :; }
detect_fetcher() { :; }
cleanup() { :; }
check_system() { :; }
forkop_needs_xrust_repair() { return 0; }
repair_xrust() { printf 'repair\n' >> "$trace"; }
sync_time() { printf 'normal upgrade\n' >> "$trace"; exit 0; }
(main --repair-xrust)
printf 'repair\n' | cmp - "$trace"
: > "$trace"
(main)
printf 'repair\nnormal upgrade\n' | cmp - "$trace"
echo 'Xrust repair checks the exact package, shares locks, and preserves service state during a normal update'
