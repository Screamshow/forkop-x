# Subscription preview recovery and selected proxy downloads

Implemented locally on existing dev, base `36bad44f`, 14 November 2026.

Unchanged saved subscription sources now load the working section catalogue before attempting a network preview. Draft identity includes source settings, including the selected proxy section. New or changed sources do not inherit names from an unrelated saved catalogue. A delayed cache read or preview cannot replace the results for newer inputs. Returning to the saved sources invalidates pending draft state, so revisiting that draft starts a fresh request.

The editor delegates downloads to `subscription/cache.uc` instead of maintaining its own curl request. Preview shares the normal request profiles, device headers, HWID, bootstrap DNS and parser. Optional preview download parameters keep the private curl config, redirects restricted to HTTP/HTTPS, 20-second request limit and 4 MiB body limit. Existing callers retain their previous defaults. Preview does not publish persistent subscription caches or direct links and does not commit UCI or apply/restart the core.

Selected proxy downloads use the dedicated subscription mixed inbound and its section route from the active core configuration. They do not derive a possibly stale port from edited UCI order. A stopped core, missing inbound, wrong route or failed proxy returns an error without falling back directly. Explicit proxy requests disable curl NO_PROXY bypass. A newly selected target therefore needs its dedicated download listener already present in the running configuration; preview does not create it or apply draft configuration. The error explains that the selected section is unavailable.

## Verification

- `node tests/editor_preview.cjs`: passed, including unchanged saved source, failed changed target, revert, late reply and revisiting a discarded draft. The same test against original dev `36bad44f` fails with `[]` instead of `Old runtime`, proving the regression check detects the defect.
- `python3 tests/editor_preview_download.py` in Ubuntu WSL: passed with real curl and ucode. A loopback HTTP proxy serves a synthetic VLESS subscription for an unresolvable destination hostname. Checks include normal headers/HWID, private request mode, NO_PROXY bypass prevention, normal direct download, stopped/missing/empty/wrong target, HTTP failure without direct retry, and unchanged isolated UCI/runtime files. The full editor dispatcher and generator return the expected server name and remove their private temporary tree.
- `bash tests/subscription_bootstrap_dns.sh`: passed, including DNS fallback, IPv6, preserved TLS verification and secret-log controls for the existing downloader.
- `bash tests/urltest_groups.sh`, `node tests/luci_save_apply.cjs`, `node tests/subscription_any_provider.cjs`: passed. The provider validator ran in WSL after a Windows attempt found the installed esbuild is Linux-only.
- LuCI regenerated with the existing `compactLuCIAssets()` implementation; semantic AST checks and all `generated/source.sha256` checks passed. `git diff --check` passed.
- Independent focused re-review found no additional confirmed regression in the initial fix. The final discarded-draft state guard has its own passing regression case.

The initial checks used isolated local fixtures. No VM/router packages, real subscriptions, running router configuration, main branch, tags or releases were changed during those checks. Browser E2E and real provider/proxy interoperability were tested separately afterward, as described below.

## Subsequent live VM check

The user subsequently supplied a subscription and authorized testing on the existing OpenWrt 25 VM. Real direct and proxied preview, URLTest/Priority selection, saved catalogue availability with the selected proxy unavailable, and complete restoration passed. See [the sanitized VM report](subscription-preview-live-vm-2026-11-14.md). These later tests temporarily overlaid VM files and runtime configuration, with no package installation; original hashes, packages, PID, service and DNS recovery were verified. Initial browser caching required a temporary resource-path alias, which was restored afterward.
