#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FORKOP_LIB="$ROOT/forkop/files/usr/lib"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
{
cat <<'UC'
let runtime_health=require("core.runtime_health");
let now=0, probes=[], applies=[];
const STATE_FILE="state",LIB_DIR="lib",STATE_UC="state.uc",CORE_GRACE_SECONDS=90;
let common={read_json_file:function(p){return{};},option:function(c,k,f){return f;}};
let runtime_dns={normalize_state:function(c,s){return {main_servers:["a","b"],bootstrap_servers:["a","b"],main_index:0,bootstrap_index:0};},state_template:function(c){return{};},state_matches:function(t,s){return now<=230;}};
function settings(){return{};}
function write_state(p,s){return true;}
function duration_seconds(v,f){return f;}
function probe_timeout(v){return 2;}
function failure_threshold(v){return 3;}
function now_seconds(){return now;}
function clock(monotonic){return [now,0];}
function command_output_from_args(args){
 if(now>=110 && now<120)return "";
 return sprintf("%J",{pid:now<100?42:43,start_ticks:now<100?100:200});
}
function command_success_from_args(args){now+=10;return true;}
function choose_index(kind,state,current,timeout,recovery){
 push(probes,{now,recovery});return {index:1,alive:false};
}
function apply_selections(state,selections){
 if(length(keys(selections))>0)push(applies,now);
 return true;
}
function log_message(m,l){}
function update_dns_outage(){}
UC
sed -n '/^function failover_confirmed(/,/^}/p' "$FORKOP_LIB/singbox/dns_failover.uc"
sed -n '/^function worker(/,/^}/p' "$FORKOP_LIB/singbox/dns_failover.uc"
cat <<'UC'
if(worker()!=0)die("worker termination\n");
if(length(probes)!=8)die("unexpected startup/restart probe count\n");
for(let probe in probes)
 if(probe.recovery || (probe.now!=90 && probe.now!=210 && probe.now!=220 && probe.now!=230))die("probe inside startup grace\n");
if(sprintf("%J",applies)!="[ 230 ]")die("stale failure strikes survived restart/absence\n");
print("DNS worker startup/restart grace and strike-reset checks passed\n");
UC
} > "$WORK/worker.uc"
ucode -L "$FORKOP_LIB" "$WORK/worker.uc"
