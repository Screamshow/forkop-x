#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
{
cat <<'UC'
let now=0,reloads=0;
const STATE_FILE='state',LIB_DIR='lib',STATE_UC='state',CORE_GRACE_SECONDS=90,SERVICE_BIN='/usr/bin/forkop';
let common={read_json_file:function(){return{};},option:function(c,k,f){return f;}};
let runtime_dns={
 normalize_state:function(){return {provider:true,main_servers:['a'],bootstrap_servers:['a']};},
 state_template:function(){return {provider:true,main_servers:now==10?[]:['b']};},
 state_matches:function(){return now==0;}
};
function settings(){return{};}
function as_string(v){return ''+v;}
function write_state(){return true;}
function duration_seconds(v,f){return f;}
function probe_timeout(){return 2;}
function failure_threshold(){return 3;}
function now_seconds(){return now;}
function command_success_from_args(args){now+=int(args[1]);return true;}
function command_status(command){if(index(command,'reload')<0)die('wrong command');reloads++;return 0;}
function command_from_args(args){return join(' ',args);}
function log_message(){}
UC
sed -n '/^function worker(/,/^}/p' "$ROOT/forkop/files/usr/lib/singbox/dns_failover.uc"
cat <<'UC'
let status=worker();
if(status!=0 || reloads!=1 || now!=21)die(sprintf('provider worker recovery: status=%d reloads=%d now=%d\n',status,reloads,now));
print('Provider DNS worker single-server, all-offline and WAN-change checks passed\n');
UC
} > "$WORK/worker.uc"
ucode "$WORK/worker.uc"
