#!/bin/sh
set -eu
umask 077

# An optional filesystem root is used only by the isolated regression tests.
ROOT="${FORKOP_UNINSTALL_ROOT:-}"
if [ -n "$ROOT" ]; then ROOT="$(cd "$ROOT" && pwd -P)"; fi
MIRROR="${FORKOP_MIRROR_BASE_URL:-}"
if [ -z "$MIRROR" ]; then MIRROR="$(uci -q get forkop.settings.mirror_base_url 2>/dev/null || true)"; fi
MIRROR="${MIRROR:-https://mirror.51343.ru}"
BIN="$ROOT/usr/bin/forkop"
TORRSERVER_DIRECT_INIT="$ROOT/etc/init.d/forkop-torrserver-direct"
TORRSERVER_DIRECT_UC="$ROOT/usr/lib/forkop/torrserver/direct.uc"
UCODE_BIN="$ROOT/usr/bin/ucode"
LOCK="$ROOT/tmp/forkop-full-uninstall.lock"
COMPONENT_LOCK="$ROOT/var/run/forkop/component-action.lock"
PACKAGES="luci-i18n-forkop-ru luci-app-forkop forkop rust-x sing-box-x sing-box sing-box-tiny sing-box-extended"
PHASE=preflight

has_mirror() {
    grep -Fq "${MIRROR%/}/" "$1" || grep -Fq 'mirror.51343.ru/' "$1"
}

repository_plan() {
    : > "$JOB/repositories"
    # Only system repository files that Forkop itself backed up are eligible
    # for restoration. Never infer ownership from a URL in custom/vendor feeds.
    for file in "$ROOT/etc/opkg/distfeeds.conf" \
        "$ROOT/etc/apk/repositories" "$ROOT"/etc/apk/repositories.d/*.list; do
        [ -f "$file" ] || continue
        [ "$file" != "$ROOT/etc/apk/repositories.d/forkop.list" ] || continue
        source="${file}.pre-forkop-mirror"
        if [ ! -f "$source" ] || has_mirror "$source" || ! has_mirror "$file"; then
            continue
        fi
        printf '%s|%s\n' "$file" "$source" >> "$JOB/repositories"
    done
}

remove_owned_apk_mirror_artifacts() {
    feed="$ROOT/etc/apk/repositories.d/forkop.list"
    if [ -f "$feed" ] && grep -Fqx \
        -e "${MIRROR%/}/forkop/mirror/current/packages.adb" \
        -e "${MIRROR%/}/forkop/mirror/current/aarch64_cortex-a53/packages.adb" \
        -e "${MIRROR%/}/forkop/mirror/current/x86_64/packages.adb" "$feed"; then
        rm -f "$feed" "$ROOT/etc/apk/keys/forkop-mirror.pem"
    fi
}

installed() {
    if [ "$MANAGER" = apk ]; then apk info -e "$1" >/dev/null 2>&1
    else opkg status "$1" 2>/dev/null | grep -q '^Status: .* installed$'; fi
}

remove_packages() {
    if [ "$MANAGER" = apk ]; then apk del "$@"
    else opkg remove "$@"; fi
}

state() {
    printf '{"state":"%s","phase":"%s"}\n' "$1" "$PHASE" > "$STATUS.new"
    chmod 644 "$STATUS.new"
    mv "$STATUS.new" "$STATUS"
}

finish() {
    code=$?
    trap - EXIT
    if [ "$code" -ne 0 ]; then state failed; fi
    rm -f "$COMPONENT_LOCK/pid"
    rmdir "$COMPONENT_LOCK" 2>/dev/null || true
    rm -f "$LOCK/pid"
    rmdir "$LOCK" 2>/dev/null || true
    # A short-lived, non-sensitive status file remains readable after LuCI is
    # uninstalled, so the browser never has to guess whether removal succeeded.
    (sleep 300; rm -f "$STATUS" "$STATUS.new") </dev/null >/dev/null 2>&1 &
    exit "$code"
}

run() {
    trap finish EXIT
    state running
    repository_plan
    if [ -n "$ROOT" ]; then
        # A fixture root must never fall back to the host package manager.
        if [ -x "$ROOT/bin/apk" ]; then MANAGER=apk
        elif [ -x "$ROOT/bin/opkg" ]; then MANAGER=opkg
        else return 1; fi
        PATH="$ROOT/bin:$PATH"
        export PATH
    elif command -v apk >/dev/null 2>&1; then MANAGER=apk
    elif command -v opkg >/dev/null 2>&1; then MANAGER=opkg
    else return 1; fi

    PHASE=stop
    state running
    if [ -x "$ROOT/etc/init.d/forkop-tailscale" ]; then
        "$ROOT/etc/init.d/forkop-tailscale" stop || true
        "$ROOT/etc/init.d/forkop-tailscale" disable || true
    fi
    if [ -x "$ROOT/etc/init.d/forkop-support" ]; then
        "$ROOT/etc/init.d/forkop-support" stop || true
        "$ROOT/etc/init.d/forkop-support" disable || true
    fi
    if [ -x "$ROOT/etc/init.d/forkop" ]; then
        "$ROOT/etc/init.d/forkop" stop || echo "Forkop service did not stop cleanly" >&2
        "$ROOT/etc/init.d/forkop" disable || echo "Forkop service could not be disabled" >&2
    fi
    if [ -x "$BIN" ] && ! "$BIN" dnsmasq_restore; then
        echo "Could not restore dnsmasq; removal stopped before deleting packages" >&2
        return 1
    fi
    # Direct proxy is served by the Forkop-managed sing-box runtime, so
    # stopping Forkop above closes its listener. TorrServer Direct owns a
    # separate service and nftables table: stop both explicitly before its
    # configuration and binaries disappear.
    if [ -x "$TORRSERVER_DIRECT_INIT" ]; then
        "$TORRSERVER_DIRECT_INIT" stop || true
        "$TORRSERVER_DIRECT_INIT" disable || true
    fi
    if [ -x "$UCODE_BIN" ] && [ -f "$TORRSERVER_DIRECT_UC" ]; then
        "$UCODE_BIN" -L "$ROOT/usr/lib/forkop" "$TORRSERVER_DIRECT_UC" remove || true
    fi
    if [ -x "$ROOT/etc/init.d/sing-box" ]; then
        "$ROOT/etc/init.d/sing-box" stop || echo "sing-box service did not stop cleanly" >&2
        "$ROOT/etc/init.d/sing-box" disable || echo "sing-box service could not be disabled" >&2
    fi

    PHASE=repositories
    state running
    while IFS='|' read -r file source; do
        cp "$source" "$file.forkop-restore"
        chmod 644 "$file.forkop-restore"
        mv "$file.forkop-restore" "$file"
    done < "$JOB/repositories"
    remove_owned_apk_mirror_artifacts

    PHASE=packages
    state running
    set --
    for package in $PACKAGES; do
        if installed "$package"; then set -- "$@" "$package"; fi
    done
    if [ "$#" -gt 0 ] && ! remove_packages "$@"; then
        echo "Batch removal failed; retrying remaining packages individually" >&2
        for package in "$@"; do
            if installed "$package"; then remove_packages "$package" || true; fi
        done
    fi
    remaining=
    for package in $PACKAGES; do
        if installed "$package"; then remaining="$remaining $package"; fi
    done
    if [ -n "$remaining" ]; then
        echo "Packages were not removed:$remaining" >&2
        return 1
    fi

    PHASE=files
    state running
    # Lite is a private standalone installation. Never remove system Tailscale.
    if [ ! -L "$ROOT/usr/lib/forkop-support" ] && \
        [ ! -L "$ROOT/usr/lib/forkop-support/.forkop-lite" ] && \
        [ -f "$ROOT/usr/lib/forkop-support/.forkop-lite" ] && \
        grep -qx 'forkop-tailscale-lite' "$ROOT/usr/lib/forkop-support/.forkop-lite"; then
        rm -f "$ROOT/usr/lib/forkop-support/tailscale" "$ROOT/usr/lib/forkop-support/tailscaled" \
            "$ROOT/usr/lib/forkop-support/tailscale.combined" "$ROOT/usr/lib/forkop-support/.forkop-lite"
        rmdir "$ROOT/usr/lib/forkop-support" 2>/dev/null || true
    fi
    # Only known product paths are removed. Never recursively delete a path
    # supplied by a UCI option (it might point at /etc or other system data).
    # /tmp/xrust-rulesets holds the Rust X core's compiled rule-set cache;
    # cores before the rename used /tmp/tachyon-rulesets.
    for directory in /etc/forkop /etc/forkop-tailscale /etc/sing-box /tmp/sing-box /tmp/xrust-rulesets \
        /tmp/tachyon-rulesets /usr/lib/forkop /usr/share/forkop /www/luci-static/resources/view/forkop; do
        rm -rf "$ROOT$directory"
    done
    for file in /etc/config/forkop /etc/config/forkop.apk-new /etc/config/forkop.apk-old \
        /etc/config/forkop-opkg /etc/config/forkop.opkg-new /etc/config/forkop.opkg-old \
        /etc/config/forkop.opkg-dist /etc/config/sing-box /etc/config/sing-box.apk-new \
        /etc/config/sing-box.apk-old /etc/config/sing-box-opkg /etc/config/sing-box.opkg-new \
        /etc/config/sing-box.opkg-old /etc/config/sing-box.opkg-dist \
        /usr/bin/forkop /usr/bin/sing-box /usr/lib/libcronet.so \
        /etc/init.d/forkop /etc/init.d/sing-box /etc/init.d/forkop-torrserver-direct /etc/init.d/forkop-support /etc/init.d/forkop-tailscale \
        /etc/uci-defaults/50_luci-forkop \
        /usr/share/luci/menu.d/luci-app-forkop.json /usr/share/rpcd/acl.d/luci-app-forkop.json; do
        rm -f "$ROOT$file"
    done
    for file in "$ROOT"/usr/lib/lua/luci/i18n/forkop.* \
        "$ROOT"/tmp/luci-indexcache* "$ROOT"/tmp/luci-modulecache/*; do
        [ ! -f "$file" ] || rm -f "$file"
    done
    while IFS='|' read -r file source; do
        rm -f "${file}.pre-forkop-mirror"
    done < "$JOB/repositories"
    # Leave the component lock intact until finish() releases it.
    for item in "$ROOT"/var/run/forkop/*; do
        [ "$item" = "$COMPONENT_LOCK" ] || rm -rf "$item"
    done
    PHASE=complete
    state complete
}

case "${1:-}" in
    start)
        mkdir -p "$ROOT/tmp" "$ROOT/www" "$ROOT/var/run/forkop"
        if ! mkdir "$LOCK" 2>/dev/null; then
            echo '{"success":false,"message":"Removal is already running"}'
            exit 1
        fi
        if ! mkdir "$COMPONENT_LOCK" 2>/dev/null; then
            rmdir "$LOCK"
            echo '{"success":false,"message":"Another component action is running"}'
            exit 1
        fi
        trap 'rm -f "$LOCK/pid" "$COMPONENT_LOCK/pid"; rmdir "$LOCK" "$COMPONENT_LOCK" 2>/dev/null || true' EXIT
        printf '%s\n' "$$" > "$LOCK/pid"
        printf '%s\n' "$$" > "$COMPONENT_LOCK/pid"
        JOB="$(mktemp -d "$ROOT/tmp/forkop-uninstall.XXXXXX")"
        STATUS="$ROOT/www/$(basename "$JOB").json"
        cp "$0" "$JOB/worker.sh"
        state running
        sh "$JOB/worker.sh" worker "$JOB" "$STATUS" > "$JOB/output.log" 2>&1 </dev/null 1000>&- &
        trap - EXIT
        printf '{"success":true,"status_url":"/%s.json"}\n' "$(basename "$JOB")"
        ;;
    worker)
        JOB="$2"
        STATUS="$3"
        printf '%s\n' "$$" > "$LOCK/pid"
        printf '%s\n' "$$" > "$COMPONENT_LOCK/pid"
        run
        ;;
    *) exit 2 ;;
esac
