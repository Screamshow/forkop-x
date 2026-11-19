#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let worker_identity = require("core.worker_identity");

let as_string = common.as_string;
let read_json_file = common.read_json_file;
let write_json = common.write_json;
let array_or_empty = common.array_or_empty;
let object_or_empty = common.object_or_empty;

const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const RUNTIME_STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const SECTION_CACHE_DIR = getenv("FORKOP_SECTION_CACHE_DIR") || RUNTIME_STATE_DIR + "/section-cache";
const PRIORITY_PID_FILE = getenv("FORKOP_PRIORITY_PID_FILE") || RUNTIME_STATE_DIR + "/priority.pid";
const PRIORITY_UC = getenv("FORKOP_PRIORITY_UC") || LIB_DIR + "/singbox/priority.uc";
const DIAGNOSTICS_UC = getenv("FORKOP_DIAGNOSTICS_UC") || LIB_DIR + "/diagnostics/runtime.uc";

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
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
    return command_status(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function ensure_dir(path) {
    return command_success_from_args([ "mkdir", "-p", path ]);
}

function remove_file(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "forkop", "[" + level + "] priority: " + as_string(message) ]);
}

function now_seconds() {
    return int(clock()[0]);
}

function duration_to_milliseconds(value, fallback_ms) {
    let rest = as_string(value);
    if (rest == "")
        return fallback_ms;

    let total = 0.0;
    let multipliers = {
        ns: 0.000001,
        us: 0.001,
        ms: 1,
        s: 1000,
        m: 60000,
        h: 3600000,
        d: 86400000
    };

    while (rest != "") {
        let matched = match(rest, /^([0-9]+(\.[0-9]+)?)(ns|us|ms|s|m|h|d)/);
        if (!matched)
            return fallback_ms;

        let token = as_string(matched[0]);
        total += (matched[1] * 1) * multipliers[matched[3]];
        rest = substr(rest, length(token));
    }

    return total <= 0 ? fallback_ms : int(total + 0.5);
}

function duration_to_seconds(value, fallback_seconds) {
    let ms = duration_to_milliseconds(value, fallback_seconds * 1000);
    let seconds = int((ms + 999) / 1000);
    return seconds > 0 ? seconds : fallback_seconds;
}

function bool_value(value, fallback) {
    if (value == null || value == "")
        return !!fallback;
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function normalize_group(group, tag_name) {
    group = object_or_empty(group);
    let levels = [];
    for (let level in array_or_empty(group.levels)) {
        let outbounds = [];
        for (let outbound in array_or_empty(level.outbounds)) {
            outbound = as_string(outbound);
            if (outbound != "")
                push(outbounds, outbound);
        }
        if (length(outbounds) > 0) {
            push(levels, {
                id: as_string(level.id || ""),
                displayName: as_string(level.displayName || level.name || ""),
                order: int(level.order || 0),
                outbounds
            });
        }
    }

    return {
        id: as_string(group.id || ""),
        tag: as_string(group.tag || tag_name),
        section: as_string(group.section || ""),
        displayName: as_string(group.displayName || group.name || tag_name),
        health_url: as_string(group.health_url || "https://www.gstatic.com/generate_204"),
        active_check_interval: as_string(group.active_check_interval || "5s"),
        check_timeout: as_string(group.check_timeout || "2s"),
        recovery_check_interval: as_string(group.recovery_check_interval || "15s"),
        pick_fastest: bool_value(group.pick_fastest, false),
        switch_to_faster_same_priority: bool_value(group.switch_to_faster_same_priority, false),
        fastest_check_interval: as_string(group.fastest_check_interval || "3m"),
        levels
    };
}

function section_cache_files() {
    let result = [];
    for (let path in split(command_output_from_args([
        "find",
        SECTION_CACHE_DIR,
        "-mindepth",
        "1",
        "-maxdepth",
        "1",
        "-type",
        "f",
        "-name",
        "*.json"
    ]), "\n")) {
        path = as_string(path);
        if (path != "")
            push(result, path);
    }
    return result;
}

function priority_groups_from_cache() {
    let result = [];
    for (let path in section_cache_files()) {
        let cache = object_or_empty(read_json_file(path));
        for (let tag_name, group in object_or_empty(cache.priorityGroups)) {
            let normalized = normalize_group(group, tag_name);
            if (normalized.tag != "" && length(normalized.levels) > 0)
                push(result, normalized);
        }
    }
    return result;
}

function module_capture(args) {
    let output_path = trim(command_output_from_args([ "mktemp" ]));
    if (output_path == "")
        return { status: 1, output: "" };

    let command = command_from_args([ "ucode", "-L", LIB_DIR, DIAGNOSTICS_UC, "clash-api" ]);
    for (let arg in args)
        command += " " + shell_quote(arg);

    let status = command_status(command + " >" + shell_quote(output_path) + " 2>&1");
    let output = as_string(fs.readfile(output_path) || "");
    remove_file(output_path);
    return { status, output };
}

function parse_delay_output(output) {
    let value = null;
    try {
        value = json(output);
    }
    catch (e) {
        return null;
    }

    if (type(value) != "object")
        return null;

    let delay = value.delay;
    if (delay == null || as_string(delay) == "")
        return null;

    delay = int(delay, 10);
    return delay >= 0 ? delay : null;
}

function clash_probe(tag_name, group) {
    let timeout = as_string(duration_to_milliseconds(group.check_timeout, 2000));
    let result = module_capture([ "get_proxy_latency", tag_name, timeout, group.health_url ]);
    if (result.status != 0)
        return { alive: false, delay: 0 };

    let delay = parse_delay_output(result.output);
    if (delay == null)
        return { alive: false, delay: 0 };

    return { alive: true, delay };
}

function fixture_probe(latencies, tag_name) {
    let value = object_or_empty(latencies)[tag_name];
    if (value == null || as_string(value) == "" || int(value, 10) < 0)
        return { alive: false, delay: 0 };
    return { alive: true, delay: int(value, 10) };
}

function new_probe_scan(group, kind, first_level, last_level, skip_tag, active_tag) {
    return {
        kind,
        level: max(0, int(first_level || 0)),
        last_level: min(length(group.levels) - 1, int(last_level || 0)),
        member: 0,
        skip_tag: as_string(skip_tag),
        active_tag: as_string(active_tag),
        active_delay: null,
        best: null
    };
}

// One network probe per step. Finish the first level with a live member
// before looking at lower priorities, even when choosing the fastest member.
function advance_probe_scan(group, scan, probe) {
    while (scan.level <= scan.last_level) {
        let members = group.levels[scan.level].outbounds;
        while (scan.member < length(members)) {
            let tag = members[scan.member++];
            if (tag == scan.skip_tag)
                continue;

            let result = probe(tag, group);
            if (result.alive) {
                if (tag == scan.active_tag)
                    scan.active_delay = result.delay;
                if (scan.best == null || result.delay < scan.best.delay)
                    scan.best = { tag, levelIndex: scan.level, delay: result.delay };
                if (!group.pick_fastest && scan.kind != "fastest")
                    return true;
            }
            return false;
        }
        if (scan.best != null)
            return true;
        scan.level++;
        scan.member = 0;
    }
    return true;
}

function probe_scan_selection(scan) {
    let best = scan.best;
    if (best != null && best.tag != scan.active_tag &&
        (scan.active_delay == null || best.delay < scan.active_delay))
        return best;
    return null;
}

function set_group_proxy(group, tag_name) {
    let result = module_capture([ "set_group_proxy", group.tag, tag_name, "" ]);
    return result.status == 0;
}

function switch_group(state, group, selected) {
    if (selected == null || selected.tag == "")
        return false;

    if (state.active == selected.tag) {
        state.levelIndex = selected.levelIndex;
        state.activeDelay = selected.delay;
        return true;
    }

    if (!set_group_proxy(group, selected.tag)) {
        log_message("failed to switch " + group.tag + " to " + selected.tag, "warn");
        return false;
    }

    state.active = selected.tag;
    state.levelIndex = selected.levelIndex;
    state.activeDelay = selected.delay;
    return true;
}

function init_group_state(group) {
    return {
        active: "",
        levelIndex: -1,
        activeDelay: 0,
        scan: null,
        nextActiveCheck: now_seconds(),
        nextRecoveryCheck: now_seconds() + duration_to_seconds(group.recovery_check_interval, 15),
        nextFastestCheck: now_seconds() + duration_to_seconds(group.fastest_check_interval, 180)
    };
}

function finish_group_scan(state, group) {
    let scan = state.scan;
    state.scan = null;
    let switched = switch_group(state, group, probe_scan_selection(scan));
    let now = now_seconds();

    if (scan.kind == "recovery") {
        state.nextRecoveryCheck = now + duration_to_seconds(group.recovery_check_interval, 15);
        if (switched)
            state.nextFastestCheck = now + duration_to_seconds(group.fastest_check_interval, 180);
        return;
    }
    if (scan.kind == "fastest") {
        state.nextFastestCheck = now + duration_to_seconds(group.fastest_check_interval, 180);
        return;
    }
    if (scan.kind == "failover") {
        if (switched) {
            state.nextRecoveryCheck = now + duration_to_seconds(group.recovery_check_interval, 15);
            state.nextFastestCheck = now + duration_to_seconds(group.fastest_check_interval, 180);
        }
        else {
            state.active = "";
            state.levelIndex = -1;
        }
    }
    state.nextActiveCheck = now + duration_to_seconds(group.active_check_interval, 5);
}

function tick_group(state, group, probe) {
    if (state.scan != null) {
        if (advance_probe_scan(group, state.scan, probe))
            finish_group_scan(state, group);
        return true;
    }

    // Choose the oldest scheduled check so repeated active checks cannot
    // crowd out recovery or fastest checks when other groups are busy.
    let kind = "active";
    let deadline = state.nextActiveCheck;
    if (state.active != "" && state.levelIndex > 0 && state.nextRecoveryCheck < deadline) {
        kind = "recovery";
        deadline = state.nextRecoveryCheck;
    }
    if (state.active != "" && group.switch_to_faster_same_priority && state.nextFastestCheck < deadline) {
        kind = "fastest";
        deadline = state.nextFastestCheck;
    }
    if (now_seconds() < deadline)
        return false;

    if (kind == "recovery")
        state.scan = new_probe_scan(group, kind, 0, state.levelIndex - 1);
    else if (kind == "fastest")
        state.scan = new_probe_scan(group, kind, state.levelIndex, state.levelIndex, "", state.active);
    else if (state.active == "")
        state.scan = new_probe_scan(group, "initial", 0, length(group.levels) - 1);
    else {
        let active = probe(state.active, group);
        if (active.alive) {
            state.activeDelay = active.delay;
            state.nextActiveCheck = now_seconds() + duration_to_seconds(group.active_check_interval, 5);
        }
        else {
            state.scan = new_probe_scan(group, "failover", state.levelIndex, length(group.levels) - 1, state.active);
        }
    }
    return true;
}

function tick_groups(groups, states, probe) {
    let busy = false;
    for (let group in groups)
        if (tick_group(states[group.tag], group, probe))
            busy = true;
    return busy;
}

function worker() {
    let groups = priority_groups_from_cache();
    if (length(groups) == 0)
        return 0;

    let states = {};
    for (let group in groups)
        states[group.tag] = init_group_state(group);

    while (true)
        if (!tick_groups(groups, states, clash_probe))
            sleep(1000);
}

function stop_runtime() {
    return worker_identity.stop(PRIORITY_PID_FILE, PRIORITY_UC, LIB_DIR) ? 0 : 1;
}

function start_runtime() {
    let groups = priority_groups_from_cache();
    if (stop_runtime() != 0)
        return 1;
    if (length(groups) == 0)
        return 0;

    if (!ensure_dir(RUNTIME_STATE_DIR))
        return 1;

    let command = command_from_args([ "ucode", "-L", LIB_DIR, PRIORITY_UC, "worker" ]) +
        " >/dev/null 2>&1 1000>&- & echo $! >" + shell_quote(PRIORITY_PID_FILE);
    if (command_status(command) != 0)
        return 1;
    if (worker_identity.record_started(PRIORITY_PID_FILE, PRIORITY_UC, LIB_DIR))
        return 0;
    stop_runtime();
    return 1;
}

function select_fixture(group_path, latency_path, start_index, end_index, skip_tag) {
    let group = normalize_group(read_json_file(group_path), "fixture");
    let latencies = object_or_empty(read_json_file(latency_path));
    let scan = new_probe_scan(group, "initial", start_index, end_index, skip_tag);
    while (!advance_probe_scan(group, scan, (tag) => fixture_probe(latencies, tag))) {}
    write_json(probe_scan_selection(scan) || {});
}

function select_faster_fixture(group_path, latency_path, level_index, active_tag) {
    let group = normalize_group(read_json_file(group_path), "fixture");
    let latencies = object_or_empty(read_json_file(latency_path));
    let scan = new_probe_scan(group, "fastest", level_index, level_index, "", active_tag);
    while (!advance_probe_scan(group, scan, (tag) => fixture_probe(latencies, tag))) {}
    write_json(probe_scan_selection(scan) || {});
}

let mode = ARGV[0] || "";

if (mode == "start-runtime")
    exit(start_runtime());
else if (mode == "stop-runtime")
    exit(stop_runtime());
else if (mode == "worker")
    exit(worker());
else if (mode == "select-fixture")
    select_fixture(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]);
else if (mode == "select-faster-fixture")
    select_faster_fixture(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else {
    warn("Usage: singbox/priority.uc <start-runtime|stop-runtime|worker|select-fixture|select-faster-fixture>\n");
    exit(1);
}
