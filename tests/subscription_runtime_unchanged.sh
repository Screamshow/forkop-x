#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
{
cat <<'UC'
let current, candidate, running, prepare_ok, publish_ok, calls;
let subscription_outbounds_changed=false;
let subscription_failure_detail=null;
const LIB_DIR="lib", PRIORITY_UC="priority", DNS_FAILOVER_UC="dns", SECTION_CACHE_DIR="section-cache";
function trim(v){return replace(v,/^[ \t\r\n]+|[ \t\r\n]+$/g,"");}
function service_state_success(args){push(calls,join(" ",args));if(args[0]=="sing-box-current-owned-service-runtime"||args[0]=="sing-box-service-running")return running;die("unexpected service mutation\n");}
function command_output_from_args(args){return "probe";}
function command_success_from_args(args){push(calls,join(" ",args));return true;}
let fs={chmod:function(p,m){return true;},stat:function(p){return null;}};
function read_json_file(path){return path=="config"?current:candidate;}
function xrust_runtime_success(args){
 push(calls,join(" ",args));
 if(args[0]=="prepare-config-stage")return prepare_ok;
 if(args[0]=="publish-section-cache")return publish_ok;
 if(args[0]=="discard-config-stage")return true;
 if(args[0]=="commit-config-stage")return true;
 die("unexpected runtime mutation\n");
}
function option(s,k,f){return s[k]||f;}
let desired="config";
const CONFIG_NAME="forkop", xrust={APPLIED_CONFIG_PATH_FILE:"pointer"};
let uci_core={reload:()=>true};
function uci_settings(){return {config_path:desired};}
function file_first_line_value(path){assert(path=="pointer");return "config";}
function mark_pending_reload(reason){push(calls,reason);return true;}
function current_proxy_outbounds_signature(p){return "same-proxies";}
function subscription_prepare_cache_request(a,b,c){return {ok:true,updated:1,failed:0};}
function log_message(m,l){push(calls,"log:"+m);}
function module_capture(args){push(calls,join(" ",args));return {status:0,output:"hot"};}
function module_success(args){push(calls,join(" ",args));return true;}
UC
sed -n '/^function subscription_config_value(/,/^}/p' "$ROOT/forkop/files/usr/lib/components/updates.uc"
sed -n '/^function subscription_hot_transition(/,/^}/p' "$ROOT/forkop/files/usr/lib/components/updates.uc"
sed -n '/^function subscription_runtime_change_check(/,/^}/p' "$ROOT/forkop/files/usr/lib/components/updates.uc"
sed -n '/^function subscription_update_common_locked(/,/^}/p' "$ROOT/forkop/files/usr/lib/components/updates.uc"
cat <<'UC'
let fixture={outbounds:[{type:"vless",tag:"p",server:"node.invalid",server_port:443},{type:"selector",tag:"section",outbounds:["p","direct"]}],route:{final:"section"},dns:{servers:[{tag:"dns",server:"1.1.1.1"}]}};
function reset(){current=json(sprintf("%J",fixture));candidate=json(sprintf("%J",fixture));running=true;prepare_ok=true;publish_ok=true;calls=[];}
function expect(changed,ok){let result=subscription_runtime_change_check("config");if(result.changed!=changed||result.ok!=ok)die("comparison outcome mismatch\n");}
reset();
// Formatting/key order may differ; array order remains meaningful.
candidate={dns:fixture.dns,route:fixture.route,outbounds:fixture.outbounds};
if(!subscription_update_common_locked(true,"section",0))die("unchanged update failed\n");
let text=join("\n",calls);
if(index(text,"publish-section-cache")<0||index(text,"reload skipped")<0||index(text,"stop-managed")>=0)die("unchanged runtime was disturbed\n");
reset();candidate.outbounds[0].server="other.invalid";expect(true,true);
reset();candidate.outbounds[0].server="other.invalid";
if(!subscription_update_common_locked(true,"section",0))die("changed update failed\n");
if(length(filter(calls, call => index(call,"prepare-config-stage ")==0))!=1 ||
    index(calls,"lib/service/hot_reload.uc plan probe/candidate.json config")<0 ||
    index(calls,"commit-config-stage probe/candidate.json probe/previous.json config")<0 ||
    index(calls,"rm -rf probe")<0)
    die("changed subscription regenerated or leaked its staged candidate\n");
reset();candidate.outbounds[1].outbounds=["direct","p"];expect(true,true);
reset();candidate.route.final="direct";expect(true,true);
reset();candidate.dns.servers[0].server="9.9.9.9";expect(true,true);
reset();candidate.outbounds[1].type="urltest";candidate.outbounds[1].interval="5m";expect(true,true);
reset();candidate=null;expect(true,false);
reset();prepare_ok=false;expect(true,false);
reset();publish_ok=false;expect(false,false);
reset();running=false;expect(true,true);if(length(calls)!=1)die("stopped runtime staged/skipped\n");
reset();running=false;
if(!subscription_update_common_locked(true,"section",0)||length(calls)!=1)die("subscription update tried to start a stopped service\n");
reset();desired="inactive-config";
if(!subscription_update_common_locked(true,"section",0)||
    index(calls,"subscription_config_path_changed")<0||
    index(join("\n",calls),"prepare-config-stage")>=0)
    die("subscription update tried to apply an inactive config path\n");
desired="config";
reset();prepare_ok=false;if(subscription_update_common_locked(true,"section",0))die("failed preparation accepted\n");
print("Subscription unchanged runtime, semantic changes, stopped service and preparation failure checks passed\n");
UC
} > "$WORK/check.uc"
ucode "$WORK/check.uc"
