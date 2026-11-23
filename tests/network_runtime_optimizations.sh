#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export FORKOP_NFT_BATCH_FILE="$WORK/priority.nft"
cat >"$WORK/sections.json" <<'JSON'
{"section":[
 {".name":"plain","action":"proxy","ip_cidr":["198.51.100.0/24","2001:db8:1::/64"]},
 {".name":"port","action":"block","ports":["853"]},
 {".name":"full","action":"bypass","fully_routed_ips":["192.168.1.10"],"excluded_source_ip_cidr":["192.168.1.11"]},
 {".name":"projected","action":"bypass","ports":["443"],"remote_subnet_lists":["https://fixture.test/rules.json"]},
 {".name":"disabled","action":"block","enabled":"0","ip_cidr":["203.0.113.0/24"]}
]}
JSON
ucode -L "$LIB" "$LIB/nft/apply.uc" nft-add-section-priority-rules-fixture \
  "$WORK/sections.json" forkop interfaces local local6 0x100 198.18.0.0/15 2001:2::/112
for entry in plain:2 port:1 full:4 projected:5 disabled:0; do
    prefix=${entry%:*}
    count=$(grep -c "^add set inet forkop forkop_rule_${prefix}_" "$FORKOP_NFT_BATCH_FILE" || true)
    test "$count" = "${entry#*:}"
done
for name in $(grep -oE '@forkop_rule_[A-Za-z0-9_]+' "$FORKOP_NFT_BATCH_FILE" | sort -u); do
    grep -Fq "add set inet forkop ${name#@} " "$FORKOP_NFT_BATCH_FILE"
done
printf 'Four active fixture sections declare 12 required sets (previous plan: 61)\n'

{
cat <<'UC'
let scans = 0, fd_scans = 0, udp_reads = 0, tcp_reads = 0, raced = false, foreign_socket = false;
let processes = { "/dns/a": { pid: "10", identity: "10:100" }, "/dns/b": { pid: "20", identity: "20:200" } };
let sockets = "0: 0100007F:0035 00000000:0000 0A 0:0 0:0 0 0 0 100\n" +
    "1: 00000000:0036 00000000:0000 0A 0:0 0:0 0 0 0 200\n";
let fs = { readfile: function(path) {
    if (path == "/proc/net/udp") { udp_reads++; return sockets; }
    if (path == "/proc/net/tcp") { tcp_reads++; return sockets; }
    return path;
} };
function as_string(value) { return value == null ? "" : "" + value; }
function service_instances() { return { a: { running: true, pid: 10 }, b: { running: true, pid: 20 } }; }
function process_map() {
    scans++;
    return raced && scans == 2 ? { ...processes, "/dns/b": { pid: "20", identity: "20:999" } } : processes;
}
function socket_inodes(pid) {
    fd_scans++;
    return pid == "10" ? { "100": true } : { "200": !foreign_socket };
}
function monotonic() { return 0; }
function expected_config(section, text) { return section == text; }
function output(command, timeout) { return "status: NOERROR,"; }
UC
sed -n '/^function loopback_sockets(/,/^}/p; /^function owns_port(/,/^}/p; /^function ready(/,/^}/p' "$LIB/dns/reload.uc"
cat <<'UC'
let entries = [
    { name: "a", path: "/dns/a", section: "/dns/a", port: 53 },
    { name: "b", path: "/dns/b", section: "/dns/b", port: 54 }
];
assert(ready(entries, {}, {}, {}, 1));
assert(scans == 2 && fd_scans == 2 && udp_reads == 1 && tcp_reads == 1);
scans = 0;
raced = true;
assert(!ready(entries, {}, {}, {}, 1));
raced = false;
foreign_socket = true;
assert(!ready(entries, {}, {}, {}, 1));
print("Two DNS daemons: 3→2 process scans, 4→2 FD scans, 4→2 socket-table reads; PID replacement and foreign socket rejected\n");
UC
} >"$WORK/readiness.uc"
ucode "$WORK/readiness.uc"

ucode -L "$LIB" -e '
let duration = require("core.duration");
for (let invalid in ["", "15", "-2s", "0s", "1s 1m", "1bad", "1s-junk", "9007199254740992s"])
    assert(duration.parse_seconds(invalid) == null);
assert(duration.round_seconds("1m500ms") == 61);
assert(duration.ceil_seconds("1h2m3.25s", 5) == 3724);
assert(duration.ceil_seconds("1ns", 5) == 1);
assert(duration.ceil_seconds("invalid", 5) == 5);
assert(duration.round_milliseconds("500us250us", 5) == 1);
assert(duration.round_milliseconds("1.234s", 5) == 1234);
assert(duration.round_milliseconds("9007199254740991s", 5) == 5);
assert(duration.round_seconds("9007199254740991s") == 9007199254740991);
print("Shared duration grammar, per-consumer rounding and bounds passed\n");
'
