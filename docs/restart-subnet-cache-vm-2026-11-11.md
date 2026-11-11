# Restart subnet cache regression — 2026-11-11

Adapted slayer326/forkop 8de8c1fd (1.0.84) to Forkop X dev.
The cold restart override runs after reload planning, so unchanged signatures
leave needs_list_update=0 while needs_nft_rebuild is forced to 1. Replay must
therefore depend on has-nft-list-update-sources, not the old planner flag.
Our lifecycle has no validate_manual_restart_candidate helper; the common
checked nft candidate path handles this case and retains its abort behavior.

## Existing OpenWrt 25 VMware VM, 192.168.1.1

VM was initially powered off and was started for the requested test. Captured
package inventory, service state, UCI/lifecycle hashes and nft rules on the VM.
Private snapshots stay at /root/restart-cache-20261111 on that VM.
No package or core change. Temporary block section cache_repro loaded the local
HTTP list http://127.0.0.1/restart-cache-20261111.txt (203.0.113.0/24).

- Before restart: section nft subnet set contained 203.0.113.0/24.
- Original CLI forkop restart returned 0 but removed that section set element.
  The unrelated localv4 exclusion set still contained the documentation subnet;
  the assertion concerns the section-specific set, not a whole-ruleset grep.
- Applied only the replay predicate change to installed lifecycle.
- forkop reload list-content repopulated the section set.
- Fixed forkop restart returned 0 and preserved the section set element.
- tests/restart_cache_candidate.sh failed on original lifecycle (exit 1),
  passed on fixed lifecycle (exit 0). This executes extracted real preparation
  code with controlled module calls: replay success, replay failure/discard,
  and no downloaded subnet sources. Failure injection is a unit fixture,
  not an actual corrupt-cache lifecycle integration test.

Restored original UCI and lifecycle, removed the HTTP fixture, reloaded Forkop.
Original Forkop UCI, DHCP and lifecycle SHA-256 matched; package inventories
matched; init service remained enabled and Rust X process was running.
The VM remains running. No operator/customer router was changed.

This verifies actual nft set preservation, not end-to-end Telegram traffic.
No package build/publication or full compatibility suite was performed.
Pre-existing dev worktree changes were preserved; the worktree could not be
fast-forwarded due to those changes. The replay condition was also reviewed
against current origin/dev d84926ba, where the same defect remains.

## Synchronized dev and expanded VM checks

Local dev was fast-forwarded from 740e6314 to origin/dev d84926ba (22 commits).
The pre-sync patch and overwritten untracked monitoring sources were saved in
workspace tmp/dev-sync-20261111; stash "Preserve local dev work before
2026-11-11 sync" was retained. Conflicting old monitoring/diagnostic/bundle
implementations were superseded by current GitHub implementations, rather
than reintroducing obsolete variants. Other historical untracked files remain.

The new regression test is now explicitly included by .gitignore. The existing
list_update_reload_policy textual assertion was updated for the already-present
for_restart branch of ruleset_cache.uc; backend behavior was not changed there.

On the same OpenWrt 25 VM, tested the synchronized lifecycle with supporting
source modules staged from synchronized dev. Installed VM supporting modules
were retained. State captured before mutations; test script restores original
UCI and lifecycle on exit. All packages and the original core were retained.

Actual list sources: built-in Telegram IPv4 149.154.160.0/20 and IPv6
2001:b28:f23d::/48 (URLs overridden to VM-local HTTP fixtures), external plain
IP list 203.0.113.0/24, JSON source ruleset 198.51.100.0/24. All were placed in
the same temporary block section; checks examine section-specific nft sets.

Passed:
- restart_cache_candidate.sh (real extracted candidate preparation).
- manual_restart_contract.sh (LuCI dispatch to manual_restart).
- restart_transition_recovery.sh (controlled failure-handler outcomes).
- list_update_reload_policy.sh with synchronized source library.
- Actual CLI restart preserves all four subnet entries.
- Actual manual_restart backend used by LuCI preserves all four entries.
- Missing-cache actual restart is rejected with status 1; static live table
  and core PID are unchanged.

The system filesystem had insufficient room for a duplicate source tree;
removed only the incomplete test-owned copy and used /tmp for the checks.
The first JSON fixture used .txt and was rejected during source preflight;
corrected its URL to .json before counting integration results.
No package build or publication, browser click, actual Telegram traffic,
or OpenWrt 24 matrix is claimed by this targeted test.

Final repeated series additionally passed:
- Malformed runtime manifest with unavailable persistent fallback: actual restart
  returns 1; static live table and core PID remain unchanged.
- Removed all VM-local HTTP fixture files: CLI restart succeeds from validated
  cache and retains all four subnet entries offline.
- Final restoration: byte comparisons of original UCI, DHCP and lifecycle;
  package inventory equality; enabled service, running Rust X and DNS query.

VM script: workspace tmp/dev-sync-20261111/vm-check.sh (historical paths; inspect
before reuse). Private captures/logs remain on VM in
/tmp/restart-cache-sync-20261111 and are ephemeral. Earlier baseline evidence
remains /root/restart-cache-20261111. VM remains running as it was at the start
of this continuation. Git main and remote branches were not changed.
