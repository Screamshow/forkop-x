#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
prefix="${FORKOP_WSL_PREFIX:-$HOME/.local}"
export PATH="$prefix/bin:$PATH"
export LD_LIBRARY_PATH="$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

local_fixtures() {
  cat <<'FIXTURES'
shell build_version.sh
shell forkop_upgrade_recovery.sh
shell installer_pinned_xrust_busy.sh
shell installer_update_rollback.sh
shell repository_modes.sh
ucode full_uninstall.sh
ucode package_contract.sh
ucode package_upgrade_service_action.sh
ucode installer_sing_box_x_plan.sh
ucode bytecode_cache.sh
ucode config_migration_transaction.sh
ucode dns_rollback_transaction.sh
ucode latency_probe_batches.sh
ucode list_change_cache.sh
ucode list_update_final_reload.sh
ucode list_update_reload_policy.sh
ucode monitoring_runtime_config.sh
ucode network_runtime_p2.sh
ucode priority_scheduler.sh
ucode restart_transition_recovery.sh
ucode ruleset_cache.sh
ucode ruleset_digest_reuse.sh
ucode socks_uri_auth.sh
ucode subscription_base64.sh
ucode subscription_cache_relocation.sh
ucode subscription_filter_selection.sh
ucode subscription_runtime_unchanged.sh
ucode watchdog_recovery.sh
ucode worker_identity.sh
ucode xrust_path_migration.sh
ucode component_action_rollback.uc
python editor_preview_download.py
xrust dns_action_source_exclusions.sh
xrust ruleset_required_reload.sh
xrust ruleset_rollback_references.sh
xrust urltest_groups.sh
FIXTURES
}

usage() {
  printf 'Usage: %s [--list | --list-vm | --require-native]\n' "${0##*/}"
}

if (( $# > 1 )); then usage >&2; exit 2; fi
case "${1:-}" in
  --list) local_fixtures; exit 0 ;;
  --list-vm)
    find "$ROOT_DIR/tests" -maxdepth 1 -type f \( -name '*_vm.sh' -o -name 'vm_*.sh' \) \
      -printf 'tests/%f\n' | sort
    exit 0 ;;
  --help|-h) usage; exit 0 ;;
  --require-native|'') ;;
  *) usage >&2; exit 2 ;;
esac
command -v timeout >/dev/null || { printf 'GNU timeout is required.\n' >&2; exit 2; }

passed=0
failed=0
skipped=0
run_check() {
  local name=$1
  shift
  printf '\nRunning %s\n' "$name"
  local status=0
  timeout 180 "$@" || status=$?
  if (( status == 0 )); then
    printf 'PASS %s\n' "$name"
    passed=$((passed + 1))
  else
    printf 'FAIL %s (exit %s)\n' "$name" "$status" >&2
    failed=$((failed + 1))
  fi
}
skip_check() {
  printf 'SKIP %s (%s)\n' "$1" "$2"
  skipped=$((skipped + 1))
}

ucode_reason=""
if ! ucode -e 'require("fs");' >/dev/null 2>&1; then
  ucode_reason='ucode with the fs module is unavailable'
fi
xrust_reason=""
core="${FORKOP_XRUST_BIN:-$(command -v xrust || true)}"
if [[ -z "$core" ]] || ! core_version=$("$core" version 2>/dev/null) ||
   [[ "$core_version" != 'xrust version '* ]]; then
  xrust_reason='native Xrust is unavailable (set FORKOP_XRUST_BIN)'
  unset FORKOP_XRUST_BIN
else
  export FORKOP_XRUST_BIN="$core"
  printf 'Using %s\n' "${core_version%%$'\n'*}"
fi

export FORKOP_TEST_LIB="$LIB"
export PYTHONDONTWRITEBYTECODE=1
if [[ -n "$ucode_reason" ]]; then
  skip_check 'ucode source and bytecode compilation' "$ucode_reason"
else
  run_check 'ucode source and bytecode compilation' bash -o pipefail -c '
    find "$1" -name "*.uc" -print0 | xargs -0 -n1 ucode -c -o /dev/null &&
    find "$1" -name "*.uc" -print0 | xargs -0 -n1 ucode -S -c -o /dev/null
  ' _ "$LIB"
  for module in uci ubus; do
    if ! ucode -e "require(\"$module\");" >/dev/null 2>&1; then
      printf 'Ucode module %s unavailable. Local fixtures use mocks.\n' "$module"
    fi
  done
fi

while read -r dependency fixture; do
  reason=""
  [[ "$dependency" == shell ]] || reason="$ucode_reason"
  if [[ -z "$reason" ]]; then
    case "$dependency" in
      xrust) reason="$xrust_reason" ;;
      python)
        if ! command -v python3 >/dev/null || ! command -v curl >/dev/null; then
          reason='python3 and curl are required'
        fi ;;
    esac
  fi
  if [[ -n "$reason" ]]; then
    skip_check "tests/$fixture" "$reason"
    continue
  fi
  case "$fixture" in
    *.uc) run_check "tests/$fixture" ucode "$ROOT_DIR/tests/$fixture" "$LIB/components/action.uc" ;;
    *.py) run_check "tests/$fixture" python3 "$ROOT_DIR/tests/$fixture" ;;
    *) run_check "tests/$fixture" bash "$ROOT_DIR/tests/$fixture" ;;
  esac
done < <(local_fixtures)

printf '\nLocal backend fixtures: %s passed, %s failed, %s skipped.\n' "$passed" "$failed" "$skipped"
if [[ "${1:-}" == --require-native && ( -n "$ucode_reason" || -n "$xrust_reason" ) ]]; then
  exit 1
fi
(( failed == 0 ))
