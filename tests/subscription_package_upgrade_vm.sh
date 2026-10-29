#!/bin/sh
# Existing VMware VM only. Local candidate catalog; real package manager,
# package hooks, component transaction, service start and rollback.
set -eu
root=${1:?staged directory required}
export FORKOP_TEST_ROOT="$root"
[ "${FORKOP_TEST_VM:-}" = 1 ]
export FORKOP_TEST_REAL_APK=$(command -v apk)
ubus call system board | grep -qi VMware
cd "$root"
umask 077
mkdir -p target baseline original bin evidence
# Stage original 2.5.0, baseline 2.6.0 and target 2.6.2-canary.999 packages
# in their respective directories, plus the native unzip dependency at root.
test -s original/forkop_2.5.0.apk
test -s baseline/forkop_2.6.0.apk
test -s target/forkop_2.6.2-canary.999.apk
apk list --installed | sort > evidence/packages.before
uci export > evidence/uci.before
cp -a /etc/apk/world evidence/world.before
tar -czpf evidence/state.before.tar.gz /etc/config /etc/forkop /etc/sing-box /etc/crontabs /etc/rc.d /opt /usr/libexec/rpcd /usr/share/luci/menu.d /usr/share/rpcd/acl.d /www
cp -a /usr/bin/sing-box evidence/sing-box.before
/etc/init.d/forkop status > evidence/service.before
restore() {
    rc=$?
    trap - EXIT
    if [ "${FORKOP_TEST_RESTORE_ORIGINAL:-0}" != 1 ]; then
        echo "Test VM retained at current package/configuration state (test status=$rc)"
        exit "$rc"
    fi
    unset FORKOP_LIB FORKOP_SOURCE_LIB FORKOP_SERVICE_INIT
    /etc/init.d/forkop stop > evidence/restore-stop.log 2>&1 || true
    apk --preserve-env add --allow-untrusted --force-reinstall original/forkop_2.5.0.apk original/luci-app-forkop_2.5.0.apk original/luci-i18n-forkop-ru_2.5.0.apk > evidence/restore-packages.log 2>&1 || { echo 'RESTORE FAILED'; exit 1; }
    tar -xzpf evidence/state.before.tar.gz -C /
    rm -f /usr/bin/sing-box
    cp -a evidence/sing-box.before /usr/bin/sing-box
    cp -a evidence/world.before /etc/apk/world
    if ! grep -q '^unzip-' evidence/packages.before; then apk del unzip > evidence/restore-dependencies.log 2>&1; fi
    /etc/init.d/forkop start > evidence/restore-start.log 2>&1
    apk list --installed | sort > evidence/packages.after
    cmp evidence/packages.before evidence/packages.after
    uci export > evidence/uci.after
    cmp evidence/uci.before evidence/uci.after
    nslookup example.com 127.0.0.1 > evidence/dns.after
    echo "RESTORED original packages, UCI and DNS (test status=$rc)"
    exit "$rc"
}
trap restore EXIT
apk --no-network --preserve-env add --allow-untrusted unzip.apk baseline/*.apk > evidence/baseline-install.log 2>&1
/etc/init.d/forkop status
ucode - <<'UC'
let fs=require('fs');let root=getenv('FORKOP_TEST_ROOT');let releases=[];
for(let pair in [['original','2.5.0'],['baseline','2.6.0'],['target','2.6.2-canary.999']]) {
 let assets=[];let prefix='/forkop/updates/'+(pair[1]=='2.6.2-canary.999'?'canary/':'')+'releases/'+pair[1]+'/';
 for(let name in ['forkop','luci-app-forkop','luci-i18n-forkop-ru']) {
  let file=name+'_'+pair[1]+'.apk';let p=fs.popen('sha256sum '+root+'/'+pair[0]+'/'+file,'r');let hash=split(p.read('all'),/\s+/)[0];p.close();
  push(assets,{name:file,sha256:hash,browser_download_url:prefix+file});
 }
 push(releases,{tag_name:pair[1],html_url:prefix,assets});
}
fs.writefile(root+'/catalog.json',sprintf('%J',{format:1,releases}));
UC
cat > bin/curl <<'SH'
#!/bin/sh
set -eu
root=$FORKOP_TEST_ROOT
out= next= url=
for arg; do
 if [ "$next" = out ]; then out=$arg; next=; continue; fi
 case "$arg" in -o) next=out ;; https://*) url=$arg ;; esac
done
file=
case "$url" in
 https://subscription.test/migration) file=$root/feed.json ;;
 */forkop/updates/releases.json) file=$root/catalog.json ;;
 */forkop/updates/*/2.6.2-canary.999/*.apk) file=$root/target/${url##*/} ;;
 */forkop/updates/releases/2.6.0/*.apk) file=$root/baseline/${url##*/} ;;
 */forkop/updates/releases/2.5.0/*.apk) file=$root/original/${url##*/} ;;
 *Screamshow/Zapret-Manager/main/ZapretManager_LuCI.sh) file=$root/manager-installer.sh ;;
esac
if [ -n "$file" ]; then
 [ -z "$out" ] && { cat "$file"; exit; }
 cp "$file" "$out"; exit
fi
exec /usr/bin/curl "$@"
SH
chmod 755 bin/curl
cat > bin/apk <<'SH'
#!/bin/sh
# Package delivery is offline in this test; use the VM's captured native indexes.
printf '%s\n' "$*" >> "$FORKOP_TEST_ROOT/evidence/apk.commands"
[ "${1:-}" != update ] || exit 0
exec "$FORKOP_TEST_REAL_APK" --no-network "$@"
SH
chmod 755 bin/apk
export PATH="$root/bin:$PATH"
if [ -s manager-installer.sh ]; then
    /usr/bin/forkop component_action zapret_manager install > evidence/manager-install.log 2>&1
fi
ucode - <<'UC'
let fs=require('fs');let u=require('uci').cursor();
function section(name,kind,values) {
 u.set('forkop',name,kind);
 for(let key,value in values) u.set('forkop',name,key,value);
}
section('migration','section',{enabled:'1',action:'connection',connection_type:'subscription',domain:'migration.invalid'});
section('migration_source','subscription_url',{section:'migration',url:'https://subscription.test/migration'});
section('migration_group','urltest',{section:'migration',name:'Migration',filter_mode:'include',include_outbounds:'Migration node',testing_url:'https://www.gstatic.com/generate_204',check_interval:'3m'});
u.commit('forkop');
fs.writefile(getenv('FORKOP_TEST_ROOT')+'/feed.json',sprintf('%J',{outbounds:[{type:'vless',tag:'Migration node',server:'migration.example',server_port:443,uuid:'11111111-1111-4111-8111-111111111111',tls:{enabled:true,server_name:'migration.example'}}]}));
UC
/usr/bin/forkop subscription_update > evidence/seed-update.log 2>&1
/etc/init.d/forkop restart > evidence/seed-start.log 2>&1
ucode -L /usr/lib/forkop - <<'UC'
let fs=require('fs');let f=require('subscription.filter_selection');let u=require('core.uci');
assert(f.finish(f.snapshot(u.get_all('forkop','migration'))).ok);
for(let dir in ['/etc/forkop/subscription-cache','/tmp/sing-box/subscriptions']) {
 let p=dir+'/migration-subscription-1.json';let feed=json(fs.readfile(p));feed.outbounds[0].server='192.0.2.10';fs.writefile(p,sprintf('%J',feed));
}
UC
logread > evidence/log-before
/usr/bin/forkop component_action forkop install 2.6.2-canary.999 > evidence/upgrade.log 2>&1
/etc/init.d/forkop status
ucode - <<'UC'
let fs=require('fs');let cfg=json(fs.readfile('/etc/sing-box/config.json'));
let group=filter(cfg.outbounds,o=>o.tag=='migration-urltest-migration_group-out')[0];
assert(group && length(group.outbounds)==1,'migration group empty');
let node=filter(cfg.outbounds,o=>o.tag==group.outbounds[0])[0];assert(node.server=='192.0.2.10','old domain retained');
UC
nslookup example.com 127.0.0.1 > evidence/dns-upgraded
echo 'PASS actual updater: old binding recovered during package startup; new IP generated; DNS works'
/usr/bin/forkop component_action forkop install 2.6.2-canary.999 > evidence/repeat.log 2>&1
/etc/init.d/forkop status
echo 'PASS repeated package transaction'
/usr/bin/forkop component_action forkop install 2.6.0 > evidence/downgrade.log 2>&1
/etc/init.d/forkop status
cat > fail-start <<'SH'
#!/bin/sh
if [ "$1" = start ] && apk list --installed forkop | grep -q 'forkop-2.6.2_rc999'; then
 touch "$FORKOP_TEST_ROOT/fault-triggered"
 exit 1
fi
exec /etc/init.d/forkop "$@"
SH
chmod 755 fail-start
if FORKOP_SERVICE_INIT="$root/fail-start" /usr/bin/forkop component_action forkop install 2.6.2-canary.999 > evidence/rollback.log 2>&1; then
 echo 'FAIL startup fault ignored'; exit 1
fi
test -e fault-triggered
apk list --installed forkop | grep 'forkop-2.6.0 '
/etc/init.d/forkop status
nslookup example.com 127.0.0.1 > evidence/dns-rollback
echo 'PASS injected startup failure: updater restored 2.6.0 and DNS'
/usr/bin/forkop component_action forkop install 2.6.2-canary.999 > evidence/final-upgrade.log 2>&1
/etc/init.d/forkop status
nslookup example.com 127.0.0.1 > evidence/dns-final
echo 'PASS final candidate running; test VM retained on candidate'
