#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
GENERATOR="$FORKOP_LIB/singbox/generator.uc"
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
    "config_path": "/tmp/sing-box/config.json",
    "dns_type": "doh",
    "dns_server": "https://dns.example/dns-query",
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

# $1 case name, $2 core version, $3 uci state body ("" for no system.ntp at all)
generate() {
  local case_name="$1" version="$2" state="$3"
  local output="$WORK_DIR/$case_name-$version.json"
  rm -rf "$output.section-cache" "$output.rulesets"
  mkdir -p "$output.section-cache" "$output.rulesets"
  local state_file="$WORK_DIR/$case_name.state"
  printf '%s' "$state" >"$state_file"
  FORKOP_UCI_STATE_FILE="$state_file" ucode -L "$FORKOP_LIB" "$GENERATOR" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$output" "127.0.0.1" "0" "1" "" "$version" ||
    fail "generation failed for $case_name on $version"
  printf '%s' "$output"
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

# Both core variants the generator targets: a classic sing-box and an Xrust build.
for version in 1.12.25 1.14.1 1.14.1-rust-x.3; do
  generate names "$version" "$NAMES_STATE" >/dev/null
  generate disabled "$version" "$DISABLED_STATE" >/dev/null
  generate addresses "$version" "$ADDRESSES_STATE" >/dev/null
  generate absent "$version" "" >/dev/null
done

NTP_WORK_DIR="$WORK_DIR" ucode -e '
let fs = require("fs");

function assert(ok, message) { if (!ok) { warn(message, "\n"); exit(1); } }
function config(case_name, version) {
    return json(fs.readfile(getenv("NTP_WORK_DIR") + "/" + case_name + "-" + version + ".json"));
}
function rules(value) { return value.dns.rules || []; }
function index_of(value, predicate) {
    let all = rules(value);
    for (let i = 0; i < length(all); i++) if (predicate(all[i])) return i;
    return -1;
}
function bootstrap_rules(value) {
    return filter(rules(value), (rule) => rule.server == "bootstrap-dns-server");
}

for (let version in [ "1.12.25", "1.14.1", "1.14.1-rust-x.3" ]) {
    let named = config("names", version);
    let found = bootstrap_rules(named);
    assert(length(found) == 1, version + ": exactly one bootstrap DNS rule is expected");
    assert(found[0].action == "route", version + ": the NTP rule must route");
    assert(found[0].inbound == null && found[0].source_ip_cidr == null,
        version + ": the NTP rule must not be narrowed to one listener");
    assert(length(found[0].domain) == 2 &&
        found[0].domain[0] == "0.openwrt.pool.ntp.org" &&
        found[0].domain[1] == "time.example",
        version + ": only the server names belong in the rule, an address needs no lookup");

    // The rule has to beat the sections, or a FakeIP address reaches sysntpd,
    // and it must not displace the FakeIP test and proxy-check domains.
    let ntp_index = index_of(named, (rule) => rule.server == "bootstrap-dns-server");
    let fakeip_index = index_of(named, (rule) => rule.server == "fakeip-server" &&
        rule.domain != null && rule.domain[0] == "fakeip.podkop.fyi" && rule.domain[1] == "ip.podkop.fyi");
    let section_index = index_of(named, (rule) => type(rule.domain_suffix) == "array" &&
        rule.domain_suffix[0] == "vpn.example");
    assert(fakeip_index >= 0, version + ": the FakeIP test and proxy-check route must survive");
    assert(ntp_index == fakeip_index + 1, version + ": the NTP rule belongs right after the FakeIP test route");
    assert(section_index > ntp_index, version + ": the sections must not answer the NTP names first");

    assert(length(bootstrap_rules(config("disabled", version))) == 0, version + ": sysntpd is off");
    assert(length(bootstrap_rules(config("addresses", version))) == 0, version + ": addresses need no lookup");
    assert(length(bootstrap_rules(config("absent", version))) == 0, version + ": no NTP section");

    // Nothing but that one rule may move.
    let absent = config("absent", version);
    let without_ntp = filter(rules(named), (rule) => rule.server != "bootstrap-dns-server");
    assert(sprintf("%J", without_ntp) == sprintf("%J", rules(absent)),
        version + ": the NTP rule must be the only difference in the DNS rules");
    named.dns.rules = rules(absent);
    assert(sprintf("%J", named) == sprintf("%J", absent),
        version + ": nothing outside the DNS rules may change");
}
' || fail "NTP bootstrap DNS rule assertions failed"

printf 'sing-box NTP bootstrap DNS checks passed\n'
