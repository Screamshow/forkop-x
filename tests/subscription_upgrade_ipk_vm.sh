#!/bin/sh
# Existing OpenWrt 24 VMware VM. Baseline and target packages must be staged.
# Retains the final candidate; no automatic package/configuration rollback.
set -eu
[ "${FORKOP_TEST_VM:-}" = 1 ]
ubus call system board | grep -qi VMware
root=${1:?staged directory required}
export FORKOP_TEST_ROOT="$root" FORKOP_TEST_REAL_OPKG=$(command -v opkg)
cd "$root"
mkdir -p bin evidence
umask 077
cp /usr/share/forkop/zapret-manager-upgrade.sh evidence/old-worker.sh
ucode - <<'UC'
let fs=require('fs'), root=getenv('FORKOP_TEST_ROOT'), releases=[];
for(let pair in [['baseline','2.6.0'],['target','2.6.2-canary.999']]) {
 let assets=[], prefix='/forkop/updates/'+(pair[0]=='target'?'canary/':'')+'releases/'+pair[1]+'/';
 for(let kind in ['forkop','luci-app-forkop','luci-i18n-forkop-ru']) {
  let name=kind+'_'+pair[1]+'.ipk';let pipe=fs.popen('sha256sum '+root+'/'+pair[0]+'/'+name,'r');let hash=split(pipe.read('all'),/\s+/)[0];pipe.close();
  push(assets,{name,sha256:hash,browser_download_url:prefix+name});
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
 */forkop/updates/*/2.6.2-canary.999/*.ipk) file=$root/target/${url##*/} ;;
 */forkop/updates/releases/2.6.0/*.ipk) file=$root/baseline/${url##*/} ;;
 *Screamshow/Zapret-Manager/main/ZapretManager_LuCI.sh) file=$root/manager-installer.sh ;;
esac
if [ -n "$file" ]; then
 [ -z "$out" ] && { cat "$file"; exit; }
 cp "$file" "$out"; exit
fi
exec /usr/bin/curl "$@"
SH
cat > bin/opkg <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$FORKOP_TEST_ROOT/evidence/opkg.commands"
# Network delivery only: package installation/verification/hooks remain native.
[ "${1:-}" != update ] || exit 0
exec "$FORKOP_TEST_REAL_OPKG" "$@"
SH
chmod 755 bin/*
export PATH="$root/bin:$PATH"
/usr/bin/forkop component_action zapret_manager install > evidence/manager-install.log 2>&1
# Reproduce both deferred-worker errors on 2.6.0 without changing packages.
logger -t forkop-ipk-review reproduce-worker-errors
FORKOP_LIB=/var/run/forkop/bytecode/deleted-review-generation sh evidence/old-worker.sh run || true
lock=/var/run/forkop/component-action.lock
mkdir "$lock"
echo $$ > "$lock/pid"
FORKOP_LIB=/usr/lib/forkop sh evidence/old-worker.sh run &
worker=$!
sleep 5
kill "$worker" 2>/dev/null || true
wait "$worker" 2>/dev/null || true
rm "$lock/pid"
rmdir "$lock"
logread > evidence/old-worker-system.log
ucode - <<'UC'
let fs=require('fs'),root=getenv('FORKOP_TEST_ROOT');let t=fs.readfile(root+'/evidence/old-worker-system.log');t=substr(t,index(t,'reproduce-worker-errors'));
assert(index(t,'deleted-review-generation/components/action.uc')>=0,'stale bytecode error not reproduced');
let busy=filter(split(t,'\n'),l=>index(l,'Another component action is already running')>=0);
assert(length(busy)>=2,'repeated lock errors not reproduced');
printf('REPRODUCED stale bytecode and %d busy error messages\n',length(busy));
UC
ucode - <<'UC'
let fs=require('fs'),u=require('uci').cursor();
function section(name,kind,values){u.set('forkop',name,kind);for(let k,v in values)u.set('forkop',name,k,v);}
section('migration','section',{enabled:'1',action:'connection',connection_type:'subscription',domain:'migration.invalid'});
section('migration_source','subscription_url',{section:'migration',url:'https://subscription.test/migration'});
section('migration_group','urltest',{section:'migration',name:'ms1',filter_mode:'include',include_outbounds:'Migration node',testing_url:'https://www.gstatic.com/generate_204',check_interval:'3m'});
u.commit('forkop');
fs.writefile(getenv('FORKOP_TEST_ROOT')+'/feed.json',sprintf('%J',{outbounds:[{type:'vless',tag:'Migration node',server:'migration.example',server_port:443,uuid:'11111111-1111-4111-8111-111111111111',tls:{enabled:true,server_name:'migration.example'}}]}));
UC
/usr/bin/forkop subscription_update > evidence/seed-update.log 2>&1
/etc/init.d/forkop restart > evidence/seed-start.log 2>&1
ucode -L /usr/lib/forkop - <<'UC'
let fs=require('fs'),f=require('subscription.filter_selection'),u=require('core.uci');
assert(f.finish(f.snapshot(u.get_all('forkop','migration'))).ok);
for(let dir in ['/etc/forkop/subscription-cache','/tmp/sing-box/subscriptions']) {
 let p=dir+'/migration-subscription-1.json';let d=json(fs.readfile(p));d.outbounds[0].server='192.0.2.10';fs.writefile(p,sprintf('%J',d));
}
UC
# Reproduce generation failure while retaining the running baseline core.
if ucode -L /usr/lib/forkop /usr/lib/forkop/singbox/generator.uc generate-config "$root/before.json" 127.0.0.1 0 1 '' 1.14.2-rust-x.0.0.27 1 > evidence/old-generator.log 2>&1; then
 echo 'FAIL stale binding unexpectedly generated'; exit 1
fi
grep "URLTest group 'ms1'.*has no usable proxy outbounds" evidence/old-generator.log
echo 'REPRODUCED empty ms1 after domain to IP change'
logger -t forkop-ipk-review patched-ipk-upgrade-begin
/usr/bin/forkop component_action forkop install 2.6.2-canary.999 > evidence/upgrade.log 2>&1
/etc/init.d/forkop status
ucode - <<'UC'
let fs=require('fs'),c=json(fs.readfile('/etc/sing-box/config.json'));
let g=filter(c.outbounds,o=>o.tag=='migration-urltest-migration_group-out')[0];assert(g && length(g.outbounds)==1);
let o=filter(c.outbounds,o=>o.tag==g.outbounds[0])[0];assert(o.server=='192.0.2.10','IP migration failed');
UC
nslookup example.com 127.0.0.1 > evidence/dns.after
ubus -t 5 call zapret-manager health '{}' > evidence/manager-health.after
# Run new worker with the same invalid inherited library and a held lock.
mkdir "$lock"
echo $$ > "$lock/pid"
FORKOP_LIB=/var/run/forkop/bytecode/deleted-review-generation sh /usr/share/forkop/zapret-manager-upgrade.sh run &
worker=$!
sleep 5
rm "$lock/pid"
rmdir "$lock"
wait "$worker"
logread > evidence/final-system.log
ucode - <<'UC'
let fs=require('fs'),root=getenv('FORKOP_TEST_ROOT');let t=fs.readfile(root+'/evidence/final-system.log');let n=index(t,'patched-ipk-upgrade-begin');assert(n>=0);t=substr(t,n);
let errors=filter(split(t,'\n'),l=>index(l,'forkop:')>=0 && match(l,/\[error\]|\[fatal\]|migration failed|Failed to open|Another component action/));
printf('Patched IPK update Forkop errors: %d\n',length(errors));assert(length(errors)==0);
assert(index(t,'FORKOP_ZM_CHANGED=0')>=0,'deferred migration did not complete');
UC
echo 'PASS real IPK updater, recovered ms1, DNS, Manager RPC, stale library and lock contention; VM retained on candidate'
