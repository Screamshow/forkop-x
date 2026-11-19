#!/bin/sh
set -eu

MIRROR_BASE_URL="${FORKOP_MIRROR_BASE_URL:-https://mirror.51343.ru}"
MIRROR_BASE_URL="${MIRROR_BASE_URL%/}"
MIGRATION_ID="mirror_51343_ru_v1"
SETTINGS_SECTION="forkop.settings"
MIGRATION_ROOT="${FORKOP_MIGRATION_ROOT:-}"
APK_BIN="${FORKOP_MIGRATION_APK_BIN:-apk}"
OPKG_BIN="${FORKOP_MIGRATION_OPKG_BIN:-opkg}"
CURL_BIN="${FORKOP_MIGRATION_CURL_BIN:-curl}"
UCI_BIN="${FORKOP_MIGRATION_UCI_BIN:-uci}"

PACKAGE_MANAGER=""
if command -v "$APK_BIN" >/dev/null 2>&1; then
    PACKAGE_MANAGER="apk"
elif command -v "$OPKG_BIN" >/dev/null 2>&1; then
    PACKAGE_MANAGER="opkg"
else
    exit 0
fi

root_path() {
    printf '%s%s\n' "$MIGRATION_ROOT" "$1"
}

mirror_supported() {
    release_file="$(root_path /etc/openwrt_release)"
    [ -r "$release_file" ] || return 1
    release="$(sed -n "s/^DISTRIB_RELEASE='\(.*\)'/\1/p" "$release_file" | head -n 1)"
    # Snapshot system packages must come from the firmware's own build feeds.
    # Keep Forkop release downloads on our mirror, but never redirect these feeds.
    case "$release" in
        *SNAPSHOT*) return 1 ;;
    esac
    target="$(sed -n "s/^DISTRIB_TARGET='\(.*\)'/\1/p" "$release_file" | head -n 1)"
    architecture="$(sed -n "s/^DISTRIB_ARCH='\(.*\)'/\1/p" "$release_file" | head -n 1)"
    [ "$target" = "mediatek/filogic" ] && [ "$architecture" = "aarch64_cortex-a53" ] || return 1
    for repository_file in "$(root_path /etc/opkg/distfeeds.conf)" "$(root_path /etc/apk/repositories)" \
        "$(root_path /etc/apk/repositories.d/distfeeds.list)"; do
        repository_file_has_vendor_origin "$repository_file" && return 1
        # A feed layout the mirror cannot replace keeps all native feeds, so a
        # file is never left half redirected.
        repository_layout_recognized "$repository_file" || return 1
    done
    return 0
}

repository_file_has_vendor_origin() {
    repository_file="$1"
    [ -r "$repository_file" ] || return 1
    grep -Eqi 'https?://[^/]*(packages\.routerich\.ru|[^/]*gl[-.]?inet[^/]*)/' "$repository_file"
}

restore_native_repository_file() {
    repository_file="$1"
    backup="${repository_file}.pre-forkop-mirror"
    [ -f "$backup" ] && [ -s "$repository_file" ] || return 0
    # Restore only the exact rewrite of the saved feeds. A mixed file may
    # contain vendor or user changes alongside URLs Forkop redirected.
    cmp -s "$backup" "$repository_file" && return 0
    rewrite_feed_urls "$backup" | cmp -s "$repository_file" - ||
        MIRROR_BASE_URL=https://mirror.51343.ru rewrite_feed_urls "$backup" | cmp -s "$repository_file" - ||
        return 0
    cp "$backup" "${repository_file}.forkop-restore"
    chmod 0644 "${repository_file}.forkop-restore"
    mv "${repository_file}.forkop-restore" "$repository_file"
    rm -f "$backup"
}

remove_owned_apk_mirror_artifacts() {
    feed="$repositories_dir/forkop.list"
    [ -f "$feed" ] || return 0
    case "$(cat "$feed")" in
        "$MIRROR_BASE_URL"/forkop/mirror/current/packages.adb|\
        "$MIRROR_BASE_URL"/forkop/mirror/current/aarch64_cortex-a53/packages.adb|\
        "$MIRROR_BASE_URL"/forkop/mirror/current/x86_64/packages.adb)
            rm -f "$feed" "$keys_dir/forkop-mirror.pem"
            ;;
    esac
}

# A release feed is recognised by what follows releases/ (a version with
# targets/ or packages/, or the vNN.x layout), so any mirror path before it
# works: /releases, /openwrt/releases, /downloads.openwrt.org/releases ...
rewrite_feed_urls() {
    sed -E \
        -e "s#https?://[^/[:space:]]+/([^[:space:]]*/)?releases/(v[0-9]+\\.x/)#${MIRROR_BASE_URL}/openwrt/releases/\\2#" \
        -e "s#https?://[^/[:space:]]+/([^[:space:]]*/)?releases/([0-9]+\\.[0-9]+[^/[:space:]]*/(targets|packages)/)#${MIRROR_BASE_URL}/openwrt/releases/\\2#" \
        -e "s#${MIRROR_BASE_URL}/openwrt/releases/v[0-9]+\\.x/v?([0-9]+\\.[0-9]+\\.[0-9]+)/mediatek/filogic/?([[:space:]]|$)#${MIRROR_BASE_URL}/openwrt/releases/\\1/targets/mediatek/filogic/packages\\2#" \
        -e "s#${MIRROR_BASE_URL}/openwrt/releases/v[0-9]+\\.x/v([0-9]+\\.[0-9]+\\.[0-9]+)/([^/]+)/([^/]+)/packages/packages\\.adb#${MIRROR_BASE_URL}/openwrt/releases/\\1/targets/\\2/\\3/packages/packages.adb#" \
        -e "s#${MIRROR_BASE_URL}/openwrt/releases/v[0-9]+\\.x/v([0-9]+\\.[0-9]+\\.[0-9]+)/([^/]+)/([^/]+)/packages\\.adb#${MIRROR_BASE_URL}/openwrt/releases/\\1/packages/\\2/\\3/packages.adb#" \
        "$1"
}

# True when every release URL (in the file, or stdin) maps onto the mirror.
feed_urls_redirected() {
    ! grep -E 'https?://[^[:space:]]*/releases/' ${1:+"$1"} | grep -Fv "$MIRROR_BASE_URL/openwrt/releases/" >/dev/null
}

repository_layout_recognized() {
    [ -e "$1" ] || return 0
    rewrite_feed_urls "$1" | feed_urls_redirected
}

rewrite_repository_file() {
    repository_file="$1"
    [ -e "$repository_file" ] || return 0

    temporary="${repository_file}.forkop-mirror-new"
    rewrite_feed_urls "$repository_file" > "$temporary"

    if ! feed_urls_redirected "$temporary"; then
        rm -f "$temporary"
        echo "Forkop mirror migration could not rewrite every URL in $repository_file" >&2
        return 1
    fi

    backup="${repository_file}.pre-forkop-mirror"
    [ -e "$backup" ] || cp "$repository_file" "$backup"
    mv "$temporary" "$repository_file"
}

case "$MIRROR_BASE_URL" in
    https://*|http://*) ;;
    *) echo "Invalid Forkop mirror URL: $MIRROR_BASE_URL" >&2; exit 1 ;;
esac

repositories="$(root_path /etc/apk/repositories)"
repositories_dir="$(root_path /etc/apk/repositories.d)"
keys_dir="$(root_path /etc/apk/keys)"
opkg_distfeeds="$(root_path /etc/opkg/distfeeds.conf)"

if ! mirror_supported; then
    # Unsupported targets use their vendor OpenWrt feeds for all dependencies.
    # Clean up only artifacts created by the old Forkop mirror integration.
    restore_native_repository_file "$repositories"
    restore_native_repository_file "$repositories_dir/distfeeds.list"
    restore_native_repository_file "$opkg_distfeeds"
    remove_owned_apk_mirror_artifacts
elif [ "$PACKAGE_MANAGER" = "apk" ]; then
    rewrite_repository_file "$repositories"
    rewrite_repository_file "$repositories_dir/distfeeds.list"

    mkdir -p "$keys_dir" "$repositories_dir"
    key_file="$keys_dir/forkop-mirror.pem"
    if ! grep -Fq 'BEGIN PUBLIC KEY' "$key_file" 2>/dev/null; then
        key_tmp="$key_file.new"
        if ! "$CURL_BIN" -fsSL --connect-timeout 15 --max-time 60 \
            "$MIRROR_BASE_URL/forkop/forkop-apk.pem" -o "$key_tmp"; then
            rm -f "$key_tmp"
            echo "Unable to download the Forkop mirror APK key" >&2
            exit 1
        fi
        grep -Fq 'BEGIN PUBLIC KEY' "$key_tmp" || {
            rm -f "$key_tmp"
            echo "The downloaded Forkop mirror APK key is invalid" >&2
            exit 1
        }
        mv "$key_tmp" "$key_file"
        chmod 0644 "$key_file"
    fi

    printf '%s\n' "$MIRROR_BASE_URL/forkop/mirror/current/$architecture/packages.adb" \
        > "$repositories_dir/forkop.list"
else
    rewrite_repository_file "$opkg_distfeeds"
fi

"$UCI_BIN" -q set "$SETTINGS_SECTION.mirror_base_url=$MIRROR_BASE_URL"
if ! "$UCI_BIN" -q get "$SETTINGS_SECTION.applied_migrations" 2>/dev/null |
    tr ' ' '\n' | grep -Fxq "$MIGRATION_ID"; then
    "$UCI_BIN" -q add_list "$SETTINGS_SECTION.applied_migrations=$MIGRATION_ID"
fi
"$UCI_BIN" -q commit forkop

exit 0
