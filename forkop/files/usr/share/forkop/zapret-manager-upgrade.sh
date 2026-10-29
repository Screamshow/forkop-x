#!/bin/sh
# Package upgrades can run inside a component transaction. Wait outside
# postinst so the parent can release the component lock first.
set -eu
# A postinst child must not retain its parent's disposable bytecode directory.
lib=${FORKOP_SOURCE_LIB:-/usr/lib/forkop}
export FORKOP_LIB="$lib"
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
    rc=0
    result=$(FORKOP_COMPONENT_BACKGROUND=1 ucode -L "$lib" "$lib/components/action.uc" component-action zapret_manager migrate 2>&1) || rc=$?
    [ "$rc" != 0 ] || exit 0
    if [ "$rc" = 75 ]; then sleep 2; n=$((n + 1)); continue; fi
    case "$result" in
        *'Another component action is already running'*) sleep 2; n=$((n + 1)) ;;
        *) logger -t forkop "Zapret Manager migration failed: $result"; exit 1 ;;
    esac
done
logger -t forkop 'Zapret Manager migration deferred: component lock remained busy'
exit 1
