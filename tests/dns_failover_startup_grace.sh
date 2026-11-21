#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FORKOP_LIB="$ROOT/forkop/files/usr/lib"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
{
cat <<'UC'
let runtime_health=require("core.runtime_health");
let now=0, probes=[], applies=[], finished=false;
const STATE_FILE="state",LIB_DIR="lib",STATE_UC="state.uc",CORE_GRACE_SECONDS=90;
let common={read_json_file: () => ({version:1, health:{}, main_servers:["a","b"],
    bootstrap_servers:["a","b"],main_index:0,bootstrap_index:0})};
function duration_seconds(v,f){return f;}
function probe_timeout(v){return 2;}
function failure_threshold(v){return 3;}
function now_seconds(){return now;}
function clock(monotonic){return [now,0];}
function command_output_from_args(args){
 if(now>=110 && now<120)return "";
 return sprintf("%J",{pid:now<100?42:43,start_ticks:now<100?100:200});
}
function command_success_from_args(args){if(now>=230){finished=true;die("fixture done");}now+=10;return true;}
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
sed -n '/^function failover_confirmed(/,/^}/p' "$FORKOP_LIB/xrust/dns_failover.uc"
sed -n '/^function worker(/,/^}/p' "$FORKOP_LIB/xrust/dns_failover.uc"
cat <<'UC'
try { worker(); } catch(e) { if(!finished) die(e); }
assert(finished, "worker exited before fixture finished");
if(length(probes)!=8)die("unexpected startup/restart probe count\n");
for(let probe in probes)
 if(probe.recovery || (probe.now!=90 && probe.now!=210 && probe.now!=220 && probe.now!=230))die("probe inside startup grace\n");
if(sprintf("%J",applies)!="[ 230 ]")die("stale failure strikes survived restart/absence\n");
print("DNS worker startup/restart grace and strike-reset checks passed\n");
UC
} > "$WORK/worker.uc"
ucode -L "$FORKOP_LIB" "$WORK/worker.uc"

{
cat <<'UC'
const STATE_FILE = "state", LIB_DIR = "lib", STATE_UC = "state.uc", CORE_GRACE_SECONDS = 90;
let now, sustained_outage, switches, finished;
let common = { read_json_file: () => ({ version: 1, health: { failure_threshold: "3" },
    main_servers: ["primary", "backup"], bootstrap_servers: ["primary", "backup"],
    main_index: 0, bootstrap_index: 0 }) };
let runtime_health = { observe_runtime: () => ({ ready: true }) };
function settings() { die("worker read unapplied settings"); }
function duration_seconds(value, fallback) { return fallback; }
function probe_timeout() { return 2; }
function failure_threshold(value) { return int(value); }
function now_seconds() { return now; }
function clock() { return [now, 0]; }
function command_output_from_args() { return "{}"; }
function command_success_from_args() {
    if (now >= 120) {
        finished = true;
        die("fixture done");
    }
    now++;
    return true;
}
function probe_port(kind, index, timeout) {
    return index == 1 || (sustained_outage ? now < 60 || now >= 100 : now != 60);
}
function apply_selections(state, selections) {
    let main = selections.main != null ? selections.main.index : state.main_index;
    let bootstrap = selections.bootstrap != null ? selections.bootstrap.index : state.bootstrap_index;
    if (state.main_index != main || state.bootstrap_index != bootstrap)
        push(switches, [now, main, bootstrap]);
    state.main_index = main;
    state.bootstrap_index = bootstrap;
    return true;
}
function log_message() {}
function update_dns_outage() {}
UC
sed -n '/^function choose_index(/,/^}/p; /^function failover_confirmed(/,/^}/p; /^function worker(/,/^}/p' \
    "$FORKOP_LIB/xrust/dns_failover.uc"
cat <<'UC'
function run_worker() {
    finished = false;
    try { worker(); } catch(e) { if (!finished) die(e); }
    assert(finished, "worker exited on unapplied edit");
}
now = 0;
sustained_outage = false;
switches = [];
run_worker();
assert(length(switches) == 0, "recovery timer bypassed failover threshold");
now = 0;
sustained_outage = true;
switches = [];
run_worker();
assert(sprintf("%J", switches) == "[ [ 80, 1, 1 ], [ 120, 0, 0 ] ]",
    "three failures should switch both resolvers; recovery should restore their higher priorities");
print("DNS worker honors failure threshold and higher-priority recovery despite unapplied UCI changes\n");
UC
} > "$WORK/recovery-timer.uc"
ucode "$WORK/recovery-timer.uc"

ucode -L "$FORKOP_LIB" -e '
let dns = require("xrust.dns");
let applied = dns.state_template({dns_server: ["192.0.2.1", "192.0.2.2"]});
applied.config_path = "/active/config.json";
let selection = dns.failover_selection(applied, {...applied, main_index: 1, config_path: "/edited/config.json"});
assert(selection.config_path == "/active/config.json");
assert(dns.server_config_from_state(selection).server == "192.0.2.2");
assert(dns.failover_selection(applied, {...applied, main_index: 2}) == null);
assert(dns.failover_selection(applied, {...applied, main_servers: ["192.0.2.3"]}) == null);
'

cat > "$WORK/uci" <<'UCI'
forkop.inherited=section
forkop.explicit=section
forkop.explicit.native_tunnel_dns_address=9.9.9.9
UCI
{
cat <<'UC'
let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let runtime_dns = require("xrust.dns");
let connections = require("config.connections");
const CONFIG_NAME = "forkop", STATE_FILE = ARGV[0], SECTION_CACHE_DIR = ARGV[1];
let cfg = { config_path: "/old/config.json", dns_server: ["192.0.2.1", "192.0.2.2"] };
function settings() { return cfg; }
UC
sed -n '/^function applied_worker_state(/,/^}/p' "$FORKOP_LIB/xrust/dns_failover.uc"
cat <<'UC'
let state = applied_worker_state(false);
assert(state.config_path == "/old/config.json");
assert(join(",", state.inherited_tunnel_dns) == runtime_dns.tunnel_dns_tag("inherited"));
fs.writefile(STATE_FILE, sprintf("%J", state));
cfg = { config_path: "/draft/config.json", dns_server: ["192.0.2.3"], dns_failover_failure_threshold: "9" };
let committed = { ...state, config_path: "/committed/config.json", main_servers: ["198.51.100.1", "198.51.100.2"],
    health: runtime_dns.health_settings({ dns_failover_failure_threshold: "5" }) };
assert(common.write_private_json_file(SECTION_CACHE_DIR + "/" + runtime_dns.APPLIED_DNS_CACHE_NAME, committed));
let next = applied_worker_state(false);
assert(next.config_path == "/committed/config.json" && next.main_servers[1] == "198.51.100.2");
assert(next.health.failure_threshold == "5");
let restored = applied_worker_state(true);
assert(restored.config_path == state.config_path && restored.main_servers[0] == state.main_servers[0]);
UC
} >"$WORK/applied.uc"
FORKOP_UCI_STATE_FILE="$WORK/uci" ucode -L "$FORKOP_LIB" "$WORK/applied.uc" "$WORK/applied.json" "$WORK"
echo 'DNS worker startup captures the applied path and inherited tunnel resolvers'
