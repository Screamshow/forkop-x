#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/sing-box" <<'SH'
#!/bin/sh
printf 'parse\n' >> "$PARSER_LOG"
grep -q '^good' "$5"
SH
chmod +x "$work/bin/sing-box"
export REAL_SHA256SUM="$(command -v sha256sum)" HASH_LOG="$work/hashes"
cat > "$work/bin/sha256sum" <<'SH'
#!/bin/sh
printf 'hash\n' >> "$HASH_LOG"
exec "$REAL_SHA256SUM" "$@"
SH
chmod +x "$work/bin/sha256sum"
export PATH="$work/bin:$PATH" PARSER_LOG="$work/parses"
{
cat <<'UC'
let fs=require("fs");
let xrust={PATH:"sing-box"};
function as_string(v) {return v==null?"":""+v;}
function quote(v) {return "'"+replace(as_string(v),/'/g,"'\\''")+"'";}
function command_success(args) {return system(join(" ",map(args,quote))+" >/dev/null 2>&1")==0;}
function command_output(args) {let p=fs.popen(join(" ",map(args,quote)),"r");let data=p.read("all");return p.close()==0?data:"";}
UC
sed -n '/^function binary_validation_path(/,/^function valid_runtime_entry(/ { /^function valid_runtime_entry(/d; p; }' "$ROOT/forkop/files/usr/lib/xrust/ruleset_cache.uc"
cat <<'UC'
let root=ARGV[0]; let source=root+"/source"; let target=root+"/target";
function count() {return length(split(trim(as_string(fs.readfile(getenv("PARSER_LOG")))),"\n"));}
function hashes() {return length(split(trim(as_string(fs.readfile(getenv("HASH_LOG")))),"\n"));}
function valid_binary(path) { return validate_cache(path, "binary"); }
fs.writefile(source,"good-v1\n");
assert(valid_binary(source),"new valid source rejected"); let n=count();
let before=hashes(), checked=valid_binary(source);
assert(checked && count()==n && hashes()==before+1,"trusted cache must hash once and avoid the parser");
fs.writefile(target,fs.readfile(source));
before=hashes();
assert(validate_cache(target,"binary",checked) && hashes()==before+1,"identical copy must hash only its own bytes");
assert(valid_binary(target) && count()==n,"inherited proof was not reused");
fs.writefile(source,"evil-v1\n"); // Same size, deliberately no sleep.
assert(!valid_binary(source) && count()==n+1,"corrupt changed source accepted");
assert(fs.stat(source+".validated")==null,"corrupt marker survived");
fs.writefile(source,"good-v2\n");
fs.writefile(source+".validated",binary_stat_signature(source)+"\n");
n=count(); assert(valid_binary(source) && count()==n+1,"legacy marker must parse once");
n=count(); assert(valid_binary(source) && count()==n,"upgraded proof not reused");
fs.writefile(target,"evil-v2\n");
checked=valid_binary(source);
assert(!validate_cache(target,"binary",checked),"different candidate skipped parser");
fs.unlink(source+".validated");
n=count();assert(valid_binary(source) && count()==n+1,"missing proof did not parse");
fs.writefile(source+".validated","stale\n"+binary_digest(source)+"\n");
n=count();assert(valid_binary(source) && count()==n+1,"stale signature did not parse");
fs.writefile(source+".validated",binary_stat_signature(source)+"\n"+"0"+substr(binary_digest(source),1)+"\n");
n=count();assert(valid_binary(source) && count()==n+1,"incorrect digest did not parse");
fs.writefile(target,fs.readfile(source));
checked=valid_binary(source);
let copied=validate_cache(target,"binary",checked);
let published=root+"/published";
before=hashes();
assert(copied && publish_cache_file(copied,published) && hashes()==before,"immutable rename repeated body hashing");
assert(valid_binary(published),"copy publication failed");
fs.unlink(source);
assert(!valid_binary(source),"deleted source was trusted");
print("Binary digest reuse: 1 hash per cached body or copied candidate; 0 on immutable publication; stale and corrupt data rejected\n");
UC
} > "$work/check.uc"
ucode "$work/check.uc" "$work"
