#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
UI="$ROOT/forkop/files/usr/lib/service/ui.uc"

# A manual latency test may only be refused while a test really is running.
{
cat <<'UCODE'
let lock_present = true;
let lock_owner = "4242";
let alive = [ "4242" ];
let states = [];
const LATENCY_TEST_LOCK_DIR = "/var/run/forkop/automatic-latency-test.lock";
const LATENCY_ACTION_DIR = "/var/run/forkop/latency-actions";
let fs = { stat: (path) => lock_present ? { type: "directory" } : null };
function as_string(value) { return value == null ? "" : "" + value; }
function first_line(path) {
    assert(path == LATENCY_TEST_LOCK_DIR + "/pid", "unexpected lock owner path");
    return lock_owner;
}
function pid_running(pid) { return index(alive, as_string(pid)) >= 0; }
function action_state_from_dir(dir) {
    assert(dir == LATENCY_ACTION_DIR, "unexpected job directory");
    return states;
}
function non_negative_number(value) {
    let number = int(value);
    return number > 0 ? number : 0;
}
UCODE
sed -n '/^function running_latency_test_reason() {/,/^}/p' "$UI"
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

// The worker takes a stale lock over, so the request must not be refused here.
states = [];
alive = [];
assert(running_latency_test_reason() == "", "lock of a dead worker still refuses the test");

alive = [ "4242" ];
lock_owner = "";
assert(running_latency_test_reason() == "", "lock without an owner still refuses the test");
print("latency test lock tests passed\n");
UCODE
} | ucode -
