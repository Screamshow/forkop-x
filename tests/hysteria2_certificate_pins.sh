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
ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture "$WORK/fixture.json" "$WORK/generated.json" 127.0.0.1 0 1 '' 1.14.2-rust-x.0.0.26
ucode -e 'let c=json(require("fs").readfile(ARGV[0]));let n=filter(c.outbounds,function(o){return o.type=="hysteria2";});assert(length(n)==1&&n[0].tls.certificate_sha256&&n[0].tls.certificate_sha256[0]==ARGV[1],"manual Hysteria2 link lost pinSHA256");' "$WORK/generated.json" "$PIN"
echo 'Manual Hysteria2 link keeps pinSHA256 on Xrust'

echo KEEP >"$WORK/kept.json"
if ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture "$WORK/fixture.json" "$WORK/kept.json" 127.0.0.1 0 1 '' 1.14.2-x-1.0.4 >"$WORK/log" 2>&1; then
    echo "Hysteria2 pin accepted by a core without certificate pin support" >&2
    exit 1
fi
grep -q "manual outbound 'HY2 Pinned' requires TLS certificate SHA-256 pinning" "$WORK/log"
test "$(cat "$WORK/kept.json")" = KEEP
echo 'Cores without pin support refuse the pinned Hysteria2 link'
