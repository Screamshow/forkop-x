#!/bin/sh
verify_forkop_pin() {
    [ -z "${IPKG_INSTROOT:-}" ] || return 0

    root="${FORKOP_PREINST_ROOT:-}"
    pin="@XRUST_VERSION@"
    revision="@XRUST_REVISION@"
    expected_forkop="@FORKOP_VERSION@"
    if [ -r "$root/lib/apk/db/installed" ] || { [ -z "$root" ] && command -v apk >/dev/null 2>&1; }; then
        expected_core="$pin-r$revision"
        installed="$(awk -F: '
            /^P:/ { package = $2 }
            /^V:/ && package == "rust-x" { print $2; exit }
        ' "$root/lib/apk/db/installed" 2>/dev/null)"
    else
        expected_core="$pin-$revision"
        installed="$(awk -F '\n' '
            BEGIN { RS = "" }
            /(^|\n)Package: rust-x(\n|$)/ && /(^|\n)Status: [^\n]* installed(\n|$)/ {
                for (i = 1; i <= NF; i++) if ($i ~ /^Version: /) {
                    sub(/^Version: /, "", $i); print $i; exit
                }
            }
        ' "$root/usr/lib/opkg/status" 2>/dev/null)"
    fi

    if [ "$installed" = "$expected_core" ] &&
        banner="$("$root/usr/bin/xrust" version 2>/dev/null)" &&
        [ "$(printf '%s\n' "$banner" | head -n 1)" = "xrust version $pin" ]; then
        return 0
    fi

    # APK may run the Forkop hook before unpacking the core in a rollback.
    # Accept only the exact pair in the checked, explicitly invoked journal.
    if [ "${FORKOP_PACKAGE_RECOVERY:-}" = 1 ] &&
        "$root/etc/rc.d/S98forkop-upgrade-recovery" verify-preinst "$expected_forkop" "$expected_core"; then
        return 0
    fi

    printf '%s\n' "Forkop 3 requires native Xrust $expected_core. Run the official Forkop installer to upgrade the packages together: https://mirror.51343.ru/forkop/install.sh" >&2
    # opkg has already run the old prerm. Its abort path does not run postinst.
    if [ "${PKG_UPGRADE:-}" = 1 ] && [ "${1:-}" = upgrade ] && [ -x "$root/usr/bin/forkop" ]; then
        FORKOP_LIB="$root/usr/lib/forkop" "$root/usr/bin/forkop" package_postinst ||
            printf '%s\n' 'Could not restore the previous Forkop service. Check the Forkop log.' >&2
    fi
    return 1
}
verify_forkop_pin "$@" || exit $?
