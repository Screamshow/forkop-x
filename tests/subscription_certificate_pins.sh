#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB=${FORKOP_LIB:-$ROOT/forkop/files/usr/lib}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ucode -L "$LIB" "$ROOT/tests/subscription_certificate_pins.uc" "$WORK"
for pin in bad 1234 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA; do
    if ucode -L "$LIB" "$LIB/subscription/parser.uc" share-link-outbound \
        "vless://00000000-0000-4000-8000-000000000001@127.0.0.1:443?security=tls&pcs=$pin" pinned >"$WORK/out" 2>"$WORK/err"; then
        echo "Invalid certificate pin accepted" >&2
        exit 1
    fi
    grep -q 'Invalid TLS certificate SHA-256 pin' "$WORK/err"
done
echo 'Malformed certificate pins fail closed'
cat >"$WORK/fixture.json" <<'JSON'
{"settings":{".name":"settings",".type":"settings","dns_server":"1.1.1.1"},"section":[{".name":"pinned",".type":"section","enabled":"1","action":"connection","selector_proxy_links":["vless://00000000-0000-4000-8000-000000000001@127.0.0.1:443?security=tls&sni=localhost&pcs=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"]}]}
JSON
ucode -L "$LIB" "$LIB/xrust/generator.uc" generate-config-fixture "$WORK/fixture.json" "$WORK/generated.json" 127.0.0.1 0 1 '' 0.0.22
ucode -e 'let c=json(require("fs").readfile(ARGV[0]));let nodes=filter(c.outbounds,function(o){return o.type=="vless";});assert(length(nodes)==1 && nodes[0].tls.certificate_sha256[0]=="ASNFZ4mrze8BI0VniavN7wEjRWeJq83vASNFZ4mrze8=","manual generation lost certificate pin");' "$WORK/generated.json"
echo 'Manual link generator retains certificate pin'
