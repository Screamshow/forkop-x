#!/usr/bin/env ucode
let fs = require("fs");
let common = require("core.common");
let uci = require("core.uci");
const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
const STATE_UC = getenv("FORKOP_STATE_UC") || LIB_DIR + "/service/state.uc";
const BINARY = getenv("FORKOP_SING_BOX_BIN") || "/usr/bin/sing-box";

function str(value) { return value == null ? "" : "" + value; }
function quote(value) { return "'" + replace(str(value), /'/g, "'\\''") + "'"; }
function capture(args) {
    let encoded = [];
    for (let arg in args) push(encoded, quote(arg));
    let pipe = fs.popen(join(" ", encoded) + " 2>/dev/null", "r");
    if (!pipe) return { status: 1, output: "" };
    let output = pipe.read("all");
    let status = int(pipe.close());
    return { status: status > 255 ? int(status / 256) : status, output: str(output) };
}
function parsed(value) { try { return json(value); } catch (e) { return null; } }
function read(path) { return parsed(fs.readfile(path)); }
function unlink(path) { try { fs.unlink(path); } catch (e) {} }
function provenance() {
    let result = capture([ "ucode", "-L", LIB_DIR, STATE_UC, "sing-box-runtime-provenance" ]);
    return result.status == 0 ? parsed(result.output) : null;
}
// The start time read straight from /proc: enough to prove that the PID
// still names the process whose full provenance was checked before HUP.
function start_ticks(pid) {
    let stat = str(fs.readfile("/proc/" + int(pid) + "/stat"));
    let marker = index(stat, ") ");
    if (marker < 0) return null;
    let fields = split(trim(substr(stat, marker + 2)), /[ \t\r\n]+/);
    return length(fields) >= 20 && match(fields[19], /^[0-9]+$/) != null ? int(fields[19]) : null;
}
function same_process(expected, actual) {
    return type(expected) == "object" && type(actual) == "object" &&
        int(expected.pid) > 0 && expected.pid == actual.pid && expected.start_ticks == actual.start_ticks;
}
// One controller endpoint per config path for this invocation: the poll loop
// must not re-read the whole config and rewrite the secret file every round.
let controllers = {};
function controller(config_path) {
    if (controllers[config_path] != null) return controllers[config_path];
    let root = read(config_path);
    let api = type(root) == "object" ? common.object_or_empty(common.object_or_empty(root.experimental).clash_api) : {};
    let address = str(api.external_controller);
    if (address == "") return null;
    address = replace(address, /^0\.0\.0\.0:/, "127.0.0.1:");
    address = replace(address, /^\[::\]:/, "[::1]:");
    // Curl config keeps the controller secret out of process arguments.
    let temporary = trim(capture([ "mktemp" ]).output);
    if (temporary == "") return null;
    let escaped = replace(replace(str(api.secret), /\\/g, "\\\\"), /"/g, "\\\"");
    if (match(escaped, /[\r\n]/) != null || common.write_private_file(temporary,
        "header = \"Authorization: Bearer " + escaped + "\"\n") == null) {
        unlink(temporary); return null;
    }
    controllers[config_path] = { address, auth: temporary };
    return controllers[config_path];
}
function forget_controllers() {
    for (let path in controllers) unlink(controllers[path].auth);
    controllers = {};
}
function controller_request(config_path, path, method) {
    let api = controller(config_path);
    if (api == null) return null;
    let result = capture([ "curl", "--noproxy", "*", "-fsS", "--max-time", method == "POST" ? "60" : "2", "--config", api.auth,
        "--request", method || "GET", "http://" + api.address + path ]);
    return result.status == 0 ? (method == "DELETE" ? { ok: true } : parsed(result.output)) : null;
}
function status(config_path) {
    let value = controller_request(config_path, "/rust-x/applied-config", "GET");
    return type(value) == "object" && value.schema == 1 && value.ready === true && value.hot_reload === true &&
        int(value.generation) > 0 && match(str(value.config_sha256), /^[a-f0-9]{64}$/) != null ? value : null;
}
function retired_tags(previous, current) {
    let active = {};
    for (let entry in common.array_or_empty(common.object_or_empty(current.route).rule_set))
        active[str(entry.tag)] = true;
    let removed = {};
    for (let entry in common.array_or_empty(common.object_or_empty(previous.route).rule_set))
        if (str(entry.tag) != "" && !active[str(entry.tag)]) removed[str(entry.tag)] = true;
    return removed;
}
function affected_ids(connections, removed) {
    let ids = [];
    for (let connection in common.array_or_empty(connections)) {
        let payload = str(connection.rulePayload);
        // Match complete payload tokens, never substrings of another tag.
        let tokens = split(payload, /[ \t\r\n,;]+/);
        for (let token in tokens) {
            let tag = substr(token, 0, 9) == "rule_set=" ? substr(token, 9) : token;
            if (removed[tag] && match(str(connection.id), /^[A-Za-z0-9-]+$/)) {
                push(ids, str(connection.id)); break;
            }
        }
    }
    return ids;
}
function close_retired(previous_path, current_path, explicit_tag) {
    let current = read(current_path);
    let previous = explicit_tag != "" ? {} : read(previous_path);
    if (type(current) != "object" || type(previous) != "object") return 1;
    let capability = explicit_tag == "" ? status(current_path) : null;
    if (capability != null && capability.connection_revalidation === true) {
        let checked = controller_request(current_path, "/rust-x/revalidate-connections", "POST");
        if (type(checked) != "object" || checked.superseded === true || int(checked.skipped || 0) > 0) return 1;
        print(int(checked.closed || 0), "\n"); return 0;
    }
    let removed = explicit_tag != "" ? {} : retired_tags(previous, current);
    if (explicit_tag != "") removed[explicit_tag] = true;
    let has_removed = false;
    for (let tag in removed) has_removed = true;
    if (!has_removed) { print("0\n"); return 0; }
    let view = controller_request(current_path, "/connections", "GET");
    if (type(view) != "object") return 1;
    let count = 0;
    for (let id in affected_ids(view.connections, removed)) {
        if (controller_request(current_path, "/connections/" + id, "DELETE") == null) return 1;
        count++;
    }
    print(count, "\n"); return 0;
}
function acknowledged(plan, current, actual, fingerprint) {
    return same_process(plan.process, actual) && type(current) == "object" &&
        int(current.pid) == int(plan.process.pid) && int(current.generation) > int(plan.generation) &&
        current.config_sha256 == fingerprint;
}
// A core that reports refused reloads names the refused config: stop waiting
// for this fingerprint instead of holding the transition until the timeout.
function rejected(plan, current, fingerprint) {
    return type(current) == "object" && plan.reload_attempt != null &&
        int(current.pid) == int(plan.process.pid) &&
        int(current.reload_attempt) > int(plan.reload_attempt) &&
        str(current.rejected_sha256) == fingerprint &&
        int(current.generation) == int(plan.generation);
}
function plan(stage_path) {
    let cfg = common.object_or_empty(uci.get_all(CONFIG_NAME, "settings"));
    let current_path = str(cfg.config_path);
    let process = provenance();
    let before = status(current_path);
    if (!same_process(process, provenance()) || before == null || int(before.pid) != int(process.pid)) {
        print("cold\n"); return 0;
    }
    let result = capture([ BINARY, "reload-plan", "--current", current_path, "-c", stage_path ]);
    let candidate = result.status == 0 ? parsed(result.output) : null;
    if (candidate == null || candidate.schema != 1) return 1;
    if (!candidate.in_place || candidate.current_sha256 != before.config_sha256) {
        print("cold\n"); return 0;
    }
    let value = { process, generation: before.generation, current_path,
        previous_sha256: before.config_sha256, config_sha256: candidate.config_sha256 };
    if (common.write_private_json_file(stage_path + ".hot-plan", value) == null) return 1;
    print("hot\n"); return 0;
}
function apply(plan_path, restore_path) {
    let value = read(plan_path);
    if (type(value) != "object" || !same_process(value.process, provenance())) return 1;
    let before = status(value.current_path);
    if (before == null || int(before.pid) != int(value.process.pid)) return 1;
    // Require a new acknowledgment for this signal, including rollback of a
    // no-op configuration whose hash is already visible.
    value.generation = int(before.generation);
    value.reload_attempt = before.reload_attempt;
    let fingerprint = value.config_sha256;
    if (str(restore_path) != "") {
        if (capture([ "cp", "-p", restore_path, value.current_path ]).status != 0) return 1;
        fingerprint = value.previous_sha256;
    }
    if (capture([ "kill", "-HUP", str(value.process.pid) ]).status != 0) return 1;
    let timeout = int(getenv("FORKOP_HOT_RELOAD_TIMEOUT") || "30");
    timeout = timeout > 0 && timeout <= 120 ? timeout : 30;
    let deadline = int(clock(true)[0]) + timeout;
    let expected = value.process;
    while (int(clock(true)[0]) <= deadline) {
        let actual = { pid: expected.pid, start_ticks: start_ticks(expected.pid) };
        if (!same_process(expected, actual)) return 1;
        let current = status(value.current_path);
        // Confirm the full provenance (sole procd-owned core) once, on success.
        if (acknowledged(value, current, actual, fingerprint))
            return same_process(expected, provenance()) ? 0 : 1;
        if (rejected(value, current, fingerprint)) return 1;
        sleep(100);
    }
    return 1;
}
function finish(code) { forget_controllers(); exit(code); }
let mode = ARGV[0] || "";
if (mode == "plan") finish(plan(ARGV[1] || ""));
else if (mode == "close-retired") finish(close_retired(ARGV[1] || "", ARGV[2] || "", ""));
else if (mode == "close-tag") finish(close_retired("", ARGV[1] || "", ARGV[2] || ""));
else if (mode == "connections-fixture") {
    let fixture = read(ARGV[1]);
    print(sprintf("%J", affected_ids(fixture.connections, retired_tags(fixture.previous, fixture.current))), "\n");
}
else if (mode == "apply") finish(apply(ARGV[1] || "", ""));
else if (mode == "restore") finish(apply(ARGV[1] || "", ARGV[2] || ""));
else if (mode == "ack-fixture") {
    let fixture = read(ARGV[1]);
    exit(acknowledged(fixture.plan, fixture.current, fixture.actual, fixture.fingerprint) ? 0 : 1);
}
else if (mode == "reject-fixture") {
    let fixture = read(ARGV[1]);
    exit(rejected(fixture.plan, fixture.current, fixture.fingerprint) ? 0 : 1);
}
else if (mode == "start-ticks-fixture") print(start_ticks(ARGV[1]), "\n");
else exit(1);
