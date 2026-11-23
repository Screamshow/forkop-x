#!/bin/sh
set -eu
REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$REPO/forkop/files/usr/lib/full-uninstall.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fixture() {
    ROOT="$WORK/$1"
    mkdir -p "$ROOT/etc/opkg" "$ROOT/usr/bin" "$ROOT/bin" "$ROOT/packages" \
        "$ROOT/etc/forkop" "$ROOT/etc/sing-box" "$ROOT/etc/xrust" "$ROOT/etc/config" "$ROOT/etc/init.d" \
        "$ROOT/usr/lib/forkop/torrserver" "$ROOT/tmp/xrust-rulesets" "$ROOT/tmp/tachyon-rulesets"
    mkdir -p "$ROOT/usr/share/forkop" "$ROOT/etc/forkop-backups"
    cp "$REPO/forkop/files/usr/share/forkop/mirror-migration.sh" "$ROOT/usr/share/forkop/"
    printf 'src/gz base https://vendor.example.test/releases/24.10.2/packages/x86/base\n' > "$ROOT/etc/opkg/distfeeds.conf.pre-forkop-mirror"
    printf 'src/gz base https://mirror.51343.ru/openwrt/releases/24.10.2/packages/x86/base\n' > "$ROOT/etc/opkg/distfeeds.conf"
    printf 'managed configuration backup\n' > "$ROOT/etc/forkop-backups/configuration.tar.gz"
    printf 'user backup\n' > "$ROOT/etc/forkop-backups/manual.tar.gz"
    printf 'wifi configuration\n' > "$ROOT/etc/config/wireless"
    touch "$ROOT/etc/config/wireless.apk-new"
    touch "$ROOT/etc/config/forkop.apk-new" "$ROOT/etc/config/forkop.apk-old" \
        "$ROOT/etc/config/forkop-opkg" "$ROOT/etc/config/forkop.opkg-new" \
        "$ROOT/etc/config/forkop.opkg-old" "$ROOT/etc/config/forkop.opkg-dist"
    touch "$ROOT/etc/config/sing-box.apk-new" "$ROOT/etc/config/sing-box.apk-old" \
        "$ROOT/etc/config/sing-box-opkg" "$ROOT/etc/config/sing-box.opkg-new" \
        "$ROOT/etc/config/sing-box.opkg-old" "$ROOT/etc/config/sing-box.opkg-dist"
    touch "$ROOT/etc/forkop/secret" "$ROOT/usr/lib/forkop/test" \
        "$ROOT/usr/lib/forkop/torrserver/direct.uc" "$ROOT/etc/config/forkop"
    for file in etc/sing-box/config.json etc/xrust/config.json etc/config/sing-box usr/bin/sing-box usr/bin/xrust \
        tmp/xrust-rulesets/main-remote-domains-ruleset.tsrs tmp/tachyon-rulesets/main-remote-domains-ruleset.tsrs; do
        printf 'independent core data\n' > "$ROOT/$file"
    done
    touch "$ROOT/packages/forkop" "$ROOT/packages/luci-app-forkop" "$ROOT/packages/sing-box" \
        "$ROOT/packages/sing-box-x" "$ROOT/packages/sing-box-tiny" \
        "$ROOT/packages/sing-box-extended" "$ROOT/packages/rust-x"
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
    cat > "$ROOT/etc/init.d/forkop" <<'SH'
#!/bin/sh
if [ "$1" = stop ]; then
    printf 'forkop stop internal=%s\n' "${FORKOP_INTERNAL_SERVICE_STOP:-0}" >> "$FORKOP_UNINSTALL_ROOT/service-calls"
    [ "${FORKOP_INTERNAL_SERVICE_STOP:-0}" = 1 ] || exit 2
    exit "${FAIL_MANAGED_STOP:-0}"
fi
SH
    cat > "$ROOT/etc/init.d/sing-box" <<'SH'
#!/bin/sh
printf 'standalone sing-box %s\n' "$1" >> "$FORKOP_UNINSTALL_ROOT/service-calls"
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
        "$ROOT/etc/init.d/forkop" "$ROOT/etc/init.d/forkop-torrserver-direct" "$ROOT/etc/init.d/forkop-support" \
        "$ROOT/etc/init.d/sing-box" "$ROOT/bin/opkg"
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
    for package in rust-x sing-box sing-box-x sing-box-tiny sing-box-extended; do
        [ -f "$ROOT/packages/$package" ]
    done
    for file in etc/sing-box/config.json etc/xrust/config.json etc/config/sing-box usr/bin/sing-box usr/bin/xrust \
        tmp/xrust-rulesets/main-remote-domains-ruleset.tsrs tmp/tachyon-rulesets/main-remote-domains-ruleset.tsrs; do
        grep -qx 'independent core data' "$ROOT/$file"
    done
    [ -x "$ROOT/etc/init.d/sing-box" ]
    if grep -q 'standalone sing-box' "$ROOT/service-calls" 2>/dev/null; then
        echo 'Independent sing-box received a service command' >&2
        return 1
    fi
    if [ "$1" = complete ]; then [ ! -e "$ROOT/usr/lib/forkop-support" ]; fi
}

fixture opkg
run_case complete
grep -Fq 'https://vendor.example.test/releases/24.10.2/' "$ROOT/etc/opkg/distfeeds.conf"
[ ! -f "$ROOT/etc/forkop-backups/configuration.tar.gz" ]
grep -qx 'user backup' "$ROOT/etc/forkop-backups/manual.tar.gz"
[ ! -e "$ROOT/usr/lib/forkop" ] && [ ! -e "$ROOT/etc/forkop" ]
[ ! -e "$ROOT/packages/forkop" ]
grep -qx 'wifi configuration' "$ROOT/etc/config/wireless"
[ -e "$ROOT/etc/config/wireless.apk-new" ]
for file in forkop.apk-new forkop.apk-old forkop-opkg forkop.opkg-new forkop.opkg-old \
    forkop.opkg-dist; do
    [ ! -e "$ROOT/etc/config/$file" ]
done
for file in sing-box.apk-new sing-box.apk-old sing-box-opkg sing-box.opkg-new sing-box.opkg-old sing-box.opkg-dist; do
    [ -f "$ROOT/etc/config/$file" ]
done
grep -qx dnsmasq_restore "$ROOT/service-calls"
grep -qx 'forkop stop internal=1' "$ROOT/service-calls"
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
printf 'src/gz extra https://packages.vendor.example/added\n' >> "$ROOT/etc/opkg/distfeeds.conf"
vendor_hash="$(sha256sum "$ROOT/etc/opkg/customfeeds.conf" | awk '{print $1}')"
run_case complete
grep -Fq 'https://packages.vendor.example/added' "$ROOT/etc/opkg/distfeeds.conf"
[ -f "$ROOT/etc/opkg/distfeeds.conf.pre-forkop-mirror" ]
[ "$vendor_hash" = "$(sha256sum "$ROOT/etc/opkg/customfeeds.conf" | awk '{print $1}')" ] || {
    echo 'custom vendor feed was modified' >&2; exit 1;
}

fixture rom_fallback
rm "$ROOT/etc/opkg/distfeeds.conf.pre-forkop-mirror"
mkdir -p "$ROOT/rom/etc/opkg"
printf 'firmware repositories\n' > "$ROOT/rom/etc/opkg/distfeeds.conf"
run_case complete
grep -Fq 'mirror.51343.ru' "$ROOT/etc/opkg/distfeeds.conf"

fixture failed_stop
FAIL_MANAGED_STOP=2 run_case failed
for file in packages/forkop usr/lib/forkop/test etc/config/forkop; do
    [ -e "$ROOT/$file" ]
done
grep -Fq 'Forkop service did not stop cleanly' "$ROOT"/tmp/forkop-uninstall.*/output.log

fixture failed_batch
FAIL_BATCH=1 run_case complete
[ ! -e "$ROOT/packages/forkop" ] && [ ! -e "$ROOT/usr/lib/forkop/test" ]
grep -Fq 'Batch removal failed' "$ROOT"/tmp/forkop-uninstall.*/output.log

fixture failed_package
FAIL_PACKAGE=forkop run_case failed
[ -e "$ROOT/packages/forkop" ] && [ -e "$ROOT/usr/lib/forkop/test" ]
[ -e "$ROOT/packages/rust-x" ]
grep -Fq 'Packages were not removed: forkop' "$ROOT"/tmp/forkop-uninstall.*/output.log

fixture failed_dns_restore
FAIL_DNS_RESTORE=1 run_case failed
[ -e "$ROOT/packages/forkop" ] && [ -e "$ROOT/usr/lib/forkop/test" ]

fixture apk
mkdir -p "$ROOT/etc/apk/repositories.d" "$ROOT/etc/apk/keys"
printf 'https://mirror.51343.ru/openwrt/releases/25.12.2/packages/x86/base\n' > "$ROOT/etc/apk/repositories.d/distfeeds.list"
printf 'https://vendor.example.test/releases/25.12.2/packages/x86/base\n' > "$ROOT/etc/apk/repositories.d/distfeeds.list.pre-forkop-mirror"
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
grep -qx 'https://vendor.example.test/releases/25.12.2/packages/x86/base' "$ROOT/etc/apk/repositories.d/distfeeds.list"
[ ! -e "$ROOT/etc/apk/repositories.d/forkop.list" ] && [ ! -e "$ROOT/etc/apk/keys/forkop-mirror.pem" ]
printf 'Full uninstall checks passed\n'

fixture mixed_apk
mkdir -p "$ROOT/etc/apk/repositories.d" "$ROOT/etc/apk/keys"
printf '%s\n' https://mirror.51343.ru/forkop/mirror/current/packages.adb https://vendor.example.test/user-feed \
    > "$ROOT/etc/apk/repositories.d/forkop.list"
touch "$ROOT/etc/apk/keys/forkop-mirror.pem"
run_case complete
grep -qx 'https://vendor.example.test/user-feed' "$ROOT/etc/apk/repositories.d/forkop.list"
[ -f "$ROOT/etc/apk/keys/forkop-mirror.pem" ]

# Even if the host has apk/opkg, a fixture must fail without its own manager.
fixture missing_manager
rm -f "$ROOT/bin/opkg"
run_case failed
[ -e "$ROOT/packages/forkop" ]
printf 'Missing fixture manager safely rejected\n'

if command -v ucode >/dev/null 2>&1; then
    lifecycle="$REPO/forkop/files/usr/lib/service/lifecycle.uc"
    cat > "$WORK/legacy-uninstall.uc" <<'UCODE'
const SERVICE_INIT = "/fixture/forkop";
const fs = { stat: () => ({}) };
let calls = [];
let first_stop_status = 7;
function log_message() {}
function stop_impl(unrestricted) {
    if (unrestricted !== false)
        die("Legacy uninstall requested an unrestricted stop");
    return first_stop_status;
}
function command_success_from_args(args) {
    push(calls, join(" ", args));
    return false;
}
UCODE
    awk '/^function uninstall\(\)/ { copying=1 } copying { print } copying && /^}/ { exit }' \
        "$lifecycle" >> "$WORK/legacy-uninstall.uc"
    cat >> "$WORK/legacy-uninstall.uc" <<'UCODE'
if (uninstall() != 7 || length(calls) != 0)
    die("Legacy uninstall continued after managed stop failed");
first_stop_status = 0;
if (uninstall() != 1 || length(calls) != 1 ||
    calls[0] != "env FORKOP_INTERNAL_SERVICE_STOP=1 /etc/init.d/forkop stop")
    die("Legacy uninstall continued after the canonical managed stop failed");
UCODE
    ucode "$WORK/legacy-uninstall.uc"
fi
