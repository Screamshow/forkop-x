#!/usr/bin/env bash
# tailscaled in netfilter mode sets net.ipv4.conf.all.src_valid_mark=1. The
# kernel then checks the source of a packet it routes to itself with a lookup
# from lo carrying the packet's mark; answered from the Forkop table, whose
# local default route makes the client's address one of the router's, the
# packet dies as a martian source. A rule below 105 answers that lookup from
# the main table, and the router's own traffic carries a mark of its own so
# that rule never meets its rerouting lookup.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="${FORKOP_LIB:-$ROOT_DIR/forkop/files/usr/lib}"
NFT_UC="$FORKOP_LIB/nft/apply.uc"
VALIDATOR_UC="$FORKOP_LIB/config/validator.uc"
LIFECYCLE_UC="$FORKOP_LIB/service/lifecycle.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

FAKEIP_MARK=0x04000000
ROUTER_MARK="$(ucode -L "$FORKOP_LIB" "$FORKOP_LIB/core/constants.uc" get NFT_ROUTER_MARK)"
[ -n "$ROUTER_MARK" ] || fail 'the router mark is not a constant'
[ "$ROUTER_MARK" != "$FAKEIP_MARK" ] || fail 'the router mark repeats the FakeIP mark'

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/sysctl/all" "$WORK_DIR/sysctl/lo"
printf '0\n' >"$WORK_DIR/sysctl/all/disable_ipv6"
printf '0\n' >"$WORK_DIR/sysctl/lo/disable_ipv6"
export FORKOP_IPV6_SYSCTL_DIR="$WORK_DIR/sysctl"
export IP_LOG="$WORK_DIR/ip.log"
export PATH="$WORK_DIR/bin:$PATH"
cat >"$WORK_DIR/bin/ip" <<'EOF_IP'
#!/bin/sh
printf '%s\n' "$*" >>"$IP_LOG"
case "$*" in
  *'route list'*) [ "${IP_PRESENT:-0}" = 1 ] && echo 'local default dev lo scope host'; exit 0 ;;
  *'rule list'*) [ "${IP_PRESENT:-0}" = 1 ] && cat "$IP_RULES"; exit 0 ;;
esac
exit 0
EOF_IP
chmod +x "$WORK_DIR/bin/ip"

: >"$IP_LOG"
ucode -L "$FORKOP_LIB" "$NFT_UC" ensure-tproxy-route-rule forkop "$FAKEIP_MARK" "$WORK_DIR/rt_tables"

grep -Fxq -- "-4 rule add fwmark $FAKEIP_MARK/$FAKEIP_MARK table forkop priority 105" "$IP_LOG" ||
  fail 'the IPv4 TPROXY rule of LAN traffic was lost'
grep -Fxq -- "-6 rule add fwmark $FAKEIP_MARK/$FAKEIP_MARK table forkop priority 105" "$IP_LOG" ||
  fail 'the IPv6 TPROXY rule of LAN traffic was lost'
grep -Fxq -- "-4 rule add fwmark $ROUTER_MARK/$ROUTER_MARK table forkop priority 105" "$IP_LOG" ||
  fail "the router's own IPv4 traffic has no route to the core"
grep -Fxq -- "-6 rule add fwmark $ROUTER_MARK/$ROUTER_MARK table forkop priority 105" "$IP_LOG" ||
  fail "the router's own IPv6 traffic has no route to the core"

source_check="$(grep -E -- '^-4 rule add iif lo fwmark .* lookup main priority ' "$IP_LOG" || true)"
[ -n "$source_check" ] || fail 'the source check is still answered from the Forkop table'
case "$source_check" in
  "-4 rule add iif lo fwmark $FAKEIP_MARK/$FAKEIP_MARK lookup main priority "*) ;;
  *) fail 'the source-check rule does not read the FakeIP mark' ;;
esac
priority="${source_check##* }"
[ "$priority" -lt 105 ] || fail 'the source-check rule does not precede the TPROXY rules'
# forkop/files/usr/lib/tailscale/lan.sh owns priority 104 and refuses to set up
# the exit-node LAN while a rule it does not own sits there.
[ "$priority" != 104 ] || fail 'the source-check rule takes the Tailscale exit-node LAN priority'
grep -qE -- '^-6 rule add .*lookup main' "$IP_LOG" && fail 'IPv6 has no source check and needs no rule for it'

# Nothing is added twice: a reload keeps the rule set exact.
cat >"$WORK_DIR/rules" <<EOF_RULES
$priority:	from all fwmark $FAKEIP_MARK/$FAKEIP_MARK iif lo lookup main
105:	from all fwmark $FAKEIP_MARK/$FAKEIP_MARK lookup forkop
105:	from all fwmark $ROUTER_MARK/$ROUTER_MARK lookup forkop
EOF_RULES
: >"$IP_LOG"
IP_PRESENT=1 IP_RULES="$WORK_DIR/rules" ucode -L "$FORKOP_LIB" "$NFT_UC" \
  ensure-tproxy-route-rule forkop "$FAKEIP_MARK" "$WORK_DIR/rt_tables"
grep -q 'rule add' "$IP_LOG" && fail 'an existing rule set was added to again'
grep -q 'route add' "$IP_LOG" && fail 'an existing route was added again'

# A rule that only answers the source check is not the marking rule of its mark.
: >"$IP_LOG"
printf '%s:\tfrom all fwmark %s/%s iif lo lookup main\n' "$priority" "$FAKEIP_MARK" "$FAKEIP_MARK" >"$WORK_DIR/rules"
printf '105:\tfrom all fwmark %s/%s lookup forkop\n' "$ROUTER_MARK" "$ROUTER_MARK" >>"$WORK_DIR/rules"
IP_PRESENT=1 IP_RULES="$WORK_DIR/rules" ucode -L "$FORKOP_LIB" "$NFT_UC" \
  ensure-tproxy-route-rule forkop "$FAKEIP_MARK" "$WORK_DIR/rt_tables"
grep -Fxq -- "-4 rule add fwmark $FAKEIP_MARK/$FAKEIP_MARK table forkop priority 105" "$IP_LOG" ||
  fail 'a missing IPv4 TPROXY rule was read off the source-check rule'

# A stop removes every rule the start adds.
adds="$(sed -n '/^function ensure_tproxy_route_rule(/,/^function ensure_bridge_netfilter_disabled(/p' "$NFT_UC" |
  grep -c '"rule", "add"')"
stop_body="$(sed -n '/^function stop_main(/,/^function cleanup_failed_runtime(/p' "$LIFECYCLE_UC")"
dels="$(grep -c '"rule", "del"' <<<"$stop_body")"
[ "$adds" = "$dels" ] || fail "the stop removes $dels of the $adds routing rules the start adds"
grep -Fq '"ip", "-4", "rule", "del", "fwmark", NFT_ROUTER_MARK + "/" + NFT_ROUTER_MARK, "table", RT_TABLE_NAME, "priority", "105"' <<<"$stop_body" ||
  fail "the stop keeps the router's IPv4 TPROXY rule"
grep -Fq '"ip", "-6", "rule", "del", "fwmark", NFT_ROUTER_MARK + "/" + NFT_ROUTER_MARK, "table", RT_TABLE_NAME, "priority", "105"' <<<"$stop_body" ||
  fail "the stop keeps the router's IPv6 TPROXY rule"
grep -Fq '"ip", "-4", "rule", "del", "iif", "lo", "fwmark", NFT_FAKEIP_MARK + "/" + NFT_FAKEIP_MARK, "lookup", "main", "priority", NFT_SOURCE_CHECK_PRIORITY' <<<"$stop_body" ||
  fail 'the stop keeps the source-check rule'

# The two marks reach the same inbound, and each path carries its own.
BATCH="$WORK_DIR/candidate.nft"
: >"$BATCH"
cat >"$WORK_DIR/fixture.json" <<'EOF_FIXTURE'
{"section":[{".name":"capture","enabled":"1","action":"connection","ip_cidr":["11.0.0.1/32"]}]}
EOF_FIXTURE
FORKOP_NFT_BATCH_FILE="$BATCH" ucode -L "$FORKOP_LIB" "$NFT_UC" nft-create-runtime-base \
    ForkopRouterTest localv4 subnets ports ip_ports interfaces br-lan "$FAKEIP_MARK" 0x08000000 \
    198.18.0.0/15 1602 0 localv6 subnets6 ip_ports6 2001:2::/112 ::1
FORKOP_NFT_BATCH_FILE="$BATCH" ucode -L "$FORKOP_LIB" "$NFT_UC" nft-add-section-priority-rules-fixture \
    "$WORK_DIR/fixture.json" ForkopRouterTest interfaces localv4 localv6 "$FAKEIP_MARK" 198.18.0.0/15 2001:2::/112
FORKOP_NFT_BATCH_FILE="$BATCH" ucode -L "$FORKOP_LIB" "$NFT_UC" nft-create-runtime-output-rules \
    ForkopRouterTest localv4 subnets ports ip_ports "$FAKEIP_MARK" 198.18.0.0/15 localv6 subnets6 ip_ports6 2001:2::/112

capture_mask="$(ucode -L "$FORKOP_LIB" -e "
let fakeip = $FAKEIP_MARK;
let router = $ROUTER_MARK;
print(sprintf('0x%08x', fakeip | router));")"
for proto in tcp udp; do
  grep -Fq "proxy meta mark & $capture_mask != 0 meta l4proto $proto tproxy ip to :1602" "$BATCH" ||
    fail "the router's own $proto traffic is not intercepted"
done
grep -Fq "proxy meta mark & $capture_mask == 0 return" "$BATCH" ||
  fail 'unmarked traffic no longer leaves the interception chain early'

grep -q "^add rule inet ForkopRouterTest mangle .*meta mark set $FAKEIP_MARK" "$BATCH" ||
  fail 'LAN traffic lost the FakeIP mark'
grep -q "^add rule inet ForkopRouterTest mangle .*meta mark set $ROUTER_MARK" "$BATCH" &&
  fail 'LAN traffic was given the router mark'
grep -q "^add rule inet ForkopRouterTest mangle_output .*meta mark set $ROUTER_MARK" "$BATCH" ||
  fail "the router's own traffic lost the router mark"
grep -q "^add rule inet ForkopRouterTest mangle_output .*meta mark set $FAKEIP_MARK" "$BATCH" &&
  fail "the router's own traffic still carries the FakeIP mark"
grep -q "^add rule inet ForkopRouterTest priority_output_rules .*meta mark set $ROUTER_MARK" "$BATCH" ||
  fail 'a section no longer marks what the router itself sends with the router mark'
grep -q "^add rule inet ForkopRouterTest priority_rules .*meta mark set $FAKEIP_MARK" "$BATCH" ||
  fail 'a section no longer marks LAN traffic with the FakeIP mark'

# The fail-closed transition guard covers both marks or the router leaks.
: >"$WORK_DIR/nft.log"
: >"$WORK_DIR/guard.nft"
cat >"$WORK_DIR/bin/nft" <<'EOF_NFT'
#!/bin/sh
printf '%s\n' "$*" >>"$NFT_LOG"
[ "$1" = "-f" ] && cat "$2" >>"$GUARD_CAPTURE"
[ "$1" = "list" ] && exit 1
exit 0
EOF_NFT
chmod +x "$WORK_DIR/bin/nft"
NFT_LOG="$WORK_DIR/nft.log" GUARD_CAPTURE="$WORK_DIR/guard.nft" \
  ucode -L "$FORKOP_LIB" "$NFT_UC" install-transition-guard ForkopRouterTest "$FAKEIP_MARK"
for mark in "$FAKEIP_MARK" "$ROUTER_MARK"; do
  grep -Fq "meta mark & $mark == $mark counter drop" "$WORK_DIR/guard.nft" ||
    fail "the transition guard does not fail closed for $mark"
done

# The marks are checked against each other and against Tailscale's fwmark mask.
cat >"$WORK_DIR/validator.json" <<'EOF_VALIDATOR'
{"settings":{"dns_server":"1.1.1.1"},"section":[{".name":"a",".type":"section","enabled":"1","action":"connection","outbound_jsons":"{\"type\":\"direct\"}","domain_suffix":"example.org"}]}
EOF_VALIDATOR
validate() {
  ucode -L "$FORKOP_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$WORK_DIR/validator.json" "$1" 2>&1 || true
}
grep -Fq 'Router mark shares bits with the FakeIP or outbound mark' \
  <<<"$(validate "{\"nft_router_mark\":\"$FAKEIP_MARK\"}")" ||
  fail 'a router mark sharing bits with the FakeIP mark was accepted'
grep -Fq 'Router mark shares bits with the FakeIP or outbound mark' \
  <<<"$(validate '{"nft_router_mark":"0x08000000"}')" ||
  fail 'a router mark sharing bits with the outbound mark was accepted'
grep -Fq 'Router mark overlaps Tailscale fwmark mask' <<<"$(validate '{"nft_router_mark":"0x00880000"}')" ||
  fail 'a router mark inside the Tailscale fwmark mask was accepted'
grep -Fq 'Forkop marks contain invalid numeric constants' <<<"$(validate '{"nft_router_mark":""}')" ||
  fail 'a missing router mark was accepted'
grep -Fq 'Router mark' <<<"$(validate '{}')" &&
  fail 'the shipped marks are rejected by their own validation'

printf 'router mark and source-check routing checks passed\n'
