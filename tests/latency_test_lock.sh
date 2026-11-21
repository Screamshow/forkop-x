#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
UI="$ROOT/forkop/files/usr/lib/service/ui.uc"

# A manual latency test may only be refused while a test really is running.
{
cat <<'UCODE'
let lock_present = true;
let lock_held = true;
let states = [];
let worker_args = [];
let worker_result = { status: 0, output: "" };
let finished = null;
const BIN_PATH = "/usr/bin/forkop";
const STATE_UC = "service/state.uc";
const LATENCY_TEST_LOCK_DIR = "/var/run/forkop/automatic-latency-test.lock";
const LATENCY_ACTION_DIR = "/var/run/forkop/latency-actions";
let fs = { stat: (path) => lock_present ? { type: "directory" } : null };
let locks = {
    held: (lock_dir) => {
        assert(lock_dir == LATENCY_TEST_LOCK_DIR, "unexpected lock query");
        return lock_held;
    }
};
function as_string(value) { return value == null ? "" : "" + value; }
function action_state_from_dir(dir) {
    assert(dir == LATENCY_ACTION_DIR, "unexpected job directory");
    return states;
}
function non_negative_number(value) {
    let number = int(value);
    return number > 0 ? number : 0;
}
function current_pid() { return "42"; }
function module_success(path, args) { return true; }
function command_from_args(args) { worker_args = args; return ""; }
function command_capture(command) { return worker_result; }
function parse_json_or_null(value) { return json(value); }
function write_finished_action_state(path, success, message, status) {
    finished = { success, message, status };
}
UCODE
sed -n '/^function running_latency_test_reason() {/,/^}/p;
        /^function latency_clash_method(/,/^}/p;
        /^function latency_worker(/,/^}/p' "$UI"
cat <<'UCODE'
lock_present = false;
assert(running_latency_test_reason() == "", "test refused without a lock");

lock_present = true;
assert(running_latency_test_reason() == "Another latency test is already running",
    "running test not reported");

states = [ { running: true, kind: "latency", progress: { completed: 12, total: 67, failed: 1 } } ];
assert(running_latency_test_reason() == "Another latency test is already running (12 of 67)",
    "progress of the running test not reported");

states = [ { running: false, kind: "latency", progress: { completed: 67, total: 67, failed: 0 } } ];
assert(running_latency_test_reason() == "Another latency test is already running",
    "progress of a finished job reported");

// The worker takes an abandoned lock over, so the request must not be refused
// here. Whether the lock is abandoned is state.uc's answer, which also keeps a
// lock that is still being taken out of this hand.
states = [];
lock_held = false;
assert(running_latency_test_reason() == "", "abandoned lock still refuses the test");

latency_worker("/tmp/job.json", "proxy", "proxy-a", "5000");
assert(length(worker_args) == 5 && worker_args[2] == "get_proxy_latency",
    "single-proxy worker sends a job path as the test URL");
latency_worker("/tmp/job.json", "proxy_list", '["proxy-a"]', "5000");
assert(worker_args[2] == "get_proxy_latencies" && worker_args[5] == "/tmp/job.json",
    "batch worker does not forward its progress path");
assert(finished.success && finished.status == 0, "successful job did not finish");
worker_result = { status: 1, output: '{"error":"Could not read proxy list from Clash API"}' };
latency_worker("/tmp/job.json", "proxy_list", '["proxy-a"]', "5000");
assert(!finished.success && finished.status == 1 &&
    finished.message == "Could not read proxy list from Clash API", "batch error lost its cause");
print("latency test lock tests passed\n");
UCODE
} | ucode -
