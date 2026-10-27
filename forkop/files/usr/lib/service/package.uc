#!/usr/bin/env ucode

let fs = require("fs");
let bytecode = require("core.bytecode");
let uci_core = require("core.uci");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function env(name, fallback) {
    let value = getenv(name);
    return value == null ? as_string(fallback) : as_string(value);
}

const LIB_DIR = env("FORKOP_LIB", "/usr/lib/forkop");
const CONFIG_NAME = env("FORKOP_CONFIG_NAME", "forkop");
const CONFIG_PATH = env("FORKOP_CONFIG_PATH", "/etc/config/forkop");
const DEFAULT_CONFIG_PATH = env("FORKOP_DEFAULT_CONFIG_PATH", "/usr/share/forkop/defaults/forkop");
const RT_TABLES_PATH = env("FORKOP_RT_TABLES", "/etc/iproute2/rt_tables");
const BIN_PATH = env("FORKOP_BIN", "/usr/bin/forkop");
const INIT_PATH = env("FORKOP_INIT", "/etc/init.d/forkop");
const UI_UC = env("FORKOP_UI_UC", LIB_DIR + "/service/ui.uc");
const SING_BOX_INIT = env("FORKOP_SING_BOX_INIT", "/etc/init.d/sing-box");
const SING_BOX_BIN = env("FORKOP_SING_BOX_BIN", "/usr/bin/sing-box");
const SING_BOX_CRONET = env("FORKOP_SING_BOX_CRONET", "/usr/lib/libcronet.so");
const SING_BOX_MANAGED_MARKER = env("SB_MANAGED_SERVICE_MARKER", "Forkop managed sing-box service for binary variants");
const COMPRESSED_UPGRADE_BACKUP = "/tmp/forkop-compressed-upgrade";
const PACKAGE_UPGRADE_STATE = env("FORKOP_PACKAGE_UPGRADE_STATE", "/tmp/forkop-package-was-running");
const PACKAGE_UPGRADE_QUIESCE_FILE = env("FORKOP_PACKAGE_UPGRADE_QUIESCE_FILE", "/var/run/forkop/package-upgrade.quiesce");
const UPGRADE_SING_BOX_WAIT_SECONDS = int(env("FORKOP_UPGRADE_SING_BOX_WAIT_SECONDS", "15"));
const UPGRADE_RESTORE_WAIT_SECONDS = int(env("FORKOP_UPGRADE_RESTORE_WAIT_SECONDS", "180"));
const COMPONENT_UPDATE_CHECK_CACHE_DIR = env("FORKOP_COMPONENT_UPDATE_CHECK_CACHE_DIR", "/var/run/forkop/component-update-checks");
const COMPONENT_UPDATE_CHECK_STATE_FILE = env("FORKOP_COMPONENT_UPDATE_CHECK_STATE_FILE", "/var/run/forkop/component-update-check.timestamp");
const PACKAGE_TEST_MODE = env("FORKOP_PACKAGE_TEST_MODE", "") != "";

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function normalize_status(status) {
    status = int(status);
    return status > 255 ? int(status / 256) : status;
}

function command_success_from_args(args) {
    return normalize_status(system(command_from_args(args) + " >/dev/null 2>&1")) == 0;
}

function path_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function path_basename(path) {
    path = as_string(path);
    let slash = rindex(path, "/");
    return slash >= 0 ? substr(path, slash + 1) : path;
}

function sing_box_exe_path(path) {
    let basename = path_basename(path);
    return basename == "sing-box" || basename == "sing-box (deleted)";
}

function sing_box_process_count() {
    let count = 0;
    for (let exe_path in fs.glob("/proc/[0-9]*/exe")) {
        let parts = split(as_string(exe_path), "/");
        let args = split(fs.readfile("/proc/" + parts[2] + "/cmdline") || "", chr(0));
        if (args[1] == "tailscale-luci") continue;
        if (length(parts) >= 4 &&
            sing_box_exe_path(fs.readlink(exe_path)))
            count++;
    }
    return count;
}

function wait_for_upgrade_sing_box_exit() {
    let timeout = UPGRADE_SING_BOX_WAIT_SECONDS;

    // Package removal stops the old service asynchronously. This is especially
    // visible when upgrading from 1.3.16 and from legacy releases up to 1.2.7:
    // postinst can otherwise reach the guarded start while the old child is
    // still present. Wait for it to exit, but never kill a process by name.
    while (sing_box_process_count() > 0) {
        if (timeout <= 0)
            return false;
        command_success_from_args([ "sleep", "1" ]);
        timeout--;
    }

    return true;
}

function unlink_if_exists(path) {
    if (path_exists(path))
        fs.unlink(as_string(path));
}

function clear_component_update_check_cache() {
    for (let path in fs.glob(COMPONENT_UPDATE_CHECK_CACHE_DIR + "/*"))
        unlink_if_exists(path);
    unlink_if_exists(COMPONENT_UPDATE_CHECK_STATE_FILE);
}

function remove_rt_tables_entry() {
    let data = fs.readfile(RT_TABLES_PATH);
    if (data == null)
        return true;

    let changed = false;
    let lines = [];
    for (let line in split(data, "\n")) {
        if (index(line, "105 forkop") >= 0) {
            changed = true;
            continue;
        }
        push(lines, line);
    }

    return !changed || fs.writefile(RT_TABLES_PATH, join("\n", lines)) != null;
}

function ascii_lower(value) {
    let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    let lower = "abcdefghijklmnopqrstuvwxyz";
    return replace(as_string(value), /[A-Z]/g, function(ch) {
        return substr(lower, index(upper, ch), 1);
    });
}

function truthy(value) {
    value = ascii_lower(trim(as_string(value)));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function dont_touch_dhcp_enabled() {
    return truthy(uci_core.get(CONFIG_NAME + ".settings.dont_touch_dhcp"));
}

function restore_dnsmasq_if_needed() {
    if (dont_touch_dhcp_enabled())
        return;

    // The backend owns the transaction marker and decides whether rollback is
    // safe. Do not invoke a second raw failsafe pass after it returns.
    command_success_from_args([ BIN_PATH, "restore_dnsmasq" ]);
}

function remove_managed_sing_box() {
    let data = fs.readfile(SING_BOX_INIT);
    if (data == null || index(data, SING_BOX_MANAGED_MARKER) < 0)
        return;

    command_success_from_args([ SING_BOX_INIT, "stop" ]);
    command_success_from_args([ SING_BOX_INIT, "disable" ]);
    unlink_if_exists(SING_BOX_INIT);
    unlink_if_exists(SING_BOX_BIN);
    unlink_if_exists(SING_BOX_CRONET);
}

function restore_compressed_upgrade_backup() {
    let backup_bin = COMPRESSED_UPGRADE_BACKUP + "/sing-box";
    let backup_init = COMPRESSED_UPGRADE_BACKUP + "/sing-box.init";
    if (!path_exists(backup_bin) && !path_exists(backup_init))
        return true;
    if (trim(as_string(fs.readfile("/etc/forkop/sing-box-variant"))) != "extended-compressed" ||
        !path_exists(backup_bin) ||
        index(as_string(fs.readfile(backup_init)), SING_BOX_MANAGED_MARKER) < 0)
        return false;
    let init_was_missing = !path_exists(SING_BOX_INIT);
    for (let pair in [ [ backup_bin, SING_BOX_BIN ], [ backup_init, SING_BOX_INIT ],
                       [ COMPRESSED_UPGRADE_BACKUP + "/libcronet.so", SING_BOX_CRONET ] ]) {
        if (path_exists(pair[0]) && !path_exists(pair[1]) &&
            !command_success_from_args([ "cp", "-p", pair[0], pair[1] ]))
            return false;
    }
    if (init_was_missing && !command_success_from_args([ SING_BOX_INIT, "enable" ]))
        return false;
    return true;
}

function clear_compressed_upgrade_backup() {
    for (let name in [ "sing-box", "sing-box.init", "libcronet.so" ])
        unlink_if_exists(COMPRESSED_UPGRADE_BACKUP + "/" + name);
    command_success_from_args([ "rmdir", COMPRESSED_UPGRADE_BACKUP ]);
}

function remember_upgrade_state(action) {
    // opkg invokes prerm without an action argument on some supported
    // OpenWrt 24 builds, including a normal version upgrade.  The old
    // action-based branch then erased the only hand-off telling postinst to
    // restore a service that was deliberately stopped for the package swap.
    // Service state is the authoritative input here: a marker is written only
    // when Forkop was actually running immediately before prerm.
    if (command_success_from_args([ INIT_PATH, "status" ]))
        fs.writefile(PACKAGE_UPGRADE_STATE, "1\n");
    else
        unlink_if_exists(PACKAGE_UPGRADE_STATE);
}

function current_pid() {
    let stat = as_string(fs.readfile("/proc/self/stat"));
    let separator = index(stat, " ");
    return separator > 0 ? substr(stat, 0, separator) : "";
}

function parent_pid() {
    let stat = as_string(fs.readfile("/proc/self/stat"));
    let marker = rindex(stat, ") ");
    if (marker < 0)
        return "";
    let fields = split(substr(stat, marker + 2), " ");
    return length(fields) > 1 && match(as_string(fields[1]), /^[0-9]+$/) != null ? fields[1] : "";
}

function process_parent_pid(pid) {
    for (let line in split(as_string(fs.readfile("/proc/" + pid + "/status")), "\n")) {
        if (index(line, "PPid:") == 0) {
            let parent = trim(substr(line, 5));
            return match(parent, /^[0-9]+$/) != null ? parent : "";
        }
    }
    return "";
}

function package_transaction_pid() {
    let pid = current_pid();
    for (let i = 0; i < 12 && pid != "" && pid != "1"; i++) {
        let comm = trim(as_string(fs.readfile("/proc/" + pid + "/comm")));
        if (comm == "apk" || comm == "opkg" || comm == "opkg-cl")
            return pid;
        pid = process_parent_pid(pid);
    }
    return parent_pid();
}

function begin_upgrade_quiesce(action) {
    // opkg on supported OpenWrt 24 builds can omit the prerm action during an
    // upgrade.  Treat every non-removal package replacement as an upgrade and
    // pin the marker to the apk/opkg ancestor, which remains alive until
    // postinst has completed. The immediate parent is only the Forkop command
    // wrapper and exits with prerm.
    if (as_string(action) == "remove")
        return true;
    let pid = package_transaction_pid();
    if (pid == "")
        pid = current_pid();
    return pid != "" && command_success_from_args([ "ucode", "-L", LIB_DIR, UI_UC, "transfer-package-upgrade-quiesce", pid ]);
}

function clear_upgrade_quiesce() {
    unlink_if_exists(PACKAGE_UPGRADE_QUIESCE_FILE);
}

function wait_for_restored_service() {
    let timeout = UPGRADE_RESTORE_WAIT_SECONDS;

    // start_service() deliberately detaches when invoked from a procd package
    // transaction.  Do not let postinst return while that worker is still
    // starting: the component updater would otherwise mistake the transient
    // state for failure and launch a concurrent restart.
    while (timeout >= 0) {
        if (path_exists(UI_UC) && command_success_from_args([ "ucode", "-L", LIB_DIR, UI_UC, "service-action-idle" ])) {
            if (command_success_from_args([ INIT_PATH, "status" ]))
                return true;
        }
        if (timeout <= 0)
            break;
        command_success_from_args([ "sleep", "1" ]);
        timeout--;
    }

    return false;
}

function wait_for_existing_service_action() {
    let remaining = UPGRADE_RESTORE_WAIT_SECONDS;
    while (remaining >= 0) {
        if (path_exists(UI_UC) && command_success_from_args([ "ucode", "-L", LIB_DIR, UI_UC, "service-action-idle" ]))
            return true;
        if (remaining == 0)
            break;
        command_success_from_args([ "sleep", "1" ]);
        remaining--;
    }
    return false;
}

function prerm_cleanup(action) {
    if (env("IPKG_INSTROOT", "") != "")
        return true;

    if (!begin_upgrade_quiesce(action)) {
        warn("Unable to acquire Forkop package upgrade quiesce state.\n");
        return false;
    }
    if (as_string(action) != "remove" && !wait_for_existing_service_action()) {
        warn("Timed out waiting for a Forkop service action before package upgrade.\n");
        unlink_if_exists(PACKAGE_UPGRADE_STATE);
        clear_upgrade_quiesce();
        return false;
    }
    remember_upgrade_state(action);
    // The files under /usr/lib/forkop are replaced right after this returns.
    // Dropping the cache's short-lived validation stamp makes the next process
    // re-check the manifest against the new sources instead of trusting a
    // library compiled from the old ones.
    bytecode.invalidate_validation_stamp();
    if (!PACKAGE_TEST_MODE) {
        if (path_exists('/etc/init.d/forkop-tailscale'))
            command_success_from_args([ '/etc/init.d/forkop-tailscale', 'stop' ]);
        if (path_exists('/etc/init.d/forkop-support'))
            command_success_from_args([ '/etc/init.d/forkop-support', 'stop' ]);
        if (!command_success_from_args([ INIT_PATH, "stop" ])) {
            warn("Unable to stop Forkop before package replacement.\n");
            return false;
        }
        restore_dnsmasq_if_needed();
        // The compressed variant is installed outside the package manager.
        // Keep its binary and managed init script across a Forkop upgrade;
        // postinst needs both to restore the previously running service.
        if (as_string(action) == "remove")
            remove_managed_sing_box();
    }
    if (!remove_rt_tables_entry()) {
        warn("Unable to remove Forkop routing table entry before package replacement.\n");
        return false;
    }
    return true;
}

function postinst_restore() {
    if (env("IPKG_INSTROOT", "") != "")
        return true;

    clear_component_update_check_cache();
    bytecode.invalidate_validation_stamp();
    if (!PACKAGE_TEST_MODE && path_exists('/etc/forkop-tailscale/enabled') && path_exists('/etc/init.d/forkop-tailscale'))
        command_success_from_args([ '/etc/init.d/forkop-tailscale', 'start' ]);
    if (!restore_compressed_upgrade_backup()) {
        warn("Unable to restore compressed sing-box after package upgrade.\n");
        return false;
    }

    let config = fs.readfile(CONFIG_PATH);
    if (config == null || trim(as_string(config)) == "") {
        let defaults = fs.readfile(DEFAULT_CONFIG_PATH);
        if (defaults == null || trim(as_string(defaults)) == "") {
            warn("Unable to restore missing Forkop configuration: packaged defaults are unavailable.\n");
            return false;
        }
        if (fs.writefile(CONFIG_PATH, defaults) == null ||
            !command_success_from_args([ "chmod", "0644", CONFIG_PATH ])) {
            warn("Unable to restore missing Forkop configuration.\n");
            return false;
        }
    }

    if (!uci_core.load(CONFIG_NAME) || !uci_core.exists(CONFIG_NAME + ".settings")) {
        warn("Forkop configuration is invalid or unavailable to UCI.\n");
        return false;
    }

    // The worker keeps the old module in memory; restart it so an upgrade
    // applies the new rule. The init script does nothing while disabled.
    if (!PACKAGE_TEST_MODE && path_exists('/etc/init.d/forkop-torrserver-direct'))
        command_success_from_args([ '/etc/init.d/forkop-torrserver-direct', 'restart' ]);

    if (!path_exists(PACKAGE_UPGRADE_STATE)) {
        clear_upgrade_quiesce();
        clear_compressed_upgrade_backup();
        return true;
    }

    if (!wait_for_upgrade_sing_box_exit()) {
        warn("Timed out waiting for the previous Forkop sing-box runtime to exit; startup was not attempted.\n");
        return false;
    }

    if (!command_success_from_args([ INIT_PATH, "start" ])) {
        warn("Forkop package restore could not start the service.\n");
        return false;
    }
    if (!wait_for_restored_service()) {
        warn("Timed out waiting for the Forkop package restore to finish.\n");
        return false;
    }

    unlink_if_exists(PACKAGE_UPGRADE_STATE);
    clear_upgrade_quiesce();
    clear_compressed_upgrade_backup();
    return true;
}

function luci_cache_globs() {
    let configured = env("FORKOP_LUCI_CACHE_GLOBS", "");
    if (configured != "")
        return split(configured, /[ \t\r\n]+/);

    return [ "/var/luci-indexcache*", "/tmp/luci-indexcache*" ];
}

function remove_luci_index_cache() {
    for (let pattern in luci_cache_globs()) {
        pattern = as_string(pattern);
        if (pattern == "")
            continue;

        for (let path in fs.glob(pattern))
            unlink_if_exists(path);
    }
}

function luci_postinst() {
    remove_luci_index_cache();
    if (!PACKAGE_TEST_MODE) {
        if (path_exists("/etc/init.d/rpcd"))
            command_success_from_args([ "/etc/init.d/rpcd", "reload" ]);
        command_success_from_args([ "logger", "-t", "forkop", "[info] Package defaults applied" ]);
    }
    return true;
}

let mode = ARGV[0] || "";

if (mode == "prerm")
    exit(prerm_cleanup(ARGV[1]) ? 0 : 1);
else if (mode == "postinst")
    exit(postinst_restore() ? 0 : 1);
else if (mode == "remove-rt-tables-entry")
    exit(remove_rt_tables_entry() ? 0 : 1);
else if (mode == "luci-postinst")
    exit(luci_postinst() ? 0 : 1);
else if (mode == "sing-box-exe-path-fixture")
    exit(sing_box_exe_path(ARGV[1]) ? 0 : 1);
else {
    warn("Usage: service/package.uc <prerm|postinst|remove-rt-tables-entry|luci-postinst>\n");
    exit(1);
}
