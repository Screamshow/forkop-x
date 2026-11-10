#!/bin/sh
set -eu
REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$REPO/forkop/files/usr/lib/full-uninstall.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fixture() {
    ROOT="$WORK/$1"
    mkdir -p "$ROOT/etc/opkg" "$ROOT/usr/bin" "$ROOT/bin" "$ROOT/packages" \
        "$ROOT/etc/forkop" "$ROOT/etc/sing-box" "$ROOT/etc/config" "$ROOT/etc/init.d" \
        "$ROOT/usr/lib/forkop/torrserver" "$ROOT/tmp/xrust-rulesets" "$ROOT/tmp/tachyon-rulesets"
    printf 'original vendor repositories\n' > "$ROOT/etc/opkg/distfeeds.conf.pre-forkop-mirror"
    printf 'https://mirror.51343.ru/openwrt/releases/test\n' > "$ROOT/etc/opkg/distfeeds.conf"
    printf 'wifi configuration\n' > "$ROOT/etc/config/wireless"
    touch "$ROOT/etc/config/wireless.apk-new"
    touch "$ROOT/etc/config/forkop.apk-new" "$ROOT/etc/config/forkop.apk-old" \
        "$ROOT/etc/config/forkop-opkg" "$ROOT/etc/config/forkop.opkg-new" \
        "$ROOT/etc/config/forkop.opkg-old" "$ROOT/etc/config/forkop.opkg-dist"
    touch "$ROOT/etc/config/sing-box.apk-new" "$ROOT/etc/config/sing-box.apk-old" \
        "$ROOT/etc/config/sing-box-opkg" "$ROOT/etc/config/sing-box.opkg-new" \
        "$ROOT/etc/config/sing-box.opkg-old" "$ROOT/etc/config/sing-box.opkg-dist"
    touch "$ROOT/etc/forkop/secret" "$ROOT/etc/sing-box/config.json" "$ROOT/usr/lib/forkop/test" \
        "$ROOT/usr/lib/forkop/torrserver/direct.uc" "$ROOT/usr/bin/sing-box"
    touch "$ROOT/packages/forkop" "$ROOT/packages/luci-app-forkop" "$ROOT/packages/sing-box" \
        "$ROOT/packages/sing-box-tiny" "$ROOT/packages/sing-box-extended" "$ROOT/packages/rust-x" \
        "$ROOT/tmp/xrust-rulesets/main-remote-domains-ruleset.tsrs" \
        "$ROOT/tmp/tachyon-rulesets/main-remote-domains-ruleset.tsrs"
    cat > "$ROOT/usr/bin/forkop" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$FORKOP_UNINSTALL_ROOT/service-calls"
exit "${FAIL_DNS_RESTORE:-0}"
SH
    cat > "$ROOT/etc/init.d/forkop-torrserver-direct" <<'SH'
#!/bin/sh
printf 'torrserver-direct %s\n' "$1" >> "$FORKOP_UNINSTALL_ROOT/service-calls"
SH
    cat > "$ROOT/etc/init.d/forkop-support" <<'SH'
#!/bin/sh
printf 'support %s\n' "$1" >> "$FORKOP_UNINSTALL_ROOT/service-calls"
SH
    printf 'user Tailscale installation\n' > "$ROOT/etc/init.d/tailscale"
    mkdir -p "$ROOT/usr/lib/forkop-support" "$ROOT/usr/sbin" "$ROOT/etc/tailscale" "$ROOT/etc/rc.d"
    printf 'forkop-tailscale-lite\n' > "$ROOT/usr/lib/forkop-support/.forkop-lite"
    printf 'Lite binary\n' > "$ROOT/usr/lib/forkop-support/tailscale.combined"
    ln -s tailscale.combined "$ROOT/usr/lib/forkop-support/tailscale"
    ln -s tailscale.combined "$ROOT/usr/lib/forkop-support/tailscaled"
    for file in usr/bin/tailscale usr/sbin/tailscaled etc/config/tailscale etc/tailscale/tailscaled.state packages/tailscale; do
        printf 'customer Tailscale data\n' > "$ROOT/$file"
    done
    ln -s ../init.d/tailscale "$ROOT/etc/rc.d/S80tailscale"
    cat > "$ROOT/usr/bin/ucode" <<'SH'
#!/bin/sh
printf 'torrserver-direct-rule %s\n' "$*" >> "$FORKOP_UNINSTALL_ROOT/service-calls"
SH
    cat > "$ROOT/bin/opkg" <<'SH'
#!/bin/sh
case "$1" in
 status) [ -e "$FORKOP_UNINSTALL_ROOT/packages/$2" ] && echo 'Status: install ok installed';;
 remove)
  shift
  if [ "${FAIL_BATCH:-0}" = 1 ] && [ "$#" -gt 1 ]; then exit 1; fi
  for p in "$@"; do [ "$p" != "${FAIL_PACKAGE:-}" ] || exit 1; done
  for p in "$@"; do rm -f "$FORKOP_UNINSTALL_ROOT/packages/$p"; done;;
 *) exit 1;;
esac
SH
    chmod +x "$ROOT/usr/bin/forkop" "$ROOT/usr/bin/ucode" \
        "$ROOT/etc/init.d/forkop-torrserver-direct" "$ROOT/etc/init.d/forkop-support" "$ROOT/bin/opkg"
}

run_case() {
    FORKOP_UNINSTALL_ROOT="$ROOT" PATH="$ROOT/bin:$PATH" sh "$SCRIPT" start > "$ROOT/response"
    count=0
    while :; do
        status="$(cat "$ROOT"/www/forkop-uninstall.*.json)"
        case "$status" in *'"state":"complete"'*|*'"state":"failed"'*) break;; esac
        count=$((count+1))
        [ "$count" -lt 20 ] || { echo 'worker timed out'; exit 1; }
        sleep 1
    done
    printf '%s\n' "$status" | grep -q "\"state\":\"$1\""
    for file in usr/bin/tailscale usr/sbin/tailscaled etc/config/tailscale etc/tailscale/tailscaled.state packages/tailscale; do
        grep -qx 'customer Tailscale data' "$ROOT/$file"
    done
    [ -L "$ROOT/etc/rc.d/S80tailscale" ]
    if [ "$1" = complete ]; then [ ! -e "$ROOT/usr/lib/forkop-support" ]; fi
}

fixture opkg
run_case complete
grep -qx 'original vendor repositories' "$ROOT/etc/opkg/distfeeds.conf"
[ ! -e "$ROOT/usr/lib/forkop" ] && [ ! -e "$ROOT/etc/forkop" ] && [ ! -e "$ROOT/etc/sing-box" ]
[ ! -e "$ROOT/packages/forkop" ]
[ ! -e "$ROOT/packages/sing-box" ] && [ ! -e "$ROOT/packages/sing-box-tiny" ] && \
    [ ! -e "$ROOT/packages/sing-box-extended" ]
# The Rust X core package and its RAM rule-set cache (current and pre-rename
# location) are removed too.
[ ! -e "$ROOT/packages/rust-x" ] && [ ! -e "$ROOT/tmp/xrust-rulesets" ] && \
    [ ! -e "$ROOT/tmp/tachyon-rulesets" ]
[ ! -e "$ROOT/usr/bin/sing-box" ]
grep -qx 'wifi configuration' "$ROOT/etc/config/wireless"
[ -e "$ROOT/etc/config/wireless.apk-new" ]
for file in forkop.apk-new forkop.apk-old forkop-opkg forkop.opkg-new forkop.opkg-old \
    forkop.opkg-dist sing-box.apk-new sing-box.apk-old sing-box-opkg sing-box.opkg-new \
    sing-box.opkg-old sing-box.opkg-dist; do
    [ ! -e "$ROOT/etc/config/$file" ]
done
grep -qx dnsmasq_restore "$ROOT/service-calls"
grep -qx 'torrserver-direct stop' "$ROOT/service-calls"
grep -qx 'torrserver-direct disable' "$ROOT/service-calls"
grep -qx 'support stop' "$ROOT/service-calls"
[ ! -e "$ROOT/etc/init.d/forkop-support" ]
grep -qx 'user Tailscale installation' "$ROOT/etc/init.d/tailscale"
grep -Fq 'torrserver-direct-rule ' "$ROOT/service-calls"
grep -Fq 'torrserver/direct.uc remove' "$ROOT/service-calls"
[ ! -e "$ROOT/etc/init.d/forkop-torrserver-direct" ]

fixture missing_backup
rm "$ROOT/etc/opkg/distfeeds.conf.pre-forkop-mirror"
run_case complete
# A legacy mirror file without a Forkop-created backup is not guessed back to
# /rom. Package removal remains safe and the unknown repository is untouched.
grep -Fq 'mirror.51343.ru' "$ROOT/etc/opkg/distfeeds.conf"

fixture native_vendor
printf 'src/gz vendor https://packages.vendor.example/custom\n' > "$ROOT/etc/opkg/customfeeds.conf"
vendor_hash="$(sha256sum "$ROOT/etc/opkg/customfeeds.conf" | awk '{print $1}')"
run_case complete
[ "$vendor_hash" = "$(sha256sum "$ROOT/etc/opkg/customfeeds.conf" | awk '{print $1}')" ] || {
    echo 'custom vendor feed was modified' >&2; exit 1;
}

fixture rom_fallback
rm "$ROOT/etc/opkg/distfeeds.conf.pre-forkop-mirror"
mkdir -p "$ROOT/rom/etc/opkg"
printf 'firmware repositories\n' > "$ROOT/rom/etc/opkg/distfeeds.conf"
run_case complete
grep -Fq 'mirror.51343.ru' "$ROOT/etc/opkg/distfeeds.conf"

fixture failed_stop_and_batch
cat > "$ROOT/etc/init.d/forkop" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$ROOT/etc/init.d/forkop"
FAIL_BATCH=1 run_case complete
[ ! -e "$ROOT/packages/forkop" ] && [ ! -e "$ROOT/usr/lib/forkop/test" ]
grep -Fq 'Forkop service did not stop cleanly' "$ROOT"/tmp/forkop-uninstall.*/output.log

fixture failed_package
FAIL_PACKAGE=forkop run_case failed
[ -e "$ROOT/packages/forkop" ] && [ -e "$ROOT/usr/lib/forkop/test" ]
[ ! -e "$ROOT/packages/rust-x" ]
grep -Fq 'Packages were not removed: forkop' "$ROOT"/tmp/forkop-uninstall.*/output.log

fixture failed_dns_restore
FAIL_DNS_RESTORE=1 run_case failed
[ -e "$ROOT/packages/forkop" ] && [ -e "$ROOT/usr/lib/forkop/test" ]

fixture apk
mkdir -p "$ROOT/etc/apk/repositories.d" "$ROOT/etc/apk/keys"
printf 'https://mirror.51343.ru/openwrt/releases/test\n' > "$ROOT/etc/apk/repositories.d/distfeeds.list"
printf 'original apk repositories\n' > "$ROOT/etc/apk/repositories.d/distfeeds.list.pre-forkop-mirror"
printf 'https://mirror.51343.ru/forkop/mirror/current/packages.adb\n' > "$ROOT/etc/apk/repositories.d/forkop.list"
touch "$ROOT/etc/apk/keys/forkop-mirror.pem"
cat > "$ROOT/bin/apk" <<'SH'
#!/bin/sh
case "$1" in
 info) test -f "$FORKOP_UNINSTALL_ROOT/packages/$3";;
 del) shift; for p in "$@"; do rm -f "$FORKOP_UNINSTALL_ROOT/packages/$p"; done;;
 *) exit 1;;
esac
SH
chmod +x "$ROOT/bin/apk"
run_case complete
grep -qx 'original apk repositories' "$ROOT/etc/apk/repositories.d/distfeeds.list"
[ ! -e "$ROOT/etc/apk/repositories.d/forkop.list" ] && [ ! -e "$ROOT/etc/apk/keys/forkop-mirror.pem" ]
printf 'Full uninstall checks passed\n'

# Even if the host has apk/opkg, a fixture must fail without its own manager.
fixture missing_manager
rm -f "$ROOT/bin/opkg"
run_case failed
[ -e "$ROOT/packages/forkop" ]
printf 'Missing fixture manager safely rejected\n'
