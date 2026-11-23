#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
UPDATES_UC="$FORKOP_LIB/components/updates.uc"
STATE_UC="$FORKOP_LIB/service/state.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/cache" "$WORK_DIR/runtime-rulesets" "$WORK_DIR/bin"
cat >"$WORK_DIR/uci.state" <<'EOF_UCI'
forkop.settings=settings
forkop.settings.update_interval=1d
forkop.alpha=section
forkop.alpha.enabled=1
forkop.alpha.action=connection
forkop.alpha.remote_domain_lists=https://lists.test/domains.txt
EOF_UCI
cat >"$WORK_DIR/cache/alpha-remote-domains-ruleset.json" <<'EOF_RULESET'
{"version":3,"rules":[{"domain_suffix":["old.example"]}]}
EOF_RULESET
printf 'cached.example\n' >"$WORK_DIR/cache/source-1"

signature="$(FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  ucode -L "$FORKOP_LIB" "$STATE_UC" list-update-signature)"
ruleset_md5="$(md5sum "$WORK_DIR/cache/alpha-remote-domains-ruleset.json" | cut -d' ' -f1)"
source_md5="$(md5sum "$WORK_DIR/cache/source-1" | cut -d' ' -f1)"
ruleset_size="$(wc -c <"$WORK_DIR/cache/alpha-remote-domains-ruleset.json")"
source_size="$(wc -c <"$WORK_DIR/cache/source-1")"
cat >"$WORK_DIR/cache/manifest.json" <<EOF_MANIFEST
{"format":"2","generation":"gen-persistent-fixture","signature":"$signature","files":[{"name":"alpha-remote-domains-ruleset.json","kind":"ruleset","size":$ruleset_size,"md5":"$ruleset_md5"},{"name":"source-1","kind":"source","url":"https://lists.test/domains.txt","source_format":"plain","size":$source_size,"md5":"$source_md5"}]}
EOF_MANIFEST
printf '2000000000\n' >"$WORK_DIR/cache/last-success.timestamp"

cache_cmd() {
  PATH="$WORK_DIR/bin:$PATH" \
  FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  FORKOP_PERSISTENT_LIST_CACHE_DIR="$WORK_DIR/cache" \
  FORKOP_RULESET_CACHE_DIR="$WORK_DIR/ruleset-cache" \
  FORKOP_PERSISTENT_LIST_CACHE_MANIFEST="$WORK_DIR/cache/manifest.json" \
  FORKOP_LIST_UPDATE_STATE_FILE="$WORK_DIR/cache/last-success.timestamp" \
  FORKOP_LIST_UPDATE_RUNTIME_STATE_FILE="$WORK_DIR/runtime-last-success.timestamp" \
  FORKOP_LIST_UPDATE_RUNTIME_SIGNATURE_FILE="$WORK_DIR/runtime-signature" \
  FORKOP_RUNTIME_LIST_GENERATION_DIR="$WORK_DIR/runtime-generation" \
  FORKOP_LIST_CACHE_LOG_STATE_FILE="$WORK_DIR/list-cache-log-state" \
  TMP_RULESET_FOLDER="$WORK_DIR/runtime-rulesets" \
  FORKOP_LIB="$FORKOP_LIB" \
    ucode -L "$FORKOP_LIB" "$UPDATES_UC" "$@"
}

cat >"$WORK_DIR/bin/curl" <<'EOF_CURL'
#!/bin/sh
printf 'network attempted\n' >>"$LIST_CACHE_WGET_LOG"
exit 1
EOF_CURL
chmod +x "$WORK_DIR/bin/curl"
cat >"$WORK_DIR/bin/logger" <<'EOF_LOGGER'
#!/bin/sh
printf '%s\n' "$*" >>"$LIST_CACHE_LOG"
EOF_LOGGER
chmod +x "$WORK_DIR/bin/logger"
export LIST_CACHE_WGET_LOG="$WORK_DIR/wget.log"
export LIST_CACHE_LOG="$WORK_DIR/cache.log"
export LIST_CACHE_MD5_LOG="$WORK_DIR/md5.log"
export REAL_MD5SUM="$(command -v md5sum)"
cat >"$WORK_DIR/bin/md5sum" <<'EOF_MD5'
#!/bin/sh
printf '%s\n' "$1" >> "$LIST_CACHE_MD5_LOG"
exec "$REAL_MD5SUM" "$@"
EOF_MD5
chmod +x "$WORK_DIR/bin/md5sum"
: >"$LIST_CACHE_WGET_LOG"
: >"$LIST_CACHE_LOG"

cache_cmd list-cache-valid || fail "valid persistent cache was rejected"
cache_cmd restore-list-cache || fail "valid persistent cache was not restored"
expected_bytes=$(($(wc -c <"$WORK_DIR/cache/source-1") + $(wc -c <"$WORK_DIR/cache/alpha-remote-domains-ruleset.json")))
grep -Fq "Restored 1 list sources and 1 rule-set files from persistent cache ($expected_bytes bytes); network access was not required" "$LIST_CACHE_LOG" ||
  fail "persistent cache restore summary was not logged"
restore_log_lines="$(wc -l <"$LIST_CACHE_LOG")"
cache_cmd restore-list-cache || fail "repeated persistent cache restore failed"
[ "$(wc -l <"$LIST_CACHE_LOG")" -eq "$restore_log_lines" ] ||
  fail "ordinary reload repeated the same persistent cache log message"
cmp "$WORK_DIR/cache/alpha-remote-domains-ruleset.json" \
  "$WORK_DIR/runtime-rulesets/alpha-remote-domains-ruleset.json" ||
  fail "restored materialized list differs from persistent cache"

# A newer RAM-only generation must survive reload preparation even when its
# timestamp would be equal to the persistent generation's timestamp.
rm -rf "$WORK_DIR/runtime-generation"
cp -a "$WORK_DIR/cache" "$WORK_DIR/runtime-generation"
cat >"$WORK_DIR/runtime-rulesets/alpha-remote-domains-ruleset.json" <<'EOF_RUNTIME_NEW'
{"version":3,"rules":[{"domain_suffix":["runtime-new.example"]}]}
EOF_RUNTIME_NEW
cat >"$WORK_DIR/runtime-generation/alpha-remote-domains-ruleset.json" <<'EOF_RUNTIME_GENERATION'
{"version":3,"rules":[{"domain_suffix":["runtime-new.example"]}]}
EOF_RUNTIME_GENERATION
printf 'runtime-new.example\n' >"$WORK_DIR/runtime-generation/source-1"
runtime_md5="$(md5sum "$WORK_DIR/runtime-generation/alpha-remote-domains-ruleset.json" | cut -d' ' -f1)"
runtime_size="$(wc -c <"$WORK_DIR/runtime-generation/alpha-remote-domains-ruleset.json")"
runtime_source_md5="$(md5sum "$WORK_DIR/runtime-generation/source-1" | cut -d' ' -f1)"
runtime_source_size="$(wc -c <"$WORK_DIR/runtime-generation/source-1")"
cat >"$WORK_DIR/runtime-generation/manifest.json" <<EOF_RUNTIME_MANIFEST
{"format":"2","generation":"gen-ram-fixture","signature":"$signature","files":[{"name":"alpha-remote-domains-ruleset.json","kind":"ruleset","size":$runtime_size,"md5":"$runtime_md5"},{"name":"source-1","kind":"source","url":"https://lists.test/domains.txt","source_format":"plain","size":$runtime_source_size,"md5":"$runtime_source_md5"}]}
EOF_RUNTIME_MANIFEST
printf '2000000000\n' >"$WORK_DIR/runtime-last-success.timestamp"
printf '%s\n' "$signature" >"$WORK_DIR/runtime-signature"
cache_cmd runtime-list-cache-active || fail "newer RAM-only list state was not recognized"
cache_cmd restore-list-cache || fail "RAM-only list state was rejected during reload preparation"
grep -Fq 'Using the newer RAM-only list generation from this boot' "$LIST_CACHE_LOG" ||
  fail "RAM-only list generation use was not logged"
grep -Fq 'runtime-new.example' "$WORK_DIR/runtime-rulesets/alpha-remote-domains-ruleset.json" ||
  fail "older persistent cache overwrote newer RAM-only lists"
: > "$LIST_CACHE_MD5_LOG"
cache_cmd apply-list-cache || fail "RAM-only list state could not bypass persistent cache application"
[ "$(grep -Fxc "$WORK_DIR/runtime-generation/source-1" "$LIST_CACHE_MD5_LOG")" = 1 ] ||
  fail "runtime cache recovery, restore and import repeated the source digest"
grep -Fq 'runtime-new.example' "$WORK_DIR/runtime-rulesets/alpha-remote-domains-ruleset.json" ||
  fail "persistent cache application overwrote newer RAM-only lists"

# A damaged RAM generation must never be used just because it exists.  The
# complete persistent generation is the only permitted fallback after its
# checksum validation succeeds.
printf 'corrupt\n' >>"$WORK_DIR/runtime-generation/source-1"
cache_cmd runtime-list-cache-active && fail "corrupt runtime generation was accepted"
cache_cmd restore-list-cache || fail "valid persistent generation did not replace corrupt RAM generation"

# A valid .previous must also repair an existing but corrupt active directory.
runtime_manifest_md5="$(md5sum "$WORK_DIR/runtime-generation/manifest.json" | cut -d' ' -f1)"
cp -a "$WORK_DIR/runtime-generation" "$WORK_DIR/runtime-generation.previous"
printf '{broken\n' >"$WORK_DIR/runtime-generation/manifest.json"
cache_cmd runtime-list-cache-active || fail "valid runtime .previous did not repair corrupt active generation"
[ "$runtime_manifest_md5" = "$(md5sum "$WORK_DIR/runtime-generation/manifest.json" | cut -d' ' -f1)" ] ||
  fail "runtime .previous recovery selected corrupt active data"
[ ! -e "$WORK_DIR/runtime-generation.previous" ] || fail "recovered runtime previous generation was not consumed"
grep -Fq 'old.example' "$WORK_DIR/runtime-rulesets/alpha-remote-domains-ruleset.json" ||
  fail "corrupt RAM generation was not replaced by persistent last-known-good data"

# An interrupted runtime publication recovers .previous and discards .stage
# before selecting an active generation.
mv "$WORK_DIR/runtime-generation" "$WORK_DIR/runtime-generation.previous"
mkdir -p "$WORK_DIR/runtime-generation.stage"
printf 'incomplete\n' >"$WORK_DIR/runtime-generation.stage/source-1"
cache_cmd runtime-list-cache-active || fail "runtime .previous generation was not recovered"
[ ! -e "$WORK_DIR/runtime-generation.previous" ] || fail "recovered runtime previous generation was not consumed"
[ ! -e "$WORK_DIR/runtime-generation.stage" ] || fail "incomplete runtime stage was not discarded"
rm -rf "$WORK_DIR/runtime-generation"

# Recover the previous complete generation if power is lost between the two
# atomic directory renames, and discard an untrusted incomplete stage.
mv "$WORK_DIR/cache" "$WORK_DIR/cache.previous"
mkdir -p "$WORK_DIR/cache.stage"
printf 'incomplete\n' >"$WORK_DIR/cache.stage/source-1"
cache_cmd list-cache-valid || fail "interrupted persistent cache swap was not recovered"
[ -d "$WORK_DIR/cache" ] || fail "previous persistent cache generation was not restored"
[ ! -e "$WORK_DIR/cache.previous" ] || fail "recovered previous cache generation was not consumed"
[ ! -e "$WORK_DIR/cache.stage" ] || fail "incomplete staged cache generation was not removed"

# Local routing conditions do not invalidate source cache identity.
sed -i 's/forkop.alpha.action=connection/forkop.alpha.action=block/' "$WORK_DIR/uci.state"
cache_cmd list-cache-valid || fail "local action change invalidated list cache"

cache_cmd apply-list-cache || fail "cached sources could not be applied offline"
[ ! -s "$LIST_CACHE_WGET_LOG" ] || fail "offline cache application attempted network I/O"
grep -Fq 'cached.example' "$WORK_DIR/runtime-rulesets/alpha-remote-domains-ruleset.json" ||
  fail "cached source content was not materialized"

# A malformed manifest is a fail-safe cache rejection, not a partial restore.
rm -rf "$WORK_DIR/runtime-generation"
cp "$WORK_DIR/cache/manifest.json" "$WORK_DIR/cache/manifest.valid"
printf '{broken\n' >"$WORK_DIR/cache/manifest.json"
cache_cmd list-cache-valid && fail "corrupt manifest was accepted"
cache_cmd restore-list-cache && fail "corrupt manifest was restored"
mv "$WORK_DIR/cache/manifest.valid" "$WORK_DIR/cache/manifest.json"

# A matching checksum cannot make malformed rule-set JSON acceptable.
cp "$WORK_DIR/cache/manifest.json" "$WORK_DIR/cache/manifest.schema-valid"
cp "$WORK_DIR/cache/alpha-remote-domains-ruleset.json" "$WORK_DIR/cache/ruleset.schema-valid"
printf '{broken\n' >"$WORK_DIR/cache/alpha-remote-domains-ruleset.json"
broken_ruleset_md5="$(md5sum "$WORK_DIR/cache/alpha-remote-domains-ruleset.json" | cut -d' ' -f1)"
sed -i "s/$ruleset_md5/$broken_ruleset_md5/" "$WORK_DIR/cache/manifest.json"
cache_cmd list-cache-valid && fail "checksum-matching malformed JSON ruleset was accepted"
mv "$WORK_DIR/cache/manifest.schema-valid" "$WORK_DIR/cache/manifest.json"
mv "$WORK_DIR/cache/ruleset.schema-valid" "$WORK_DIR/cache/alpha-remote-domains-ruleset.json"

# Source changes and corruption must be rejected before use.
sed -i 's#domains.txt#changed.txt#' "$WORK_DIR/uci.state"
if cache_cmd list-cache-valid; then
  fail "changed source URL reused a stale cache generation"
fi
sed -i 's#changed.txt#domains.txt#' "$WORK_DIR/uci.state"
printf 'corrupt\n' >>"$WORK_DIR/cache/source-1"
if cache_cmd list-cache-valid; then
  fail "corrupt cached source was accepted"
fi
cache_cmd restore-list-cache && fail "corrupt cached source was restored"
grep -Eq '^rejected-(size|md5)-source-1$' "$WORK_DIR/list-cache-log-state" ||
  fail "corrupt source cache rejection reason was not recorded"

# Flash quota applies only to persistence. With 10 MiB available and an
# 8 MiB reserve, a 1 MiB generation fits while a 3 MiB generation does not.
FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=10485760 \
FORKOP_PERSISTENT_LIST_CACHE_MAX_BYTES=8388608 \
FORKOP_PERSISTENT_LIST_CACHE_MIN_FREE_BYTES=8388608 \
  cache_cmd list-cache-capacity 1048576 ||
  fail "a cache generation fitting above the flash reserve was rejected"
if FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=10485760 \
  FORKOP_PERSISTENT_LIST_CACHE_MAX_BYTES=8388608 \
  FORKOP_PERSISTENT_LIST_CACHE_MIN_FREE_BYTES=8388608 \
    cache_cmd list-cache-capacity 3145728; then
  fail "a cache generation crossing the flash reserve was accepted"
fi
if FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=33554432 \
  FORKOP_PERSISTENT_LIST_CACHE_MAX_BYTES=8388608 \
  FORKOP_PERSISTENT_LIST_CACHE_MIN_FREE_BYTES=8388608 \
    cache_cmd list-cache-capacity 9437184; then
  fail "a cache generation exceeding the absolute quota was accepted"
fi
mkdir -p "$WORK_DIR/ruleset-cache"
dd if=/dev/zero of="$WORK_DIR/ruleset-cache/existing.srs" bs=1024 count=7680 2>/dev/null
if FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=33554432 \
  FORKOP_PERSISTENT_LIST_CACHE_MAX_BYTES=8388608 \
  FORKOP_PERSISTENT_LIST_CACHE_MIN_FREE_BYTES=8388608 \
    cache_cmd list-cache-capacity 1048576; then
  fail "combined list and remote rule-set caches exceeded the shared quota"
fi
rm -rf "$WORK_DIR/ruleset-cache"

# A failed persistence attempt must leave the previous complete cache intact.
mkdir -p "$WORK_DIR/quota-runtime" "$WORK_DIR/quota-cache"
cat >"$WORK_DIR/quota-runtime/alpha-lists-ruleset.json" <<'EOF_QUOTA_RULESET'
{"version":3,"rules":[{"domain_suffix":["first.example"]}]}
EOF_QUOTA_RULESET
head -c 1048576 /dev/zero | tr '\000' ' ' >> "$WORK_DIR/quota-runtime/alpha-lists-ruleset.json"
quota_cmd() {
  FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  FORKOP_PERSISTENT_LIST_CACHE_DIR="$WORK_DIR/quota-cache" \
  FORKOP_RULESET_CACHE_DIR="$WORK_DIR/quota-ruleset-cache" \
  FORKOP_PERSISTENT_LIST_CACHE_MANIFEST="$WORK_DIR/quota-cache/manifest.json" \
  FORKOP_LIST_UPDATE_STATE_FILE="$WORK_DIR/quota-cache/last-success.timestamp" \
  FORKOP_RUNTIME_LIST_GENERATION_DIR="$WORK_DIR/quota-generation" \
  TMP_RULESET_FOLDER="$WORK_DIR/quota-runtime" \
  FORKOP_LIB="$FORKOP_LIB" \
    ucode -L "$FORKOP_LIB" "$UPDATES_UC" "$@"
}
quota_cmd commit-runtime-list-generation || fail "a runtime generation was not committed"
unchanged_generation_manifest="$(md5sum "$WORK_DIR/quota-generation/manifest.json" | cut -d' ' -f1)"
quota_cmd commit-runtime-list-generation || fail "an identical runtime generation was rejected"
[ "$unchanged_generation_manifest" = "$(md5sum "$WORK_DIR/quota-generation/manifest.json" | cut -d' ' -f1)" ] ||
  fail "an identical validated generation replaced the active generation"
[ ! -e "$WORK_DIR/quota-generation.stage" ] ||
  fail "an identical validated generation retained staging material"
FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=33554432 quota_cmd persist-list-cache 100 ||
  fail "a fitting persistent cache was not committed"
first_md5="$(md5sum "$WORK_DIR/quota-cache/alpha-lists-ruleset.json" | cut -d' ' -f1)"
payload_inode="$(stat -c %i "$WORK_DIR/quota-cache/alpha-lists-ruleset.json")"
manifest_inode="$(stat -c %i "$WORK_DIR/quota-cache/manifest.json")"
FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=8392704 quota_cmd persist-list-cache 101 ||
  fail "an unchanged generation could not refresh its timestamp alone"
[ "$(stat -c %i "$WORK_DIR/quota-cache/alpha-lists-ruleset.json")" = "$payload_inode" ] &&
  [ "$(stat -c %i "$WORK_DIR/quota-cache/manifest.json")" = "$manifest_inode" ] &&
  [ "$(cat "$WORK_DIR/quota-cache/last-success.timestamp")" = 101 ] ||
  fail "an unchanged generation replaced files other than its timestamp"
[ ! -e "$WORK_DIR/quota-cache.stage" ] || fail "unchanged cache created a full staging generation"
printf 'Unchanged refresh writes %s timestamp bytes while retaining %s checked payload bytes\n' \
    "$(wc -c < "$WORK_DIR/quota-cache/last-success.timestamp")" \
    "$(wc -c < "$WORK_DIR/quota-cache/alpha-lists-ruleset.json")"
cat >"$WORK_DIR/quota-runtime/alpha-lists-ruleset.json" <<'EOF_QUOTA_CHANGED'
{"version":3,"rules":[{"domain_suffix":["second.example"]}]}
EOF_QUOTA_CHANGED
quota_cmd commit-runtime-list-generation || fail "changed runtime generation was not committed"
if FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=8390000 quota_cmd persist-list-cache 200; then
  fail "persistent cache committed despite violating the free-space reserve"
fi
[ "$first_md5" = "$(md5sum "$WORK_DIR/quota-cache/alpha-lists-ruleset.json" | cut -d' ' -f1)" ] ||
  fail "failed persistence replaced the previous complete cache"
[ "$(cat "$WORK_DIR/quota-cache/last-success.timestamp")" = 101 ] ||
  fail "failed persistence changed the previous success timestamp"

# Every pre-publication runtime failure retains the old active generation and
# leaves no trusted stage behind. The environment switch is intentionally a
# test hook; production leaves it unset.
runtime_before="$(md5sum "$WORK_DIR/quota-generation/manifest.json" | cut -d' ' -f1)"
for phase in runtime-stage-create runtime-file-write runtime-manifest-write runtime-validate runtime-rename-previous; do
  if FORKOP_LIST_GENERATION_FAIL_PHASE="$phase" quota_cmd commit-runtime-list-generation; then
    fail "runtime failure injection '$phase' unexpectedly committed"
  fi
  quota_cmd runtime-list-cache-active || fail "runtime active generation was lost after '$phase'"
  [ "$runtime_before" = "$(md5sum "$WORK_DIR/quota-generation/manifest.json" | cut -d' ' -f1)" ] ||
    fail "runtime failure '$phase' changed active generation"
  [ ! -e "$WORK_DIR/quota-generation.stage" ] || fail "runtime failure '$phase' retained stage"
done

if FORKOP_LIST_DOWNLOAD_MIN_FREE_BYTES=999999999999 quota_cmd commit-runtime-list-generation; then
  fail "runtime generation committed despite insufficient /tmp capacity"
fi
quota_cmd runtime-list-cache-active || fail "runtime active generation was lost after /tmp capacity failure"

# Interruption after active -> .previous recovers the old complete generation;
# the fully written but unpublished stage is discarded.
if FORKOP_LIST_GENERATION_FAIL_PHASE=runtime-rename-active quota_cmd commit-runtime-list-generation; then
  fail "runtime rename-active injection unexpectedly committed"
fi
[ -d "$WORK_DIR/quota-generation.previous" ] || fail "runtime previous was not retained after interrupted swap"
quota_cmd runtime-list-cache-active || fail "runtime interrupted swap did not recover previous"
[ "$runtime_before" = "$(md5sum "$WORK_DIR/quota-generation/manifest.json" | cut -d' ' -f1)" ] ||
  fail "runtime interrupted swap selected unpublished stage"
[ ! -e "$WORK_DIR/quota-generation.stage" ] || fail "runtime interrupted swap retained stage"

FORKOP_LIST_GENERATION_FAIL_PHASE=runtime-cleanup-previous quota_cmd commit-runtime-list-generation ||
  fail "runtime cleanup interruption did not publish complete active generation"
[ -d "$WORK_DIR/quota-generation.previous" ] || fail "runtime cleanup injection did not retain previous"
quota_cmd runtime-list-cache-active || fail "runtime generation was invalid after cleanup interruption"
[ ! -e "$WORK_DIR/quota-generation.previous" ] || fail "runtime recovery did not clean stale previous"

# Persistent failures before publication never replace the known-good flash
# cache. An interruption between the two renames is recovered from .previous.
for phase in persistent-stage-create persistent-file-write persistent-manifest-write persistent-validate persistent-rename-previous; do
  if FORKOP_LIST_GENERATION_FAIL_PHASE="$phase" FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=33554432 quota_cmd persist-list-cache 300; then
    fail "persistent failure injection '$phase' unexpectedly committed"
  fi
  quota_cmd list-cache-valid || fail "persistent LKG was lost after '$phase'"
  [ "$first_md5" = "$(md5sum "$WORK_DIR/quota-cache/alpha-lists-ruleset.json" | cut -d' ' -f1)" ] ||
    fail "persistent failure '$phase' replaced LKG"
  [ ! -e "$WORK_DIR/quota-cache.stage" ] || fail "persistent failure '$phase' retained stage"
done

if FORKOP_LIST_GENERATION_FAIL_PHASE=persistent-rename-active FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=33554432 quota_cmd persist-list-cache 400; then
  fail "persistent rename-active injection unexpectedly committed"
fi
[ -d "$WORK_DIR/quota-cache.previous" ] || fail "persistent previous was not retained after interrupted swap"
quota_cmd list-cache-valid || fail "persistent interrupted swap did not recover LKG"
[ "$first_md5" = "$(md5sum "$WORK_DIR/quota-cache/alpha-lists-ruleset.json" | cut -d' ' -f1)" ] ||
  fail "persistent interrupted swap selected unpublished stage"
[ ! -e "$WORK_DIR/quota-cache.stage" ] || fail "persistent interrupted swap retained stage"

FORKOP_LIST_GENERATION_FAIL_PHASE=persistent-cleanup-previous FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=33554432 quota_cmd persist-list-cache 500 ||
  fail "persistent cleanup interruption did not publish complete cache"
[ -d "$WORK_DIR/quota-cache.previous" ] || fail "persistent cleanup injection did not retain previous"
quota_cmd list-cache-valid || fail "persistent generation was invalid after cleanup interruption"
[ ! -e "$WORK_DIR/quota-cache.previous" ] || fail "persistent recovery did not clean stale previous"

# A real 1.3.8 cache uses format 1: a ruleset checksum map plus a separate
# source array. Upgrading must convert it offline into a staged v2 generation,
# then use the ordinary v2 restore path. It must never be treated as v2 in
# place, and an invalid v1 cache must remain untouched.
mkdir -p "$WORK_DIR/legacy-v1" "$WORK_DIR/legacy-runtime-rulesets"
cat >"$WORK_DIR/legacy-v1/alpha-remote-domains-ruleset.json" <<'EOF_LEGACY_RULESET'
{"version":3,"rules":[{"domain_suffix":["upgrade.example"]}]}
EOF_LEGACY_RULESET
printf 'upgrade.example\n' >"$WORK_DIR/legacy-v1/source-1"
legacy_ruleset_md5="$(md5sum "$WORK_DIR/legacy-v1/alpha-remote-domains-ruleset.json" | cut -d' ' -f1)"
legacy_source_md5="$(md5sum "$WORK_DIR/legacy-v1/source-1" | cut -d' ' -f1)"
cat >"$WORK_DIR/legacy-v1/manifest.json" <<EOF_LEGACY_MANIFEST
{"format":"1","signature":"$signature","files":{"alpha-remote-domains-ruleset.json":"$legacy_ruleset_md5"},"sources":[{"name":"source-1","url":"https://lists.test/domains.txt","format":"plain","md5":"$legacy_source_md5"}]}
EOF_LEGACY_MANIFEST
printf '123\n' >"$WORK_DIR/legacy-v1/last-success.timestamp"
cp -a "$WORK_DIR/legacy-v1" "$WORK_DIR/legacy-v1-invalid"
legacy_cmd() {
  PATH="$WORK_DIR/bin:$PATH" \
  FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  FORKOP_PERSISTENT_LIST_CACHE_DIR="$WORK_DIR/legacy-v1" \
  FORKOP_RULESET_CACHE_DIR="$WORK_DIR/legacy-ruleset-cache" \
  FORKOP_PERSISTENT_LIST_CACHE_MANIFEST="$WORK_DIR/legacy-v1/manifest.json" \
  FORKOP_LIST_UPDATE_STATE_FILE="$WORK_DIR/legacy-v1/last-success.timestamp" \
  FORKOP_LIST_UPDATE_RUNTIME_STATE_FILE="$WORK_DIR/legacy-runtime-last-success.timestamp" \
  FORKOP_LIST_UPDATE_RUNTIME_SIGNATURE_FILE="$WORK_DIR/legacy-runtime-signature" \
  FORKOP_RUNTIME_LIST_GENERATION_DIR="$WORK_DIR/legacy-runtime-generation" \
  FORKOP_LIST_CACHE_LOG_STATE_FILE="$WORK_DIR/legacy-log-state" \
  FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=33554432 \
  TMP_RULESET_FOLDER="$WORK_DIR/legacy-runtime-rulesets" \
  FORKOP_LIB="$FORKOP_LIB" \
    ucode -L "$FORKOP_LIB" "$UPDATES_UC" "$@"
}
: >"$LIST_CACHE_WGET_LOG"
legacy_cmd list-cache-valid || fail "valid 1.3.8 v1 cache was not migrated to v2"
[ "$(ucode -e 'print(json(require("fs").readfile(ARGV[0])).format)' "$WORK_DIR/legacy-v1/manifest.json")" = 2 ] ||
  fail "v1 cache was not replaced by a v2 manifest"
legacy_cmd restore-list-cache || fail "migrated v2 cache was not restored offline"
[ ! -s "$LIST_CACHE_WGET_LOG" ] || fail "v1 to v2 migration attempted network I/O"
grep -Fq 'upgrade.example' "$WORK_DIR/legacy-runtime-rulesets/alpha-remote-domains-ruleset.json" ||
  fail "migrated v2 cache did not restore the 1.3.8 ruleset"
legacy_manifest_md5="$(md5sum "$WORK_DIR/legacy-v1/manifest.json" | cut -d' ' -f1)"
legacy_cmd list-cache-valid || fail "migrated v2 cache was not idempotently valid"
[ "$legacy_manifest_md5" = "$(md5sum "$WORK_DIR/legacy-v1/manifest.json" | cut -d' ' -f1)" ] ||
  fail "revalidating a migrated cache changed its v2 generation"

printf 'corrupt\n' >>"$WORK_DIR/legacy-v1-invalid/source-1"
legacy_bad_cmd() {
  FORKOP_PERSISTENT_LIST_CACHE_DIR="$WORK_DIR/legacy-v1-invalid" \
  FORKOP_PERSISTENT_LIST_CACHE_MANIFEST="$WORK_DIR/legacy-v1-invalid/manifest.json" \
  FORKOP_LIST_UPDATE_STATE_FILE="$WORK_DIR/legacy-v1-invalid/last-success.timestamp" \
  FORKOP_RUNTIME_LIST_GENERATION_DIR="$WORK_DIR/legacy-invalid-runtime-generation" \
  FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=33554432 \
  FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" TMP_RULESET_FOLDER="$WORK_DIR/legacy-invalid-rulesets" \
  FORKOP_LIB="$FORKOP_LIB" ucode -L "$FORKOP_LIB" "$UPDATES_UC" "$@"
}
legacy_bad_cmd list-cache-valid && fail "corrupt v1 cache was migrated"
[ "$(ucode -e 'print(json(require("fs").readfile(ARGV[0])).format)' "$WORK_DIR/legacy-v1-invalid/manifest.json")" = 1 ] ||
  fail "failed v1 migration destroyed its LKG"
[ ! -e "$WORK_DIR/legacy-v1-invalid.stage" ] || fail "failed v1 migration retained a stage"

# The streaming limit wrapper must retain the explicitly selected service proxy.
cat >"$WORK_DIR/bin/curl" <<'EOF_PROXY_CURL'
#!/bin/sh
proxy=0
output=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = -x ] && [ "${2:-}" = 'http://127.0.0.1:18080' ]; then
    proxy=1
    shift
  elif [ "$1" = -o ]; then
    output="$2"
    shift
  fi
  shift
done
[ "$proxy" = 1 ] && [ -n "$output" ] || exit 1
printf 'proxied.example\n' >"$output"
EOF_PROXY_CURL
chmod +x "$WORK_DIR/bin/curl"
PATH="$WORK_DIR/bin:$PATH" FORKOP_LIST_DOWNLOAD_MIN_FREE_BYTES=0 FORKOP_LIB="$FORKOP_LIB" \
  ucode -L "$FORKOP_LIB" "$UPDATES_UC" download-list-file \
    https://lists.test/proxied "$WORK_DIR/proxied" 127.0.0.1:18080 ||
  fail "temporary-space limit wrapper dropped the selected service proxy"
grep -Fq 'proxied.example' "$WORK_DIR/proxied" || fail "proxied fixture download was not written"

printf 'persistent list cache checks passed\n'
