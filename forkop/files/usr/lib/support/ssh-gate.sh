#!/bin/sh
# A leftover key after a crash/reboot cannot authorize a new support shell.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
state=/var/run/forkop/support/status.json
[ ! -f /var/run/forkop/support/cancelled ] || exit 1
[ -f "$state" ] || exit 1
[ "$(jsonfilter -i "$state" -e '@.phase')" = connected ] || exit 1
deadline=$(jsonfilter -i "$state" -e '@.deadline')
case "$deadline" in ''|*[!0-9]*) exit 1;; esac
[ "$(cut -d. -f1 /proc/uptime)" -lt "$deadline" ] || exit 1
[ -S /var/run/forkop/support/socket ] || exit 1
if [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
    exec /bin/sh -c "$SSH_ORIGINAL_COMMAND"
fi
exec /bin/sh -l
