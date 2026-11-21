#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
fixture=${1:?Supply a real large SRS fixture}
work=$(mktemp -d /tmp/forkop-binary-validation.XXXXXX)
trap 'rm -rf "$work"' EXIT
cat > "$work/probe.json" <<'JSON'
{"version":3,"rules":[{"domain_suffix":["example.test"]},{"type":"logical","mode":"or","rules":[{"ip_cidr":["192.0.2.0/24"]},{"domain":["another.test"]}]}]}
JSON
sing-box rule-set compile "$work/probe.json" -o "$work/probe.srs"
printf 'broken rule set' > "$work/bad.srs"
head -c 64 "$fixture" > "$work/truncated.srs"
printf 'SRS\177' > "$work/unsupported.srs"
{
cat <<'UCODE'
let fs = require("fs");
function as_string(v) { return v == null ? "" : "" + v; }
function shell_quote(v) { return "'" + replace(as_string(v), /'/g, "'\\''") + "'"; }
function trim(v) { return replace(v, /^\s+|\s+$/g, ""); }
function command_success(args) { return system(join(" ", map(args, shell_quote)) + " >/dev/null 2>&1") == 0; }
function command_output(args) { let p=fs.popen(join(" ", map(args, shell_quote)), "r"); let data=p.read("all"); return p.close()==0 ? data : ""; }
function command_success_from_args(args) { return command_success(args); }
function file_nonempty(path) { let s = fs.stat(path); return s != null && s.size > 0; }
function remove_file(path) { fs.unlink(path); }
function valid_list_ruleset_file(path) { let v = json(fs.readfile(path)); return type(v) == "object" && type(v.rules) == "array"; }
UCODE
sed -n '/^function binary_validation_path(path) {/,/^}/p; /^function binary_stat_signature(path) {/,/^}/p; /^function binary_digest(path) {/,/^}/p; /^function trusted_binary_digest(path) {/,/^}/p; /^function mark_binary_valid(path) {/,/^}/p; /^function valid_binary(path) {/,/^}/p' "$LIB/xrust/ruleset_cache.uc"
sed -n '/^function validate_staged_list_download(path, format) {/,/^}/p' "$LIB/components/updates.uc"
cat <<'UCODE'
for (let path in [ ARGV[0], ARGV[1] ]) {
    assert(valid_binary(path), "valid compiled rule set rejected");
    assert(valid_binary(path), "cached rule set rejected");
    assert(validate_staged_list_download(path, "srs"), "staged rule set rejected");
    assert(fs.stat(path + ".json") == null, "validation expanded source JSON");
}
for (let path in [ ARGV[2], ARGV[3], ARGV[4] ]) {
    assert(!valid_binary(path), "bad rule set accepted");
    assert(!validate_staged_list_download(path, "srs"), "bad staged rule set accepted");
    assert(fs.stat(path + ".validated") == null, "bad rule set marked valid");
}
fs.writefile(ARGV[0], "broken");
assert(!valid_binary(ARGV[0]), "changed file reused stale validation marker");
assert(fs.stat(ARGV[0] + ".validated") == null, "stale validation marker survived");
print("Real binary validation: large, nested, malformed, truncated, unsupported and changed fixtures passed\n");
UCODE
} > "$work/check.uc"
cp "$fixture" "$work/large.srs"
ucode "$work/check.uc" "$work/probe.srs" "$work/large.srs" "$work/bad.srs" "$work/truncated.srs" "$work/unsupported.srs"

# Exercise the complete cache publication path with a real large binary and
# real sing-box parser; only the network download is replaced with a fixture.
mkdir -p "$work/bin"
cat > "$work/bin/curl" <<'SH'
#!/bin/sh
output=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) output=$2; shift 2 ;;
        *) shift ;;
    esac
done
cp "$RULESET_REAL_DOWNLOAD" "$output"
SH
chmod +x "$work/bin/curl"
export PATH="$work/bin:$PATH"
export RULESET_REAL_DOWNLOAD="$fixture"
export FORKOP_RULESET_CACHE_DIR="$work/cache"
export FORKOP_RULESET_CACHE_MANIFEST="$work/cache/manifest.json"
export FORKOP_RULESET_RUNTIME_CACHE_DIR="$work/runtime"
export FORKOP_RULESET_RUNTIME_MANIFEST="$work/runtime-manifest.json"
export FORKOP_PERSISTENT_LIST_CACHE_DIR="$work/list-cache"
cat > "$work/config.json" <<'JSON'
{"route":{"rule_set":[{"type":"remote","tag":"large","format":"binary","url":"https://fixture.invalid/large.srs"}]}}
JSON
ucode -L "$LIB" "$LIB/xrust/ruleset_cache.uc" materialize-config "$work/config.json"
cache_path=$(ucode -e 'let fs=require("fs"); print(json(fs.readfile(ARGV[0])).route.rule_set[0].path);' "$work/config.json")
[ -f "$cache_path.validated" ]
old_hash=$(md5sum "$cache_path")
status=0
ucode -L "$LIB" "$LIB/xrust/ruleset_cache.uc" refresh || status=$?
[ "$status" = 1 ] || { echo 'unchanged large cache unexpectedly failed or changed'; exit 1; }
RULESET_REAL_DOWNLOAD="$work/truncated.srs"
export RULESET_REAL_DOWNLOAD
if ucode -L "$LIB" "$LIB/xrust/ruleset_cache.uc" refresh 2> "$work/rejection.log"; then
    echo 'corrupt download accepted'
    exit 1
fi
[ "$old_hash" = "$(md5sum "$cache_path")" ]
[ -f "$cache_path.validated" ]
echo 'Large cache publication, unchanged refresh and last-known-good preservation passed'

# A changed valid binary may live in RAM when flash is constrained, then be
# promoted without reparsing already validated bytes when space returns.
sing-box rule-set compile "$work/probe.json" -o "$work/probe.srs"
export RULESET_REAL_DOWNLOAD="$work/probe.srs"
export FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=8388608
ucode -L "$LIB" "$LIB/xrust/ruleset_cache.uc" refresh
[ "$old_hash" = "$(md5sum "$cache_path")" ]
runtime_path=$(ucode -e 'let fs=require("fs");let m=json(fs.readfile(ARGV[0]));for(let k,e in m)if(e.path)print(e.path);' "$FORKOP_RULESET_RUNTIME_MANIFEST")
[ -f "$runtime_path" ] && [ -f "$runtime_path.validated" ]
cmp "$RULESET_REAL_DOWNLOAD" "$runtime_path"
export FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=33554432
status=0
ucode -L "$LIB" "$LIB/xrust/ruleset_cache.uc" refresh || status=$?
[ "$status" = 1 ]
cmp "$RULESET_REAL_DOWNLOAD" "$cache_path"
[ ! -e "$runtime_path" ]
[ -f "$cache_path.validated" ]
echo 'Changed binary, RAM-only cache and later persistent promotion passed'