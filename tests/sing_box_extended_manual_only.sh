#!/bin/sh
set -eu
# Forkop no longer installs or updates sing-box-extended (packaged or
# compressed); a build installed by hand keeps working.
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
ACTION="$LIB/components/action.uc"
VALIDATOR="$LIB/config/validator.uc"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# No install, update or download path is left in the backend or LuCI.
if grep -n -E 'install_extended|sing-box-extended/(latest|releases)|install_sing_box_extended' \
    "$ACTION" "$LIB/components/updates.uc" "$LIB/components/updater.uc" "$ROOT/install.sh" \
    "$ROOT/luci-app-forkop/htdocs/luci-static/resources/view/forkop/main.js" \
    "$ROOT/fe-app-forkop/src/forkop/tabs/updates/initController.ts"; then
  fail 'sing-box-extended can still be installed or downloaded'
fi
grep -Fq 'sing-box-extended was installed manually; update it manually' "$ACTION" ||
  fail 'a manual sing-box-extended update request is not refused clearly'

run_case() {
    ucode -e '
let fs = require("fs");
let source = fs.readfile(ARGV[0]);
function extract(name) {
    let start = index(source, "function " + name + "(");
    assert(start >= 0, name + " exists");
    let tail = substr(source, start);
    return substr(tail, 0, index(tail, "\n}") + 2);
}
let path = "/tmp/forkop-extended-manual." + fs.readlink("/proc/self") + ".uc";
fs.writefile(path, ARGV[1] + "\n" + join("\n", map(split(ARGV[2], " "), extract)) + "\n" + ARGV[3]);
let status = system([ "ucode", path ]);
fs.unlink(path);
exit(status);
' "$1" "$2" "$3" "$4"
}

# --- validator: adoption of an unpackaged sing-box-extended binary ---
VALIDATOR_STUBS='
let files = {}, written = {}, unlinked = [], marker = false, packages = {}, binary = true, logged = 0;
let fs = {
    readfile: function(p) { return files[p]; },
    writefile: function(p, d) { written[p] = d; return true; },
    unlink: function(p) { push(unlinked, p); return true; }
};
function as_string(v) { return v == null ? "" : "" + v; }
function command_exists(n) { return n == "sing-box" && binary; }
function sing_box_compressed_marker_set(ctx) { return marker; }
function service_exists(n) { return files["/etc/init.d/sing-box"] != null; }
function run_args(args) {
    if (args[0] == "mkdir") return true;
    return packages[args[length(args) - 1]] == true;
}
function log_message(m, l) { logged++; }
let ctx = { sing_box_variant_state_file: "/s/variant", sing_box_version_state_file: "/s/version",
    sing_box_managed_service_marker: "Forkop managed sing-box service for binary variants" };
function reset() { files = {}; written = {}; unlinked = []; marker = false; packages = {}; binary = true; }
'
run_case "$VALIDATOR" "$VALIDATOR_STUBS" adopt_unpackaged_extended_sing_box '
reset();
adopt_unpackaged_extended_sing_box(ctx, "1.14.0-extended-2.7.1");
assert(written["/s/variant"] == "extended-compressed\n", "binary without a service is not adopted");
assert(written["/s/version"] == "1.14.0-extended-2.7.1\n", "version state not recorded");
assert(length(unlinked) == 0, "nothing to replace without a service");

reset();
files["/etc/init.d/sing-box"] = "#!/bin/sh\n# Legacy managed sing-box service for binary variants\n";
adopt_unpackaged_extended_sing_box(ctx, "1.14.0-extended-2.7.1");
assert(written["/s/variant"] == "extended-compressed\n", "legacy binary is not adopted");
assert(length(unlinked) == 1 && unlinked[0] == "/etc/init.d/sing-box", "legacy service is not replaced");

reset();
files["/etc/init.d/sing-box"] = "#!/bin/sh\n# Forkop managed sing-box service for binary variants\n";
adopt_unpackaged_extended_sing_box(ctx, "1.14.0-extended-2.7.1");
assert(length(keys(written)) == 0 && length(unlinked) == 0, "Forkop service is touched");

reset();
files["/etc/init.d/sing-box"] = "#!/bin/sh /etc/rc.common\n# written by the user\n";
adopt_unpackaged_extended_sing_box(ctx, "1.14.0-extended-2.7.1");
assert(length(keys(written)) == 0 && length(unlinked) == 0, "a user service is replaced");

reset();
packages["sing-box-extended"] = true;
adopt_unpackaged_extended_sing_box(ctx, "1.14.0-extended-2.7.1");
assert(length(keys(written)) == 0, "a packaged build is adopted as unpackaged");

reset();
adopt_unpackaged_extended_sing_box(ctx, "1.13.21");
assert(length(keys(written)) == 0, "a non-extended binary is adopted");

reset();
marker = true;
adopt_unpackaged_extended_sing_box(ctx, "1.14.0-extended-2.7.1");
assert(length(keys(written)) == 0, "an adopted binary is adopted again");
' || fail 'unpackaged sing-box-extended adoption'
grep -A3 'adopt_unpackaged_extended_sing_box(ctx, sing_box_version);' "$VALIDATOR" |
  grep -Fq 'install_managed_sing_box_service_script(ctx)' ||
  fail 'adoption does not run before the managed service installation'

# --- backend: a sing-box-extended package is rolled back from local files ---
ACTION_STUBS='
let tmp_dir = "/t", extended_package_file_backups = [], present = {}, copied = [], moved = [];
function as_string(v) { return v == null ? "" : "" + v; }
function file_exists(p) { return present[p] == true; }
function command_success_from_args(args) { push(copied, args[2] + "<" + args[1]); present[args[2]] = true; return true; }
function move_file_portable(s, d) { push(moved, d + "<" + s); present[d] = true; return true; }
'
run_case "$ACTION" "$ACTION_STUBS" 'sing_box_variant_uses_file_backup backup_extended_package_files restore_extended_package_files' '
assert(sing_box_variant_uses_file_backup("extended") && sing_box_variant_uses_file_backup("extended-compressed"), "extended builds are not kept locally");
assert(!sing_box_variant_uses_file_backup("x") && !sing_box_variant_uses_file_backup("rust-x") && !sing_box_variant_uses_file_backup("tiny"), "packaged cores lost their package rollback");
present["/etc/init.d/sing-box"] = true;
present["/etc/config/sing-box"] = true;
assert(backup_extended_package_files(), "backup failed");
assert(length(copied) == 2, "service files not copied: " + join(",", copied));
present["/etc/init.d/sing-box"] = false;
present["/etc/config/sing-box"] = true;
assert(restore_extended_package_files(), "restore failed");
assert(length(moved) == 1 && moved[0] == "/etc/init.d/sing-box</t/etc_init.d_sing-box.forkop-backup", "restore: " + join(",", moved));
' || fail 'sing-box-extended service file backup'
grep -Fq 'if (previous_variant == "extended")
        return restore_sing_box_backup(backup_binary) && restore_extended_package_files();' "$ACTION" ||
  fail 'a failed change does not restore the sing-box-extended files'

UPGRADE_STUBS='
const COMPRESSED_UPGRADE_BACKUP = "/handoff";
const SB_MANAGED_SERVICE_MARKER = "managed init";
const FORKOP_VERSION = "2.7.5";
let tmp_dir = "/owned", events = [], fail_copy = "", stopped = false;
let variant = "extended-compressed", cronet = true, error = "";
let fs = {
    rename: function(src, dst) {
        assert(src == "/owned/compressed-upgrade" && dst == "/handoff", "invalid package hook handoff");
        push(events, "publish");
        return true;
    }
};
function command_success_from_args(args) {
    assert(args[0] == "cp" && !stopped, "backup attempted after the service stopped");
    push(events, args[2]);
    return args[2] != fail_copy;
}
function file_nonempty(path) { return path == "/usr/bin/sing-box"; }
function read_file(path) { return SB_MANAGED_SERVICE_MARKER; }
function ensure_dir(path) { return path == "/owned/compressed-upgrade"; }
function file_exists(path) { return path == "/usr/lib/libcronet.so" && cronet; }
function sing_box_runtime_output() { return variant; }
function capture_managed_upgrade_sing_box_marker() { push(events, "marker"); }
function stop_old_sing_box_before_forkop_upgrade() { stopped = true; push(events, "stop"); return true; }
function upgrade_sing_box_processes() { return {}; }
function upgrade_sing_box_count() { return 0; }
function action_fail(component, action, message) { error = message; die(message); }
'
run_case "$ACTION" "$UPGRADE_STUBS" 'clear_compressed_upgrade_backup stage_compressed_upgrade_backup prepare_forkop_runtime_for_package_upgrade' '
for (let path in [ "/usr/bin/sing-box", "/etc/init.d/sing-box", "/usr/lib/libcronet.so" ]) {
    fail_copy = path;
    error = "";
    events = [];
    try { prepare_forkop_runtime_for_package_upgrade("2.7.6"); }
    catch (e) { assert(error == "Failed to preserve compressed sing-box before upgrade", e.message); }
    assert(error != "" && !stopped && index(events, "publish") < 0 && index(events, "marker") < 0,
        "incomplete compressed backup was published or interrupted the service");
}
fail_copy = "";
events = [];
prepare_forkop_runtime_for_package_upgrade("2.7.6");
assert(join(" ", events) == "/usr/bin/sing-box /etc/init.d/sing-box /usr/lib/libcronet.so publish marker stop",
    "complete backup did not precede service stop");
events = [];
stopped = false;
cronet = false;
prepare_forkop_runtime_for_package_upgrade("2.7.6");
assert(join(" ", events) == "/usr/bin/sing-box /etc/init.d/sing-box publish marker stop",
    "Cronet is optional");
events = [];
stopped = false;
variant = "extended";
prepare_forkop_runtime_for_package_upgrade("2.7.6");
assert(join(" ", events) == "marker stop", "non-compressed core unnecessarily staged binary files");
' || fail 'compressed upgrade preparation ordering'

echo 'sing-box-extended is supported only as a manual installation: OK'
