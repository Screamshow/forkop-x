#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
GENERATOR="$FORKOP_LIB/xrust/generator.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

write_materialized_rulesets() {
  local output="$1"
  mkdir -p "$output.rulesets" "$output.section-cache"
  cat >"$output.rulesets/vpn-remote-domains-ruleset.json" <<'JSON'
{"version":1,"rules":[{"domain_suffix":["plain-one.fixture.test","plain-two.fixture.test"]}]}
JSON
  cat >"$output.rulesets/vpn-remote-subnets-ruleset.json" <<'JSON'
{"version":1,"rules":[{"ip_cidr":["149.154.160.0/20","2001:db8:149::/48"]}]}
JSON
}

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_path": "/tmp/sing-box/config.json",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "vpn",
      ".type": "section",
      "enabled": "1",
      "action": "vpn",
      "interface": "wg0",
      "remote_domain_lists": [
        "https://fixture.test/domains-one.txt",
        "https://fixture.test/domains-two.txt"
      ],
      "remote_subnet_lists": [
        "https://fixture.test/subnets-one.txt",
        "https://fixture.test/subnets-two.txt"
      ],
      "rule_set_with_subnets": [ "https://fixture.test/mixed.srs" ]
    },
    {
      ".name": "bypass",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "remote_domain_lists": [ "https://fixture.test/remote-domains.json" ],
      "remote_subnet_lists": [ "https://fixture.test/remote-subnets.srs" ]
    },
    {
      ".name": "shared",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\"}" ],
      "remote_domain_lists": [ "https://fixture.test/remote-domains.json" ],
      "remote_subnet_lists": [ "https://fixture.test/remote-subnets.srs" ]
    }
  ]
}
JSON

generate() {
  local fixture="$1"
  local output="$2"
  write_materialized_rulesets "$output"
  ucode -L "$FORKOP_LIB" "$GENERATOR" generate-config-fixture \
    "$fixture" "$output" "127.0.0.1" "0" "1" "" "1.14.0"
}

OUTPUT="$WORK_DIR/generated.json"
generate "$WORK_DIR/fixture.json" "$OUTPUT"

ucode -e '
let fs = require("fs");
let config = json(fs.readfile(ARGV[0]));

function values(value) {
    return type(value) == "array" ? value : value == null ? [] : [ value ];
}
function contains(value, expected) {
    for (let item in values(value))
        if (item == expected)
            return true;
    return false;
}
function rule_set(tag) {
    for (let item in config.route.rule_set || [])
        if (item && item.tag == tag)
            return item;
    return null;
}
function route(outbound, tag) {
    for (let item in config.route.rules || [])
        if (item && item.outbound == outbound && contains(item.rule_set, tag))
            return item;
    return null;
}
function dns(tag) {
    for (let item in config.dns.rules || [])
        if (item && contains(item.rule_set, tag))
            return item;
    return null;
}
function assert(condition, message) {
    if (!condition)
        die(message + "\n");
}

let vpn_domains = rule_set("vpn-remote-domains-ruleset");
let vpn_subnets = rule_set("vpn-remote-subnets-ruleset");
assert(vpn_domains && vpn_domains.type == "local" && vpn_domains.format == "source", "plain remote domains are registered as a local source rule-set");
assert(vpn_subnets && vpn_subnets.type == "local" && vpn_subnets.format == "source", "plain remote IPv4/IPv6 subnets are registered as a local source rule-set");
assert(route("vpn-out", "vpn-remote-domains-ruleset") != null, "VPN route includes materialized remote domain tag");
assert(route("vpn-out", "vpn-remote-subnets-ruleset") != null, "VPN route includes materialized remote subnet tag");
assert(dns("vpn-remote-domains-ruleset") != null, "remote domains participate in FakeIP DNS routing");

let mixed = null;
for (let item in config.route.rule_set || [])
    if (item && item.url == "https://fixture.test/mixed.srs") mixed = item;
assert(mixed && route("vpn-out", mixed.tag) != null, "rule_set_with_subnets remains in VPN route routing");

let json_domains = null;
let srs_subnets = null;
for (let item in config.route.rule_set || []) {
    if (item && item.url == "https://fixture.test/remote-domains.json") json_domains = item;
    if (item && item.url == "https://fixture.test/remote-subnets.srs") srs_subnets = item;
}
assert(json_domains && json_domains.type == "remote" && json_domains.format == "source", "remote JSON domains are registered");
assert(srs_subnets && srs_subnets.type == "remote" && srs_subnets.format == "binary", "remote SRS subnets are registered");
assert(route("bypass-out", json_domains.tag) != null, "bypass route includes remote JSON domain tag");
assert(route("bypass-out", srs_subnets.tag) != null, "bypass route includes remote SRS subnet tag");
assert(dns(json_domains.tag) != null, "remote JSON domains participate in bypass DNS routing");
assert(route("shared-out", json_domains.tag) != null && route("shared-out", srs_subnets.tag) != null, "shared remote sources are attached to every owning section route");
' "$OUTPUT" || fail "remote lists must be registered in the generated routing config"

# Removing the source from the effective UCI input must remove its route tag,
# even if an old materialized file still exists in the ruleset directory.
cat >"$WORK_DIR/without-remote.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "1.1.1.1", "service_listen_address": "127.0.0.1" },
  "section": [
    { ".name": "vpn", ".type": "section", "enabled": "1", "action": "vpn", "interface": "wg0", "remote_subnet_lists": [ "https://fixture.test/subnets-one.txt" ] }
  ]
}
JSON
STALE_OUTPUT="$WORK_DIR/without-remote.generated.json"
generate "$WORK_DIR/without-remote.json" "$STALE_OUTPUT"
ucode -e '
let fs = require("fs");
let config = json(fs.readfile(ARGV[0]));
for (let rule in config.route.rules || []) {
    let tags = type(rule.rule_set) == "array" ? rule.rule_set : rule.rule_set == null ? [] : [ rule.rule_set ];
    for (let tag in tags)
        if (tag == "vpn-remote-domains-ruleset") die("stale remote domain route tag remained after source removal\n");
}
for (let rule_set in config.route.rule_set || [])
    if (rule_set.tag == "vpn-remote-domains-ruleset") die("stale remote domain rule-set remained after source removal\n");
' "$STALE_OUTPUT" || fail "removed remote list source must not leave a stale route tag"

# A plain remote subnet can be intercepted by nft before sing-box sees it.
# Refuse the configuration if its materialized active-generation rule-set is
# missing; accepting it would silently fall through to route.final/direct.
MISSING_OUTPUT="$WORK_DIR/missing-materialized.json"
write_materialized_rulesets "$MISSING_OUTPUT"
rm -f "$MISSING_OUTPUT.rulesets/vpn-remote-subnets-ruleset.json"
if ucode -L "$FORKOP_LIB" "$GENERATOR" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$MISSING_OUTPUT" "127.0.0.1" "0" "1" "" "1.14.0" \
  >"$WORK_DIR/missing-materialized.stdout" 2>"$WORK_DIR/missing-materialized.stderr"; then
  fail "missing materialized remote subnet ruleset must fail closed"
fi
grep -Fq "remote subnets ruleset for 'vpn' is missing or invalid" "$WORK_DIR/missing-materialized.stderr" ||
  fail "missing materialized remote subnet ruleset must report a safe reason"

cat >"$WORK_DIR/local-matchers.uc" <<'UCODE'
let fs = require("fs");
let rulesets = require("routing.rulesets");
let path = ARGV[0];
fs.writefile(path, "not JSON");
assert(rulesets.source_matchers(path) == null, "skip malformed local lists");
fs.writefile(path, sprintf("%J", {version: 3, rules: [{domain_suffix: ["local.fixture.test"]}]}));
let domains = rulesets.source_matchers(path);
assert(domains.domains && !domains.addresses, "domain-only lists match DNS queries");
fs.writefile(path, sprintf("%J", {version: 3, rules: [{domain_suffix: ["local.fixture.test"]}, {ip_cidr: ["192.0.2.0/24"]}]}));
let mixed = rulesets.source_matchers(path);
assert(mixed.addresses && !mixed.domains, "mixed lists match DNS responses");
UCODE
ucode -L "$FORKOP_LIB" "$WORK_DIR/local-matchers.uc" "$WORK_DIR/local-ruleset.json" ||
  fail "local ruleset matcher classification changed"

printf 'local.fixture.test\r\n192.0.2.0/24\n2001:db8:149::/48\n' >"$WORK_DIR/local-list.txt"
cat >"$WORK_DIR/combined.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "1.1.1.1" },
  "section": [
    { ".name": "combined", ".type": "section", "enabled": "1", "action": "bypass",
      "domain_ip_lists": [ "$WORK_DIR/local-list.txt", "https://fixture.test/combined.txt" ] },
    { ".name": "local_only", ".type": "section", "enabled": "1", "action": "bypass",
      "domain_ip_lists": [ "$WORK_DIR/local-list.txt" ] }
  ]
}
JSON

COMBINED_OUTPUT="$WORK_DIR/combined.generated.json"
mkdir -p "$COMBINED_OUTPUT.rulesets"
cat >"$WORK_DIR/materialized.json" <<'JSON'
{"version":3,"rules":[{"domain_suffix":["local.fixture.test","remote.fixture.test"]},{"ip_cidr":["192.0.2.0/24","198.51.100.0/24"]}]}
JSON
cp "$WORK_DIR/materialized.json" "$COMBINED_OUTPUT.rulesets/combined-lists-ruleset.json"
generate "$WORK_DIR/combined.json" "$COMBINED_OUTPUT"
cmp "$WORK_DIR/materialized.json" "$COMBINED_OUTPUT.rulesets/combined-lists-ruleset.json" ||
  fail "generator overwrote the updater's mixed local/remote materialization"
ucode -e '
let fs = require("fs");
let config = json(fs.readfile(ARGV[0]));
assert(length(filter(config.route.rule_set, item => item.tag == "combined-lists-ruleset")) == 1,
    "the complete mixed ruleset must participate in routing");
let local = json(fs.readfile(ARGV[0] + ".rulesets/local_only-lists-ruleset.json"));
assert(local.rules[0].domain_suffix[0] == "local.fixture.test", "local CRLF domain missing");
assert(length(local.rules[1].ip_cidr) == 2, "local IPv4 and IPv6 networks missing");
' "$COMBINED_OUTPUT"

ABSENT_OUTPUT="$WORK_DIR/absent.generated.json"
generate "$WORK_DIR/combined.json" "$ABSENT_OUTPUT"
[ ! -e "$ABSENT_OUTPUT.rulesets/combined-lists-ruleset.json" ] ||
  fail "generator published incomplete mixed list without an updater generation"
[ -s "$ABSENT_OUTPUT.rulesets/local_only-lists-ruleset.json" ] ||
  fail "missing mixed generation suppressed an independent local list"

printf 'Remote list routing checks passed\n'
