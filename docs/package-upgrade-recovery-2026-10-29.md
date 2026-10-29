# Package upgrade recovery verification

Implemented in the existing Forkop dev checkout. No release was published and
the operator router was not modified. Existing VMware OpenWrt 25 was powered on
and used for package transactions. It remains running on the private test build
2.6.2-canary.999; the user requested that it not be restored after every run.

## Changes

- Cache preparation reconciles URLTest/Priority selection bindings before startup
  generation, including when the subscription feed is already current and no
  download is needed. Failure to persist required bindings blocks startup in
  the cache phase. Sections without filter descriptors need no binding write.
- The deferred Zapret Manager package worker uses the source library instead of
  inheriting the updater's disposable bytecode generation. It explicitly exports
  that library for nested module calls.
- Background component lock contention returns exit 75 without publishing an
  error or running transaction failure cleanup. The worker waits and retries.
  Interactive component actions retain their existing busy response.

## Verification

Existing OpenWrt 25 VM: 192.168.1.1, VMware x86/64, OpenWrt 25.12.5.
Original package/service/UCI/nft/DNS snapshots were captured before mutations.
Evidence remains on the VM in `/root/forkop-upgrade-review-20261029`.

The real component updater installed private APKs with native apk, actual
pre/post-upgrade hooks, bytecode rebuilding and procd service transitions.
Package catalog/download delivery was a local fixture. Native package indexes
were retained, and package transactions used apk offline mode: both curl and
apk/wget encountered external TLS EOF failures in this VM. The native unzip
dependency and the unmodified public Manager 4.71.1 installer were delivered
through the operator host. This verifies the package transaction and startup,
not live public-feed availability.

Confirmed cases:

1. Baseline 2.6.0 runs with a selected synthetic VLESS node bound to a domain.
   Runtime and persistent feeds then change only server to 192.0.2.10, while the
   saved private binding remains stale. The running baseline is preserved until
   the real update transaction stops it.
2. Upgrade to the candidate recovers the binding during startup, generates a
   nonempty URLTest group using the new IP, and restores DNS service.
3. Repeating the package update succeeds.
4. One intentionally rejected candidate start causes the updater to restore
   2.6.0, its service and working DNS. This expected failure is recorded as an
   error, not hidden by the fix.
5. With the actual public Manager installed, upgrade succeeds; deferred
   migration waits for the transaction and reports FORKOP_ZM_CHANGED=0. The
   successful-upgrade log contains no Forkop error/fatal, stale bytecode path,
   migration failure or repeated busy errors. Manager RPC health responds.
6. The final candidate was rebuilt after adding the no-filter-descriptor guard
   and installed through the updater again. The three changed installed backend
   files match dev SHA-256 values. The final successful transaction has zero
   Forkop error/fatal messages, and deferred Manager migration completed.

Additional passing checks:

- startup_filter_reconciliation.sh (cached-source reconciliation, persistence
  failure, unavailable feed, quiet busy retry)
- subscription_filter_selection.sh (45 checks plus generated selection/name
  fallback)
- urltest_empty_groups.sh and urltest_groups.sh
- subscription_runtime_readiness.sh and subscription_runtime_unchanged.sh
- bytecode_cache.sh
- zapret_manager_web.sh
- zapret_manager_migration.sh on native OpenWrt, including stale inherited
  FORKOP_LIB, busy retry, idempotence and installer/file rollback scenarios

No assertion is made that every system log is empty: the VM has unrelated
Tailscale connection failures, DNS-rebind warnings and external feed TLS failures.
No successful proxy transfer to the synthetic migration endpoint is expected;
the reserved test IP is deliberately not a live proxy.

## OpenWrt 24 / IPK reproduction and upgrade

Existing VMware OpenWrt 24.10.8 at 192.168.241.2 was also tested. Initial state
was Forkop 2.3.4-canary.2 and Rust X 0.0.27-9200. Package, service, UCI, nft and
configuration snapshots were saved before installing baseline Forkop 2.6.0.
The existing core was preserved.

On the real 2.6.0 backend, all three original failures were reproduced:

- A worker inheriting a deleted bytecode generation logged the missing
  `components/action.uc` file.
- A worker encountering a held component lock produced three busy error logs.
- A cached subscription changed from a domain to 192.0.2.10 with a stale selected
  binding; the original generator rejected URLTest group ms1 as empty.

The real component updater then installed all three candidate IPKs through
native opkg, including actual pre/post-upgrade hooks and service startup.
Startup recovered the binding, ms1 selected the IP, DNS answered, and Manager
RPC health succeeded. The patched worker was then given the same deleted
inherited library path and held component lock: it waited, retried and exited
successfully after lock release. The log segment from candidate update through
worker completion contained zero Forkop errors/fatals, missing bytecode errors,
migration failures or busy error messages.

All three installed packages are 2.6.2-canary.999; installed changed backend
files match the same dev SHA-256 values verified on VM25. VM24 was left running
on the candidate, without restoring original packages or configuration.
Evidence: `/root/forkop-upgrade-review24-20261029` on VM24.

Reproducible test: `tests/subscription_upgrade_ipk_vm.sh`. It uses a private
catalog and local delivery of unmodified public baseline packages, private
candidate packages and the public Manager installer. opkg index update is a
fixture using already available native indexes; package installation, hooks,
checksums, locks, bytecode resolution and procd transitions are real. No public
catalog, release or operator-router configuration was changed.
