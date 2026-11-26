#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let duration = require("core.duration");
let constants = require("core.constants");
let uci_core = require("core.uci");
let connections = require("config.connections");
let subscription_share_link = require("subscription.share_link");
let filter_identity = require("subscription.filter_identity");
let filter_selection = require("subscription.filter_selection");
let source_cache = require("subscription.source_cache");
let core_ip = require("core.ip");
let core_url = require("core.url");
let xrust = require("xrust.binary");
let xrust_tags = require("xrust.constants");
let rulesets = require("xrust.rulesets");
let locks = require("core.locks");
let bootstrap_dns = require("dns.bootstrap");

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const TMP_SING_BOX_FOLDER = getenv("TMP_SING_BOX_FOLDER") || "/tmp/xrust";
const TMP_RULESET_FOLDER = getenv("TMP_RULESET_FOLDER") || TMP_SING_BOX_FOLDER + "/rulesets";
const TMP_SUBSCRIPTION_FOLDER = getenv("TMP_SUBSCRIPTION_FOLDER") || TMP_SING_BOX_FOLDER + "/subscriptions";
const FORKOP_RUNTIME_STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const FORKOP_SUBSCRIPTION_UPDATE_STATE_DIR = getenv("FORKOP_SUBSCRIPTION_UPDATE_STATE_DIR") || FORKOP_RUNTIME_STATE_DIR + "/subscription-update";
const FORKOP_SUBSCRIPTION_LINKS_DIR = getenv("FORKOP_SUBSCRIPTION_LINKS_DIR") || FORKOP_RUNTIME_STATE_DIR + "/subscription-links";
const FORKOP_SUBSCRIPTION_METADATA_DIR = getenv("FORKOP_SUBSCRIPTION_METADATA_DIR") || FORKOP_RUNTIME_STATE_DIR + "/subscription-metadata";
const FORKOP_OUTBOUND_METADATA_DIR = getenv("FORKOP_OUTBOUND_METADATA_DIR") || FORKOP_RUNTIME_STATE_DIR + "/outbound-metadata";
const FORKOP_SECTION_CACHE_DIR = getenv("FORKOP_SECTION_CACHE_DIR") || FORKOP_RUNTIME_STATE_DIR + "/section-cache";
const FORKOP_RUNTIME_CACHE_FORMAT_FILE = getenv("FORKOP_RUNTIME_CACHE_FORMAT_FILE") || FORKOP_RUNTIME_STATE_DIR + "/cache-format";
const FORKOP_RUNTIME_CACHE_FORMAT = getenv("FORKOP_RUNTIME_CACHE_FORMAT") || "12";
const FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR = getenv("FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR") || "/etc/forkop/subscription-cache";
const FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE = getenv("FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE") || FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR + "/cache-format";
const FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT = getenv("FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT") || "9";
const FORKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE = getenv("FORKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE") || FORKOP_RUNTIME_STATE_DIR + "/subscription-bootstrap-retry.pid";
const FORKOP_SUBSCRIPTION_UPDATE_LOCK_DIR = getenv("FORKOP_SUBSCRIPTION_UPDATE_LOCK_DIR") || FORKOP_RUNTIME_STATE_DIR + "/subscription-update.lock";
const FORKOP_PENDING_RELOAD_FILE = getenv("FORKOP_PENDING_RELOAD_FILE") || FORKOP_RUNTIME_STATE_DIR + "/reload.pending";
const RELOAD_LOCK_DIR = getenv("FORKOP_RELOAD_LOCK_DIR") || "/var/run/forkop.reload.lock";
const FORKOP_SERVICE_INIT = getenv("FORKOP_SERVICE_INIT") || "/etc/init.d/forkop";
const SB_SERVICE_MIXED_INBOUND_ADDRESS = getenv("SB_SERVICE_MIXED_INBOUND_ADDRESS") || "127.0.0.1";
const SUBSCRIPTION_DOWNLOAD_MAX_BYTES = 16 * 1024 * 1024;
const SUBSCRIPTION_PREVIEW_MAX_BYTES = 4 * 1024 * 1024;
const SUBSCRIPTION_ATTEMPT_SECONDS = 20;
const SUBSCRIPTION_DOWNLOAD_SECONDS = 60;
const SUBSCRIPTION_BOOTSTRAP_SECONDS = 5;
const SUBSCRIPTION_UNUSABLE_RESPONSE = 2;
const SUBSCRIPTION_UPDATE_ROLLBACK_DIR = TMP_SUBSCRIPTION_FOLDER + "/.update-rollback";
let guard_subscription_source_update = false;
let record_subscription_update_timestamps = true;
let direct_fetch_dir = "";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function read_json(path) {
    if (path == null || path == "" || path == "-")
        return null;

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

function write_file(path, value) {
    return common.write_private_file(path, value) != null;
}

function write_json(path, value) {
    return write_file(path, sprintf("%J", value) + "\n");
}

function write_stdout_json(value) {
    print(sprintf("%J", value), "\n");
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

function whitespace_values(value) {
    let result = [];
    for (let item in split(trim(as_string(value)), /[ \t\r\n]+/))
        if (item != "")
            push(result, item);
    return result;
}

function state_list_contains(list, value) {
    value = as_string(value);
    if (value == "")
        return false;

    for (let item in whitespace_values(list))
        if (item == value)
            return true;

    return false;
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
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

function bool_value(value, fallback) {
    if (value == null)
        return !!fallback;

    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function bool_option(section, key, fallback) {
    return bool_value(object_or_empty(section)[key], fallback);
}

function unsigned_number(value) {
    value = as_string(value);
    if (value == "" || match(value, /[^0-9]/) != null)
        return null;
    return int(value);
}

function duration_to_seconds_value(value) {
    return duration.round_seconds(value);
}

function update_due_status(now_value, last_run_value, interval_value) {
    let now = unsigned_number(now_value);
    let interval = unsigned_number(interval_value);

    if (now == null || interval == null || interval <= 0)
        return 2;

    let last_run = duration.schedule_timestamp(now, unsigned_number(last_run_value));
    if (last_run == null)
        last_run = 0;

    // Hourly cron checks can precede the previous successful download's
    // completion by a few seconds. Do not turn that jitter into a whole
    // extra scheduling period. Keep short intervals exact and never use
    // the allowance to hide a backwards wall-clock jump.
    let allowance = interval >= 3600 ? 60 : 0;
    if (last_run > 0 && (now < last_run || now - last_run < interval - allowance))
        return 1;

    return 0;
}

function cache_section_is_safe(section) {
    section = as_string(section);
    return section != "" && index(section, "/") < 0 && index(section, "..") < 0;
}

function append_word_once(words, value) {
    words = trim(as_string(words));
    value = as_string(value);

    if (value == "" || state_list_contains(words, value))
        return words;

    return words + (words != "" ? " " : "") + value;
}

function section_name(section) {
    return as_string(object_or_empty(section)[".name"]);
}

function source_id(section, index) {
    return as_string(section) + "-subscription-" + as_string(index);
}

function subscription_metadata_path(section) {
    section = as_string(section);
    if (!cache_section_is_safe(section))
        return "";
    return FORKOP_SUBSCRIPTION_METADATA_DIR + "/" + section + ".json";
}

function outbound_metadata_path(section) {
    section = as_string(section);
    if (!cache_section_is_safe(section))
        return "";
    return FORKOP_OUTBOUND_METADATA_DIR + "/" + section + ".json";
}

function section_has_subscription_urls(section) {
    return length(connections.subscription_urls(section)) > 0;
}

function section_is_subscription_proxy(section) {
    return bool_option(section, "enabled", true) &&
        connections.is_connections_action(option(section, "action", "")) &&
        section_has_subscription_urls(section);
}

function subscription_source_count(section) {
    return length(connections.subscription_urls(section));
}

function cache_keep_sets(sections) {
    let keep = {
        sections: "",
        sources: "",
        all: ""
    };

    for (let section in sections) {
        section = object_or_empty(section);
        let name = section_name(section);
        if (!cache_section_is_safe(name))
            continue;

        keep.sections = append_word_once(keep.sections, name);
        keep.all = append_word_once(keep.all, name);

        let count = subscription_source_count(section);
        for (let i = 1; i <= count; i++) {
            let source = source_id(name, i);
            if (!cache_section_is_safe(source))
                continue;

            keep.sources = append_word_once(keep.sources, source);
            keep.all = append_word_once(keep.all, source);
        }
    }

    return keep;
}

function runtime_cache_missing(sections, section_cache_dir) {
    section_cache_dir = as_string(section_cache_dir);

    for (let section in sections) {
        section = object_or_empty(section);
        let name = section_name(section);
        if (!section_is_subscription_proxy(section))
            continue;
        if (!cache_section_is_safe(name))
            continue;
        if (fs.stat(section_cache_dir + "/" + name + ".json") == null)
            return true;
    }

    return false;
}

function path_starts_with(path, prefix) {
    path = as_string(path);
    prefix = as_string(prefix);
    if (prefix == "")
        return false;
    return path == prefix || substr(path, 0, length(prefix) + 1) == prefix + "/";
}

function ends_with(value, suffix) {
    value = as_string(value);
    suffix = as_string(suffix);
    return length(value) >= length(suffix) && substr(value, length(value) - length(suffix)) == suffix;
}

function cache_name_from_file(path) {
    let slash = rindex(path, "/");
    let file_name = slash >= 0 ? substr(path, slash + 1) : path;

    if (file_name == "cache-format")
        return "";
    if (ends_with(file_name, ".filter-bindings"))
        return substr(file_name, 0, length(file_name) - 16);
    if (ends_with(file_name, ".metadata.json"))
        return substr(file_name, 0, length(file_name) - 14);
    if (ends_with(file_name, ".json"))
        return substr(file_name, 0, length(file_name) - 5);
    if (ends_with(file_name, ".url"))
        return substr(file_name, 0, length(file_name) - 4);
    if (ends_with(file_name, ".user_agent"))
        return substr(file_name, 0, length(file_name) - 11);
    if (ends_with(file_name, ".hwid"))
        return substr(file_name, 0, length(file_name) - 5);

    return "";
}

function keep_names_for_path(path, keep, tmp_dir, persistent_dir, section_cache_dir, links_dir, metadata_dir, outbound_metadata_dir) {
    if (ends_with(path, ".filter-bindings"))
        return keep.sections;
    if (path_starts_with(path, tmp_dir) || path_starts_with(path, persistent_dir))
        return keep.sources;
    if (path_starts_with(path, section_cache_dir))
        return keep.all;
    if (path_starts_with(path, links_dir) || path_starts_with(path, metadata_dir) || path_starts_with(path, outbound_metadata_dir))
        return keep.sections;
    return "";
}

function uci_sections() {
    return uci_core.section_objects(CONFIG_NAME, "section");
}

let forkop_version = as_string(constants.FORKOP_VERSION);
let incy_version = match(forkop_version, /^([0-9]+[.][0-9]+[.][0-9]+)(-canary[.][0-9]+)?$/);
const SUBSCRIPTION_USER_AGENT = "INCY/" + (incy_version != null ? incy_version[1] : forkop_version);
// The 2.7.6 compatibility version without the Xrust build suffix.
const SUBSCRIPTION_FALLBACK_USER_AGENT = "sing-box/1.14.2";

function user_agent_supported(user_agent, default_user_agent) {
    user_agent = as_string(user_agent);
    if (user_agent == "")
        return false;
    // Keep working automatic caches across upgrades. New downloads always
    // start with the current INCY profile, regardless of the cached profile.
    return user_agent == default_user_agent ||
        match(user_agent, /^INCY\/[0-9][A-Za-z0-9._+-]*$/) != null ||
        match(user_agent, /^sing-box\/[A-Za-z0-9][A-Za-z0-9._+-]*$/) != null;
}

function user_agent_matches_config(configured_user_agent, cached_user_agent, default_user_agent) {
    configured_user_agent = as_string(configured_user_agent);
    cached_user_agent = as_string(cached_user_agent);

    if (configured_user_agent != "")
        return cached_user_agent == configured_user_agent;

    return user_agent_supported(cached_user_agent, default_user_agent);
}

let parser_module = null;

function subscription_parser() {
    if (parser_module == null)
        parser_module = require("subscription.parser");
    return parser_module;
}

function subscription_cache_is_usable(path) {
    if (fs.stat(as_string(path)) == null)
        return false;
    return subscription_parser().validate_subscription(path);
}

function source_json_path(dir, source_section) {
    return as_string(dir) + "/" + as_string(source_section) + ".json";
}

function source_url_path(dir, source_section) {
    return as_string(dir) + "/" + as_string(source_section) + ".url";
}

function source_user_agent_path(dir, source_section) {
    return as_string(dir) + "/" + as_string(source_section) + ".user_agent";
}

function source_hwid_path(dir, source_section) {
    return as_string(dir) + "/" + as_string(source_section) + ".hwid";
}

function unlink_path(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function file_nonempty(path) {
    let stat = fs.stat(as_string(path));
    return stat != null && stat.size != null && stat.size > 0;
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

function command_args_with(base, extra) {
    let result = [];

    for (let arg in base)
        push(result, arg);
    for (let arg in extra)
        push(result, arg);

    return result;
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

function command_success_from_args(args) {
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function command_status_from_args(args) {
    let status = int(system(command_from_args(args)));
    return status > 255 ? int(status / 256) : status;
}

function run_silent(command) {
    system(command + " >/dev/null 2>&1");
}

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "forkop", "[" + level + "] " + as_string(message) ]);
}

function ensure_dir(path) {
    run_silent("mkdir -p " + shell_quote(path));
}

function chmod_path(path, mode) {
    run_silent("chmod " + shell_quote(mode) + " " + shell_quote(path));
}

function ensure_runtime_dirs() {
    ensure_dir(TMP_SING_BOX_FOLDER);
    ensure_dir(TMP_RULESET_FOLDER);
    ensure_dir(TMP_SUBSCRIPTION_FOLDER);
    ensure_dir(FORKOP_RUNTIME_STATE_DIR);
    ensure_dir(FORKOP_SUBSCRIPTION_UPDATE_STATE_DIR);
    ensure_dir(FORKOP_SUBSCRIPTION_METADATA_DIR);
    ensure_dir(FORKOP_OUTBOUND_METADATA_DIR);
    ensure_dir(FORKOP_SECTION_CACHE_DIR);
    for (let dir in [ TMP_SUBSCRIPTION_FOLDER, FORKOP_SUBSCRIPTION_LINKS_DIR,
                     FORKOP_SUBSCRIPTION_METADATA_DIR, FORKOP_OUTBOUND_METADATA_DIR,
                     FORKOP_SECTION_CACHE_DIR, FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR ]) {
        ensure_dir(dir);
        if (!common.secure_private_dir(dir)) {
            log_message("Cannot secure subscription cache directory " + dir, "error");
            exit(1);
        }
    }
}

function clear_subscription_runtime_cache() {
    run_silent("rm -rf " +
        shell_quote(TMP_SUBSCRIPTION_FOLDER) + " " +
        shell_quote(FORKOP_SUBSCRIPTION_LINKS_DIR) + " " +
        shell_quote(FORKOP_SUBSCRIPTION_METADATA_DIR) + " " +
        shell_quote(FORKOP_OUTBOUND_METADATA_DIR) + " " +
        shell_quote(FORKOP_SECTION_CACHE_DIR));
}

function ensure_runtime_cache_format() {
    ensure_runtime_dirs();

    if (file_first_line_value(FORKOP_RUNTIME_CACHE_FORMAT_FILE) != FORKOP_RUNTIME_CACHE_FORMAT) {
        log_message("Runtime subscription cache format changed; clearing old subscription cache", "info");
        if (file_first_line_value(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE) == FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT) {
            for (let path in fs.glob(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR + "/*.json")) {
                let cached = read_json(path);
                if (type(cached) != "object" || type(cached.outbounds) != "array")
                    continue;
                if (!subscription_parser().repair_cached_subscription_file(path))
                    log_message("Cannot repair cached subscription " + path, "warn");
            }
            subscription_share_link.populate_subscription_dir(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR);
        }
        clear_subscription_runtime_cache();
        ensure_runtime_dirs();
        write_file(FORKOP_RUNTIME_CACHE_FORMAT_FILE, FORKOP_RUNTIME_CACHE_FORMAT + "\n");
    }

    if (file_first_line_value(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE) != FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT) {
        run_silent("rm -rf " + shell_quote(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR));
        ensure_dir(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR);
        chmod_path(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR, "700");
        write_file(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE, FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT + "\n");
        chmod_path(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE, "600");
    }
}

function temp_path(dir, section, kind) {
    ensure_dir(dir);
    let stamp = clock();
    return sprintf("%s/%s.%s.%d.%d", dir, as_string(section), as_string(kind), stamp[0], stamp[1]);
}

function move_file(source, target) {
    return fs.rename(as_string(source), as_string(target));
}

function get_device_model() {
    let model = fs.readfile("/tmp/sysinfo/model");
    model = trim(as_string(model));
    return model != "" ? model : "OpenWrt Router";
}

function generate_hwid() {
    let mac = trim(as_string(fs.readfile("/sys/class/net/eth0/address")));
    if (mac == "")
        mac = trim(as_string(fs.readfile("/sys/class/net/br-lan/address")));

    let input = mac + "-" + get_device_model();
    let output = command_output("printf %s " + shell_quote(input) + " | md5sum");
    let hash = length(whitespace_values(output)) > 0 ? substr(whitespace_values(output)[0], 0, 16) : "";
    return substr(hash, 0, 4) + "-" + substr(hash, 4, 4) + "-" + substr(hash, 8, 4) + "-" + substr(hash, 12, 4);
}

function hwid_matches_config(configured_hwid, cached_hwid) {
    configured_hwid = as_string(configured_hwid);
    cached_hwid = as_string(cached_hwid);

    if (configured_hwid != "")
        return cached_hwid == configured_hwid;

    return cached_hwid == "" || cached_hwid == generate_hwid();
}

function source_cache_profile_matches(parsed, profile, default_user_agent) {
    return profile.url == as_string(parsed.url) &&
        user_agent_matches_config(parsed.user_agent, profile.user_agent, default_user_agent) &&
        hwid_matches_config(parsed.hwid, profile.hwid);
}

function source_cache_matches_profile(record, url, user_agent, hwid, default_user_agent) {
    return source_cache_profile_matches({ url, user_agent, hwid }, record.profile, default_user_agent) &&
        subscription_parser().validate_subscription_value(record.payload);
}

function find_matching_source_cache(dir, source_section, expected_url, expected_user_agent, expected_hwid, default_user_agent) {
    if (!dir)
        return null;
    let record = source_cache.read(dir, source_section);
    if (source_cache_matches_profile(record, expected_url, expected_user_agent, expected_hwid, default_user_agent))
        return record;

    for (let path in fs.glob(dir + "/*.json") || []) {
        let name = substr(path, rindex(path, "/") + 1, -5);
        if (name == source_section || !cache_section_is_safe(name))
            continue;
        record = source_cache.read(dir, name);
        if (source_cache_matches_profile(record, expected_url, expected_user_agent, expected_hwid, default_user_agent))
            return record;
    }
    return null;
}

function restore_persistent_subscription_cache(source_section, tmp_dir, persistent_dir, expected_url, expected_user_agent, expected_hwid, default_user_agent, runtime_snapshot) {
    if (!cache_section_is_safe(source_section))
        return false;

    let runtime = source_cache.read(tmp_dir, source_section, true);
    let runtime_current = source_cache_matches_profile(runtime,
        expected_url, expected_user_agent, expected_hwid, default_user_agent);
    let backup = !runtime_current && runtime_snapshot
        ? find_matching_source_cache(runtime_snapshot, source_section, expected_url,
            expected_user_agent, expected_hwid, default_user_agent)
        : null;
    if (backup == null && (!runtime_current || runtime.profile.metadata == null))
        backup = find_matching_source_cache(persistent_dir, source_section, expected_url,
            expected_user_agent, expected_hwid, default_user_agent);
    let record = runtime_current ? runtime : backup;
    if (record == null)
        return false;
    if (backup != null && record.profile.metadata == null && source_cache.same_profile(record.profile, backup.profile))
        record.profile.metadata = backup.profile.metadata;

    subscription_parser().repair_cached_outbounds(record.payload.outbounds);
    return source_cache.publish(source_json_path(tmp_dir, source_section), record.payload, record.profile, runtime.text);
}

function subscription_source_profile(section, entry) {
    let parsed = subscription_parser().parse_subscription_source_entry(entry);
    if (type(parsed) != "object" || parsed.valid !== true)
        return parsed;

    let user_agent = connections.subscription_user_agent(section, entry);
    if (user_agent != "")
        parsed.user_agent = user_agent;

    parsed.hwid = connections.subscription_hwid(section, entry);
    parsed.download_section = connections.subscription_download_section(section, entry);
    parsed.update_enabled = connections.subscription_update_enabled(section, entry);
    parsed.update_interval = connections.subscription_update_interval(section, entry);
    parsed.show_dashboard_metadata = connections.subscription_dashboard_metadata_enabled(section, entry);
    return parsed;
}

function section_current_usable_cache(section, tmp_dir, persistent_dir, default_user_agent) {
    section = object_or_empty(section);
    let name = section_name(section);
    if (!section_has_subscription_urls(section) || !cache_section_is_safe(name))
        return false;

    let index = 0;
    for (let entry in connections.subscription_urls(section)) {
        index++;
        let parsed = subscription_source_profile(section, entry);
        if (type(parsed) != "object" || parsed.valid !== true)
            continue;

        let source_section = source_id(name, index);
        if (restore_persistent_subscription_cache(
            source_section,
            tmp_dir,
            persistent_dir,
            parsed.url,
            parsed.user_agent,
            parsed.hwid,
            default_user_agent
        ))
            return true;
    }

    return false;
}

function uci_named_section(section_name_value) {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, section_name_value));
}

function find_section(sections, name) {
    name = as_string(name);
    for (let section in sections) {
        section = object_or_empty(section);
        if (section_name(section) == name)
            return section;
    }
    return {};
}

function sing_box_service_running() {
    return command_success_from_args([ "ucode", "-L", LIB_DIR, LIB_DIR + "/service/state.uc", "sing-box-service-running" ]);
}

function section_current_usable_cache_by_name(sections, section, default_user_agent) {
    return section_current_usable_cache(find_section(sections, section), TMP_SUBSCRIPTION_FOLDER, FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR, default_user_agent);
}

function section_has_non_subscription_connection_sources(section) {
    return length(connections.connection_urls(section)) > 0 ||
        length(connections.interfaces(section)) > 0 ||
        length(connections.outbound_jsons(section)) > 0;
}

function subscription_download_target_section_is_ready(sections, download_section, startup_blocked_sections, default_user_agent) {
    download_section = as_string(download_section);
    if (download_section == "" || state_list_contains(startup_blocked_sections, download_section))
        return false;

    let section = find_section(sections, download_section);
    if (!bool_option(section, "enabled", true))
        return false;

    if (!connections.is_connections_action(option(section, "action", "")))
        return false;
    if (section_has_non_subscription_connection_sources(section))
        return true;

    return section_current_usable_cache_by_name(sections, download_section, default_user_agent) ? true : false;
}

function subscription_bootstrap_download_section_is_ready(sections, startup_blocked_sections, default_user_agent) {
    let any_target = false;

    for (let section_name_value in whitespace_values(startup_blocked_sections)) {
        let section = find_section(sections, section_name_value);
        let source_can_retry = false;

        for (let entry in connections.subscription_urls(section)) {
            let parsed = subscription_source_profile(section, entry);
            let download_section = as_string(object_or_empty(parsed).download_section);
            if (download_section == "" || download_section == section_name_value)
                continue;
            any_target = true;

            if (subscription_download_target_section_is_ready(sections, download_section, startup_blocked_sections, default_user_agent)) {
                source_can_retry = true;
                break;
            }
        }

        if (!source_can_retry)
            return false;
    }

    if (!any_target)
        log_message("Subscription startup cannot be deferred because unavailable subscription-only rules have no download-through-section target", "error");

    return any_target;
}

function cache_candidate_paths() {
    let result = [];
    for (let dir in [
        TMP_SUBSCRIPTION_FOLDER,
        FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR,
        FORKOP_SECTION_CACHE_DIR,
        FORKOP_SUBSCRIPTION_LINKS_DIR,
        FORKOP_SUBSCRIPTION_METADATA_DIR,
        FORKOP_OUTBOUND_METADATA_DIR
    ]) {
        let entries = fs.lsdir(dir);
        if (type(entries) != "array")
            continue;
        for (let entry in entries) {
            // Hidden files in the section cache belong to the applied runtime.
            if (substr(entry, 0, 1) == ".")
                continue;
            let path = dir + "/" + as_string(entry);
            let stat = fs.stat(path);
            if (stat != null && stat.type == "file")
                push(result, path);
        }
    }
    return result;
}

function prune_stale_subscription_caches_for_sections(sections) {
    ensure_runtime_dirs();
    let keep = cache_keep_sets(sections);

    for (let path in cache_candidate_paths()) {
        let cache_name = cache_name_from_file(path);
        if (cache_name == "")
            continue;

        let keep_names = keep_names_for_path(
            path,
            keep,
            TMP_SUBSCRIPTION_FOLDER,
            FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR,
            FORKOP_SECTION_CACHE_DIR,
            FORKOP_SUBSCRIPTION_LINKS_DIR,
            FORKOP_SUBSCRIPTION_METADATA_DIR,
            FORKOP_OUTBOUND_METADATA_DIR
        );
        if (!state_list_contains(keep_names, cache_name))
            unlink_path(path);
    }
}

function write_empty_outbound_metadata() {
    write_stdout_json({
        names: {},
        countries: {}
    });
}

function is_array(value) {
    return type(value) == "array";
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function int_or_zero(value) {
    value = as_string(value);
    if (match(value, /^[0-9]+$/) == null)
        return 0;
    return int(value);
}

function count_label(count, singular, plural) {
    count = int(count || 0);
    return as_string(count) + " " + (count == 1 ? singular : plural);
}

function log_subscription_source_summary(section_name_value, source_index, payload, unchanged) {
    let prefix = "Subscription source " + as_string(source_index) + " for rule '" + as_string(section_name_value) + "'";
    let stats = count_label(length(array_or_empty(payload.outbounds)), "proxy entry", "proxy entries");
    let skipped = int_or_zero(payload.skipped);
    if (skipped > 0)
        stats += ", " + count_label(skipped, "skipped entry", "skipped entries");
    log_message(unchanged ? prefix + " refreshed: runtime proxy entries are unchanged (" + stats + ")" :
        prefix + " imported: " + stats, "info");
}

function object_key_count(value) {
    return type(value) == "object" ? length(keys(value)) : 0;
}

function valid_metadata_object(value) {
    return type(value) == "object" && object_key_count(value) > 1;
}

function json_length(path) {
    let value = read_json(path);
    if (type(value) == "array" || type(value) == "object")
        print(length(value), "\n");
    else
        print("0\n");
}

function safe_section(section) {
    return type(section) == "string" && match(section, /^[A-Za-z0-9_-]+$/);
}

function cache_path(cache_dir, section) {
    return cache_dir + "/" + section + ".json";
}

function load_cache(cache_dir, section) {
    return object_or_empty(read_json(cache_path(cache_dir, section)));
}

function normalize_cache(cache, section, format_version) {
    cache.version = int(format_version || 0);
    cache.section = as_string(section);
    cache.links = object_or_empty(cache.links);
    cache.outboundMetadata = object_or_empty(cache.outboundMetadata);
    cache.outboundMetadata.names = object_or_empty(cache.outboundMetadata.names);
    cache.outboundMetadata.countries = object_or_empty(cache.outboundMetadata.countries);
    cache.servers = object_or_empty(cache.servers);
    cache.urltestCandidateTags = array_or_empty(cache.urltestCandidateTags);
    cache.urltestGroups = object_or_empty(cache.urltestGroups);
    cache.priorityGroups = object_or_empty(cache.priorityGroups);
    cache.subscriptionMetadata = array_or_empty(cache.subscriptionMetadata);
    return cache;
}

function save_cache(cache_dir, section, format_version, cache) {
    ensure_dir(cache_dir);
    if (!common.secure_private_dir(cache_dir))
        exit(1);
    cache = normalize_cache(cache, section, format_version);
    let path = cache_path(cache_dir, section);
    let stamp = clock();
    let tmp_path = sprintf("%s.%d.%d.tmp", path, stamp[0], stamp[1]);

    if (!write_json(tmp_path, cache))
        exit(1);
    if (!fs.rename(tmp_path, path)) {
        fs.unlink(tmp_path);
        exit(1);
    }
}

function write_outbound_metadata(cache_dir, format_version, section, names_path, countries_path, servers_path) {
    let cache = load_cache(cache_dir, section);
    cache.outboundMetadata = {
        names: object_or_empty(read_json(names_path)),
        countries: object_or_empty(read_json(countries_path))
    };
    cache.servers = object_or_empty(read_json(servers_path));
    save_cache(cache_dir, section, format_version, cache);
}

function metadata_array_from_file(metadata_path) {
    let metadata = read_json(metadata_path);
    let result = [];

    if (is_array(metadata)) {
        for (let item in metadata) {
            if (valid_metadata_object(item))
                push(result, item);
        }
    }
    else if (valid_metadata_object(metadata)) {
        push(result, metadata);
    }

    return result;
}

function write_subscription_metadata(cache_dir, format_version, section, metadata_path) {
    let cache = load_cache(cache_dir, section);
    cache.subscriptionMetadata = metadata_array_from_file(metadata_path);
    save_cache(cache_dir, section, format_version, cache);
}

function read_metadata_items_from_cache(cache_dir, section, legacy_path) {
    let cache = load_cache(cache_dir, section);
    let metadata = cache.subscriptionMetadata;

    if (type(metadata) != "array")
        metadata = read_json(legacy_path);

    let result = [];
    if (is_array(metadata)) {
        for (let item in metadata) {
            if (valid_metadata_object(item))
                push(result, item);
        }
    }
    else if (valid_metadata_object(metadata)) {
        push(result, metadata);
    }

    return result;
}

function metadata_source_index(item) {
    if (type(item) != "object")
        return null;
    let value = item.sourceIndex != null ? item.sourceIndex : item.source_index;
    if (value == null || as_string(value) == "")
        return null;
    return int(value);
}

function metadata_source_section(item) {
    if (type(item) != "object")
        return "";
    return as_string(item.sourceSection != null ? item.sourceSection : item.source_section);
}

function metadata_items_have_source_markers(items) {
    for (let item in items) {
        if (metadata_source_index(item) != null || metadata_source_section(item) != "")
            return true;
    }
    return false;
}

function metadata_matches_source(item, source_index, source_section, has_source_markers) {
    if (!has_source_markers)
        return false;

    let item_section = metadata_source_section(item);
    let item_index = metadata_source_index(item);
    return (item_section != "" && item_section == source_section) ||
        (item_section == "" && item_index == source_index);
}

function attach_source_metadata(item, source_index, source_section) {
    if (type(item) != "object")
        item = {};
    item.sourceIndex = source_index;
    item.sourceSection = as_string(source_section);
    return item;
}

function append_source_metadata(array_path, metadata, source_index, source_section) {
    if (array_path == null || array_path == "")
        return;

    let array = array_or_empty(read_json(array_path));
    source_index = int(source_index || 0);
    source_section = as_string(source_section);

    if (valid_metadata_object(metadata)) {
        push(array, attach_source_metadata(metadata, source_index, source_section));
        write_json(array_path, array);
    }
}

function append_metadata_file(array_path, metadata_path, source_index, source_section) {
    if (array_path != null && array_path != "")
        append_source_metadata(array_path, read_json(metadata_path), source_index, source_section);
}

function append_cached_metadata(array_path, cache_dir, section, legacy_path, source_index, source_section) {
    if (array_path == null || array_path == "")
        return;

    let array = array_or_empty(read_json(array_path));
    let items = read_metadata_items_from_cache(cache_dir, section, legacy_path);
    source_index = int(source_index || 0);
    source_section = as_string(source_section);

    let has_source_markers = metadata_items_have_source_markers(items);
    let selected = null;
    if (has_source_markers) {
        for (let item in items) {
            if (metadata_matches_source(item, source_index, source_section, true)) {
                selected = item;
                break;
            }
        }
    }
    else if (source_index > 0 && source_index <= length(items)) {
        selected = items[source_index - 1];
    }

    if (valid_metadata_object(selected)) {
        push(array, attach_source_metadata(selected, source_index, source_section));
        write_json(array_path, array);
    }
}

function write_source_metadata(cache_dir, format_version, section, source_index, source_section, metadata_path, legacy_path) {
    let cache = load_cache(cache_dir, section);
    let items = read_metadata_items_from_cache(cache_dir, section, legacy_path);
    let kept = [];
    let has_source_markers = metadata_items_have_source_markers(items);
    source_index = int(source_index || 0);
    source_section = as_string(source_section);

    for (let index, item in items) {
        let keep = has_source_markers ?
            !metadata_matches_source(item, source_index, source_section, true) :
            (index + 1) != source_index;
        if (keep && valid_metadata_object(item))
            push(kept, item);
    }

    let metadata = read_json(metadata_path);
    if (valid_metadata_object(metadata))
        push(kept, attach_source_metadata(metadata, source_index, source_section));

    sort(kept, function(first, second) {
        let first_index = metadata_source_index(first) || 999999;
        let second_index = metadata_source_index(second) || 999999;
        return first_index == second_index ? 0 : (first_index < second_index ? -1 : 1);
    });

    cache.subscriptionMetadata = kept;
    save_cache(cache_dir, section, format_version, cache);
}

function get_outbound_metadata(cache_dir, section, legacy_path) {
    let cache = load_cache(cache_dir, section);
    let metadata = cache.outboundMetadata;
    if (type(metadata) != "object")
        metadata = read_json(legacy_path);
    metadata = object_or_empty(metadata);
    let names = object_or_empty(metadata.names);
    let countries = object_or_empty(metadata.countries);
    let candidate_tags = array_or_empty(cache.urltestCandidateTags);
    let groups = object_or_empty(cache.urltestGroups);
    let priority_groups = object_or_empty(cache.priorityGroups);
    let result = {
        names: {},
        countries: {}
    };

    if (length(candidate_tags) > 0) {
        for (let tag in candidate_tags) {
            tag = as_string(tag);
            if (tag == "")
                continue;
            if (names[tag] != null)
                result.names[tag] = names[tag];
            if (countries[tag] != null)
                result.countries[tag] = countries[tag];
        }
    }
    else {
        for (let tag, name in names) {
            if (!groups[tag] && !priority_groups[tag])
                result.names[tag] = name;
        }
        for (let tag, country in countries) {
            if (!groups[tag] && !priority_groups[tag])
                result.countries[tag] = country;
        }
    }

    write_stdout_json(result);
}

function get_subscription_metadata(cache_dir, section, legacy_path) {
    let items = read_metadata_items_from_cache(cache_dir, section, legacy_path);
    if (length(items) > 0)
        write_stdout_json(items);
    else
        print("{}\n");
}

function runtime_metadata_path(source_section) {
    return TMP_SUBSCRIPTION_FOLDER + "/" + as_string(source_section) + ".metadata.json";
}

function cached_source_metadata(source_section, runtime) {
    runtime = runtime ?? source_cache.read(TMP_SUBSCRIPTION_FOLDER, source_section);
    if (runtime.profile.metadata != null)
        return runtime.profile.metadata;
    let persistent = source_cache.read(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR, source_section);
    return source_cache.same_profile(runtime.profile, persistent.profile) ? persistent.profile.metadata : null;
}

function remove_subscription_source_runtime_cache(source_section) {
    if (!cache_section_is_safe(source_section))
        return;

    unlink_path(source_json_path(TMP_SUBSCRIPTION_FOLDER, source_section));
    unlink_path(source_url_path(TMP_SUBSCRIPTION_FOLDER, source_section));
    unlink_path(source_user_agent_path(TMP_SUBSCRIPTION_FOLDER, source_section));
    unlink_path(source_hwid_path(TMP_SUBSCRIPTION_FOLDER, source_section));
    unlink_path(runtime_metadata_path(source_section));
}

function persist_subscription_cache(source_section, record) {
    if (!cache_section_is_safe(source_section) || !subscription_parser().validate_subscription_value(record.payload))
        return false;

    ensure_dir(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR);
    chmod_path(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR, "700");
    let persistent_json = source_json_path(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR, source_section);
    return source_cache.publish(persistent_json, record.payload, record.profile);
}

function append_persistent_source_metadata(array_path, source_index, source_section) {
    let metadata = cached_source_metadata(source_section);
    if (!valid_metadata_object(metadata))
        return false;

    append_source_metadata(array_path, metadata, source_index, source_section);
    return true;
}

function append_available_cached_metadata(array_path, section, source_index, source_section) {
    if (array_path == null || array_path == "")
        return false;

    let before = length(array_or_empty(read_json(array_path)));
    append_persistent_source_metadata(array_path, source_index, source_section) ||
        append_cached_metadata(array_path, FORKOP_SECTION_CACHE_DIR, section, FORKOP_SUBSCRIPTION_METADATA_DIR + "/" + section + ".json", source_index, source_section);
    return length(array_or_empty(read_json(array_path))) > before;
}

function get_kernel_version() {
    return trim(command_output_from_args([ "uname", "-r" ]));
}

function get_subscription_hwid(custom_hwid) {
    custom_hwid = as_string(custom_hwid);
    return custom_hwid != "" ? custom_hwid : generate_hwid();
}

function subscription_url_host(url) {
    return core_url.host(url);
}

function subscription_url_port(url) {
    let port = core_url.port(url);
    if (port != "")
        return port;
    return core_url.scheme(url) == "http" ? "80" : "443";
}

function bootstrap_resolve_subscription_host(url, deadline) {
    let host = subscription_url_host(url);
    if (host == "" || core_ip.valid_ip(host))
        return null;

    let settings = bootstrap_dns.configured();
    for (let server in settings.servers) {
        let remaining = deadline - int(clock(true)[0]);
        if (remaining <= 0)
            break;
        log_message("Resolving subscription host via bootstrap DNS", "info");
        let address = bootstrap_dns.lookup(host, server, settings.protocol, min(remaining, SUBSCRIPTION_BOOTSTRAP_SECONDS));
        let server_host = core_url.host(server);
        if (address != "") {
            log_message("Bootstrap DNS " + server_host + " resolved " + host + " -> " + address, "info");
            return { host, port: subscription_url_port(url), address };
        }
        log_message("Bootstrap DNS " + server_host + " failed", "warn");
    }
    return null;
}

function curl_resolve_address(address) {
    return core_ip.ip_family(address) == 6 ? "[" + address + "]" : address;
}

function subscription_curl_args(url, filepath, http_proxy_address, headers_filepath, effective_hwid, resolve, options) {
    options = object_or_empty(options);
    let args = [
        "curl", "-f", "-sS",
        "--location", "--max-redirs", "5",
        "--proto", "=http,https",
        "--proto-redir", core_url.scheme(url) == "https" ? "=https" : "=http,https",
        "--connect-timeout", "15",
        "--speed-time", "15",
        "--speed-limit", "1",
        "--max-time", as_string(options.timeout),
        "--max-filesize", as_string(options.max_bytes)
    ];

    if (http_proxy_address != "") {
        push(args, "-x");
        push(args, "http://" + http_proxy_address);
        push(args, "--noproxy", "");
    }
    if (headers_filepath != "") {
        push(args, "-D");
        push(args, headers_filepath);
    }
    if (resolve != null) {
        push(args, "--resolve");
        push(args, resolve.host + ":" + resolve.port + ":" + curl_resolve_address(resolve.address));
    }

    push(args, "-o");
    push(args, filepath);
    let headers = [
        "User-Agent: " + (options.user_agent || SUBSCRIPTION_USER_AGENT),
        "X-HWID: " + get_subscription_hwid(effective_hwid),
        "X-Device-OS: OpenWrt Linux",
        "X-Device-Model: " + get_device_model(),
        "X-Ver-OS: " + get_kernel_version(),
        "Accept-Language: ru-RU,en,*",
        "X-Device-Locale: EN"
    ];
    if (options.config_path) {
        let config = "url = " + sprintf("%J", url) + "\n";
        for (let header in headers)
            config += "header = " + sprintf("%J", header) + "\n";
        if (!write_file(options.config_path, config))
            return null;
        push(args, "--config", options.config_path);
    }
    else {
        for (let header in headers) {
            push(args, "-H");
            push(args, header);
        }
        push(args, url);
    }
    return args;
}

function run_subscription_curl(args, max_bytes) {
    if (args == null)
        return 1;
    // BusyBox sh counts 512-byte blocks. Keep streaming file output bounded
    // even with older curl versions and an unknown response length.
    let status = int(system("umask 077; ulimit -f " + int(max_bytes / 512) +
        " && " + command_from_args(args) + " 2>/dev/null"));
    return status > 255 ? int(status / 256) : status;
}

function subscription_http_allows_profile_retry(headers_path) {
    let headers = fs.open(headers_path, "r");
    if (headers == null)
        return false;
    let status = 0;
    let line;
    while ((line = headers.read("line")) != null) {
        let parsed = match(line, /^HTTP\/[^ ]+ ([0-9]{3})[[:space:]]/);
        if (parsed != null)
            status = int(parsed[1]);
    }
    headers.close();
    // A proxy authentication challenge, timeout or rate limit is handled by
    // the normal download retry policy.
    return status >= 400 && status < 500 && status != 407 && status != 408 && status != 429;
}

function download_subscription(url, filepath, http_proxy_address, headers_filepath, effective_hwid, options) {
    options = object_or_empty(options);
    options.max_bytes = options.preview ? SUBSCRIPTION_PREVIEW_MAX_BYTES : SUBSCRIPTION_DOWNLOAD_MAX_BYTES;
    // The retries, pauses and bootstrap fallback share this per-source budget.
    let deadline = options.deadline || int(clock(true)[0]) + SUBSCRIPTION_DOWNLOAD_SECONDS;
    let retries = options.preview || options.user_agent == SUBSCRIPTION_FALLBACK_USER_AGENT ? 1 : 3;
    let wait_seconds = 2;
    let stamp = clock();
    let suffix = sprintf(".part.%d.%d", stamp[0], stamp[1]);
    let tmpfile = filepath + suffix;
    let headers_tmpfile = headers_filepath != "" ? headers_filepath + suffix : "";
    let resolution_failed = false;

    unlink_path(tmpfile);
    if (headers_tmpfile != "")
        unlink_path(headers_tmpfile);

    for (let attempt = 1; attempt <= retries; attempt++) {
        let remaining = deadline - int(clock(true)[0]);
        if (remaining <= 0)
            break;
        options.timeout = remaining < SUBSCRIPTION_ATTEMPT_SECONDS ? remaining : SUBSCRIPTION_ATTEMPT_SECONDS;
        let status = run_subscription_curl(subscription_curl_args(
            url, tmpfile, http_proxy_address, headers_tmpfile, effective_hwid, null, options
        ), options.max_bytes);
        if (status == 6) {
            let resolved = bootstrap_resolve_subscription_host(url, deadline);
            remaining = deadline - int(clock(true)[0]);
            if (resolved != null && remaining > 0) {
                options.timeout = remaining < SUBSCRIPTION_ATTEMPT_SECONDS ? remaining : SUBSCRIPTION_ATTEMPT_SECONDS;
                log_message("Downloading subscription using bootstrap-resolved address", "info");
                status = run_subscription_curl(subscription_curl_args(
                    url, tmpfile, http_proxy_address, headers_tmpfile, effective_hwid, resolved, options
                ), options.max_bytes);
            }
        }
        if (status == 0 && file_nonempty(tmpfile)) {
            move_file(tmpfile, filepath);
            if (headers_filepath != "") {
                if (file_nonempty(headers_tmpfile))
                    move_file(headers_tmpfile, headers_filepath);
                else {
                    unlink_path(headers_filepath);
                    unlink_path(headers_tmpfile);
                }
            }
            return 0;
        }

        let unusable_response = status == 0 || (status == 22 && headers_tmpfile != "" &&
            subscription_http_allows_profile_retry(headers_tmpfile));
        unlink_path(tmpfile);
        unlink_path(headers_tmpfile);

        if (unusable_response)
            return SUBSCRIPTION_UNUSABLE_RESPONSE;

        if (status == 5 || status == 6) {
            resolution_failed = true;
            break;
        }

        if (attempt < retries && deadline - int(clock(true)[0]) > wait_seconds)
            system("sleep " + int(wait_seconds));
    }

    unlink_path(tmpfile);
    unlink_path(headers_tmpfile);
    return resolution_failed ? 6 : 1;
}

function subscription_has_proxy_candidates(value) {
    for (let outbound in array_or_empty(value?.outbounds)) {
        if (type(outbound) != "object" || type(outbound.server) != "string" || trim(outbound.server) == "")
            continue;
        // The native Forkop client cannot use provider-only groups, Direct,
        // Block or legacy protocol-only feeds as a subscription by themselves.
        if (outbound.type == "vless" && trim(as_string(outbound.uuid)) != "")
            return true;
        if ((outbound.type == "hysteria2" || outbound.type == "trojan") &&
            trim(as_string(outbound.password)) != "")
            return true;
    }
    return false;
}

function download_normalized_subscription(url, proxy, hwid, files, preview) {
    let options = {
        preview,
        config_path: files.curl,
        deadline: int(clock(true)[0]) + (preview ? SUBSCRIPTION_ATTEMPT_SECONDS : SUBSCRIPTION_DOWNLOAD_SECONDS)
    };
    let parser = subscription_parser();
    let status;
    for (let user_agent in [ SUBSCRIPTION_USER_AGENT, SUBSCRIPTION_FALLBACK_USER_AGENT ]) {
        options.user_agent = user_agent;
        status = download_subscription(url, files.raw, proxy, files.headers, hwid, options);
        if (status == 0) {
            let decoded_gzip = parser.try_decode_gzip_content_file(files.raw);
            let payload = parser.normalize_content_value(files.raw, files.normalized);
            if (subscription_has_proxy_candidates(payload))
                return { status, user_agent, decoded_gzip, payload };
            status = SUBSCRIPTION_UNUSABLE_RESPONSE;
            unlink_path(files.raw);
            unlink_path(files.headers);
            unlink_path(files.normalized);
        }
        if (status != SUBSCRIPTION_UNUSABLE_RESPONSE)
            break;
    }
    return { status };
}

function save_subscription_source_for_rollback(source, path) {
    if (!common.secure_private_dir(SUBSCRIPTION_UPDATE_ROLLBACK_DIR))
        return false;
    let backup = SUBSCRIPTION_UPDATE_ROLLBACK_DIR + "/" + source;
    if (fs.stat(backup + ".json") != null || fs.stat(backup + ".absent") != null)
        return true;
    if (fs.stat(path) == null)
        return write_file(backup + ".absent", "1\n");
    return command_success_from_args([ "ln", path, backup + ".json" ]);
}

function finish_subscription_source_update(commit) {
    if (fs.stat(SUBSCRIPTION_UPDATE_ROLLBACK_DIR) == null)
        return true;
    // Once the runtime has accepted the update, recovery must finish saving it,
    // even if the process died between two sources or flash ran out of space.
    let decision = SUBSCRIPTION_UPDATE_ROLLBACK_DIR + "/.commit";
    if (fs.stat(decision) != null)
        commit = true;
    else if (commit && !write_file(decision, "1\n"))
        return false;
    let restored = true;
    for (let path in fs.glob(SUBSCRIPTION_UPDATE_ROLLBACK_DIR + "/*") || []) {
        let entry = match(fs.basename(path), /^([A-Za-z0-9_-]+)\.(json|absent)$/);
        if (entry == null)
            continue;
        let source = entry[1];
        let target = source_json_path(TMP_SUBSCRIPTION_FOLDER, source);
        if (commit) {
            // A failed or removed source may have no accepted runtime payload
            // when another source in the same batch succeeded.
            if (fs.stat(target) == null)
                continue;
            let record = source_cache.read(TMP_SUBSCRIPTION_FOLDER, source);
            if (!persist_subscription_cache(source, record)) {
                log_message("Failed to persist last working subscription cache for source '" + source + "'", "warn");
                restored = false;
            }
        }
        else if (entry[2] == "json")
            restored = fs.rename(path, target) && restored;
        else if (fs.stat(target) != null)
            restored = fs.unlink(target) && restored;
    }
    if (restored && commit) {
        let timestamps = fs.glob(SUBSCRIPTION_UPDATE_ROLLBACK_DIR + "/*.timestamp") || [];
        if (length(timestamps) && !command_success_from_args([ "mkdir", "-p", FORKOP_SUBSCRIPTION_UPDATE_STATE_DIR ]))
            return false;
        for (let path in timestamps) {
            let target = FORKOP_SUBSCRIPTION_UPDATE_STATE_DIR + "/" + fs.basename(path);
            if (!common.copy_private_file_atomic(path, target))
                restored = false;
        }
    }
    return restored && command_success_from_args([ "rm", "-rf", SUBSCRIPTION_UPDATE_ROLLBACK_DIR ]);
}

function write_source_metadata_output(metadata, metadata_output_path) {
    if (metadata_output_path == null || metadata_output_path == "")
        return;

    if (!valid_metadata_object(metadata) || !write_json(metadata_output_path, metadata))
        unlink_path(metadata_output_path);
}

function subscription_config_is_current(section_name_value, source_index, expected) {
    if (!uci_core.reload(CONFIG_NAME))
        return false;
    connections.reload_item_sections();
    let section = uci_named_section(section_name_value);
    if (!section_is_subscription_proxy(section))
        return false;
    let entry = connections.subscription_urls(section)[source_index - 1];
    let current = entry == null ? null : subscription_source_profile(section, entry);
    return current?.valid === true && current.url == expected.url &&
        current.user_agent == expected.user_agent && current.hwid == expected.hwid &&
        current.download_section == expected.download_section;
}

function get_subscription_download_proxy_address(section_name_value, parsed, phase) {
    let download_section = as_string(object_or_empty(parsed).download_section);
    if (download_section == "")
        return "";

    if (!sing_box_service_running()) {
        if (phase != "startup")
            return null;
        log_message("Subscription source for rule '" + section_name_value + "' is configured to download via rule '" + download_section + "', but Xrust is not running yet; downloading it directly during startup", "warn");
        return "";
    }

    // UCI may already contain a new file path or a different order of proxy
    // sections. Use the listener and its route in the applied core config.
    let config = read_json(file_first_line_value(xrust.APPLIED_CONFIG_PATH_FILE));
    let tag = xrust_tags.inbound_tag("service-subscription-" + download_section);
    for (let inbound in config?.inbounds || []) {
        let port = int(inbound.listen_port);
        if (inbound.tag != tag || inbound.type != "mixed" ||
            inbound.listen != SB_SERVICE_MIXED_INBOUND_ADDRESS || port <= 0 || port > 65535)
            continue;
        for (let rule in config?.route?.rules || [])
            if ((rule.inbound == tag || (type(rule.inbound) == "array" && length(rule.inbound) == 1 &&
                rule.inbound[0] == tag)) && rule.outbound == xrust_tags.outbound_tag(download_section)) {
                let address = inbound.listen + ":" + port;
                log_message("Downloading subscription for rule '" + section_name_value + "' via service proxy " + address, "debug");
                return address;
            }
    }
    return null;
}

// Draft-only download: reuse request profiles, bootstrap DNS, curl and parser
// without changing UCI, persistent caches, links or the running configuration.
function editor_download_source(request_path, prefix) {
    let input = read_json(request_path);
    let source = input?.source;
    let url = source?.url;
    if (type(url) != "string" || length(url) > 8192 ||
        !match(url, /^https?:\/\//) || match(url, /[[:space:]]/))
        return { error: "Invalid subscription URL" };
    let download_section = source.download_via_proxy_enabled == "1" ? as_string(source.download_via_proxy_section) : "";
    if (source.download_via_proxy_enabled == "1" && download_section == "")
        return { error: "Select a subscription download proxy section" };
    // Keep the selected listener's routing stable across both request profiles.
    // Plain direct previews do not need an Xrust runtime lock.
    let proxy_requested = download_section != "";
    let pid = split(fs.readfile("/proc/self/stat") || "", " ")[0];
    if (proxy_requested && !locks.acquire(RELOAD_LOCK_DIR, pid))
        return { error: "Forkop is applying settings; retry the proxy preview after it finishes" };
    let proxy = get_subscription_download_proxy_address(as_string(input.section), { download_section }, "preview");
    let hwid = get_subscription_hwid("");
    let result = proxy == null ? null : download_normalized_subscription(url, proxy, hwid, {
        raw: prefix + ".body", headers: prefix + ".headers", normalized: prefix + ".json", curl: prefix + ".curl"
    }, true);
    if (proxy_requested) {
        locks.release(RELOAD_LOCK_DIR);
        if (fs.stat(FORKOP_PENDING_RELOAD_FILE) != null)
            command_success_from_args([ "ucode", "-L", LIB_DIR, LIB_DIR + "/service/state.uc",
                "run-pending-reload-if-requested", FORKOP_PENDING_RELOAD_FILE, FORKOP_SERVICE_INIT ]);
    }
    if (proxy == null)
        return { error: "Selected proxy section is unavailable in the running configuration; direct download was not attempted" };
    if (result.status == 0)
        return { user_agent: result.user_agent, hwid };
    return { error: "Subscription download failed or returned an invalid response" };
}

function fetch_runtime_source(parsed, proxy, prefix) {
    let files = { raw: prefix + ".body", headers: prefix + ".headers", normalized: prefix + ".json", curl: prefix + ".curl" };
    let hwid = get_subscription_hwid(parsed.hwid);
    let result = download_normalized_subscription(parsed.url, proxy, hwid, files, false);
    result.hwid = hwid;
    if (result.status == 0)
        result.metadata = subscription_parser().extract_ui_metadata(files.headers, files.raw);
    for (let path in [ files.raw, files.headers, files.curl ])
        unlink_path(path);
    return result;
}

function subscription_update_timestamp_path(section_name_value, entry) {
    let name = as_string(section_name_value);
    if (entry != null)
        name += "." + rulesets.hash12(entry);
    return FORKOP_SUBSCRIPTION_UPDATE_STATE_DIR + "/" + name + ".timestamp";
}

function subscription_source_due_result(section, entry, now) {
    if (!connections.subscription_update_enabled(section, entry))
        return 1;
    let interval = connections.subscription_update_interval(section, entry) || "4h";
    let seconds = duration_to_seconds_value(interval);
    if (seconds == null || seconds <= 0) {
        log_message("Invalid subscription_update_interval value for rule '" + section_name(section) + "': " + interval, "error");
        return 2;
    }

    let section_id = section_name(section);
    let previous = file_first_line_value(subscription_update_timestamp_path(section_id, entry));
    if (previous == "")
        previous = file_first_line_value(subscription_update_timestamp_path(section_id));
    return update_due_status(now, previous, seconds);
}

function source_revision(source) {
    let path = source_json_path(TMP_SUBSCRIPTION_FOLDER, source);
    if (fs.stat(path) == null)
        return "";
    // Permissions, hard-link snapshots and rollback can change stat metadata
    // without changing the last accepted response.
    let digest = split(command_output_from_args([ "sha256sum", path ]), " ")[0];
    return match(digest, /^[0-9a-f]{64}$/) != null ? digest : null;
}

// Only private response files are written here. UCI, the active cache, filter
// bindings and the next-check timestamps still change under the reload lock.
function prefetch_direct_sources(dir, force, target_section, target_index) {
    let now = int(clock()[0]);
    if (!write_file(dir + "/.started-at", now + "\n"))
        return false;
    for (let section in uci_sections()) {
        let name = section_name(section);
        if (!cache_section_is_safe(name) || !section_is_subscription_proxy(section) ||
            (target_section && target_section != name))
            continue;
        for (let offset, entry in connections.subscription_urls(section)) {
            let number = offset + 1;
            if ((target_index && number != int(target_index)) ||
                (!force && subscription_source_due_result(section, entry, now) != 0))
                continue;
            let parsed = subscription_source_profile(section, entry);
            if (!parsed?.valid || parsed.download_section ||
                !subscription_config_is_current(name, number, parsed))
                continue;
            let source = source_id(name, number);
            let prefix = dir + "/" + source;
            let revision = source_revision(source);
            if (revision == null)
                return false;
            let result = fetch_runtime_source(parsed, "", prefix);
            delete result.payload; // The normalizer already wrote it to prefix.json.
            result.profile = parsed;
            result.revision = revision;
            if (!write_json(prefix + ".result", result))
                return false;
        }
    }
    return true;
}

function download_subscription_into_cache(section_name_value, parsed, proxy, source_index, cache_section, metadata_output_path, staged) {
    if (proxy == null) {
        log_message("Selected subscription download proxy is unavailable for rule '" + section_name_value + "'", "warn");
        return 1;
    }
    ensure_dir(TMP_SUBSCRIPTION_FOLDER);
    let subscription_json_path = source_json_path(TMP_SUBSCRIPTION_FOLDER, cache_section);
    let previous = source_cache.read(TMP_SUBSCRIPTION_FOLDER, cache_section);
    let parser = subscription_parser();
    let result;
    if (staged) {
        let prefix = direct_fetch_dir + "/" + cache_section;
        result = staged;
        if (result.status == 0) {
            result.payload = read_json(prefix + ".json");
            if (!subscription_has_proxy_candidates(result.payload))
                return 1;
        }
    }
    else {
        let prefix = temp_path(TMP_SUBSCRIPTION_FOLDER, cache_section, "download");
        result = fetch_runtime_source(parsed, proxy, prefix);
        unlink_path(prefix + ".json");
    }

    if (result.status != 0) {
        if (metadata_output_path != "")
            unlink_path(metadata_output_path);
        let reason = result.status == 6 ? "subscription host could not be resolved" :
            result.status == SUBSCRIPTION_UNUSABLE_RESPONSE ?
                "provider rejected the request or returned no valid proxy entries" : "download failed";
        log_message("Subscription for rule '" + section_name_value + "': " + reason, "warn");
        return 1;
    }

    if (result.decoded_gzip)
        log_message("Decoded gzip-compressed subscription body for rule '" + section_name_value + "'", "info");
    // Preserve the applied order if only provider metadata or order changed.
    let unchanged = parser.runtime_outbounds_values_equal(result.payload, previous.payload);
    let payload = previous.payload;
    if (!unchanged) {
        // Keep old selected names attached to the connection across renames.
        payload = filter_identity.inherit_names(previous.payload, result.payload);
        subscription_share_link.populate_subscription_links(payload);
    }
    let profile = { url: parsed.url, user_agent: result.user_agent, hwid: result.hwid, metadata: null };
    let metadata = result.metadata;
    if (valid_metadata_object(metadata))
        profile.metadata = metadata;
    else if (source_cache.same_profile(profile, previous.profile))
        profile.metadata = cached_source_metadata(cache_section, previous);
    else {
        let persistent = source_cache.read(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR, cache_section);
        if (source_cache.same_profile(profile, persistent.profile))
            profile.metadata = persistent.profile.metadata;
    }
    if (!subscription_config_is_current(section_name_value, source_index, parsed)) {
        log_message("Subscription source settings changed while updating rule '" + section_name_value + "'; discarding superseded download", "warn");
        if (metadata_output_path != "")
            unlink_path(metadata_output_path);
        return 4;
    }
    if (!source_cache.publish(subscription_json_path, payload, profile)) {
        if (metadata_output_path != "")
            unlink_path(metadata_output_path);
        return 1;
    }

    if (!guard_subscription_source_update && !persist_subscription_cache(cache_section, { payload, profile }))
        log_message("Failed to persist last working subscription cache for source '" + cache_section + "'", "warn");
    write_source_metadata_output(profile.metadata, metadata_output_path);
    log_subscription_source_summary(section_name_value, source_index, payload, unchanged);
    return unchanged ? 2 : 0;
}

function ensure_current_subscription_cache(source_section, parsed) {
    if (restore_persistent_subscription_cache(
        source_section,
        TMP_SUBSCRIPTION_FOLDER,
        FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR,
        parsed.url,
        parsed.user_agent,
        parsed.hwid,
        SUBSCRIPTION_USER_AGENT
    ))
        return true;

    let json_path = source_json_path(TMP_SUBSCRIPTION_FOLDER, source_section);
    let record = source_cache.read(TMP_SUBSCRIPTION_FOLDER, source_section);
    // If a repair could not be published, a previously usable cache remains
    // eligible as long as its source identity still matches.
    if (!subscription_parser().validate_subscription_value(record.payload)) {
        unlink_path(json_path);
        return false;
    }
    if (!source_cache_profile_matches(parsed, record.profile, SUBSCRIPTION_USER_AGENT)) {
        remove_subscription_source_runtime_cache(source_section);
        return false;
    }
    return true;
}

function update_subscription_source(section_name_value, index_value, entry, phase, metadata_output_path) {
    ensure_runtime_dirs();
    let index = int(index_value || 0);
    if (!uci_core.reload(CONFIG_NAME))
        return 1;
    connections.reload_item_sections();
    let section = uci_named_section(section_name_value);
    if (!section_is_subscription_proxy(section) || connections.subscription_urls(section)[index - 1] != entry)
        return 4;
    let parsed = subscription_source_profile(section, entry);
    if (type(parsed) != "object" || parsed.valid !== true) {
        log_message("Invalid subscription URL in rule '" + section_name_value + "': " + as_string(parsed.error || "Invalid subscription source entry"), "error");
        return 1;
    }

    let source_section = source_id(section_name_value, index);
    let staged = null;
    if (direct_fetch_dir && !parsed.download_section) {
        staged = read_json(direct_fetch_dir + "/" + source_section + ".result");
        let profile = staged?.profile;
        if (profile == null || type(staged.revision) != "string" ||
            profile.url != parsed.url || profile.hwid != parsed.hwid ||
            profile.user_agent != parsed.user_agent || profile.download_section != parsed.download_section ||
            staged.hwid != get_subscription_hwid(parsed.hwid) || staged.revision != source_revision(source_section))
            return 4;
    }
    if (guard_subscription_source_update &&
        !save_subscription_source_for_rollback(source_section, source_json_path(TMP_SUBSCRIPTION_FOLDER, source_section)))
        return 1;
    ensure_current_subscription_cache(source_section, parsed);

    let proxy = get_subscription_download_proxy_address(section_name_value, parsed, phase || "runtime");
    return download_subscription_into_cache(
        section_name_value, parsed, proxy, index, source_section, as_string(metadata_output_path), staged
    );
}

function write_subscription_update_timestamp(section_name_value, entry) {
    if (!record_subscription_update_timestamps)
        return;
    let path = subscription_update_timestamp_path(section_name_value, entry);
    if (guard_subscription_source_update)
        path = SUBSCRIPTION_UPDATE_ROLLBACK_DIR + "/" + fs.basename(path);
    if (!write_file(path, int(clock()[0]) + "\n"))
        die("Could not record successful subscription update\n");
}

function finalize_subscription_section_metadata(section_name_value, metadata_tmpfile, superseded) {
    if (as_string(metadata_tmpfile) == "")
        return;

    if (!superseded) {
        if (length(array_or_empty(read_json(metadata_tmpfile))) > 0)
            write_subscription_metadata(FORKOP_SECTION_CACHE_DIR, FORKOP_RUNTIME_CACHE_FORMAT, section_name_value, metadata_tmpfile);
        else
            write_subscription_metadata(FORKOP_SECTION_CACHE_DIR, FORKOP_RUNTIME_CACHE_FORMAT, section_name_value, "");
    }

    unlink_path(metadata_tmpfile);
}

function update_count_summary(updated, unchanged, failed) {
    let parts = [];
    if (updated > 0)
        push(parts, count_label(updated, "source updated", "sources updated"));
    if (unchanged > 0)
        push(parts, count_label(unchanged, "source unchanged", "sources unchanged"));
    if (failed > 0)
        push(parts, count_label(failed, "source failed", "sources failed"));
    return length(parts) > 0 ? join(", ", parts) : "no subscription sources checked";
}

function subscription_update_section(section, force, now, summary) {
    section = object_or_empty(section);
    if (!section_is_subscription_proxy(section))
        return 3;

    let section_name_value = section_name(section);
    let entries = connections.subscription_urls(section);
    let due_sources = [];
    let scheduled = 0;
    let failed = 0;
    for (let entry in entries) {
        let due = force ? 0 : subscription_source_due_result(section, entry, now);
        push(due_sources, due == 0);
        if (due == 0)
            scheduled++;
        else if (due != 1)
            failed++;
    }
    if (!scheduled) {
        if (summary != null)
            summary.failed += failed;
        return failed ? 1 : 3;
    }

    ensure_runtime_dirs();
    log_message("Updating subscriptions for rule '" + section_name_value + "'", "info");
    let filter_snapshot = filter_selection.snapshot(section);

    let metadata_tmpfile = temp_path(TMP_SUBSCRIPTION_FOLDER, section_name_value, "metadata-section");
    write_json(metadata_tmpfile, []);

    let changed = 0;
    let unchanged = 0;
    let superseded = 0;
    let total = 0;
    let checked_entries = [];

    for (let entry in entries) {
        total++;
        let source_section = source_id(section_name_value, total);
        if (!due_sources[total - 1]) {
            append_available_cached_metadata(metadata_tmpfile, section_name_value, total, source_section);
            continue;
        }
        let metadata_output_path = temp_path(TMP_SUBSCRIPTION_FOLDER, source_section, "metadata-output");
        let update_result = update_subscription_source(section_name_value, total, entry, "runtime", metadata_output_path);
        if (update_result == 0) {
            append_metadata_file(metadata_tmpfile, metadata_output_path, total, source_section);
            push(checked_entries, entry);
            changed++;
        }
        else if (update_result == 2) {
            append_metadata_file(metadata_tmpfile, metadata_output_path, total, source_section);
            push(checked_entries, entry);
            unchanged++;
        }
        else if (update_result == 4) {
            superseded++;
        }
        else {
            append_available_cached_metadata(metadata_tmpfile, section_name_value, total, source_section);
            failed++;
        }

        unlink_path(metadata_output_path);
    }

    let update_result = 2;
    if (changed > 0)
        update_result = 0;
    else if (failed > 0)
        update_result = 1;
    else if (superseded > 0)
        update_result = 4;

    finalize_subscription_section_metadata(section_name_value, metadata_tmpfile, superseded > 0);

    if (superseded == 0) {
        let filters = filter_selection.finish(filter_snapshot);
        if (!filters.ok) {
            if (summary != null)
                summary.failed += failed + 1;
            return 1;
        }
        if (filters.changed && changed == 0 && unchanged > 0) {
            changed++;
            unchanged--;
            update_result = 0;
        }
    }
    for (let entry in checked_entries)
        write_subscription_update_timestamp(section_name_value, entry);

    if (summary != null) {
        summary.updated += changed;
        summary.failed += failed;
        summary.unchanged += unchanged;
        summary.superseded += superseded;
    }

    if (update_result == 0) {
        log_message("Subscription update for rule '" + section_name_value + "' completed: " + update_count_summary(changed, unchanged, failed), "info");
    }
    else if (update_result == 2) {
        log_message("Subscription update for rule '" + section_name_value + "' completed: no changes (" + count_label(unchanged, "source checked", "sources checked") + ")", "info");
    }
    else if (update_result == 4) {
        log_message("Subscription update for rule '" + section_name_value + "' was superseded by newer URLs", "info");
    }
    else {
        log_message("Subscription update for rule '" + section_name_value + "' failed: " + update_count_summary(changed, unchanged, failed), "warn");
    }

    return update_result;
}

function source_index_number(value) {
    value = as_string(value);
    if (value == "" || match(value, /[^0-9]/) != null)
        return null;

    let result = int(value);
    return result > 0 ? result : null;
}

function subscription_update_selected_source(sections, section_name_value, source_index_value, force, now) {
    if (!cache_section_is_safe(section_name_value)) {
        log_message("Invalid subscription rule name", "error");
        return 1;
    }

    let source_index = source_index_number(source_index_value);
    if (source_index == null) {
        log_message("Invalid subscription source index for rule '" + section_name_value + "'", "error");
        return 1;
    }

    let section = find_section(sections, section_name_value);
    if (!section_is_subscription_proxy(section)) {
        log_message("Rule '" + section_name_value + "' has no subscription sources", "info");
        return 1;
    }

    let current_index = 0;
    let selected_entry = null;
    for (let entry in connections.subscription_urls(section)) {
        current_index++;
        if (current_index == source_index) {
            selected_entry = entry;
            break;
        }
    }

    if (selected_entry == null) {
        log_message("Subscription source '" + source_index + "' was not found for rule '" + section_name_value + "'", "info");
        return 1;
    }

    if (!force) {
        let due_result = subscription_source_due_result(section, selected_entry, now);
        if (due_result != 0)
            return due_result == 1 ? 3 : 1;
    }

    ensure_runtime_dirs();
    log_message("Updating subscription source " + source_index + " for rule '" + section_name_value + "'", "info");
    let source_section = source_id(section_name_value, source_index);
    let metadata_output_path = temp_path(TMP_SUBSCRIPTION_FOLDER, source_section, "metadata-output");
    let filter_snapshot = filter_selection.snapshot(section);
    let update_result = update_subscription_source(section_name_value, source_index, selected_entry, "runtime", metadata_output_path);

    if (update_result == 0 || update_result == 2)
        write_source_metadata(
            FORKOP_SECTION_CACHE_DIR,
            FORKOP_RUNTIME_CACHE_FORMAT,
            section_name_value,
            source_index,
            source_section,
            metadata_output_path,
            FORKOP_SUBSCRIPTION_METADATA_DIR + "/" + section_name_value + ".json"
        );

    unlink_path(metadata_output_path);

    if (update_result == 0 || update_result == 2) {
        let filters = filter_selection.finish(filter_snapshot);
        if (!filters.ok)
            return 1;
        if (filters.changed)
            update_result = 0;
        write_subscription_update_timestamp(section_name_value, selected_entry);
    }

    if (update_result == 4) {
        log_message("Subscription source '" + source_index + "' update for rule '" + section_name_value + "' was superseded by newer URLs", "info");
    }
    else if (update_result != 0 && update_result != 2) {
        log_message("Failed to download subscription source '" + source_index + "' for rule '" + section_name_value + "'", "info");
    }

    return update_result;
}

function empty_subscription_update_summary() {
    return {
        updated: 0,
        failed: 0,
        unchanged: 0,
        superseded: 0
    };
}

function add_subscription_update_result(summary, result) {
    if (result == 0)
        summary.updated++;
    else if (result == 1)
        summary.failed++;
    else if (result == 2)
        summary.unchanged++;
    else if (result == 4)
        summary.superseded++;
}

function print_subscription_update_summary(summary) {
    print(summary.updated, "\t", summary.failed, "\t", summary.unchanged, "\t", summary.superseded, "\n");
}

function subscription_update_request(force_value, target_section_name, target_source_index) {
    let force = as_string(force_value) == "1";
    let now = direct_fetch_dir == "" ? int(clock()[0]) :
        int(file_first_line_value(direct_fetch_dir + "/.started-at"));
    if (now <= 0)
        die("Missing subscription prefetch timestamp\n");
    let sections = uci_sections();
    let summary = empty_subscription_update_summary();

    target_section_name = as_string(target_section_name);
    target_source_index = as_string(target_source_index);

    if (target_section_name != "") {
        if (target_source_index != "")
            add_subscription_update_result(summary, subscription_update_selected_source(sections, target_section_name, target_source_index, force, now));
        else
            subscription_update_section(find_section(sections, target_section_name), force, now, summary);
        print_subscription_update_summary(summary);
        return;
    }

    for (let section in sections)
        subscription_update_section(section, force, now, summary);

    print_subscription_update_summary(summary);
}

function ensure_subscription_source_for_prepare(state, section, source_index, entry, metadata_tmpfile) {
    let section_name_value = section_name(section);
    let parsed = subscription_source_profile(section, entry);
    if (type(parsed) != "object" || parsed.valid !== true) {
        log_message("Invalid subscription source for rule '" + section_name_value + "': " + as_string(parsed.error || "Invalid subscription source entry"), "error");
        state.startup_blocked = true;
        return false;
    }

    let source_section = source_id(section_name_value, source_index);
    if (ensure_current_subscription_cache(source_section, parsed)) {
        append_available_cached_metadata(metadata_tmpfile, section_name_value, source_index, source_section);
        return true;
    }

    if (state.no_refresh) {
        log_message("No current subscription cache for rule '" + section_name_value + "' source '" + source_index + "'; skipping refresh during scoped runtime rebuild", "warn");
        return false;
    }

    let metadata_output_path = metadata_tmpfile != "" ? temp_path(TMP_SUBSCRIPTION_FOLDER, source_section, "metadata-output") : "";
    let proxy = get_subscription_download_proxy_address(section_name_value, parsed, state.phase);
    let update_result = download_subscription_into_cache(
        section_name_value, parsed, proxy, source_index, source_section, metadata_output_path
    );

    if (update_result == 0 || update_result == 2) {
        append_metadata_file(metadata_tmpfile, metadata_output_path, source_index, source_section);
        unlink_path(metadata_output_path);
        return true;
    }

    unlink_path(metadata_output_path);

    log_message("No usable subscription cache for rule '" + section_name_value + "'", "warn");
    return false;
}

function prepare_subscription_cache_section(state, section) {
    section = object_or_empty(section);
    if (!section_is_subscription_proxy(section))
        return;

    // Startup may use an already refreshed cache with stale persisted filters
    // (including after an upgrade). Reconcile before generating any runtime,
    // even when every source is current and no network download is necessary.
    let filter_snapshot = filter_selection.snapshot(section);

    let section_name_value = section_name(section);
    let metadata_tmpfile = temp_path(TMP_SUBSCRIPTION_FOLDER, section_name_value, "metadata-section");
    write_json(metadata_tmpfile, []);

    let total = 0;
    let ready = 0;
    let failed = 0;
    for (let entry in connections.subscription_urls(section)) {
        total++;
        if (ensure_subscription_source_for_prepare(state, section, total, entry, metadata_tmpfile))
            ready++;
        else {
            failed++;
            state.unavailable_sources = append_word_once(state.unavailable_sources, source_id(section_name_value, total));
        }
    }

    if (ready > 0 && length(filter_snapshot.descriptors) > 0 && !filter_selection.finish(filter_snapshot).ok) {
        log_message("Failed to reconcile subscription filters for rule '" + section_name_value + "'", "error");
        state.startup_blocked = true;
    }

    if (total > 0 && ready == 0) {
        if (section_has_non_subscription_connection_sources(section)) {
            log_message("All subscription sources for rule '" + section_name_value + "' are unavailable; starting with manual proxy links only", "warn");
        }
        else {
            if (state.phase == "startup")
                log_message("No usable subscription cache for rule '" + section_name_value + "' and no manual proxy links are configured; checking whether startup can be bootstrapped through the selected proxy/VPN rule", "warn");
            else
                log_message("No usable subscription cache for rule '" + section_name_value + "' and no manual proxy links are configured; fast runtime generation cannot use this rule", "warn");
            state.startup_blocked_sections = append_word_once(state.startup_blocked_sections, section_name_value);
        }
    }
    else if (failed > 0) {
        log_message("Skipping unavailable subscription source(s) for rule '" + section_name_value + "'; using available outbounds", "warn");
    }

    let metadata_count = length(array_or_empty(read_json(metadata_tmpfile)));
    if (metadata_count > 0)
        write_subscription_metadata(FORKOP_SECTION_CACHE_DIR, FORKOP_RUNTIME_CACHE_FORMAT, section_name_value, metadata_tmpfile);
    else
        write_subscription_metadata(FORKOP_SECTION_CACHE_DIR, FORKOP_RUNTIME_CACHE_FORMAT, section_name_value, "");
    unlink_path(metadata_tmpfile);
}

function prepared_runtime_cache_should_skip(sections, section_cache_dir, phase, already_prepared) {
    return as_string(phase) == "runtime" &&
        as_string(already_prepared) == "1" &&
        !runtime_cache_missing(sections, section_cache_dir);
}

function recover_subscription_sources_for_sections(sections) {
    // Restore every source before downloads or persistence can overwrite old
    // indices. A RAM-only slot must survive a swap even if writing the
    // corresponding flash copy failed. Hard links keep the original bytes
    // available while the active paths are replaced atomically.
    let source_files = filter(fs.glob(TMP_SUBSCRIPTION_FOLDER + "/*") || [],
        path => match(path, /\.(json|url|user_agent|hwid)$/) != null &&
            fs.lstat(path)?.type == "file");
    let snapshot = "";
    if (length(source_files)) {
        snapshot = trim(command_output_from_args([ "mktemp", "-d", TMP_SUBSCRIPTION_FOLDER + "/.relocate.XXXXXX" ]));
        if (snapshot == "")
            return false;
        if (!command_success_from_args([ "ln", ...source_files, snapshot ])) {
            command_success_from_args([ "rm", "-rf", snapshot ]);
            return false;
        }
    }

    for (let section in sections) {
        if (!section_is_subscription_proxy(section))
            continue;
        let index_value = 0;
        for (let entry in connections.subscription_urls(section)) {
            index_value++;
            let parsed = subscription_source_profile(section, entry);
            if (type(parsed) == "object" && parsed.valid === true)
                restore_persistent_subscription_cache(source_id(section_name(section), index_value),
                    TMP_SUBSCRIPTION_FOLDER, FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR,
                    parsed.url, parsed.user_agent, parsed.hwid, SUBSCRIPTION_USER_AGENT, snapshot);
        }
    }
    if (snapshot != "")
        command_success_from_args([ "rm", "-rf", snapshot ]);
    return true;
}

function persist_recovered_subscription_sources(sections) {
    for (let section in sections) {
        if (!section_is_subscription_proxy(section))
            continue;
        let index_value = 0;
        for (let entry in connections.subscription_urls(section)) {
            index_value++;
            let source = source_id(section_name(section), index_value);
            let parsed = subscription_source_profile(section, entry);
            let record = source_cache.read(TMP_SUBSCRIPTION_FOLDER, source);
            if (type(parsed) != "object" || parsed.valid !== true ||
                !source_cache_matches_profile(record, parsed.url,
                    parsed.user_agent, parsed.hwid, SUBSCRIPTION_USER_AGENT))
                continue;
            if (!persist_subscription_cache(source, record)) {
                log_message("Failed to persist relocated subscription cache for source '" + source + "'", "warn");
                return false;
            }
        }
    }
    return true;
}

function prepare_subscription_caches(phase, already_prepared, no_refresh) {
    phase = as_string(phase || "startup");
    let sections = uci_sections();

    if (prepared_runtime_cache_should_skip(sections, FORKOP_SECTION_CACHE_DIR, phase, already_prepared)) {
        print("\n");
        return 0;
    }
    if (as_string(already_prepared) != "1" && !finish_subscription_source_update(false) &&
        fs.stat(SUBSCRIPTION_UPDATE_ROLLBACK_DIR + "/.commit") == null) {
        log_message("Cannot restore the source cache after an interrupted subscription update", "error");
        return 1;
    }

    ensure_runtime_dirs();
    let state = {
        phase,
        sections,
        settings: uci_named_section("settings"),
        startup_blocked: false,
        startup_blocked_sections: "",
        unavailable_sources: "",
        no_refresh: as_string(no_refresh) == "1"
    };

    if (!recover_subscription_sources_for_sections(sections)) {
        log_message("Cannot preserve current subscription sources for cache relocation", "error");
        return 1;
    }
    for (let section in sections)
        prepare_subscription_cache_section(state, section);
    // Preserve old source names if migration failed; they remain recoverable.
    if (persist_recovered_subscription_sources(sections))
        prune_stale_subscription_caches_for_sections(sections);

    if (state.startup_blocked)
        return 1;

    if (state.startup_blocked_sections == "") {
        print("\n");
        return 0;
    }

    if (phase == "startup" && subscription_bootstrap_download_section_is_ready(sections, state.startup_blocked_sections, SUBSCRIPTION_USER_AGENT)) {
        log_message("Starting temporarily without subscription-only rule(s): " + state.startup_blocked_sections + ". They will be retried through the service proxy after sing-box starts", "warn");
        print(state.startup_blocked_sections, "\n");
        return 0;
    }

    for (let section in whitespace_values(state.startup_blocked_sections))
        log_message("No usable subscription cache for rule '" + section + "' and no manual proxy links are configured; startup cannot continue", "error");

    return 1;
}

function current_pid() {
    return trim(command_output("sh -c 'echo $PPID'"));
}

function pid_running(pid) {
    pid = as_string(pid);
    return match(pid, /^[0-9]+$/) != null && command_success_from_args([ "kill", "-0", pid ]);
}

function state_ucode_status(args) {
    return command_status_from_args(command_args_with([ "ucode", "-L", LIB_DIR, LIB_DIR + "/service/state.uc" ], args)) == 0;
}

function mark_pending_subscription_recovery_reload() {
    state_ucode_status([ "mark-pending-reload", FORKOP_PENDING_RELOAD_FILE, "subscription_deferred_recovery" ]);
}

function trigger_subscription_recovery_reload(worker) {
    if (worker)
        command_status_from_args([ FORKOP_SERVICE_INIT, "reload", "subscription_deferred_recovery" ]);
    else
        mark_pending_subscription_recovery_reload();
}

function subscription_bootstrap_retry_result(deferred_sections) {
    let sections = uci_sections();
    let default_user_agent = SUBSCRIPTION_USER_AGENT;
    let result = {
        recovered: "",
        remaining: ""
    };

    for (let section in whitespace_values(deferred_sections)) {
        let value = find_section(sections, section);
        if (!section_is_subscription_proxy(value)) {
            log_message("Deferred subscription rule '" + section + "' no longer has subscription proxy sources; removing it from bootstrap retry list", "warn");
            result.recovered = append_word_once(result.recovered, section);
            continue;
        }

        log_message("Retrying deferred subscription rule '" + section + "' through the service proxy", "info");
        let update_result = subscription_update_section(value, true, int(clock()[0]));
        if (update_result == 0 || update_result == 2) {
            result.recovered = append_word_once(result.recovered, section);
            continue;
        }

        if (section_current_usable_cache_by_name(sections, section, default_user_agent)) {
            log_message("Deferred subscription rule '" + section + "' has a usable cache after retry despite partial update errors", "warn");
            result.recovered = append_word_once(result.recovered, section);
            continue;
        }

        result.remaining = append_word_once(result.remaining, section);
        log_message("Deferred subscription rule '" + section + "' is still unavailable; keeping it disabled for this startup", "warn");
    }

    return result;
}

function worker_env() {
    return {
        FORKOP_CONFIG_NAME: CONFIG_NAME,
        FORKOP_LIB: LIB_DIR,
        TMP_SING_BOX_FOLDER,
        TMP_RULESET_FOLDER,
        TMP_SUBSCRIPTION_FOLDER,
        FORKOP_RUNTIME_STATE_DIR,
        FORKOP_SUBSCRIPTION_UPDATE_STATE_DIR,
        FORKOP_SUBSCRIPTION_LINKS_DIR,
        FORKOP_SUBSCRIPTION_METADATA_DIR,
        FORKOP_OUTBOUND_METADATA_DIR,
        FORKOP_SECTION_CACHE_DIR,
        FORKOP_RUNTIME_CACHE_FORMAT_FILE,
        FORKOP_RUNTIME_CACHE_FORMAT,
        FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR,
        FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE,
        FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT,
        FORKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE,
        FORKOP_SUBSCRIPTION_UPDATE_LOCK_DIR,
        FORKOP_PENDING_RELOAD_FILE,
        FORKOP_SERVICE_INIT,
        SB_SERVICE_MIXED_INBOUND_ADDRESS,
        SB_SERVICE_MIXED_INBOUND_PORT
    };
}

function launch_self_worker(args) {
    let command_args = command_args_with([ "ucode", "-L", LIB_DIR, LIB_DIR + "/subscription/cache.uc" ], args);
    let command = command_env(worker_env()) + " " + command_from_args(command_args) + " >/dev/null 2>&1 1000>&- & echo $!";
    return trim(command_output("sh -c " + shell_quote(command)));
}

function start_deferred_subscription_bootstrap_retry_worker(deferred_sections) {
    deferred_sections = trim(as_string(deferred_sections));
    if (deferred_sections == "")
        return;

    ensure_runtime_dirs();
    let existing_pid = trim(file_first_line_value(FORKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE));
    if (pid_running(existing_pid)) {
        log_message("Subscription bootstrap retry worker is already running with PID " + existing_pid, "debug");
        return;
    }

    let pid = launch_self_worker([ "deferred-bootstrap-worker", deferred_sections ]);
    if (pid != "")
        write_file(FORKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE, pid + "\n");
    log_message("Started subscription bootstrap retry worker for rule(s): " + deferred_sections, "info");
}

function stop_deferred_subscription_bootstrap_retry_worker() {
    let pid = trim(file_first_line_value(FORKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE));
    if (pid_running(pid)) {
        command_success_from_args([ "kill", pid ]);
        log_message("Stopped subscription bootstrap retry worker", "info");
    }
    unlink_path(FORKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE);
}

function run_deferred_subscription_bootstrap(deferred_sections) {
    deferred_sections = trim(as_string(deferred_sections));
    if (deferred_sections == "")
        return;

    log_message("Waiting for sing-box service proxy before retrying deferred subscription rule(s): " + deferred_sections, "info");
    let ready = false;
    for (let attempt = 1; attempt <= 10; attempt++) {
        if (sing_box_service_running()) {
            ready = true;
            break;
        }
        system("sleep 1");
    }

    if (!ready) {
        log_message("sing-box service proxy did not become ready in time; deferred subscription rule(s) will remain disabled until the next successful subscription update", "warn");
        start_deferred_subscription_bootstrap_retry_worker(deferred_sections);
        return;
    }

    let result = subscription_bootstrap_retry_result(deferred_sections);
    if (result.recovered != "") {
        log_message("Recovered deferred subscription rule(s): " + result.recovered + "; scheduling Forkop reload", "info");
        trigger_subscription_recovery_reload(false);
    }

    if (result.remaining != "") {
        log_message("Some deferred subscription rule(s) are still disabled for this startup: " + result.remaining, "warn");
        start_deferred_subscription_bootstrap_retry_worker(result.remaining);
    }
}

function deferred_subscription_bootstrap_retry_worker(remaining_sections) {
    remaining_sections = trim(as_string(remaining_sections));

    while (remaining_sections != "") {
        system("sleep 30");
        if (!sing_box_service_running()) {
            log_message("Stopping subscription bootstrap retry worker because sing-box is not running", "warn");
            break;
        }

        ensure_runtime_dirs();
        if (!state_ucode_status([ "acquire-runtime-dir-lock", FORKOP_SUBSCRIPTION_UPDATE_LOCK_DIR, current_pid() ])) {
            log_message("Subscription bootstrap retry skipped because another subscription update is running", "debug");
            continue;
        }

        let result = subscription_bootstrap_retry_result(remaining_sections);
        state_ucode_status([ "release-runtime-dir-lock", FORKOP_SUBSCRIPTION_UPDATE_LOCK_DIR ]);

        if (result.recovered != "") {
            log_message("Recovered deferred subscription rule(s): " + result.recovered + "; reloading Forkop", "info");
            trigger_subscription_recovery_reload(true);
        }

        remaining_sections = result.remaining;
    }

    unlink_path(FORKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE);
}

let mode = ARGV[0] || "";

if (mode == "file-first-line") {
    file_first_line(ARGV[1]);
}
else if (mode == "runtime-cache-needs-rebuild") {
    exit(runtime_cache_missing(uci_sections(), ARGV[1]) ? 0 : 1);
}
else if (mode == "ensure-runtime-dirs") {
    ensure_runtime_dirs();
}
else if (mode == "ensure-runtime-cache-format") {
    ensure_runtime_cache_format();
}
else if (mode == "restore-persistent-source") {
    let expected_hwid = ARGV[7] == null ? "" : ARGV[6];
    let default_user_agent = ARGV[7] == null ? ARGV[6] : ARGV[7];
    exit(restore_persistent_subscription_cache(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], expected_hwid, default_user_agent) ? 0 : 1);
}
else if (mode == "subscription-metadata-path") {
    let path = subscription_metadata_path(ARGV[1]);
    if (path == "")
        exit(1);
    print(path, "\n");
}
else if (mode == "outbound-metadata-path") {
    let path = outbound_metadata_path(ARGV[1]);
    if (path == "")
        exit(1);
    print(path, "\n");
}
else if (mode == "update-due-status-fixture") {
    exit(update_due_status(ARGV[1], ARGV[2], ARGV[3]));
}
else if (mode == "update-request") {
    guard_subscription_source_update = ARGV[4] == "1";
    direct_fetch_dir = ARGV[5] || "";
    record_subscription_update_timestamps = ARGV[6] != "0";
    subscription_update_request(ARGV[1] || "0", ARGV[2] || "", ARGV[3] || "");
}
else if (mode == "prefetch-direct") {
    exit(prefetch_direct_sources(ARGV[4], ARGV[1] == "1", ARGV[2], ARGV[3]) ? 0 : 1);
}
else if (mode == "finish-source-update") {
    exit(finish_subscription_source_update(ARGV[1] == "commit") ? 0 : 1);
}
else if (mode == "prepare-caches") {
    exit(prepare_subscription_caches(ARGV[1] || "startup", ARGV[2] || "0", ARGV[3] || "0"));
}
else if (mode == "run-deferred-bootstrap") {
    run_deferred_subscription_bootstrap(ARGV[1] || "");
}
else if (mode == "stop-deferred-bootstrap-worker") {
    stop_deferred_subscription_bootstrap_retry_worker();
}
else if (mode == "deferred-bootstrap-worker") {
    deferred_subscription_bootstrap_retry_worker(ARGV[1] || "");
}
else if (mode == "json-length") {
    json_length(ARGV[1]);
}
else if (mode == "editor-download-source") {
    exit(write_json(ARGV[2] + ".profile.json", editor_download_source(ARGV[1], ARGV[2])) ? 0 : 1);
}
else if (mode == "download-subscription-fixture") {
    exit(download_subscription(ARGV[1], ARGV[2], ARGV[3] || "", ARGV[4] || "", ARGV[6] || ""));
}
else if (mode == "write-outbound-metadata") {
    let cache_dir = ARGV[1], format_version = ARGV[2], section = ARGV[3];
    if (!safe_section(section))
        exit(1);
    write_outbound_metadata(cache_dir, format_version, section, ARGV[4], ARGV[5], ARGV[6]);
}
else if (mode == "get-outbound-metadata") {
    let cache_dir = ARGV[1], section = ARGV[2];
    if (!safe_section(section))
        write_empty_outbound_metadata();
    else
        get_outbound_metadata(cache_dir, section, ARGV[3]);
}
else if (mode == "empty-outbound-metadata") {
    write_empty_outbound_metadata();
}
else if (mode == "get-subscription-metadata") {
    let cache_dir = ARGV[1], section = ARGV[2];
    if (!safe_section(section))
        print("{}\n");
    else
        get_subscription_metadata(cache_dir, section, ARGV[3]);
}
else {
    warn("Usage: subscription/cache.uc <mode> ...\n");
    exit(1);
}
