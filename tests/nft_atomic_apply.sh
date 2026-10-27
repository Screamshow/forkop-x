#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
NFT_UC="$FORKOP_LIB/nft/apply.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/nft" <<'EOF_NFT'
#!/bin/sh
printf '%s\n' "$*" >>"$NFT_ATOMIC_LOG"
[ -n "${NFT_ATOMIC_CAPTURE:-}" ] && [ "$1" = "-f" ] && cat "$2" >>"$NFT_ATOMIC_CAPTURE"
[ "${NFT_ATOMIC_FAIL:-}" = "$1 $2" ] && exit 1
[ "$1" = "list" ] && exit 1
exit 0
EOF_NFT
chmod +x "$WORK_DIR/bin/nft"
printf '149.154.160.0/20\n2001:db8::/32\n' >"$WORK_DIR/telegram.txt"
: >"$WORK_DIR/nft.log"

PATH="$WORK_DIR/bin:$PATH" NFT_ATOMIC_LOG="$WORK_DIR/nft.log" \
FORKOP_NFT_BATCH_FILE="$WORK_DIR/candidate.nft" \
  ucode -L "$FORKOP_LIB" "$NFT_UC" nft-add-file-chunks-to-set \
    "$WORK_DIR/telegram.txt" ForkopTable forkop_subnets ips '' 5000
[ ! -s "$WORK_DIR/nft.log" ] || fail "candidate preparation touched active nft"
grep -Fq 'add element inet ForkopTable forkop_subnets { 149.154.160.0/20,2001:db8::/32 }' "$WORK_DIR/candidate.nft" ||
  fail "candidate lost Telegram IPv4 CIDR"

PATH="$WORK_DIR/bin:$PATH" NFT_ATOMIC_LOG="$WORK_DIR/nft.log" \
  ucode -L "$FORKOP_LIB" "$NFT_UC" nft-apply-candidate-batch "$WORK_DIR/candidate.nft"
[ "$(wc -l <"$WORK_DIR/nft.log")" -eq 2 ] || fail "candidate was not applied as one check/apply pair"
grep -Fxq -- "-c -f $WORK_DIR/candidate.nft" "$WORK_DIR/nft.log" || fail "candidate syntax check missing"
grep -Fxq -- "-f $WORK_DIR/candidate.nft" "$WORK_DIR/nft.log" || fail "candidate apply missing"

: >"$WORK_DIR/nft.log"
if PATH="$WORK_DIR/bin:$PATH" NFT_ATOMIC_LOG="$WORK_DIR/nft.log" FORKOP_NFT_CANDIDATE_FAIL_PHASE=prepare \
  FORKOP_NFT_BATCH_FILE="$WORK_DIR/prepare-failed.nft" \
  ucode -L "$FORKOP_LIB" "$NFT_UC" nft-add-file-chunks-to-set \
    "$WORK_DIR/telegram.txt" ForkopTable forkop_subnets ips '' 5000; then
  fail "injected candidate preparation failure was accepted"
fi
[ ! -s "$WORK_DIR/nft.log" ] || fail "preparation failure touched live nft"

: >"$WORK_DIR/nft.log"
if PATH="$WORK_DIR/bin:$PATH" NFT_ATOMIC_LOG="$WORK_DIR/nft.log" NFT_ATOMIC_FAIL='-c -f' \
  ucode -L "$FORKOP_LIB" "$NFT_UC" nft-apply-candidate-batch "$WORK_DIR/candidate.nft"; then
  fail "invalid candidate check was accepted"
fi
[ "$(wc -l <"$WORK_DIR/nft.log")" -eq 1 ] || fail "apply ran after failed candidate validation"

for phase in check apply; do
  : >"$WORK_DIR/nft.log"
  if PATH="$WORK_DIR/bin:$PATH" NFT_ATOMIC_LOG="$WORK_DIR/nft.log" FORKOP_NFT_CANDIDATE_FAIL_PHASE="$phase" \
    ucode -L "$FORKOP_LIB" "$NFT_UC" nft-apply-candidate-batch "$WORK_DIR/candidate.nft"; then
    fail "injected candidate $phase failure was accepted"
  fi
  if [ "$phase" = check ]; then
    [ ! -s "$WORK_DIR/nft.log" ] || fail "injected candidate check failure touched nft"
  else
    [ "$(wc -l <"$WORK_DIR/nft.log")" -eq 1 ] &&
      grep -Fxq -- "-c -f $WORK_DIR/candidate.nft" "$WORK_DIR/nft.log" ||
      fail "injected candidate apply failure did not stop before live apply"
  fi
done

# The cross-component guard is a separate, real nft transaction. It must not
# be appended to the final candidate: while sing-box changes generation, this
# hook drops marked protected packets before the TPROXY hook can deliver them
# to a process with a different route config.
: >"$WORK_DIR/nft.log"
: >"$WORK_DIR/guard.nft"
PATH="$WORK_DIR/bin:$PATH" NFT_ATOMIC_LOG="$WORK_DIR/nft.log" NFT_ATOMIC_CAPTURE="$WORK_DIR/guard.nft" \
  ucode -L "$FORKOP_LIB" "$NFT_UC" install-transition-guard ForkopTable 0x04000000
[ "$(wc -l <"$WORK_DIR/nft.log")" -eq 3 ] || fail "transition guard was not checked, presence-checked, and atomically applied"
grep -Fq 'add chain inet ForkopTable forkop_transition_guard { type filter hook prerouting priority -101; policy accept; }' "$WORK_DIR/guard.nft" ||
  fail "transition guard hook was not built"
grep -Fq 'meta mark & 0x04000000 == 0x04000000 counter drop' "$WORK_DIR/guard.nft" ||
  fail "transition guard does not fail closed for protected traffic"

cat >"$WORK_DIR/discord-fixture.json" <<'JSON'
{
  "section": [{
    ".name": "discord",
    ".type": "section",
    "enabled": "1",
    "action": "outbound",
    "community_lists": ["discord"]
  }]
}
JSON
cat >"$WORK_DIR/discord.lst" <<'EOF_DISCORD'
104.16.0.0/12
2606:4700::/32
66.22.196.0/22
162.159.128.0/21
EOF_DISCORD

ucode -L "$FORKOP_LIB" -e '
let ip = require("core.ip");
if (!ip.is_cloudflare_shared_cidr("104.16.0.0/12")) exit(1);
if (!ip.is_cloudflare_shared_cidr("2606:4700::/32")) exit(2);
if (ip.is_cloudflare_shared_cidr("162.159.128.0/21")) exit(3);
' || fail "Cloudflare shared-range classification is incorrect"

FORKOP_NFT_BATCH_FILE="$WORK_DIR/discord.nft" \
  ucode -L "$FORKOP_LIB" "$NFT_UC" nft-add-community-subnet-file-for-section-fixture \
    "$WORK_DIR/discord-fixture.json" discord discord "$WORK_DIR/discord.lst" \
    ForkopTable forkop_subnets forkop_ip_ports source_interfaces \
    forkop_discord_subnets 0x04000000 5000 forkop_subnets6 forkop_ip6_ports forkop_discord_subnets6
grep -Fq 'discord_subnets { 66.22.196.0/22,162.159.128.0/21 }' "$WORK_DIR/discord.nft" ||
  fail "Discord-owned IPv4 ranges were not kept as ordinary subnets"
grep -Fq 'discord_udp_ip_ports { 104.16.0.0/12 . 443' "$WORK_DIR/discord.nft" ||
  fail "shared Cloudflare IPv4 range was not scoped to Discord voice ports"
grep -Fq 'discord_udp_ip6_ports { 2606:4700::/32 . 443' "$WORK_DIR/discord.nft" ||
  fail "shared Cloudflare IPv6 range was not scoped to Discord voice ports"
if grep -Fq 'discord_subnets { 104.16.0.0/12' "$WORK_DIR/discord.nft"; then
  fail "104.16.0.0/12 leaked into the ordinary Discord subnet set"
fi
grep -Fq '19294-19344' "$WORK_DIR/discord.nft" || fail "Discord Cloudflare voice port range is missing"

FORKOP_NFT_BATCH_FILE="$WORK_DIR/discord-rules.nft" \
  ucode -L "$FORKOP_LIB" "$NFT_UC" nft-add-section-priority-rules-fixture \
    "$WORK_DIR/discord-fixture.json" ForkopTable source_interfaces localv4 localv6 0x04000000 198.18.0.0/15 fc00::/18
grep -Fq 'ip daddr . udp dport @forkop_rule_discord_udp_ip_ports' "$WORK_DIR/discord-rules.nft" ||
  fail "Discord shared ranges have no UDP voice interception rule"
if grep -Fq 'tcp dport @forkop_rule_discord_udp_ip_ports' "$WORK_DIR/discord-rules.nft"; then
  fail "Discord shared ranges unexpectedly intercept TCP"
fi

FORKOP_NFT_BATCH_FILE="$WORK_DIR/outbound-mark.nft" \
  ucode -L "$FORKOP_LIB" "$NFT_UC" nft-create-runtime-base \
    ForkopMarkTest localv4 common ports ip_ports interfaces br-lan \
    0x04000000 0x08000000 198.18.0.0/15 18602 0 \
    localv6 common6 ip_ports6 fc00::/18 ::1
grep -Fq 'meta mark & 0x08000000 == 0x08000000 counter return' "$WORK_DIR/outbound-mark.nft" ||
  fail "own-traffic bypass lost its mask"
if grep -Fq 'meta mark 0x08000000 counter return' "$WORK_DIR/outbound-mark.nft"; then
  fail "own-traffic bypass still requires exact equality"
fi

printf 'outbound mark generation checks passed\n'
FORKOP_NFT_BATCH_FILE="$WORK_DIR/outbound-mark.nft" \
  ucode -L "$FORKOP_LIB" "$NFT_UC" nft-create-runtime-output-rules \
    ForkopMarkTest localv4 common ports ip_ports 0x04000000 198.18.0.0/15 \
    localv6 common6 ip_ports6 fc00::/18
if grep -Eq '@(common6?|ports|ip_ports6?)( |$)' "$WORK_DIR/outbound-mark.nft"; then
  fail "obsolete common-set classifiers are still emitted"
fi
# A LAN client's packet carries the FakeIP mark, the router's own the router mark.
for entry in "mangle 0x04000000" "mangle_output 0x10000000"; do
  set -- $entry
  chain=$1
  mark=$2
  grep -Fq "$chain ip daddr 198.18.0.0/15 meta l4proto tcp meta mark set $mark" "$WORK_DIR/outbound-mark.nft" ||
    fail "$chain lost FakeIP TCP capture"
  grep -Fq "$chain ip daddr 198.18.0.0/15 meta l4proto udp meta mark set $mark" "$WORK_DIR/outbound-mark.nft" ||
    fail "$chain lost FakeIP UDP capture"
done
cat >"$WORK_DIR/protocols.json" <<'JSON'
{"section":[
  {".name":"capture","enabled":"1","action":"connection","ip_cidr":["11.0.0.1/32"]},
  {".name":"bypass","enabled":"1","action":"bypass","ip_cidr":["11.0.0.2/32"]}
]}
JSON
FORKOP_NFT_BATCH_FILE="$WORK_DIR/protocols.nft" \
  ucode -L "$FORKOP_LIB" "$NFT_UC" nft-add-section-priority-rules-fixture \
    "$WORK_DIR/protocols.json" ForkopMarkTest interfaces localv4 localv6 0x04000000
grep -Fq '@forkop_rule_capture_subnets meta l4proto { tcp, udp } meta mark set 0x04000000 counter accept' "$WORK_DIR/protocols.nft" ||
  fail "subnet capture still marks protocols unsupported by TPROXY"
grep -Fq '@forkop_rule_bypass_subnets counter accept' "$WORK_DIR/protocols.nft" ||
  fail "subnet bypass was restricted to TCP/UDP"
printf 'minimal classifier and capture protocol checks passed\n'
printf 'transition guard checks passed\n'
printf 'atomic nft candidate checks passed\n'
