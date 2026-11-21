#!/bin/sh
set -eu

root_repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
recovery="$root_repo/forkop/files/usr/share/forkop/upgrade-recovery"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
PATH="$work/bin:$PATH"
export PATH

cat > "$work/bin/apk" <<'SH'
#!/bin/sh
set -eu
root="$FORKOP_PACKAGE_RECOVERY_ROOT"
case "$1" in
    --preserve-env) shift ;;
esac
case "$1" in
    list)
        name="$4"
        [ ! -f "$root/packages/$name" ] || printf '%s %s\n' "$name" "$(cat "$root/packages/$name")"
        ;;
    list-installed)
        name="$2"
        [ ! -f "$root/packages/$name" ] || printf '%s - %s\n' "$name" "$(cat "$root/packages/$name")"
        ;;
    del|remove)
        for name do :; done
        rm -f "$root/packages/$name"
        ;;
    add|install)
        [ -x "$FORKOP_INIT" ]
        for file do
            case "$file" in *.apk|*.ipk) ;; *) continue ;; esac
            read -r name version < "$file"
            printf '%s\n' "$name" >> "$root/install-order"
            if [ "${FAIL_PACKAGE:-}" = "$name" ]; then exit 1; fi
            printf '%s\n' "$version" > "$root/packages/$name"
            case "$name" in
                forkop) echo 'modified by postinst' > "$root/etc/config/forkop" ;;
            esac
        done
        ;;
    *) exit 1 ;;
esac
SH
chmod 700 "$work/bin/apk"
cp "$work/bin/apk" "$work/bin/opkg"

cat > "$work/bin/logger" <<'SH'
#!/bin/sh
exit 0
SH
cp "$work/bin/logger" "$work/bin/sync"
chmod 700 "$work/bin/logger" "$work/bin/sync"
cat > "$work/bin/jsonfilter" <<'SH'
#!/bin/sh
case "$2" in
    '@.running') cut -d: -f1 ;;
    '@.dns_configured') cut -d: -f2 ;;
    *) exit 1 ;;
esac
SH
chmod 700 "$work/bin/jsonfilter"

for manager_mode in apk:native opkg:native apk:legacy opkg:legacy; do
    manager="${manager_mode%:*}"
    mode="${manager_mode#*:}"
    root="$work/$manager-$mode"
    export FORKOP_PACKAGE_RECOVERY_ROOT="$root"
    state="$root/etc/forkop/upgrade-recovery"
    boot="$root/etc/rc.d/S98forkop-upgrade-recovery"
    mkdir -p "$root/etc/config" "$root/etc/init.d" "$root/usr/bin" "$root/usr/lib/rust-x" "$root/packages" "$root/staged"
    cat > "$root/etc/init.d/forkop" <<'SH'
#!/bin/sh
root="$FORKOP_PACKAGE_RECOVERY_ROOT"
case "$1" in
    enabled) [ -f "$root/enabled" ] ;;
    enable) touch "$root/enabled" ;;
    disable) rm -f "$root/enabled" ;;
    start) touch "$root/started" ;;
esac
SH
    cat > "$root/usr/bin/xrust" <<'SH'
#!/bin/sh
version="$(cat "$FORKOP_PACKAGE_RECOVERY_ROOT/packages/rust-x")"
printf 'xrust version %s\n' "${version%-*}"
SH
    cat > "$root/usr/lib/rust-x/sing-box" <<'SH'
#!/bin/sh
version="$(cat "$FORKOP_PACKAGE_RECOVERY_ROOT/packages/rust-x")"
printf 'sing-box version 1.14.2-rust-x.%s\n' "${version%-*}"
SH
    chmod 700 "$root/etc/init.d/forkop" "$root/usr/bin/xrust" "$root/usr/lib/rust-x/sing-box"
    printf 'previous user settings\n' > "$root/etc/config/forkop"
    tar -czf "$root/configuration.tar.gz" -C "$root/etc/config" forkop
    ext=ipk core=0.0.45-1
    if [ "$manager" = apk ]; then ext=apk core=0.0.45-r1; fi
    for name in rust-x luci-app-forkop forkop; do
        case "$name" in rust-x) version="$core" ;; *) version=3.0.0 ;; esac
        archive="$root/staged/$name.$ext"
        printf '%s %s\n' "$name" "$version" > "$archive"
        printf '%s\t%s\t%s\n' "$name" "$version" "$archive"
    done > "$root/plan"
    sh "$recovery" prepare "$manager" 1 "$core" "$root/configuration.tar.gz" "$root/etc/init.d/forkop" "$root/plan" "$mode"
    [ -L "$boot" ]
    # Simulate a discarded RAM stage and a mixed, interrupted package set.
    rm -rf "$root/staged"
    printf 'updated user settings\n' > "$root/etc/config/forkop"
    echo 3.0.1 > "$root/packages/forkop"
    echo 3.0.1 > "$root/packages/luci-i18n-forkop-ru"
    touch "$root/enabled"

    if [ "$manager_mode" = apk:native ]; then
        cp "$state/rust-x.$ext" "$root/original-package"
        echo 'corrupted' >> "$state/rust-x.$ext"
        if "$boot" boot; then
            echo 'A corrupt recovery archive was accepted' >&2
            exit 1
        fi
        [ -L "$boot" ] && [ ! -e "$root/install-order" ]
        cp "$root/original-package" "$state/rust-x.$ext"
        touch "$root/enabled"
    fi
    if FAIL_PACKAGE=forkop "$boot" boot; then
        echo 'A partial restore must leave boot recovery armed' >&2
        exit 1
    fi
    [ -L "$boot" ] && [ ! -e "$root/enabled" ]
    : > "$root/install-order"
    "$boot" boot
    [ ! -L "$boot" ] && [ ! -e "$state" ]
    [ -f "$root/enabled" ] && [ -f "$root/started" ]
    [ ! -e "$root/packages/luci-i18n-forkop-ru" ]
    grep -Fxq 'previous user settings' "$root/etc/config/forkop"
    printf '%s\n' rust-x luci-app-forkop forkop | cmp "$root/install-order" -
done
echo 'Interrupted Forkop package recovery passed for APK and IPK'

# The old backend may have already rolled back successfully. Verify the
# existing state without re-installing packages or writing configuration.
for manager in apk opkg; do
    root="$work/$manager-legacy"
    export FORKOP_PACKAGE_RECOVERY_ROOT="$root"
    state="$root/etc/forkop/upgrade-recovery"
    boot="$root/etc/rc.d/S98forkop-upgrade-recovery"
    core="$(cat "$root/packages/rust-x")"
    mkdir -p "$root/staged"
    while IFS="$(printf '\t')" read -r name version archive; do
        printf '%s %s\n' "$name" "$version" > "$archive"
    done < "$root/plan"
    cat > "$root/usr/bin/forkop" <<'SH'
#!/bin/sh
cat "$FORKOP_PACKAGE_RECOVERY_ROOT/status"
SH
    chmod 700 "$root/usr/bin/forkop"
    sh "$recovery" prepare "$manager" 1 "$core" "$root/configuration.tar.gz" "$root/etc/init.d/forkop" "$root/plan" legacy 1
    echo '1:0' > "$root/status"
    if "$boot" commit-restored; then exit 1; fi
    [ -L "$boot" ]
    echo '1:1' > "$root/status"
    echo changed > "$root/etc/config/forkop"
    if "$boot" commit-restored; then exit 1; fi
    [ -L "$boot" ]
    tar -xOzf "$root/configuration.tar.gz" forkop > "$root/etc/config/forkop"
    echo 3.0.1 > "$root/packages/luci-app-forkop"
    if "$boot" commit-restored; then exit 1; fi
    [ -L "$boot" ]
    echo 3.0.0 > "$root/packages/luci-app-forkop"
    : > "$root/install-order"
    "$boot" commit-restored
    [ ! -L "$boot" ] && [ ! -e "$state" ] && [ ! -s "$root/install-order" ]
done
echo 'Verified in-process rollback clears boot recovery without replay (APK and IPK)'
