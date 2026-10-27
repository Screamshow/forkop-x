#!/bin/sh
# Owned native Tailscale forwarding. No global routes, UCI or system tailscaled changes.
set -eu
umask 077
mkdir -p /var/lock /var/run/forkop/ui-state
exec 9>/var/lock/forkop-tailscale-network.lock
# OpenWrt BusyBox provides flock; a firmware built without it must say so.
command -v flock >/dev/null 2>&1 || { echo "flock is required (BusyBox flock applet)" >&2; exit 1; }
flock -x 9
state=/etc/forkop-tailscale
owned=/var/run/forkop/ui-state/tailscale-lan-owned
# One ucode run for all constants; shell-env quotes every value.
constants=$(ucode /usr/lib/forkop/core/constants.uc shell-env)
eval "$constants"
table=$NFT_TABLE_NAME
interfaces=$NFT_INTERFACE_SET_NAME
mark=$NFT_FAKEIP_MARK
tproxy=$SB_TPROXY_INBOUND_PORT
case "$table:$interfaces" in *[!a-zA-Z0-9_:]*) exit 1;; esac
case "$mark" in 0x*[!0-9a-fA-F]*) exit 1;; esac
case "$tproxy" in ''|*[!0-9]*) exit 1;; esac
cleanup() {
    for chain in forward input; do
        nft -a list chain inet fw4 "$chain" 2>/dev/null | sed -n '/comment "forkop-native-tailscale"/s/.*# handle \([0-9][0-9]*\).*/\1/p' | while read -r handle; do
            nft delete rule inet fw4 "$chain" handle "$handle" 2>/dev/null || true
        done
    done
    nft flush chain inet fw4 forkop_native_ts_input 2>/dev/null || true
    nft delete chain inet fw4 forkop_native_ts_input 2>/dev/null || true
    if [ -f "$owned" ]; then
        nft delete table inet forkop_native_tailscale 2>/dev/null || true
        for family in -4 -6; do
            ip "$family" rule del priority 104 fwmark 0x880000/0xff0000 table 52743 2>/dev/null || true
            ip "$family" route flush table 52743 2>/dev/null || true
        done
        configured=$(uci -q get forkop.settings.source_network_interfaces || true)
        case " $configured " in *' forkop-tslan '*) ;; *)
            nft delete element inet "$table" "$interfaces" '{ "forkop-tslan" }' 2>/dev/null || true;;
        esac
        rm -f "$owned"
    fi
}
[ "${1:-}" = cleanup ] && { cleanup; exit 0; }
[ ! -f /var/run/forkop/ui-state/tailscale-stopping ] || exit 1
[ -e /sys/class/net/forkop-tslan ] || exit 1
[ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ] || exit 1
devices=''
if [ -f "$state/lan.json" ]; then
    device=$(jsonfilter -i "$state/lan.json" -e '@.device')
    case "$device" in ''|*[!a-zA-Z0-9_.-]*) exit 1;; esac
    devices="$device"
fi
exit_mode=0
if [ -f "$state/exit-enabled" ]; then
    exit_mode=1
    wan=$( { ip -4 route show default; ip -6 route show default; } | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' | sort -u)
    [ -n "$wan" ] || exit 1
    devices="$devices $wan"
fi
[ -n "$devices" ] || exit 1
# Refuse another owner's table, priority or overlapping policy selector.
for family in -4 -6; do
    rules=$(ip "$family" rule show)
    if printf '%s\n' "$rules" | grep -q '^104:'; then
        [ -f "$owned" ] || exit 1
        [ "$(printf '%s\n' "$rules" | grep -c '^104:')" = 1 ] || exit 1
        printf '%s\n' "$rules" | grep '^104:' | grep -q 'fwmark 0x880000/0xff0000 lookup 52743$' || exit 1
    fi
    while read -r priority selector; do
        [ -n "$selector" ] || continue
        [ "$priority" != 104: ] || continue
        value=${selector%/*}; mask=${selector#*/}
        [ "$mask" != "$selector" ] || mask=0xffffffff
        case "$value:$mask" in *[!0-9a-fA-Fx:]*) exit 1;; esac
        [ $((mask & 0xff0000)) = 0 ] || [ $(((value ^ 0x880000) & mask & 0xff0000)) != 0 ] || exit 1
    done <<EOF
$(printf '%s\n' "$rules" | awk '{for(i=1;i<NF;i++) if($i=="fwmark") print $1, $(i+1)}')
EOF
    routes=$(ip "$family" route show table 52743 2>/dev/null || true)
    if [ -n "$routes" ]; then
        [ -f "$owned" ] || exit 1
        expected=100.64.0.0/10
        [ "$family" = -4 ] || expected=fd7a:115c:a1e0::/48
        [ "$(printf '%s\n' "$routes" | wc -l)" = 1 ] || exit 1
        case "$routes" in "$expected dev forkop-tslan "*|"$expected dev forkop-tslan") ;; *) exit 1;; esac
    fi
done
if nft list table inet forkop_native_tailscale >/dev/null 2>&1; then
    [ -f "$owned" ] || exit 1
fi
elements=''
for device in $devices; do
    case "$device" in ''|forkop-tslan|lo|*[!a-zA-Z0-9_.-]*) exit 1;; esac
    elements="${elements}${elements:+, }\"$device\""
done
signature="$exit_mode $elements $mark $tproxy"
if [ "$exit_mode" = 1 ]; then
    nft list set inet "$table" "$interfaces" >/dev/null 2>&1 || exit 1
fi
[ "${1:-}" != check ] || exit 0
# Tailscale assigns IPv6 tailnet addresses even with an IPv4-only WAN.
# A router-wide default can disable IPv6 on this newly created owned TUN.
# Enable only this interface so its required tailnet route can be installed.
ipv6_disabled=/proc/sys/net/ipv6/conf/forkop-tslan/disable_ipv6
if [ -f "$ipv6_disabled" ] && [ "$(cat "$ipv6_disabled")" != 0 ]; then
    printf '0\n' > "$ipv6_disabled"
fi
refresh=0
if [ -f "$owned" ] && [ "$(cat "$owned")" != "$signature" ]; then refresh=1; fi
if ! nft list table inet forkop_native_tailscale >/dev/null 2>&1; then
    ip link set forkop-tslan mtu 1280 up
    if [ ! -f "$owned" ]; then
        printf '%s\n' "$signature" > "$owned"
        trap 'cleanup' EXIT
    fi
    [ -n "$(ip -4 route show table 52743 2>/dev/null)" ] || ip -4 route add table 52743 100.64.0.0/10 dev forkop-tslan
    [ -n "$(ip -6 route show table 52743 2>/dev/null)" ] || ip -6 route add table 52743 fd7a:115c:a1e0::/48 dev forkop-tslan
    for family in -4 -6; do
        ip "$family" rule show | grep -q '^104:' || ip "$family" rule add priority 104 fwmark 0x880000/0xff0000 table 52743
    done
    nft -f - <<EOF
table inet forkop_native_tailscale {
    set egress { type ifname; elements = { $elements }; }
    chain mark_reply { type filter hook prerouting priority -151; policy accept;
        iifname "forkop-tslan" ct mark set (ct mark & 0xff00ffff) | 0x880000
        ct direction reply ct mark & 0xff0000 == 0x880000 meta mark set (meta mark & 0xfb00ffff) | 0x880000
    }
    chain route_reply { type route hook output priority -149; policy accept;
        ct direction reply ct mark & 0xff0000 == 0x880000 meta mark set (meta mark & 0xfb00ffff) | 0x880000
    }
    chain nat { type nat hook postrouting priority srcnat; policy accept;
        iifname "forkop-tslan" oifname @egress masquerade
    }
    chain guard { type filter hook forward priority -2; policy accept;
        iifname "forkop-tslan" oifname != @egress drop
    }
}
EOF
    trap - EXIT
fi
[ -f "$owned" ] || exit 1
# Routes can be lost on interface/network reconfiguration while nftables survives.
[ -n "$(ip -4 route show table 52743 2>/dev/null)" ] || ip -4 route add table 52743 100.64.0.0/10 dev forkop-tslan
[ -n "$(ip -6 route show table 52743 2>/dev/null)" ] || ip -6 route add table 52743 fd7a:115c:a1e0::/48 dev forkop-tslan
for family in -4 -6; do
    ip "$family" rule show | grep -q '^104:' || ip "$family" rule add priority 104 fwmark 0x880000/0xff0000 table 52743
done
batch=/tmp/forkop-ts-lan.$$.nft
trap 'rm -f "$batch"' EXIT
: > "$batch"
if [ "$refresh" = 1 ]; then
    printf 'flush set inet forkop_native_tailscale egress\nadd element inet forkop_native_tailscale egress { %s }\n' "$elements" >> "$batch"
fi
if [ "$exit_mode" = 1 ] && ! nft get element inet "$table" "$interfaces" '{ "forkop-tslan" }' >/dev/null 2>&1; then
    printf 'add element inet %s %s { "forkop-tslan" }\n' "$table" "$interfaces" >> "$batch"
fi
if [ "$exit_mode" = 0 ] && nft get element inet "$table" "$interfaces" '{ "forkop-tslan" }' >/dev/null 2>&1; then
    configured=$(uci -q get forkop.settings.source_network_interfaces || true)
    case " $configured " in *' forkop-tslan '*) ;; *) printf 'delete element inet %s %s { "forkop-tslan" }\n' "$table" "$interfaces" >> "$batch";; esac
fi
if ! nft list chain inet fw4 forward | grep -q 'comment "forkop-native-tailscale"'; then
    printf 'insert rule inet fw4 forward iifname "forkop-tslan" accept comment "forkop-native-tailscale"\n' >> "$batch"
fi
input_hook=0
nft list chain inet fw4 input | grep -q 'comment "forkop-native-tailscale"' && input_hook=1
if [ "$input_hook" = 0 ] || [ "$refresh" = 1 ]; then
    nft list chain inet fw4 forkop_native_ts_input >/dev/null 2>&1 || printf 'add chain inet fw4 forkop_native_ts_input\n' >> "$batch"
    printf 'flush chain inet fw4 forkop_native_ts_input\n' >> "$batch"
    printf 'add rule inet fw4 forkop_native_ts_input meta mark & %s == %s meta l4proto { tcp, udp } accept\n' "$mark" "$mark" >> "$batch"
    printf 'add rule inet fw4 forkop_native_ts_input drop\n' >> "$batch"
    [ "$input_hook" = 1 ] || printf 'insert rule inet fw4 input iifname "forkop-tslan" jump forkop_native_ts_input comment "forkop-native-tailscale"\n' >> "$batch"
fi
[ ! -f /var/run/forkop/ui-state/tailscale-stopping ] || exit 1
[ ! -s "$batch" ] || nft -f "$batch"
printf '%s\n' "$signature" > "$owned.new"
mv "$owned.new" "$owned"
