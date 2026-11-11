#!/bin/sh
set -eu
# Run on an existing OpenWrt VMware test VM, with this checkout's library.
G=${1:-/usr/lib/forkop/service/proxy_transport.uc}
ubus call system board | grep -qi VMware
W=$(mktemp -d /tmp/forkop-proxy-ownership.XXXXXX)
N=fpo-own-$$
trap 'ip netns del "$N" 2>/dev/null || true; rm -rf "$W"' EXIT
ip netns add "$N"
ROOT="$W/ownership"
mkdir -p "$ROOT/zapret/common" "$ROOT/zapret/nfq" "$ROOT/zapret-manager-luci/state/transport-ownership"
cat > "$ROOT/zapret/common/nft.sh" <<'EOF'
nft_add_rule() {
	nft add rule inet $ZAPRET_NFT_TABLE $chain $FW_EXTRA_PRE "$@"
}
nft_insert_rule() {
	nft insert rule inet $ZAPRET_NFT_TABLE $chain $FW_EXTRA_PRE "$@"
}
EOF
printf binary > "$ROOT/zapret/nfq/nfqws"
cat > "$ROOT/zapret-manager-luci/backend.sh" <<'EOF'
ZM_FLAVOR="forkop-five-section-v1"
ZM_SCRIPT_URL="https://raw.githubusercontent.com/Screamshow/Zapret-Manager/refs/heads/main/ZapretManager_LuCI.sh"
EOF
ip netns exec "$N" nft -f - <<'EOF'
table inet zapret {
 chain postrouting { tcp dport 443 queue num 200 bypass; }
}
EOF
sha256sum "$ROOT/zapret/common/nft.sh" > "$W/foreign.before"
ip netns exec "$N" nft -s list table inet zapret > "$W/foreign.rules.before"
ip netns exec "$N" env FORKOP_ZAPRET_ROOT="$ROOT" ucode "$G" prepare
sha256sum -c "$W/foreign.before"
ip netns exec "$N" nft -s list table inet zapret > "$W/foreign.rules.after"
cmp "$W/foreign.rules.before" "$W/foreign.rules.after"
echo FOREIGN_FILES_AND_RULES_UNCHANGED
b=$(sha256sum "$ROOT/zapret/nfq/nfqws" | cut -d' ' -f1)
h=$(sha256sum "$ROOT/zapret/common/nft.sh" | cut -d' ' -f1)
printf '{"schema":1,"owner":"forkop-zms-v1","component":"zapret","binary_sha256":"%s","helper_sha256":"%s"}\n' "$b" "$h" > "$ROOT/zapret-manager-luci/state/transport-ownership/zapret.json"
ip netns exec "$N" env FORKOP_ZAPRET_ROOT="$ROOT" ucode "$G" prepare
grep -q FORKOP_NFQ_GUARD "$ROOT/zapret/common/nft.sh"
ip netns exec "$N" nft list table inet zapret | grep -q 'ct mark & 0x02000000'
ip netns exec "$N" env FORKOP_ZAPRET_ROOT="$ROOT" ucode "$G" prepare
echo OWNED_GUARD_IDEMPOTENT
echo foreign-update >> "$ROOT/zapret/nfq/nfqws"
sha256sum "$ROOT/zapret/common/nft.sh" > "$W/changed.before"
ip netns exec "$N" env FORKOP_ZAPRET_ROOT="$ROOT" ucode "$G" prepare
sha256sum -c "$W/changed.before"
echo OWNERSHIP_HASH_MISMATCH_NOT_ADOPTED
ip netns exec "$N" env FORKOP_ZAPRET_ROOT="$W/absent" ucode "$G" prepare
test ! -e "$W/absent"
echo ABSENT_ZAPRET_NOT_INSTALLED
