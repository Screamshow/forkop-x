#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
{
cat <<'UC'
const SINGBOX_UC='runtime',HOT_RELOAD_UC='hot',DNS_FAILOVER_UC='dns',CONFIG_NAME='forkop';
let scenario='',calls=[],removed=[];
function as_string(v){return v==null?'':''+v;}
function module_capture(mod,args){
 push(calls,args[0]);
 if(args[0]=='prepare-dns-config')return {status:scenario=='prepare-fail'?1:0,output:(scenario=='unchanged'?'0':'1')+'\tbackup\tstage'};
 return {status:scenario=='plan-fail'?1:0,output:scenario=='cold'?'cold':'hot'};
}
function module_status(mod,args){push(calls,args[0]);return scenario=='apply-fail'?1:0;}
function module_success(mod,args){push(calls,args[0]);return !(scenario=='probe-fail'&&args[0]=='probe-candidate') && !(scenario=='apply-fail'&&args[0]=='apply') && !(scenario=='commit-fail'&&args[0]=='commit-state') && !(scenario=='rollback-fail'&&args[0]=='restore');}
function wait_dns_failover_state(){push(calls,'verify');return index(['verify-fail','rollback-fail'],scenario)>=0?1:0;}
let common={copy_private_file_atomic:function(source,target){
 assert(source=='stage'&&target=='current');
 push(calls,'publish');return scenario!='copy-fail';
}};
function remove_file(path){push(removed,path);}
function log_message(){}
UC
sed -n '/^function dns_failover_hot_apply(/,/^}/p' "$ROOT/forkop/files/usr/lib/service/lifecycle.uc"
cat <<'UC'
for(let name in ['ok','unchanged','cold','prepare-fail','plan-fail','probe-fail','copy-fail','apply-fail','verify-fail','commit-fail','rollback-fail']){
 scenario=name;calls=[];removed=[];
 let status=dns_failover_hot_apply('candidate','current');
 let expected=name=='cold'?3:(index(['ok','unchanged'],name)>=0?0:1);
 if(status!=expected)die(name+': status\n');
 if(index(['apply-fail','verify-fail','commit-fail','rollback-fail'],name)>=0 && index(calls,'restore')<0)die(name+': missing rollback\n');
 if(name=='rollback-fail'&&index(removed,'backup')>=0)die('lost rollback backup\n');
 if(index(['cold','plan-fail','prepare-fail','probe-fail'],name)>=0&&index(calls,'publish')>=0)die('premature publication\n');
 if(name=='copy-fail'&&(index(calls,'apply')>=0||index(calls,'restore')>=0))die('unexpected signal after failed staging\n');
 if(name=='unchanged'&&index(calls,'apply')>=0)die('no-op signal\n');
}
print('DNS hot failover success, no-op, cold fallback and failure rollback checks passed\n');
UC
} > "$WORK/check.uc"
ucode "$WORK/check.uc"

{
cat <<'UC'
const STATE_UC = "state", SINGBOX_UC = "singbox", DNS_FAILOVER_UC = "dns", RELOAD_LOCK_DIR = "lock";
const CONFIG_NAME = "forkop", DNS_FAILOVER_STATE_FILE = "dns-state";
let fs = { stat: () => ({}) };
let scenario, calls, stop_count, start_count, backup_removed, rollback_failed;
function as_string(value) { return value == null ? "" : "" + value; }
function object_or_empty(value) { return value || {}; }
function read_json_file() { return { config_path: "current" }; }
function config_get(path, fallback) { return fallback; }
function owner_pid() { return "42"; }
function dns_failover_hot_apply() { return 3; }
function release_reload_lock() { push(calls, "unlock"); }
function log_message() {}
function remove_file(path) {
    assert(path == "backup");
    backup_removed = true;
}
function module_capture(module, args) {
    assert(args[0] == "patch-dns-config");
    push(calls, "patch");
    return { status: 0, output: "1\tbackup" };
}
function module_status(module, args) {
    let action = args[0];
    if (action == "stop-managed-sing-box-runtime")
        action = ++stop_count == 1 ? "stop" : "rollback-stop";
    if (action == "start-managed-sing-box-runtime")
        action = ++start_count == 1 ? "start" : "rollback-start";
    push(calls, action);
    if (action == scenario || (action == "start" && rollback_failed))
        return 1;
    return 0;
}
function module_success(module, args) { return module_status(module, args) == 0; }
function wait_dns_failover_state(path, attempts, required_successes) {
    assert(required_successes == 2);
    push(calls, "verify");
    return scenario == "verify" ? 1 : 0;
}
UC
sed -n '/^function dns_failover_apply(/,/^}/p' "$ROOT/forkop/files/usr/lib/service/lifecycle.uc"
cat <<'UC'
for (scenario in ["ok", "verify", "commit-state", "rollback-stop", "restore-dns-config", "rollback-start"]) {
    calls = [];
    stop_count = 0;
    start_count = 0;
    backup_removed = false;
    rollback_failed = index(["rollback-stop", "restore-dns-config", "rollback-start"], scenario) >= 0;
    // Force rollback before injecting a failure in the restoration call.
    let status = dns_failover_apply("candidate");
    assert(status == (scenario == "ok" ? 0 : 1), scenario + ": status");
    assert(backup_removed == !rollback_failed, scenario + ": recovery backup");
    assert(calls[-1] == "unlock", scenario + ": reload lock not released");
    if (scenario == "ok")
        assert(index(calls, "verify") < index(calls, "commit-state"), "state committed before verification");
    else {
        let rollback_stop = index(calls, "rollback-stop");
        let restore = index(calls, "restore-dns-config");
        let rollback_start = index(calls, "rollback-start");
        assert(rollback_stop > index(calls, "start"), scenario + ": candidate was not stopped");
        assert(scenario == "rollback-stop" ? restore < 0 : restore > rollback_stop, scenario + ": restore order");
        assert(scenario == "rollback-stop" || scenario == "restore-dns-config"
            ? rollback_start < 0 : rollback_start > restore, scenario + ": old core start order");
    }
}
print("DNS failover restart retains its backup until rollback succeeds\n");
UC
} > "$WORK/restart-check.uc"
ucode "$WORK/restart-check.uc"

# A short copy must never truncate the destination, including on rollback.
mkdir "$WORK/bin"
cat >"$WORK/bin/cp" <<'SH'
#!/bin/sh
head -c 32 "$1" >"$2"
exit 7
SH
chmod 700 "$WORK/bin/cp"
printf '%s\n' old >"$WORK/current"
printf '%s\n' 'candidate with enough bytes to be copied only in part' >"$WORK/stage"
PATH="$WORK/bin:$PATH" ucode -L "$ROOT/forkop/files/usr/lib" -e '
let common = require("core.common");
assert(!common.copy_private_file_atomic(ARGV[0], ARGV[1]));
' "$WORK/stage" "$WORK/current"
[ "$(cat "$WORK/current")" = old ]
[ "$(find "$WORK" -maxdepth 1 -name 'current.forkop.*' | wc -l)" -eq 0 ]
echo 'Failed DNS config copy leaves live bytes intact and removes partial staging'
