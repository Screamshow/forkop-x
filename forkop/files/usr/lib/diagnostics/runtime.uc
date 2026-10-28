#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let process_memory = require("core.process_memory");
let constants = require("core.constants");
let core_ip = require("core.ip");
let uci_core = require("core.uci");
let runtime_dns = require("singbox.dns");
let netstat = require("core.netstat");

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || constants.FORKOP_CONFIG_NAME || "forkop";
const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const FORKOP_VERSION = getenv("FORKOP_VERSION") || constants.FORKOP_VERSION || "";
const FORKOP_CONFIG = getenv("FORKOP_CONFIG") || constants.FORKOP_CONFIG || "/etc/config/" + CONFIG_NAME;
const FORKOP_SERVICE_NAME = getenv("FORKOP_SERVICE_NAME") || constants.FORKOP_SERVICE_NAME || "forkop";
// The core's resident memory is spread over two procd services: forkop-tailscale
// runs the very same core binary. Forkop's own workers likewise sit in more than
// one service. A name procd does not know is a component that is not installed.
const CORE_SERVICE_NAMES = [ "sing-box", "forkop-tailscale" ];
const FORKOP_SERVICE_NAMES = [ FORKOP_SERVICE_NAME, "forkop-torrserver-direct" ];
const FORKOP_LUCI_VIEW_DIR = getenv("FORKOP_LUCI_VIEW_DIR") || constants.FORKOP_LUCI_VIEW_DIR || "/www/luci-static/resources/view/forkop";
const RUNTIME_STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const SYSTEM_INFO_CACHE_FILE = getenv("FORKOP_SYSTEM_INFO_CACHE_FILE") || RUNTIME_STATE_DIR + "/system-info.json";
const SYSTEM_INFO_CACHE_TTL = int(getenv("FORKOP_SYSTEM_INFO_CACHE_TTL") || "3600");
const TMP_SING_BOX_FOLDER = getenv("TMP_SING_BOX_FOLDER") || constants.TMP_SING_BOX_FOLDER || "/tmp/sing-box";
const SECTION_CACHE_DIR = getenv("FORKOP_SECTION_CACHE_DIR") || RUNTIME_STATE_DIR + "/section-cache";
const CHECK_PROXY_IP_DOMAIN = getenv("CHECK_PROXY_IP_DOMAIN") || constants.CHECK_PROXY_IP_DOMAIN || "ip.podkop.fyi";
const FAKEIP_TEST_DOMAIN = getenv("FAKEIP_TEST_DOMAIN") || constants.FAKEIP_TEST_DOMAIN || "fakeip.podkop.fyi";
const RT_TABLE_NAME = getenv("RT_TABLE_NAME") || constants.RT_TABLE_NAME || "forkop";
const NFT_TABLE_NAME = getenv("NFT_TABLE_NAME") || constants.NFT_TABLE_NAME || "ForkopTable";
const NFT_FAKEIP_MARK = getenv("NFT_FAKEIP_MARK") || constants.NFT_FAKEIP_MARK || "0x04000000";
const NFT_COMMON_SET_NAME = getenv("NFT_COMMON_SET_NAME") || constants.NFT_COMMON_SET_NAME || "forkop_subnets";
const NFT_PORT_SET_NAME = getenv("NFT_PORT_SET_NAME") || constants.NFT_PORT_SET_NAME || "forkop_ports";
const NFT_IP_PORT_SET_NAME = getenv("NFT_IP_PORT_SET_NAME") || constants.NFT_IP_PORT_SET_NAME || "forkop_ip_ports";
const NFT_INTERFACE_SET_NAME = getenv("NFT_INTERFACE_SET_NAME") || constants.NFT_INTERFACE_SET_NAME || "forkop_interfaces";
const NFT_DISCORD_SET_NAME = getenv("NFT_DISCORD_SET_NAME") || constants.NFT_DISCORD_SET_NAME || "forkop_discord_subnets";
const NFT_LOCALV4_SET_NAME = getenv("NFT_LOCALV4_SET_NAME") || constants.NFT_LOCALV4_SET_NAME || "localv4";
const SB_DNS_INBOUND_ADDRESS = getenv("SB_DNS_INBOUND_ADDRESS") || constants.SB_DNS_INBOUND_ADDRESS || "127.0.0.42";
const SB_TPROXY_INBOUND6_ADDRESS = getenv("SB_TPROXY_INBOUND6_ADDRESS") || constants.SB_TPROXY_INBOUND6_ADDRESS || "::1";
const SB_TPROXY_INBOUND_PORT = getenv("SB_TPROXY_INBOUND_PORT") || constants.SB_TPROXY_INBOUND_PORT || "1602";
const SB_CLASH_API_CONTROLLER_PORT = getenv("SB_CLASH_API_CONTROLLER_PORT") || constants.SB_CLASH_API_CONTROLLER_PORT || "9090";
const SING_BOX_BIN_PATH = getenv("FORKOP_DIAGNOSTICS_SING_BOX_BIN_PATH") || "/usr/bin/sing-box";
const CLOUDFLARE_OCTETS = getenv("CLOUDFLARE_OCTETS") || constants.CLOUDFLARE_OCTETS || "8.47 162.159 188.114";
const ZAPRET_LEGACY_DEFAULT_NFQWS_OPT = getenv("ZAPRET_LEGACY_DEFAULT_NFQWS_OPT") || constants.ZAPRET_LEGACY_DEFAULT_NFQWS_OPT || "";
const DEFAULT_LATENCY_TEST_URL = getenv("DEFAULT_LATENCY_TEST_URL") || "https://www.gstatic.com/generate_204";
const RUNTIME_STABLE_MIN_AGE = getenv("FORKOP_RUNTIME_STABLE_MIN_AGE") || "2";
const AUTOMATIC_LATENCY_TEST_LOCK_DIR = getenv("FORKOP_AUTOMATIC_LATENCY_TEST_LOCK_DIR") || RUNTIME_STATE_DIR + "/automatic-latency-test.lock";
const RELOAD_LOCK_DIR = getenv("FORKOP_RELOAD_LOCK_DIR") || "/var/run/forkop.reload.lock";
const PENDING_RELOAD_FILE = getenv("FORKOP_PENDING_RELOAD_FILE") || "/var/run/forkop/reload.pending";
const SERVICE_INIT = getenv("FORKOP_SERVICE_INIT") || "/etc/init.d/forkop";
const AUTOMATIC_LATENCY_BATCH_SIZE = int(getenv("FORKOP_AUTOMATIC_LATENCY_BATCH_SIZE") || "4");
const AUTOMATIC_LATENCY_BATCH_PAUSE = getenv("FORKOP_AUTOMATIC_LATENCY_BATCH_PAUSE") || "1";
const AUTOMATIC_LATENCY_PENDING_FILE = getenv("FORKOP_AUTOMATIC_LATENCY_PENDING_FILE") || "/etc/forkop/automatic-latency-test.pending";
const AUTOMATIC_LATENCY_PENDING_FORMAT = "1";
const AUTOMATIC_LATENCY_RETRY_BASE_SECONDS = int(getenv("FORKOP_AUTOMATIC_LATENCY_RETRY_BASE_SECONDS") || "300");
const AUTOMATIC_LATENCY_MAX_FAILURES = int(getenv("FORKOP_AUTOMATIC_LATENCY_MAX_FAILURES") || "5");
const AUTOMATIC_LATENCY_CLASH_READY_ATTEMPTS = int(getenv("FORKOP_AUTOMATIC_LATENCY_CLASH_READY_ATTEMPTS") || "15");

const STATUS_UC = LIB_DIR + "/diagnostics/status.uc";
const HELPERS_UC = LIB_DIR + "/core/helpers.uc";
const DNS_APPLY_UC = LIB_DIR + "/dns/apply.uc";
const SERVICE_STATE_UC = getenv("FORKOP_SERVICE_STATE_UC") || LIB_DIR + "/service/state.uc";
const DIAGNOSTICS_RUNTIME_UC = getenv("FORKOP_DIAGNOSTICS_RUNTIME_UC") || LIB_DIR + "/diagnostics/runtime.uc";
const SERVICE_UI_UC = LIB_DIR + "/service/ui.uc";
const SUBSCRIPTION_CACHE_UC = LIB_DIR + "/subscription/cache.uc";
const SINGBOX_RUNTIME_UC = LIB_DIR + "/singbox/runtime.uc";
const ZAPRET_RUNTIME_UC = LIB_DIR + "/providers/zapret/runtime.uc";
const ZAPRET2_RUNTIME_UC = LIB_DIR + "/providers/zapret2/runtime.uc";
const ZAPRET_VALIDATOR_UC = LIB_DIR + "/providers/zapret/validator.uc";
const ZAPRET2_VALIDATOR_UC = LIB_DIR + "/providers/zapret2/validator.uc";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function arg_number(value) {
    value = as_string(value);
    return value == "" || match(value, /[^0-9-]/) != null ? 0 : int(value, 10);
}

function arg_bool(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
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

function normalize_status(status) {
    status = int(status);
    return status > 255 ? int(status / 256) : status;
}

function command_status(command) {
    return normalize_status(system(command));
}

function command_capture(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return { status: 1, output: "" };

    let data = pipe.read("all");
    let status = normalize_status(pipe.close());
    return { status, output: data == null ? "" : as_string(data) };
}

function command_output(command) {
    let result = command_capture(command);
    return result.status == 0 ? result.output : "";
}

function command_success(command) {
    return command_status(command + " >/dev/null 2>&1") == 0;
}

function command_output_from_args(args) {
    return command_output(command_from_args(args) + " 2>/dev/null");
}

function command_success_from_args(args) {
    return command_success(command_from_args(args));
}

function command_exists(name) {
    return command_success_from_args([ "command", "-v", as_string(name) ]);
}

function module_args(module_path, args) {
    let result = [ "ucode", "-L", LIB_DIR, module_path ];
    for (let arg in args)
        push(result, arg);
    return result;
}

function module_capture(module_path, args) {
    return command_capture(command_from_args(module_args(module_path, args)));
}

function module_capture_stdin(module_path, args, input) {
    let tmp = trim(command_output_from_args([ "mktemp" ]));
    if (tmp == "")
        return { status: 1, output: "" };

    if (!fs.writefile(tmp, as_string(input))) {
        fs.unlink(tmp);
        return { status: 1, output: "" };
    }

    let result = command_capture(command_from_args(module_args(module_path, args)) + " < " + shell_quote(tmp));
    fs.unlink(tmp);
    return result;
}

function module_output(module_path, args) {
    let result = module_capture(module_path, args);
    return result.status == 0 ? result.output : "";
}

function module_output_stdin(module_path, args, input) {
    let result = module_capture_stdin(module_path, args, input);
    return result.status == 0 ? result.output : "";
}

function module_success(module_path, args) {
    return command_success(command_from_args(module_args(module_path, args)));
}

function module_passthrough(module_path, args) {
    let result = module_capture(module_path, args);
    if (result.output != "")
        print(result.output);
    return result.status;
}

function status_capture(args, input) {
    if (input != null)
        return module_capture_stdin(STATUS_UC, args, input);
    return command_capture(command_from_args(module_args(STATUS_UC, args)));
}

function status_output(args, input) {
    let result = status_capture(args, input);
    return result.status == 0 ? result.output : "";
}

function status_success(args, input) {
    return status_capture(args, input).status == 0;
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function read_stdin() {
    let input = fs.open("/dev/stdin", "r");
    if (!input)
        return "";
    let data = input.read("all");
    input.close();
    return data == null ? "" : as_string(data);
}

function read_json_file(path) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        return null;
    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function parse_json_or_null(value) {
    try {
        return json(as_string(value));
    }
    catch (e) {
        return null;
    }
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function option(section, key, fallback) {
    if (fallback == null)
        fallback = "";
    let value = object_or_empty(section)[key];
    if (value == null)
        return as_string(fallback);
    if (type(value) == "array")
        return join(" ", value);
    return as_string(value);
}

function list_option(section, key) {
    let value = object_or_empty(section)[key];
    if (type(value) == "array")
        return value;
    if (as_string(value) != "")
        return [ as_string(value) ];
    return [];
}

function bool_option(section, key, fallback) {
    return arg_bool(option(section, key, fallback ? "1" : "0"));
}

function settings() {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function uci_sections(type_name) {
    return uci_core.section_objects(CONFIG_NAME, type_name);
}

function uci_get(path) {
    return uci_core.get(path);
}

function uci_show(path) {
    return uci_core.exists(path);
}

function append_unique(values, value) {
    value = as_string(value);
    if (value == "")
        return;
    for (let item in values)
        if (item == value)
            return;
    push(values, value);
}

function config_section_types(config_path) {
    let data = as_string(fs.readfile(config_path) || "");
    let result = [];

    for (let line in split(data, "\n")) {
        line = trim(as_string(line));
        if (substr(line, 0, 7) != "config ")
            continue;

        let fields = split(line, /[ \t\r\n]+/);
        if (length(fields) >= 2)
            append_unique(result, replace(as_string(fields[1]), /['"]/g, ""));
    }

    return result;
}

function uci_show_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function append_uci_show_option(lines, package_name, section_name, key, value) {
    if (key == ".name" || key == ".type")
        return;

    let path = as_string(package_name) + "." + as_string(section_name) + "." + as_string(key) + "=";
    if (type(value) == "array") {
        for (let item in value)
            push(lines, path + uci_show_quote(item));
    }
    else {
        push(lines, path + uci_show_quote(value));
    }
}

function uci_show_data(package_name, config_path) {
    let lines = [];
    package_name = as_string(package_name);
    for (let type_name in config_section_types(config_path)) {
        for (let section in uci_core.section_objects(package_name, type_name)) {
            let name = as_string(section[".name"] || "");
            if (name == "")
                continue;
            push(lines, package_name + "." + name + "=" + as_string(section[".type"] || type_name));
            for (let key, value in section)
                append_uci_show_option(lines, package_name, name, key, value);
        }
    }
    return join("\n", lines) + "\n";
}

function network_show_data() {
    return uci_show_data("network", "/etc/config/network");
}

function file_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function file_executable(path) {
    return command_success_from_args([ "test", "-x", as_string(path) ]);
}

function ensure_dir(path) {
    return command_success_from_args([ "mkdir", "-p", as_string(path) ]);
}

function remove_file(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function first_line_value(path, fallback) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        return as_string(fallback);
    let line = split(as_string(data), "\n")[0];
    line = replace(as_string(line), /\r$/, "");
    return line != "" ? line : as_string(fallback);
}

function stdout_is_tty() {
    return command_success_from_args([ "test", "-t", "1" ]);
}

function nolog(message) {
    if (!stdout_is_tty())
        return;
    let timestamp = replace(command_output_from_args([ "date", "+%Y-%m-%d %H:%M:%S" ]), /[\r\n]+$/g, "");
    print("\033[0;36m[", timestamp, "]\033[0m \033[0;32m", as_string(message), "\033[0m\n");
}

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "forkop", "[" + level + "] " + as_string(message) ]);
}

function valid_ipv4(value) {
    return core_ip.valid_ipv4(value, true, false);
}

function words(value) {
    value = trim(as_string(value));
    return value == "" ? [] : split(value, /[ \t\r\n]+/);
}

function allowed_ips_default_routes(value) {
    let result = [];
    for (let allowed in words(value)) {
        if (allowed == "0.0.0.0/0" || allowed == "::/0")
            push(result, allowed);
    }
    return result;
}

function helper_output(mode, args) {
    let full = [ mode ];
    for (let arg in args)
        push(full, arg);
    return replace(module_output(HELPERS_UC, full), /[\r\n]+$/g, "");
}

function cleanup_check_proxy_dir(dir) {
    dir = as_string(dir);
    let prefix = TMP_SING_BOX_FOLDER + "/check-proxy-";
    if (substr(dir, 0, length(prefix)) == prefix)
        command_success_from_args([ "rm", "-rf", dir ]);
}

function check_proxy() {
    let sing_box_config_path = option(settings(), "config_path", "");
    if (!command_exists("sing-box")) {
        nolog("sing-box is not installed");
        return 1;
    }
    if (!file_exists(sing_box_config_path)) {
        nolog("Configuration file not found");
        return 1;
    }

    nolog("Checking sing-box configuration...");
    if (!command_success_from_args([ "sing-box", "-c", sing_box_config_path, "check" ])) {
        nolog("Invalid configuration");
        return 1;
    }

    print(status_output([ "mask-sing-box-config", sing_box_config_path ], null));
    nolog("Checking proxy connection...");

    let check_proxy_dir = TMP_SING_BOX_FOLDER + "/check-proxy-" + clock()[0] + "-" + clock()[1];
    let check_proxy_config = check_proxy_dir + "/config.json";
    let check_proxy_cache = check_proxy_dir + "/cache.db";

    cleanup_check_proxy_dir(check_proxy_dir);
    ensure_dir(check_proxy_dir);
    if (!status_success([ "prepare-check-proxy-config", sing_box_config_path, check_proxy_config, check_proxy_cache ], null)) {
        nolog("Failed to prepare temporary configuration");
        cleanup_check_proxy_dir(check_proxy_dir);
        return 1;
    }

    let outbound_tag = replace(status_output(
        [ "check-proxy-outbound-tag", check_proxy_config, CHECK_PROXY_IP_DOMAIN ],
        null
    ), /[\r\n]+$/g, "");

    let response = "";
    for (let attempt = 1; attempt <= 5; attempt++) {
        let args = [ "sing-box", "tools", "fetch", "ifconfig.me", "-c", check_proxy_config, "-D", check_proxy_dir, "--disable-color" ];
        if (outbound_tag != "") {
            push(args, "-o");
            push(args, outbound_tag);
        }
        response = command_output(command_from_args(args) + " 2>/dev/null");
        if (status_success([ "proxy-response-is-retryable-error" ], response))
            continue;

        let masked_response_ip = replace(status_output([ "proxy-response-ip-mask" ], response), /[\r\n]+$/g, "");
        if (masked_response_ip != "") {
            nolog(masked_response_ip + " - should match proxy IP");
            cleanup_check_proxy_dir(check_proxy_dir);
            return 0;
        }

        if (attempt == 5) {
            nolog("Failed to get valid IP address after 5 attempts");
            nolog(response == "" ? "Error: Empty response" : "Error response: " + response);
            cleanup_check_proxy_dir(check_proxy_dir);
            return 1;
        }
    }

    cleanup_check_proxy_dir(check_proxy_dir);
    return 1;
}

function domain_lists_contain_cloud_provider() {
    for (let section in uci_sections("section")) {
        if (!bool_option(section, "domain_list_enabled", false))
            continue;
        for (let value in list_option(section, "domain_list"))
            if (value == "hetzner" || value == "ovh")
                return true;
    }
    return false;
}

function check_nft() {
    if (!command_exists("nft")) {
        nolog("nft is not installed");
        return 1;
    }

    nolog("Checking " + NFT_TABLE_NAME + " rules...");
    if (!command_success_from_args([ "nft", "list", "table", "inet", NFT_TABLE_NAME ])) {
        nolog("❌ " + NFT_TABLE_NAME + " not found");
        return 1;
    }

    if (domain_lists_contain_cloud_provider()) {
        nolog("Sets statistics:");
        for (let set_name in [
            NFT_COMMON_SET_NAME,
            NFT_PORT_SET_NAME,
            NFT_IP_PORT_SET_NAME,
            NFT_INTERFACE_SET_NAME,
            NFT_DISCORD_SET_NAME,
            NFT_LOCALV4_SET_NAME
        ]) {
            if (!command_success_from_args([ "nft", "list", "set", "inet", NFT_TABLE_NAME, set_name ]))
                continue;
            let count = replace(status_output(
                [ "nft-set-element-count" ],
                command_output_from_args([ "nft", "-j", "list", "set", "inet", NFT_TABLE_NAME, set_name ])
            ), /[\r\n]+$/g, "");
            print("- ", set_name, ": ", count, " elements\n");
        }

        nolog("Chain configurations:");
        print(status_output(
            [ "nft-chain-config-blocks", "mangle", "proxy" ],
            command_output_from_args([ "nft", "list", "table", "inet", NFT_TABLE_NAME ])
        ));
    }
    else {
        nolog("Sets configuration:");
        print(command_output_from_args([ "nft", "list", "table", "inet", NFT_TABLE_NAME ]));
    }

    nolog("NFT check completed");
    return 0;
}

function check_logs() {
    if (!command_exists("logread")) {
        nolog("Error: logread command not found");
        return 1;
    }
    let rendered = status_capture([ "forkop-logs" ], command_output_from_args([ "logread" ]));
    if (rendered.output != "")
        print(rendered.output);
    if (rendered.status != 0) {
        nolog("Logs not found");
        return 1;
    }
    return 0;
}

function check_sing_box_logs() {
    if (!command_exists("logread")) {
        nolog("Error: logread command not found");
        return 1;
    }
    let rendered = status_capture([ "matching-log-tail", "sing-box", "100" ], command_output_from_args([ "logread" ]));
    if (rendered.output != "")
        print(rendered.output);
    if (rendered.status != 0) {
        nolog("sing-box logs not found");
        return 1;
    }
    return 0;
}

function show_sing_box_config(visibility) {
    visibility = as_string(visibility || "masked");
    let sing_box_config_path = option(settings(), "config_path", "");
    nolog("Current sing-box configuration:");
    if (!file_exists(sing_box_config_path)) {
        nolog("Configuration file not found");
        return 1;
    }
    if (visibility == "raw")
        print(as_string(fs.readfile(sing_box_config_path)));
    else
        print(status_output([ "mask-sing-box-config", sing_box_config_path ], null));
    return 0;
}

function show_config(visibility) {
    visibility = as_string(visibility || "masked");
    if (!file_exists(FORKOP_CONFIG)) {
        nolog("Configuration file not found");
        return 1;
    }
    if (visibility == "raw")
        print(as_string(fs.readfile(FORKOP_CONFIG)));
    else
        print(status_output([ "forkop-config-masked", FORKOP_CONFIG ], null));
    return 0;
}

function show_version() {
    print(FORKOP_VERSION, "\n");
    return 0;
}

function show_sing_box_version() {
    print(replace(module_output(SINGBOX_RUNTIME_UC, [ "version" ]), /[\r\n]+$/g, ""), "\n");
    return 0;
}

function get_luci_app_version() {
    let path = FORKOP_LUCI_VIEW_DIR + "/main.js";
    let data = fs.readfile(path);
    if (data == null)
        return "not installed";

    for (let line in split(as_string(data), "\n")) {
        let matched = match(line, /^[ \t]*var[ \t]+([^ \t=]+)[ \t]*=[ \t]*"([^"]*)"/);
        if (matched != null && matched[1] == "FORKOP_LUCI_APP_VERSION")
            return as_string(matched[2]);
    }
    return "";
}

function provider_installed(runtime_uc) {
    return module_success(runtime_uc, [ "installed" ]);
}

function sing_box_binary_signature() {
    let stat = fs.stat(SING_BOX_BIN_PATH);
    return stat == null ? "" : join(":", [ stat.inode, stat.size, stat.mtime, stat.ctime ]);
}

function zapret_manager_launcher_installed(path) {
    if (!file_executable(path))
        return false;

    let source = as_string(fs.readfile(path));
    // ZMS can replace the mirror launchers with its own upstream launchers.
    return index(source, "/zapret-manager/proxy/") >= 0 ||
        match(source, /https:\/\/raw\.githubusercontent\.com\/(StressOzz|Screamshow)\/Zapret-Manager\/main\/Zapret-Manager\.sh([ \t\r\n"')]|$)/) != null;
}

function zapret_manager_is_installed() {
    return zapret_manager_launcher_installed("/usr/bin/zms") &&
        zapret_manager_launcher_installed("/usr/bin/zmsA");
}

function ensure_subscription_runtime_dirs() {
    module_success(SUBSCRIPTION_CACHE_UC, [
        "ensure-runtime-dirs"
    ]);
    ensure_dir(RUNTIME_STATE_DIR);
}

function write_system_info_cache(value) {
    ensure_subscription_runtime_dirs();
    let tmpfile = SYSTEM_INFO_CACHE_FILE + "." + clock()[0] + "." + clock()[1] + ".tmp";
    if (fs.writefile(tmpfile, as_string(value) + "\n") == null)
        return false;
    remove_file(SYSTEM_INFO_CACHE_FILE);
    if (!fs.rename(tmpfile, SYSTEM_INFO_CACHE_FILE)) {
        remove_file(tmpfile);
        return false;
    }
    return true;
}

function sing_box_marker_is(expected) {
    return module_success(SINGBOX_RUNTIME_UC, [ "marker-is", expected ]);
}

function sing_box_component_action_running() {
    return module_success(SERVICE_UI_UC, [ "component-action-running-for", "sing_box" ]);
}

function sing_box_package_installed_exact(package_name) {
    let installed = command_exists("apk") ? command_output_from_args([ "apk", "list", "--installed", "--manifest" ]) : "";
    for (let line in split(installed, "\n")) {
        let fields = split(trim(as_string(line)), /[ \t]+/);
        if (as_string(fields[0]) == as_string(package_name))
            return true;
    }

    installed = command_exists("opkg") ? command_output_from_args([ "opkg", "list-installed" ]) : "";
    for (let line in split(installed, "\n"))
        if (split(trim(as_string(line)), /[ \t]+/)[0] == as_string(package_name))
            return true;

    return false;
}

function sing_box_installed_package_name() {
    for (let package_name in [ "rust-x", "sing-box-x", "sing-box-extended", "sing-box-tiny", "sing-box" ])
        if (sing_box_package_installed_exact(package_name))
            return package_name;

    return "";
}

function system_info_cache_is_valid() {
    let cache = read_json_file(SYSTEM_INFO_CACHE_FILE);
    if (type(cache) != "object")
        return false;
    if (cache.sing_box_binary_signature != sing_box_binary_signature())
        return false;
    // Package hooks may populate the cache while opkg still marks the new
    // core as unpacked. Recheck identity after the transaction completes.
    if (as_string(cache.sing_box_package) != sing_box_installed_package_name())
        return false;
    let now = int(clock()[0]);
    let generated_at = arg_number(cache.generated_at || 0);
    if (now > 0 && generated_at > 0 && SYSTEM_INFO_CACHE_TTL > 0 && now - generated_at >= SYSTEM_INFO_CACHE_TTL)
        return false;
    if (cache.forkop_version != FORKOP_VERSION || cache.luci_app_version != get_luci_app_version())
        return false;

    let zapret_manager_installed = zapret_manager_is_installed() ? 1 : 0;

    let zapret_installed = 0;
    let zapret2_installed = 0;
    if (provider_installed(ZAPRET_RUNTIME_UC))
        zapret_installed = 1;
    if (provider_installed(ZAPRET2_RUNTIME_UC))
        zapret2_installed = 1;

    return int(cache.zapret_installed || 0) == zapret_installed &&
        int(cache.zapret2_installed || 0) == zapret2_installed &&
        int(cache.zapret_manager_installed || 0) == zapret_manager_installed;
}

function sing_box_compressed_binary() {
    // Managed compressed installs remove all sing-box packages. A package
    // installed manually supersedes the old variant marker.
    return sing_box_marker_is("extended-compressed") && sing_box_installed_package_name() == "";
}

function sing_box_live_probe_disabled() {
    // Never launch a binary while a component transaction may replace it.
    return sing_box_component_action_running() || sing_box_compressed_binary();
}

function sing_box_tiny_package_installed() {
    return sing_box_package_installed_exact("sing-box-tiny");
}

function sing_box_capability_flags(sing_box_version, sing_box_version_output) {
    let extended = 0;
    let tiny = 0;
    let tailscale = 0;
    let package_name = sing_box_installed_package_name();
    let unpackaged = package_name == "";

    if (package_name == "sing-box-extended" || (unpackaged && (sing_box_marker_is("extended") ||
        sing_box_marker_is("extended-compressed"))) ||
        module_success(SINGBOX_RUNTIME_UC, [ "is-extended", sing_box_version ]))
        extended = 1;

    if (package_name == "sing-box-tiny" || (unpackaged && extended == 0 &&
        (sing_box_marker_is("tiny") || sing_box_tiny_package_installed())))
        tiny = 1;

    if (extended == 1)
        tailscale = 1;
    else if (as_string(sing_box_version_output) != "") {
        if (module_success(SINGBOX_RUNTIME_UC, [ "supports-tailscale", sing_box_version, sing_box_version_output ]))
            tailscale = 1;
    }
    else if (package_name != "sing-box-x" && tiny == 0 && sing_box_component_action_running())
        tailscale = 1;

    return { extended, tiny, tailscale, package_name };
}

function provider_version(runtime_uc) {
    let value = replace(module_output(runtime_uc, [ "package-version" ]), /[\r\n]+$/g, "");
    return value != "" ? value : "unknown";
}

function openwrt_release() {
    let data = fs.readfile("/etc/os-release");
    if (data == null)
        return "unknown";
    for (let line in split(as_string(data), "\n")) {
        if (substr(line, 0, length("OPENWRT_RELEASE=")) != "OPENWRT_RELEASE=")
            continue;
        let value = substr(line, length("OPENWRT_RELEASE="));
        if (length(value) >= 2) {
            let quote = substr(value, 0, 1);
            if ((quote == "\"" || quote == "'") && substr(value, length(value) - 1) == quote)
                value = substr(value, 1, length(value) - 2);
        }
        return value != "" ? value : "unknown";
    }
    return "unknown";
}

function build_system_info() {
    let forkop_latest_version = first_line_value("/tmp/forkop.latest-version.cache", "unknown");
    let luci_app_version = get_luci_app_version();
    let sing_box_version = "";
    let sing_box_version_output = "";

    if (command_exists("sing-box")) {
        if (sing_box_live_probe_disabled()) {
            sing_box_version = replace(module_output(SINGBOX_RUNTIME_UC, [ "read-version-state" ]), /[\r\n]+$/g, "");
            sing_box_version_output = "";
        }
        else {
            sing_box_version_output = module_output(SINGBOX_RUNTIME_UC, [ "version-output" ]);
            sing_box_version = replace(module_output_stdin(SINGBOX_RUNTIME_UC, [ "version-from-output" ], sing_box_version_output), /[\r\n]+$/g, "");
        }
        if (sing_box_version == "")
            sing_box_version = "unknown";
    }
    else {
        sing_box_version = "not installed";
        sing_box_version_output = "";
    }

    let flags = sing_box_capability_flags(sing_box_version, sing_box_version_output);
    let sing_box_compressed = flags.extended == 1 && sing_box_compressed_binary() ? 1 : 0;

    let zapret_installed = provider_installed(ZAPRET_RUNTIME_UC) ? 1 : 0;
    let zapret_version = zapret_installed ? provider_version(ZAPRET_RUNTIME_UC) : "not installed";
    let zapret2_installed = provider_installed(ZAPRET2_RUNTIME_UC) ? 1 : 0;
    let zapret2_version = zapret2_installed ? provider_version(ZAPRET2_RUNTIME_UC) : "not installed";
    let zapret_manager_installed = zapret_manager_is_installed() ? 1 : 0;
    let device_model = first_line_value("/tmp/sysinfo/model", "unknown");
    let packet_steering_mode = trim(uci_core.get("network.@globals[0].packet_steering"));
    let direct_proxy_enabled = bool_option(settings(), "direct_proxy_enabled", false) ? 1 : 0;
    let direct_proxy_port = option(settings(), "direct_proxy_port", "2080");
    let direct_proxy_address = direct_proxy_enabled
        ? trim(module_output(SINGBOX_RUNTIME_UC, [ "service-listen-address" ]))
        : "";
    let torrserver_direct_status = parse_json_or_null(module_output(LIB_DIR + "/torrserver/direct.uc", [ "status" ]));
    if (type(torrserver_direct_status) != "object")
        torrserver_direct_status = {};

    return {
        forkop_version: FORKOP_VERSION,
        forkop_latest_version: forkop_latest_version || "unknown",
        luci_app_version,
        sing_box_version,
        sing_box_binary_signature: sing_box_binary_signature(),
        sing_box_extended: flags.extended,
        sing_box_tiny: flags.tiny,
        sing_box_compressed,
        sing_box_tailscale: flags.tailscale,
        sing_box_package: flags.package_name,
        zapret_version,
        zapret_installed,
        zapret2_version,
        zapret2_installed,
        zapret_manager_installed,
        packet_steering_mode,
        direct_proxy_enabled,
        direct_proxy_address,
        direct_proxy_port,
        torrserver_running: int(torrserver_direct_status.running || 0),
        torrserver_direct_available: int(torrserver_direct_status.available || 0),
        torrserver_direct_enabled: int(torrserver_direct_status.enabled || 0),
        torrserver_direct_active: int(torrserver_direct_status.active || 0),
        openwrt_version: openwrt_release(),
        device_model,
        generated_at: int(clock()[0])
    };
}

function get_system_info() {
    if (system_info_cache_is_valid()) {
        print(as_string(fs.readfile(SYSTEM_INFO_CACHE_FILE)));
        return 0;
    }

    let system_info = sprintf("%J", build_system_info());
    write_system_info_cache(system_info);
    print(system_info, "\n");
    return 0;
}

function neutralize_zapret_defaults() {
    log_message("Standalone zapret is not neutralized automatically; Forkop uses /opt/zapret/nfq/nfqws as an external provider and manages only its own NFQUEUE range.", "info");
    return 0;
}

function sing_box_process_is_running() {
    // procd owns the service PID; verify its executable instead of argv[0].
    // Xrust's wrapper execs /usr/lib/rust-x/sing-box and may rename threads.
    return module_success(SERVICE_STATE_UC, [ "sing-box-service-running" ]);
}

function service_status_label(running, enabled) {
    if (arg_number(running) == 1)
        return arg_number(enabled) == 1 ? "running & enabled" : "running but disabled";
    return arg_number(enabled) == 1 ? "stopped but enabled" : "stopped & disabled";
}

function write_service_status(running, enabled, dns_configured, service_names) {
    write_json({
        running,
        enabled,
        status: service_status_label(running, enabled),
        memory_rss_bytes: process_memory.service_group_rss_bytes(service_names),
        dns_configured
    });
}

function dnsmasq_has_forkop_dns() {
    return module_success(DNS_APPLY_UC, [ "has-forkop-dns" ]);
}

function get_sing_box_status() {
    let running = module_success(SERVICE_STATE_UC, [
        "sing-box-service-stable",
        RUNTIME_STABLE_MIN_AGE
    ]) ? 1 : 0;
    let enabled = file_executable("/etc/rc.d/S99sing-box") ? 1 : 0;
    let dns_configured = dnsmasq_has_forkop_dns() ? 1 : 0;
    write_service_status(running, enabled, dns_configured, CORE_SERVICE_NAMES);
    return 0;
}

function get_status() {
    let running = module_success(SERVICE_STATE_UC, [
        "forkop-stably-running", RT_TABLE_NAME, NFT_TABLE_NAME, NFT_FAKEIP_MARK, RUNTIME_STABLE_MIN_AGE
    ]) ? 1 : 0;
    let enabled = file_executable("/etc/rc.d/S99" + FORKOP_SERVICE_NAME) ? 1 : 0;
    let dns_configured = dnsmasq_has_forkop_dns() ? 1 : 0;
    write_service_status(running, enabled, dns_configured, FORKOP_SERVICE_NAMES);
    return 0;
}

function subscription_cache(args) {
    return module_capture(SUBSCRIPTION_CACHE_UC, args);
}

function print_subscription_result(result, fallback) {
    if (result.status == 0 && result.output != "") {
        print(result.output);
        return 0;
    }
    print(as_string(fallback));
    return 0;
}

function section_safe(section) {
    section = as_string(section);
    return section != "" && index(section, "/") < 0 && index(section, "..") < 0;
}

function get_outbound_metadata(section) {
    subscription_cache([ "ensure-runtime-dirs" ]);
    if (!section_safe(section))
        return print_subscription_result(subscription_cache([ "empty-outbound-metadata" ]), "");
    let metadata_path = replace(module_output(SUBSCRIPTION_CACHE_UC, [ "outbound-metadata-path", section ]), /[\r\n]+$/g, "");
    if (metadata_path == "")
        return print_subscription_result(subscription_cache([ "empty-outbound-metadata" ]), "");
    let result = subscription_cache([ "get-outbound-metadata", SECTION_CACHE_DIR, section, metadata_path ]);
    if (result.status != 0)
        result = subscription_cache([ "empty-outbound-metadata" ]);
    return print_subscription_result(result, "");
}

function get_subscription_metadata(section) {
    subscription_cache([ "ensure-runtime-dirs" ]);
    if (!section_safe(section)) {
        print("{}\n");
        return 0;
    }
    let metadata_path = replace(module_output(SUBSCRIPTION_CACHE_UC, [ "subscription-metadata-path", section ]), /[\r\n]+$/g, "");
    if (metadata_path == "") {
        print("{}\n");
        return 0;
    }
    let result = subscription_cache([ "get-subscription-metadata", SECTION_CACHE_DIR, section, metadata_path ]);
    return print_subscription_result(result, "{}\n");
}

function validate_nfqws_strategy_json(raw_opt) {
    let result = module_capture(ZAPRET_VALIDATOR_UC, [
        "validate-json", "nfqws", as_string(raw_opt), ZAPRET_LEGACY_DEFAULT_NFQWS_OPT
    ]);
    if (result.output != "")
        print(result.output);
    return 0;
}

function validate_nfqws2_strategy_json(raw_opt) {
    let result = module_capture(ZAPRET2_VALIDATOR_UC, [ "validate-json", "nfqws2", as_string(raw_opt) ]);
    if (result.output != "")
        print(result.output);
    return 0;
}

function url_host(value) {
    return helper_output("url-get-host", [ value ]);
}

function dns_check_resolve_host(host, resolver, timeout_seconds) {
    host = as_string(host);
    resolver = as_string(resolver);
    if (host == "")
        return "";
    if (valid_ipv4(host))
        return host;
    if (resolver == "")
        return "";

    timeout_seconds = int(timeout_seconds || 2);
    for (let line in split(command_output_from_args([
        "dig", "@" + resolver, host, "A", "+short", "+timeout=" + as_string(timeout_seconds), "+tries=1"
    ]), "\n")) {
        line = trim(as_string(line));
        if (valid_ipv4(line))
            return line;
    }
    return "";
}

function device_ipv4_address(interface) {
    let value = replace(module_output(SINGBOX_RUNTIME_UC, [ "device-ipv4-address", interface ]), /[\r\n]+$/g, "");
    if (value != "")
        return value;

    let output = command_output_from_args([ "ip", "-4", "addr", "show", "dev", interface ]);
    for (let line in split(output, "\n")) {
        line = trim(as_string(line));
        let matched = match(line, /^inet[ \t]+([0-9.]+)\//);
        if (matched != null)
            return as_string(matched[1]);
    }
    return "";
}

function dns_check_router_resolver_available(domain) {
    for (let address in [ "127.0.0.1", SB_DNS_INBOUND_ADDRESS ]) {
        if (address != "" && command_success_from_args([ "dig", "@" + address, domain, "+timeout=2", "+tries=1" ]))
            return true;
    }

    let listen_address = replace(module_output(SINGBOX_RUNTIME_UC, [ "service-listen-address" ]), /[\r\n]+$/g, "");
    if (listen_address != "" && command_success_from_args([ "dig", "@" + listen_address, domain, "+timeout=2", "+tries=1" ]))
        return true;

    let source_interfaces = option(settings(), "source_network_interfaces", "br-lan");
    for (let interface in words(source_interfaces)) {
        let address = device_ipv4_address(interface);
        if (address != "" && command_success_from_args([ "dig", "@" + address, domain, "+timeout=2", "+tries=1" ]))
            return true;
    }

    return false;
}

function dns_check_timeout_seconds(value) {
    let rest = as_string(value);
    let milliseconds = 0.0;
    let units = { ns: 0.000001, us: 0.001, ms: 1, s: 1000, m: 60000, h: 3600000, d: 86400000 };
    while (rest != "") {
        let matched = match(rest, /^([0-9]+(\.[0-9]+)?)(ns|us|ms|s|m|h|d)/);
        if (!matched)
            return 2;
        milliseconds += (matched[1] * 1) * units[matched[3]];
        rest = substr(rest, length(matched[0]));
    }
    return milliseconds > 0 ? int((milliseconds + 999) / 1000) : 2;
}

function check_dns_available() {
    let cfg = settings();
    let dns_type = option(cfg, "dns_type", "");
    let active = runtime_dns.active_values(cfg);
    let dns_server = active.main;
    let bootstrap_dns_server = active.bootstrap;
    let dont_touch_dhcp = bool_option(cfg, "dont_touch_dhcp", false) ? 1 : 0;
    let domain = "example.com";
    let timeout_seconds = dns_check_timeout_seconds(option(cfg, "dns_check_timeout", "2s"));
    let dns_status = 0;
    let dns_on_router = 0;
    let bootstrap_dns_status = 0;
    let dhcp_config_status = 1;

    let active_dns_args = [ "dig" ];
    if (runtime_dns.failover_enabled(cfg)) {
        push(active_dns_args, "-p");
        push(active_dns_args, as_string(runtime_dns.health_port("active", 0)));
    }
    push(active_dns_args, "@" + SB_DNS_INBOUND_ADDRESS);
    push(active_dns_args, domain);
    push(active_dns_args, "A");
    push(active_dns_args, "+short");
    push(active_dns_args, "+timeout=" + as_string(timeout_seconds));
    push(active_dns_args, "+tries=1");
    for (let line in split(command_output_from_args(active_dns_args), "\n"))
        if (valid_ipv4(trim(as_string(line)))) {
            dns_status = 1;
            break;
        }

    if (dns_check_router_resolver_available(domain))
        dns_on_router = 1;

    let dns_server_host = url_host(dns_server);
    if (dns_server_host == "")
        dns_server_host = dns_server;
    let bootstrap_dns_required = !core_ip.valid_ip(dns_server_host);
    if (bootstrap_dns_required && bootstrap_dns_server != "") {
        if (length(active.state.bootstrap_servers) > 1) {
            for (let line in split(command_output_from_args([
                "dig", "-p", as_string(runtime_dns.health_port("bootstrap", active.state.bootstrap_index)),
                "@" + runtime_dns.DNS_HEALTH_ADDRESS, domain, "A", "+short",
                "+timeout=" + as_string(timeout_seconds), "+tries=1"
            ]), "\n"))
                if (valid_ipv4(trim(as_string(line)))) {
                    bootstrap_dns_status = 1;
                    break;
                }
        }
        else {
            let bootstrap_check_domain = domain;
            if (dns_server_host != "" && !valid_ipv4(dns_server_host))
                bootstrap_check_domain = dns_server_host;
            if (dns_check_resolve_host(bootstrap_check_domain, bootstrap_dns_server, timeout_seconds) != "")
                bootstrap_dns_status = 1;
        }
    }

    if (!module_success(DNS_APPLY_UC, [ "default-config-complete" ]))
        dhcp_config_status = 0;

    let display_dns_server = replace(status_output([ "mask-dns-server", dns_server ], null), /[\r\n]+$/g, "");
    write_json({
        dns_type,
        dns_server: display_dns_server,
        dns_server_index: active.state.main_index,
        dns_server_count: length(active.state.main_servers),
        dns_status,
        dns_on_router,
        bootstrap_dns_server,
        bootstrap_dns_server_index: active.state.bootstrap_index,
        bootstrap_dns_server_count: length(active.state.bootstrap_servers),
        bootstrap_dns_status,
        bootstrap_dns_required: bootstrap_dns_required ? 1 : 0,
        dhcp_config_status,
        dont_touch_dhcp
    });
    return 0;
}

function nft_chain_counter_status(chain) {
    let output = command_output_from_args([ "nft", "list", "chain", "inet", NFT_TABLE_NAME, chain ]);
    let status = words(status_output([ "nft-chain-counter-status" ], output));
    while (length(status) < 2)
        push(status, "0");
    return [ arg_number(status[0]), arg_number(status[1]) ];
}

function nft_table_has_other_mark_rules(family, table_name) {
    let output = command_output_from_args([ "nft", "list", "table", family, table_name ]);
    return status_success([ "stdin-contains", "meta mark set" ], output);
}

function check_nft_rules() {
    command_status("sh -c " + shell_quote(
        "curl -m 3 -s " + shell_quote("https://" + CHECK_PROXY_IP_DOMAIN + "/check") + " >/dev/null 2>&1 & pid1=$!; " +
        "curl -m 3 -s " + shell_quote("https://" + FAKEIP_TEST_DOMAIN + "/check") + " >/dev/null 2>&1 & pid2=$!; " +
        "wait $pid1 2>/dev/null; wait $pid2 2>/dev/null; sleep 1"
    ));

    let table_exist = 0;
    let rules_mangle_exist = 0;
    let rules_mangle_counters = 0;
    let rules_mangle_output_exist = 0;
    let rules_mangle_output_counters = 0;
    let rules_proxy_exist = 0;
    let rules_proxy_counters = 0;
    let rules_other_mark_exist = 0;

    if (command_success_from_args([ "nft", "list", "table", "inet", NFT_TABLE_NAME ])) {
        table_exist = 1;
        if (command_success_from_args([ "nft", "list", "chain", "inet", NFT_TABLE_NAME, "mangle" ])) {
            let status = nft_chain_counter_status("mangle");
            rules_mangle_exist = status[0];
            rules_mangle_counters = status[1];
        }
        if (command_success_from_args([ "nft", "list", "chain", "inet", NFT_TABLE_NAME, "mangle_output" ])) {
            let status = nft_chain_counter_status("mangle_output");
            rules_mangle_output_exist = status[0];
            rules_mangle_output_counters = status[1];
        }
        if (command_success_from_args([ "nft", "list", "chain", "inet", NFT_TABLE_NAME, "proxy" ])) {
            let status = nft_chain_counter_status("proxy");
            rules_proxy_exist = status[0];
            rules_proxy_counters = status[1];
        }
    }

    for (let line in split(command_output_from_args([ "nft", "list", "tables" ]), "\n")) {
        let fields = words(line);
        if (length(fields) < 3)
            continue;
        let family = fields[1];
        let table_name = fields[2];
        if (table_name == NFT_TABLE_NAME)
            continue;
        if (nft_table_has_other_mark_rules(family, table_name)) {
            rules_other_mark_exist = 1;
            break;
        }
    }

    write_json({
        table_exist,
        rules_mangle_exist,
        rules_mangle_counters,
        rules_mangle_output_exist,
        rules_mangle_output_counters,
        rules_proxy_exist,
        rules_proxy_counters,
        rules_other_mark_exist
    });
    return 0;
}

function strip_leading_v(value) {
    value = as_string(value);
    return substr(value, 0, 1) == "v" ? substr(value, 1) : value;
}

function sing_box_standard_ports_listening(netstat_data) {
    return netstat.sing_box_standard_ports_listening(
        netstat_data,
        SB_DNS_INBOUND_ADDRESS,
        SB_TPROXY_INBOUND_PORT,
        core_ip.ipv6_tproxy_enabled() ? SB_TPROXY_INBOUND6_ADDRESS : ""
    );
}

function check_sing_box() {
    let sing_box_installed = 0;
    let sing_box_version_ok = 0;
    let sing_box_extended = 0;
    let sing_box_service_exist = 0;
    let sing_box_autostart_disabled = 0;
    let sing_box_process_running = 0;
    let sing_box_ports_listening = 0;

    if (command_exists("sing-box")) {
        sing_box_installed = 1;
        let version = strip_leading_v(replace(module_output(SINGBOX_RUNTIME_UC, [ "version" ]), /[\r\n]+$/g, ""));
        if (version != "") {
            if (sing_box_marker_is("extended-compressed") || module_success(SINGBOX_RUNTIME_UC, [ "is-extended", version ]))
                sing_box_extended = 1;
            if (module_success(HELPERS_UC, [ "version-at-least", version, "1.12.4" ]))
                sing_box_version_ok = 1;
        }
        else if (sing_box_marker_is("extended-compressed"))
            sing_box_extended = 1;
    }

    if (file_exists("/etc/init.d/sing-box")) {
        sing_box_service_exist = 1;
        if (!command_success_from_args([ "/etc/init.d/sing-box", "enabled" ]))
            sing_box_autostart_disabled = 1;
    }

    if (sing_box_process_is_running())
        sing_box_process_running = 1;

    if (sing_box_standard_ports_listening(command_output_from_args([ "netstat", "-ln" ])))
        sing_box_ports_listening = 1;

    write_json({
        sing_box_installed,
        sing_box_version_ok,
        sing_box_extended,
        sing_box_service_exist,
        sing_box_autostart_disabled,
        sing_box_process_running,
        sing_box_ports_listening
    });
    return 0;
}

function rule_matches_domain(rule, domain) {
    let value = object_or_empty(rule).domain;
    if (type(value) == "array") {
        for (let item in value)
            if (as_string(item) == as_string(domain))
                return true;
        return false;
    }
    return as_string(value) == as_string(domain);
}

function fakeip_public_ip_comparison_available(config) {
    let route = object_or_empty(object_or_empty(config).route);
    let rules = type(route.rules) == "array" ? route.rules : [];
    for (let rule in rules) {
        rule = object_or_empty(rule);
        if (option(rule, "action", "") == "route" &&
            option(rule, "outbound", "") != "" &&
            rule_matches_domain(rule, CHECK_PROXY_IP_DOMAIN))
            return true;
    }
    return false;
}

function fakeip_check_result(config) {
    let fakeip_address = "";
    let fakeip6_address = "";
    for (let line in split(command_output_from_args([
        "dig", "+short", "@" + SB_DNS_INBOUND_ADDRESS, FAKEIP_TEST_DOMAIN, "A", "+timeout=2", "+tries=1"
    ]), "\n")) {
        line = trim(as_string(line));
        if (valid_ipv4(line)) {
            fakeip_address = line;
            break;
        }
    }
    for (let line in split(command_output_from_args([
        "dig", "+short", "@" + SB_DNS_INBOUND_ADDRESS, FAKEIP_TEST_DOMAIN, "AAAA", "+timeout=2", "+tries=1"
    ]), "\n")) {
        line = lc(trim(as_string(line)));
        if (core_ip.valid_ipv6(line)) {
            fakeip6_address = line;
            break;
        }
    }
    return {
        fakeip: match(fakeip_address, /^198\.(18|19)\./) != null || match(fakeip6_address, /^fc[0-3][0-9a-f]:/) != null,
        public_ip_comparison_available: fakeip_public_ip_comparison_available(config),
        IP: fakeip_address != "" ? fakeip_address : fakeip6_address,
        IPv4: fakeip_address,
        IPv6: fakeip6_address
    };
}

function check_fakeip() {
    write_json(fakeip_check_result(read_json_file(option(settings(), "config_path", ""))));
    return 0;
}

function fakeip_public_ip_comparison_available_fixture(path) {
    exit(fakeip_public_ip_comparison_available(read_json_file(path)) ? 0 : 1);
}

function check_fakeip_fixture(path) {
    write_json(fakeip_check_result(read_json_file(path)));
    return 0;
}

function clash_json_output(args) {
    print(status_output([ "stdin-json" ], command_output(command_from_args(args))));
    return 0;
}

function clash_api_url() {
    let address = replace(module_output(SINGBOX_RUNTIME_UC, [ "service-listen-address" ]), /[\r\n]+$/g, "");
    if (address == "")
        address = "127.0.0.1";
    return address + ":" + SB_CLASH_API_CONTROLLER_PORT;
}

function clash_auth_args() {
    // Same condition as the generated config, not the WAN switch: the
    // controller requires the token whenever it has a secret.
    let secret = common.clash_api_secret(settings());
    if (secret == "")
        return [];
    return [ "--header", "Authorization: Bearer " + secret ];
}

function clash_urlencode(value) {
    return replace(status_output([ "url-encode", value ], null), /[\r\n]+$/g, "");
}

function clash_json_error(message) {
    let result = status_capture([ "json-error", message ], null);
    if (result.output != "")
        print(result.output);
    return 1;
}

function clash_proxy_entries(base_url, auth) {
    let args = [ "curl", "-s" ];
    for (let item in auth) push(args, item);
    push(args, base_url + "/proxies");

    let value = null;
    try {
        value = json(command_output(command_from_args(args)));
    }
    catch (e) {
        return null;
    }

    if (type(value) != "object" || type(value.proxies) != "object")
        return null;

    return object_or_empty(value.proxies);
}

function clash_proxy_type_map(base_url, auth) {
    let entries = clash_proxy_entries(base_url, auth);
    if (entries == null)
        return null;

    let result = {};
    for (let tag, proxy in entries)
        result[tag] = as_string(object_or_empty(proxy).type || "");
    return result;
}

function clash_api_ready() {
    return clash_proxy_type_map(clash_api_url(), clash_auth_args()) != null;
}

function latency_testable_proxy_type(proxy_type) {
    proxy_type = lc(as_string(proxy_type));
    return proxy_type != "" && proxy_type != "direct" && proxy_type != "selector" &&
        proxy_type != "urltest" && proxy_type != "fallback" && proxy_type != "block" &&
        proxy_type != "dns";
}

// URLTest periodically measures its members itself and Priority probes them
// immediately when its supervisor starts. The automatic warm-up is only for
// independent nodes exposed by a selector, so do not duplicate group-owned
// probes or touch detached/internal outbounds.
function automatic_latency_group_member_tags(proxy_entries, priority_groups) {
    let result = {};

    for (let tag, proxy in object_or_empty(proxy_entries)) {
        proxy = object_or_empty(proxy);
        if (lc(as_string(proxy.type || "")) != "urltest")
            continue;
        for (let member in type(proxy.all) == "array" ? proxy.all : []) {
            member = as_string(member);
            if (member != "")
                result[member] = true;
        }
    }

    for (let tag, group in object_or_empty(priority_groups)) {
        for (let level in type(object_or_empty(group).levels) == "array" ? group.levels : []) {
            for (let member in type(object_or_empty(level).outbounds) == "array" ? level.outbounds : []) {
                member = as_string(member);
                if (member != "")
                    result[member] = true;
            }
        }
    }

    return result;
}

function automatic_latency_priority_groups() {
    let result = {};
    let entries = fs.lsdir(SECTION_CACHE_DIR);
    if (type(entries) != "array")
        return result;

    for (let entry in entries) {
        entry = as_string(entry);
        if (match(entry, /^[A-Za-z0-9_-]+\.json$/) == null)
            continue;
        let cache = object_or_empty(read_json_file(SECTION_CACHE_DIR + "/" + entry));
        for (let tag, group in object_or_empty(cache.priorityGroups))
            result[tag] = group;
    }
    return result;
}

function automatic_latency_selector_member_tags(proxy_entries) {
    let result = {};
    for (let tag, proxy in object_or_empty(proxy_entries)) {
        proxy = object_or_empty(proxy);
        if (lc(as_string(proxy.type || "")) != "selector")
            continue;
        for (let member in type(proxy.all) == "array" ? proxy.all : []) {
            member = as_string(member);
            if (member != "")
                result[member] = true;
        }
    }
    return result;
}

function automatic_latency_proxy_tags(proxy_entries, priority_groups) {
    let group_members = automatic_latency_group_member_tags(proxy_entries, priority_groups);
    let selector_members = automatic_latency_selector_member_tags(proxy_entries);
    let selector_member_count = length(keys(selector_members));
    let result = [];
    for (let proxy_tag, proxy in object_or_empty(proxy_entries)) {
        let proxy_type = as_string(object_or_empty(proxy).type || "");
        if (latency_testable_proxy_type(proxy_type) && !group_members[proxy_tag] &&
            (selector_member_count == 0 || selector_members[proxy_tag]))
            push(result, proxy_tag);
    }
    return result;
}

function automatic_latency_proxy_tags_fixture() {
    let fixture = object_or_empty(parse_json_or_null(ARGV[1] || read_stdin()));
    write_json(automatic_latency_proxy_tags(
        object_or_empty(fixture.proxies),
        object_or_empty(fixture.priorityGroups)
    ));
}

function canonical_runtime_value(value) {
    if (type(value) == "array") {
        let result = [];
        for (let item in value)
            push(result, canonical_runtime_value(item));
        return result;
    }
    if (type(value) == "object") {
        let result = {};
        let names = keys(value);
        sort(names, function(a, b) { return a < b ? -1 : (a > b ? 1 : 0); });
        for (let name in names)
            result[name] = canonical_runtime_value(value[name]);
        return result;
    }
    return value;
}

function proxy_outbounds_signature_value(path) {
    let config = read_json_file(path);
    if (type(config) != "object" || type(config.outbounds) != "array")
        return "";

    let outbounds = [];
    for (let outbound in config.outbounds) {
        outbound = object_or_empty(outbound);
        if (latency_testable_proxy_type(outbound.type))
            push(outbounds, sprintf("%J", canonical_runtime_value(outbound)));
    }
    sort(outbounds, function(a, b) { return a < b ? -1 : (a > b ? 1 : 0); });
    if (length(outbounds) == 0)
        return "";

    let tmp = trim(command_output_from_args([ "mktemp" ]));
    if (tmp == "" || !fs.writefile(tmp, sprintf("%J", outbounds))) {
        if (tmp != "") fs.unlink(tmp);
        return "";
    }
    let fields = split(trim(command_output_from_args([ "md5sum", tmp ])), /[ \t\r\n]+/);
    fs.unlink(tmp);
    return length(fields) > 0 ? as_string(fields[0]) : "";
}

function print_proxy_outbounds_signature(path) {
    let signature = proxy_outbounds_signature_value(path);
    if (signature == "")
        return 1;
    print(signature, "\n");
    return 0;
}

function automatic_latency_pending_marker() {
    let marker = read_json_file(AUTOMATIC_LATENCY_PENDING_FILE);
    if (type(marker) != "object" || as_string(marker.format) != AUTOMATIC_LATENCY_PENDING_FORMAT ||
        match(as_string(marker.signature), /^[0-9a-f]{32}$/) == null)
        return null;
    return marker;
}

function automatic_latency_discard_invalid_marker() {
    if (fs.stat(AUTOMATIC_LATENCY_PENDING_FILE) == null)
        return true;
    remove_file(AUTOMATIC_LATENCY_PENDING_FILE);
    return fs.stat(AUTOMATIC_LATENCY_PENDING_FILE) == null;
}

function automatic_latency_write_marker(marker) {
    let slash = rindex(AUTOMATIC_LATENCY_PENDING_FILE, "/");
    let dir = slash >= 0 ? substr(AUTOMATIC_LATENCY_PENDING_FILE, 0, slash) : "";
    if (dir != "" && !ensure_dir(dir))
        return false;
    let stamp = clock();
    let tmp = sprintf("%s.%d.%d.tmp", AUTOMATIC_LATENCY_PENDING_FILE, stamp[0], stamp[1]);
    if (!fs.writefile(tmp, sprintf("%J\n", marker)) || !fs.rename(tmp, AUTOMATIC_LATENCY_PENDING_FILE)) {
        remove_file(tmp);
        return false;
    }
    command_success_from_args([ "chmod", "0600", AUTOMATIC_LATENCY_PENDING_FILE ]);
    return true;
}

function automatic_latency_marker_matches(signature, generation) {
    let marker = automatic_latency_pending_marker();
    return marker != null && as_string(marker.signature) == as_string(signature) &&
        as_string(marker.generation) == as_string(generation);
}

function automatic_latency_remove_marker(signature, generation) {
    let marker = automatic_latency_pending_marker();
    if (marker != null && as_string(marker.signature) == as_string(signature) &&
        (generation == null || as_string(marker.generation) == as_string(generation)))
        remove_file(AUTOMATIC_LATENCY_PENDING_FILE);
}

// reload.pending belongs to init.d. A latency worker only releases its locks
// and asks init.d to apply the request; the completed lifecycle schedules the
// one replacement worker against its final proxy generation.
function automatic_latency_yield_to_pending_reload() {
    return system(shell_quote(SERVICE_INIT) + " reload pending </dev/null >/dev/null 2>&1 1000>&-") == 0;
}

function automatic_latency_schedule_resume() {
    let command = command_from_args([
        "ucode", "-L", LIB_DIR, DIAGNOSTICS_RUNTIME_UC,
        "automatic-latency-test", "resume"
    ]) + " </dev/null >/dev/null 2>&1 &";
    return system(command) == 0;
}

function automatic_latency_record_failure(signature, generation) {
    let marker = automatic_latency_pending_marker();
    if (marker == null || as_string(marker.signature) != as_string(signature) ||
        as_string(marker.generation) != as_string(generation))
        return;
    let failures = int(marker.failures || 0) + 1;
    let delay = AUTOMATIC_LATENCY_RETRY_BASE_SECONDS > 0 ? AUTOMATIC_LATENCY_RETRY_BASE_SECONDS : 300;
    for (let i = 1; i < failures && i < AUTOMATIC_LATENCY_MAX_FAILURES; i++)
        delay *= 2;
    if (failures >= AUTOMATIC_LATENCY_MAX_FAILURES)
        delay = 21600;
    marker.failures = failures;
    marker.retry_after = int(clock()[0]) + delay;
    automatic_latency_write_marker(marker);
}

function clash_latency_endpoint(base_url, proxy_tag, proxy_type) {
    proxy_type = as_string(proxy_type);
    if (lc(proxy_type) == "urltest")
        return base_url + "/group/" + clash_urlencode(proxy_tag) + "/delay";
    return base_url + "/proxies/" + clash_urlencode(proxy_tag) + "/delay";
}

function latency_test_url() {
    let value = option(settings(), "latency_test_url", DEFAULT_LATENCY_TEST_URL);
    return value == "" ? DEFAULT_LATENCY_TEST_URL : value;
}

function latency_probe_concurrency() {
    let configured = trim(as_string(getenv("FORKOP_LATENCY_PROBE_CONCURRENCY") || ""));
    let value = match(configured, /^[0-9]+$/) != null ? int(configured) : 4;
    if (value < 1)
        value = 1;
    return value > 8 ? 8 : value;
}

function latency_probe_command(base_url, auth, proxy_tag, proxy_type, test_url, timeout) {
    let args = [ "curl", "-G", "-s", clash_latency_endpoint(base_url, proxy_tag, proxy_type) ];
    for (let item in auth) push(args, item);
    push(args, "--data-urlencode");
    push(args, "url=" + as_string(test_url));
    push(args, "--data-urlencode");
    push(args, "timeout=" + as_string(timeout));
    return command_from_args(args);
}

// One curl per proxy, as before, but several of them in flight: the core
// probes concurrently inside a single group request anyway, while this sweep
// paid the full per-proxy timeout once per member. Callers pass the phases
// apart, so a urltest group is still measured after its own members.
// FORKOP_LATENCY_PROBE_CONCURRENCY=1 restores the strictly sequential sweep.
function probe_proxy_latencies(plan, proxy_tags, progress) {
    let concurrency = latency_probe_concurrency();
    let index = 0;

    while (index < length(proxy_tags)) {
        let batch = [];
        while (length(batch) < concurrency && index < length(proxy_tags)) {
            push(batch, proxy_tags[index]);
            index++;
        }

        let probes = [];
        let script = "";
        for (let proxy_tag in batch) {
            let command = latency_probe_command(plan.base_url, plan.auth, proxy_tag,
                plan.proxy_types[proxy_tag], plan.test_url, plan.timeout);
            let path = length(batch) > 1 ? trim(command_output_from_args([ "mktemp" ])) : "";
            if (path == "") {
                // Alone in its batch, or without a temporary file: capture it
                // directly, which is what the sequential sweep always did.
                push(probes, { path: "", output: command_output(command) });
                continue;
            }
            push(probes, { path, output: "" });
            script += command + " >" + shell_quote(path) + " 2>/dev/null & ";
        }
        if (script != "")
            command_status(script + "wait");

        for (let probe in probes) {
            let output = probe.output;
            if (probe.path != "") {
                output = as_string(fs.readfile(probe.path));
                fs.unlink(probe.path);
            }
            if (status_capture([ "stdin-json" ], output).status != 0)
                progress.failed++;
            progress.completed++;
            if (progress.path != "")
                module_success(SERVICE_UI_UC, [ "latency-progress-state", progress.path,
                    progress.completed, progress.total, progress.failed ]);
        }
    }

    return progress;
}

function clash_api(action, arg1, arg2, arg3) {
    let base_url = clash_api_url();
    let test_url = latency_test_url();
    let auth = clash_auth_args();

    if (action == "get_proxies") {
        let args = [ "curl", "-s" ];
        for (let item in auth) push(args, item);
        push(args, base_url + "/proxies");
        return clash_json_output(args);
    }

    if (action == "get_connections") {
        let args = [ "curl", "-s" ];
        for (let item in auth) push(args, item);
        push(args, base_url + "/connections");
        return clash_json_output(args);
    }

    if (action == "get_proxy_latency") {
        if (as_string(arg1) == "")
            return clash_json_error("proxy_tag required");
        let url = as_string(arg3 || "");
        if (url == "")
            url = test_url;
        let args = [ "curl", "-G", "-s", base_url + "/proxies/" + clash_urlencode(arg1) + "/delay" ];
        for (let item in auth) push(args, item);
        push(args, "--data-urlencode");
        push(args, "url=" + url);
        push(args, "--data-urlencode");
        push(args, "timeout=" + as_string(arg2 || "2000"));
        return clash_json_output(args);
    }

    if (action == "get_proxy_latencies") {
        if (as_string(arg1) == "")
            return clash_json_error("proxy_tags_json required");
        let tags = status_capture([ "clash-proxy-tags-lines", arg1 ], null);
        if (tags.status != 0)
            return clash_json_error("proxy_tags_json must be a JSON array of non-empty strings");
        let proxy_tags = [];
        for (let proxy_tag in split(tags.output, "\n")) {
            proxy_tag = as_string(proxy_tag);
            if (proxy_tag != "")
                push(proxy_tags, proxy_tag);
        }

        let count = 0;
        let failed = 0;
        let progress_path = as_string(arg3);
        let total = length(proxy_tags);
        if (progress_path != "")
            module_success(SERVICE_UI_UC, [ "latency-progress-state", progress_path, count, total, failed ]);

        let proxy_types = clash_proxy_type_map(base_url, auth);
        let member_proxy_tags = [];
        let urltest_proxy_tags = [];
        for (let proxy_tag in proxy_tags)
            push(lc(as_string(proxy_types[proxy_tag])) == "urltest" ? urltest_proxy_tags : member_proxy_tags,
                proxy_tag);

        let plan = {
            base_url,
            auth,
            proxy_types,
            test_url,
            timeout: as_string(arg2 || "5000")
        };
        let progress = { completed: count, failed, total, path: progress_path };
        for (let phase in [ member_proxy_tags, urltest_proxy_tags ])
            progress = probe_proxy_latencies(plan, phase, progress);
        count = progress.completed;
        failed = progress.failed;

        let result = status_capture([ "clash-proxy-latencies-result", count, failed ], null);
        if (result.output != "")
            print(result.output);
        return result.status;
    }

    if (action == "get_group_latency") {
        if (as_string(arg1) == "")
            return clash_json_error("group_tag required");
        let args = [ "curl", "-G", "-s", base_url + "/group/" + clash_urlencode(arg1) + "/delay" ];
        for (let item in auth) push(args, item);
        push(args, "--data-urlencode");
        push(args, "url=" + test_url);
        push(args, "--data-urlencode");
        push(args, "timeout=" + as_string(arg2 || "5000"));
        return clash_json_output(args);
    }

    if (action == "set_group_proxy") {
        if (as_string(arg1) == "" || as_string(arg2) == "")
            return clash_json_error("group_tag and proxy_tag required");
        let payload = status_output([ "clash-set-group-proxy-payload", arg2 ], null);
        let args = [ "curl", "-X", "PUT", "-s", "-w", "\n%{http_code}", base_url + "/proxies/" + clash_urlencode(arg1) ];
        for (let item in auth) push(args, item);
        push(args, "--data-raw");
        push(args, payload);
        let result = status_capture([ "clash-set-group-proxy-result", arg1, arg2 ], command_output(command_from_args(args)));
        if (result.output != "")
            print(result.output);
        return result.status;
    }

    if (action == "close_connection") {
        if (as_string(arg1) == "")
            return clash_json_error("connection_id required");
        let args = [ "curl", "-X", "DELETE", "-s", "-w", "\n%{http_code}", base_url + "/connections/" + clash_urlencode(arg1) ];
        for (let item in auth) push(args, item);
        let result = status_capture([ "clash-close-connection-result", arg1 ], command_output(command_from_args(args)));
        if (result.output != "")
            print(result.output);
        return result.status;
    }

    if (action == "close_all_connections") {
        let args = [ "curl", "-X", "DELETE", "-s", "-w", "\n%{http_code}", base_url + "/connections" ];
        for (let item in auth) push(args, item);
        let result = status_capture([ "clash-close-all-connections-result" ], command_output(command_from_args(args)));
        if (result.output != "")
            print(result.output);
        return result.status;
    }

    let unknown = status_capture([ "clash-unknown-action" ], null);
    if (unknown.output != "")
        print(unknown.output);
    return 1;
}

function automatic_latency_test(start_kind) {
    if (module_success(SERVICE_UI_UC, [ "package-upgrade-transition-active" ])) {
        log_message("Automatic latency test yielded because a Forkop package upgrade is stopping the runtime", "info");
        return 0;
    }

    let marker = automatic_latency_pending_marker();
    if (marker == null) {
        if (fs.stat(AUTOMATIC_LATENCY_PENDING_FILE) != null) {
            if (automatic_latency_discard_invalid_marker())
                log_message("Discarded invalid automatic latency test pending marker; no test was started", "warn");
            else
                log_message("Automatic latency test pending marker is invalid and could not be discarded; no test was started", "warn");
        }
        return 0;
    }

    let pending_signature = as_string(marker.signature);
    let pending_generation = as_string(marker.generation);
    let config_path = option(settings(), "config_path", "");
    let current_signature = proxy_outbounds_signature_value(config_path);
    if (current_signature == "" || current_signature != pending_signature) {
        automatic_latency_remove_marker(pending_signature, pending_generation);
        log_message("Discarded stale automatic latency test pending marker because the proxy set no longer matches", "info");
        return 0;
    }

    // A pending reload is a hard barrier: measuring the old sing-box process
    // before it restarts only guarantees a PID-change interruption. Hand the
    // reload off first. Its completion schedules exactly one worker against
    // the final generated proxy set, so this worker must not race it.
    if (fs.stat(PENDING_RELOAD_FILE) != null) {
        log_message("Automatic latency test is waiting for the pending Forkop reload before taking measurements", "info");
        automatic_latency_yield_to_pending_reload();
        log_message("Automatic latency test yielded to the pending reload; the final runtime will resume it", "info");
        return 0;
    }

    let stat = as_string(fs.readfile("/proc/self/stat"));
    let separator = index(stat, " ");
    let owner_pid = separator > 0 ? substr(stat, 0, separator) : "";
    if (owner_pid == "" || !module_success(SERVICE_STATE_UC, [
        "acquire-runtime-dir-lock", AUTOMATIC_LATENCY_TEST_LOCK_DIR, owner_pid
    ])) {
        log_message("Automatic latency test is already scheduled or running; coalescing the duplicate request", "info");
        return 0;
    }

    let retry_delay = int(marker.retry_after || 0) - int(clock()[0]);
    if (retry_delay > 0) {
        log_message("Automatic latency test is deferred for " + retry_delay + " seconds by its retry pause; it will continue automatically", "info");
        command_success_from_args([ "sleep", as_string(retry_delay) ]);
        marker = automatic_latency_pending_marker();
        current_signature = proxy_outbounds_signature_value(config_path);
        if (marker == null || as_string(marker.signature) != pending_signature ||
            as_string(marker.generation) != pending_generation || current_signature != pending_signature) {
            module_success(SERVICE_STATE_UC, [ "release-runtime-dir-lock", AUTOMATIC_LATENCY_TEST_LOCK_DIR ]);
            return 0;
        }
    }

    if (!module_success(SERVICE_STATE_UC, [
        "acquire-runtime-dir-lock-wait-until-package-upgrade", RELOAD_LOCK_DIR, owner_pid, "300"
    ])) {
        module_success(SERVICE_STATE_UC, [ "release-runtime-dir-lock", AUTOMATIC_LATENCY_TEST_LOCK_DIR ]);
        log_message("Automatic latency test deferred because Forkop did not finish reloading; the pending marker was retained", "warn");
        return 0;
    }

    if (!module_success(SERVICE_STATE_UC, [ "single-ready-sing-box-runtime" ])) {
        module_success(SERVICE_STATE_UC, [ "release-runtime-dir-lock", AUTOMATIC_LATENCY_TEST_LOCK_DIR ]);
        module_success(SERVICE_STATE_UC, [ "release-runtime-dir-lock", RELOAD_LOCK_DIR ]);
        log_message("Automatic latency test deferred because sing-box is not ready or multiple processes are running; the pending marker was retained", "info");
        return 0;
    }

    let sing_box_pid_before = trim(module_output(SERVICE_STATE_UC, [ "sing-box-service-runtime-pid" ]));
    let proxy_entries = null;
    let readiness_attempts = AUTOMATIC_LATENCY_CLASH_READY_ATTEMPTS > 0 ? AUTOMATIC_LATENCY_CLASH_READY_ATTEMPTS : 15;
    for (let readiness_attempt = 0; readiness_attempt < readiness_attempts; readiness_attempt++) {
        proxy_entries = clash_proxy_entries(clash_api_url(), clash_auth_args());
        if (proxy_entries != null)
            break;
        if (readiness_attempt + 1 < readiness_attempts)
            command_success_from_args([ "sleep", "1" ]);
    }
    if (proxy_entries == null) {
        module_success(SERVICE_STATE_UC, [ "release-runtime-dir-lock", AUTOMATIC_LATENCY_TEST_LOCK_DIR ]);
        module_success(SERVICE_STATE_UC, [ "release-runtime-dir-lock", RELOAD_LOCK_DIR ]);
        automatic_latency_record_failure(pending_signature, pending_generation);
        log_message("Automatic latency test deferred because the Clash API is not ready; the pending marker was retained with a retry pause", "warn");
        return 1;
    }

    let proxy_tags = automatic_latency_proxy_tags(
        proxy_entries,
        automatic_latency_priority_groups()
    );

    if (length(proxy_tags) == 0) {
        module_success(SERVICE_STATE_UC, [ "release-runtime-dir-lock", AUTOMATIC_LATENCY_TEST_LOCK_DIR ]);
        module_success(SERVICE_STATE_UC, [ "release-runtime-dir-lock", RELOAD_LOCK_DIR ]);
        automatic_latency_record_failure(pending_signature, pending_generation);
        log_message("Automatic latency test could not find the pending proxy set in the Clash API; the pending marker was retained with a retry pause", "warn");
        return 1;
    }

    log_message((as_string(start_kind) == "resume" ? "Resuming interrupted" : "Starting new") +
        " automatic latency test for " + length(proxy_tags) + " independent proxy outbounds", "info");
    let status = 0;
    let completed = 0;
    let batch_size = AUTOMATIC_LATENCY_BATCH_SIZE > 0 ? AUTOMATIC_LATENCY_BATCH_SIZE : 4;
    for (let proxy_tag in proxy_tags) {
        if (!automatic_latency_marker_matches(pending_signature, pending_generation)) {
            module_success(SERVICE_STATE_UC, [ "release-runtime-dir-lock", AUTOMATIC_LATENCY_TEST_LOCK_DIR ]);
            module_success(SERVICE_STATE_UC, [ "release-runtime-dir-lock", RELOAD_LOCK_DIR ]);
            log_message("Automatic latency test was canceled because its pending generation was replaced", "info");
            return 0;
        }
        if (module_success(SERVICE_UI_UC, [ "package-upgrade-transition-active" ])) {
            module_success(SERVICE_STATE_UC, [ "release-runtime-dir-lock", AUTOMATIC_LATENCY_TEST_LOCK_DIR ]);
            module_success(SERVICE_STATE_UC, [ "release-runtime-dir-lock", RELOAD_LOCK_DIR ]);
            log_message("Automatic latency test yielded to a Forkop package upgrade", "info");
            return 0;
        }
        if (clash_api("get_proxy_latency", proxy_tag, "5000", "") != 0)
            status = 1;
        completed++;

        if (completed < length(proxy_tags) && completed % batch_size == 0) {
            module_success(SERVICE_STATE_UC, [ "release-runtime-dir-lock", RELOAD_LOCK_DIR ]);
            let pending_reload_requested = fs.stat(PENDING_RELOAD_FILE) != null;
            if (pending_reload_requested) {
                module_success(SERVICE_STATE_UC, [ "release-runtime-dir-lock", AUTOMATIC_LATENCY_TEST_LOCK_DIR ]);
                automatic_latency_yield_to_pending_reload();
                log_message("Automatic latency test yielded to a pending Forkop reload", "info");
                return 0;
            }
            command_success_from_args([ "sleep", AUTOMATIC_LATENCY_BATCH_PAUSE ]);
            let reacquired = module_success(SERVICE_STATE_UC, [
                "acquire-runtime-dir-lock-wait-until-package-upgrade", RELOAD_LOCK_DIR, owner_pid, "300"
            ]);
            if (!reacquired || !module_success(SERVICE_STATE_UC, [ "single-ready-sing-box-runtime" ]) ||
                sing_box_pid_before != trim(module_output(SERVICE_STATE_UC, [ "sing-box-service-runtime-pid" ]))) {
                if (reacquired)
                    module_success(SERVICE_STATE_UC, [ "release-runtime-dir-lock", RELOAD_LOCK_DIR ]);
                module_success(SERVICE_STATE_UC, [ "release-runtime-dir-lock", AUTOMATIC_LATENCY_TEST_LOCK_DIR ]);
                if (pending_reload_requested) {
                    log_message("Automatic latency test was interrupted by reload; the pending reload will resume it after sing-box is ready", "info");
                }
                else {
                    log_message("Automatic latency test was interrupted by reload; resuming automatically after sing-box is ready", "info");
                    automatic_latency_schedule_resume();
                }
                return 0;
            }
        }
    }
    module_success(SERVICE_STATE_UC, [ "release-runtime-dir-lock", AUTOMATIC_LATENCY_TEST_LOCK_DIR ]);
    module_success(SERVICE_STATE_UC, [ "release-runtime-dir-lock", RELOAD_LOCK_DIR ]);
    // A reload is normally detected between batches through its PID/lock. A
    // non-restarting config change can still replace the proxy set, so never
    // acknowledge the old marker after its semantic generation changed.
    if (proxy_outbounds_signature_value(config_path) != pending_signature) {
        log_message("Automatic latency test finished against a stale proxy generation; the pending marker was retained", "info");
        return 0;
    }
    if (status == 0) {
        automatic_latency_remove_marker(pending_signature, pending_generation);
        log_message("Automatic latency test completed successfully; the pending marker was removed", "info");
    }
    else {
        automatic_latency_record_failure(pending_signature, pending_generation);
        log_message("Automatic latency test completed with errors; the pending marker was retained with a retry pause", "warn");
    }
    return status;
}

function print_global(message) {
    print(as_string(message), "\n");
}

function render_or_fail(mode_args, input, fail_message, ok_statuses) {
    let result = status_capture(mode_args, input);
    if (result.output != "")
        print(result.output);
    for (let status in ok_statuses)
        if (result.status == status)
            return result.status;
    print_global(fail_message);
    return result.status;
}

function global_check(arg1, arg2) {
    let visibility = as_string(arg2 || "masked");
    if (as_string(arg1) == "raw" || as_string(arg1) == "masked")
        visibility = as_string(arg1);

    print_global("📡 Global check run!");
    print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    print_global("🛠️ System info");

    let system_info_json = sprintf("%J", build_system_info());
    render_or_fail([ "global-system-info" ], system_info_json, "❌ Failed to parse system info", [ 0 ]);

    print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    print_global("➡️ DNS status");

    let dns_check_capture = command_capture(command_from_args(module_args(LIB_DIR + "/diagnostics/runtime.uc", [ "check-dns-available" ])));
    if (dns_check_capture.output != "") {
        let dns_render = render_or_fail(
            [ "global-dns-check", bool_option(settings(), "dont_touch_dhcp", false) ? "1" : "0" ],
            dns_check_capture.output,
            "❌ Failed to parse DNS info",
            [ 0, 10 ]
        );
        if (dns_render == 10)
            print(status_output([ "dhcp-dnsmasq-config", "/etc/config/dhcp" ], null));
    }
    else
        print_global("❌ Failed to get DNS info");

    print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    print_global("📦 Sing-box status");
    let singbox_check_json = command_capture(command_from_args(module_args(LIB_DIR + "/diagnostics/runtime.uc", [ "check-sing-box" ]))).output;
    if (singbox_check_json != "")
        render_or_fail([ "global-sing-box-check" ], singbox_check_json, "❌ Failed to parse sing-box info", [ 0 ]);
    else
        print_global("❌ Failed to get sing-box info");

    print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    print_global("🧱 NFT rules status");
    let nft_check_json = command_capture(command_from_args(module_args(LIB_DIR + "/diagnostics/runtime.uc", [ "check-nft-rules" ]))).output;
    if (nft_check_json != "") {
        let nft_render = render_or_fail([ "global-nft-check" ], nft_check_json, "❌ Failed to parse NFT rules info", [ 0 ]);
        if (nft_render == 0 && status_success([ "global-nft-other-mark-exists" ], nft_check_json))
            print(status_output([ "nft-ruleset-other-mark-lines", NFT_TABLE_NAME ], command_output_from_args([ "nft", "list", "ruleset" ])));
    }
    else
        print_global("❌ Failed to get NFT rules info");

    print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    print_global("📄 Forkop config");
    show_config(visibility);

    print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    print_global("🧪 Forkop configuration validation");
    let validation = module_capture(LIB_DIR + "/config/validator.uc", [ "validate-runtime" ]);
    if (validation.status == 0)
        print_global("✅ Forkop configuration is valid");
    else {
        let message = trim(as_string(validation.output));
        print_global(message == "" ? "❌ Forkop configuration validation failed" : "❌ " + message);
    }

    print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    print_global("📄 WAN config");
    if (uci_show("network.wan")) {
        if (visibility == "raw")
            print(as_string(fs.readfile("/etc/config/network")));
        else
            print(status_output([ "wan-config-masked", "/etc/config/network" ], null));
    }
    else
        print_global("❌ WAN configuration not found");

    let network_show = network_show_data();
    for (let line in split(status_output([ "network-endpoint-host-warnings", CLOUDFLARE_OCTETS ], network_show), "\n")) {
        if (line == "")
            continue;
        let fields = split(line, "\t");
        if (length(fields) < 2)
            continue;
        if (fields[0] == "engage")
            print_global("⚠️ WARP detected: " + fields[1]);
        else if (fields[0] == "prefix") {
            print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
            print_global("⚠️ WARP detected: " + fields[1]);
        }
    }

    for (let peer_section in split(status_output([ "network-wireguard-route-allowed-peers" ], network_show), "\n")) {
        peer_section = as_string(peer_section);
        if (peer_section == "")
            continue;
        let default_routes = allowed_ips_default_routes(uci_get(peer_section + ".allowed_ips"));
        if (length(default_routes) > 0) {
            print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
            print_global("⚠️ WG Route allowed IP enabled with " + join(", ", default_routes));
        }
    }

    if (file_executable("/etc/init.d/zapret") && command_success_from_args([ "/etc/init.d/zapret", "status" ])) {
        print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
        print_global("⚠️ Standalone zapret service is active. Forkop uses separate queues, but packet-level policy overlap is possible.");
    }
    else if (file_executable("/etc/init.d/zapret") && command_success_from_args([ "/etc/init.d/zapret", "enabled" ])) {
        print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
        print_global("⚠️ Standalone zapret autostart is enabled. Forkop will not modify /etc/config/zapret.");
    }

    if (file_executable("/etc/init.d/zapret2") && command_success_from_args([ "/etc/init.d/zapret2", "status" ])) {
        print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
        print_global("⚠️ Standalone zapret2 service is active. Forkop uses separate queues, but packet-level policy overlap is possible.");
    }
    else if (file_executable("/etc/init.d/zapret2") && command_success_from_args([ "/etc/init.d/zapret2", "enabled" ])) {
        print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
        print_global("⚠️ Standalone zapret2 autostart is enabled. Forkop will not modify /etc/config/zapret2.");
    }

    print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    print_global("🥸 FakeIP status");
    let fakeip_check_json = command_capture(command_from_args(module_args(LIB_DIR + "/diagnostics/runtime.uc", [ "check-fakeip" ]))).output;
    if (fakeip_check_json != "")
        render_or_fail([ "global-fakeip-check" ], fakeip_check_json, "❌ Failed to parse FakeIP info", [ 0 ]);
    else
        print_global("❌ Failed to get FakeIP info");

    return 0;
}

function support_report_heading(title) {
    print("\n=== ", as_string(title), " ===\n");
}

function support_report_command(title, args) {
    support_report_heading(title);
    let result = command_capture(command_from_args(args) + " 2>&1");
    print(result.output != "" ? result.output : "(no output)\n");
    if (result.status != 0)
        print("[exit status: ", result.status, "]\n");
}

function support_report_file(title, path) {
    support_report_heading(title);
    let data = fs.readfile(path);
    if (data == null) {
        print("(file not found: ", path, ")\n");
        return;
    }

    let text = as_string(data);
    print(text);
    if (length(text) == 0 || substr(text, length(text) - 1) != "\n")
        print("\n");
}

function support_report() {
    print("⚠️ CONFIDENTIAL SUPPORT REPORT / КОНФИДЕНЦИАЛЬНЫЙ ОТЧЁТ ДЛЯ ПОДДЕРЖКИ\n\n");
    print("This file contains proxy and subscription URLs, UUIDs, passwords, keys, tokens, client domains and IP addresses, process command lines, and network configuration. Share it only with a trusted support specialist.\n\n");
    print("Файл содержит ссылки прокси и подписок, UUID, пароли, ключи, токены, домены и IP-адреса клиентов, параметры процессов и сетевую конфигурацию. Передавайте его только доверенному специалисту.\n\n");
    print("Generated: ", trim(command_output_from_args([ "date", "-Iseconds" ])), "\n");
    print("Forkop version: ", FORKOP_VERSION, "\n");

    support_report_heading("Global check (raw)");
    global_check("raw", "raw");

    support_report_heading("Generated sing-box configuration (raw)");
    show_sing_box_config("raw");

    support_report_command("System uptime", [ "uptime" ]);
    support_report_command("Memory", [ "free" ]);
    support_report_command("Filesystems", [ "df", "-h" ]);
    support_report_command("Processes and full arguments", [ "ps", "w" ]);
    support_report_command("Listening sockets", [ "netstat", "-lnp" ]);
    support_report_command("IPv4 addresses", [ "ip", "-4", "-details", "address", "show" ]);
    support_report_command("IPv6 addresses", [ "ip", "-6", "-details", "address", "show" ]);
    support_report_command("IPv4 rules", [ "ip", "-4", "rule", "show" ]);
    support_report_command("IPv6 rules", [ "ip", "-6", "rule", "show" ]);
    support_report_command("IPv4 routes (all tables)", [ "ip", "-4", "route", "show", "table", "all" ]);
    support_report_command("IPv6 routes (all tables)", [ "ip", "-6", "route", "show", "table", "all" ]);

    support_report_heading("Forkop nftables summary and set sizes");
    check_nft();
    support_report_command("nftables ruleset with handles (set contents omitted)", [ "nft", "-a", "-t", "list", "ruleset" ]);

    support_report_file("/etc/config/forkop", FORKOP_CONFIG);
    support_report_file("/etc/config/dhcp", "/etc/config/dhcp");
    support_report_file("/etc/config/network", "/etc/config/network");
    support_report_file("/etc/config/firewall", "/etc/config/firewall");
    support_report_command("Forkop runtime files", [ "ls", "-laR", RUNTIME_STATE_DIR ]);
    support_report_command("Sing-box runtime files", [ "ls", "-laR", TMP_SING_BOX_FOLDER ]);
    support_report_command("Recent system log", [ "logread", "-l", "500" ]);
    support_report_command("Kernel log", [ "dmesg" ]);
    return 0;
}

let mode = ARGV[0] || "";

if (mode == "check-proxy")
    exit(check_proxy());
else if (mode == "check-nft")
    exit(check_nft());
else if (mode == "check-nft-rules")
    exit(check_nft_rules());
else if (mode == "check-sing-box")
    exit(check_sing_box());
else if (mode == "automatic-latency-proxy-tags-fixture")
    automatic_latency_proxy_tags_fixture();
else if (mode == "check-logs")
    exit(check_logs());
else if (mode == "check-sing-box-logs")
    exit(check_sing_box_logs());
else if (mode == "check-fakeip")
    exit(check_fakeip());
else if (mode == "fakeip-public-ip-comparison-available-fixture")
    fakeip_public_ip_comparison_available_fixture(ARGV[1]);
else if (mode == "check-fakeip-fixture")
    exit(check_fakeip_fixture(ARGV[1]));
else if (mode == "check-zapret-runtime")
    exit(module_passthrough(ZAPRET_RUNTIME_UC, [ "check" ]));
else if (mode == "check-zapret2-runtime")
    exit(module_passthrough(ZAPRET2_RUNTIME_UC, [ "check" ]));
else if (mode == "neutralize-zapret-defaults")
    exit(neutralize_zapret_defaults());
else if (mode == "clash-api")
    exit(clash_api(ARGV[1], ARGV[2], ARGV[3], ARGV[4]));
else if (mode == "clash-api-ready")
    exit(clash_api_ready() ? 0 : 1);
else if (mode == "proxy-outbounds-signature")
    exit(print_proxy_outbounds_signature(ARGV[1]));
else if (mode == "automatic-latency-test")
    exit(automatic_latency_test(ARGV[1]));
else if (mode == "show-config")
    exit(show_config(ARGV[1] || "masked"));
else if (mode == "show-version")
    exit(show_version());
else if (mode == "show-sing-box-config")
    exit(show_sing_box_config(ARGV[1] || "masked"));
else if (mode == "show-sing-box-version")
    exit(show_sing_box_version());
else if (mode == "get-status")
    exit(get_status());
else if (mode == "get-outbound-metadata")
    exit(get_outbound_metadata(ARGV[1]));
else if (mode == "get-subscription-metadata")
    exit(get_subscription_metadata(ARGV[1]));
else if (mode == "get-sing-box-status")
    exit(get_sing_box_status());
else if (mode == "get-zapret-status")
    exit(module_passthrough(ZAPRET_RUNTIME_UC, [ "status" ]));
else if (mode == "get-zapret2-status")
    exit(module_passthrough(ZAPRET2_RUNTIME_UC, [ "status" ]));
else if (mode == "get-system-info")
    exit(get_system_info());
else if (mode == "check-dns-available")
    exit(check_dns_available());
else if (mode == "global-check")
    exit(global_check(ARGV[1] || "", ARGV[2] || ""));
else if (mode == "support-report")
    exit(support_report());
else if (mode == "validate-nfqws-strategy-json")
    exit(validate_nfqws_strategy_json(ARGV[1] || ""));
else if (mode == "validate-nfqws2-strategy-json")
    exit(validate_nfqws2_strategy_json(ARGV[1] || ""));
else {
    warn("Usage: diagnostics/runtime.uc <operation> ...\n");
    exit(1);
}
