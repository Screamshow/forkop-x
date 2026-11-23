#!/bin/sh
set -eu
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
FORKOP_LIB=${FORKOP_LIB:-$ROOT_DIR/forkop/files/usr/lib}
ucode -L "$FORKOP_LIB" -e '
let n = require("core.netstat");
let checks = 0;
function check(row, address, port, pid, expected) {
    if (n.tcp_listen_port_owned(row, address, port, pid) != expected)
        die("Unexpected listener ownership: " + row);
    checks++;
}
let tcp = "tcp 0 0 127.0.0.1:4534 0.0.0.0:* LISTEN 4200/sing-box";
check(tcp, "127.0.0.1", 4534, 4200, true);
check(tcp, "127.0.0.1", 4534, 4100, false);
check(tcp, "127.0.0.1", 4534, 420, false);
check(tcp, "127.0.0.1", 45340, 4200, false);
check(tcp, "127.0.0.2", 4534, 4200, false);
check(tcp, "127.0.0.1", 4534, 0, false);
check(replace(tcp, "LISTEN", "ESTABLISHED"), "127.0.0.1", 4534, 4200, false);
check("udp 0 0 127.0.0.1:4534 0.0.0.0:* 4200/sing-box", "127.0.0.1", 4534, 4200, false);
check(replace(tcp, "4200/sing-box", "-"), "127.0.0.1", 4534, 4200, false);
check("tcp6 0 0 :::4534 :::* LISTEN 4200/sing-box", "::1", 4534, 4200, true);
check("tcp6 0 0 [::1]:4534 :::* LISTEN 4200/sing-box", "::1", 4534, 4200, true);
check("tcp 0 0 0.0.0.0:4534 0.0.0.0:* LISTEN 4200/sing-box", "127.0.0.1", 4534, 4200, true);
let core_rows = "tcp 0 0 127.0.0.42:53 0.0.0.0:* LISTEN 4200/xrust\n" +
    "udp 0 0 127.0.0.42:53 0.0.0.0:* 4200/xrust\n" +
    "tcp 0 0 0.0.0.0:1602 0.0.0.0:* LISTEN 4200/xrust\n" +
    "udp 0 0 0.0.0.0:1602 0.0.0.0:* 4200/xrust\n" +
    "tcp6 0 0 [::1]:1602 :::* LISTEN 4200/xrust\n" +
    "udp6 0 0 [::1]:1602 :::* 4200/xrust\n";
function core_ready(rows) { return n.xrust_standard_ports_owned(rows, 4200, "127.0.0.42", 1602, "0.0.0.0", "::1"); }
assert(core_ready(core_rows), "all six Xrust sockets were not recognized");
assert(!core_ready(replace(core_rows, ":53", ":5353")), "mistook DNS port 5353 for 53");
assert(!core_ready(replace(core_rows, "4200", "4100")), "accepted a DNS socket from another process");
assert(!core_ready(replace(core_rows, "udp6 0 0", "tcp6 0 0")), "accepted an absent UDP listener");
assert(!core_ready(replace(core_rows, "[::1]:1602", ":::1602")), "accepted an unintended IPv6 wildcard bind");
print("TCP listener ownership checks passed: ", checks, " assertions\n");
'
