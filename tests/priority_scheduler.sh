#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB="$ROOT/forkop/files/usr/lib"
SOURCE="$LIB/singbox/priority.uc"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

{
cat <<'UCODE'
let now = 0, slow_probes = 0, primary_alive = true, switches = [];
function as_string(value) { return value == null ? "" : "" + value; }
function now_seconds() { return now; }
function duration_to_seconds(value, fallback) { return fallback; }
function log_message() {}
function set_group_proxy(group, tag) {
    push(switches, { tag, now });
    return true;
}
function probe(tag, group) {
    if (group.tag == "slow") {
        slow_probes++;
        now += 2;
        return { alive: false, delay: 0 };
    }
    return { alive: tag != "primary" || primary_alive, delay: 12 };
}
UCODE
sed -n '/^function new_probe_scan(/,/^}/p;
       /^function advance_probe_scan(/,/^}/p;
       /^function probe_scan_selection(/,/^}/p;
       /^function switch_group(/,/^}/p;
       /^function init_group_state(/,/^}/p;
       /^function finish_group_scan(/,/^}/p;
       /^function tick_group(/,/^}/p;
       /^function tick_groups(/,/^}/p' "$SOURCE"
cat <<'UCODE'
let dead = [];
for (let i = 0; i < 48; i++)
    push(dead, "dead-" + i);
let groups = [
    { tag: "slow", levels: [{outbounds: dead}] },
    { tag: "other", levels: [{outbounds: ["primary"]}, {outbounds: ["backup"]}] }
];
let states = { slow: init_group_state(groups[0]), other: init_group_state(groups[1]) };
assert(tick_groups(groups, states, probe), "checks did not start");
assert(tick_groups(groups, states, probe), "scheduled checks did not run");
assert(slow_probes == 1 && states.other.active == "primary" && switches[0].now == 2,
    "one large scan blocked an independent group");

primary_alive = false;
for (let i = 0; i < 8 && states.other.active != "backup"; i++)
    tick_groups(groups, states, probe);
assert(states.other.active == "backup" && slow_probes < 48,
    "independent group did not fail over during the slow scan");
primary_alive = true;
for (let i = 0; i < 15 && states.other.active != "primary"; i++)
    tick_groups(groups, states, probe);
assert(states.other.active == "primary" && slow_probes < 48,
    "independent group did not recover its preferred server");
assert(sprintf("%J", map(switches, (event) => event.tag)) == '[ "primary", "backup", "primary" ]',
    "unexpected Priority selection order");
assert(states.slow.scan != null, "slow group did not retain its in-progress scan");
print("Priority checks interleave groups, including failover and recovery\n");
UCODE
} >"$WORK/scheduler.uc"
ucode "$WORK/scheduler.uc"

cat >"$WORK/group.json" <<'JSON'
{"levels":[{"outbounds":["dead","first","faster","also-fast"]},{"outbounds":["lowest"]}]}
JSON
cat >"$WORK/delays.json" <<'JSON'
{"dead":-1,"first":30,"faster":10,"also-fast":10,"lowest":1}
JSON
choose() { ucode -L "$LIB" "$SOURCE" "$1" "$WORK/group.json" "$WORK/delays.json" "$2" "$3"; }
tag() { ucode -p 'json(require("fs").stdin.read("all")).tag || ""'; }
[ "$(choose select-fixture 0 1 | tag)" = first ]
[ "$(choose select-faster-fixture 0 first | tag)" = faster ]
[ -z "$(choose select-faster-fixture 0 also-fast | tag)" ]
sed 's/{"levels"/{"pick_fastest":true,"levels"/' "$WORK/group.json" >"$WORK/fast.json"
mv "$WORK/fast.json" "$WORK/group.json"
[ "$(choose select-fixture 0 1 | tag)" = faster ]
printf 'Priority member order, fastest tie and level precedence checks passed\n'
