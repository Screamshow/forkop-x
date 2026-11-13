#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let common = require("core.common");
let core_ip = require("core.ip");
let runtime_dns = require("singbox.dns");
let worker_identity = require("core.worker_identity");
let runtime_health = require("core.runtime_health");

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const RUNTIME_STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const STATE_FILE = getenv("FORKOP_DNS_FAILOVER_STATE_FILE") || RUNTIME_STATE_DIR + "/dns-failover.json";
const PID_FILE = getenv("FORKOP_DNS_FAILOVER_PID_FILE") || RUNTIME_STATE_DIR + "/dns-failover.pid";
const DNS_FAILOVER_UC = getenv("FORKOP_DNS_FAILOVER_UC") || LIB_DIR + "/singbox/dns_failover.uc";
const SERVICE_BIN = getenv("FORKOP_BIN") || "/usr/bin/forkop";
const CHECK_DOMAIN = "example.com";
const STATE_UC = LIB_DIR + "/service/state.uc";
const CORE_GRACE_SECONDS = 90;

function as_string(value) {
    return value == null ? "" : "" + value;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let result = [];
    for (let arg in args)
        push(result, shell_quote(arg));
    return join(" ", result);
}

function command_status(command) {
    let status = int(system(command));
    return status > 255 ? int(status / 256) : status;
}

function command_success_from_args(args) {
    return command_status(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function command_output_from_args(args) {
    let pipe = fs.popen(command_from_args(args), "r");
    if (!pipe)
        return "";
    let data = pipe.read("all");
    let status = pipe.close();
    return status == 0 && data != null ? as_string(data) : "";
}

function settings() {
    return common.object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
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

function write_state(path, value) {
    if (!ensure_dir(RUNTIME_STATE_DIR))
        return false;
    let stamp = clock();
    let temporary = as_string(path) + ".tmp." + as_string(stamp[0]) + "." + as_string(stamp[1]);
    if (!common.write_json_file(temporary, value))
        return false;
    if (!fs.rename(temporary, path)) {
        remove_file(temporary);
        return false;
    }
    return true;
}

function log_message(message, level) {
    command_success_from_args([ "logger", "-t", "forkop", "[" + as_string(level || "info") + "] DNS failover: " + as_string(message) ]);
}

function duration_milliseconds(value, fallback) {
    let rest = as_string(value);
    let total = 0.0;
    let units = { ns: 0.000001, us: 0.001, ms: 1, s: 1000, m: 60000, h: 3600000, d: 86400000 };
    while (rest != "") {
        let matched = match(rest, /^([0-9]+(\.[0-9]+)?)(ns|us|ms|s|m|h|d)/);
        if (!matched)
            return fallback;
        total += (matched[1] * 1) * units[matched[3]];
        rest = substr(rest, length(matched[0]));
    }
    return total > 0 ? int(total + 0.5) : fallback;
}

function duration_seconds(value, fallback) {
    let milliseconds = duration_milliseconds(value, fallback * 1000);
    return int((milliseconds + 999) / 1000);
}

function probe_timeout(settings_value) {
    return duration_seconds(settings_value, 2);
}

function failure_threshold(settings_value) {
    let value = int(as_string(settings_value));
    return value > 0 ? value : 3;
}

function probe_port(kind, index_value, timeout_seconds) {
    let args = [
        "dig", "-p", as_string(runtime_dns.health_port(kind, index_value)),
        "@" + runtime_dns.DNS_HEALTH_ADDRESS,
        CHECK_DOMAIN, "A", "+short",
        "+timeout=" + as_string(timeout_seconds), "+tries=1"
    ];
    for (let line in split(command_output_from_args(args), "\n"))
        if (core_ip.valid_ipv4(trim(as_string(line))))
            return true;
    return false;
}

function probe_canonical_main(timeout_seconds) {
    let args = [
        "dig", "-p", as_string(runtime_dns.health_port("active", 0)),
        "@" + runtime_dns.DNS_HEALTH_ADDRESS, CHECK_DOMAIN, "A", "+short",
        "+timeout=" + as_string(timeout_seconds), "+tries=1"
    ];
    for (let line in split(command_output_from_args(args), "\n"))
        if (core_ip.valid_ipv4(trim(as_string(line))))
            return true;
    return false;
}

function verification_plan(previous, candidate) {
    previous = common.object_or_empty(previous);
    candidate = common.object_or_empty(candidate);
    return {
        main: int(candidate.main_index || 0) != int(previous.main_index || 0),
        bootstrap: int(candidate.bootstrap_index || 0) != int(previous.bootstrap_index || 0) &&
            length(candidate.bootstrap_servers || []) > 1
    };
}

function verify_state(path, preflight, report) {
    let cfg = settings();
    let state = common.read_json_file(path);
    let expected = runtime_dns.state_template(cfg);
    if (!runtime_dns.state_matches(expected, state)) {
        if (report) log_message("candidate no longer matches current DNS settings", "warn");
        return false;
    }

    state = runtime_dns.normalize_state(cfg, state);
    let previous = runtime_dns.normalize_state(cfg, common.read_json_file(STATE_FILE));
    let plan = verification_plan(previous, state);
    let timeout_seconds = probe_timeout(common.option(cfg, "dns_check_timeout", "2s"));
    // Before publishing, the main candidate still uses the current bootstrap.
    // A simultaneous bootstrap change must verify main after both are applied.
    let main_ok = !plan.main || (preflight
        ? plan.bootstrap || probe_port("main", state.main_index, timeout_seconds)
        : probe_canonical_main(timeout_seconds));
    if (!main_ok) {
        if (report) log_message((preflight ? "preflight" : "runtime") +
            " main DNS probe failed for priority " + as_string(state.main_index + 1) + " (" + state.dns_type + ")", "warn");
        return false;
    }
    if (plan.bootstrap && !probe_port("bootstrap", state.bootstrap_index, timeout_seconds)) {
        if (report) log_message((preflight ? "preflight" : "runtime") +
            " bootstrap DNS probe failed for priority " + as_string(state.bootstrap_index + 1), "warn");
        return false;
    }
    return true;
}

function commit_state(path) {
    let cfg = settings();
    let state = common.read_json_file(path);
    if (!runtime_dns.state_matches(runtime_dns.state_template(cfg), state))
        return false;
    return fs.rename(path, STATE_FILE);
}

function now_seconds() {
    return int(clock()[0]);
}

function choose_index(kind, state, current_index, timeout_seconds, recovery) {
    let values = kind == "main" ? state.main_servers : state.bootstrap_servers;
    if (length(values) <= 1)
        return { index: 0, reason: "single", alive: true };

    if (recovery && current_index > 0) {
        for (let i = 0; i < current_index; i++)
            if (probe_port(kind, i, timeout_seconds))
                return { index: i, reason: "recovery", alive: true };
        return { index: current_index, reason: "unchanged", alive: true };
    }

    if (probe_port(kind, current_index, timeout_seconds))
        return { index: current_index, reason: "alive", alive: true };

    for (let i = 0; i < length(values); i++) {
        if (i == current_index)
            continue;
        if (probe_port(kind, i, timeout_seconds))
            return { index: i, reason: i < current_index ? "recovery" : "active_dead", alive: true };
    }
    return { index: current_index, reason: "all_down", alive: false };
}

function clone_state(value) {
    return json(sprintf("%J", value));
}

function apply_selections(state, selections) {
    let candidate = clone_state(state);
    let changed = [];
    for (let kind in [ "bootstrap", "main" ]) {
        let selected = common.object_or_empty(common.object_or_empty(selections)[kind]);
        if (selected.index == null)
            continue;
        let key = kind == "main" ? "main_index" : "bootstrap_index";
        if (int(candidate[key]) == int(selected.index))
            continue;
        candidate[key] = int(selected.index);
        push(changed, { kind, selected });
    }
    if (length(changed) == 0)
        return true;

    let stamp = clock();
    let candidate_path = STATE_FILE + ".candidate." + as_string(stamp[0]) + "." + as_string(stamp[1]);
    if (!write_state(candidate_path, candidate))
        return false;

    let status = command_status(command_from_args([ SERVICE_BIN, "dns_failover_apply", candidate_path ]) + " >/dev/null 2>&1");
    remove_file(candidate_path);
    if (status != 0)
        return false;

    state.main_index = candidate.main_index;
    state.bootstrap_index = candidate.bootstrap_index;
    for (let item in changed) {
        let values = item.kind == "main" ? state.main_servers : state.bootstrap_servers;
        let selected = item.selected;
        log_message("switched " + item.kind + " DNS to priority " + as_string(selected.index + 1) + " (" + values[selected.index] + ", " + selected.reason + ")", "info");
    }
    return true;
}

function failover_confirmed(failures, kind, current_index, selected, threshold) {
    if (selected.alive && int(selected.index) == int(current_index)) {
        failures[kind] = 0;
        return false;
    }

    failures[kind] = int(failures[kind] || 0) + 1;
    return failures[kind] >= threshold;
}

// Only confirmed loss of every main resolver warrants a user-facing error.
// Bootstrap failure alone does not imply loss of working DNS transports.
function update_dns_outage(outage, available, threshold) {
    if (available) {
        if (outage.reported)
            log_message("DNS availability restored", "info");
        outage.failures = 0;
        outage.reported = false;
        return;
    }
    outage.failures++;
    if (outage.failures >= threshold && !outage.reported) {
        log_message("all configured main DNS servers are unavailable", "error");
        outage.reported = true;
    }
}

function worker() {
    let cfg = settings();
    let state = runtime_dns.normalize_state(cfg, common.read_json_file(STATE_FILE));
    if (!state.provider && length(state.main_servers) <= 1 && length(state.bootstrap_servers) <= 1)
        return 0;
    if (!write_state(STATE_FILE, state))
        return 1;

    let active_interval = duration_seconds(common.option(cfg, "dns_check_interval", "10s"), 10);
    let recovery_interval = duration_seconds(common.option(cfg, "dns_recovery_check_interval", "60s"), 60);
    let timeout_seconds = probe_timeout(common.option(cfg, "dns_check_timeout", "2s"));
    let threshold = failure_threshold(common.option(cfg, "dns_failover_failure_threshold", "3"));
    let next_active = now_seconds();
    let next_recovery = now_seconds() + recovery_interval;
    let all_down = { main: false, bootstrap: false };
    let outage = { failures: 0, reported: false };
    let active_failures = { main: 0, bootstrap: 0 };
    let observed_runtime = null;

    while (true) {
        let now = now_seconds();
        let current_cfg = settings();
        if (now >= next_active || !state.provider) {
            let expected = runtime_dns.state_template(current_cfg);
            if (!runtime_dns.state_matches(expected, state)) {
                if (state.provider && expected.provider) {
                    // Keep the last valid runtime while every WAN is offline.
                    // Retry discovery without manufacturing a public DNS fallback.
                    if (length(expected.main_servers) == 0) {
                        next_active = now + active_interval;
                        command_success_from_args([ "sleep", "1" ]);
                        continue;
                    }
                    log_message("WAN DNS or mwan3 availability changed; regenerating DNS routes", "info");
                    // Exit before reload stops/replaces this worker; never hold
                    // a service action open from the process it must terminate.
                    command_status("(sleep 1; " + command_from_args([ SERVICE_BIN, "reload" ]) +
                        ") >/dev/null 2>&1 1000>&- &");
                }
                return 0;
            }
        }

        if (state.provider && length(state.main_servers) <= 1 && length(state.bootstrap_servers) <= 1) {
            next_active = now + active_interval;
            command_success_from_args([ "sleep", as_string(active_interval) ]);
            continue;
        }

        if (now >= next_active || now >= next_recovery) {
            let provenance = null;
            try {
                provenance = json(command_output_from_args([ "ucode", "-L", LIB_DIR, STATE_UC, "sing-box-runtime-provenance" ]));
            }
            catch (e) {}
            let observed = runtime_health.observe_runtime(observed_runtime, provenance, int(clock(true)[0]), CORE_GRACE_SECONDS);
            observed_runtime = observed.state;
            if (!observed.ready) {
                active_failures = { main: 0, bootstrap: 0 };
                all_down = { main: false, bootstrap: false };
                outage.failures = 0;
                next_active = now + active_interval;
                next_recovery = now + recovery_interval;
                command_success_from_args([ "sleep", "1" ]);
                continue;
            }
        }

        if (now >= next_active) {
            let bootstrap = choose_index("bootstrap", state, int(state.bootstrap_index), timeout_seconds, false);
            if (!bootstrap.alive && !all_down.bootstrap)
                log_message("all configured bootstrap DNS servers are unavailable", "warn");
            all_down.bootstrap = !bootstrap.alive;
            let main = choose_index("main", state, int(state.main_index), timeout_seconds, false);
            update_dns_outage(outage, main.alive, threshold);
            all_down.main = !main.alive;

            let selections = {};
            let bootstrap_ready = failover_confirmed(
                active_failures, "bootstrap", state.bootstrap_index, bootstrap, threshold
            );
            if (bootstrap.index != int(state.bootstrap_index) && bootstrap_ready)
                selections.bootstrap = bootstrap;
            let main_ready = failover_confirmed(
                active_failures, "main", state.main_index, main, threshold
            );
            if (main.index != int(state.main_index) && main_ready)
                selections.main = main;
            apply_selections(state, selections);
            next_active = now_seconds() + active_interval;
        }

        if (now >= next_recovery) {
            let bootstrap = choose_index("bootstrap", state, int(state.bootstrap_index), timeout_seconds, true);
            let main = choose_index("main", state, int(state.main_index), timeout_seconds, true);
            let has_changes = bootstrap.index != int(state.bootstrap_index) || main.index != int(state.main_index);
            let applied = apply_selections(state, { bootstrap, main });
            let completed = now_seconds();
            if (has_changes && applied) {
                active_failures.bootstrap = 0;
                active_failures.main = 0;
                next_active = completed + active_interval;
            }
            next_recovery = completed + recovery_interval;
        }

        command_success_from_args([ "sleep", "1" ]);
    }
}

function stop_runtime() {
    return worker_identity.stop(PID_FILE, DNS_FAILOVER_UC, LIB_DIR) ? 0 : 1;
}

function start_runtime() {
    let cfg = settings();
    if (stop_runtime() != 0)
        return 1;
    if (!runtime_dns.failover_enabled(cfg)) {
        remove_file(STATE_FILE);
        return 0;
    }
    if (!ensure_dir(RUNTIME_STATE_DIR))
        return 1;

    let command = command_from_args([ "ucode", "-L", LIB_DIR, DNS_FAILOVER_UC, "worker" ]) +
        " >/dev/null 2>&1 1000>&- & echo $! >" + shell_quote(PID_FILE);
    if (command_status(command) != 0)
        return 1;
    if (worker_identity.record_started(PID_FILE, DNS_FAILOVER_UC, LIB_DIR))
        return 0;
    stop_runtime();
    return 1;
}

function select_fixture(state_path, alive_path, kind, recovery) {
    let state = common.object_or_empty(common.read_json_file(state_path));
    let alive = common.object_or_empty(common.read_json_file(alive_path));
    let key = kind == "main" ? "main_index" : "bootstrap_index";
    let values = kind == "main" ? state.main_servers : state.bootstrap_servers;
    let current = int(state[key] || 0);
    let selected = { index: current, reason: "all_down", alive: false };
    let probe = function(index_value) { return alive[as_string(index_value)] === true || alive[as_string(index_value)] == 1; };

    if (as_string(recovery) == "1" && current > 0) {
        for (let i = 0; i < current; i++)
            if (probe(i)) {
                selected = { index: i, reason: "recovery", alive: true };
                break;
            }
    }
    else if (probe(current)) {
        selected = { index: current, reason: "alive", alive: true };
    }
    else {
        for (let i = 0; i < length(values); i++)
            if (i != current && probe(i)) {
                selected = { index: i, reason: i < current ? "recovery" : "active_dead", alive: true };
                break;
            }
    }
    common.write_json(selected);
}

let mode = ARGV[0] || "";

if (mode == "start-runtime")
    exit(start_runtime());
else if (mode == "stop-runtime")
    exit(stop_runtime());
else if (mode == "worker")
    exit(worker());
else if (mode == "verify-state")
    exit(verify_state(ARGV[1], false, ARGV[2] == "report") ? 0 : 1);
else if (mode == "probe-candidate")
    exit(verify_state(ARGV[1], true, true) ? 0 : 1);
else if (mode == "commit-state")
    exit(commit_state(ARGV[1]) ? 0 : 1);
else if (mode == "select-fixture")
    select_fixture(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "verification-plan-fixture")
    common.write_json(verification_plan(common.read_json_file(ARGV[1]), common.read_json_file(ARGV[2])));
else {
    warn("Usage: singbox/dns_failover.uc <start-runtime|stop-runtime|worker|verify-state|probe-candidate|commit-state|select-fixture|verification-plan-fixture> ...\n");
    exit(1);
}
