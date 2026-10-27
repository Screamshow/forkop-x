#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ACTION="$ROOT/forkop/files/usr/lib/components/action.uc"

# A failed version query must not be read as a wrong version.
{
cat <<'UCODE'
let calls = 0;
let waits = 0;
let script = [];
let status_code = 0;
const LIB_DIR = "/usr/lib/forkop";
function as_string(value) { return value == null ? "" : "" + value; }
function shell_quote(value) { return value; }
function module_command(args) { return "ucode " + args[1]; }
function make_tmp_file(prefix) { return "mock-output"; }
function owner_pid() { return 1; }
function updates_log(message, level) {}
function remove_file(path) {}
function command_status(command) { calls++; return status_code; }
function read_file(path) { return script[calls - 1] != null ? script[calls - 1] : script[length(script) - 1]; }
function command_success_from_args(args) {
    assert(args[0] == "sleep" && args[1] == "1", "unexpected command");
    waits++;
    return true;
}
UCODE
sed -n '/^function read_installed_package_version(package_name) {/,/^}/p' "$ACTION"
cat <<'UCODE'
script = [ "found 2.5.0\n" ];
let state = read_installed_package_version("forkop");
assert(state.state == "found" && state.version == "2.5.0", "installed version not read");
assert(calls == 1 && waits == 0, "successful query retried");

calls = 0; waits = 0;
script = [ "missing\n" ];
state = read_installed_package_version("forkop");
assert(state.state == "missing" && state.version == "", "missing package not reported");
assert(calls == 1 && waits == 0, "missing package retried");

calls = 0; waits = 0;
script = [
    "error opkg_conf_load: Could not lock /var/lock/opkg.lock\n",
    "error opkg_conf_load: Could not lock /var/lock/opkg.lock\n",
    "found 2.5.0\n"
];
state = read_installed_package_version("forkop");
assert(state.state == "found" && state.version == "2.5.0", "transient query failure not retried");
assert(calls == 3 && waits == 2, "incorrect retry state");

calls = 0; waits = 0;
script = [ "error opkg_conf_load: Could not lock /var/lock/opkg.lock\n" ];
state = read_installed_package_version("forkop");
assert(state.state == "error", "persistent query failure accepted as a version");
assert(index(state.error, "Could not lock") >= 0, "package manager error lost");
assert(calls == 3 && waits == 2, "retry bound incorrect");

calls = 0; waits = 0; status_code = 7;
script = [ "" ];
state = read_installed_package_version("forkop");
assert(state.state == "error" && index(state.error, "exit code 7") >= 0, "silent failure not reported");
print("installed version read tests passed\n");
UCODE
} | ucode -

# Only a version that was actually read may fail the installation.
{
cat <<'UCODE'
let queried = [];
let logged = [];
let states = {};
function as_string(value) { return value == null ? "" : "" + value; }
function updates_log(message, level) { push(logged, as_string(level) + ": " + message); }
function read_installed_package_version(package_name) {
    push(queried, package_name);
    return states[package_name];
}
UCODE
sed -n '/^function forkop_installed_version_mismatch(expected, names) {/,/^}/p' "$ACTION"
cat <<'UCODE'
let found = (version) => ({ state: "found", version, error: "" });
const MISSING = { state: "missing", version: "", error: "" };
const UNREADABLE = { state: "error", version: "", error: "opkg_conf_load: Could not lock /var/lock/opkg.lock" };

states = { forkop: found("2.5.0"), "luci-app-forkop": found("2.5.0"), "luci-i18n-forkop-ru": found("2.5.0") };
assert(forkop_installed_version_mismatch("2.5.0",
    [ "forkop", "luci-app-forkop", "luci-i18n-forkop-ru" ]) == "", "matching versions rejected");
assert(length(queried) == 3, "not every package was verified");

queried = []; logged = [];
states["luci-app-forkop"] = found("2.4.3");
let message = forkop_installed_version_mismatch("2.5.0", [ "forkop", "luci-app-forkop" ]);
assert(message != "", "stale package version accepted");
assert(index(message, "Forkop package versions disagree after installation") == 0, "message prefix changed");
assert(index(message, "expected 2.5.0") >= 0, "expected version missing from the message");
assert(index(message, "luci-app-forkop 2.4.3") >= 0, "installed version missing from the message");
assert(index(message, "forkop 2.5.0") < 0, "matching package reported as a mismatch");

queried = []; logged = [];
states = { forkop: MISSING, "luci-app-forkop": found("2.5.0") };
message = forkop_installed_version_mismatch("2.5.0", [ "forkop", "luci-app-forkop" ]);
assert(index(message, "forkop not installed") >= 0, "uninstalled package not reported");

queried = []; logged = [];
states = { forkop: UNREADABLE, "luci-app-forkop": found("2.5.0") };
assert(forkop_installed_version_mismatch("2.5.0", [ "forkop", "luci-app-forkop" ]) == "",
    "unreadable version failed the installation");
assert(length(logged) == 1 && index(logged[0], "warn: Could not read the installed version of forkop") == 0,
    "unreadable version not logged");
assert(index(logged[0], "Could not lock") >= 0, "package manager error lost");

queried = []; logged = [];
states = { forkop: found("2.5.0"), "luci-app-forkop": found("2.5.0") };
assert(forkop_installed_version_mismatch("2.5.0", [ "forkop", "luci-app-forkop" ]) == "",
    "release without the i18n package rejected");
assert(length(queried) == 2 && index(queried, "luci-i18n-forkop-ru") < 0,
    "i18n package verified although the release has none");
print("installation version verification tests passed\n");
UCODE
} | ucode -
