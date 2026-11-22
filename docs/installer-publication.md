# Installer publication

`install.sh` is the shared installer. Stable is its default channel; canary
uses `--channel canary`. `canary-install.sh` downloads that same installer,
selects canary and forwards the remaining arguments. Do not maintain a
second copy of the installation implementation.

Use the shared installer to update older installations to Forkop X 3.0.3
or later. It first upgrades releases older than 2.7.6 to the signed 2.7.6
bridge. If the bridge needs Xrust, the installer runs 2.7.6's guarded
component switch to the legacy Xrust 0.0.44 build. It then prepares the boot
recovery journal and installs the selected Forkop release and its exact
native Xrust pin. A failed bridge core switch leaves the native upgrade
unstarted. If the native update is rolled back after a successful switch,
the recovery pair is Forkop X 2.7.6 and the working bridge Xrust.

An already installed `rust-x` package is updated through the newly installed
Forkop backend after the Forkop packages and configuration checks succeed,
before the installer restores the previous service state. This separate component
transaction validates the mirror package, checks space and stages exact rollback
packages and dependencies. A core-update failure returns a nonzero installer
status and leaves the successful Forkop update in place; the backend reports
whether core recovery succeeded. Other installed core variants are preserved.

If installed Forkop 3.x has a missing or incompatible Xrust executable, the
installer repairs that release in place. `--repair-xrust` explicitly selects
this mode and exits after the repair. An ordinary update resumes after a
successful repair. The repair compares the installed package and executable against the
archived pin and platform package revision, verifies and
installs the matching `rust-x`, then checks that Forkop starts. Repair keeps a
separate copy of the UCI file and stages the exact previous Xrust package for
rollback. Installations with a separate sing-box package or unmanaged core
require manual recovery.

The installer is unattended, including legacy migration and conflicting DNS
proxy handling. Legacy configuration is backed up before migration. A fresh
Forkop 2.0+ installation selects Sing-box X from the mirror; updates preserve
the installed variant. Pre-2.0 releases retain their supported Tiny action.
There is no low-space fallback to Tiny. The former `--allow-low-space-tiny`
and `--confirm-legacy-migration` flags are accepted as deprecated no-ops.

Both the installer and LuCI update use the same storage rule: measure the
extracted backend, UI and translation payloads; require the larger of the
new and exact rollback sets plus 256 KiB on flash. RAM is checked using the
smaller of free tmpfs space and Linux MemAvailable, with 8 MiB workspace.
Packages unpack directly to flash, so no additional payload copy is reserved
in RAM. Each download has a file-size limit based on this available budget.
Downloaded archives are not counted twice. Fresh X adds its measured packed payload and 256 KiB
on flash. APK producer Installed-Size is ignored in favour of file sizes;
IPK uses data.tar.gz. Dependencies are installed by the package manager,
without a guessed allowance per missing package. Installation failure keeps
the existing package/configuration rollback path.
Updates with the managed compressed core also check the actual binary/library
backup needed by older package hooks; this is additional RAM storage, not
another copy of the Forkop package payload.

On Openwrt-Mirror, keep the Git versions of both scripts in
`/usr/local/share/forkop/` and publish them to
`/srv/mirror/public/forkop/`. The existing `sync-forkop-mirror` service uses
`/usr/local/share/forkop/install.sh` as its installer override; updating only
the public copy can therefore revert a fix during the next synchronization.
The synchronization does not replace `canary-install.sh`.

After publishing, compare SHA-256 for the Git files, the override files and
both public HTTP endpoints. Run both scripts with `--help`, then rerun the
mirror synchronization and verify the hashes remain unchanged. Preserve
previous files before replacement. Installer-only changes do not require a
new package release; changes to packaged files do.

## Verification on 2026-10-02

- Both public scripts match the committed installer implementation and
  wrapper. Their `--help` invocations succeed.
- `forkop-mirror.service` completed successfully and preserved both scripts.
- Canary wrapper channel/argument forwarding and download failure handling,
  installer configuration backups and rollback checks passed.
- Published 1.15.1-canary.2 packages passed upgrade and repeat-install checks
  on existing OpenWrt 24/opkg and OpenWrt 25/APK VMware VMs. User settings
  were preserved; only the runtime `shutdown_correctly` marker is excluded
  from the in-test comparison. Original configuration is restored exactly.
- Public `canary.json`, `releases.json`, release manifest and all six package
  hashes agree with the downloaded GitHub release assets.
