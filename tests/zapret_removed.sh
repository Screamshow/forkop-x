#!/bin/sh
# Zapret and Zapret2 rule actions are removed from Forkop X; DPI bypass is
# provided by the Zapret Manager component, which stays available.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB=${FORKOP_LIB:-$ROOT/forkop/files/usr/lib}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

[ ! -e "$LIB/providers" ] || fail "provider modules are still installed"

# Runtime code, LuCI views (handwritten, bundled and compacted), frontend
# sources and translations must not mention the removed providers. The Zapret
# Manager component keeps its own name, and the configuration migration is the
# only other exception: it cleans up what the providers left behind.
if grep -rIin 'zapret\|nfqws\|nfqueue' \
    "$ROOT/forkop/files" \
    "$ROOT/luci-app-forkop/htdocs" \
    "$ROOT/luci-app-forkop/generated" \
    "$ROOT/luci-app-forkop/po" \
    "$ROOT/fe-app-forkop/src" \
    "$ROOT/fe-app-forkop/locales" |
    grep -viE 'zapret[_-]manager|zapretmanager|zapret manager' |
    grep -v '^'"$ROOT"'/forkop/files/usr/lib/config/migration\.uc:' >"$WORK/hits"; then
    cat "$WORK/hits" >&2
    fail "Zapret provider references remain"
fi
awk '
  /^\/\/ Zapret and Zapret2 rules were removed|^\/\/ PID, log, hostlist and state files of the removed Zapret/ { cleanup = 1 }
  /^    migrate_retired_zapret\(ctx\);$|^    remove_retired_zapret_state\(\);$/ { next }
  !cleanup && tolower($0) ~ /zapret|nfqws|nfqueue/ { print FILENAME ":" NR ": " $0; bad = 1 }
  cleanup && /^}$/ { cleanup = 0 }
  END { exit bad }
' "$LIB/config/migration.uc" || fail "Zapret is referenced outside the migration cleanup"
echo 'No Zapret provider references in runtime, LuCI, frontend or translations'

# The Zapret Manager component is still installable from the GUI.
grep -Fq 'component == "zapret_manager" && action == "install"' "$LIB/components/action.uc" ||
  fail "the Zapret Manager component can no longer be installed"
grep -Fq 'component == "zapret_manager"' "$LIB/components/updates.uc" ||
  fail "the Zapret Manager component is no longer a valid component name"
grep -Fq 'zapret_manager_installed' "$LIB/diagnostics/runtime.uc" ||
  fail "system info no longer reports the Zapret Manager component"
echo 'The Zapret Manager component stays available'

# Upgrades disable Zapret rules instead of failing validation.
cat >"$WORK/zapret.json" <<'JSON'
{"settings":{"download_lists_via_proxy":"1","download_lists_via_proxy_section":"dpi",
  "download_components_via_proxy":"1","dns_detour_enabled":"1","dns_detour_section":"dpi2"},
 "section":[
  {".name":"dpi",".type":"section","enabled":"1","action":"zapret","nfqws_opt":"--dpi-desync=fake",
   "community_lists":["youtube"],"mixed_proxy_enabled":"1","mixed_proxy_port":"4545",
   "mixed_proxy_auth_enabled":"1","mixed_proxy_username":"u","mixed_proxy_password":"p"},
  {".name":"dpi2",".type":"section","enabled":"1","action":"zapret2","nfqws2_opt":"--filter-tcp=80"},
  {".name":"was_dpi",".type":"section","enabled":"1","action":"block","nfqws_opt":"--dpi-desync=fake"},
  {".name":"dnsrule",".type":"section","enabled":"1","action":"dns","dns_server":"1.1.1.1",
   "domain":"a.test","dns_detour_enabled":"1","dns_detour_section":"dpi"},
  {".name":"vpn",".type":"section","enabled":"1","action":"connection"}],
 "subscription_url":[
  {".name":"sub1",".type":"subscription_url","section":"vpn","value":"https://sub.test/a",
   "download_via_proxy_enabled":"1","download_via_proxy_section":"dpi"},
  {".name":"sub2",".type":"subscription_url","section":"vpn","value":"https://sub.test/b",
   "download_via_proxy_enabled":"1","download_via_proxy_section":"vpn"}]}
JSON
FORKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/config/migration.uc" migrate-fixture "$WORK/zapret.json" >"$WORK/migrated.json"
ucode -e '
let fs = require("fs");
let r = json(fs.readfile(ARGV[0])), c = r.config, s = {}, sub = {};
for (let x in c.section) s[x[".name"]] = x;
for (let x in c.subscription_url) sub[x[".name"]] = x;
assert(s.dpi.enabled == "0" && s.dpi.action == "bypass", "Zapret rule is not disabled as a direct rule");
assert(s.dpi2.enabled == "0" && s.dpi2.action == "bypass", "Zapret2 rule is not disabled as a direct rule");
assert(s.dpi.nfqws_opt == null && s.dpi2.nfqws2_opt == null, "NFQWS strategy kept");
assert(length(s.dpi.community_lists) == 1, "Zapret rule lost its lists");
assert(s.dpi.mixed_proxy_enabled == null && s.dpi.mixed_proxy_port == null &&
    s.dpi.mixed_proxy_auth_enabled == null && s.dpi.mixed_proxy_username == null &&
    s.dpi.mixed_proxy_password == null, "a direct rule kept the mixed proxy it can no longer serve");
assert(s.was_dpi.action == "block" && s.was_dpi.enabled == "1" && s.was_dpi.nfqws_opt == null, "stale strategy on another rule");
assert(c.settings.download_lists_via_proxy == "0" && c.settings.download_lists_via_proxy_section == null, "lists still download through the Zapret rule");
assert(c.settings.download_components_via_proxy == "0", "components still fall back to the Zapret rule");
assert(c.settings.dns_detour_enabled == "0" && c.settings.dns_detour_section == null, "DNS still resolves through the Zapret2 rule");
assert(s.dnsrule.dns_detour_enabled == "0" && s.dnsrule.dns_detour_section == null, "DNS rule still detours through the Zapret rule");
assert(sub.sub1.download_via_proxy_enabled == "0" && sub.sub1.download_via_proxy_section == null, "subscription still downloads through the Zapret rule");
assert(sub.sub2.download_via_proxy_enabled == "1" && sub.sub2.download_via_proxy_section == "vpn", "unrelated subscription changed");
fs.writefile(ARGV[1], sprintf("%J", c));
' "$WORK/migrated.json" "$WORK/again.json" || fail "Zapret configuration was not cleaned up"
FORKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/config/migration.uc" migrate-fixture "$WORK/again.json" >"$WORK/repeat.json"
ucode -e 'let r = json(require("fs").readfile(ARGV[0])); assert(!r.changed && length(r.operations) == 0, "cleanup is not idempotent");' "$WORK/repeat.json" ||
  fail "Zapret cleanup changes an already clean configuration"
echo 'Upgrades disable Zapret rules and clear their strategy, download and DNS references'

# A rule that still asks for a removed action fails validation with a clear
# message instead of generating a broken runtime.
cat >"$WORK/still-zapret.json" <<'JSON'
{"settings":{".name":"settings",".type":"settings","dns_server":"1.1.1.1","bootstrap_dns_server":"8.8.8.8"},
 "section":[{".name":"dpi",".type":"section","enabled":"1","action":"zapret","domain_suffix":["zap.example"]}]}
JSON
if FORKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/config/validator.uc" validate-runtime-fixture \
    "$WORK/still-zapret.json" '{}' >"$WORK/validation.log" 2>&1; then
    cat "$WORK/validation.log" >&2
    fail "a rule with action 'zapret' still passes validation"
fi
grep -Fq "unsupported action 'zapret'" "$WORK/validation.log" ||
  fail "validation does not report the removed action: $(cat "$WORK/validation.log")"
echo 'A leftover Zapret action is rejected by configuration validation'

# Re-enabling a rolled-back rule must still generate a configuration.
cat >"$WORK/reenabled.json" <<'JSON'
{"settings":{".name":"settings",".type":"settings","dns_server":"1.1.1.1"},
 "section":[{".name":"dpi",".type":"section","enabled":"1","action":"bypass",
  "domain_suffix":["zap.example"]}]}
JSON
mkdir -p "$WORK/reenabled-out.json.section-cache" "$WORK/reenabled-out.json.rulesets"
ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK/reenabled.json" "$WORK/reenabled-out.json" 127.0.0.1 0 1 '' 1.14.2-x-1.0.4 \
    >"$WORK/reenabled.log" 2>&1 ||
  { cat "$WORK/reenabled.log" >&2; fail "a re-enabled rolled-back rule does not generate"; }
echo 'A re-enabled rolled-back rule generates a configuration'

# Mixed Proxy survives the removal on the actions that can provide an outbound.
cat >"$WORK/mixed.json" <<'JSON'
{"settings":{".name":"settings",".type":"settings","dns_server":"1.1.1.1"},
 "section":[{".name":"proxy",".type":"section","enabled":"1","action":"connection",
  "selector_proxy_links":["socks5://127.0.0.1:1080#Manual%20SOCKS"],
  "mixed_proxy_enabled":"1","mixed_proxy_port":"4545"}]}
JSON
ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK/mixed.json" "$WORK/mixed-out.json" 127.0.0.1 0 1 '' 1.14.2-x-1.0.4 \
    >"$WORK/mixed.log" 2>&1 || { cat "$WORK/mixed.log" >&2; fail "mixed proxy generation failed"; }
ucode -e '
let c = json(require("fs").readfile(ARGV[0]));
let mixed = null;
for (let i in c.inbounds)
    if (i.type == "mixed" && i.listen_port == 4545)
        mixed = i;
assert(mixed != null, "connection rule lost its mixed proxy inbound");
' "$WORK/mixed-out.json" || fail "mixed proxy is no longer generated for connection rules"
grep -Fq 'dependsOnConnectionAction(o)' "$ROOT/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js" ||
  fail "Mixed Proxy is not offered for connection actions in LuCI"
echo 'Mixed Proxy stays available for connection rules'
