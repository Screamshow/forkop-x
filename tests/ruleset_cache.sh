#!/bin/sh
set -eu
set -o pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
RULESET_CACHE_UC="$FORKOP_LIB/singbox/ruleset_cache.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export FORKOP_RULESET_RUNTIME_CACHE_DIR="$WORK_DIR/runtime-cache"
export FORKOP_RULESET_RUNTIME_MANIFEST="$WORK_DIR/runtime-manifest.json"
export FORKOP_PERSISTENT_LIST_CACHE_DIR="$WORK_DIR/list-cache"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/cache"
cat >"$WORK_DIR/source.json" <<'EOF'
{"version":1,"rules":[{"domain_suffix":["example.test"]}]}
EOF
printf 'mock-srs\n' >"$WORK_DIR/source.srs"

cat >"$WORK_DIR/bin/curl" <<'EOF'
#!/bin/sh
output=''
url=''
speed_time=''
speed_limit=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --speed-time) speed_time="$2"; shift 2 ;;
    --speed-limit) speed_limit="$2"; shift 2 ;;
    --proxy|--connect-timeout|--max-time) shift 2 ;;
    --fail|--location|--silent|--show-error) shift ;;
    *) url="$1"; shift ;;
  esac
done
[ "$speed_time" = 15 ] && [ "$speed_limit" = 1 ] || exit 1
case "$url" in
  *.json) cp "$RULESET_TEST_SOURCE_JSON" "$output" ;;
  *.srs) cp "$RULESET_TEST_SOURCE_SRS" "$output" ;;
  *) exit 1 ;;
esac
EOF
cat >"$WORK_DIR/bin/sing-box" <<'EOF'
#!/bin/sh
[ "$1" = rule-set ] && [ "$2" = match ] || exit 1
[ "$3" = --format ] && [ "$4" = binary ] || exit 1
[ -f "$5" ] && [ "$6" = forkop-validation.invalid ] || exit 1
EOF
chmod +x "$WORK_DIR/bin/curl" "$WORK_DIR/bin/sing-box"

cat >"$WORK_DIR/config.json" <<'EOF'
{"route":{"rule_set":[
  {"type":"remote","tag":"binary","format":"binary","url":"https://example.test/rules.srs","download_detour":"proxy-out","update_interval":"1d"},
  {"type":"remote","tag":"source","format":"source","url":"https://example.test/rules.json"}
]}}
EOF
cp "$WORK_DIR/config.json" "$WORK_DIR/config-prune.json"

PATH="$WORK_DIR/bin:$PATH" \
RULESET_TEST_SOURCE_JSON="$WORK_DIR/source.json" \
RULESET_TEST_SOURCE_SRS="$WORK_DIR/source.srs" \
FORKOP_RULESET_CACHE_DIR="$WORK_DIR/cache" \
FORKOP_RULESET_CACHE_MANIFEST="$WORK_DIR/cache/manifest.json" \
  ucode -L "$FORKOP_LIB" "$RULESET_CACHE_UC" materialize-config "$WORK_DIR/config.json"

if ! ucode -e '
  let fs = require("fs");
  let config = json(fs.readfile(ARGV[0]));
  let values = config.route.rule_set;
  if (length(values) != 2) exit(1);
  for (let value in values) {
    if (value.type != "local" || value.url != null || value.download_detour != null || value.update_interval != null)
      exit(1);
    if (fs.stat(value.path) == null)
      exit(1);
  }
' "$WORK_DIR/config.json"; then
  cat "$WORK_DIR/config.json" >&2
  find "$WORK_DIR/cache" -maxdepth 1 -type f -print >&2
  fail "remote rule sets must be materialized as local validated files"
fi

printf 'orphan\n' >"$WORK_DIR/cache/aaaaaaaaaaaa.srs"
printf 'orphan validation\n' >"$WORK_DIR/cache/aaaaaaaaaaaa.srs.validated"
printf '{"version":1,"rules":[]}\n' >"$WORK_DIR/cache/bbbbbbbbbbbb.json"
printf '{"version":1,"rules":[]}\n' >"$WORK_DIR/cache/empty-cccccccccccc.json"
PATH="$WORK_DIR/bin:$PATH" \
RULESET_TEST_SOURCE_JSON="$WORK_DIR/source.json" \
RULESET_TEST_SOURCE_SRS="$WORK_DIR/source.srs" \
FORKOP_RULESET_CACHE_DIR="$WORK_DIR/cache" \
FORKOP_RULESET_CACHE_MANIFEST="$WORK_DIR/cache/manifest.json" \
  ucode -L "$FORKOP_LIB" "$RULESET_CACHE_UC" materialize-config "$WORK_DIR/config-prune.json"
for orphan in aaaaaaaaaaaa.srs aaaaaaaaaaaa.srs.validated bbbbbbbbbbbb.json empty-cccccccccccc.json; do
  [ ! -e "$WORK_DIR/cache/$orphan" ] ||
    fail "materialization must prune stale managed rule-set cache file $orphan"
done
[ "$(find "$WORK_DIR/cache" -maxdepth 1 -type f -name '*.srs' | wc -l)" -eq 1 ] ||
  fail "materialization must retain the active binary rule-set cache"

# Interrupted refreshes must not accumulate persistent temporary files. Exact
# managed patterns are cleaned, while unrelated files remain untouched.
printf 'partial\n' >"$WORK_DIR/cache/aaaaaaaaaaaa.srs.download.1.2"
printf 'partial validation\n' >"$WORK_DIR/cache/aaaaaaaaaaaa.srs.download.1.2.validated"
printf 'partial manifest\n' >"$WORK_DIR/cache/manifest.json.1.2.tmp"
printf 'partial validation output\n' >"$WORK_DIR/cache/.validate-aaaaaaaaaaaa.json"
printf 'keep\n' >"$WORK_DIR/cache/user-file.download.1.2"
PATH="$WORK_DIR/bin:$PATH" \
RULESET_TEST_SOURCE_JSON="$WORK_DIR/source.json" \
RULESET_TEST_SOURCE_SRS="$WORK_DIR/source.srs" \
FORKOP_RULESET_CACHE_DIR="$WORK_DIR/cache" \
FORKOP_RULESET_CACHE_MANIFEST="$WORK_DIR/cache/manifest.json" \
FORKOP_RULESET_CACHE_TEMP_MAX_AGE=0 \
  ucode -L "$FORKOP_LIB" "$RULESET_CACHE_UC" materialize-config "$WORK_DIR/config-prune.json"
for temporary in aaaaaaaaaaaa.srs.download.1.2 aaaaaaaaaaaa.srs.download.1.2.validated manifest.json.1.2.tmp .validate-aaaaaaaaaaaa.json; do
  [ ! -e "$WORK_DIR/cache/$temporary" ] ||
    fail "stale rule-set temporary file was not removed: $temporary"
done
[ -e "$WORK_DIR/cache/user-file.download.1.2" ] ||
  fail "temporary cleanup removed an unrelated cache file"

# A failed independent source must retain its old cache without suppressing
# application of another source that changed successfully.
mkdir -p "$WORK_DIR/partial-cache"
cat >"$WORK_DIR/partial-old.json" <<'EOF'
{"version":1,"rules":[{"domain_suffix":["old.test"]}]}
EOF
cat >"$WORK_DIR/partial-new.json" <<'EOF'
{"version":1,"rules":[{"domain_suffix":["new.test"]}]}
EOF
cat >"$WORK_DIR/partial-config.json" <<'EOF'
{"route":{"rule_set":[
  {"type":"remote","tag":"good","format":"source","url":"https://good.test/rules.json"},
  {"type":"remote","tag":"bad","format":"source","url":"https://bad.test/rules.json"}
]}}
EOF
PATH="$WORK_DIR/bin:$PATH" \
RULESET_TEST_SOURCE_JSON="$WORK_DIR/partial-old.json" \
RULESET_TEST_SOURCE_SRS="$WORK_DIR/source.srs" \
FORKOP_RULESET_CACHE_DIR="$WORK_DIR/partial-cache" \
FORKOP_RULESET_CACHE_MANIFEST="$WORK_DIR/partial-cache/manifest.json" \
  ucode -L "$FORKOP_LIB" "$RULESET_CACHE_UC" materialize-config "$WORK_DIR/partial-config.json"
good_path="$(ucode -e 'let fs=require("fs"); let c=json(fs.readfile(ARGV[0])); print(c.route.rule_set[0].path)' "$WORK_DIR/partial-config.json")"
bad_path="$(ucode -e 'let fs=require("fs"); let c=json(fs.readfile(ARGV[0])); print(c.route.rule_set[1].path)' "$WORK_DIR/partial-config.json")"
cat >"$WORK_DIR/bin/curl" <<'EOF'
#!/bin/sh
output=''
url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --proxy|--connect-timeout|--max-time) shift 2 ;;
    --fail|--location|--silent|--show-error) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  https://good.test/*) cp "$RULESET_TEST_SOURCE_JSON" "$output" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK_DIR/bin/curl"
PATH="$WORK_DIR/bin:$PATH" \
RULESET_TEST_SOURCE_JSON="$WORK_DIR/partial-new.json" \
FORKOP_RULESET_CACHE_DIR="$WORK_DIR/partial-cache" \
FORKOP_RULESET_CACHE_MANIFEST="$WORK_DIR/partial-cache/manifest.json" \
  ucode -L "$FORKOP_LIB" "$RULESET_CACHE_UC" refresh >/dev/null 2>&1 ||
  fail "a changed rule set must request reload even when another source failed"
grep -Fq 'new.test' "$good_path" || fail "successful rule-set refresh was not committed"
grep -Fq 'old.test' "$bad_path" || fail "failed rule-set refresh did not retain last-known-good data"

export FORKOP_RULESET_CACHE_DIR="$WORK_DIR/partial-cache"
export FORKOP_RULESET_CACHE_MANIFEST="$WORK_DIR/partial-cache/manifest.json"
status=0
PATH="$WORK_DIR/bin:$PATH" RULESET_TEST_SOURCE_JSON="$WORK_DIR/partial-new.json" \
  ucode -L "$FORKOP_LIB" "$RULESET_CACHE_UC" refresh-for-restart || status=$?
[ "$status" = 1 ] || fail "manual refresh must accept a valid cache when a source is offline"

printf 'invalid cache\n' >"$bad_path"
status=0
PATH="$WORK_DIR/bin:$PATH" RULESET_TEST_SOURCE_JSON="$WORK_DIR/partial-old.json" \
  ucode -L "$FORKOP_LIB" "$RULESET_CACHE_UC" refresh-for-restart || status=$?
[ "$status" = 2 ] || fail "manual refresh must reject invalid cache even if another source changed"
unset FORKOP_RULESET_CACHE_DIR FORKOP_RULESET_CACHE_MANIFEST

cat >"$WORK_DIR/offline.json" <<'EOF'
{"route":{"rule_set":[{"type":"remote","tag":"offline","format":"binary","url":"https://offline.test/missing.srs"}]}}
EOF
cat >"$WORK_DIR/bin/curl" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$WORK_DIR/bin/curl"
PATH="$WORK_DIR/bin:$PATH" \
RULESET_TEST_SOURCE_JSON="$WORK_DIR/source.json" \
FORKOP_RULESET_CACHE_DIR="$WORK_DIR/cache" \
FORKOP_RULESET_CACHE_MANIFEST="$WORK_DIR/cache/manifest.json" \
  ucode -L "$FORKOP_LIB" "$RULESET_CACHE_UC" materialize-config "$WORK_DIR/offline.json" 2>/dev/null
ucode -e '
  let fs = require("fs");
  let value = json(fs.readfile(ARGV[0])).route.rule_set[0];
  let source = json(fs.readfile(value.path));
  if (value.type != "local" || value.format != "source" || length(source.rules) != 0)
    exit(1);
' "$WORK_DIR/offline.json" || fail "first offline start must use an empty local rule set instead of blocking sing-box"

cat >"$WORK_DIR/cache-only.json" <<'EOF'
{"route":{"rule_set":[{"type":"remote","tag":"private","format":"binary","url":"https://private.test/rules.srs"}]}}
EOF
cat >"$WORK_DIR/bin/curl" <<'EOF'
#!/bin/sh
printf 'direct download attempted\n' >>"$RULESET_TEST_CURL_CALLS"
exit 1
EOF
chmod +x "$WORK_DIR/bin/curl"
: >"$WORK_DIR/curl.calls"
PATH="$WORK_DIR/bin:$PATH" \
RULESET_TEST_SOURCE_JSON="$WORK_DIR/source.json" \
RULESET_TEST_CURL_CALLS="$WORK_DIR/curl.calls" \
FORKOP_RULESET_CACHE_DIR="$WORK_DIR/cache" \
FORKOP_RULESET_CACHE_MANIFEST="$WORK_DIR/cache/manifest.json" \
  ucode -L "$FORKOP_LIB" "$RULESET_CACHE_UC" materialize-config "$WORK_DIR/cache-only.json" cache-only 2>/dev/null
[ ! -s "$WORK_DIR/curl.calls" ] ||
  fail "proxy-only cold start must not attempt a direct rule-set download before the service proxy is ready"

fallback="$({
  FORKOP_MIRROR_BASE_URL='https://mirror.test'
  SRS_MAIN_URL='https://mirror.test/forkop/lists/rulesets/community'
  SRS_FALLBACK_MAIN_URL='https://upstream.test/community'
  export FORKOP_MIRROR_BASE_URL SRS_MAIN_URL SRS_FALLBACK_MAIN_URL
  ucode -L "$FORKOP_LIB" "$RULESET_CACHE_UC" fallback-urls \
    'https://mirror.test/forkop/lists/rulesets/community/youtube.srs'
})"
[ "$fallback" = 'https://upstream.test/community/youtube.srs' ] ||
  fail "community rule-set fallback must preserve the asset name"

secondary_fallback="$(FORKOP_MIRROR_BASE_URL='https://mirror.test' \
  ucode -L "$FORKOP_LIB" "$RULESET_CACHE_UC" fallback-urls \
  'https://mirror.test/forkop/lists/b4geoip-forkop/srs/twitch.srs')"
[ "$secondary_fallback" = "$(printf '%s\n%s' \
  'https://cdn.jsdelivr.net/gh/Greeg0ry/b4geoip-forkop@main/srs/twitch.srs' \
  'https://raw.githubusercontent.com/Greeg0ry/b4geoip-forkop/main/srs/twitch.srs')" ] ||
  fail "secondary rule-set fallback must use jsDelivr before raw GitHub"

before="$(find "$WORK_DIR/cache" -maxdepth 1 -type f -name '*.srs' -exec md5sum {} \;)"
PATH="$WORK_DIR/bin:$PATH" \
RULESET_TEST_SOURCE_JSON="$WORK_DIR/source.json" \
RULESET_TEST_SOURCE_SRS="$WORK_DIR/source.srs" \
FORKOP_RULESET_CACHE_DIR="$WORK_DIR/cache" \
FORKOP_RULESET_CACHE_MANIFEST="$WORK_DIR/cache/manifest.json" \
  ucode -L "$FORKOP_LIB" "$RULESET_CACHE_UC" refresh >/dev/null 2>&1 || true
after="$(find "$WORK_DIR/cache" -maxdepth 1 -type f -name '*.srs' -exec md5sum {} \;)"
[ "$before" = "$after" ] || fail "an unchanged cached rule set must remain stable"

# When flash cannot keep the reserve, a changed remote rule-set is activated
# from /tmp for this boot while its last-known-good persistent copy stays put.
mkdir -p "$WORK_DIR/quota-cache" "$WORK_DIR/quota-runtime"
cat >"$WORK_DIR/quota-old.json" <<'EOF_QUOTA_OLD'
{"version":1,"rules":[{"domain_suffix":["quota-old.test"]}]}
EOF_QUOTA_OLD
cat >"$WORK_DIR/quota-new.json" <<'EOF_QUOTA_NEW'
{"version":1,"rules":[{"domain_suffix":["quota-new.test"]}]}
EOF_QUOTA_NEW
cat >"$WORK_DIR/quota-config.json" <<'EOF_QUOTA_CONFIG'
{"route":{"rule_set":[{"type":"remote","tag":"quota","format":"source","url":"https://quota.test/rules.json"}]}}
EOF_QUOTA_CONFIG
cat >"$WORK_DIR/bin/curl" <<'EOF_QUOTA_CURL'
#!/bin/sh
output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --proxy|--connect-timeout|--max-time) shift 2 ;;
    --fail|--location|--silent|--show-error) shift ;;
    *) shift ;;
  esac
done
cp "$RULESET_TEST_SOURCE_JSON" "$output"
EOF_QUOTA_CURL
chmod +x "$WORK_DIR/bin/curl"
PATH="$WORK_DIR/bin:$PATH" \
RULESET_TEST_SOURCE_JSON="$WORK_DIR/quota-old.json" \
FORKOP_RULESET_CACHE_DIR="$WORK_DIR/quota-cache" \
FORKOP_RULESET_CACHE_MANIFEST="$WORK_DIR/quota-cache/manifest.json" \
FORKOP_RULESET_RUNTIME_CACHE_DIR="$WORK_DIR/quota-runtime" \
FORKOP_RULESET_RUNTIME_MANIFEST="$WORK_DIR/quota-runtime-manifest.json" \
FORKOP_PERSISTENT_LIST_CACHE_DIR="$WORK_DIR/quota-list-cache" \
  ucode -L "$FORKOP_LIB" "$RULESET_CACHE_UC" materialize-config "$WORK_DIR/quota-config.json"
persistent_path="$(ucode -e 'let fs=require("fs"); print(json(fs.readfile(ARGV[0])).route.rule_set[0].path)' "$WORK_DIR/quota-config.json")"
grep -Fq 'quota-old.test' "$persistent_path" || fail "initial rule-set was not persisted"
persistent_md5="$(md5sum "$persistent_path" | cut -d' ' -f1)"
PATH="$WORK_DIR/bin:$PATH" \
RULESET_TEST_SOURCE_JSON="$WORK_DIR/quota-new.json" \
FORKOP_RULESET_CACHE_DIR="$WORK_DIR/quota-cache" \
FORKOP_RULESET_CACHE_MANIFEST="$WORK_DIR/quota-cache/manifest.json" \
FORKOP_RULESET_RUNTIME_CACHE_DIR="$WORK_DIR/quota-runtime" \
FORKOP_RULESET_RUNTIME_MANIFEST="$WORK_DIR/quota-runtime-manifest.json" \
FORKOP_PERSISTENT_LIST_CACHE_DIR="$WORK_DIR/quota-list-cache" \
FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=8390000 \
  ucode -L "$FORKOP_LIB" "$RULESET_CACHE_UC" refresh >/dev/null
[ "$persistent_md5" = "$(md5sum "$persistent_path" | cut -d' ' -f1)" ] ||
  fail "RAM-only rule-set refresh replaced the persistent last-known-good copy"
cp "$WORK_DIR/quota-config.json" "$WORK_DIR/quota-rematerialized.json"
# Restore the remote declaration for a reload-style materialization.
cat >"$WORK_DIR/quota-rematerialized.json" <<'EOF_QUOTA_REMATERIALIZE'
{"route":{"rule_set":[{"type":"remote","tag":"quota","format":"source","url":"https://quota.test/rules.json"}]}}
EOF_QUOTA_REMATERIALIZE
FORKOP_RULESET_CACHE_DIR="$WORK_DIR/quota-cache" \
FORKOP_RULESET_CACHE_MANIFEST="$WORK_DIR/quota-cache/manifest.json" \
FORKOP_RULESET_RUNTIME_CACHE_DIR="$WORK_DIR/quota-runtime" \
FORKOP_RULESET_RUNTIME_MANIFEST="$WORK_DIR/quota-runtime-manifest.json" \
FORKOP_PERSISTENT_LIST_CACHE_DIR="$WORK_DIR/quota-list-cache" \
FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=8390000 \
  ucode -L "$FORKOP_LIB" "$RULESET_CACHE_UC" materialize-config "$WORK_DIR/quota-rematerialized.json" cache-only
runtime_path="$(ucode -e 'let fs=require("fs"); print(json(fs.readfile(ARGV[0])).route.rule_set[0].path)' "$WORK_DIR/quota-rematerialized.json")"
grep -Fq 'quota-new.test' "$runtime_path" || fail "reload did not retain the newer RAM-only rule-set"
case "$runtime_path" in
  "$WORK_DIR/quota-runtime"/*) ;;
  *) fail "low-flash rule-set was not served from runtime storage" ;;
esac

# If space becomes available later, identical runtime data is promoted to the
# persistent cache without requiring another rule change or service reload.
PATH="$WORK_DIR/bin:$PATH" \
RULESET_TEST_SOURCE_JSON="$WORK_DIR/quota-new.json" \
FORKOP_RULESET_CACHE_DIR="$WORK_DIR/quota-cache" \
FORKOP_RULESET_CACHE_MANIFEST="$WORK_DIR/quota-cache/manifest.json" \
FORKOP_RULESET_RUNTIME_CACHE_DIR="$WORK_DIR/quota-runtime" \
FORKOP_RULESET_RUNTIME_MANIFEST="$WORK_DIR/quota-runtime-manifest.json" \
FORKOP_PERSISTENT_LIST_CACHE_DIR="$WORK_DIR/quota-list-cache" \
FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=33554432 \
  ucode -L "$FORKOP_LIB" "$RULESET_CACHE_UC" refresh >/dev/null 2>&1 || true
grep -Fq 'quota-new.test' "$persistent_path" ||
  fail "runtime rule-set was not promoted when flash space became available"
[ ! -e "$runtime_path" ] || fail "promoted runtime rule-set copy was not removed"

printf 'ruleset cache checks passed\n'
