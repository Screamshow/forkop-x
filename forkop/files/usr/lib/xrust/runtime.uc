#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let common = require("core.common");
let xrust = require("xrust.binary");
let connections = require("config.connections");
let runtime_dns = require("xrust.dns");
let runtime_constants = require("xrust.constants");
let subscription_recovery = require("xrust.subscription_recovery");

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
// Test-only config preparation failure injection. Empty in production.
const SINGBOX_CONFIG_FAIL_PHASE = getenv("FORKOP_SINGBOX_CONFIG_FAIL_PHASE") || "";
const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const TMP_SING_BOX_FOLDER = getenv("TMP_SING_BOX_FOLDER") || "/tmp/xrust";
const TMP_RULESET_FOLDER = getenv("TMP_RULESET_FOLDER") || TMP_SING_BOX_FOLDER + "/rulesets";
const TMP_SUBSCRIPTION_FOLDER = getenv("TMP_SUBSCRIPTION_FOLDER") || TMP_SING_BOX_FOLDER + "/subscriptions";
const RUNTIME_STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const SUBSCRIPTION_UPDATE_STATE_DIR = getenv("FORKOP_SUBSCRIPTION_UPDATE_STATE_DIR") || RUNTIME_STATE_DIR + "/subscription-update";
const SUBSCRIPTION_LINKS_DIR = getenv("FORKOP_SUBSCRIPTION_LINKS_DIR") || RUNTIME_STATE_DIR + "/subscription-links";
const SUBSCRIPTION_METADATA_DIR = getenv("FORKOP_SUBSCRIPTION_METADATA_DIR") || RUNTIME_STATE_DIR + "/subscription-metadata";
const OUTBOUND_METADATA_DIR = getenv("FORKOP_OUTBOUND_METADATA_DIR") || RUNTIME_STATE_DIR + "/outbound-metadata";
const SECTION_CACHE_DIR = getenv("FORKOP_SECTION_CACHE_DIR") || RUNTIME_STATE_DIR + "/section-cache";
const RUNTIME_CACHE_FORMAT_FILE = getenv("FORKOP_RUNTIME_CACHE_FORMAT_FILE") || RUNTIME_STATE_DIR + "/cache-format";
const RUNTIME_CACHE_FORMAT = getenv("FORKOP_RUNTIME_CACHE_FORMAT") || "10";
const PERSISTENT_SUBSCRIPTION_CACHE_DIR = getenv("FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR") || "/etc/forkop/subscription-cache";
const PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE = getenv("FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE") || PERSISTENT_SUBSCRIPTION_CACHE_DIR + "/cache-format";
const RULESET_CACHE_UC = LIB_DIR + "/xrust/ruleset_cache.uc";
const PERSISTENT_SUBSCRIPTION_CACHE_FORMAT = getenv("FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT") || "9";
const PENDING_RELOAD_FILE = getenv("FORKOP_PENDING_RELOAD_FILE") || RUNTIME_STATE_DIR + "/reload.pending";
const SERVICE_INIT = getenv("FORKOP_SERVICE_INIT") || "/etc/init.d/forkop";
const NFT_TABLE_NAME = getenv("NFT_TABLE_NAME") || "ForkopTable";
const NFT_COMMON_SET_NAME = getenv("NFT_COMMON_SET_NAME") || "forkop_subnets";
const NFT_COMMON6_SET_NAME = getenv("NFT_COMMON6_SET_NAME") || "forkop_subnets6";
const NFT_PORT_SET_NAME = getenv("NFT_PORT_SET_NAME") || "forkop_ports";
const NFT_IP_PORT_SET_NAME = getenv("NFT_IP_PORT_SET_NAME") || "forkop_ip_ports";
const NFT_IP_PORT6_SET_NAME = getenv("NFT_IP_PORT6_SET_NAME") || "forkop_ip6_ports";
const NFT_INTERFACE_SET_NAME = getenv("NFT_INTERFACE_SET_NAME") || "forkop_interfaces";
const NFT_LOCALV4_SET_NAME = getenv("NFT_LOCALV4_SET_NAME") || "localv4";
const NFT_LOCALV6_SET_NAME = getenv("NFT_LOCALV6_SET_NAME") || "localv6";
const NFT_FAKEIP_MARK = getenv("NFT_FAKEIP_MARK") || "0x04000000";
const SB_SERVICE_MIXED_INBOUND_ADDRESS = getenv("SB_SERVICE_MIXED_INBOUND_ADDRESS") || "127.0.0.1";
const SB_SERVICE_MIXED_INBOUND_PORT = getenv("SB_SERVICE_MIXED_INBOUND_PORT") || "4534";
function as_string(value) {
    return value == null ? "" : "" + value;
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

function command_status(command) {
    let status = int(system(command));
    return status > 255 ? int(status / 256) : status;
}

function command_success_from_args(args) {
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function command_exists(name) {
    return command_success_from_args([ "command", "-v", name ]);
}

function remove_file(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function remove_files(paths) {
    for (let path in paths)
        if (as_string(path) != "")
            remove_file(path);
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function option(section, key, fallback) {
    if (fallback == null)
        fallback = "";

    let value = object_or_empty(section)[key];
    if (value == null)
        return fallback;
    if (type(value) == "array")
        return join(" ", value);
    return as_string(value);
}

function arg_bool(value) {
    value = lc(as_string(value));
    return value == "true" || value == "1" || value == "yes" || value == "on";
}

function bool_option(section, key, fallback) {
    let value = object_or_empty(section)[key];
    return value == null ? !!fallback : arg_bool(value);
}

function whitespace_items(value) {
    let result = [];
    if (type(value) == "array") {
        for (let item in value) {
            item = as_string(item);
            if (item != "")
                push(result, item);
        }
        return result;
    }

    for (let item in split(trim(as_string(value)), /[ \t\r\n]+/))
        if (item != "")
            push(result, item);
    return result;
}

function file_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function parent_dir(path) {
    path = as_string(path);
    let slash = rindex(path, "/");
    return slash >= 0 ? substr(path, 0, slash) : "";
}

function ensure_dir(path) {
    return command_success_from_args([ "mkdir", "-p", path ]);
}

function ensure_parent_dir(path) {
    let dir = parent_dir(path);
    return dir == "" || dir == "." || ensure_dir(dir);
}

function temp_path() {
    return trim(command_output_from_args([ "mktemp" ]));
}

function md5_file(path) {
    let line = trim(command_output_from_args([ "md5sum", as_string(path) ]));
    return length(line) >= 32 ? substr(line, 0, 32) : "";
}

function xrust_version_output() {
    return command_exists(xrust.PATH) ? command_output_from_args([ xrust.PATH, "version" ]) : "";
}

function xray_client_features(output) {
    return join(",", filter([ "transport.xhttp.split", "transport.xhttp.http3", "transport.grpc.multi", "tls.xray-pins", "tls.verify-name" ],
        feature => xrust.has_feature(output, feature)));
}

function module_command(args) {
    let command_args = [ "ucode", "-L", LIB_DIR ];
    for (let arg in args)
        push(command_args, arg);
    return command_from_args(command_args);
}

function module_success(args) {
    return command_status(module_command(args)) == 0;
}

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "forkop", "[" + level + "] " + as_string(message) ]);
}

function module_env_capture(env, args) {
    let output_path = temp_path();
    if (output_path == "")
        return { status: 1, output: "" };

    let status = command_status(command_env(env) + " " + module_command(args) + " >" + shell_quote(output_path) + " 2>&1");
    let output = as_string(fs.readfile(output_path) || "");
    remove_file(output_path);
    return { status, output };
}

function uci_settings() {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function set_service_config_path(path) {
    if (path == "" || index(path, "\n") >= 0)
        return false;
    if (split(fs.readfile(xrust.APPLIED_CONFIG_PATH_FILE) || "", "\n")[0] == path)
        return true;

    if (!ensure_parent_dir(xrust.APPLIED_CONFIG_PATH_FILE))
        return false;
    let staging = trim(command_output_from_args([ "mktemp", xrust.APPLIED_CONFIG_PATH_FILE + ".XXXXXX" ]));
    if (staging == "")
        return false;
    let written = common.write_private_file(staging, path + "\n") != null &&
        fs.rename(staging, xrust.APPLIED_CONFIG_PATH_FILE);
    if (!written)
        remove_file(staging);
    return written;
}

function configure_service(config_path_override) {
    let config_path = config_path_override || option(uci_settings(), "config_path", xrust.CONFIG_PATH);
    // The pinned package still owns the old init script for 2.7.6 rollback.
    // Forkop's core must never autostart through both procd services.
    let legacy_init = "/etc/init.d/sing-box";
    if (file_exists("/etc/rc.d/S99sing-box") &&
        module_success([ LIB_DIR + "/core/packages.uc", "installed", "rust-x" ]) &&
        !command_success_from_args([ legacy_init, "disable" ])) {
        log_message("Failed to disable the Xrust package's legacy boot service", "fatal");
        exit(1);
    }

    if (!set_service_config_path(config_path)) {
        log_message("Failed to stage the Xrust service configuration path", "fatal");
        exit(1);
    }
}

function download_via_proxy_option_for_purpose(purpose) {
    purpose = as_string(purpose || "lists");
    if (purpose == "lists")
        return "download_lists_via_proxy";
    if (purpose == "components")
        return "download_components_via_proxy";
    return "";
}

function download_via_proxy_section_option_for_purpose(purpose) {
    purpose = as_string(purpose || "lists");
    if (purpose == "lists")
        return "download_lists_via_proxy_section";
    if (purpose == "components")
        return "download_components_via_proxy_section";
    return "";
}

function download_via_proxy_section(settings, purpose) {
    let enabled_option = download_via_proxy_option_for_purpose(purpose);
    if (enabled_option == "" || !bool_option(settings, enabled_option, false))
        return "";

    let section_option = download_via_proxy_section_option_for_purpose(purpose);
    let configured = section_option != "" ? option(settings, section_option, "") : "";
    if (configured != "")
        return configured;

    return option(settings, "download_lists_via_proxy_section", "");
}

function service_proxy_port_for_purpose(purpose) {
    return int(SB_SERVICE_MIXED_INBOUND_PORT) + (as_string(purpose || "lists") == "components" ? 1 : 0);
}

function service_proxy_address(settings, purpose) {
    return download_via_proxy_section(settings, purpose) != "" ?
        SB_SERVICE_MIXED_INBOUND_ADDRESS + ":" + service_proxy_port_for_purpose(purpose) : "";
}

function ip_addr_first_inet4(data) {
    for (let line in split(as_string(data), "\n")) {
        let matched = match(line, /inet[ \t]+([0-9.]+)\//);
        if (matched)
            return as_string(matched[1]);
    }
    return "";
}

function network_interface_ipv4(name) {
    let data = command_output_from_args([ "ubus", "call", "network.interface." + as_string(name), "status" ]);
    try {
        let value = json(data);
        let addresses = array_or_empty(object_or_empty(value)["ipv4-address"]);
        if (length(addresses) > 0)
            return as_string(object_or_empty(addresses[0]).address);
    }
    catch (e) {
    }
    return "";
}

function device_ipv4_address_value(device) {
    return ip_addr_first_inet4(command_output_from_args([ "ip", "-4", "addr", "show", "dev", as_string(device) ]));
}

function service_listen_address_value(settings) {
    let configured = option(settings, "service_listen_address", "");
    if (configured != "") {
        log_message("service_listen_address is set manually; automatic listen-address detection is skipped", "warn");
        return configured;
    }

    let address = network_interface_ipv4("lan");
    if (address != "")
        return address;

    for (let iface in whitespace_items(option(settings, "source_network_interfaces", "br-lan"))) {
        address = network_interface_ipv4(iface);
        if (address != "")
            return address;
        address = device_ipv4_address_value(iface);
        if (address != "")
            return address;
    }

    log_message("Failed to determine the listening IP address. Please open an issue to report this problem: https://github.com/Screamshow/forkop-x/issues", "error");
    return "";
}

function subscription_cache_env() {
    return {
        FORKOP_CONFIG_NAME: CONFIG_NAME,
        FORKOP_LIB: LIB_DIR,
        TMP_SING_BOX_FOLDER,
        TMP_RULESET_FOLDER,
        TMP_SUBSCRIPTION_FOLDER,
        FORKOP_RUNTIME_STATE_DIR: RUNTIME_STATE_DIR,
        FORKOP_SUBSCRIPTION_UPDATE_STATE_DIR: SUBSCRIPTION_UPDATE_STATE_DIR,
        FORKOP_SUBSCRIPTION_LINKS_DIR: SUBSCRIPTION_LINKS_DIR,
        FORKOP_SUBSCRIPTION_METADATA_DIR: SUBSCRIPTION_METADATA_DIR,
        FORKOP_OUTBOUND_METADATA_DIR: OUTBOUND_METADATA_DIR,
        FORKOP_SECTION_CACHE_DIR: SECTION_CACHE_DIR,
        FORKOP_RUNTIME_CACHE_FORMAT_FILE: RUNTIME_CACHE_FORMAT_FILE,
        FORKOP_RUNTIME_CACHE_FORMAT: RUNTIME_CACHE_FORMAT,
        FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR: PERSISTENT_SUBSCRIPTION_CACHE_DIR,
        FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE: PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE,
        FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT: PERSISTENT_SUBSCRIPTION_CACHE_FORMAT,
        FORKOP_PENDING_RELOAD_FILE: PENDING_RELOAD_FILE,
        FORKOP_SERVICE_INIT: SERVICE_INIT
    };
}

function subscription_cache_capture(args) {
    let command_args = [ LIB_DIR + "/subscription/cache.uc" ];
    for (let arg in args)
        push(command_args, arg);
    return module_env_capture(subscription_cache_env(), command_args);
}

function log_lines(text, level, prefix) {
    for (let line in split(as_string(text), "\n"))
        if (trim(as_string(line)) != "")
            log_message(as_string(prefix) + as_string(line), level);
}

function last_nonblank_line(path) {
    let result = "";
    let data = as_string(fs.readfile(path) || "");
    for (let line in split(data, "\n"))
        if (trim(as_string(line)) != "")
            result = as_string(line);
    return result;
}

function generator_failure_reason(path, status) {
    let reason = last_nonblank_line(path);
    return reason != "" ? reason : "exit status " + status;
}

function log_file_lines(path, level, prefix) {
    log_lines(fs.readfile(path), level, prefix);
}

function sing_box_check(config_path, output_path) {
    let status = command_status(
        command_from_args([ xrust.PATH, "check", "-c", config_path ]) +
        " >" + shell_quote(output_path) + " 2>&1"
    );
    let reason = status == 0 ? "" : trim(as_string(fs.readfile(output_path) || ""));
    if (status != 0 && reason == "")
        reason = "exit status " + status;
    return { status, reason };
}

function check_with_subscription_recovery(config_path, output_path) {
    let result = sing_box_check(config_path, output_path);
    while (result.status != 0) {
        let cache_dir = config_path + ".section-cache";
        let states = [], paths = [];
        for (let entry in array_or_empty(fs.lsdir(cache_dir))) {
            if (match(entry, /^[A-Za-z0-9_-]+\.json$/) == null) continue;
            let path = cache_dir + "/" + entry;
            let state = common.read_json_file(path);
            if (type(state) != "object") return result;
            push(paths, path); push(states, state);
        }
        let config = common.read_json_file(config_path);
        if (type(config) != "object") return result;
        let repaired = subscription_recovery.recover(config, states, result.reason);
        if (repaired == null) return result;
        // Every retry removes at least one proven subscription node. Nothing
        // is written to the source subscription or live UI/configuration.
        if (common.write_private_json_file(config_path, repaired.config) == null)
            return { status: 1, reason: "unable to write recovered configuration" };
        for (let i = 0; i < length(paths); i++)
            if (common.write_private_json_file(paths[i], repaired.states[i]) == null)
                return { status: 1, reason: "unable to write recovered section cache" };
        for (let tag in repaired.removed)
            log_message("Skipping incompatible subscription outbound '" + tag + "'; source cache preserved", "warn");
        result = sing_box_check(config_path, output_path);
    }
    return result;
}

// A full sing-box check parses every outbound eagerly and can briefly use far
// more memory than the long-running runtime. Call this only when no managed
// sing-box process is alive (the lifecycle owns that serialization).
function validate_config_stage(stage_path) {
    let check_log = temp_path();
    if (as_string(stage_path) == "" || check_log == "") {
        remove_file(check_log);
        return false;
    }

    let result = SINGBOX_CONFIG_FAIL_PHASE == "check"
        ? { status: 1, reason: "injected Xrust configuration check failure" }
        : check_with_subscription_recovery(stage_path, check_log);
    if (result.status != 0)
        log_message("Staged Xrust configuration is invalid: " + result.reason + ". Aborted.", "fatal");
    remove_file(check_log);
    return result.status == 0;
}

function prepare_subscription_caches(prepared, no_refresh) {
    let result = subscription_cache_capture([ "prepare-caches", "runtime", prepared ? "1" : "0", no_refresh ? "1" : "0" ]);
    if (result.status != 0) {
        log_message("Subscription caches are not ready for sing-box config generation. Aborted.", "fatal");
        log_lines(result.output, "debug", "subscription cache: ");
        return null;
    }
    return trim(result.output);
}

function save_config_file(temp_file_path, config_path) {
    if (!fs.chmod(temp_file_path, 0600) ||
        (file_exists(config_path) && !fs.chmod(config_path, 0600)))
        return false;
    let current_hash = md5_file(config_path);
    let temp_hash = md5_file(temp_file_path);

    if (current_hash != temp_hash) {
        log_message("Xrust configuration changed; updating " + config_path, "info");
        if (!ensure_parent_dir(config_path))
            return false;
        return command_success_from_args([ "mv", "-f", temp_file_path, config_path ]);
    }

    log_message("Xrust configuration is unchanged", "info");
    remove_file(temp_file_path);
    return true;
}

function discard_config_stage(stage_path) {
    stage_path = as_string(stage_path);
    if (stage_path == "")
        return false;
    remove_file(stage_path + ".hot-plan");
    remove_file(stage_path + ".rulesets");
    remove_file(stage_path);
    command_success_from_args([ "rm", "-rf", stage_path + ".section-cache" ]);
    return true;
}

function restore_config_stage(backup_path, applied_path) {
    if (applied_path)
        return common.copy_private_file_atomic(backup_path, applied_path);
    let config_path = option(uci_settings(), "config_path", "");
    backup_path = as_string(backup_path);
    return config_path != "" && file_exists(backup_path) && fs.chmod(backup_path, 0600) &&
        command_success_from_args([ "mv", "-f", backup_path, config_path ]);
}

function finish_section_cache_transaction(transaction, restore) {
    if (parent_dir(transaction) != parent_dir(SECTION_CACHE_DIR) ||
        index(transaction, SECTION_CACHE_DIR + ".reload.") != 0)
        return false;
    if (fs.stat(transaction) == null)
        return true;
    if (restore) {
        let candidate = transaction + "/candidate";
        let previous = transaction + "/previous";
        if (!fs.rename(SECTION_CACHE_DIR, candidate))
            return false;
        if (fs.stat(previous) != null && !fs.rename(previous, SECTION_CACHE_DIR)) {
            fs.rename(candidate, SECTION_CACHE_DIR);
            return false;
        }
    }
    if (!command_success_from_args([ "rm", "-rf", transaction ]))
        log_message("Section cache is ready; could not remove recovery files at " + transaction, "warn");
    return true;
}

function publish_section_cache(temp_config_path, retained_transaction) {
    let source_dir = as_string(temp_config_path) + ".section-cache";
    let entries = fs.lsdir(source_dir);
    if (type(entries) != "array")
        return fs.stat(source_dir) == null;
    if (!ensure_parent_dir(SECTION_CACHE_DIR))
        return false;

    // Build the complete replacement beside the live cache, on the same
    // filesystem. Never consume generated files before publication succeeds.
    let transaction = retained_transaction;
    if (transaction) {
        if (parent_dir(transaction) != parent_dir(SECTION_CACHE_DIR) ||
            index(transaction, SECTION_CACHE_DIR + ".reload.") != 0 || !fs.mkdir(transaction, 0700))
            return false;
    }
    else
        transaction = trim(command_output_from_args([
            "mktemp", "-d", parent_dir(SECTION_CACHE_DIR) + "/.section-cache.XXXXXX"
        ]));
    if (transaction == "")
        return false;
    let candidate = transaction + "/candidate";
    let previous = transaction + "/previous";
    let prepared = fs.chmod(transaction, 0700) && fs.mkdir(candidate, 0700);
    for (let entry in entries) {
        if (!prepared)
            break;
        entry = as_string(entry);
        if (entry != runtime_dns.APPLIED_DNS_CACHE_NAME && match(entry, /^[A-Za-z0-9_-]+\.json$/) == null)
            continue;

        let source = source_dir + "/" + entry;
        let data = fs.readfile(source);
        prepared = data != null && common.write_private_file(candidate + "/" + entry, data) != null;
    }
    let had_previous = fs.stat(SECTION_CACHE_DIR) != null;
    if (!prepared || (had_previous &&
        (!common.secure_private_dir(SECTION_CACHE_DIR) || !fs.rename(SECTION_CACHE_DIR, previous)))) {
        command_success_from_args([ "rm", "-rf", transaction ]);
        return false;
    }
    let published = SINGBOX_CONFIG_FAIL_PHASE != "cache-publish" && fs.rename(candidate, SECTION_CACHE_DIR);
    if (!published || SINGBOX_CONFIG_FAIL_PHASE == "cache-after-publish") {
        // Keep recovery files if withdrawing the candidate or restoring the
        // previous directory fails; do not delete the only surviving old set.
        if ((published && !fs.rename(SECTION_CACHE_DIR, candidate)) ||
            (had_previous && !fs.rename(previous, SECTION_CACHE_DIR))) {
            log_message("Failed to restore section cache; recovery files retained at " + transaction, "fatal");
            return false;
        }
        command_success_from_args([ "rm", "-rf", transaction ]);
        return false;
    }
    // Cleanup failure is not a failed publication: the complete new set is
    // already live. Leave private leftovers rather than report a false rollback.
    let cleanup = retained_transaction ? [ source_dir ] : [ source_dir, transaction ];
    if (!command_success_from_args([ "rm", "-rf", ...cleanup ]))
        log_message("Section cache published; failed to remove private temporary files", "warn");
    return true;
}

function commit_config_stage(stage_path, backup_path, applied_path) {
    let config_path = applied_path || option(uci_settings(), "config_path", "");
    stage_path = as_string(stage_path);
    backup_path = as_string(backup_path);
    if (config_path == "" || !file_exists(stage_path) || backup_path == "")
        return false;

    // The reload lifecycle creates this backup before the first live config
    // change. It is consumed only after nft and sing-box reach the same state.
    if (file_exists(config_path)) {
        if (!fs.chmod(config_path, 0600) ||
            (file_exists(backup_path) && !fs.chmod(backup_path, 0600)) ||
            !command_success_from_args([ "cp", "-p", config_path, backup_path ]) ||
            !fs.chmod(backup_path, 0600))
            return false;
    }
    else if (getenv("FORKOP_LIFECYCLE_LIST_BOOTSTRAP") != "1")
        return false;
    if (!save_config_file(stage_path, config_path))
        return false;
    if (!publish_section_cache(stage_path))
        return false;
    return true;
}

function replace_dns_server(config, replacement) {
    let servers = array_or_empty(object_or_empty(config.dns).servers);
    for (let i = 0; i < length(servers); i++) {
        let current = object_or_empty(servers[i]);
        if (current.tag == replacement.tag) {
            if (current.type != replacement.type)
                return false;
            servers[i] = replacement;
            return true;
        }
    }
    return false;
}

function patch_dns_config(state_path, prepare_only) {
    let applied = common.read_json_file(runtime_dns.DNS_FAILOVER_STATE_FILE);
    let candidate = runtime_dns.failover_selection(applied, common.read_json_file(state_path));
    if (candidate == null) {
        log_message("DNS failover state does not match the applied DNS configuration", "warn");
        exit(2);
    }

    let config_path = as_string(applied.config_path || option(uci_settings(), "config_path", ""));
    let config = common.read_json_file(config_path);
    if (config_path == "" || type(config) != "object") {
        log_message("Cannot read the current Xrust configuration for DNS failover", "error");
        exit(1);
    }

    let main = runtime_dns.server_config_from_state(candidate);
    let bootstrap = runtime_dns.bootstrap_config_from_state(candidate);
    if (main.unsupported || bootstrap.unsupported || !replace_dns_server(config, main) || !replace_dns_server(config, bootstrap)) {
        log_message("Cannot locate or build canonical DNS servers for failover", "error");
        exit(1);
    }

    let servers = config.dns.servers;
    for (let i = 0; i < length(servers); i++) {
        let server = servers[i];
        if (server.type == "udp" && (server.tag == runtime_dns.NTP_BOOTSTRAP_FALLBACK_TAG ||
            (server.tag == runtime_constants.NTP_DNS_SERVER_TAG && server.detour == null)))
            server.server = bootstrap.server;
        if (index(as_string(server.tag), runtime_dns.TUNNEL_DNS_TAG_PREFIX) != 0)
            continue;
        let section_name = substr(server.tag, length(runtime_dns.TUNNEL_DNS_TAG_PREFIX));
        // Only inherited DNS follows the main resolver. Explicit tunnel
        // resolvers are already materialized in the working core config.
        let inherited = type(applied.inherited_tunnel_dns) == "array"
            ? index(applied.inherited_tunnel_dns, server.tag) >= 0
            : connections.native_tunnel_dns_address(uci_core.get_all(CONFIG_NAME, section_name)) == "";
        if (inherited)
            servers[i] = { ...main, tag: server.tag, detour: server.detour };
    }

    let backup_path = temp_path();
    let temp_config = temp_path();
    if (backup_path == "" || temp_config == "" ||
        common.write_private_file(backup_path, fs.readfile(config_path)) == null ||
        !common.write_private_json_file(temp_config, config)) {
        remove_files([ backup_path, temp_config ]);
        exit(1);
    }

    let check_log = temp_path();
    let check_result = check_log == ""
        ? { status: 1, reason: "unable to create check output file" }
        : sing_box_check(temp_config, check_log);
    if (check_result.status != 0) {
        log_message("DNS failover produced an invalid Xrust configuration: " + check_result.reason, "error");
        remove_files([ backup_path, temp_config, check_log ]);
        exit(1);
    }
    remove_file(check_log);

    let changed = md5_file(config_path) != md5_file(temp_config);
    if (prepare_only) {
        print(changed ? "1" : "0", "\t", backup_path, "\t", temp_config, "\n");
        return;
    }
    if (!changed) {
        remove_files([ backup_path, temp_config ]);
        print("0\n");
        return;
    }

    let published = common.copy_private_file_atomic(temp_config, config_path);
    remove_file(temp_config);
    if (!published) {
        remove_file(backup_path);
        exit(1);
    }
    print("1\t", backup_path, "\n");
}

function restore_dns_config(backup_path, config_path) {
    config_path = config_path || option(uci_settings(), "config_path", "");
    if (config_path == "" || !file_exists(backup_path) || !fs.chmod(backup_path, 0600))
        return false;

    // Keep the recovery copy until lifecycle has confirmed the old core started.
    return common.copy_private_file_atomic(backup_path, config_path);
}

function init_config(populate_nft, caches_prepared, no_refresh, prepared_deferred_sections, stage_path, validate_now, applied_path) {
    let settings = uci_settings();
    let config_path = applied_path || option(settings, "config_path", "");
    if (config_path == "") {
        log_message("sing-box config path is empty. Aborted.", "fatal");
        exit(1);
    }

    let mwan3_active = module_success([ LIB_DIR + "/config/validator.uc", "mwan3-is-active" ]);
    let output_interface = option(settings, "output_network_interface", "");
    if (mwan3_active && output_interface != "")
        log_message("mwan3 is active and Output Network Interface is set to '" + output_interface + "'; sing-box egress is pinned to this interface", "warn");
    else if (mwan3_active)
        log_message("mwan3 is active; disabling sing-box auto_detect_interface so mwan3 can control egress routing", "warn");

    let deferred_sections = trim(as_string(prepared_deferred_sections));
    if (deferred_sections == "") {
        deferred_sections = prepare_subscription_caches(caches_prepared, no_refresh);
        if (deferred_sections == null)
            exit(1);
    }

    let temp_config = temp_path();
    let runtime_log = temp_path();
    if (temp_config == "" || runtime_log == "") {
        remove_files([ temp_config, runtime_log ]);
        exit(1);
    }

    // This invocation cannot change the installed core; use one capability
    // snapshot for both generator arguments instead of executing version twice.
    let version_output = xrust_version_output();
    let core_version = xrust.version_from_output(version_output);
    if (core_version == "") {
        log_message("Could not identify the installed Xrust client", "fatal");
        discard_config_stage(temp_config);
        remove_file(runtime_log);
        exit(1);
    }
    let generate_status = command_status(
        command_env({ FORKOP_APPLIED_XRUST_CONFIG_PATH: config_path }) + " " +
        module_command([
            LIB_DIR + "/xrust/generator.uc",
            "generate-config",
            temp_config,
            service_listen_address_value(settings),
            mwan3_active ? "1" : "0",
            xrust.has_feature(version_output, "transport.xhttp") ? "1" : "0",
            deferred_sections,
            core_version,
            xrust.has_feature(version_output, "outbound.trojan") ? "1" : "0",
            xrust.has_feature(version_output, "sniff.bittorrent-extended") ? "1" : "0",
            xrust.has_feature(version_output, "outbound.vless.encryption") ? "1" : "0",
            xray_client_features(version_output)
        ]) + " >" + shell_quote(runtime_log) + " 2>&1"
    );
    if (SINGBOX_CONFIG_FAIL_PHASE == "generate")
        generate_status = 1;
    if (generate_status != 0) {
        let reason = generator_failure_reason(runtime_log, generate_status);
        let retryable = generate_status == runtime_constants.PROVIDER_DNS_UNAVAILABLE;
        log_message("Failed to generate Xrust configuration: " + reason, retryable ? "warn" : "fatal");
        discard_config_stage(temp_config);
        remove_file(runtime_log);
        exit(retryable ? generate_status : 1);
    }
    log_file_lines(runtime_log, "warn", "sing-box config generator: ");

    // Cold start can bootstrap missing remote lists in its background worker.
    // A live transition must resolve every newly declared list before ACK:
    // refreshing the old manifest cannot discover a new UCI list declaration.
    // Existing valid caches remain offline; a failed download rejects the stage.
    // The preparation config has no remote rulesets. Materializing its empty
    // declaration would prune the existing last-known-good ruleset cache.
    if (getenv("FORKOP_LIFECYCLE_LIST_BOOTSTRAP") != "1" &&
        !module_success([ RULESET_CACHE_UC, "materialize-config", temp_config,
            as_string(stage_path) != "" ? "required" : "cache-only",
            as_string(stage_path) != "" ? "stage" : "" ])) {
        log_message("[rule-set-unavailable] A required rule-set could not be downloaded or validated. Settings were not applied; the previous running configuration is preserved.", "error");
        discard_config_stage(temp_config);
        remove_file(runtime_log);
        exit(1);
    }

    if (validate_now !== false) {
        let check_result = SINGBOX_CONFIG_FAIL_PHASE == "check"
            ? { status: 1, reason: "injected Xrust configuration check failure" }
            : check_with_subscription_recovery(temp_config, runtime_log);
        if (check_result.status != 0) {
            log_message("Generated Xrust configuration is invalid: " + check_result.reason + ". Aborted.", "fatal");
            discard_config_stage(temp_config);
            remove_file(runtime_log);
            exit(1);
        }
    }

    if (populate_nft && !module_success([
        LIB_DIR + "/nft/apply.uc",
        "nft-populate-runtime-sets-from-uci",
        "1",
        deferred_sections,
        NFT_TABLE_NAME,
        NFT_COMMON_SET_NAME,
        NFT_PORT_SET_NAME,
        NFT_IP_PORT_SET_NAME,
        NFT_INTERFACE_SET_NAME,
        NFT_LOCALV4_SET_NAME,
        NFT_FAKEIP_MARK,
        NFT_COMMON6_SET_NAME,
        NFT_IP_PORT6_SET_NAME,
        NFT_LOCALV6_SET_NAME
    ])) {
        log_message("Failed to update nftables runtime sets from the generated Xrust configuration. Aborted.", "fatal");
        discard_config_stage(temp_config);
        remove_file(runtime_log);
        exit(1);
    }

    if (as_string(stage_path) != "") {
        if (!ensure_parent_dir(stage_path)) {
            discard_config_stage(temp_config);
            remove_file(runtime_log);
            exit(1);
        }
        for (let suffix in [ ".section-cache", ".rulesets" ]) {
            if (file_exists(temp_config + suffix) && !fs.rename(temp_config + suffix, stage_path + suffix)) {
                discard_config_stage(temp_config);
                discard_config_stage(stage_path);
                remove_file(runtime_log);
                exit(1);
            }
        }
        if (!command_success_from_args([ "mv", "-f", temp_config, stage_path ])) {
            discard_config_stage(temp_config);
            discard_config_stage(stage_path);
            remove_file(runtime_log);
            exit(1);
        }
        remove_file(runtime_log);
        print(deferred_sections, "\n");
        return;
    }

    if (!save_config_file(temp_config, config_path)) {
        remove_file(runtime_log);
        exit(1);
    }
    if (!publish_section_cache(temp_config)) {
        log_message("Failed to publish sing-box dashboard cache", "error");
        remove_file(runtime_log);
        exit(1);
    }
    remove_file(runtime_log);
    print(deferred_sections, "\n");
}

let mode = ARGV[0] || "";

if (mode == "configure-service")
    configure_service(ARGV[1]);
else if (mode == "set-service-config-path")
    exit(set_service_config_path(ARGV[1] || "") ? 0 : 1);
else if (mode == "publish-reload-config") {
    let path = ARGV[2] || "";
    exit(path != "" && ensure_parent_dir(path) && common.copy_private_file_atomic(ARGV[1], path) ? 0 : 1);
}
else if (mode == "init-config")
    init_config(arg_bool(ARGV[1] || "1"), arg_bool(ARGV[2] || "0"), arg_bool(ARGV[3] || "0"), ARGV[4] || "", "", true, ARGV[5]);
else if (mode == "prepare-config-stage")
    // The lifecycle validates this staged file after stopping the old runtime.
    // That ordering avoids a high transient memory peak on small routers.
    init_config(arg_bool(ARGV[1] || "0"), arg_bool(ARGV[2] || "0"), arg_bool(ARGV[3] || "0"), ARGV[4] || "", ARGV[5] || "", false, ARGV[6]);
else if (mode == "commit-config-stage")
    exit(commit_config_stage(ARGV[1] || "", ARGV[2] || "", ARGV[3]) ? 0 : 1);
else if (mode == "commit-ruleset-stage")
    exit(ARGV[1] && module_success([ RULESET_CACHE_UC, "commit-staged", ARGV[1] ]) ? 0 : 1);
else if (mode == "restore-config-stage")
    exit(restore_config_stage(ARGV[1] || "", ARGV[2]) ? 0 : 1);
else if (mode == "discard-config-stage")
    exit(discard_config_stage(ARGV[1] || "") ? 0 : 1);
else if (mode == "publish-section-cache")
    exit(publish_section_cache(ARGV[1] || "", ARGV[2]) ? 0 : 1);
else if (mode == "finish-section-cache")
    exit(ARGV[1] && finish_section_cache_transaction(ARGV[1], ARGV[2] == "restore") ? 0 : 1);
else if (mode == "validate-config-stage")
    exit(validate_config_stage(ARGV[1] || "") ? 0 : 1);
else if (mode == "save-config-file-fixture")
    exit(save_config_file(ARGV[1] || "", ARGV[2] || "") ? 0 : 1);
else if (mode == "publish-section-cache-fixture")
    exit(publish_section_cache(ARGV[1] || "") ? 0 : 1);
else if (mode == "check-config-fixture") {
    let result = sing_box_check(ARGV[1] || "", ARGV[2] || "");
    if (result.reason != "")
        print(result.reason, "\n");
    exit(result.status);
}
else if (mode == "generator-failure-reason-fixture")
    print(generator_failure_reason(ARGV[1] || "", int(ARGV[2] || "1")), "\n");
else if (mode == "patch-dns-config")
    patch_dns_config(ARGV[1] || "");
else if (mode == "prepare-dns-config")
    patch_dns_config(ARGV[1] || "", true);
else if (mode == "restore-dns-config")
    exit(restore_dns_config(ARGV[1] || "", ARGV[2] || "") ? 0 : 1);
else if (mode == "service-proxy-address")
    print(service_proxy_address(uci_settings(), ARGV[1] || "lists"), "\n");
else if (mode == "service-listen-address") {
    let address = service_listen_address_value(uci_settings());
    if (address == "")
        exit(1);
    print(address, "\n");
}
else if (mode == "device-ipv4-address") {
    let address = device_ipv4_address_value(ARGV[1]);
    if (address == "")
        exit(1);
    print(address, "\n");
}
else if (mode == "ip-addr-first-inet4")
    print(ip_addr_first_inet4(fs.readfile("/dev/stdin")), "\n");
else if (mode == "version")
    print(xrust.version_from_output(xrust_version_output()), "\n");
else if (mode == "build-version")
    print(xrust.build_version(xrust.version_from_output(xrust_version_output())), "\n");
else if (mode == "version-output")
    print(xrust_version_output());
else {
    warn("Usage: xrust/runtime.uc <operation> ...\n");
    exit(1);
}
