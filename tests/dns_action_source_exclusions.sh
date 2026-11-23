#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/forkop/files/usr/lib"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

printf '%s\n' '{"version":3,"rules":[{"domain_suffix":["list.example"]}]}' > "$WORK/domains.json"
ucode -e '
let fs = require("fs");
let fixture = {
    settings: { ".name": "settings", ".type": "settings", dns_server: "1.1.1.1" },
    section: [{
        ".name": "special", ".type": "section", action: "dns", enabled: "1",
        dns_type: "udp", dns_server: "9.9.9.9",
        fully_routed_ips: ["192.0.2.10/32"],
        domain_suffix: ["inline.example"],
        rule_set: [ARGV[0] + "/domains.json"],
        source_ip_cidr: ["192.0.2.0/24"],
        excluded_source_ip_cidr: ["192.0.2.2/32", "2001:db8::2/128"]
    }]
};
fs.writefile(ARGV[0] + "/fixture.json", sprintf("%J", fixture));
' "$WORK"
ucode -L "$LIB" "$LIB/xrust/generator.uc" generate-config-fixture \
 "$WORK/fixture.json" "$WORK/config.json" 127.0.0.1 0 1 '' 0.0.46
ucode -e '
let config = json(require("fs").readfile(ARGV[0]));
let server = filter(config.dns.servers, entry => entry.server == "9.9.9.9")[0];
assert(server != null, "configured resolver missing");
let rules = filter(config.dns.rules, rule => rule.server == server.tag);
assert(length(rules) == 3, "expected a resolver rule for each source, inline domain and list");
let matches = [];
for (let rule in rules) {
    assert(rule.type == "logical" && rule.mode == "and" && rule.action == "route" && rule.rewrite_ttl == 60,
        "DNS action belongs at the top level");
    assert(length(rule.rules) == 2 && rule.rules[1].invert &&
        "192.0.2.2/32" in rule.rules[1].source_ip_cidr && "2001:db8::2/128" in rule.rules[1].source_ip_cidr,
        "expected both source exclusions");
    for (let child in rule.rules)
        assert(child.action == null && child.server == null && child.rewrite_ttl == null, "child must contain only matchers");
    push(matches, rule.rules[0]);
}
assert(length(filter(matches, r => r.source_ip_cidr == "192.0.2.10/32")) == 1, "fully routed source lost");
assert(length(filter(matches, r => r.domain_suffix != null && r.source_ip_cidr == "192.0.2.0/24")) == 1,
    "inline domain and source restriction lost");
assert(length(filter(matches, r => r.rule_set != null && r.source_ip_cidr == "192.0.2.0/24")) == 1,
    "list and source restriction lost");
' "$WORK/config.json"
if [ -n "${FORKOP_XRUST_BIN:-}" ]; then
 "$FORKOP_XRUST_BIN" check -c "$WORK/config.json"
fi
printf 'DNS actions preserve exclusions and put resolver outside logical matchers\n'
