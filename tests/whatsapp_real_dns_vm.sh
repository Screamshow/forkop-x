#!/bin/sh
# Isolated integration test on the existing OpenWrt VMware VMs.
# No installed packages, UCI configuration or host firewall are changed.
set -eu
[ "${FORKOP_TEST_VM:-}" = 1 ] || exit 1
ubus call system board | grep -qi VMware || exit 1
LIB=${FORKOP_LIB:-/usr/lib/forkop}
CORE=${FORKOP_TEST_CORE:-/usr/bin/sing-box}
WORK=${FORKOP_TEST_WORK:-/tmp/forkop-whatsapp-test}
NS=wa-dns-$$
CLIENT=wa-client-$$
SERVER=wa-server-$$
mkdir -p "$WORK"
cleanup() {
    ip netns pids "$SERVER" 2>/dev/null | xargs -r kill 2>/dev/null || true
    ip netns del "$SERVER" 2>/dev/null || true
    ip netns pids "$CLIENT" 2>/dev/null | xargs -r kill 2>/dev/null || true
    ip netns del "$CLIENT" 2>/dev/null || true
    ip netns pids "$NS" 2>/dev/null | xargs -r kill 2>/dev/null || true
    ip netns del "$NS" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
ip netns add "$NS"
ip -n "$NS" link set lo up
r() { ip netns exec "$NS" "$@"; }
export WORK
ucode -e '
let fs = require("fs");
let work = getenv("WORK");
let fixture = {
 settings: { ".name":"settings", ".type":"settings", dns_type:"udp",
  dns_server:"127.0.0.1:5300", bootstrap_dns_server:"127.0.0.1",
  whatsapp_real_dns:"1", disable_quic:"1", log_level:"debug" },
 section: [
  { ".name":"vpn", ".type":"section", enabled:"1", action:"connection",
    outbound_jsons:["{\"type\":\"direct\",\"tag\":\"test-direct\"}"], community_lists:["meta"],
    domain_suffix:["whatsapp.net","unrelated.example"], excluded_source_ip_cidr:["192.0.2.99/32"] }
 ]
};
fs.writefile(work+"/on.json",sprintf("%J",fixture));
fixture.settings.whatsapp_real_dns="0";
fs.writefile(work+"/off.json",sprintf("%J",fixture));
fixture.settings.whatsapp_real_dns="1";
fixture.section[0].community_lists=[];
fs.writefile(work+"/missing-meta.json",sprintf("%J",fixture));
fixture.section[0].community_lists=["meta"];
fixture.section[0].source_ip_cidr=["192.0.2.10/32"];
fs.writefile(work+"/filtered-meta.json",sprintf("%J",fixture));
delete fixture.section[0].source_ip_cidr;
unshift(fixture.section,{".name":"custom_dns",".type":"section",enabled:"1",action:"dns",dns_type:"udp",dns_server:"127.0.0.1:5301",domain_suffix:["whatsapp.net"]});
fs.writefile(work+"/custom.json",sprintf("%J",fixture));
let rules={version:3,rules:[{domain_suffix:["whatsapp.net","whatsapp.com","whatsapp.biz","wa.me","unrelated.example"]},{ip_cidr:["11.0.0.0/24","2001:db8:2::/64"]}]};
fs.writefile(work+"/meta.json",sprintf("%J",rules));
'
version=$($CORE version | head -1 | awk '{print $3}')
for mode in on off custom; do
    mkdir -p "$WORK/$mode.config.rulesets"
    cp "$WORK/meta.json" "$WORK/$mode.config.rulesets/vpn-community-subnets-lists-ruleset.json"
    ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture \
        "$WORK/$mode.json" "$WORK/$mode.config" 127.0.0.1 0 1 '' "$version"
done
# Avoid remote rule-set downloads and persistent caches in this deterministic test.
# The rule-set contains both names and real addresses, matching Meta's mixed format.
ucode -e '
let fs=require("fs"); let work=getenv("WORK");
for (let mode in ["on","off","custom"]) {
 let p=work+"/"+mode+".config"; let c=json(fs.readfile(p));
 for (let rs in c.route.rule_set || []) if (rs.type=="remote") {
  rs.type="local"; rs.format="source"; rs.path=work+"/meta.json";
  delete rs.url; delete rs.update_interval;
 }
 delete c.experimental;
 if (mode=="on" && c.dns.reverse_mapping!==true) die("reverse mapping missing\n");
 fs.writefile(p,sprintf("%J",c));
}
let on=json(fs.readfile(work+"/on.config"));
let off=json(fs.readfile(work+"/off.config"));
if (sprintf("%J",on.route.rules)!=sprintf("%J",off.route.rules) ||
    sprintf("%J",on.outbounds)!=sprintf("%J",off.outbounds)) die("toggle changed routes\n");
'
for mode in on off custom; do r "$CORE" check -c "$WORK/$mode.config"; done
ucode -L "$LIB" "$LIB/config/validator.uc" validate-runtime-fixture "$WORK/on.json"
for fixture in missing-meta filtered-meta; do
    if ucode -L "$LIB" "$LIB/config/validator.uc" validate-runtime-fixture "$WORK/$fixture.json" >"$WORK/$fixture.log" 2>&1; then
        echo "FAIL: $fixture accepted"; exit 1
    fi
    grep -q 'WhatsApp real DNS requires' "$WORK/$fixture.log"
    echo "PASS $fixture rejected"
done
if ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture "$WORK/on.json" "$WORK/no-subnets.config" 127.0.0.1 0 1 '' "$version" >"$WORK/no-subnets.log" 2>&1; then
    echo 'FAIL: missing subnet cache accepted'; exit 1
fi
grep -q 'WhatsApp real DNS requires downloaded Meta' "$WORK/no-subnets.log"
for mode in on off; do
    ucode -L "$LIB" "$LIB/service/state.uc" reload-state-text-fixture "$WORK/$mode.json" >"$WORK/$mode.state"
done
on_signature=$(sed -n 's/^sing_box_signature=//p' "$WORK/on.state")
off_signature=$(sed -n 's/^sing_box_signature=//p' "$WORK/off.state")
[ -n "$on_signature" ] && [ "$on_signature" != "$off_signature" ]
echo 'PASS routes unchanged; reload signature changes; missing subnet cache rejected'
r dnsmasq --keep-in-foreground --conf-file=/dev/null --no-resolv --no-hosts --local-ttl=60 --port=5300 \
    --address=/whatsapp.net/11.0.0.2 --address=/whatsapp.net/2001:db8:2::2 \
    --address=/whatsapp.com/11.0.0.2 --address=/whatsapp.com/2001:db8:2::2 \
    --address=/whatsapp.biz/11.0.0.2 --address=/whatsapp.biz/2001:db8:2::2 \
    --address=/wa.me/11.0.0.2 --address=/wa.me/2001:db8:2::2 \
    --address=/unrelated.example/11.0.0.2 >"$WORK/resolver.log" 2>&1 &
sleep 1
r dnsmasq --keep-in-foreground --conf-file=/dev/null --no-resolv --no-hosts --local-ttl=60 --port=5301 \
    --address=/whatsapp.net/11.0.0.3 >"$WORK/custom-resolver.log" 2>&1 &
sleep 1
r "$CORE" run -c "$WORK/custom.config" >"$WORK/custom.log" 2>&1 &
sleep 2
r dig @127.0.0.42 api.whatsapp.net A +short +time=2 +tries=1 | grep -qx 11.0.0.3
echo 'PASS explicit DNS section takes precedence'
ip netns pids "$NS" | while read -r pid; do
    [ "$(cat /proc/$pid/comm)" = dnsmasq ] || kill "$pid" 2>/dev/null || true
done
sleep 1
for mode in off on off; do
    r "$CORE" run -c "$WORK/$mode.config" >"$WORK/$mode.log" 2>&1 &
    sleep 2
    for name in api.whatsapp.net web.whatsapp.com whatsapp.biz wa.me; do
        a=$(r dig @127.0.0.42 "$name" A +short +time=2 +tries=1)
        aaaa=$(r dig @127.0.0.42 "$name" AAAA +short +time=2 +tries=1)
        if [ "$mode" = on ]; then
            [ "$a" = 11.0.0.2 ] && [ "$aaaa" = 2001:db8:2::2 ] || {
                echo "FAIL $mode $name A=$a AAAA=$aaaa"; exit 1;
            }
        else
            echo "$a" | grep -Eq '^198\.(18|19)\.'
            echo "$aaaa" | grep -Eq '^2001:2::'
        fi
    done
    r dig @127.0.0.42 unrelated.example A +short +time=2 +tries=1 | grep -Eq '^198\.(18|19)\.'
    r dig @127.0.0.42 fakeip.podkop.fyi A +short +time=2 +tries=1 | grep -Eq '^198\.(18|19)\.'
    echo "PASS $mode WhatsApp A/AAAA; other domains and FakeIP control preserved"
    ip netns pids "$NS" | while read -r pid; do
        [ "$(cat /proc/$pid/comm)" = dnsmasq ] || kill "$pid" 2>/dev/null || true
    done
    sleep 1
done
echo "PASS $version DNS enable/disable/recovery"

# Real client packets through Forkop-generated nftables and TPROXY rules.
ip netns add "$CLIENT"
ip -n "$CLIENT" link set lo up
ip -n "$NS" link add br-lan type veth peer name wa-client
ip -n "$NS" link set wa-client netns "$CLIENT"
ip -n "$NS" addr add 172.30.0.1/24 dev br-lan
ip -n "$CLIENT" addr add 172.30.0.2/24 dev wa-client
ip -n "$NS" link set br-lan up
ip -n "$CLIENT" link set wa-client up
ip netns add "$SERVER"
ip -n "$SERVER" link set lo up
ip -n "$NS" link add wan type veth peer name wa-server
ip -n "$NS" link set wa-server netns "$SERVER"
ip -n "$NS" addr add 11.0.0.1/24 dev wan
ip -n "$SERVER" addr add 11.0.0.2/24 dev wa-server
ip -n "$NS" -6 addr add 2001:db8:2::1/64 dev wan nodad
ip -n "$SERVER" -6 addr add 2001:db8:2::2/64 dev wa-server nodad
ip -n "$NS" link set wan up
ip -n "$SERVER" link set wa-server up
ip -n "$SERVER" route add default via 11.0.0.1
ip -n "$SERVER" -6 route add default via 2001:db8:2::1
ip -n "$CLIENT" route add default via 172.30.0.1
ip -n "$NS" -6 addr add 2001:db8:1::1/64 dev br-lan nodad
ip -n "$CLIENT" -6 addr add 2001:db8:1::2/64 dev wa-client nodad
ip -n "$CLIENT" -6 route add default via 2001:db8:1::1
r ip rule add fwmark 0x04000000/0x04000000 table 100
r ip route add local 0.0.0.0/0 dev lo table 100
r ip -6 rule add fwmark 0x04000000/0x04000000 table 100
r ip -6 route add local ::/0 dev lo table 100
FORKOP_NFT_BATCH_FILE="$WORK/base.nft" ucode -L "$LIB" "$LIB/nft/apply.uc" nft-create-runtime-base \
    WhatsAppTest localv4 subnets ports ip_ports interfaces br-lan 0x04000000 0x08000000 198.18.0.0/15 1602 0 localv6 subnets6 ip_ports6 2001:2::/112 ::1
r nft -f "$WORK/base.nft"
# Documentation prefixes are local-bypassed in production; remove that prefix
# only inside this isolated test namespace to exercise the IPv6 capture path.
r nft 'delete element inet WhatsAppTest localv6 { 2001:db8::/32 }'
r nft 'add element inet WhatsAppTest subnets { 11.0.0.0/24 }'
r nft 'add element inet WhatsAppTest subnets6 { 2001:db8:2::/64 }'
r "$CORE" run -c "$WORK/on.config" >"$WORK/traffic.log" 2>&1 &
ip netns exec "$SERVER" socat TCP4-LISTEN:18080,bind=11.0.0.2,reuseaddr,fork EXEC:/bin/cat >"$WORK/echo4.log" 2>&1 &
ip netns exec "$SERVER" socat UDP4-RECVFROM:18081,bind=11.0.0.2,fork EXEC:/bin/cat >>"$WORK/echo4.log" 2>&1 &
ip netns exec "$SERVER" socat 'TCP6-LISTEN:18080,bind=[2001:db8:2::2],ipv6only=1,reuseaddr,fork' EXEC:/bin/cat >"$WORK/echo6.log" 2>&1 &
ip netns exec "$SERVER" socat 'UDP6-RECVFROM:18081,bind=[2001:db8:2::2],ipv6only=1,fork' EXEC:/bin/cat >>"$WORK/echo6.log" 2>&1 &
sleep 2
r dig @127.0.0.42 api.whatsapp.net A +short | grep -qx 11.0.0.2
r dig @127.0.0.42 api.whatsapp.net AAAA +short | grep -qx 2001:db8:2::2
for destination in TCP4:11.0.0.2:18080 UDP4:11.0.0.2:18081 'TCP6:[2001:db8:2::2]:18080' 'UDP6:[2001:db8:2::2]:18081'; do
    result=$(printf 'whatsapp-probe\n' | ip netns exec "$CLIENT" socat -T 3 - "$destination")
    [ "$result" = whatsapp-probe ] || { echo "FAIL traffic $destination"; exit 1; }
    echo "PASS TPROXY $destination"
done
r nft list table inet WhatsAppTest >"$WORK/traffic.nft"
grep -Eq 'tproxy.*counter packets [1-9]' "$WORK/traffic.nft"
if ! grep -q 'outbound/direct\[test-direct\]' "$WORK/traffic.log"; then
    # Rust X logs the matching rule index instead of the outbound tag.
    indices=$(ucode -e 'let fs=require("fs"); let c=json(fs.readfile(getenv("WORK")+"/on.config")); let result=[]; for(let i=0;i<length(c.route.rules);i++) if(c.route.rules[i].outbound=="vpn-out") push(result,""+i); print(join("|",result));')
    [ -n "$indices" ]
    grep -Eq "route: match\[($indices)\].*=> route" "$WORK/traffic.log"
fi
echo "PASS $version real-IP TCP/UDP IPv4/IPv6 routed through selected section"
