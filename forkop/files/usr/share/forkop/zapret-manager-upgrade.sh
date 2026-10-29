#!/bin/sh
# Package upgrades can run inside a component transaction. Wait outside
# postinst so the parent can release the component lock first.
set -eu
lib=${FORKOP_LIB:-/usr/lib/forkop}
case ${1:-} in
    queue)
        [ -e /opt/zapret-manager-luci/backend.sh ] ||
        [ -e /usr/libexec/rpcd/zapret-manager ] ||
        [ -e /usr/bin/zms ] || [ -e /usr/bin/zmsA ] || [ -e /usr/bin/zmw ] || exit 0
        sh "$0" run </dev/null >/dev/null 2>&1 &
        exit 0 ;;
    run) ;;
    *) exit 1 ;;
esac
n=0
while [ "$n" -lt 120 ]; do
    result=$(ucode -L "$lib" "$lib/components/action.uc" component-action zapret_manager migrate 2>&1) && exit 0
    case "$result" in
        *'Another component action is already running'*) sleep 2; n=$((n + 1)) ;;
        *) logger -t forkop "Zapret Manager migration failed: $result"; exit 1 ;;
    esac
done
logger -t forkop 'Zapret Manager migration deferred: component lock remained busy'
exit 1
