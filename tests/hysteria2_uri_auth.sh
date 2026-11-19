#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB=${FORKOP_LIB:-$ROOT/forkop/files/usr/lib}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/links.txt" <<'URI'
hy2://lab:qa+one@literal.example:8443/?sni=localhost#literal
hysteria2://lab:qa%2Bone@escaped.example:8443/?sni=localhost#escaped
hy2://lab%40host:p%2Fq%3Fr%23s%252B@reserved.example:8443/?sni=localhost&obfs=salamander&obfs-password=ob%2Bfs%26x#reserved
URI

ucode -L "$LIB" "$LIB/subscription/parser.uc" normalize-uri-list \
    "$WORK/links.txt" "$WORK/subscription.json"
ucode -e '
    let fs = require("fs");
    let fixture = { settings: { ".name": "settings", ".type": "settings", dns_server: "1.1.1.1" },
        section: [{ ".name": "hy2", ".type": "section", enabled: "1", action: "connection",
            selector_proxy_links: split(trim(fs.readfile(ARGV[0])), "\n") }] };
    fs.writefile(ARGV[1], sprintf("%J", fixture));
' "$WORK/links.txt" "$WORK/fixture.json"
ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK/fixture.json" "$WORK/runtime.json" 127.0.0.1 0 1 '' 1.14.2-rust-x.0.0.43

cat >"$WORK/check.uc" <<'UC'
let fs = require("fs"), parser = require("subscription.parser");
for (let path in [ARGV[0], ARGV[1]]) {
    let outbounds = {};
    for (let node in json(fs.readfile(path)).outbounds)
        if (node.type == "hysteria2") outbounds[node.server] = node;
    assert(length(keys(outbounds)) == 3, "all Hysteria2 profiles must import");
    assert(outbounds["literal.example"].password == "lab:qa+one", "literal plus must survive");
    assert(outbounds["escaped.example"].password == "lab:qa+one", "escaped plus must survive");
    let reserved = outbounds["reserved.example"];
    assert(reserved.password == "lab@host:p/q?r#s%2B", "decode credentials once after splitting the URI");
    assert(reserved.obfs.password == "ob+fs&x", "query value must remain a single parameter");
}

let fixed = { type: "hysteria2", server: "cached.example", server_port: 8443,
    password: "qa one+two", share_link: "hy2://qa+one%2Btwo@cached.example:8443" };
let different_password = { ...fixed, password: "operator password" };
let different_port = { ...fixed, server_port: 9443 };
let different_hop_ports = { ...fixed, server_port: null, server_ports: ["2443:2443", "2444:2444"],
    share_link: "hy2://qa+one%2Btwo@cached.example:2443,2445" };
parser.repair_cached_outbounds([fixed, different_password, different_port, different_hop_ports]);
assert(fixed.password == "qa+one+two", "repair the old cached decoding result");
assert(different_password.password == "operator password", "preserve a different cached credential");
assert(different_port.password == "qa one+two", "preserve credentials at a different port");
assert(different_hop_ports.password == "qa one+two", "preserve credentials for a different port list");
UC
ucode -L "$LIB" "$WORK/check.uc" "$WORK/subscription.json" "$WORK/runtime.json"

echo 'PASS: Hysteria2 URI authentication survives import and cache repair'
