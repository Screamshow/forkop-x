# Forkop X 2.6.3 dev — OpenWrt 25 verification, 2026-10-31

Target: existing VMware x86/64 VM at 192.168.1.1, OpenWrt 25.12.5. No operator/customer router or mirror was changed.

## Installed candidate

- Forkop, LuCI and Russian localization: 2.6.3, unpublished GitHub Actions test packages.
- Final build: https://github.com/Screamshow/forkop-x/actions/runs/41166594109, source `6ae1a713`, successful; publication disabled.
- Subsequent dev `f5e65554` changes only the historical VM test expectation to the new IPv6 prefix.
- Xrust 0.0.30-r1 x86_64 from the mirror. Catalog identity, URL, 3982112-byte size, SHA-256 and APK signature verified before installation.
- The original VM had no installed core binary. Forkop and the core were stopped; Forkop autostart was enabled.

Final APK SHA-256:

- forkop: `a995a13e9f5d8980145c02e4a8e718616ef6d8fa63e5bd0d14af3c43813c0b5d`
- luci-app-forkop: `4d8eb04cf3138f339b120ed7f3fba4d87a5c568e9c829b8f745ec70711b79af9`
- luci-i18n-forkop-ru: `c141c8cfc5ef665ef605f4907ad80016dd163837dcdb35963b55747b1c3f665a`

## Results

- Actual Xrust `check` accepted the working configuration.
- Live DNS: IPv4 `198.18.0.7`, IPv6 `2001:2::2` for the FakeIP control domain.
- Live service route explicitly selects direct-out and port 8443 for the FakeIP/direct-IP reference. The external check endpoint answered; response contents remain private on the VM.
- Generated live nftables includes `2001:2::/112` interception.
- An isolated IPv6 client transferred an HTTP response through Forkop-generated nftables and TPROXY, reverse FakeIP mapping, and the actual Xrust binary. All owned namespaces and processes were removed afterwards.
- Actual persistent-cache transition: the same test domain first received fc00::/18, then 2001:2::/112 after restarting the isolated core against the same database.
- Found and fixed an additional IPv6-only diagnostic bug: the previous detector recognized only the old prefix when A was absent. Actual installed backend passed compressed and expanded benchmark-prefix controls and rejected `2001:3::42`.
- Temporarily disabled both optional modules: live UI state omitted Tailscale and TorrServer Direct while the main services kept running. Restored both modules and exact pre-test UCI bytes.
- Forkop restart completed; Forkop, Xrust, native Tailscale and TorrServer Direct running afterwards. Tailscale state connected.
- Existing configuration preserved semantically except the runtime `settings.shutdown_correctly` flag.
- Local dashboard metrics command returns connection list, byte totals and memory. Browser over Tailscale remains the user's manual check.
- Served UI asset HTTP 200; LuCI returns its unauthenticated login response. rpcd/uhttpd running. Installed JS hash matches source after the expected compiled-version substitution; installed diagnostics source hash matches dev exactly.

## Baseline and operational notes

Restricted baseline and exact previous Forkop package rollback files remain on the VM in `/root/forkop-dev263-baseline`; private UCI, runtime config, connections and service-response contents were not downloaded or committed.

During the final same-version APK replacement, `apk --upgrade` also updated five dependency packages: rpcd, rpcd-mod-file, rpcd-mod-ucode, luci-base and ca-bundle. Final package inventory and services were captured. These dependency updates remain on the test VM.

VM left running for manual Tailscale dashboard verification. Release not published and main not changed. This does not claim general WAN IPv6 interoperability or browser validation through Tailscale.
