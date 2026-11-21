#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_UC="$ROOT_DIR/forkop/files/usr/lib/diagnostics/runtime.uc"
CONTROLLER_UC="$ROOT_DIR/luci-app-forkop/root/usr/share/ucode/luci/controller/forkop.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# The report is an explicitly confidential artifact. Logging sanitization must
# never silently turn it into a masked diagnostic report.
grep -Fq 'global_check("raw", "raw")' "$RUNTIME_UC" ||
  fail "support report no longer requests raw global diagnostics"
grep -Fq 'show_xrust_config("raw")' "$RUNTIME_UC" ||
  fail "support report no longer includes raw generated Xrust config"
grep -Fq 'support_report_file("/etc/config/forkop", FORKOP_CONFIG)' "$RUNTIME_UC" ||
  fail "support report no longer includes raw Forkop UCI config"
grep -Fq 'CONFIDENTIAL SUPPORT REPORT' "$RUNTIME_UC" ||
  fail "support report confidentiality warning is missing"

{
  cat <<'UCODE'
let opened = 0;
let status;
let dispatched;
let http = {
  header: function() {},
  prepare_content: function() {},
  status: function(code) { status = code; },
  write: function() {}
};
function popen() {
  opened++;
  return { read: function() { return null; }, close: function() {} };
}
UCODE
  sed -n '/^function action_support_report()/,/^}/p' "$CONTROLLER_UC"
  cat <<'UCODE'
action_support_report();
if (status != 403 || opened != 0) die("Missing permission must deny the report");
dispatched = { readonly: true };
action_support_report();
if (status != 403 || opened != 0) die("Read-only role opened the confidential report");
dispatched = { readonly: false };
action_support_report();
if (opened != 1) die("Writable role could not open the report");
UCODE
} | ucode -

printf 'support report raw-data contract checks passed\n'

LIB="$ROOT_DIR/forkop/files/usr/lib"
fixture=$(mktemp)
trap 'rm -f "$fixture"' EXIT
printf '%s\n' '{"headers":{"Authorization":"fixture","pRoXy-AuThOrIzAtIoN":"fixture","COOKIE":"fixture","Set-Cookie":"fixture","Content-Type":"application/json"}}' >"$fixture"
ucode -L "$LIB" "$LIB/diagnostics/status.uc" mask-sing-box-config "$fixture" | ucode -e '
let config = json(require("fs").open("/dev/stdin", "r").read("all"));
for (let key in [ "Authorization", "pRoXy-AuThOrIzAtIoN", "COOKIE", "Set-Cookie" ])
  if (config.headers[key] != "MASKED") die("Credential header escaped masking");
if (config.headers["Content-Type"] != "application/json") die("Unrelated header was hidden");
'
printf '%s\n' '{"password":"fixture"' >"$fixture"
[ "$(ucode -L "$LIB" "$LIB/diagnostics/status.uc" mask-sing-box-config "$fixture")" = '"MASKED"' ] ||
  fail "invalid JSON was not withheld"
printf 'Xrust diagnostics masking checks passed\n'
