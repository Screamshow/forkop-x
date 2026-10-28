#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let connections = require("config.connections");
let core_ip = require("core.ip");
let core_url = require("core.url");
const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const STATE_UC = getenv("FORKOP_STATE_UC") || LIB_DIR + "/service/state.uc";
const BIN_PATH = getenv("FORKOP_BIN") || "/usr/bin/forkop";
const CRONTAB_FILE = getenv("FORKOP_CRONTAB_FILE") || "/etc/crontabs/root";
const TMP_SING_BOX_FOLDER = getenv("TMP_SING_BOX_FOLDER") || "/tmp/sing-box";
const TMP_RULESET_FOLDER = getenv("TMP_RULESET_FOLDER") || TMP_SING_BOX_FOLDER + "/rulesets";
const RUNTIME_LIST_GENERATION_DIR = getenv("FORKOP_RUNTIME_LIST_GENERATION_DIR") || TMP_SING_BOX_FOLDER + "/list-generation";
const TMP_SUBSCRIPTION_FOLDER = getenv("TMP_SUBSCRIPTION_FOLDER") || TMP_SING_BOX_FOLDER + "/subscriptions";
const RUNTIME_STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const PERSISTENT_LIST_CACHE_DIR = getenv("FORKOP_PERSISTENT_LIST_CACHE_DIR") || "/etc/forkop/list-cache";
const PERSISTENT_RULESET_CACHE_DIR = getenv("FORKOP_RULESET_CACHE_DIR") || "/etc/forkop/ruleset-cache";
const PERSISTENT_LIST_CACHE_MANIFEST = getenv("FORKOP_PERSISTENT_LIST_CACHE_MANIFEST") || PERSISTENT_LIST_CACHE_DIR + "/manifest.json";
const PERSISTENT_LIST_CACHE_FORMAT = getenv("FORKOP_PERSISTENT_LIST_CACHE_FORMAT") || "2";
const LEGACY_PERSISTENT_LIST_CACHE_FORMAT = "1";
// Test-only failure injection. Empty in production; each value names one
// publication phase and is deliberately checked before that phase mutates state.
const LIST_GENERATION_FAIL_PHASE = getenv("FORKOP_LIST_GENERATION_FAIL_PHASE") || "";
const LIST_UPDATE_STATE_FILE = getenv("FORKOP_LIST_UPDATE_STATE_FILE") || PERSISTENT_LIST_CACHE_DIR + "/last-success.timestamp";
const LIST_UPDATE_RUNTIME_STATE_FILE = getenv("FORKOP_LIST_UPDATE_RUNTIME_STATE_FILE") || RUNTIME_STATE_DIR + "/list-update-last-success.timestamp";
const LIST_UPDATE_RUNTIME_SIGNATURE_FILE = getenv("FORKOP_LIST_UPDATE_RUNTIME_SIGNATURE_FILE") || RUNTIME_STATE_DIR + "/list-update-signature";
const LIST_CACHE_LOG_STATE_FILE = getenv("FORKOP_LIST_CACHE_LOG_STATE_FILE") || RUNTIME_STATE_DIR + "/list-cache-restore.log-state";
const LIST_SRS_VALIDATION_DIR = getenv("FORKOP_LIST_SRS_VALIDATION_DIR") || RUNTIME_STATE_DIR + "/validated-list-srs";
const AUTOMATIC_LATENCY_PENDING_FILE = getenv("FORKOP_AUTOMATIC_LATENCY_PENDING_FILE") || "/etc/forkop/automatic-latency-test.pending";
const AUTOMATIC_LATENCY_PENDING_FORMAT = "1";
const PERSISTENT_LIST_CACHE_MAX_BYTES = int(getenv("FORKOP_PERSISTENT_LIST_CACHE_MAX_BYTES") || "8388608");
const PERSISTENT_LIST_CACHE_MIN_FREE_BYTES = int(getenv("FORKOP_PERSISTENT_LIST_CACHE_MIN_FREE_BYTES") || "8388608");
const PERSISTENT_LIST_CACHE_MANIFEST_ALLOWANCE = 65536;
const LIST_DOWNLOAD_MIN_FREE_BYTES = int(getenv("FORKOP_LIST_DOWNLOAD_MIN_FREE_BYTES") || "8388608");
const LIST_UPDATE_PID_FILE = getenv("FORKOP_LIST_UPDATE_PID_FILE") || "/var/run/forkop_list_update.pid";
const SUBSCRIPTION_UPDATE_STATE_DIR = getenv("FORKOP_SUBSCRIPTION_UPDATE_STATE_DIR") || RUNTIME_STATE_DIR + "/subscription-update";
const SUBSCRIPTION_JOB_DIR = getenv("FORKOP_SUBSCRIPTION_UPDATE_JOB_DIR") || "/var/run/forkop/subscription-update-jobs";
const SUBSCRIPTION_UPDATE_LOCK_DIR = getenv("FORKOP_SUBSCRIPTION_UPDATE_LOCK_DIR") || RUNTIME_STATE_DIR + "/subscription-update.lock";
const SUBSCRIPTION_LINKS_DIR = getenv("FORKOP_SUBSCRIPTION_LINKS_DIR") || RUNTIME_STATE_DIR + "/subscription-links";
const SUBSCRIPTION_METADATA_DIR = getenv("FORKOP_SUBSCRIPTION_METADATA_DIR") || RUNTIME_STATE_DIR + "/subscription-metadata";
const OUTBOUND_METADATA_DIR = getenv("FORKOP_OUTBOUND_METADATA_DIR") || RUNTIME_STATE_DIR + "/outbound-metadata";
const SECTION_CACHE_DIR = getenv("FORKOP_SECTION_CACHE_DIR") || RUNTIME_STATE_DIR + "/section-cache";
const RUNTIME_CACHE_FORMAT_FILE = getenv("FORKOP_RUNTIME_CACHE_FORMAT_FILE") || RUNTIME_STATE_DIR + "/cache-format";
const RUNTIME_CACHE_FORMAT = getenv("FORKOP_RUNTIME_CACHE_FORMAT") || "10";
const PERSISTENT_SUBSCRIPTION_CACHE_DIR = getenv("FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR") || "/etc/forkop/subscription-cache";
const PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE = getenv("FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE") || PERSISTENT_SUBSCRIPTION_CACHE_DIR + "/cache-format";
const PERSISTENT_SUBSCRIPTION_CACHE_FORMAT = getenv("FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT") || "9";
const PENDING_RELOAD_FILE = getenv("FORKOP_PENDING_RELOAD_FILE") || RUNTIME_STATE_DIR + "/reload.pending";
const LIST_UPDATE_RELOAD_FILE = getenv("FORKOP_LIST_UPDATE_RELOAD_FILE") || RUNTIME_STATE_DIR + "/list-update.reload";
const RULESET_REFRESH_AFTER_LIST_FILE = getenv("FORKOP_RULESET_REFRESH_AFTER_LIST_FILE") || RUNTIME_STATE_DIR + "/ruleset-refresh-after-list";
const RELOAD_STATE_FILE = getenv("FORKOP_RELOAD_STATE_FILE") || RUNTIME_STATE_DIR + "/reload-state";
const RELOAD_STATE_FORMAT = getenv("FORKOP_RELOAD_STATE_FORMAT") || "1";
const RULE_CONDITION_CACHE_DIR = getenv("FORKOP_RULE_CONDITION_CACHE_DIR") || RUNTIME_STATE_DIR + "/rule-condition-cache";
const RELOAD_LOCK_DIR = getenv("FORKOP_RELOAD_LOCK_DIR") || "/var/run/forkop.reload.lock";
const SERVICE_INIT = getenv("FORKOP_SERVICE_INIT") || "/etc/init.d/forkop";
const PRIORITY_UC = getenv("FORKOP_PRIORITY_UC") || LIB_DIR + "/singbox/priority.uc";
const DNS_FAILOVER_UC = getenv("FORKOP_DNS_FAILOVER_UC") || LIB_DIR + "/singbox/dns_failover.uc";
const SUBSCRIPTION_APPLY_ERROR_FILE = getenv("FORKOP_SUBSCRIPTION_APPLY_ERROR_FILE") || RUNTIME_STATE_DIR + "/subscription-apply-error.json";
let subscription_failure_detail = null;
const DIAGNOSTICS_UC = getenv("FORKOP_DIAGNOSTICS_UC") || LIB_DIR + "/diagnostics/runtime.uc";
const RULESET_CACHE_UC = getenv("FORKOP_RULESET_CACHE_UC") || LIB_DIR + "/singbox/ruleset_cache.uc";
const COMPONENT_JOB_DIR = getenv("UPDATES_JOB_DIR") || getenv("FORKOP_UI_COMPONENT_ACTION_DIR") || "/var/run/forkop/component-actions";
const COMPONENT_UPDATE_CHECK_CACHE_DIR = getenv("FORKOP_COMPONENT_UPDATE_CHECK_CACHE_DIR") || RUNTIME_STATE_DIR + "/component-update-checks";
const COMPONENT_UPDATE_CHECK_STATE_FILE = getenv("FORKOP_COMPONENT_UPDATE_CHECK_STATE_FILE") || RUNTIME_STATE_DIR + "/component-update-check.timestamp";
const COMPONENT_UPDATE_CHECK_LOCK_DIR = getenv("FORKOP_COMPONENT_UPDATE_CHECK_LOCK_DIR") || RUNTIME_STATE_DIR + "/component-update-check.lock";
const COMPONENT_JOB_FINISHED_TTL_MINUTES = getenv("UPDATES_JOB_FINISHED_TTL_MINUTES") || "60";
const COMPONENT_JOB_ORPHAN_OUTPUT_TTL_MINUTES = getenv("UPDATES_JOB_ORPHAN_OUTPUT_TTL_MINUTES") || "60";
const COMPONENT_JOB_STALE_GRACE_SECONDS = getenv("UPDATES_JOB_STALE_GRACE_SECONDS") || getenv("FORKOP_UI_ACTION_STALE_GRACE_SECONDS") || "15";
const SUBSCRIPTION_JOB_FINISHED_TTL_MINUTES = getenv("FORKOP_SUBSCRIPTION_UPDATE_JOB_FINISHED_TTL_MINUTES") || "60";
const SUBSCRIPTION_JOB_ORPHAN_OUTPUT_TTL_MINUTES = getenv("FORKOP_SUBSCRIPTION_UPDATE_JOB_ORPHAN_OUTPUT_TTL_MINUTES") || "60";
const SUBSCRIPTION_JOB_STALE_GRACE_SECONDS = getenv("FORKOP_UI_ACTION_STALE_GRACE_SECONDS") || "15";
const NFT_TABLE_NAME = getenv("NFT_TABLE_NAME") || "ForkopTable";
const NFT_COMMON_SET_NAME = getenv("NFT_COMMON_SET_NAME") || "forkop_subnets";
const NFT_COMMON6_SET_NAME = getenv("NFT_COMMON6_SET_NAME") || "forkop_subnets6";
const NFT_IP_PORT_SET_NAME = getenv("NFT_IP_PORT_SET_NAME") || "forkop_ip_ports";
const NFT_IP_PORT6_SET_NAME = getenv("NFT_IP_PORT6_SET_NAME") || "forkop_ip6_ports";
const NFT_DISCORD_SET_NAME = getenv("NFT_DISCORD_SET_NAME") || "forkop_discord_subnets";
const NFT_DISCORD6_SET_NAME = getenv("NFT_DISCORD6_SET_NAME") || "forkop_discord_subnets6";
const NFT_INTERFACE_SET_NAME = getenv("NFT_INTERFACE_SET_NAME") || "forkop_interfaces";
const NFT_FAKEIP_MARK = getenv("NFT_FAKEIP_MARK") || "0x04000000";
const SB_SERVICE_MIXED_INBOUND_ADDRESS = getenv("SB_SERVICE_MIXED_INBOUND_ADDRESS") || "127.0.0.1";
const SB_SERVICE_MIXED_INBOUND_PORT = getenv("SB_SERVICE_MIXED_INBOUND_PORT") || "4534";
const SB_VARIANT_STATE_FILE = getenv("SB_VARIANT_STATE_FILE") || "/etc/forkop/sing-box-variant";
let core_constants = require("core.constants");
const GITHUB_RAW_URL = getenv("GITHUB_RAW_URL") || core_constants.GITHUB_RAW_URL;
const FORKOP_MIRROR_BASE_URL = core_constants.FORKOP_MIRROR_BASE_URL || "";
const MIRROR_FAILURE_THRESHOLD = 6;
const BUILTIN_SUBNET_URLS = {
    twitter: [ getenv("SUBNETS_TWITTER") || GITHUB_RAW_URL + "/Subnets/IPv4/twitter.lst", getenv("SUBNETS_TWITTER6") || GITHUB_RAW_URL + "/Subnets/IPv6/twitter.lst" ],
    meta: [ getenv("SUBNETS_META") || GITHUB_RAW_URL + "/Subnets/IPv4/meta.lst", getenv("SUBNETS_META6") || GITHUB_RAW_URL + "/Subnets/IPv6/meta.lst" ],
    discord: [ getenv("SUBNETS_DISCORD") || GITHUB_RAW_URL + "/Subnets/IPv4/discord.lst", getenv("SUBNETS_DISCORD6") || GITHUB_RAW_URL + "/Subnets/IPv6/discord.lst" ],
    roblox: [ getenv("SUBNETS_ROBLOX") || GITHUB_RAW_URL + "/Subnets/IPv4/roblox.lst" ],
    telegram: [ getenv("SUBNETS_TELERAM") || GITHUB_RAW_URL + "/Subnets/IPv4/telegram.lst", getenv("SUBNETS_TELERAM6") || GITHUB_RAW_URL + "/Subnets/IPv6/telegram.lst" ],
    cloudflare: [ getenv("SUBNETS_CLOUDFLARE") || GITHUB_RAW_URL + "/Subnets/IPv4/cloudflare.lst", getenv("SUBNETS_CLOUDFLARE6") || GITHUB_RAW_URL + "/Subnets/IPv6/cloudflare.lst" ],
    hetzner: [ getenv("SUBNETS_HETZNER") || GITHUB_RAW_URL + "/Subnets/IPv4/hetzner.lst", getenv("SUBNETS_HETZNER6") || GITHUB_RAW_URL + "/Subnets/IPv6/hetzner.lst" ],
    ovh: [ getenv("SUBNETS_OVH") || GITHUB_RAW_URL + "/Subnets/IPv4/ovh.lst", getenv("SUBNETS_OVH6") || GITHUB_RAW_URL + "/Subnets/IPv6/ovh.lst" ],
    digitalocean: [ getenv("SUBNETS_DIGITALOCEAN") || GITHUB_RAW_URL + "/Subnets/IPv4/digitalocean.lst", getenv("SUBNETS_DIGITALOCEAN6") || GITHUB_RAW_URL + "/Subnets/IPv6/digitalocean.lst" ],
    cloudfront: [ getenv("SUBNETS_CLOUDFRONT") || GITHUB_RAW_URL + "/Subnets/IPv4/cloudfront.lst", getenv("SUBNETS_CLOUDFRONT6") || GITHUB_RAW_URL + "/Subnets/IPv6/cloudfront.lst" ]
};
let rule_config = null;
let routing_rulesets_module_value = null;
let singbox_rulesets_module_value = null;
let list_mirror_download_state = {};
let list_ruleset_snapshot_dir = "";
let list_nft_candidate_file = "";
let list_download_staging_dir = "";
let list_download_cache = {};
let list_download_metadata = [];
let list_download_sequence = 0;
let list_update_signature_at_start = "";
let subscription_outbounds_changed = false;
let runtime_generation_commit_changed = false;

function routing_rulesets_module() {
    if (routing_rulesets_module_value == null)
        routing_rulesets_module_value = require("routing.rulesets");
    return routing_rulesets_module_value;
}

function singbox_rulesets_module() {
    if (singbox_rulesets_module_value == null)
        singbox_rulesets_module_value = require("singbox.rulesets");
    return singbox_rulesets_module_value;
}

function as_string(value) {
    return value == null ? "" : "" + value;
}

function read_stdin() {
    let data = fs.readfile("/dev/stdin");
    return data == null ? "" : data;
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

function file_md5(path) {
    path = as_string(path);
    if (path == "" || fs.stat(path) == null)
        return "";

    let fields = split(trim(command_output(command_from_args([ "md5sum", path ]))), /[ \t\r\n]+/);
    return length(fields) > 0 ? as_string(fields[0]) : "";
}

function command_output_from_args(args) {
    return command_output(command_from_args(args));
}

function command_status(command) {
    let status = int(system(command));
    return status > 255 ? int(status / 256) : status;
}

function command_capture(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return { status: 1, output: "" };

    let data = pipe.read("all");
    let status = int(pipe.close());
    return { status: status > 255 ? int(status / 256) : status, output: data == null ? "" : as_string(data) };
}

function command_success(command) {
    return command_status(command + " >/dev/null 2>&1") == 0;
}

function command_success_from_args(args) {
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function now_seconds() {
    return int(clock()[0]);
}

function ensure_dir(path) {
    return command_success_from_args([ "mkdir", "-p", path ]);
}

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "forkop", "[" + level + "] " + as_string(message) ]);
}

// Runtime logs need enough context to identify a failing remote source, but
// subscription and list URLs can carry credentials in userinfo or query
// parameters. Keep only the public host and path. This helper is deliberately
// shared by every remote-list diagnostic below.
function safe_remote_source_identity(url, logical_name) {
    let value = trim(as_string(url));
    let label = trim(as_string(logical_name));
    value = replace(value, /^[A-Za-z][A-Za-z0-9+.-]*:\/\//, "");
    value = replace(value, /[?#].*$/, "");
    value = replace(value, /^[^/@]*@/, "");

    let slash = index(value, "/");
    let host = slash >= 0 ? substr(value, 0, slash) : value;
    let path = slash >= 0 ? substr(value, slash) : "";
    if (host == "" || index(host, " ") >= 0 || index(host, "\t") >= 0)
        return label == "" ? "configured remote source" : "rule '" + label + "' remote source";

    let identity = host + path;
    return label == "" ? identity : "rule '" + label + "': " + identity;
}

function read_json_file(path) {
    let data = fs.readfile(path);
    if (data == null)
        return null;

    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function json_text(value) {
    return sprintf("%J", value) + "\n";
}

function write_file(path, value) {
    return fs.writefile(as_string(path), as_string(value)) != null;
}

function write_state_file(path, value) {
    path = as_string(path);
    let stamp = clock();
    let tmp_path = sprintf("%s.%d.%d.tmp", path, stamp[0], stamp[1]);

    if (!write_file(tmp_path, json_text(value))) {
        fs.unlink(tmp_path);
        return false;
    }
    if (!fs.rename(tmp_path, path)) {
        fs.unlink(tmp_path);
        return false;
    }
    return true;
}

function remove_file(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function file_first_line(path) {
    let data = fs.readfile(path);
    if (data == null)
        exit(1);

    let newline = index(data, "\n");
    print(newline >= 0 ? substr(data, 0, newline) : data, "\n");
}

function file_first_line_value(path) {
    let data = fs.readfile(path);
    if (data == null)
        return "";

    let newline = index(data, "\n");
    return newline >= 0 ? substr(data, 0, newline) : data;
}

function arg_bool(value) {
    value = lc(as_string(value));
    return value == "true" || value == "1" || value == "yes" || value == "on";
}

function arg_number(value) {
    value = as_string(value);
    if (value == "" || match(value, /[^0-9-]/))
        return 0;
    return int(value);
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function text_first_chars(value, max_chars) {
    value = as_string(value);
    max_chars = int(max_chars || "0", 10) || 0;
    return max_chars > 0 && length(value) > max_chars ? substr(value, 0, max_chars) : value;
}

function file_last_nonblank_line_value(path, fallback, max_chars) {
    let data = fs.readfile(path);
    let result = "";

    if (data != null) {
        for (let line in split(as_string(data), "\n"))
            if (match(line, /^[[:space:]]*$/) == null)
                result = line;
    }

    if (result == "")
        result = as_string(fallback);

    return text_first_chars(result, max_chars);
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

function bool_option(section, key, fallback) {
    let value = object_or_empty(section)[key];
    return value == null ? !!fallback : arg_bool(value);
}

function section_name(section) {
    return as_string(object_or_empty(section)[".name"]);
}

function file_exists_value(path) {
    return fs.stat(as_string(path)) != null;
}

function file_nonempty(path) {
    let stat = fs.stat(as_string(path));
    return stat != null && int(stat.size || 0) > 0;
}

function rounded_file_bytes(path) {
    let stat = fs.stat(as_string(path));
    let size = stat == null ? 0 : int(stat.size || 0);
    return size <= 0 ? 0 : int((size + 4095) / 4096) * 4096;
}

function persistent_list_cache_available_bytes() {
    let override = getenv("FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES");
    if (override != null && as_string(override) != "")
        return int(override);

    let slash = rindex(PERSISTENT_LIST_CACHE_DIR, "/");
    let probe = slash >= 0 ? substr(PERSISTENT_LIST_CACHE_DIR, 0, slash) : "";
    if (probe == "")
        probe = "/";
    ensure_dir(probe);
    let output = trim(command_output_from_args([ "df", "-Pk", probe ]));
    let lines = split(output, "\n");
    if (length(lines) < 2)
        return -1;
    let fields = split(trim(lines[length(lines) - 1]), /[ \t]+/);
    return length(fields) >= 4 ? int(fields[3]) * 1024 : -1;
}

function persistent_list_cache_estimated_bytes() {
    let total = PERSISTENT_LIST_CACHE_MANIFEST_ALLOWANCE;
    for (let path in fs.glob(TMP_RULESET_FOLDER + "/*")) {
        let name = substr(path, length(TMP_RULESET_FOLDER) + 1);
        if (match(as_string(name), /^[A-Za-z0-9_][A-Za-z0-9_.-]*-(lists|remote-domains|remote-subnets)-ruleset\.json$/) != null)
            total += rounded_file_bytes(path);
    }
    for (let source in list_download_metadata) {
        source = object_or_empty(source);
        let cached = as_string(list_download_cache[as_string(source.url)]);
        if (cached != "")
            total += rounded_file_bytes(cached);
    }
    return total;
}

function directory_allocated_bytes(path) {
    let output = trim(command_output(command_from_args([ "du", "-sk", path ]) + " 2>/dev/null"));
    if (output == "")
        return fs.stat(path) == null ? 0 : -1;
    let fields = split(output, /[ \t\r\n]+/);
    return length(fields) > 0 ? int(fields[0]) * 1024 : -1;
}

function list_cache_has_capacity(required, staged) {
    let ruleset_bytes = directory_allocated_bytes(PERSISTENT_RULESET_CACHE_DIR);
    if (ruleset_bytes < 0)
        ruleset_bytes = 0;
    if (required < 0 || required + ruleset_bytes > PERSISTENT_LIST_CACHE_MAX_BYTES) {
        log_message(
            "Persistent list caches need " + (required + ruleset_bytes) + " bytes, exceeding the " +
                PERSISTENT_LIST_CACHE_MAX_BYTES + " byte combined limit; keeping the lists in runtime memory only",
            "warn"
        );
        return false;
    }

    let available = persistent_list_cache_available_bytes();
    if (available < 0) {
        log_message("Could not determine free flash space; keeping the lists in runtime memory only", "warn");
        return false;
    }
    let remaining = staged ? available : available - required;
    if (remaining < PERSISTENT_LIST_CACHE_MIN_FREE_BYTES) {
        log_message(
            "Persistent list cache would leave only " + remaining + " bytes free; at least " +
                PERSISTENT_LIST_CACHE_MIN_FREE_BYTES + " bytes are reserved, keeping the lists in runtime memory only",
            "warn"
        );
        return false;
    }
    return true;
}

function cache_copy_file(source, target) {
    let data = fs.readfile(as_string(source));
    return data != null && write_file(target, data);
}

function valid_list_ruleset_file(path) {
    let value = read_json_file(path);
    return type(value) == "object" && type(value.rules) == "array";
}

function managed_list_ruleset_name(name) {
    return match(as_string(name), /^[A-Za-z0-9_][A-Za-z0-9_.-]*-(lists|remote-domains|remote-subnets)-ruleset\.json$/) != null;
}

function current_list_update_signature() {
    return trim(command_output_from_args([
        "ucode", "-L", LIB_DIR, STATE_UC, "list-update-signature"
    ]));
}

function persistent_list_cache_manifest() {
    let manifest = read_json_file(PERSISTENT_LIST_CACHE_MANIFEST);
    return type(manifest) == "object" ? manifest : null;
}

function parent_dir(path) {
    path = as_string(path);
    let slash = rindex(path, "/");
    return slash >= 0 ? substr(path, 0, slash) : "";
}

function ensure_parent_dir(path) {
    let dir = parent_dir(path);
    return dir == "" || dir == "." || ensure_dir(dir);
}

function list_cache_log_once(key, message, level) {
    key = as_string(key);
    if (key != "" && trim(file_first_line_value(LIST_CACHE_LOG_STATE_FILE)) == key)
        return;

    log_message(message, level);
    if (key != "") {
        ensure_parent_dir(LIST_CACHE_LOG_STATE_FILE);
        write_file(LIST_CACHE_LOG_STATE_FILE, key + "\n");
    }
}

function generation_phase_failed(phase) {
    return LIST_GENERATION_FAIL_PHASE == phase;
}

function validate_staged_list_download(path, format) {
    if (!file_nonempty(path))
        return false;
    if (format == "json")
        return valid_list_ruleset_file(path);
    if (format != "srs")
        return true;

    // Parse every compiled rule without expanding domain/IP structures into
    // JSON alongside the running proxy (large lists can otherwise cause OOM).
    return command_success_from_args([
        "sing-box", "rule-set", "match", "--format", "binary", path,
        "forkop-validation.invalid"
    ]);
}

function owner_pid() {
    let pid = trim(command_output_from_args([ "sh", "-c", "echo $PPID" ]));
    return match(pid, /^[0-9]+$/) != null ? pid : "0";
}

function generation_identity(signature) {
    let stamp = clock();
    return "gen-" + as_string(stamp[0]) + "-" + as_string(stamp[1]) + "-" + owner_pid() + "-" + substr(as_string(signature), 0, 12);
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

function list_option_values(section, key) {
    return whitespace_items(object_or_empty(section)[key]);
}

function uci_sections(type_name) {
    return uci_core.section_objects(CONFIG_NAME, as_string(type_name));
}

function uci_settings() {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function list_preflight_add(entries, seen, url, format) {
    url = as_string(url);
    if (url == "" || seen[url])
        return;
    seen[url] = true;
    push(entries, { url, format: as_string(format) });
}

function list_preflight_entries(sections) {
    let entries = [];
    let seen = {};
    for (let section in sections) {
        if (!bool_option(section, "enabled", true))
            continue;
        for (let service in connections.community_lists(section))
            for (let url in array_or_empty(BUILTIN_SUBNET_URLS[as_string(service)]))
                list_preflight_add(entries, seen, url, "plain");
        for (let reference in list_option_values(section, "domain_ip_lists"))
            if (match(reference, /^https?:\/\//) != null)
                list_preflight_add(entries, seen, reference, "plain");
        for (let url in list_option_values(section, "remote_domain_lists")) {
            let extension = singbox_rulesets_module().file_extension(url);
            if (extension != "json" && extension != "srs")
                list_preflight_add(entries, seen, url, "plain");
        }
        for (let url in list_option_values(section, "remote_subnet_lists")) {
            let extension = singbox_rulesets_module().file_extension(url);
            list_preflight_add(entries, seen, url, extension == "json" || extension == "srs" ? extension : "plain");
        }
        for (let reference in connections.rule_sets_with_subnets(section)) {
            if (match(reference, /^https?:\/\//) == null)
                continue;
            let extension = singbox_rulesets_module().file_extension(reference);
            list_preflight_add(entries, seen, reference, extension == "json" || extension == "srs" ? extension : "srs");
        }
    }
    return entries;
}

function generation_file_valid(root, entry) {
    entry = object_or_empty(entry);
    let name = as_string(entry.name);
    let kind = as_string(entry.kind);
    let path = root + "/" + name;
    if (kind != "ruleset" && kind != "source")
        return { valid: false, reason: "manifest contains an unknown generation file kind", key: "kind-" + name };
    if ((kind == "ruleset" && !managed_list_ruleset_name(name)) ||
        (kind == "source" && match(name, /^source-[0-9]+$/) == null))
        return { valid: false, reason: "manifest contains an invalid " + kind + " file name", key: "invalid-name-" + name };
    if (!file_nonempty(path))
        return { valid: false, reason: "generation file '" + name + "' is missing or empty", key: "missing-" + name };
    let stat = fs.stat(path);
    if (int(entry.size || -1) != int(object_or_empty(stat).size || 0))
        return { valid: false, reason: "size verification failed for generation file '" + name + "'", key: "size-" + name };
    if (file_md5(path) != as_string(entry.md5))
        return { valid: false, reason: "checksum verification failed for generation file '" + name + "'", key: "md5-" + name };
    if (kind == "ruleset" && !valid_list_ruleset_file(path))
        return { valid: false, reason: "rule-set file '" + name + "' is not valid JSON", key: "json-" + name };
    if (kind == "source" && as_string(entry.url) == "")
        return { valid: false, reason: "source file '" + name + "' has no identity", key: "source-identity-" + name };
    // The manifest checksum was verified above. Parsing the same SRS on
    // every cache check is expensive on routers, so remember a successful
    // schema check for this exact content in the boot-local runtime directory.
    // Fresh downloads still pass through full validation before publication.
    let source_format = as_string(entry.source_format);
    let srs_stamp = source_format == "srs" ? LIST_SRS_VALIDATION_DIR + "/" + as_string(entry.md5) : "";
    let srs_checked = srs_stamp != "" && trim(as_string(fs.readfile(srs_stamp))) == "srs-v1";
    if (kind == "source" && !srs_checked && !validate_staged_list_download(path, source_format))
        return { valid: false, reason: "source file '" + name + "' failed " + as_string(entry.source_format) + " validation", key: "source-schema-" + name };
    if (kind == "source" && srs_stamp != "" && !srs_checked && ensure_dir(LIST_SRS_VALIDATION_DIR))
        fs.writefile(srs_stamp, "srs-v1\n");
    return { valid: true, bytes: int(object_or_empty(stat).size || 0) };
}

function list_generation_validation(root, expected_signature) {
    let manifest = read_json_file(root + "/manifest.json");
    if (manifest == null || as_string(manifest.format) != PERSISTENT_LIST_CACHE_FORMAT)
        return { valid: false, reason: "generation manifest is missing, invalid, or incompatible", key: "manifest" };
    if (match(as_string(manifest.generation), /^gen-[A-Za-z0-9_.-]+$/) == null)
        return { valid: false, reason: "generation identity is invalid", key: "generation" };
    if (expected_signature == "" || as_string(manifest.signature) != expected_signature)
        return { valid: false, reason: "generation signature is stale for the current list configuration", key: "signature" };
    if (type(manifest.files) != "array")
        return { valid: false, reason: "generation file list is invalid", key: "files" };
    if (length(manifest.files) == 0 && length(list_preflight_entries(uci_sections("section"))) > 0)
        return { valid: false, reason: "empty generation cannot satisfy required list sources", key: "empty-sources" };
    let names = {};
    let sources = 0;
    let rulesets = 0;
    let bytes = 0;
    for (let entry in manifest.files) {
        entry = object_or_empty(entry);
        let name = as_string(entry.name);
        if (name == "" || names[name])
            return { valid: false, reason: "generation contains duplicate file names", key: "duplicate-" + name };
        names[name] = true;
        let checked = generation_file_valid(root, entry);
        if (!checked.valid)
            return checked;
        bytes += checked.bytes;
        if (as_string(entry.kind) == "source") sources++;
        if (as_string(entry.kind) == "ruleset") rulesets++;
    }
    return { valid: true, manifest, signature: expected_signature, source_count: sources, file_count: rulesets, total_bytes: bytes };
}

// Generation identities are deliberately unique publication labels, not a
// content comparison mechanism.  A no-op source refresh therefore compares
// the validated manifest payload (including source identity) and ignores the
// identity itself.
function list_generation_manifest_content_equal(left, right) {
    left = object_or_empty(left);
    right = object_or_empty(right);
    let left_files = type(left.files) == "array" ? left.files : [];
    let right_files = type(right.files) == "array" ? right.files : [];
    if (as_string(left.signature) != as_string(right.signature) || length(left_files) != length(right_files))
        return false;

    let right_by_name = {};
    for (let entry in right_files) {
        entry = object_or_empty(entry);
        let name = as_string(entry.name);
        if (name == "" || right_by_name[name] != null)
            return false;
        right_by_name[name] = entry;
    }
    for (let entry in left_files) {
        entry = object_or_empty(entry);
        let name = as_string(entry.name);
        let other = object_or_empty(right_by_name[name]);
        if (name == "" || type(right_by_name[name]) != "object" ||
            as_string(entry.kind) != as_string(other.kind) ||
            int(entry.size || 0) != int(other.size || 0) ||
            as_string(entry.md5) != as_string(other.md5))
            return false;
        if (as_string(entry.kind) == "source" &&
            (as_string(entry.url) != as_string(other.url) ||
             as_string(entry.source_format) != as_string(other.source_format)))
            return false;
    }
    return true;
}

// 1.3.8 stored a checked ruleset map and source metadata separately.  It is
// deliberately not accepted by v2 validation: it must first be copied into a
// fully described v2 generation and pass the ordinary v2 validator.
function legacy_v1_list_cache_validation(root, expected_signature) {
    let manifest = read_json_file(root + "/manifest.json");
    if (manifest == null || as_string(manifest.format) != LEGACY_PERSISTENT_LIST_CACHE_FORMAT)
        return { valid: false, reason: "legacy cache manifest is missing or incompatible", key: "legacy-manifest" };
    if (expected_signature == "" || as_string(manifest.signature) != expected_signature)
        return { valid: false, reason: "legacy cache signature is stale for the current list configuration", key: "legacy-signature" };
    if (type(manifest.files) != "object" || type(manifest.sources) != "array")
        return { valid: false, reason: "legacy cache file metadata is invalid", key: "legacy-files" };

    let names = {};
    let files = [];
    let bytes = 0;
    for (let name, md5 in manifest.files) {
        name = as_string(name);
        let path = root + "/" + name;
        if (names[name] || !managed_list_ruleset_name(name) || !file_nonempty(path) ||
            file_md5(path) != as_string(md5) || !valid_list_ruleset_file(path))
            return { valid: false, reason: "legacy cache rule-set validation failed", key: "legacy-ruleset-" + name };
        names[name] = true;
        let stat = fs.stat(path);
        let size = int(object_or_empty(stat).size || 0);
        bytes += size;
        push(files, { name, kind: "ruleset", size, md5: as_string(md5) });
    }
    for (let source in manifest.sources) {
        source = object_or_empty(source);
        let name = as_string(source.name);
        let url = as_string(source.url);
        let format = as_string(source.format);
        let path = root + "/" + name;
        if (names[name] || url == "" || match(name, /^source-[0-9]+$/) == null ||
            !file_nonempty(path) || file_md5(path) != as_string(source.md5) ||
            !validate_staged_list_download(path, format))
            return { valid: false, reason: "legacy cache source validation failed", key: "legacy-source-" + name };
        names[name] = true;
        let stat = fs.stat(path);
        let size = int(object_or_empty(stat).size || 0);
        bytes += size;
        push(files, { name, kind: "source", url, source_format: format, size, md5: as_string(source.md5) });
    }
    if (length(files) == 0)
        return { valid: false, reason: "legacy cache has no generation files", key: "legacy-empty" };
    return { valid: true, signature: expected_signature, files, total_bytes: bytes };
}

function migrate_legacy_v1_persistent_list_cache() {
    let signature = current_list_update_signature();
    let legacy = legacy_v1_list_cache_validation(PERSISTENT_LIST_CACHE_DIR, signature);
    if (!legacy.valid)
        return false;

    let stage = PERSISTENT_LIST_CACHE_DIR + ".stage";
    let previous = PERSISTENT_LIST_CACHE_DIR + ".previous";
    command_success_from_args([ "rm", "-rf", stage ]);
    if (!list_cache_has_capacity(legacy.total_bytes + PERSISTENT_LIST_CACHE_MANIFEST_ALLOWANCE, false) || !ensure_dir(stage))
        return false;

    for (let entry in legacy.files) {
        entry = object_or_empty(entry);
        let name = as_string(entry.name);
        if (!cache_copy_file(PERSISTENT_LIST_CACHE_DIR + "/" + name, stage + "/" + name)) {
            command_success_from_args([ "rm", "-rf", stage ]);
            return false;
        }
    }
    let manifest = {
        format: PERSISTENT_LIST_CACHE_FORMAT,
        generation: generation_identity(signature),
        signature,
        files: legacy.files
    };
    if (!write_file(stage + "/manifest.json", json_text(manifest)) ||
        !list_generation_validation(stage, signature).valid) {
        command_success_from_args([ "rm", "-rf", stage ]);
        return false;
    }
    if (!cache_copy_file(PERSISTENT_LIST_CACHE_DIR + "/last-success.timestamp", stage + "/last-success.timestamp"))
        write_file(stage + "/last-success.timestamp", "0\n");
    command_success_from_args([ "chmod", "0700", stage ]);
    for (let path in fs.glob(stage + "/*"))
        command_success_from_args([ "chmod", "0600", path ]);

    command_success_from_args([ "rm", "-rf", previous ]);
    if (!fs.rename(PERSISTENT_LIST_CACHE_DIR, previous)) {
        command_success_from_args([ "rm", "-rf", stage ]);
        return false;
    }
    if (!fs.rename(stage, PERSISTENT_LIST_CACHE_DIR)) {
        fs.rename(previous, PERSISTENT_LIST_CACHE_DIR);
        command_success_from_args([ "rm", "-rf", stage ]);
        return false;
    }
    command_success_from_args([ "rm", "-rf", previous ]);
    list_cache_log_once("migrated-v1-" + signature, "Migrated a validated legacy list cache to generation format 2 without network access", "info");
    return true;
}

function recover_list_generation_transaction(root, signature) {
    let stage = root + ".stage";
    let previous = root + ".previous";
    let active = list_generation_validation(root, signature);
    let old = list_generation_validation(previous, signature);

    // A stage has no publication marker, so it is never a recovery source.
    // If active is corrupt, only a fully validated previous generation may
    // replace it. This also handles interruption after active -> previous.
    if (!active.valid && old.valid) {
        if (file_exists_value(root))
            command_success_from_args([ "rm", "-rf", root ]);
        if (!fs.rename(previous, root))
            return false;
        active = list_generation_validation(root, signature);
    }
    if (active.valid && file_exists_value(previous))
        command_success_from_args([ "rm", "-rf", previous ]);
    command_success_from_args([ "rm", "-rf", stage ]);
    return active.valid;
}

function persistent_list_cache_validation() {
    let signature = current_list_update_signature();
    let manifest = persistent_list_cache_manifest();
    if (manifest != null && as_string(manifest.format) == LEGACY_PERSISTENT_LIST_CACHE_FORMAT)
        migrate_legacy_v1_persistent_list_cache();
    recover_list_generation_transaction(PERSISTENT_LIST_CACHE_DIR, signature);
    return list_generation_validation(PERSISTENT_LIST_CACHE_DIR, signature);
}

function runtime_list_cache_active() {
    let signature = current_list_update_signature();
    recover_list_generation_transaction(RUNTIME_LIST_GENERATION_DIR, signature);
    return list_generation_validation(RUNTIME_LIST_GENERATION_DIR, signature).valid;
}

function activate_persistent_list_generation(validation) {
    let stage = RUNTIME_LIST_GENERATION_DIR + ".stage";
    let previous = RUNTIME_LIST_GENERATION_DIR + ".previous";
    command_success_from_args([ "rm", "-rf", stage ]);
    if (!ensure_dir(stage))
        return false;
    for (let entry in validation.manifest.files) {
        let name = as_string(object_or_empty(entry).name);
        if (!cache_copy_file(PERSISTENT_LIST_CACHE_DIR + "/" + name, stage + "/" + name)) {
            command_success_from_args([ "rm", "-rf", stage ]);
            return false;
        }
    }
    if (!write_file(stage + "/manifest.json", json_text(validation.manifest)) ||
        !list_generation_validation(stage, validation.signature).valid) {
        command_success_from_args([ "rm", "-rf", stage ]);
        return false;
    }
    command_success_from_args([ "rm", "-rf", previous ]);
    if (file_exists_value(RUNTIME_LIST_GENERATION_DIR) && !fs.rename(RUNTIME_LIST_GENERATION_DIR, previous)) {
        command_success_from_args([ "rm", "-rf", stage ]);
        return false;
    }
    if (!fs.rename(stage, RUNTIME_LIST_GENERATION_DIR)) {
        if (file_exists_value(previous))
            fs.rename(previous, RUNTIME_LIST_GENERATION_DIR);
        command_success_from_args([ "rm", "-rf", stage ]);
        return false;
    }
    command_success_from_args([ "rm", "-rf", previous ]);
    return true;
}

function persistent_list_cache_valid() {
    return persistent_list_cache_validation().valid;
}

function restore_persistent_list_cache() {
    // A successful RAM-only update is newer than the flash cache. Preserve it
    // across service reloads during this boot; /var/run and /tmp disappear on
    // a real reboot, when the last persistent cache becomes the fallback.
    if (runtime_list_cache_active()) {
        let runtime_timestamp = trim(file_first_line_value(LIST_UPDATE_RUNTIME_STATE_FILE));
        let runtime_signature = trim(file_first_line_value(LIST_UPDATE_RUNTIME_SIGNATURE_FILE));
        let runtime = list_generation_validation(RUNTIME_LIST_GENERATION_DIR, current_list_update_signature());
        let persistent = persistent_list_cache_validation();
        // A normal successful update leaves a runtime copy of the same
        // generation.  It is not RAM-only; reserve that diagnostic for a
        // missing or older persistent LKG.
        if (runtime_timestamp != "" && runtime_signature == current_list_update_signature() && runtime.valid &&
            (!persistent.valid || as_string(persistent.manifest.generation) != as_string(runtime.manifest.generation)))
            list_cache_log_once(
                "ram-" + runtime_timestamp + "-" + runtime_signature,
                "Using the newer RAM-only list generation from this boot; the older persistent cache was not restored",
                "info"
            );
        return true;
    }

    let validation = persistent_list_cache_validation();
    if (!validation.valid) {
        list_cache_log_once(
            "rejected-" + as_string(validation.key),
            "Persistent list cache was not restored: " + as_string(validation.reason),
            "warn"
        );
        return false;
    }

    let manifest = validation.manifest;
    let generation_root = PERSISTENT_LIST_CACHE_DIR;
    if (!ensure_dir(TMP_RULESET_FOLDER)) {
        list_cache_log_once("restore-runtime-dir", "Persistent list cache was not restored: runtime rule-set directory could not be created", "warn");
        return false;
    }

    let keep = {};
    for (let entry in manifest.files) {
        entry = object_or_empty(entry);
        if (as_string(entry.kind) != "ruleset")
            continue;
        let name = as_string(entry.name);
        let source = generation_root + "/" + name;
        let target = TMP_RULESET_FOLDER + "/" + name;
        let temporary = target + ".restore." + as_string(now_seconds());
        keep[name] = true;
        remove_file(temporary);
        if (!cache_copy_file(source, temporary) || file_md5(temporary) != as_string(entry.md5) || !fs.rename(temporary, target)) {
            remove_file(temporary);
            list_cache_log_once("restore-copy-" + name, "Persistent list cache was not restored: failed to copy and verify rule-set file '" + name + "'", "warn");
            return false;
        }
    }

    for (let path in fs.glob(TMP_RULESET_FOLDER + "/*")) {
        let name = substr(path, length(TMP_RULESET_FOLDER) + 1);
        if (managed_list_ruleset_name(name) && !keep[name])
            remove_file(path);
    }
    if (!activate_persistent_list_generation(validation))
        return false;
    list_cache_log_once(
        "restored-" + as_string(validation.signature) + "-" + as_string(validation.total_bytes),
        "Restored " + validation.source_count + " list sources and " + validation.file_count +
            " rule-set files from persistent cache (" + validation.total_bytes +
            " bytes); network access was not required",
        "info"
    );
    return true;
}

function restore_runtime_list_generation() {
    let validation = list_generation_validation(RUNTIME_LIST_GENERATION_DIR, current_list_update_signature());
    if (!validation.valid)
        return false;
    if (!ensure_dir(TMP_RULESET_FOLDER))
        return false;
    let keep = {};
    for (let entry in validation.manifest.files) {
        entry = object_or_empty(entry);
        if (as_string(entry.kind) != "ruleset")
            continue;
        let name = as_string(entry.name);
        let target = TMP_RULESET_FOLDER + "/" + name;
        let temporary = target + ".restore." + as_string(now_seconds());
        keep[name] = true;
        remove_file(temporary);
        if (!cache_copy_file(RUNTIME_LIST_GENERATION_DIR + "/" + name, temporary) ||
            file_md5(temporary) != as_string(entry.md5) || !fs.rename(temporary, target)) {
            remove_file(temporary);
            return false;
        }
    }
    for (let path in fs.glob(TMP_RULESET_FOLDER + "/*")) {
        let name = substr(path, length(TMP_RULESET_FOLDER) + 1);
        if (managed_list_ruleset_name(name) && !keep[name])
            remove_file(path);
    }
    return true;
}

function invalidate_persistent_list_cache(preserve_runtime) {
    command_success_from_args([ "rm", "-rf", PERSISTENT_LIST_CACHE_DIR ]);
    // Reload has already generated and applied local lists. Invalidating a
    // remote cache signature must not remove files referenced by that config.
    if (preserve_runtime)
        return true;
    for (let path in fs.glob(TMP_RULESET_FOLDER + "/*")) {
        let name = substr(path, length(TMP_RULESET_FOLDER) + 1);
        if (managed_list_ruleset_name(name))
            remove_file(path);
    }
    return true;
}

function runtime_list_generation_has_capacity(required) {
    if (!ensure_dir(TMP_SING_BOX_FOLDER))
        return false;
    let output = trim(command_output_from_args([ "df", "-Pk", TMP_SING_BOX_FOLDER ]));
    let lines = split(output, "\n");
    let fields = length(lines) >= 2 ? split(trim(lines[length(lines) - 1]), /[ \t]+/) : [];
    let available = length(fields) >= 4 ? int(fields[3]) * 1024 : -1;
    return required >= 0 && available >= required + LIST_DOWNLOAD_MIN_FREE_BYTES;
}

function commit_runtime_list_generation(signature) {
    signature = as_string(signature);
    runtime_generation_commit_changed = false;
    if (signature == "")
        return false;
    // The old active directory remains in place until the staged directory is
    // complete, so reserve space for the new generation before publication.
    if (!runtime_list_generation_has_capacity(persistent_list_cache_estimated_bytes())) {
        log_message("Not enough runtime storage to stage a complete list generation; keeping the active generation", "error");
        return false;
    }
    let stage = RUNTIME_LIST_GENERATION_DIR + ".stage";
    let previous = RUNTIME_LIST_GENERATION_DIR + ".previous";
    recover_list_generation_transaction(RUNTIME_LIST_GENERATION_DIR, signature);
    command_success_from_args([ "rm", "-rf", stage ]);
    if (generation_phase_failed("runtime-stage-create") || !ensure_dir(stage))
        return false;
    let files = [];
    for (let path in fs.glob(TMP_RULESET_FOLDER + "/*")) {
        let name = substr(path, length(TMP_RULESET_FOLDER) + 1);
        let target = stage + "/" + name;
        if (generation_phase_failed("runtime-file-write") || !managed_list_ruleset_name(name) || !valid_list_ruleset_file(path) || !cache_copy_file(path, target)) {
            command_success_from_args([ "rm", "-rf", stage ]);
            return false;
        }
        let stat = fs.stat(target);
        push(files, { name, kind: "ruleset", size: int(object_or_empty(stat).size || 0), md5: file_md5(target) });
    }
    for (let source in list_download_metadata) {
        source = object_or_empty(source);
        let name = as_string(source.name);
        let origin = as_string(list_download_cache[as_string(source.url)]);
        let target = stage + "/" + name;
        if (generation_phase_failed("runtime-file-write") || origin == "" || match(name, /^source-[0-9]+$/) == null || !cache_copy_file(origin, target)) {
            command_success_from_args([ "rm", "-rf", stage ]);
            return false;
        }
        let stat = fs.stat(target);
        push(files, { name, kind: "source", url: as_string(source.url), source_format: as_string(source.format), size: int(object_or_empty(stat).size || 0), md5: file_md5(target) });
    }
    let manifest = { format: PERSISTENT_LIST_CACHE_FORMAT, generation: generation_identity(signature), signature, files };
    if (generation_phase_failed("runtime-manifest-write") || !write_file(stage + "/manifest.json", json_text(manifest)) ||
        generation_phase_failed("runtime-validate")) {
        command_success_from_args([ "rm", "-rf", stage ]);
        return false;
    }
    let staged_validation = list_generation_validation(stage, signature);
    if (!staged_validation.valid) {
        command_success_from_args([ "rm", "-rf", stage ]);
        return false;
    }
    let active_validation = list_generation_validation(RUNTIME_LIST_GENERATION_DIR, signature);
    // Failure injection deliberately exercises every publication phase even
    // for equal data. It is test-only; normal runtime never sets this switch.
    let failure_injection_enabled = as_string(getenv("FORKOP_LIST_GENERATION_FAIL_PHASE")) != "";
    if (!failure_injection_enabled && active_validation.valid && list_generation_manifest_content_equal(staged_validation.manifest, active_validation.manifest)) {
        command_success_from_args([ "rm", "-rf", stage ]);
        log_message("Validated list generation is unchanged; runtime policy reload is not needed", "info");
        return true;
    }
    command_success_from_args([ "rm", "-rf", previous ]);
    if (generation_phase_failed("runtime-rename-previous") ||
        (file_exists_value(RUNTIME_LIST_GENERATION_DIR) && !fs.rename(RUNTIME_LIST_GENERATION_DIR, previous))) {
        command_success_from_args([ "rm", "-rf", stage ]);
        return false;
    }
    if (generation_phase_failed("runtime-rename-active"))
        return false;
    if (!fs.rename(stage, RUNTIME_LIST_GENERATION_DIR)) {
        if (file_exists_value(previous))
            fs.rename(previous, RUNTIME_LIST_GENERATION_DIR);
        command_success_from_args([ "rm", "-rf", stage ]);
        return false;
    }
    runtime_generation_commit_changed = true;
    if (!generation_phase_failed("runtime-cleanup-previous"))
        command_success_from_args([ "rm", "-rf", previous ]);
    return true;
}

function persist_list_cache(timestamp) {
    let signature = current_list_update_signature();
    recover_list_generation_transaction(RUNTIME_LIST_GENERATION_DIR, signature);
    recover_list_generation_transaction(PERSISTENT_LIST_CACHE_DIR, signature);
    let runtime = list_generation_validation(RUNTIME_LIST_GENERATION_DIR, signature);
    if (!runtime.valid)
        return false;

    let stage = PERSISTENT_LIST_CACHE_DIR + ".stage";
    let previous = PERSISTENT_LIST_CACHE_DIR + ".previous";
    command_success_from_args([ "rm", "-rf", stage ]);
    let estimated = runtime.total_bytes + PERSISTENT_LIST_CACHE_MANIFEST_ALLOWANCE;
    if (!list_cache_has_capacity(estimated, false))
        return false;
    if (generation_phase_failed("persistent-stage-create") || !ensure_dir(stage))
        return false;

    for (let entry in runtime.manifest.files) {
        entry = object_or_empty(entry);
        let name = as_string(entry.name);
        if (generation_phase_failed("persistent-file-write") || !cache_copy_file(RUNTIME_LIST_GENERATION_DIR + "/" + name, stage + "/" + name)) {
            command_success_from_args([ "rm", "-rf", stage ]);
            return false;
        }
    }
    if (generation_phase_failed("persistent-manifest-write") || !write_file(stage + "/manifest.json", json_text(runtime.manifest)) ||
        !write_file(stage + "/last-success.timestamp", as_string(timestamp) + "\n") ||
        generation_phase_failed("persistent-validate") || !list_generation_validation(stage, runtime.signature).valid) {
        command_success_from_args([ "rm", "-rf", stage ]);
        return false;
    }
    command_success_from_args([ "chmod", "0700", stage ]);
    for (let path in fs.glob(stage + "/*"))
        command_success_from_args([ "chmod", "0600", path ]);

    let staged_bytes = directory_allocated_bytes(stage);
    let staged_capacity_ok = staged_bytes >= 0 && list_cache_has_capacity(staged_bytes, true);
    if (!staged_capacity_ok) {
        log_message("Completed persistent list cache does not fit the flash safety limits; keeping the lists in runtime memory only", "warn");
        command_success_from_args([ "rm", "-rf", stage ]);
        return false;
    }

    if (generation_phase_failed("persistent-rename-previous") ||
        (file_exists_value(PERSISTENT_LIST_CACHE_DIR) && !fs.rename(PERSISTENT_LIST_CACHE_DIR, previous))) {
        command_success_from_args([ "rm", "-rf", stage ]);
        return false;
    }
    if (generation_phase_failed("persistent-rename-active"))
        return false;
    if (!fs.rename(stage, PERSISTENT_LIST_CACHE_DIR)) {
        if (file_exists_value(previous))
            fs.rename(previous, PERSISTENT_LIST_CACHE_DIR);
        command_success_from_args([ "rm", "-rf", stage ]);
        return false;
    }
    if (!generation_phase_failed("persistent-cleanup-previous"))
        command_success_from_args([ "rm", "-rf", previous ]);
    return true;
}

function list_update_last_success() {
    let persistent = int(trim(file_first_line_value(LIST_UPDATE_STATE_FILE)) || "0");
    let runtime = int(trim(file_first_line_value(LIST_UPDATE_RUNTIME_STATE_FILE)) || "0");
    return runtime > persistent ? runtime : persistent;
}

function copy_file(source, target) {
    let data = fs.readfile(as_string(source));
    if (data == null)
        return false;
    return write_file(target, data);
}

function temp_path() {
    return trim(command_output_from_args([ "mktemp" ]));
}

function remove_files(paths) {
    for (let path in paths)
        if (as_string(path) != "")
            remove_file(path);
}

function runtime_pid_running(pid) {
    pid = as_string(pid);
    return match(pid, /^[0-9]+$/) != null && command_success_from_args([ "kill", "-0", pid ]);
}

function module_command(args) {
    let command_args = [ "ucode", "-L", LIB_DIR ];
    for (let arg in args)
        push(command_args, arg);
    return command_from_args(command_args);
}

function module_status(args) {
    return command_status(module_command(args));
}

function module_capture(args) {
    return command_capture(module_command(args));
}

function module_success(args) {
    return module_status(args) == 0;
}

function module_output(args) {
    return command_output(module_command(args));
}

function module_background(args) {
    let command = module_command(args) + " >/dev/null 2>&1 1000>&- &";
    return command_success("sh -c " + shell_quote(command));
}

function current_proxy_outbounds_signature(config_path) {
    config_path = as_string(config_path);
    if (config_path == "")
        config_path = option(uci_settings(), "config_path", "");
    if (config_path == "")
        return "";
    return trim(module_output([ DIAGNOSTICS_UC, "proxy-outbounds-signature", config_path ]));
}

function automatic_latency_pending_marker() {
    let marker = read_json_file(AUTOMATIC_LATENCY_PENDING_FILE);
    return type(marker) == "object" ? marker : null;
}

function schedule_automatic_latency_test(signature) {
    signature = as_string(signature);
    if (signature == "")
        return false;

    let existing = automatic_latency_pending_marker();
    if (existing != null && as_string(existing.format) == AUTOMATIC_LATENCY_PENDING_FORMAT &&
        as_string(existing.signature) == signature) {
        log_message("Automatic latency test is already pending for the current proxy set; coalescing the request", "info");
        return true;
    }

    if (!ensure_parent_dir(AUTOMATIC_LATENCY_PENDING_FILE) || !write_state_file(AUTOMATIC_LATENCY_PENDING_FILE, {
        format: AUTOMATIC_LATENCY_PENDING_FORMAT,
        signature,
        generation: sprintf("%d-%d", clock()[0], clock()[1]),
        scheduled_at: now_seconds(),
        failures: 0,
        retry_after: 0
    }))
        return false;

    command_success_from_args([ "chmod", "0600", AUTOMATIC_LATENCY_PENDING_FILE ]);
    log_message("Automatic latency test scheduled because the final proxy set changed", "info");
    return true;
}

function validation_failure_message(result) {
    for (let line in split(as_string(result.output), "\n")) {
        line = trim(line);
        if (line != "")
            return line;
    }

    return "The configuration could not be validated. Aborted.";
}

function nft_module_success(args) {
    let command_args = [ LIB_DIR + "/nft/apply.uc" ];
    for (let arg in args)
        push(command_args, arg);
    if (list_nft_candidate_file != "")
        return command_success(command_env({ FORKOP_NFT_BATCH_FILE: list_nft_candidate_file }) + " " + module_command(command_args));
    return module_success(command_args);
}

function service_state_success(args) {
    let command_args = [ LIB_DIR + "/service/state.uc" ];
    for (let arg in args)
        push(command_args, arg);
    return module_success(command_args);
}

function acquire_runtime_lock(lock_dir, wait) {
    return service_state_success([
        wait ? "acquire-runtime-dir-lock-wait" : "acquire-runtime-dir-lock",
        lock_dir,
        owner_pid(),
        "300"
    ]);
}

function release_runtime_lock(lock_dir) {
    service_state_success([ "release-runtime-dir-lock", lock_dir ]);
}

function unsigned_number(value) {
    value = as_string(value);
    if (value == "" || match(value, /[^0-9]/) != null)
        return null;
    return int(value);
}

function update_due_status(now_value, last_run_value, interval_value, subscription) {
    let now = unsigned_number(now_value);
    let interval = unsigned_number(interval_value);

    if (now == null || interval == null || interval <= 0)
        return 2;

    let last_run = unsigned_number(last_run_value);
    if (last_run == null)
        last_run = 0;

    // Match subscription/cache.uc; other update families retain exact timing.
    let allowance = subscription && interval >= 3600 ? 60 : 0;
    if (last_run > 0 && (now < last_run || now - last_run < interval - allowance))
        return 1;

    return 0;
}

function duration_to_seconds_value(value) {
    let rest = as_string(value);
    if (rest == "")
        return null;

    let total = 0.0;
    let multipliers = {
        ns: 0.000000001,
        us: 0.000001,
        ms: 0.001,
        s: 1,
        m: 60,
        h: 3600,
        d: 86400
    };

    while (rest != "") {
        let matched = match(rest, /^([0-9]+(\.[0-9]+)?)(ns|us|ms|s|m|h|d)/);
        if (!matched)
            return null;

        let token = as_string(matched[0]);
        let amount = matched[1] * 1;
        let unit = matched[3];
        total = total + amount * multipliers[unit];
        rest = substr(rest, length(token));
    }

    if (total <= 0)
        return null;

    return int(total + 0.5);
}

function due_check_cron_schedule_text(value) {
    let seconds = arg_number(value);

    if (seconds <= 60)
        return "* * * * *";

    if (seconds % 86400 == 0)
        return "0 0 * * *";

    if (seconds % 3600 == 0) {
        let hours = seconds / 3600;
        if (hours >= 1 && hours <= 23)
            return hours == 1 ? "0 * * * *" : "0 */" + hours + " * * *";
    }

    if (seconds % 60 == 0) {
        let minutes = seconds / 60;
        if (minutes >= 1 && minutes <= 59)
            return minutes == 1 ? "* * * * *" : "*/" + minutes + " * * * *";
    }

    return "* * * * *";
}

function list_has_remote_references(value) {
    for (let item in split(as_string(value), /[ \t\r\n]+/)) {
        if (match(item, /^https?:\/\//) != null)
            return true;
    }

    return false;
}

function rule_has_list_update_source(section) {
    section = object_or_empty(section);
    if (rule_config == null)
        rule_config = require("config.rule");

    if (!bool_option(section, "enabled", true))
        return false;
    if (option(section, "action", "") == "dns")
        return list_has_remote_references(option(section, "domain_ip_lists", ""));

    return (
        rule_config.has_community_subnet_list(connections.community_lists_value(section)) ||
        option(section, "remote_domain_lists", "") != "" ||
        option(section, "remote_subnet_lists", "") != "" ||
        length(connections.rule_sets_with_subnets(section)) > 0 ||
        list_has_remote_references(option(section, "domain_ip_lists", ""))
    );
}

function has_list_update_sources(sections) {
    for (let section in sections)
        if (rule_has_list_update_source(section))
            return true;
    return false;
}

function settings_update_interval(settings) {
    settings = object_or_empty(settings);

    if (!bool_option(settings, "list_update_enabled", true))
        return "";

    let value = option(settings, "update_interval", "1d");
    return value != "" ? value : "1d";
}

function settings_component_update_check_interval(settings) {
    settings = object_or_empty(settings);

    if (!bool_option(settings, "component_update_check_enabled", false))
        return "";

    let value = option(settings, "component_update_check_interval", "1d");
    return value != "" ? value : "1d";
}

function section_subscription_update_interval(section) {
    let result = "";
    let result_seconds = 0;

    for (let entry in connections.subscription_urls(section)) {
        if (!connections.subscription_update_enabled(section, entry))
            continue;

        let value = connections.subscription_update_interval(section, entry);
        if (value == "")
            value = "4h";
        let seconds = duration_to_seconds_value(value);
        if (result == "" || (seconds != null && (result_seconds == 0 || seconds < result_seconds))) {
            result = value;
            result_seconds = seconds == null ? 0 : seconds;
        }
    }

    return result;
}

function section_is_subscription_proxy(section) {
    return bool_option(section, "enabled", true) &&
        connections.is_connections_action(option(section, "action", "")) &&
        length(connections.subscription_urls(section)) > 0;
}

function line_contains_any_marker(line, markers) {
    line = as_string(line);
    for (let marker in markers) {
        marker = as_string(marker);
        if (marker != "" && index(line, marker) >= 0)
            return true;
    }

    return false;
}

function filter_cron_markers_text(data, markers) {
    data = as_string(data);
    if (data == "")
        return "";

    let lines = split(data, "\n");
    let has_trailing_newline = substr(data, length(data) - 1) == "\n";
    let result = "";

    for (let i = 0; i < length(lines); i++) {
        let line = as_string(lines[i]);
        if (i == length(lines) - 1 && has_trailing_newline && line == "")
            continue;
        if (line_contains_any_marker(line, markers))
            continue;
        result += line + "\n";
    }

    return result;
}

function cron_refresh_plan_rows(settings, sections, bin, list_marker, subscription_marker, component_marker) {
    let status = 0;
    let rows = [];

    if (has_list_update_sources(sections)) {
        let interval = settings_update_interval(settings);
        if (interval == "") {
            push(rows, "list-disabled");
        }
        else {
            let seconds = duration_to_seconds_value(interval);
            if (seconds == null) {
                push(rows, "list-error\t" + as_string(interval));
                status = 1;
            }
            else {
                push(rows, "list\t" + due_check_cron_schedule_text(seconds) + " " + as_string(bin) + " list_update_if_due " + as_string(list_marker));
            }
        }
    }

    let min_interval = 0;
    let subscription_source_count = 0;
    for (let section in sections) {
        section = object_or_empty(section);
        if (!section_is_subscription_proxy(section))
            continue;

        let interval = section_subscription_update_interval(section);
        if (interval == "")
            continue;

        subscription_source_count++;
        let seconds = duration_to_seconds_value(interval);
        if (seconds == null) {
            push(rows, "subscription-error\t" + section_name(section) + "\t" + as_string(interval));
            continue;
        }

        if (min_interval == 0 || seconds < min_interval)
            min_interval = seconds;
    }

    if (subscription_source_count > 0) {
        if (min_interval <= 0)
            status = 1;
        else
            push(rows, "subscription\t" + due_check_cron_schedule_text(min_interval) + " " + as_string(bin) + " subscription_update_if_due " + as_string(subscription_marker));
    }

    let component_interval = settings_component_update_check_interval(settings);
    if (component_interval != "") {
        let component_seconds = duration_to_seconds_value(component_interval);
        if (component_seconds == null) {
            push(rows, "component-error\t" + as_string(component_interval));
            status = 1;
        }
        else {
            push(rows, "component\t" + due_check_cron_schedule_text(component_seconds) + " " + as_string(bin) + " component_updates_if_due " + as_string(component_marker));
        }
    }

    return {
        status,
        rows
    };
}

function cron_refresh_apply_result(settings, sections, existing_crontab, bin, list_marker, subscription_marker, component_marker) {
    let plan = cron_refresh_plan_rows(settings, sections, bin, list_marker, subscription_marker, component_marker);
    let filtered_crontab = filter_cron_markers_text(existing_crontab, [ list_marker, subscription_marker, component_marker ]);
    let cron_jobs = "";
    let logs = [ { level: "info", message: "The cron job removed" } ];
    let tab = "\t";

    for (let row in plan.rows) {
        let line = as_string(row);
        let separator = index(line, tab);
        let type = separator >= 0 ? substr(line, 0, separator) : line;
        let rest = separator >= 0 ? substr(line, separator + 1) : "";

        if (type == "list") {
            cron_jobs += rest + "\n";
            push(logs, { level: "info", message: "The cron job has been created: " + rest });
        }
        else if (type == "list-disabled") {
            push(logs, { level: "info", message: "Remote list auto-update is disabled" });
        }
        else if (type == "list-error") {
            push(logs, { level: "error", message: "Invalid update_interval value: " + rest });
        }
        else if (type == "subscription") {
            cron_jobs += rest + "\n";
            push(logs, { level: "info", message: "The subscription cron job has been created: " + rest });
        }
        else if (type == "subscription-error") {
            let section_separator = index(rest, tab);
            let section = section_separator >= 0 ? substr(rest, 0, section_separator) : rest;
            let interval = section_separator >= 0 ? substr(rest, section_separator + 1) : "";
            push(logs, { level: "error", message: "Invalid subscription_update_interval value for rule '" + section + "': " + interval });
        }
        else if (type == "component") {
            cron_jobs += rest + "\n";
            push(logs, { level: "info", message: "The component update check cron job has been created: " + rest });
        }
        else if (type == "component-error") {
            push(logs, { level: "error", message: "Invalid component_update_check_interval value: " + rest });
        }
    }

    return {
        status: int(plan.status || 0),
        crontab: filtered_crontab + (int(plan.status || 0) == 0 ? cron_jobs : ""),
        logs
    };
}

function write_crontab_text(text) {
    let tmp = trim(command_output_from_args([ "mktemp" ]));
    if (tmp == "")
        return false;

    if (fs.writefile(tmp, as_string(text)) == null) {
        fs.unlink(tmp);
        return false;
    }

    let ok = command_success_from_args([ "crontab", tmp ]);
    fs.unlink(tmp);
    return ok;
}

function log_cron_apply_result(result) {
    for (let item in array_or_empty(object_or_empty(result).logs))
        log_message(item.message, item.level);
}

function remove_cron_jobs(list_marker, subscription_marker, component_marker) {
    // Read BusyBox's backing file directly. `crontab -l` may fail and return
    // an empty string; writing that result back would erase unrelated jobs.
    let crontab = as_string(fs.readfile(CRONTAB_FILE) || "");
    let result = {
        crontab: filter_cron_markers_text(crontab, [ list_marker, subscription_marker, component_marker ]),
        logs: [ { level: "info", message: "The cron job removed" } ]
    };

    if (!write_crontab_text(result.crontab))
        exit(1);

    log_cron_apply_result(result);
}

function refresh_cron_from_sources(settings, sections, bin, list_marker, subscription_marker, component_marker) {
    let existing = as_string(fs.readfile(CRONTAB_FILE) || "");
    let result = cron_refresh_apply_result(
        settings,
        sections,
        existing,
        bin,
        list_marker,
        subscription_marker,
        component_marker
    );

    if (result.status == 0 && result.crontab == existing)
        exit(0);
    if (!write_crontab_text(result.crontab))
        exit(1);

    log_cron_apply_result(result);
    exit(result.status);
}

function list_update_due_status(settings, timestamp_path, now) {
    let interval = settings_update_interval(settings);
    if (interval == "")
        exit(1);

    let seconds = duration_to_seconds_value(interval);
    if (seconds == null) {
        print("error\t", interval, "\n");
        exit(2);
    }

    exit(update_due_status(now, file_first_line_value(timestamp_path), seconds));
}

function subscription_update_section_due_status(section, timestamp_path, now) {
    section = object_or_empty(section);
    let interval = section_subscription_update_interval(section);
    if (interval == "")
        exit(1);

    let seconds = duration_to_seconds_value(interval);
    if (seconds == null) {
        print("error\t", interval, "\n");
        exit(2);
    }

    exit(update_due_status(now, file_first_line_value(timestamp_path), seconds, true));
}

function stdin_first_ipv4_line() {
    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (match(line, /^[0-9]+\./) != null) {
            print(line, "\n");
            return;
        }
    }
}

function json_length(path) {
    let value = read_json_file(path);
    if (type(value) == "array" || type(value) == "object")
        print(length(value), "\n");
    else
        print("0\n");
}

function subscription_job_json_response(success, job_id, message) {
    write_json({
        success: arg_bool(success),
        job_id: as_string(job_id),
        message: as_string(message)
    });
}

function subscription_running_job_state_value(section, source_index, started_at) {
    return {
        success: true,
        running: true,
        kind: "subscription",
        message: "Subscription update is running",
        section: as_string(section),
        source_index: as_string(source_index),
        pid: null,
        started_at: arg_number(started_at),
        updated_at: null,
        exit_code: null
    };
}

function job_started_at_within_grace(value, now, grace_seconds) {
    let started_at = arg_number(value);
    now = arg_number(now);
    grace_seconds = arg_number(grace_seconds);

    if (started_at <= 0 || now <= 0)
        return false;

    return now - started_at < grace_seconds;
}

function job_pid_valid(pid) {
    pid = as_string(pid);
    return pid != "" && match(pid, /^[0-9]+$/) != null;
}

function set_subscription_running_job_pid(path, pid) {
    pid = as_string(pid);
    if (!job_pid_valid(pid))
        return false;

    let value = object_or_empty(read_json_file(path));
    if (value.running === true) {
        value.pid = pid;
        return write_state_file(path, value);
    }

    return false;
}

function subscription_finished_job_state_value(success, message, exit_code, updated_at, section, source_index, started_at) {
    return {
        success: arg_bool(success),
        running: false,
        kind: "subscription",
        message: as_string(message),
        section: as_string(section),
        source_index: as_string(source_index),
        pid: null,
        started_at: arg_number(started_at),
        exit_code: arg_number(exit_code),
        updated_at: arg_number(updated_at)
    };
}

function subscription_stale_job_state_value(updated_at, section, source_index, started_at) {
    return {
        success: false,
        running: false,
        kind: "subscription",
        message: "Subscription update worker exited unexpectedly",
        section: as_string(section),
        source_index: as_string(source_index),
        pid: null,
        started_at: arg_number(started_at),
        exit_code: null,
        updated_at: arg_number(updated_at)
    };
}

function subscription_status_error(message) {
    write_json({
        success: false,
        running: false,
        message: as_string(message),
        exit_code: null
    });
}

function subscription_status_error_exit(message) {
    subscription_status_error(message);
    exit(1);
}

function valid_subscription_job_id(job_id) {
    job_id = as_string(job_id);
    return job_id != "" && job_id != "." && job_id != ".." && match(job_id, /[^A-Za-z0-9._-]/) == null;
}

function subscription_job_state_path_value(job_dir, job_id) {
    if (!valid_subscription_job_id(job_id))
        return "";
    return as_string(job_dir) + "/" + as_string(job_id) + ".json";
}

function subscription_job_id() {
    let stamp = clock();
    return sprintf("%d-%d", stamp[0], stamp[1]);
}

function ensure_subscription_runtime_dirs() {
    let command = command_env({
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
        FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT: PERSISTENT_SUBSCRIPTION_CACHE_FORMAT
    }) + " " + command_from_args([
        "ucode",
        "-L", LIB_DIR,
        LIB_DIR + "/subscription/cache.uc",
        "ensure-runtime-dirs"
    ]);

    return command_success(command) && ensure_dir(SUBSCRIPTION_JOB_DIR);
}

function subscription_job_output_path(job_id) {
    return SUBSCRIPTION_JOB_DIR + "/" + as_string(job_id) + ".out";
}

function subscription_job_output_path_from_state(path) {
    path = as_string(path);
    if (length(path) >= 5 && substr(path, length(path) - 5) == ".json")
        return substr(path, 0, length(path) - 5) + ".out";
    return path + ".out";
}

function remove_subscription_job_state(path) {
    remove_file(path);
    remove_file(subscription_job_output_path_from_state(path));
}

function subscription_job_running_is(path, expected) {
    let value = read_json_file(path);
    let running = type(value) == "object" && value.running === true;
    return running == arg_bool(expected);
}

function subscription_cleanup_jobs() {
    ensure_dir(SUBSCRIPTION_JOB_DIR);

    command_success_from_args([
        "find",
        SUBSCRIPTION_JOB_DIR,
        "-type", "f",
        "-name", "*.out",
        "-mmin", "+" + as_string(SUBSCRIPTION_JOB_ORPHAN_OUTPUT_TTL_MINUTES),
        "-delete"
    ]);

    let old = command_output_from_args([
        "find",
        SUBSCRIPTION_JOB_DIR,
        "-type", "f",
        "-name", "*.json",
        "-mmin", "+" + as_string(SUBSCRIPTION_JOB_FINISHED_TTL_MINUTES)
    ]);

    for (let path in split(old, "\n")) {
        path = trim(as_string(path));
        if (path != "" && subscription_job_running_is(path, false))
            remove_subscription_job_state(path);
    }
}

function pid_running(pid) {
    pid = as_string(pid);
    return job_pid_valid(pid) && command_success_from_args([ "kill", "-0", pid ]);
}

function write_subscription_stale_job_state(path) {
    let value = object_or_empty(read_json_file(path));
    return write_state_file(path, subscription_stale_job_state_value(
        now_seconds(),
        value.section || "",
        value.source_index || "",
        value.started_at || 0
    ));
}

function refresh_subscription_running_job_state(path) {
    let value = read_json_file(path);
    if (type(value) != "object" || value.running !== true)
        return;

    let now = now_seconds();
    let within_grace = job_started_at_within_grace(value.started_at, now, SUBSCRIPTION_JOB_STALE_GRACE_SECONDS);
    let pid = as_string(value.pid || "");

    if (!job_pid_valid(pid)) {
        if (!within_grace)
            write_subscription_stale_job_state(path);
        return;
    }

    if (pid_running(pid))
        return;
    if (within_grace)
        return;

    command_success_from_args([ "sleep", "1" ]);
    value = read_json_file(path);
    if (type(value) != "object" || value.running !== true)
        return;
    if (pid_running(pid))
        return;

    write_subscription_stale_job_state(path);
}

function finish_subscription_job(path, exit_code, output_file) {
    let value = object_or_empty(read_json_file(path));
    let success = arg_number(exit_code) == 0;
    let message = file_last_nonblank_line_value(
        output_file,
        success ? "Subscription update completed" : "Subscription update failed",
        240
    );

    let ok = write_state_file(path, subscription_finished_job_state_value(
        success,
        message,
        exit_code,
        now_seconds(),
        value.section || "",
        value.source_index || "",
        value.started_at || 0
    ));
    remove_file(output_file);
    return ok;
}

function subscription_worker_env() {
    return {
        FORKOP_CONFIG_NAME: CONFIG_NAME,
        FORKOP_LIB: LIB_DIR,
        FORKOP_BIN: BIN_PATH,
        TMP_SING_BOX_FOLDER,
        TMP_RULESET_FOLDER,
        TMP_SUBSCRIPTION_FOLDER,
        FORKOP_RUNTIME_STATE_DIR: RUNTIME_STATE_DIR,
        FORKOP_SUBSCRIPTION_UPDATE_STATE_DIR: SUBSCRIPTION_UPDATE_STATE_DIR,
        FORKOP_SUBSCRIPTION_UPDATE_JOB_DIR: SUBSCRIPTION_JOB_DIR,
        FORKOP_SUBSCRIPTION_LINKS_DIR: SUBSCRIPTION_LINKS_DIR,
        FORKOP_SUBSCRIPTION_METADATA_DIR: SUBSCRIPTION_METADATA_DIR,
        FORKOP_OUTBOUND_METADATA_DIR: OUTBOUND_METADATA_DIR,
        FORKOP_SECTION_CACHE_DIR: SECTION_CACHE_DIR,
        FORKOP_RUNTIME_CACHE_FORMAT_FILE: RUNTIME_CACHE_FORMAT_FILE,
        FORKOP_RUNTIME_CACHE_FORMAT: RUNTIME_CACHE_FORMAT,
        FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR: PERSISTENT_SUBSCRIPTION_CACHE_DIR,
        FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE: PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE,
        FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT: PERSISTENT_SUBSCRIPTION_CACHE_FORMAT,
        FORKOP_SUBSCRIPTION_UPDATE_JOB_FINISHED_TTL_MINUTES: SUBSCRIPTION_JOB_FINISHED_TTL_MINUTES,
        FORKOP_SUBSCRIPTION_UPDATE_JOB_ORPHAN_OUTPUT_TTL_MINUTES: SUBSCRIPTION_JOB_ORPHAN_OUTPUT_TTL_MINUTES,
        FORKOP_UI_ACTION_STALE_GRACE_SECONDS: SUBSCRIPTION_JOB_STALE_GRACE_SECONDS
    };
}

function launch_subscription_worker(args) {
    let command_args = [ "ucode", "-L", LIB_DIR, LIB_DIR + "/components/updates.uc" ];
    for (let arg in args)
        push(command_args, arg);

    let command = command_env(subscription_worker_env()) + " " +
        command_from_args(command_args) +
        " >/dev/null 2>&1 1000>&- & echo $!";
    return trim(command_output("sh -c " + shell_quote(command)));
}

function subscription_update_worker(state_file, output_file, section, source_index) {
    let status = command_status(command_from_args([
        BIN_PATH,
        "subscription_update",
        as_string(section),
        as_string(source_index)
    ]) + " >" + shell_quote(output_file) + " 2>&1");

    finish_subscription_job(state_file, status, output_file);
}

function subscription_update_async(section, source_index) {
    if (!ensure_subscription_runtime_dirs()) {
        subscription_job_json_response(false, "", "Failed to create subscription update state directory");
        exit(1);
    }

    subscription_cleanup_jobs();

    let job_id = subscription_job_id();
    let state_file = subscription_job_state_path_value(SUBSCRIPTION_JOB_DIR, job_id);
    if (state_file == "") {
        subscription_job_json_response(false, "", "Failed to prepare subscription update job");
        exit(1);
    }

    if (!write_state_file(state_file, subscription_running_job_state_value(section, source_index, now_seconds()))) {
        subscription_job_json_response(false, "", "Failed to write subscription update state");
        exit(1);
    }

    let output_file = subscription_job_output_path(job_id);
    let pid = launch_subscription_worker([
        "subscription-update-worker",
        state_file,
        output_file,
        as_string(section),
        as_string(source_index)
    ]);

    if (pid == "" || !set_subscription_running_job_pid(state_file, pid)) {
        if (pid != "")
            command_success_from_args([ "kill", pid ]);
        subscription_job_json_response(false, "", "Failed to write subscription update worker pid");
        exit(1);
    }

    subscription_job_json_response(true, job_id, "Subscription update started");
}

function subscription_update_status(job_id) {
    ensure_dir(SUBSCRIPTION_JOB_DIR);
    subscription_cleanup_jobs();

    let state_file = subscription_job_state_path_value(SUBSCRIPTION_JOB_DIR, job_id);
    if (state_file == "")
        subscription_status_error_exit("Invalid subscription update job id");

    if (fs.stat(state_file) == null)
        subscription_status_error_exit("Subscription update job was not found");

    refresh_subscription_running_job_state(state_file);
    print(as_string(fs.readfile(state_file)));
}

function component_job_json_response(success, job_id, message) {
    write_json({
        success: arg_bool(success),
        job_id: as_string(job_id),
        message: as_string(message)
    });
}

function component_action_status_error(message) {
    write_json({
        success: false,
        running: false,
        kind: "component",
        component: "unknown",
        action: "status",
        message: as_string(message),
        current_version: "",
        latest_version: "",
        changed: 0,
        status: "",
        exit_code: null
    });
}

function component_action_status_error_exit(message) {
    component_action_status_error(message);
    exit(1);
}

function component_running_job_state_value(component, action, started_at) {
    return {
        success: true,
        running: true,
        kind: "component",
        component: as_string(component),
        action: as_string(action),
        message: "Component action is running",
        pid: null,
        started_at: arg_number(started_at),
        updated_at: null,
        current_version: "",
        latest_version: "",
        changed: 0,
        status: "",
        exit_code: null
    };
}

function normalize_component_name(component) {
    component = as_string(component);
    if (component == "sing-box" || component == "singbox")
        return "sing_box";
    if (component == "forkop")
        return "forkop";
    return component;
}

function valid_component_name(component) {
    component = normalize_component_name(component);
    return component == "forkop" || component == "sing_box" || component == "zapret_manager" ||
        component == "packet_steering" || component == "direct_proxy" || component == "torrserver_direct";
}

function component_update_check_cache_path(component) {
    component = normalize_component_name(component);
    if (!valid_component_name(component))
        return "";
    return COMPONENT_UPDATE_CHECK_CACHE_DIR + "/" + component + ".json";
}

function component_update_check_cache_enabled() {
    return settings_component_update_check_interval(uci_settings()) != "";
}

function component_update_check_result_cacheable(value) {
    value = object_or_empty(value);
    let status = as_string(value.status || "");
    return value.success === true && as_string(value.action) == "check_update" &&
        valid_component_name(value.component) &&
        (status == "latest" || status == "outdated" || status == "dev");
}

function cache_component_update_check_result(value, notify_update) {
    value = object_or_empty(value);
    if (!component_update_check_result_cacheable(value))
        return false;

    let component = normalize_component_name(value.component);
    let path = component_update_check_cache_path(component);
    if (path == "" || !ensure_dir(COMPONENT_UPDATE_CHECK_CACHE_DIR))
        return false;

    let previous = object_or_empty(read_json_file(path));
    let cached = {
        success: true,
        component,
        action: "check_update",
        message: as_string(value.message),
        current_version: as_string(value.current_version),
        latest_version: as_string(value.latest_version),
        release_url: as_string(value.release_url),
        changed: 0,
        status: as_string(value.status),
        updated_at: now_seconds()
    };
    if (!write_state_file(path, cached))
        return false;

    if (arg_bool(notify_update) && cached.status == "outdated" &&
        (as_string(previous.status) != "outdated" ||
            as_string(previous.latest_version) != cached.latest_version)) {
        let notification_component = component;
        if (component == "sing_box" && trim(fs.readfile(SB_VARIANT_STATE_FILE) || "") == "rust-x") notification_component = "rust_x";
        log_message("[component-update] " + notification_component + " " + cached.latest_version, "info");
    }

    return true;
}

function update_component_check_cache_from_action(value) {
    value = object_or_empty(value);
    let component = normalize_component_name(value.component);
    let action = as_string(value.action);
    let path = component_update_check_cache_path(component);
    if (path == "")
        return;

    if (action == "remove" && value.success === true) {
        remove_file(path);
        return;
    }

    if (!component_update_check_cache_enabled())
        return;

    if (action == "check_update") {
        cache_component_update_check_result(value, false);
        return;
    }

    if (value.success === true && (action == "install" || match(action, /^install_/) != null)) {
        let latest_version = as_string(value.latest_version);
        if (latest_version == "")
            latest_version = as_string(value.current_version);
        cache_component_update_check_result({
            success: true,
            component,
            action: "check_update",
            message: "Latest version is installed",
            current_version: as_string(value.current_version),
            latest_version,
            release_url: as_string(value.release_url),
            status: "latest"
        }, false);
    }
}

function clear_component_update_check_cache() {
    for (let path in fs.glob(COMPONENT_UPDATE_CHECK_CACHE_DIR + "/*.json"))
        remove_file(path);
    remove_file(COMPONENT_UPDATE_CHECK_STATE_FILE);
}

function component_update_check_cache() {
    let enabled = component_update_check_cache_enabled();
    let results = [];

    if (enabled) {
        for (let component in [ "forkop", "sing_box" ]) {
            let value = read_json_file(component_update_check_cache_path(component));
            if (component_update_check_result_cacheable(value))
                push(results, value);
        }
    }

    write_json({ enabled, results });
}

function valid_component_job_id(job_id) {
    job_id = as_string(job_id);
    return job_id != "" && job_id != "." && job_id != ".." && match(job_id, /[^A-Za-z0-9._-]/) == null;
}

function component_job_state_path_value(job_id) {
    if (!valid_component_job_id(job_id))
        return "";
    return COMPONENT_JOB_DIR + "/" + as_string(job_id) + ".json";
}

function component_job_id() {
    let stamp = clock();
    return sprintf("%d-%d", stamp[0], stamp[1]);
}

function component_job_output_path(job_id) {
    return COMPONENT_JOB_DIR + "/" + as_string(job_id) + ".out";
}

function component_job_output_path_from_state(path) {
    path = as_string(path);
    if (length(path) >= 5 && substr(path, length(path) - 5) == ".json")
        return substr(path, 0, length(path) - 5) + ".out";
    return path + ".out";
}

function remove_component_job_state(path) {
    let output_path = component_job_output_path_from_state(path);
    remove_file(path);
    remove_file(output_path);
    remove_file(output_path + ".json");
}

function component_job_running_is(path, expected) {
    let value = read_json_file(path);
    let running = type(value) == "object" && value.running === true;
    return running == arg_bool(expected);
}

function ensure_component_runtime_dirs() {
    return ensure_dir(COMPONENT_JOB_DIR);
}

function write_component_stale_job_state(path) {
    let value = object_or_empty(read_json_file(path));
    value.success = false;
    value.running = false;
    value.kind = "component";
    value.message = "Component action job is stale or the worker process exited unexpectedly";
    value.changed = 0;
    value.status = "";
    value.exit_code = null;
    value.updated_at = now_seconds();
    return write_state_file(path, value);
}

function refresh_component_running_job_state(path) {
    let value = read_json_file(path);
    if (type(value) != "object" || value.running !== true)
        return;

    let now = now_seconds();
    let within_grace = job_started_at_within_grace(value.started_at, now, COMPONENT_JOB_STALE_GRACE_SECONDS);
    let pid = as_string(value.pid || "");

    if (!job_pid_valid(pid)) {
        if (!within_grace)
            write_component_stale_job_state(path);
        return;
    }

    if (pid_running(pid) || within_grace)
        return;

    command_success_from_args([ "sleep", "1" ]);
    value = read_json_file(path);
    if (type(value) != "object" || value.running !== true)
        return;
    if (pid_running(pid))
        return;

    write_component_stale_job_state(path);
}

function path_basename_without_suffix(path, suffix) {
    let parts = split(as_string(path), "/");
    let name = length(parts) > 0 ? as_string(parts[length(parts) - 1]) : "";
    suffix = as_string(suffix);
    if (length(name) >= length(suffix) && substr(name, length(name) - length(suffix)) == suffix)
        return substr(name, 0, length(name) - length(suffix));
    return name;
}

function component_cleanup_jobs() {
    ensure_dir(COMPONENT_JOB_DIR);

    for (let path in fs.glob(COMPONENT_JOB_DIR + "/*.json"))
        refresh_component_running_job_state(path);

    for (let output_path in fs.glob(COMPONENT_JOB_DIR + "/*.out")) {
        let state_file = component_job_state_path_value(path_basename_without_suffix(output_path, ".out"));
        if (state_file == "" || fs.stat(state_file) == null || !component_job_running_is(state_file, true)) {
            remove_file(output_path);
            remove_file(output_path + ".json");
        }
    }

    command_success_from_args([
        "find",
        COMPONENT_JOB_DIR,
        "-type", "f",
        "-name", "*.out",
        "-mmin", "+" + as_string(COMPONENT_JOB_ORPHAN_OUTPUT_TTL_MINUTES),
        "-delete"
    ]);
    command_success_from_args([
        "find",
        COMPONENT_JOB_DIR,
        "-type", "f",
        "-name", "*.out.json",
        "-mmin", "+" + as_string(COMPONENT_JOB_ORPHAN_OUTPUT_TTL_MINUTES),
        "-delete"
    ]);
    command_success_from_args([
        "find",
        COMPONENT_JOB_DIR,
        "-type", "f",
        "-name", "*.json.*",
        "-mmin", "+10",
        "-delete"
    ]);

    let old = command_output_from_args([
        "find",
        COMPONENT_JOB_DIR,
        "-type", "f",
        "-name", "*.json",
        "-mmin", "+" + as_string(COMPONENT_JOB_FINISHED_TTL_MINUTES)
    ]);

    for (let path in split(old, "\n")) {
        path = trim(as_string(path));
        if (path != "" && component_job_running_is(path, false))
            remove_component_job_state(path);
    }
}

function set_component_running_job_pid(path, pid) {
    pid = as_string(pid);
    if (!job_pid_valid(pid))
        return false;

    let value = object_or_empty(read_json_file(path));
    if (value.running === true) {
        value.pid = pid;
        return write_state_file(path, value);
    }

    return false;
}

function output_json_object(path) {
    let data = as_string(fs.readfile(path) || "");

    try {
        let value = json(data);
        if (type(value) == "object")
            return value;
    }
    catch (e) {
    }

    let result = null;
    for (let line in split(data, "\n")) {
        line = trim(as_string(line));
        let start = index(line, "{");
        if (start < 0)
            continue;
        try {
            let value = json(substr(line, start));
            if (type(value) == "object")
                result = value;
        }
        catch (e) {
        }
    }

    return result;
}

function component_fallback_job_state(component, action, message, exit_code, updated_at) {
    return {
        success: false,
        running: false,
        kind: "component",
        component: as_string(component),
        action: as_string(action),
        message: as_string(message),
        current_version: "",
        latest_version: "",
        changed: 0,
        status: "",
        exit_code: arg_number(exit_code),
        updated_at: arg_number(updated_at)
    };
}

function finish_component_job(path, component, action, exit_code, output_file) {
    let updated_at = now_seconds();
    let value = output_json_object(output_file);
    let ok;

    if (type(value) == "object") {
        value.running = false;
        value.kind = "component";
        value.exit_code = arg_number(exit_code);
        value.updated_at = updated_at;
        update_component_check_cache_from_action(value);
        ok = write_state_file(path, value);
    }
    else {
        let raw_output = file_last_nonblank_line_value(output_file, "Failed to execute", 240);
        ok = write_state_file(path, component_fallback_job_state(component, action, raw_output, exit_code, updated_at));
    }

    remove_file(output_file);
    remove_file(output_file + ".json");
    return ok;
}

function component_worker_env() {
    return {
        FORKOP_CONFIG_NAME: CONFIG_NAME,
        FORKOP_LIB: LIB_DIR,
        FORKOP_BIN: BIN_PATH,
        FORKOP_SERVICE_INIT: SERVICE_INIT,
        UPDATES_JOB_DIR: COMPONENT_JOB_DIR,
        UPDATES_JOB_FINISHED_TTL_MINUTES: COMPONENT_JOB_FINISHED_TTL_MINUTES,
        UPDATES_JOB_ORPHAN_OUTPUT_TTL_MINUTES: COMPONENT_JOB_ORPHAN_OUTPUT_TTL_MINUTES,
        UPDATES_JOB_STALE_GRACE_SECONDS: COMPONENT_JOB_STALE_GRACE_SECONDS,
        FORKOP_UI_COMPONENT_ACTION_TRACKED: "1"
    };
}

function launch_component_worker(args) {
    let command_args = [ "ucode", "-L", LIB_DIR, LIB_DIR + "/components/updates.uc" ];
    for (let arg in args)
        push(command_args, arg);

    let command = command_env(component_worker_env()) + " " +
        command_from_args(command_args) +
        " >/dev/null 2>&1 1000>&- & echo $!";
    return trim(command_output("sh -c " + shell_quote(command)));
}

function component_action_worker(state_file, output_file, component, action, version) {
    component = normalize_component_name(component);
    let command = command_env(component_worker_env()) + " " +
        command_from_args([
            "ucode",
            "-L", LIB_DIR,
            LIB_DIR + "/components/action.uc",
            "component-action",
            as_string(component),
            as_string(action),
            as_string(version)
        ]) + " >" + shell_quote(output_file) + " 2>&1";
    let status = command_status(command);

    finish_component_job(state_file, component, action, status, output_file);
}

function component_action_async(component, action, version) {
    version = as_string(version);
    // An exact version can be chosen for Forkop and for Xrust.
    let forkop_version = component == "forkop" && action == "install" &&
        match(version, /^[0-9]+[.][0-9]+[.][0-9]+(-canary[.][0-9]+)?$/) != null;
    let rust_x_version = component == "sing_box" && action == "install_rust_x" &&
        match(version, /^[0-9]+[.][0-9]+[.][0-9]+$/) != null;
    if (version != "" && !forkop_version && !rust_x_version) {
        component_job_json_response(false, "", "Invalid release selection");
        exit(1);
    }
    component = normalize_component_name(component);
    if (!ensure_component_runtime_dirs()) {
        component_job_json_response(false, "", "Failed to create component action state directory");
        exit(1);
    }

    component_cleanup_jobs();

    let job_id = component_job_id();
    let state_file = component_job_state_path_value(job_id);
    if (state_file == "") {
        component_job_json_response(false, "", "Failed to prepare component action job");
        exit(1);
    }

    if (!write_state_file(state_file, component_running_job_state_value(component, action, now_seconds()))) {
        component_job_json_response(false, "", "Failed to write component action state");
        exit(1);
    }

    let output_file = component_job_output_path(job_id);
    let pid = launch_component_worker([
        "component-action-worker",
        state_file,
        output_file,
        as_string(component),
        as_string(action),
        version
    ]);

    if (pid == "" || !set_component_running_job_pid(state_file, pid)) {
        if (pid != "")
            command_success_from_args([ "kill", pid ]);
        component_job_json_response(false, "", "Failed to write component action worker pid");
        exit(1);
    }

    component_job_json_response(true, job_id, "Component action started");
}

function component_action_status(job_id) {
    ensure_dir(COMPONENT_JOB_DIR);
    component_cleanup_jobs();

    let state_file = component_job_state_path_value(job_id);
    if (state_file == "")
        component_action_status_error_exit("Invalid component action job id");

    if (fs.stat(state_file) == null)
        component_action_status_error_exit("Component action job was not found");

    refresh_component_running_job_state(state_file);
    print(as_string(fs.readfile(state_file)));
}

function automatic_component_check_names() {
    let result = [ "forkop" ];

    if (fs.stat("/usr/bin/sing-box") != null)
        push(result, "sing_box");

    return result;
}

function run_automatic_component_update_check(component) {
    let output_file = temp_path();
    if (output_file == "")
        return false;

    let command = command_env(component_worker_env()) + " " +
        command_from_args([
            "ucode",
            "-L", LIB_DIR,
            LIB_DIR + "/components/action.uc",
            "component-action",
            as_string(component),
            "check_update"
        ]) + " >" + shell_quote(output_file) + " 2>&1";
    let status = command_status(command);
    let value = output_json_object(output_file);
    remove_file(output_file);

    if (status != 0 || !component_update_check_result_cacheable(value))
        return false;

    return cache_component_update_check_result(value, true);
}

function component_updates_if_due() {
    let interval = settings_component_update_check_interval(uci_settings());
    if (interval == "")
        exit(0);

    let seconds = duration_to_seconds_value(interval);
    if (seconds == null) {
        log_message("Invalid component_update_check_interval value: " + interval, "error");
        exit(1);
    }

    let due = update_due_status(
        now_seconds(),
        file_first_line_value(COMPONENT_UPDATE_CHECK_STATE_FILE),
        seconds
    );
    if (due == 1)
        exit(0);
    if (due != 0)
        exit(1);

    if (!acquire_runtime_lock(COMPONENT_UPDATE_CHECK_LOCK_DIR, false))
        exit(0);

    due = update_due_status(
        now_seconds(),
        file_first_line_value(COMPONENT_UPDATE_CHECK_STATE_FILE),
        seconds
    );
    if (due != 0) {
        release_runtime_lock(COMPONENT_UPDATE_CHECK_LOCK_DIR);
        exit(due == 1 ? 0 : 1);
    }

    ensure_dir(COMPONENT_UPDATE_CHECK_CACHE_DIR);
    for (let component in automatic_component_check_names())
        run_automatic_component_update_check(component);

    if (!write_file(COMPONENT_UPDATE_CHECK_STATE_FILE, as_string(now_seconds()) + "\n")) {
        release_runtime_lock(COMPONENT_UPDATE_CHECK_LOCK_DIR);
        log_message("Failed to write component update check timestamp", "error");
        exit(1);
    }
    release_runtime_lock(COMPONENT_UPDATE_CHECK_LOCK_DIR);
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

function jsdelivr_fallback_url(url) {
    url = as_string(url);
    let sources = [
        [ "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/", "https://cdn.jsdelivr.net/gh/itdoginfo/allow-domains@main/" ],
        [ FORKOP_MIRROR_BASE_URL + "/forkop/lists/allow-domains/", "https://cdn.jsdelivr.net/gh/itdoginfo/allow-domains@main/" ],
        [ FORKOP_MIRROR_BASE_URL + "/forkop/lists/b4geoip-forkop/", "https://cdn.jsdelivr.net/gh/Greeg0ry/b4geoip-forkop@main/" ],
        [ "https://raw.githubusercontent.com/Greeg0ry/b4geoip-forkop/main/", "https://cdn.jsdelivr.net/gh/Greeg0ry/b4geoip-forkop@main/" ]
    ];

    for (let source in sources) {
        let prefix = source[0];
        if (substr(url, 0, length(prefix)) == prefix)
            return source[1] + substr(url, length(prefix));
    }

    return "";
}

function github_raw_fallback_url(url) {
    url = as_string(url);
    let mirror_prefix = FORKOP_MIRROR_BASE_URL != "" ?
        FORKOP_MIRROR_BASE_URL + "/forkop/lists/allow-domains/" : "";
    let jsdelivr_prefix = "https://cdn.jsdelivr.net/gh/itdoginfo/allow-domains@main/";
    let b4geoip_mirror_prefix = FORKOP_MIRROR_BASE_URL != "" ?
        FORKOP_MIRROR_BASE_URL + "/forkop/lists/b4geoip-forkop/" : "";
    let b4geoip_jsdelivr_prefix = "https://cdn.jsdelivr.net/gh/Greeg0ry/b4geoip-forkop@main/";

    if (mirror_prefix != "" && substr(url, 0, length(mirror_prefix)) == mirror_prefix)
        return "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/" +
            substr(url, length(mirror_prefix));
    if (substr(url, 0, length(jsdelivr_prefix)) == jsdelivr_prefix)
        return "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/" +
            substr(url, length(jsdelivr_prefix));
    if (b4geoip_mirror_prefix != "" && substr(url, 0, length(b4geoip_mirror_prefix)) == b4geoip_mirror_prefix)
        return "https://raw.githubusercontent.com/Greeg0ry/b4geoip-forkop/main/" +
            substr(url, length(b4geoip_mirror_prefix));
    if (substr(url, 0, length(b4geoip_jsdelivr_prefix)) == b4geoip_jsdelivr_prefix)
        return "https://raw.githubusercontent.com/Greeg0ry/b4geoip-forkop/main/" +
            substr(url, length(b4geoip_jsdelivr_prefix));
    return "";
}

function fallback_urls(url) {
    let result = [];
    let jsdelivr = jsdelivr_fallback_url(url);
    let github_raw = github_raw_fallback_url(url);

    if (jsdelivr != "")
        push(result, jsdelivr);
    if (github_raw != "" && github_raw != jsdelivr)
        push(result, github_raw);
    return result;
}

function mirror_source_prefix(url) {
    let prefix = FORKOP_MIRROR_BASE_URL != "" ?
        FORKOP_MIRROR_BASE_URL + "/forkop/lists/allow-domains/" : "";
    return prefix != "" && substr(as_string(url), 0, length(prefix)) == prefix ? prefix : "";
}

function mirror_download_state(url) {
    let prefix = mirror_source_prefix(url);
    if (prefix == "")
        return null;

    if (type(list_mirror_download_state[prefix]) != "object")
        list_mirror_download_state[prefix] = { failures: 0, fallback_active: false };

    return list_mirror_download_state[prefix];
}

function record_mirror_download_success(state) {
    if (state != null && !state.fallback_active)
        state.failures = 0;
}

function record_mirror_download_failure(state) {
    if (state == null || state.fallback_active)
        return false;

    state.failures += 1;
    if (state.failures < MIRROR_FAILURE_THRESHOLD)
        return false;

    state.fallback_active = true;
    log_message(
        "Mirror source failed " + MIRROR_FAILURE_THRESHOLD +
            " consecutive times; using jsDelivr for remaining allow-domains lists in this update",
        "warn"
    );
    return true;
}

function list_bootstrap_dns_servers() {
    let result = [];
    let configured = uci_core.get(CONFIG_NAME + ".settings.bootstrap_dns_server");
    if (type(configured) != "array")
        configured = split(trim(as_string(configured)), /[ \t\r\n]+/);

    for (let value in configured) {
        let server = core_url.host(value);
        if (core_ip.valid_ip(server))
            push(result, server);
    }
    return result;
}

function list_bootstrap_resolve(url) {
    let host = core_url.host(url);
    if (host == "" || core_ip.valid_ip(host))
        return null;

    for (let server in list_bootstrap_dns_servers()) {
        let output = command_output_from_args([ "nslookup", host, server ]);
        let name_seen = false;
        let ipv6_address = "";
        for (let line in split(output, "\n")) {
            line = trim(as_string(line));
            if (index(line, "Name:") == 0) {
                name_seen = true;
                continue;
            }
            if (!name_seen)
                continue;
            let matched = match(line, /^Address([ \t]+[0-9]+)?:[ \t]*(.*)$/);
            if (matched == null)
                continue;
            let address = trim(as_string(matched[2]));
            if (core_ip.ip_family(address) == 4)
                return {
                    host,
                    port: core_url.port(url) || (core_url.scheme(url) == "http" ? "80" : "443"),
                    address
                };
            if (ipv6_address == "" && core_ip.ip_family(address) == 6)
                ipv6_address = address;
        }
        if (ipv6_address != "")
            return {
                host,
                port: core_url.port(url) || (core_url.scheme(url) == "http" ? "80" : "443"),
                address: ipv6_address
            };
    }
    return null;
}

function list_curl_args(url, filepath, proxy_address, resolve) {
    let args = [
        "curl", "-f", "-sS",
        "--connect-timeout", "20",
        "--speed-time", "15",
        "--speed-limit", "1",
        "-o", filepath
    ];
    if (as_string(proxy_address) != "") {
        push(args, "-x");
        push(args, "http://" + as_string(proxy_address));
    }
    if (resolve != null) {
        push(args, "--resolve");
        push(args, resolve.host + ":" + resolve.port + ":" +
            (core_ip.ip_family(resolve.address) == 6 ? "[" + resolve.address + "]" : resolve.address));
    }
    push(args, url);
    return args;
}

function download_to_file_once(url, filepath, proxy_address, resolve) {
    let target_dir = parent_dir(filepath);
    if (target_dir == "")
        target_dir = ".";
    let output = trim(command_output_from_args([ "df", "-Pk", target_dir ]));
    let lines = split(output, "\n");
    let fields = length(lines) >= 2 ? split(trim(lines[length(lines) - 1]), /[ \t]+/) : [];
    let available = length(fields) >= 4 ? int(fields[3]) * 1024 : -1;
    if (available < 0 || available <= LIST_DOWNLOAD_MIN_FREE_BYTES) {
        log_message("Not enough temporary storage to download " + safe_remote_source_identity(url) + " safely", "warn");
        return false;
    }
    // ash's file-size limit is enforced while bytes are written, including
    // responses without Content-Length. Keep a reserve for the running router.
    let max_blocks = int((available - LIST_DOWNLOAD_MIN_FREE_BYTES) / 512);
    let download_command = command_from_args(list_curl_args(url, filepath, proxy_address, resolve));
    let command = "ulimit -f " + max_blocks + "; " + download_command;

    let status = command_status(command);
    if (status != 0)
        fs.unlink(filepath);
    return status;
}

function download_to_file_with_bootstrap(url, filepath, proxy_address) {
    let status = download_to_file_once(url, filepath, proxy_address, null);
    // A configured proxy owns destination DNS. Do not bypass it with a direct
    // Bootstrap connection; the direct path uses this fallback only on curl's
    // explicit name-resolution failure code.
    if (status == 6 && as_string(proxy_address) == "") {
        let resolved = list_bootstrap_resolve(url);
        if (resolved != null) {
            log_message("Retrying remote list download with Bootstrap DNS", "info");
            status = download_to_file_once(url, filepath, proxy_address, resolved);
        }
    }
    return status == 0;
}

function download_fallback(url, filepath, proxy_address) {
    let attempt = 1;
    while (attempt <= 3) {
        if (download_to_file_with_bootstrap(url, filepath, proxy_address))
            return true;

        log_message("Attempt " + attempt + "/3 to download " + safe_remote_source_identity(url) + " failed", "warn");
        if (attempt < 3)
            command_success_from_args([ "sleep", "2" ]);
        attempt++;
    }

    return false;
}

function download_to_file_network(url, filepath, proxy_address) {
    let fallbacks = fallback_urls(url);
    let mirror_state = mirror_download_state(url);
    if (mirror_state != null && mirror_state.fallback_active) {
        log_message("Mirror source " + safe_remote_source_identity(url) + " is unavailable; trying fallback sources", "info");
        for (let fallback in fallbacks)
            if (download_fallback(fallback, filepath, proxy_address))
                return true;
        return false;
    }

    let attempt = 1;
    while (attempt <= 3) {
        if (download_to_file_with_bootstrap(url, filepath, proxy_address)) {
            record_mirror_download_success(mirror_state);
            return true;
        }

        log_message("Attempt " + attempt + "/3 to download " + safe_remote_source_identity(url) + " failed", "warn");
        let mirror_fallback_activated = record_mirror_download_failure(mirror_state);
        if (mirror_fallback_activated)
            break;
        if (attempt < 3)
            command_success_from_args([ "sleep", "2" ]);
        attempt++;
    }

    if (length(fallbacks) == 0)
        return false;

    log_message("Primary rule-set source " + safe_remote_source_identity(url) + " is unavailable; trying fallback sources", "warn");
    for (let fallback in fallbacks)
        if (download_fallback(fallback, filepath, proxy_address))
            return true;
    return false;
}

function download_to_file(url, filepath, proxy_address) {
    let staged = as_string(list_download_cache[as_string(url)]);
    if (staged != "")
        return copy_file(staged, filepath);
    return download_to_file_network(url, filepath, proxy_address);
}

function dns_probe_passed(proxy_address) {
    if (as_string(proxy_address) != "") {
        log_message("DNS check skipped because list downloads use service proxy", "info");
        return true;
    }

    let bootstrap_available = length(list_bootstrap_dns_servers()) > 0;
    let attempt = 1;
    while (attempt <= 10) {
        let output = command_output_from_args([ "dig", "+short", "openwrt.org", "A", "+timeout=3", "+tries=1" ]);
        for (let line in split(output, "\n")) {
            if (match(as_string(line), /^[0-9]+\./) != null) {
                log_message("DNS check passed", "info");
                return true;
            }
        }

        if (bootstrap_available) {
            log_message("System DNS is unavailable; continuing list update with configured Bootstrap DNS fallback", "warn");
            return true;
        }

        log_message("DNS is unavailable [" + attempt + "/10]", "info");
        command_success_from_args([ "sleep", "3" ]);
        attempt++;
    }

    log_message("DNS check failed after 10 attempts; skipping remote lists update until the next attempt", "error");
    return false;
}

function cached_list_change_sources() {
    // Runtime data is authoritative during this boot. Never substitute older
    // flash contents for a missing/corrupt source in a newer RAM generation.
    let root = fs.stat(RUNTIME_LIST_GENERATION_DIR + "/manifest.json") != null
        ? RUNTIME_LIST_GENERATION_DIR : PERSISTENT_LIST_CACHE_DIR;
    let manifest = read_json_file(root + "/manifest.json");
    let sources = {};
    if (manifest == null || as_string(manifest.format) != PERSISTENT_LIST_CACHE_FORMAT ||
        match(as_string(manifest.generation), /^gen-[A-Za-z0-9_.-]+$/) == null || type(manifest.files) != "array")
        return sources;
    for (let entry in manifest.files) {
        entry = object_or_empty(entry);
        if (as_string(entry.kind) == "source")
            sources[as_string(entry.url)] = { root, entry };
    }
    return sources;
}

function prepare_list_downloads(sections, proxy_address, reuse_sources) {
    list_download_cache = {};
    list_download_metadata = [];
    list_download_sequence = 0;
    list_download_staging_dir = temp_path();
    if (list_download_staging_dir != "")
        remove_file(list_download_staging_dir);
    if (list_download_staging_dir == "" || !ensure_dir(list_download_staging_dir)) {
        list_download_staging_dir = "";
        return false;
    }

    let cached = reuse_sources ? cached_list_change_sources() : {};
    let network_ready = !reuse_sources;
    for (let entry in list_preflight_entries(sections)) {
        list_download_sequence++;
        let path = list_download_staging_dir + "/source-" + as_string(list_download_sequence);
        let source = object_or_empty(cached[entry.url]);
        let metadata = object_or_empty(source.entry);
        let reused = as_string(metadata.source_format) == entry.format &&
            generation_file_valid(as_string(source.root), metadata).valid &&
            cache_copy_file(as_string(source.root) + "/" + as_string(metadata.name), path);
        if (!reused && !network_ready) {
            if (!dns_probe_passed(proxy_address))
                return false;
            network_ready = true;
        }
        if ((!reused && !download_to_file_network(entry.url, path, proxy_address)) ||
            !validate_staged_list_download(path, entry.format)) {
            log_message("Failed to preflight list source " + safe_remote_source_identity(entry.url) + "; keeping the active generation", "error");
            command_success_from_args([ "rm", "-rf", list_download_staging_dir ]);
            list_download_staging_dir = "";
            list_download_cache = {};
            return false;
        }
        list_download_cache[entry.url] = path;
        push(list_download_metadata, {
            name: "source-" + as_string(list_download_sequence),
            url: entry.url,
            format: entry.format
        });
    }
    return true;
}

function cleanup_list_downloads() {
    if (list_download_staging_dir != "")
        command_success_from_args([ "rm", "-rf", list_download_staging_dir ]);
    list_download_staging_dir = "";
    list_download_cache = {};
    list_download_metadata = [];
}

function load_persistent_list_sources() {
    let root = runtime_list_cache_active() ? RUNTIME_LIST_GENERATION_DIR : PERSISTENT_LIST_CACHE_DIR;
    let validation = list_generation_validation(root, current_list_update_signature());
    if (!validation.valid)
        return false;
    list_download_cache = {};
    list_download_metadata = [];
    for (let entry in validation.manifest.files) {
        entry = object_or_empty(entry);
        if (as_string(entry.kind) != "source")
            continue;
        let source = { name: as_string(entry.name), url: as_string(entry.url), format: as_string(entry.source_format) };
        let path = root + "/" + as_string(entry.name);
        list_download_cache[source.url] = path;
        push(list_download_metadata, source);
    }
    return true;
}

function convert_crlf_to_lf(path) {
    let data = fs.readfile(as_string(path));
    if (data == null || index(data, "\r") < 0)
        return;

        log_message("Converting CRLF line endings to LF in " + as_string(path), "debug");
    write_file(path, replace(data, /\r/g, ""));
}

function ruleset_module_success(args) {
    let command_args = [ LIB_DIR + "/routing/rulesets.uc" ];
    for (let arg in args)
        push(command_args, arg);
    return module_success(command_args);
}

function domain_ip_list_ruleset_path(section) {
    return TMP_RULESET_FOLDER + "/" + routing_rulesets_module().ruleset_tag(section_name(section), "lists", "") + ".json";
}

function remote_ruleset_path(section, kind) {
    return TMP_RULESET_FOLDER + "/" + routing_rulesets_module().ruleset_tag(section_name(section), "remote", kind) + ".json";
}

function reset_domain_ip_list_ruleset(section) {
    let path = domain_ip_list_ruleset_path(section);
    ensure_dir(TMP_RULESET_FOLDER);
    remove_file(path);
    return ruleset_module_success([ "create-source", path ]);
}

function ensure_ruleset_source(path) {
    ensure_dir(TMP_RULESET_FOLDER);
    if (file_exists_value(path))
        return true;
    return ruleset_module_success([ "create-source", path ]);
}

function cleanup_empty_ruleset(path) {
    if (routing_rulesets_module().has_rules(path))
        return true;
    remove_file(path);
    return false;
}

function add_plain_subnet_file_to_nft_for_section(section, filepath) {
    if (!file_nonempty(filepath))
        return true;

    return nft_module_success([
        "nft-add-subnet-file-for-uci-section",
        section_name(section),
        filepath,
        NFT_TABLE_NAME,
        NFT_COMMON_SET_NAME,
        NFT_IP_PORT_SET_NAME,
        "5000",
        NFT_COMMON6_SET_NAME,
        NFT_IP_PORT6_SET_NAME
    ]);
}

function add_json_ruleset_subnets_to_nft_for_section(section, json_file, label) {
    let unscoped_tmpfile = temp_path();
    let scoped_tmpfile = temp_path();
    if (unscoped_tmpfile == "" || scoped_tmpfile == "") {
        remove_files([ unscoped_tmpfile, scoped_tmpfile ]);
        return false;
    }

    let ok = nft_module_success([
        "nft-add-json-ruleset-subnets-for-uci-section",
        section_name(section),
        json_file,
        label,
        NFT_TABLE_NAME,
        NFT_COMMON_SET_NAME,
        NFT_IP_PORT_SET_NAME,
        unscoped_tmpfile,
        scoped_tmpfile,
        "5000",
        NFT_COMMON6_SET_NAME,
        NFT_IP_PORT6_SET_NAME
    ]);
    remove_files([ unscoped_tmpfile, scoped_tmpfile, scoped_tmpfile + ".tcp", scoped_tmpfile + ".udp" ]);
    return ok;
}

function import_domain_ip_list_file_into_rulesets(filepath, section) {
    if (!file_exists_value(filepath))
        return true;

    let domains_tmpfile = temp_path();
    let subnets_tmpfile = temp_path();
    if (domains_tmpfile == "" || subnets_tmpfile == "") {
        remove_files([ domains_tmpfile, subnets_tmpfile ]);
        return false;
    }

    let ruleset_filepath = domain_ip_list_ruleset_path(section);
    let ok = nft_module_success([ "split-domain-subnet-file", filepath, domains_tmpfile, subnets_tmpfile ]);
    let domains_only = option(section, "action", "") == "dns";
    if (ok)
        ok = ruleset_module_success([ "import-plain-list", domains_tmpfile, ruleset_filepath, "domain_suffix", "domains", "5000" ]);
    if (ok && !domains_only)
        ok = ruleset_module_success([ "import-plain-list", subnets_tmpfile, ruleset_filepath, "ip_cidr", "subnets", "5000" ]);
    if (ok && !domains_only)
        ok = add_plain_subnet_file_to_nft_for_section(section, subnets_tmpfile);

    remove_files([ domains_tmpfile, subnets_tmpfile ]);
    return ok;
}

function import_domain_ip_list_reference_into_rulesets(reference, section, settings) {
    reference = as_string(reference);
    if (match(reference, /^https?:\/\//) == null)
        return import_domain_ip_list_file_into_rulesets(reference, section);

    let tmpfile = temp_path();
    if (tmpfile == "")
        return false;

    let ok = true;
    if (download_to_file(reference, tmpfile, service_proxy_address(settings, "lists")) && file_nonempty(tmpfile)) {
        convert_crlf_to_lf(tmpfile);
        ok = import_domain_ip_list_file_into_rulesets(tmpfile, section);
    }
    else {
        log_message("Failed to download remote domain/IP list " + safe_remote_source_identity(reference, section_name(section)) + "; skipping it until the next successful update", "error");
        ok = false;
    }

    remove_file(tmpfile);
    return ok;
}

function rebuild_domain_ip_lists_from_rule(section, settings) {
    if (!bool_option(section, "enabled", true))
        return true;

    let references = list_option_values(section, "domain_ip_lists");
    if (length(references) == 0)
        return true;

    if (!reset_domain_ip_list_ruleset(section))
        return false;

    let ok = true;
    for (let reference in references)
        if (!import_domain_ip_list_reference_into_rulesets(reference, section, settings))
            ok = false;

    cleanup_empty_ruleset(domain_ip_list_ruleset_path(section));
    return ok;
}

function import_builtin_subnets_from_rule(section, settings) {
    if (!bool_option(section, "enabled", true))
        return true;
    if (option(section, "action", "") == "dns")
        return true;
    if (length(connections.community_lists(section)) == 0)
        return true;

    let ok = true;
    let materialized = { version: 3, rules: [] };
    let materialized_path = TMP_RULESET_FOLDER + "/" + section_name(section) + "-community-subnets-lists-ruleset.json";
    for (let service in connections.community_lists(section)) {
        if (!singbox_rulesets_module().is_community(service))
            continue;

        let urls = BUILTIN_SUBNET_URLS[as_string(service)];
        if (type(urls) != "array")
            continue;

        for (let url in urls) {
            let tmpfile = temp_path();
            if (tmpfile == "") {
                ok = false;
                continue;
            }

            if (!download_to_file(url, tmpfile, service_proxy_address(settings, "lists")) || !file_nonempty(tmpfile)) {
                log_message("Failed to download built-in " + as_string(service) + " subnet list; skipping it until the next successful update", "error");
                ok = false;
                remove_file(tmpfile);
                continue;
            }

            for (let rule in core_ip.community_subnet_rules(as_string(service), fs.readfile(tmpfile)))
                push(materialized.rules, rule);

            if (!nft_module_success([
                "nft-add-community-subnet-file-for-uci-section",
                section_name(section),
                service,
                tmpfile,
                NFT_TABLE_NAME,
                NFT_COMMON_SET_NAME,
                NFT_IP_PORT_SET_NAME,
                NFT_INTERFACE_SET_NAME,
                NFT_DISCORD_SET_NAME,
                NFT_FAKEIP_MARK,
                "5000",
                NFT_COMMON6_SET_NAME,
                NFT_IP_PORT6_SET_NAME,
                NFT_DISCORD6_SET_NAME
            ]))
                ok = false;

            remove_file(tmpfile);
        }
    }

    // Publish the same downloaded subnet generation for sing-box. The list
    // transaction snapshots/validates this managed file together with nft.
    if (ok && !write_file(materialized_path, sprintf("%J\n", materialized)))
        ok = false;
    return ok;
}

function import_custom_ruleset_subnets_from_local(path, format, section, label) {
    if (!file_exists_value(path)) {
        log_message("Local rule set file " + as_string(path) + " not found", "error");
        return false;
    }

    let json_tmpfile = temp_path();
    if (json_tmpfile == "")
        return false;

    let ok = true;
    if (as_string(format) == "binary") {
        if (!command_success_from_args([ "sing-box", "rule-set", "decompile", path, "-o", json_tmpfile ])) {
            log_message("Failed to decompile rule set " + as_string(path), "error");
            ok = false;
        }
    }
    else if (!copy_file(path, json_tmpfile)) {
        log_message("Failed to copy source rule set file " + as_string(path), "error");
        ok = false;
    }

    if (ok && !add_json_ruleset_subnets_to_nft_for_section(section, json_tmpfile, label))
        ok = false;

    remove_file(json_tmpfile);
    return ok;
}

function import_custom_ruleset_subnets_from_remote(url, format, section, label, settings) {
    let remote_tmpfile = temp_path();
    let json_tmpfile = temp_path();
    if (remote_tmpfile == "" || json_tmpfile == "") {
        remove_files([ remote_tmpfile, json_tmpfile ]);
        return false;
    }

    if (!download_to_file(url, remote_tmpfile, service_proxy_address(settings, "lists")) || !file_nonempty(remote_tmpfile)) {
        log_message("Failed to download remote rule set " + safe_remote_source_identity(url, section_name(section)) + "; skipping it until the next successful update", "error");
        remove_files([ remote_tmpfile, json_tmpfile ]);
        return false;
    }

    let ok = true;
    if (as_string(format) == "binary") {
        if (!command_success_from_args([ "sing-box", "rule-set", "decompile", remote_tmpfile, "-o", json_tmpfile ])) {
            log_message("Failed to decompile remote rule set " + safe_remote_source_identity(url, section_name(section)), "error");
            ok = false;
        }
    }
    else if (!copy_file(remote_tmpfile, json_tmpfile)) {
        log_message("Failed to copy downloaded remote rule set " + safe_remote_source_identity(url, section_name(section)), "error");
        ok = false;
    }

    if (ok && !add_json_ruleset_subnets_to_nft_for_section(section, json_tmpfile, label))
        ok = false;

    remove_files([ remote_tmpfile, json_tmpfile ]);
    return ok;
}

function import_rule_sets_with_subnets_from_rule(section, settings) {
    if (!bool_option(section, "enabled", true))
        return true;
    if (option(section, "action", "") == "dns")
        return true;

    let references = connections.rule_sets_with_subnets(section);
    if (length(references) == 0)
        return true;

    log_message("Importing subnets from rule sets with subnets for '" + section_name(section) + "' section", "info");
    let ok = true;

    for (let reference in references) {
        reference = as_string(reference);
        log_message("Importing subnets from rule set " + safe_remote_source_identity(reference, section_name(section)), "info");

        let extension = singbox_rulesets_module().file_extension(reference);
        if (match(reference, /^\/.*\.srs$/) != null) {
            if (!import_custom_ruleset_subnets_from_local(reference, "binary", section, "Rule set " + reference))
                ok = false;
        }
        else if (match(reference, /^\/.*\.json$/) != null) {
            if (!import_custom_ruleset_subnets_from_local(reference, "source", section, "Rule set " + reference))
                ok = false;
        }
        else if (match(reference, /^https?:\/\//) != null) {
            let format = extension == "json" ? "source" : (extension == "srs" ? "binary" : singbox_rulesets_module().remote_format(reference));
            if (!import_custom_ruleset_subnets_from_remote(reference, format, section, "Rule set " + reference, settings))
                ok = false;
        }
        else {
            log_message("Unsupported rule set reference for subnet import: " + safe_remote_source_identity(reference, section_name(section)), "error");
            ok = false;
        }
    }

    return ok;
}

function import_domains_from_remote_plain_file(url, section, settings) {
    let tmpfile = temp_path();
    if (tmpfile == "")
        return false;

    if (!download_to_file(url, tmpfile, service_proxy_address(settings, "lists")) || !file_nonempty(tmpfile)) {
        log_message("Failed to download remote domain list " + safe_remote_source_identity(url, section_name(section)) + "; skipping it until the next successful update", "error");
        remove_file(tmpfile);
        return false;
    }

    convert_crlf_to_lf(tmpfile);
    let ruleset_path = remote_ruleset_path(section, "domains");
    let ok = ensure_ruleset_source(ruleset_path) &&
        ruleset_module_success([ "import-plain-list", tmpfile, ruleset_path, "domain_suffix", "domains", "5000" ]);
    remove_file(tmpfile);
    return ok;
}

function import_domains_from_remote_domain_lists(section, settings) {
    if (!bool_option(section, "enabled", true))
        return true;

    let references = list_option_values(section, "remote_domain_lists");
    if (length(references) == 0)
        return true;

    log_message("Importing domains from remote domain lists for '" + section_name(section) + "' section", "info");
    let ok = true;
    for (let url in references) {
        log_message("Importing domains from " + safe_remote_source_identity(url, section_name(section)), "info");
        let extension = singbox_rulesets_module().file_extension(url);
        log_message("Detected file extension: '" + extension + "'", "debug");
        if (extension == "json" || extension == "srs") {
            log_message("No update needed - sing-box manages updates automatically.", "info");
            continue;
        }
        log_message("Import domains from a remote plain-text list", "info");
        if (!import_domains_from_remote_plain_file(url, section, settings))
            ok = false;
    }
    return ok;
}

function import_subnets_from_remote_json_file(url, section, settings) {
    let json_tmpfile = temp_path();
    if (json_tmpfile == "")
        return false;

    if (!download_to_file(url, json_tmpfile, service_proxy_address(settings, "lists")) || !file_nonempty(json_tmpfile)) {
        log_message("Failed to download remote JSON subnet list " + safe_remote_source_identity(url, section_name(section)) + "; skipping it until the next successful update", "error");
        remove_file(json_tmpfile);
        return false;
    }

    let ok = add_json_ruleset_subnets_to_nft_for_section(section, json_tmpfile, "Remote JSON rule set " + as_string(url));
    if (!ok)
        log_message("Failed to add subnets from remote JSON list " + safe_remote_source_identity(url, section_name(section)) + " to nftables", "error");
    remove_file(json_tmpfile);
    return ok;
}

function import_subnets_from_remote_srs_file(url, section, settings) {
    let binary_tmpfile = temp_path();
    let json_tmpfile = temp_path();
    if (binary_tmpfile == "" || json_tmpfile == "") {
        remove_files([ binary_tmpfile, json_tmpfile ]);
        return false;
    }

    if (!download_to_file(url, binary_tmpfile, service_proxy_address(settings, "lists")) || !file_nonempty(binary_tmpfile)) {
        log_message("Failed to download remote SRS subnet list " + safe_remote_source_identity(url, section_name(section)) + "; skipping it until the next successful update", "error");
        remove_files([ binary_tmpfile, json_tmpfile ]);
        return false;
    }

    let ok = command_success_from_args([ "sing-box", "rule-set", "decompile", binary_tmpfile, "-o", json_tmpfile ]);
    if (!ok)
        log_message("Failed to decompile binary rule set file", "error");
    if (ok && !add_json_ruleset_subnets_to_nft_for_section(section, json_tmpfile, "Remote SRS rule set " + as_string(url))) {
        log_message("Failed to add subnets from remote SRS list " + safe_remote_source_identity(url, section_name(section)) + " to nftables", "error");
        ok = false;
    }

    remove_files([ binary_tmpfile, json_tmpfile ]);
    return ok;
}

function import_subnets_from_remote_plain_file(url, section, settings) {
    let tmpfile = temp_path();
    if (tmpfile == "")
        return false;

    if (!download_to_file(url, tmpfile, service_proxy_address(settings, "lists")) || !file_nonempty(tmpfile)) {
        log_message("Failed to download remote plain subnet list " + safe_remote_source_identity(url, section_name(section)) + "; skipping it until the next successful update", "error");
        remove_file(tmpfile);
        return false;
    }

    convert_crlf_to_lf(tmpfile);
    let ruleset_path = remote_ruleset_path(section, "subnets");
    let ok = ensure_ruleset_source(ruleset_path) &&
        ruleset_module_success([ "import-plain-list", tmpfile, ruleset_path, "ip_cidr", "subnets", "5000" ]);
    if (ok)
        ok = add_plain_subnet_file_to_nft_for_section(section, tmpfile);
    remove_file(tmpfile);
    return ok;
}

function import_subnets_from_remote_subnet_lists(section, settings) {
    if (!bool_option(section, "enabled", true))
        return true;

    let references = list_option_values(section, "remote_subnet_lists");
    if (length(references) == 0)
        return true;

    log_message("Importing subnets from remote subnet lists for '" + section_name(section) + "' section", "info");
    let ok = true;
    for (let url in references) {
        log_message("Importing subnets from " + safe_remote_source_identity(url, section_name(section)), "info");
        let extension = singbox_rulesets_module().file_extension(url);
        log_message("Detected file extension: '" + extension + "'", "debug");
        if (extension == "json") {
            log_message("Import subnets from a remote JSON list", "info");
            if (!import_subnets_from_remote_json_file(url, section, settings))
                ok = false;
        }
        else if (extension == "srs") {
            log_message("Import subnets from a remote SRS list", "info");
            if (!import_subnets_from_remote_srs_file(url, section, settings))
                ok = false;
        }
        else {
            log_message("Import subnets from a remote plain-text list", "info");
            if (!import_subnets_from_remote_plain_file(url, section, settings))
                ok = false;
        }
    }
    return ok;
}

function list_update_pid_begin() {
    let existing_pid = trim(as_string(fs.readfile(LIST_UPDATE_PID_FILE) || ""));
    let current_pid = owner_pid();
    if (existing_pid != "" && existing_pid != current_pid && runtime_pid_running(existing_pid)) {
        log_message("Another lists update is already running, skipping", "info");
        return false;
    }

    ensure_parent_dir(LIST_UPDATE_PID_FILE);
    write_file(LIST_UPDATE_PID_FILE, current_pid + "\n");
    return true;
}

function list_update_pid_end() {
    remove_file(LIST_UPDATE_PID_FILE);
}

function begin_list_ruleset_snapshot() {
    list_ruleset_snapshot_dir = as_string(getenv("FORKOP_LIST_CHANGE_ROLLBACK_DIR") || "") || temp_path();
    if (list_ruleset_snapshot_dir != "")
        remove_file(list_ruleset_snapshot_dir);
    if (list_ruleset_snapshot_dir == "" || !ensure_dir(list_ruleset_snapshot_dir)) {
        list_ruleset_snapshot_dir = "";
        return;
    }

    ensure_dir(TMP_RULESET_FOLDER);
    if (!command_success_from_args([ "cp", "-R", "-p", TMP_RULESET_FOLDER + "/.", list_ruleset_snapshot_dir ])) {
        command_success_from_args([ "rm", "-rf", list_ruleset_snapshot_dir ]);
        list_ruleset_snapshot_dir = "";
    }
}

function begin_list_nft_candidate() {
    list_nft_candidate_file = temp_path();
    if (list_nft_candidate_file == "")
        return false;
    remove_file(list_nft_candidate_file);
    if (!write_file(list_nft_candidate_file, "")) {
        list_nft_candidate_file = "";
        return false;
    }
    return true;
}

function discard_list_nft_candidate() {
    // Preflight can fail before a candidate is created. In that case the
    // active nft table was never touched and there is nothing to roll back.
    remove_file(list_nft_candidate_file);
    list_nft_candidate_file = "";
}

function finish_list_ruleset_snapshot(commit) {
    if (list_ruleset_snapshot_dir == "")
        return false;

    if (!commit) {
        command_success_from_args([ "rm", "-rf", TMP_RULESET_FOLDER ]);
        ensure_dir(TMP_RULESET_FOLDER);
        let restored = command_success_from_args([ "cp", "-R", "-p", list_ruleset_snapshot_dir + "/.", TMP_RULESET_FOLDER ]);
        command_success_from_args([ "rm", "-rf", list_ruleset_snapshot_dir ]);
        list_ruleset_snapshot_dir = "";
        return false;
    }

    let sing_box_changed = false;
    // A source edit is prepared inside lifecycle's transaction. Keep its
    // existing snapshot until the core and nft policy have both committed,
    // so a hot-reload rollback can still read the exact old list contents.
    let retain = as_string(getenv("FORKOP_LIST_CHANGE_ROLLBACK_DIR") || "") == list_ruleset_snapshot_dir;
    let seen = {};
    for (let backup in fs.glob(list_ruleset_snapshot_dir + "/*")) {
        let name = substr(backup, length(list_ruleset_snapshot_dir) + 1);
        let current = TMP_RULESET_FOLDER + "/" + name;
        seen[name] = true;
        if (file_md5(backup) != "" && file_md5(backup) == file_md5(current)) {
            // Preserve both bytes and metadata when a checked source produced
            // exactly the same materialized rule set.
            if (retain)
                cache_copy_file(backup, current);
            else
                fs.rename(backup, current);
        }
        else if (match(name, /-(lists|remote-domains)-ruleset\.json$/) != null)
            sing_box_changed = true;
    }
    for (let current in fs.glob(TMP_RULESET_FOLDER + "/*")) {
        let name = substr(current, length(TMP_RULESET_FOLDER) + 1);
        if (!seen[name] && match(name, /-(lists|remote-domains)-ruleset\.json$/) != null)
            sing_box_changed = true;
    }

    if (!retain)
        command_success_from_args([ "rm", "-rf", list_ruleset_snapshot_dir ]);
    list_ruleset_snapshot_dir = "";
    return sing_box_changed;
}

function reset_remote_plain_rulesets(sections) {
    for (let section in sections) {
        if (!bool_option(section, "enabled", true))
            continue;

        for (let url in list_option_values(section, "remote_domain_lists")) {
            let extension = singbox_rulesets_module().file_extension(url);
            if (extension != "json" && extension != "srs") {
                remove_file(remote_ruleset_path(section, "domains"));
                break;
            }
        }
        for (let url in list_option_values(section, "remote_subnet_lists")) {
            let extension = singbox_rulesets_module().file_extension(url);
            if (extension != "json" && extension != "srs") {
                remove_file(remote_ruleset_path(section, "subnets"));
                break;
            }
        }
    }
}

function apply_persistent_list_cache() {
    // The runtime generation is authoritative for this boot, including a
    // successful RAM-only update.  Reloads must rebuild from it locally and
    // never replace it with an older flash generation.
    if (runtime_list_cache_active()) {
        if (!restore_runtime_list_generation() || !load_persistent_list_sources())
            return false;
    }
    else if (!restore_persistent_list_cache() || !load_persistent_list_sources())
        return false;

    let settings = uci_settings();
    let sections = uci_sections("section");
    reset_remote_plain_rulesets(sections);
    let ok = true;
    for (let section in sections)
        if (!rebuild_domain_ip_lists_from_rule(section, settings))
            ok = false;
    for (let section in sections)
        if (!import_builtin_subnets_from_rule(section, settings))
            ok = false;
    for (let section in sections)
        if (!import_domains_from_remote_domain_lists(section, settings))
            ok = false;
    for (let section in sections)
        if (!import_subnets_from_remote_subnet_lists(section, settings))
            ok = false;
    for (let section in sections)
        if (!import_rule_sets_with_subnets_from_rule(section, settings))
            ok = false;
    list_download_cache = {};
    list_download_metadata = [];
    return ok;
}

function run_deferred_ruleset_refresh() {
    let request = trim(file_first_line_value(RULESET_REFRESH_AFTER_LIST_FILE));
    remove_file(RULESET_REFRESH_AFTER_LIST_FILE);
    if (request == "")
        return;
    module_background([
        RULESET_CACHE_UC,
        request == "due" ? "refresh-if-due-and-reload" : "refresh-and-reload",
        service_proxy_address(uci_settings(), "lists")
    ]);
}

function finish_list_update(status, applied, generation_changed) {
    if (applied == null)
        applied = status == 0;
    if (generation_changed == null)
        generation_changed = applied;
    let rulesets_changed = finish_list_ruleset_snapshot(applied);
    discard_list_nft_candidate();
    cleanup_list_downloads();
    let reload_deferred = file_exists_value(LIST_UPDATE_RELOAD_FILE);
    let ruleset_request = trim(file_first_line_value(RULESET_REFRESH_AFTER_LIST_FILE));
    let ruleset_changed = false;
    remove_file(RULESET_REFRESH_AFTER_LIST_FILE);

    // When both list families changed, refresh remote sing-box rule sets while
    // the old service proxy is still alive and coalesce everything into the
    // same final reload.
    if (!applied) {
        // A source/config reload requested this transaction, but no complete
        // generation was committed. Keep both requests pending so the next
        // successful scheduled or manual list update applies all changes once.
        if (reload_deferred)
            write_file(LIST_UPDATE_RELOAD_FILE, "1\n");
        if (ruleset_request != "")
            write_file(RULESET_REFRESH_AFTER_LIST_FILE, ruleset_request + "\n");
    }
    else if (ruleset_request != "") {
        let ruleset_status = module_status([
            RULESET_CACHE_UC,
            ruleset_request == "due" ? "refresh-if-due" : "refresh",
            service_proxy_address(uci_settings(), "lists")
        ]);
        ruleset_changed = ruleset_status == 0;
        if (ruleset_status > 1)
            log_message("Remote rule-set refresh failed; keeping its last-known-good cache", "warn");
    }
    list_update_pid_end();
    if (as_string(getenv("FORKOP_MANUAL_RESTART_LOCK_HELD") || "0") != "1")
        release_runtime_lock(RELOAD_LOCK_DIR);

    // The LuCI manual-restart path prepares and validates a complete list
    // generation while the old runtime is still serving traffic. The staged
    // generation is atomically published by commit_runtime_list_generation(),
    // but it is not made policy-active here: lifecycle.restart() is the sole
    // runtime transition after all data families are prepared.
    if (as_string(getenv("FORKOP_LIST_UPDATE_PREPARE_ONLY") || "0") == "1")
        exit(status == 0 ? 0 : 1);

    // A successful generation reload reads the newest UCI state itself, so it
    // subsumes a queued reload instead of launching pending + list-content as
    // two competing reloads. Do not consume that request until the final
    // runtime apply actually succeeds: the generation may be complete while
    // its corresponding nft/sing-box transition still fails.
    let pending_reload = applied ? fs.readfile(PENDING_RELOAD_FILE) : null;
    if (!applied)
        service_state_success([ "run-pending-reload-if-requested", PENDING_RELOAD_FILE, SERVICE_INIT ]);
    // nft list mutations were only candidate data. Publish the committed
    // generation through lifecycle, which rebuilds the full nft table in one
    // transaction; never append those elements to the active table here.
    let needs_runtime_apply = applied && (generation_changed || rulesets_changed || ruleset_changed || reload_deferred || pending_reload != null);
    if (needs_runtime_apply) {
        // The init wrapper may accept this request while another lifecycle
        // owns reload.lock and return success after only queuing it. Persist
        // the local-apply intent before that call; lifecycle removes it only
        // after a real list-content transition commits.
        if (!write_file(LIST_UPDATE_RELOAD_FILE, "apply-pending\n")) {
            log_message("Unable to persist the committed list generation's local runtime-apply request", "error");
            exit(1);
        }
        // Avoid a competing pending reload while this synchronous apply owns
        // the transition. Restore the exact request if the apply fails.
        if (pending_reload != null)
            service_state_success([ "consume-pending-reload", PENDING_RELOAD_FILE ]);

        let reload_result = command_capture(command_from_args([ SERVICE_INIT, "reload", "list-content" ]) + " 2>/dev/null 0<&-");
        let reload_status = reload_result.status;
        if (reload_status != 0) {
            // The generation is valid and remains active. Retain an explicit
            // local-only apply request; lifecycle turns the next ordinary
            // reload into list-content, so it never has to download again.
            write_file(LIST_UPDATE_RELOAD_FILE, "apply-failed\n");
            if (pending_reload != null)
                write_file(PENDING_RELOAD_FILE, pending_reload);
            log_message("List generation was committed, but applying it to the runtime policy failed; retaining it for a local retry", "error");
            exit(reload_status);
        }
        if (trim(reload_result.output) == "queued") {
            log_message("List generation was committed and its runtime apply was queued; retaining the local list-content request", "info");
            exit(status == 0 ? 0 : 1);
        }

        exit(status == 0 ? 0 : 1);
    }
    exit(status == 0 ? 0 : 1);
}

function list_update(reuse_sources) {
    log_message(reuse_sources ? "Preparing changed list sources; reusing validated cache" : "Starting lists update", "info");
    if (!list_update_pid_begin()) {
        if (as_string(getenv("FORKOP_MANUAL_RESTART_LOCK_HELD") || "0") == "1") {
            log_message("Lists update is already running; manual restart preparation was not started", "warn");
            exit(1);
        }
        exit(0);
    }

    // Share the same lock as lifecycle reloads.  Waiting here is intentional:
    // a startup or config reload must settle before this worker opens requests
    // through the sing-box service proxy.  Conversely, init.d queues reloads
    // that arrive while this lock is held, and finish_list_update() runs them.
    if (as_string(getenv("FORKOP_MANUAL_RESTART_LOCK_HELD") || "0") != "1" && !acquire_runtime_lock(RELOAD_LOCK_DIR, true)) {
        log_message("Lists update skipped because Forkop reload did not release the runtime lock", "warn");
        list_update_pid_end();
        exit(1);
    }

    list_mirror_download_state = {};
    let settings = uci_settings();
    list_update_signature_at_start = current_list_update_signature();
    if (list_update_signature_at_start == "")
        finish_list_update(1, false);
    let proxy_address = service_proxy_address(settings, "lists");
    if (!reuse_sources && !dns_probe_passed(proxy_address)) {
        finish_list_update(1, false);
    }
    log_message(reuse_sources ? "Processing required lists; downloading only uncached sources" : "Downloading and processing lists", "info");
    let sections = uci_sections("section");
    if (!prepare_list_downloads(sections, proxy_address, reuse_sources))
        finish_list_update(1, false);
    begin_list_ruleset_snapshot();
    if (list_ruleset_snapshot_dir == "")
        finish_list_update(1, false);
    if (!begin_list_nft_candidate()) {
        log_message("Could not prepare the nftables candidate batch; aborting the list transaction", "error");
        finish_list_update(1, false);
    }
    // Reconstruct the current composition, including removal of the last
    // list or section. The snapshot restores the old files on preparation
    // failure; unrelated old materializations must not enter the new manifest.
    if (reuse_sources)
        for (let path in fs.glob(TMP_RULESET_FOLDER + "/*"))
            if (managed_list_ruleset_name(substr(path, length(TMP_RULESET_FOLDER) + 1)))
                remove_file(path);
    reset_remote_plain_rulesets(sections);
    let ok = true;

    for (let section in sections)
        if (!rebuild_domain_ip_lists_from_rule(section, settings))
            ok = false;
    for (let section in sections)
        if (!import_builtin_subnets_from_rule(section, settings))
            ok = false;
    for (let section in sections)
        if (!import_domains_from_remote_domain_lists(section, settings))
            ok = false;
    for (let section in sections)
        if (!import_subnets_from_remote_subnet_lists(section, settings))
            ok = false;
    for (let section in sections)
        if (!import_rule_sets_with_subnets_from_rule(section, settings))
            ok = false;

    if (current_list_update_signature() != list_update_signature_at_start) {
        log_message("List sources changed during the update; discarding the stale generation", "warn");
        ok = false;
    }

    // A configuration edit reuses cached bytes; it is not a periodic refresh
    // and must not postpone the next scheduled check of those sources.
    let completed_at = reuse_sources
        ? int(trim(file_first_line_value(LIST_UPDATE_RUNTIME_STATE_FILE)) ||
            trim(file_first_line_value(LIST_UPDATE_STATE_FILE)) || "0")
        : now_seconds();
    let runtime_committed = ok && commit_runtime_list_generation(list_update_signature_at_start);
    if (!runtime_committed)
        ok = false;
    let generation_changed = ok && runtime_generation_commit_changed;
    let cache_persisted = ok && persist_list_cache(completed_at);
    if (ok) {
        ensure_parent_dir(LIST_UPDATE_RUNTIME_STATE_FILE);
        write_file(LIST_UPDATE_RUNTIME_STATE_FILE, as_string(completed_at) + "\n");
        write_file(LIST_UPDATE_RUNTIME_SIGNATURE_FILE, list_update_signature_at_start + "\n");
        if (cache_persisted)
            log_message("Lists update completed successfully and was saved to persistent cache", "info");
        else
            log_message("Lists update completed successfully in runtime memory; persistent cache was not changed", "warn");
    }
    else {
        log_message("Lists update failed", "info");
    }

    finish_list_update(ok ? 0 : 1, ok, generation_changed);
}

function list_update_after_start() {
    if (!service_state_success([ "has-list-update-sources" ])) {
        run_deferred_ruleset_refresh();
        exit(0);
    }

    if (!restore_persistent_list_cache()) {
        log_message("Persistent list cache is missing, stale or invalid; scheduling a recovery update", "info");
        list_update();
    }

    let interval = settings_update_interval(uci_settings());
    if (interval == "") {
        run_deferred_ruleset_refresh();
        exit(0);
    }
    let seconds = duration_to_seconds_value(interval);
    if (seconds == null)
        exit(1);
    let status = update_due_status(now_seconds(), list_update_last_success(), seconds);
    if (status == 0)
        list_update();
    run_deferred_ruleset_refresh();
    exit(status == 1 ? 0 : 1);
}

function list_update_if_due() {
    let interval = settings_update_interval(uci_settings());
    if (interval == "")
        exit(1);

    let seconds = duration_to_seconds_value(interval);
    if (seconds == null) {
        log_message("Invalid update_interval value: " + interval, "error");
        exit(1);
    }

    let status = update_due_status(now_seconds(), list_update_last_success(), seconds);
    if (status == 0)
        list_update();
    if (status == 1)
        exit(0);

    exit(1);
}

function stop_list_update() {
    let pid = trim(as_string(fs.readfile(LIST_UPDATE_PID_FILE) || ""));
    if (pid != "" && runtime_pid_running(pid)) {
        command_success_from_args([ "kill", pid ]);
        log_message("Stopped list_update", "info");
    }
    remove_file(LIST_UPDATE_PID_FILE);
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
        FORKOP_SERVICE_INIT: SERVICE_INIT,
        SB_SERVICE_MIXED_INBOUND_ADDRESS,
        SB_SERVICE_MIXED_INBOUND_PORT,
        SB_VARIANT_STATE_FILE
    };
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

function subscription_cache_capture(args) {
    let command_args = [ LIB_DIR + "/subscription/cache.uc" ];
    for (let arg in args)
        push(command_args, arg);
    return module_env_capture(subscription_cache_env(), command_args);
}

function subscription_cache_success(args) {
    let result = subscription_cache_capture(args);
    if (result.output != "")
        for (let line in split(result.output, "\n"))
            if (trim(as_string(line)) != "")
                log_message("subscription cache: " + line, "debug");
    return result.status == 0;
}

function log_file_lines_from_text(text, level, prefix) {
    for (let line in split(as_string(text), "\n"))
        if (trim(as_string(line)) != "")
            log_message(as_string(prefix) + as_string(line), level);
}

function singbox_runtime_success(args) {
    let command_args = [ LIB_DIR + "/singbox/runtime.uc" ];
    for (let arg in args)
        push(command_args, arg);

    let result = module_env_capture(subscription_cache_env(), command_args);
    if (result.output != "")
        log_file_lines_from_text(result.output, "debug", "sing-box runtime: ");
    return result.status == 0;
}

function write_current_reload_state_clean() {
    return service_state_success([
        "write-current-reload-state-clean",
        RELOAD_STATE_FILE,
        RELOAD_STATE_FORMAT,
        RULE_CONDITION_CACHE_DIR
    ]);
}

function mark_pending_reload(reason) {
    service_state_success([ "mark-pending-reload", PENDING_RELOAD_FILE, reason ]);
}

function run_pending_reload_if_requested() {
    service_state_success([ "run-pending-reload-if-requested", PENDING_RELOAD_FILE, SERVICE_INIT ]);
}

function subscription_prepare_cache_request(force, target_section, target_source_index) {
    let result = subscription_cache_capture([
        "update-request",
        force ? "1" : "0",
        as_string(target_section),
        as_string(target_source_index)
    ]);
    if (result.status != 0) {
        log_file_lines_from_text(result.output, "error", "subscription update: ");
        return { ok: false, updated: 0, failed: 0, unchanged: 0, superseded: 0 };
    }

    let fields = split(trim(result.output), /[ \t\r\n]+/);
    let updated = arg_number(fields[0] || "0");
    let failed = arg_number(fields[1] || "0");
    let unchanged = arg_number(fields[2] || "0");
    let superseded = arg_number(fields[3] || "0");

    if (updated == 0) {
        if (superseded > 0) {
            log_message("Subscription update was superseded by newer configuration", "info");
            return { ok: true, updated, failed, unchanged, superseded };
        }
        if (failed > 0) {
            log_message("Subscription update finished with errors; keeping the last working cache", "info");
            return { ok: false, updated, failed, unchanged, superseded };
        }
        if (unchanged > 0)
            log_message("Subscription update completed: no changes detected", "info");
        else
            log_message("No subscription rules are due for update", "info");
        return { ok: true, updated, failed, unchanged, superseded };
    }

    return { ok: true, updated, failed, unchanged, superseded };
}

function subscription_apply_failure(reason, state) {
    subscription_failure_detail = { reason, state };
    log_message("[subscription-apply-failed] " + state + ": " + reason, "error");
    return false;
}

function subscription_record_result(ok, section) {
    if (ok) {
        fs.unlink(SUBSCRIPTION_APPLY_ERROR_FILE);
        return;
    }
    ensure_dir(RUNTIME_STATE_DIR);
    let value = subscription_failure_detail || { reason: "apply_failed", state: "unknown" };
    value.section = as_string(section);
    let temporary = SUBSCRIPTION_APPLY_ERROR_FILE + ".tmp";
    if (common.write_private_json_file(temporary, value) == null || !fs.rename(temporary, SUBSCRIPTION_APPLY_ERROR_FILE)) {
        fs.unlink(temporary);
        log_message("Unable to store the subscription apply alert", "error");
    }
}

function subscription_hot_transition(config_path) {
    let work = trim(command_output_from_args([ "mktemp", "-d", "/tmp/forkop-subscription-hot.XXXXXX" ]));
    if (work == "" || !fs.chmod(work, 0700)) {
        if (work != "") command_success_from_args([ "rm", "-rf", work ]);
        return { handled: true, ok: subscription_apply_failure("stage_failed", "previous") };
    }
    let stage = work + "/candidate.json", backup = work + "/previous.json";
    let hot_module = LIB_DIR + "/service/hot_reload.uc";
    let prepared = singbox_runtime_success([ "prepare-config-stage", "0", "1", "1", "", stage ]);
    let plan = prepared ? module_capture([ hot_module, "plan", stage ]) : { status: 1 };
    if (plan.status != 0 || trim(plan.output) != "hot") {
        singbox_runtime_success([ "discard-config-stage", stage ]);
        command_success_from_args([ "rm", "-rf", work ]);
        return plan.status == 0 && trim(plan.output) == "cold"
            ? { handled: false }
            : { handled: true, ok: subscription_apply_failure(prepared ? "plan_failed" : "stage_failed", "previous") };
    }
    let had_cache = fs.stat(SECTION_CACHE_DIR) != null;
    if ((had_cache && !command_success_from_args([ "cp", "-R", "-p", SECTION_CACHE_DIR, backup + ".section-cache" ])) ||
        !command_success_from_args([ "cp", "-p", config_path, backup ]) ||
        !module_success([ LIB_DIR + "/service/lifecycle.uc", "save-selector-state", backup + ".selectors" ])) {
        singbox_runtime_success([ "discard-config-stage", stage ]);
        command_success_from_args([ "rm", "-rf", work ]);
        return { handled: true, ok: subscription_apply_failure("backup_failed", "previous") };
    }
    module_success([ DNS_FAILOVER_UC, "stop-runtime" ]);
    module_success([ PRIORITY_UC, "stop-runtime" ]);
    let committed = singbox_runtime_success([ "commit-config-stage", stage, backup ]);
    let applied = committed && module_success([ hot_module, "apply", stage + ".hot-plan" ]);
    let reason = "hot_apply_failed";
    if (applied) {
        let workers = module_success([ PRIORITY_UC, "start-runtime" ]);
        workers = module_success([ DNS_FAILOVER_UC, "start-runtime" ]) && workers;
        if (!workers) {
            reason = "workers_failed";
            applied = false;
            module_success([ PRIORITY_UC, "stop-runtime" ]);
            module_success([ DNS_FAILOVER_UC, "stop-runtime" ]);
        }
    }
    if (!applied) {
        let restored = module_success([ hot_module, "restore", stage + ".hot-plan", backup ]);
        let cache_restored = restored && (had_cache
            ? singbox_runtime_success([ "publish-section-cache", backup ])
            : command_success_from_args([ "rm", "-rf", SECTION_CACHE_DIR ]));
        cache_restored = cache_restored && module_success([ LIB_DIR + "/service/lifecycle.uc", "restore-selector-state", backup + ".selectors" ]);
        if (restored) {
            module_success([ PRIORITY_UC, "start-runtime" ]);
            module_success([ DNS_FAILOVER_UC, "start-runtime" ]);
        }
        if (restored && cache_restored) {
            singbox_runtime_success([ "discard-config-stage", stage ]);
            command_success_from_args([ "rm", "-rf", work ]);
        }
        else log_message("Subscription rollback files retained at " + work, "error");
        return { handled: true, ok: subscription_apply_failure(cache_restored ? reason : "rollback_failed", cache_restored ? "previous" : "recovery_failed") };
    }
    singbox_runtime_success([ "discard-config-stage", stage ]);
    command_success_from_args([ "rm", "-rf", work ]);
    log_message("Subscriptions applied with acknowledged Xrust hot reload; core process preserved", "info");
    return { handled: true, ok: true };
}

function subscription_restore_selectors(backup) {
    let snapshot = backup + ".selectors";
    if (fs.stat(snapshot) == null)
        return;
    if (!module_success([ LIB_DIR + "/service/lifecycle.uc", "restore-selector-state", snapshot ]))
        log_message("Could not restore all manual selector choices after subscription runtime transition", "warn");
}

function subscription_restore_runtime(backup, config_path, timeout) {
    let restore = backup + ".restore";
    let restored = service_state_success([ "stop-managed-sing-box-runtime", timeout ]) &&
        command_success_from_args([ "cp", "-p", backup, restore ]) &&
        singbox_runtime_success([ "restore-config-stage", restore ]) &&
        service_state_success([ "start-managed-sing-box-runtime", timeout ]) &&
        service_state_success([ "wait-managed-sing-box-config-listeners", config_path,
            as_string(getenv("FORKOP_SING_BOX_READY_TIMEOUT") || "90") ]);
    if (!restored) {
        log_message("Failed to recover the previous subscription runtime; backup retained at " + backup, "error");
        subscription_apply_failure("rollback_failed", "recovery_failed");
        return false;
    }
    subscription_restore_selectors(backup);
    module_success([ PRIORITY_UC, "start-runtime" ]);
    module_success([ DNS_FAILOVER_UC, "start-runtime" ]);
    subscription_apply_failure("apply_failed", "previous");
    return true;
}

function subscription_config_value(value) {
    if (type(value) == "array")
        return map(value, item => subscription_config_value(item));
    if (type(value) != "object")
        return value;
    let result = {};
    for (let key in sort(keys(value)))
        result[key] = subscription_config_value(value[key]);
    return result;
}

function subscription_runtime_change_check(config_path) {
    // Do not treat a stopped or foreign runtime as an already applied config.
    if (!service_state_success([ "sing-box-current-owned-service-runtime" ]))
        return { ok: true, changed: true };
    let work = trim(command_output_from_args([ "mktemp", "-d", "/tmp/forkop-subscription-check.XXXXXX" ]));
    if (work == "")
        return { ok: false, changed: true };
    if (!fs.chmod(work, 0700)) {
        command_success_from_args([ "rm", "-rf", work ]);
        return { ok: false, changed: true };
    }
    let stage = work + "/candidate.json";
    let prepared = singbox_runtime_success([ "prepare-config-stage", "0", "1", "1", "", stage ]);
    let current = read_json_file(config_path);
    let candidate = prepared ? read_json_file(stage) : null;
    let valid = type(current) == "object" && type(current.outbounds) == "array" &&
        type(candidate) == "object" && type(candidate.outbounds) == "array";
    // Compare the entire generated config, including selectors, urltests, DNS
    // and routing. Equal proxy signatures alone cannot justify skipping reload.
    let unchanged = valid && sprintf("%J", subscription_config_value(current)) ==
        sprintf("%J", subscription_config_value(candidate));
    let published = !unchanged || singbox_runtime_success([ "publish-section-cache", stage ]);
    singbox_runtime_success([ "discard-config-stage", stage ]);
    command_success_from_args([ "rm", "-rf", work ]);
    return { ok: prepared && valid && published, changed: !unchanged };
}

function subscription_update_common_locked(force, target_section, target_source_index) {
    subscription_failure_detail = null;
    subscription_outbounds_changed = false;
    let sing_box_config_path = option(uci_settings(), "config_path", "");
    let proxy_signature_before = current_proxy_outbounds_signature(sing_box_config_path);
    let prepared = subscription_prepare_cache_request(force, target_section, target_source_index);
    if (!prepared.ok)
        return false;
    let updated = prepared.updated;
    let failed = prepared.failed;
    if (updated == 0 && fs.stat(SUBSCRIPTION_APPLY_ERROR_FILE) == null)
        return true;

    let change = subscription_runtime_change_check(sing_box_config_path);
    if (!change.ok) {
        log_message("Cannot compare the updated subscription configuration; preserving the running runtime", "error");
        return false;
    }
    if (!change.changed) {
        log_message("Subscription cache refreshed; generated runtime configuration is unchanged, reload skipped", "info");
        return true;
    }

    let hot = subscription_hot_transition(sing_box_config_path);
    if (hot.handled && !hot.ok)
        return false;
    if (!hot.handled) {
        log_message("Reloading sing-box to apply updated subscriptions", "info");
        let validation = module_capture([ LIB_DIR + "/config/validator.uc", "validate-runtime" ]);
        if (validation.status != 0) {
            log_message("Forkop configuration is invalid: " + validation_failure_message(validation), "fatal");
            return false;
        }

        if (!singbox_runtime_success([ "configure-service" ]))
            return false;
        let backup_dir = trim(command_output_from_args([ "mktemp", "-d", "/tmp/forkop-subscription-runtime.XXXXXX" ]));
        let backup = backup_dir + "/previous.json";
        let previous = fs.readfile(sing_box_config_path);
        if (backup_dir == "" || !fs.chmod(backup_dir, 0700) || previous == null ||
            common.write_private_file(backup, previous) == null) {
            if (backup_dir != "")
                command_success_from_args([ "rm", "-rf", backup_dir ]);
            log_message("Cannot stage the previous subscription runtime", "error");
            return false;
        }
        // A subscription in one section restarts every selector, including manual
        // groups in other sections. Snapshot while the old API is still available.
        if (service_state_success([ "sing-box-current-owned-service-runtime" ]) &&
            !module_success([ LIB_DIR + "/service/lifecycle.uc", "save-selector-state", backup + ".selectors" ])) {
            command_success_from_args([ "rm", "-rf", backup_dir ]);
            log_message("Cannot save manual selector choices; preserving the running subscription runtime", "error");
            return false;
        }
        module_success([ DNS_FAILOVER_UC, "stop-runtime" ]);
        module_success([ PRIORITY_UC, "stop-runtime" ]);
        let transition_timeout = as_string(getenv("FORKOP_SING_BOX_RELOAD_PID_TIMEOUT") || "15");
        if (!service_state_success([ "stop-managed-sing-box-runtime", transition_timeout ])) {
            command_success_from_args([ "rm", "-rf", backup_dir ]);
            module_success([ PRIORITY_UC, "start-runtime" ]);
            module_success([ DNS_FAILOVER_UC, "start-runtime" ]);
            log_message("Refusing subscription runtime update: the previous sing-box runtime did not stop safely", "error");
            return false;
        }
        if (!singbox_runtime_success([ "init-config", "0", "1", "1" ])) {
            if (subscription_restore_runtime(backup, sing_box_config_path, transition_timeout))
                command_success_from_args([ "rm", "-rf", backup_dir ]);
            log_message("Failed to rebuild sing-box after subscription update", "error");
            return false;
        }
        if (!service_state_success([
            "start-managed-sing-box-runtime",
            transition_timeout
        ])) {
            if (subscription_restore_runtime(backup, sing_box_config_path, transition_timeout))
                command_success_from_args([ "rm", "-rf", backup_dir ]);
            return false;
        }
        if (!service_state_success([
            "wait-managed-sing-box-config-listeners", sing_box_config_path,
            as_string(getenv("FORKOP_SING_BOX_READY_TIMEOUT") || "90")
        ])) {
            log_message("Updated subscription runtime did not open its configured listeners", "error");
            if (subscription_restore_runtime(backup, sing_box_config_path, transition_timeout))
                command_success_from_args([ "rm", "-rf", backup_dir ]);
            return false;
        }
        subscription_restore_selectors(backup);
        command_success_from_args([ "rm", "-rf", backup_dir ]);
        if (!module_success([ PRIORITY_UC, "start-runtime" ])) {
            log_message("Failed to restart Priority runtime after subscription update", "error");
            return false;
        }
        if (!module_success([ DNS_FAILOVER_UC, "start-runtime" ])) {
            log_message("Failed to restart DNS failover runtime after subscription update", "error");
            return false;
        }
    }
    if (!write_current_reload_state_clean())
        return false;

    let proxy_signature_after = current_proxy_outbounds_signature(sing_box_config_path);
    let final_proxy_set_changed = proxy_signature_after != "" && proxy_signature_after != proxy_signature_before;
    if (final_proxy_set_changed) {
        if (schedule_automatic_latency_test(proxy_signature_after))
            subscription_outbounds_changed = true;
        else
            log_message("The proxy set changed, but the persistent automatic latency pending marker could not be written", "warn");
    }
    else {
        log_message("Subscription data was refreshed, but the final usable proxy set is unchanged; automatic latency test was not scheduled", "info");
    }

    if (failed > 0)
        log_message("Subscription update applied for changed rules; failed rules kept their previous cache", "info");
    else
        log_message("Subscription update completed", "info");
    return true;
}

function subscription_update_common(force, target_section, target_source_index) {
    if (!subscription_cache_success([ "ensure-runtime-dirs" ]))
        exit(1);

    force = !!force;
    if (!acquire_runtime_lock(SUBSCRIPTION_UPDATE_LOCK_DIR, force)) {
        log_message("Subscription update is already running", "info");
        if (force)
            mark_pending_reload("subscription_update_busy");
        return force ? 1 : 0;
    }

    if (!acquire_runtime_lock(RELOAD_LOCK_DIR, force)) {
        release_runtime_lock(SUBSCRIPTION_UPDATE_LOCK_DIR);
        log_message("Forkop reload is already running; skipping subscription update", "info");
        if (force)
            mark_pending_reload("reload_busy");
        return force ? 1 : 0;
    }

    let ok = subscription_update_common_locked(force, target_section, target_source_index);
    subscription_record_result(ok, target_section);
    release_runtime_lock(RELOAD_LOCK_DIR);
    release_runtime_lock(SUBSCRIPTION_UPDATE_LOCK_DIR);
    run_pending_reload_if_requested();
    if (ok && subscription_outbounds_changed)
        module_background([ DIAGNOSTICS_UC, "automatic-latency-test", "new" ]);
    return ok ? 0 : 1;
}

// Refresh subscription cache data without reloading sing-box. Used only by
// the explicit LuCI manual-restart workflow, which performs one full runtime
// restart after all data families have completed their own atomic updates.
function subscription_prepare_only(target_section, target_source_index) {
    if (!subscription_cache_success([ "ensure-runtime-dirs" ]))
        exit(1);

    if (!acquire_runtime_lock(SUBSCRIPTION_UPDATE_LOCK_DIR, true)) {
        log_message("Subscription update is already running; manual restart preparation was not started", "warn");
        exit(1);
    }
    let owns_reload_lock = as_string(getenv("FORKOP_MANUAL_RESTART_LOCK_HELD") || "0") != "1";
    if (owns_reload_lock && !acquire_runtime_lock(RELOAD_LOCK_DIR, true)) {
        release_runtime_lock(SUBSCRIPTION_UPDATE_LOCK_DIR);
        log_message("Forkop reload is already running; manual restart preparation was not started", "warn");
        exit(1);
    }

    let prepared = subscription_prepare_cache_request(true, target_section, target_source_index);
    if (owns_reload_lock)
        release_runtime_lock(RELOAD_LOCK_DIR);
    release_runtime_lock(SUBSCRIPTION_UPDATE_LOCK_DIR);
    if (!prepared.ok)
        exit(1);

    log_message(prepared.updated > 0 ?
        "Subscription data was prepared for manual restart" :
        "Subscription data was checked for manual restart; no changes detected", "info");
    exit(0);
}

function subscription_update_if_due() {
    log_message("Starting due subscription update", "info");
    exit(subscription_update_common(false, "", ""));
}

function subscription_update(target_section, target_source_index) {
    if (as_string(target_section) != "")
        log_message("Starting subscription update for rule '" + as_string(target_section) + "'", "info");
    else
        log_message("Starting subscription update", "info");
    exit(subscription_update_common(true, target_section, target_source_index));
}

function fixture_section_list(data, type_name) {
    type_name = as_string(type_name || "section");
    let value = object_or_empty(data)[type_name];
    if (type(value) == "array")
        return value;
    if (type(value) == "object")
        return [ value ];

    let plural = object_or_empty(data)[type_name + "s"];
    return type(plural) == "array" ? plural : [];
}

function fixture_section_by_name(data, target_name) {
    target_name = as_string(target_name);
    for (let section in fixture_section_list(data))
        if (section_name(section) == target_name)
            return section;
    return {};
}

function uci_refresh_cron(bin, list_marker, subscription_marker, component_marker) {
    let settings = uci_settings();
    if (settings_component_update_check_interval(settings) == "")
        clear_component_update_check_cache();
    refresh_cron_from_sources(
        settings,
        uci_sections("section"),
        bin,
        list_marker,
        subscription_marker,
        component_marker
    );
}

function fixture_list_update_due_status(path, timestamp_path, now) {
    let data = object_or_empty(read_json_file(path));
    connections.set_item_sections_from_data(data);
    list_update_due_status(object_or_empty(data.settings), timestamp_path, now);
}

function fixture_subscription_update_section_due_status(path, section_name_value, timestamp_path, now) {
    let data = object_or_empty(read_json_file(path));
    connections.set_item_sections_from_data(data);
    subscription_update_section_due_status(fixture_section_by_name(data, section_name_value), timestamp_path, now);
}

let mode = ARGV[0] || "";

if (mode == "json-length")
    json_length(ARGV[1]);
else if (mode == "refresh-cron-from-uci")
    uci_refresh_cron(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "remove-cron-jobs")
    remove_cron_jobs(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "list-update")
    list_update();
else if (mode == "prepare-list-change")
    list_update(true);
else if (mode == "snapshot-list-files") {
    begin_list_ruleset_snapshot();
    exit(list_ruleset_snapshot_dir != "" ? 0 : 1);
}
else if (mode == "list-update-if-due")
    list_update_if_due();
else if (mode == "list-update-after-start")
    list_update_after_start();
else if (mode == "finish-list-update-fixture")
    finish_list_update(int(ARGV[1]), ARGV[2] == "1", ARGV[3] == null ? null : ARGV[3] == "1");
else if (mode == "safe-remote-source-identity")
    print(safe_remote_source_identity(ARGV[1], ARGV[2]), "\n");
else if (mode == "restore-list-cache")
    exit(restore_persistent_list_cache() ? 0 : 1);
else if (mode == "list-cache-valid")
    exit(persistent_list_cache_valid() ? 0 : 1);
else if (mode == "list-cache-capacity")
    exit(list_cache_has_capacity(int(ARGV[1]), false) ? 0 : 1);
else if (mode == "runtime-list-cache-active")
    exit(runtime_list_cache_active() ? 0 : 1);
else if (mode == "commit-runtime-list-generation")
    exit(commit_runtime_list_generation(current_list_update_signature()) ? 0 : 1);
else if (mode == "schedule-automatic-latency-test")
    exit(schedule_automatic_latency_test(ARGV[1]) ? 0 : 1);
else if (mode == "persist-list-cache")
    exit(persist_list_cache(int(ARGV[1])) ? 0 : 1);
else if (mode == "download-list-file")
    exit(download_to_file_network(ARGV[1], ARGV[2], ARGV[3]) ? 0 : 1);
else if (mode == "apply-list-cache")
    exit(apply_persistent_list_cache() ? 0 : 1);
else if (mode == "invalidate-list-cache")
    exit(invalidate_persistent_list_cache(ARGV[1] == "preserve-runtime") ? 0 : 1);
else if (mode == "stop-list-update")
    stop_list_update();
else if (mode == "list-update-due-status-fixture")
    fixture_list_update_due_status(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "subscription-update-section-due-status-fixture")
    fixture_subscription_update_section_due_status(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "file-first-line")
    file_first_line(ARGV[1]);
else if (mode == "stdin-first-ipv4-line")
    stdin_first_ipv4_line();
else if (mode == "subscription-update-worker")
    subscription_update_worker(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "subscription-update")
    subscription_update(ARGV[1], ARGV[2]);
else if (mode == "subscription-prepare-only")
    subscription_prepare_only(ARGV[1], ARGV[2]);
else if (mode == "subscription-update-if-due")
    subscription_update_if_due();
else if (mode == "subscription-update-async")
    subscription_update_async(ARGV[1], ARGV[2]);
else if (mode == "subscription-update-status")
    subscription_update_status(ARGV[1]);
else if (mode == "component-action-worker")
    component_action_worker(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]);
else if (mode == "component-action-async")
    component_action_async(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "component-action-status")
    component_action_status(ARGV[1]);
else if (mode == "component-updates-if-due")
    component_updates_if_due();
else if (mode == "component-update-check-cache")
    component_update_check_cache();
else {
    warn("Usage: components/updates.uc <operation> ...\n");
    exit(1);
}
