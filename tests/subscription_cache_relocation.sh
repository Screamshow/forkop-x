#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SOURCE="$ROOT/forkop/files/usr/lib/subscription/cache.uc"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/runtime" "$WORK/persistent"
export FORKOP_CACHE_TEST_DIR="$WORK"
{
cat <<'UC'
let fs=require("fs"), common=require("core.common"), parser=require("subscription.parser");
let source_cache=require("subscription.source_cache");
let TMP_SUBSCRIPTION_FOLDER=getenv("FORKOP_CACHE_TEST_DIR")+"/runtime";
let FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR=getenv("FORKOP_CACHE_TEST_DIR")+"/persistent";
let auto_user_agents={}, default_ua="sing-box/1.14.2-x-1.0.4";
let as_string=common.as_string;
function trim(v){return replace(v,/^[ \t\r\n]+|[ \t\r\n]+$/g,"");}
function command_output_from_args(args) {
 let command = join(" ", map(args, arg => "'" + replace(arg, /'/g, "'\\''") + "'"));
 let pipe = fs.popen(command, "r");
 let data = pipe.read("all");
 return pipe.close()==0 ? data : "";
}
function command_success_from_args(args) { return system(args)==0; }
function subscription_parser(){return parser;}
function generate_hwid(){return "auto-device";}
function ensure_dir(p){if(!fs.stat(p))fs.mkdir(p,0700);}
function chmod_path(p,m){fs.chmod(p,m=="700"?0700:0600);}
function log_message(m,l){die("unexpected persistence error\n");}
function section_is_subscription_proxy(s){return true;}
function section_name(s){return s.name;}
let connections={subscription_urls:function(s){return s.urls;}};
function subscription_source_profile(s,e){return e;}
function get_subscription_user_agent(v){return default_ua;}
UC
for fn in source_id source_json_path source_url_path source_user_agent_path source_hwid_path cache_section_is_safe \
    subscription_cache_is_usable user_agent_supported user_agent_matches_config hwid_matches_config \
    source_cache_profile_matches source_cache_matches_profile find_matching_source_cache restore_persistent_subscription_cache persist_subscription_cache \
    recover_subscription_sources_for_sections persist_recovered_subscription_sources; do
    sed -n "/^function $fn(/,/^}/p" "$SOURCE"
done
cat <<'UC'
function seed(s,url,ua,hwid,label){
 let dir=FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR;
 if(!common.write_private_json_file(source_json_path(dir,s),{outbounds:[{type:"socks",tag:label,server:label+".invalid",server_port:1080}]}))die("seed\n");
 fs.writefile(source_url_path(dir,s),url);fs.writefile(source_user_agent_path(dir,s),ua);fs.writefile(source_hwid_path(dir,s),hwid);
 common.write_private_json_file(dir+"/"+s+".metadata.json",{label:label});
}
function entry(url,ua,hwid){return {valid:true,url:url,user_agent:ua||"",hwid:hwid||""};}
function clear_runtime(){for(let p in fs.glob(TMP_SUBSCRIPTION_FOLDER+"/*")||[])fs.unlink(p);}
function check(s,label){
 let o=source_cache.read(TMP_SUBSCRIPTION_FOLDER,s);
 if(o.payload.outbounds[0].tag!=label||o.profile.metadata?.label!=label)die("source/metadata mismatch\n");
 if(fs.stat(source_json_path(TMP_SUBSCRIPTION_FOLDER,s)).mode!=0600)die("private mode lost\n");
}
seed("main-subscription-1","https://a.invalid","sing-box/1.14.2-x-1.0.1","auto-device","A");
seed("main-subscription-2","https://b.invalid","sing-box/1.14.2-rust-x-0.0.7","auto-device","B");
seed("other-subscription-1","https://c.invalid","INCY/2.2.1-canary.1","auto-device","C");
let sections=[{name:"main",urls:[entry("https://b.invalid"),entry("https://c.invalid")]},{name:"moved",urls:[entry("https://a.invalid")]}];
for(let ua in ["sing-box/1.14.2-x-1.0.4","sing-box/1.14.2-rust-x-0.0.12"]){
 default_ua=ua;clear_runtime();recover_subscription_sources_for_sections(sections);
 check("main-subscription-1","B");check("main-subscription-2","C");check("moved-subscription-1","A");
 if(!persist_recovered_subscription_sources(sections))die("persist relocation\n");
}
// Remove stale slots to simulate prune; relocation must survive another boot.
for(let p in fs.glob(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR+"/other-subscription-1.*")||[])fs.unlink(p);
clear_runtime();recover_subscription_sources_for_sections(sections);check("moved-subscription-1","A");check("main-subscription-2","C");
// Matching sidecars must not cause an invalid persistent payload to be retained.
fs.writefile(source_json_path(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR,"main-subscription-1"),"invalid");
if(!persist_recovered_subscription_sources(sections)||!subscription_cache_is_usable(source_json_path(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR,"main-subscription-1")))die("invalid persistent payload retained\n");
// A populated but mismatched runtime slot must not bypass identity checks.
if(restore_persistent_subscription_cache("main-subscription-1",TMP_SUBSCRIPTION_FOLDER,FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR,"https://unknown.invalid","","",default_ua))die("wrong URL accepted\n");
if(restore_persistent_subscription_cache("main-subscription-1",TMP_SUBSCRIPTION_FOLDER,FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR,"https://b.invalid","custom/1","",default_ua))die("manual UA ignored\n");
if(restore_persistent_subscription_cache("main-subscription-1",TMP_SUBSCRIPTION_FOLDER,FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR,"https://b.invalid","","other-device",default_ua))die("HWID ignored\n");
seed("manual-subscription-1","https://manual.invalid","custom/1","manual-device","M");
if(!restore_persistent_subscription_cache("new-subscription-1",TMP_SUBSCRIPTION_FOLDER,FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR,"https://manual.invalid","custom/1","manual-device",default_ua))die("manual relocation failed\n");
check("new-subscription-1","M");
if(user_agent_supported("sing-box/not a version",default_ua)||user_agent_supported("arbitrary/1",default_ua))die("foreign profile accepted\n");
// The latest RAM feed can survive low flash and a simultaneous offline swap.
clear_runtime();
for(let i=1;i<=2;i++) {
 let source="main-subscription-"+i;
 let record=source_cache.read(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR, source);
 record.payload.outbounds[0].tag+=" RAM";
 record.profile.metadata.label+=" RAM";
 assert(source_cache.publish(source_json_path(TMP_SUBSCRIPTION_FOLDER, source), record.payload, record.profile));
 fs.unlink(source_json_path(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR, source));
}
assert(recover_subscription_sources_for_sections([{name:"main", urls:[entry("https://c.invalid"),entry("https://b.invalid")]}]));
check("main-subscription-1","C RAM");
check("main-subscription-2","B RAM");
print("Subscription relocation: swaps, section move, reboot, metadata, both X core profiles and URL/UA/HWID guards passed\n");
UC
} > "$WORK/check.uc"
ucode -L "$ROOT/forkop/files/usr/lib" "$WORK/check.uc"

# Run the complete preparation module with isolated UCI and cache paths. Network
# refresh is disabled; a stub version command exercises both core identities.
mkdir "$WORK/actual" "$WORK/actual/persistent" "$WORK/bin"
cat > "$WORK/bin/sing-box" <<'SH'
#!/bin/sh
echo "sing-box version $FORKOP_TEST_CORE_VERSION"
SH
chmod +x "$WORK/bin/sing-box"
export PATH="$WORK/bin:$PATH" FORKOP_LIB="$ROOT/forkop/files/usr/lib"
export FORKOP_UCI_STATE_FILE="$WORK/uci.state" TMP_SING_BOX_FOLDER="$WORK/actual/sing-box"
export FORKOP_RUNTIME_STATE_DIR="$WORK/actual/state"
export FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK/actual/persistent"
export SB_VARIANT_STATE_FILE="$WORK/absent-variant" SB_VERSION_STATE_FILE="$WORK/absent-version"
cat > "$WORK/uci.state" <<'STATE'
forkop.settings=settings
forkop.test=section
forkop.test.enabled=1
forkop.test.action=connection
forkop.test.subscription_urls=https://aes2215.vs2112.51343.ru/test-b https://aes2215.vs2112.51343.ru/test-a
STATE
for spec in '1 A a' '2 B b'; do
    set -- $spec
    prefix="$WORK/actual/persistent/test-subscription-$1"
    printf '{"outbounds":[{"type":"socks","tag":"%s","server":"%s.invalid","server_port":1080}]}' "$2" "$3" > "$prefix.json"
    printf 'https://aes2215.vs2112.51343.ru/test-%s' "$3" > "$prefix.url"
    printf 'sing-box/1.14.2-x-1.0.1' > "$prefix.user_agent"
    : > "$prefix.hwid"
    printf '{"label":"%s"}' "$2" > "$prefix.metadata.json"
    chmod 600 "$prefix".*
done
for version in 1.14.2-x-1.0.4 1.14.2-rust-x-0.0.12; do
    export FORKOP_TEST_CORE_VERSION="$version"
    if ! ucode -L "$FORKOP_LIB" "$SOURCE" prepare-caches runtime 0 1 > "$WORK/prepare.log" 2>&1; then
        cat "$WORK/prepare.log"
        exit 1
    fi
    grep -q 'B.invalid\|b.invalid' "$WORK/actual/sing-box/subscriptions/test-subscription-1.json"
    grep -q 'a.invalid' "$WORK/actual/sing-box/subscriptions/test-subscription-2.json"
    ucode -L "$FORKOP_LIB" -e '
        let cache = require("subscription.source_cache");
        assert(cache.read(ARGV[0], "test-subscription-1").profile.url == "https://aes2215.vs2112.51343.ru/test-b");
    ' "$WORK/actual/persistent"
    # Clear only this test's runtime via the module's normal format migration.
    printf '9\n' > "$WORK/actual/persistent/cache-format"
    printf 'old-format' > "$WORK/actual/state/cache-format"
    ucode -L "$FORKOP_LIB" "$SOURCE" ensure-runtime-cache-format
done
echo 'Complete offline prepare-caches passed across core identities and runtime cache reset'
