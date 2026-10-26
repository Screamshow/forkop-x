#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let constants = require("core.constants");
let uci_core = require("core.uci");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function constant_value(name, fallback) {
    let value = constants[name];
    return value == null ? as_string(fallback) : as_string(value);
}

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || constant_value("FORKOP_CONFIG_NAME", "forkop");
const CONFIG_FILE = getenv("FORKOP_CONFIG_FILE") || "/etc/config/" + CONFIG_NAME;
const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const HOT_RELOAD_UC = LIB_DIR + "/service/hot_reload.uc";
const BIN_PATH = getenv("FORKOP_BIN") || constant_value("FORKOP_BIN", "/usr/bin/forkop");
const SERVICE_INIT = getenv("FORKOP_SERVICE_INIT") || constant_value("FORKOP_SERVICE_INIT", "/etc/init.d/forkop");
const SERVICE_NAME = getenv("FORKOP_SERVICE_NAME") || constant_value("FORKOP_SERVICE_NAME", "forkop");
const LUCI_VIEW_DIR = getenv("FORKOP_LUCI_VIEW_DIR") || constant_value("FORKOP_LUCI_VIEW_DIR", "/www/luci-static/resources/view/forkop");
const LUCI_I18N_DOMAIN = getenv("FORKOP_LUCI_I18N_DOMAIN") || constant_value("FORKOP_LUCI_I18N_DOMAIN", "forkop");

const RUNTIME_STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const SYSTEM_INFO_CACHE_FILE = getenv("FORKOP_SYSTEM_INFO_CACHE_FILE") || RUNTIME_STATE_DIR + "/system-info.json";
const RELOAD_STATE_FILE = getenv("FORKOP_RELOAD_STATE_FILE") || RUNTIME_STATE_DIR + "/reload-state";
const RELOAD_STATE_SNAPSHOT_FILE = getenv("FORKOP_RELOAD_STATE_SNAPSHOT_FILE") || RUNTIME_STATE_DIR + "/reload-state.snapshot." + clock()[0] + "." + clock()[1];
const PENDING_RELOAD_FILE = getenv("FORKOP_PENDING_RELOAD_FILE") || RUNTIME_STATE_DIR + "/reload.pending";
const LIST_UPDATE_RELOAD_FILE = getenv("FORKOP_LIST_UPDATE_RELOAD_FILE") || RUNTIME_STATE_DIR + "/list-update.reload";
const RULESET_REFRESH_AFTER_LIST_FILE = getenv("FORKOP_RULESET_REFRESH_AFTER_LIST_FILE") || RUNTIME_STATE_DIR + "/ruleset-refresh-after-list";
const POST_START_LATENCY_FILE = getenv("FORKOP_POST_START_LATENCY_FILE") || RUNTIME_STATE_DIR + "/post-start-latency.pending";
const START_FAILURE_FILE = getenv("FORKOP_START_FAILURE_FILE") || RUNTIME_STATE_DIR + "/start.failure";
const WATCHDOG_READY_FILE = getenv("FORKOP_WATCHDOG_READY_FILE") || RUNTIME_STATE_DIR + "/watchdog.ready";
const RUNTIME_CONFIG_ERROR_FILE = getenv("FORKOP_RUNTIME_CONFIG_ERROR_FILE") || RUNTIME_STATE_DIR + "/config-error";
const MANAGED_UPGRADE_SING_BOX_MARKER = getenv("FORKOP_MANAGED_UPGRADE_SING_BOX_MARKER") || "/tmp/forkop-managed-upgrade-sing-box";
const MANAGED_UPGRADE_SING_BOX_WAIT_SECONDS = int(getenv("FORKOP_MANAGED_UPGRADE_SING_BOX_WAIT_SECONDS") || "15");
const MANAGED_UPGRADE_SING_BOX_MARKER_MAX_AGE_SECONDS = int(getenv("FORKOP_MANAGED_UPGRADE_SING_BOX_MARKER_MAX_AGE_SECONDS") || "120");
const SERVICE_TRIGGER_SYNC_FILE = getenv("FORKOP_SERVICE_TRIGGER_SYNC_FILE") || RUNTIME_STATE_DIR + "/service-triggers.sync";
const SUBSCRIPTION_UPDATE_STATE_DIR = getenv("FORKOP_SUBSCRIPTION_UPDATE_STATE_DIR") || RUNTIME_STATE_DIR + "/subscription-update";
const SUBSCRIPTION_LINKS_DIR = getenv("FORKOP_SUBSCRIPTION_LINKS_DIR") || RUNTIME_STATE_DIR + "/subscription-links";
const SUBSCRIPTION_METADATA_DIR = getenv("FORKOP_SUBSCRIPTION_METADATA_DIR") || RUNTIME_STATE_DIR + "/subscription-metadata";
const OUTBOUND_METADATA_DIR = getenv("FORKOP_OUTBOUND_METADATA_DIR") || RUNTIME_STATE_DIR + "/outbound-metadata";
const SECTION_CACHE_DIR = getenv("FORKOP_SECTION_CACHE_DIR") || RUNTIME_STATE_DIR + "/section-cache";
const RULE_CONDITION_CACHE_DIR = getenv("FORKOP_RULE_CONDITION_CACHE_DIR") || RUNTIME_STATE_DIR + "/rule-condition-cache";
const RUNTIME_CACHE_FORMAT_FILE = getenv("FORKOP_RUNTIME_CACHE_FORMAT_FILE") || RUNTIME_STATE_DIR + "/cache-format";
const PERSISTENT_SUBSCRIPTION_CACHE_DIR = getenv("FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR") || "/etc/forkop/subscription-cache";
const PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE = getenv("FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE") || PERSISTENT_SUBSCRIPTION_CACHE_DIR + "/cache-format";
const PERSISTENT_SUBSCRIPTION_CACHE_FORMAT = getenv("FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT") || "9";
const LIFECYCLE_UC = LIB_DIR + "/service/lifecycle.uc";
const SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE = getenv("FORKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE") || RUNTIME_STATE_DIR + "/subscription-bootstrap-retry.pid";
const DNS_FAILOVER_STATE_FILE = getenv("FORKOP_DNS_FAILOVER_STATE_FILE") || RUNTIME_STATE_DIR + "/dns-failover.json";
const DNS_FAILOVER_PID_FILE = getenv("FORKOP_DNS_FAILOVER_PID_FILE") || RUNTIME_STATE_DIR + "/dns-failover.pid";
const SUBSCRIPTION_UPDATE_LOCK_DIR = getenv("FORKOP_SUBSCRIPTION_UPDATE_LOCK_DIR") || RUNTIME_STATE_DIR + "/subscription-update.lock";
const RELOAD_LOCK_DIR = getenv("FORKOP_RELOAD_LOCK_DIR") || "/var/run/forkop.reload.lock";
const INTERNAL_CONFIG_TRIGGER_GUARD = getenv("FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD") || "/var/run/forkop.internal-config-change";

const LIST_UPDATE_CRON_MARKER = getenv("FORKOP_LIST_UPDATE_CRON_MARKER") || "# forkop-list-update";
const SUBSCRIPTION_UPDATE_CRON_MARKER = getenv("FORKOP_SUBSCRIPTION_UPDATE_CRON_MARKER") || "# forkop-subscription-update";
const COMPONENT_UPDATE_CHECK_CRON_MARKER = getenv("FORKOP_COMPONENT_UPDATE_CHECK_CRON_MARKER") || "# forkop-component-update-check";
const RELOAD_STATE_FORMAT = int(getenv("FORKOP_RELOAD_STATE_FORMAT") || "1");
const RUNTIME_CACHE_FORMAT = int(getenv("FORKOP_RUNTIME_CACHE_FORMAT") || "10");
const RUNTIME_STABLE_MIN_AGE = int(getenv("FORKOP_RUNTIME_STABLE_MIN_AGE") || "2");
const SING_BOX_START_STABLE_MIN_AGE = int(getenv("FORKOP_SING_BOX_START_STABLE_MIN_AGE") || "8");
const SING_BOX_START_VERIFY_TIMEOUT = int(getenv("FORKOP_SING_BOX_START_VERIFY_TIMEOUT") || "10");
const NFT_POPULATE_ENABLED_DEFAULT = int(getenv("FORKOP_NFT_POPULATE_ENABLED") || "1");

let permanent_start_failure = false;

const TMP_SING_BOX_FOLDER = getenv("TMP_SING_BOX_FOLDER") || constant_value("TMP_SING_BOX_FOLDER", "/tmp/sing-box");
const TMP_RULESET_FOLDER = getenv("TMP_RULESET_FOLDER") || constant_value("TMP_RULESET_FOLDER", TMP_SING_BOX_FOLDER + "/rulesets");
const TMP_SUBSCRIPTION_FOLDER = getenv("TMP_SUBSCRIPTION_FOLDER") || constant_value("TMP_SUBSCRIPTION_FOLDER", TMP_SING_BOX_FOLDER + "/subscriptions");

const RT_TABLE_NAME = constant_value("RT_TABLE_NAME", "forkop");
const NFT_TABLE_NAME = constant_value("NFT_TABLE_NAME", "ForkopTable");
const NFT_LOCALV4_SET_NAME = constant_value("NFT_LOCALV4_SET_NAME", "localv4");
const NFT_LOCALV6_SET_NAME = constant_value("NFT_LOCALV6_SET_NAME", "localv6");
const NFT_COMMON_SET_NAME = constant_value("NFT_COMMON_SET_NAME", "forkop_subnets");
const NFT_COMMON6_SET_NAME = constant_value("NFT_COMMON6_SET_NAME", "forkop_subnets6");
const NFT_PORT_SET_NAME = constant_value("NFT_PORT_SET_NAME", "forkop_ports");
const NFT_IP_PORT_SET_NAME = constant_value("NFT_IP_PORT_SET_NAME", "forkop_ip_ports");
const NFT_IP_PORT6_SET_NAME = constant_value("NFT_IP_PORT6_SET_NAME", "forkop_ip6_ports");
const NFT_INTERFACE_SET_NAME = constant_value("NFT_INTERFACE_SET_NAME", "forkop_interfaces");
const NFT_FAKEIP_MARK = constant_value("NFT_FAKEIP_MARK", "0x04000000");
const NFT_OUTBOUND_MARK = constant_value("NFT_OUTBOUND_MARK", "0x08000000");

const SB_FAKEIP_INET4_RANGE = constant_value("SB_FAKEIP_INET4_RANGE", "198.18.0.0/15");
const SB_FAKEIP_INET6_RANGE = constant_value("SB_FAKEIP_INET6_RANGE", "fc00::/18");
const SB_TPROXY_INBOUND6_ADDRESS = constant_value("SB_TPROXY_INBOUND6_ADDRESS", "::1");
const SB_TPROXY_INBOUND_PORT = constant_value("SB_TPROXY_INBOUND_PORT", "1602");
const SB_SERVICE_MIXED_INBOUND_ADDRESS = constant_value("SB_SERVICE_MIXED_INBOUND_ADDRESS", "127.0.0.1");
const SB_SERVICE_MIXED_INBOUND_PORT = constant_value("SB_SERVICE_MIXED_INBOUND_PORT", "4534");
const SB_VARIANT_STATE_FILE = constant_value("SB_VARIANT_STATE_FILE", "/etc/forkop/sing-box-variant");
const SB_VERSION_STATE_FILE = constant_value("SB_VERSION_STATE_FILE", "/etc/forkop/sing-box-version");

const ZAPRET_PROVIDER_NFQWS_BIN = constant_value("ZAPRET_PROVIDER_NFQWS_BIN", "/opt/zapret/nfq/nfqws");
const ZAPRET_ROUTE_MARK_BASE = constant_value("ZAPRET_ROUTE_MARK_BASE", "0x01000000");
const ZAPRET_QUEUE_BASE = constant_value("ZAPRET_QUEUE_BASE", "4000");
const ZAPRET_DESYNC_MARK = constant_value("ZAPRET_DESYNC_MARK", "0x40000000");
const ZAPRET_DESYNC_MARK_POSTNAT = constant_value("ZAPRET_DESYNC_MARK_POSTNAT", "0x20000000");
const ZAPRET2_PROVIDER_NFQWS2_BIN = constant_value("ZAPRET2_PROVIDER_NFQWS2_BIN", "/opt/zapret2/nfq2/nfqws2");
const ZAPRET2_ROUTE_MARK_BASE = constant_value("ZAPRET2_ROUTE_MARK_BASE", "0x02000000");
const ZAPRET2_QUEUE_BASE = constant_value("ZAPRET2_QUEUE_BASE", "4300");
const ZAPRET2_DESYNC_MARK = constant_value("ZAPRET2_DESYNC_MARK", "0x40000000");
const ZAPRET2_DESYNC_MARK_POSTNAT = constant_value("ZAPRET2_DESYNC_MARK_POSTNAT", "0x20000000");

const DNS_APPLY_UC = LIB_DIR + "/dns/apply.uc";
const VALIDATOR_UC = LIB_DIR + "/config/validator.uc";
const NFT_UC = LIB_DIR + "/nft/apply.uc";
const SINGBOX_UC = LIB_DIR + "/singbox/runtime.uc";
const PRIORITY_UC = LIB_DIR + "/singbox/priority.uc";
const DNS_FAILOVER_UC = LIB_DIR + "/singbox/dns_failover.uc";
const SUBSCRIPTION_CACHE_UC = LIB_DIR + "/subscription/cache.uc";
const RULESET_CACHE_UC = LIB_DIR + "/singbox/ruleset_cache.uc";
const UPDATES_UC = LIB_DIR + "/components/updates.uc";
const STATE_UC = LIB_DIR + "/service/state.uc";
const RELOAD_UC = LIB_DIR + "/service/reload.uc";
const UI_UC = LIB_DIR + "/service/ui.uc";
const DIAGNOSTICS_UC = LIB_DIR + "/diagnostics/runtime.uc";
const AUTOMATIC_LATENCY_PENDING_FILE = getenv("FORKOP_AUTOMATIC_LATENCY_PENDING_FILE") || "/etc/forkop/automatic-latency-test.pending";
const ZAPRET_UC = LIB_DIR + "/providers/zapret/runtime.uc";
const ZAPRET2_UC = LIB_DIR + "/providers/zapret2/runtime.uc";
const PACKAGES_UC = LIB_DIR + "/core/packages.uc";

let start_subscription_update_lock_held = false;
let subscription_caches_prepared = getenv("FORKOP_SUBSCRIPTION_CACHES_PREPARED") || "0";
let subscription_runtime_no_refresh = getenv("FORKOP_SUBSCRIPTION_RUNTIME_NO_REFRESH") || "0";
let subscription_deferred_sections = "";
let nft_populate_enabled = NFT_POPULATE_ENABLED_DEFAULT;
let nft_candidate_batch_file = "";
let list_change_rollback_dir = "";
let rule_condition_cache_enabled = 0;
let startup_config_fingerprint = "";

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

function command_success(command) {
    return command_status(command + " >/dev/null 2>&1") == 0;
}

function command_status_from_args(args) {
    return command_status(command_from_args(args));
}

function command_output_from_args(args) {
    return command_output(command_from_args(args) + " 2>/dev/null");
}

function command_success_from_args(args) {
    return command_status(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function external_config_fingerprint() {
    let data = fs.readfile(CONFIG_FILE);
    if (data == null)
        return "";

    let lines = [];
    for (let line in split(as_string(data), "\n"))
        if (match(as_string(line), /^[ \t]*option[ \t]+shutdown_correctly([ \t]|$)/) == null)
            push(lines, line);

    return join("\n", lines);
}

function trim(value) {
    return replace(as_string(value), /^[ \t\r\n]+|[ \t\r\n]+$/g, "");
}

function owner_pid() {
    // fs.popen() spawns an intermediate shell, so querying $PPID from that
    // shell records a PID which exits immediately.  A tracked reload can run
    // longer than the stale-job grace period and LuCI would then expose Start
    // while the reload is still changing the runtime.
    let stat = as_string(fs.readfile("/proc/self/stat"));
    let separator = index(stat, " ");
    let pid = separator > 0 ? substr(stat, 0, separator) : "";
    return match(pid, /^[0-9]+$/) != null ? pid : "0";
}

function bool_text(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function string_array_contains(values, needle) {
    needle = as_string(needle);
    if (needle == "")
        return false;

    for (let item in array_or_empty(values))
        if (as_string(item) == needle)
            return true;

    return false;
}

function write_file(path, value) {
    return fs.writefile(as_string(path), as_string(value));
}

function remove_file(path) {
    return fs.unlink(as_string(path)) || true;
}

function ensure_dir(path) {
    path = as_string(path);
    return path == "" || fs.mkdir(path, 0755) || fs.stat(path) != null;
}

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", SERVICE_NAME, "[" + level + "] " + as_string(message) ]);
}

function lifecycle_env() {
    let result = {
        FORKOP_CONFIG_NAME: CONFIG_NAME,
        FORKOP_LIB: LIB_DIR,
        FORKOP_BIN: BIN_PATH,
        FORKOP_SERVICE_INIT: SERVICE_INIT,
        FORKOP_RUNTIME_STATE_DIR: RUNTIME_STATE_DIR,
        FORKOP_SYSTEM_INFO_CACHE_FILE: SYSTEM_INFO_CACHE_FILE,
        FORKOP_SUBSCRIPTION_UPDATE_STATE_DIR: SUBSCRIPTION_UPDATE_STATE_DIR,
        FORKOP_SUBSCRIPTION_LINKS_DIR: SUBSCRIPTION_LINKS_DIR,
        FORKOP_SUBSCRIPTION_METADATA_DIR: SUBSCRIPTION_METADATA_DIR,
        FORKOP_OUTBOUND_METADATA_DIR: OUTBOUND_METADATA_DIR,
        FORKOP_SECTION_CACHE_DIR: SECTION_CACHE_DIR,
        FORKOP_RULE_CONDITION_CACHE_DIR: RULE_CONDITION_CACHE_DIR,
        FORKOP_RUNTIME_CACHE_FORMAT_FILE: RUNTIME_CACHE_FORMAT_FILE,
        FORKOP_RUNTIME_CACHE_FORMAT: as_string(RUNTIME_CACHE_FORMAT),
        FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR: PERSISTENT_SUBSCRIPTION_CACHE_DIR,
        FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE: PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE,
        FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT: PERSISTENT_SUBSCRIPTION_CACHE_FORMAT,
        FORKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE: SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE,
        FORKOP_DNS_FAILOVER_STATE_FILE: DNS_FAILOVER_STATE_FILE,
        FORKOP_DNS_FAILOVER_PID_FILE: DNS_FAILOVER_PID_FILE,
        FORKOP_SUBSCRIPTION_UPDATE_LOCK_DIR: SUBSCRIPTION_UPDATE_LOCK_DIR,
        FORKOP_PENDING_RELOAD_FILE: PENDING_RELOAD_FILE,
        FORKOP_RELOAD_LOCK_DIR: RELOAD_LOCK_DIR,
        FORKOP_NFT_BATCH_FILE: nft_candidate_batch_file,
        FORKOP_NFT_CANDIDATE_FAIL_PHASE: getenv("FORKOP_NFT_CANDIDATE_FAIL_PHASE") || "",
        FORKOP_SINGBOX_CONFIG_FAIL_PHASE: getenv("FORKOP_SINGBOX_CONFIG_FAIL_PHASE") || "",
        // Test-only bounded readiness fault injection is forwarded to the
        // state module. Empty in production, where its normal timeout stays
        // unchanged.
        FORKOP_SING_BOX_RELOAD_PID_TIMEOUT: getenv("FORKOP_SING_BOX_RELOAD_PID_TIMEOUT") || "",
        TMP_SING_BOX_FOLDER: TMP_SING_BOX_FOLDER,
        TMP_RULESET_FOLDER: TMP_RULESET_FOLDER,
        TMP_SUBSCRIPTION_FOLDER: TMP_SUBSCRIPTION_FOLDER,
        SB_SERVICE_MIXED_INBOUND_ADDRESS: SB_SERVICE_MIXED_INBOUND_ADDRESS,
        SB_SERVICE_MIXED_INBOUND_PORT: SB_SERVICE_MIXED_INBOUND_PORT,
        SB_VARIANT_STATE_FILE: SB_VARIANT_STATE_FILE,
        SB_VERSION_STATE_FILE: SB_VERSION_STATE_FILE,
        ZAPRET_PROVIDER_NFQWS_BIN: ZAPRET_PROVIDER_NFQWS_BIN,
        ZAPRET2_PROVIDER_NFQWS2_BIN: ZAPRET2_PROVIDER_NFQWS2_BIN,
        FORKOP_RULE_CONDITION_CACHE_ENABLED: as_string(rule_condition_cache_enabled)
    };

    return result;
}

function command_env(assignments) {
    let parts = [];
    for (let name, value in assignments)
        push(parts, as_string(name) + "=" + shell_quote(value));
    return join(" ", parts);
}

function module_args(module_path, args) {
    let result = [ "ucode", "-L", LIB_DIR, module_path ];
    for (let arg in (type(args) == "array" ? args : []))
        push(result, arg);
    return result;
}

function module_command(module_path, args) {
    return command_env(lifecycle_env()) + " " + command_from_args(module_args(module_path, args));
}

function module_capture(module_path, args) {
    return command_capture(module_command(module_path, args));
}

function module_status(module_path, args) {
    return command_status(module_command(module_path, args));
}

function module_status_with_env(module_path, args, additions) {
    return command_status(command_env(lifecycle_env()) + " " + command_env(additions) + " " + command_from_args(module_args(module_path, args)));
}

function module_success(module_path, args) {
    return module_status(module_path, args) == 0;
}

function validation_failure_message(result) {
    for (let line in split(as_string(result.output), "\n")) {
        line = trim(line);
        if (line != "")
            return line;
    }

    return "The configuration could not be validated. Aborted.";
}

function mark_pending_reload(reason) {
    return module_success(STATE_UC, [ "mark-pending-reload", PENDING_RELOAD_FILE, reason ]);
}

function pending_reload_log_context(reason) {
    reason = as_string(reason);
    if (reason == "config_changed_during_reload")
        return "current reload";
    return "startup";
}

function mark_pending_reload_if_config_changed(initial_fingerprint, reason) {
    initial_fingerprint = as_string(initial_fingerprint);
    if (initial_fingerprint == "")
        return false;

    let current_fingerprint = external_config_fingerprint();
    if (current_fingerprint == "" || current_fingerprint == initial_fingerprint)
        return false;

    let context = pending_reload_log_context(reason);
    if (mark_pending_reload(reason)) {
        log_message("Configuration changed during " + context + "; queued reload after " + context + " completes", "info");
        return true;
    }

    log_message("Configuration changed during " + context + ", but pending reload could not be queued", "warn");
    return false;
}

function module_output(module_path, args) {
    let result = module_capture(module_path, args);
    return result.status == 0 ? result.output : "";
}

function selector_state_from_proxies_payload(payload) {
    let result = {};
    let proxies = object_or_empty(object_or_empty(payload).proxies);

    for (let tag, proxy in proxies) {
        proxy = object_or_empty(proxy);
        let proxy_type = lc(as_string(proxy.type || ""));
        let selected = as_string(proxy.now || "");

        if (proxy_type == "selector" && string_array_contains(proxy.all, selected))
            result[as_string(tag)] = selected;
    }

    return result;
}

function selector_restore_pairs(snapshot, payload) {
    let result = [];
    snapshot = object_or_empty(snapshot);
    let proxies = object_or_empty(object_or_empty(payload).proxies);

    for (let group, selected in snapshot) {
        group = as_string(group);
        selected = as_string(selected);

        if (group == "" || selected == "")
            continue;

        let proxy = object_or_empty(proxies[group]);
        if (lc(as_string(proxy.type || "")) != "selector")
            continue;
        if (!string_array_contains(proxy.all, selected))
            continue;
        if (as_string(proxy.now || "") == selected)
            continue;

        push(result, { group, proxy: selected });
    }

    return result;
}

function clash_api_json(action, arg1, arg2, arg3) {
    let result = module_capture(DIAGNOSTICS_UC, [
        "clash-api",
        action,
        as_string(arg1 || ""),
        as_string(arg2 || ""),
        as_string(arg3 || "")
    ]);
    if (result.status != 0)
        return null;

    try {
        return json(result.output);
    }
    catch (e) {
        return null;
    }
}

function capture_selector_state() {
    return selector_state_from_proxies_payload(clash_api_json("get_proxies"));
}

function restore_selector_state(snapshot) {
    let pairs = selector_restore_pairs(snapshot, clash_api_json("get_proxies"));

    for (let pair in pairs)
        module_success(DIAGNOSTICS_UC, [ "clash-api", "set_group_proxy", pair.group, pair.proxy, "" ]);
}

function save_selector_state(path) {
    let payload = clash_api_json("get_proxies");
    if (type(payload) != "object" || type(payload.proxies) != "object")
        return 1;
    return common.write_private_file(path, sprintf("%J", selector_state_from_proxies_payload(payload))) != null ? 0 : 1;
}

function restore_saved_selector_state(path) {
    let snapshot = read_json_file(path);
    let payload = clash_api_json("get_proxies");
    if (type(snapshot) != "object" || type(payload) != "object" || type(payload.proxies) != "object")
        return 1;
    let ok = true;
    for (let pair in selector_restore_pairs(snapshot, payload))
        if (!module_success(DIAGNOSTICS_UC, [ "clash-api", "set_group_proxy", pair.group, pair.proxy, "" ]))
            ok = false;
    return ok ? 0 : 1;
}

function module_background(module_path, args) {
    return command_status(module_command(module_path, args) + " >/dev/null 2>&1 1000>&- &") == 0;
}

function config_get(path, fallback) {
    path = as_string(path);
    if (!uci_core.exists(path))
        return as_string(fallback);
    return trim(uci_core.get(path));
}

function schedule_automatic_latency_after_runtime() {
    if (fs.stat(PENDING_RELOAD_FILE) != null) {
        log_message("Automatic latency test is deferred until the pending Forkop reload completes", "info");
        return false;
    }

    let config_path = config_get(CONFIG_NAME + ".settings.config_path", "");
    let proxy_signature = trim(module_output(DIAGNOSTICS_UC, [
        "proxy-outbounds-signature", config_path
    ]));
    if (proxy_signature == "") {
        log_message("Automatic latency test was not scheduled because no testable proxy outbounds were found", "info");
        return false;
    }
    if (!module_success(UPDATES_UC, [ "schedule-automatic-latency-test", proxy_signature ])) {
        log_message("Automatic latency test could not be scheduled", "warn");
        return false;
    }

    module_background(DIAGNOSTICS_UC, [ "automatic-latency-test", "resume" ]);
    return true;
}

function finish_reload_status(status, initial_fingerprint, schedule_latency) {
    status = int(status || 0);
    if (status == 0) {
        mark_pending_reload_if_config_changed(initial_fingerprint, "config_changed_during_reload");
        if (schedule_latency || fs.stat(POST_START_LATENCY_FILE) != null) {
            remove_file(POST_START_LATENCY_FILE);
            schedule_automatic_latency_after_runtime();
        }
    }
    return status;
}

function config_set(path, value) {
    return uci_core.set(path, value);
}

function file_md5(path) {
    path = as_string(path);
    if (path == "" || fs.stat(path) == null)
        return "";

    let output = command_output("md5sum " + shell_quote(path) + " 2>/dev/null");
    let fields = split(trim(output), /[ \t\r\n]+/);
    return length(fields) > 0 ? as_string(fields[0]) : "";
}

function current_config_hash() {
    return file_md5(CONFIG_FILE);
}

function mark_internal_config_guard() {
    let hash = current_config_hash();
    if (hash == "") {
        fs.unlink(INTERNAL_CONFIG_TRIGGER_GUARD);
        return;
    }

    let stamp = clock();
    let tmp_path = INTERNAL_CONFIG_TRIGGER_GUARD + "." + stamp[0] + "." + stamp[1];
    fs.writefile(tmp_path, as_string(stamp[0]) + "\n" + hash + "\n");
    if (!fs.rename(tmp_path, INTERNAL_CONFIG_TRIGGER_GUARD))
        fs.unlink(tmp_path);
}

function config_commit() {
    if (!uci_core.commit(CONFIG_NAME))
        return 1;
    mark_internal_config_guard();
    return 0;
}

function mark_runtime_stopped_clean() {
    let status = 0;
    if (!config_set(CONFIG_NAME + ".settings.shutdown_correctly", "1"))
        status = 1;
    else {
        let commit_status = config_commit();
        if (commit_status != 0)
            status = commit_status;
    }

    module_success(STATE_UC, [ "clear-reload-state", RELOAD_STATE_FILE, RELOAD_STATE_SNAPSHOT_FILE ]);
    return status;
}

function setting_bool(name, fallback) {
    let value = config_get(CONFIG_NAME + ".settings." + as_string(name), fallback ? "1" : "0");
    return bool_text(value);
}

function clear_start_failure() {
    remove_file(START_FAILURE_FILE);
}

function mark_start_failure(reason) {
    return fs.writefile(START_FAILURE_FILE, as_string(reason || "permanent_start_failure") + "\n") != null;
}

function set_runtime_config_error(message) {
    fs.writefile(RUNTIME_CONFIG_ERROR_FILE, as_string(message) + "\n");
}

function clear_runtime_config_error() {
    remove_file(RUNTIME_CONFIG_ERROR_FILE);
}

function dns_apply_status(args) {
    return module_status(DNS_APPLY_UC, args);
}

function dns_apply_success(args) {
    return dns_apply_status(args) == 0;
}

function dnsmasq_configure(force) {
    let args = [ "configure" ];
    if (force)
        push(args, "force");
    return dns_apply_status(args);
}

function dnsmasq_restore(force) {
    let args = [ "restore" ];
    if (force)
        push(args, "force");
    return dns_apply_status(args);
}

function dnsmasq_restore_fail_safe() {
    return dns_apply_status([ "failsafe-restore" ]);
}

function dnsmasq_has_forkop_managed_state() {
    return dns_apply_success([ "has-managed-state" ]);
}

function validate_start_config() {
    let status = module_status(VALIDATOR_UC, [ "check-requirements" ]);
    if (status != 0)
        return status;

    let validation = module_capture(VALIDATOR_UC, [ "validate-runtime" ]);
    if (validation.status != 0) {
        log_message("Forkop configuration is invalid: " + validation_failure_message(validation), "fatal");
        return validation.status;
    }

    return 0;
}

function acquire_start_subscription_update_lock() {
    if (module_success(STATE_UC, [ "acquire-runtime-dir-lock-wait", SUBSCRIPTION_UPDATE_LOCK_DIR, owner_pid(), "300" ])) {
        start_subscription_update_lock_held = true;
        return true;
    }

    log_message("Subscription update is already running during startup. Aborted.", "fatal");
    return false;
}

function release_start_subscription_update_lock() {
    if (!start_subscription_update_lock_held)
        return;

    module_success(STATE_UC, [ "release-runtime-dir-lock", SUBSCRIPTION_UPDATE_LOCK_DIR ]);
    start_subscription_update_lock_held = false;
}

function nft_rebuild_runtime() {
    return module_status(NFT_UC, [
        "nft-rebuild-runtime-from-uci",
        RT_TABLE_NAME,
        NFT_TABLE_NAME,
        NFT_LOCALV4_SET_NAME,
        NFT_COMMON_SET_NAME,
        NFT_PORT_SET_NAME,
        NFT_IP_PORT_SET_NAME,
        NFT_INTERFACE_SET_NAME,
        NFT_FAKEIP_MARK,
        NFT_OUTBOUND_MARK,
        SB_FAKEIP_INET4_RANGE,
        SB_TPROXY_INBOUND_PORT,
        ZAPRET_PROVIDER_NFQWS_BIN,
        ZAPRET_ROUTE_MARK_BASE,
        ZAPRET_QUEUE_BASE,
        ZAPRET_DESYNC_MARK,
        ZAPRET_DESYNC_MARK_POSTNAT,
        ZAPRET2_PROVIDER_NFQWS2_BIN,
        ZAPRET2_ROUTE_MARK_BASE,
        ZAPRET2_QUEUE_BASE,
        ZAPRET2_DESYNC_MARK,
        ZAPRET2_DESYNC_MARK_POSTNAT,
        NFT_LOCALV6_SET_NAME,
        NFT_COMMON6_SET_NAME,
        NFT_IP_PORT6_SET_NAME,
        SB_FAKEIP_INET6_RANGE,
        SB_TPROXY_INBOUND6_ADDRESS
    ]);
}

function nft_candidate_begin() {
    nft_candidate_batch_file = trim(command_output_from_args([ "mktemp" ]));
    if (nft_candidate_batch_file == "") {
        log_message("Failed to create nft candidate batch: mktemp returned no path", "fatal");
        return false;
    }
    remove_file(nft_candidate_batch_file);
    // fs.writefile() returns the byte count on OpenWrt. An empty seed is a
    // successful zero-byte write but is falsey, so keep a harmless nft comment
    // as the first line of every candidate transaction.
    let created = write_file(nft_candidate_batch_file, "# Forkop nft candidate\n");
    if (!created)
        log_message("Failed to create nft candidate batch: ucode write_file returned false", "fatal");
    return created;
}

function nft_candidate_validate() {
    return nft_candidate_batch_file != "" && module_success(NFT_UC, [
        "nft-validate-candidate-batch",
        nft_candidate_batch_file
    ]);
}

function nft_candidate_finish(commit, validated) {
    let path = nft_candidate_batch_file;
    nft_candidate_batch_file = "";
    if (path == "")
        return !commit;
    let status = !commit || module_success(NFT_UC, [
        validated ? "nft-commit-candidate-batch" : "nft-apply-candidate-batch",
        path
    ]);
    remove_file(path);
    return status;
}

function nft_populate_runtime_sets() {
    return module_status(NFT_UC, [
        "nft-populate-runtime-sets-from-uci",
        as_string(nft_populate_enabled),
        subscription_deferred_sections,
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
    ]);
}

function singbox_init_config() {
    let result = module_capture(SINGBOX_UC, [
        "init-config",
        as_string(nft_populate_enabled),
        subscription_caches_prepared,
        subscription_runtime_no_refresh,
        subscription_deferred_sections
    ]);
    if (result.status == 0) {
        subscription_deferred_sections = trim(result.output);
        subscription_caches_prepared = "1";
    }
    return result.status;
}

function singbox_prepare_config_stage(stage_path) {
    let result = module_capture(SINGBOX_UC, [
        "prepare-config-stage",
        "0",
        subscription_caches_prepared,
        subscription_runtime_no_refresh,
        subscription_deferred_sections,
        stage_path
    ]);
    if (result.status == 0) {
        subscription_deferred_sections = trim(result.output);
        subscription_caches_prepared = "1";
    }
    return result.status;
}

function discard_singbox_config_stage(stage_path) {
    if (as_string(stage_path) != "")
        module_success(SINGBOX_UC, [ "discard-config-stage", stage_path ]);
}

function restore_guarded_singbox_runtime(backup_path, guard_active) {
    // The stock sing-box init script may watch config.json too. Ensure that no
    // managed runtime can observe the restored file before we publish it.
    if (as_string(backup_path) == "" || module_status(STATE_UC, [
        "stop-managed-sing-box-runtime",
        as_string(getenv("FORKOP_SING_BOX_RELOAD_PID_TIMEOUT") || "15")
    ]) != 0 || !module_success(SINGBOX_UC, [ "restore-config-stage", backup_path ]))
        return false;

    if (module_status(STATE_UC, [
        "start-managed-sing-box-runtime",
        as_string(getenv("FORKOP_SING_BOX_RELOAD_PID_TIMEOUT") || "15")
    ]) != 0)
        return false;

    if (module_status(STATE_UC, [
        "wait-forkop-stable-start",
        RT_TABLE_NAME,
        NFT_TABLE_NAME,
        NFT_FAKEIP_MARK,
        as_string(SING_BOX_START_STABLE_MIN_AGE),
        as_string(SING_BOX_START_VERIFY_TIMEOUT)
    ]) != 0)
        return false;

    return !guard_active || module_success(NFT_UC, [
        "remove-transition-guard",
        NFT_TABLE_NAME,
        NFT_FAKEIP_MARK
    ]);
}

function refresh_cron() {
    return module_status(UPDATES_UC, [
        "refresh-cron-from-uci",
        BIN_PATH,
        LIST_UPDATE_CRON_MARKER,
        SUBSCRIPTION_UPDATE_CRON_MARKER,
        COMPONENT_UPDATE_CHECK_CRON_MARKER
    ]);
}

function remove_cron_jobs() {
    return module_status(UPDATES_UC, [
        "remove-cron-jobs",
        LIST_UPDATE_CRON_MARKER,
        SUBSCRIPTION_UPDATE_CRON_MARKER,
        COMPONENT_UPDATE_CHECK_CRON_MARKER
    ]);
}

function prepare_subscription_caches(mode) {
    let result = module_capture(SUBSCRIPTION_CACHE_UC, [
        "prepare-caches",
        mode,
        subscription_caches_prepared,
        subscription_runtime_no_refresh
    ]);
    if (result.status == 0) {
        subscription_deferred_sections = trim(result.output);
        subscription_caches_prepared = "1";
    }
    return result.status;
}

function start_sing_box_and_wait() {
    if (module_status(STATE_UC, [
        "start-managed-sing-box-runtime",
        getenv("FORKOP_SING_BOX_RELOAD_PID_TIMEOUT") || "15"
    ]) != 0)
        return 1;

    return module_status(STATE_UC, [
        "wait-forkop-stable-start",
        RT_TABLE_NAME,
        NFT_TABLE_NAME,
        NFT_FAKEIP_MARK,
        as_string(SING_BOX_START_STABLE_MIN_AGE),
        as_string(SING_BOX_START_VERIFY_TIMEOUT)
    ]);
}

function start_phase_failed(phase, status) {
    if (status != 0)
        log_message("Startup phase '" + phase + "' failed with exit status " + as_string(status), "fatal");
    return status;
}

// The reload lock owns this preparation runtime. It is the same procd service
// as the final runtime, and cannot authorize a second or foreign process.
function prepare_lists_for_cold_start() {
    let proxy = trim(module_capture(SINGBOX_UC, [ "service-proxy-address", "lists" ]).output);
    let stage = RUNTIME_STATE_DIR + "/list-bootstrap.config." + owner_pid();
    let backup = stage + ".previous";
    let config_path = config_get(CONFIG_NAME + ".settings.config_path", "");
    let had_config = fs.stat(config_path) != null;
    let managed = false;
    let status = 0;
    if (proxy != "") {
        status = module_status(SINGBOX_UC, [ "configure-service" ]);
        // Config checks also run sing-box briefly. Preserve the existing
        // no-runtime-during-check rule, then publish only after proven exit.
        // PID reuse, extra processes and ambiguous owners fail closed.
        if (status == 0)
            status = module_status(STATE_UC, [ "stop-managed-sing-box-runtime", "15" ]);
        if (status == 0)
            status = module_status_with_env(SINGBOX_UC, [
                "prepare-config-stage", "0", subscription_caches_prepared,
                subscription_runtime_no_refresh, subscription_deferred_sections, stage
            ], { FORKOP_LIFECYCLE_LIST_BOOTSTRAP: "1" });
        if (status == 0)
            status = module_status(SINGBOX_UC, [ "validate-config-stage", stage ]);
        if (status == 0)
            status = module_status_with_env(SINGBOX_UC, [ "commit-config-stage", stage, backup ],
                { FORKOP_LIFECYCLE_LIST_BOOTSTRAP: "1" });
        if (status == 0) {
            managed = true;
            status = module_status(STATE_UC, [ "start-managed-sing-box-runtime", "15" ]);
        }
        if (status == 0)
            status = module_status(STATE_UC, [
                "wait-managed-sing-box-config-listeners", config_path, "15"
            ]);
    }
    if (status == 0)
        status = module_status_with_env(UPDATES_UC, [ "list-update" ], {
            FORKOP_LIST_UPDATE_PREPARE_ONLY: "1",
            FORKOP_MANUAL_RESTART_LOCK_HELD: "1"
        });
    if (managed) {
        let stopped = module_status(STATE_UC, [ "stop-managed-sing-box-runtime", "15" ]);
        if (stopped != 0)
            return stopped;
    }
    // Restore the previous file only after the managed preparation PID exits.
    // It remains a rollback file, never a successful partial routing policy.
    if (fs.stat(backup) != null && !module_success(SINGBOX_UC, [ "restore-config-stage", backup ]))
        status = 1;
    if (managed && !had_config && fs.stat(backup) == null)
        remove_file(config_path);
    discard_singbox_config_stage(stage);
    return status;
}
function start_main() {
    let status;

    log_message("Starting Forkop", "info");

    status = validate_start_config();
    if (status != 0) {
        // Validation failures are local configuration failures. Keep the
        // durable marker until a later, verified successful start proves an
        // operator has corrected the configuration.
        permanent_start_failure = true;
        return status;
    }

    startup_config_fingerprint = external_config_fingerprint();

    status = module_status(NFT_UC, [ "ensure-bridge-netfilter-disabled" ]);
    if (status != 0)
        return start_phase_failed("bridge-netfilter", status);

    module_success(STATE_UC, [ "sync-time-if-needed" ]);

    status = module_status(SUBSCRIPTION_CACHE_UC, [ "ensure-runtime-dirs" ]);
    if (status != 0)
        return start_phase_failed("runtime-dirs", status);

    if (!acquire_start_subscription_update_lock())
        return 1;

    status = prepare_subscription_caches("startup");
    if (status != 0) {
        log_message("Subscription caches are not ready. Aborted.", "fatal");
        return start_phase_failed("subscription-caches", status);
    }

    // The normal downloader must finish before a cold start references local
    // lists. A post-start download cannot recover a generator rejection.
    let has_list_sources = module_success(STATE_UC, [ "has-list-update-sources" ]);
    if (has_list_sources && !module_success(UPDATES_UC, [ "restore-list-cache" ])) {
        log_message("No valid list cache is available; downloading the configured lists before starting", "info");
        status = prepare_lists_for_cold_start();
        if (status != 0 || !module_success(UPDATES_UC, [ "runtime-list-cache-active" ])) {
            // Missing downloaded data is retryable once the connection or
            // list source becomes available. Discard stale config failures.
            permanent_start_failure = false;
            clear_start_failure();
            log_message("Configured lists could not be downloaded; Forkop was not started. Check the list source and download connection", "fatal");
            return start_phase_failed("list-download", status == 0 ? 1 : status);
        }
    }

    if (!nft_candidate_begin())
        return start_phase_failed("nft-candidate-begin", 1);
    status = nft_rebuild_runtime();
    if (status != 0) {
        nft_candidate_finish(false);
        return start_phase_failed("nft-rebuild", status);
    }

    status = module_status(SINGBOX_UC, [ "configure-service" ]);
    if (status != 0) {
        nft_candidate_finish(false);
        return start_phase_failed("sing-box-service-configure", status);
    }

    // The generator rebuilds local file references. Re-apply the complete
    // cached generation to both rule-set files and the freshly-created nft
    // table before sing-box validates/starts. A corrupt cache is fatal here;
    // silently starting with a partial routing policy is less safe.
    if (has_list_sources && (module_success(UPDATES_UC, [ "runtime-list-cache-active" ]) ||
        module_success(UPDATES_UC, [ "list-cache-valid" ]))) {
        status = module_status(UPDATES_UC, [ "apply-list-cache" ]);
        if (status != 0) {
            nft_candidate_finish(false);
            log_message("Persistent list cache could not be applied. Aborted.", "fatal");
            return start_phase_failed("active-list-generation", status);
        }
    }
    status = nft_populate_runtime_sets();
    if (status != 0) {
        nft_candidate_finish(false);
        return start_phase_failed("nft-runtime-sets", status);
    }
    if (!nft_candidate_finish(true)) {
        log_message("Candidate nftables policy could not be applied; the active policy was left unchanged", "fatal");
        return start_phase_failed("nft-candidate-apply", 1);
    }

    status = singbox_init_config();
    if (status != 0) {
        // A generator rejection is a deterministic configuration problem;
        // retrying it every time WAN comes up cannot make it valid.
        permanent_start_failure = true;
        return start_phase_failed("sing-box-config", status);
    }

    status = refresh_cron();
    if (status != 0)
        return start_phase_failed("cron-refresh", status);

    status = start_sing_box_and_wait();
    if (status != 0) {
        log_message("sing-box did not reach a stable running state after start. Aborted.", "fatal");
        return status;
    }

    status = module_status(PRIORITY_UC, [ "start-runtime" ]);
    if (status != 0) {
        log_message("Failed to start Priority runtime. Aborted.", "fatal");
        return status;
    }

    status = module_status(SUBSCRIPTION_CACHE_UC, [ "run-deferred-bootstrap", subscription_deferred_sections ]);
    if (status != 0)
        return status;

    release_start_subscription_update_lock();
    module_success(ZAPRET_UC, [ "start-runtime" ]);
    module_success(ZAPRET2_UC, [ "start-runtime" ]);

    return 0;
}

function refresh_rulesets_after_start() {
    let proxy_address = setting_bool("download_lists_via_proxy", false)
        ? SB_SERVICE_MIXED_INBOUND_ADDRESS + ":" + as_string(SB_SERVICE_MIXED_INBOUND_PORT)
        : "";
    let status = module_status(RULESET_CACHE_UC, [ "refresh-if-due", proxy_address ]);

    if (status == 0) {
        log_message("Rule-set cache changed; reloading Forkop", "info");
        command_status_from_args([ SERVICE_INIT, "reload", "ruleset-cache" ]);
        return;
    }

    if (status != 1)
        log_message("Rule-set cache refresh failed", "warn");
}

function start_impl() {
    let status = start_main();
    if (status != 0)
        return status;

    if (!setting_bool("dont_touch_dhcp", false)) {
        status = dnsmasq_configure(false);
        if (status != 0)
            return status;
    }
    else if (dnsmasq_has_forkop_managed_state()) {
        status = dnsmasq_restore(true);
        if (status != 0)
            return status;
    }

    if (!config_set(CONFIG_NAME + ".settings.shutdown_correctly", "0"))
        return 1;

    status = config_commit();
    if (status != 0)
        return status;

    status = module_status(STATE_UC, [
        "write-current-reload-state-clean",
        RELOAD_STATE_FILE,
        as_string(RELOAD_STATE_FORMAT),
        RULE_CONDITION_CACHE_DIR
    ]);
    if (status != 0)
        return status;

    status = module_status(DNS_FAILOVER_UC, [ "start-runtime" ]);
    if (status != 0) {
        log_message("Failed to start DNS failover runtime", "fatal");
        return status;
    }

    if (module_success(STATE_UC, [ "has-list-update-sources" ])) {
        // Serialize the two network workers. The rule-set refresh may reload
        // sing-box and must not tear down the service proxy during list I/O.
        write_file(RULESET_REFRESH_AFTER_LIST_FILE, "due\n");
        write_file(POST_START_LATENCY_FILE, "pending\n");
        module_background(UPDATES_UC, [ "list-update-after-start" ]);
    }
    else {
        module_background(LIFECYCLE_UC, [ "refresh-rulesets-after-start" ]);
    }
    module_background(DIAGNOSTICS_UC, [ "get-system-info" ]);
    return 0;
}

function stop_main(allow_process_conflict) {
    let status = 0;

    let process_conflict = module_success(STATE_UC, [ "sing-box-process-conflict" ]);
    // Reload must preserve the working dataplane until process ownership is
    // settled. An explicit Stop removes interception and every sing-box.
    if (process_conflict && !allow_process_conflict) {
        log_message("Refusing Forkop stop: sing-box process ownership is ambiguous; preserving the existing runtime", "fatal");
        return 2;
    }
    if (process_conflict)
        log_message("Additional sing-box process detected; explicit Stop will terminate all sing-box runtimes", "warn");

    remove_file(WATCHDOG_READY_FILE);
    log_message("Stopping Forkop", "info");
    module_success(DNS_FAILOVER_UC, [ "stop-runtime" ]);
    module_success(PRIORITY_UC, [ "stop-runtime" ]);
    module_success(SUBSCRIPTION_CACHE_UC, [ "stop-deferred-bootstrap-worker" ]);
    module_success(UPDATES_UC, [ "stop-list-update" ]);
    remove_cron_jobs();
    // A newer list generation may intentionally live only in /tmp because
    // flash space was below the persistent-cache reserve. Keep it across an
    // in-boot service reload; a real reboot clears both /tmp and its marker.
    if (!module_success(UPDATES_UC, [ "runtime-list-cache-active" ]))
        command_success_from_args([ "find", TMP_RULESET_FOLDER, "-mindepth", "1", "-maxdepth", "1", "-type", "f", "-delete" ]);

    module_success(ZAPRET_UC, [ "stop-runtime" ]);
    module_success(ZAPRET2_UC, [ "stop-runtime" ]);

    if (command_success_from_args([ "nft", "list", "table", "inet", NFT_TABLE_NAME ]))
        command_success_from_args([ "nft", "delete", "table", "inet", NFT_TABLE_NAME ]);

    if (module_success(NFT_UC, [ "tproxy-marking-rule4-present", RT_TABLE_NAME, NFT_FAKEIP_MARK ]))
        command_success_from_args([ "ip", "-4", "rule", "del", "fwmark", NFT_FAKEIP_MARK + "/" + NFT_FAKEIP_MARK, "table", RT_TABLE_NAME, "priority", "105" ]);
    if (module_success(NFT_UC, [ "tproxy-marking-rule6-present", RT_TABLE_NAME, NFT_FAKEIP_MARK ]))
        command_success_from_args([ "ip", "-6", "rule", "del", "fwmark", NFT_FAKEIP_MARK + "/" + NFT_FAKEIP_MARK, "table", RT_TABLE_NAME, "priority", "105" ]);

    if (module_success(NFT_UC, [ "tproxy-route4-present", RT_TABLE_NAME ]))
        command_success_from_args([ "ip", "route", "flush", "table", RT_TABLE_NAME ]);
    if (module_success(NFT_UC, [ "tproxy-route6-present", RT_TABLE_NAME ]))
        command_success_from_args([ "ip", "-6", "route", "flush", "table", RT_TABLE_NAME ]);

    let sing_box_status = module_status(STATE_UC, [
        allow_process_conflict ? "stop-all-sing-box-runtime" : "stop-managed-sing-box-runtime",
        getenv("FORKOP_SING_BOX_RELOAD_PID_TIMEOUT") || "15"
    ]);
    if (sing_box_status != 0)
        status = sing_box_status;

    return status;
}

function cleanup_failed_runtime() {
    let status = 0;

    log_message("Cleaning up Forkop runtime after failed start/reload", "info");

    let stop_status = stop_main();
    if (stop_status != 0)
        status = stop_status;

    let dns_status = dnsmasq_restore_fail_safe();
    if (dns_status != 0 && status == 0)
        status = dns_status;

    let mark_status = mark_runtime_stopped_clean();
    if (mark_status != 0 && status == 0)
        status = mark_status;

    if (status != 0)
        log_message("Failed to fully clean up Forkop runtime after start/reload failure", "warn");

    return status;
}

function finish_list_change_files(restore) {
    let path = list_change_rollback_dir;
    if (path == "")
        return true;
    if (restore && fs.stat(path) != null) {
        if (!command_success_from_args([ "rm", "-rf", TMP_RULESET_FOLDER ]) ||
            !ensure_dir(TMP_RULESET_FOLDER) ||
            !command_success_from_args([ "cp", "-R", "-p", path + "/.", TMP_RULESET_FOLDER ])) {
            log_message("Could not restore the previous materialized lists; retaining their rollback snapshot", "error");
            return false;
        }
    }
    if (!command_success_from_args([ "rm", "-rf", path ]))
        return false;
    list_change_rollback_dir = "";
    return true;
}

function abort_reload(status, runtime_changed) {
    finish_list_change_files(true);
    status = int(status || 0);
    if (status == 0)
        status = 1;

    if (runtime_changed)
        cleanup_failed_runtime();
    else
        remove_file(RELOAD_STATE_SNAPSHOT_FILE);

    return status;
}

function abort_guarded_transition(status, stage_path, backup_path, guard_active) {
    nft_candidate_finish(false);
    discard_singbox_config_stage(stage_path);
    if (!finish_list_change_files(true))
        return status || 1;

    if (!guard_active)
        return abort_reload(status, false);

    if (fs.stat(backup_path) != null && restore_guarded_singbox_runtime(backup_path, true))
        return abort_reload(status, false);

    // Do not call cleanup_failed_runtime here. The guard intentionally stays
    // in the old table and drops classified traffic until an operator/retry can
    // restore a coherent pair; tearing down the table would create a direct
    // leak window.
    log_message("Cross-component transition rollback failed; retaining the fail-closed nft guard", "fatal");
    remove_file(RELOAD_STATE_SNAPSHOT_FILE);
    return status == 0 ? 1 : status;
}

// The cold fallback below always runs behind the fail-closed guard, also when
// the hot attempt itself did not need one.
function abort_hot_to_guarded(status, stage_path, backup_path) {
    module_success(NFT_UC, [ "install-transition-guard", NFT_TABLE_NAME, NFT_FAKEIP_MARK ]);
    return abort_guarded_transition(status, stage_path, backup_path, true);
}

function abort_hot_transition(status, stage_path, backup_path) {
    nft_candidate_finish(false);
    if (!finish_list_change_files(true))
        return abort_hot_to_guarded(status, stage_path, backup_path);
    // A queued HUP may finish late. Always request and acknowledge the old
    // config after restoring it; a momentary old hash is not sufficient.
    if (fs.stat(backup_path) != null && module_success(HOT_RELOAD_UC, [
        "restore", stage_path + ".hot-plan", backup_path
    ]) && module_success(STATE_UC, [ "single-ready-sing-box-runtime" ]) &&
        module_success(NFT_UC, [ "remove-transition-guard", NFT_TABLE_NAME, NFT_FAKEIP_MARK ])) {
        discard_singbox_config_stage(stage_path);
        remove_file(backup_path);
        module_success(PRIORITY_UC, [ "start-runtime" ]);
        module_success(DNS_FAILOVER_UC, [ "start-runtime" ]);
        log_message("Hot reload failed; previous core configuration and nft policy restored", "warn");
        return abort_reload(status, false);
    }
    return abort_hot_to_guarded(status, stage_path, backup_path);
}

function abort_invalid_staged_config(stage_path) {
    nft_candidate_finish(false);
    discard_singbox_config_stage(stage_path);
    finish_list_change_files(true);
    // A configuration which sing-box itself rejects is a hard fail-closed
    // condition: do not silently retain a previous policy after the user has
    // applied new settings.
    cleanup_failed_runtime();
    return 1;
}

function start() {
    // A current installer/updater may have recorded one exact, procd-owned
    // pre-upgrade process. Wait only for that process to exit; a legacy direct
    // opkg/apk upgrade has no marker and remains fail-closed below.
    if (fs.stat(MANAGED_UPGRADE_SING_BOX_MARKER) != null &&
        !module_success(STATE_UC, [
            "wait-managed-upgrade-sing-box-exit",
            MANAGED_UPGRADE_SING_BOX_MARKER,
            as_string(MANAGED_UPGRADE_SING_BOX_WAIT_SECONDS),
            as_string(MANAGED_UPGRADE_SING_BOX_MARKER_MAX_AGE_SECONDS)
        ])) {
        log_message("Refusing Forkop start: managed upgrade sing-box provenance did not resolve safely", "fatal");
        release_start_subscription_update_lock();
        return 1;
    }

    // A second sing-box is not safely attributable from its executable name.
    // Do not turn this detection into a stop/restart cycle: that could remove
    // the old working nft policy while an orphan remains alive.
    if (module_success(STATE_UC, [ "sing-box-process-conflict" ])) {
        log_message("Refusing Forkop start: sing-box process ownership is ambiguous; preserving the existing runtime", "fatal");
        release_start_subscription_update_lock();
        return 1;
    }

    // Package installation can queue a second init.d start while the first
    // one is still building its runtime. initd serializes both calls with
    // reload.lock, so by the time this call acquires it the first start may
    // already have completed. Treat that coherent, sole procd-owned runtime
    // as a successful idempotent start. Without this check the second call
    // reaches start_managed_sing_box_and_verify() with a live sing-box and
    // incorrectly classifies the first start's process as unexpected.
    //
    // Do not relax the ownership safety rule: the full stable-runtime
    // predicate requires the sole procd-owned process, ready listeners and
    // Clash API, plus Forkop's nftables/routing state. A partial or foreign
    // runtime continues through the guarded cold-start path and fails closed.
    if (module_success(STATE_UC, [
        "forkop-stably-running",
        RT_TABLE_NAME,
        NFT_TABLE_NAME,
        NFT_FAKEIP_MARK,
        as_string(RUNTIME_STABLE_MIN_AGE)
    ])) {
        log_message("Forkop is already stably running; treating duplicate start as successful", "info");
        write_file(WATCHDOG_READY_FILE, "1\n");
        release_start_subscription_update_lock();
        return 0;
    }

    remove_file(WATCHDOG_READY_FILE);
    let status = start_impl();
    release_start_subscription_update_lock();

    if (status != 0) {
        cleanup_failed_runtime();
        if (permanent_start_failure)
            mark_start_failure("sing_box_config");
        return status;
    }

    mark_pending_reload_if_config_changed(startup_config_fingerprint, "config_changed_during_start");

    status = module_status(STATE_UC, [
        "wait-forkop-stable-start",
        RT_TABLE_NAME,
        NFT_TABLE_NAME,
        NFT_FAKEIP_MARK,
        as_string(RUNTIME_STABLE_MIN_AGE),
        "8"
    ]);
    if (status != 0) {
        log_message("Startup verification failed after Forkop was started; rolling back DNS changes", "warn");
        cleanup_failed_runtime();
        return status;
    }

    clear_runtime_config_error();
    // A failure marker must survive subsequent failed starts. Clearing it
    // before validation lets a detached package/boot start re-enable an
    // endless retry loop for the same invalid configuration.
    clear_start_failure();
    write_file(WATCHDOG_READY_FILE, "1\n");

    // A queued reload owns the next runtime transition. initd starts it only
    // after this start action has released reload.lock; calling it here would
    // deadlock the nested init.d reload handoff.
    if (fs.stat(PENDING_RELOAD_FILE) != null) {
        log_message("Automatic latency test is deferred until the pending Forkop reload completes", "info");
        return 0;
    }

    if (fs.stat(POST_START_LATENCY_FILE) != null) {
        log_message("Automatic latency test is deferred until the post-start list and rule-set pipeline completes", "info");
        return 0;
    }

    schedule_automatic_latency_after_runtime();

    return 0;
}

function stop_impl(allow_process_conflict) {
    // Drop interception before restoring DNS so a new query cannot be sent
    // through the old proxy policy during an explicit stop.
    let status = stop_main(allow_process_conflict);
    if (status == 2)
        return 2;

    if (!setting_bool("dont_touch_dhcp", false)) {
        let dns_status = dnsmasq_restore(false);
        if (dns_status != 0)
            status = dns_status;
    }
    else if (dnsmasq_has_forkop_managed_state()) {
        let dns_status = dnsmasq_restore(true);
        if (dns_status != 0)
            status = dns_status;
    }

    if (!config_set(CONFIG_NAME + ".settings.shutdown_correctly", "1"))
        status = 1;
    else {
        let commit_status = config_commit();
        if (commit_status != 0)
            status = commit_status;
    }

    module_success(STATE_UC, [ "clear-reload-state", RELOAD_STATE_FILE, RELOAD_STATE_SNAPSHOT_FILE ]);

    if (status != 0)
        dnsmasq_restore_fail_safe();

    return status;
}

function stop() {
    // The UI and normal init.d Stop are explicit shutdowns. Package upgrades
    // and internal component transitions must retain the ownership guard.
    let internal_stop = getenv("FORKOP_INTERNAL_SERVICE_STOP") == "1" ||
        fs.stat(PACKAGE_UPGRADE_QUIESCE_FILE) != null ||
        fs.stat(MANAGED_UPGRADE_SING_BOX_MARKER) != null;
    return stop_impl(!internal_stop);
}

function restart_runtime_for_reload() {
    let status;
    let selector_state = capture_selector_state();

    log_message("Reload requires a full Forkop runtime restart", "info");

    status = stop_main();
    if (status != 0)
        return status;

    status = start_impl();
    if (status != 0) {
        cleanup_failed_runtime();
        return status;
    }

    status = module_status(STATE_UC, [
        "wait-forkop-stable-start",
        RT_TABLE_NAME,
        NFT_TABLE_NAME,
        NFT_FAKEIP_MARK,
        as_string(RUNTIME_STABLE_MIN_AGE),
        "8"
    ]);
    if (status != 0) {
        log_message("Reload runtime restart verification failed after Forkop was started; rolling back DNS changes", "fatal");
        cleanup_failed_runtime();
        return status;
    }

    write_file(WATCHDOG_READY_FILE, "1\n");
    restore_selector_state(selector_state);
    remove_file(RELOAD_STATE_SNAPSHOT_FILE);
    return 0;
}

function write_service_trigger_sync_state(changed) {
    ensure_dir(RUNTIME_STATE_DIR);
    write_file(SERVICE_TRIGGER_SYNC_FILE, as_string(changed) + "\n");
}

function parse_reload_plan(output) {
    let result = {
        changed_service_triggers: 0,
        changed_dnsmasq: 0,
        changed_sing_box: 0,
        changed_nft: 0,
        changed_zapret_queue: 0,
        changed_zapret_runtime: 0,
        changed_zapret2_queue: 0,
        changed_zapret2_runtime: 0,
        changed_cron: 0,
        changed_list: 0,
        needs_sing_box_reload: 0,
        needs_nft_rebuild: 0,
        needs_zapret_restart: 0,
        needs_zapret2_restart: 0,
        needs_dnsmasq_configure: 0,
        needs_dnsmasq_restore: 0,
        needs_cron_refresh: 0,
        needs_list_update: 0,
        has_work: 0
    };

    for (let line in split(as_string(output), "\n")) {
        line = as_string(line);
        if (line == "")
            continue;
        let fields = split(line, "\t");
        if (length(fields) < 2)
            continue;
        let key = fields[0];
        if (result[key] != null)
            result[key] = int(fields[1] || 0);
    }

    return result;
}

function append_reload_action(actions, enabled, label) {
    if (!(enabled === true || int(enabled || 0) == 1))
        return actions;
    return actions + (actions != "" ? ", " : "") + label;
}

function reload_actions_summary(plan) {
    let actions = "";
    actions = append_reload_action(actions, plan.needs_sing_box_reload, "sing-box");
    actions = append_reload_action(actions, plan.needs_nft_rebuild, "nftables");
    actions = append_reload_action(actions, plan.needs_zapret_restart, "Zapret");
    actions = append_reload_action(actions, plan.needs_zapret2_restart, "Zapret2");
    actions = append_reload_action(actions, plan.needs_dnsmasq_configure || plan.needs_dnsmasq_restore, "dnsmasq");
    actions = append_reload_action(actions, plan.needs_cron_refresh, "scheduled jobs");
    actions = append_reload_action(actions, plan.needs_list_update, "remote lists");
    return actions;
}

function release_reload_lock() {
    module_success(STATE_UC, [ "release-runtime-dir-lock", RELOAD_LOCK_DIR ]);
}

function sing_box_runtime_pid() {
    let result = module_capture(STATE_UC, [ "sing-box-service-runtime-pid" ]);
    return result.status == 0 ? trim(result.output) : "";
}

function wait_dns_failover_state(candidate_state_path, attempts) {
    attempts = int(attempts || 1);
    for (let i = 0; i < attempts; i++) {
        let status = module_status(DNS_FAILOVER_UC, [ "verify-state", candidate_state_path ]);
        if (status == 0)
            return 0;
        if (i + 1 < attempts)
            command_success_from_args([ "sleep", "1" ]);
    }
    return 1;
}

function dns_failover_apply(candidate_state_path) {
    candidate_state_path = as_string(candidate_state_path);
    if (candidate_state_path == "" || fs.stat(candidate_state_path) == null)
        return 1;

    if (!module_success(STATE_UC, [ "acquire-runtime-dir-lock-wait", RELOAD_LOCK_DIR, owner_pid(), "2" ]))
        return 2;

    // Do not publish config.json while a vendor-provided init script can be
    // watching it. Its watcher is outside Forkop's ownership and can otherwise
    // race our controlled replacement with a second procd start.
    let transition_timeout = as_string(getenv("FORKOP_SING_BOX_RELOAD_PID_TIMEOUT") || "15");
    if (module_status(STATE_UC, [ "stop-managed-sing-box-runtime", transition_timeout ]) != 0) {
        release_reload_lock();
        return 1;
    }

    let patch_result = module_capture(SINGBOX_UC, [ "patch-dns-config", candidate_state_path ]);
    if (patch_result.status != 0) {
        module_success(STATE_UC, [ "start-managed-sing-box-runtime", transition_timeout ]);
        release_reload_lock();
        return patch_result.status;
    }

    let fields = split(trim(patch_result.output), "\t");
    let changed = as_string(fields[0]) == "1";
    let backup_path = length(fields) > 1 ? as_string(fields[1]) : "";
    let status = 0;

    if (changed) {
        status = module_status(STATE_UC, [ "start-managed-sing-box-runtime", transition_timeout ]);
        if (status == 0)
            status = wait_dns_failover_state(candidate_state_path, 8);
    }
    else {
        status = module_status(STATE_UC, [ "start-managed-sing-box-runtime", transition_timeout ]);
    }

    if (status == 0 && !module_success(DNS_FAILOVER_UC, [ "commit-state", candidate_state_path ]))
        status = 1;

    if (status != 0 && backup_path != "") {
        log_message("DNS failover apply failed; restoring the previous sing-box configuration", "error");
        if (module_success(STATE_UC, [ "stop-managed-sing-box-runtime", transition_timeout ]) &&
            module_success(SINGBOX_UC, [ "restore-dns-config", backup_path ]))
            module_success(STATE_UC, [ "start-managed-sing-box-runtime", transition_timeout ]);
    }

    if (backup_path != "")
        remove_file(backup_path);
    release_reload_lock();
    return status;
}

function reload_reason_for_generation(reason, pending, generation_current) {
    if (reason == "list-content" || pending)
        return generation_current ? "list-content" : "list-source-retry";
    return reason;
}

function reload(reason) {
    reason = as_string(reason || "");
    // Retry a completed generation locally only while its source signature
    // matches UCI. Cancelling or replacing a failed edit needs a new generation
    // before the pending runtime apply can continue.
    if (reason == "list-content" || fs.stat(LIST_UPDATE_RELOAD_FILE) != null) {
        reason = reload_reason_for_generation(reason, true,
            module_success(UPDATES_UC, [ "runtime-list-cache-active" ]));
        log_message(reason == "list-content"
            ? "A committed list generation is pending runtime apply; performing a local list-content reload"
            : "Pending list generation no longer matches the settings; preparing the current list sources before applying", "info");
    }
    let status;
    // This remains false until a complete nft transaction was accepted or a
    // sing-box process reload was requested. Candidate preparation and its
    // check/apply failures have not changed the live policy.
    let runtime_changed = false;
    let force_runtime_reload = reason == "on_config_change" ? 0 : 1;
    let reload_config_fingerprint = external_config_fingerprint();
    rule_condition_cache_enabled = force_runtime_reload;

    log_message("Reloading Forkop", "info");

    status = validate_start_config();
    if (status != 0)
        return status;

    status = module_status(SUBSCRIPTION_CACHE_UC, [ "ensure-runtime-dirs" ]);
    if (status != 0)
        return status;

    // This gate must precede every reload-state capture and candidate nft
    // operation. A reload can otherwise rebuild the live dataplane before a
    // later sing-box transition notices that procd ownership is unsettled.
    // Preserve the coherent runtime until ownership has converged instead.
    if (module_success(STATE_UC, [ "sing-box-process-conflict" ])) {
        log_message("Reload refused: multiple or non-procd sing-box processes were detected; preserving the existing runtime", "fatal");
        return finish_reload_status(1, reload_config_fingerprint, reason == "pending");
    }

    if (!module_success(STATE_UC, [ "forkop-running", RT_TABLE_NAME, NFT_TABLE_NAME, NFT_FAKEIP_MARK ])) {
        log_message("Runtime state is incomplete; restarting Forkop runtime", "info");
        return finish_reload_status(restart_runtime_for_reload(), reload_config_fingerprint, reason == "pending");
    }

    remove_file(RELOAD_STATE_SNAPSHOT_FILE);
    status = module_status(STATE_UC, [
        "capture-reload-state",
        RELOAD_STATE_SNAPSHOT_FILE,
        as_string(RELOAD_STATE_FORMAT)
    ]);
    if (status != 0)
        return status;

    let current_reload_state_file = trim(command_output_from_args([ "mktemp" ]));
    if (current_reload_state_file == "")
        return abort_reload(1, false);

    status = module_status(STATE_UC, [
        "write-captured-reload-state",
        current_reload_state_file,
        RELOAD_STATE_SNAPSHOT_FILE,
        as_string(RELOAD_STATE_FORMAT),
        "",
        "0",
        "0"
    ]);
    if (status != 0) {
        remove_file(current_reload_state_file);
        return abort_reload(status, false);
    }

    let dnsmasq_managed_state = dnsmasq_has_forkop_managed_state() ? 1 : 0;
    let list_update_sources = module_success(STATE_UC, [ "has-list-update-sources" ]) ? 1 : 0;
    let nft_list_update_sources = module_success(STATE_UC, [ "has-nft-list-update-sources" ]) ? 1 : 0;
    let runtime_cache_needs_rebuild = 0;
    if (as_string(getenv("FORKOP_RUNTIME_CACHE_INVALIDATED") || "0") == "1" ||
        module_success(SUBSCRIPTION_CACHE_UC, [ "runtime-cache-needs-rebuild", SECTION_CACHE_DIR ]))
        runtime_cache_needs_rebuild = 1;

    let plan_result = module_capture(RELOAD_UC, [
        "plan-state-files",
        RELOAD_STATE_FILE,
        current_reload_state_file,
        as_string(force_runtime_reload),
        as_string(dnsmasq_managed_state),
        as_string(list_update_sources),
        as_string(nft_list_update_sources),
        as_string(runtime_cache_needs_rebuild)
    ]);
    remove_file(current_reload_state_file);

    if (plan_result.status != 0) {
        if (plan_result.status == 2) {
            log_message("Reload state is unavailable; restarting Forkop runtime", "info");
            return finish_reload_status(restart_runtime_for_reload(), reload_config_fingerprint, reason == "pending");
        }
        return abort_reload(plan_result.status, false);
    }

    let plan = parse_reload_plan(plan_result.output);
    // A changed source must first become a complete active generation. Do not
    // publish a freshly rebuilt table without its replacement list data.
    if (reason == "list-source-retry") {
        plan.has_work = 1;
        plan.needs_nft_rebuild = 1;
        plan.needs_sing_box_reload = 1;
        plan.needs_list_update = 1;
        plan.changed_list = 1;
    }
    else if (reason == "list-content") {
        plan.has_work = 1;
        plan.needs_nft_rebuild = 1;
        plan.needs_list_update = 0;
        plan.changed_list = 0;
    }
    write_service_trigger_sync_state(plan.changed_service_triggers);

    if (plan.has_work == 0) {
        status = module_status(STATE_UC, [
            "write-captured-reload-state",
            RELOAD_STATE_FILE,
            RELOAD_STATE_SNAPSHOT_FILE,
            as_string(RELOAD_STATE_FORMAT),
            RULE_CONDITION_CACHE_DIR,
            "1",
            "1"
        ]);
        if (status == 0)
            log_message("Reload skipped: runtime-relevant configuration is unchanged", "info");
        return finish_reload_status(status, reload_config_fingerprint, reason == "pending");
    }

    let actions = reload_actions_summary(plan);
    if (actions != "")
        log_message("Applying reload changes: " + actions, "info");

    // Prepare the complete new composition under this reload's lock while
    // the old runtime serves traffic. Reuse sources by URL, even across
    // sections; fetch only missing data. The worker publishes no live nft
    // policy and requests no second reload in prepare-only mode.
    if (plan.changed_list == 1) {
        list_change_rollback_dir = RELOAD_STATE_SNAPSHOT_FILE + ".lists";
        status = module_status_with_env(UPDATES_UC, [ "prepare-list-change" ], {
            FORKOP_LIST_UPDATE_PREPARE_ONLY: "1",
            FORKOP_MANUAL_RESTART_LOCK_HELD: "1",
            FORKOP_LIST_CHANGE_ROLLBACK_DIR: list_change_rollback_dir
        });
        if (status != 0)
            return abort_reload(status, false);
        if (!write_file(LIST_UPDATE_RELOAD_FILE, "apply-pending\n"))
            return abort_reload(1, false);
        reason = "list-content";
        plan.changed_list = 0;
        plan.needs_list_update = 0;
        plan.needs_nft_rebuild = 1;
        plan.needs_sing_box_reload = 1;
    }

    // A committed generation may be retried after an earlier apply failed.
    // The restored live files still belong to the previous policy; preserve
    // them again before apply-list-cache replaces them on this attempt.
    if (reason == "list-content" && list_change_rollback_dir == "") {
        list_change_rollback_dir = RELOAD_STATE_SNAPSHOT_FILE + ".lists";
        status = module_status_with_env(UPDATES_UC, [ "snapshot-list-files" ], {
            FORKOP_LIST_CHANGE_ROLLBACK_DIR: list_change_rollback_dir
        });
        if (status != 0)
            return abort_reload(status, false);
    }

    if (plan.needs_zapret_restart == 1)
        module_success(ZAPRET_UC, [ "stop-runtime" ]);
    if (plan.needs_zapret2_restart == 1)
        module_success(ZAPRET2_UC, [ "stop-runtime" ]);

    // A staged config and a checked nft batch must both exist before the
    // first live transition. The old sing-box process keeps its in-memory
    // config while this preparation runs.
    let staged_singbox_config = "";
    let staged_singbox_backup = "";
    let transition_guard_active = false;
    let hot_reload = false;
    let needs_singbox_transition = plan.needs_sing_box_reload == 1;
    let sing_box_config_path = "";
    let sing_box_config_hash_before = "";
    let sing_box_pid_before = "";
    if (needs_singbox_transition) {
        module_success(DNS_FAILOVER_UC, [ "stop-runtime" ]);
        module_success(PRIORITY_UC, [ "stop-runtime" ]);
        status = module_status(SINGBOX_UC, [ "configure-service" ]);
        if (status != 0)
            return abort_reload(status, false);
        sing_box_config_path = config_get(CONFIG_NAME + ".settings.config_path", "");
        sing_box_config_hash_before = file_md5(sing_box_config_path);
        sing_box_pid_before = sing_box_runtime_pid();
        staged_singbox_config = trim(command_output_from_args([ "mktemp" ]));
        staged_singbox_backup = trim(command_output_from_args([ "mktemp" ]));
        if (staged_singbox_config == "" || staged_singbox_backup == "") {
            discard_singbox_config_stage(staged_singbox_config);
            remove_file(staged_singbox_backup);
            return abort_reload(1, false);
        }
        // mktemp creates the backup path, while commit-config-stage requires
        // copying the live config itself before it is changed.
        remove_file(staged_singbox_backup);
        status = singbox_prepare_config_stage(staged_singbox_config);
        if (status != 0) {
            discard_singbox_config_stage(staged_singbox_config);
            return abort_reload(status, false);
        }
        let hot_plan = module_capture(HOT_RELOAD_UC, [ "plan", staged_singbox_config ]);
        if (hot_plan.status != 0) {
            discard_singbox_config_stage(staged_singbox_config);
            log_message("Hot reload candidate rejected before changing the running core", "error");
            return abort_reload(hot_plan.status, false);
        }
        hot_reload = trim(hot_plan.output) == "hot";
    }

    if (plan.needs_nft_rebuild == 1) {
        log_message("Rebuilding nftables rules", "info");
        if (!nft_candidate_begin())
            return abort_reload(1, false);
        status = nft_rebuild_runtime();
        if (status != 0) {
            nft_candidate_finish(false);
            return abort_reload(status, runtime_changed);
        }
        // A local policy change must reconstruct downloaded subnet data from
        // the already active generation.  It is deliberately synchronous and
        // offline: list_update is reserved for a changed source signature.
        if ((plan.needs_list_update == 1 && plan.changed_list == 0) || reason == "list-content") {
            status = module_status(UPDATES_UC, [ "apply-list-cache" ]);
            if (status != 0) {
                nft_candidate_finish(false);
                log_message("Active list generation could not be restored after nft rebuild. Aborted to preserve fail-safe policy.", "fatal");
                return abort_reload(status, runtime_changed);
            }
        }
        // Inline/source-aware sets are part of the same candidate, not a
        // post-commit append. List-derived elements above use the active
        // generation and are recorded in this very batch as well.
        status = nft_populate_runtime_sets();
        if (status != 0) {
            nft_candidate_finish(false);
            discard_singbox_config_stage(staged_singbox_config);
            if (status == 0)
                log_message("Candidate nftables policy failed validation or apply; active policy was left unchanged", "fatal");
            return abort_reload(status == 0 ? 1 : status, runtime_changed);
        }
        // When sing-box also changes, retain this checked candidate until the
        // new process is ready behind the temporary fail-closed guard.
        if (needs_singbox_transition && !nft_candidate_validate()) {
            nft_candidate_finish(false);
            discard_singbox_config_stage(staged_singbox_config);
            log_message("Candidate nftables policy failed validation; active policy was left unchanged", "fatal");
            return abort_reload(1, runtime_changed);
        }
        if (!needs_singbox_transition && !nft_candidate_finish(true, false)) {
            if (status == 0)
                log_message("Candidate nftables policy failed validation or apply; active policy was left unchanged", "fatal");
            return abort_reload(status == 0 ? 1 : status, runtime_changed);
        }
        if (!needs_singbox_transition)
            runtime_changed = true;
    }

    if (needs_singbox_transition) {
        // The guard is installed atomically in the existing table after
        // mangle marking and before TPROXY. It is the only unavoidable
        // cross-component window: protected packets are dropped, never sent
        // to a process with a different routing generation. A hot reload
        // with an unchanged nft policy has no such window: the same process
        // swaps its routing at once, so traffic keeps flowing.
        if (!hot_reload || nft_candidate_batch_file != "") {
            if (!module_success(NFT_UC, [ "install-transition-guard", NFT_TABLE_NAME, NFT_FAKEIP_MARK ]))
                return abort_guarded_transition(1, staged_singbox_config, staged_singbox_backup, false);
            transition_guard_active = true;
        }
        if (hot_reload) {
            log_message("Applying Xrust configuration with acknowledged hot reload", "info");
            if (!module_success(SINGBOX_UC, [ "commit-config-stage", staged_singbox_config, staged_singbox_backup ]))
                return abort_hot_transition(1, staged_singbox_config, staged_singbox_backup);
            status = module_status(HOT_RELOAD_UC, [ "apply", staged_singbox_config + ".hot-plan" ]);
            if (status != 0 || getenv("FORKOP_HOT_RELOAD_FAIL_PHASE") == "after-apply")
                return abort_hot_transition(status || 1, staged_singbox_config, staged_singbox_backup);
            clear_runtime_config_error();
        }
        else {
            if (module_status(STATE_UC, [
                "stop-managed-sing-box-runtime",
                as_string(getenv("FORKOP_SING_BOX_RELOAD_PID_TIMEOUT") || "15")
            ]) != 0)
                return abort_guarded_transition(1, staged_singbox_config, staged_singbox_backup, transition_guard_active);
            // Do not run the eager full-config check while the old runtime is
            // still resident. On 256 MiB routers their combined peak can trigger
            // the OOM killer even though either process runs safely on its own.
            if (!module_success(SINGBOX_UC, [ "validate-config-stage", staged_singbox_config ])) {
                set_runtime_config_error("Forkop stopped: the generated sing-box configuration is invalid. Correct the settings and apply them again; see the system log for details.");
                return abort_invalid_staged_config(staged_singbox_config);
            }
            clear_runtime_config_error();
            if (!module_success(SINGBOX_UC, [ "commit-config-stage", staged_singbox_config, staged_singbox_backup ]))
                return abort_guarded_transition(1, staged_singbox_config, staged_singbox_backup, transition_guard_active);
            status = module_status(STATE_UC, [
                "start-managed-sing-box-runtime",
                as_string(getenv("FORKOP_SING_BOX_RELOAD_PID_TIMEOUT") || "15")
            ]);
            if (status != 0)
                return abort_guarded_transition(status, staged_singbox_config, staged_singbox_backup, transition_guard_active);
        }
        status = module_status(STATE_UC, [
            "wait-forkop-stable-start",
            RT_TABLE_NAME,
            NFT_TABLE_NAME,
            NFT_FAKEIP_MARK,
            as_string(SING_BOX_START_STABLE_MIN_AGE),
            as_string(SING_BOX_START_VERIFY_TIMEOUT)
        ]);
        if (status != 0) {
            log_message("Reload verification failed after sing-box was reloaded; restoring the previous coherent runtime", "fatal");
            return hot_reload ? abort_hot_transition(status, staged_singbox_config, staged_singbox_backup) : abort_guarded_transition(status, staged_singbox_config, staged_singbox_backup, transition_guard_active);
        }
        if (nft_candidate_batch_file != "" && !nft_candidate_finish(true, true))
            return hot_reload ? abort_hot_transition(1, staged_singbox_config, staged_singbox_backup) : abort_guarded_transition(1, staged_singbox_config, staged_singbox_backup, transition_guard_active);
        if (transition_guard_active && nft_candidate_batch_file == "" && !module_success(NFT_UC, [ "remove-transition-guard", NFT_TABLE_NAME, NFT_FAKEIP_MARK ]))
            return hot_reload ? abort_hot_transition(1, staged_singbox_config, staged_singbox_backup) : abort_guarded_transition(1, staged_singbox_config, staged_singbox_backup, transition_guard_active);
        transition_guard_active = false;
        if (hot_reload) {
            let closed = module_capture(HOT_RELOAD_UC, [ "close-retired", staged_singbox_backup, sing_box_config_path ]);
            if (closed.status != 0)
                log_message("Configuration applied, but closing connections of removed rule sets failed", "warn");
            else if (int(trim(closed.output)) > 0)
                log_message("Closed " + trim(closed.output) + " connections of removed rule sets", "info");
        }
        remove_file(staged_singbox_config + ".hot-plan");
        remove_file(staged_singbox_backup);
        runtime_changed = true;
        finish_list_change_files(false);
        status = module_status(PRIORITY_UC, [ "start-runtime" ]);
        if (status != 0) {
            log_message("Failed to start Priority runtime after sing-box reload", "fatal");
            cleanup_failed_runtime();
            return status;
        }
        status = module_status(DNS_FAILOVER_UC, [ "start-runtime" ]);
        if (status != 0) {
            log_message("Failed to restart DNS failover runtime after sing-box reload", "fatal");
            cleanup_failed_runtime();
            return status;
        }
    }

    if (plan.needs_zapret_restart == 1)
        module_success(ZAPRET_UC, [ "start-runtime" ]);
    if (plan.needs_zapret2_restart == 1)
        module_success(ZAPRET2_UC, [ "start-runtime" ]);

    if (plan.needs_dnsmasq_configure == 1) {
        status = dnsmasq_configure(true);
        if (status != 0)
            return abort_reload(status, true);
        module_success(STATE_UC, [ "capture-reload-state", RELOAD_STATE_SNAPSHOT_FILE, as_string(RELOAD_STATE_FORMAT) ]);
    }
    else if (plan.needs_dnsmasq_restore == 1) {
        status = dnsmasq_restore(true);
        if (status != 0)
            return abort_reload(status, true);
        module_success(STATE_UC, [ "capture-reload-state", RELOAD_STATE_SNAPSHOT_FILE, as_string(RELOAD_STATE_FORMAT) ]);
    }

    if (plan.needs_cron_refresh == 1) {
        status = refresh_cron();
        if (status != 0)
            return abort_reload(status, false);
    }

    status = finish_reload_status(module_status(STATE_UC, [
        "write-captured-reload-state",
        RELOAD_STATE_FILE,
        RELOAD_STATE_SNAPSHOT_FILE,
        as_string(RELOAD_STATE_FORMAT),
        RULE_CONDITION_CACHE_DIR,
        "1",
        "1"
    ]), reload_config_fingerprint, reason == "pending");
    if (status != 0)
        return status;

    // Clear the durable retry request only after the complete local apply
    // committed its reload state. A failed candidate/guarded transition
    // returns above and deliberately leaves the marker intact.
    if (reason == "list-content")
        remove_file(LIST_UPDATE_RELOAD_FILE);

    if (needs_singbox_transition)
        module_success(RULESET_CACHE_UC, [ "prune-applied" ]);

    finish_list_change_files(false);
    // Required remote rule sets were materialized with the staged config.
    // Existing valid bytes stay offline; periodic workers own freshness.
    return 0;
}

function reload_tracked(reason) {
    if (as_string(getenv("FORKOP_UI_ACTION_TRACKED") || "0") == "1")
        return reload(reason);

    let job_id = trim(module_output(UI_UC, [ "service-action-begin-if-idle", "reload", "runtime_reload" ]));
    if (job_id != "")
        module_success(UI_UC, [ "service-action-update-pid", job_id, owner_pid() ]);

    let status = reload(reason);
    if (job_id != "")
        module_success(UI_UC, [ "service-action-finish-after-command", "reload", job_id, as_string(status) ]);

    return status;
}

function reload_reason_fixture(reason) {
    reason = as_string(reason || "");
    reason = reload_reason_for_generation(reason, fs.stat(LIST_UPDATE_RELOAD_FILE) != null,
        as_string(ARGV[2] || "1") == "1");
    print(reason, "\n");
}

function restart() {
    if (module_success(UI_UC, [ "package-upgrade-transition-active" ])) {
        log_message("Refusing Forkop restart: package upgrade owns the service transition", "warn");
        return 1;
    }
    log_message("Restarting Forkop", "info");

    // Do not let any restart caller bypass the same ownership check as cold
    // start. In particular, delayed startup recovery must never stop an
    // unknown runtime merely to make room for Forkop.
    if (module_success(STATE_UC, [ "sing-box-process-conflict" ])) {
        log_message("Refusing Forkop restart: sing-box process ownership is ambiguous; preserving the existing runtime", "fatal");
        return 1;
    }

    let selector_state = capture_selector_state();
    // Restart is one runtime transition, not an explicit DNS shutdown. Keep
    // the existing dnsmasq transaction and local forwarding while the core
    // is unavailable: a retry is preferable to caching real addresses that
    // bypass FakeIP interception after startup. Failed transitions still
    // restore the original resolver through cleanup_failed_runtime().
    let status = stop_main(false);
    if (status != 0) {
        if (status != 2)
            cleanup_failed_runtime();
        return status;
    }

    status = start_impl();
    if (status != 0) {
        cleanup_failed_runtime();
        return status;
    }

    if (module_success(STATE_UC, [
        "forkop-stably-running",
        RT_TABLE_NAME,
        NFT_TABLE_NAME,
        NFT_FAKEIP_MARK,
        as_string(RUNTIME_STABLE_MIN_AGE)
    ])) {
        write_file(WATCHDOG_READY_FILE, "1\n");
        restore_selector_state(selector_state);
        return 0;
    }

    log_message("Restart verification failed after Forkop was started; stopping Forkop runtime", "fatal");
    cleanup_failed_runtime();
    return 1;
}

// This path is intentionally not used by init.d restart, UCI reload, cron, or
// background workers. LuCI's explicit restart first prepares each cache using
// the existing transactional update implementations, then makes one full
// stop/start transition. None of the prepare modes reload the live runtime.
function manual_restart() {
    log_message("Preparing fresh remote data for manual Forkop restart", "info");

    // A new runtime may schedule its own latency test. Invalidate the previous
    // generation first so its worker exits at the next batch boundary instead
    // of resuming alongside the new runtime.
    if (fs.stat(AUTOMATIC_LATENCY_PENDING_FILE) != null) {
        remove_file(AUTOMATIC_LATENCY_PENDING_FILE);
        log_message("Canceled the previous automatic latency test before manual Forkop restart", "info");
    }

    // Keep lifecycle reloads out of the interval between atomic cache
    // publication and the final stop/start. The prepare workers inherit this
    // ownership and therefore do not release or reacquire the same lock.
    if (!module_success(STATE_UC, [ "acquire-runtime-dir-lock", RELOAD_LOCK_DIR, owner_pid() ])) {
        log_message("Manual restart deferred because another runtime transition is active", "warn");
        return 75;
    }
    let prepare_env = { FORKOP_MANUAL_RESTART_LOCK_HELD: "1" };

    if (module_status_with_env(UPDATES_UC, [ "subscription-prepare-only", "", "" ], prepare_env) != 0) {
        module_success(STATE_UC, [ "release-runtime-dir-lock", RELOAD_LOCK_DIR ]);
        log_message("Manual restart aborted: subscriptions could not be prepared; the running runtime was preserved", "error");
        return 1;
    }
    if (module_success(STATE_UC, [ "has-list-update-sources" ])) {
        if (module_status_with_env(UPDATES_UC, [ "list-update" ], {
            FORKOP_LIST_UPDATE_PREPARE_ONLY: "1",
            FORKOP_MANUAL_RESTART_LOCK_HELD: "1"
        }) != 0) {
            module_success(STATE_UC, [ "release-runtime-dir-lock", RELOAD_LOCK_DIR ]);
            log_message("Manual restart aborted: lists could not be prepared; the running runtime was preserved", "error");
            return 1;
        }
    }

    // lifecycle.uc deliberately does not import updates.uc helpers. Keep the
    // ruleset refresh on the same lists proxy policy as its scheduled path.
    let ruleset_proxy_address = setting_bool("download_lists_via_proxy", false)
        ? SB_SERVICE_MIXED_INBOUND_ADDRESS + ":" + as_string(SB_SERVICE_MIXED_INBOUND_PORT)
        : "";
    let ruleset_status = module_status(RULESET_CACHE_UC, [ "refresh", ruleset_proxy_address ]);
    if (ruleset_status > 1) {
        module_success(STATE_UC, [ "release-runtime-dir-lock", RELOAD_LOCK_DIR ]);
        log_message("Manual restart aborted: remote rule sets could not be prepared; the running runtime was preserved", "error");
        return 1;
    }

    log_message("Remote data preparation completed; performing manual Forkop restart", "info");
    let status = restart();
    module_success(STATE_UC, [ "release-runtime-dir-lock", RELOAD_LOCK_DIR ]);
    return status;
}

function package_manager_remove_if_installed(package_name) {
    package_name = as_string(package_name);
    if (command_success_from_args([ "sh", "-c", "command -v apk" ])) {
        if (command_success_from_args([ "apk", "info", "-e", package_name ]))
            command_success_from_args([ "apk", "del", package_name ]);
        return;
    }

    if (module_success(PACKAGES_UC, [ "opkg-installed", package_name ]))
        command_success_from_args([ "opkg", "remove", "--force-depends", package_name ]);
}

function uninstall() {
    log_message("Uninstalling Forkop", "info");

    if (fs.stat(SERVICE_INIT) != null) {
        stop();
        command_success_from_args([ SERVICE_INIT, "disable" ]);
    }

    dnsmasq_restore_fail_safe();

    if (fs.stat("/etc/init.d/forkop") != null) {
        command_success_from_args([ "/etc/init.d/forkop", "stop" ]);
        command_success_from_args([ "/etc/init.d/forkop", "disable" ]);
    }

    package_manager_remove_if_installed("luci-i18n-forkop-ru");
    package_manager_remove_if_installed("luci-app-forkop");

    if (module_success(SINGBOX_UC, [ "managed-service-installed" ])) {
        module_success(SINGBOX_UC, [ "remove-managed-service-script" ]);
        remove_file("/usr/bin/sing-box");
        remove_file("/usr/lib/libcronet.so");
    }

    command_success_from_args([ "rm", "-rf", "/usr/lib/forkop" ]);
    command_success_from_args([ "rm", "-rf", LUCI_VIEW_DIR ]);
    remove_file(SERVICE_INIT);
    remove_file(BIN_PATH);
    remove_file("/usr/share/luci/menu.d/luci-app-forkop.json");
    remove_file("/usr/share/rpcd/acl.d/luci-app-forkop.json");
    remove_file("/etc/uci-defaults/50_luci-forkop");
    command_success_from_args([ "find", "/usr/lib/lua/luci/i18n", "-maxdepth", "1", "-type", "f", "-name", LUCI_I18N_DOMAIN + ".*.lmo", "-delete" ]);
    remove_file("/usr/lib/lua/luci/i18n/" + LUCI_I18N_DOMAIN + ".ru.lua");
    remove_file("/usr/lib/lua/luci/i18n/" + LUCI_I18N_DOMAIN + ".en.lua");
    command_success("rm -f /var/luci-indexcache* /tmp/luci-indexcache* 2>/dev/null");
    if (fs.stat("/etc/init.d/rpcd") != null)
        command_success_from_args([ "/etc/init.d/rpcd", "reload" ]);

    print("{\"removed\":true}\n");
    return 0;
}

function enable_service() {
    return command_status_from_args([ SERVICE_INIT, "enable" ]);
}

function post_start_latency() {
    if (fs.stat(POST_START_LATENCY_FILE) == null)
        return 0;
    if (fs.stat(PENDING_RELOAD_FILE) != null) {
        log_message("Automatic latency test remains deferred while the post-start pipeline hands off a pending reload", "info");
        return 0;
    }
    remove_file(POST_START_LATENCY_FILE);
    schedule_automatic_latency_after_runtime();
    return 0;
}

function disable_service() {
    return command_status_from_args([ SERVICE_INIT, "disable" ]);
}

let mode = ARGV[0] || "";
let status = 1;

if (mode == "main")
    status = start_main();
else if (mode == "start")
    status = start();
else if (mode == "stop")
    status = stop();
else if (mode == "reload")
    status = reload_tracked(ARGV[1] || "");
else if (mode == "reload-reason-fixture") {
    reload_reason_fixture(ARGV[1] || "");
    status = 0;
}
else if (mode == "dns-failover-apply")
    status = dns_failover_apply(ARGV[1] || "");
else if (mode == "restart")
    status = restart();
else if (mode == "manual-restart")
    status = manual_restart();
else if (mode == "refresh-rulesets-after-start") {
    refresh_rulesets_after_start();
    status = 0;
}
else if (mode == "post-start-latency")
    status = post_start_latency();
else if (mode == "enable")
    status = enable_service();
else if (mode == "disable")
    status = disable_service();
else if (mode == "save-selector-state")
    status = save_selector_state(ARGV[1]);
else if (mode == "restore-selector-state")
    status = restore_saved_selector_state(ARGV[1]);
else if (mode == "dnsmasq-restore" || mode == "restore-dnsmasq")
    status = dnsmasq_restore_fail_safe();
else if (mode == "uninstall")
    status = uninstall();
else {
    warn("Usage: service/lifecycle.uc <start|stop|reload|restart|manual-restart|main|enable|disable|dnsmasq-restore|uninstall> ...\n");
    status = 1;
}

release_start_subscription_update_lock();
exit(status);
