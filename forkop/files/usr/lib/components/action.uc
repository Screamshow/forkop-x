#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");
let uci_core = require("core.uci");
let netstat = require("core.netstat");
let github_http = require("core.github_http");
let storage_cleanup = require("components.storage_cleanup");
let xrust = require("xrust.binary");

const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || constants.FORKOP_CONFIG_NAME || "forkop";
const XRUST_BINARY = xrust.PATH;
const LEGACY_XRUST_RELEASE = "0.0.44";
const BIN_PATH = getenv("FORKOP_BIN") || constants.FORKOP_BIN || "/usr/bin/forkop";
const SERVICE_INIT = getenv("FORKOP_SERVICE_INIT") || constants.FORKOP_SERVICE_INIT || "/etc/init.d/forkop";
const FORKOP_VERSION = getenv("FORKOP_VERSION") || constants.FORKOP_VERSION || "";
const FORKOP_RELEASE_REPO = getenv("FORKOP_RELEASE_REPO") || constants.FORKOP_RELEASE_REPO || "Screamshow/forkop-x";
const FORKOP_MIRROR_BASE_URL = getenv("FORKOP_MIRROR_BASE_URL") || constants.FORKOP_MIRROR_BASE_URL || "";
const RUNTIME_STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const START_FAILURE_FILE = getenv("FORKOP_START_FAILURE_FILE") || RUNTIME_STATE_DIR + "/start.failure";
const GITHUB_BACKOFF_FILE = RUNTIME_STATE_DIR + "/github-api-backoff.json";
const PACKAGE_UPGRADE_STATE = getenv("FORKOP_PACKAGE_UPGRADE_STATE") || "/tmp/forkop-package-was-running";
const UPGRADE_RECOVERY_HOOK = "/etc/rc.d/S98forkop-upgrade-recovery";
const UPGRADE_RECOVERY_SCRIPT = "/usr/share/forkop/upgrade-recovery";
const FORKOP_UPGRADE_IDLE_WAIT_SECONDS = int(getenv("FORKOP_UPGRADE_IDLE_WAIT_SECONDS") || "180");
const SYSTEM_INFO_CACHE_FILE = getenv("FORKOP_SYSTEM_INFO_CACHE_FILE") || RUNTIME_STATE_DIR + "/system-info.json";
const COMPONENT_LOCK_DIR = getenv("UPDATES_LOCK_DIR") || RUNTIME_STATE_DIR + "/component-action.lock";
const TMP_STALE_TTL_MINUTES = getenv("UPDATES_TMP_STALE_TTL_MINUTES") || "30";
const TMP_FILE_STALE_TTL_MINUTES = getenv("UPDATES_TMP_FILE_STALE_TTL_MINUTES") || "10";
const TORRSERVER_DIRECT_INIT = getenv("FORKOP_TORRSERVER_DIRECT_INIT") || "/etc/init.d/forkop-torrserver-direct";
const TORRSERVER_DIRECT_UC = LIB_DIR + "/torrserver/direct.uc";

let tmp_dir = "";
let repository_indexes_ready = false;
let lock_held = false;
let forkop_was_running = false;
let forkop_was_enabled = false;
let last_logged_output = "";
let forkop_configuration_backup = "";
let preserve_update_recovery_files = false;
let forkop_package_init = "";
let upgrade_recovery_owned = false;
let forkop_package_version_reader = "";
// Repository staging is declared before the download helpers. ucode needs a
// shared binding here instead of capturing an uninitialised function value.
let limited_download_command;

function as_string(value) {
    return value == null ? "" : "" + value;
}

function configured_runtime_cache() {
    let config_path = as_string(uci_core.get(CONFIG_NAME + ".settings.config_path") || "/etc/xrust/config.json");
    try {
        let config = json(fs.readfile(config_path));
        return config.experimental.cache_file.enabled
            ? as_string(config.experimental.cache_file.path) : "";
    }
    catch (e) { return ""; }
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function command_env(assignments) {
    let parts = [];
    for (let name, value in assignments)
        push(parts, name + "=" + shell_quote(value));
    return join(" ", parts);
}

function command_status(command) {
    let status = int(system(command));
    return status > 255 ? int(status / 256) : status;
}

function command_success(command) {
    return command_status("(" + command + ") >/dev/null 2>&1") == 0;
}

function command_success_from_args(args) {
    return command_success(command_from_args(args));
}

function command_output(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";
    return as_string(data);
}

function command_output_from_args(args) {
    return command_output(command_from_args(args));
}

function command_exists(name) {
    return command_success_from_args([ "command", "-v", name ]);
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function write_file(path, value) {
    return fs.writefile(as_string(path), as_string(value)) != null;
}

function read_file(path) {
    let data = fs.readfile(as_string(path));
    return data == null ? "" : as_string(data);
}

function parse_json_object(value) {
    try {
        let parsed = json(as_string(value));
        return type(parsed) == "object" ? parsed : {};
    }
    catch (e) {
        return {};
    }
}

function remove_file(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function ensure_dir(path) {
    return command_success_from_args([ "mkdir", "-p", as_string(path) ]);
}

function file_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function file_nonempty(path) {
    let stat = fs.stat(as_string(path));
    return stat != null && int(stat.size || 0) > 0;
}

function now_seconds() {
    return int(clock()[0]);
}

function owner_pid() {
    let pid = trim(command_output_from_args([ "sh", "-c", "echo $PPID" ]));
    return match(pid, /^[0-9]+$/) != null ? pid : "0";
}

function pid_running(pid) {
    pid = as_string(pid);
    return match(pid, /^[0-9]+$/) != null && command_success_from_args([ "kill", "-0", pid ]);
}

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "forkop", "[" + level + "] " + as_string(message) ]);
}

function updates_log(message, level) {
    log_message("Updates: " + as_string(message), level || "info");
}

function module_command(args) {
    let command_args = [ "ucode", "-L", LIB_DIR ];
    for (let arg in args)
        push(command_args, arg);
    return command_from_args(command_args);
}

function module_output(args) {
    return command_output(module_command(args));
}

function module_success(args) {
    return command_success(module_command(args));
}

function helper_output(mode, args) {
    let command_args = [ LIB_DIR + "/components/updater.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    return module_output(command_args);
}

function helper_success(mode, args) {
    let command_args = [ LIB_DIR + "/components/updater.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    return module_success(command_args);
}

function cleanup_stale_tmp_files() {
    storage_cleanup.prune("/tmp", [ "/usr/bin/sing-box", "/usr/lib/libcronet.so" ], now_seconds(),
        int(TMP_STALE_TTL_MINUTES) * 60, int(TMP_FILE_STALE_TTL_MINUTES) * 60, COMPONENT_LOCK_DIR, owner_pid());
}

function init_tmp_dir() {
    if (tmp_dir != "")
        return true;

    cleanup_stale_tmp_files();
    tmp_dir = trim(command_output_from_args([ "mktemp", "-d", "/tmp/forkop-updates.XXXXXX" ]));
    if (tmp_dir == "") {
        tmp_dir = "/tmp/forkop-updates." + owner_pid();
        if (!ensure_dir(tmp_dir)) {
            tmp_dir = "";
            return false;
        }
    }
    write_file(tmp_dir + "/.forkop-owner", owner_pid() + "\n");
    return true;
}

function make_tmp_file(prefix) {
    init_tmp_dir();
    let base = tmp_dir != "" ? tmp_dir + "/" + as_string(prefix) + ".XXXXXX" : "/tmp/forkop-updates-" + as_string(prefix) + ".XXXXXX";
    let path = trim(command_output_from_args([ "mktemp", base ]));
    if (path == "") {
        path = (tmp_dir != "" ? tmp_dir : "/tmp") + "/" + as_string(prefix) + "." + owner_pid() + "." + now_seconds();
        if (!write_file(path, ""))
            return "";
    }
    return path;
}

function helper_output_input(input, mode, args) {
    let input_path = make_tmp_file("helper-input");
    if (input_path == "")
        return "";
    write_file(input_path, as_string(input));

    let command_args = [ LIB_DIR + "/components/updater.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    let output = command_output(command_from_args([ "cat", input_path ]) + " | " + module_command(command_args));
    remove_file(input_path);
    return output;
}

function helper_success_input(input, mode, args) {
    let input_path = make_tmp_file("helper-input");
    if (input_path == "")
        return false;
    write_file(input_path, as_string(input));

    let command_args = [ LIB_DIR + "/components/updater.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    let ok = command_success(command_from_args([ "cat", input_path ]) + " | " + module_command(command_args));
    remove_file(input_path);
    return ok;
}

function cleanup_tmp_dir() {
    if (preserve_update_recovery_files) {
        if (tmp_dir != "") write_file(tmp_dir + "/.forkop-recovery", "1\n");
        return;
    }
    if (tmp_dir != "") {
        command_success_from_args([ "rm", "-rf", tmp_dir ]);
        tmp_dir = "";
    }
    cleanup_stale_tmp_files();
}

function acquire_component_lock() {
    ensure_dir(RUNTIME_STATE_DIR);
    if (command_success_from_args([ "mkdir", COMPONENT_LOCK_DIR ])) {
        write_file(COMPONENT_LOCK_DIR + "/pid", owner_pid() + "\n");
        lock_held = true;
        return true;
    }

    let current_owner = trim(read_file(COMPONENT_LOCK_DIR + "/pid"));
    if (current_owner != "" && pid_running(current_owner))
        return false;

    remove_file(COMPONENT_LOCK_DIR + "/pid");
    command_success_from_args([ "rmdir", COMPONENT_LOCK_DIR ]);
    if (!command_success_from_args([ "mkdir", COMPONENT_LOCK_DIR ]))
        return false;

    write_file(COMPONENT_LOCK_DIR + "/pid", owner_pid() + "\n");
    lock_held = true;
    return true;
}

function release_component_lock() {
    if (!lock_held)
        return;
    remove_file(COMPONENT_LOCK_DIR + "/pid");
    command_success_from_args([ "rmdir", COMPONENT_LOCK_DIR ]);
    lock_held = false;
}

function clear_owned_upgrade_quiesce() {
    module_success([ LIB_DIR + "/service/ui.uc", "clear-package-upgrade-quiesce-if-owner", owner_pid() ]);
}

function cleanup_action() {
    if (upgrade_recovery_owned && !preserve_update_recovery_files &&
        !command_success_from_args([ UPGRADE_RECOVERY_HOOK, "commit" ])) {
        preserve_update_recovery_files = true;
        updates_log("Could not clear the Forkop package recovery journal", "error");
    }
    clear_owned_upgrade_quiesce();
    cleanup_tmp_dir();
    release_component_lock();
}

function updates_response(success, component, action, message, current_version, latest_version, changed, status, release_url) {
    write_json({
        success: !!success,
        kind: "component",
        component: as_string(component),
        action: as_string(action),
        message: as_string(message),
        current_version: as_string(current_version),
        latest_version: as_string(latest_version),
        changed: int(changed || 0),
        status: as_string(status),
        release_url: as_string(release_url)
    });
}

function action_success(component, action, message, current_version, latest_version, changed, status, release_url) {
    updates_response(true, component, action, message, current_version, latest_version, changed || 0, status || "", release_url || "");
    cleanup_action();
    exit(0);
}

function action_fail(component, action, message, current_version, latest_version, status, release_url) {
    updates_log(message, "error");
    updates_response(false, component, action, message, current_version || "", latest_version || "", 0, status || "", release_url || "");
    cleanup_action();
    exit(1);
}

function run_logged(description, command) {
    init_tmp_dir();
    let output_file = make_tmp_file("command");
    if (output_file == "")
        output_file = "/tmp/forkop-updates-command." + owner_pid();

    updates_log(description);
    let status;
    for (let attempt = 0; attempt <= 15; attempt++) {
        status = command_status(as_string(command) + " >" + shell_quote(output_file) + " 2>&1");
        last_logged_output = read_file(output_file);
        for (let line in split(last_logged_output, "\n"))
            if (trim(as_string(line)) != "")
                updates_log(line);
        // opkg fails before changing packages when its global lock is busy.
        // Retry that specific failure only; package hook errors are not safe
        // to repeat. Retrying the command also avoids a check/acquire race.
        if (status == 0 ||
            index(last_logged_output, "opkg_conf_load: Could not lock ") < 0 ||
            index(last_logged_output, "Resource temporarily unavailable") < 0 || attempt == 15)
            break;
        updates_log("opkg is busy; waiting 2 seconds before retrying " + description, "warn");
        command_success_from_args([ "sleep", "2" ]);
    }
    remove_file(output_file);
    if (status != 0)
        updates_log(description + " failed with exit code " + status, "warn");
    return status == 0;
}

function is_apk() {
    return command_exists("apk");
}

function pkg_is_installed(package_name) {
    package_name = as_string(package_name);
    if (is_apk())
        return command_success_from_args([ "apk", "info", "-e", package_name ]);
    return module_success([ LIB_DIR + "/core/packages.uc", "opkg-installed", package_name ]);
}

function installed_package_version(package_name) {
    package_name = as_string(package_name);
    if (is_apk()) {
        if (!pkg_is_installed(package_name))
            return "";
        return trim(module_output([ LIB_DIR + "/core/packages.uc", "apk-version", package_name ]));
    }
    return trim(module_output([ LIB_DIR + "/core/packages.uc", "opkg-version", package_name ]));
}

// installed_package_version() reports an unanswered query and a package that
// is not installed as the same empty string. Verification after an upgrade
// must tell them apart: opkg fails read-only queries while its global lock is
// busy, and that is no reason to discard a good installation.
function read_installed_package_version(package_name, reader_path) {
    package_name = as_string(package_name);
    let output_file = make_tmp_file("version");
    if (output_file == "")
        output_file = "/tmp/forkop-updates-version." + owner_pid();

    let state;
    for (let attempt = 0; attempt <= 2; attempt++) {
        let status = command_status(module_command([ reader_path || LIB_DIR + "/core/packages.uc",
            "installed-version", package_name ]) + " >" + shell_quote(output_file) + " 2>&1");
        let line = trim(as_string(split(read_file(output_file), "\n")[0] || ""));
        if (substr(line, 0, 6) == "found ")
            state = { state: "found", version: trim(substr(line, 6)), error: "" };
        else if (line == "missing")
            state = { state: "missing", version: "", error: "" };
        else
            state = { state: "error", version: "", error:
                substr(line, 0, 6) == "error " ? trim(substr(line, 6)) :
                (line != "" ? line : "the version query failed with exit code " + status) };
        if (state.state != "error" || attempt == 2)
            break;
        updates_log("Retrying the installed version query for " + package_name +
            ": " + state.error, "warn");
        command_success_from_args([ "sleep", "1" ]);
    }
    remove_file(output_file);
    return state;
}

function forkop_installed_version_mismatch(expected, names, reader_path) {
    expected = as_string(expected);
    let mismatched = [];
    for (let name in names) {
        name = as_string(name);
        let state = read_installed_package_version(name, reader_path);
        if (state.state == "found" && state.version == expected)
            continue;
        if (state.state == "found")
            push(mismatched, name + " " + state.version);
        else if (state.state == "missing")
            push(mismatched, name + " not installed");
        else
            // The release metadata was verified before the transaction and
            // every install command reported success. Record why the version
            // could not be read instead of rolling the installation back.
            updates_log("Could not read the installed version of " + name +
                " after installation: " + state.error, "warn");
    }
    if (length(mismatched) == 0)
        return "";
    return "Forkop package versions disagree after installation (expected " +
        expected + ", installed " + join("; ", mismatched) + ")";
}

function pkg_list_update_command() {
    return is_apk() ? "apk update </dev/null" : "opkg update </dev/null";
}

function ensure_repository_indexes() {
    if (repository_indexes_ready)
        return true;
    repository_indexes_ready = run_logged("Updating package lists before package staging", pkg_list_update_command());
    return repository_indexes_ready;
}

function pkg_install_name_command(package_name) {
    return is_apk() ? command_from_args([ "apk", "add", package_name ]) + " </dev/null" :
        command_from_args([ "opkg", "install", package_name ]) + " </dev/null";
}

function pkg_install_files_command(files) {
    let args = is_apk() ? [ "apk", "add", "--allow-untrusted" ] : [ "opkg", "install", "--force-overwrite", "--force-downgrade" ];
    if (is_apk() && forkop_package_init != "")
        args = [ "apk", "--preserve-env", "add", "--allow-untrusted" ];
    for (let file in files)
        push(args, file);
    return (forkop_package_init != "" ? command_env({ FORKOP_INIT: forkop_package_init }) + " " : "") +
        command_from_args(args) + " </dev/null";
}

function ipk_unpacked_bytes(path) {
    let archive = shell_quote(path);
    let command = "(tar -xzOf " + archive + " data.tar.gz 2>/dev/null || " +
        "tar -xzOf " + archive + " ./data.tar.gz 2>/dev/null) | " +
        "tar -tvzf - 2>/dev/null | awk '{ sum += $3 } END { printf \"%.0f\", sum }'";
    return int(trim(command_output(command)));
}

function staged_package_field(path, field) {
    let control_archive = "(tar -xzOf " + shell_quote(path) + " control.tar.gz 2>/dev/null || " +
        "tar -xzOf " + shell_quote(path) + " ./control.tar.gz 2>/dev/null)";
    // Both ./control (OpenWrt SDK) and control (Xrust) are valid IPK members.
    let command = is_apk() ? command_from_args([ "apk", "--allow-untrusted", "adbdump", path ]) :
        "(" + control_archive + " | tar -xzOf - ./control 2>/dev/null || " +
        control_archive + " | tar -xzOf - control 2>/dev/null)";
    let metadata = command_output(command);
    if (field == "installed-size") {
        // Measure files stored on flash, including an UPX-packed executable.
        // Producer metadata may describe an unpacked executable or use KiB.
        if (!is_apk())
            return sprintf("%d", ipk_unpacked_bytes(path));
        let bytes = 0;
        for (let line in split(metadata, "\n")) {
            let size = match(line, /^        size: ([0-9]+)$/);
            if (size != null) bytes += int(size[1]);
        }
        return sprintf("%d", bytes);
    }
    let key = (is_apk() ? field :
        field == "name" ? "Package" : field == "version" ? "Version" :
        field == "arch" ? "Architecture" : field == "depends" ? "Depends" :
        field == "provides" ? "Provides" : "Installed-Size") + ": ";
    for (let line in split(metadata, "\n")) {
        line = trim(as_string(line));
        if (substr(line, 0, length(key)) == key) {
            let value = trim(substr(line, length(key)));
            return value;
        }
    }
    return "";
}

function staged_package_info(path, expected_name, expected_version) {
    if (!file_nonempty(path))
        return null;
    let name = staged_package_field(path, "name");
    let version = staged_package_field(path, "version");
    let arch = staged_package_field(path, "arch");
    let size = int(staged_package_field(path, "installed-size"));
    if (name != expected_name || version == "" ||
        (as_string(expected_version) != "" && version != expected_version) ||
        arch == "" || size <= 0)
        return null;
    let supported = arch == "all" || arch == "noarch";
    if (is_apk()) {
        // apk has a compatibility table which is broader than --print-arch.
        // For example, an OpenWrt 25 aarch64 APK host accepts the
        // aarch64_cortex-a53 package produced for mediatek/filogic.  Comparing
        // these strings here rejects a valid archive before apk can resolve it.
        // Keep metadata validation above, and let apk validate architecture
        // during the local-file transaction.
        supported = true;
    }
    else {
        for (let line in split(command_output_from_args([ "opkg", "print-architecture" ]), "\n")) {
            let fields = split(trim(line), " ");
            if (length(fields) > 1 && fields[1] == arch)
                supported = true;
        }
    }
    return supported ? { path, name, version, size } : null;
}

function package_sha256(path) {
    return split(trim(command_output_from_args([ "sha256sum", path ])), /[ \t]+/)[0];
}

function ipk_provides(provides, name) {
    for (let entry in split(as_string(provides), ","))
        if (trim(replace(entry, /\s*\([^)]*\)/g, "")) == name)
            return true;
    return false;
}

function stage_repository_package(package_name, expected_version) {
    // Both apk fetch and opkg download need repository indexes, including
    // when the current package is being saved for rollback.
    if (!ensure_repository_indexes())
        return null;
    let ext = is_apk() ? "apk" : "ipk";
    let command = is_apk() ?
        command_from_args([ "apk", "fetch", "-o", tmp_dir, package_name ]) :
        "cd " + shell_quote(tmp_dir) + " && " + command_from_args([ "opkg", "download", package_name ]);
    let downloaded = false;
    for (let attempt = 1; attempt <= 3; attempt++) {
        let limited = limited_download_command(command);
        if (limited == "") return null;
        if (run_logged("Downloading " + package_name + " before package change (" + attempt + "/3)", limited)) {
            downloaded = true;
            break;
        }
    }
    if (!downloaded)
        return null;
    let matches = command_output("find " + shell_quote(tmp_dir) + " -maxdepth 1 -type f -name " +
        shell_quote(is_apk() ? package_name + "-*." + ext : "*.ipk"));
    for (let path in split(matches, "\n")) {
        path = trim(path);
        let actual_name = is_apk() ? package_name : staged_package_field(path, "name");
        if (actual_name != package_name &&
            (as_string(expected_version) != "" || !ipk_provides(staged_package_field(path, "provides"), package_name)))
            continue;
        let info = staged_package_info(path, actual_name, expected_version);
        if (info != null) {
            return info;
        }
    }
    return null;
}

function array_has(values, item) {
    for (let value in values)
        if (value == item)
            return true;
    return false;
}

function available_kib(path) {
    let output = trim(command_output("df -Pk " + shell_quote(path) + " | tail -n 1 | awk '{print $4}'"));
    return match(output, /^[0-9]+$/) == null ? -1 : int(output);
}

function temporary_capacity_kib(filesystem_kib, memory_kib) {
    if (filesystem_kib < 0 || memory_kib < 0) return -1;
    return filesystem_kib < memory_kib ? filesystem_kib : memory_kib;
}

function temporary_available_kib() {
    let memory = match(read_file("/proc/meminfo"), /MemAvailable:\s+([0-9]+) kB/);
    return temporary_capacity_kib(available_kib(tmp_dir || "/tmp"), memory == null ? -1 : int(memory[1]));
}

limited_download_command = function(command, capacity_kib) {
    // tmpfs capacity alone does not describe physical RAM. Bound the output
    // file using BusyBox sh's 512-byte RLIMIT_FSIZE units, leaving workspace.
    let budget = (capacity_kib == null ? temporary_available_kib() : capacity_kib) - 8192;
    if (budget <= 0) {
        updates_log("Not enough temporary memory for download", "error");
        return "";
    }
    return "sh -c " + shell_quote("ulimit -f " + (budget * 2) + " || exit 1; " + command);
};

function bounded_download(command, capacity_kib) {
    let limited = limited_download_command(command, capacity_kib);
    return limited != "" && command_success(limited);
}

function file_bytes(path) {
    let stat = fs.stat(as_string(path));
    return stat == null ? 0 : int(stat.size || 0);
}

function status_from_compare(compare_result) {
    if (compare_result == -1)
        return "outdated";
    if (compare_result == 0)
        return "latest";
    if (compare_result == 1)
        return "dev";
    return "";
}

function read_openwrt_release_value(key) {
    return trim(helper_output("openwrt-release-value", [ "/etc/openwrt_release", key ]));
}

function service_proxy_address() {
    if (!file_exists(LIB_DIR + "/xrust/runtime.uc"))
        return "";
    if (file_exists(LIB_DIR + "/service/state.uc") &&
        !module_success([ LIB_DIR + "/service/state.uc", "sing-box-service-running" ]))
        return "";
    return trim(module_output([ LIB_DIR + "/xrust/runtime.uc", "service-proxy-address", "components" ]));
}

function http_get_once(url, output_path, proxy_address, timeout) {
    url = as_string(url);
    output_path = as_string(output_path);
    proxy_address = as_string(proxy_address);
    timeout = as_string(timeout || "30");

    if (command_exists("curl")) {
        let args = [ "curl", "--connect-timeout", "5", "-m", timeout,
            "--speed-time", "15", "--speed-limit", "1", "-fsSL" ];
        if (proxy_address != "") {
            push(args, "-x");
            push(args, "http://" + proxy_address);
        }
        push(args, url);
        push(args, "-o");
        push(args, output_path);
        return bounded_download(command_from_args(args));
    }

    if (command_exists("wget")) {
        let command = command_from_args([ "wget", "-T", timeout, "-q", "-O", output_path, url ]);
        if (proxy_address != "")
            command = command_env({ http_proxy: "http://" + proxy_address, https_proxy: "http://" + proxy_address }) + " " + command;
        return bounded_download(command);
    }

    return false;
}

function http_get(url) {
    init_tmp_dir();
    let output_path = make_tmp_file("http");
    if (output_path == "")
        return "";

    let proxy_address = service_proxy_address();
    if (proxy_address != "") {
        if (http_get_once(url, output_path, proxy_address, "30")) {
            let data = read_file(output_path);
            remove_file(output_path);
            return data;
        }
        remove_file(output_path);
        updates_log("HTTP request via service proxy failed for " + as_string(url) + "; retrying directly", "warn");
    }

    if (http_get_once(url, output_path, "", "30")) {
        let data = read_file(output_path);
        remove_file(output_path);
        return data;
    }

    remove_file(output_path);
    return "";
}

function download_file_once(url, output_path) {
    let proxy_address = service_proxy_address();
    if (proxy_address != "") {
        if (http_get_once(url, output_path, proxy_address, "120"))
            return true;
        remove_file(output_path);
        updates_log("Download via service proxy failed for " + as_string(url) + "; retrying directly", "warn");
    }
    return http_get_once(url, output_path, "", "120");
}

function download_with_retry(url, output_path, label) {
    for (let attempt = 1; attempt <= 3; attempt++) {
        updates_log("Downloading " + as_string(label) + " (" + attempt + "/3)");
        if (download_file_once(url, output_path) && file_nonempty(output_path))
            return true;
        remove_file(output_path);
        updates_log("Retrying " + as_string(label), "warn");
    }
    return false;
}

function github_backoff_active() {
    let state;
    try { state = json(read_file(GITHUB_BACKOFF_FILE)); }
    catch (e) { return false; }
    let remaining = int(state?.until || 0) - time();
    if (remaining <= 0 || remaining > 86400)
        return false;
    updates_log("GitHub API rate limit backoff; retry in " + remaining + "s", "warn");
    return true;
}

function fetch_github_json(url) {
    if (github_backoff_active())
        return "";
    if (!command_exists("curl"))
        return http_get(url);
    let output = make_tmp_file("github-body");
    let headers = make_tmp_file("github-headers");
    let status_path = make_tmp_file("github-status");
    if (output == "" || headers == "" || status_path == "")
        return "";
    let proxy = service_proxy_address();
    for (let address in (proxy == "" ? [ "" ] : [ proxy, "" ])) {
        let args = [ "curl", "--connect-timeout", "5", "-m", "30", "-sSL",
            "-H", "User-Agent: Forkop-OpenWrt", "-D", headers,
            "-o", output, "-w", "%{http_code}" ];
        if (address != "") {
            push(args, "-x");
            push(args, "http://" + address);
        }
        push(args, url);
        let ok = bounded_download(command_from_args(args) + " >" + shell_quote(status_path));
        let status = trim(read_file(status_path));
        let body = read_file(output);
        let limit = ok ? github_http.rate_limit(status, read_file(headers), body, time()) : null;
        if (limit != null) {
            if (ensure_dir(RUNTIME_STATE_DIR)) {
                let staged = GITHUB_BACKOFF_FILE + "." + owner_pid();
                if (write_file(staged, sprintf("%J", limit)))
                    fs.rename(staged, GITHUB_BACKOFF_FILE);
                remove_file(staged);
            }
            updates_log(limit.message, "warn");
            break;
        }
        if (ok && status == "200" && helper_success_input(body, "github-response-ok", [])) {
            remove_file(output);
            remove_file(headers);
            remove_file(status_path);
            return body;
        }
        updates_log("GitHub API request failed (HTTP " + (status || "000") + ")" +
            (address != "" ? "; retrying directly" : ""), "warn");
    }
    remove_file(output);
    remove_file(headers);
    remove_file(status_path);
    return "";
}

function fetch_github_release_json(owner, repo) {
    let response = fetch_github_json("https://api.github.com/repos/" + as_string(owner) + "/" + as_string(repo) + "/releases/latest");
    if (response == "" || !helper_success_input(response, "github-response-ok", []))
        return "";
    return response;
}

function forkop_update_channel() {
    // A stable build may have inherited update_channel=canary while it was
    // upgraded from a canary release. Never let that stale setting make a
    // stable installation consume pre-release metadata.
    if (match(FORKOP_VERSION, /-canary[.][0-9]+$/) == null)
        return "stable";

    return "canary";
}

function forkop_release_requires_xrust(version) {
    let parts = match(as_string(version), /^([0-9]+)[.][0-9]+[.][0-9]+(-canary[.][0-9]+)?$/);
    return parts != null && int(parts[1]) >= 3;
}

function valid_xrust_pin(pin) {
    return type(pin) == "string" && match(pin, /^[0-9]+[.][0-9]+[.][0-9]+$/) != null;
}

function parse_forkop_release_catalog(response, ext) {
    let catalog;
    try { catalog = json(response); } catch (e) { return []; }
    if (type(catalog) != "object" || catalog.format != 1 || type(catalog.releases) != "array")
        return [];
    let releases = [];
    for (let release in catalog.releases) {
        if (type(release) != "object" ||
            match(as_string(release.tag_name), /^[0-9]+[.][0-9]+[.][0-9]+(-canary[.][0-9]+)?$/) == null)
            continue;
        if (forkop_release_requires_xrust(release.tag_name) && !valid_xrust_pin(release.xrust_version))
            continue;
        if (type(release.assets) != "array") continue;
        let prefix = "/forkop/updates/" + (match(release.tag_name, /-canary[.]/) != null ? "canary/" : "") + "releases/" + release.tag_name + "/";
        let complete = true;
        for (let kind in [ "forkop", "luci-app-forkop", "luci-i18n-forkop-ru" ]) {
            let found = false;
            for (let asset in release.assets || []) {
                if (type(asset) == "object" && asset.name == kind + "_" + release.tag_name + "." + ext &&
                    match(as_string(asset.sha256), /^[a-f0-9]{64}$/) != null &&
                    as_string(asset.browser_download_url) == prefix + asset.name)
                    found = true;
            }
            if (!found) complete = false;
        }
        if (complete) push(releases, release);
    }
    return releases;
}

function forkop_release_catalog() {
    return parse_forkop_release_catalog(http_get(FORKOP_MIRROR_BASE_URL + "/forkop/updates/releases.json"), is_apk() ? "apk" : "ipk");
}

function forkop_releases() {
    let releases = forkop_release_catalog();
    let rows = [];
    for (let release in releases)
        push(rows, { version: release.tag_name, channel: match(release.tag_name, /-canary[.]/) != null ? "canary" : "stable" });
    print(sprintf("%J", { success: length(rows) > 0, releases: rows }), "\n");
    cleanup_tmp_dir();
}

function selected_forkop_release(version) {
    for (let release in forkop_release_catalog())
        if (release.tag_name == version) return release;
    return null;
}

function latest_forkop_release_json() {
    if (FORKOP_MIRROR_BASE_URL != "") {
        let response = http_get(FORKOP_MIRROR_BASE_URL + "/forkop/updates/" + forkop_update_channel() + ".json");
        let release = parse_json_object(response);
        if (forkop_release_requires_xrust(release.tag_name) && !valid_xrust_pin(release.xrust_version))
            return "";
        return response;
    }

    let parts = split(FORKOP_RELEASE_REPO, "/");
    if (length(parts) != 2 || as_string(parts[0]) == "" || as_string(parts[1]) == "")
        return "";
    return fetch_github_release_json(parts[0], parts[1]);
}

function forkop_release_url(value) {
    value = as_string(value);
    if (FORKOP_MIRROR_BASE_URL != "" && substr(value, 0, 1) == "/")
        return FORKOP_MIRROR_BASE_URL + value;
    return value;
}

function forkop_release_page_url(version, fallback) {
    let parts = split(FORKOP_RELEASE_REPO, "/");
    version = as_string(version);
    if (length(parts) == 2 &&
        match(as_string(parts[0]), /^[A-Za-z0-9_.-]+$/) != null &&
        match(as_string(parts[1]), /^[A-Za-z0-9_.-]+$/) != null &&
        match(version, /^[0-9]+[.][0-9]+[.][0-9]+(-canary[.][0-9]+)?$/) != null)
        return "https://github.com/" + parts[0] + "/" + parts[1] + "/releases/tag/" + version;

    return forkop_release_url(fallback);
}

function latest_forkop_version() {
    let response = latest_forkop_release_json();
    if (response == "")
        return "";
    return trim(helper_output_input(response, "object-get-default", [ "tag_name", "" ]));
}

function fetch_forkop_latest_release_metadata() {
    let response = latest_forkop_release_json();
    if (response == "")
        return "";
    return trim(helper_output_input(response, "release-metadata-tsv", []));
}

function write_forkop_latest_version_cache(value, timestamp) {
    if (as_string(value) == "")
        return;
    write_file("/tmp/forkop.latest-version.cache", as_string(value) + "\n" + as_string(timestamp) + "\n");
}

function clear_version_caches() {
    remove_file("/tmp/forkop.latest-version.cache");
    remove_file(SYSTEM_INFO_CACHE_FILE);
    remove_file("/tmp/forkop/system-info.json");
}

function forkop_status_running_with_timeout() {
    init_tmp_dir();
    let output_file = make_tmp_file("forkop-status");
    if (output_file == "")
        return false;

    // The installed CLI may have changed since this action resolved its module cache.
    let command = command_env({ FORKOP_LIB: "" }) + " " + command_from_args([ BIN_PATH, "get_status" ]) +
        " >" + shell_quote(output_file) + " 2>/dev/null & pid=$!; " +
        "( sleep 6; kill $pid 2>/dev/null || true ) & watcher=$!; " +
        "wait $pid 2>/dev/null; rc=$?; kill $watcher 2>/dev/null || true; wait $watcher 2>/dev/null || true; exit $rc";
    let ok = command_status("sh -c " + shell_quote(command)) == 0 &&
        match(read_file(output_file), /"running"[ \t]*:[ \t]*1/) != null;
    remove_file(output_file);
    return ok;
}

function forkop_starting() {
    if (!file_exists(LIB_DIR + "/service/ui.uc"))
        return false;
    return trim(module_output([ LIB_DIR + "/service/ui.uc", "active-service-action" ])) == "start";
}

function wait_for_service_action_idle() {
    let remaining = FORKOP_UPGRADE_IDLE_WAIT_SECONDS;
    while (remaining >= 0) {
        if (module_success([ LIB_DIR + "/service/ui.uc", "service-action-idle" ]))
            return true;
        if (remaining == 0)
            break;
        command_success_from_args([ "sleep", "1" ]);
        remaining--;
    }
    return false;
}

function wait_for_forkop_restore(wait_for_explicit_start) {
    let deadline = clock(true)[0] + 180;
    while (clock(true)[0] < deadline) {
        let starting = forkop_starting();
        // A rejected configuration cannot become ready by waiting. During
        // an owned start the marker may still belong to the previous attempt.
        if (!starting && file_exists(START_FAILURE_FILE))
            return false;
        if (!starting && forkop_status_running_with_timeout())
            return true;
        // A package postinst may have detached its start worker from procd.
        // "starting" is an owned transition, not a reason to race it with a
        // second restart. Keep waiting for its explicit terminal state.
        if (!starting && !file_exists(PACKAGE_UPGRADE_STATE) && !wait_for_explicit_start)
            return false;
        if (clock(true)[0] >= deadline)
            break;
        command_success_from_args([ "sleep", "1" ]);
    }
    return false;
}

function capture_forkop_running_state() {
    // Readiness can fail temporarily (API timeout, respawn, young process).
    // Preserve an active managed lifecycle, rather than interpreting that as
    // an explicit Stop. Stop removes watchdog.ready and records shutdown=1.
    let state_module = LIB_DIR + "/service/state.uc";
    let managed_active = file_exists(RUNTIME_STATE_DIR + "/watchdog.ready") &&
        uci_core.get(CONFIG_NAME + ".settings.shutdown_correctly") == "0" &&
        file_exists(state_module) &&
        module_success([ state_module, "sing-box-service-running" ]);
    forkop_was_running = file_exists(BIN_PATH) &&
        (managed_active || forkop_status_running_with_timeout());
}

// The web version ("Zapret Manager for WEB + LuCI") is what the script's
// "w" command installs. Its state follows the script: installed when the
// rpcd backend exists, with the version from its backend.sh.
const ZAPRET_MANAGER_WEB_BACKEND = "/usr/libexec/rpcd/zapret-manager";
const ZAPRET_MANAGER_WEB_SCRIPT = "/opt/zapret-manager-luci/backend.sh";

function zapret_manager_web_installed_version() {
    let matched = match(read_file(ZAPRET_MANAGER_WEB_SCRIPT), /(^|\n)ZM_VERSION="([^"]*)"/);
    return matched != null ? matched[2] : "";
}

function install_zapret_manager(action) {
    let component = "zapret_manager";
    let current_version = zapret_manager_web_installed_version();
    if (FORKOP_MIRROR_BASE_URL == "")
        action_fail(component, action, "Forkop mirror URL is not configured", current_version);
    if (!run_logged("Migrating Zapret Manager with file rollback",
        command_from_args([ "sh", "/usr/share/forkop/zapret-manager-migrate.sh", action == "migrate" ? "migrate" : "install", FORKOP_MIRROR_BASE_URL ])))
        action_fail(component, action, "Zapret Manager migration failed; see component log and recovery result", current_version);
    let changed = index(last_logged_output, "FORKOP_ZM_CHANGED=1") >= 0 ? 1 : 0;
    clear_version_caches();
    action_success(component, action, "Zapret Manager backend, RPC and launchers verified",
        current_version, zapret_manager_web_installed_version(), changed, "latest");
}

// Remove the web version the way the script's "w" command does.
function remove_zapret_manager_web() {
    if (!file_exists(ZAPRET_MANAGER_WEB_BACKEND) && !file_exists(ZAPRET_MANAGER_WEB_SCRIPT))
        return true;
    let script = join("\n", [
        "rm -rf /opt/zapret-manager-luci /usr/libexec/rpcd/zapret-manager " +
            "/usr/share/luci/menu.d/luci-app-zapret-manager.json /usr/share/rpcd/acl.d/luci-app-zapret-manager.json " +
            "/www/luci-static/resources/view/zapret-manager /www/luci-static/resources/zapret-manager " +
            "/www/zm /www/zm-webui.html " +
            "/tmp/zapret-manager* /tmp/zm_uninstall_panel.sh /tmp/zm_luci_latest /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null",
        // These three legacy UI files were panel assets. Preserve directories
        // and standalone services even when the old panel knew about them.
        "rm -f /www/luci-static/resources/bytetube/common.js /www/luci-static/resources/bytetube/presets.js /www/luci-static/resources/view/bytetube/style.css",
        "uci -q delete uhttpd.zmweb && uci -q commit uhttpd",
        "/etc/init.d/rpcd restart >/dev/null 2>&1",
        "/etc/init.d/uhttpd restart >/dev/null 2>&1",
        "exit 0"
    ]);
    run_logged("Removing the Zapret-Manager web version", command_from_args([ "sh", "-c", script ]));
    return !file_exists(ZAPRET_MANAGER_WEB_BACKEND);
}

// Launchers Forkop may remove: its mirror launchers and the ones the web
// installer writes (they fetch through /tmp/zm-get.PID.sh). Any other
// /usr/bin/zms* belongs to the user and is kept.
function zapret_manager_launcher_owned(source) {
    return match(source, /https:\/\/[^ \t\r\n"')]*raw\.githubusercontent\.com\/(StressOzz|Screamshow)\/Zapret-Manager\/(refs\/heads\/)?main\/(Zapret-Manager|ZapretManager_LuCI)\.sh([ \t\r\n"')]|$)/) != null;
}

function remove_zapret_manager(action) {
    let component = "zapret_manager";
    let paths = [ "/usr/bin/zms", "/usr/bin/zmsA", "/usr/bin/zmw" ];
    let removed = 0;

    for (let path in paths)
        if (fs.readlink(path) != null || (file_exists(path) && !zapret_manager_launcher_owned(read_file(path))))
            action_fail(component, action, "Existing " + path + " was not created by Forkop X or Zapret-Manager and was not removed");
    if (!remove_zapret_manager_web())
        action_fail(component, action, "Failed to remove the Zapret-Manager web version");

    for (let path in paths) {
        if (!file_exists(path))
            continue;
        remove_file(path);
        if (file_exists(path))
            action_fail(component, action, "Failed to remove " + path);
        removed++;
    }

    clear_version_caches();
    action_success(component, action, removed > 0 ?
        "Zapret-Manager and its web version have been removed" :
        "Zapret-Manager launchers are already removed", "installed", "", 1);
}

function installed_xrust_build(legacy) {
    let binary = legacy ? xrust.LEGACY_PATH : XRUST_BINARY;
    if (!file_exists(binary)) return "";
    let output = command_output_from_args([ binary, "version" ]);
    return legacy ? xrust.legacy_version_from_output(output) : xrust.version_from_output(output);
}

function resolve_xrust_release(version) {
    let package_name = "rust-x";
    if (FORKOP_MIRROR_BASE_URL == "") return null;
    version = as_string(version);
    if (match(version, /^[0-9]+[.][0-9]+[.][0-9]+$/) == null)
        return null;
    let base = FORKOP_MIRROR_BASE_URL + "/forkop/" + package_name + "/";
    let catalog = parse_json_object(http_get(base + "releases/" + version + "/manifest.json"));
    if (catalog.schema != 1 || catalog.name != package_name || catalog.version != version ||
        type(catalog.package_revision) != "int" || catalog.package_revision <= 0 ||
        type(catalog.assets) != "array")
        return null;
    let arch = read_openwrt_release_value("DISTRIB_ARCH");
    let format = is_apk() ? "apk" : "ipk";
    for (let asset in catalog.assets || []) {
        // APK ARM64 and Beam cortex-a73 can use the cortex-a53 baseline build.
        let compatible = asset.architecture == arch ||
            (is_apk() && (arch == "aarch64" || arch == "aarch64_cortex-a73") && asset.architecture == "aarch64_cortex-a53");
        if (asset.package != package_name || asset.format != format || !compatible)
            continue;
        if (asset.name != package_name + "_" + asset.version + "_" + asset.architecture + "." + format ||
            match(as_string(asset.sha256), /^[a-f0-9]{64}$/) == null || int(asset.size) <= 0 ||
            asset.url != base + "releases/" + catalog.version + "/" + asset.name ||
            asset.version != catalog.version + (is_apk() ? "-r" : "-") + int(catalog.package_revision))
            return null;
        return { ...asset, native_xrust: catalog.minimum_forkop_major == 3 };
    }
    return null;
}

function stage_xrust_package(release, expected_version) {
    if (release == null || (as_string(expected_version) != "" && release.version != expected_version))
        return null;
    let path = tmp_dir + "/" + release.name;
    if (file_bytes(path) != int(release.size) || package_sha256(path) != release.sha256) {
        if (!download_with_retry(release.url, path, "Xrust package") ||
            file_bytes(path) != int(release.size) || package_sha256(path) != release.sha256)
            return null;
    }
    if (staged_package_field(path, "arch") != release.architecture)
        return null;
    return staged_package_info(path, release.package, release.version);
}

function check_forkop() {
    let metadata = fetch_forkop_latest_release_metadata();
    let fields = split(metadata, "\t");
    let latest_version = length(fields) > 0 && as_string(fields[0]) != "" ? as_string(fields[0]) : "unknown";
    let release_url = forkop_release_page_url(latest_version,
        length(fields) > 1 ? as_string(fields[1]) : "");
    if (latest_version == "unknown")
        action_fail("forkop", "check_update", "Failed to check Forkop updates", FORKOP_VERSION, latest_version);

    write_forkop_latest_version_cache(latest_version, now_seconds());
    if (!helper_success("forkop-release-version-valid", [ FORKOP_VERSION ])) {
        updates_log("Forkop current version is not a release version (" + FORKOP_VERSION + ")");
        action_success("forkop", "check_update", "Installed version is newer than release", FORKOP_VERSION, latest_version, 0, "dev", release_url);
    }

    let compare = trim(helper_output("forkop-release-version-compare", [ FORKOP_VERSION, latest_version ]));
    if (compare == "")
        action_fail("forkop", "check_update", "Failed to compare Forkop versions", FORKOP_VERSION, latest_version);
    let status = status_from_compare(int(compare));
    if (status == "")
        action_fail("forkop", "check_update", "Failed to compare Forkop versions", FORKOP_VERSION, latest_version);
    if (status == "latest") {
        updates_log("Forkop is already up to date (" + FORKOP_VERSION + ")");
        action_success("forkop", "check_update", "Latest version is installed", FORKOP_VERSION, latest_version, 0, status, release_url);
    }
    if (status == "outdated") {
        updates_log("Forkop update found: " + FORKOP_VERSION + " -> " + latest_version);
        action_success("forkop", "check_update", "Update is available", FORKOP_VERSION, latest_version, 0, status, release_url);
    }
    updates_log("Forkop installed version is newer than upstream release: " + FORKOP_VERSION + " -> " + latest_version);
    action_success("forkop", "check_update", "Installed version is newer than release", FORKOP_VERSION, latest_version, 0, status, release_url);
}

function parse_forkop_release_plan(plan, latest_version, i18n_required) {
    // The final two TSV fields are intentionally empty when i18n is absent.
    plan = replace(as_string(plan), /[\r\n]+$/, "");
    let fields = split(plan, "\t");
    if (length(fields) < 7 || as_string(fields[1]) == "" || as_string(fields[2]) == "" || as_string(fields[3]) == "" || as_string(fields[4]) == "")
        return null;
    if (i18n_required == "1" && (as_string(fields[5]) == "" || as_string(fields[6]) == ""))
        return null;
    return {
        release_url: forkop_release_page_url(latest_version, fields[0]),
        backend_name: fields[1],
        backend_url: forkop_release_url(fields[2]),
        app_name: fields[3],
        app_url: forkop_release_url(fields[4]),
        i18n_name: fields[5],
        i18n_url: forkop_release_url(fields[6])
    };
}

function resolve_forkop_release(latest_version, selected) {
    let release_json = selected != null ? sprintf("%J", selected) : latest_forkop_release_json();
    if (release_json == "")
        return null;
    let asset_ext = is_apk() ? "apk" : "ipk";
    let i18n_required = "1";
    let plan = helper_output_input(release_json, "forkop-release-plan", [ latest_version, asset_ext, i18n_required ]);
    let release = parse_forkop_release_plan(plan, latest_version, i18n_required);
    if (release != null) {
        try {
            let metadata = json(release_json);
            release.assets = type(metadata.assets) == "array" ? metadata.assets : [];
            release.xrust_version = metadata.xrust_version;
        }
        catch (e) { return null; }
    }
    return release;
}

function stage_forkop_release_archive(release, name, version) {
    let asset_name = name + "_" + release.tag_name + (is_apk() ? ".apk" : ".ipk");
    for (let asset in release.assets || []) {
        if (asset.name != asset_name)
            continue;
        let path = tmp_dir + "/rollback-" + asset_name;
        if (!download_with_retry(forkop_release_url(asset.browser_download_url), path, asset_name))
            return null;
        let actual = split(trim(command_output_from_args([ "sha256sum", path ])), /[ \t]+/)[0];
        if (actual != asset.sha256)
            return null;
        return staged_package_info(path, name, version);
    }
    return null;
}

function forkop_package_version(release_version) {
    if (is_apk())
        return replace(as_string(release_version), /-canary[.]([0-9]+)$/, "_rc$1");
    return as_string(release_version);
}

function forkop_release_version(package_version) {
    if (is_apk())
        return replace(as_string(package_version), /_rc([0-9]+)$/, "-canary.$1");
    return as_string(package_version);
}

function check_forkop_xrust_requirement(latest_version) {
    let installed = installed_package_version("rust-x");
    // The package database alone does not detect a manually replaced binary.
    let build = installed_xrust_build();
    if (build == "" || match(installed, /^[0-9]+[.][0-9]+[.][0-9]+-r?[1-9][0-9]*$/) == null ||
        replace(installed, /-r?[0-9]+$/, "") != build)
        action_fail("forkop", "install", "The installed Xrust package and binary must match before updating Forkop.",
            FORKOP_VERSION, latest_version);
    return installed;
}

function stage_forkop_xrust(release, current_version, latest_version) {
    let require_native = forkop_release_requires_xrust(latest_version);
    let pin = require_native ? release.xrust_version : LEGACY_XRUST_RELEASE;
    if (!valid_xrust_pin(pin))
        action_fail("forkop", "install", "The Forkop release does not specify an exact Xrust version",
            FORKOP_VERSION, latest_version);
    let pinned_release = resolve_xrust_release(pin);
    if (pinned_release == null)
        action_fail("forkop", "install", "Xrust " + pin + " is unavailable for this router",
            FORKOP_VERSION, latest_version);
    if (pinned_release.native_xrust !== require_native)
        action_fail("forkop", "install", "The selected Xrust package is incompatible with Forkop " + latest_version,
            FORKOP_VERSION, latest_version);
    if (pinned_release.version == current_version)
        return null;

    let target = stage_xrust_package(pinned_release, pinned_release.version);
    let rollback = stage_xrust_package(resolve_xrust_release(replace(current_version, /-r?[0-9]+$/, "")), current_version);
    if (target == null || rollback == null || rollback.version != current_version)
        action_fail("forkop", "install", "Cannot stage the exact Xrust packages for update and rollback",
            FORKOP_VERSION, latest_version);
    return { target, rollback, pin, legacy: !require_native };
}

function stage_forkop_rollback_packages() {
    let staged = [];
    let current = read_installed_package_version("forkop", forkop_package_version_reader);
    if (current.state != "found")
        return null;
    let release = selected_forkop_release(forkop_release_version(current.version));
    for (let name in [ "luci-app-forkop", "luci-i18n-forkop-ru", "forkop" ]) {
        let installed = name == "forkop" ? current : read_installed_package_version(name, forkop_package_version_reader);
        if (name == "luci-i18n-forkop-ru" && installed.state == "missing")
            continue;
        if (installed.state != "found")
            return null;
        let archive = release != null && installed.version == current.version ?
            stage_forkop_release_archive(release, name, installed.version) : null;
        if (archive == null)
            archive = stage_repository_package(name, installed.version);
        if (archive == null)
            return null;
        push(staged, archive);
    }
    return staged;
}

function forkop_package_space_error(overlay_kib, tmp_kib, target_bytes, rollback_bytes, recovery_bytes) {
    let target_kib = int((target_bytes + 1023) / 1024);
    let rollback_kib = int((rollback_bytes + 1023) / 1024);
    // Flash reserve is independent of the temporary workspace allowance.
    // Budget the larger extracted payload and allow for package metadata.
    let payload_kib = target_kib > rollback_kib ? target_kib : rollback_kib;
    let overlay_need = payload_kib + int(((recovery_bytes || 0) + 1023) / 1024) + 256;
    // The downloaded package archives already occupy tmpfs. Package managers
    // unpack directly to flash; do not reserve another payload copy in RAM.
    let tmp_need = 8192;
    if (overlay_kib <= 0 || tmp_kib <= 0 || target_kib <= 0 || rollback_kib <= 0)
        return "Cannot determine storage required for Forkop package update and rollback";
    if (overlay_kib < overlay_need)
        return "Not enough flash space for Forkop update and rollback: need " + overlay_need + " KiB free, have " + overlay_kib + " KiB";
    if (tmp_kib < tmp_need)
        return "Not enough temporary memory for Forkop update and rollback: need " + tmp_need + " KiB free, have " + tmp_kib + " KiB";
    return "";
}

function forkop_package_preflight(backend_file, app_file, i18n_file, rollback_packages, version, xrust) {
    let target_bytes = xrust != null ? xrust.target.size : 0;
    for (let item in [ [ backend_file, "forkop" ], [ app_file, "luci-app-forkop" ],
        [ i18n_file, "luci-i18n-forkop-ru" ] ]) {
        if (item[0] == "") continue;
        let info = staged_package_info(item[0], item[1], forkop_package_version(version));
        if (info == null) return "Forkop release package is invalid or incompatible: " + item[1];
        target_bytes += info.size;
    }
    let rollback_bytes = 0;
    let recovery_bytes = file_bytes(forkop_configuration_backup || "/etc/config/forkop");
    for (let item in rollback_packages) {
        rollback_bytes += item.size;
        recovery_bytes += file_bytes(item.path);
    }
    let overlay_kib = available_kib("/usr/bin");
    let tmp_kib = temporary_available_kib();
    let error = forkop_package_space_error(overlay_kib, tmp_kib, target_bytes, rollback_bytes, recovery_bytes);
    if (error == "")
        updates_log("Forkop package preflight passed: flash " + overlay_kib + " KiB, tmp " +
            tmp_kib + " KiB, target " + int((target_bytes + 1023) / 1024) +
            " KiB, rollback " + int((rollback_bytes + 1023) / 1024) +
            " KiB, persistent recovery archives " + int((recovery_bytes + 1023) / 1024) + " KiB");
    return error;
}

function pkg_restore_file_command(path) {
    return (forkop_package_init != "" ? command_env({ FORKOP_INIT: forkop_package_init }) + " " : "") + (is_apk() ?
        command_from_args([ "apk", "--preserve-env", "add", "--no-network", "--allow-untrusted", "--force-reinstall", path ]) + " </dev/null" :
        command_from_args([ "opkg", "install", "--force-overwrite", "--force-reinstall", "--force-downgrade", path ]) + " </dev/null");
}

function forkop_package_init_adapter() {
    let path = tmp_dir + "/package-init";
    let source = fs.readfile("/usr/share/forkop/package-init");
    if (source == null)
        source = fs.readfile(getenv("FORKOP_PACKAGE_INIT_ADAPTER") || "");
    if (source == null || !write_file(path, source) ||
        !command_success_from_args([ "chmod", "700", path ]))
        return "";
    return path;
}

function restore_forkop_configuration_backup(backup, config_dir) {
    if (backup == "")
        return false;
    let temporary = trim(command_output_from_args([ "mktemp", config_dir + "/.forkop-restore.XXXXXX" ]));
    if (temporary == "")
        return false;
    if (!command_success(command_from_args([ "tar", "-xOzf", backup, "forkop" ]) +
            " >" + shell_quote(temporary)) ||
        !command_success_from_args([ "chmod", "600", temporary ]) ||
        !fs.rename(temporary, config_dir + "/forkop")) {
        remove_file(temporary);
        return false;
    }
    return true;
}

function xrust_runtime_is_stopped() {
    return trim(module_output([ LIB_DIR + "/service/state.uc", "sing-box-process-count" ])) == "0";
}

function stop_forkop_for_package_restore() {
    let script = forkop_package_init || SERVICE_INIT;
    command_success_from_args([ "env", "FORKOP_INTERNAL_SERVICE_STOP=1", script, "stop" ]);
    if (!wait_for_service_action_idle())
        return false;
    // Older init scripts can return an error after a successful asynchronous
    // stop. The adapter confirms that the dataplane is actually absent.
    return command_success_from_args([ "env", "FORKOP_INTERNAL_SERVICE_STOP=1", script, "stop" ]) &&
        xrust_runtime_is_stopped();
}

function remove_new_forkop_translation(staged) {
    let name = "luci-i18n-forkop-ru";
    for (let archive in staged)
        if (archive.name == name)
            return true;

    let installed = read_installed_package_version(name, forkop_package_version_reader);
    if (installed.state == "missing")
        return true;
    if (installed.state == "found" &&
        run_logged("Removing translation added by the failed upgrade",
            command_from_args(is_apk() ? [ "apk", "del", "--no-network", name ] : [ "opkg", "remove", name ]) + " </dev/null") &&
        read_installed_package_version(name, forkop_package_version_reader).state == "missing")
        return true;

    updates_log("Cannot restore the previous absence of " + name, "error");
    return false;
}

function restore_forkop_packages(staged) {
    let restored = remove_new_forkop_translation(staged);
    // Keep the backend last, just as in the normal opkg upgrade. Its postinst
    // owns service restoration after the matching LuCI files are back in place.
    if (is_apk()) {
        let args = [ "apk", "--preserve-env", "add", "--no-network", "--allow-untrusted", "--force-reinstall" ];
        for (let archive in staged)
            push(args, archive.path);
        if (!run_logged("Restoring previous Forkop package set",
            command_env({ FORKOP_INIT: forkop_package_init }) + " " + command_from_args(args) + " </dev/null"))
            restored = false;
    }
    else {
        for (let archive in staged) {
            if (!run_logged("Restoring previous " + archive.name + " package",
                pkg_restore_file_command(archive.path)))
                restored = false;
        }
    }
    for (let archive in staged) {
        let installed = read_installed_package_version(archive.name, forkop_package_version_reader);
        if (installed.state != "found" || installed.version != archive.version) {
            updates_log("Restored " + archive.name + " version mismatch: expected " + archive.version +
                ", got " + (installed.version || installed.error || installed.state), "error");
            restored = false;
        }
    }
    // Quiesce any runtime launched by package hooks, also on partial rollback.
    if (!stop_forkop_for_package_restore()) {
        updates_log("Cannot confirm stopped Forkop after restoring previous packages", "error");
        return false;
    }
    if (!restored)
        return false;
    for (let archive in staged) {
        if (archive.name != "rust-x")
            continue;
        if (installed_xrust_build() != replace(archive.version, /-r?[0-9]+$/, "")) {
            updates_log("Cannot restore the previous Xrust binary", "error");
            return false;
        }
    }
    if (!restore_forkop_configuration_backup(forkop_configuration_backup, "/etc/config")) {
        updates_log("Cannot reapply configuration after previous package hooks", "error");
        return false;
    }
    if (!command_success_from_args([ SERVICE_INIT, forkop_was_enabled ? "enable" : "disable" ])) {
        updates_log("Cannot restore Forkop enabled state", "error");
        return false;
    }
    if (forkop_was_running && !wait_for_forkop_restore()) {
        if (file_exists(SERVICE_INIT))
            command_success_from_args([ SERVICE_INIT, "start" ]);
        if (!wait_for_forkop_restore(true)) {
            updates_log("Forkop did not become ready after package rollback", "error");
            restored = false;
        }
    }
    return restored;
}

function fail_forkop_package_install(staged, failed_step, latest_version) {
    // Restore the pre-migration configuration before the old backend's postinst
    // validates it and tries to bring the service back.
    if (!stop_forkop_for_package_restore() ||
        !restore_forkop_configuration_backup(forkop_configuration_backup, "/etc/config")) {
        preserve_update_recovery_files = true;
        action_fail("forkop", "install", failed_step +
            "; cannot safely restore configuration, recovery packages retained in " + tmp_dir,
            FORKOP_VERSION, latest_version);
    }
    let restored = restore_forkop_packages(staged);
    preserve_update_recovery_files = !restored;
    action_fail("forkop", "install", failed_step + (restored ?
        "; previous configuration, packages and service restored" :
        "; rollback incomplete, recovery packages retained in " + tmp_dir),
        FORKOP_VERSION, latest_version);
}

function upgrade_bounded_stop(script) {
    let seconds = int(getenv("FORKOP_UPGRADE_STOP_TIMEOUT_SECONDS") || "60");
    if (seconds < 1)
        seconds = 60;
    let command = command_from_args([ "env", "FORKOP_INTERNAL_SERVICE_STOP=1", script, "stop" ]) + " >/dev/null 2>&1 & pid=$!; " +
        "( sleep " + seconds + "; kill $pid 2>/dev/null || true ) & watcher=$!; " +
        "wait $pid 2>/dev/null; rc=$?; kill $watcher 2>/dev/null || true; " +
        "wait $watcher 2>/dev/null || true; exit $rc";
    return command_status("sh -c " + shell_quote(command)) == 0;
}

function save_forkop_configuration_backup(config_dir, backup_dir) {
    if (!ensure_dir(backup_dir) ||
        !command_success_from_args([ "chmod", "700", backup_dir ]))
        return "";
    let backup = backup_dir + "/configuration.tar.gz";
    let temporary = trim(command_output_from_args([ "mktemp", backup_dir + "/.configuration.XXXXXX" ]));
    if (temporary == "")
        return "";
    // Keep the previous copy until the new archive is complete and valid.
    if (!command_success_from_args([ "tar", "-czf", temporary, "-C", config_dir, "forkop" ]) ||
        !command_success_from_args([ "tar", "-tzf", temporary ]) ||
        !command_success_from_args([ "chmod", "600", temporary ]) ||
        !fs.rename(temporary, backup)) {
        remove_file(temporary);
        return "";
    }
    // Only remove archives created by the previous timestamped-backup policy.
    for (let previous in fs.glob(backup_dir + "/before-*.tar.gz")) {
        let name = replace(previous, /^.*\//, "");
        if (match(name, /^before-[0-9]+[.][0-9]+[.][0-9]+(-canary[.][0-9]+)?-[0-9]+[.]tar[.]gz$/) != null &&
            !fs.unlink(previous))
            return "";
    }
    return backup;
}

// Packages the release files would newly pull from the feeds: dependencies
// that are new to this release (flock in 2.4.1, for example). A dry run lists
// them, nested ones included, without changing anything. null when the dry
// run fails, e.g. on a conflict that is only removed later in the upgrade.
function release_dependencies_to_preinstall(files) {
    let args = is_apk() ? [ "apk", "add", "--simulate", "--allow-untrusted" ] :
        [ "opkg", "install", "--noaction", "--force-overwrite", "--force-downgrade" ];
    for (let file in files)
        if (as_string(file) != "")
            push(args, file);
    if (!run_logged("Checking dependencies of the Forkop release", command_from_args(args) + " </dev/null"))
        return null;
    let names = [];
    for (let line in split(last_logged_output, "\n")) {
        // apk: "(1/2) Installing flock (2.40-r1)"; opkg: "Installing flock (2.40-1) to root..."
        let parsed = match(trim(line), /^(\([0-9]+\/[0-9]+\) )?Installing ([A-Za-z0-9][A-Za-z0-9._+-]*) \(/);
        if (parsed != null && !array_has([ "forkop", "luci-app-forkop", "luci-i18n-forkop-ru", "rust-x" ], parsed[2]) &&
            !array_has(names, parsed[2]))
            push(names, parsed[2]);
    }
    return names;
}

// Install them while Forkop still routes the router's own traffic: once it
// stops, the router can be offline until the new release starts, and a
// dependency download at that point fails the whole upgrade.
function preinstall_release_dependencies(files) {
    let names = release_dependencies_to_preinstall(files);
    if (names == null) {
        updates_log("New Forkop dependencies could not be listed in advance; the package manager installs them during the upgrade", "warn");
        return true;
    }
    for (let name in names)
        if (!run_logged("Installing new Forkop dependency " + name + " before stopping Forkop", pkg_install_name_command(name)))
            return false;
    return true;
}

function prepare_forkop_runtime_for_package_upgrade(latest_version) {
    upgrade_bounded_stop(SERVICE_INIT);
    if (!upgrade_bounded_stop(forkop_package_init) || !xrust_runtime_is_stopped()) {
        if (forkop_was_running && !forkop_status_running_with_timeout() &&
            (!command_success_from_args([ SERVICE_INIT, "start" ]) || !wait_for_forkop_restore(true))) {
            preserve_update_recovery_files = true;
            action_fail("forkop", "install", "Forkop did not recover after stopping it; recovery packages retained in " +
                tmp_dir, FORKOP_VERSION, latest_version);
        }
        action_fail("forkop", "install", "Cannot safely stop Forkop before package installation",
            FORKOP_VERSION, latest_version);
    }
}

function begin_forkop_upgrade_recovery(staged, core_version) {
    let plan = tmp_dir + "/recovery-packages.tsv";
    let rows = map(staged, item => join("\t", [ item.name, item.version, item.path ]));
    upgrade_recovery_owned = write_file(plan, join("\n", rows) + "\n") &&
        run_logged("Preserving the exact rollback set across reboot", command_from_args([
            UPGRADE_RECOVERY_SCRIPT, "prepare", is_apk() ? "apk" : "opkg",
            forkop_was_enabled ? "1" : "0", core_version,
            forkop_configuration_backup, forkop_package_init, plan
        ]));
    return upgrade_recovery_owned;
}

function install_forkop(requested_version) {
    requested_version = as_string(requested_version);
    let selected = requested_version != "" ? selected_forkop_release(requested_version) :
        parse_json_object(latest_forkop_release_json());
    if (requested_version != "" && selected == null)
        action_fail("forkop", "install", "Selected release is unavailable or incompatible", FORKOP_VERSION, requested_version);
    let latest_version = as_string(selected?.tag_name);
    if (latest_version == "")
        action_fail("forkop", "install", "Failed to resolve Forkop release", FORKOP_VERSION, "unknown");
    if (fs.lstat(UPGRADE_RECOVERY_HOOK) != null)
        action_fail("forkop", "install", "An interrupted update has recovery packages ready for the next boot.",
            FORKOP_VERSION, latest_version);
    let current_xrust = check_forkop_xrust_requirement(latest_version);

    if (requested_version == "") write_forkop_latest_version_cache(latest_version, now_seconds());
    init_tmp_dir() || action_fail("forkop", "install", "Failed to create temporary directory", FORKOP_VERSION, latest_version);
    let package_init = forkop_package_init_adapter();
    if (package_init == "")
        action_fail("forkop", "install", "Failed to prepare package lifecycle adapter", FORKOP_VERSION, latest_version);
    // package.uc supports FORKOP_INIT in older releases as well.
    forkop_package_init = package_init;
    updates_log("Resolving Forkop release " + latest_version + " packages");
    let release = resolve_forkop_release(latest_version, selected);
    if (release == null)
        action_fail("forkop", "install", "Failed to resolve Forkop release packages", FORKOP_VERSION, latest_version);

    let backend_file = tmp_dir + "/" + release.backend_name;
    let app_file = tmp_dir + "/" + release.app_name;
    let i18n_file = release.i18n_url != "" ? tmp_dir + "/" + release.i18n_name : "";
    if (!download_with_retry(release.backend_url, backend_file, release.backend_name) ||
        !download_with_retry(release.app_url, app_file, release.app_name) ||
        (release.i18n_url != "" && !download_with_retry(release.i18n_url, i18n_file, release.i18n_name)))
        action_fail("forkop", "install", "Failed to download Forkop release packages", FORKOP_VERSION, latest_version);

    {
        for (let file in [ backend_file, app_file, i18n_file ]) {
            if (file == "") continue;
            let name = replace(file, /^.*\//, "");
            let expected = "";
            for (let asset in release.assets)
                if (asset.name == name) expected = asset.sha256;
            let actual = split(trim(command_output_from_args([ "sha256sum", file ])), /[ \t]+/)[0];
            if (expected == "" || actual != expected)
                action_fail("forkop", "install", "Release package checksum mismatch", FORKOP_VERSION, latest_version);
        }
    }

    // New release dependencies must be resolvable before stopping Forkop or
    // installing any release package, including when opkg lists are empty.
    if (!ensure_repository_indexes())
        action_fail("forkop", "install", "Failed to update package lists", FORKOP_VERSION, latest_version);

    // Changing the backend also replaces the reader. Keep these checks usable
    // with older packages that predate the installed-version query.
    forkop_package_version_reader = tmp_dir + "/package-versions.uc";
    if (!command_success_from_args([ "cp", LIB_DIR + "/core/packages.uc", forkop_package_version_reader ]))
        action_fail("forkop", "install", "Failed to preserve the installed package version reader", FORKOP_VERSION, latest_version);
    let rollback_packages = stage_forkop_rollback_packages();
    if (rollback_packages == null)
        action_fail("forkop", "install", "Cannot cache the exact installed Forkop packages for rollback", FORKOP_VERSION, latest_version);
    let xrust = stage_forkop_xrust(release, current_xrust, latest_version);
    if (xrust != null)
        unshift(rollback_packages, xrust.rollback);
    let preflight_error = forkop_package_preflight(backend_file, app_file, i18n_file, rollback_packages, latest_version, xrust);
    if (preflight_error != "")
        action_fail("forkop", "install", preflight_error, FORKOP_VERSION, latest_version);
    if (!preinstall_release_dependencies([ backend_file, app_file, i18n_file, xrust?.target.path || "" ]))
        action_fail("forkop", "install", "Failed to install new dependencies of the Forkop release", FORKOP_VERSION, latest_version);

    if (!module_success([ LIB_DIR + "/service/ui.uc", "begin-package-upgrade-quiesce", owner_pid() ]))
        action_fail("forkop", "install", "Another Forkop service transition or package upgrade is starting", FORKOP_VERSION, latest_version);
    if (!wait_for_service_action_idle())
        action_fail("forkop", "install", "Timed out waiting for the current Forkop service action before upgrade", FORKOP_VERSION, latest_version);
    capture_forkop_running_state();
    forkop_was_enabled = command_success_from_args([ SERVICE_INIT, "enabled" ]);
    forkop_configuration_backup = save_forkop_configuration_backup("/etc/config", "/etc/forkop-backups");
    if (forkop_configuration_backup == "")
        action_fail("forkop", "install", "Failed to back up Forkop configuration", FORKOP_VERSION, latest_version);
    updates_log("Forkop configuration backup: " + forkop_configuration_backup);

    preflight_error = forkop_package_preflight(backend_file, app_file, i18n_file, rollback_packages, latest_version, xrust);
    if (preflight_error != "")
        action_fail("forkop", "install", preflight_error, FORKOP_VERSION, latest_version);
    if (!write_file(tmp_dir + "/.forkop-recovery", "transition\n") ||
        !begin_forkop_upgrade_recovery(rollback_packages, current_xrust))
        action_fail("forkop", "install", "Cannot protect packages needed for rollback after reboot", FORKOP_VERSION, latest_version);
    prepare_forkop_runtime_for_package_upgrade(latest_version);

    if (xrust != null) {
        if (!run_logged("Installing pinned Xrust " + xrust.target.version, pkg_restore_file_command(xrust.target.path)))
            fail_forkop_package_install(rollback_packages, "Failed to install pinned Xrust", latest_version);
        let mismatch = forkop_installed_version_mismatch(xrust.target.version, [ "rust-x" ], forkop_package_version_reader);
        if (mismatch != "" || installed_xrust_build(xrust.legacy) != xrust.pin)
            fail_forkop_package_install(rollback_packages,
                mismatch || "Installed Xrust does not match the Forkop release", latest_version);
    }

    // apk refreshes repository indexes for every `add` invocation. Install the
    // release files in one transaction on APK systems to retain dependency
    // resolution while avoiding two redundant index refreshes. Keep opkg's
    // established ordering unchanged.
    if (is_apk()) {
        let files = [ app_file ];
        if (i18n_file != "")
            push(files, i18n_file);
        push(files, backend_file);
        if (!run_logged("Installing Forkop release packages", pkg_install_files_command(files)))
            fail_forkop_package_install(rollback_packages, "Failed to install Forkop release packages", latest_version);
    }
    else {
        if (!run_logged("Installing LuCI app package " + release.app_name, pkg_install_files_command([ app_file ])))
            fail_forkop_package_install(rollback_packages, "Failed to install LuCI app package", latest_version);
        if (i18n_file != "" && !run_logged("Installing LuCI Russian i18n package " + release.i18n_name, pkg_install_files_command([ i18n_file ])))
            fail_forkop_package_install(rollback_packages, "Failed to install LuCI Russian i18n package", latest_version);
        if (!run_logged("Installing Forkop package " + release.backend_name, pkg_install_files_command([ backend_file ])))
            fail_forkop_package_install(rollback_packages, "Failed to install Forkop package", latest_version);
    }

    let expected_package_version = forkop_package_version(latest_version);
    let installed_names = [ "forkop", "luci-app-forkop" ];
    if (i18n_file != "")
        push(installed_names, "luci-i18n-forkop-ru");
    let version_mismatch = forkop_installed_version_mismatch(expected_package_version, installed_names, forkop_package_version_reader);
    if (version_mismatch != "")
        fail_forkop_package_install(rollback_packages, version_mismatch, latest_version);

    remove_file("/var/luci-indexcache");
    command_success("rm -f /var/luci-indexcache* /tmp/luci-indexcache* 2>/dev/null");
    command_success("rm -rf /tmp/luci-modulecache/ 2>/dev/null");
    if (file_exists("/etc/init.d/rpcd") && !command_success_from_args([ "/etc/init.d/rpcd", "reload" ]))
        command_success_from_args([ "/etc/init.d/rpcd", "restart" ]);
    command_success_from_args([ "killall", "-HUP", "rpcd" ]);

    // The updater stops Forkop before apk/opkg runs prerm. The package hook
    // therefore sees a stopped service and normally has nothing to restore.
    // Start it directly instead of restarting a service that procd no longer
    // has registered.
    if (!command_success_from_args([ SERVICE_INIT, forkop_was_enabled ? "enable" : "disable" ]) ||
        (!forkop_was_running && !stop_forkop_for_package_restore()))
        fail_forkop_package_install(rollback_packages, "Failed to restore Forkop service state", latest_version);
    if (forkop_was_running && wait_for_forkop_restore())
        updates_log("Forkop was restored by the package upgrade; final restart skipped");
    else {
        if (forkop_was_running &&
            (!run_logged("Starting Forkop after installing release packages",
                command_from_args([ SERVICE_INIT, "start" ])) ||
             !wait_for_forkop_restore(true)))
            fail_forkop_package_install(rollback_packages, "Forkop did not recover after installing release packages", latest_version);
    }
    if (!command_success_from_args([ UPGRADE_RECOVERY_HOOK, "commit" ])) {
        preserve_update_recovery_files = true;
        action_fail("forkop", "install", "The release was installed but its recovery journal could not be cleared",
            FORKOP_VERSION, latest_version);
    }
    upgrade_recovery_owned = false;
    clear_version_caches();
    let new_version = installed_package_version("forkop");
    if (new_version == "")
        new_version = latest_version;
    updates_log("Forkop updated to " + new_version);
    action_success("forkop", "install", "Forkop has been installed", new_version, latest_version, 1, "latest", release.release_url);
}

function set_packet_steering(action) {
    let init_script = "/etc/init.d/packet_steering";
    let config_path = "network.@globals[0].packet_steering";
    let current_mode = trim(uci_core.get(config_path));
    let target_mode = action == "enable" ? "2" : "1";

    if (!file_exists(init_script))
        action_fail("packet_steering", action, "Packet Steering service is not available", current_mode, target_mode);
    if (!uci_core.available() ||
        !uci_core.set(config_path, target_mode) ||
        !uci_core.commit("network") ||
        !command_success_from_args([ init_script, "restart" ]))
        action_fail("packet_steering", action, "Failed to apply Packet Steering mode " + target_mode, current_mode, target_mode);

    remove_file(SYSTEM_INFO_CACHE_FILE);
    action_success("packet_steering", action,
        target_mode == "2" ? "Packet Steering mode 2 has been enabled" : "Packet Steering normal mode has been restored",
        target_mode, target_mode, current_mode == target_mode ? 0 : 1, "", "");
}

function set_direct_proxy(action) {
    let enabled_path = CONFIG_NAME + ".settings.direct_proxy_enabled";
    let port_path = CONFIG_NAME + ".settings.direct_proxy_port";
    let current_enabled = trim(uci_core.get(enabled_path)) == "1" ? "1" : "0";
    let target_enabled = action == "enable" ? "1" : "0";
    let current_port = trim(uci_core.get(port_path));
    let current_port_number = match(current_port, /^[0-9]+$/) != null ? int(current_port, 10) : 0;
    let target_port = current_port_number >= 1 && current_port_number <= 65535 ? current_port : "2080";

    if (!file_exists(SERVICE_INIT))
        action_fail("direct_proxy", action, "Forkop service is not available", current_enabled, target_enabled);
    if (target_enabled == "1" && current_enabled != "1") {
        let listen = trim(module_output([ LIB_DIR + "/xrust/runtime.uc", "service-listen-address" ]));
        if (listen == "")
            action_fail("direct_proxy", action, "Failed to determine the Direct Proxy LAN address", current_enabled, target_enabled);
        if (!command_exists("netstat"))
            action_fail("direct_proxy", action, "Failed to verify whether Direct Proxy port " + target_port + " is available", current_enabled, target_enabled);
        let listeners = command_output_from_args([ "netstat", "-ln" ]);
        if (listeners == "")
            action_fail("direct_proxy", action, "Failed to verify whether Direct Proxy port " + target_port + " is available", current_enabled, target_enabled);
        if (netstat.listen_port_in_use(listeners, listen, target_port))
            action_fail("direct_proxy", action, "Direct Proxy port " + target_port + " is already in use", current_enabled, target_enabled);
    }
    if (!uci_core.available() ||
        !uci_core.set(enabled_path, target_enabled) ||
        !uci_core.set(port_path, target_port) ||
        !uci_core.commit(CONFIG_NAME))
        action_fail("direct_proxy", action, "Failed to save Direct Proxy settings", current_enabled, target_enabled);

    // Direct Proxy changes only the Xrust configuration. Use the normal
    // serialized reload instead of stopping every Forkop component.
    if (!command_success_from_args([ SERVICE_INIT, "reload" ])) {
        uci_core.set(enabled_path, current_enabled);
        if (current_port != "")
            uci_core.set(port_path, current_port);
        else
            uci_core.delete(port_path);
        uci_core.commit(CONFIG_NAME);
        command_success_from_args([ SERVICE_INIT, "reload" ]);
        action_fail("direct_proxy", action, "Failed to apply Direct Proxy settings", current_enabled, target_enabled);
    }

    remove_file(SYSTEM_INFO_CACHE_FILE);
    action_success("direct_proxy", action,
        target_enabled == "1" ? "Direct Proxy has been enabled" : "Direct Proxy has been disabled",
        target_enabled, target_enabled, current_enabled == target_enabled ? 0 : 1, "", "");
}

function set_torrserver_direct(action) {
    let enabled_path = CONFIG_NAME + ".settings.torrserver_direct_enabled";
    let current_enabled = trim(uci_core.get(enabled_path)) == "1" ? "1" : "0";
    let target_enabled = action == "enable" ? "1" : "0";

    if (!file_exists(TORRSERVER_DIRECT_INIT) || !file_exists(TORRSERVER_DIRECT_UC))
        action_fail("torrserver_direct", action, "TorrServer Direct service is not available", current_enabled, target_enabled);
    if (target_enabled == "1") {
        if (!command_success_from_args([ "modprobe", "nft_socket" ]) &&
            (!run_logged("Installing TorrServer Direct kernel support", pkg_install_name_command("kmod-nft-socket")) ||
             !command_success_from_args([ "modprobe", "nft_socket" ])))
            action_fail("torrserver_direct", action, "This firmware does not provide kmod-nft-socket required for TorrServer Direct", current_enabled, target_enabled);
        let status = parse_json_object(module_output([ TORRSERVER_DIRECT_UC, "status" ]));
        if (type(status) != "object" || int(status.running || 0) != 1)
            action_fail("torrserver_direct", action, "TorrServer is not running", current_enabled, target_enabled);
        if (int(status.available || 0) != 1)
            action_fail("torrserver_direct", action, "TorrServer does not have a dedicated cgroup", current_enabled, target_enabled);
    }
    if (!uci_core.available() || !uci_core.set(enabled_path, target_enabled) || !uci_core.commit(CONFIG_NAME))
        action_fail("torrserver_direct", action, "Failed to save TorrServer Direct settings", current_enabled, target_enabled);

    let applied = target_enabled == "1"
        ? command_success_from_args([ TORRSERVER_DIRECT_INIT, "enable" ]) &&
            command_success_from_args([ TORRSERVER_DIRECT_INIT, "restart" ]) &&
            module_success([ TORRSERVER_DIRECT_UC, "reconcile" ])
        : command_success_from_args([ TORRSERVER_DIRECT_INIT, "stop" ]) &&
            command_success_from_args([ TORRSERVER_DIRECT_INIT, "disable" ]);
    if (!applied) {
        uci_core.set(enabled_path, current_enabled);
        uci_core.commit(CONFIG_NAME);
        action_fail("torrserver_direct", action, "Failed to apply TorrServer Direct settings", current_enabled, target_enabled);
    }
    remove_file(SYSTEM_INFO_CACHE_FILE);
    action_success("torrserver_direct", action,
        target_enabled == "1" ? "TorrServer Direct has been enabled" : "TorrServer Direct has been disabled",
        target_enabled, target_enabled, current_enabled == target_enabled ? 0 : 1, "", "");
}

function component_action(component, action, version) {
    component = as_string(component);
    action = as_string(action);
    if (!acquire_component_lock()) {
        // Scheduled maintenance waits for the owning transaction. A busy lock
        // is expected here and must not publish an error or run failure cleanup.
        if (getenv("FORKOP_COMPONENT_BACKGROUND") == "1")
            exit(75);
        action_fail(component != "" ? component : "unknown", action != "" ? action : "unknown", "Another component action is already running");
    }
    if (!init_tmp_dir())
        action_fail(component != "" ? component : "unknown", action != "" ? action : "unknown", "Failed to create temporary directory");
    capture_forkop_running_state();

    if (component == "forkop" && action == "check_update")
        check_forkop();
    else if (component == "forkop" && (action == "install" ||
             (action == "install_pinned_xrust" && forkop_release_requires_xrust(version))))
        install_forkop(version);
    else if (component == "zapret_manager" && (action == "install" || action == "migrate"))
        install_zapret_manager(action);
    else if (component == "zapret_manager" && action == "remove")
        remove_zapret_manager(action);
    else if (component == "packet_steering" && (action == "enable" || action == "restore"))
        set_packet_steering(action);
    else if (component == "direct_proxy" && (action == "enable" || action == "disable"))
        set_direct_proxy(action);
    else if (component == "torrserver_direct" && (action == "enable" || action == "disable"))
        set_torrserver_direct(action);
    else
        action_fail(component != "" ? component : "unknown", action != "" ? action : "unknown", "Unknown component action");
}

let mode = ARGV[0] || "";

if (mode == "component-action")
    component_action(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "github-json-fixture") {
    print(fetch_github_json("https://api.github.com/repos/fixture/fixture/releases"));
    cleanup_tmp_dir();
}
else if (mode == "latest-forkop-version")
    print(latest_forkop_version(), "\n");
else if (mode == "forkop-release-metadata")
    print(fetch_forkop_latest_release_metadata(), "\n");
else if (mode == "forkop-backup-fixture") {
    let backup = save_forkop_configuration_backup(ARGV[1], ARGV[2]);
    if (backup == "") exit(1);
    print(backup, "\n");
}
else if (mode == "forkop-restore-backup-fixture")
    exit(restore_forkop_configuration_backup(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "forkop-release-catalog-fixture") {
    let input = fs.open("/dev/stdin", "r");
    let data = input ? input.read("all") : "";
    if (input) input.close();
    write_json(parse_forkop_release_catalog(data, ARGV[1]));
}
else if (mode == "runtime-cache-path-fixture")
    print(configured_runtime_cache(), "\n");
else if (mode == "forkop-package-version-fixture")
    write_json({ package_version: forkop_package_version(ARGV[1]), release_version: forkop_release_version(ARGV[2]) });
else if (mode == "forkop-package-space-fixture") {
    let error = forkop_package_space_error(int(ARGV[1]), int(ARGV[2]), int(ARGV[3]), int(ARGV[4]));
    if (error != "") {
        warn(error, "\n");
        exit(1);
    }
    print("ok\n");
}
else if (mode == "forkop-releases")
    forkop_releases();
else if (mode == "forkop-resolve-release-fixture") {
    let input = fs.open("/dev/stdin", "r");
    let release = resolve_forkop_release(ARGV[1], json(input.read("all")));
    input.close();
    if (release == null)
        exit(1);
    write_json(release);
}
else if (mode == "forkop-release-plan-fixture") {
    let input = fs.open("/dev/stdin", "r");
    let fixture_input = input ? input.read("all") : "";
    if (input)
        input.close();
    let plan = ARGV[4] == "tsv" ? fixture_input : helper_output_input(fixture_input, "forkop-release-plan", [ ARGV[1], ARGV[2], ARGV[3] ]);
    let release = parse_forkop_release_plan(plan, ARGV[1], ARGV[3]);
    if (release == null)
        exit(1);
    write_json(release);
}
else if (mode == "temporary-capacity-fixture")
    print(temporary_capacity_kib(int(ARGV[1]), int(ARGV[2])), "\n");
else if (mode == "download-limit-fixture") {
    if (!bounded_download(command_from_args([ "dd", "if=/dev/zero", "of=" + ARGV[2], "bs=1024", "count=4" ]), int(ARGV[1]))) exit(1);
}
else if (mode == "package-info-fixture") {
    let info = staged_package_info(ARGV[1], ARGV[2], ARGV[3]);
    if (info == null)
        exit(1);
    write_json(info);
}
else if (mode == "repository-package-stage-fixture") {
    init_tmp_dir();
    let info = stage_repository_package(ARGV[1], ARGV[2]);
    if (info == null) {
        cleanup_tmp_dir();
        exit(1);
    }
    write_json(info);
}
else {
    warn("Usage: components/action.uc <component-action|latest-forkop-version|forkop-release-metadata> ...\n");
    exit(1);
}
