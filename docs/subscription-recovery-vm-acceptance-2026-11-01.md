# Packaged VM acceptance: subscription recovery and REALITY fixes — 2026-11-01

## Scope and candidates

Existing VMware OpenWrt 25.12.5 x86/64 at 192.168.1.1. No replacement VM or operator-router mutation. Forkop dev changes through fa573992 plus the CLI restart serialization change in this report; Rust X dev 595502d.

Built both IPK and APK Forkop artifacts using build.sh and the existing SDKs. VM installs used local, unpublished APK candidates 2.6.5-canary.900 and then 2.6.5-canary.901, with Rust X 0.0.32-r900 (the tested full-range validator fix). These are test identifiers, not published releases. Candidate packages were unsigned and allowed only on the integration VM.

Original signed rollback APKs: Forkop/LuCI/translations 2.6.4 and Rust X 0.0.32-r1. Exact downloaded asset sizes/SHA256 matched GitHub release metadata; all four APK signatures verified on the VM before mutation. Private UCI, service, nftables, installed-package/world and configuration snapshots remained restricted on the VM at /root/codex-recovery-acceptance-20261101.

## Findings and changes

1. The broad sing_box_runtime.sh failure was an obsolete expectation: when explicit URLTest/Priority groups select leaves, the unused provider group is correctly pruned by reachability. Added a separate provider-only fixture to exercise member filtering and default-field cleanup; retained an explicit assertion that custom-group scenarios prune unused provider groups. The entire script now passes.
2. Rapidly changing a manual/source configuration and issuing public `forkop restart` reproduced overlapping restart/reload transitions and ownership-guard refusal with candidate .900. Public CLI restart bypassed initd's transition lock. Route CLI restart to initd restart-service, and have that locked dispatcher invoke lifecycle directly (avoiding recursion). Rebuilt .901 and reran the same expanded sequence successfully without adding sleeps to hide the race.
3. ui_runtime_job.sh wrote a legacy PID-only package-owner marker despite the current PID/start-ticks contract. Replaced that test fixture with the production begin-package-upgrade-quiesce helper. The suite passes; no UI product behavior was changed for this test fix.

## Installed-package acceptance

Final expanded .901 cycle returned FINAL_RC=0 and ACCEPTANCE_CASES_PASSED, then restored the original packages. Verified:

- Candidate installation and cold start with a valid subscription.
- Real external HTTPS via the test section's mixed inbound: HTTP 200.
- Subscription update containing a bad number / 4-8 XHTTP node, dependent detour, valid node and provider group: bad/dependent excluded, two skip warnings in published cache, remaining group works, HTTPS 200.
- Corrected subscription source: skip warning disappears; valid update uses acknowledged Xrust hot reload with preserved core process (confirmed in runtime log).
- Valid Base62 / 4-8 node through the installed fixed Rust X: HTTPS 200.
- Manual link with the hyphenated support-x25519mlkem768=true alias, same user-authorized REALITY endpoint: HTTPS 200.
- Incompatible manual JSON outbound: reload returns failure; removal/restart recovers.
- Source containing only an incompatible node: update/apply returns failure, not a direct fallback; correcting the source recovers, final HTTPS 200.
- Package downgrade/rollback through actual package hooks.

The fixture used one HTTPS source URL mapped by a narrowly scoped test curl wrapper to a local file. Production curl calls and the actual HTTPS/REALITY traffic were not weakened. Early fixture attempts using plain HTTP were rejected by the validator; a local HTTP fixture attempt also failed. Those are not recorded as product passes. Test source credentials and bodies were not committed.

## Focused verification

- sing_box_runtime.sh: PASS after repairing the fixture contract.
- package_contract.sh: PASS.
- manual_restart_contract.sh: PASS.
- ui_runtime_job.sh: PASS with current process-identity fixture and explicit host library environment.
- runtime_dir_lock.sh: PASS.
- Earlier unchanged recovery implementation checks: 21 recovery controls on VM, real-core recovery on Rust X and Sing-Box X, 340 REALITY/XHTTP assertions, section-cache rollback, live hot-reload ACK/refusal, 29 frontend tests, TypeScript/lint/build passed. Rust validator's 205 focused tests/Clippy/release build previously passed; the built candidate was installed and exercised here.

## Restoration

Original package inventory and apk world match the snapshot. Forkop, DHCP and firewall UCI files, plus installed Rust X binary, match their original SHA256 values. Final installed versions are Forkop/LuCI/translations 2.6.4 and Rust X 0.0.32-r1. Core configuration check and forkop-stably-running passed, DNS resolves through local dnsmasq, and the original fw4/ForkopTable/native-tailscale tables are present. No test section or listeners on 19591/19816 remain; test subscription cache files were removed.

The regenerated active JSON differs only in ordering of one group's members. After normalizing member order it equals the original JSON exactly: same 60 outbounds, zero added/removed tags. This is not reported as byte-identical generated-config restoration.

## Limits

This is installed-package acceptance on the existing OpenWrt 25 x86 VM, not OpenWrt 24/ARM/MIPS or all-platform CI. It verifies one real Chrome/auto XHTTP REALITY endpoint, not universal REALITY/PQ interoperability or timing camouflage. New diagnostics outside the recognized structured core-error shapes still fail normally. No push, main integration, public release, mirror sync or operator-router installation was performed.
