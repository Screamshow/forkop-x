#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_SRC="$ROOT_DIR/forkop/files/usr/lib"
FORKOP_ENTRY="$ROOT_DIR/forkop/files/usr/bin/forkop"
INITD="$ROOT_DIR/forkop/files/etc/init.d/forkop"
WORK_DIR="$(mktemp -d)"

# The suite points FORKOP_LIB at the checkout. The cache resolves its own source
# directory from FORKOP_SOURCE_LIB, and the entrypoint checks below set
# FORKOP_LIB deliberately, so an inherited value must not reach them.
unset FORKOP_LIB FORKOP_SOURCE_LIB FORKOP_BYTECODE_CACHE FORKOP_BYTECODE_CACHE_DIR
unset FORKOP_UCODE_BIN FORKOP_BYTECODE_VALIDATION_TTL

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

SOURCE_DIR="$WORK_DIR/lib"
CACHE_DIR="$WORK_DIR/cache"
mkdir -p "$SOURCE_DIR/core" "$SOURCE_DIR/config" "$SOURCE_DIR/service"

# A miniature library: one leaf module the cache self-check loads, one module
# that imports it, one entry script, and one non-module payload file.
cat >"$SOURCE_DIR/config/domain.uc" <<'UCODE'
#!/usr/bin/env ucode
return { marker: "domain-v1" };
UCODE

cat >"$SOURCE_DIR/core/probe.uc" <<'UCODE'
#!/usr/bin/env ucode
let domain = require("config.domain");
return { marker: "probe-" + domain.marker };
UCODE

cat >"$SOURCE_DIR/service/entry.uc" <<'UCODE'
#!/usr/bin/env ucode
let probe = require("core.probe");
print(probe.marker, "\n");
UCODE

printf 'payload\n' >"$SOURCE_DIR/core/payload.txt"

# A proven manifest is trusted for a few seconds, which would hide the staleness
# the checks below are about; full validation is what they exercise.
bytecode() {
  local source_dir="$1" cache_dir="$2" call="$3"
  shift 3
  env FORKOP_SOURCE_LIB="$source_dir" FORKOP_BYTECODE_CACHE_DIR="$cache_dir" \
    FORKOP_BYTECODE_VALIDATION_TTL=0 "$@" \
    ucode -L "$LIB_SRC" -e "
      let bytecode = require(\"core.bytecode\");
      print(bytecode.$call(), \"\n\");
    "
}

resolve() {
  bytecode "$SOURCE_DIR" "$CACHE_DIR" refresh "$@"
}

resolve_only() {
  bytecode "$SOURCE_DIR" "$CACHE_DIR" library_dir "$@"
}

is_bytecode() {
  head -c 64 "$1" | grep -qaF $'\x1bucb'
}

# The self-check module has to exist in the shipped library, or the cache would
# refuse every build and quietly leave the sources in charge forever.
self_check_module="$(sed -n 's/^const SELF_CHECK_MODULE = "\(.*\)";$/\1/p' "$LIB_SRC/core/bytecode.uc")"
[ -n "$self_check_module" ] ||
  fail "core/bytecode.uc must name a self-check module"
[ -f "$LIB_SRC/${self_check_module//.//}.uc" ] ||
  fail "the self-check module $self_check_module is missing from the library"

built="$(resolve)"
[ "$built" != "$SOURCE_DIR" ] ||
  fail "a healthy library must compile into a cache directory"
[ -f "$CACHE_DIR/manifest" ] ||
  fail "a published cache must leave a manifest behind"

for module in config/domain.uc core/probe.uc service/entry.uc; do
  [ -f "$built/$module" ] ||
    fail "cache must carry $module"
  is_bytecode "$built/$module" ||
    fail "$module must be stored as bytecode"
done

# Files that are not modules are still needed by whatever reads them relative to
# the library directory, so they are carried over verbatim.
[ "$(cat "$built/core/payload.txt")" = "payload" ] ||
  fail "non-module files must be copied into the cache unchanged"

# What matters is that the cached library behaves exactly like the sources, both
# for `require` resolution and for an entry script executed by path.
source_out="$(ucode -L "$SOURCE_DIR" "$SOURCE_DIR/service/entry.uc")"
cache_out="$(ucode -L "$built" "$built/service/entry.uc")"
[ "$source_out" = "probe-domain-v1" ] ||
  fail "source library must print probe-domain-v1, got '$source_out'"
[ "$cache_out" = "$source_out" ] ||
  fail "cached library must behave like the sources: '$cache_out' != '$source_out'"

# A second resolve must reuse the published cache instead of compiling again.
reused="$(resolve)"
[ "$reused" = "$built" ] ||
  fail "an up-to-date cache must be reused, got '$reused' instead of '$built'"

# Editing an installed module is how a module gets copied onto a router during
# development. The manifest records size, mtime and inode, so the stale cache
# has to be rejected and rebuilt rather than silently kept.
sleep 1
cat >"$SOURCE_DIR/config/domain.uc" <<'UCODE'
#!/usr/bin/env ucode
return { marker: "domain-v2" };
UCODE

stale="$(resolve_only)"
[ "$stale" = "$SOURCE_DIR" ] ||
  fail "a cache built from replaced sources must not be resolved, got '$stale'"

rebuilt="$(resolve)"
[ "$rebuilt" != "$SOURCE_DIR" ] && [ "$rebuilt" != "$built" ] ||
  fail "replaced sources must produce a new cache directory, got '$rebuilt'"
rebuilt_out="$(ucode -L "$rebuilt" "$rebuilt/service/entry.uc")"
[ "$rebuilt_out" = "probe-domain-v2" ] ||
  fail "rebuilt cache must carry the new sources, got '$rebuilt_out'"

# A module added beside unchanged siblings leaves every recorded file signature
# intact, so the directory listing is what has to notice it.
cat >"$SOURCE_DIR/core/added.uc" <<'UCODE'
#!/usr/bin/env ucode
return { marker: "added-v1" };
UCODE
[ "$(resolve_only)" = "$SOURCE_DIR" ] ||
  fail "a module added beside unchanged siblings must invalidate the cache"
with_added="$(resolve)"
[ -f "$with_added/core/added.uc" ] ||
  fail "the added module must reach the rebuilt cache"
rm -f "$SOURCE_DIR/core/added.uc"
[ "$(resolve_only)" = "$SOURCE_DIR" ] ||
  fail "a removed module must invalidate the cache"
without_added="$(resolve)"
[ ! -e "$without_added/core/added.uc" ] ||
  fail "a removed module must not survive in the rebuilt cache"

# A newer interpreter writes a bytecode format the running one refuses, so the
# recorded interpreter identity has to invalidate the cache as well.
FAKE_UCODE_DIR="$WORK_DIR/bin"
mkdir -p "$FAKE_UCODE_DIR"
printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v ucode)" >"$FAKE_UCODE_DIR/ucode"
chmod +x "$FAKE_UCODE_DIR/ucode"
with_fake_ucode="$(
  bytecode "$SOURCE_DIR" "$CACHE_DIR" library_dir FORKOP_UCODE_BIN="$FAKE_UCODE_DIR/ucode"
)"
[ "$with_fake_ucode" = "$SOURCE_DIR" ] ||
  fail "a different interpreter must invalidate the cache, got '$with_fake_ucode'"

# Revalidating costs a stat per module, so a proven manifest is trusted for a
# few seconds. A package upgrade drops that stamp, which is the only thing
# standing between a replaced library and a few seconds of the old one.
stamped="$(bytecode "$SOURCE_DIR" "$CACHE_DIR" refresh FORKOP_BYTECODE_VALIDATION_TTL=60)"
[ -f "$CACHE_DIR/validated" ] ||
  fail "a proven manifest must leave a validation stamp"
sleep 1
cat >"$SOURCE_DIR/config/domain.uc" <<'UCODE'
#!/usr/bin/env ucode
return { marker: "domain-v3" };
UCODE
[ "$(bytecode "$SOURCE_DIR" "$CACHE_DIR" library_dir FORKOP_BYTECODE_VALIDATION_TTL=60)" = "$stamped" ] ||
  fail "a fresh validation stamp must be trusted without re-reading the manifest"
bytecode "$SOURCE_DIR" "$CACHE_DIR" invalidate_validation_stamp FORKOP_BYTECODE_VALIDATION_TTL=60 >/dev/null
[ ! -e "$CACHE_DIR/validated" ] ||
  fail "invalidate_validation_stamp() must remove the stamp"
[ "$(bytecode "$SOURCE_DIR" "$CACHE_DIR" library_dir FORKOP_BYTECODE_VALIDATION_TTL=60)" = "$SOURCE_DIR" ] ||
  fail "a dropped stamp must send the replaced sources back to full validation"

# service/package.uc drops the stamp on both sides of a package replacement, so
# the library installed over the old one is never served from the old cache.
grep -Fq 'bytecode.invalidate_validation_stamp()' "$LIB_SRC/service/package.uc" ||
  fail "service/package.uc must drop the cache validation stamp around a package change"

# The cache is an optimisation: switching it off has to leave the sources in
# charge without touching anything on disk.
disabled_cache_dir="$WORK_DIR/cache-disabled"
disabled="$(
  bytecode "$SOURCE_DIR" "$disabled_cache_dir" refresh FORKOP_BYTECODE_CACHE=0
)"
[ "$disabled" = "$SOURCE_DIR" ] ||
  fail "FORKOP_BYTECODE_CACHE=0 must resolve to the sources, got '$disabled'"
[ ! -e "$disabled_cache_dir" ] ||
  fail "FORKOP_BYTECODE_CACHE=0 must not create a cache directory"

# A library that cannot be compiled must not take the service down with it: the
# broken module still has to be present under the cache so `require` keeps
# reporting the real syntax error instead of a missing file.
BROKEN_DIR="$WORK_DIR/broken"
BROKEN_CACHE="$WORK_DIR/broken-cache"
mkdir -p "$BROKEN_DIR/config" "$BROKEN_DIR/core"
cp "$SOURCE_DIR/config/domain.uc" "$BROKEN_DIR/config/domain.uc"
printf 'this is ( not ucode\n' >"$BROKEN_DIR/core/broken.uc"
broken="$(bytecode "$BROKEN_DIR" "$BROKEN_CACHE" refresh)"
[ -f "$broken/core/broken.uc" ] ||
  fail "a module that fails to compile must still be present in the cache"
is_bytecode "$broken/core/broken.uc" &&
  fail "a module that fails to compile must be copied as source, not as bytecode"

# A library the self-check cannot load is a build that must be thrown away
# whole, leaving the sources to serve the router exactly as before.
UNUSABLE_DIR="$WORK_DIR/unusable"
UNUSABLE_CACHE="$WORK_DIR/unusable-cache"
mkdir -p "$UNUSABLE_DIR/core"
cp "$SOURCE_DIR/core/probe.uc" "$UNUSABLE_DIR/core/probe.uc"
unusable="$(bytecode "$UNUSABLE_DIR" "$UNUSABLE_CACHE" refresh)"
[ "$unusable" = "$UNUSABLE_DIR" ] ||
  fail "a library failing its self-check must resolve to the sources, got '$unusable'"
[ -z "$(find "$UNUSABLE_CACHE" -maxdepth 1 -name 'lib.*' 2>/dev/null)" ] ||
  fail "a rejected build must not leave a library directory behind"
[ ! -e "$UNUSABLE_CACHE/manifest" ] ||
  fail "a rejected build must not publish a manifest"

# A cache directory that cannot be created is the ordinary read-only-tmpfs case.
printf 'not a directory\n' >"$WORK_DIR/blocked"
blocked="$(bytecode "$SOURCE_DIR" "$WORK_DIR/blocked/cache" refresh)"
[ "$blocked" = "$SOURCE_DIR" ] ||
  fail "an unusable cache location must resolve to the sources, got '$blocked'"

# The real library is what every router runs; it has to compile and behave.
REAL_CACHE="$WORK_DIR/real-cache"
real="$(bytecode "$LIB_SRC" "$REAL_CACHE" refresh)"
[ "$real" != "$LIB_SRC" ] ||
  fail "the shipped library must compile into a cache"
is_bytecode "$real/config/validator.uc" ||
  fail "the shipped library must reach the cache as bytecode"
[ "$(find "$real" -type f | wc -l)" = "$(find "$LIB_SRC" -type f | wc -l)" ] ||
  fail "the cache must stand in for every file of the shipped library"
real_constants="$(ucode -L "$real" "$real/core/constants.uc" json)"
source_constants="$(ucode -L "$LIB_SRC" "$LIB_SRC/core/constants.uc" json)"
[ -n "$source_constants" ] && [ "$real_constants" = "$source_constants" ] ||
  fail "a cached module run by path must answer like its source"

# The entrypoint keeps honouring an explicit FORKOP_LIB, which is what tests and
# manual overrides rely on and what every child process is handed.
mkdir -p "$WORK_DIR/fake/diagnostics"
cat >"$WORK_DIR/fake/diagnostics/runtime.uc" <<'UCODE'
#!/usr/bin/env ucode
print(getenv("FORKOP_LIB") || "unset", "\n");
UCODE
forwarded="$(FORKOP_LIB="$WORK_DIR/fake" ucode "$FORKOP_ENTRY" show_version)"
[ "$forwarded" = "$WORK_DIR/fake" ] ||
  fail "entrypoint must export the resolved library to its children, got '$forwarded'"

# Without one it resolves the cache itself, and hands that directory on.
mkdir -p "$WORK_DIR/entry/diagnostics" "$WORK_DIR/entry/config" "$WORK_DIR/entry/core"
cp "$LIB_SRC/core/bytecode.uc" "$WORK_DIR/entry/core/bytecode.uc"
cp "$SOURCE_DIR/config/domain.uc" "$WORK_DIR/entry/config/domain.uc"
cp "$WORK_DIR/fake/diagnostics/runtime.uc" "$WORK_DIR/entry/diagnostics/runtime.uc"
entry_resolved="$(
  env FORKOP_SOURCE_LIB="$WORK_DIR/entry" FORKOP_BYTECODE_CACHE_DIR="$WORK_DIR/entry-cache" \
    ucode "$FORKOP_ENTRY" show_version
)"
case "$entry_resolved" in
  "$WORK_DIR/entry-cache"/lib.*) ;;
  *) fail "entrypoint must hand the resolved cache to its children, got '$entry_resolved'" ;;
esac
entry_disabled="$(
  env FORKOP_SOURCE_LIB="$WORK_DIR/entry" FORKOP_BYTECODE_CACHE_DIR="$WORK_DIR/entry-off" \
    FORKOP_BYTECODE_CACHE=0 ucode "$FORKOP_ENTRY" show_version
)"
[ "$entry_disabled" = "$WORK_DIR/entry" ] ||
  fail "a disabled cache must leave the entrypoint on the sources, got '$entry_disabled'"

# An exported FORKOP_LIB reaches every descendant, so the init script must not
# pin the source directory: that is what silently switched the whole procd path
# back to parsing sources on each reload.
if grep -Eq '^[[:space:]]*FORKOP_LIB="\$FORKOP_LIB"[[:space:]]*\\?$' "$INITD"; then
  fail "init script must not export FORKOP_LIB into service/initd.uc"
fi
grep -Fq 'bytecode.refresh()' "$LIB_SRC/service/initd.uc" ||
  fail "service/initd.uc must resolve the library cache for the procd path"
grep -Fq 'FORKOP_LIB=" + shell_quote(LIB_DIR)' "$LIB_SRC/service/initd.uc" ||
  fail "service/initd.uc must hand the resolved library to the modules it starts"

printf 'Bytecode cache checks passed\n'
