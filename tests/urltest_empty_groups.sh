#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
GENERATOR_UC="$FORKOP_LIB/xrust/generator.uc"
WORK_DIR="$(mktemp -d)"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

generate() {
  ucode -L "$FORKOP_LIB" "$GENERATOR_UC" generate-config-fixture "$1" "$2" 127.0.0.1
}

# A group which loses every leaf to its filter must fail while the config is
# still staged.  It may never be represented by final/direct.
cat >"$WORK_DIR/urltest-empty.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [{
    ".name": "proxy", ".type": "section", "enabled": "1", "action": "connection",
    "selector_proxy_links": ["vless://00000000-0000-4000-8000-000000000001@edge.example:443?encryption=none&security=tls&sni=edge.example&type=ws#Only%20leaf"]
  }],
  "urltest": [{
    ".name": "ut_empty", ".type": "urltest", "section": "proxy", "name": "Empty URLTest",
    "filter_mode": "include", "include_regex": ["^does-not-match$"]
  }]
}
JSON

if generate "$WORK_DIR/urltest-empty.json" "$WORK_DIR/urltest-empty-config.json" >"$WORK_DIR/urltest-empty.out" 2>"$WORK_DIR/urltest-empty.err"; then
  fail "URLTest with zero usable leaves was accepted"
fi
grep -Fq "URLTest group 'Empty URLTest'" "$WORK_DIR/urltest-empty.out" "$WORK_DIR/urltest-empty.err" &&
  grep -Fq 'has no usable proxy outbounds after filtering' "$WORK_DIR/urltest-empty.out" "$WORK_DIR/urltest-empty.err" ||
  fail "empty URLTest did not report the fail-closed reason"

cat >"$WORK_DIR/priority-empty.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [{
    ".name": "proxy", ".type": "section", "enabled": "1", "action": "connection",
    "selector_proxy_links": ["vless://00000000-0000-4000-8000-000000000001@edge.example:443?encryption=none&security=tls&sni=edge.example&type=ws#Only%20leaf"]
  }],
  "priority_group": [{
    ".name": "pg_empty", ".type": "priority_group", "section": "proxy", "name": "Empty Priority"
  }],
  "priority_level": [{
    ".name": "pl_empty", ".type": "priority_level", "group": "pg_empty", "name": "No matches",
    "order": "0", "filter_mode": "include", "include_regex": ["^does-not-match$"]
  }]
}
JSON

if generate "$WORK_DIR/priority-empty.json" "$WORK_DIR/priority-empty-config.json" >"$WORK_DIR/priority-empty.out" 2>"$WORK_DIR/priority-empty.err"; then
  fail "Priority group with zero usable leaves was accepted"
fi
grep -Fq "Priority group 'Empty Priority'" "$WORK_DIR/priority-empty.out" "$WORK_DIR/priority-empty.err" &&
  grep -Fq 'has no usable proxy outbounds after filtering' "$WORK_DIR/priority-empty.out" "$WORK_DIR/priority-empty.err" ||
  fail "empty Priority group did not report the fail-closed reason"

printf 'empty URLTest/Priority group checks passed\n'
