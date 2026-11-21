#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB=${FORKOP_LIB:-$ROOT/forkop/files/usr/lib}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ucode -L "$LIB" -e '
let fs=require("fs"), identity=require("xrust.cache_identity"), base=ARGV[0]+"/custom.db";
let versions=["1.14.2","1.14.2-x-1.0.0","1.14.2-rust-x.0.0.17","1.14.2-extended","1.14.2-lx"];
let paths={};
for(let v in versions) {
    let p=identity.path(base,v);
    if(paths[p]) die("families share a physical database\n");
    paths[p]=v;
    fs.writefile(p,v);
}
for(let v in [versions[1],versions[2],versions[3],versions[2],versions[1]]) {
    let p=identity.path(base,v);
    if(fs.readfile(p)!=v) die("previous family database unavailable on return\n");
    for(let saved, content in paths)
        if(fs.readfile(saved)!=content) die("inactive database changed\n");
}
// Transition completion must not discard either an old store or a candidate
// store that already existed before a failed switch.
let action=fs.readfile(ARGV[1]);
if(index(action,"cleanup_previous")>=0) die("component action still deletes family databases\n");
print("PASS: separate FakeIP stores retained for return and rollback\n");
' "$WORK" "$LIB/components/action.uc"
