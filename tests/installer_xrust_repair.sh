#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sed '/^main "\$@"$/d' "$ROOT/install.sh" > "$work/library.sh"
. "$work/library.sh"
TMP_DIR="$work"
export FORKOP_INSTALLER_INIT="$work/init"
cat > "$FORKOP_INSTALLER_INIT" <<'SH'
#!/bin/sh
[ "${RUNNING:-0}" = 1 ]
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
[ "$REPAIR_XRUST_LOCK" = "$lock" ] && [ "$(cat "$lock/pid")" = "$$" ]
release_xrust_repair_lock
[ ! -d "$lock" ]

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
echo 'Xrust repair checks exact release and package revision and recovers a dead lock'
