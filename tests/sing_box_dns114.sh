#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
GENERATOR="$FORKOP_LIB/xrust/generator.uc"
WORK_DIR="${DNS114_WORK_DIR_OUTPUT:-}"
if [ -n "$WORK_DIR" ]; then
  mkdir -p "$WORK_DIR"
else
  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "$WORK_DIR"' EXIT
fi

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
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "source_bypass",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "domain_suffix": [ "bypass.example" ],
      "source_ip_cidr": [ "192.0.2.20/32" ]
    },
    {
      ".name": "vpn",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\"}" ],
      "excluded_source_ip_cidr": [ "192.0.2.133/32" ],
      "domain_suffix": [ "vpn.example" ],
      "community_lists": [ "youtube", "discord", "meta" ]
    }
  ]
}
JSON

generate() {
  local version="$1"
  local output="$WORK_DIR/config-$version.json"
  mkdir -p "$output.section-cache" "$output.rulesets"
  printf '%s\n' '{"version":3,"rules":[{"ip_cidr":["192.0.2.0/24"]}]}' > "$output.rulesets/vpn-community-subnets-lists-ruleset.json"
  ucode -L "$FORKOP_LIB" "$GENERATOR" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$output" "127.0.0.1" "0" "1" "" "$version"
}

generate 0.0.44
if generate 1.14.2-x-1.0.4 > "$WORK_DIR/legacy.log" 2>&1; then
  fail "a legacy core completed configuration generation"
fi
grep -q "the installed client must be Xrust" "$WORK_DIR/legacy.log" || fail "wrong legacy rejection"

DNS114_WORK_DIR="$WORK_DIR" ucode -e '
let fs = require("fs");

function config(version) { return json(fs.readfile(getenv("DNS114_WORK_DIR") + "/config-" + version + ".json")); }
function rules(value) { return value.dns.rules || []; }
for (let version in ["0.0.44"]) {
    let https = filter(rules(config(version)), function(rule) { return rule.query_type == "HTTPS"; });
    if (length(https) != 1 || https[0].action != "predefined" || https[0].rcode != "NOERROR")
        die("HTTPS suppression must return NODATA: " + version + "\n");
}
function contains(value, needle) {
    if (type(value) == "array") {
        for (let item in value) if (item == needle) return true;
    }
    return value == needle;
}
function domain_rule(rule) {
    if (rule == null) return false;
    if (contains(rule.domain_suffix, "bypass.example")) return true;
    for (let child in rule.rules || []) if (domain_rule(child)) return true;
    return false;
}
function ruleset_rule(rule, tag) {
    if (contains(rule.rule_set, tag)) return true;
    for (let child in rule.rules || []) if (ruleset_rule(child, tag)) return true;
    return false;
}
function response_rule(rule) {
    if (rule.match_response === true) return true;
    for (let child in rule.rules || []) if (response_rule(child)) return true;
    return false;
}
function no_empty_children(rule) {
    for (let child in rule.rules || []) {
        assert(length(child) > 0, "logical DNS rule must not contain an empty matcher");
        no_empty_children(child);
    }
}
function find(value, predicate) {
    for (let rule in rules(value)) if (predicate(rule)) return rule;
    return null;
}
function index(value, predicate) {
    let all = rules(value);
    for (let i = 0; i < length(all); i++) if (predicate(all[i])) return i;
    return -1;
}
function assert(ok, message) { if (!ok) { warn(message, "\n"); exit(1); } }

for (let version in [ "0.0.44" ]) {
    let count = 0;
    for (let rule in rules(config(version))) {
        if (rule.server != "fakeip-server") continue;
        count++;
        let types = rule.query_type;
        if (rule.type == "logical" && rule.mode == "and")
            for (let child in rule.rules) if (child.query_type != null) types = child.query_type;
        assert(type(types) == "array" && length(types) == 2 &&
            contains(types, "A") && contains(types, "AAAA"),
            version + " FakeIP must only receive address queries");
    }
    assert(count > 0, version + " fixture must exercise FakeIP routes");
}

let version = "0.0.44";
let value = config(version);
for (let rule in rules(value)) no_empty_children(rule);
let excluded_evaluate = find(value, r => r.action == "evaluate" && r.server == "dns-server");
assert(excluded_evaluate != null && excluded_evaluate.type == null &&
    contains(excluded_evaluate.source_ip_cidr, "192.0.2.133/32") && excluded_evaluate.invert === true,
    version + " unconditional evaluate must preserve the device exclusion without an empty logical child");
let evaluate_index = index(value, r => r.action == "evaluate" && r.server == "dnsmasq-server" && domain_rule(r));
let respond_index = index(value, r => r.action == "respond" && r.type == "logical" && domain_rule(r));
let fallback_index = index(value, r => r.action == "route" && r.server == "dns-server" && domain_rule(r));
assert(evaluate_index >= 0, "1.14 must evaluate the dnsmasq response");
assert(respond_index > evaluate_index, "1.14 must respond only after dnsmasq evaluate");
assert(fallback_index > respond_index, "1.14 fallback must run only after rejected dnsmasq response");
let respond = rules(value)[respond_index];
assert(respond.server == null, "1.14 respond must return the evaluated response, not query another server");
assert(respond.rules[1].match_response === true && respond.rules[1].invert === true, "1.14 response filter must inspect the evaluated non-FakeIP response");
assert(find(value, r => r.action == "evaluate" && r.server == "dns-server" && domain_rule(r)) == null, "1.14 must not evaluate the fallback resolver before dnsmasq");

let youtube = find(value, r => ruleset_rule(r, "vpn-youtube-community-ruleset"));
assert(youtube != null && youtube.match_response == null, version + " must keep domain-only rule-sets on query matching");
assert(find(value, r => ruleset_rule(r, "vpn-discord-community-ruleset") && !response_rule(r)) != null,
    version + " must select Discord domains before resolution");
assert(find(value, r => ruleset_rule(r, "vpn-discord-community-ruleset") && response_rule(r)) == null,
    version + " must not issue FakeIP by matching Discord shared edge addresses");
' || fail "Xrust DNS response-matching assertion failed"

printf 'Xrust DNS response-matching and FakeIP generation checks passed\n'
