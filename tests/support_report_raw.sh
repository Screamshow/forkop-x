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

ACL_JSON="$ROOT_DIR/luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json"
MENU_JSON="$ROOT_DIR/luci-app-forkop/root/usr/share/luci/menu.d/luci-app-forkop.json"
ucode -e '
let fs = require("fs");
let acl = json(fs.readfile(ARGV[0]))["luci-app-forkop"];
let route = json(fs.readfile(ARGV[1]))["admin/services/forkop/ui-read"];
if (acl.read.file || acl.read.ubus.file || acl.read.ubus.service)
  die("Read-only role has direct access to files or processes");
if (!acl.write.file["/usr/bin/forkop"] || !acl.write.file["/etc/init.d/forkop"])
  die("Writable role lost its administrative commands");
if (!route.action.post || !route.auth.login ||
    route.depends.acl[0] != "luci-app-forkop" || route.action.function != "action_ui_read")
  die("Read endpoint missing the LuCI authentication or CSRF contract");
' "$ACL_JSON" "$MENU_JSON"

{
  cat <<'UCODE'
let opened = 0, accessed = 0, status, dispatched, request, response;
let auth_dirs = 0, auth_files = {}, auth_handoffs = [];
let fs = {
  mkdtemp: function(template) {
    assert(template == '/tmp/forkop-tailscale-connect.XXXXXX');
    return '/tmp/forkop-tailscale-connect.AAAAA' + (++auth_dirs);
  },
  open: function(path, mode, permissions) {
    assert(mode == 'w' && permissions == 0600);
    return {
      write: function(value) {
        auth_files[path] = value;
        return length(value);
      },
      close: function() {}
    };
  },
  unlink: path => delete auth_files[path],
  rmdir: function() {}
};
let http = {
  header: function() {},
  prepare_content: function() {},
  formvalue: function(key) { return request[key]; },
  status: function(code) { status = code; },
  write: function(value) { response = json(value); }
};
function popen(command, mode) {
  opened++;
  let connect = match(command, /^\/usr\/bin\/forkop tailscale_native_connect (\/tmp\/forkop-tailscale-connect\.[A-Za-z0-9]{6}\/input) 2>\/dev\/null$/);
  if (connect) {
    push(auth_handoffs, [connect[1], auth_files[connect[1]]]);
    return { read: () => '{"state":"connecting"}', close: () => 0 };
  }
  if (command == '/usr/bin/forkop runtime_config_reference 2>/dev/null')
    return {
      read: () => '{"path":"/srv/custom/xrust.json","revision":"42:2"}',
      close: () => 0
    };
  if (command == '/usr/bin/forkop clash_api_address 2>/dev/null')
    return { read: () => '127.0.0.1\n', close: () => 0 };
  if (command == "curl --noproxy '*' --max-time 20 -fs http://127.0.0.1:9090/connections 2>/dev/null") {
    let count = 0, chunk = 'x';
    while (length(chunk) < 16384) chunk += chunk;
    return {
      read: function(size) {
        assert(size == 16384);
        return count++ < 32 ? chunk : '';
      },
      close: () => 0
    };
  }
  if (command != '/usr/bin/forkop get_ui_state 2>/dev/null' || mode != 'r')
    die('Unexpected command in read route');
  return {
    read: function() { return '{"service":{"forkop":{"running":1}},"config_error":"fixture"}'; },
    close: function() { return 0; }
  };
}
function stat(path) {
  accessed++;
  if (path != '/srv/custom/xrust.json')
    die('Unexpected path in read route');
  return { type: 'file', size: 420 };
}
function readfile() {
  return sprintf('%J', {
    outbounds: [
      { type: 'urltest', tag: 'group', outbounds: ['proxy'], url: 'fixture' },
      { type: 'socks', tag: 'proxy', password: 'fixture' }
    ],
    route: { rules: [{
      type: 'logical', mode: 'and', action: 'route', outbound: 'group', inbound: ['lan'],
      rules: [{
        domain_suffix: ['example.com', { secret: 'fixture' }],
        headers: { Cookie: 'fixture' }
      }]
    }] },
    endpoints: [{ private_key: 'fixture' }]
  });
}
UCODE
  sed -e '/^import /d' -e '/^function action_support_report()/,$d' "$CONTROLLER_UC"
  cat <<'UCODE'
request = { operation: 'get_ui_state' };
action_ui_read();
if (status != 403 || opened || accessed)
  die('Missing read permission was not denied');
dispatched = { readonly: true };
action_ui_read();
let state = json(response.stdout);
if (response.code || opened != 1 || !state.service.forkop.running || state.config_error)
  die('Delegated reader did not get a filtered status');
for (let operation in ['component_action_async', 'global_check', 'show_xrust_config', 'check_logs']) {
  status = null;
  request = { operation };
  action_ui_read();
  if (status != 400 || response.code != 1 || opened != 1 || accessed)
    die('Command outside the read allowlist was accepted');
}
status = null;
request = { operation: 'get_ui_state', subject: 'unexpected' };
action_ui_read();
if (status != 400 || opened != 1 || accessed)
  die('A fixed operation accepted input');
request = { operation: 'runtime_config', subject: '/etc/config/network' };
action_ui_read();
if (response.code != 1 || accessed)
  die('An unexpected path reached the filesystem');
request = { operation: 'runtime_config', subject: '42:2' };
action_ui_read();
let config = json(response.stdout);
if (response.code || accessed != 1 || length(config.outbounds) != 1 ||
    config.outbounds[0].tag != 'group' || config.outbounds[0].url ||
    config.endpoints)
  die('Delegated runtime metadata was missing or exposed protected fields');
let rule = config.route.rules[0];
if (rule.type != 'logical' || rule.mode != 'and' || rule.action != 'route' ||
    rule.inbound[0] != 'lan' || rule.rules[0].headers ||
    length(rule.rules[0].domain_suffix) != 1 ||
    rule.rules[0].domain_suffix[0] != 'example.com')
  die('Nested route conditions were missing or exposed protected fields');
request = { operation: 'validate_regex', value: '["^[A-Za-z]+$","^(?=example)example$"]' };
action_ui_write();
if (status != 403 || response.code != 1) die('Delegated read could submit a write request');
dispatched = { readonly: false };
action_ui_write();
if (response.code || json(response.stdout).invalid != 1)
  die('Validate did not use the ucode regular-expression dialect');
request = { operation: 'runtime_config', subject: '42:2' };
action_ui_read();
config = json(response.stdout);
if (response.code || config.outbounds[0].url != 'fixture' || config.endpoints)
  die('Writable session lost its URLTest settings');
let transferred = 0;
http.write = value => transferred += length(value);
request = { operation: 'connections' };
for (let readonly in [true, false]) {
  dispatched = { readonly };
  transferred = 0;
  action_ui_clash();
  if (transferred != 524288) die('Clash stream truncated a valid snapshot');
}
http.write = value => response = json(value);
dispatched = { readonly: true };
request = { operation: 'tailscale_connect', value: 'tskey-auth-fixture-one' };
action_ui_write();
if (status != 403 || auth_dirs) die('Delegated session could stage a native Tailscale request');
dispatched = { readonly: false };
action_ui_write();
if (response.code || length(keys(auth_files))) die('First Tailscale request was not cleaned up');
request.value = 'tskey-auth-fixture-two';
action_ui_write();
if (response.code || length(keys(auth_files)) || length(auth_handoffs) != 2 ||
    auth_handoffs[0][0] == auth_handoffs[1][0] ||
    auth_handoffs[0][1] != 'tskey-auth-fixture-one' ||
    auth_handoffs[1][1] != 'tskey-auth-fixture-two')
  die('Tailscale requests share staged input or lost their own key');
UCODE
} | ucode -
printf 'LuCI read and write permission contracts passed\n'

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
