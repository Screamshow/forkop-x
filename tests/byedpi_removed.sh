#!/bin/sh
# ByeDPI is removed from Forkop X; user SOCKS connections stay supported.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB=${FORKOP_LIB:-$ROOT/forkop/files/usr/lib}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

[ ! -e "$LIB/providers/byedpi" ] || fail "ByeDPI provider module is still installed"

# Runtime code, LuCI views (handwritten, bundled and compacted), frontend
# sources and translations must not mention ByeDPI or its ciadpi binary.
# The configuration migration is the only exception: it cleans up what
# ByeDPI left behind, and may name it only inside that cleanup.
if grep -rIil --exclude=migration.uc 'byedpi\|ciadpi' \
    "$ROOT/forkop/files" \
    "$ROOT/luci-app-forkop/htdocs" \
    "$ROOT/luci-app-forkop/generated" \
    "$ROOT/luci-app-forkop/po" \
    "$ROOT/fe-app-forkop/src" \
    "$ROOT/fe-app-forkop/locales" >"$WORK/hits"; then
    cat "$WORK/hits" >&2
    fail "ByeDPI references remain"
fi
awk '
  /^\/\/ ByeDPI support was removed|^\/\/ PID, log and state files of the removed ByeDPI/ { cleanup = 1 }
  /^    migrate_retired_byedpi\(ctx\);$|^    remove_retired_byedpi_state\(\);$/ { next }
  !cleanup && tolower($0) ~ /byedpi|ciadpi/ { print FILENAME ":" NR ": " $0; bad = 1 }
  cleanup && /^}$/ { cleanup = 0 }
  END { exit bad }
' "$LIB/config/migration.uc" || fail "ByeDPI is referenced outside the migration cleanup"
echo 'No ByeDPI references in runtime, LuCI, frontend or translations'

# Upgrades clean up ByeDPI rules and options instead of failing validation.
cat >"$WORK/byedpi.json" <<'JSON'
{"settings":{"download_lists_via_proxy":"1","download_lists_via_proxy_section":"dpi",
  "download_components_via_proxy":"1"},
 "section":[
  {".name":"dpi",".type":"section","enabled":"1","action":"byedpi","byedpi_cmd_opts":"-o 2 -d 2",
   "community_lists":["youtube"]},
  {".name":"was_dpi",".type":"section","enabled":"1","action":"block","byedpi_cmd_opts":"-d 1"},
  {".name":"vpn",".type":"section","enabled":"1","action":"connection"}],
 "subscription_url":[
  {".name":"sub1",".type":"subscription_url","section":"vpn","value":"https://sub.test/a",
   "download_via_proxy_enabled":"1","download_via_proxy_section":"dpi"},
  {".name":"sub2",".type":"subscription_url","section":"vpn","value":"https://sub.test/b",
   "download_via_proxy_enabled":"1","download_via_proxy_section":"vpn"}]}
JSON
FORKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/config/migration.uc" migrate-fixture "$WORK/byedpi.json" >"$WORK/migrated.json"
ucode -e '
let fs = require("fs");
let r = json(fs.readfile(ARGV[0])), c = r.config, s = {}, sub = {};
for (let x in c.section) s[x[".name"]] = x;
for (let x in c.subscription_url) sub[x[".name"]] = x;
assert(s.dpi.enabled == "0" && s.dpi.action == "bypass", "ByeDPI rule is not disabled as a direct rule");
assert(s.dpi.byedpi_cmd_opts == null, "ByeDPI strategy kept");
assert(length(s.dpi.community_lists) == 1, "ByeDPI rule lost its lists");
assert(s.was_dpi.action == "block" && s.was_dpi.enabled == "1" && s.was_dpi.byedpi_cmd_opts == null, "stale strategy on another rule");
assert(c.settings.download_lists_via_proxy == "0" && c.settings.download_lists_via_proxy_section == null, "lists still download through the ByeDPI rule");
assert(c.settings.download_components_via_proxy == "0", "components still fall back to the ByeDPI rule");
assert(sub.sub1.download_via_proxy_enabled == "0" && sub.sub1.download_via_proxy_section == null, "subscription still downloads through the ByeDPI rule");
assert(sub.sub2.download_via_proxy_enabled == "1" && sub.sub2.download_via_proxy_section == "vpn", "unrelated subscription changed");
fs.writefile(ARGV[1], sprintf("%J", c));
' "$WORK/migrated.json" "$WORK/again.json" || fail "ByeDPI configuration was not cleaned up"
FORKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/config/migration.uc" migrate-fixture "$WORK/again.json" >"$WORK/repeat.json"
ucode -e 'let r = json(require("fs").readfile(ARGV[0])); assert(!r.changed && length(r.operations) == 0, "cleanup is not idempotent");' "$WORK/repeat.json" ||
  fail "ByeDPI cleanup changes an already clean configuration"

# A section with its own components download target keeps it.
cat >"$WORK/own.json" <<'JSON'
{"settings":{"download_lists_via_proxy":"1","download_lists_via_proxy_section":"dpi",
  "download_components_via_proxy":"1","download_components_via_proxy_section":"vpn"},
 "section":[{".name":"dpi",".type":"section","enabled":"1","action":"byedpi"},
  {".name":"vpn",".type":"section","enabled":"1","action":"connection"}]}
JSON
FORKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/config/migration.uc" migrate-fixture "$WORK/own.json" >"$WORK/own-out.json"
ucode -e '
let c = json(require("fs").readfile(ARGV[0])).config;
assert(c.settings.download_lists_via_proxy == "0", "lists download through the ByeDPI rule");
assert(c.settings.download_components_via_proxy == "1" && c.settings.download_components_via_proxy_section == "vpn", "own components target lost");
' "$WORK/own-out.json" || fail "ByeDPI cleanup touched an unrelated download target"
echo 'Upgrades disable ByeDPI rules and clear their strategy and download references'

# Manual SOCKS links and SOCKS JSON outbounds still generate socks outbounds.
cat >"$WORK/fixture.json" <<'JSON'
{"settings":{".name":"settings",".type":"settings","dns_server":"1.1.1.1"},
 "section":[{".name":"socksrule",".type":"section","enabled":"1","action":"connection",
  "selector_proxy_links":["socks5://user:pw@127.0.0.1:1080#Manual%20SOCKS","socks4://127.0.0.1:1081#SOCKS4"],
  "outbound_jsons":["{\"type\":\"socks\",\"tag\":\"JSON SOCKS\",\"server\":\"127.0.0.1\",\"server_port\":1082,\"version\":\"5\"}"]}]}
JSON
ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK/fixture.json" "$WORK/generated.json" 127.0.0.1 0 1 '' 1.14.2-x-1.0.4 \
    >"$WORK/log" 2>&1 || { cat "$WORK/log" >&2; fail "SOCKS connection generation failed"; }
ucode -e '
let c = json(require("fs").readfile(ARGV[0]));
let socks = {};
for (let o in c.outbounds)
    if (o.type == "socks")
        socks[o.server_port] = o;
assert(socks[1080] && socks[1080].version == "5" && socks[1080].username == "user" && socks[1080].password == "pw", "manual SOCKS5 link lost");
assert(socks[1081] && socks[1081].version == "4", "manual SOCKS4 link lost");
assert(socks[1082] && socks[1082].tag == "JSON SOCKS", "SOCKS JSON outbound lost");
assert(length(keys(socks)) == 3, "unexpected socks outbound");
' "$WORK/generated.json"
echo 'Manual SOCKS links and SOCKS JSON outbounds still generate socks outbounds'
