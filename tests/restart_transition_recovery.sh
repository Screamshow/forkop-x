#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/forkop/files/usr/lib/service/lifecycle.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Exercise the production failure handler with controlled recovery outcomes.
cat > "$WORK/recovery.uc" <<'UC'
let calls = [];
let fs = { stat: function(path) { return {}; } };
let PRIORITY_UC = "priority", DNS_FAILOVER_UC = "dns";
let RELOAD_STATE_SNAPSHOT_FILE = "snapshot";
function discard_reload_config_backup(path) {}
function finish_reload_section_cache(restore) { return true; }
function nft_candidate_finish(commit) { push(calls, "discard-nft"); }
function discard_singbox_config_stage(path) {}
function finish_list_change_files(restore) { return getenv("CASE") != "lists-failed"; }
function restore_guarded_singbox_runtime(path, guard) {
    push(calls, "rollback"); return getenv("CASE") == "recovered";
}
function module_success(module, args) { push(calls, module); return true; }
function log_message(message, level) {}
function cleanup_failed_runtime() { push(calls, "direct-access"); }
function remove_file(path) {}
function abort_reload(status, changed) { push(calls, "abort"); return status || 1; }
UC
sed -n '/^function abort_guarded_transition(/,/^\/\/ The cold fallback/p' "$SOURCE" | sed '$d' >> "$WORK/recovery.uc"
cat >> "$WORK/recovery.uc" <<'UC'
let rc = abort_guarded_transition(7, "stage", "backup", true);
if (rc != 7) die("failure status lost\n");
let direct = index(calls, "direct-access") >= 0;
if (getenv("CASE") == "recovered") {
    if (direct || index(calls, "priority") < 0 || index(calls, "dns") < 0)
        die("successful rollback lost service or opened direct access\n");
} else if (!direct) die("unrecoverable failure left internet blocked\n");
UC
for scenario in recovered core-failed lists-failed; do
  CASE="$scenario" ucode "$WORK/recovery.uc"
done
echo 'restart transition recovery checks passed'

# Reject candidate configurations while both existing workers are still alive.
{
cat <<'UC'
const CONFIG_NAME = "forkop", SUBSCRIPTION_CACHE_UC = "cache", STATE_UC = "state", RELOAD_UC = "reload";
const DNS_FAILOVER_UC = "dns", PRIORITY_UC = "priority", SINGBOX_UC = "singbox", HOT_RELOAD_UC = "hot";
const RT_TABLE_NAME = "routes", NFT_UC = "nft", NFT_TABLE_NAME = "table", NFT_FAKEIP_MARK = "mark";
const LIST_UPDATE_RELOAD_FILE = "pending.lists", RELOAD_STATE_SNAPSHOT_FILE = "snapshot";
const RELOAD_STATE_FILE = "reload-state", RELOAD_STATE_FORMAT = 1, SECTION_CACHE_DIR = "sections";
let fs = require("fs");
let common = require("core.common");
let reload_core_transaction;
let work = getenv("FORKOP_TEST_WORK");
let current = work + "/current.json";
let rule_condition_cache_enabled, nft_candidate_batch_file, scenario, calls, temporary;
function as_string(value) { return value == null ? "" : "" + value; }
function finish_list_change_files() { return true; }
function remove_file(path) { if (as_string(path) != "") fs.unlink(path); }
function cleanup_failed_runtime() { die("candidate failure removed live runtime\n"); }
function log_message() {}
function external_config_fingerprint() { return "config"; }
function validate_start_config() { return 0; }
function module_status(module, args) {
    push(calls, args[0]);
    return 0;
}
function module_success(module, args) {
    push(calls, args[0]);
    return args[0] == "forkop-running";
}
function module_capture() { return { status: 0, output: scenario == "configure" ? "hot" : "cold" }; }
function command_output_from_args() {
    let path = work + "/candidate." + length(temporary);
    push(temporary, path);
    fs.writefile(path, "");
    return path;
}
function command_success_from_args(args) { return system(args) == 0; }
function dnsmasq_has_forkop_managed_state() { return true; }
function parse_reload_plan() {
    return { has_work: 1, changed_list: 0, needs_sing_box_reload: 1, needs_nft_rebuild: 1 };
}
function write_service_trigger_sync_state() {}
function reload_actions_summary() { return ""; }
function config_get() { return current; }
function singbox_prepare_config_stage(path) {
    fs.writefile(path, "candidate");
    return scenario == "stage" ? 7 : 0;
}
function discard_singbox_config_stage(path) { remove_file(path); }
function nft_candidate_begin() { nft_candidate_batch_file = "candidate.nft"; return true; }
function nft_rebuild_runtime() { return scenario == "nft-build" ? 7 : 0; }
function nft_populate_runtime_sets() { return 0; }
function nft_candidate_validate() { return scenario != "nft"; }
function nft_candidate_finish() { nft_candidate_batch_file = ""; return true; }
UC
sed -n '/^function finish_reload_section_cache(/,/^}/p; /^function discard_reload_config_backup(/,/^}/p; /^function abort_reload(/,/^}/p; /^function abort_guarded_transition(/,/^}/p; /^function reload(/,/^}/p' "$SOURCE"
cat <<'UC'
fs.writefile(current, "old config");
for (scenario in ["configure", "stage", "nft-build", "nft", "guard"]) {
    calls = [];
    temporary = [];
    nft_candidate_batch_file = "";
    let expected_status = scenario == "nft" || scenario == "guard" || scenario == "configure" ? 1 : 7;
    assert(reload("on_config_change", false) == expected_status, scenario + ": status");
    assert(index(calls, "stop-runtime") < 0 && index(calls, "start-runtime") < 0,
        scenario + ": candidate failure changed runtime workers");
    assert((index(calls, "install-transition-guard") >= 0) == (scenario == "guard"),
        scenario + ": unexpected guard attempt");
    for (let path in temporary)
        assert(fs.stat(path) == null, scenario + ": temporary configuration retained");
    assert(fs.readfile(current) == "old config");
}
print("Reload candidate failures preserve running DNS and Priority workers and remove temporary configs\n");
UC
} > "$WORK/prepare.uc"
FORKOP_TEST_WORK="$WORK" ucode -L "$ROOT/forkop/files/usr/lib" "$WORK/prepare.uc"

# Record the components that applied successfully before a late dnsmasq failure.
# The retry must compare against the new core/nft signatures and only redo DNS.
LIB="$ROOT/forkop/files/usr/lib"
STATE="$LIB/service/state.uc"
cat >"$WORK/new.state" <<'STATE'
format=1
service_trigger_signature=triggers-new
dnsmasq_signature=dns-new
sing_box_signature=core-new
nft_signature=nft-new
list_signature=lists-new
cron_signature=cron-new
dont_touch_dhcp=0
STATE
sed 's/^service_trigger_signature=.*/service_trigger_signature=triggers-old/' "$WORK/new.state" >"$WORK/applied.state"
ucode -L "$LIB" "$STATE" write-captured-reload-state \
    "$WORK/applied.state" "$WORK/new.state" 1 "" 0 0 dnsmasq-pending
sed -e 's/^dnsmasq_signature=.*/dnsmasq_signature=pending/' \
    -e 's/^service_trigger_signature=.*/service_trigger_signature=triggers-old/' "$WORK/new.state" >"$WORK/expected.state"
cmp "$WORK/expected.state" "$WORK/applied.state"
plan="$(ucode -L "$LIB" "$LIB/service/reload.uc" plan-state-files "$WORK/applied.state" "$WORK/new.state" 1 0 0 0 0)"
printf '%s\n' "$plan" | grep -Eq '^needs_dnsmasq_configure[[:space:]]+1$'
printf '%s\n' "$plan" | grep -Eq '^needs_sing_box_reload[[:space:]]+0$'
printf '%s\n' "$plan" | grep -Eq '^needs_nft_rebuild[[:space:]]+0$'
printf '%s\n' "$plan" | grep -Eq '^changed_service_triggers[[:space:]]+1$'
echo 'Pending dnsmasq retry retains applied core/nft state and requests outstanding trigger sync'

# A successful dnsmasq step may read DHCP after another UCI edit commits.
# The snapshot must only pick up DHCP's new signature using the applied mode.
cat >"$WORK/phase-b" <<'UCI'
forkop.settings=settings
forkop.settings.dont_touch_dhcp=0
forkop.settings.exclude_ntp=0
forkop.settings.component_update_check_enabled=0
dhcp.@dnsmasq[0]=dnsmasq
dhcp.@dnsmasq[0].server=1.1.1.1
UCI
FORKOP_UCI_STATE_FILE="$WORK/phase-b" ucode -L "$LIB" "$STATE" capture-reload-state "$WORK/phase-b-snapshot" 1
sed 's/^dhcp.@dnsmasq\[0\].server=.*/dhcp.@dnsmasq[0].server=127.0.0.42/' "$WORK/phase-b" >"$WORK/phase-b-applied"
sed -e 's/^forkop.settings.dont_touch_dhcp=0/forkop.settings.dont_touch_dhcp=1/' \
    -e 's/^forkop.settings.exclude_ntp=0/forkop.settings.exclude_ntp=1/' \
    -e 's/^forkop.settings.component_update_check_enabled=0/forkop.settings.component_update_check_enabled=1/' \
    "$WORK/phase-b-applied" >"$WORK/phase-c"
cat >>"$WORK/phase-c" <<'UCI'
forkop.settings.enable_badwan_interface_monitoring=1
forkop.settings.badwan_monitored_interfaces=wan lan
UCI
FORKOP_UCI_STATE_FILE="$WORK/phase-b-applied" ucode -L "$LIB" "$STATE" capture-reload-state "$WORK/phase-b-expected" 1
FORKOP_UCI_STATE_FILE="$WORK/phase-c" ucode -L "$LIB" "$STATE" refresh-reload-dnsmasq-signature "$WORK/phase-b-snapshot"
cmp "$WORK/phase-b-expected" "$WORK/phase-b-snapshot"
test ! -e "$WORK/phase-b-snapshot.dnsmasq"
FORKOP_UCI_STATE_FILE="$WORK/phase-c" ucode -L "$LIB" "$STATE" capture-reload-state "$WORK/phase-c-snapshot" 1
plan="$(ucode -L "$LIB" "$LIB/service/reload.uc" plan-state-files "$WORK/phase-b-snapshot" "$WORK/phase-c-snapshot" 1 1 0 0 0)"
for field in needs_dnsmasq_restore needs_nft_rebuild needs_cron_refresh changed_service_triggers; do
    printf '%s\n' "$plan" | grep -Eq "^$field[[:space:]]+1$"
done
grep -v '^dnsmasq_signature=' "$WORK/phase-b-expected" >"$WORK/incomplete"
if FORKOP_UCI_STATE_FILE="$WORK/phase-c" ucode -L "$LIB" "$STATE" refresh-reload-dnsmasq-signature "$WORK/incomplete"; then
    echo 'Invalid DNS snapshot was accepted' >&2
    exit 1
fi
test ! -e "$WORK/incomplete.dnsmasq"
echo 'Post-dnsmasq refresh preserves concurrent DNS, nft, cron and trigger edits for the next reload'
