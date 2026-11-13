# DNS failover notifications, 2026-11-13

Base: Forkop dev fcb53f84. Supersedes the abandoned local change that restored
cold restart for automatic failover. That change and its test/report were removed.
Hot reload remains enabled for manual DNS edits and automatic failover.

Intermediate DNS apply, verification and rollback failures are logged as warnings,
not LuCI error notifications. Existing rollback checks, failure return codes,
backup retention and applied-state verification are unchanged. The worker emits
one error only after every configured main resolver fails for the configured
number of consecutive active checks (default three). A successful resolver resets
the counter; recovery is informational and a later confirmed outage can alert
again. Bootstrap failure alone stays a warning: an established main transport
can still work. Other unrelated Forkop errors are unchanged.

VM: existing VMware 192.168.1.1, OpenWrt 25.12.5 x86_64. Installed packages remained
Forkop 2.6.8 / Xrust 0.0.36. Candidate Forkop library ran from a temporary path;
the previously manifest-verified Xrust 0.0.40 binary was temporarily bind-mounted
for the tests. State/packages/services/nft and configuration were captured before
mutation. Customer/operator routers were not accessed.

Live tests used two local dnsmasq responders returning distinct A answers:

- Four candidate DNS switches passed, with unchanged core PID and correct answers.
- Actual worker with a one-second check interval, threshold three and test-only
  startup grace zero: primary stopped, automatic hot failover selected backup,
  backup answered, no error/fatal logs during the interval.
- Both responders stopped: exactly one error after confirmed complete outage,
  with no repeated error while unavailable.
- Backup restarted: informational recovery observed; total error count remained one.
- Forced runtime verification failure (test library only): hot apply failed,
  rollback restored the acknowledged configuration byte-for-byte, original DNS
  answered, PID stayed unchanged, intermediate diagnostics were warnings only.

Focused OpenWrt tests passed: dns_hot_failover.sh, dns_outage_notifications.sh,
dns_failover_startup_grace.sh, provider_dns_worker.sh. The notification contract
also verifies transient failure reset, deduplication and a new outage after
recovery. git diff --check passed. LuCI's existing isErrorLogLine() recognizes
[error]/[fatal]; these DNS warnings do not match its error notification predicate.
No frontend bundle changed.

Restoration verified: packages and Forkop UCI match; original wrapper/core restored;
DHCP matches excluding regenerated transaction ID; no test mount, DNS responder
or temporary cron entry remains. Original service running, final PID 3691, DNS
answers through its original fake-IP setup. Private snapshots remain on the VM;
temporary VM fixture removed. Sanitized logs/scripts are in operator workspace
tmp/dns-failover-20261112 (notifications.log, rollback-result.log, rollback.log,
recovered.log).

Limits: controlled UDP failure/recovery exercised the real worker. The customer's
intermittent Cloudflare DoH failure was not reproduced or diagnosed by this test.
Previous DoH checks passed, but were not rerun for this logging-only change.
No release, push or permanent VM package/source installation was performed.
