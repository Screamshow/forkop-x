#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB=${FORKOP_LIB:-$ROOT/forkop/files/usr/lib}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/subscription.txt" <<'URI'
hy2://pw@default-short.example/?sni=localhost#implicit-short
hysteria2://pw@default-long.example/?sni=localhost#implicit-long
hy2://pw@explicit.example:8443/?sni=localhost#explicit
hy2://pw@multi.example/?sni=localhost&mport=2443,2444-2445#multi
hy2://pw@empty.example:/?sni=localhost#empty
hy2://pw@invalid.example:0/?sni=localhost#invalid
vless://b831381d-6324-4d53-ad4f-8cda48b30811@vless.example/?type=tcp#vless
URI
ucode -L "$LIB" "$LIB/subscription/parser.uc" normalize-uri-list \
    "$WORK/subscription.txt" "$WORK/subscription.json"
ucode -e '
    let config = json(require("fs").readfile(ARGV[0]));
    let nodes = {};
    for (let node in config.outbounds) nodes[node.tag] = node;
    assert(length(keys(nodes)) == 4, "unexpected imported nodes");
    assert(nodes["implicit-short"].server_port == 443, "hy2 default port");
    assert(nodes["implicit-long"].server_port == 443, "hysteria2 default port");
    assert(nodes.explicit.server_port == 8443, "explicit port");
    assert(sprintf("%J", nodes.multi.server_ports) == sprintf("%J", ["2443:2443", "2444:2445"]), "mport precedence");
' "$WORK/subscription.json"

cat >"$WORK/fixture.json" <<'JSON'
{"settings":{".name":"settings",".type":"settings","dns_server":"1.1.1.1"},"section":[{".name":"hy2",".type":"section","enabled":"1","action":"connection","selector_proxy_links":["hy2://pw@default-short.example/?sni=localhost","hysteria2://pw@default-long.example/?sni=localhost","hy2://pw@explicit.example:8443/?sni=localhost","hysteria2://pw@override.example/?sni=localhost&mport=9443","hy2://pw@hopping.example:2443,2444-2445/?sni=localhost"]}]}
JSON
ucode -L "$LIB" "$LIB/xrust/generator.uc" generate-config-fixture \
    "$WORK/fixture.json" "$WORK/runtime.json" 127.0.0.1 0 1 '' 0.0.43
ucode -e '
    let config = json(require("fs").readfile(ARGV[0]));
    let ports = {};
    for (let node in config.outbounds) {
        if (node.type != "hysteria2") continue;
        ports[node.server] = node.server_port;
        if (node.server == "hopping.example")
            assert(sprintf("%J", node.server_ports) == sprintf("%J", ["2443:2443", "2444:2445"]), "manual port list");
    }
    assert(ports["default-short.example"] == 443 && ports["default-long.example"] == 443, "manual default ports");
    assert(ports["explicit.example"] == 8443 && ports["override.example"] == 9443, "explicit port and mport");
' "$WORK/runtime.json"

cat >"$WORK/clash.yaml" <<'YAML'
proxies:
  - name: range
    type: hysteria2
    server: range.example
    port: 7999
    ports: "2443,2444-2445"
    hop-interval: "15-30"
    password: pw
  - name: single
    type: hysteria2
    server: single.example
    ports: 2443
    password: pw
YAML
ucode -L "$LIB" "$LIB/subscription/parser.uc" normalize-content-validated "$WORK/clash.yaml" "$WORK/yaml.json"
ucode -e '
    let nodes = json(require("fs").readfile(ARGV[0])).outbounds;
    assert(length(nodes) == 2, "both Mihomo Hysteria2 nodes must import");
    assert(nodes[0].server_port == null && sprintf("%J", nodes[0].server_ports) == sprintf("%J", ["2443:2443", "2444:2445"]), "Mihomo ports override port");
    assert(nodes[0].hop_interval == "15s" && nodes[0].hop_interval_max == "30s", "Mihomo hop interval range");
    assert(nodes[1].server_port == 2443, "Mihomo single port without fallback");
' "$WORK/yaml.json"

echo 'PASS: Hysteria2 links default to 443 in subscriptions and manual imports'
