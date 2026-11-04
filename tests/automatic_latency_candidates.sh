#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RUNTIME="$ROOT/forkop/files/usr/lib/diagnostics/runtime.uc"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# URLTest performs its own interval checks, and Priority starts by probing its
# levels. The startup warm-up must retain only independent outbounds.
result="$(printf '%s' '{
  "proxies": {
    "main-selector": { "type": "selector", "all": ["standalone", "provider-urltest", "manual-urltest", "main-priority"] },
    "standalone": { "type": "vless" },
    "provider-urltest": { "type": "urltest", "all": ["provider-member"] },
    "provider-member": { "type": "vless" },
    "manual-urltest": { "type": "urltest", "all": ["manual-member"] },
    "manual-member": { "type": "trojan" },
    "priority-member": { "type": "shadowsocks" },
    "hidden-detour": { "type": "vless" },
    "direct": { "type": "direct" }
  },
  "priorityGroups": {
    "main-priority": {
      "levels": [
        { "outbounds": ["priority-member"] }
      ]
    }
  }
}' | ucode -L "$ROOT/forkop/files/usr/lib" "$RUNTIME" automatic-latency-proxy-tags-fixture)"

[ "$(printf '%s' "$result" | tr -d '[:space:]')" = '["standalone"]' ] ||
  fail "automatic latency must exclude URLTest and Priority members: $result"

grep -Fq 'automatic_latency_priority_groups()' "$RUNTIME" ||
  fail "automatic latency must read Priority members from the runtime cache"
grep -Fq 'lc(as_string(proxy.type || "")) != "urltest"' "$RUNTIME" ||
  fail "automatic latency must exclude provider URLTest members"

printf 'automatic latency candidate checks passed\n'
