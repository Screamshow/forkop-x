#!/bin/sh
# Phased test on an existing OpenWrt VM. No installed service/UCI changes.
# start prints WORK; keep an SSH session through port 19096 open while calling
# apply, then call cleanup. Port 19096 forwards through the test core to sshd.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export FORKOP_LIB="$ROOT/forkop/files/usr/lib"
if [ "$1" = start ]; then
    : "${FORKOP_TEST_CORE:?test binary required}"
    WORK=$(mktemp -d /tmp/forkop-subscription-hot-live.XXXXXX)
else
    : "${WORK:?test work directory required}"
    case "$WORK" in /tmp/forkop-subscription-hot-live.*) ;; *) exit 1 ;; esac
fi
export WORK
export FORKOP_UCI_CONFIG_DIR="$WORK/uci"
export FORKOP_RUNTIME_STATE_DIR="$WORK/state"
export FORKOP_SECTION_CACHE_DIR="$WORK/section-cache"
export FORKOP_SUBSCRIPTION_APPLY_ERROR_FILE="$WORK/state/subscription-apply-error.json"
export FORKOP_STATE_UC="$WORK/provenance.uc"
export FORKOP_SING_BOX_BIN="$WORK/xrust"
export SB_CLASH_API_CONTROLLER_PORT=19097
case "$1" in
cleanup)
    if test -f "$WORK/pid"; then
        pid=$(cat "$WORK/pid")
        if tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -Fq "$WORK/active.json"; then kill "$pid"; fi
    fi
    rm -rf "$WORK"
    exit 0
    ;;
start)
    mkdir -p "$WORK/uci" "$WORK/state" "$WORK/section-cache"
    cp "$FORKOP_TEST_CORE" "$WORK/xrust"
    chmod 755 "$WORK/xrust"
    cat > "$WORK/uci/forkop" <<EOF
config settings 'settings'
    option config_path '$WORK/active.json'
    option service_listen_address '127.0.0.1'
    option enable_yacd_wan_access '0'
EOF
    echo '{"old":true}' > "$WORK/section-cache/Proxy.json"
    cat > "$WORK/provenance.uc" <<'UC'
let fs=require("fs"),pid=int(fs.readfile(getenv("WORK")+"/pid"));
let raw=fs.readfile("/proc/"+pid+"/stat");
if(raw==null)exit(1);
let fields=split(substr(raw,index(raw,")")+2)," ");
print(sprintf("%J\n",{pid,start_ticks:int(fields[19])}));
UC
    cat > "$WORK/make.uc" <<'UC'
let fs=require("fs"),work=getenv("WORK");
let config={inbounds:[{type:"direct",tag:"ssh",listen:"0.0.0.0",listen_port:19096,network:"tcp",override_address:"127.0.0.1",override_port:22}],
 outbounds:[{type:"direct",tag:"a"},{type:"direct",tag:"b"},
 {type:"selector",tag:"Proxy",outbounds:["a","b"],default:"a"}],route:{final:"Proxy"},
 experimental:{clash_api:{external_controller:"127.0.0.1:19097"},cache_file:{enabled:true,path:work+"/cache.db"}}};
fs.writefile(work+"/active.json",sprintf("%J",config));
push(config.outbounds,{type:"direct",tag:"c"});config.outbounds[2].outbounds=["a","b","c"];
fs.writefile(work+"/candidate.json",sprintf("%J",config));
UC
    ucode "$WORK/make.uc"
    "$WORK/xrust" run -c "$WORK/active.json" < /dev/null > "$WORK/core.log" 2>&1 &
    echo $! > "$WORK/pid"
    for i in $(seq 1 15); do
        if curl -fsS --max-time 1 http://127.0.0.1:19097/proxies >/dev/null 2>&1; then echo "$WORK"; exit 0; fi
        sleep 1
    done
    cat "$WORK/core.log" >&2
    exit 1
    ;;
apply) ;;
*) exit 1 ;;
esac
{
cat <<'UC'
let fs=require("fs"),common=require("core.common");
let work=getenv("WORK"),LIB_DIR=getenv("FORKOP_LIB"),SECTION_CACHE_DIR=getenv("FORKOP_SECTION_CACHE_DIR");
let RUNTIME_STATE_DIR=getenv("FORKOP_RUNTIME_STATE_DIR"),SUBSCRIPTION_APPLY_ERROR_FILE=getenv("FORKOP_SUBSCRIPTION_APPLY_ERROR_FILE");
let PRIORITY_UC="priority",DNS_FAILOVER_UC="dns",subscription_failure_detail=null,subscription_outbounds_changed=false,fail_ack=false;
let as_string=common.as_string;
function trim(v){return replace(as_string(v),/^[ \t\r\n]+|[ \t\r\n]+$/g,"");}
function quote(v){return "'"+replace(as_string(v),/'/g,"'\\''")+"'";}
function capture(args){let p=fs.popen(join(" ",map(args,quote)),"r"),output=p.read("all"),status=int(p.close());return {output,status:status>255?int(status/256):status};}
function command_output_from_args(args){let r=capture(args);return r.status==0?r.output:"";}
function command_success_from_args(args){return capture(args).status==0;}
function ensure_dir(p){return fs.stat(p)!=null||fs.mkdir(p,0700);}
function read_json_file(p){try{return json(fs.readfile(p));}catch(e){return null;}}
function option(s,k,f){return s[k]||f;}
function uci_settings(){return {config_path:work+"/active.json"};}
function module_capture(args){let command=["ucode","-L",LIB_DIR];for(let arg in args)push(command,arg);return capture(command);}
function module_success(args){
 if(args[0]==PRIORITY_UC||args[0]==DNS_FAILOVER_UC)return true;
 let ok=module_capture(args).status==0;
 return args[1]=="apply" && fail_ack ? false : ok;
}
function singbox_runtime_success(args){
 if(args[0]=="prepare-config-stage"){
  let ok=command_success_from_args(["cp",work+"/candidate.json",args[5]]);
  fs.mkdir(args[5]+".section-cache",0700);
  fs.writefile(args[5]+".section-cache/Proxy.json",'{"new":true}');return ok;
 }
 if(index(["discard-config-stage","commit-config-stage","publish-section-cache"],args[0])<0)die("unexpected cold mutation\n");
 let command=[LIB_DIR+"/xrust/runtime.uc"];for(let arg in args)push(command,arg);return module_success(command);
}
function service_state_success(args){if(args[0]!="sing-box-current-owned-service-runtime")die("cold service action\n");return true;}
function current_proxy_outbounds_signature(p){return command_output_from_args(["sha256sum",p]);}
function subscription_prepare_cache_request(a,b,c){return {ok:true,updated:1,failed:0};}
function log_message(m,l){print(l+": "+m+"\n");}
function write_current_reload_state_clean(){return true;}
function schedule_automatic_latency_test(s){return true;}
function validation_failure_message(v){return "invalid";}
UC
for name in subscription_apply_failure subscription_record_result subscription_hot_transition subscription_restore_selectors subscription_restore_runtime subscription_config_value subscription_runtime_change_check subscription_update_common_locked; do
    sed -n "/^function $name(/,/^}/p" "$FORKOP_LIB/components/updates.uc"
done
cat <<'UC'
let pid=trim(fs.readfile(work+"/pid"));
if(!command_success_from_args(["curl","-fsS","-X","PUT","--data-raw",'{"name":"b"}',"http://127.0.0.1:19097/proxies/Proxy"]))die("selection failed\n");
if(!subscription_update_common_locked(true,"Proxy",0))die("hot apply failed\n");
subscription_record_result(true,"Proxy");
let view=json(command_output_from_args(["curl","-fsS","http://127.0.0.1:19097/proxies"]));
if(view.proxies.Proxy.now!="b"||trim(fs.readfile(work+"/pid"))!=pid)die("PID/selection changed\n");
print("PASS: subscription changed via hot reload; PID and manual choice preserved\n");
let previous=fs.readfile(work+"/active.json"),candidate=read_json_file(work+"/candidate.json");
candidate.outbounds[2].outbounds=["a","c"];fs.writefile(work+"/candidate.json",sprintf("%J",candidate));
fail_ack=true;
if(subscription_update_common_locked(true,"Proxy",0))die("missing acknowledgment accepted\n");
subscription_record_result(false,"Proxy");
let alert=read_json_file(SUBSCRIPTION_APPLY_ERROR_FILE);
if(fs.readfile(work+"/active.json")!=previous||alert.state!="previous"||alert.reason!="hot_apply_failed"||!read_json_file(SECTION_CACHE_DIR+"/Proxy.json").new)die("rollback/alert mismatch\n");
view=json(command_output_from_args(["curl","-fsS","http://127.0.0.1:19097/proxies"]));
if(view.proxies.Proxy.now!="b")die("rollback lost the removed manual selection\n");
print("PASS: failed acknowledgment rolled back configuration/UI cache and stored an explicit alert\n");
UC
} > "$WORK/check.uc"
ucode -L "$FORKOP_LIB" "$WORK/check.uc"
