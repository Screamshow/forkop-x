#!/bin/bash
# Execute the real nft candidate preparation with an unchanged restart plan.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIFECYCLE=${FORKOP_TEST_LIFECYCLE:-$ROOT/forkop/files/usr/lib/service/lifecycle.uc}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/candidate.uc" <<'UC'
const UPDATES_UC = "updates";
let events = [];
function log_message() {}
function nft_candidate_begin() { push(events, "begin"); return true; }
function nft_rebuild_runtime() { push(events, "rebuild"); return 0; }
function nft_candidate_finish(commit) { push(events, "discard"); }
function abort_reload(status, changed) { return status; }
function module_status(module, args) {
    if (module != UPDATES_UC || args[0] != "apply-list-cache") die("unexpected action");
    push(events, "cache");
    return int(ARGV[1]);
}
function prepare() {
    let plan = { needs_nft_rebuild: 1, needs_list_update: 0, changed_list: 0 };
    let nft_list_update_sources = int(ARGV[0]);
    let reason = "restart", status = 0, runtime_changed = false;
UC
awk '/^    if \(plan.needs_nft_rebuild == 1\)/ { active=1 } active && /        \/\/ Inline\/source-aware/ { exit } active { print }' "$LIFECYCLE" >> "$WORK/candidate.uc"
cat >> "$WORK/candidate.uc" <<'UC'
    }
    return 0;
}
let status = prepare();
print(join(",", events), " status=", status, "\n");
UC
[ "$(ucode "$WORK/candidate.uc" 1 0)" = 'begin,rebuild,cache status=0' ]
[ "$(ucode "$WORK/candidate.uc" 1 7)" = 'begin,rebuild,cache,discard status=7' ]
[ "$(ucode "$WORK/candidate.uc" 0 0)" = 'begin,rebuild status=0' ]
echo 'restart cache candidate checks passed'
