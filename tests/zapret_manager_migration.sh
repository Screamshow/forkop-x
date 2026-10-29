#!/bin/sh
# Root-only sandbox tests. No host service or configuration is modified.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
box=$work/root
mkdir -p "$box/bin" "$box/lib" "$box/usr/bin" "$box/tmp" "$box/etc/init.d"
mkdir -p "$box/usr/lib/ucode"
mkdir -p "$box/dev"
: > "$box/dev/null"
cp /bin/busybox "$box/bin/"
cp -L /lib/libc.so "$box/lib/libc.so"
cp -L /lib/libgcc_s.so.1 "$box/lib/"
for loader in /lib/ld-musl-*.so.1; do cp -L "$loader" "$box/lib/"; done
for applet in sh cat grep sed head mktemp chmod rm tar cp mkdir sleep; do ln -s busybox "$box/bin/$applet"; done
cp /usr/bin/ucode "$box/usr/bin/"
cp -L /usr/lib/libucode.so.* /usr/lib/libjson-c.so.* "$box/usr/lib/"
cp /usr/lib/ucode/fs.so "$box/usr/lib/ucode/"
: > "$box/usr/lib/uhttpd_ubus.so"
cp "$ROOT/forkop/files/usr/share/forkop/zapret-manager-migrate.sh" "$box/migrate"
cat > "$box/usr/bin/curl" <<'EOF'
#!/bin/sh
echo "$*" >> /downloads
case "$TEST_SCENARIO:$*" in downloadfail:*|fallback:*mirror.test*) exit 1 ;; esac
for last; do :; done
cp /fixture "$last"
EOF
cat > "$box/usr/bin/ubus" <<'EOF'
#!/bin/sh
[ "$TEST_SCENARIO" != rpcfail ] || ! grep -q forkop-five-section-v1 /opt/zapret-manager-luci/backend.sh || exit 1
echo '{"dots":{}}'
EOF
chmod 0755 "$box/usr/bin/"*
for svc in rpcd uhttpd cron; do printf '#!/bin/sh\nexit 0\n' > "$box/etc/init.d/$svc"; chmod 0755 "$box/etc/init.d/$svc"; done
cat > "$box/fixture" <<'EOF'
#!/bin/sh
# Version: 4.71.1
# Forkop-Manager-Contract: five-section-v1
mkdir -p /opt/zapret-manager-luci /usr/libexec/rpcd /www/luci-static/resources/view/zapret-manager /www/zm /usr/share/luci/menu.d /usr/share/rpcd/acl.d
cat > /opt/zapret-manager-luci/backend.sh <<'BACKEND'
#!/bin/sh
ZM_VERSION="4.71.1"
ZM_FLAVOR="forkop-five-section-v1"
ZM_SCRIPT_URL="https://raw.githubusercontent.com/Screamshow/Zapret-Manager/main/ZapretManager_LuCI.sh"
BACKEND
[ "$TEST_SCENARIO" != installfail ] || exit 1
printf '#!/bin/sh\n' > /usr/libexec/rpcd/zapret-manager
chmod 0755 /usr/libexec/rpcd/zapret-manager /opt/zapret-manager-luci/backend.sh
echo '{}' > /usr/share/luci/menu.d/luci-app-zapret-manager.json
echo '' > /www/zm/app.js
ucode -e 'let fs=require("fs"),m={}; for(let page in ["dashboard","strategy","zapret2","hosts","terminal"]) m["admin/services/zapret-manager/"+page]={}; fs.writefile("/usr/share/luci/menu.d/luci-app-zapret-manager.json",sprintf("%J",m));'
for page in dashboard strategy zapret2 hosts terminal; do
    echo page > "/www/luci-static/resources/view/zapret-manager/$page.js"
    echo "{ id: '$page' }" >> /www/zm/app.js
done
for file in /www/zm/app.css /www/zm-webui.html /usr/share/rpcd/acl.d/luci-app-zapret-manager.json; do echo payload > "$file"; done
EOF
run() { TEST_SCENARIO=$1 chroot "$box" /bin/sh /migrate "$2" https://mirror.test; }
mkdir -p "$box/etc/config" "$box/etc/crontabs"
for file in config/zapret config/zapret2 config/uhttpd hosts crontabs/root; do echo "preserve $file" > "$box/etc/$file"; done
find "$box/etc" -type f -exec sha256sum {} \; | sort > "$work/settings.sha"
# No manager: no network or installation on package upgrade.
run normal migrate
[ ! -e "$box/downloads" ]
# Lower, equal and higher upstream versions must all migrate by provenance.
for version in 4.0 4.71.1 99.0; do
    rm -rf "$box/opt" "$box/usr/libexec" "$box/www" "$box/usr/share"
    mkdir -p "$box/opt/zapret-manager-luci"
    printf 'ZM_VERSION="%s"\nZM_SCRIPT_URL="https://raw.githubusercontent.com/StressOzz/Zapret-Manager/main/ZapretManager_LuCI.sh"\n' "$version" > "$box/opt/zapret-manager-luci/backend.sh"
    for name in zms zmsA zmw; do printf '#!/bin/sh\nsh <(wget -q -O - https://raw.githubusercontent.com/StressOzz/Zapret-Manager/main/Zapret-Manager.sh)\n' > "$box/usr/bin/$name"; done
    run fallback migrate
    grep -q Screamshow "$box/usr/bin/zmw"
    before=$(wc -l < "$box/downloads")
    run normal migrate
    [ "$before" = "$(wc -l < "$box/downloads")" ]
    # Explicit install may check upstream but must not replace an equal build.
    run normal install
    [ "$before" -lt "$(wc -l < "$box/downloads")" ]
done
# A newer healthy fork with a missing launcher is repaired offline, retaining
# both backend contents and version even when public sources are unavailable.
sed -i 's/4.71.1/99.0/g' "$box/opt/zapret-manager-luci/backend.sh"
rm "$box/usr/bin/zmsA"
before=$(wc -l < "$box/downloads")
run downloadfail migrate
[ "$before" = "$(wc -l < "$box/downloads")" ]
grep -q 'ZM_VERSION="99.0"' "$box/opt/zapret-manager-luci/backend.sh"
[ -x "$box/usr/bin/zmsA" ]
# Partial panel, exact rollback of old source, launchers, modes and settings.
snapshot_content() {
    find "$box/opt" "$box/etc" "$box/www" "$box/usr/share" "$box/usr/libexec" \
        "$box/usr/bin/zms" "$box/usr/bin/zmsA" "$box/usr/bin/zmw" \
        -type f -exec sha256sum {} \; | sort
}
for scenario in missingdependency downloadfail installfail rpcfail; do
    printf 'ZM_VERSION="4.71"\nZM_SCRIPT_URL="https://raw.githubusercontent.com/StressOzz/Zapret-Manager/main/ZapretManager_LuCI.sh"\n' > "$box/opt/zapret-manager-luci/backend.sh"
    chmod 0700 "$box/opt/zapret-manager-luci/backend.sh"
    tar -cpf "$work/before.tar" -C "$box" opt usr/bin/zms usr/bin/zmsA usr/bin/zmw etc
    snapshot_content > "$work/content.before"
    if [ "$scenario" = missingdependency ]; then rm "$box/usr/lib/uhttpd_ubus.so"; fi
    if run "$scenario" migrate; then echo "Unexpected success: $scenario"; exit 1; fi
    tar -cpf "$work/after.tar" -C "$box" opt usr/bin/zms usr/bin/zmsA usr/bin/zmw etc
    tar -tvf "$work/before.tar" | sort > "$work/before.list"
    tar -tvf "$work/after.tar" | sort > "$work/after.list"
    cmp "$work/before.list" "$work/after.list"
    snapshot_content > "$work/content.after"
    cmp "$work/content.before" "$work/content.after"
    grep -q StressOzz "$box/opt/zapret-manager-luci/backend.sh"
    : > "$box/usr/lib/uhttpd_ubus.so"
done
echo '#!/bin/sh custom launcher' > "$box/usr/bin/zms"
if run normal install; then echo 'Foreign launcher overwritten'; exit 1; fi
grep -q custom "$box/usr/bin/zms"
rm "$box/usr/bin/zms"
echo custom > "$box/user-launcher"
ln -s /user-launcher "$box/usr/bin/zms"
if run normal install; then echo 'Symlink launcher overwritten'; exit 1; fi
[ -L "$box/usr/bin/zms" ] && grep -qx custom "$box/user-launcher"
find "$box/etc" -type f -exec sha256sum {} \; | sort > "$work/settings-after.sha"
cmp "$work/settings.sha" "$work/settings-after.sha"

# Package postinst runs asynchronously outside the component lock. Exercise
# its real worker, including lock contention and non-retryable failures.
cp "$ROOT/forkop/files/usr/share/forkop/zapret-manager-upgrade.sh" "$box/upgrade"
cat > "$box/usr/bin/ucode" <<'EOF'
#!/bin/sh
n=0; [ ! -e /attempts ] || n=$(cat /attempts)
n=$((n + 1)); echo "$n" > /attempts
case "$*" in *'component-action zapret_manager migrate') ;; *) exit 2 ;; esac
if [ "$TEST_SCENARIO" = queuefail ]; then echo 'installer failed'; exit 1; fi
if [ "$n" -lt 2 ]; then echo 'Another component action is already running'; exit 1; fi
echo 'migration verified'
EOF
printf '#!/bin/sh\nexit 0\n' > "$box/usr/bin/logger"
chmod 0755 "$box/usr/bin/logger"
run_worker() { TEST_SCENARIO=$1 chroot "$box" /bin/sh /upgrade run; }
run_worker queuebusy
[ "$(cat "$box/attempts")" = 2 ]
rm "$box/attempts"
if run_worker queuefail; then echo 'Worker ignored failure'; exit 1; fi
[ "$(cat "$box/attempts")" = 1 ]
rm "$box/attempts"
# Fresh Forkop installation must not queue a manager download.
rm -rf "$box/opt" "$box/usr/libexec/rpcd/zapret-manager"
rm -f "$box/usr/bin/zms" "$box/usr/bin/zmsA" "$box/usr/bin/zmw"
TEST_SCENARIO=queuebusy chroot "$box" /bin/sh /upgrade queue
[ ! -e "$box/attempts" ]
echo 'PASS: absent, historical versions, fallback, idempotence, download/install/RPC rollback, settings, foreign launcher'
echo 'PASS: package migration worker waits for lock and preserves absence'
