#!/bin/sh
# Called only while components/action.uc owns the component lock.
# No dev URLs: the public installer must expose the agreed contract first.
set -eu
mode=${1:-install}
mirror=${2:-}
mirror=${mirror%/}
case "$mode" in install|migrate) ;; *) exit 2 ;; esac
case "$mirror" in https://*) ;; *) echo 'Missing HTTPS mirror URL' >&2; exit 2 ;; esac
backend=/opt/zapret-manager-luci/backend.sh
repo=https://raw.githubusercontent.com/Screamshow/Zapret-Manager/main
unchanged() { echo 'FORKOP_ZM_CHANGED=0'; exit 0; }
owned() {
    grep -Eq "https://[^[:space:]\"')]*raw[.]githubusercontent[.]com/(StressOzz|Screamshow)/Zapret-Manager/(refs/heads/)?main/(Zapret-Manager|ZapretManager_LuCI)[.]sh([[:space:]\"')]|$)" "$1"
}
present=0
[ ! -e "$backend" ] || present=1
[ ! -e /usr/libexec/rpcd/zapret-manager ] || present=1
for p in /usr/bin/zms /usr/bin/zmsA /usr/bin/zmw; do
    [ ! -L "$p" ] || { echo "Symlink launcher: $p; no files changed" >&2; exit 1; }
    if [ -e "$p" ]; then
        owned "$p" || { echo "Foreign launcher: $p; no files changed" >&2; exit 1; }
        present=1
    fi
done
[ "$mode" != migrate ] || [ "$present" = 1 ] || unchanged
ready() {
    [ -x "$backend" ] && [ -x /usr/libexec/rpcd/zapret-manager ] || return 1
    grep -qx 'ZM_FLAVOR="forkop-five-section-v1"' "$backend" || return 1
    grep -Eq '^ZM_SCRIPT_URL="https://raw.githubusercontent.com/Screamshow/Zapret-Manager/(refs/heads/)?main/ZapretManager_LuCI.sh"$' "$backend" || return 1
    for page in dashboard strategy zapret2 hosts terminal; do
        [ -s "/www/luci-static/resources/view/zapret-manager/$page.js" ] || return 1
    done
    [ -s /www/zm/app.js ] && [ -s /www/zm/app.css ] && [ -s /www/zm-webui.html ] || return 1
    [ -s /usr/share/luci/menu.d/luci-app-zapret-manager.json ] || return 1
    [ -s /usr/share/rpcd/acl.d/luci-app-zapret-manager.json ] || return 1
    sh -n "$backend" && sh -n /usr/libexec/rpcd/zapret-manager || return 1
    # Validate installed routes, not just download success or nonempty files.
    ucode -e '
let fs=require("fs"), menu=json(fs.readfile(ARGV[0]));
let pages=[];
for(let key in keys(menu)) if(length(split(key,"/"))==4) push(pages,split(key,"/")[3]);
assert(join(",",sort(pages))=="dashboard,hosts,strategy,terminal,zapret2","panel menu");
let app=fs.readfile("/www/zm/app.js");
for(let page in pages) assert(index(app,"id: " + "\x27" + page + "\x27")>=0,"Web route " + page);
' /usr/share/luci/menu.d/luci-app-zapret-manager.json || return 1
    health=$(ubus -t 5 call zapret-manager health '{}') || return 1
    ucode -e 'let h=json(ARGV[0]); assert(type(h)=="object" && type(h.dots)=="object","panel health");' "$health"
}
launchers_ready() {
    for p in /usr/bin/zms /usr/bin/zmsA /usr/bin/zmw; do
        [ -x "$p" ] && grep -q 'Screamshow/Zapret-Manager/main/' "$p" || return 1
        ! grep -q StressOzz "$p" || return 1
    done
}
if [ "$mode" = migrate ] && ready && launchers_ready; then unchanged; fi
work=$(mktemp -d /tmp/forkop-zm.XXXXXX)
chmod 0700 "$work"
changed=0
for svc in rpcd uhttpd cron; do
    if /etc/init.d/"$svc" running >/dev/null 2>&1; then
        printf '%s\n' "$svc" >> "$work/running"
    fi
done
paths() {
    # Full panel payload/state plus every shared file touched by its installer.
    for p in /opt/zapret-manager-luci /usr/libexec/rpcd/zapret-manager \
        /usr/share/luci/menu.d/luci-app-zapret-manager.json \
        /usr/share/rpcd/acl.d/luci-app-zapret-manager.json \
        /www/luci-static/resources/zapret-manager \
        /www/luci-static/resources/view/zapret-manager \
        /www/luci-static/resources/bytetube /www/luci-static/resources/view/bytetube \
        /www/zm /www/zm-webui.html /usr/bin/zms /usr/bin/zmsA /usr/bin/zmw \
        /etc/crontabs/root /etc/config/uhttpd /etc/config/system \
        /etc/config/zapret /etc/config/zapret2 /etc/hosts; do
        printf '%s\n' "${p#/}"
    done
}
finish() {
    rc=$?
    trap - EXIT HUP INT TERM
    if [ "$changed" = 1 ]; then
        echo 'Restoring previous Zapret Manager files and update source' >&2
        while IFS= read -r p; do rm -rf "/$p"; done < "$work/paths"
        if ! tar -xpf "$work/before.tar" -C /; then
            echo "RESTORE FAILED: recovery archive retained at $work" >&2
            exit 1
        fi
        for svc in rpcd uhttpd cron; do
            op=stop
            if [ -f "$work/running" ] && grep -qx "$svc" "$work/running"; then op=restart; fi
            /etc/init.d/"$svc" "$op" >/dev/null 2>&1 || true
        done
        rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null || true
    fi
    rm -rf "$work"
    exit "$rc"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM
get() {
    curl -fLsS --connect-timeout 10 --max-time 120 "$1" -o "$work/installer" &&
        grep -qx '# Forkop-Manager-Contract: five-section-v1' "$work/installer" &&
        grep -q '^ZM_FLAVOR="forkop-five-section-v1"' "$work/installer" &&
        grep -q '^ZM_SCRIPT_URL="https://raw.githubusercontent.com/Screamshow/Zapret-Manager/' "$work/installer" &&
        sh -n "$work/installer"
}
need_install=1
# A valid panel needs only launcher repair during package migration. This
# also repairs an interrupted installation offline without downgrading it.
if [ "$mode" = migrate ] && ready; then need_install=0; fi
if [ "$need_install" = 1 ]; then
    get "$mirror/zapret-manager/proxy/raw.githubusercontent.com/Screamshow/Zapret-Manager/main/ZapretManager_LuCI.sh" ||
        get "$repo/ZapretManager_LuCI.sh" || { echo 'No compatible public Forkop manager installer available' >&2; exit 1; }
    if ready; then
        installed=$(sed -n 's/^ZM_VERSION="\([0-9.]*\)"$/\1/p' "$backend" | head -n1)
        latest=$(sed -n 's/^# Version: \([0-9.]*\)$/\1/p' "$work/installer" | head -n1)
        if ! ucode -e 'let a=split(ARGV[0],"."),b=split(ARGV[1],"."); for(let i=0;i<length(a)||i<length(b);i++){let x=int(a[i]||0),y=int(b[i]||0);if(x!=y)exit(x>y?0:1);}exit(1);' "$latest" "$installed"; then need_install=0; fi
    fi
fi
if [ "$need_install" = 0 ] && launchers_ready; then unchanged; fi
if [ "$need_install" = 1 ] && [ ! -e /usr/lib/uhttpd_ubus.so ]; then
    echo 'uhttpd-mod-ubus is required from the native firmware feeds; panel files were not changed' >&2
    exit 1
fi
paths > "$work/paths"
while IFS= read -r p; do [ ! -e "/$p" ] && [ ! -L "/$p" ] || printf '%s\n' "$p"; done < "$work/paths" > "$work/existing"
tar -cpf "$work/before.tar" -C / -T "$work/existing"
# Detect a truncated archive before any file is changed.
tar -tf "$work/before.tar" >/dev/null
# Integration mode avoids dependency installation and background work while
# Forkop owns the transaction; existing services and enabled states stay intact.
changed=1
if [ "$need_install" = 1 ]; then ZM_FORKOP_TRANSACTION=1 sh "$work/installer" </dev/null; fi
ready || { echo 'Manager backend, resources or RPC verification failed' >&2; exit 1; }
for item in 'zms Zapret-Manager.sh' 'zmsA Zapret-Manager.sh' 'zmw ZapretManager_LuCI.sh'; do
    name=${item%% *}; file=${item#* }
    cat > "/usr/bin/$name" <<EOF
#!/bin/sh
u='$mirror/zapret-manager/proxy/raw.githubusercontent.com/Screamshow/Zapret-Manager/main/$file'
fallback='$repo/$file'
EOF
    cat >> "/usr/bin/$name" <<'EOF'
t=$(mktemp /tmp/forkop-zm-get.XXXXXX) || exit 1
trap 'rm -f "$t"' EXIT HUP INT TERM
get() { curl -fLsS --connect-timeout 10 --max-time 120 "$1" -o "$t" && [ -s "$t" ] && sh -n "$t"; }
get "$u" || get "$fallback" || exit 1
sh "$t" "$@"
EOF
    chmod 0755 "/usr/bin/$name"
done
launchers_ready || exit 1
if [ -f "$work/running" ] && grep -qx cron "$work/running"; then
    /etc/init.d/cron restart >/dev/null 2>&1 || exit 1
fi
changed=0
echo 'Forkop Zapret Manager verified; settings and existing services preserved'
echo 'FORKOP_ZM_CHANGED=1'
