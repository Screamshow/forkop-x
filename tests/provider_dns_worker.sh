#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
{
cat <<'UC'
let now=0,reloads=[],finished=false;
const STATE_FILE='state',LIB_DIR='lib',STATE_UC='state',CORE_GRACE_SECONDS=90,SERVICE_BIN='/usr/bin/forkop';
const WAN_RELOAD_RETRY_SECONDS=60;
let provider_mode=ARGV[0]=='provider';
let common={read_json_file: () => ({version:1, provider:provider_mode, ntp_wan_routes:provider_mode?null:['a'],
    main_servers:['a'], bootstrap_servers:['a'], health:{}})};
function wan_servers(){return now==0||now==120?['a']:now==10?[]:now<50||now==130?['b']:['c'];}
let provider_dns={discover:wan_servers};
let runtime_dns={
 state_template:function(cfg){
    assert(provider_mode&&cfg.dns_use_provider=="1","the applied provider mode was lost");
    let servers=wan_servers();
    return { provider:true, main_servers:servers, provider_routes:servers };
 },
 state_matches: (a,b) => a.main_servers[0]==b.main_servers[0]
};
function settings(){die("draft UCI cannot influence the worker");}
function as_string(v){return ''+v;}
function write_state(){return true;}
function duration_seconds(v,f){return f;}
function probe_timeout(){return 2;}
function failure_threshold(){return 3;}
function now_seconds(){return now;}
function command_success_from_args(args){
    if(now>=130){finished=true;die("fixture done");}
    now+=int(args[1]);return true;
}
function command_status(command){if(index(command,'reload')<0)die('wrong command');push(reloads,now);return 0;}
function command_from_args(args){return join(' ',args);}
function log_message(){}
UC
sed -n '/^function worker(/,/^}/p' "$ROOT/forkop/files/usr/lib/xrust/dns_failover.uc"
cat <<'UC'
try { worker(); } catch(e) { if(!finished) die(e); }
let expected=provider_mode?"[ 20, 50, 110, 130 ]":"[ 10, 20, 50, 110, 130 ]";
assert(finished && sprintf("%J",reloads)==expected,sprintf("unexpected WAN reload requests: %J",reloads));
print(ARGV[0], ' DNS worker deduplicates WAN reloads, retries and reacts to a different WAN immediately\n');
UC
} > "$WORK/worker.uc"
ucode "$WORK/worker.uc" provider
ucode "$WORK/worker.uc" ntp
