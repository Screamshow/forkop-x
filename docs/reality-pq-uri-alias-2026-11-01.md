# REALITY hyphenated PQ URI alias — 2026-11-01

Forkop dev: support support-x25519mlkem768 alongside support_x25519mlkem768 and supportX25519MLKEM768 in both subscription parser and manual URI generator. Existing canonical/camelCase precedence is preserved. Cache repair reuses the parser and recovers missing preferences from retained share links while preserving explicit cached settings. Export remains canonical.

The user-reported endpoint worked on published Rust X 0.0.30 but failed with 0.0.32 when the hyphenated preference was lost. Isolated VM tests confirmed current core succeeds with explicit true. No changes to core PQ defaults or authentication were made.

Validation: tests/reality_xhttp.uc passed 340 assertions on WSL ucode and OpenWrt 25 VMware (192.168.1.1). Tests cover all three aliases, true/false import and manual generation, cache recovery, preservation of explicit cached values and precedence. Fresh import through patched manual generator produced explicit true; isolated SOCKS client using installed Rust X 0.0.32 completed HTTPS api.github.com/zen with HTTP 200 (19 bytes). Real endpoint credentials omitted from this report and commits.

VM package/PID/config/binary summary hashes matched before and after: 347d91f66a3f63cc14521fe99858fb82dcc837547d4b1fb3098bee5a647802f0. Working packages, services and config were not replaced. Operator router settings were not changed. Existing manual entries require reimport if only the generated outbound, without original share link, was retained.

Separate Rust X change fixes XHTTP session ID range validation. General removal of invalid subscription nodes, PR #15 disposition and releases are outside these implementation commits.
