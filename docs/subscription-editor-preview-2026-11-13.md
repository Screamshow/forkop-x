# Draft subscription catalogue preview

Local dev preview, installed as a file overlay on the existing VMware OpenWrt
25.12.5 VM, 192.168.1.1. No release published and no customer installation.

The editor downloads draft subscription sources after an 800 ms input pause.
There is no manual load button. A request file with mode 0600 carries the
sources to `forkop editor_preview`; subscription URLs are not command arguments.
Downloads and generator fixtures live in a private temporary directory and are
removed after completion. Neither UCI nor the live core is applied.

The existing parser and generator supply compatibility filtering, naming,
provider group handling and duplicate handling. The generator fixture has no
user URLTest or Priority groups, so an empty draft filter cannot block the
catalogue. Both editors use the returned names. Late responses cannot overwrite
a catalogue requested for a newer source list.

## Verification

- VM backend downloaded and normalized a synthetic two-node VLESS subscription;
  both names were returned without an active configuration for the draft section.
- Actual LuCI: created an unsaved section, loaded the fixture, opened URLTest
  with include filtering and a Priority level: both offered VM Germany and VM
  Netherlands. Screenshots are in workspace tmp/editor-preview-urltest.png and
  tmp/editor-preview-priority.png.
- Browser test used a temporary exception for the loopback HTTP fixture only;
  that exception and fixture were removed. Installed preview retains HTTPS-only
  validation. Live HTTPS-provider behaviour still needs interactive evaluation.
- Node test `node tests/editor_preview.cjs` covers draft without runtime,
  reversed completion order after URL change, source removal, failure and retry.
- JavaScript syntax and git diff whitespace checks passed.
- Live UCI and DHCP matched backups, runtime config SHA-256 matched, service
  stayed running; no core restart was used.

VM installed files were newer than this local checkout. Deployment therefore
preserves the VM's original CLI and section module and injects only the preview
changes. Rollback files, package/service/nft snapshots are kept privately at
/root/forkop-editor-preview-20261113 on the VM. No version bump/package build.

## Prototype limits before a release

The catalogue currently stays in browser memory; ordinary Apply still uses
the normal subscription preparation/download path. Provider User-Agent/HWID
fallback negotiation is not yet unified with the updater; the preview now
obtains the primary INCY User-Agent, stable HWID and device headers from the
updater's `editor-request-profile` helper. Preview through another proxy section is explicitly
rejected rather than silently downloading directly. Multiple slow sources can
exceed the LuCI request deadline; durable asynchronous jobs and concurrency
limits remain release work. This is a VM evaluation build, not a production fix.

## Real-provider follow-up

The supplied Flintnet subscription exposed two distinct issues. VM UDP DNS,
including apparent external-server queries, returned FakeIP for the provider;
curl failed with TLS status 35. Switching only the VM DNS to DoH at 1.1.1.1
restored real resolution. The UCI, DHCP and service baseline before that change
is in the private VM backup directory (`before-doh.*`). DoH remains selected
for interactive testing; this was not applied to any customer or operator router.

The next response was a single VLESS placeholder named “This application is not
supported” (Russian text), not a real catalogue. Merely counting parsed nodes was
insufficient evidence. Both bare sing-box and INCY without device headers got
the placeholder. Preview now shares the updater's primary request identity and
device headers. Two independent preview requests (source and regular dispatcher)
returned 22 candidates, zero unsupported-application placeholders. Runtime/UCI
hashes stayed unchanged during this profile correction; the service stayed running.
Provider credentials and raw responses were not included in this report.
