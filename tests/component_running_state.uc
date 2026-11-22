#!/usr/bin/env ucode
// Exercise the real capture and stop functions with failed readiness,
// explicit Stop, stale markers and legacy installations, without package IO.
let fs = require("fs");
let source = fs.readfile(ARGV[0]);
function extract(name) {
    let start = index(source, "function " + name + "(");
    assert(start >= 0, name);
    let tail = substr(source, start);
    let end = index(tail, "\n}");
    return substr(tail, 0, end + 2);
}
let capture = extract("capture_forkop_running_state");
let cases = [
    [ "active despite failed readiness", true, "0", true, false, true ],
    [ "explicit stop", false, "1", false, false, false ],
    [ "stale ready marker after stop", true, "1", true, false, false ],
    [ "unmanaged standalone core", false, "0", true, false, false ],
    [ "stale marker without core", true, "0", false, false, false ],
    [ "healthy legacy runtime", false, "", false, true, true ]
];
for (let c in cases) {
    let code = 'let LIB_DIR="/lib", RUNTIME_STATE_DIR="/run", CONFIG_NAME="forkop", BIN_PATH="/bin/forkop", SERVICE_INIT="/init";\n' +
        'let forkop_was_running=false;\n' +
        'let uci_core={get: function(path) { return ' + sprintf("%J", c[2]) + '; }};\n' +
        'function file_exists(path) { return path=="/run/watchdog.ready" ? ' + sprintf("%J", c[1]) + ' : true; }\n' +
        'function module_success(args) { return ' + sprintf("%J", c[3]) + '; }\n' +
        'function forkop_status_running_with_timeout() { return ' + sprintf("%J", c[4]) + '; }\n' +
        capture + '\n' +
        'capture_forkop_running_state(); if (forkop_was_running!=' + sprintf("%J", c[5]) + ') die("capture failed");';
    let path = "/tmp/forkop-component-state-case." + fs.readlink("/proc/self") + ".uc";
    fs.writefile(path, code);
    if (system("ucode " + path) != 0)
        die(c[0]);
    fs.unlink(path);
    print("PASS: ", c[0], "\n");
}

let stop_fixture = '
const SERVICE_INIT = "/fixture/init", FORKOP_VERSION = "3.0.2";
let tmp_dir = "/fixture", forkop_package_init = "/fixture/adapter";
let forkop_was_running = true, stopped = false, restored = false;
let preserve_update_recovery_files = false, starts = 0, failed = false;
function upgrade_bounded_stop(script) { return script == forkop_package_init; }
function xrust_runtime_is_stopped() { return stopped; }
function forkop_status_running_with_timeout() { return false; }
function command_success_from_args(args) { assert(args[1] == "start", "wrong action"); starts++; return true; }
function wait_for_forkop_restore(explicit) { return explicit && restored; }
function action_fail(component, action, message, current, target) {
    assert(component == "forkop" && action == "install" && current == "3.0.2" && target == "3.0.3", "lost action context");
    failed = true;
    die(message);
}
' + extract("prepare_forkop_runtime_for_package_upgrade") + '
try { prepare_forkop_runtime_for_package_upgrade("3.0.3"); }
catch (e) { assert(failed, e.message); }
assert(failed && starts == 1 && preserve_update_recovery_files, "failed recovery must retain packages");

failed = false;
restored = true;
preserve_update_recovery_files = false;
try { prepare_forkop_runtime_for_package_upgrade("3.0.3"); }
catch (e) { assert(failed, e.message); }
assert(failed && starts == 2 && !preserve_update_recovery_files, "failed stop must restore the active runtime");

stopped = true;
prepare_forkop_runtime_for_package_upgrade("3.0.3");
assert(starts == 2, "confirmed stop should enter the upgrade without a restart");
';
let stop_fixture_path = "/tmp/forkop-component-stop-case." + fs.readlink("/proc/self") + ".uc";
fs.writefile(stop_fixture_path, stop_fixture);
let stop_status = system([ "ucode", stop_fixture_path ]);
fs.unlink(stop_fixture_path);
assert(stop_status == 0, "component change did not respect the stop result");
print("PASS: component mutations follow a confirmed stop\n");
