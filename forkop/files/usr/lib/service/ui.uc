#!/usr/bin/env ucode

let fs = require("fs");
let locks = require("core.locks");
let process_memory = require("core.process_memory");
let uci_core = require("core.uci");

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const BIN_PATH = getenv("FORKOP_BIN") || "/usr/bin/forkop";
const SERVICE_INIT = getenv("FORKOP_SERVICE_INIT") || "/etc/init.d/forkop";
const SERVICE_NAME = getenv("FORKOP_SERVICE_NAME") || "forkop";
// The core's resident memory is spread over two procd services: forkop-tailscale
// runs the very same core binary, so leaving it out reports roughly half of what
// the core actually occupies. A name procd does not know is a component that is
// not installed and simply adds nothing.
const CORE_SERVICE_NAMES = [ "sing-box", "forkop-tailscale" ];
// Forkop's own workers, each in a procd service of its own.
const FORKOP_SERVICE_NAMES = [ SERVICE_NAME, "forkop-torrserver-direct" ];
const STATE_UC = LIB_DIR + "/service/state.uc";
const UI_UC = LIB_DIR + "/service/ui.uc";
const STATE_DIR = getenv("FORKOP_UI_STATE_DIR") || "/var/run/forkop/ui-state";
const PENDING_RELOAD_FILE = getenv("FORKOP_PENDING_RELOAD_FILE") || "/var/run/forkop/reload.pending";
const PACKAGE_UPGRADE_QUIESCE_FILE = getenv("FORKOP_PACKAGE_UPGRADE_QUIESCE_FILE") || "/var/run/forkop/package-upgrade.quiesce";
const RUNTIME_CONFIG_ERROR_FILE = getenv("FORKOP_RUNTIME_CONFIG_ERROR_FILE") || "/var/run/forkop/config-error";
const SUBSCRIPTION_APPLY_ERROR_FILE = getenv("FORKOP_SUBSCRIPTION_APPLY_ERROR_FILE") || "/var/run/forkop/subscription-apply-error.json";
const SERVICE_ACTION_DIR = getenv("FORKOP_UI_SERVICE_ACTION_DIR") || STATE_DIR + "/service-actions";
const SERVICE_ACTION_LOCK_DIR = getenv("FORKOP_UI_SERVICE_ACTION_LOCK_DIR") || STATE_DIR + "/service-actions.lock";
const LATENCY_ACTION_DIR = getenv("FORKOP_UI_LATENCY_ACTION_DIR") || STATE_DIR + "/latency-actions";
const LATENCY_TEST_LOCK_DIR = getenv("FORKOP_LATENCY_TEST_LOCK_DIR") || "/var/run/forkop/automatic-latency-test.lock";
const COMPONENT_ACTION_DIR = getenv("FORKOP_UI_COMPONENT_ACTION_DIR") || getenv("UPDATES_JOB_DIR") || "/var/run/forkop/component-actions";
const SUBSCRIPTION_ACTION_DIR = getenv("FORKOP_UI_SUBSCRIPTION_ACTION_DIR") || getenv("FORKOP_SUBSCRIPTION_UPDATE_JOB_DIR") || "/var/run/forkop/subscription-update-jobs";
const SING_BOX_VERSION_CACHE_FILE = getenv("FORKOP_UI_SING_BOX_VERSION_CACHE_FILE") || STATE_DIR + "/sing-box-version";
const SING_BOX_VERSION_CACHE_LOCK_DIR = getenv("FORKOP_UI_SING_BOX_VERSION_CACHE_LOCK_DIR") || SING_BOX_VERSION_CACHE_FILE + ".lock";
const SING_BOX_VARIANT_STATE_FILE = getenv("FORKOP_UI_SING_BOX_VARIANT_STATE_FILE") || "/etc/forkop/sing-box-variant";
const SING_BOX_BIN_PATH = getenv("FORKOP_UI_SING_BOX_BIN_PATH") || "/usr/bin/sing-box";
const SING_BOX_VERSION_PROBE_TIMEOUT_SECONDS = getenv("FORKOP_UI_SING_BOX_VERSION_PROBE_TIMEOUT_SECONDS") || "1";
const SING_BOX_VERSION_PROBE_FAILURE_TTL_SECONDS = getenv("FORKOP_UI_SING_BOX_VERSION_PROBE_FAILURE_TTL_SECONDS") || "30";
const ACTION_FINISHED_TTL_MINUTES = getenv("FORKOP_UI_ACTION_FINISHED_TTL_MINUTES") || "60";
const ACTION_ACKED_TTL_SECONDS = getenv("FORKOP_UI_ACTION_ACKED_TTL_SECONDS") || "15";
const ACTION_STALE_GRACE_SECONDS = getenv("FORKOP_UI_ACTION_STALE_GRACE_SECONDS") || "15";
const SERVICE_ACTION_TIMEOUT_SECONDS = getenv("FORKOP_UI_SERVICE_ACTION_TIMEOUT_SECONDS") || "120";
const SERVICE_ACTION_SETTLE_SECONDS = getenv("FORKOP_UI_SERVICE_ACTION_SETTLE_SECONDS") || "2";
const RUNTIME_STABLE_MIN_AGE = getenv("FORKOP_RUNTIME_STABLE_MIN_AGE") || "2";
const NFT_TABLE_NAME = getenv("NFT_TABLE_NAME") || "ForkopTable";
const RT_TABLE_NAME = getenv("RT_TABLE_NAME") || "forkop";
const NFT_FAKEIP_MARK = getenv("NFT_FAKEIP_MARK") || "0x04000000";
const SB_DNS_INBOUND_ADDRESS = getenv("SB_DNS_INBOUND_ADDRESS") || "127.0.0.42";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function read_stdin() {
    let input = fs.open("/dev/stdin", "r");
    if (!input)
        return "";
    let data = input.read("all");
    input.close();
    return data == null ? "" : data;
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

function parse_json_or_null(value) {
    try {
        return json(as_string(value));
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

function command_success(command) {
    return command_status(command + " >/dev/null 2>&1") == 0;
}

function command_success_from_args(args) {
    return command_success(command_from_args(args));
}

function process_start_ticks(pid) {
    if (match(as_string(pid), /^[0-9]+$/) == null)
        return null;
    let stat = as_string(fs.readfile("/proc/" + pid + "/stat"));
    let marker = index(stat, ") ");
    if (marker < 0)
        return null;
    let fields = split(trim(substr(stat, marker + 2)), /[ \t\r\n]+/);
    return length(fields) >= 20 && match(as_string(fields[19]), /^[0-9]+$/) != null ? fields[19] : null;
}

function package_upgrade_marker_values() {
    let fields = split(trim(as_string(fs.readfile(PACKAGE_UPGRADE_QUIESCE_FILE))), /[ \t\r\n]+/);
    if (length(fields) != 2 || match(as_string(fields[0]), /^[0-9]+$/) == null ||
        match(as_string(fields[1]), /^[0-9]+$/) == null)
        return null;
    return { pid: fields[0], start_ticks: fields[1] };
}

function package_upgrade_transition_active() {
    let marker = package_upgrade_marker_values();
    return marker != null && process_start_ticks(marker.pid) == marker.start_ticks;
}

function package_upgrade_quiesce_owned(pid) {
    let marker = package_upgrade_marker_values();
    return marker != null && marker.pid == as_string(pid) &&
        process_start_ticks(marker.pid) == marker.start_ticks;
}

function module_success(module_path, args) {
    let command_args = [ "ucode", "-L", LIB_DIR, module_path ];
    for (let arg in args)
        push(command_args, arg);
    return command_success_from_args(command_args);
}

function now_seconds() {
    return int(clock()[0]);
}

function ensure_dir(path) {
    return fs.mkdir(path, 0755) || fs.stat(path) != null;
}

function ensure_dirs() {
    for (let dir in [
        STATE_DIR,
        SERVICE_ACTION_DIR,
        LATENCY_ACTION_DIR,
        COMPONENT_ACTION_DIR,
        SUBSCRIPTION_ACTION_DIR
    ])
        ensure_dir(dir);
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

function remove_state_file(path) {
    path = as_string(path);
    let base = path;
    let suffix = ".json";
    if (length(base) >= length(suffix) && substr(base, length(base) - length(suffix)) == suffix)
        base = substr(base, 0, length(base) - length(suffix));
    remove_file(path);
    remove_file(base + ".out");
    remove_file(base + ".out.json");
}

function arg_bool(value) {
    return value === true || value == "true" || value == "1" || value == 1;
}

function arg_number(value) {
    value = as_string(value);
    if (value == "" || match(value, /[^0-9-]/))
        return 0;
    return int(value);
}

function non_negative_number(value) {
    let number = arg_number(value);
    return number < 0 ? 0 : number;
}

function unsigned_number(value) {
    value = as_string(value);
    if (value == "" || match(value, /[^0-9]/) != null)
        return null;
    return int(value);
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function path_basename(path) {
    let parts = split(as_string(path), "/");
    return length(parts) > 0 ? as_string(parts[length(parts) - 1]) : "";
}

function str_remove_suffix(value, suffix) {
    value = as_string(value);
    suffix = as_string(suffix);
    if (length(value) >= length(suffix) && substr(value, length(value) - length(suffix)) == suffix)
        return substr(value, 0, length(value) - length(suffix));
    return value;
}

function job_id_from_path(path) {
    return str_remove_suffix(path_basename(path), ".json");
}

function valid_action_state(value) {
    return type(value) == "object" && (value.running === true || value.running === false);
}

function read_state_paths() {
    let result = {
        service: [],
        latency: [],
        component: [],
        subscription: []
    };

    for (let line in split(read_stdin(), "\n")) {
        line = trim(as_string(line));
        if (line == "")
            continue;

        let tab = index(line, "\t");
        if (tab <= 0)
            continue;

        let kind = substr(line, 0, tab);
        let path = substr(line, tab + 1);
        let value = read_json_file(path);
        if (!valid_action_state(value))
            continue;

        value.job_id = job_id_from_path(path);

        if (type(result[kind]) == "array")
            push(result[kind], value);
    }

    return result;
}

function service_status_text(running, enabled) {
    if (arg_bool(running))
        return arg_bool(enabled) ? "running & enabled" : "running but disabled";

    return arg_bool(enabled) ? "stopped but enabled" : "stopped & disabled";
}

function print_service_status_text(running, enabled) {
    print(service_status_text(running, enabled), "\n");
}

function ui_state_json() {
    let action_state = read_state_paths();
    let forkop_running = arg_number(ARGV[1]);
    let forkop_enabled = arg_number(ARGV[2]);
    let forkop_status = as_string(ARGV[3]);
    let forkop_dns_configured = arg_number(ARGV[4]);
    let sing_box_running = arg_number(ARGV[5]);
    let sing_box_enabled = arg_number(ARGV[6]);
    let sing_box_status = as_string(ARGV[7]);

    if (forkop_status == "")
        forkop_status = service_status_text(forkop_running, forkop_enabled);

    if (sing_box_status == "")
        sing_box_status = service_status_text(sing_box_running, sing_box_enabled);

    write_json({
        service: {
            forkop: {
                running: forkop_running,
                enabled: forkop_enabled,
                status: forkop_status,
                dns_configured: forkop_dns_configured
            },
            sing_box: {
                running: sing_box_running,
                enabled: sing_box_enabled,
                status: sing_box_status
            }
        },
        capabilities: {
            sing_box_extended: arg_number(ARGV[8]),
            sing_box_tiny: arg_number(ARGV[9]),
            sing_box_compressed: arg_number(ARGV[10]),
            sing_box_tailscale: arg_number(ARGV[11])
        },
        actions: action_state
    });
}

function action_start_response(success, job_id, message) {
    write_json({
        success: arg_bool(success),
        job_id: as_string(job_id),
        message: as_string(message)
    });
}

function service_action_valid(action) {
    action = as_string(action);
    return action == "start" || action == "stop" || action == "restart" || action == "reload";
}

function latency_type_valid(latency_type) {
    latency_type = as_string(latency_type);
    return latency_type == "group" || latency_type == "proxy" || latency_type == "proxy_list";
}

function service_action_expected_running(action) {
    action = as_string(action);

    if (action == "start" || action == "restart" || action == "reload")
        print("1\n");
    else if (action == "stop")
        print("0\n");
    else
        exit(1);
}

function stale_action_state(path, message, updated_at) {
    let value = object_or_empty(read_json_file(path));
    if (value.running === true) {
        value.success = false;
        value.running = false;
        value.message = as_string(message);
        value.exit_code = null;
        value.updated_at = arg_number(updated_at);
    }
    write_json(value);
}

function action_ack_expired(path, now_value, ttl_value) {
    let value = read_json_file(path);
    if (type(value) != "object")
        exit(1);

    let acked_at = unsigned_number(value.acked_at);
    let now = unsigned_number(now_value);
    let ttl = unsigned_number(ttl_value);

    if (acked_at == null || now == null || now <= 0 || ttl == null)
        exit(1);

    exit(now - acked_at >= ttl ? 0 : 1);
}

function json_file_field(path, key, fallback) {
    let value = read_json_file(path);
    if (type(value) == "object" && value[key] != null)
        print(as_string(value[key]), "\n");
    else
        print(as_string(fallback), "\n");
}

function job_state_path(dir, job_id) {
    dir = as_string(dir);
    job_id = as_string(job_id);

    if (job_id == "" || job_id == "." || job_id == ".." || match(job_id, /[^A-Za-z0-9._-]/) != null)
        exit(1);

    print(dir, "/", job_id, ".json\n");
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

function job_refresh_plan(path, now, grace_seconds) {
    let value = read_json_file(path);
    if (type(value) != "object" || value.running !== true) {
        print("skip\n");
        return;
    }

    let within_grace = job_started_at_within_grace(value.started_at, now, grace_seconds);
    let pid = as_string(value.pid || "");
    if (!job_pid_valid(pid)) {
        print(within_grace ? "skip\n" : "stale\n");
        return;
    }

    print("pid\t", pid, "\t", within_grace ? "0" : "1", "\n");
}

function active_service_action(dir) {
    dir = as_string(dir || SERVICE_ACTION_DIR);

    for (let path in fs.glob(as_string(dir) + "/*.json")) {
        let value = read_json_file(path);
        if (type(value) == "object" && value.running === true && as_string(value.action) != "") {
            print(as_string(value.action), "\n");
            return;
        }
    }

    exit(1);
}

function active_service_action_value() {
    for (let path in fs.glob(SERVICE_ACTION_DIR + "/*.json")) {
        let value = read_json_file(path);
        if (type(value) == "object" && value.running === true && as_string(value.action) != "")
            return as_string(value.action);
    }

    return "";
}

function file_executable(path) {
    let stat = fs.stat(as_string(path));
    return stat != null && stat.mode != null && (int(stat.mode) & 73) != 0;
}

function first_line(path) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        return "";

    let newline = index(data, "\n");
    return trim(newline >= 0 ? substr(data, 0, newline) : data);
}

function valid_job_id(job_id) {
    job_id = as_string(job_id);
    return job_id != "" && job_id != "." && job_id != ".." && match(job_id, /[^A-Za-z0-9._-]/) == null;
}

function job_state_path_value(dir, job_id) {
    if (!valid_job_id(job_id))
        return "";
    return as_string(dir) + "/" + as_string(job_id) + ".json";
}

function job_id() {
    let stamp = clock();
    return sprintf("%d-%d", stamp[0], stamp[1]);
}

function running_service_action_value(action, source, started_at) {
    return {
        success: true,
        running: true,
        kind: "service",
        action: as_string(action),
        source: as_string(source),
        message: "Service action is running",
        pid: null,
        started_at: arg_number(started_at),
        updated_at: null,
        exit_code: null
    };
}

function latency_progress_value(completed, total, failed) {
    let progress_total = non_negative_number(total);
    let progress_completed = non_negative_number(completed);
    if (progress_total > 0 && progress_completed > progress_total)
        progress_completed = progress_total;

    return {
        completed: progress_completed,
        total: progress_total,
        failed: non_negative_number(failed)
    };
}

function proxy_list_total(tag) {
    let value = parse_json_or_null(tag);
    if (type(value) != "array")
        return 0;

    let total = 0;
    for (let proxy_tag in value) {
        if (type(proxy_tag) == "string" && proxy_tag != "")
            total++;
    }

    return total;
}

function initial_latency_progress(latency_type, tag) {
    if (as_string(latency_type) != "proxy_list")
        return null;

    return latency_progress_value(0, proxy_list_total(tag), 0);
}

function running_latency_action_value(latency_type, section, tag, started_at) {
    let value = {
        success: true,
        running: true,
        kind: "latency",
        latency_type: as_string(latency_type),
        section: as_string(section),
        tag: as_string(tag),
        message: "Latency test is running",
        pid: null,
        started_at: arg_number(started_at),
        updated_at: null,
        exit_code: null
    };

    let progress = initial_latency_progress(latency_type, tag);
    if (type(progress) == "object")
        value.progress = progress;

    return value;
}

function latency_action_path_allowed(path) {
    path = as_string(path);
    let prefix = LATENCY_ACTION_DIR + "/";
    let suffix = ".json";
    return path != "" &&
        substr(path, 0, length(prefix)) == prefix &&
        length(path) > length(prefix) + length(suffix) &&
        substr(path, length(path) - length(suffix)) == suffix;
}

function update_latency_progress_state(path, completed, total, failed) {
    if (!latency_action_path_allowed(path))
        return false;

    let value = read_json_file(path);
    if (type(value) != "object" || value.kind != "latency" || value.running !== true)
        return false;

    value.progress = latency_progress_value(completed, total, failed);
    value.updated_at = now_seconds();
    return write_state_file(path, value);
}

function update_latency_progress_state_mode(path, completed, total, failed) {
    exit(update_latency_progress_state(path, completed, total, failed) ? 0 : 1);
}

function finished_action_state_value(path, success, message, exit_code, updated_at) {
    let value = object_or_empty(read_json_file(path));
    value.success = arg_bool(success);
    value.running = false;
    value.message = as_string(message);
    value.exit_code = as_string(exit_code) == "" ? null : arg_number(exit_code);
    value.updated_at = arg_number(updated_at);
    return value;
}

function stale_action_state_value(path, message, updated_at) {
    let value = object_or_empty(read_json_file(path));
    if (value.running === true) {
        value.success = false;
        value.running = false;
        value.message = as_string(message);
        value.exit_code = null;
        value.updated_at = arg_number(updated_at);
    }
    return value;
}

function ack_action_state_value(path, acked_at) {
    let value = object_or_empty(read_json_file(path));
    if (value.running === false)
        value.acked_at = arg_number(acked_at);
    return value;
}

function set_running_job_pid_file(path, pid) {
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

function write_finished_action_state(path, success, message, exit_code) {
    return write_state_file(path, finished_action_state_value(path, success, message, exit_code, now_seconds()));
}

function write_stale_action_state(path, message) {
    return write_state_file(path, stale_action_state_value(path, message, now_seconds()));
}

function pid_running(pid) {
    pid = as_string(pid);
    return job_pid_valid(pid) && command_success_from_args([ "kill", "-0", pid ]);
}

function current_pid() {
    let stat = as_string(fs.readfile("/proc/self/stat"));
    let separator = index(stat, " ");
    return separator > 0 ? substr(stat, 0, separator) : "";
}

function refresh_pid_job_state(path, stale_message) {
    let value = read_json_file(path);
    if (type(value) != "object" || value.running !== true)
        return;

    let now = now_seconds();
    let within_grace = job_started_at_within_grace(value.started_at, now, ACTION_STALE_GRACE_SECONDS);
    let pid = as_string(value.pid || "");

    if (job_pid_valid(pid) && pid_running(pid))
        return;

    if (!within_grace)
        write_stale_action_state(path, stale_message);
}

function state_file_ack_expired(path) {
    let value = read_json_file(path);
    if (type(value) != "object")
        return false;

    let acked_at = unsigned_number(value.acked_at);
    let now = now_seconds();
    let ttl = unsigned_number(ACTION_ACKED_TTL_SECONDS);
    return acked_at != null && now > 0 && ttl != null && now - acked_at >= ttl;
}

function cleanup_dir(dir) {
    dir = as_string(dir);
    let now = now_seconds();
    let ttl_minutes = unsigned_number(ACTION_FINISHED_TTL_MINUTES);

    for (let path in fs.glob(dir + "/*.json")) {
        let value = read_json_file(path);
        if (!valid_action_state(value)) {
            remove_state_file(path);
            continue;
        }

        if (value.running !== false)
            continue;

        if (state_file_ack_expired(path)) {
            remove_state_file(path);
            continue;
        }

        let stat = fs.stat(path);
        if (stat != null && ttl_minutes != null && now - int(stat.mtime || 0) > ttl_minutes * 60)
            remove_state_file(path);
    }
}

function refresh_action_dirs() {
    ensure_dirs();
    cleanup_dir(SERVICE_ACTION_DIR);
    cleanup_dir(LATENCY_ACTION_DIR);
    cleanup_dir(COMPONENT_ACTION_DIR);
    cleanup_dir(SUBSCRIPTION_ACTION_DIR);

    for (let path in fs.glob(SERVICE_ACTION_DIR + "/*.json"))
        refresh_pid_job_state(path, "Service action worker exited unexpectedly");
    for (let path in fs.glob(LATENCY_ACTION_DIR + "/*.json"))
        refresh_pid_job_state(path, "Latency test worker exited unexpectedly");
    for (let path in fs.glob(COMPONENT_ACTION_DIR + "/*.json"))
        refresh_pid_job_state(path, "Component action worker exited unexpectedly");
    for (let path in fs.glob(SUBSCRIPTION_ACTION_DIR + "/*.json"))
        refresh_pid_job_state(path, "Subscription update worker exited unexpectedly");
}

function active_service_action_default() {
    refresh_action_dirs();
    active_service_action(SERVICE_ACTION_DIR);
}

function service_action_idle() {
    refresh_action_dirs();
    exit(active_service_action_value() == "" ? 0 : 1);
}

function action_state_from_dir(dir) {
    let result = [];

    for (let path in fs.glob(as_string(dir) + "/*.json")) {
        let value = read_json_file(path);
        if (!valid_action_state(value))
            continue;

        value.job_id = job_id_from_path(path);
        push(result, value);
    }

    return result;
}

function action_state_from_dirs() {
    return {
        service: action_state_from_dir(SERVICE_ACTION_DIR),
        latency: action_state_from_dir(LATENCY_ACTION_DIR),
        component: action_state_from_dir(COMPONENT_ACTION_DIR),
        subscription: action_state_from_dir(SUBSCRIPTION_ACTION_DIR)
    };
}

function acquire_dir_lock(lock_dir) {
    return locks.acquire(lock_dir, current_pid());
}

function release_dir_lock(lock_dir) {
    locks.release(lock_dir);
}

function service_enabled() {
    return file_executable("/etc/rc.d/S99" + SERVICE_NAME);
}

function sing_box_enabled() {
    return file_executable("/etc/rc.d/S99sing-box");
}

function sing_box_running() {
    return module_success(LIB_DIR + "/service/state.uc", [
        "sing-box-service-stable",
        RUNTIME_STABLE_MIN_AGE
    ]);
}

function forkop_running() {
    return module_success(LIB_DIR + "/service/state.uc", [
        "forkop-stably-running",
        RT_TABLE_NAME,
        NFT_TABLE_NAME,
        NFT_FAKEIP_MARK,
        RUNTIME_STABLE_MIN_AGE
    ]);
}

function dns_configured() {
    return index(uci_core.get("dhcp.@dnsmasq[0].server"), SB_DNS_INBOUND_ADDRESS) >= 0;
}

function marker_is(expected) {
    return first_line(SING_BOX_VARIANT_STATE_FILE) == as_string(expected);
}

function apk_package_installed(package_name) {
    if (!command_success_from_args([ "sh", "-c", "command -v apk" ]))
        return false;
    let installed = command_output_from_args([ "apk", "list", "--installed", "--manifest" ]);
    for (let line in split(installed, "\n")) {
        let fields = split(trim(as_string(line)), /[ \t]+/);
        if (as_string(fields[0]) == as_string(package_name))
            return true;
    }
    return false;
}

function installed_sing_box_package_name() {
    let installed = command_success_from_args([ "sh", "-c", "command -v apk" ]) ?
        command_output_from_args([ "apk", "list", "--installed", "--manifest" ]) : "";
    for (let package_name in [ "rust-x", "sing-box-x", "sing-box-extended", "sing-box-tiny", "sing-box" ]) {
        for (let line in split(installed, "\n"))
            if (split(trim(as_string(line)), /[ \t]+/)[0] == package_name)
                return package_name;
    }

    installed = command_success_from_args([ "sh", "-c", "command -v opkg" ]) ?
        command_output_from_args([ "opkg", "list-installed" ]) : "";
    for (let package_name in [ "rust-x", "sing-box-x", "sing-box-extended", "sing-box-tiny", "sing-box" ]) {
        for (let line in split(installed, "\n"))
            if (split(trim(as_string(line)), /[ \t]+/)[0] == package_name)
                return package_name;
    }

    return "";
}

function tiny_package_installed() {
    if (command_success_from_args([ "sh", "-c", "command -v apk" ]))
        return apk_package_installed("sing-box-tiny");

    let installed = command_output_from_args([ "opkg", "list-installed" ]);
    for (let line in split(installed, "\n"))
        if (split(trim(as_string(line)), /[ \t]+/)[0] == "sing-box-tiny")
            return true;

    return false;
}

function component_action_running_for(component) {
    component = as_string(component);
    for (let path in fs.glob(COMPONENT_ACTION_DIR + "/*.json")) {
        let value = read_json_file(path);
        if (type(value) == "object" && value.running === true && as_string(value.component) == component)
            return true;
    }

    return false;
}

function sing_box_signature() {
    let stat = fs.stat(SING_BOX_BIN_PATH);
    if (stat == null)
        return "";

    return join(":", [ stat.inode, stat.size, stat.mtime, stat.ctime ]);
}

function sing_box_version_info_from_output(output) {
    let first = split(as_string(output), "\n")[0] || "";
    let fields = split(trim(as_string(first)), /[ \t]+/);
    let version = length(fields) > 0 ? fields[length(fields) - 1] : "";
    if (version == "")
        return null;

    let tags = "";
    let features = "";
    for (let line in split(as_string(output), "\n")) {
        line = as_string(line);
        if (substr(line, 0, 5) == "Tags:") {
            tags = trim(substr(line, 5));
        }
        if (substr(line, 0, 9) == "Features:")
            features = trim(substr(line, 9));
    }

    return { version, tags, features };
}

function sing_box_cached_version_info(signature) {
    let cache = read_json_file(SING_BOX_VERSION_CACHE_FILE);
    if (type(cache) == "object" && as_string(cache.signature) == signature) {
        if (cache.success === true && as_string(cache.version) != "" && cache.features != null)
            return { hit: true, info: { version: as_string(cache.version), tags: as_string(cache.tags), features: as_string(cache.features) } };

        let checked_at = arg_number(cache.checked_at);
        let failure_ttl = arg_number(SING_BOX_VERSION_PROBE_FAILURE_TTL_SECONDS);
        if (cache.success === false && checked_at > 0) {
            let failure_age = now_seconds() - checked_at;
            if (failure_age >= 0 && failure_age < failure_ttl)
                return { hit: true, info: null };
        }
    }

    let legacy = split(as_string(fs.readfile(SING_BOX_VERSION_CACHE_FILE)), "\n");
    let legacy_version = as_string(legacy[1] || "");
    if (as_string(legacy[0] || "") == signature && index(legacy_version, "extended") >= 0)
        return { hit: true, info: { version: legacy_version, tags: "" } };

    return null;
}

function bounded_command_output_from_args(args, timeout_seconds) {
    timeout_seconds = arg_number(timeout_seconds);
    if (timeout_seconds <= 0)
        timeout_seconds = 1;

    let pid = current_pid();
    if (!job_pid_valid(pid))
        return "";

    let output_path = SING_BOX_VERSION_CACHE_FILE + "." + pid + ".out";
    remove_file(output_path);

    let script = command_from_args(args) + " >" + shell_quote(output_path) + " 2>/dev/null & child=$!; " +
        "(sleep " + as_string(timeout_seconds) + "; kill -KILL \"$child\" 2>/dev/null) & watchdog=$!; " +
        "wait \"$child\"; rc=$?; kill \"$watchdog\" 2>/dev/null; wait \"$watchdog\" 2>/dev/null; exit \"$rc\"";
    let status = command_status(command_from_args([ "sh", "-c", script ]) + " 2>/dev/null");
    let output = as_string(fs.readfile(output_path));
    remove_file(output_path);
    return status == 0 ? output : "";
}

function sing_box_version_info() {
    if (!file_executable(SING_BOX_BIN_PATH))
        return null;

    let signature = sing_box_signature();
    if (signature == "")
        return null;

    let cached = sing_box_cached_version_info(signature);
    if (cached != null)
        return cached.info;

    ensure_dir(STATE_DIR);
    if (!acquire_dir_lock(SING_BOX_VERSION_CACHE_LOCK_DIR)) {
        cached = sing_box_cached_version_info(signature);
        return cached != null ? cached.info : null;
    }

    cached = sing_box_cached_version_info(signature);
    if (cached != null) {
        release_dir_lock(SING_BOX_VERSION_CACHE_LOCK_DIR);
        return cached.info;
    }

    let output = bounded_command_output_from_args([ SING_BOX_BIN_PATH, "version" ], SING_BOX_VERSION_PROBE_TIMEOUT_SECONDS);
    let info = sing_box_version_info_from_output(output);
    write_state_file(SING_BOX_VERSION_CACHE_FILE, {
        signature,
        success: info != null,
        version: info != null ? info.version : "",
        tags: info != null ? info.tags : "",
        features: info != null ? info.features : "",
        checked_at: now_seconds()
    });
    release_dir_lock(SING_BOX_VERSION_CACHE_LOCK_DIR);
    return info;
}

function capability_flags() {
    let result = {
        sing_box_extended: 0,
        sing_box_tiny: 0,
        sing_box_compressed: 0,
        sing_box_tailscale: 0,
        sing_box_xhttp: 0,
        sing_box_package: ""
    };

    if (file_executable(SING_BOX_BIN_PATH)) {
        result.sing_box_package = installed_sing_box_package_name();
        // A manually installed regular package supersedes a persisted variant
        // marker from a previous Forkop-managed Tiny/Extended installation.
        // Package-manager state is authoritative for this case.
        let regular_installed = result.sing_box_package == "rust-x" || result.sing_box_package == "sing-box" || result.sing_box_package == "sing-box-x";
        if (result.sing_box_package == "sing-box-extended") {
            result.sing_box_extended = 1;
            result.sing_box_tailscale = 1;
        }
        else if (result.sing_box_package == "sing-box-tiny") {
            result.sing_box_tiny = 1;
        }
        else if (!regular_installed && marker_is("extended-compressed")) {
            result.sing_box_extended = 1;
            result.sing_box_compressed = 1;
            result.sing_box_tailscale = 1;
        }
        else if (!regular_installed && marker_is("extended")) {
            result.sing_box_extended = 1;
            result.sing_box_tailscale = 1;
        }
        else if (!regular_installed && (marker_is("tiny") || tiny_package_installed())) {
            result.sing_box_tiny = 1;
        }
        else if (!regular_installed && component_action_running_for("sing_box")) {
            result.sing_box_tailscale = 1;
        }
        else if (!regular_installed || result.sing_box_package == "rust-x") {
            let info = sing_box_version_info();
            if (info != null && index(info.version, "extended") >= 0) {
                result.sing_box_extended = 1;
                result.sing_box_tailscale = 1;
            }
            else if (info != null) {
                if (match(info.tags, /(^|[,: \t])with_tailscale([, \t]|$)/) != null)
                    result.sing_box_tailscale = 1;
            }
        }
    }

    if (file_executable(SING_BOX_BIN_PATH)) {
        let info = sing_box_version_info();
        result.sing_box_xhttp = result.sing_box_extended ||
            (info != null && match(as_string(info.features), /(^|[, \t])transport[.]xhttp([, \t]|$)/) != null) ? 1 : 0;
    }
    return result;
}

function ui_capabilities_json() {
    write_json(capability_flags());
}

function current_ui_state_json() {
    refresh_action_dirs();

    let capabilities = capability_flags();
    let restart_blocked = module_success(STATE_UC, [ "sing-box-process-conflict" ]);
    // Ownership checks may wait for a transient CLI process to exit. Sample
    // health afterward, so the response describes the settled runtime rather
    // than reporting it stopped alongside an already-cleared restart block.
    let forkop_is_running = forkop_running() ? 1 : 0;
    // Health requires sole procd ownership, but Stop must remain available
    // when that check fails while a sing-box or Forkop nft policy remains.
    let stop_available = forkop_is_running ||
        int(trim(command_output_from_args([ "ucode", "-L", LIB_DIR, STATE_UC, "sing-box-process-count" ]))) > 0 ||
        dns_configured() ||
        command_success_from_args([ "nft", "list", "table", "inet", NFT_TABLE_NAME ]);
    let forkop_is_enabled = service_enabled() ? 1 : 0;
    let sing_box_is_running = forkop_is_running ? 1 : (sing_box_running() ? 1 : 0);
    let sing_box_is_enabled = sing_box_enabled() ? 1 : 0;
    let forkop_status = service_status_text(forkop_is_running, forkop_is_enabled);
    let sing_box_status = service_status_text(sing_box_is_running, sing_box_is_enabled);
    let active_action = active_service_action_value();
    let config_error = trim(as_string(fs.readfile(RUNTIME_CONFIG_ERROR_FILE)));

    if (active_action == "start" || (active_action == "" && package_upgrade_transition_active()))
        forkop_status = "starting";
    else if (active_action == "stop")
        forkop_status = "stopping";
    else if (active_action == "restart")
        forkop_status = "restarting";
    else if (active_action == "reload")
        forkop_status = "reloading";

    // One listing answers for every service below, instead of a shell and a ubus
    // round trip per name.
    let procd_services = process_memory.ubus_services("");

    write_json({
        service: {
            forkop: {
                running: forkop_is_running,
                memory_rss_bytes: process_memory.services_group_rss_bytes(
                    procd_services, FORKOP_SERVICE_NAMES, "/proc"),
                restart_blocked: restart_blocked ? 1 : 0,
                stop_available: stop_available ? 1 : 0,
                enabled: forkop_is_enabled,
                status: forkop_status,
                dns_configured: dns_configured() ? 1 : 0
            },
            sing_box: {
                running: sing_box_is_running,
                memory_rss_bytes: process_memory.services_group_rss_bytes(
                    procd_services, CORE_SERVICE_NAMES, "/proc"),
                enabled: sing_box_is_enabled,
                status: sing_box_status
            }
        },
        config_error,
        subscription_error: read_json_file(SUBSCRIPTION_APPLY_ERROR_FILE),
        capabilities,
        actions: action_state_from_dirs()
    });
}

function service_action_expected_running_value(action) {
    action = as_string(action);
    if (action == "start" || action == "restart" || action == "reload")
        return 1;
    if (action == "stop")
        return 0;
    return -1;
}

function service_action_reached_expected_state(action) {
    let expected = service_action_expected_running_value(action);
    if (expected < 0)
        return false;
    return expected == 1 ? forkop_running() : !forkop_running();
}

function service_action_wait_for_expected_state(action, timeout, settle_seconds) {
    timeout = arg_number(timeout || SERVICE_ACTION_TIMEOUT_SECONDS);
    settle_seconds = arg_number(settle_seconds || SERVICE_ACTION_SETTLE_SECONDS);
    let deadline = now_seconds() + timeout;
    let stable_seconds = 0;

    while (true) {
        if (service_action_reached_expected_state(action)) {
            stable_seconds++;
            if (stable_seconds >= settle_seconds)
                return true;
        }
        else {
            stable_seconds = 0;
        }

        if (now_seconds() >= deadline)
            return false;
        system("sleep 1");
    }
}

function begin_service_action_if_idle(action, source) {
    action = as_string(action);
    source = as_string(source || "ui");
    if (!service_action_valid(action))
        return { status: 1, job_id: "" };

    // Package prerm/postinst owns the complete stop -> detached start ->
    // stable-runtime transition. Never let a manual LuCI action race it.
    if (package_upgrade_transition_active())
        return { status: 2, job_id: "" };

    ensure_dirs();
    if (!acquire_dir_lock(SERVICE_ACTION_LOCK_DIR))
        return { status: 2, job_id: "" };

    // An upgrade may have claimed the transition after the unlocked check.
    if (package_upgrade_transition_active()) {
        release_dir_lock(SERVICE_ACTION_LOCK_DIR);
        return { status: 2, job_id: "" };
    }

    refresh_action_dirs();
    if (active_service_action_value() != "") {
        release_dir_lock(SERVICE_ACTION_LOCK_DIR);
        return { status: 2, job_id: "" };
    }

    let id = job_id();
    let path = job_state_path_value(SERVICE_ACTION_DIR, id);
    if (path == "" || !write_state_file(path, running_service_action_value(action, source, now_seconds()))) {
        release_dir_lock(SERVICE_ACTION_LOCK_DIR);
        return { status: 1, job_id: "" };
    }

    release_dir_lock(SERVICE_ACTION_LOCK_DIR);
    return { status: 0, job_id: id };
}

function begin_package_upgrade_quiesce(pid, replace_owner) {
    pid = as_string(pid);
    if (!job_pid_valid(pid))
        return false;

    ensure_dirs();
    if (!acquire_dir_lock(SERVICE_ACTION_LOCK_DIR))
        return false;

    // The shared lock makes marker publication atomic with a new LuCI action.
    let ticks = process_start_ticks(pid);
    let claimed = false;
    if (ticks != null && (replace_owner || !package_upgrade_transition_active())) {
        let temporary = PACKAGE_UPGRADE_QUIESCE_FILE + "." + pid + ".tmp";
        claimed = write_file(temporary, pid + " " + ticks + "\n") &&
            fs.rename(temporary, PACKAGE_UPGRADE_QUIESCE_FILE);
        if (!claimed)
            remove_file(temporary);
    }
    release_dir_lock(SERVICE_ACTION_LOCK_DIR);
    return claimed;
}

function clear_package_upgrade_quiesce_if_owner(pid) {
    if (!acquire_dir_lock(SERVICE_ACTION_LOCK_DIR))
        return false;
    if (package_upgrade_quiesce_owned(pid))
        remove_file(PACKAGE_UPGRADE_QUIESCE_FILE);
    release_dir_lock(SERVICE_ACTION_LOCK_DIR);
    return true;
}

function begin_package_upgrade_quiesce_mode(pid, replace_owner) {
    exit(begin_package_upgrade_quiesce(pid, replace_owner) ? 0 : 1);
}

function begin_service_action_mode(action, source) {
    let result = begin_service_action_if_idle(action, source || "ui");
    if (result.status == 0)
        print(result.job_id, "\n");
    exit(result.status);
}

function finish_service_action(job_id_value, success, message, exit_code) {
    let path = job_state_path_value(SERVICE_ACTION_DIR, job_id_value);
    if (path == "" || fs.stat(path) == null)
        return false;
    return write_finished_action_state(path, success, message, exit_code);
}

function finish_service_action_mode(job_id_value, success, message, exit_code) {
    exit(finish_service_action(job_id_value, success, message, exit_code) ? 0 : 1);
}

function launch_worker(args) {
    let command_args = [ "ucode", "-L", LIB_DIR, UI_UC ];
    for (let arg in args)
        push(command_args, arg);

    let command = command_env({
        FORKOP_CONFIG_NAME: CONFIG_NAME,
        FORKOP_LIB: LIB_DIR,
        FORKOP_BIN: BIN_PATH,
        FORKOP_SERVICE_INIT: SERVICE_INIT,
        FORKOP_SERVICE_NAME: SERVICE_NAME,
        FORKOP_UI_STATE_DIR: STATE_DIR,
        FORKOP_UI_SERVICE_ACTION_DIR: SERVICE_ACTION_DIR,
        FORKOP_UI_SERVICE_ACTION_LOCK_DIR: SERVICE_ACTION_LOCK_DIR,
        FORKOP_UI_LATENCY_ACTION_DIR: LATENCY_ACTION_DIR,
        FORKOP_UI_COMPONENT_ACTION_DIR: COMPONENT_ACTION_DIR,
        FORKOP_UI_SUBSCRIPTION_ACTION_DIR: SUBSCRIPTION_ACTION_DIR,
        FORKOP_UI_SING_BOX_VERSION_CACHE_FILE: SING_BOX_VERSION_CACHE_FILE,
        FORKOP_UI_SING_BOX_VERSION_CACHE_LOCK_DIR: SING_BOX_VERSION_CACHE_LOCK_DIR,
        FORKOP_UI_SING_BOX_VARIANT_STATE_FILE: SING_BOX_VARIANT_STATE_FILE,
        FORKOP_UI_SING_BOX_BIN_PATH: SING_BOX_BIN_PATH,
        FORKOP_UI_SING_BOX_VERSION_PROBE_TIMEOUT_SECONDS: SING_BOX_VERSION_PROBE_TIMEOUT_SECONDS,
        FORKOP_UI_SING_BOX_VERSION_PROBE_FAILURE_TTL_SECONDS: SING_BOX_VERSION_PROBE_FAILURE_TTL_SECONDS,
        FORKOP_UI_ACTION_FINISHED_TTL_MINUTES: ACTION_FINISHED_TTL_MINUTES,
        FORKOP_UI_ACTION_ACKED_TTL_SECONDS: ACTION_ACKED_TTL_SECONDS,
        FORKOP_UI_ACTION_STALE_GRACE_SECONDS: ACTION_STALE_GRACE_SECONDS,
        FORKOP_UI_SERVICE_ACTION_TIMEOUT_SECONDS: SERVICE_ACTION_TIMEOUT_SECONDS,
        FORKOP_UI_SERVICE_ACTION_SETTLE_SECONDS: SERVICE_ACTION_SETTLE_SECONDS,
        FORKOP_PENDING_RELOAD_FILE: PENDING_RELOAD_FILE,
        NFT_TABLE_NAME,
        RT_TABLE_NAME,
        NFT_FAKEIP_MARK,
        SB_DNS_INBOUND_ADDRESS
    }) + " " +
        command_from_args(command_args) +
        " >/dev/null 2>&1 1000>&- & echo $!";
    return trim(command_output("sh -c " + shell_quote(command)));
}

function start_service_action(action, source, reason) {
    let begin = begin_service_action_if_idle(action, source || "ui");
    if (begin.status != 0)
        return { success: false, job_id: "" };

    let path = job_state_path_value(SERVICE_ACTION_DIR, begin.job_id);
    if (path == "")
        return { success: false, job_id: begin.job_id };

    let pid = launch_worker([ "service-action-worker", path, action, begin.job_id, reason || "" ]);
    if (pid == "" || !set_running_job_pid_file(path, pid)) {
        if (pid != "")
            command_success_from_args([ "kill", pid ]);
        write_finished_action_state(path, false, "Failed to write service action worker pid", 1);
        return { success: false, job_id: begin.job_id };
    }

    return { success: true, job_id: begin.job_id };
}

function service_action_allows_pending_reload(action) {
    action = as_string(action);
    return action == "start" || action == "restart" || action == "reload";
}

function consume_pending_reload() {
    return command_success_from_args([
        "ucode",
        "-L", LIB_DIR,
        STATE_UC,
        "consume-pending-reload",
        PENDING_RELOAD_FILE
    ]);
}

function mark_pending_reload(reason) {
    return command_success_from_args([
        "ucode",
        "-L", LIB_DIR,
        STATE_UC,
        "mark-pending-reload",
        PENDING_RELOAD_FILE,
        reason
    ]);
}

function run_pending_reload_after_service_action(action, success) {
    if (!success || !service_action_allows_pending_reload(action) || fs.stat(STATE_UC) == null)
        return;

    if (!consume_pending_reload())
        return;

    command_success_from_args([ "logger", "-t", SERVICE_NAME, "[info] Applying pending Forkop reload" ]);
    let started = start_service_action("reload", "initd", "pending");
    if (!started.success)
        mark_pending_reload("pending");
}

function write_finished_service_action_state(path, action, success, message, exit_code) {
    let written = write_finished_action_state(path, success, message, exit_code);
    if (written)
        run_pending_reload_after_service_action(action, success);
    return written;
}

function finish_service_action_after_command(action, job_id_value, status, spawn_waiter) {
    status = arg_number(status);
    if (as_string(job_id_value) == "")
        return 0;

    let path = job_state_path_value(SERVICE_ACTION_DIR, job_id_value);
    if (path == "" || fs.stat(path) == null)
        return 0;

    if (status != 0) {
        let config_error = trim(as_string(fs.readfile(RUNTIME_CONFIG_ERROR_FILE)));
        let message = action == "restart" && status == 75
            ? "Forkop X is busy updating data or applying settings. Wait for the operation to finish, then try restarting again."
            : (config_error != "" ? config_error : "Service " + as_string(action) + " failed");
        write_finished_service_action_state(path, action, false, message, status);
        return 0;
    }

    if (!service_enabled() && !forkop_running()) {
        write_finished_service_action_state(path, action, true, "Service " + as_string(action) + " completed", 0);
        return 0;
    }

    if (spawn_waiter) {
        let pid = launch_worker([ "service-action-wait-worker", path, as_string(action), as_string(job_id_value) ]);
        if (pid != "")
            set_running_job_pid_file(path, pid);
        return 0;
    }

    if (service_action_wait_for_expected_state(action, SERVICE_ACTION_TIMEOUT_SECONDS, SERVICE_ACTION_SETTLE_SECONDS))
        write_finished_service_action_state(path, action, true, "Service " + as_string(action) + " completed", 0);
    else
        write_finished_service_action_state(path, action, false, "Service " + as_string(action) + " did not reach expected state", 1);
    return 0;
}

function finish_service_action_after_command_mode(action, job_id_value, status) {
    finish_service_action_after_command(action, job_id_value, status, true);
}

function update_service_action_pid_mode(job_id_value, pid) {
    let path = job_state_path_value(SERVICE_ACTION_DIR, job_id_value);
    exit(path != "" && set_running_job_pid_file(path, pid) ? 0 : 1);
}

function service_action_worker(path, action, job_id_value, reason) {
    reason = as_string(reason || "");
    let args = reason == "manual-ui-restart" ? [ BIN_PATH, "manual_restart" ] : [ SERVICE_INIT, action ];
    if (reason != "" && reason != "manual-ui-restart")
        push(args, reason);
    let command = "FORKOP_UI_ACTION_TRACKED=1 " + command_from_args(args) + " >/dev/null 2>&1";
    let status = command_status(command);
    finish_service_action_after_command(action, job_id_value, status, false);
}

function service_action_wait_worker(path, action, job_id_value) {
    if (service_action_wait_for_expected_state(action, SERVICE_ACTION_TIMEOUT_SECONDS, SERVICE_ACTION_SETTLE_SECONDS))
        write_finished_service_action_state(path, action, true, "Service " + as_string(action) + " completed", 0);
    else
        write_finished_service_action_state(path, action, false, "Service " + as_string(action) + " did not reach expected state", 1);
}

function service_action_async(action) {
    action = as_string(action);
    if (!service_action_valid(action)) {
        action_start_response(false, "", "Invalid service action");
        exit(1);
    }

    let started = start_service_action(action, "ui", action == "restart" ? "manual-ui-restart" : "");
    if (!started.success && package_upgrade_transition_active()) {
        action_start_response(false, "", "Forkop package upgrade is still restoring the service");
        exit(1);
    }
    if (!started.success && active_service_action_value() != "") {
        action_start_response(false, "", "Another service action is already running");
        exit(1);
    }
    if (!started.success) {
        action_start_response(false, "", "Failed to write service action worker pid");
        exit(1);
    }

    action_start_response(true, started.job_id, "Service " + action + " started");
}

function service_action_status(job_id_value) {
    let path = job_state_path_value(SERVICE_ACTION_DIR, job_id_value);
    if (path == "") {
        action_start_response(false, "", "Invalid service action job id");
        exit(1);
    }
    if (fs.stat(path) == null) {
        action_start_response(false, "", "Service action job was not found");
        exit(1);
    }

    refresh_pid_job_state(path, "Service action worker exited unexpectedly");
    print(as_string(fs.readfile(path)));
}

function latency_clash_method(latency_type) {
    latency_type = as_string(latency_type);
    if (latency_type == "group")
        return { method: "get_group_latency", timeout: "10000" };
    if (latency_type == "proxy_list")
        return { method: "get_proxy_latencies", timeout: "5000" };
    return { method: "get_proxy_latency", timeout: "5000" };
}

function latency_worker(path, latency_type, tag, timeout) {
    let owner_pid = current_pid();
    if (owner_pid == "" || !module_success(STATE_UC, [
        "acquire-runtime-dir-lock", LATENCY_TEST_LOCK_DIR, owner_pid
    ])) {
        write_finished_action_state(path, false, "Another latency test is already running", 1);
        return;
    }

    let method = latency_clash_method(latency_type).method;
    let status = command_status(command_from_args([ BIN_PATH, "clash_api", method, tag, timeout, path ]) + " >/dev/null 2>&1");
    module_success(STATE_UC, [ "release-runtime-dir-lock", LATENCY_TEST_LOCK_DIR ]);
    if (status == 0)
        write_finished_action_state(path, true, "Latency test completed", status);
    else
        write_finished_action_state(path, false, "Latency test failed", status);
}

// A lock whose owner is gone must not refuse the next test. The worker takes
// over a stale lock when it acquires, so refusing here on the directory alone
// let one killed worker block every manual test until the next automatic
// sweep. Name the progress of the test that really is running, because the
// bare sentence looks the same to the operator as a lock nobody holds.
function running_latency_test_reason() {
    if (fs.stat(LATENCY_TEST_LOCK_DIR) == null)
        return "";
    // What counts as a held lock is decided in one place, including a lock
    // created moments ago whose owner is not written yet.
    if (!locks.held(LATENCY_TEST_LOCK_DIR))
        return "";

    let message = "Another latency test is already running";
    for (let value in action_state_from_dir(LATENCY_ACTION_DIR)) {
        if (value.running !== true || type(value.progress) != "object")
            continue;
        let total = non_negative_number(value.progress.total);
        if (total <= 0)
            continue;
        return message + " (" + non_negative_number(value.progress.completed) +
            " of " + total + ")";
    }
    return message;
}

function latency_test_async(latency_type, section, tag, requested_timeout) {
    latency_type = as_string(latency_type);
    tag = as_string(tag);
    if (!latency_type_valid(latency_type)) {
        action_start_response(false, "", "Invalid latency test type");
        exit(1);
    }
    if (tag == "") {
        action_start_response(false, "", "Latency test tag is required");
        exit(1);
    }

    // The automatic startup/subscription sweep and a user-requested test share
    // one runtime lock. Reject early so the UI can report the real reason
    // instead of briefly showing a second, doomed progress job.
    let running_reason = running_latency_test_reason();
    if (running_reason != "") {
        action_start_response(false, "", running_reason);
        exit(1);
    }

    ensure_dirs();
    let id = job_id();
    let path = job_state_path_value(LATENCY_ACTION_DIR, id);
    if (path == "" || !write_state_file(path, running_latency_action_value(latency_type, section, tag, now_seconds()))) {
        action_start_response(false, "", "Failed to write latency test state");
        exit(1);
    }

    let plan = latency_clash_method(latency_type);
    let timeout = as_string(requested_timeout) != "" ? as_string(requested_timeout) : plan.timeout;
    let pid = launch_worker([ "latency-worker", path, latency_type, tag, timeout ]);
    if (pid == "" || !set_running_job_pid_file(path, pid)) {
        if (pid != "")
            command_success_from_args([ "kill", pid ]);
        action_start_response(false, "", "Failed to write latency test worker pid");
        exit(1);
    }

    action_start_response(true, id, "Latency test started");
}

function latency_test_status(job_id_value) {
    let path = job_state_path_value(LATENCY_ACTION_DIR, job_id_value);
    if (path == "") {
        action_start_response(false, "", "Invalid latency test job id");
        exit(1);
    }
    if (fs.stat(path) == null) {
        action_start_response(false, "", "Latency test job was not found");
        exit(1);
    }

    refresh_pid_job_state(path, "Latency test worker exited unexpectedly");
    print(as_string(fs.readfile(path)));
}

function action_dir(kind) {
    kind = as_string(kind);
    if (kind == "service")
        return SERVICE_ACTION_DIR;
    if (kind == "latency")
        return LATENCY_ACTION_DIR;
    if (kind == "component")
        return COMPONENT_ACTION_DIR;
    if (kind == "subscription")
        return SUBSCRIPTION_ACTION_DIR;
    return "";
}

function action_ack(kind, job_id_value) {
    let dir = action_dir(kind);
    if (dir == "") {
        action_start_response(false, "", "Invalid UI action kind");
        exit(1);
    }

    let path = job_state_path_value(dir, job_id_value);
    if (path == "") {
        action_start_response(false, "", "Invalid UI action job id");
        exit(1);
    }

    if (fs.stat(path) == null) {
        action_start_response(true, job_id_value, "UI action already acknowledged");
        return;
    }

    let value = read_json_file(path);
    if (type(value) == "object" && value.running === true) {
        action_start_response(false, job_id_value, "UI action is still running");
        exit(1);
    }

    if (!write_state_file(path, ack_action_state_value(path, now_seconds()))) {
        action_start_response(false, job_id_value, "Failed to acknowledge UI action");
        exit(1);
    }

    action_start_response(true, job_id_value, "UI action acknowledged");
}

let mode = ARGV[0] || "";

if (mode == "ui-state-json")
    ui_state_json();
else if (mode == "get-ui-capabilities")
    ui_capabilities_json();
else if (mode == "get-ui-state")
    current_ui_state_json();
else if (mode == "service-status-text")
    print_service_status_text(ARGV[1], ARGV[2]);
else if (mode == "service-action-valid")
    exit(service_action_valid(ARGV[1]) ? 0 : 1);
else if (mode == "package-upgrade-transition-active")
    exit(package_upgrade_transition_active() ? 0 : 1);
else if (mode == "clear-package-upgrade-quiesce-if-owner")
    exit(clear_package_upgrade_quiesce_if_owner(ARGV[1]) ? 0 : 1);
else if (mode == "latency-type-valid")
    exit(latency_type_valid(ARGV[1]) ? 0 : 1);
else if (mode == "service-action-expected-running")
    service_action_expected_running(ARGV[1]);
else if (mode == "stale-action-state")
    stale_action_state(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "action-ack-expired")
    action_ack_expired(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "json-file-field")
    json_file_field(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "job-state-path")
    job_state_path(ARGV[1], ARGV[2]);
else if (mode == "job-refresh-plan")
    job_refresh_plan(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "active-service-action")
    ARGV[1] == null ? active_service_action_default() : active_service_action(ARGV[1]);
else if (mode == "service-action-idle")
    service_action_idle();
else if (mode == "component-action-running-for")
    exit(component_action_running_for(ARGV[1]) ? 0 : 1);
else if (mode == "service-action-begin-if-idle")
    begin_service_action_mode(ARGV[1], ARGV[2] || "ui");
else if (mode == "begin-package-upgrade-quiesce")
    begin_package_upgrade_quiesce_mode(ARGV[1], false);
else if (mode == "transfer-package-upgrade-quiesce")
    begin_package_upgrade_quiesce_mode(ARGV[1], true);
else if (mode == "service-action-update-pid")
    update_service_action_pid_mode(ARGV[1], ARGV[2]);
else if (mode == "service-action-finish")
    finish_service_action_mode(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "latency-progress-state")
    update_latency_progress_state_mode(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "service-action-finish-after-command")
    finish_service_action_after_command_mode(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "service-action-wait-worker")
    service_action_wait_worker(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "service-action-worker")
    service_action_worker(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "service-action-async")
    service_action_async(ARGV[1]);
else if (mode == "service-action-status")
    service_action_status(ARGV[1]);
else if (mode == "latency-worker")
    latency_worker(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "latency-test-async")
    latency_test_async(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "latency-test-status")
    latency_test_status(ARGV[1]);
else if (mode == "action-ack")
    action_ack(ARGV[1], ARGV[2]);
else if (mode == "cleanup-action-dir-fixture")
    cleanup_dir(ARGV[1]);
else {
    warn("Usage: service/ui.uc <operation> ...\n");
    exit(1);
}
