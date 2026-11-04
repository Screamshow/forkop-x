# Tailscale localization and Direct Proxy hot reload

Implemented on Forkop X dev and Xrust dev (2026-11-04).

Tailscale now uses English message IDs with Russian translations, including controls, connection paths, status, LAN/Exit Node help and historical native-worker events. Dates follow the browser locale. Simulated connected-state rendering passed in both languages.

Direct Proxy previously changed the inbound list, forcing a cold restart. Xrust now supports adding/removing the reserved mixed inbound direct-proxy-in. Bind happens before routing publication; bind failure preserves the running instance. Existing listeners remain active. Changing an existing Direct Proxy listener address/port still requires a cold restart. Other listener changes retain existing restrictions.

Verification: 15 hot-reload tests passed, including repeated enable/disable with live TCP, actual traffic through the new listener, listener removal and occupied-port refusal. Forkop frontend type check/build passed.

Installed locally on operator router 192.168.90.1. Core built from clean source 37e8b70a466efea32ce4b687b58079e4aa6d938a plus only the runtime/test patch, excluding pre-existing VLESS changes. This is a local patched Xrust 0.0.33, not a published release or package version update. Exact binary SHA-256: 6980cb3f0d46912d0281e461099d61e700fe5284ce01887d627d3b3a496bd776.

An isolated ARM fixture acknowledged both hot reloads, retained its PID, passed HTTPS via Direct Proxy and stopped accepting new connections after disable. Production services were unchanged during this fixture. Installation required one main-core restart. Subsequent actual Forkop component enable/disable preserved both PID and process start ticks; Direct Proxy HTTPS passed. Original disabled setting restored; UCI export and installed package list matched. Tailscale process state matched. DNS, HTTPS and Forkop/core runtime health passed afterward.

Exact previous binary and UI are retained privately on the router under /root/forkop-direct-proxy-hotfix-20261104. Local build manifest and patch: tmp/direct-proxy-hotfix-20261104. No private runtime configuration was downloaded. No public release, tag or mirror update was made.
