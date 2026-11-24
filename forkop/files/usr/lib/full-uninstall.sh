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
PACKAGES="luci-i18n-forkop-ru luci-app-forkop forkop"
PHASE=preflight

has_mirror() {
    grep -Fq "${MIRROR%/}/" "$1" || grep -Fq 'mirror.51343.ru/' "$1"
}

repository_plan() {
    : > "$JOB/repositories"
    rewrite="$ROOT/usr/share/forkop/mirror-migration.sh"
    [ -r "$rewrite" ] || return 0
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
        FORKOP_MIRROR_BASE_URL="$MIRROR" sh "$rewrite" --print-rewrite "$source" | cmp -s "$file" - ||
            FORKOP_MIRROR_BASE_URL=https://mirror.51343.ru sh "$rewrite" --print-rewrite "$source" | cmp -s "$file" - ||
            continue
        printf '%s|%s\n' "$file" "$source" >> "$JOB/repositories"
    done
}

remove_owned_apk_mirror_artifacts() {
    feed="$ROOT/etc/apk/repositories.d/forkop.list"
    [ -f "$feed" ] || return 0
    case "$(cat "$feed")" in
        "${MIRROR%/}"/forkop/mirror/current/packages.adb|\
        "${MIRROR%/}"/forkop/mirror/current/aarch64_cortex-a53/packages.adb|\
        "${MIRROR%/}"/forkop/mirror/current/x86_64/packages.adb)
            rm -f "$feed" "$ROOT/etc/apk/keys/forkop-mirror.pem"
            ;;
    esac
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

guard_owner_changes() {
    # Use the same permanent guard inode as core.locks for component owners.
    exec 9>>"$COMPONENT_LOCK.guard"
    if command -v flock >/dev/null 2>&1; then flock -x 9
    else busybox flock -x 9; fi
}

claim_lock() {
    local path="$1" pid modified
    if ! mkdir "$path" 2>/dev/null; then
        [ -d "$path" ] && [ ! -L "$path" ] &&
            [ "$(stat -c %u "$path")" = "$(id -u)" ] || return 1
        case "$(stat -c %a "$path")" in *[0145][0145]) ;; *) return 1 ;; esac
        [ ! -L "$path/pid" ] || return 1
        pid="$(cat "$path/pid" 2>/dev/null || true)"
        case "$pid" in
            '') # Keep the creation grace period used by older unguarded workers.
                modified="$(stat -c %Y "$path")" || return 1
                [ "$(($(date +%s) - modified))" -ge 5 ] || return 1 ;;
            0*|*[!0-9]*) ;;
            *) if kill -0 "$pid" 2>/dev/null; then return 1; fi ;;
        esac
    fi
    printf '%s\n' "$$" > "$path/pid"
}

release_owned_lock() {
    local path="$1"
    [ "$(cat "$path/pid" 2>/dev/null || true)" = "$$" ] || return 0
    rm -f "$path/pid"
    rmdir "$path" 2>/dev/null || true
}

finish() {
    code=$?
    trap - EXIT
    if [ "$code" -ne 0 ]; then state failed; fi
    guard_owner_changes
    release_owned_lock "$COMPONENT_LOCK"
    release_owned_lock "$LOCK"
    exec 9>&-
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
    if [ -x "$ROOT/etc/init.d/forkop" ]; then
        if ! FORKOP_INTERNAL_SERVICE_STOP=1 "$ROOT/etc/init.d/forkop" stop; then
            echo "Forkop service did not stop cleanly; removal stopped before deleting packages" >&2
            return 1
        fi
        "$ROOT/etc/init.d/forkop" disable || echo "Forkop service could not be disabled" >&2
    fi
    if [ -x "$ROOT/etc/init.d/forkop-tailscale" ]; then
        "$ROOT/etc/init.d/forkop-tailscale" stop || true
        "$ROOT/etc/init.d/forkop-tailscale" disable || true
    fi
    if [ -x "$ROOT/etc/init.d/forkop-support" ]; then
        "$ROOT/etc/init.d/forkop-support" stop || true
        "$ROOT/etc/init.d/forkop-support" disable || true
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
    # Shared cores and their directories have no exclusive Forkop ownership.
    # Remove only product paths, never a location supplied by a UCI option.
    for directory in /etc/forkop /etc/forkop-tailscale /usr/lib/forkop \
        /usr/share/forkop /www/luci-static/resources/view/forkop; do
        rm -rf "$ROOT$directory"
    done
    for file in /etc/config/forkop /etc/config/forkop.apk-new /etc/config/forkop.apk-old \
        /etc/config/forkop-opkg /etc/config/forkop.opkg-new /etc/config/forkop.opkg-old \
        /etc/config/forkop.opkg-dist /usr/bin/forkop \
        /etc/init.d/forkop /etc/init.d/forkop-xrust /etc/init.d/forkop-torrserver-direct /etc/init.d/forkop-support /etc/init.d/forkop-tailscale \
        /etc/uci-defaults/50_luci-forkop \
        /usr/share/luci/menu.d/luci-app-forkop.json /usr/share/rpcd/acl.d/luci-app-forkop.json; do
        rm -f "$ROOT$file"
    done
    for file in "$ROOT"/usr/lib/lua/luci/i18n/forkop.* \
        "$ROOT"/tmp/luci-indexcache* "$ROOT"/tmp/luci-modulecache/*; do
        [ ! -f "$file" ] || rm -f "$file"
    done
    if [ ! -L "$ROOT/etc/forkop-backups" ]; then
        rm -f "$ROOT/etc/forkop-backups/configuration.tar.gz"
        for file in "$ROOT"/etc/forkop-backups/forkop-before-xrust.??????; do
            [ -f "$file" ] && [ ! -L "$file" ] || continue
            case "${file##*.}" in *[!a-zA-Z0-9]*) continue ;; esac
            rm -f "$file"
        done
        rmdir "$ROOT/etc/forkop-backups" 2>/dev/null || true
    fi
    while IFS='|' read -r file source; do
        rm -f "${file}.pre-forkop-mirror"
    done < "$JOB/repositories"
    # Leave the component lock intact until finish() releases it.
    for item in "$ROOT"/var/run/forkop/*; do
        case "$item" in "$COMPONENT_LOCK"|"$COMPONENT_LOCK.guard") ;; *) rm -rf "$item" ;; esac
    done
    PHASE=complete
    state complete
}

case "${1:-}" in
    start)
        mkdir -p "$ROOT/tmp" "$ROOT/www" "$ROOT/var/run/forkop"
        guard_owner_changes
        if ! claim_lock "$LOCK"; then
            echo '{"success":false,"message":"Removal is already running"}'
            exit 1
        fi
        trap 'release_owned_lock "$COMPONENT_LOCK"; release_owned_lock "$LOCK"' EXIT
        if ! claim_lock "$COMPONENT_LOCK"; then
            echo '{"success":false,"message":"Another component action is running"}'
            exit 1
        fi
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
        # The inherited guard covers the parent-to-worker PID handover.
        printf '%s\n' "$$" > "$LOCK/pid"
        printf '%s\n' "$$" > "$COMPONENT_LOCK/pid"
        exec 9>&-
        run
        ;;
    *) exit 2 ;;
esac
