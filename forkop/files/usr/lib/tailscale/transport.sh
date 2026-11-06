#!/bin/sh
# Allow only the native encrypted UDP transport on current WAN devices.
set -eu
umask 077
mkdir -p /var/lock /var/run/forkop/ui-state
exec 9>/var/lock/forkop-tailscale-network.lock
# OpenWrt BusyBox provides flock; a firmware built without it must say so.
command -v flock >/dev/null 2>&1 || { echo "flock is required (BusyBox flock applet)" >&2; exit 1; }
flock -x 9
owned=/var/run/forkop/ui-state/tailscale-udp-owned
cleanup() {
    nft -a list chain inet fw4 input 2>/dev/null | sed -n '/comment "forkop-native-tailscale-udp"/s/.*# handle \([0-9][0-9]*\).*/\1/p' | while read -r handle; do
        nft delete rule inet fw4 input handle "$handle" 2>/dev/null || true
    done
    rm -f "$owned"
}
[ "${1:-}" = cleanup ] && { cleanup; exit 0; }
[ ! -f /var/run/forkop/ui-state/tailscale-stopping ] || exit 1
[ -f /etc/forkop-tailscale/enabled ] || { cleanup; exit 0; }
[ "$(cat /etc/forkop/sing-box-variant 2>/dev/null)" = rust-x ] || exit 1
default_routes() {
    /usr/libexec/ip-full "$1" route show default 2>/dev/null || ip "$1" route show default
}
devices=$( { default_routes -4; default_routes -6; } | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' | sort -u)
[ -n "$devices" ] || { cleanup; exit 1; }
elements=''
for device in $devices; do
    case "$device" in ''|lo|forkop-tslan|*[!a-zA-Z0-9_.-]*) exit 1;; esac
    elements="${elements}${elements:+, }\"$device\""
done
if [ -f "$owned" ] && [ "$(cat "$owned")" = "$elements" ] && nft list chain inet fw4 input | grep -q 'comment "forkop-native-tailscale-udp"'; then exit 0; fi
batch=/tmp/forkop-ts-udp.$$.nft
trap 'rm -f "$batch"' EXIT
{
    nft -a list chain inet fw4 input 2>/dev/null | sed -n '/comment "forkop-native-tailscale-udp"/s/.*# handle \([0-9][0-9]*\).*/delete rule inet fw4 input handle \1/p'
    printf 'insert rule inet fw4 input iifname { %s } udp dport 41642 accept comment "forkop-native-tailscale-udp"\n' "$elements"
} > "$batch"
[ ! -f /var/run/forkop/ui-state/tailscale-stopping ] || exit 1
nft -f "$batch"
printf '%s\n' "$elements" > "$owned.new"
mv "$owned.new" "$owned"
