#!/bin/sh
set -eu

FORKOP_LIB="${FORKOP_LIB:-$(CDPATH= cd -- "$(dirname -- "$0")/../forkop/files/usr/lib" && pwd)}"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

cat >"$work_dir/input.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "1.1.1.1", "service_listen_address": "127.0.0.1" },
  "section": [{
    ".name": "proxy", ".type": "section", "enabled": "1", "action": "connection",
    "outbound_jsons": [
      "{\"type\":\"direct\",\"tag\":\"proxy-out\"}",
      "{\"type\":\"direct\",\"tag\":\"second\"}"
    ],
    "urltest_enabled": "1", "domain_suffix": ["example.org"]
  }]
}
JSON

mkdir -p "$work_dir/output.json.section-cache" "$work_dir/output.json.rulesets"
ucode -L "$FORKOP_LIB" "$FORKOP_LIB/xrust/generator.uc" generate-config-fixture \
  "$work_dir/input.json" "$work_dir/output.json" "127.0.0.1" "0"

ucode -e '
let config = json(require("fs").readfile(ARGV[0]));
let by_tag = {};
for (let outbound in config.outbounds)
    by_tag[outbound.tag] = outbound;
if (by_tag["proxy-out-1"]?.type != "direct" || by_tag.second?.type != "direct")
    die("multiple JSON outbounds or conflicting tag rewrite failed\n");
if (by_tag["proxy-out"]?.type != "selector")
    die("Connection selector missing\n");
if (index(by_tag["proxy-out"].outbounds, "proxy-out-1") < 0 || index(by_tag["proxy-out"].outbounds, "second") < 0)
    die("JSON outbounds absent from Connection selector\n");
if (index(by_tag["proxy-urltest-out"].outbounds, "proxy-out-1") < 0 || index(by_tag["proxy-urltest-out"].outbounds, "second") < 0)
    die("JSON outbounds absent from URLTest\n");
' "$work_dir/output.json"

echo 'JSON outbound Connection: PASS'
