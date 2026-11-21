#!/bin/sh
# Hysteria2 pinSHA256 must reach tls.certificate_sha256 or the node must be refused.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB=${FORKOP_LIB:-$ROOT/forkop/files/usr/lib}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
HEX=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
COLON=01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF
PIN=ASNFZ4mrze8BI0VniavN7wEjRWeJq83vASNFZ4mrze8=
LINK="hysteria2://pw@127.0.0.1:8443?sni=localhost&pinSHA256=$COLON#HY2%20Pinned"

ucode -L "$LIB" "$LIB/subscription/parser.uc" share-link-outbound "$LINK" pinned >"$WORK/node.json"
ucode -e 'let n=json(require("fs").readfile(ARGV[0]));assert(type(n.tls.certificate_sha256)=="array"&&length(n.tls.certificate_sha256)==1&&n.tls.certificate_sha256[0]==ARGV[1],"Hysteria2 pinSHA256 dropped by the subscription parser");' "$WORK/node.json" "$PIN"
echo 'Subscription parser keeps Hysteria2 pinSHA256'

for pin in bad 1234; do
    if ucode -L "$LIB" "$LIB/subscription/parser.uc" share-link-outbound \
        "hysteria2://pw@127.0.0.1:8443?sni=localhost&pinSHA256=$pin" pinned >"$WORK/out" 2>"$WORK/err"; then
        echo "Invalid Hysteria2 pinSHA256 accepted" >&2
        exit 1
    fi
    grep -q 'Invalid TLS certificate SHA-256 pin' "$WORK/err"
done
echo 'Malformed Hysteria2 pinSHA256 fails closed'

cat >"$WORK/mihomo.yaml" <<YAML
proxies:
  - name: mihomo-pinned
    type: hysteria2
    server: 127.0.0.1
    port: 8443
    password: pw
    sni: localhost
    skip-cert-verify: true
    fingerprint: "$COLON"
    name-cert-verify: pinned.example
  - {name: bad-pin, type: hysteria2, server: 127.0.0.1, port: 8443, password: pw, fingerprint: abcdef}
  - {name: unpinned, type: hysteria2, server: 127.0.0.1, port: 8443, password: pw, skip-cert-verify: true}
YAML
ucode -L "$LIB" "$LIB/subscription/parser.uc" normalize-clash-yaml "$WORK/mihomo.yaml" "$WORK/mihomo.json"
ucode -e 'let nodes=json(require("fs").readfile(ARGV[0])).outbounds;
assert(length(nodes)==2&&nodes[0].tag=="mihomo-pinned"&&nodes[1].tag=="unpinned","malformed YAML pin retained or other nodes lost");
assert(nodes[0].tls.xray_pinned_peer_cert_sha256[0]==ARGV[1]&&nodes[0].tls.verify_server_name[0]=="pinned.example"&&nodes[0].tls.server_name=="localhost","Mihomo SHA-256 TLS fields lost");
assert(nodes[0].tls.insecure==null&&nodes[1].tls.insecure===true,"YAML pin changed skip-cert-verify policy");' "$WORK/mihomo.json" "$PIN"
echo 'Mihomo HY2 import preserves SHA-256 and rejects a malformed fingerprint'

# Export keeps the pin; an older cache entry is repaired from its share link.
# Modules expose their API only when required from a script file.
cat >"$WORK/roundtrip.uc" <<'UC'
let fs=require("fs"), links=require("subscription.share_link"), parser=require("subscription.parser");
let work=ARGV[0], pin=ARGV[1];
function normalize(raw){fs.writefile(work+"/input",raw);assert(parser.normalize_content_validated(work+"/input",work+"/output"),"normalize");return json(fs.readfile(work+"/output")).outbounds[0];}
let n=json(fs.readfile(work+"/node.json"));
delete n.share_link;
let exported=links.serialize_outbound_link(n);
let again=normalize(exported);
assert(again.tls.certificate_sha256 && again.tls.certificate_sha256[0]==pin,"Hysteria2 pin lost on export: "+exported);
let cached={type:"hysteria2",tag:"c",server:"127.0.0.1",server_port:8443,password:"pw",tls:{enabled:true,server_name:"localhost"},share_link:ARGV[2]};
parser.repair_cached_outbounds([cached]);
assert(cached.tls.certificate_sha256 && cached.tls.certificate_sha256[0]==pin,"cached Hysteria2 pin not repaired");
let mihomo=json(fs.readfile(work+"/mihomo.json")).outbounds[0];
let share=links.serialize_outbound_link(mihomo);
assert(index(share,"insecure=1")<0,"Mihomo pin export enables unpinned insecure fallback");
let restored=normalize(share);
assert(restored.tls.xray_pinned_peer_cert_sha256[0]==pin&&restored.tls.verify_server_name[0]=="pinned.example","Mihomo pin export lost its policy");
let xray=normalize(sprintf("%J",{outbounds:[{protocol:"hysteria",tag:"x",settings:{version:2,address:"127.0.0.1",port:8443},
 streamSettings:{network:"hysteria",security:"tls",hysteriaSettings:{version:2,auth:"pw"},tlsSettings:{serverName:"localhost",pinnedPeerCertSha256:[ARGV[3]]},
 finalmask:{udp:[{type:"salamander",settings:{password:"mask-password"}}]}}}]}));
assert(xray.type=="hysteria2" && xray.tls.xray_pinned_peer_cert_sha256 && xray.tls.xray_pinned_peer_cert_sha256[0]==pin,"Xray Hysteria2 pin dropped");
assert(xray.obfs?.type=="salamander" && xray.obfs.password=="mask-password","Xray Hysteria2 Salamander dropped");
UC
ucode -L "$LIB" "$WORK/roundtrip.uc" "$WORK" "$PIN" "$LINK" "$HEX"
echo 'Hysteria2 pin survives export, cache repair and Xray JSON import'

cat >"$WORK/fixture.json" <<JSON
{"settings":{".name":"settings",".type":"settings","dns_server":"1.1.1.1"},"section":[{".name":"pinned",".type":"section","enabled":"1","action":"connection","selector_proxy_links":["$LINK"]}]}
JSON
ucode -L "$LIB" "$LIB/xrust/generator.uc" generate-config-fixture "$WORK/fixture.json" "$WORK/generated.json" 127.0.0.1 0 1 '' 0.0.26
ucode -e 'let c=json(require("fs").readfile(ARGV[0]));let n=filter(c.outbounds,function(o){return o.type=="hysteria2";});assert(length(n)==1&&n[0].tls.certificate_sha256&&n[0].tls.certificate_sha256[0]==ARGV[1],"manual Hysteria2 link lost pinSHA256");' "$WORK/generated.json" "$PIN"
echo 'Manual Hysteria2 link keeps pinSHA256 on Xrust'

sed "s@pinSHA256=$COLON@pcs=$COLON@" "$WORK/fixture.json" >"$WORK/pcs.json"
ucode -L "$LIB" "$LIB/xrust/generator.uc" generate-config-fixture "$WORK/pcs.json" "$WORK/older.json" 127.0.0.1 0 1 '' 0.0.43
ucode -e 'let c=json(require("fs").readfile(ARGV[0]));let n=filter(c.outbounds,function(o){return o.type=="hysteria2";})[0];assert(n.tls.certificate_sha256[0]==ARGV[1]&&n.tls.insecure===true&&n.tls.xray_pinned_peer_cert_sha256==null,"old Xrust strict leaf pin missing");' "$WORK/older.json" "$PIN"
echo 'Older Xrust uses a mandatory whole-certificate leaf pin for HY2 pcs'

for pins in '[]' '[""]'; do
    ucode -e 'let outbound={type:"hysteria2",tag:"pinned",server:"127.0.0.1",server_port:8443,password:"pw",
        tls:{enabled:true,xray_pinned_peer_cert_sha256:json(ARGV[0])}};
    print(sprintf("%J",{settings:{".name":"settings",".type":"settings",dns_server:"1.1.1.1"},
        section:[{".name":"pinned",".type":"section",enabled:"1",action:"connection",outbound_jsons:[sprintf("%J",outbound)]}]}));' \
        "$pins" >"$WORK/empty-pcs.json"
    if ucode -L "$LIB" "$LIB/xrust/generator.uc" generate-config-fixture "$WORK/empty-pcs.json" "$WORK/empty-result.json" 127.0.0.1 0 1 '' 0.0.43 >"$WORK/log" 2>&1; then
        echo 'An empty HY2 pin list enabled insecure fallback' >&2
        exit 1
    fi
    grep -q 'TLS certificate SHA-256 pin' "$WORK/log"
done
echo 'HY2 fallback refuses empty and blank pin values'

echo KEEP >"$WORK/kept.json"
if ucode -L "$LIB" "$LIB/xrust/generator.uc" generate-config-fixture "$WORK/fixture.json" "$WORK/kept.json" 127.0.0.1 0 1 '' 1.14.2-x-1.0.4 >"$WORK/log" 2>&1; then
    echo "Legacy core accepted by the Xrust generator" >&2
    exit 1
fi
grep -q "the installed client must be Xrust" "$WORK/log"
test "$(cat "$WORK/kept.json")" = KEEP
echo 'The Xrust generator rejects a legacy core and preserves the active configuration'
