#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/forkop/files/usr/lib"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/cache"
export FORKOP_RULESET_CACHE_DIR="$WORK/cache"
export FORKOP_RULESET_CACHE_MANIFEST="$WORK/cache/manifest.json"
export FORKOP_RULESET_RUNTIME_CACHE_DIR="$WORK/runtime"
export FORKOP_RULESET_RUNTIME_MANIFEST="$WORK/runtime-manifest.json"
export FORKOP_PERSISTENT_LIST_CACHE_DIR="$WORK/list-cache"
export PATH="$WORK/bin:$PATH"
cat > "$WORK/bin/curl" <<'EOF'
#!/bin/sh
[ "${TEST_DOWNLOAD_FAIL:-0}" = 0 ] || exit 22
while [ "$#" -gt 0 ]; do
 case "$1" in --output) output="$2"; shift 2;; *) shift;; esac
done
if [ "${TEST_INVALID_SOURCE:-0}" = 1 ]; then
    printf '{"version":"invalid","rules":[{"domain_suffix":["candidate.example"]}]}' > "$output"
elif [ "${TEST_NEW_SOURCE:-0}" = 1 ]; then
    printf '{"version":1,"rules":[{"domain_suffix":["candidate.example"]}]}' > "$output"
else
    printf '{"version":1,"rules":[{"domain_suffix":["tiktok.com"]}]}' > "$output"
fi
EOF
chmod +x "$WORK/bin/curl"
printf '{"route":{"rule_set":[{"type":"remote","tag":"tiktok","format":"source","url":"https://example.test/tiktok.json"}]}}' > "$WORK/candidate.json"
cp "$WORK/candidate.json" "$WORK/original.json"
printf '{"old":{"url":"https://example.test/old.json"}}' > "$FORKOP_RULESET_CACHE_MANIFEST"
cp "$FORKOP_RULESET_CACHE_MANIFEST" "$WORK/old-manifest.json"
if TEST_DOWNLOAD_FAIL=1 ucode -L "$LIB" "$LIB/xrust/ruleset_cache.uc" materialize-config "$WORK/candidate.json" required; then
 echo 'Failed download was accepted'; exit 1
fi
cmp "$WORK/candidate.json" "$WORK/original.json"
cmp "$FORKOP_RULESET_CACHE_MANIFEST" "$WORK/old-manifest.json"
ucode -L "$LIB" "$LIB/xrust/ruleset_cache.uc" materialize-config "$WORK/candidate.json" required
path=$(ucode -e 'let fs=require("fs"); print(json(fs.readfile(ARGV[0])).route.rule_set[0].path)' "$WORK/candidate.json")
grep -q tiktok.com "$path"
cp "$FORKOP_RULESET_CACHE_MANIFEST" "$WORK/valid-manifest.json"
status=0
TEST_INVALID_SOURCE=1 ucode -L "$LIB" "$LIB/xrust/ruleset_cache.uc" refresh || status=$?
[ "$status" -eq 2 ]
cmp "$WORK/valid-manifest.json" "$FORKOP_RULESET_CACHE_MANIFEST"
grep -q tiktok.com "$path"
# Existing verified data must work with the network unavailable.
cp "$WORK/original.json" "$WORK/candidate.json"
TEST_DOWNLOAD_FAIL=1 ucode -L "$LIB" "$LIB/xrust/ruleset_cache.uc" materialize-config "$WORK/candidate.json" required
# A generated but unacknowledged config may download a new list. Both
# schedules must stay byte-for-byte unchanged until it has been applied.
cp "$FORKOP_RULESET_CACHE_MANIFEST" "$WORK/prior-flash.json"
cp "$FORKOP_RULESET_RUNTIME_MANIFEST" "$WORK/prior-runtime.json"
sed 's@tiktok.json@candidate.json@g' "$WORK/original.json" > "$WORK/staged.json"
TEST_NEW_SOURCE=1 ucode -L "$LIB" "$LIB/xrust/ruleset_cache.uc" materialize-config "$WORK/staged.json" required stage
cmp "$WORK/prior-flash.json" "$FORKOP_RULESET_CACHE_MANIFEST"
cmp "$WORK/prior-runtime.json" "$FORKOP_RULESET_RUNTIME_MANIFEST"
[ -s "$WORK/staged.json.rulesets" ]
FORKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/xrust/runtime.uc" discard-config-stage "$WORK/staged.json"
[ ! -e "$WORK/staged.json.rulesets" ]
cmp "$WORK/prior-flash.json" "$FORKOP_RULESET_CACHE_MANIFEST"
cmp "$WORK/prior-runtime.json" "$FORKOP_RULESET_RUNTIME_MANIFEST"
sed 's@tiktok.json@candidate.json@g' "$WORK/original.json" > "$WORK/staged.json"
TEST_NEW_SOURCE=1 ucode -L "$LIB" "$LIB/xrust/ruleset_cache.uc" materialize-config "$WORK/staged.json" required stage
mkdir "$WORK/unwritable-runtime-file"
if FORKOP_RULESET_RUNTIME_MANIFEST="$WORK/unwritable-runtime-file" \
    FORKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/xrust/runtime.uc" commit-ruleset-stage "$WORK/staged.json"; then
    echo 'Failed runtime schedule publication accepted'; exit 1
fi
cmp "$WORK/prior-flash.json" "$FORKOP_RULESET_CACHE_MANIFEST"
[ -s "$WORK/staged.json.rulesets" ]
FORKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/xrust/runtime.uc" commit-ruleset-stage "$WORK/staged.json"
[ ! -e "$WORK/staged.json.rulesets" ]
grep -q candidate.json "$FORKOP_RULESET_CACHE_MANIFEST"
# Removal drops the declaration while retaining rollback data during staging.
printf '{"route":{"rule_set":[]}}' > "$WORK/candidate.json"
ucode -L "$LIB" "$LIB/xrust/ruleset_cache.uc" materialize-config "$WORK/candidate.json" required
[ -e "$path" ]
! grep -q tiktok "$WORK/candidate.json"
! grep -q tiktok "$FORKOP_RULESET_CACHE_MANIFEST"
printf 'user data' > "$WORK/cache/unmanaged.txt"
mkdir -p "$WORK/runtime"
printf '{}' > "$WORK/runtime/empty-0123456789ab.json"
FORKOP_SING_BOX_CONFIG_PATH="$WORK/candidate.json" ucode -L "$LIB" "$LIB/xrust/ruleset_cache.uc" prune-applied
[ ! -e "$path" ]
[ ! -e "$WORK/runtime/empty-0123456789ab.json" ]
[ -e "$WORK/cache/unmanaged.txt" ]
echo 'Required list download, rejection, offline reuse and removal passed'
