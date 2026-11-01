#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/forkop/files/usr/lib/service/lifecycle.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Exercise the production failure handler with controlled recovery outcomes.
cat > "$WORK/recovery.uc" <<'UC'
let calls = [];
let fs = { stat: function(path) { return {}; } };
let PRIORITY_UC = "priority", DNS_FAILOVER_UC = "dns";
let RELOAD_STATE_SNAPSHOT_FILE = "snapshot";
function nft_candidate_finish(commit) { push(calls, "discard-nft"); }
function discard_singbox_config_stage(path) {}
function finish_list_change_files(restore) { return getenv("CASE") != "lists-failed"; }
function restore_guarded_singbox_runtime(path, guard) {
    push(calls, "rollback"); return getenv("CASE") == "recovered";
}
function module_success(module, args) { push(calls, module); return true; }
function log_message(message, level) {}
function cleanup_failed_runtime() { push(calls, "direct-access"); }
function remove_file(path) {}
function abort_reload(status, changed) { push(calls, "abort"); return status || 1; }
UC
sed -n '/^function abort_guarded_transition(/,/^\/\/ The cold fallback/p' "$SOURCE" | sed '$d' >> "$WORK/recovery.uc"
cat >> "$WORK/recovery.uc" <<'UC'
let rc = abort_guarded_transition(7, "stage", "backup", true);
if (rc != 7) die("failure status lost\n");
let direct = index(calls, "direct-access") >= 0;
if (getenv("CASE") == "recovered") {
    if (direct || index(calls, "priority") < 0 || index(calls, "dns") < 0)
        die("successful rollback lost service or opened direct access\n");
} else if (!direct) die("unrecoverable failure left internet blocked\n");
UC
for scenario in recovered core-failed lists-failed; do
  CASE="$scenario" ucode "$WORK/recovery.uc"
done
echo 'restart transition recovery checks passed'
