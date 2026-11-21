#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
UPDATES_UC="$FORKOP_LIB/components/updates.uc"
LIFECYCLE_UC="$FORKOP_LIB/service/lifecycle.uc"
INITD_UC="$FORKOP_LIB/service/initd.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/runtime-generation"
printf 'coherent-generation\n' >"$WORK_DIR/runtime-generation/source-1"
generation_hash="$(md5sum "$WORK_DIR/runtime-generation/source-1" | awk '{print $1}')"

cat >"$WORK_DIR/bin/forkop-init" <<'EOF_INIT'
#!/bin/sh
printf '%s\n' "$*" >>"$FORKOP_TEST_RELOAD_LOG"
if [ -e "$FORKOP_TEST_PENDING_FILE" ]; then
  cat "$FORKOP_TEST_PENDING_FILE" >"${FORKOP_TEST_PENDING_FILE}.seen-by-init"
fi
if [ -e "${FORKOP_TEST_PENDING_FILE}.queue" ]; then
  printf 'reason=list-content\n' >"$FORKOP_TEST_PENDING_FILE"
  printf 'queued\n'
  exit 0
fi
if [ "${FORKOP_TEST_RELOAD_STATUS:-0}" = 0 ]; then
  # Model lifecycle's post-commit removal. A synchronous init.d reload has
  # actually completed by this point; a queued one must leave the marker.
  rm -f "$FORKOP_TEST_LIST_APPLY_MARKER" "$FORKOP_TEST_PENDING_FILE"
fi
exit "${FORKOP_TEST_RELOAD_STATUS:-0}"
EOF_INIT
cat >"$WORK_DIR/ruleset-cache-stub.uc" <<'EOF_RULESET'
#!/usr/bin/env ucode
exit(int(getenv("FORKOP_TEST_RULESET_STATUS") || "1"));
EOF_RULESET
cat >"$WORK_DIR/bin/logger" <<'EOF_LOGGER'
#!/bin/sh
printf '%s\n' "$*" >>"$FORKOP_TEST_LOG"
EOF_LOGGER
chmod +x "$WORK_DIR/bin/forkop-init" "$WORK_DIR/bin/logger"

run_finish() {
  PATH="$WORK_DIR/bin:$PATH" \
  FORKOP_LIB="$FORKOP_LIB" \
  FORKOP_SERVICE_INIT="$WORK_DIR/bin/forkop-init" \
  FORKOP_RULESET_CACHE_UC="$WORK_DIR/ruleset-cache-stub.uc" \
  FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
  FORKOP_PENDING_RELOAD_FILE="$WORK_DIR/reload.pending" \
  FORKOP_LIST_UPDATE_RELOAD_FILE="$WORK_DIR/list-update.reload" \
  FORKOP_RULESET_REFRESH_AFTER_LIST_FILE="$WORK_DIR/ruleset-refresh-after-list" \
  FORKOP_LIST_UPDATE_PID_FILE="$WORK_DIR/list-update.pid" \
  FORKOP_RELOAD_LOCK_DIR="$WORK_DIR/reload.lock" \
  FORKOP_TEST_RELOAD_LOG="$WORK_DIR/reload.log" \
  FORKOP_TEST_PENDING_FILE="$WORK_DIR/reload.pending" \
  FORKOP_TEST_LIST_APPLY_MARKER="$WORK_DIR/list-update.reload" \
  FORKOP_TEST_LOG="$WORK_DIR/log" \
  FORKOP_TEST_RELOAD_STATUS="$1" \
  FORKOP_TEST_RULESET_STATUS="${4:-1}" \
    ucode -L "$FORKOP_LIB" "$UPDATES_UC" finish-list-update-fixture "${5:-0}" "${6:-1}" "$2"
}

printf 'reason=config-change\n' >"$WORK_DIR/reload.pending"
: >"$WORK_DIR/reload.log"
run_finish 0 1 || fail "successful changed generation final reload returned failure"
[ "$(cat "$WORK_DIR/reload.log")" = "reload list-content" ] ||
  fail "successful worker did not issue exactly one list-content reload"
[ "$(cat "$WORK_DIR/reload.pending.seen-by-init")" = "reason=config-change" ] ||
  fail "list worker consumed the queued request before initd could claim it"
[ ! -e "$WORK_DIR/reload.pending" ] || fail "successful apply did not consume pending reload"
[ ! -e "$WORK_DIR/list-update.reload" ] || fail "successful apply retained its apply marker"

# init.d returns zero when reload.lock is held, but reports `queued` for a
# list-content request. The committed generation is not applied until that
# queued lifecycle runs, so the durable marker must survive.
: >"$WORK_DIR/reload.log"
rm -f "$WORK_DIR/reload.pending" "$WORK_DIR/list-update.reload"
: >"$WORK_DIR/reload.pending.queue"
run_finish 0 1 || fail "queued final list-content reload returned failure"
rm -f "$WORK_DIR/reload.pending.queue"
[ "$(cat "$WORK_DIR/reload.log")" = "reload list-content" ] ||
  fail "queued final apply did not issue list-content reload"
[ "$(cat "$WORK_DIR/reload.pending")" = "reason=list-content" ] ||
  fail "queued final apply did not preserve list-content pending semantics"
[ "$(cat "$WORK_DIR/list-update.reload")" = "apply-pending" ] ||
  fail "queued final apply lost its durable local marker"
pending_reason="$(FORKOP_LIST_UPDATE_RELOAD_FILE="$WORK_DIR/list-update.reload" \
  ucode -L "$FORKOP_LIB" "$LIFECYCLE_UC" reload-reason-fixture pending)"
[ "$pending_reason" = "list-content" ] || fail "queued pending reload lost list-content reason"

# Exercise the real initd lock path too, rather than merely returning the
# queue acknowledgement from the worker stub above. A live owner makes the
# directory non-stale, so initd must queue list-content and expose `queued`.
mkdir "$WORK_DIR/held-reload.lock"
printf '%s\n' "$$" >"$WORK_DIR/held-reload.lock/pid"
initd_queue_output="$(
  FORKOP_LIB="$FORKOP_LIB" \
  FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/initd-runtime" \
  FORKOP_PENDING_RELOAD_FILE="$WORK_DIR/initd-reload.pending" \
  FORKOP_RELOAD_LOCK_DIR="$WORK_DIR/held-reload.lock" \
  FORKOP_SERVICE_INIT="$WORK_DIR/bin/forkop-init" \
    ucode -L "$FORKOP_LIB" "$INITD_UC" reload-service list-content "$$"
)"
[ "$initd_queue_output" = "queued" ] || fail "locked initd request did not report queued list-content"
[ "$(sed -n '1p' "$WORK_DIR/initd-reload.pending")" = "reason=list-content" ] ||
  fail "locked initd request did not retain list-content as its pending reason"
rm -f "$WORK_DIR/held-reload.lock/pid"
rmdir "$WORK_DIR/held-reload.lock"

# A changed remote JSON/SRS cache is independent of list-derived generation.
# Its refresh return code 0 means changed and must coalesce into one apply.
: >"$WORK_DIR/reload.log"
rm -f "$WORK_DIR/reload.pending" "$WORK_DIR/list-update.reload"
printf 'refresh\n' >"$WORK_DIR/ruleset-refresh-after-list"
run_finish 0 0 0 0 || fail "changed remote ruleset final apply returned failure"
[ "$(cat "$WORK_DIR/reload.log")" = "reload list-content" ] ||
  fail "changed remote ruleset did not trigger exactly one runtime apply"
[ ! -e "$WORK_DIR/list-update.reload" ] ||
  fail "completed remote ruleset apply retained durable marker"

# Return code 1 means byte-identical cache; no apply. Return code 2 is a
# refresh failure, which must neither claim a change nor trigger an apply.
for ruleset_status in 1 2; do
  : >"$WORK_DIR/reload.log"
  rm -f "$WORK_DIR/reload.pending" "$WORK_DIR/list-update.reload"
  printf 'refresh\n' >"$WORK_DIR/ruleset-refresh-after-list"
  run_finish 0 0 0 "$ruleset_status" || fail "ruleset status $ruleset_status changed worker success"
  [ ! -s "$WORK_DIR/reload.log" ] || fail "ruleset status $ruleset_status triggered a false runtime apply"
  [ ! -e "$WORK_DIR/list-update.reload" ] || fail "ruleset status $ruleset_status retained false apply marker"
done

# An equal, fully validated generation has no runtime delta. It must complete
# the worker successfully without creating a reload, pending, or retry marker.
: >"$WORK_DIR/reload.log"
run_finish 0 0 || fail "byte-identical generation worker returned failure"
[ ! -s "$WORK_DIR/reload.log" ] || fail "byte-identical generation triggered list-content reload"
[ ! -e "$WORK_DIR/reload.pending" ] || fail "byte-identical generation retained pending reload"
[ ! -e "$WORK_DIR/list-update.reload" ] || fail "byte-identical generation retained an apply marker"

printf 'reason=config-change\n' >"$WORK_DIR/reload.pending"
printf '1\n' >"$WORK_DIR/list-update.reload"
: >"$WORK_DIR/reload.log"
if run_finish 23 1; then
  fail "worker reported success after final list-content reload failure"
fi
[ "$(cat "$WORK_DIR/reload.log")" = "reload list-content" ] ||
  fail "failed worker did not attempt exactly one final list-content reload"
[ "$(cat "$WORK_DIR/reload.pending")" = "reason=config-change" ] ||
  fail "failed apply lost the prior pending reload request"
[ "$(cat "$WORK_DIR/list-update.reload")" = "apply-pending" ] ||
  fail "failed apply did not retain durable local retry marker"
[ "$generation_hash" = "$(md5sum "$WORK_DIR/runtime-generation/source-1" | awk '{print $1}')" ] ||
  fail "failed runtime apply changed the committed generation"
grep -Fq 'retaining it for a local retry' "$WORK_DIR/log" ||
  fail "failed runtime apply did not record the retry-safe error"

pending_reason="$(FORKOP_LIST_UPDATE_RELOAD_FILE="$WORK_DIR/list-update.reload" \
  ucode -L "$FORKOP_LIB" "$LIFECYCLE_UC" reload-reason-fixture pending)"
[ "$pending_reason" = "list-content" ] || fail "pending reload did not choose local list-content retry"
grep -Fq 'plan.has_work = 1;' "$LIFECYCLE_UC" ||
  fail "local list-content retry can still be skipped as a no-op"
grep -Fq 'if (reason == "list-content")' "$LIFECYCLE_UC" ||
  fail "successful local list-content retry does not clear its durable marker"
rm -f "$WORK_DIR/list-update.reload"
ordinary_reason="$(FORKOP_LIST_UPDATE_RELOAD_FILE="$WORK_DIR/list-update.reload" \
  ucode -L "$FORKOP_LIB" "$LIFECYCLE_UC" reload-reason-fixture pending)"
[ "$ordinary_reason" = "pending" ] || fail "normal pending reload was unexpectedly rewritten"

# An aborted source transaction must not apply a new generation or lose the
# committed files. Pending source/ruleset work must survive for the next retry.
rm -f "$WORK_DIR/reload.pending"
printf '1\n' >"$WORK_DIR/list-update.reload"
printf 'refresh\n' >"$WORK_DIR/ruleset-refresh-after-list"
: >"$WORK_DIR/reload.log"
if run_finish 0 0 0 1 1 0; then
  fail "aborted source transaction reported success"
fi
[ ! -s "$WORK_DIR/reload.log" ] || fail "aborted source transaction applied a new runtime"
[ "$(cat "$WORK_DIR/list-update.reload")" = 1 ] || fail "abort lost pending list retry"
[ "$(cat "$WORK_DIR/ruleset-refresh-after-list")" = refresh ] || fail "abort lost pending ruleset retry"
[ "$(md5sum "$WORK_DIR/runtime-generation/source-1" | awk '{print $1}')" = "$generation_hash" ] ||
  fail "aborted transaction replaced the committed generation"

printf 'final list update/reload lifecycle checks passed\n'
stale_reason="$(FORKOP_LIST_UPDATE_RELOAD_FILE="$WORK_DIR/list-update.reload" \
  ucode -L "$FORKOP_LIB" "$LIFECYCLE_UC" reload-reason-fixture pending 0)"
[ "$stale_reason" = "list-source-retry" ] || fail "stale generation was retried as local content"
explicit_stale="$(ucode -L "$FORKOP_LIB" "$LIFECYCLE_UC" reload-reason-fixture list-content 0)"
[ "$explicit_stale" = "list-source-retry" ] || fail "explicit content reload accepted stale generation"
