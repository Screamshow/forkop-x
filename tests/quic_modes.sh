#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB=${FORKOP_LIB:-$ROOT/forkop/files/usr/lib}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

for mode in 00 01 11 10 00 10 11 01 00; do
    global=${mode%?}; vpn=${mode#?}
    cat >"$WORK/fixture.json" <<EOF
{"settings":{"dns_server":"1.1.1.1","disable_quic":"$global","disable_quic_vpn":"$vpn"},"section":[
{".name":"direct",".type":"section","enabled":"1","action":"bypass","domain_suffix":"direct.example"},
{".name":"vpn",".type":"section","enabled":"1","action":"connection","outbound_jsons":"{\"type\":\"vless\",\"server\":\"127.0.0.1\",\"server_port\":443,\"uuid\":\"00000000-0000-0000-0000-000000000001\"}","domain_suffix":"vpn.example","excluded_source_ip_cidr":"192.168.1.10/32","fully_routed_ips":"192.168.1.20/32"}]}
EOF
    ucode -L "$LIB" "$LIB/xrust/generator.uc" generate-config-fixture \
        "$WORK/fixture.json" "$WORK/config.json" 127.0.0.1 0 '' '' 1.14.2
    ucode -L "$LIB" -e '
let fs=require("fs"), c=json(fs.readfile(ARGV[0])), mode=ARGV[1];
function expect(ok, why) { if (!ok) die(mode+": "+why+"\n"); }
let rejects=[], direct=-1;
for(let i=0;i<length(c.route.rules);i++) {
    let r=c.route.rules[i];
    if(r.action=="route" && index(sprintf("%J",r),"direct.example")>=0) direct=i;
    if(r.action=="reject") push(rejects,{r,i});
}
let global=substr(mode,0,1)=="1", vpn=substr(mode,1,1)=="1";
expect(direct>=0,"DIRECT fixture route missing");
expect(length(rejects)==(global?1:vpn?2:0),"unexpected reject count");
if(global) {
    expect(rejects[0].r.protocol=="quic" && rejects[0].i<direct,"global rejection must precede DIRECT");
} else if(vpn) {
    for(let item in rejects) {
        expect(item.i>direct,"earlier DIRECT must win");
        let next=c.route.rules[item.i+1];
        expect(next.action=="route" && next.outbound=="vpn-out","reject must precede its VPN route");
        let encoded=sprintf("%J",item.r);
        expect(index(encoded,"quic")>=0,"QUIC protocol missing");
        expect(index(encoded,"192.168.1.10/32")>=0,"source exclusion lost");
        expect(index(encoded,"vpn.example")>=0 || index(encoded,"192.168.1.20/32")>=0,"VPN matchers lost");
        expect(index(encoded,"direct.example")<0,"DIRECT rule broadened");
    }
}
' "$WORK/config.json" "$mode"
    if command -v sing-box >/dev/null 2>&1; then
        sing-box check -c "$WORK/config.json"
    fi
done
printf 'PASS: QUIC modes and both toggle orders; scoped routes, DIRECT and source exclusions\n'
