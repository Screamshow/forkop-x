#!/bin/sh
set -eu
LIB=${FORKOP_LIB:-/usr/lib/forkop}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
export FORKOP_RUNTIME_LIST_GENERATION_DIR="$WORK/runtime-generation"
mkdir -p "$WORK/runtime" "$WORK/persistent"
printf '{"version":3,"rules":[{"domain_suffix":["iana.org"]}]}' > "$WORK/runtime/baseline-lists-ruleset.json"
printf 'stale-cache' > "$WORK/persistent/manifest.json"
FORKOP_PERSISTENT_LIST_CACHE_DIR="$WORK/persistent" TMP_RULESET_FOLDER="$WORK/runtime" \
    ucode -L "$LIB" "$LIB/components/updates.uc" invalidate-list-cache preserve-runtime
[ ! -e "$WORK/persistent" ] || { echo 'Persistent cache survived invalidation'; exit 1; }
[ -s "$WORK/runtime/baseline-lists-ruleset.json" ] || { echo 'Applied local list was removed'; exit 1; }
FORKOP_PERSISTENT_LIST_CACHE_DIR="$WORK/persistent" TMP_RULESET_FOLDER="$WORK/runtime" \
    ucode -L "$LIB" "$LIB/components/updates.uc" invalidate-list-cache
[ ! -e "$WORK/runtime/baseline-lists-ruleset.json" ] || { echo 'Explicit runtime invalidation failed'; exit 1; }
echo 'List cache invalidation preserves applied runtime files when requested'
