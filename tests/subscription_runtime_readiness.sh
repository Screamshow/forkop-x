#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FORKOP_LIB="$ROOT/forkop/files/usr/lib"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
{
cat <<'UC'
let runtime_health=require("core.runtime_health"), netstat=require("core.netstat");
let config, snapshot, observations, identity, sleeps;
function as_string(v) {return v==null?"":""+v;}
function int_value(v) {return int(v);}
function read_json_file(path) {return config;}
function sing_box_runtime_provenance() { observations++; return observations==3 && !identity ? {pid:43,start_ticks:200} : {pid:42,start_ticks:100}; }
function pid_has_current_sing_box_exe(pid) {return true;}
function command_output_from_args(args) {return snapshot;}
function command_success_from_args(args) {sleeps++; return true;}
let fs={glob:function(p){return[];},stat:function(p){return null;}};
UC
sed -n '/^function wait_managed_sing_box_config_listeners(/,/^}/p' "$FORKOP_LIB/service/state.uc"
cat <<'UC'
function run(c,s,want) {
 config=c; snapshot=s; observations=0; identity=true; sleeps=0;
 if(wait_managed_sing_box_config_listeners("fixture",0)!=want) die("readiness outcome mismatch\n");
}
let tcp="tcp 0 0 127.0.0.42:53 0.0.0.0:* LISTEN 42/sing-box";
let udp="udp 0 0 127.0.0.42:53 0.0.0.0:* 42/sing-box";
let dns={inbounds:[{type:"direct",listen:"127.0.0.42",listen_port:53}]};
run(dns,tcp+"\n"+udp,true);
run(dns,tcp,false);
run(dns,udp,false);
run(dns,replace(tcp+"\n"+udp,"42/sing-box","99/sing-box"),false);
run({inbounds:[{type:"mixed",listen:"127.0.0.42",listen_port:53}]},tcp,true);
run({inbounds:[]},"",true);
run(null,"",false);
run({inbounds:[{type:"tun",interface_name:"tun0"}]},"",false);
config=dns; snapshot=tcp+"\n"+udp; observations=0; identity=false;
if(wait_managed_sing_box_config_listeners("fixture",0)) die("PID snapshot race accepted\n");
print("Managed readiness fault checks passed\n");
UC
} > "$WORK/listeners.uc"
ucode -L "$FORKOP_LIB" "$WORK/listeners.uc"

# Run the actual subscription transition with faulted startup/readiness.
# All external effects are mocks: no daemon, UCI or firewall is changed.
{
cat <<'UC'
let subscription_outbounds_changed=false;
let subscription_failure_detail=null;
function subscription_apply_failure(reason,state){subscription_failure_detail={reason,state};return false;}
function subscription_hot_transition(p){return {handled:false};}
let PRIORITY_UC="priority", DNS_FAILOVER_UC="dns", LIB_DIR="lib";
let fail_ready, fail_start, fail_init, fail_recovery, fail_snapshot, calls, config, readiness_calls;
function trim(v) {return replace(v,/^[ \t\r\n]+|[ \t\r\n]+$/g,"");}
function as_string(v){return v==null?"":""+v;}
function option(s,k,f){return s[k]||f;}
function uci_settings(){return {config_path:"config"};}
function current_proxy_outbounds_signature(p){return "unchanged";}
function subscription_prepare_cache_request(a,b,c){return {ok:true,updated:1,failed:0};}
function subscription_runtime_change_check(p){return {ok:true,changed:true};}
function module_capture(args){return {status:0};}
function validation_failure_message(v){return "validation failed";}
function log_message(m,l){push(calls,"log:"+m);}
function command_output_from_args(args){return "backup-dir";}
function command_success_from_args(args){push(calls,join(" ",args));return true;}
let fs={readfile:function(p){return config;},chmod:function(p,m){return true;},stat:function(p){return {};}};
let common={write_private_file:function(p,v){return length(v);}};
function module_success(args){push(calls,join(" ",args));return !(args[1]=="save-selector-state" && fail_snapshot);}
function singbox_runtime_success(args){
 push(calls,join(" ",args));
 if(args[0]=="restore-config-stage"){config="old"; return true;}
 if(args[0]=="init-config"){config="new";return !fail_init;}
 return true;
}
function service_state_success(args){
 push(calls,join(" ",args));
 if(args[0]=="start-managed-sing-box-runtime" && config=="new" && fail_start)return false;
 if(args[0]=="wait-managed-sing-box-config-listeners"){
   readiness_calls++;
   return config=="new" ? !fail_ready : !fail_recovery;
 }
 return true;
}
function write_current_reload_state_clean(){push(calls,"clean");return true;}
function schedule_automatic_latency_test(s){return true;}
UC
sed -n '/^function subscription_restore_selectors(/,/^}/p' "$FORKOP_LIB/components/updates.uc"
sed -n '/^function subscription_restore_runtime(/,/^}/p' "$FORKOP_LIB/components/updates.uc"
sed -n '/^function subscription_update_common_locked(/,/^}/p' "$FORKOP_LIB/components/updates.uc"
cat <<'UC'
function run(ready,start,init,recovery,want) {
 fail_ready=ready;fail_start=start;fail_init=init;fail_recovery=recovery;fail_snapshot=false;calls=[];config="old";readiness_calls=0;
 if(subscription_update_common_locked(true,"section",0)!=want)die("subscription fault result\n");
 let text=join("\n",calls);
 if(index(text,"clean")>=0)die("subscription update marked unrelated UCI settings as applied\n");
 if(index(text,"save-selector-state")<0 || index(text,"save-selector-state")>index(text,"stop-managed-sing-box-runtime"))die("selector snapshot missing/late\n");
 if(!recovery && (index(text,"restore-selector-state")<0 || index(text,"restore-selector-state")>index(text,"priority start-runtime")))die("selector restore missing/late\n");
 if(want){
   if(config!="new" || readiness_calls!=1 || index(text,"restore-config-stage")>=0)die("success transition\n");
   if(index(text,"wait-managed-sing-box-config-listeners")>index(text,"priority start-runtime"))die("helpers started before ready\n");
 }else{
   if(config!="old" || index(text,"restore-config-stage backup-dir/previous.json.restore")<0)die("old runtime not restored\n");
   if(recovery){
     if(index(text,"rm -rf backup-dir")>=0 || index(text,"priority start-runtime")>=0)die("failed recovery backup/helpers\n");
   }else if(index(text,"priority start-runtime")<0 || index(text,"dns start-runtime")<0)die("recovered workers missing\n");
 }
}
run(false,false,false,false,true);
run(true,false,false,false,false);
run(false,true,false,false,false);
run(false,false,true,false,false);
run(true,false,false,true,false);
fail_snapshot=true;calls=[];config="old";
if(subscription_update_common_locked(true,"section",0))die("failed snapshot accepted\n");
if(config!="old" || index(join("\n",calls),"stop-managed-sing-box-runtime")>=0)die("snapshot failure disturbed runtime\n");
print("Subscription readiness and rollback fault checks passed\n");
UC
} > "$WORK/subscription.uc"
ucode -L "$FORKOP_LIB" "$WORK/subscription.uc"
