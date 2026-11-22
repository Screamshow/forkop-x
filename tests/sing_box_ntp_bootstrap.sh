#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
GENERATOR="$FORKOP_LIB/xrust/generator.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_path": "/tmp/xrust/config.json",
    "dns_type": "DNS_TYPE",
    "dns_server": "https://dns.example/dns-query",
    "bootstrap_dns_server": ["8.8.8.8:1443", "1.1.1.1"],
    "dns_detour_enabled": "1",
    "dns_detour_section": "vpn",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "vpn",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\"}" ],
      "domain_suffix": [ "vpn.example" ]
    }
  ]
}
JSON

mkdir "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/ubus" <<'SH'
#!/bin/sh
[ "$1 $2 $3" = "call network.interface dump" ] || exit 1
case "${NTP_WAN_FIXTURE:-0}" in
  1) primary=192.0.2.53 ;;
  2) primary=192.0.2.55 ;;
  *) exit 1 ;;
esac
printf '{"interface":[{"up":true,"interface":"fixturewan","l3_device":"ethfixture","route":[{"mask":0,"target":"0.0.0.0"}],"dns-server":["%s"]},{"up":true,"interface":"fixturewan2","l3_device":"ethfixture2","route":[{"mask":0,"target":"0.0.0.0"}],"dns-server":["192.0.2.54"]}]}\n' "$primary"
SH
chmod +x "$WORK_DIR/bin/ubus"

# $1 case name, $2 DNS protocol, $3 uci state body, $4 WAN DNS available
generate() {
  local case_name="$1" protocol="$2" state="$3" wan="${4:-0}"
  local output="$WORK_DIR/$case_name-$protocol.json"
  mkdir -p "$output.section-cache" "$output.rulesets"
  local state_file="$output.state" fixture="$output.fixture"
  printf '%s' "$state" >"$state_file"
  sed -e "s/DNS_TYPE/$protocol/" "$WORK_DIR/fixture.json" >"$fixture"
  PATH="$WORK_DIR/bin:$PATH" NTP_WAN_FIXTURE="$wan" FORKOP_UCI_STATE_FILE="$state_file" \
    ucode -L "$FORKOP_LIB" "$GENERATOR" generate-config-fixture \
    "$fixture" "$output" "127.0.0.1" "0" "1" "" "0.0.45" ||
    fail "generation failed for $case_name on $protocol"
}

NAMES_STATE='system.ntp=timeserver
system.ntp.enabled=1
system.ntp.server=0.openwrt.pool.ntp.org 192.0.2.123 time.example 2001:db8::1
'
DISABLED_STATE='system.ntp=timeserver
system.ntp.enabled=0
system.ntp.server=0.openwrt.pool.ntp.org
'
ADDRESSES_STATE='system.ntp=timeserver
system.ntp.enabled=1
system.ntp.server=192.0.2.123 2001:db8::1
'

for protocol in udp doh dot; do
  generate names "$protocol" "$NAMES_STATE"
  generate disabled "$protocol" "$DISABLED_STATE"
  generate addresses "$protocol" "$ADDRESSES_STATE"
  generate absent "$protocol" ""
  if [ "$protocol" != udp ]; then
    generate wan "$protocol" "$NAMES_STATE" 1
    generate renewed "$protocol" "$NAMES_STATE" 2
    SIGNATURE_UC="$FORKOP_LIB/service/state.uc"
    signature() {
      PATH="$WORK_DIR/bin:$PATH" NTP_WAN_FIXTURE="$1" FORKOP_UCI_STATE_FILE="$2" \
        ucode -L "$FORKOP_LIB" "$SIGNATURE_UC" sing-box-signature-fixture "$3"
    }
    base="$WORK_DIR/wan-$protocol.json"
    [ "$(signature 1 "$base.state" "$base.fixture")" != "$(signature 2 "$base.state" "$base.fixture")" ] ||
      fail "WAN renewal did not change the manual $protocol runtime signature"
  fi
done

NTP_WORK_DIR="$WORK_DIR" ucode -e '
let fs = require("fs");

function assert(ok, message) { if (!ok) { warn(message, "\n"); exit(1); } }
function config(case_name, protocol) {
    return json(fs.readfile(getenv("NTP_WORK_DIR") + "/" + case_name + "-" + protocol + ".json"));
}
function rules(value) { return value.dns.rules || []; }
function index_of(value, predicate) {
    let all = rules(value);
    for (let i = 0; i < length(all); i++) if (predicate(all[i])) return i;
    return -1;
}
function ntp_rule(rule, tag) {
    return rule.server == tag && type(rule.domain) == "array";
}
function server(value, tag) {
    return filter(value.dns.servers, (entry) => entry.tag == tag)[0];
}

for (let protocol in [ "udp", "doh", "dot" ]) {
    let udp = protocol == "udp";
    let tag = udp ? "bootstrap-dns-server" : "ntp-dns-server";
    let named = config("names", protocol);
    let expected_type = { udp: "udp", doh: "https", dot: "tls" }[protocol];
    let bootstrap = server(named, "bootstrap-dns-server");
    let backup = server(named, "dns-health-bootstrap-2-server");
    assert(bootstrap.type == expected_type && bootstrap.server_port == 1443 &&
        backup.type == expected_type && backup.server_port == { udp: 53, doh: 443, dot: 853 }[protocol],
        protocol + ": Bootstrap and all health candidates use the selected transport");
    assert(bootstrap.path == (protocol == "doh" ? "/dns-query" : null) &&
        bootstrap.tls?.server_name == (udp ? null : "dns.google"),
        protocol + ": defaults and the TLS identity are included where applicable");
    assert(bootstrap.detour == null && bootstrap.domain_resolver == null && backup.detour == null &&
        server(named, "dns-server").detour == "vpn-out" &&
        named.route.default_domain_resolver == "bootstrap-dns-server",
        protocol + ": Bootstrap is direct and resolves the proxy and main DNS dial targets");
    let found = filter(rules(named), (rule) => ntp_rule(rule, tag));
    assert(length(found) == 1, protocol + ": exactly one NTP DNS rule is expected");
    assert(found[0].action == "route", protocol + ": the NTP rule must route");
    assert(found[0].inbound == null && found[0].source_ip_cidr == null,
        protocol + ": the NTP rule must not be narrowed to one listener");
    assert(length(found[0].domain) == 2 &&
        found[0].domain[0] == "0.openwrt.pool.ntp.org" &&
        found[0].domain[1] == "time.example",
        protocol + ": only the server names belong in the rule, an address needs no lookup");

    // The rule has to beat the sections, or a FakeIP address reaches sysntpd,
    // and it must not displace the FakeIP test and proxy-check domains.
    let ntp_index = index_of(named, (rule) => ntp_rule(rule, tag));
    let fakeip_index = index_of(named, (rule) => rule.server == "fakeip-server" &&
        rule.domain != null && rule.domain[0] == "fakeip.podkop.fyi" && rule.domain[1] == "ip.podkop.fyi");
    let section_index = index_of(named, (rule) => type(rule.domain_suffix) == "array" &&
        rule.domain_suffix[0] == "vpn.example");
    assert(fakeip_index >= 0, protocol + ": the FakeIP test and proxy-check route must survive");
    assert(ntp_index == fakeip_index + 1, protocol + ": the NTP rule belongs right after the FakeIP test route");
    assert(section_index > ntp_index, protocol + ": the sections must not answer the NTP names first");

    for (let mode in [ "disabled", "addresses", "absent" ]) {
        let unused = config(mode, protocol);
        assert(index_of(unused, (rule) => ntp_rule(rule, tag)) == -1, protocol + ": no NTP rule for " + mode);
        assert(length(filter(unused.dns.servers, (server) => server.tag == "ntp-dns-server")) == 0,
            protocol + ": no independent NTP resolver for " + mode);
    }

    let resolver = server(named, tag);
    let plain = udp ? resolver : server(named, "ntp-dns-server-bootstrap");
    assert(plain.type == "udp", protocol + ": NTP name resolution works with an unset clock");
    assert(plain.server == "8.8.8.8" && plain.server_port == (udp ? 1443 : 53),
        protocol + ": an explicit encrypted port must not be used for plain NTP DNS");
    let absent = config("absent", protocol);
    let without_ntp = filter(rules(named), (rule) => !ntp_rule(rule, tag));
    assert(sprintf("%J", without_ntp) == sprintf("%J", rules(absent)),
        protocol + ": the NTP rule must be the only difference in the DNS rules");
    named.dns.rules = rules(absent);
    if (!udp) {
        assert(resolver.type == "group" && resolver.mode == "stable" &&
            join(",", resolver.servers) == "ntp-dns-server-bootstrap,bootstrap-dns-server",
            protocol + ": NTP falls back to encrypted Bootstrap once its clock is valid");
        named.dns.servers = filter(named.dns.servers, (server) => server.tag != tag && server.tag != plain.tag);
        let wan = config("wan", protocol);
        let wan_group = server(wan, tag);
        assert(wan_group.type == "group" && join(",", wan_group.servers) ==
            "ntp-dns-server-wan-1,ntp-dns-server-wan-2,ntp-dns-server-bootstrap,bootstrap-dns-server",
            protocol + ": NTP has two WAN DNS members and both Bootstrap fallbacks");
        for (let i = 0; i < 2; i++) {
            let ntp = server(wan, wan_group.servers[i]);
            let outbound = filter(wan.outbounds, (entry) => entry.tag == ntp.detour)[0];
            assert(ntp.type == "udp" && ntp.server == (i == 0 ? "192.0.2.53" : "192.0.2.54") && ntp.server_port == 53 &&
                outbound.type == "direct" && outbound.bind_interface == (i == 0 ? "ethfixture" : "ethfixture2"),
                protocol + ": NTP uses each provider DNS on its own WAN");
        }
        let renewed = config("renewed", protocol);
        assert(server(renewed, wan_group.servers[0]).server == "192.0.2.55",
            protocol + ": renewed primary WAN DNS is regenerated");
    }
    assert(sprintf("%J", named) == sprintf("%J", absent),
        protocol + ": the NTP changes must be limited to its rule and resolver");
}
' || fail "NTP bootstrap DNS rule assertions failed"

printf 'Xrust NTP DNS checks passed\n'

{
cat <<'UC'
let core_ip = require("core.ip");
let common_module = require("core.common");
let saved = null, calls = [], configured = { enabled: true, servers: [ "time.example", "192.0.2.123" ] };
let query_ok = true, dns = { dns_type: "doh" }, year = 2025;
const NTP_STARTUP_STATE = "fixture";
const CONFIG_NAME = "forkop";
let uci_core = { get_all: () => dns };
let ntp = { configuration: () => configured };
let common = { object_or_empty: common_module.object_or_empty, option: common_module.option, bool_option: common_module.bool_option,
    write_private_json_file: (path, state) => { assert(path == NTP_STARTUP_STATE); saved = state; } };
function current_year() { return year; }
function current_epoch() { return "1735689600"; }
function read_json_file(path) { assert(path == NTP_STARTUP_STATE); return saved; }
function command_success_from_args(args) { push(calls, args); return true; }
function system(args, timeout) { assert(timeout == 12000); push(calls, args); return query_ok ? 0 : -9; }
UC
sed -n '/^function time_sync_needed(/,/^}/p; /^function sync_time_if_needed(/,/^}/p' "$FORKOP_LIB/service/state.uc"
cat <<'UC'
assert(time_sync_needed(2025, true, true, 1735689600, 100, null), "plausible stale clock must be checked for TLS startup");
assert(!time_sync_needed(2025, true, true, 1735689610, 110, { uptime: 100, synchronized: 1735689600 }), "synced boot must not wait again");
assert(time_sync_needed(2025, true, true, 1735690000, 110, { uptime: 100, synchronized: 1735689600 }), "clock step must recheck");
assert(!time_sync_needed(2025, true, true, 1735689600, 119, { uptime: 100, synchronized: 0 }), "blocked NTP must be rate limited");
assert(time_sync_needed(2025, true, true, 1735689600, 145, { uptime: 100, synchronized: 0 }), "failed sync should become retryable");
assert(!time_sync_needed(2025, false, true, 1735689600, 100, null), "UDP startup should keep its previous policy");
assert(!time_sync_needed(2025, true, false, 1735689600, 100, null), "disabled sysntpd should not force a probe");
assert(time_sync_needed(2023, false, false, 10, 100, null), "extremely old clock should retain its recovery attempt");
sync_time_if_needed();
assert(join(" ", calls[0]) == "/usr/sbin/ntpd -n -q -p 192.0.2.123",
    "early startup must use bounded foreground NTP with IP literals only");
sync_time_if_needed();
assert(length(calls) == 1, "successful startup sync ran again");
saved = null;
calls = [];
query_ok = false;
configured.servers = [ "time.example" ];
sync_time_if_needed();
assert(saved.synchronized == 0 && calls[1][0] == "logger" &&
    index(calls[0], "194.190.168.1") >= 0 && index(calls[0], "time.example") < 0,
    "failed early sync should report the failure and use DNS-independent fallbacks");
sync_time_if_needed();
assert(length(calls) == 2, "failed startup sync ignored its cooldown");
print("Bounded numeric-IP NTP startup, synchronization marker and retry checks passed\n");
UC
} > "$WORK_DIR/sync-time.uc"
ucode -L "$FORKOP_LIB" "$WORK_DIR/sync-time.uc"

cat > "$WORK_DIR/bin/date" <<'SH'
#!/bin/sh
case "$1" in
    +%Y) printf '2025\n' ;;
    +%s) printf '1735689600\n' ;;
    *) exit 1 ;;
esac
SH
chmod +x "$WORK_DIR/bin/date"
printf 'forkop.settings=settings\nforkop.settings.dns_type=doh\n%s' "$DISABLED_STATE" > "$WORK_DIR/sync-dispatch.uci"
mkdir "$WORK_DIR/ntp-dispatch"
PATH="$WORK_DIR/bin:$PATH" FORKOP_UCI_STATE_FILE="$WORK_DIR/sync-dispatch.uci" \
  FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/ntp-dispatch" \
  ucode -L "$FORKOP_LIB" "$FORKOP_LIB/service/state.uc" sync-time-if-needed ||
  fail "native startup NTP dispatch failed with NTP disabled"
test ! -e "$WORK_DIR/ntp-dispatch/ntp-startup.json" || fail "disabled NTP must not start the probe"
printf 'Unmodified service module dispatch verified\n'
