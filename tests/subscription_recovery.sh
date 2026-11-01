#!/bin/bash
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE=$(readlink -f "${FORKOP_TEST_SING_BOX:?Set FORKOP_TEST_SING_BOX to a test core binary}")


W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT HUP INT TERM
mkdir -p "$W/bin" "$W/subs"
ln -s "$CORE" "$W/bin/sing-box"

export PATH="$W/bin:$PATH"
export FORKOP_LIB="$ROOT/forkop/files/usr/lib" FORKOP_RUNTIME_STATE_DIR="$W/state" TMP_SUBSCRIPTION_FOLDER="$W/subs" FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$W/persistent" TMP_SING_BOX_FOLDER="$W/box" TMP_RULESET_FOLDER="$W/rules"
cat > "$W/subs/probe-subscription-1.json" <<'JSON'
{"outbounds":[{"type":"vless","tag":"good","server":"127.0.0.1","server_port":19443,"uuid":"00000000-0000-4000-8000-000000000001"},{"type":"vless","tag":"bad","server":"127.0.0.1","server_port":19444,"uuid":"00000000-0000-4000-8000-000000000002","transport":{"type":"xhttp","session_id_table":"number","session_id_length":"4-8"}}]}
JSON
printf 'https://feed.example/test' > "$W/subs/probe-subscription-1.url"
printf 'Happ' > "$W/subs/probe-subscription-1.user_agent"
printf '' > "$W/subs/probe-subscription-1.hwid"
cat > "$W/fixture.json" <<'JSON'
{ "settings": { ".name": "settings", ".type": "settings", "dns_server": "1.1.1.1" }, "section": [ { ".name": "probe", ".type": "section", "enabled": "1", "action": "connection", "subscription_urls": [ "https://feed.example/test" ], "subscription_url_settings": "{\"https://feed.example/test\":{\"user_agent\":\"Happ\"}}" } ] }
JSON
ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/generator.uc" generate-config-fixture "$W/fixture.json" "$W/candidate.json" 127.0.0.1 0 1 '' 1.14.2-rust-x.0.0.32
if sing-box check -c "$W/candidate.json"; then echo 'expected invalid input' >&2; exit 1; fi
# The same rejected outbound without subscription provenance must not be dropped.
cp "$W/candidate.json" "$W/manual.json"
mkdir -p "$W/manual.json.section-cache"
printf '{}' > "$W/manual.json.section-cache/probe.json"
sha256sum "$W/manual.json" > "$W/manual.before"
if ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/runtime.uc" validate-config-stage "$W/manual.json"; then
    echo 'manual node silently removed' >&2; exit 1
fi
sha256sum "$W/manual.json" > "$W/manual.after"
cmp "$W/manual.before" "$W/manual.after"
sha256sum "$W/subs/probe-subscription-1.json" > "$W/source.before"
ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/runtime.uc" validate-config-stage "$W/candidate.json"
sing-box check -c "$W/candidate.json"
sha256sum "$W/subs/probe-subscription-1.json" > "$W/source.after"
cmp "$W/source.before" "$W/source.after"
ucode -e 'let fs=require("fs");let c=json(fs.readfile(ARGV[0]));for(let o in c.outbounds)if(o.server_port==19444)die("bad node retained");let s=json(fs.readfile(ARGV[0]+".section-cache/probe.json"));if(length(s.skippedSubscriptionOutbounds)!=1)die("missing warning");print("Real-core recovery and source preservation passed\n");' "$W/candidate.json"

