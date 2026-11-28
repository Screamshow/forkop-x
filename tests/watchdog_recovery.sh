#!/bin/sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/forkop/files/usr/lib"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

{
    cat <<'UC'
const GRACE_SECONDS = 0, FAILURE_SECONDS = 2, INTERVAL_SECONDS = 1, UPDATE_CHECK_INTERVAL_SECONDS = 60;
const BIN_PATH = "forkop";
let now = 0, kind, guarded, recoveries, commands;
function clock(monotonic) { return [now, 0]; }
function active() { return true; }
function transitioning() { return false; }
function xrust_runtime_kind() { return kind; }
function transition_guard_present() { return guarded; }
function recover_runtime() { recoveries++; guarded = false; return 0; }
function log() {}
function quote(value) { return value; }
function system(command) { push(commands, command); return 0; }
function resume_due_latency_test() {}
function sleep(milliseconds) { assert(milliseconds == 1000); now++; if (now > 4) die("fixture complete"); }
UC
    sed -n '/^function main(/,/^}/p' "$LIB/service/watchdog.uc"
    cat <<'UC'
for (let fixture in [
    { kind: "ambiguous", guarded: false, expected: 0 },
    { kind: "absent", guarded: false, expected: 1 },
    { kind: "current", guarded: true, expected: 1 }
]) {
    now = 0;
    kind = fixture.kind;
    guarded = fixture.guarded;
    recoveries = 0;
    commands = [];
    try { main(); } catch (e) { assert(e.message == "fixture complete", e.message); }
    assert(recoveries == fixture.expected, "incorrect recovery for " + kind);
    assert(length(commands) == 0, "watchdog invoked an operator command during automatic recovery");
}
UC
} >"$WORK/watchdog.uc"
ucode "$WORK/watchdog.uc"

{
    cat <<'UC'
let fs = require("fs");
let common = require("core.common");
let read_json_file = common.read_json_file;
let as_string = common.as_string;
let work = ARGV[0];
const SECTION_CACHE_DIR = work + "/section-cache";
const TRANSITION_RECOVERY_FILE = work + "/journal";
const DNS_FAILOVER_STATE_FILE = work + "/dns-state";
const STATE_UC = "state", SINGBOX_UC = "xrust", UI_UC = "ui";
const WATCHDOG_READY_FILE = work + "/ready", RELOAD_STOPPED_FILE = work + "/stopped";
const RELOAD_LOCK_DIR = work + "/lock", CONFIG_NAME = "forkop";
let backup = work + "/old-config", section_txn = SECTION_CACHE_DIR + ".reload.42";
let reload_core_transaction = { path: "live", previous_path: "old", published: false };
let list_change_rollback_dir = "snapshot", nft_candidate_batch_file = "batch";
let calls = [], guarded = true, ambiguous = false, kind = "absent", dns_status = 0;
function owner_pid() { return fs.readlink("/proc/self"); }
function transition_guard_present() { return guarded; }
function remove_file(path) { if (path) fs.unlink(path); }
function write_file(path, value) { return fs.writefile(path, value) != null; }
function log_message() {}
function module_output() { return kind; }
function module_success(module, args) {
    if (args[0] == "sing-box-process-conflict") return ambiguous;
    if (args[0] == "package-upgrade-transition-active") return false;
    push(calls, args[0]);
    return true;
}
function release_reload_lock() { push(calls, "release"); }
function config_get() { return "0"; }
function stop_candidate_reload_workers() { push(calls, "stop-workers"); }
function nft_candidate_finish() { push(calls, "discard-nft-candidate"); }
function finish_reload_section_cache(restore) { push(calls, "restore-section-cache"); return true; }
function finish_list_change_files(restore) { push(calls, "restore-list-snapshot"); return true; }
function restore_guarded_singbox_runtime(path, guard_active) {
    assert(fs.readfile(path) == "last known good" && guard_active, "prior state lost before guarded rollback");
    push(calls, "restore-core");
    guarded = false;
    return true;
}
function restore_reload_workers(path) {
    assert(fs.readfile(path + ".dns-failover") == "old DNS state", "prior DNS worker state was lost");
    push(calls, "restore-workers");
}
function discard_singbox_config_stage(path) { push(calls, "discard-stage"); }
function discard_reload_config_backup(path) { push(calls, "discard-backup"); }
function stop_main(allow_conflict) {
    assert(allow_conflict == false, "automatic recovery allowed stopping an unowned process");
    push(calls, "stop-owned-runtime");
    guarded = false;
    fs.unlink(WATCHDOG_READY_FILE);
    return 0;
}
function dnsmasq_restore_fail_safe() { push(calls, "restore-dnsmasq"); return dns_status; }
function mark_runtime_stopped_clean() { push(calls, "clean"); return 0; }
UC
    sed -n '/^function cleanup_failed_runtime(/,/^}/p;
            /^function transition_owner_start_ticks(/,/^}/p;
            /^function record_guarded_reload(/,/^}/p;
            /^function clear_guarded_reload_recovery(/,/^}/p;
            /^function recover_interrupted_section_cache(/,/^}/p;
            /^function recover_guarded_reload(/,/^}/p;
            /^function watchdog_recover(/,/^}/p' "$LIB/service/lifecycle.uc"
    cat <<'UC'
fs.writefile(backup, "last known good");
fs.writefile(DNS_FAILOVER_STATE_FILE, "old DNS state");
fs.mkdir(SECTION_CACHE_DIR);
fs.writefile(SECTION_CACHE_DIR + "/old", "previous cache");
assert(record_guarded_reload("stage", backup, section_txn));
assert(recover_guarded_reload() == 2 && length(calls) == 0, "live transition owner was interrupted");

let journal = read_json_file(TRANSITION_RECOVERY_FILE);
journal.start_ticks = "0";
common.write_private_json_file(TRANSITION_RECOVERY_FILE, journal);
ambiguous = true;
assert(recover_guarded_reload() == 2 && length(calls) == 0, "recovery touched a competing runtime");
ambiguous = false;

fs.mkdir(section_txn);
assert(fs.rename(SECTION_CACHE_DIR, section_txn + "/previous"));
assert(recover_guarded_reload() == 0, "orphaned guard was not recovered");
assert(join(",", calls) == "stop-workers,discard-nft-candidate,finish-section-cache,restore-list-snapshot,restore-core,restore-workers,discard-stage,discard-backup", "wrong recovery order");
assert(fs.readfile(SECTION_CACHE_DIR + "/old") == "previous cache", "interrupted cache rename was not undone");
assert(fs.stat(TRANSITION_RECOVERY_FILE) == null && !guarded, "completed rollback left recovery state");

calls = [];
guarded = true;
assert(recover_guarded_reload() == 1 && !guarded, "orphaned pre-journal guard was never cleaned up");
assert(join(",", calls) == "stop-owned-runtime,restore-dnsmasq,clean", "fallback skipped managed DNS cleanup");

calls = [];
dns_status = 7;
fs.writefile(WATCHDOG_READY_FILE, "1\n");
assert(watchdog_recover() == 7, "dnsmasq failure was lost");
assert(index(calls, "clean") < 0 && fs.stat(WATCHDOG_READY_FILE) != null, "failed restore was marked clean or stopped retrying");

calls = [];
kind = "ambiguous";
assert(watchdog_recover() == 2 && index(calls, "stop-owned-runtime") < 0, "ownership was not rechecked after acquiring the lock");
UC
} >"$WORK/lifecycle.uc"
ucode -L "$LIB" "$WORK/lifecycle.uc" "$WORK"
echo 'Watchdog ownership, interrupted guard rollback, and DNS retry checks passed'
