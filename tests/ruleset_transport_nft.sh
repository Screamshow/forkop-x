#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FORKOP_LIB="$ROOT/forkop/files/usr/lib"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/extract.uc" <<'UC'
let fs=require("fs"), r=require("routing.rulesets");
function check(rules, ports, tcp, udp, common, ips, defer) {
    fs.writefile(ARGV[0]+"/rules.json",sprintf("%J",{version:3,rules}));
    let needs_core = r.extract_ip_cidr_nft_protocol_elements(ARGV[0]+"/rules.json",ARGV[0]+"/ips",ARGV[0]+"/ports",sprintf("%J",ports),"[]");
    assert(needs_core === !!defer, "wrong decision to defer rule to Xrust");
    for(let test in [{path:"ports.tcp",want:tcp},{path:"ports.udp",want:udp},{path:"ports",want:common},{path:"ips",want:ips}])
        if(trim(fs.readfile(ARGV[0]+"/"+test.path))!=test.want) die("transport extraction mismatch "+test.path+": "+fs.readfile(ARGV[0]+"/"+test.path)+"\n");
}
check([{network:"udp",ip_cidr:["192.0.2.0/24"],port:443}],[],"","192.0.2.0/24 . 443","","");
check([{network:["tcp"],ip_cidr:["2001:db8::/32"],port_range:["80:90"]}],[],"2001:db8::/32 . 80-90","","","");
check([{network:["tcp","udp"],ip_cidr:["192.0.2.0/24"],port:443}],[],"","","192.0.2.0/24 . 443","");
check([{network:"udp",ip_cidr:["192.0.2.0/24"]}],[],"","192.0.2.0/24 . 1-65535","","");
check([{ip_cidr:["192.0.2.0/24"]}],[],"","","","192.0.2.0/24");
check([{type:"logical",mode:"and",rules:[{network:"udp"},{ip_cidr:["192.0.2.0/24"],port_range:["80:90"]}]}],[85],"","192.0.2.0/24 . 85","","");
check([{type:"logical",mode:"and",rules:[{network:"udp"},{network:"tcp",ip_cidr:["192.0.2.0/24"],port:443}]}],[],"","","","");
check([{type:"logical",mode:"or",rules:[{network:"tcp",ip_cidr:["192.0.2.0/24"],port:80},{network:"udp",ip_cidr:["2001:db8::/32"],port:53}]}],[],"192.0.2.0/24 . 80","2001:db8::/32 . 53","","");
check([{type:"logical",mode:"and",rules:[{network:"udp"},{type:"logical",mode:"or",rules:[{network:"tcp",ip_cidr:["192.0.2.0/24"],port:80},{network:"udp",ip_cidr:["2001:db8::/32"],port:53}]}]}],[],"","2001:db8::/32 . 53","","");
check([{type:"logical",mode:"and",rules:[{ip_cidr:["192.0.2.0/24"]},{type:"logical",mode:"or",rules:[{network:"tcp",port:80},{network:"udp",port:53}]}]}],[],"192.0.2.0/24 . 80","192.0.2.0/24 . 53","","");
check([{network:"udp",invert:true,ip_cidr:["192.0.2.0/24"],port:443}],[],"","","","",true);
check([{type:"logical",mode:"and",rules:[{ip_cidr:["192.0.2.0/24"]},{invert:true,port:80}]}],[],"","","","",true);
check([{type:"logical",mode:"and",rules:[{ip_cidr:["192.0.2.0/24"]},{ip_cidr:["192.0.2.0/25"]}]}],[],"","","","",true);
check([{ip_cidr:["192.0.2.0/24"],source_ip_cidr:["198.51.100.2/32"]}],[],"","","","",true);
check([{type:"logical",mode:"or",rules:[{ip_cidr:["192.0.2.0/24"]},{port:80}]}],[],"","","","",true);
print("Ruleset transport extraction checks passed\n");
UC
ucode -L "$FORKOP_LIB" "$WORK/extract.uc" "$WORK"

cat > "$WORK/fixture.json" <<'JSON'
{"section":[{".name":"alpha","enabled":"1","action":"block","community_subnets":"0","rule_set_with_subnets":["https://fixture.test/rules.json"]}]}
JSON
cat > "$WORK/rules.json" <<'JSON'
{"version":3,"rules":[{"network":"udp","ip_cidr":["192.0.2.0/24","2001:db8::/32"],"port":443},{"network":"tcp","ip_cidr":["198.51.100.0/24"],"port":80}]}
JSON
export FORKOP_NFT_BATCH_FILE="$WORK/candidate.nft"
ucode -L "$FORKOP_LIB" "$FORKOP_LIB/nft/apply.uc" nft-add-json-ruleset-subnets-for-section-fixture \
 "$WORK/fixture.json" alpha "$WORK/rules.json" fixture forkop common ports "$WORK/ips" "$WORK/ports" 100 common6 ports6
grep -Eq 'alpha_udp_ip_ports.*192\.0\.2\.0/24 \. 443' "$WORK/candidate.nft"
grep -Eq 'alpha_udp_ip6_ports.*2001:db8::/32 \. 443' "$WORK/candidate.nft"
grep -Eq 'alpha_tcp_ip_ports.*198\.51\.100\.0/24 \. 80' "$WORK/candidate.nft"
if grep -Eq 'alpha_ip[6]?_ports.*(192\.0\.2|198\.51\.100|2001:db8)' "$WORK/candidate.nft"; then
 echo 'FAIL: transport-specific element leaked into shared set' >&2; exit 1
fi
if [ "${FORKOP_TEST_NFT_CHECK:-0}" = 1 ]; then
 table="forkop_transport_check_$$"
 {
  printf 'add table inet %s\n' "$table"
  for proto in tcp udp; do
   printf 'add set inet %s forkop_rule_alpha_%s_ip_ports { type ipv4_addr . inet_service; flags interval; }\n' "$table" "$proto"
   printf 'add set inet %s forkop_rule_alpha_%s_ip6_ports { type ipv6_addr . inet_service; flags interval; }\n' "$table" "$proto"
  done
  sed "s/inet forkop /inet $table /g" "$WORK/candidate.nft"
 } > "$WORK/kernel-check.nft"
 nft -c -f "$WORK/kernel-check.nft"
 if nft list table inet "$table" > /dev/null 2>&1; then
  echo 'FAIL: check-only candidate changed the firewall' >&2; exit 1
 fi
 printf 'Real nft check-only validation passed\n'
fi
# Generate the chains too: transport-specific sets need consumers even when
# Discord/community_subnets is disabled.
ucode -L "$FORKOP_LIB" "$FORKOP_LIB/nft/apply.uc" nft-add-section-priority-rules-fixture \
 "$WORK/fixture.json" forkop interfaces local local6 0x100 198.18.0.0/15 2001:2::/112
grep -Eq 'udp dport.*@forkop_rule_alpha_udp_ip_ports' "$WORK/candidate.nft"
grep -Eq 'tcp dport.*@forkop_rule_alpha_tcp_ip_ports' "$WORK/candidate.nft"

# A bypass with an inexact rule must send potential matches to Xrust. Locally
# accepting the projection would skip lower-priority routing and blocking.
cat > "$WORK/bypass.json" <<'JSON'
{"section":[
 {".name":"early","action":"bypass","ports":["443"],"remote_subnet_lists":["https://fixture.test/rules.json"]},
 {".name":"domains","action":"bypass","ports":["853"],"remote_domain_lists":["https://fixture.test/domains.txt"]},
 {".name":"late","action":"block","ports":["443"]}
]}
JSON
cat > "$WORK/complex.json" <<'JSON'
{"version":3,"rules":[{"type":"logical","mode":"and","rules":[{"ip_cidr":["192.0.2.0/24"]},{"invert":true,"port":80}]}]}
JSON
export FORKOP_NFT_BATCH_FILE="$WORK/bypass.nft"
ucode -L "$FORKOP_LIB" "$FORKOP_LIB/nft/apply.uc" nft-add-section-priority-rules-fixture \
 "$WORK/bypass.json" forkop interfaces local local6 0x100 198.18.0.0/15 2001:2::/112
ucode -L "$FORKOP_LIB" "$FORKOP_LIB/nft/apply.uc" nft-add-json-ruleset-subnets-for-section-fixture \
 "$WORK/bypass.json" early "$WORK/complex.json" fixture forkop common ports "$WORK/ips" "$WORK/ports" 100 common6 ports6
if grep -Eq 'dport @forkop_rule_(early|domains)_ports([[:space:]]|$)' "$WORK/bypass.nft"; then
 echo 'FAIL: remote-list bypass installed an unconditional port rule' >&2; exit 1
fi
grep -Eq 'add rule inet forkop priority_rules .*tcp dport @forkop_rule_early_ruleset_core_ports .*mark set 0x100 .*accept' "$WORK/bypass.nft"
grep -Eq 'add rule inet forkop priority_output_rules .*udp dport @forkop_rule_early_ruleset_core_ports .*mark set 0x10000000 .*accept' "$WORK/bypass.nft"
grep -Fxq 'add element inet forkop forkop_rule_early_ruleset_core_ports { 443 }' "$WORK/bypass.nft"
if grep -Eq '^add element .*forkop_rule_early_(subnets|ip_ports)' "$WORK/bypass.nft"; then
 echo 'FAIL: inexact ruleset installed a bypass projection' >&2; exit 1
fi
awk '/^add rule .* @forkop_rule_early_ruleset_core_ports / && !first { first=NR }
     /^add rule .* @forkop_rule_late_ports / && !last { last=NR }
     END { exit !(first && last && first < last) }' "$WORK/bypass.nft"
if [ "${FORKOP_TEST_NFT_CHECK:-0}" = 1 ]; then
 table="forkop_ruleset_fallback_$$"
 {
  printf 'add table inet %s\n' "$table"
  printf 'add chain inet %s priority_rules\n' "$table"
  printf 'add chain inet %s priority_output_rules\n' "$table"
  printf 'add set inet %s local { type ipv4_addr; flags interval; }\n' "$table"
  printf 'add set inet %s local6 { type ipv6_addr; flags interval; }\n' "$table"
  sed "s/inet forkop /inet $table /g" "$WORK/bypass.nft"
 } > "$WORK/kernel-fallback.nft"
 nft -c -f "$WORK/kernel-fallback.nft"
 if nft list table inet "$table" > /dev/null 2>&1; then
  echo 'FAIL: check-only fallback changed the firewall' >&2; exit 1
 fi
fi
printf 'Ruleset nft candidate checks passed\n'
