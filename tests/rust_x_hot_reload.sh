#!/bin/sh
# Run on an OpenWrt integration VM with the candidate Rust X binary.
set -eu
LIB=${FORKOP_LIB:-/usr/lib/forkop}
CORE=${FORKOP_SING_BOX_BIN:-/usr/bin/sing-box}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
for case in good stale-generation wrong-pid reused-pid wrong-hash; do
    CASE="$case" WORK="$WORK" ucode -e '
        let fs = require("fs");
        let f = { plan: { process: { pid: 123, start_ticks: "456" }, generation: 2 },
            current: { pid: 123, generation: 3, config_sha256: "new" },
            actual: { pid: 123, start_ticks: "456" }, fingerprint: "new" };
        let c = getenv("CASE");
        if (c == "stale-generation") f.current.generation = 2;
        if (c == "wrong-pid") f.current.pid = 124;
        if (c == "reused-pid") f.actual.start_ticks = "457";
        if (c == "wrong-hash") f.current.config_sha256 = "old";
        fs.writefile(getenv("WORK") + "/ack.json", sprintf("%J", f));
    '
    if ucode -L "$LIB" "$LIB/service/hot_reload.uc" ack-fixture "$WORK/ack.json"; then
        [ "$case" = good ] || { echo "False acknowledgment: $case"; exit 1; }
    else
        [ "$case" != good ] || { echo 'Valid acknowledgment rejected'; exit 1; }
    fi
done
# A refused reload ends the wait only for the very config this apply sent.
for case in rejected old-core same-attempt other-hash applied other-pid; do
    CASE="$case" WORK="$WORK" ucode -e '
        let fs = require("fs");
        let f = { plan: { process: { pid: 123, start_ticks: 456 }, generation: 2, reload_attempt: 5 },
            current: { pid: 123, generation: 2, reload_attempt: 6, rejected_sha256: "new" }, fingerprint: "new" };
        let c = getenv("CASE");
        if (c == "old-core") { delete f.plan.reload_attempt; delete f.current.reload_attempt; delete f.current.rejected_sha256; }
        if (c == "same-attempt") f.current.reload_attempt = 5;
        if (c == "other-hash") f.current.rejected_sha256 = "old";
        if (c == "applied") f.current.generation = 3;
        if (c == "other-pid") f.current.pid = 124;
        fs.writefile(getenv("WORK") + "/reject.json", sprintf("%J", f));
    '
    if ucode -L "$LIB" "$LIB/service/hot_reload.uc" reject-fixture "$WORK/reject.json"; then
        [ "$case" = rejected ] || { echo "False rejection: $case"; exit 1; }
    else
        [ "$case" != rejected ] || { echo 'Refused reload not recognised'; exit 1; }
    fi
done
# The poll loop reads the start time from /proc itself; it must agree with stat(5).
ticks=$(ucode -L "$LIB" "$LIB/service/hot_reload.uc" start-ticks-fixture $$)
expected=$(sed 's/.*) //' /proc/$$/stat | cut -d' ' -f20)
[ "$ticks" = "$expected" ] || { echo "Start ticks $ticks, expected $expected"; exit 1; }
cat > "$WORK/current.json" <<'EOF'
{"inbounds":[{"type":"mixed","tag":"in","listen":"127.0.0.1","listen_port":12080}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}
EOF
cp "$WORK/current.json" "$WORK/next.json"
# Forkop always passes --skip-rule-set-payloads; every Xrust must accept it.
"$CORE" reload-plan --current "$WORK/current.json" -c "$WORK/next.json" --skip-rule-set-payloads > "$WORK/plan.json"
WORK="$WORK" ucode -e '
    let fs=require("fs"); let p=json(fs.readfile(getenv("WORK")+"/plan.json"));
    assert(p.schema == 1 && p.in_place && p.current_sha256 == p.config_sha256, "No-op reload plan");
    let c=json(fs.readfile(getenv("WORK")+"/next.json")); c.inbounds[0].listen_port=12081;
    fs.writefile(getenv("WORK")+"/next.json", sprintf("%J",c));
'
"$CORE" reload-plan --current "$WORK/current.json" -c "$WORK/next.json" > "$WORK/plan.json"
WORK="$WORK" ucode -e '
    let fs=require("fs"); let p=json(fs.readfile(getenv("WORK")+"/plan.json"));
    assert(p.in_place === false && p.current_sha256 != p.config_sha256, "Listener change must restart");
'
printf '{broken' > "$WORK/next.json"
if "$CORE" reload-plan --current "$WORK/current.json" -c "$WORK/next.json" >/dev/null 2>&1; then
    echo 'Invalid candidate accepted'; exit 1
fi
# Live apply against a running core: an accepted config is acknowledged, and
# a refused one ends the wait at once on cores that report refusals.
PORT=${FORKOP_TEST_CONTROLLER_PORT:-19391}
cat > "$WORK/live.json" <<EOF
{"inbounds":[{"type":"mixed","tag":"in","listen":"127.0.0.1","listen_port":$((PORT + 1))}],
 "outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"},
 "experimental":{"clash_api":{"external_controller":"127.0.0.1:$PORT","secret":"s3cret"}}}
EOF
"$CORE" run -c "$WORK/live.json" >"$WORK/core.log" 2>&1 &
CORE_PID=$!
trap 'kill "$CORE_PID" 2>/dev/null; rm -rf "$WORK"' EXIT HUP INT TERM
# Stand-in for state.uc: the provenance of the core started above.
cat > "$WORK/state.uc" <<'EOF'
let fs = require("fs");
let pid = getenv("TEST_CORE_PID");
let stat = fs.readfile("/proc/" + pid + "/stat");
let fields = split(trim(substr(stat, index(stat, ") ") + 2)), " ");
print(sprintf("%J\n", { pid: int(pid), start_ticks: int(fields[19]) }));
EOF
# mktemp files of hot_reload.uc (the controller secret) land here.
mkdir "$WORK/tmp"
export TEST_CORE_PID="$CORE_PID" FORKOP_STATE_UC="$WORK/state.uc" TMPDIR="$WORK/tmp"
applied_config() {
    curl --noproxy '*' -fsS -H 'Authorization: Bearer s3cret' "http://127.0.0.1:$PORT/rust-x/applied-config"
}
i=0
until applied_config >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 100 ] || { echo 'Core did not start'; cat "$WORK/core.log"; exit 1; }
    sleep 0.1
done
ucode "$WORK/state.uc" > "$WORK/provenance.json"
# Write the plan the way plan() does; $2 is the expected hash.
live_plan() {
    WORK="$WORK" SHA="$1" ucode -e '
        let fs = require("fs"); let w = getenv("WORK");
        let process = json(fs.readfile(w + "/provenance.json"));
        fs.writefile(w + "/live.hot-plan", sprintf("%J", { process, generation: 0,
            current_path: w + "/live.json", previous_sha256: "", config_sha256: getenv("SHA") }));
    '
}
sha_of() {
    "$CORE" reload-plan --current "$1" -c "$1" | sed 's/.*"config_sha256":"\([a-f0-9]*\)".*/\1/'
}
WORK="$WORK" ucode -e '
    let fs = require("fs"); let w = getenv("WORK"); let c = json(fs.readfile(w + "/live.json"));
    push(c.outbounds, { type: "direct", tag: "second" });
    fs.writefile(w + "/next.json", sprintf("%J", c));
    c.route.final = "missing";
    fs.writefile(w + "/bad.json", sprintf("%J", c));
'
live_plan "$(sha_of "$WORK/next.json")"
cp "$WORK/next.json" "$WORK/live.json"
ucode -L "$LIB" "$LIB/service/hot_reload.uc" apply "$WORK/live.hot-plan" ||
    { echo 'Accepted live reload not acknowledged'; exit 1; }
# The core hashes a refused config too; reload-plan hashes --current unchecked.
bad_sha=$("$CORE" reload-plan --current "$WORK/bad.json" -c "$WORK/next.json" |
    sed 's/.*"current_sha256":"\([a-f0-9]*\)".*/\1/')
live_plan "$bad_sha"
cp "$WORK/bad.json" "$WORK/live.json"
started=$(date +%s)
if FORKOP_HOT_RELOAD_TIMEOUT=20 ucode -L "$LIB" "$LIB/service/hot_reload.uc" apply "$WORK/live.hot-plan"; then
    echo 'Refused live reload reported as applied'; exit 1
fi
elapsed=$(( $(date +%s) - started ))
# Older cores do not report refusals and keep the plain timeout.
if applied_config | grep -q "\"rejected_sha256\":\"$bad_sha\""; then
    [ "$elapsed" -lt 5 ] || { echo "Refused reload waited ${elapsed}s"; exit 1; }
fi
[ -z "$(ls -A "$WORK/tmp")" ] || { echo 'Controller secret file left behind'; exit 1; }
kill "$CORE_PID"
echo 'Rust X reload acknowledgment and plan checks passed'
