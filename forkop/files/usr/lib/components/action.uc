#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");
let uci_core = require("core.uci");
let netstat = require("core.netstat");
let github_http = require("core.github_http");
let storage_cleanup = require("components.storage_cleanup");

const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || constants.FORKOP_CONFIG_NAME || "forkop";
const BIN_PATH = getenv("FORKOP_BIN") || constants.FORKOP_BIN || "/usr/bin/forkop";
const SERVICE_INIT = getenv("FORKOP_SERVICE_INIT") || constants.FORKOP_SERVICE_INIT || "/etc/init.d/forkop";
const FORKOP_VERSION = getenv("FORKOP_VERSION") || constants.FORKOP_VERSION || "";
const FORKOP_RELEASE_REPO = getenv("FORKOP_RELEASE_REPO") || constants.FORKOP_RELEASE_REPO || "Screamshow/forkop-x";
const FORKOP_MIRROR_BASE_URL = getenv("FORKOP_MIRROR_BASE_URL") || constants.FORKOP_MIRROR_BASE_URL || "";
const RUNTIME_STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const START_FAILURE_FILE = getenv("FORKOP_START_FAILURE_FILE") || RUNTIME_STATE_DIR + "/start.failure";
const GITHUB_BACKOFF_FILE = RUNTIME_STATE_DIR + "/github-api-backoff.json";
const MANAGED_UPGRADE_SING_BOX_MARKER = getenv("FORKOP_MANAGED_UPGRADE_SING_BOX_MARKER") || "/tmp/forkop-managed-upgrade-sing-box";
const PACKAGE_UPGRADE_STATE = getenv("FORKOP_PACKAGE_UPGRADE_STATE") || "/tmp/forkop-package-was-running";
const FORKOP_UPGRADE_IDLE_WAIT_SECONDS = int(getenv("FORKOP_UPGRADE_IDLE_WAIT_SECONDS") || "180");
const COMPRESSED_UPGRADE_BACKUP = "/tmp/forkop-compressed-upgrade";
const SYSTEM_INFO_CACHE_FILE = getenv("FORKOP_SYSTEM_INFO_CACHE_FILE") || RUNTIME_STATE_DIR + "/system-info.json";
const COMPONENT_LOCK_DIR = getenv("UPDATES_LOCK_DIR") || RUNTIME_STATE_DIR + "/component-action.lock";
const TMP_STALE_TTL_MINUTES = getenv("UPDATES_TMP_STALE_TTL_MINUTES") || "30";
const TMP_FILE_STALE_TTL_MINUTES = getenv("UPDATES_TMP_FILE_STALE_TTL_MINUTES") || "10";
const SB_MANAGED_SERVICE_MARKER = getenv("SB_MANAGED_SERVICE_MARKER") || constants.SB_MANAGED_SERVICE_MARKER || "Forkop managed sing-box service for binary variants";
const TORRSERVER_DIRECT_INIT = getenv("FORKOP_TORRSERVER_DIRECT_INIT") || "/etc/init.d/forkop-torrserver-direct";
const TORRSERVER_DIRECT_UC = LIB_DIR + "/torrserver/direct.uc";

let tmp_dir = "";
let repository_indexes_ready = false;
let lock_held = false;
let forkop_was_running = false;
let forkop_was_enabled = false;
let forkop_stopped_for_sing_box_change = false;
let last_logged_output = "";
let sing_box_target_dependency_files = [];
let sing_box_rollback_dependency_files = [];
let extended_package_file_backups = [];
let sing_box_flash_after_remove_bytes = 0;
let forkop_configuration_backup = "";
let preserve_update_recovery_files = false;
let forkop_package_init = "";
let stage_archived_sing_box_package;
let wait_forkop_running_after_sing_box_change;
// Repository staging is declared before the download helpers. ucode needs a
// shared binding here instead of capturing an uninitialised function value.
let limited_download_command;

function as_string(value) {
    return value == null ? "" : "" + value;
}

function configured_runtime_cache() {
    let config_path = as_string(uci_core.get(CONFIG_NAME + ".settings.config_path") || "/etc/sing-box/config.json");
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

function path_basename(path) {
    let parts = split(as_string(path), "/");
    return length(parts) > 0 ? as_string(parts[length(parts) - 1]) : "";
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

function restart_forkop_after_failed_sing_box_change() {
    if (!forkop_stopped_for_sing_box_change || !forkop_was_running || !file_exists(SERVICE_INIT))
        return;
    updates_log("Restarting Forkop after failed sing-box component change");
    if (!command_success_from_args([ SERVICE_INIT, "start" ]))
        command_success_from_args([ SERVICE_INIT, "restart" ]);
    if (!wait_forkop_running_after_sing_box_change())
        updates_log("Previous sing-box runtime did not recover cleanly after failed component change", "error");
}

function action_success(component, action, message, current_version, latest_version, changed, status, release_url) {
    // Family-specific FakeIP stores belong to that core, including after a
    // successful switch. Keep them available for a later return or rollback.
    updates_response(true, component, action, message, current_version, latest_version, changed || 0, status || "", release_url || "");
    cleanup_action();
    exit(0);
}

function action_fail(component, action, message, current_version, latest_version, status, release_url) {
    updates_log(message, "error");
    restart_forkop_after_failed_sing_box_change();
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

function opkg_package_version_from_list(package_name, output) {
    return trim(helper_output_input(output, "updates-opkg-package-version", [ package_name ]));
}

function available_package_version(package_name) {
    package_name = as_string(package_name);
    if (is_apk())
        return trim(module_output([ LIB_DIR + "/core/packages.uc", "apk-available-version", package_name ]));
    return opkg_package_version_from_list(package_name, command_output_from_args([ "opkg", "list", package_name ]));
}

function pkg_list_update_command() {
    return is_apk() ? "apk update </dev/null" : "opkg update </dev/null";
}

function ensure_repository_indexes() {
    if (repository_indexes_ready)
        return true;
    repository_indexes_ready = run_logged("Updating package lists before sing-box package change", pkg_list_update_command());
    return repository_indexes_ready;
}

function pkg_install_name_command(package_name) {
    return is_apk() ? command_from_args([ "apk", "add", package_name ]) + " </dev/null" :
        command_from_args([ "opkg", "install", package_name ]) + " </dev/null";
}

function pkg_install_name_downgrade(package_name, package_version) {
    package_name = as_string(package_name);
    if (is_apk()) {
        package_version = as_string(package_version);
        if (package_version == "")
            return false;
        let package_spec = package_name + "=" + package_version;
        if (pkg_is_installed(package_name))
            return command_success(command_from_args([ "apk", "add", "--force-reinstall", "--upgrade", package_spec ]) + " </dev/null");
        return command_success(command_from_args([ "apk", "add", package_spec ]) + " </dev/null");
    }

    return command_success(command_from_args([ "opkg", "install", "--force-overwrite", "--force-reinstall", "--force-downgrade", package_name ]) + " </dev/null") ||
        command_success(command_from_args([ "opkg", "install", "--force-downgrade", package_name ]) + " </dev/null");
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

function pkg_install_sing_box_files_command(files) {
    if (!is_apk()) {
        let args = [ "opkg", "install", "--force-overwrite", "--force-reinstall", "--force-downgrade" ];
        for (let file in files)
            push(args, file);
        return command_from_args(args) + " </dev/null";
    }
    let args = [ "apk", "add", "--force-reinstall", "--no-network", "--allow-untrusted" ];
    for (let file in files)
        push(args, file);
    return command_from_args(args) + " </dev/null";
}

// Keep the exact packages needed for both sides of a variant change in tmpfs.
// A binary alone is not a package-manager rollback.
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
        field == "arch" ? "Architecture" : field == "depends" ? "Depends" : "Installed-Size") + ": ";
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

function sing_box_archive_asset(catalog, package_name, version, arch, format) {
    for (let asset in catalog?.packages || []) {
        if (asset.package != package_name || asset.version != version ||
            asset.arch != arch || asset.format != format)
            continue;
        if (match(as_string(asset.sha256), /^[a-f0-9]{64}$/) == null ||
            match(as_string(asset.filename), /^[A-Za-z0-9_.+~-]+[.](ipk|apk)$/) == null ||
            asset.url != "/forkop/sing-box-archive/blobs/" + asset.sha256 + "/" + asset.filename)
            return null;
        return asset;
    }
    return null;
}

function package_sha256(path) {
    return split(trim(command_output_from_args([ "sha256sum", path ])), /[ \t]+/)[0];
}

function stage_repository_package(package_name, expected_version) {
    let retain = index([ "sing-box", "sing-box-tiny" ], package_name) != -1;
    if (retain && as_string(expected_version) != "") {
        let previous = stage_archived_sing_box_package(package_name, expected_version);
        if (previous != null) return previous;
    }
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
        shell_quote(is_apk() ? package_name + "-*." + ext : package_name + "_*." + ext));
    for (let path in split(matches, "\n")) {
        let info = staged_package_info(trim(path), package_name, expected_version);
        if (info != null) {
            return info;
        }
    }
    return null;
}

function apk_archive_dependencies(path) {
    let dependencies = [];
    let metadata = command_output_from_args([ "apk", "--allow-untrusted", "adbdump", path ]);
    let inside = false;
    for (let line in split(metadata, "\n")) {
        if (match(line, /^  [a-z][a-z-]*:/) != null)
            inside = match(line, /^  depends:/) != null;
        else if (inside && match(line, /^    - /) != null) {
            let name = trim(replace(replace(substr(line, 6), /['"]/g, ""), /[<>=~].*$/, ""));
            // APK expresses conflicts as negative dependencies, not packages to fetch.
            if (name != "" && substr(name, 0, 1) != "!")
                push(dependencies, name);
        }
    }
    return dependencies;
}

function apk_packages_removed_with(package_name) {
    if (!is_apk() || as_string(package_name) == "" || !pkg_is_installed(package_name))
        return [];
    if (!run_logged("Checking packages removed with " + package_name,
        command_from_args([ "apk", "del", "--simulate", package_name ])))
        return null;
    let removed = [];
    for (let line in split(last_logged_output, "\n")) {
        let fields = split(trim(line), " ");
        if (length(fields) > 2 && fields[1] == "Purging")
            push(removed, fields[2]);
    }
    return removed;
}

function array_has(values, item) {
    for (let value in values)
        if (value == item)
            return true;
    return false;
}

function staged_package_by_name(values, name) {
    for (let item in values)
        if (item.name == name)
            return item;
    return null;
}

function stage_apk_dependency_tree(info, removed, staged) {
    if (length(staged) > 32)
        return false;
    let dependencies = is_apk() ? apk_archive_dependencies(info.path) :
        split(replace(staged_package_field(info.path, "depends"), /\s*\([^)]*\)/g, ""), /\s*,\s*/);
    for (let dependency in dependencies) {
        dependency = trim(dependency);
        if (dependency == "") continue;
        if (!array_has(removed, dependency) && pkg_is_installed(dependency))
            continue;
        if (staged_package_by_name(staged, dependency) != null)
            continue;
        let expected = pkg_is_installed(dependency) ? installed_package_version(dependency) : "";
        let package = stage_repository_package(dependency, expected);
        if (package == null)
            return false;
        push(staged, package);
        if (!stage_apk_dependency_tree(package, removed, staged))
            return false;
    }
    return true;
}

function prepare_sing_box_package_dependencies(target, rollback, previous_variant) {
    sing_box_target_dependency_files = [];
    sing_box_rollback_dependency_files = [];
    let previous_package = previous_variant == "rust-x" ? "rust-x" : previous_variant == "x" ? "sing-box-x" : previous_variant == "tiny" ? "sing-box-tiny" :
        previous_variant == "stable" ? "sing-box" :
        previous_variant == "extended" ? "sing-box-extended" : "";
    let removed = apk_packages_removed_with(previous_package);
    if (removed == null)
        return false;
    let target_dependencies = [];
    if (target != null && !stage_apk_dependency_tree(target, removed, target_dependencies))
        return false;
    for (let item in target_dependencies)
        push(sing_box_target_dependency_files, item.path);
    if (rollback != null) {
        let rollback_dependencies = [];
        if (!stage_apk_dependency_tree(rollback, removed, rollback_dependencies))
            return false;
        // apk del may garbage-collect dependencies beyond this package's
        // direct dependency tree. Cache their exact installed revisions too.
        for (let name in removed) {
            if (name == previous_package || staged_package_by_name(rollback_dependencies, name) != null)
                continue;
            let item = stage_repository_package(name, installed_package_version(name));
            if (item == null) return false;
            push(rollback_dependencies, item);
        }
        for (let item in rollback_dependencies)
            push(sing_box_rollback_dependency_files, item.path);
    }
    return true;
}

function sing_box_target_files(target_path) {
    let files = [];
    for (let path in sing_box_target_dependency_files)
        push(files, path);
    push(files, target_path);
    return files;
}

function sing_box_rollback_files(rollback_path) {
    let files = [];
    for (let path in sing_box_rollback_dependency_files)
        push(files, path);
    push(files, rollback_path);
    return files;
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

function sing_box_flash_need_kib(write_bytes) {
    // Payload is measured from the package, including the still packed UPX
    // executable. Leave only a small allowance for package metadata.
    return write_bytes > 0 ? int((write_bytes + 1023) / 1024) + 256 : 0;
}

function sing_box_space_error(overlay_kib, tmp_kib, write_bytes, tmp_backup_bytes) {
    let overlay_need = sing_box_flash_need_kib(write_bytes);
    let tmp_need = int((tmp_backup_bytes + 1023) / 1024) + 8192;
    if (overlay_kib < 0 || tmp_kib <= 0 || write_bytes < 0)
        return "Cannot determine storage required for sing-box package change";
    if (overlay_kib < overlay_need)
        return "Not enough flash space for sing-box: need " + overlay_need + " KiB free, have " + overlay_kib + " KiB";
    if (tmp_kib < tmp_need)
        return "Not enough temporary memory for sing-box: need " + tmp_need + " KiB free, have " + tmp_kib + " KiB";
    return "";
}

function sing_box_writable_path(path, has_upper, has_rom) {
    return has_upper ? "/overlay/upper" + path : has_rom ? "" : path;
}

function sing_box_writable_file_bytes(path) {
    // Removing a symlink or one of several hardlinks cannot release the
    // executable's storage. Never use the target's logical size as credit.
    let stat = fs.lstat(path);
    return stat?.type == "file" && int(stat.nlink) == 1 ? int(stat.size) : 0;
}

function sing_box_existing_writable_bytes(previous) {
    // The exact previous writable files already fit. This describes the
    // rollback baseline, not an estimate of blocks that removal will free.
    // Installation uses actual df after removal on every filesystem.
    let bytes = 0;
    let owned = previous == null ? null : split(command_output_from_args(is_apk() ?
        [ "apk", "info", "-L", previous.name ] : [ "opkg", "files", previous.name ]), "\n");
    for (let path in [ "/usr/bin/sing-box", "/usr/lib/rust-x/sing-box", "/usr/lib/libcronet.so" ]) {
        // A library belonging to another package remains installed and is
        // not part of this rollback baseline.
        if (owned != null && !array_has(owned, path) && !array_has(owned, substr(path, 1)))
            continue;
        let writable = sing_box_writable_path(path, file_exists("/overlay/upper"), file_exists("/rom" + path));
        if (writable != "" && file_exists(writable))
            bytes += sing_box_writable_file_bytes(writable);
    }
    return bytes;
}

function sing_box_rollback_growth_bytes(previous_bytes, writable_bytes, dependency_bytes) {
    let growth = previous_bytes > writable_bytes ? previous_bytes - writable_bytes : 0;
    return growth + dependency_bytes;
}

function sing_box_package_preflight(target, previous, tmp_backup_bytes) {
    if (target == null)
        return "Target package is unavailable, invalid, or incompatible with this architecture";
    // Both solvers report an intentional conflict with the old variant.
    // Dependencies are staged before this preflight; the package manager
    // validates the local transaction after conflict removal.

    let overlay_kib = available_kib("/usr/bin");
    let tmp_kib = temporary_available_kib();
    let target_dependency_bytes = 0;
    let rollback_dependency_bytes = 0;
    for (let path in sing_box_target_dependency_files)
        target_dependency_bytes += int(staged_package_field(path, "installed-size"));
    for (let path in sing_box_rollback_dependency_files)
        rollback_dependency_bytes += int(staged_package_field(path, "installed-size"));
    // Target dependencies may remain after an opkg failure. Reserve them
    // during rollback as well. Rollback archives already occupy tmpfs.
    let rollback_growth = sing_box_rollback_growth_bytes(previous == null ? tmp_backup_bytes : previous.size,
        sing_box_existing_writable_bytes(previous), rollback_dependency_bytes + target_dependency_bytes);
    sing_box_flash_after_remove_bytes = target.size + target_dependency_bytes + rollback_dependency_bytes;
    let space_error = sing_box_space_error(overlay_kib, tmp_kib, rollback_growth, tmp_backup_bytes);
    if (space_error != "")
        return space_error;
    updates_log("Sing-box rollback staged; target flash checked after removal");
    return "";
}

function sing_box_removed_space_error() {
    // sync allows delayed allocation/GC to update df. Never force-space:
    // insufficient actual blocks trigger the already staged exact rollback.
    command_success_from_args([ "sync" ]);
    return sing_box_space_error(available_kib("/usr/bin"), temporary_available_kib(),
        sing_box_flash_after_remove_bytes, 0);
}

function pkg_install_files(files) {
    return command_success(pkg_install_files_command(files));
}

function pkg_remove_sing_box_conflict(package_name) {
    package_name = as_string(package_name);
    if (!pkg_is_installed(package_name))
        return true;
    if (is_apk())
        return command_success(command_from_args([ "apk", "del", package_name ]) + " </dev/null");
    return command_success(command_from_args([ "opkg", "remove", package_name ]) + " </dev/null");
}

function run_logged_pkg_remove_sing_box_conflict(package_name, description) {
    if (!pkg_is_installed(package_name)) {
        updates_log(description);
        return true;
    }

    let command = is_apk() ?
        command_from_args([ "apk", "del", package_name ]) + " </dev/null" :
        command_from_args([ "opkg", "remove", package_name ]) + " </dev/null";
    return run_logged(description, command);
}

function remove_previous_sing_box_packages() {
    for (let name in [ "rust-x", "sing-box-x", "sing-box-extended", "sing-box-tiny", "sing-box" ])
        if (!run_logged_pkg_remove_sing_box_conflict(name, "Removing previous " + name + " package"))
            return false;
    return true;
}

function compare_versions(lhs, rhs) {
    lhs = as_string(lhs);
    rhs = as_string(rhs);
    if (lhs == "" || rhs == "")
        return null;
    if (lhs == rhs)
        return 0;

    if (is_apk()) {
        let apk_result = trim(command_output_from_args([ "apk", "version", "-t", lhs, rhs ]));
        if (apk_result == ">")
            return 1;
        if (apk_result == "<")
            return -1;
        if (apk_result == "=")
            return 0;
    }

    if (command_exists("opkg")) {
        if (command_success_from_args([ "opkg", "compare-versions", lhs, ">", rhs ]))
            return 1;
        if (command_success_from_args([ "opkg", "compare-versions", lhs, "<", rhs ]))
            return -1;
        if (command_success_from_args([ "opkg", "compare-versions", lhs, "=", rhs ]))
            return 0;
    }

    return module_success([ LIB_DIR + "/core/helpers.uc", "version-at-least", lhs, rhs ]) ? 1 : -1;
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

function check_success_compared(component, current_version, latest_version, compare_current_version, compare_latest_version, release_url) {
    let compare_result = compare_versions(compare_current_version, compare_latest_version);
    if (compare_result == null)
        action_fail(component, "check_update", "Failed to compare versions", current_version, latest_version);

    let status = status_from_compare(compare_result);
    if (status == "")
        action_fail(component, "check_update", "Failed to compare versions", current_version, latest_version);

    let result_row = trim(helper_output("updates-check-result-row", [ component, current_version, latest_version, status ]));
    if (result_row == "")
        action_fail(component, "check_update", "Failed to compare versions", current_version, latest_version);

    let fields = split(result_row, "\t");
    let message = as_string(fields[0] || "");
    let log_line = length(fields) > 1 ? as_string(fields[1]) : message;
    updates_log(log_line);
    action_success(component, "check_update", message, current_version, latest_version, 0, status, release_url || "");
}

function check_success(component, current_version, latest_version, release_url) {
    check_success_compared(component, current_version, latest_version, current_version, latest_version, release_url || "");
}

function read_openwrt_release_value(key) {
    return trim(helper_output("openwrt-release-value", [ "/etc/openwrt_release", key ]));
}

function service_proxy_address() {
    if (!file_exists(LIB_DIR + "/singbox/runtime.uc"))
        return "";
    if (file_exists(LIB_DIR + "/service/state.uc") &&
        !module_success([ LIB_DIR + "/service/state.uc", "sing-box-service-running" ]))
        return "";
    return trim(module_output([ LIB_DIR + "/singbox/runtime.uc", "service-proxy-address", "components" ]));
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

stage_archived_sing_box_package = function(package_name, version) {
    if (FORKOP_MIRROR_BASE_URL == "") return null;
    let catalog;
    try { catalog = json(http_get(FORKOP_MIRROR_BASE_URL + "/forkop/sing-box-archive/packages.json")); }
    catch (e) { updates_log("Cannot read sing-box archive catalog: " + as_string(e), "warn"); return null; }
    let asset = sing_box_archive_asset(catalog, package_name, version,
        read_openwrt_release_value("DISTRIB_ARCH"), is_apk() ? "apk" : "ipk");
    if (asset == null) return null;
    let path = tmp_dir + "/archive-" + asset.filename;
    if (!download_with_retry(FORKOP_MIRROR_BASE_URL + asset.url, path, "exact sing-box rollback archive") ||
        package_sha256(path) != asset.sha256)
        return null;
    let info = staged_package_info(path, package_name, version);
    if (staged_package_field(path, "arch") != asset.arch) return null;
    return info;
};

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

function fetch_github_releases_json(owner, repo, per_page) {
    let response = fetch_github_json("https://api.github.com/repos/" + as_string(owner) + "/" + as_string(repo) + "/releases?per_page=" + as_string(per_page || "30"));
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
        if (response == "")
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

function retry_resolve(description, fn) {
    for (let attempt = 1; attempt <= 3; attempt++) {
        if (fn())
            return true;
        updates_log(as_string(description) + " failed (" + attempt + "/3)", "warn");
        command_success_from_args([ "sleep", "2" ]);
    }
    return false;
}

function ensure_package_tool(tool_name, package_name, component, action) {
    if (command_exists(tool_name))
        return true;
    if (!run_logged("Updating package lists before installing " + as_string(package_name), pkg_list_update_command()))
        return false;
    return run_logged("Installing bootstrap package " + as_string(package_name), pkg_install_name_command(package_name));
}

function clear_version_caches() {
    remove_file("/tmp/forkop.latest-version.cache");
    remove_file(SYSTEM_INFO_CACHE_FILE);
    remove_file("/tmp/forkop/system-info.json");
}

function managed_sing_box_service_installed() {
    return file_exists("/etc/init.d/sing-box") && index(read_file("/etc/init.d/sing-box"), SB_MANAGED_SERVICE_MARKER) >= 0;
}

function managed_sing_box_service_text() {
    return "#!/bin/sh /etc/rc.common\n" +
        "# " + SB_MANAGED_SERVICE_MARKER + "\n\n" +
        "USE_PROCD=1\n" +
        "START=99\n" +
        "PROG=\"/usr/bin/sing-box\"\n\n" +
        "start_service() {\n" +
        "    config_load \"sing-box\"\n" +
        "    local enabled config_file working_directory\n" +
        "    local log_stderr\n\n" +
        "    config_get_bool enabled \"main\" \"enabled\" \"0\"\n" +
        "    [ \"$enabled\" -eq \"1\" ] || return 0\n\n" +
        "    config_get config_file \"main\" \"conffile\" \"/etc/sing-box/config.json\"\n" +
        "    config_get working_directory \"main\" \"workdir\" \"/usr/share/sing-box\"\n" +
        "    mkdir -p \"$working_directory\" || return 1\n" +
        "    config_get_bool log_stderr \"main\" \"log_stderr\" \"1\"\n\n" +
        "    procd_open_instance\n" +
        "    procd_set_param command \"$PROG\" run -c \"$config_file\" -D \"$working_directory\"\n" +
        "    procd_set_param stderr \"$log_stderr\"\n" +
        "    procd_set_param limits core=\"unlimited\"\n" +
        "    procd_set_param limits nofile=\"1000000 1000000\"\n" +
        "    procd_set_param respawn\n" +
        "    procd_close_instance\n" +
        "}\n\n" +
        "service_triggers() {\n" +
        "    procd_add_reload_trigger \"sing-box\"\n" +
        "}\n";
}

function install_managed_sing_box_service_script() {
    let tmp = "/etc/init.d/sing-box.forkop." + owner_pid();
    if (!write_file(tmp, managed_sing_box_service_text()))
        return false;
    if (!command_success_from_args([ "chmod", "0755", tmp ])) {
        remove_file(tmp);
        return false;
    }
    return fs.rename(tmp, "/etc/init.d/sing-box");
}

function remove_managed_sing_box_service_script() {
    if (!managed_sing_box_service_installed())
        return true;
    command_success_from_args([ "/etc/init.d/sing-box", "stop" ]);
    command_success_from_args([ "/etc/init.d/sing-box", "disable" ]);
    remove_file("/etc/init.d/sing-box");
    return true;
}

function disable_sing_box_service_config() {
    if (!uci_core.available())
        return true;
    if (!uci_core.exists("sing-box.main") && !uci_core.set_section("sing-box.main", "sing-box"))
        return false;
    if (!uci_core.set("sing-box.main.enabled", "0"))
        return false;
    return uci_core.commit("sing-box");
}

function prepare_sing_box_service_disabled() {
    disable_sing_box_service_config();
    if (file_exists("/etc/init.d/sing-box")) {
        command_success_from_args([ "/etc/init.d/sing-box", "stop" ]);
        command_success_from_args([ "/etc/init.d/sing-box", "disable" ]);
    }
}

function prepare_sing_box_package_service_install() {
    prepare_sing_box_service_disabled();
    remove_managed_sing_box_service_script();
}

function forkop_status_running_with_timeout() {
    init_tmp_dir();
    let output_file = make_tmp_file("forkop-status");
    if (output_file == "")
        return false;

    let command = command_from_args([ BIN_PATH, "get_status" ]) + " >" + shell_quote(output_file) + " 2>/dev/null & pid=$!; " +
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
    let deadline = now_seconds() + 180;
    while (now_seconds() < deadline) {
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
        if (now_seconds() >= deadline)
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

function capture_managed_upgrade_sing_box_marker() {
    let state_module = LIB_DIR + "/service/state.uc";
    if (!file_exists(state_module))
        return;
    if (module_success([ state_module, "write-managed-upgrade-sing-box-marker", MANAGED_UPGRADE_SING_BOX_MARKER ]))
        updates_log("Recorded managed sing-box provenance for package upgrade");
}

function restart_forkop_after_successful_change() {
    if (!file_exists(SERVICE_INIT))
        return !forkop_was_running;
    if (!forkop_was_running) {
        updates_log("Forkop was not running before component change; restart skipped");
        prepare_sing_box_service_disabled();
        return true;
    }
    let action = forkop_stopped_for_sing_box_change ? "start" : "restart";
    return run_logged("Restarting Forkop after successful component change", command_from_args([ SERVICE_INIT, action ]));
}

function stop_forkop_before_sing_box_change() {
    if (forkop_stopped_for_sing_box_change)
        return;
    // A SIGKILL during package replacement must not let a later TTL sweep
    // discard the exact rollback package. Mark before the first mutation.
    if (tmp_dir != "" && !write_file(tmp_dir + "/.forkop-recovery", "transition\n"))
        action_fail("sing_box", "install", "Cannot protect rollback files before component change");
    forkop_stopped_for_sing_box_change = true;
    if (file_exists('/etc/init.d/forkop-tailscale'))
        command_success_from_args([ '/etc/init.d/forkop-tailscale', 'stop' ]);

    if (forkop_was_running && file_exists(SERVICE_INIT))
        run_logged("Stopping Forkop before sing-box package change", command_from_args([ "env", "FORKOP_INTERNAL_SERVICE_STOP=1", SERVICE_INIT, "stop" ]));

    if (forkop_was_running && file_exists(BIN_PATH))
        command_success_from_args([ BIN_PATH, "restore_dnsmasq" ]);

    prepare_sing_box_service_disabled();
}

wait_forkop_running_after_sing_box_change = function() {
    if (!forkop_was_running)
        return true;
    if (!file_exists(BIN_PATH))
        return false;

    let deadline = now_seconds() + 180;
    while (now_seconds() < deadline) {
        let starting = forkop_starting();
        if (!starting && file_exists(START_FAILURE_FILE)) {
            updates_log("Forkop startup failed; ending readiness wait so the component transition can finish or roll back", "error");
            return false;
        }
        if (!starting && forkop_status_running_with_timeout()) {
            if (now_seconds() + 8 >= deadline)
                return false;
            command_success_from_args([ "sleep", "8" ]);
            if (!forkop_starting() && !file_exists(START_FAILURE_FILE) &&
                forkop_status_running_with_timeout()) {
                return true;
            }
        }
        let remaining = deadline - now_seconds();
        if (remaining <= 0)
            break;
        command_success_from_args([ "sleep", "" + (remaining < 4 ? remaining : 4) ]);
    }
    return false;
};

function opkg_arch_list() {
    return trim(helper_output_input(command_output_from_args([ "opkg", "print-architecture" ]), "updates-opkg-arch-list", []));
}

function resolve_arch_candidates() {
    let arch_list = "";
    if (is_apk()) {
        if (file_exists("/etc/apk/arch"))
            arch_list += " " + trim(helper_output("file-whitespace-list", [ "/etc/apk/arch" ]));
        arch_list += " " + trim(command_output_from_args([ "apk", "--print-arch" ]));
    }
    else {
        arch_list = opkg_arch_list();
    }

    let release_arch = read_openwrt_release_value("DISTRIB_ARCH");
    if (release_arch != "")
        arch_list += " " + release_arch;
    if (!helper_success("string-has-whitespace-field", [ arch_list ]))
        arch_list = trim(command_output_from_args([ "uname", "-m" ]));

    let resolved = trim(helper_output("updates-arch-candidates", [ arch_list ]));
    let fields = split(resolved, "\t");
    if (length(fields) < 2 || as_string(fields[0]) == "" || as_string(fields[1]) == "")
        return null;

    updates_log("Detected package architecture candidates: " + fields[1]);
    return {
        target: as_string(fields[0]),
        candidates: as_string(fields[1])
    };
}

function select_inner_package_path(bundle_file, component, arch, ext) {
    return trim(helper_output_input(command_output_from_args([ "unzip", "-l", bundle_file ]), "updates-zip-inner-package-path", [ component, arch, ext ]));
}

function extract_arch_package_version(package_name, package_arch) {
    return trim(helper_output("updates-arch-package-version", [ package_name, package_arch ]));
}

function extract_zapret_bundle_version(bundle_name) {
    return trim(helper_output("updates-zapret-bundle-version", [ bundle_name ]));
}

function extract_zapret2_bundle_version(bundle_name) {
    return trim(helper_output("updates-zapret2-bundle-version", [ bundle_name ]));
}

function normalize_zapret_version(value) {
    return trim(helper_output("updates-normalize-zapret-version", [ value ]));
}

function normalize_sing_box_version(value) {
    return trim(helper_output("updates-normalize-sing-box-version", [ value ]));
}

function resolve_zapret_release(arch) {
    let release_json = fetch_github_release_json("remittor", "zapret-openwrt");
    if (release_json == "")
        return null;
    let resolved = trim(helper_output_input(release_json, "release-select-arch-suffix-asset", [ "zip", arch.candidates ]));
    let fields = split(resolved, "\t");
    if (length(fields) < 4)
        return null;
    let version = extract_zapret_bundle_version(fields[1]);
    if (version == "")
        version = trim(helper_output("string-remove-suffix", [ fields[1], ".zip" ]));
    return {
        arch: fields[0],
        bundle_name: fields[1],
        bundle_url: fields[2],
        release_url: fields[3],
        version
    };
}

function resolve_zapret2_release(arch) {
    let releases_json = fetch_github_releases_json("remittor", "zapret-openwrt", "30");
    if (releases_json == "")
        return null;
    let resolved = trim(helper_output_input(releases_json, "named-release-select-asset", [ "zapret2 ", "zapret2", "zip", arch.candidates ]));
    let fields = split(resolved, "\t");
    if (length(fields) < 4)
        return null;
    let version = extract_zapret2_bundle_version(fields[1]);
    if (version == "")
        version = trim(helper_output("string-remove-suffix", [ fields[1], ".zip" ]));
    return {
        arch: fields[0],
        bundle_name: fields[1],
        bundle_url: fields[2],
        release_url: fields[3],
        version
    };
}

function download_and_extract_zip_package(release, component) {
    let bundle_file = tmp_dir + "/" + release.bundle_name;
    if (!download_with_retry(release.bundle_url, bundle_file, release.bundle_name))
        return null;

    let inner_package_path = is_apk() ?
        select_inner_package_path(bundle_file, component, "", "apk") :
        select_inner_package_path(bundle_file, component, release.arch, "ipk");
    if (inner_package_path == "")
        return null;

    let package_name = path_basename(inner_package_path);
    let package_file = tmp_dir + "/" + package_name;
    if (!command_success(command_from_args([ "unzip", "-p", bundle_file, inner_package_path ]) + " >" + shell_quote(package_file)) ||
        !file_nonempty(package_file))
        return null;

    let version = as_string(release.version || "");
    if (version == "")
        version = component == "zapret2" ? extract_zapret2_bundle_version(release.bundle_name) : extract_zapret_bundle_version(release.bundle_name);
    if (version == "")
        version = extract_arch_package_version(package_name, release.arch);

    return {
        name: package_name,
        file: package_file,
        version
    };
}

function disable_standalone_service(name) {
    let init = "/etc/init.d/" + as_string(name);
    if (!file_exists(init))
        return;
    run_logged("Stopping standalone " + as_string(name) + " service", command_from_args([ init, "stop" ]));
    run_logged("Disabling standalone " + as_string(name) + " autostart", command_from_args([ init, "disable" ]));
}

function provider_installed(runtime_module) {
    return module_success([ runtime_module, "installed" ]);
}

function provider_package_version(runtime_module) {
    return trim(module_output([ runtime_module, "package-version" ]));
}

function install_zapret_like(component, action, runtime_module, resolve_fn, label) {
    init_tmp_dir() || action_fail(component, action, "Failed to create temporary directory");
    let arch = resolve_arch_candidates();
    if (arch == null)
        action_fail(component, action, "Failed to detect package architecture");
    let release = null;
    retry_resolve("Resolving " + label + " package", function() {
        release = resolve_fn(arch);
        return release != null;
    });
    if (release == null)
        action_fail(component, action, "Failed to resolve " + label + " package for this router architecture");

    let installed = provider_installed(runtime_module);
    let current_version = provider_package_version(runtime_module);
    if (action == "check_update") {
        if (!installed)
            action_fail(component, action, label + " is not installed", current_version, release.version, "", release.release_url || "");
        check_success_compared(component, current_version, release.version, normalize_zapret_version(current_version), normalize_zapret_version(release.version), release.release_url || "");
    }

    if (!ensure_package_tool("unzip", "unzip", component, action))
        action_fail(component, action, "Failed to install unzip");
    let pkg = download_and_extract_zip_package(release, component);
    if (pkg == null)
        action_fail(component, action, "Failed to download " + label + " package", current_version, release.version, "", release.release_url || "");

    if (!run_logged("Installing " + label + " package " + pkg.name, pkg_install_files_command([ pkg.file ])))
        action_fail(component, action, "Failed to install " + label + " package", current_version, pkg.version, "", release.release_url || "");

    disable_standalone_service(component);
    restart_forkop_after_successful_change();
    clear_version_caches();
    current_version = provider_package_version(runtime_module);
    if (current_version == "")
        current_version = "unknown";
    action_success(component, action, label + " package has been installed", current_version, pkg.version, 1, "latest", release.release_url || "");
}

function install_zapret(action) {
    install_zapret_like("zapret", action, LIB_DIR + "/providers/zapret/runtime.uc", resolve_zapret_release, "zapret");
}

function install_zapret2(action) {
    install_zapret_like("zapret2", action, LIB_DIR + "/providers/zapret2/runtime.uc", resolve_zapret2_release, "zapret2");
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

// Same rule as the script's zm_ver_gt: numeric dotted fields.
function zapret_manager_version_newer(candidate, installed) {
    let a = split(as_string(candidate), "."), b = split(as_string(installed), ".");
    for (let i = 0; i < length(a) || i < length(b); i++) {
        let x = int(a[i] || 0), y = int(b[i] || 0);
        if (x != y)
            return x > y;
    }
    return false;
}

// Install or update the web version like "w" does, but never remove it.
// "" on success, otherwise the reason it was not activated.
function activate_zapret_manager_web(manager_source) {
    let path = match(manager_source, /ZM_LUCI_URL="\$\{GH_RAW\}\/([^"]+)"/);
    if (path == null)
        return "the script does not name its web installer";
    let url = FORKOP_MIRROR_BASE_URL + "/zapret-manager/proxy/raw.githubusercontent.com/" + path[1];
    let installer = tmp_dir + "/ZapretManager_LuCI.sh";
    if (!download_with_retry(url, installer, "Zapret-Manager web version"))
        return "its installer could not be downloaded from the mirror";
    let header = match(read_file(installer), /\n# Version:[ \t]*([0-9.]+)/);
    let latest = header != null ? header[1] : "";
    let installed = file_exists(ZAPRET_MANAGER_WEB_BACKEND) ? zapret_manager_web_installed_version() : "";
    if (installed != "" && !zapret_manager_version_newer(latest, installed)) {
        updates_log("Zapret-Manager web version " + installed + " is already installed");
        return "";
    }
    let ok = run_logged("Activating the Zapret-Manager web version" + (latest != "" ? " " + latest : ""),
        command_from_args([ "sh", installer ]) + " </dev/null");
    remove_file(installer);
    if (!ok || !file_exists(ZAPRET_MANAGER_WEB_BACKEND))
        return "its installer failed; see the component log";
    return "";
}

function write_zapret_manager_launchers(manager_url, web_url) {
    let launcher = function(url) {
        return "#!/bin/sh\nexec sh <(wget -q -O - " + shell_quote(url) + ") \"$@\"\n";
    };
    // zmw is the web version's own update command; keep it on the mirror too.
    return write_file("/usr/bin/zms", launcher(manager_url)) && write_file("/usr/bin/zmsA", launcher(manager_url)) &&
        write_file("/usr/bin/zmw", launcher(web_url)) &&
        command_success_from_args([ "chmod", "0755", "/usr/bin/zms", "/usr/bin/zmsA", "/usr/bin/zmw" ]);
}

function install_zapret_manager(action) {
    let component = "zapret_manager";
    let manager_url = FORKOP_MIRROR_BASE_URL + "/zapret-manager/proxy/raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh";
    let web_url = FORKOP_MIRROR_BASE_URL + "/zapret-manager/proxy/raw.githubusercontent.com/StressOzz/Zapret-Manager/main/ZapretManager_LuCI.sh";
    let manager_file = tmp_dir + "/Zapret-Manager.sh";
    let current_version = file_exists("/usr/bin/zms") ? "installed" : "not installed";

    if (FORKOP_MIRROR_BASE_URL == "")
        action_fail(component, action, "Forkop mirror URL is not configured", current_version);
    if (!download_with_retry(manager_url, manager_file, "Zapret-Manager"))
        action_fail(component, action, "Failed to download Zapret-Manager from the mirror", current_version);

    let source = read_file(manager_file);
    let matched = match(source, /ZAPRET_MANAGER_VERSION="([^"]+)"/);
    let latest_version = matched != null ? as_string(matched[1]) : "mirror";

    // The web installer replaces zms with a GitHub launcher, so the Forkop
    // mirror launchers are written after it.
    let web_error = activate_zapret_manager_web(source);
    if (!write_zapret_manager_launchers(manager_url, web_url))
        action_fail(component, action, "Failed to install Zapret-Manager launchers", current_version, latest_version);

    clear_version_caches();
    if (web_error != "")
        action_fail(component, action, "Zapret-Manager has been installed, but its web version was not activated: " + web_error,
            "installed", latest_version);
    action_success(component, action, "Zapret-Manager and its web version have been installed from the Forkop mirror (LuCI: Services → Zapret Manager)",
        current_version, latest_version, 1, "latest", manager_url);
}

// Remove the web version the way the script's "w" command does.
function remove_zapret_manager_web() {
    if (!file_exists(ZAPRET_MANAGER_WEB_BACKEND) && !file_exists(ZAPRET_MANAGER_WEB_SCRIPT))
        return true;
    let script = join("\n", [
        "[ -x /opt/zapret-manager-luci/backend.sh ] && /opt/zapret-manager-luci/backend.sh redbtn_panel_gone >/dev/null 2>&1",
        "rm -rf /opt/zapret-manager-luci /usr/lib/zapret-manager* /usr/libexec/rpcd/zapret-manager* " +
            "/usr/share/luci/menu.d/luci-app-zapret-manager.json /usr/share/rpcd/acl.d/luci-app-zapret-manager.json " +
            "/www/luci-static/resources/view/zapret-manager* /www/luci-static/resources/zapret-manager* " +
            "/www/luci-static/resources/bytetube /www/luci-static/resources/view/bytetube /www/zm /www/zm-webui.html " +
            "/tmp/zapret-manager* /tmp/zm_uninstall_panel.sh /tmp/zm_luci_latest /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null",
        "[ -s /etc/zm-steer/owned ] || rm -rf /usr/share/zm-redbtn",
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
    return index(source, "/zapret-manager/proxy/") >= 0 ||
        (index(source, "/tmp/zm-get.$$.sh") >= 0 && index(source, "/StressOzz/Zapret-Manager/main/") >= 0);
}

function remove_zapret_manager(action) {
    let component = "zapret_manager";
    let paths = [ "/usr/bin/zms", "/usr/bin/zmsA", "/usr/bin/zmw" ];
    let removed = 0;

    for (let path in paths)
        if (file_exists(path) && !zapret_manager_launcher_owned(read_file(path)))
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

function remove_optional_component(component, package_name, label, runtime_module) {
    if (!pkg_is_installed(package_name)) {
        if (provider_installed(runtime_module))
            action_fail(component, "remove", label + " exists outside the package manager and was not removed automatically");
        action_success(component, "remove", label + " is already removed", "", "", 0);
    }

    let current_version = provider_package_version(runtime_module);
    let command = is_apk() ?
        command_from_args([ "apk", "del", package_name ]) + " </dev/null" :
        command_from_args([ "opkg", "remove", "--force-depends", package_name ]) + " </dev/null";
    if (!run_logged("Removing " + label + " package", command))
        action_fail(component, "remove", "Failed to remove " + label + " package", current_version);

    clear_version_caches();
    if (provider_installed(runtime_module))
        action_fail(component, "remove", label + " package was removed, but provider files are still present", current_version);
    restart_forkop_after_successful_change();
    action_success(component, "remove", label + " package has been removed", current_version, "", 1);
}

function read_sing_box_binary_version(binary, library_dir) {
    binary = as_string(binary);
    if (binary == "" || !file_exists(binary))
        return "";

    let command = command_from_args([ binary, "version" ]);
    if (as_string(library_dir || "") != "")
        command = command_env({ LD_LIBRARY_PATH: as_string(library_dir) }) + " " + command;

    return trim(helper_output_input(command_output(command), "stdin-first-line-last-field", []));
}

function move_file_portable(source_path, target_path) {
    if (fs.rename(source_path, target_path))
        return true;

    let staged_path = as_string(target_path) + ".forkop-move." + owner_pid();
    remove_file(staged_path);
    if (!command_success_from_args([ "cp", "-p", source_path, staged_path ]) ||
        !command_success_from_args([ "cmp", source_path, staged_path ]) ||
        !fs.rename(staged_path, target_path)) {
        remove_file(staged_path);
        return false;
    }
    remove_file(source_path);
    return true;
}

function install_archive_member(archive, member, target_path, mode) {
    let staged_path = as_string(target_path) + ".forkop-new." + owner_pid();
    remove_file(staged_path);
    if (!command_success(command_from_args([ "tar", "-xzf", archive, "-O", member ]) + " >" + shell_quote(staged_path)) ||
        !file_nonempty(staged_path) ||
        !command_success_from_args([ "chmod", mode, staged_path ]) ||
        !fs.rename(staged_path, target_path)) {
        remove_file(staged_path);
        return false;
    }
    return true;
}

function move_file_to_backup(target_path, backup_path) {
    if (!file_exists(target_path))
        return true;
    remove_file(backup_path);
    return move_file_portable(target_path, backup_path);
}

function restore_sing_box_backup(backup_binary) {
    if (as_string(backup_binary) != "" && file_nonempty(backup_binary)) {
        if (!move_file_portable(backup_binary, "/usr/bin/sing-box"))
            return false;
        return command_success_from_args([ "chmod", "0755", "/usr/bin/sing-box" ]);
    }
    remove_file("/usr/bin/sing-box");
    return true;
}

function restore_file_backup(target_path, backup_path) {
    if (as_string(backup_path) != "" && file_nonempty(backup_path))
        return move_file_portable(backup_path, target_path);
    remove_file(target_path);
    return true;
}

function sing_box_variant_is_package_managed(variant) {
    return variant == "rust-x" || variant == "x" || variant == "stable" || variant == "tiny" || variant == "extended";
}

function sing_box_x_build_version(value) {
    let parts = match(as_string(value), /^v?[0-9]+[.][0-9]+[.][0-9]+-x-([0-9]+[.][0-9]+[.][0-9]+)$/);
    return parts == null ? "" : parts[1];
}

function rust_x_build_version(value) {
    let parts = match(as_string(value), /^v?[0-9]+[.][0-9]+[.][0-9]+-rust-x[.]([0-9]+[.][0-9]+[.][0-9]+)$/);
    return parts == null ? "" : parts[1];
}

function resolve_sing_box_x_release(version, rust) {
    let package_name = rust ? "rust-x" : "sing-box-x";
    if (FORKOP_MIRROR_BASE_URL == "") return null;
    version = as_string(version);
    if (version != "" && match(version, /^[0-9]+[.][0-9]+[.][0-9]+$/) == null)
        return null;
    let base = FORKOP_MIRROR_BASE_URL + "/forkop/" + package_name + "/";
    let catalog = parse_json_object(http_get(base + (version == "" ? "latest.json" : "releases/" + version + "/manifest.json")));
    if (catalog.schema != 1 || catalog.name != package_name || int(catalog.package_revision) <= 0 ||
        match(as_string(catalog.version), /^[0-9]+[.][0-9]+[.][0-9]+$/) == null ||
        (version != "" && catalog.version != version))
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
        return { ...asset, build_version: catalog.version };
    }
    return null;
}

// The mirror catalog /forkop/rust-x/releases.json lists every published Xrust
// release; the package for this router is chosen from its assets by
// architecture and format, with the same checks as a release manifest.
function rust_x_catalog_asset(release) {
    let version = as_string(release?.version);
    if (match(version, /^[0-9]+[.][0-9]+[.][0-9]+$/) == null)
        return null;
    let base = FORKOP_MIRROR_BASE_URL + "/forkop/rust-x/";
    if (as_string(release.manifest_url) != base + "releases/" + version + "/manifest.json")
        return null;
    let arch = read_openwrt_release_value("DISTRIB_ARCH");
    let format = is_apk() ? "apk" : "ipk";
    for (let asset in release.assets || []) {
        // APK ARM64 and Beam cortex-a73 can use the cortex-a53 baseline build.
        let compatible = asset.architecture == arch ||
            (is_apk() && (arch == "aarch64" || arch == "aarch64_cortex-a73") && asset.architecture == "aarch64_cortex-a53");
        if (asset.package != "rust-x" || asset.format != format || !compatible)
            continue;
        if (match(as_string(asset.version), is_apk() ? /^[0-9.]+-r[1-9][0-9]*$/ : /^[0-9.]+-[1-9][0-9]*$/) == null ||
            substr(asset.version, 0, length(version) + 1) != version + "-" ||
            asset.name != "rust-x_" + asset.version + "_" + asset.architecture + "." + format ||
            match(as_string(asset.sha256), /^[a-f0-9]{64}$/) == null || int(asset.size) <= 0 ||
            asset.url != base + "releases/" + version + "/" + asset.name)
            return null;
        return { ...asset, build_version: version };
    }
    return null;
}

function rust_x_release_catalog() {
    if (FORKOP_MIRROR_BASE_URL == "")
        return [];
    let catalog = parse_json_object(http_get(FORKOP_MIRROR_BASE_URL + "/forkop/rust-x/releases.json"));
    if (catalog.schema != 1 || catalog.name != "rust-x" || type(catalog.releases) != "array")
        return [];
    let releases = [];
    for (let release in catalog.releases) {
        let asset = type(release) == "object" ? rust_x_catalog_asset(release) : null;
        if (asset != null)
            push(releases, asset);
    }
    return releases;
}

function rust_x_releases() {
    let rows = [];
    for (let release in rust_x_release_catalog())
        push(rows, { version: release.build_version, channel: "stable" });
    print(sprintf("%J", { success: length(rows) > 0, releases: rows }), "\n");
    cleanup_tmp_dir();
}

function selected_rust_x_release(version) {
    for (let release in rust_x_release_catalog())
        if (release.build_version == version)
            return release;
    return null;
}

function stage_sing_box_x_package(release, expected_version) {
    if (release == null || (as_string(expected_version) != "" && release.version != expected_version))
        return null;
    let path = tmp_dir + "/" + release.name;
    if (file_bytes(path) == int(release.size) && package_sha256(path) == release.sha256)
        return staged_package_info(path, release.package, release.version);
    if (!download_with_retry(release.url, path, release.package + " package") ||
        file_bytes(path) != int(release.size) || package_sha256(path) != release.sha256)
        return null;
    return staged_package_info(path, release.package, release.version);
}

function restore_sing_box_service_from_marker(marker) {
    if (as_string(marker) == "extended-compressed")
        return install_managed_sing_box_service_script();
    if (sing_box_variant_is_package_managed(as_string(marker)) && is_apk() &&
        file_exists("/etc/init.d/sing-box.apk-new") &&
        (managed_sing_box_service_installed() || !file_exists("/etc/init.d/sing-box"))) {
        remove_managed_sing_box_service_script();
        if (!move_file_portable("/etc/init.d/sing-box.apk-new", "/etc/init.d/sing-box"))
            return false;
        return command_success_from_args([ "chmod", "0755", "/etc/init.d/sing-box" ]);
    }
    if (!file_exists("/etc/init.d/sing-box") && file_nonempty("/usr/bin/sing-box"))
        return install_managed_sing_box_service_script();
    remove_managed_sing_box_service_script();
    return true;
}

function stage_previous_sing_box_package(variant) {
    // sing-box-extended is not downloaded for rollback; its files are kept
    // locally instead (sing_box_variant_uses_file_backup).
    let package_name = variant == "rust-x" ? "rust-x" : variant == "x" ? "sing-box-x" : variant == "tiny" ? "sing-box-tiny" : variant == "stable" ? "sing-box" : "";
    if (package_name == "")
        return null;
    let version = installed_package_version(package_name);
    if (version == "")
        return null;
    if (variant == "x" || variant == "rust-x")
        return stage_sing_box_x_package(resolve_sing_box_x_release(replace(version, /-r?[0-9]+$/, ""), variant == "rust-x"), version);
    return stage_repository_package(package_name, version);
}

function sing_box_runtime_output(mode, args) {
    let command_args = [ LIB_DIR + "/singbox/runtime.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    return trim(module_output(command_args));
}

function sing_box_runtime_success(mode, args) {
    let command_args = [ LIB_DIR + "/singbox/runtime.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    return module_success(command_args);
}

function write_sing_box_variant_state(marker, version) {
    if (!sing_box_runtime_success("write-variant-marker", [ marker ]))
        updates_log("Failed to write sing-box variant marker", "warn");
    if (!sing_box_runtime_success("write-version-state", [ version ]))
        updates_log("Failed to write sing-box version state", "warn");
    if (marker == 'rust-x' && file_exists('/etc/forkop-tailscale/enabled') && file_exists('/etc/init.d/forkop-tailscale'))
        command_success_from_args([ '/etc/init.d/forkop-tailscale', 'start' ]);
}

function restore_sing_box_variant_state(previous_marker, previous_version_state) {
    sing_box_runtime_success("restore-variant-marker", [ previous_marker ]);
    sing_box_runtime_success("restore-version-state", [ previous_version_state ]);
    if (previous_marker == 'rust-x' && file_exists('/etc/forkop-tailscale/enabled') && file_exists('/etc/init.d/forkop-tailscale'))
        command_success_from_args([ '/etc/init.d/forkop-tailscale', 'start' ]);
}

function replace_sing_box_package_variant(target_package, conflict_package, target_version) {
    prepare_sing_box_package_service_install();
    if ((as_string(conflict_package) == "" || !pkg_is_installed(conflict_package)) &&
        (target_package == "sing-box-extended" || !pkg_is_installed("sing-box-extended")))
        return pkg_install_name_downgrade(target_package, target_version);

    if (target_package != "sing-box-extended" && !pkg_remove_sing_box_conflict("sing-box-extended"))
        return false;
    if (as_string(conflict_package) != "" && !pkg_remove_sing_box_conflict(conflict_package))
        return false;
    return pkg_install_name_downgrade(target_package, target_version);
}

function restore_sing_box_package_variant(previous_variant) {
    if (previous_variant == "x" || previous_variant == "rust-x") {
        let target = stage_sing_box_x_package(resolve_sing_box_x_release("", previous_variant == "rust-x"), "");
        if (target == null) return false;
        for (let name in [ "rust-x", "sing-box-x", "sing-box", "sing-box-tiny", "sing-box-extended" ])
            if (name != target.name && !pkg_remove_sing_box_conflict(name)) return false;
        return pkg_install_files([ target.path ]);
    }
    if (previous_variant == "tiny")
        return replace_sing_box_package_variant("sing-box-tiny", "sing-box", available_package_version("sing-box-tiny"));
    if (previous_variant == "stable")
        return replace_sing_box_package_variant("sing-box", "sing-box-tiny", available_package_version("sing-box"));
    if (previous_variant == "not-installed") {
        pkg_remove_sing_box_conflict("rust-x");
        pkg_remove_sing_box_conflict("sing-box-x");
        pkg_remove_sing_box_conflict("sing-box-extended");
        pkg_remove_sing_box_conflict("sing-box-tiny");
        pkg_remove_sing_box_conflict("sing-box");
        remove_managed_sing_box_service_script();
        remove_file("/usr/bin/sing-box");
        return true;
    }
    return false;
}

function restore_sing_box_install_backup(previous_variant, backup_binary, rollback_file) {
    if (previous_variant == "extended")
        return restore_sing_box_backup(backup_binary) && restore_extended_package_files();
    if (sing_box_variant_is_package_managed(previous_variant)) {
        // The legacy compressed-archive action does not use this package
        // transaction; preserve its existing rollback behavior.
        if (rollback_file == null)
            return restore_sing_box_package_variant(previous_variant) ||
                (as_string(backup_binary) != "" && restore_sing_box_backup(backup_binary));
        let package_name = previous_variant == "rust-x" ? "rust-x" : previous_variant == "x" ? "sing-box-x" : previous_variant == "tiny" ? "sing-box-tiny" :
            previous_variant == "stable" ? "sing-box" : "sing-box-extended";
        let previous_version = as_string(rollback_file) != "" ? staged_package_field(rollback_file, "version") : "";
        if (previous_version != "" && installed_package_version(package_name) == previous_version &&
            read_sing_box_binary_version("/usr/bin/sing-box", previous_variant == "extended" ? "/usr/lib" : "") != "")
            return true;
        remove_file("/usr/bin/sing-box");
        if (as_string(rollback_file) != "" && file_nonempty(rollback_file) &&
            previous_version != "" &&
            run_logged("Restoring previous sing-box package from local archive",
                pkg_install_sing_box_files_command(sing_box_rollback_files(rollback_file))) &&
            installed_package_version(package_name) == previous_version &&
            read_sing_box_binary_version("/usr/bin/sing-box", "") != "")
            return true;
        updates_log("Previous sing-box package could not be restored; package state may be inconsistent", "error");
        return false;
    }

    if (as_string(backup_binary) != "")
        return restore_sing_box_backup(backup_binary);
    return restore_sing_box_package_variant(previous_variant);
}

function restore_sing_box_after_failed_package_install(target_package, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched, rollback_file) {
    pkg_remove_sing_box_conflict(target_package);
    let restore_status = restore_sing_box_install_backup(previous_variant, backup_binary, rollback_file);
    if (cronet_touched) {
        if (!restore_file_backup("/usr/lib/libcronet.so", backup_cronet))
            restore_status = false;
        if (file_nonempty("/usr/lib/libcronet.so") && !command_success_from_args([ "chmod", "0644", "/usr/lib/libcronet.so" ]))
            restore_status = false;
    }
    restore_sing_box_variant_state(previous_marker, previous_version_state);
    if (!restore_sing_box_service_from_marker(previous_marker))
        restore_status = false;
    if (restore_status) {
        remove_file(backup_binary);
        remove_file(backup_cronet);
    }
    clear_version_caches();
    return restore_status;
}

function fail_package_sing_box_install(action, tiny, reason, current_version, latest_version,
    target_package, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched, rollback_file) {
    let restored = restore_sing_box_after_failed_package_install(
        target_package,
        previous_variant,
        backup_binary,
        backup_cronet,
        previous_marker,
        previous_version_state,
        cronet_touched,
        rollback_file
    );

    let prefix = target_package == "rust-x" ? "Xrust" : target_package == "sing-box-x" ? "Sing-box X" : tiny ? "sing-box-tiny" : "Stable sing-box";
    if (restored)
        restored = restart_forkop_after_successful_change() && wait_forkop_running_after_sing_box_change();
    if (!restored)
        preserve_update_recovery_files = true;
    if (restored)
        action_fail("sing_box", action, prefix + " " + reason + "; previous sing-box variant was restored", current_version, latest_version);
    action_fail("sing_box", action, prefix + " " + reason + " and previous sing-box variant could not be restored", current_version, latest_version);
}

// Forkop does not download sing-box-extended, also not for a rollback. A
// manually installed build is restored from local copies of its files, like
// the unpackaged compressed binary.
function sing_box_variant_uses_file_backup(variant) {
    return variant == "extended" || variant == "extended-compressed";
}

// Removing the sing-box-extended package deletes these small files too.
function backup_extended_package_files() {
    extended_package_file_backups = [];
    for (let path in [ "/etc/init.d/sing-box", "/etc/config/sing-box" ]) {
        if (!file_exists(path))
            continue;
        let backup = tmp_dir + "/" + replace(substr(path, 1), /\//g, "_") + ".forkop-backup";
        if (!command_success_from_args([ "cp", "-p", path, backup ]))
            return false;
        push(extended_package_file_backups, { path, backup });
    }
    return true;
}

function restore_extended_package_files() {
    let restored = true;
    for (let item in extended_package_file_backups)
        if (!file_exists(item.path) && !move_file_portable(item.backup, item.path))
            restored = false;
    return restored;
}

function install_package_sing_box(action, tiny, x, rust, requested_version) {
    x = x || rust;
    let package_name = rust ? "rust-x" : x ? "sing-box-x" : tiny ? "sing-box-tiny" : "sing-box";
    let target_variant = rust ? "rust-x" : x ? "x" : tiny ? "tiny" : "stable";
    let label = rust ? "Xrust" : x ? "sing-box X" : tiny ? "tiny sing-box" : "stable sing-box";
    let package_version = installed_package_version(package_name);
    let binary_version = sing_box_runtime_output("version", []);
    let current_version = package_version;
    if (sing_box_runtime_success("is-extended", [ binary_version ]))
        current_version = binary_version;
    if (current_version == "")
        current_version = binary_version;
    // An exact Xrust version comes from the mirror release catalog.
    requested_version = rust && action == "install_rust_x" ? as_string(requested_version) : "";
    let release = requested_version != "" ? selected_rust_x_release(requested_version) :
        x ? resolve_sing_box_x_release("", rust) : null;
    if (requested_version != "" && release == null)
        action_fail("sing_box", action, "Selected Xrust version is unavailable for this router", current_version, requested_version);
    let latest_version = x ? as_string(release?.version) : available_package_version(package_name);
    if (latest_version == "")
        latest_version = installed_package_version(package_name);

    if (action == "check_update") {
        if (x) {
            if (release == null || package_version == "")
                action_fail("sing_box", action, "Cannot resolve installed " + label + " or mirror catalog", current_version);
            check_success_compared("sing_box", (rust ? rust_x_build_version(binary_version) : sing_box_x_build_version(binary_version)), release.build_version,
                package_version, release.version, "");
        }
        if (latest_version == "")
            action_fail("sing_box", action, "Failed to resolve " + (tiny ? "tiny" : "stable") + " sing-box package version", current_version);
        if (tiny && !sing_box_runtime_success("is-tiny", [ binary_version ]))
            action_fail("sing_box", action, "sing-box-tiny is not installed", current_version, latest_version);
        check_success("sing_box", current_version, latest_version, "");
    }

    if (!x && !ensure_repository_indexes())
        action_fail("sing_box", action, "Failed to update package lists", current_version, latest_version);
    latest_version = x ? as_string(release?.version) : available_package_version(package_name);
    if (latest_version == "")
        latest_version = installed_package_version(package_name);
    if (latest_version == "")
        action_fail("sing_box", action, "Failed to resolve " + (tiny ? "tiny" : "stable") + " sing-box package version", current_version);
    if (x && release == null)
        action_fail("sing_box", action, "Failed to resolve " + label + " package from mirror", current_version);

    let previous_variant = sing_box_runtime_output("variant", []);
    if (action == "install" && previous_variant == target_variant &&
        current_version == latest_version)
        action_success("sing_box", action, "Installed sing-box package is already up to date",
            x ? binary_version : current_version, x ? release.build_version : latest_version, 0, "latest");

    let target = x ? stage_sing_box_x_package(release, latest_version) : stage_repository_package(package_name, latest_version);
    if (target == null)
        action_fail("sing_box", action, "Cannot download or validate the selected sing-box package", current_version, latest_version);
    let file_backup = sing_box_variant_uses_file_backup(previous_variant);
    let package_rollback = sing_box_variant_is_package_managed(previous_variant) && !file_backup;
    let rollback = package_rollback ?
        (previous_variant == target_variant &&
            installed_package_version(package_name) == target.version ? target :
            stage_previous_sing_box_package(previous_variant)) : null;
    if (package_rollback && rollback == null)
        action_fail("sing_box", action, "Cannot find the exact installed sing-box package in the mirror archive or repository; package change was not started", current_version, latest_version);
    let rollback_file = rollback == null ? "" : rollback.path;
    if (!prepare_sing_box_package_dependencies(target, rollback, previous_variant))
        action_fail("sing_box", action, "Cannot cache all required sing-box dependencies for offline installation and rollback", current_version, latest_version);
    // The compressed binary is small and is kept on tmpfs. A sing-box-extended
    // package binary is large: keep it on tmpfs only with ample room left,
    // otherwise rename it on flash, which the removed-space check accounts for.
    let backup_bytes = file_backup ? file_bytes("/usr/bin/sing-box") + file_bytes("/usr/lib/libcronet.so") : 0;
    let backup_on_tmpfs = previous_variant == "extended-compressed" ||
        (previous_variant == "extended" && temporary_available_kib() * 1024 >= backup_bytes + 32 * 1024 * 1024);
    let tmp_backup_bytes = backup_on_tmpfs ? backup_bytes : 0;
    let preflight_error = sing_box_package_preflight(target, rollback, tmp_backup_bytes);
    if (preflight_error != "")
        action_fail("sing_box", action, preflight_error, current_version, latest_version);

    let previous_marker = sing_box_runtime_output("read-variant-marker", []);
    let previous_version_state = sing_box_runtime_output("read-version-state", []);
    stop_forkop_before_sing_box_change();

    let backup_binary = "";
    let backup_cronet = "";
    let cronet_touched = false;
    if (file_backup && file_exists("/usr/bin/sing-box")) {
        backup_binary = backup_on_tmpfs ? tmp_dir + "/sing-box.forkop-backup" :
            "/usr/bin/sing-box.forkop-backup." + owner_pid();
        if (!move_file_to_backup("/usr/bin/sing-box", backup_binary))
            action_fail("sing_box", action, "Failed to backup current sing-box binary", current_version, latest_version);
    }
    if (file_backup && file_exists("/usr/lib/libcronet.so")) {
        cronet_touched = true;
        backup_cronet = backup_on_tmpfs ? tmp_dir + "/libcronet.so.forkop-backup" :
            "/usr/lib/libcronet.so.forkop-backup." + owner_pid();
        if (!move_file_to_backup("/usr/lib/libcronet.so", backup_cronet)) {
            restore_sing_box_backup(backup_binary);
            action_fail("sing_box", action, "Failed to backup current libcronet.so", current_version, latest_version);
        }
    }
    if (previous_variant == "extended" && !backup_extended_package_files()) {
        restore_sing_box_backup(backup_binary);
        restore_file_backup("/usr/lib/libcronet.so", backup_cronet);
        action_fail("sing_box", action, "Failed to backup the current sing-box-extended service files", current_version, latest_version);
    }

    prepare_sing_box_package_service_install();
    if (!remove_previous_sing_box_packages())
        fail_package_sing_box_install(action, tiny, "package installation failed", current_version, latest_version,
            package_name, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched, rollback_file);

    let removed_space_error = sing_box_removed_space_error();
    if (removed_space_error != "")
        fail_package_sing_box_install(action, tiny, removed_space_error, current_version, latest_version,
            package_name, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched, rollback_file);
    if (!run_logged("Installing " + label + " package",
        pkg_install_sing_box_files_command(sing_box_target_files(target.path))))
        fail_package_sing_box_install(action, tiny, "package installation failed", current_version, latest_version,
            package_name, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched, rollback_file);

    let new_version = read_sing_box_binary_version("/usr/bin/sing-box", "");
    if (new_version == "")
        fail_package_sing_box_install(action, tiny, "package was installed, but sing-box binary is not available", current_version, latest_version,
            package_name, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched, rollback_file);
    if (sing_box_runtime_success("is-extended", [ new_version ]) ||
        (x && (rust ? rust_x_build_version(new_version) : sing_box_x_build_version(new_version)) != release.build_version))
        fail_package_sing_box_install(action, tiny, "package was installed, but active binary identity or version does not match the selected core", new_version, latest_version,
            package_name, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched, rollback_file);
    write_sing_box_variant_state(target_variant, new_version);
    if (!restart_forkop_after_successful_change() || !wait_forkop_running_after_sing_box_change())
        fail_package_sing_box_install(action, tiny, "was installed, but Forkop did not start cleanly", new_version, latest_version,
            package_name, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched, rollback_file);
    remove_file(backup_binary);
    remove_file(backup_cronet);
    clear_version_caches();
    action_success("sing_box", action, label + " has been installed", new_version, x ? release.build_version : latest_version,
        normalize_sing_box_version(new_version) == normalize_sing_box_version(current_version) ? 0 : 1, "latest");
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
            let assets = json(release_json).assets;
            release.assets = type(assets) == "array" ? assets : [];
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

function stage_forkop_rollback_packages() {
    let staged = [];
    let current_version = installed_package_version("forkop");
    let release = current_version != "" ? selected_forkop_release(forkop_release_version(current_version)) : null;
    for (let name in [ "luci-app-forkop", "luci-i18n-forkop-ru", "forkop" ]) {
        let version = installed_package_version(name);
        if (version == "") {
            if (name != "luci-i18n-forkop-ru")
                return null;
            continue;
        }
        let archive = release != null && version == current_version ?
            stage_forkop_release_archive(release, name, version) : null;
        if (archive == null)
            archive = stage_repository_package(name, version);
        if (archive == null)
            return null;
        push(staged, archive);
    }
    return staged;
}

function forkop_package_space_error(overlay_kib, tmp_kib, target_bytes, rollback_bytes) {
    let target_kib = int((target_bytes + 1023) / 1024);
    let rollback_kib = int((rollback_bytes + 1023) / 1024);
    // Flash reserve is independent of the temporary workspace allowance.
    // Budget the larger extracted payload with the same metadata allowance as sing-box.
    let payload_kib = target_kib > rollback_kib ? target_kib : rollback_kib;
    let overlay_need = payload_kib + 256;
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

function forkop_package_preflight(backend_file, app_file, i18n_file, rollback_packages, version) {
    let target_bytes = 0;
    for (let item in [ [ backend_file, "forkop" ], [ app_file, "luci-app-forkop" ],
        [ i18n_file, "luci-i18n-forkop-ru" ] ]) {
        if (item[0] == "") continue;
        let info = staged_package_info(item[0], item[1], forkop_package_version(version));
        if (info == null) return "Forkop release package is invalid or incompatible: " + item[1];
        target_bytes += info.size;
    }
    let rollback_bytes = 0;
    for (let item in rollback_packages)
        rollback_bytes += item.size;
    let overlay_kib = available_kib("/usr/bin");
    let tmp_kib = temporary_available_kib();
    let error = forkop_package_space_error(overlay_kib, tmp_kib, target_bytes, rollback_bytes);
    if (error == "" && sing_box_runtime_output("read-variant-marker", []) == "extended-compressed") {
        let backup_kib = int((file_bytes("/usr/bin/sing-box") + file_bytes("/usr/lib/libcronet.so") + 1023) / 1024);
        if (tmp_kib < backup_kib + 8192)
            error = "Not enough temporary memory to preserve compressed sing-box during Forkop update";
    }
    if (error == "")
        updates_log("Forkop package preflight passed: flash " + overlay_kib + " KiB, tmp " +
            tmp_kib + " KiB, target " + int((target_bytes + 1023) / 1024) +
            " KiB, rollback " + int((rollback_bytes + 1023) / 1024) + " KiB");
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

function stop_forkop_for_package_restore() {
    let script = forkop_package_init || SERVICE_INIT;
    command_success_from_args([ "env", "FORKOP_INTERNAL_SERVICE_STOP=1", script, "stop" ]);
    if (!wait_for_service_action_idle())
        return false;
    // Older init scripts can return an error after a successful asynchronous
    // stop. The adapter confirms that the dataplane is actually absent.
    return command_success_from_args([ "env", "FORKOP_INTERNAL_SERVICE_STOP=1", script, "stop" ]);
}

function restore_forkop_packages(staged) {
    let restored = true;
    // Keep the backend last, just as in the normal opkg upgrade. Its postinst
    // owns service restoration after the matching LuCI files are back in place.
    if (is_apk()) {
        let args = [ "apk", "--preserve-env", "add", "--no-network", "--allow-untrusted", "--force-reinstall" ];
        for (let archive in staged)
            push(args, archive.path);
        restored = run_logged("Restoring previous Forkop package set",
            command_env({ FORKOP_INIT: forkop_package_init }) + " " + command_from_args(args) + " </dev/null");
    }
    else {
        for (let archive in staged) {
            if (!run_logged("Restoring previous " + archive.name + " package",
                pkg_restore_file_command(archive.path)))
                restored = false;
        }
    }
    for (let archive in staged) {
        let actual = installed_package_version(archive.name);
        if (actual != archive.version) {
            updates_log("Restored " + archive.name + " version mismatch: expected " + archive.version + ", got " + actual, "error");
            restored = false;
        }
    }
    if (restored) {
        if (!stop_forkop_for_package_restore()) {
            updates_log("Cannot confirm stopped Forkop after restoring previous packages", "error");
            restored = false;
        }
        else if (!restore_forkop_configuration_backup(forkop_configuration_backup, "/etc/config")) {
            updates_log("Cannot reapply configuration after previous package hooks", "error");
            restored = false;
        }
    }
    if (!command_success_from_args([ SERVICE_INIT, forkop_was_enabled ? "enable" : "disable" ])) {
        updates_log("Cannot restore Forkop enabled state", "error");
        restored = false;
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

function upgrade_sing_box_ticks(pid) {
    let stat = read_file("/proc/" + pid + "/stat");
    let marker = index(stat, ") ");
    if (marker < 0)
        return null;
    let fields = split(trim(substr(stat, marker + 2)), /[ \t\r\n]+/);
    return length(fields) >= 20 && match(fields[19], /^[0-9]+$/) != null ? fields[19] : null;
}

function upgrade_sing_box_processes() {
    let processes = {};
    for (let exe in fs.glob("/proc/[0-9]*/exe")) {
        let path = trim(command_output_from_args([ "readlink", exe ]));
        let name = replace(path, /^.*\//, "");
        if (name != "sing-box" && name != "sing-box (deleted)")
            continue;
        let pid = split(exe, "/")[2];
        let args = split(fs.readfile("/proc/" + pid + "/cmdline") || "", chr(0));
        if (args[1] == "tailscale-luci") continue;
        let ticks = upgrade_sing_box_ticks(pid);
        if (ticks == null)
            return null;
        processes[pid] = ticks;
    }
    return processes;
}

function upgrade_sing_box_count(processes) {
    let count = 0;
    for (let _ in processes)
        count++;
    return count;
}

function upgrade_procd_owns_all(processes) {
    let data = command_output_from_args([ "ubus", "call", "service", "list" ]);
    let service;
    try { service = json(data)["sing-box"]; } catch (e) { return false; }
    let instances = service && type(service.instances) == "object" ? service.instances : {};
    for (let pid, ticks in processes) {
        let owned = false;
        for (let _, instance in instances) {
            if (type(instance) != "object")
                continue;
            let command = instance.command;
            if (instance.running === true && as_string(instance.pid) == pid &&
                type(command) == "array" && length(command) >= 4 &&
                command[0] == "/usr/bin/sing-box" && command[1] == "run" &&
                command[2] == "-c" && command[3] == "/etc/sing-box/config.json" &&
                upgrade_sing_box_ticks(pid) == ticks)
                owned = true;
        }
        if (!owned)
            return false;
    }
    return true;
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

function stop_old_sing_box_before_forkop_upgrade() {
    if (file_exists(SERVICE_INIT))
        upgrade_bounded_stop(SERVICE_INIT);

    let processes = upgrade_sing_box_processes();
    if (processes == null)
        return false;
    if (upgrade_sing_box_count(processes) == 0)
        return true;
    if (!upgrade_procd_owns_all(processes))
        return false;

    let confirmed = upgrade_sing_box_processes();
    if (confirmed == null || upgrade_sing_box_count(confirmed) != upgrade_sing_box_count(processes))
        return false;
    for (let pid, ticks in processes)
        if (confirmed[pid] != ticks)
            return false;
    if (!upgrade_procd_owns_all(confirmed) || !file_exists("/etc/init.d/sing-box"))
        return false;

    upgrade_bounded_stop("/etc/init.d/sing-box");
    let quiet = 0;
    for (let attempt = 0; attempt < 17; attempt++) {
        let remaining = upgrade_sing_box_processes();
        if (remaining == null)
            return false;
        quiet = upgrade_sing_box_count(remaining) == 0 ? quiet + 1 : 0;
        if (quiet >= 2)
            return true;
        command_success_from_args([ "sleep", "1" ]);
    }
    return false;
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
        if (parsed != null && !array_has([ "forkop", "luci-app-forkop", "luci-i18n-forkop-ru" ], parsed[2]) &&
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

function install_forkop(requested_version) {
    requested_version = as_string(requested_version);
    let selected = requested_version != "" ? selected_forkop_release(requested_version) : null;
    if (requested_version != "" && selected == null)
        action_fail("forkop", "install", "Selected release is unavailable or incompatible", FORKOP_VERSION, requested_version);
    let latest_version = selected != null ? selected.tag_name : latest_forkop_version();
    if (latest_version == "")
        latest_version = "unknown";
    if (latest_version == "unknown")
        action_fail("forkop", "install", "Failed to resolve Forkop release", FORKOP_VERSION, latest_version);

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
    if (!run_logged("Updating package lists before Forkop package change", pkg_list_update_command()))
        action_fail("forkop", "install", "Failed to update package lists", FORKOP_VERSION, latest_version);

    let rollback_packages = stage_forkop_rollback_packages();
    if (rollback_packages == null)
        action_fail("forkop", "install", "Cannot cache the exact installed Forkop packages for rollback", FORKOP_VERSION, latest_version);
    let preflight_error = forkop_package_preflight(backend_file, app_file, i18n_file, rollback_packages, latest_version);
    if (preflight_error != "")
        action_fail("forkop", "install", preflight_error, FORKOP_VERSION, latest_version);
    if (!preinstall_release_dependencies([ backend_file, app_file, i18n_file ]))
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

    // Capture before apk/opkg runs the currently installed package's prerm.
    // The new lifecycle will accept only this exact PID/starttime for a short
    // bounded exit wait, then re-run the normal ownership guard.
    capture_managed_upgrade_sing_box_marker();

    if (!stop_old_sing_box_before_forkop_upgrade())
        action_fail("forkop", "install", "Old sing-box processes have ambiguous ownership or did not stop", FORKOP_VERSION, latest_version);

    // Releases before this fix remove the unmanaged compressed binary in
    // their prerm. Save it before the package manager invokes that old hook.
    if (sing_box_runtime_output("read-variant-marker", []) == "extended-compressed") {
        for (let name in [ "sing-box", "sing-box.init", "libcronet.so" ])
            remove_file(COMPRESSED_UPGRADE_BACKUP + "/" + name);
        let service = read_file("/etc/init.d/sing-box");
        if (!file_nonempty("/usr/bin/sing-box") || index(service, SB_MANAGED_SERVICE_MARKER) < 0 ||
            !ensure_dir(COMPRESSED_UPGRADE_BACKUP) ||
            !command_success_from_args([ "cp", "-p", "/usr/bin/sing-box", COMPRESSED_UPGRADE_BACKUP + "/sing-box" ]) ||
            !command_success_from_args([ "cp", "-p", "/etc/init.d/sing-box", COMPRESSED_UPGRADE_BACKUP + "/sing-box.init" ]) ||
            (file_exists("/usr/lib/libcronet.so") &&
             !command_success_from_args([ "cp", "-p", "/usr/lib/libcronet.so", COMPRESSED_UPGRADE_BACKUP + "/libcronet.so" ])))
            action_fail("forkop", "install", "Failed to preserve compressed sing-box before upgrade", FORKOP_VERSION, latest_version);
    }

    let remaining_sing_box = upgrade_sing_box_processes();
    if (remaining_sing_box == null || upgrade_sing_box_count(remaining_sing_box) != 0)
        action_fail("forkop", "install", "Old sing-box processes appeared before package installation", FORKOP_VERSION, latest_version);

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
    if (installed_package_version("forkop") != expected_package_version ||
        installed_package_version("luci-app-forkop") != expected_package_version ||
        (i18n_file != "" && installed_package_version("luci-i18n-forkop-ru") != expected_package_version))
        fail_forkop_package_install(rollback_packages, "Forkop package versions disagree after installation", latest_version);

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
    clear_version_caches();
    let new_version = installed_package_version("forkop");
    if (new_version == "")
        new_version = latest_version;
    updates_log("Forkop updated to " + new_version);
    action_success("forkop", "install", "Forkop has been installed", new_version, latest_version, 1, "latest", release.release_url);
}

function dispatch_sing_box(action, version) {
    if (action == "install_rust_x") {
        install_package_sing_box(action, false, false, true, version);
        return;
    }
    if (action == "install_x") {
        install_package_sing_box(action, false, true);
        return;
    }
    if (action == "install_tiny") {
        install_package_sing_box(action, true);
        return;
    }
    if (action == "install_stable") {
        install_package_sing_box(action, false);
        return;
    }

    let variant = sing_box_runtime_output("variant", []);
    if (variant == "rust-x")
        install_package_sing_box(action, false, false, true);
    else if (variant == "x" || variant == "not-installed")
        install_package_sing_box(action, false, true);
    else if (variant == "extended" || variant == "extended-compressed")
        // Forkop no longer downloads sing-box-extended; a manually installed
        // build keeps working and is updated the same way it was installed.
        action_fail("sing_box", action, "sing-box-extended was installed manually; update it manually",
            sing_box_runtime_output("version", []));
    else if (variant == "tiny")
        install_package_sing_box(action, true);
    else
        install_package_sing_box(action, false);
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
        let listen = trim(module_output([ LIB_DIR + "/singbox/runtime.uc", "service-listen-address" ]));
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

    // Direct Proxy changes only the sing-box configuration. Use the normal
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

function normalize_component_name(component) {
    component = as_string(component);
    if (component == "sing-box" || component == "singbox")
        return "sing_box";
    if (component == "forkop")
        return "forkop";
    return component;
}

function component_action(component, action, version) {
    component = normalize_component_name(component);
    action = as_string(action);
    if (!acquire_component_lock())
        action_fail(component != "" ? component : "unknown", action != "" ? action : "unknown", "Another component action is already running");
    if (!init_tmp_dir())
        action_fail(component != "" ? component : "unknown", action != "" ? action : "unknown", "Failed to create temporary directory");
    capture_forkop_running_state();

    if (component == "forkop" && action == "check_update")
        check_forkop();
    else if (component == "forkop" && action == "install")
        install_forkop(version);
    else if (component == "sing_box" && (action == "check_update" || action == "install" ||
        action == "install_rust_x" || action == "install_x" || action == "install_tiny" || action == "install_stable"))
        dispatch_sing_box(action, version);
    else if (component == "zapret" && (action == "check_update" || action == "install"))
        install_zapret(action);
    else if (component == "zapret" && action == "remove")
        remove_optional_component("zapret", "zapret", "zapret", LIB_DIR + "/providers/zapret/runtime.uc");
    else if (component == "zapret2" && (action == "check_update" || action == "install"))
        install_zapret2(action);
    else if (component == "zapret2" && action == "remove")
        remove_optional_component("zapret2", "zapret2", "zapret2", LIB_DIR + "/providers/zapret2/runtime.uc");
    else if (component == "zapret_manager" && action == "install")
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
else if (mode == "rust-x-releases")
    rust_x_releases();
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
else if (mode == "sing-box-file-size-fixture")
    print(file_bytes(ARGV[1]), "\n");
else if (mode == "temporary-capacity-fixture")
    print(temporary_capacity_kib(int(ARGV[1]), int(ARGV[2])), "\n");
else if (mode == "archive-install-fixture") {
    if (!install_archive_member(ARGV[1], ARGV[2], ARGV[3], "0755")) exit(1);
}
else if (mode == "download-limit-fixture") {
    if (!bounded_download(command_from_args([ "dd", "if=/dev/zero", "of=" + ARGV[2], "bs=1024", "count=4" ]), int(ARGV[1]))) exit(1);
}
else if (mode == "sing-box-writable-path-fixture")
    print(sing_box_writable_path(ARGV[1], ARGV[2] == "1", ARGV[3] == "1"), "\n");
else if (mode == "sing-box-writable-file-size-fixture")
    print(sing_box_writable_file_bytes(ARGV[1]), "\n");
else if (mode == "sing-box-package-info-fixture") {
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
else if (mode == "sing-box-space-fixture") {
    let error = sing_box_space_error(int(ARGV[1]), int(ARGV[2]), int(ARGV[3]),
        int(ARGV[4] || "0"));
    if (error != "") {
        warn(error, "\n");
        exit(1);
    }
    print("ok\n");
}
else if (mode == "sing-box-rollback-space-fixture") {
    let growth = sing_box_rollback_growth_bytes(int(ARGV[3]), int(ARGV[4]), int(ARGV[5] || "0"));
    let error = sing_box_space_error(int(ARGV[1]), int(ARGV[2]), growth, int(ARGV[6] || "0"));
    if (error != "") {
        warn(error, "\n");
        exit(1);
    }
    print("ok\n");
}
else {
    warn("Usage: components/action.uc <component-action|latest-forkop-version|forkop-release-metadata> ...\n");
    exit(1);
}
