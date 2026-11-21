# Signed releases in one command

Run on the operator computer from the Forkop main checkout with Python 3,
authenticated `gh`, OpenSSH and access to the existing mirror. The SSH key
defaults to `~/.ssh/codex_forkop_mt6000`. The private APK signing key stays on
the mirror; neither private key is uploaded to GitHub Actions.

```powershell
python scripts/release.py --forkop 2.2.3-canary.1
python scripts/release.py --rust 0.0.8
python scripts/release.py --forkop 2.2.3-canary.1 --rust 0.0.8
```

These are example **new** versions. For Rust X first prepare and push the
workspace version, Cargo.lock and release notes on its existing main branch.
Keep its checkout at `artifacts/xrust`. The command checks the GitHub
main version before it creates a tag. Forkop accepts `x.y.z` and
`x.y.z-canary.N`; its package version is set by the build workflow.

The command checks prerequisites, starts a release workflow, waits for the
exact source commit to build successfully and signs APK on the existing
mirror. It validates package identities and hashes, checks signatures
against the mirror's trusted public key, uploads the signed files to the
draft and verifies their GitHub sizes/digests before publishing. IPK remains
unchanged and is verified by SHA-256. Forkop APK uses `noarch` and maps
`-canary.N` to `_rcN`; IPK retains the public version and architecture `all`.

Forkop's workflow now leaves a draft, including when triggered by a tag.
It no longer exposes unsigned packages as a public release. Rust X already
uses this draft gate. Use the operator command for both projects; no GitHub
signing secret or self-hosted runner is required. Forkop releases include
`forkop-manifest.json`, `forkop-apk.pem` and `SHA256SUMS`; Rust X retains its
existing `openwrt-manifest.json` format.

For a new Forkop 3.x release, pass `--xrust-version VERSION` if that exact
Xrust version is already signed, published and mirrored. When publishing both
projects, pass `--forkop FORKOP_VERSION --rust XRUST_VERSION`. The command
publishes and verifies the versioned Xrust archive first and uses its version
as the Forkop pin. The paired release leaves Xrust's standalone latest pointers
on GitHub and the mirror where they are. Forkop 2.7.6 still uses the mirror's
`rust-x/latest.json` for default installation and automatic core updates.
Each Forkop release keeps the pin in `forkop-manifest.json`. A resumed
public release uses its existing pin. The release command verifies that the
public GitHub release and exact Xrust mirror archive describe the same packages.

Before the first 3.x publication, deploy the mirror scripts from this
checkout. The release command checks the installed publisher and catalog
writer before starting the build.

| Checkout | Mirror |
| --- | --- |
| `mirror/publish-forkop-feed` | `/usr/local/sbin/publish-forkop-feed` |
| `mirror/sync-forkop-canary` | `/usr/local/sbin/sync-forkop-canary` |
| `scripts/write-channel-manifest.sh` | `/usr/local/lib/forkop/write-channel-manifest.sh` |
| `scripts/write-release-catalog.py` | `/usr/local/lib/forkop/write-release-catalog.py` |

Both publishers validate and include `xrust_version` in the staged
`release.json` before moving the channel pointer. Canary verifies the
manifest's GitHub size and digest before reading it. After publishing,
compare the exact pin in the channel pointer, archived manifest and release
catalog. Keep all published 2.x and Xrust archives for rollback.

Forkop 2.7.6 upgrades to 3.x with Xrust already installed. If 2.7.6 uses
sing-box, select Xrust there and verify it starts before upgrading. The 3.x
installer stages the pinned package for clean installations. The normal
Forkop update and version selector install the pinned core for the chosen 3.x
release. These core archives declare `minimum_forkop_major: 3`, and the
`rust-x/releases.json` selector for 2.x excludes them. Forkop 3.x uses
`/usr/bin/xrust`, which reports `xrust version VERSION`. During the
2.7.6 upgrade, the old backend installs the core first and runs
`/usr/bin/sing-box version` before replacing itself. The 3.x Xrust package
carries a version-only command for that handoff. A downgrade from 3.x to 2.x
stages the archived Xrust 0.0.44 runtime and restores it before the 2.x
backend is installed.

Forkop 3.x stages the exact previous package set and a copy of its UCI
configuration on flash before replacing packages. If power is lost during
the update, an early boot hook checks the saved archives and restores the
previous set. The shared installer also prepares this recovery set before
delegating a 2.7.6 → 3.x update to the 2.7.6 backend. For that transition, use
the shared installer to enable boot recovery. The legacy 2.7.6 LuCI updater
keeps its original rollback behavior.

Stable 3.x packages are published to the updater and its version selector.
The combined `mirror/current` APK feed keeps its last compatible 2.x release
because a system-wide APK upgrade cannot coordinate Forkop's exact Xrust pin.
Both 3.x channel publishers verify the six Forkop packages and the referenced
native Xrust archive before activating their pointers.

After publication the command runs the existing canary mirror service,
publishes the signed stable packages through the existing feed publisher,
or publishes Rust X's signed directory. It downloads the public packages and
checks catalogs, archived manifests and hashes. The mirror's anonymous
GitHub cache may delay canary selection; synchronization retries within the
timeout. The default timeout is 1800 seconds. Signed output is retained in
`artifacts/signed-releases`.

Rust X publication also rebuilds `/forkop/rust-x/releases.json` from archived
`releases/*/manifest.json`. The schema-1 catalog contains `name: rust-x` and
`releases`, sorted by numeric version descending. Each entry includes `version`,
`manifest_url`, `architectures`, `formats`, and verified `assets` with package
identity, size, SHA-256 and mirror URL. Clients should select an asset matching
both architecture and format. Invalid archives are logged and excluded; an empty
result preserves the previous catalog. Catalog and pointer writes are atomic.
To rebuild only the catalog on the mirror, without moving latest:

```sh
python3 publish-rust-x.py /srv/mirror/public/forkop/rust-x /srv/mirror/public/forkop/rust-x --catalog-only
```

Verified on 2026-10-26: the updated publisher was installed at
`/usr/local/lib/forkop/publish-rust-x.py` on the existing mirror. Catalog-only
rebuilding verified all 25 archived releases (100 packages). The public catalog
returned HTTP 200 with 0.0.26 and 0.0.25 first; latest.json retained SHA-256
`73ce1add42338233a492eede02c66998d04538e09dc867adef290344d9103fad`.
All 23 tests in `scripts/tests` passed, including five catalog tests.
The operator release command uploads the publisher from its own checkout, so
future publications use this publisher after integration into main.

If signing, uploading or synchronization was interrupted:

```powershell
python scripts/release.py --forkop 2.2.3-canary.1 --resume
python scripts/release.py --rust 0.0.8 --resume
```

A draft can be finalized on retry. An already public signed release can only
be downloaded, verified and synchronized; its assets are never replaced.
Older unsigned Forkop releases cannot be converted using `--resume` because
their mirror archives and hashes are immutable. Publish a new version.
Do not resume an old release to move a channel pointer backward.

Install/update compatibility is retained: the existing installer and LuCI
paths can install signed APK as well as historical unsigned rollback APK.
This change does not remove `--allow-untrusted` from legacy installation or
rollback paths. It adds publisher signatures and enforces them during release
publication, without changing the existing client trust policy.

The mirror's stable Git updater uses `sync-signed-forkop-stable.py` for releases
containing `forkop-manifest.json`, preserving the exact GitHub package bytes.
Older releases retain their existing rebuild path. The operator publisher and
the timer share `/run/lock/forkop-git-build.lock`; the signed publisher checks
existing archive hashes before calling the feed publisher. Deploy the three
Python files from `mirror/` (`sign-forkop-release.py`, `publish-forkop-stable.py`,
`sync-signed-forkop-stable.py`) to `/usr/local/lib/forkop/` and the updater to
`/usr/local/sbin/update-forkop-from-git`. Preserve the previous updater first.

Verification:

```powershell
python -m unittest discover -s scripts/tests -p test_signed_release.py
```

Verified on 2026-10-11: 14 focused tests passed. Copies of all six real
2.2.2-canary.1 packages were checked and the three APK were signed on the
existing mirror. Re-running the signer preserved all three APK hashes.
The unified `--rust 0.0.7 --resume` command completed signature verification,
mirror synchronization and public checks for all four packages. No public
Forkop 2.2.2 assets were replaced and no new release was published for testing.
The stable updater and helpers were deployed with matching SHA-256 values;
the previous updater is retained as
`/usr/local/sbin/update-forkop-from-git.before-signed-20261011`. Stable feed
publication and conflict refusal were tested with isolated fixtures; a new
stable production release was not issued as part of this change.
