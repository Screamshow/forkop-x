#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$WORK/bin" "$WORK/generation" "$WORK/rulesets" "$WORK/state"
cat >"$WORK/bin/curl" <<'EOF'
#!/bin/sh
echo "$*" >>"$TEST_NETWORK_LOG"
if [ "${TEST_ACCEPT_NEW:-0}" = 1 ]; then
  output=''
  resolved=''
  previous=''
  for arg in "$@"; do
    [ "$previous" != '-o' ] || output="$arg"
    [ "$previous" != '--resolve' ] || resolved="$arg"
    previous="$arg"
  done
  case "$*" in
    *https://lists.test/c.txt*) printf 'c.example\n' >"$output"; exit 0 ;;
    *https://lists.test/d.txt*)
      [ "$resolved" = 'lists.test:443:192.0.2.10' ] || exit 6
      printf 'd.example\n' >"$output"; exit 0 ;;
  esac
fi
exit 1
EOF
cat >"$WORK/bin/dig" <<'EOF'
#!/bin/sh
case "$*" in
  *'@192.0.2.54 -p 8443 -q lists.test -t A '*' +https=/custom-dns +tls-ca=/etc/ssl/certs/ca-certificates.crt +tls-hostname=192.0.2.54')
    printf '192.0.2.10\n'; exit 0 ;;
  *@*|*+https*) exit 1 ;;
esac
echo 192.0.2.1
EOF
cat >"$WORK/bin/logger" <<'EOF'
#!/bin/sh
echo "$*" >>"$TEST_LOG"
EOF
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH" TEST_NETWORK_LOG="$WORK/network" TEST_LOG="$WORK/log"
export FORKOP_LIB="$LIB" FORKOP_UCI_STATE_FILE="$WORK/uci.state"
export TMP_SING_BOX_FOLDER="$WORK" TMP_RULESET_FOLDER="$WORK/rulesets"
export FORKOP_RUNTIME_LIST_GENERATION_DIR="$WORK/generation" FORKOP_RUNTIME_STATE_DIR="$WORK/state"
export FORKOP_PERSISTENT_LIST_CACHE_DIR="$WORK/persistent" FORKOP_RULESET_CACHE_DIR="$WORK/remote-cache"
export FORKOP_LIST_UPDATE_PID_FILE="$WORK/update.pid" FORKOP_RELOAD_LOCK_DIR="$WORK/reload.lock"
export FORKOP_LIST_UPDATE_PREPARE_ONLY=1 FORKOP_MANUAL_RESTART_LOCK_HELD=1
printf '1234\n' >"$WORK/state/list-update-last-success.timestamp"
: >"$TEST_NETWORK_LOG"
write_section() {
  printf 'forkop.%s=section\nforkop.%s.enabled=1\nforkop.%s.action=block\n' "$1" "$1" "$1"
  [ -z "${2:-}" ] || printf 'forkop.%s.remote_domain_lists=%s\n' "$1" "$2"
}
write_base() {
  printf 'forkop.settings=settings\nforkop.settings.update_interval=1d\n'
  write_section alpha 'https://lists.test/a.txt https://lists.test/b.txt'
}
signature() { ucode -L "$LIB" "$LIB/service/state.uc" "$1"; }
prepare() { ucode -L "$LIB" "$LIB/components/updates.uc" prepare-list-change; }
write_base >"$WORK/uci.state"
initial_cron=$(signature cron-signature)
initial_list=$(signature list-update-signature)
printf 'a.example\n' >"$WORK/generation/source-1"
printf 'b.example\n' >"$WORK/generation/source-2"
cat >"$WORK/generation/manifest.json" <<EOF
{"format":"2","generation":"gen-original","signature":"$initial_list","files":[
{"name":"source-1","kind":"source","url":"https://lists.test/a.txt","source_format":"plain","size":$(wc -c <"$WORK/generation/source-1"),"md5":"$(md5sum "$WORK/generation/source-1" | cut -d' ' -f1)"},
{"name":"source-2","kind":"source","url":"https://lists.test/b.txt","source_format":"plain","size":$(wc -c <"$WORK/generation/source-2"),"md5":"$(md5sum "$WORK/generation/source-2" | cut -d' ' -f1)"}]}
EOF

cp "$WORK/generation/manifest.json" "$WORK/full-manifest"
printf '{"format":"2","generation":"gen-empty-corrupt","signature":"%s","files":[]}\n' "$initial_list" >"$WORK/generation/manifest.json"
if ucode -L "$LIB" "$LIB/components/updates.uc" runtime-list-cache-active; then
  fail 'empty manifest accepted while sources are required'
fi
cp "$WORK/full-manifest" "$WORK/generation/manifest.json"

# An empty section must affect neither source preparation nor shared cron.
write_section empty >>"$WORK/uci.state"
[ "$(signature list-update-signature)" = "$initial_list" ] || fail 'empty section changed source identity'
[ "$(signature cron-signature)" = "$initial_cron" ] || fail 'empty section changed cron'

# Add another consumer of the same data, then remove one list and its section.
write_section beta 'https://lists.test/a.txt' >>"$WORK/uci.state"
prepare || fail 'adding section with cached source failed'
grep -q 'a.example' "$WORK/rulesets/beta-remote-domains-ruleset.json" || fail 'new section not materialized'
[ "$(signature cron-signature)" = "$initial_cron" ] || fail 'shared source changed cron'
sed -i 's@a.txt https://lists.test/b.txt@a.txt@' "$WORK/uci.state"
FORKOP_LIST_CHANGE_ROLLBACK_DIR="$WORK/rollback" prepare || fail 'list deletion failed'
! grep -q 'b.example' "$WORK/rulesets/alpha-remote-domains-ruleset.json" || fail 'removed domain survived'
grep -q 'b.example' "$WORK/rollback/alpha-remote-domains-ruleset.json" || fail 'old list data unavailable for core rollback'
test -s "$WORK/rollback/beta-remote-domains-ruleset.json" || fail 'unchanged list lost from rollback snapshot'
cp "$WORK/rollback/alpha-remote-domains-ruleset.json" "$WORK/rulesets/alpha-remote-domains-ruleset.json"
FORKOP_LIST_CHANGE_ROLLBACK_DIR="$WORK/retry-rollback" ucode -L "$LIB" "$LIB/components/updates.uc" snapshot-list-files
cmp "$WORK/rollback/alpha-remote-domains-ruleset.json" "$WORK/retry-rollback/alpha-remote-domains-ruleset.json" || fail 'retry did not snapshot the restored applied files'
rm -rf "$WORK/retry-rollback"
rm -rf "$WORK/rollback"
sed -i '/forkop.alpha/d' "$WORK/uci.state"
prepare || fail 'section deletion failed'
[ ! -e "$WORK/rulesets/alpha-remote-domains-ruleset.json" ] || fail 'deleted section materialization survived'
grep -q 'a.example' "$WORK/rulesets/beta-remote-domains-ruleset.json" || fail 'remaining section lost data'
[ ! -s "$TEST_NETWORK_LOG" ] || fail 'cached composition edits used network'
[ "$(cat "$WORK/state/list-update-last-success.timestamp")" = 1234 ] || fail 'edit postponed periodic refresh'

# A new URL fetches only its own data, while the existing source stays cached.
write_section gamma 'https://lists.test/c.txt' >>"$WORK/uci.state"
TEST_ACCEPT_NEW=1 prepare || fail 'new source failed'
grep -q 'c.example' "$WORK/rulesets/gamma-remote-domains-ruleset.json" || fail 'new source not materialized'
[ "$(wc -l <"$TEST_NETWORK_LOG")" -eq 1 ] || fail 'new source re-fetched existing sources'
grep -q 'https://lists.test/c.txt' "$TEST_NETWORK_LOG" || fail 'wrong source fetched'
sed -i '/forkop.gamma/d' "$WORK/uci.state"
prepare || fail 'new section removal failed'

# A direct source whose system DNS fails retries through the selected DoH endpoint.
printf 'forkop.settings.dns_type=doh\nforkop.settings.bootstrap_dns_server=192.0.2.54:8443/custom-dns\n' >>"$WORK/uci.state"
write_section delta 'https://lists.test/d.txt' >>"$WORK/uci.state"
TEST_ACCEPT_NEW=1 prepare || fail 'new source was not downloaded via DoH Bootstrap DNS'
grep -q 'd.example' "$WORK/rulesets/delta-remote-domains-ruleset.json" || fail 'DoH-resolved source not materialized'
sed -i '/forkop.delta/d' "$WORK/uci.state"
prepare || fail 'DoH-resolved section removal failed'

# A corrupt needed source cannot silently use older flash bytes or apply.
cp "$WORK/generation/manifest.json" "$WORK/good-manifest"
printf 'tampered\n' >"$WORK/generation/source-1"
cp "$WORK/rulesets/beta-remote-domains-ruleset.json" "$WORK/good-ruleset"
if prepare; then fail 'corrupt source accepted with unavailable network'; fi
cmp "$WORK/good-manifest" "$WORK/generation/manifest.json" || fail 'failed preflight changed generation'
cmp "$WORK/good-ruleset" "$WORK/rulesets/beta-remote-domains-ruleset.json" || fail 'failed preflight changed ruleset'

# Disabling the last consumer needs no source, including the corrupt retired one.
: >"$TEST_NETWORK_LOG"
sed -i 's/forkop.beta.enabled=1/forkop.beta.enabled=0/' "$WORK/uci.state"
prepare || fail 'last section disable failed'
[ ! -e "$WORK/rulesets/beta-remote-domains-ruleset.json" ] || fail 'disabled materialization survived'
ucode -L "$LIB" "$LIB/components/updates.uc" runtime-list-cache-active || fail 'empty generation rejected'
[ ! -s "$TEST_NETWORK_LOG" ] || fail 'disabling last section used network'
[ "$(signature cron-signature)" != "$initial_cron" ] || fail 'last list schedule was not removed'

# Shared subscription cron depends on the smallest enabled interval, not URLs.
for name in sub1 sub2; do
  write_section "$name" >>"$WORK/uci.state"
  printf 'forkop.%s.action=connection\nforkop.%s.subscription_urls=https://subscriptions.test/%s\nforkop.%s.subscription_update_enabled=1\nforkop.%s.subscription_update_interval=1h\n' \
    "$name" "$name" "$name" "$name" "$name" >>"$WORK/uci.state"
done
subscription_cron=$(signature cron-signature)
sed -i '/forkop.sub2/d' "$WORK/uci.state"
[ "$(signature cron-signature)" = "$subscription_cron" ] || fail 'removing redundant subscription changed cron'
sed -i 's@https://subscriptions.test/sub1@https://subscriptions.test/replacement@' "$WORK/uci.state"
[ "$(signature cron-signature)" = "$subscription_cron" ] || fail 'subscription URL changed cron'
sed -i 's/forkop.sub1.subscription_update_interval=1h/forkop.sub1.subscription_update_interval=4h/' "$WORK/uci.state"
[ "$(signature cron-signature)" != "$subscription_cron" ] || fail 'subscription interval did not change cron'

export FORKOP_CRONTAB_FILE="$WORK/crontab" TEST_CRON_LOG="$WORK/cron-writes"
printf '0 12 * * * unrelated-job\n' >"$FORKOP_CRONTAB_FILE"
cat >"$WORK/bin/crontab" <<'EOF'
#!/bin/sh
echo write >>"$TEST_CRON_LOG"
cp "$1" "$FORKOP_CRONTAB_FILE"
EOF
chmod +x "$WORK/bin/crontab"
for attempt in 1 2; do
  ucode -L "$LIB" "$LIB/components/updates.uc" refresh-cron-from-uci /usr/bin/forkop '# forkop-list-update' '# forkop-subscription-update' '# forkop-component-update-check'
done
[ "$(wc -l <"$TEST_CRON_LOG")" -eq 1 ] || fail 'unchanged cron was rewritten'
grep -q 'unrelated-job' "$FORKOP_CRONTAB_FILE" || fail 'unrelated cron was removed'

# With */45, cron skips 01:30 even though a job completed at 00:45 is due.
write_section scheduled 'https://lists.test/unavailable.txt' >>"$WORK/uci.state"
sed -i 's/^forkop.settings.update_interval=1d$/forkop.settings.update_interval=45m/' "$WORK/uci.state"
printf 'forkop.settings.component_update_check_enabled=1\nforkop.settings.component_update_check_interval=45m\n' >>"$WORK/uci.state"
printf '%s\n' '*/45 * * * * /usr/bin/forkop list_update_if_due # forkop-list-update' \
  '*/45 * * * * /usr/bin/forkop component_updates_if_due # forkop-component-update-check' >>"$FORKOP_CRONTAB_FILE"
updates() { ucode -L "$LIB" "$LIB/components/updates.uc" "$@"; }
updates refresh-cron-from-uci /usr/bin/forkop '# forkop-list-update' '# forkop-subscription-update' '# forkop-component-update-check'
! grep -Eq 'forkop-(list-update|component-update-check)' "$FORKOP_CRONTAB_FILE" ||
  fail 'legacy list or component cron entries survived'
grep -Fxq '0 12 * * * unrelated-job' "$FORKOP_CRONTAB_FILE" ||
  fail 'migration removed an unrelated cron entry'
cp "$FORKOP_CRONTAB_FILE" "$WORK/valid-crontab"
sed -i 's/component_update_check_interval=45m/component_update_check_interval=broken/' "$WORK/uci.state"
if updates refresh-cron-from-uci /usr/bin/forkop '# forkop-list-update' '# forkop-subscription-update' '# forkop-component-update-check'; then
  fail 'invalid schedule accepted'
fi
cmp "$WORK/valid-crontab" "$FORKOP_CRONTAB_FILE" || fail 'invalid interval erased unrelated schedules'
sed -i 's/component_update_check_interval=broken/component_update_check_interval=45m/' "$WORK/uci.state"

expect_list_due() {
  local interval="$1" last="$2" now="$3" expected="$4" status=0
  printf '{"settings":{"update_interval":"%s"}}\n' "$interval" >"$WORK/list-interval.json"
  printf '%s\n' "$last" >"$WORK/last-update"
  updates list-update-due-status-fixture "$WORK/list-interval.json" "$WORK/last-update" "$now" || status=$?
  [ "$status" -eq "$expected" ] || fail "unexpected due result for $interval at $now"
}
expect_list_due 45m 2700 5399 1
expect_list_due 45m 2700 5400 0
expect_list_due 1d 86405 172800 1
expect_list_due 1d 86405 172860 0
expect_list_due 100ms 2700 2759 1
expect_list_due 100ms 2700 2760 0
expect_list_due 1d 1900000000 1800000000 0
expect_list_due 1d 1900000000 42 1
ucode -L "$LIB" "$LIB/subscription/cache.uc" update-due-status-fixture 1800000000 1900000000 3600 ||
  fail 'future subscription timestamp suppressed updates after clock correction'

export TEST_REAL_UCODE="$(command -v ucode)" TEST_COMPONENT_CALLS="$WORK/component-calls"
cat >"$WORK/bin/ucode" <<'EOF'
#!/bin/sh
case "$*" in
  *'/components/action.uc component-action forkop check_update')
    [ "${FORKOP_COMPONENT_BACKGROUND:-0}" = 1 ] || exit 90
    echo check >>"$TEST_COMPONENT_CALLS"
    case "${TEST_COMPONENT_RESULT:-error}" in
      occupied) exec "$TEST_REAL_UCODE" "$@" ;;
      latest)
        printf '%s\n' '{"success":true,"component":"forkop","action":"check_update","status":"latest","latest_version":"3.0.7"}'
        exit 0
        ;;
    esac
    exit 1
    ;;
esac
exec "$TEST_REAL_UCODE" "$@"
EOF
chmod +x "$WORK/bin/ucode"
now=$(date +%s)
printf '%s\n' "$((now - 44 * 60))" >"$WORK/state/component-update-check.timestamp"
updates component-updates-if-due || fail 'early component poll failed'
[ ! -e "$TEST_COMPONENT_CALLS" ] || fail 'component poll started an early request'
printf '%s\n' "$((now - 46 * 60))" >"$WORK/state/component-update-check.timestamp"
mkdir "$WORK/state/component-action.lock"
printf '%s\n' "$$" >"$WORK/state/component-action.lock/pid"
TEST_COMPONENT_RESULT=occupied updates component-updates-if-due || fail 'busy component poll failed'
[ "$(cat "$WORK/state/component-update-check.timestamp")" = "$((now - 46 * 60))" ] ||
  fail 'busy component poll consumed the scheduled attempt'
[ "$(cat "$WORK/state/component-action.lock/pid")" = "$$" ] ||
  fail 'busy component poll changed the existing action owner'
[ ! -d "$WORK/state/component-update-check.lock" ] || fail 'busy component poll retained its scheduler lock'
[ ! -e "$WORK/state/component-update-checks/forkop.json" ] || fail 'busy component poll cached a result'
rm "$WORK/state/component-action.lock/pid"
rmdir "$WORK/state/component-action.lock"
TEST_COMPONENT_RESULT=latest updates component-updates-if-due || fail 'deferred component poll did not retry'
grep -Eq '"status"[[:space:]]*:[[:space:]]*"latest"' "$WORK/state/component-update-checks/forkop.json" ||
  fail 'retried component poll did not cache the successful result'
[ "$(wc -l <"$TEST_COMPONENT_CALLS")" -eq 2 ] || fail 'expected a deferred poll and one retry'

# An actual check failure still consumes an attempt to avoid polling the mirror every minute.
: >"$TEST_COMPONENT_CALLS"
printf '%s\n' "$((now - 46 * 60))" >"$WORK/state/component-update-check.timestamp"
updates component-updates-if-due || fail 'due component check failed'
updates component-updates-if-due || fail 'component poll after the attempt failed'
[ "$(cat "$TEST_COMPONENT_CALLS")" = check ] || fail 'due component check did not run exactly once'

sed -i 's/component_update_check_interval=45m/component_update_check_interval=100ms/' "$WORK/uci.state"
date +%s >"$WORK/state/component-update-check.timestamp"
updates component-updates-if-due || fail 'a saved sub-minute component interval must use a one-minute minimum'

printf '1234\n' >"$WORK/state/list-update-last-success.timestamp"
mkdir -p "$FORKOP_PERSISTENT_LIST_CACHE_DIR"
printf '%s\n' "$((now + 86400))" >"$FORKOP_PERSISTENT_LIST_CACHE_DIR/last-success.timestamp"
if TEST_ACCEPT_NEW=0 updates list-update-if-due; then
  fail 'scheduled download failure was not detected'
fi
test -s "$WORK/state/list-update-last-attempt.timestamp" || fail 'scheduled attempt was not recorded'
test "$(cat "$WORK/state/list-update-last-success.timestamp")" = 1234 || fail 'failed attempt became a success'
: >"$TEST_NETWORK_LOG"
TEST_ACCEPT_NEW=0 updates list-update-if-due || fail 'immediate repeat did not skip the failed download'
[ ! -s "$TEST_NETWORK_LOG" ] || fail 'the next tick retried the failed download early'

printf '%s\n1\n' "$$" > "$FORKOP_LIST_UPDATE_PID_FILE"
updates stop-list-update
[ ! -e "$FORKOP_LIST_UPDATE_PID_FILE" ] || fail 'stale worker record remained'
(
  guard="$FORKOP_RUNTIME_LIST_GENERATION_DIR.guard"
  stage="$FORKOP_RUNTIME_LIST_GENERATION_DIR.stage"
  exec 9>>"$guard"
  flock -x 9
  mkdir "$stage"
  : > "$stage/in-progress"
  updates runtime-list-cache-active 9>&- &
  reader=$!
  sleep 0.2
  [ -f "$stage/in-progress" ] || fail 'reader removed a concurrent generation stage'
  flock -u 9
  wait "$reader" || true
  [ ! -e "$stage" ] || fail 'abandoned stage was not cleaned after releasing the lock'
)
echo 'list composition cache checks passed'
