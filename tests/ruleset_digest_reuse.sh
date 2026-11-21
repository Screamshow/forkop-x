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
export PATH="$work/bin:$PATH" PARSER_LOG="$work/parses"
{
cat <<'UC'
let fs=require("fs");
function as_string(v) {return v==null?"":""+v;}
function quote(v) {return "'"+replace(as_string(v),/'/g,"'\\''")+"'";}
function command_success(args) {return system(join(" ",map(args,quote))+" >/dev/null 2>&1")==0;}
function command_output(args) {let p=fs.popen(join(" ",map(args,quote)),"r");let data=p.read("all");return p.close()==0?data:"";}
UC
sed -n '/^function binary_validation_path(path) {/,/^}/p; /^function binary_stat_signature(path) {/,/^}/p; /^function binary_digest(path) {/,/^}/p; /^function mark_binary_valid(path) {/,/^}/p; /^function trusted_binary_digest(path) {/,/^}/p; /^function reuse_binary_validation(source, target) {/,/^}/p; /^function valid_binary(path) {/,/^}/p' "$ROOT/forkop/files/usr/lib/xrust/ruleset_cache.uc"
cat <<'UC'
let root=ARGV[0]; let source=root+"/source"; let target=root+"/target";
function count() {return length(split(trim(as_string(fs.readfile(getenv("PARSER_LOG")))),"\n"));}
fs.writefile(source,"good-v1\n");
assert(valid_binary(source),"new valid source rejected"); let n=count();
assert(valid_binary(source) && count()==n,"trusted source parsed again");
fs.writefile(target,fs.readfile(source));
assert(reuse_binary_validation(source,target),"identical target did not inherit validation");
assert(valid_binary(target) && count()==n,"inherited proof was not reused");
fs.writefile(source,"evil-v1\n"); // Same size, deliberately no sleep.
assert(!reuse_binary_validation(source,target),"modified source inherited stale proof");
assert(!valid_binary(source) && count()==n+1,"corrupt changed source accepted");
assert(fs.stat(source+".validated")==null,"corrupt marker survived");
fs.writefile(source,"good-v2\n");
fs.writefile(source+".validated",binary_stat_signature(source)+"\n");
n=count(); assert(valid_binary(source) && count()==n+1,"legacy marker must parse once");
n=count(); assert(valid_binary(source) && count()==n,"upgraded proof not reused");
fs.writefile(target,"evil-v2\n");
assert(!reuse_binary_validation(source,target),"different candidate skipped parser");
assert(!valid_binary(target),"invalid candidate accepted");
fs.unlink(source+".validated");
assert(!reuse_binary_validation(source,target),"missing proof was trusted");
n=count();assert(valid_binary(source) && count()==n+1,"missing proof did not parse");
fs.writefile(source+".validated","stale\n"+binary_digest(source)+"\n");
n=count();assert(valid_binary(source) && count()==n+1,"stale signature did not parse");
fs.writefile(source+".validated",binary_stat_signature(source)+"\n"+"0"+substr(binary_digest(source),1)+"\n");
n=count();assert(valid_binary(source) && count()==n+1,"incorrect digest did not parse");
fs.writefile(target,fs.readfile(source));
assert(reuse_binary_validation(source,target) && valid_binary(target),"copy publication failed");
fs.unlink(source);
assert(!reuse_binary_validation(source,target),"deleted source was trusted");
print("Binary digest reuse: changed bytes, corrupt candidate, legacy/missing/stale proof and copied payload passed\n");
UC
} > "$work/check.uc"
ucode "$work/check.uc" "$work"