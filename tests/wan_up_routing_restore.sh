#!/usr/bin/env bash
# netifd flushes every ip rule when it starts and the devices it takes down
# lose their routes, so after /etc/init.d/network restart the routing of a
# running Forkop is gone while the core and the nft table keep running. The
# WAN-up hook used to retry only a failed start, so nothing put it back.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="${FORKOP_LIB:-$ROOT_DIR/forkop/files/usr/lib}"
INITD_UC="$FORKOP_LIB/service/initd.uc"
LIFECYCLE_UC="$FORKOP_LIB/service/lifecycle.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  [ -z "${SING_BOX_PID:-}" ] || kill "$SING_BOX_PID" 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

initd_ucode() { ucode -L "$FORKOP_LIB" "$INITD_UC" "$@"; }

# The decision stays a pure function of what the hook observes.
[ "$(initd_ucode wan-up-restore-routing-action 1 1)" = skip_running ] ||
  fail 'a running Forkop has nothing to restore'
[ "$(initd_ucode wan-up-restore-routing-action 0 0)" = skip_disabled ] ||
  fail 'a disabled service must be left alone'
[ "$(initd_ucode wan-up-restore-routing-action 0 1)" = restore_routing ] ||
  fail 'a stopped-looking runtime of an enabled service is never checked for lost routing'

[ "$(initd_ucode wan-up-action 0 1 1 1 1)" = reload ] ||
  fail 'restored routing on a monitored WAN does not reapply the configuration'
[ "$(initd_ucode wan-up-action 0 1 1 0 1)" = skip_running ] ||
  fail 'restored routing still restarts the core on an unmonitored WAN'
[ "$(initd_ucode wan-up-action 0 1 1 1 0)" = start ] ||
  fail 'a failed start is no longer retried when no routing was restored'
[ "$(initd_ucode wan-up-action 0 1 0 1 0)" = skip_no_retry ] ||
  fail 'a WAN-up without a pending retry does something'
[ "$(initd_ucode wan-up-action 1 1 0 1)" = reload ] ||
  fail 'a monitored WAN under a running Forkop no longer reloads'

# The hook asks lifecycle, and only while the runtime does not look running.
handle_body="$(sed -n '/^function handle_wan_up(/,/^}/p' "$INITD_UC")"
grep -Fq 'wan_up_restore_routing_action(running, enabled) == "restore_routing" &&' <<<"$handle_body" ||
  fail 'the WAN-up hook does not gate the routing restore on its own decision'
grep -Fq 'restore_lost_routing()' <<<"$handle_body" ||
  fail 'the WAN-up hook never restores lost routing'
restore_body="$(sed -n '/^function restore_lost_routing(/,/^}/p' "$INITD_UC")"
grep -Fq 'module_status(LIFECYCLE_UC, [ "restore-routing" ])' <<<"$restore_body" ||
  fail 'the routing restore does not go through lifecycle'
lifecycle_body="$(sed -n '/^function restore_routing(/,/^}/p' "$LIFECYCLE_UC")"
grep -Fq 'acquire-runtime-dir-lock", RELOAD_LOCK_DIR' <<<"$lifecycle_body" ||
  fail 'the routing restore does not take the lifecycle lock'
grep -Fq 'release-runtime-dir-lock", RELOAD_LOCK_DIR' <<<"$lifecycle_body" ||
  fail 'the routing restore keeps the lifecycle lock'
for forbidden in start_impl stop_main restart reload_tracked start-managed-sing-box-runtime; do
  grep -Fq "$forbidden" <<<"$lifecycle_body" && fail "the routing restore touches the core through $forbidden"
done

# A core the hook must find running: state.uc reads the exe name behind the pid.
cp /bin/sleep "$WORK_DIR/sing-box"
"$WORK_DIR/sing-box" 300 &
SING_BOX_PID=$!

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/state"
export PATH="$WORK_DIR/bin:$PATH"
export NFT_LOG="$WORK_DIR/nft.log" IP_LOG="$WORK_DIR/ip.log" LOGGER_LOG="$WORK_DIR/logger.log"
export SING_BOX_PID
cat >"$WORK_DIR/bin/nft" <<'EOF_NFT'
#!/bin/sh
printf '%s\n' "$*" >>"$NFT_LOG"
case "$*" in
  'list table inet '*) [ "${NFT_TABLE_UP:-1}" = 1 ] || exit 1 ;;
  'list chain '*forkop_transition_guard) [ "${NFT_GUARD_UP:-0}" = 1 ] || exit 1 ;;
esac
exit 0
EOF_NFT
# The stub keeps state: what it is told to add is listed afterwards.
cat >"$WORK_DIR/bin/ip" <<'EOF_IP'
#!/bin/sh
printf '%s\n' "$*" >>"$IP_LOG"
case "$*" in
  *'route add'*) : >"$IP_STATE_DIR/route"; exit 0 ;;
  *'rule add'*)
    priority=${*##* priority }
    mark=${*#*fwmark }
    mark=${mark%% *}
    case "$*" in
      *'lookup main'*) printf '%s:\tfrom all fwmark %s iif lo lookup main\n' "$priority" "$mark" >>"$IP_STATE_DIR/rules" ;;
      *) printf '%s:\tfrom all fwmark %s lookup forkop\n' "$priority" "$mark" >>"$IP_STATE_DIR/rules" ;;
    esac
    exit 0 ;;
  *'route list'*)
    if [ "${ROUTING_UP:-0}" = 1 ] || [ -e "$IP_STATE_DIR/route" ]; then
      echo 'local default dev lo scope host'
    fi
    exit 0 ;;
  *'rule list'*)
    [ "${ROUTING_UP:-0}" = 1 ] && cat "$RULES_FILE"
    [ -e "$IP_STATE_DIR/rules" ] && cat "$IP_STATE_DIR/rules"
    exit 0 ;;
esac
exit 0
EOF_IP
cat >"$WORK_DIR/bin/ubus" <<'EOF_UBUS'
#!/bin/sh
[ "${CORE_UP:-1}" = 1 ] || { echo '{}'; exit 0; }
printf '{"sing-box":{"instances":{"instance1":{"running":true,"pid":%s}}}}\n' "$SING_BOX_PID"
EOF_UBUS
cat >"$WORK_DIR/bin/logger" <<'EOF_LOGGER'
#!/bin/sh
printf '%s\n' "$*" >>"$LOGGER_LOG"
exit 0
EOF_LOGGER
chmod +x "$WORK_DIR/bin/nft" "$WORK_DIR/bin/ip" "$WORK_DIR/bin/ubus" "$WORK_DIR/bin/logger"

export RULES_FILE="$WORK_DIR/rules" IP_STATE_DIR="$WORK_DIR/ip-state"
cat >"$RULES_FILE" <<'EOF_RULES'
103:	from all fwmark 0x4000000/0x4000000 iif lo lookup main
105:	from all fwmark 0x4000000/0x4000000 lookup forkop
105:	from all fwmark 0x10000000/0x10000000 lookup forkop
EOF_RULES

export FORKOP_LIB
export FORKOP_RELOAD_LOCK_DIR="$WORK_DIR/reload.lock"
export FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/state"
export FORKOP_IPV6_SYSCTL_DIR="$WORK_DIR/sysctl"
export FORKOP_RT_TABLES_FILE="$WORK_DIR/rt_tables"
mkdir -p "$WORK_DIR/sysctl/all" "$WORK_DIR/sysctl/lo"
printf '1\n' >"$WORK_DIR/sysctl/all/disable_ipv6"
printf '1\n' >"$WORK_DIR/sysctl/lo/disable_ipv6"

# table present, core running, routing present, transition guard, lock held
world() {
  export NFT_TABLE_UP="$1" CORE_UP="$2" ROUTING_UP="$3" NFT_GUARD_UP="${4:-0}"
  : >"$NFT_LOG"; : >"$IP_LOG"; : >"$LOGGER_LOG"
  rm -rf "$IP_STATE_DIR" "$FORKOP_RELOAD_LOCK_DIR"
  mkdir -p "$IP_STATE_DIR"
  if [ "${5:-0}" = 1 ]; then
    mkdir -p "$FORKOP_RELOAD_LOCK_DIR"
    printf '%s\n' "$SING_BOX_PID" >"$FORKOP_RELOAD_LOCK_DIR/pid"
  fi
}

restore() {
  set +e
  ucode -L "$FORKOP_LIB" "$LIFECYCLE_UC" restore-routing >"$WORK_DIR/restore.out" 2>&1
  status=$?
  set -e
  printf '%s' "$status"
}

# A network restart: the table and the core are there, the routing is not.
world 1 1 0
status="$(restore)"
[ "$status" = 0 ] || fail "the routing a network restart took was not put back (status $status)"
grep -q 'rule add fwmark 0x04000000/0x04000000 table forkop priority 105' "$IP_LOG" ||
  fail 'the TPROXY rule was not added again'
grep -q 'route add local 0.0.0.0/0 dev lo table forkop' "$IP_LOG" ||
  fail 'the local route of the Forkop table was not added again'
grep -Fq "[info] The WAN came up without Forkop's routing; restored it" "$LOGGER_LOG" ||
  fail 'restoring the routing was not logged'
grep -q 'delete table' "$NFT_LOG" && fail 'the nft table was rebuilt instead of the routing'
grep -q 'add rule' "$NFT_LOG" && fail 'the nft table was rebuilt instead of the routing'
[ ! -e "$FORKOP_RELOAD_LOCK_DIR" ] || fail 'the lifecycle lock was kept'

# Nothing is touched when there is nothing to restore.
world 1 1 1
status="$(restore)"
[ "$status" = 2 ] || fail "a routing that is in place was restored anyway (status $status)"
grep -q 'rule add' "$IP_LOG" && fail 'a routing that is in place was added to'
[ ! -s "$LOGGER_LOG" ] || fail 'a routing that is in place was logged about'

world 0 1 0
status="$(restore)"
[ "$status" = 2 ] || fail "routing was restored under a stopped Forkop (status $status)"
grep -q 'rule add' "$IP_LOG" && fail 'a stopped Forkop had its routing restored'

world 1 0 0
status="$(restore)"
[ "$status" = 2 ] || fail "routing was restored without a core to route to (status $status)"
grep -q 'rule add' "$IP_LOG" && fail 'routing was added without a running core'

world 1 1 0 1
status="$(restore)"
[ "$status" = 2 ] || fail "routing was restored during a fail-closed transition (status $status)"
grep -q 'rule add' "$IP_LOG" && fail 'the fail-closed transition guard was fought'

world 1 1 0 0 1
status="$(restore)"
[ "$status" = 1 ] || fail "routing was restored while a lifecycle action holds the lock (status $status)"
grep -q 'rule add' "$IP_LOG" && fail 'the lifecycle lock was ignored'
[ -e "$FORKOP_RELOAD_LOCK_DIR/pid" ] || fail "another owner's lock was released"
rm -rf "$FORKOP_RELOAD_LOCK_DIR"

printf 'WAN-up routing restore checks passed\n'
