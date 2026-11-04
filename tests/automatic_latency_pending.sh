#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORKOP_LIB="${FORKOP_LIB:-$ROOT_DIR/forkop/files/usr/lib}"
DIAGNOSTICS_UC="$FORKOP_LIB/diagnostics/runtime.uc"
UPDATES_UC="$FORKOP_LIB/components/updates.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/config-a.json" <<'EOF_CONFIG_A'
{"outbounds":[{"type":"direct","tag":"direct"},{"type":"vless","tag":"proxy-a","server":"one.test","server_port":443},{"type":"trojan","tag":"proxy-b","server":"two.test","server_port":443}],"experimental":{"cache_file":{"enabled":true}}}
EOF_CONFIG_A
cat >"$WORK_DIR/config-metadata.json" <<'EOF_CONFIG_METADATA'
{"outbounds":[{"server_port":443,"server":"two.test","tag":"proxy-b","type":"trojan"},{"server_port":443,"server":"one.test","tag":"proxy-a","type":"vless"},{"tag":"direct","type":"direct"}],"experimental":{"cache_file":{"enabled":false}},"log":{"level":"debug"}}
EOF_CONFIG_METADATA
cat >"$WORK_DIR/config-changed.json" <<'EOF_CONFIG_CHANGED'
{"outbounds":[{"type":"direct","tag":"direct"},{"type":"vless","tag":"proxy-a","server":"changed.test","server_port":443},{"type":"trojan","tag":"proxy-b","server":"two.test","server_port":443}]}
EOF_CONFIG_CHANGED

signature() {
  FORKOP_LIB="$FORKOP_LIB" ucode -L "$FORKOP_LIB" "$DIAGNOSTICS_UC" proxy-outbounds-signature "$1"
}

sig_a="$(signature "$WORK_DIR/config-a.json")"
sig_metadata="$(signature "$WORK_DIR/config-metadata.json")"
sig_changed="$(signature "$WORK_DIR/config-changed.json")"
[ -n "$sig_a" ] || fail "proxy signature was not produced"
[ "$sig_a" = "$sig_metadata" ] || fail "metadata or top-level config changes altered the proxy signature"
[ "$sig_a" != "$sig_changed" ] || fail "a real proxy endpoint change did not alter the proxy signature"

cat >"$WORK_DIR/uci.state" <<EOF_UCI
forkop.settings=settings
forkop.settings.config_path=$WORK_DIR/config-changed.json
EOF_UCI
cat >"$WORK_DIR/state-stub.uc" <<'EOF_STATE'
#!/usr/bin/env ucode
let fs = require("fs");
let mode = ARGV[0] || "";
let path = ARGV[1] || "";
if (mode == "acquire-runtime-dir-lock" || mode == "acquire-runtime-dir-lock-wait" ||
    mode == "acquire-runtime-dir-lock-wait-until-package-upgrade") {
    if (index(path, "reload.lock") >= 0 && fs.stat(getenv("TEST_RELOAD_FAIL_FLAG")) != null) {
        let count_path = getenv("TEST_RELOAD_COUNT_FILE");
        let count = int(fs.readfile(count_path) || "0") + 1;
        fs.writefile(count_path, count + "\n");
        if (count > 1) exit(1);
    }
    if (fs.stat(path) != null) exit(1);
    exit(system("mkdir " + path));
}
if (mode == "release-runtime-dir-lock") {
    system("rmdir " + path + " 2>/dev/null");
    exit(0);
}
if (mode == "sing-box-service-runtime-pid") {
    print(fs.readfile(getenv("TEST_PID_FILE")) || "123\n");
    exit(0);
}
exit(0);
EOF_STATE
cat >"$WORK_DIR/bin/logger" <<'EOF_LOGGER'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_LOG"
EOF_LOGGER
cat >"$WORK_DIR/bin/curl" <<'EOF_CURL'
#!/bin/sh
case "$*" in
  */proxies)
    [ "${TEST_CLASH_UNREADY:-0}" = 1 ] && { printf 'not-json\n'; exit 0; }
    printf '%s\n' '{"proxies":{"proxy-a":{"type":"VLESS"},"proxy-b":{"type":"Trojan"},"proxy-c":{"type":"VLESS"},"proxy-d":{"type":"Trojan"},"proxy-e":{"type":"VLESS"},"proxy-f":{"type":"Trojan"},"proxy-g":{"type":"VLESS"},"proxy-h":{"type":"Trojan"},"proxy-i":{"type":"VLESS"},"DIRECT":{"type":"Direct"}}}'
    ;;
  */delay*)
    printf 'latency\n' >>"$TEST_CURL_LOG"
    if [ -n "${TEST_CHANGE_PID_FILE:-}" ]; then
      printf '456\n' >"$TEST_CHANGE_PID_FILE"
    fi
    if [ -n "${TEST_CHANGE_CONFIG_FILE:-}" ]; then
      cp "$TEST_CHANGED_CONFIG" "$TEST_CHANGE_CONFIG_FILE"
    fi
    if [ -n "${TEST_CANCEL_MARKER_FILE:-}" ]; then
      rm -f "$TEST_CANCEL_MARKER_FILE"
    fi
    if [ -n "${TEST_CURL_DELAY:-}" ]; then
      mkdir "$TEST_CURL_LOG.active.$$"
      set -- "$TEST_CURL_LOG".active.*
      [ "$#" -gt 1 ] && : >"$TEST_CURL_LOG.parallel"
      sleep "$TEST_CURL_DELAY"
      rmdir "$TEST_CURL_LOG.active.$$"
    fi
    [ "${TEST_CURL_FAIL:-0}" = 1 ] && { printf 'not-json\n'; exit 0; }
    printf '%s\n' '{"delay":25}'
    ;;
  *) printf '%s\n' '{}' ;;
esac
EOF_CURL
chmod +x "$WORK_DIR/bin/logger" "$WORK_DIR/bin/curl" "$WORK_DIR/state-stub.uc"

export PATH="$WORK_DIR/bin:$PATH"
export TEST_LOG="$WORK_DIR/test.log"
export TEST_CURL_LOG="$WORK_DIR/curl.log"
export TEST_PID_FILE="$WORK_DIR/pid"
export TEST_RELOAD_COUNT_FILE="$WORK_DIR/reload-count"
export TEST_RELOAD_FAIL_FLAG="$WORK_DIR/fail-reacquire"
export FORKOP_UI_STATE_DIR="$WORK_DIR/ui"
export FORKOP_UI_COMPONENT_ACTION_DIR="$WORK_DIR/components"
export FORKOP_UI_SUBSCRIPTION_ACTION_DIR="$WORK_DIR/subscriptions"
export FORKOP_LIB FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export FORKOP_SERVICE_STATE_UC="$WORK_DIR/state-stub.uc"
export FORKOP_AUTOMATIC_LATENCY_PENDING_FILE="$WORK_DIR/automatic-latency.pending"
export FORKOP_AUTOMATIC_LATENCY_TEST_LOCK_DIR="$WORK_DIR/latency.lock"
export FORKOP_RELOAD_LOCK_DIR="$WORK_DIR/reload.lock"
export FORKOP_AUTOMATIC_LATENCY_BATCH_PAUSE=0
export FORKOP_AUTOMATIC_LATENCY_RETRY_BASE_SECONDS=2
export FORKOP_AUTOMATIC_LATENCY_CLASH_READY_ATTEMPTS=1
: >"$TEST_LOG"
: >"$TEST_CURL_LOG"
printf '123\n' >"$TEST_PID_FILE"
printf '0\n' >"$TEST_RELOAD_COUNT_FILE"

FORKOP_AUTOMATIC_LATENCY_PENDING_FILE="$FORKOP_AUTOMATIC_LATENCY_PENDING_FILE" \
  ucode -L "$FORKOP_LIB" "$UPDATES_UC" schedule-automatic-latency-test "$sig_changed" ||
  fail "proxy change did not create a pending marker"
[ -s "$FORKOP_AUTOMATIC_LATENCY_PENDING_FILE" ] || fail "pending marker was not persisted"
marker_before="$(cat "$FORKOP_AUTOMATIC_LATENCY_PENDING_FILE")"
ucode -L "$FORKOP_LIB" "$UPDATES_UC" schedule-automatic-latency-test "$sig_changed" ||
  fail "identical pending request was not coalesced"
[ "$(cat "$FORKOP_AUTOMATIC_LATENCY_PENDING_FILE")" = "$marker_before" ] ||
  fail "identical request rewrote pending retry state"

# A malformed marker cannot survive startup and produce one warning per boot.
printf '{malformed\n' >"$FORKOP_AUTOMATIC_LATENCY_PENDING_FILE"
invalid_log_lines="$(wc -l <"$TEST_LOG")"
ucode -L "$FORKOP_LIB" "$DIAGNOSTICS_UC" automatic-latency-test resume
[ ! -e "$FORKOP_AUTOMATIC_LATENCY_PENDING_FILE" ] || fail "invalid marker was retained"
[ "$(wc -l <"$TEST_LOG")" -eq $((invalid_log_lines + 1)) ] ||
  fail "invalid marker did not emit exactly one discard log"
grep -Fq 'Discarded invalid automatic latency test pending marker' "$TEST_LOG" ||
  fail "invalid marker discard was not logged"
ucode -L "$FORKOP_LIB" "$DIAGNOSTICS_UC" automatic-latency-test resume
[ "$(wc -l <"$TEST_LOG")" -eq $((invalid_log_lines + 1)) ] ||
  fail "discarded invalid marker logged again on the next startup"

# A stale marker must not test a different current proxy set.
ucode -L "$FORKOP_LIB" "$UPDATES_UC" schedule-automatic-latency-test "$sig_changed"
sed "s/$sig_changed/$sig_a/" "$FORKOP_AUTOMATIC_LATENCY_PENDING_FILE" >"$WORK_DIR/stale"
mv "$WORK_DIR/stale" "$FORKOP_AUTOMATIC_LATENCY_PENDING_FILE"
ucode -L "$FORKOP_LIB" "$DIAGNOSTICS_UC" automatic-latency-test resume
[ ! -e "$FORKOP_AUTOMATIC_LATENCY_PENDING_FILE" ] || fail "stale marker was retained"
[ ! -s "$TEST_CURL_LOG" ] || fail "stale marker triggered Clash latency requests"

# Two requests coalesce behind one runtime lock; success removes the marker.
ucode -L "$FORKOP_LIB" "$UPDATES_UC" schedule-automatic-latency-test "$sig_changed"
TEST_CURL_DELAY=2 ucode -L "$FORKOP_LIB" "$DIAGNOSTICS_UC" automatic-latency-test new &
first_pid=$!
sleep 1
ucode -L "$FORKOP_LIB" "$DIAGNOSTICS_UC" automatic-latency-test new &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
[ "$(wc -l <"$TEST_CURL_LOG")" -eq 9 ] || fail "concurrent workers did not coalesce"
[ ! -e "$FORKOP_AUTOMATIC_LATENCY_PENDING_FILE" ] || fail "successful full test did not remove marker"
[ -e "$TEST_CURL_LOG.parallel" ] || fail "automatic sweep did not overlap latency requests"
ucode -e 'let fs = require("fs"); let paths = fs.glob(getenv("FORKOP_UI_STATE_DIR") + "/latency-actions/*.json"); assert(length(paths) == 1, "automatic progress job missing or duplicated"); let value = json(fs.readfile(paths[0])); assert(value.section == "*" && value.running == false && value.success == true, "automatic job did not finish"); assert(value.progress.completed == 9 && value.progress.total == 9 && value.progress.failed == 0, "automatic progress was not updated");'
[ "$(grep -Fc 'Automatic latency test progress:' "$TEST_LOG" || true)" -eq 0 ] ||
  fail "latency batching emitted intermediate syslog progress"

# A manual restart invalidates the pending marker before it creates a new
# runtime. Its old worker must stop at the next batch boundary rather than
# continue or schedule a background resume alongside that runtime.
: >"$TEST_CURL_LOG"
ucode -L "$FORKOP_LIB" "$UPDATES_UC" schedule-automatic-latency-test "$sig_changed"
TEST_CANCEL_MARKER_FILE="$FORKOP_AUTOMATIC_LATENCY_PENDING_FILE" \
  FORKOP_AUTOMATIC_LATENCY_BATCH_SIZE=1 \
  ucode -L "$FORKOP_LIB" "$DIAGNOSTICS_UC" automatic-latency-test new
[ "$(wc -l <"$TEST_CURL_LOG")" -eq 1 ] || fail "canceled automatic latency worker continued after manual restart"
[ ! -e "$FORKOP_AUTOMATIC_LATENCY_PENDING_FILE" ] || fail "manual restart cancellation retained the old latency marker"
grep -Fq 'pending generation was replaced' "$TEST_LOG" ||
  fail "canceled automatic latency worker did not report its generation change"

# A semantic proxy change without a PID change cannot let an old worker
# acknowledge its marker; the next worker discards that stale marker.
: >"$TEST_CURL_LOG"
cp "$WORK_DIR/config-changed.json" "$WORK_DIR/config-before-stale.json"
ucode -L "$FORKOP_LIB" "$UPDATES_UC" schedule-automatic-latency-test "$sig_changed"
TEST_CHANGE_CONFIG_FILE="$WORK_DIR/config-changed.json" \
TEST_CHANGED_CONFIG="$WORK_DIR/config-a.json" \
  ucode -L "$FORKOP_LIB" "$DIAGNOSTICS_UC" automatic-latency-test new
[ -s "$FORKOP_AUTOMATIC_LATENCY_PENDING_FILE" ] || fail "stale worker removed its pending marker"
ucode -L "$FORKOP_LIB" "$DIAGNOSTICS_UC" automatic-latency-test resume
[ ! -e "$FORKOP_AUTOMATIC_LATENCY_PENDING_FILE" ] || fail "stale proxy marker was not discarded"
mv "$WORK_DIR/config-before-stale.json" "$WORK_DIR/config-changed.json"

# A reload between batches keeps the marker, and a later start resumes it.
: >"$TEST_CURL_LOG"
printf '123\n' >"$TEST_PID_FILE"
printf '0\n' >"$TEST_RELOAD_COUNT_FILE"
: >"$TEST_RELOAD_FAIL_FLAG"
ucode -L "$FORKOP_LIB" "$UPDATES_UC" schedule-automatic-latency-test "$sig_changed"
export FORKOP_AUTOMATIC_LATENCY_BATCH_SIZE=1
ucode -L "$FORKOP_LIB" "$DIAGNOSTICS_UC" automatic-latency-test new
unset FORKOP_AUTOMATIC_LATENCY_BATCH_SIZE
[ -s "$FORKOP_AUTOMATIC_LATENCY_PENDING_FILE" ] || {
  printf '%s\n' '--- automatic latency test log ---' >&2
  cat "$TEST_LOG" >&2
  printf 'reload acquisitions: %s\n' "$(cat "$TEST_RELOAD_COUNT_FILE")" >&2
  fail "reload interruption removed pending marker"
}
rm -f "$TEST_RELOAD_FAIL_FLAG"
printf '456\n' >"$TEST_PID_FILE"
: >"$TEST_CURL_LOG"
ucode -L "$FORKOP_LIB" "$DIAGNOSTICS_UC" automatic-latency-test resume
# The interruption path schedules its own detached resume.  An explicit resume
# above may legitimately coalesce behind that worker, so wait for the single
# owner to finish instead of assuming which process wins the lock race.
resume_wait=0
while [ -e "$FORKOP_AUTOMATIC_LATENCY_PENDING_FILE" ] && [ "$resume_wait" -lt 10 ]; do
  sleep 1
  resume_wait=$((resume_wait + 1))
done
[ ! -e "$FORKOP_AUTOMATIC_LATENCY_PENDING_FILE" ] || fail "resumed test did not complete and clear marker"

# Clash failure retains the marker and an immediate retry performs no requests.
: >"$TEST_CURL_LOG"
ucode -L "$FORKOP_LIB" "$UPDATES_UC" schedule-automatic-latency-test "$sig_changed"
TEST_CLASH_UNREADY=1 ucode -L "$FORKOP_LIB" "$DIAGNOSTICS_UC" automatic-latency-test new &&
  fail "unready Clash API unexpectedly succeeded"
[ -s "$FORKOP_AUTOMATIC_LATENCY_PENDING_FILE" ] || fail "Clash failure removed pending marker"
grep -Eq '"failures":[[:space:]]*1.*"retry_after":[[:space:]]*[1-9][0-9]+' "$FORKOP_AUTOMATIC_LATENCY_PENDING_FILE" ||
  { cat "$FORKOP_AUTOMATIC_LATENCY_PENDING_FILE" >&2; fail "Clash failure did not record retry backoff"; }
requests_before="$(wc -l <"$TEST_CURL_LOG")"
ucode -L "$FORKOP_LIB" "$DIAGNOSTICS_UC" automatic-latency-test resume &
retry_pid=$!
sleep 1
[ "$(wc -l <"$TEST_CURL_LOG")" -eq "$requests_before" ] || fail "retry pause allowed a rapid retry loop"
wait "$retry_pid"
[ ! -e "$FORKOP_AUTOMATIC_LATENCY_PENDING_FILE" ] || fail "deferred retry did not continue automatically"

grep -Fq 'Starting new automatic latency test' "$TEST_LOG" || fail "new-test log is missing"
grep -Fq 'Resuming interrupted automatic latency test' "$TEST_LOG" || fail "resume log is missing"
grep -Fq 'pending marker was removed' "$TEST_LOG" || fail "completion log is missing"
grep -Fq 'interrupted by reload' "$TEST_LOG" || fail "reload interruption log is missing"

printf 'automatic latency pending-marker checks passed\n'
