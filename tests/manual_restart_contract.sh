#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIFECYCLE="$ROOT_DIR/forkop/files/usr/lib/service/lifecycle.uc"
UI="$ROOT_DIR/forkop/files/usr/lib/service/ui.uc"
UPDATES="$ROOT_DIR/forkop/files/usr/lib/components/updates.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

manual_body="$(sed -n '/^function manual_restart()/,/^function package_manager_remove_if_installed()/p' "$LIFECYCLE")"
restart_body="$(sed -n '/^function restart()/,/^function manual_restart()/p' "$LIFECYCLE")"

for required in \
  '"acquire-runtime-dir-lock", RELOAD_LOCK_DIR' \
  'subscription-prepare-only' \
  'FORKOP_LIST_UPDATE_PREPARE_ONLY: "1"' \
  'FORKOP_MANUAL_RESTART_LOCK_HELD: "1"' \
  'let ruleset_proxy_address = setting_bool("download_lists_via_proxy", false)' \
  '"refresh-for-restart", ruleset_proxy_address' \
  'let status = restart();'; do
  grep -Fq "$required" <<<"$manual_body" || fail "manual restart is missing $required"
done

subscription_line="$(grep -nF 'subscription-prepare-only' <<<"$manual_body" | sed -n '1p' | cut -d: -f1)"
list_line="$(grep -nF 'FORKOP_LIST_UPDATE_PREPARE_ONLY: "1"' <<<"$manual_body" | sed -n '1p' | cut -d: -f1)"
ruleset_line="$(grep -nF '"refresh-for-restart", ruleset_proxy_address' <<<"$manual_body" | sed -n '1p' | cut -d: -f1)"
restart_line="$(grep -nF 'let status = restart();' <<<"$manual_body" | sed -n '1p' | cut -d: -f1)"
[ "$subscription_line" -lt "$list_line" ] && [ "$list_line" -lt "$ruleset_line" ] && [ "$ruleset_line" -lt "$restart_line" ] ||
  fail "manual restart does not prepare subscriptions, lists, and rulesets before restart"

grep -Fq 'module_status(UPDATES_UC' <<<"$restart_body" &&
  fail "ordinary restart unexpectedly gained forced update behavior"
grep -Fq 'manual-ui-restart' "$UI" || fail "LuCI restart is not routed to the manual path"
grep -Fq '[ BIN_PATH, "manual_restart" ]' "$UI" || fail "service worker does not invoke manual restart entrypoint"
grep -Fq 'FORKOP_MANUAL_RESTART_LOCK_HELD' "$UPDATES" || fail "prepare workers do not preserve the manual restart lock"

prepare_finish="$(sed -n '/^function finish_list_update/,/^function dns_probe_passed/p' "$UPDATES")"
grep -Fq 'exit(status == 0 ? 0 : 1);' <<<"$prepare_finish" ||
  fail "list prepare-only mode does not stop before runtime apply"
prepare_exit_line="$(grep -nF 'exit(status == 0 ? 0 : 1);' <<<"$prepare_finish" | sed -n '1p' | cut -d: -f1)"
runtime_reload_line="$(grep -nF '[ SERVICE_INIT, "reload", "list-content" ]' <<<"$prepare_finish" | sed -n '1p' | cut -d: -f1)"
[ "$prepare_exit_line" -lt "$runtime_reload_line" ] ||
  fail "list prepare-only mode can invoke an intermediate runtime reload"

printf 'manual restart contract checks passed\n'
