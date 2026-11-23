#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
{
  cat <<'UCODE'
let links = {};
let cmdline = "xrust";
let cmdline_reads = 0;
let observed_runtime, observed_ticks, provenance_reads;
let xrust = require("xrust.binary");
let fs = {
    readlink: function(path) { return links[path]; },
    readfile: function(path) { cmdline_reads++; return cmdline; }
};
function as_string(value) { return value == null ? "" : "" + value; }
function sing_box_runtime_provenance() { provenance_reads++; return observed_runtime; }
function process_start_ticks_for_pid(pid) { return observed_ticks; }
UCODE
  awk '/^function sing_box_exe_path\(/ { emit = 1 }
       /^function hup_sing_box_runtime\(/ { emit = 0 }
       emit { print }' "$ROOT_DIR/forkop/files/usr/lib/service/state.uc"
  sed -n '/^function sing_box_owned_service_kind(/,/^}/p' "$ROOT_DIR/forkop/files/usr/lib/service/state.uc"
  cat <<'UCODE'
let cases = [
    { target: "/usr/bin/sing-box", present: false, current: false, deleted: false },
    { target: "/usr/lib/rust-x/sing-box", present: false, current: false, deleted: false },
    { target: xrust.PATH, present: true, current: true, deleted: false },
    { target: xrust.PATH + " (deleted)", present: true, current: false, deleted: true },
    { target: "/usr/bin/sing-box (deleted)", present: false, current: false, deleted: false },
    { target: "/tmp/foreign/sing-box", present: false, current: false, deleted: false },
    { target: "/tmp/foreign/sing-box (deleted)", present: false, current: false, deleted: false },
    { target: "/usr/bin/sing-box-test", present: false, current: false, deleted: false },
    { target: "/usr/bin/ash", present: false, current: false, deleted: false },
    { target: null, present: false, current: false, deleted: false }
];
for (let test in cases) {
    links = { "/proc/123/exe": test.target };
    let before = cmdline_reads;
    if (pid_is_sing_box("123") != test.present ||
        pid_has_current_sing_box_exe("123") != test.current ||
        (sing_box_exe_kind(test.target) == "deleted") != test.deleted)
        die("Executable identity regression\n");
    if (cmdline_reads - before != (test.present ? 1 : 0))
        die("Read cmdline before checking the executable\n");
}
if (pid_is_sing_box("../123") || pid_is_sing_box("123; echo injected") || pid_is_sing_box(""))
    die("Invalid PID accepted\n");
links = { "/proc/123/exe": xrust.PATH };
for (let mode in [
    "tailscale-luci", "tailscale-native-capability", "tailscale-ssh-capability", "tailscale-exit-capability",
    "check", "version", "-v", "--version", "help", "-h", "--help",
    "rule-set", "reload-plan", "tools", "api", "generate", "format", "merge", "netns-holder"
]) {
    cmdline = join(chr(0), [ "xrust", mode, "" ]);
    if (pid_is_sing_box("123"))
        die(mode + " process counted as proxy core\n");
}
for (let args in [
    [ "xrust", "run", "-c", "check", "" ],
    [ "xrust", "-c", "rule-set", "run", "" ],
    [ "xrust", "future-core-mode", "" ]
]) {
    cmdline = join(chr(0), args);
    if (!pid_is_sing_box("123"))
        die("A potential Xrust runtime was ignored\n");
}
observed_runtime = { pid: 123, start_ticks: 9001 };
observed_ticks = 9001;
provenance_reads = 0;
assert(sing_box_owned_service_kind() == "current" && provenance_reads == 1);
links["/proc/123/exe"] = xrust.PATH + " (deleted)";
assert(sing_box_owned_service_kind() == "deleted" && provenance_reads == 2);
observed_ticks++;
assert(sing_box_owned_service_kind() == "other" && provenance_reads == 3, "PID reuse was trusted");
observed_runtime = null;
assert(sing_box_owned_service_kind() == "other" && provenance_reads == 4, "unowned runtime was trusted");
let old_banner = "sing-box version 1.14.2-rust-x.0.0.44\n";
if (xrust.version_from_output("xrust version 0.0.45\nTags: with_tailscale\n") != "0.0.45" ||
    xrust.version_from_output(old_banner) != "" ||
    xrust.legacy_version_from_output(old_banner) != "0.0.44" ||
    xrust.legacy_version_from_output("sing-box version 1.14.2\n") != "")
    die("Native and rollback version checks used the wrong banner\n");
print("Native executable identity checks passed\n");
UCODE
} | ucode -L "$ROOT_DIR/forkop/files/usr/lib" -
