# Subscription validation recovery — 2026-11-01

Implemented independently on Forkop dev, after evaluating slayer326 1.0.68. No source was copied from that release. This is core-driven recovery rather than another hardcoded XHTTP filter.

## Behavior

Generator records explicit subscription provenance in candidate section caches. Validation may remove only a node identified by a recognized structured configuration error and that provenance. Tags or protocol names alone never establish ownership. Source subscriptions remain intact. Dependent subscription detours and empty provider groups are removed recursively; manual dependencies, direct route/DNS references, an empty section selector or a direct-only fallback reject recovery. Remaining config must pass a fresh full core check before publication.

Recognized diagnostics: Rust X check paths outbounds[N].field and Sing-Box X FATAL initialize outbound[N]. Unknown diagnostic shapes and general configuration, file, runtime or network failures fail normally. This is not a promise to recover every possible core error.

Section metadata is prepared beside the candidate, moved with it, cleaned for removed nodes and published with the accepted config. Removed nodes and reason codes are surfaced on the dashboard, with Russian translations. Explicit cached configuration is preserved. Next generation retries the original source nodes, so updating the core can restore compatibility.

Successful hot plans stay hot. When older Xrust reports only a generic candidate-validation refusal and a candidate has proven subscription nodes, planning selects the existing guarded cold path. Only after the running core exits does the normal detailed check/recovery run. Manual-only hot candidates and non-validation errors retain their previous failure behavior. This does not start an additional eager core check beside the managed runtime.

## Verification

- subscription_recovery.uc: 21 controls on host and OpenWrt 25 VM. Covers ownership, copy-on-write, index bounds, detours, group/default repair, metadata, manual nodes/dependencies, route references, no empty/direct-only fallback, accepted/rejected cold fallback, network/binary error refusal and Go diagnostic shape.
- subscription_recovery.sh: real-core recovery with the new Rust X candidate and Sing-Box X 1.0.2 on WSL; real-core recovery with installed Rust X 0.0.32 and Sing-Box X on OpenWrt 25 VMware. Synthetic number / 4-8 node rejected before recovery, accepted config afterward, original subscription hashes unchanged. Additional host control confirms the same invalid config without provenance remains rejected and unchanged.
- tests/reality_xhttp.uc: 340 assertions passed after changes.
- tests/section_cache_rollback.sh passed.
- tests/rust_x_hot_reload.sh passed against a separately started test Xrust, using explicit FORKOP_LIB/FORKOP_SING_BOX_BIN. An initial invocation had incorrect shell environment and failed; rerunning through a script with explicit paths passed, including live ACK/refusal handling.
- Dashboard tests: 29 passed, including exposing skip warnings without adding phantom nodes.
- TypeScript, focused ESLint and tsup/LuCI generated build passed.
- VM packages, running PID set and installed configuration/core hashes matched before/after: summary SHA256 347d91f66a3f63cc14521fe99858fb82dcc837547d4b1fb3098bee5a647802f0.

## Remaining release checks

The broad tests/sing_box_runtime.sh fails at its existing assertion "provider group removes XHTTP member". The identical failure was reproduced in an isolated archive of pre-change commit 05aec522; it is not reported as a passing check. Investigate that baseline discrepancy before release acceptance.

No installed package/service replacement, operator router mutation, main integration, push, public release or PR closure was performed. Full on-device lifecycle acceptance of the packaged release and CI remain required; the VM checks above validate isolated candidate generation/check/recovery, not an installed-package upgrade or end-to-end guarded lifecycle transition.

## Follow-up acceptance

The broad runtime-test discrepancy and package lifecycle acceptance were resolved in [subscription-recovery-vm-acceptance-2026-11-01.md](subscription-recovery-vm-acceptance-2026-11-01.md). The group expectation was repaired with separate reachable/unreachable fixtures; the full runtime suite passes. Installed-package testing also found and fixed public CLI restart bypassing the initd transition lock. The expanded VM sequence passed after that fix, and original signed packages/configuration were restored as detailed in the report. CI and other platforms remain unverified.
