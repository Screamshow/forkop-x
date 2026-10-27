#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RUNTIME="$ROOT/forkop/files/usr/lib/diagnostics/runtime.uc"

extract() {
  sed -n '/^function latency_probe_concurrency() {/,/^}/p;
          /^function latency_probe_command(/,/^}/p;
          /^function probe_proxy_latencies(/,/^}/p' "$RUNTIME"
}

mocks() {
cat <<'UCODE'
let probed = [];
let scripts = [];
let temps = {};
let unlinked = [];
let updates = [];
let temp_fail = false;
let temp_serial = 0;
let bodies = {};
const SERVICE_UI_UC = "service/ui.uc";
function as_string(value) { return value == null ? "" : "" + value; }
function shell_quote(value) { return "'" + as_string(value) + "'"; }
function command_from_args(args) { return join(" ", args); }
function clash_latency_endpoint(base_url, proxy_tag, proxy_type) {
    return as_string(base_url) + (lc(as_string(proxy_type)) == "urltest" ? "/group/" : "/proxies/") +
        as_string(proxy_tag) + "/delay";
}
function body_for(tag) { return bodies[tag] != null ? bodies[tag] : '{"delay":42}'; }
function tag_of(command) {
    for (let part in split(as_string(command), " "))
        if (index(part, "/delay") >= 0)
            return replace(replace(replace(part, /.*\/proxies\//, ""), /.*\/group\//, ""), /\/delay.*/, "");
    return "";
}
// A batch runs its probes through the shell; a lone probe is captured directly.
function command_output(command) {
    let tag = tag_of(command);
    push(probed, tag);
    return body_for(tag);
}
function command_output_from_args(args) {
    if (args[0] == "mktemp")
        return temp_fail ? "" : "/tmp/probe." + (++temp_serial);
    return "";
}
function command_status(script) {
    push(scripts, script);
    for (let part in split(as_string(script), " & ")) {
        let tag = tag_of(part);
        if (tag == "")
            continue;
        push(probed, tag);
        let path = replace(replace(part, /.*>'/, ""), /'.*/, "");
        temps[path] = body_for(tag);
    }
    return 0;
}
function status_capture(args, input) {
    return { status: index(as_string(input), "delay") >= 0 ? 0 : 1, output: "" };
}
function module_success(module_path, args) {
    push(updates, as_string(args[2]) + "/" + as_string(args[3]) + " failed=" + as_string(args[4]));
    return true;
}
let fs = {
    readfile: (path) => temps[path] != null ? temps[path] : null,
    unlink: (path) => { push(unlinked, path); return true; }
};
function new_progress(total) { return { completed: 0, failed: 0, total, path: "job.json" }; }
const PLAN = {
    base_url: "http://127.0.0.1:9090",
    auth: [ "-H", "Authorization: Bearer x" ],
    proxy_types: { a: "vless", b: "vless", c: "vless", d: "vless", group: "urltest" },
    test_url: "http://example.invalid/generate_204",
    timeout: "5000"
};
UCODE
}

# The configured batch size is bounded, and anything unusable means the default.
{ mocks; extract; cat <<'UCODE'
assert(latency_probe_concurrency() == int(getenv("EXPECT_CONCURRENCY")), "unexpected batch size");
print("concurrency ", latency_probe_concurrency(), " ok\n");
UCODE
} >"${TMPDIR:-/tmp}/latency_probe_case.uc"

for pair in ":4" "2:2" "1:1" "0:1" "99:8" "abc:4"; do
  value="${pair%%:*}"
  expect="${pair##*:}"
  if [ -z "$value" ]; then
    EXPECT_CONCURRENCY="$expect" ucode "${TMPDIR:-/tmp}/latency_probe_case.uc" >/dev/null
  else
    FORKOP_LATENCY_PROBE_CONCURRENCY="$value" EXPECT_CONCURRENCY="$expect" \
      ucode "${TMPDIR:-/tmp}/latency_probe_case.uc" >/dev/null
  fi
done
rm -f "${TMPDIR:-/tmp}/latency_probe_case.uc"

# Every proxy is probed exactly once, in order, and progress counts each answer.
{ mocks; extract; cat <<'UCODE'
bodies = { b: "not json" };
let progress = probe_proxy_latencies(PLAN, [ "a", "b", "c", "d" ], new_progress(5));
assert(length(probed) == 4, "probe count is wrong");
assert(join(",", probed) == "a,b,c,d", "probe order changed: " + join(",", probed));
assert(progress.completed == 4 && progress.failed == 1, "progress accounting is wrong");
assert(length(scripts) == 2, "batches of two were not used: " + length(scripts));
assert(length(unlinked) == 4, "temporary files were left behind");
assert(join(" ", updates) == "1/5 failed=0 2/5 failed=1 3/5 failed=1 4/5 failed=1",
    "progress was not reported per answer: " + join(" ", updates));

// A phase that ends on an odd probe captures the last one directly.
probed = []; scripts = []; unlinked = [];
progress = probe_proxy_latencies(PLAN, [ "a", "b", "c" ], new_progress(3));
assert(length(scripts) == 1 && length(probed) == 3 && length(unlinked) == 2,
    "the trailing probe was not captured directly");
print("batched probing ok\n");
UCODE
} | FORKOP_LATENCY_PROBE_CONCURRENCY=2 ucode -

# Concurrency 1 keeps the sequential sweep, and so does a failing mktemp.
{ mocks; extract; cat <<'UCODE'
let progress = probe_proxy_latencies(PLAN, [ "a", "b", "c" ], new_progress(3));
assert(length(scripts) == 0 && temp_serial == 0, "sequential sweep used the shell");
assert(length(probed) == 3 && progress.completed == 3 && progress.failed == 0, "sequential sweep lost probes");
print("sequential sweep ok\n");
UCODE
} | FORKOP_LATENCY_PROBE_CONCURRENCY=1 ucode -

{ mocks; extract; cat <<'UCODE'
temp_fail = true;
let progress = probe_proxy_latencies(PLAN, [ "a", "b", "c" ], new_progress(3));
assert(length(scripts) == 0, "a batch ran without temporary files");
assert(length(probed) == 3 && progress.completed == 3 && progress.failed == 0,
    "probes were lost when mktemp failed");
print("mktemp fallback ok\n");
UCODE
} | FORKOP_LATENCY_PROBE_CONCURRENCY=4 ucode -

printf 'latency probe batch tests passed\n'
