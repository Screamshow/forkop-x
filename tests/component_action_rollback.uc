#!/usr/bin/env ucode
// Parse the live functions with only fixture state and no device commands.
let fs = require("fs");
let source = fs.readfile(ARGV[0]);
let fixture = '
const CONFIG_NAME = "forkop";
const TORRSERVER_DIRECT_INIT = "/init/torrserver";
const TORRSERVER_DIRECT_UC = "/lib/torrserver";
const SYSTEM_INFO_CACHE_FILE = "/fixture/cache";
const packet_path = "network.@globals[0].packet_steering";
const torrserver_path = "forkop.settings.torrserver_direct_enabled";
let options = {};
let enabled = false, running = false, firewall = "", batch = "";
let packet_restarts = [], scenario = "";
let archive_inode = 1, adbdumps = 0;
let fs = { stat: () => ({ inode: archive_inode, size: 100, mtime: 5, ctime: 5 }) };
let staged_package_metadata_cache = {};
function as_string(value) { return value == null ? "" : "" + value; }
function is_apk() { return true; }
function file_nonempty() { return true; }
function shell_quote(value) { return value; }
function command_from_args(args) { return join(" ", args); }
function command_output(command) {
    assert(command == "apk --allow-untrusted adbdump package.apk", "unexpected metadata command");
    adbdumps++;
    return "  name: forkop\\n  version: 3.0.3\\n  arch: noarch\\n        size: 900\\n        size: 50\\n";
}
let uci_core = {
    get: path => options[path] || "",
    available: () => true,
    set: (path, value) => { options[path] = value; return true; },
    exists: path => options[path] != null,
    delete: path => { delete options[path]; return true; },
    commit: () => true
};
function file_exists() { return true; }
function module_output() { return sprintf("%J", { running: 1, available: 1 }); }
function parse_json_object(text) { return json(text); }
function module_success() { firewall = "partial firewall"; return false; }
function command_output_from_args(args) {
    if (args[2] == "tables") return firewall == "" ? "" : "table inet ForkopTorrServerDirect\\n";
    return firewall;
}
function make_tmp_file() { return "fixture-file"; }
function write_file(path, value) { batch = value; return true; }
function remove_file() {}
function command_success_from_args(args) {
    if (args[0] == "/etc/init.d/packet_steering") {
        push(packet_restarts, options[packet_path] || "unset");
        return options[packet_path] != "2";
    }
    if (args[0] == "modprobe") return true;
    if (args[0] == "nft") {
        if (args[1] == "-f") {
            firewall = trim(replace(batch, /^delete table inet ForkopTorrServerDirect\\n/, ""));
            return true;
        }
        return args[2] == "tables" || firewall != "";
    }
    switch (args[1]) {
    case "enabled": return enabled;
    case "running": return running;
    case "enable": enabled = true; return true;
    case "disable":
        enabled = false;
        return scenario != "disable";
    case "restart":
    case "start":
        running = true;
        return true;
    case "stop": running = false; firewall = ""; return true;
    }
    assert(false, "unexpected fixture command");
}
function action_fail(component, action, message) { die(message); }
function action_success() { assert(false, "failure was not propagated"); }
';
for (let name in [ "restore_component_option", "set_packet_steering", "restore_torrserver_table", "set_torrserver_direct",
    "staged_package_metadata", "staged_package_field", "staged_package_info" ]) {
    let start = index(source, "function " + name + "(");
    assert(start >= 0, "missing fixture function");
    let tail = substr(source, start);
    fixture += substr(tail, 0, index(tail, "\n}") + 2) + "\n";
}
fixture += '
try { set_packet_steering("enable"); } catch (e) {}
assert(options[packet_path] == null && join(",", packet_restarts) == "2,unset", "Packet Steering rollback");
try { set_torrserver_direct("enable"); } catch (e) {}
assert(!enabled && !running && firewall == "" && options[torrserver_path] == null, "TorrServer enable rollback");
enabled = true;
running = true;
firewall = "table inet ForkopTorrServerDirect {}";
options[torrserver_path] = "1";
scenario = "disable";
try { set_torrserver_direct("disable"); } catch (e) {}
assert(enabled && running && firewall == "table inet ForkopTorrServerDirect {}" && options[torrserver_path] == "1", "TorrServer disable rollback");
assert(staged_package_field("package.apk", "arch") == "noarch", "incorrect APK architecture");
assert(staged_package_info("package.apk", "forkop", "3.0.3").size == 950, "incorrect APK payload size");
assert(staged_package_info("package.apk", "forkop", "3.0.4") == null && adbdumps == 1, "repeated APK metadata extraction");
archive_inode++;
assert(staged_package_info("package.apk", "forkop", "3.0.3").size == 950 && adbdumps == 2, "replaced archive reused stale metadata");
print("Packet Steering and TorrServer Direct rollback fixtures passed\\n");
print("APK metadata uses 1 subprocess per staged inode and checks package identity and packed payload size\\n");
';
let path = "/tmp/forkop-component-rollback." + fs.readlink("/proc/self") + ".uc";
assert(fs.writefile(path, fixture) != null);
let status = system("ucode " + path);
fs.unlink(path);
exit(status);
