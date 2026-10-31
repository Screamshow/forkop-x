#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
FORKOP_LIB=${FORKOP_LIB:-$ROOT_DIR/forkop/files/usr/lib}
NFT_UC=$FORKOP_LIB/nft/apply.uc
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/sysctl/all" "$WORK_DIR/sysctl/lo"
export FORKOP_IPV6_SYSCTL_DIR=$WORK_DIR/sysctl
export IPV6_TEST_LOG=$WORK_DIR/ip.log
export PATH=$WORK_DIR/bin:$PATH
cat >"$WORK_DIR/bin/ip" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$IPV6_TEST_LOG"
case "$*" in '-6 '*) [ "${IPV6_TEST_FAIL6:-0}" = 0 ] || exit 1 ;; esac
case "$*" in
  *'route list'*) [ "${IPV6_TEST_PRESENT:-0}" = 1 ] && echo 'local default dev lo scope host'; exit 0 ;;
  *'rule list'*) [ "${IPV6_TEST_PRESENT:-0}" = 1 ] && echo '105: from all fwmark 0x4000000/0x4000000 lookup 305'; exit 0 ;;
esac
[ "${IPV6_TEST_FAIL:-0}" = 0 ]
EOF
cat >"$WORK_DIR/bin/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$WORK_DIR/bin/ip" "$WORK_DIR/bin/logger"
cat >"$WORK_DIR/fixture.json" <<'EOF'
{"settings":{"dns_server":"1.1.1.1"},"section":[{".name":"test",".type":"section","enabled":"1","action":"connection","outbound_jsons":"{\"type\":\"direct\"}","domain_suffix":"example.org","ports":"443","fully_routed_ips":["192.0.2.1/32","2001:db8::1/128"]},{".name":"ports",".type":"section","enabled":"1","action":"block","ports":"443"}]}
EOF

for mode in enabled all-disabled lo-disabled missing; do
    printf '0\n' >"$WORK_DIR/sysctl/all/disable_ipv6"
    printf '0\n' >"$WORK_DIR/sysctl/lo/disable_ipv6"
    case "$mode" in
        all-disabled) printf '1\n' >"$WORK_DIR/sysctl/all/disable_ipv6" ;;
        lo-disabled) printf '1\n' >"$WORK_DIR/sysctl/lo/disable_ipv6" ;;
        missing) rm "$WORK_DIR/sysctl/all/disable_ipv6" "$WORK_DIR/sysctl/lo/disable_ipv6" ;;
    esac
    : >"$IPV6_TEST_LOG"
    ucode -L "$FORKOP_LIB" "$NFT_UC" ensure-tproxy-route-rule 305 0x04000000 "$WORK_DIR/rt_tables"
    grep -q '^route add local 0.0.0.0/0' "$IPV6_TEST_LOG" || fail "$mode lost IPv4 route"
    grep -q '^-4 rule add' "$IPV6_TEST_LOG" || fail "$mode lost IPv4 rule"
    if [ "$mode" = enabled ]; then
        grep -q '^-6 route add local ::/0' "$IPV6_TEST_LOG" || fail 'missing IPv6 route'
        grep -q '^-6 rule add' "$IPV6_TEST_LOG" || fail 'missing IPv6 rule'
    elif grep -q '^-6 ' "$IPV6_TEST_LOG"; then
        fail "$mode attempted IPv6 routing"
    fi
    IPV6_TEST_PRESENT=1 ucode -L "$FORKOP_LIB" "$NFT_UC" tproxy-route-rule-present 305 0x04000000
    if [ "$mode" = enabled ]; then
        if IPV6_TEST_FAIL6=1 ucode -L "$FORKOP_LIB" "$NFT_UC" ensure-tproxy-route-rule 305 0x04000000 "$WORK_DIR/rt_tables"; then
            fail 'enabled IPv6 routing failure was ignored'
        fi
    fi
    if IPV6_TEST_FAIL=1 ucode -L "$FORKOP_LIB" "$NFT_UC" ensure-tproxy-route-rule 305 0x04000000 "$WORK_DIR/rt_tables"; then
        fail "$mode ignored a routing failure"
    fi

    batch=$WORK_DIR/$mode.nft
    FORKOP_NFT_BATCH_FILE=$batch ucode -L "$FORKOP_LIB" "$NFT_UC" nft-create-runtime-base \
        ForkopIPv6Test localv4 subnets ports ip_ports interfaces br-lan 0x04000000 0x08000000 198.18.0.0/15 1602 0 localv6 subnets6 ip_ports6 2001:2::/112 ::1
    FORKOP_NFT_BATCH_FILE=$batch ucode -L "$FORKOP_LIB" "$NFT_UC" nft-create-runtime-output-rules \
        ForkopIPv6Test localv4 subnets ports ip_ports 0x04000000 198.18.0.0/15 localv6 subnets6 ip_ports6 2001:2::/112
    FORKOP_NFT_BATCH_FILE=$batch ucode -L "$FORKOP_LIB" "$NFT_UC" nft-add-section-priority-rules-fixture \
        "$WORK_DIR/fixture.json" ForkopIPv6Test interfaces localv4 localv6 0x04000000 198.18.0.0/15 2001:2::/112
    grep -q 'tproxy ip to' "$batch" || fail "$mode lost IPv4 interception"
    grep -q 'priority_output_rules ip daddr != @localv4 tcp dport @forkop_rule_ports_ports' "$batch" ||
        fail "$mode lost family-scoped section port capture"
    if [ "$mode" = enabled ]; then
        grep -q 'tproxy ip6 to' "$batch" || fail 'missing IPv6 interception'
    else
        if grep '^add rule ' "$batch" | grep -q ' ip6 '; then fail "$mode kept IPv6 rules"; fi
    fi
    signature=$(ucode -L "$FORKOP_LIB" "$NFT_UC" nft-runtime-signature-fixture "$WORK_DIR/fixture.json")
    state_signature=$(ucode -L "$FORKOP_LIB" "$FORKOP_LIB/service/state.uc" nft-signature-fixture "$WORK_DIR/fixture.json")
    [ "$signature" = "$state_signature" ] || fail 'nft and reload signatures disagree'
    for disable_quic in 0 1; do
        sed "s/\"dns_server\"/\"disable_quic\":\"$disable_quic\",\"dns_server\"/" \
            "$WORK_DIR/fixture.json" >"$WORK_DIR/quic-$disable_quic.json"
        quic_signature=$(ucode -L "$FORKOP_LIB" "$NFT_UC" nft-runtime-signature-fixture "$WORK_DIR/quic-$disable_quic.json")
        quic_state_signature=$(ucode -L "$FORKOP_LIB" "$FORKOP_LIB/service/state.uc" nft-signature-fixture "$WORK_DIR/quic-$disable_quic.json")
        [ "$quic_signature" = "$quic_state_signature" ] || fail "$mode QUIC=$disable_quic signatures disagree"
        if [ "$disable_quic" = 0 ]; then
            quic_off_signature=$quic_signature
        else
            [ "$quic_signature" != "$quic_off_signature" ] || fail "$mode QUIC toggle did not change signature"
            [ "$quic_signature" = "$signature" ] || fail "$mode default QUIC signature differs from enabled"
        fi
    done
    sb_signature=$(ucode -L "$FORKOP_LIB" "$FORKOP_LIB/service/state.uc" sing-box-signature-fixture "$WORK_DIR/fixture.json")
    if [ "$mode" = enabled ]; then enabled_signature=$signature; else
        [ "$signature" != "$enabled_signature" ] || fail 'IPv6 change did not change nft signature'
    fi
    if [ "$mode" = enabled ]; then enabled_sb_signature=$sb_signature; else
        [ "$sb_signature" != "$enabled_sb_signature" ] || fail 'IPv6 change did not change sing-box signature'
    fi
    ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/generator.uc" generate-config-fixture \
        "$WORK_DIR/fixture.json" "$WORK_DIR/$mode.json" 127.0.0.1 0 '' '' 1.12.0
    if command -v sing-box >/dev/null 2>&1; then
        sing-box check -c "$WORK_DIR/$mode.json"
    fi
    if [ "$mode" = enabled ]; then
        grep -q 'tproxy6-in' "$WORK_DIR/$mode.json" || fail 'IPv6 listener missing'
    elif grep -q 'tproxy6-in' "$WORK_DIR/$mode.json"; then
        fail "$mode kept IPv6 listener or matcher"
    fi
done

ucode -L "$FORKOP_LIB" -e '
let n = require("core.netstat");
let ports = "0.0.0.0:1602\n127.0.0.42:53\n";
if (!n.sing_box_standard_ports_listening(ports, null, null, "")) exit(1);
if (n.sing_box_standard_ports_listening(ports, null, null, "::1")) exit(1);
if (!n.sing_box_standard_ports_listening(ports + "::1:1602\n", null, null, "::1")) exit(1);
'
# Service checks must precede both port-wide and system-wide proxy sections.
mkdir -p "$WORK_DIR/enabled-sysctl/all" "$WORK_DIR/enabled-sysctl/lo"
printf "0\n" >"$WORK_DIR/enabled-sysctl/all/disable_ipv6"
printf "0\n" >"$WORK_DIR/enabled-sysctl/lo/disable_ipv6"
for version in 1.12.0 1.14.2-x-1.0.0 1.14.2-rust-x.0.0.30; do
    for capture in ports system; do
    ucode -e '
let fs = require("fs"), c = json(fs.readfile(ARGV[0]));
c.section[0].ports = ARGV[2] == "ports" ? ["1-65535"] : [];
c.section[0].fully_routed_ips = ARGV[2] == "system" ? ["@system"] : [];
fs.writefile(ARGV[1], sprintf("%J", c));
' "$WORK_DIR/fixture.json" "$WORK_DIR/service-fixture.json" "$capture"
    FORKOP_IPV6_SYSCTL_DIR="$WORK_DIR/enabled-sysctl" ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/generator.uc" generate-config-fixture \
        "$WORK_DIR/service-fixture.json" "$WORK_DIR/service.json" 127.0.0.1 0 '' '' "$version"
    ucode -e '
let fs = require("fs"), c = json(fs.readfile(ARGV[0]));
let check = -1, exit_check = -1, section = -1;
for (let i, r in c.route.rules) {
    if (r.domain == "fakeip.podkop.fyi") {
        check = i;
        if (r.action != "route" || r.outbound != "direct-out" || r.override_port != 8443 || r.inbound != null)
            die("FakeIP reference must go direct for every inbound\n");
    }
    if (r.domain == "ip.podkop.fyi") {
        exit_check = i;
        if (r.outbound != "test-out") die("exit check bypassed the proxy section\n");
    }
    if (r.domain == null && r.outbound == "test-out") section = i;
}
if (check < 0 || exit_check < 0 || section < 0 || check >= section)
    die("service checks must precede user sections\n");
let found = false;
for (let r in c.dns.servers)
    if (r.tag == "fakeip-server") {
        found = true;
        if (r.inet6_range != "2001:2::/112") die("wrong IPv6 FakeIP range\n");
    }
if (!found) die("missing FakeIP server\n");
' "$WORK_DIR/service.json"
    done
done
printf 'IPv6 TPROXY auto-detection checks passed\n'
