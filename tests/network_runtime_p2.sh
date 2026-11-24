#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/forkop/files/usr/lib"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export FORKOP_RUNTIME_STATE_DIR="$WORK/runtime"
mkdir -p "$FORKOP_RUNTIME_STATE_DIR"

ucode -L "$LIB" -e '
let fs = require("fs"), common = require("core.common");
let xrust = require("xrust.binary");
let config_path = ARGV[0] + "/old-config.json";
fs.writefile(xrust.APPLIED_CONFIG_PATH_FILE, config_path + "\n");
common.write_private_json_file(config_path, {experimental:{clash_api:{external_controller:"192.168.2.1:9090"}}});
let clash = require("xrust.clash_api");
let calls = 0;
fs.popen = function() {
    calls++;
    return {read: () => "{\"up\":true,\"l3_device\":\"br-lan\",\"ipv4-address\":[{\"address\":\"192.168.3.1\"}]}", close: () => 0};
};
assert(clash.local_request_address() == "192.168.2.1" && calls == 0);
assert(clash.listen_address() == "192.168.3.1");
common.write_private_json_file(config_path, {experimental:{clash_api:{external_controller:"0.0.0.0:9090"}}});
assert(clash.local_request_address() == "127.0.0.1");
print("#20 applied Clash bind remains valid through a LAN address change\n");
' "$WORK"
FORKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/service/initd.uc" trigger-plan |
  grep -q $'interface\tinterface\\.\\*\tlan\t.*\treload\tlan-api-address'

{
    cat <<'UC'
let core_ip = require("core.ip");
let runtime_dns = require("xrust.dns");
const SECTION_CACHE_DIR = "/applied";
function words(text) { return split(trim(text), /[ \t]+/); }
function valid_ipv4(value) { return core_ip.valid_ipv4(value, false, true); }
function as_string(value) { return "" + value; }
let response, last_args, applied;
function read_json_file(path) {
    assert(path == SECTION_CACHE_DIR + "/" + runtime_dns.APPLIED_DNS_CACHE_NAME);
    return applied;
}
function command_output_from_args(args) {
    last_args = args;
    return response;
}
function clock(monotonic) { return monotonic ? [91, 0] : [1000000, 0]; }
UC
    sed -n '/^function dns_check_bootstrap(/,/^}/p; /^function dns_check_has_ipv4_answer(/,/^}/p; /^function dns_check_router_resolver_available(/,/^}/p' "$LIB/diagnostics/runtime.uc"
    sed -n '/^function now_seconds(/,/^}/p' "$LIB/xrust/dns_failover.uc"
    cat <<'UC'
let answer = "example.com.\t600\tIN\tA\t192.0.2.10\n";
let header = ";; ->>HEADER<<- opcode: QUERY, status: ";
for (let error in ["NXDOMAIN", "SERVFAIL", "REFUSED"]) {
    response = header + error + ", id: 1\n" + answer;
    assert(!dns_check_router_resolver_available("example.com", 2), "accepted RCODE " + error);
}
response = header + "NOERROR, id: 1\n";
assert(!dns_check_router_resolver_available("example.com", 2), "accepted an empty successful response");
response += answer;
assert(dns_check_router_resolver_available("example.com", 2), "did not recognize a successful A response");
assert(index(last_args, "@" + runtime_dns.DNS_HEALTH_ADDRESS) < 0, "system DNS probe explicitly targeted Xrust");

let active = { state: { bootstrap_index: 1 } };
response = "192.0.2.10\n";
assert(dns_check_bootstrap(active, "example.com", 2));
assert(index(last_args, "-b") < 0 && last_args[index(last_args, "-p") + 1] == "" + runtime_dns.health_port("bootstrap", 1));
applied = { health_probe_mode: "loopback-source-v1" };
assert(dns_check_bootstrap(active, "example.com", 2));
assert(last_args[index(last_args, "-b") + 1] == "127.32.0.2" &&
    last_args[index(last_args, "-p") + 1] == "" + runtime_dns.health_port("active", 0));
assert(now_seconds() == 91, "failover scheduling uses the wall clock");
print("#21 checked system and Bootstrap DNS probes, #22 failover uses monotonic time\n");
UC
} >"$WORK/dns.uc"
ucode -L "$LIB" "$WORK/dns.uc"

ucode -L "$LIB" -e '
let dns = require("xrust.dns");
let expected = "[2001:db8::53]";
let address = expected + ":8443/custom-query";
for (let server in [ dns.server_from_options("main", "doh", address, ""),
    dns.bootstrap_config_from_state({bootstrap_dns_type:"doh", bootstrap_servers:[address], bootstrap_index:0}),
    dns.tunnel_dns_server({}, "tunnel", "egress", address, "doh") ]) {
    assert(server.server == "2001:db8::53" && server.server_port == 8443 && server.path == "/custom-query");
    assert(server.tls.server_name == expected && server.tls.verify_server_name == "2001:db8::53" &&
        server.tls.disable_sni == true && server.tls.insecure == null);
}
print("#53 IPv6 DoH uses a bracketed authority and strict IP SAN for main, bootstrap, DNS action and tunnel paths\n");
'

{
    cat <<'UC'
let fs = require("fs");
let core_ip = require("core.ip");
const DIR = ARGV[0] + '/support', CANCELLED = DIR + '/cancelled', SERVICE = '/fixture/support';
const STATE = ARGV[0] + '/native', STATUS = ARGV[0] + '/native-status';
const START_DEADLINE = ARGV[0] + '/native-deadline', INIT = '/fixture/native';
let stop_called = false, start_calls = 0, clock_seconds = 100, wall_offset = 0;
let support_running = false;
function session_service_running() { return support_running; }
function read_json(path) { return json(fs.readfile(path) || '{}'); }
function status() { assert(stop_called, "awaited status before revoking the support session"); return {}; }
function clock(monotonic) { return [monotonic ? clock_seconds : time() + wall_offset, 0]; }
function system(command, timeout) {
    if (index(command, SERVICE) >= 0) {
        assert(fs.stat(CANCELLED) != null && fs.stat(DIR + '/auth.key') == null);
        assert(timeout == 8000);
        stop_called = true;
        return 0;
    }
    if (index(command, ' start ') >= 0) return ++start_calls == 1 ? 1 : 0;
    return 0;
}
UC
    sed -n '/^function request(/,/^}/p' "$LIB/support/session.uc"
    sed -n '/^function mark_connecting(/,/^}/p; /^function start_pending(/,/^}/p;
            /^function native_flag_write(/,/^}/p; /^function change_native_setting(/,/^}/p;
            /^function private_lan_routes(/,/^}/p' "$LIB/tailscale/action.uc"
    cat <<'UC'
fs.mkdir(DIR);
fs.writefile(DIR + '/operation', 'start');
fs.writefile(DIR + '/auth.key', 'fixture');
request({operation:'stop'});
assert(stop_called && fs.readfile(CANCELLED) == '1\n');
fs.writefile(DIR + '/operation', 'install');
fs.mkdir(DIR + '/lock');
function blocked_stop() {
    try { request({operation:'stop'}); } catch (e) { return true; }
    return false;
}
assert(blocked_stop(), "lost procd startup grace");
wall_offset = 60;
support_running = true;
assert(blocked_stop(), "interrupted a live support installation");
support_running = null;
assert(blocked_stop(), "treated ubus failure as a dead worker");
support_running = false;
request({operation:'stop'});
assert(!fs.stat(DIR + '/lock'), "stale support operation blocked retry");

let routes = private_lan_routes({up:true, l3_device:'br-lan', 'ipv4-address':[
    {address:'172.20.1.1', mask:8}, {address:'192.168.1.1', mask:15}, {address:'10.1.0.2', mask:7},
    {address:'172.20.1.1', mask:12}, {address:'192.168.1.1', mask:24}, {address:'10.1.0.2', mask:8}
]});
assert(join(',', routes.routes) == '10.0.0.0/8,172.16.0.0/12,192.168.1.0/24');
fs.mkdir(STATE);
fs.writefile(STATE + '/enabled', '1');
let error = change_native_setting(STATE + '/ssh-enabled', '1');
assert(length(error) > 0 && fs.stat(STATE + '/ssh-enabled') == null && start_calls == 2);
assert(start_pending());
clock_seconds += 21;
assert(!start_pending(), "failed startup never expires");
print("#26 support stop revokes locally, #28 whole LAN route is private, #29 restart rollback and deadline\n");
UC
} >"$WORK/native.uc"
ucode -L "$LIB" "$WORK/native.uc" "$WORK"

{
  cat <<'UC'
let fs = require('fs');
const DIR = ARGV[0], STATE = DIR, INIT = '/fixture/init', CONTROL_LOCK = '/fixture/lock';
let calls = 0, output_count = 0, owned = false, allowed = ARGV[1] != 'busy';
function output(command) { output_count++; return 'fixture-version'; }
function system(command) { assert(owned); calls++; return ARGV[1] == 'failed' ? 1 : 0; }
let locks = { acquire: () => { owned = allowed; return owned; }, release: () => { owned = false; } };
function result(value) {
  assert(!owned && value.state == 'error');
  assert(ARGV[1] == 'busy' ? calls == 0 && fs.stat(STATE + '/enabled') != null : calls == 2);
}
UC
  sed -n '/^function read_json(/,/^}/p; /^function version(/,/^}/p' "$LIB/support/session.uc"
  sed -n '/^function native_flag_write(/,/^}/p; /^function run_native_action(/,/^}/p' "$LIB/tailscale/action.uc"
  cat <<'UC'
fs.writefile(STATE + '/enabled', '1');
let path = DIR + '/test-binary', cache = DIR + '/test-cache';
fs.writefile(path, 'a');
fs.unlink(cache);
assert(version('fixture', path, cache) == 'fixture-version');
assert(version('fixture', path, cache) == 'fixture-version' && output_count == 1);
fs.writefile(path, 'changed');
assert(version('fixture', path, cache) == 'fixture-version' && output_count == 2);
UC
  sed -n '/^} else if (action == '\''disconnect'\'') {$/,/^} else if (action == '\''ssh'\''/p' "$LIB/tailscale/action.uc" | sed '1d;$d'
  printf '%s\n' "assert(ARGV[1] == 'ok' && !owned && calls == 2 && !fs.stat(STATE + '/enabled'));"
} >"$WORK/controls.uc"
for mode in busy failed ok; do ucode "$WORK/controls.uc" "$WORK" "$mode"; done

mkdir -p "$WORK/bin"
cat >"$WORK/bin/sysctl" <<'SH'
#!/bin/sh
case "$2" in *ip6tables*) state="$BRIDGE_FIXTURE/v6" ;; *) state="$BRIDGE_FIXTURE/v4" ;; esac
case "$1" in
    -n) cat "$state" ;;
    -w) case "$2" in
        *ip6tables=0) [ "${FAIL_V6:-0}" = 0 ] || exit 1 ;;
        esac
        printf '%s\n' "${2##*=}" >"$state" ;;
esac
SH
chmod +x "$WORK/bin/sysctl"
export PATH="$WORK/bin:$PATH" BRIDGE_FIXTURE="$WORK"
printf '0\n' >"$WORK/v4"
printf '1\n' >"$WORK/v6"
ucode -L "$LIB" "$LIB/nft/apply.uc" ensure-bridge-netfilter-disabled
grep -qx 0 "$WORK/v6"
ucode -L "$LIB" "$LIB/nft/apply.uc" restore-bridge-netfilter
grep -qx 0 "$WORK/v4"
grep -qx 1 "$WORK/v6"
printf '1\n' >"$WORK/v4"
if FAIL_V6=1 ucode -L "$LIB" "$LIB/nft/apply.uc" ensure-bridge-netfilter-disabled; then exit 1; fi
ucode -L "$LIB" "$LIB/nft/apply.uc" restore-bridge-netfilter
grep -qx 1 "$WORK/v4"
grep -qx 1 "$WORK/v6"
test ! -f "$FORKOP_RUNTIME_STATE_DIR/bridge-netfilter.json"
echo '#51 bridge sysctls are handled and restored separately'

cat >"$WORK/bin/nft" <<'SH'
#!/bin/sh
case "$*" in
    'list tables'|'list table inet ForkopTable') echo 'table inet ForkopTable' ;;
    'list chain inet ForkopTable mangle'|'list chain inet ForkopTable mangle_output')
        echo 'meta mark set 0x100 counter packets 0 bytes 0 return' ;;
    'list chain inet ForkopTable priority_rules'|'list chain inet ForkopTable priority_output_rules')
        echo 'counter packets 19 bytes 2100 accept'
        if [ "$NFT_DIAG_MARKED" = 1 ]; then
            echo 'meta mark set 0x100 counter packets 7 bytes 800 accept'
        else
            echo 'meta mark set 0x100 counter packets 0 bytes 0 accept'
        fi ;;
    'list chain inet ForkopTable proxy') echo 'tproxy ip to :1602 counter packets 7 bytes 800' ;;
    *) exit 1 ;;
esac
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/curl"
chmod +x "$WORK/bin/nft" "$WORK/bin/curl"
for marked in 0 1; do
    NFT_DIAG_MARKED="$marked" FORKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/diagnostics/runtime.uc" check-nft-rules |
        ucode -e '
            let result = json(require("fs").readfile("/dev/stdin"));
            let marked = int(ARGV[0]);
            assert(result.table_exist && result.rules_mangle_exist && result.rules_mangle_output_exist);
            assert(result.rules_mangle_counters == marked && result.rules_mangle_output_counters == marked);
            assert(result.rules_proxy_exist && result.rules_proxy_counters);
        ' "$marked"
done
echo 'nftables diagnostics count priority-chain marking without counting bypass'
