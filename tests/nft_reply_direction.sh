#!/usr/bin/env bash
# A reply packet answers a connection the other side opened, or one the core
# already holds. Marked for TPROXY it finds no socket of its own and the
# connection dies, so both capture chains must let it out before they classify.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="${FORKOP_LIB:-$ROOT_DIR/forkop/files/usr/lib}"
NFT_UC="$FORKOP_LIB/nft/apply.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK_DIR/sysctl/all" "$WORK_DIR/sysctl/lo"
printf '0\n' >"$WORK_DIR/sysctl/all/disable_ipv6"
printf '0\n' >"$WORK_DIR/sysctl/lo/disable_ipv6"
export FORKOP_IPV6_SYSCTL_DIR="$WORK_DIR/sysctl"

cat >"$WORK_DIR/fixture.json" <<'EOF_FIXTURE'
{"settings":{"dns_server":"1.1.1.1"},"section":[{".name":"telegram",".type":"section","enabled":"1","action":"connection","outbound_jsons":"{\"type\":\"direct\"}","subnets":["149.154.160.0/20"],"fully_routed_ips":["192.0.2.1/32","2001:db8::1/128"]}]}
EOF_FIXTURE

BATCH="$WORK_DIR/candidate.nft"
: >"$BATCH"
FORKOP_NFT_BATCH_FILE="$BATCH" ucode -L "$FORKOP_LIB" "$NFT_UC" nft-create-runtime-base \
    ForkopReplyTest localv4 subnets ports ip_ports interfaces br-lan 0x04000000 0x08000000 \
    198.18.0.0/15 1602 0 localv6 subnets6 ip_ports6 fc00::/18 ::1
FORKOP_NFT_BATCH_FILE="$BATCH" ucode -L "$FORKOP_LIB" "$NFT_UC" nft-add-section-priority-rules-fixture \
    "$WORK_DIR/fixture.json" ForkopReplyTest interfaces localv4 localv6 0x04000000 198.18.0.0/15 fc00::/18
FORKOP_NFT_BATCH_FILE="$BATCH" ucode -L "$FORKOP_LIB" "$NFT_UC" nft-create-runtime-output-rules \
    ForkopReplyTest localv4 subnets ports ip_ports 0x04000000 198.18.0.0/15 localv6 subnets6 ip_ports6 fc00::/18

# Position of the first rule of a chain whose text matches the pattern, or 0.
rule_position() {
    awk -v chain="$1" -v pattern="$2" '
        $0 ~ "^add rule inet ForkopReplyTest " chain " " {
            position++
            if (index($0, pattern) > 0 && !found) { found = position }
        }
        END { print found + 0 }
    ' "$BATCH"
}

for chain in mangle mangle_output; do
    reply="$(rule_position "$chain" "ct direction reply return")"
    [ "$reply" -gt 0 ] || fail "$chain never leaves reply packets out of the capture"
done

mangle_reply="$(rule_position mangle 'ct direction reply return')"
mangle_jump="$(rule_position mangle 'jump priority_rules')"
mangle_mark="$(rule_position mangle 'meta mark set 0x04000000')"
[ "$mangle_jump" -gt 0 ] || fail 'mangle lost its section jump'
[ "$mangle_mark" -gt 0 ] || fail 'mangle lost its FakeIP marking'
[ "$mangle_reply" -lt "$mangle_jump" ] ||
    fail 'a LAN device answering an inbound connection still reaches the section rules'
[ "$mangle_reply" -lt "$mangle_mark" ] || fail 'mangle marks a reply before dropping out'

output_reply="$(rule_position mangle_output 'ct direction reply return')"
output_jump="$(rule_position mangle_output 'jump priority_output_rules')"
output_mark="$(rule_position mangle_output 'meta mark set 0x04000000')"
[ "$output_jump" -gt 0 ] || fail 'mangle_output lost its section jump'
[ "$output_mark" -gt 0 ] || fail 'mangle_output lost its FakeIP marking'
[ "$output_reply" -lt "$output_jump" ] ||
    fail 'a server on the router answering over WAN still reaches the section rules'
[ "$output_reply" -lt "$output_mark" ] || fail 'mangle_output marks a reply before dropping out'

# The original direction, which is what a client actually sends, is untouched.
grep -q '^add rule inet ForkopReplyTest mangle ct status dnat return$' "$BATCH" ||
    fail 'the DNAT return was lost'
grep -q 'priority_rules .*meta mark set 0x04000000 counter accept' "$BATCH" ||
    fail 'section capture of client traffic was lost'

printf 'reply-direction capture checks passed\n'
