#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UI="$ROOT/forkop/files/usr/lib/service/ui.uc"

{
    cat <<'UC'
const RELOAD_LOCK_DIR = "/var/run/forkop.reload.lock";
const flash = "/etc/sing-box/config.json";
const ram = "/tmp/sing-box/config.json";
let active = false;
let lock_on_stat = false;
let inode = 500;
let owner = 42;
let inspected = [];
function as_string(value) { return value == null ? "" : "" + value; }
let locks = { held: path => { assert(path == RELOAD_LOCK_DIR); return active; } };
let fs = { stat: path => {
    push(inspected, path);
    if (lock_on_stat) active = true;
    return { type: "file", inode, size: 100, mtime: 20, ctime: 20 };
} };
function procd(path) {
    return { "sing-box": { instances: { main: { running: true, pid: owner,
        command: ["/usr/bin/sing-box", "run", "-c", path, "-D", "/tmp/sing-box"] } } } };
}
UC
    sed -n '/^function monitoring_runtime_config(/,/^}/p' "$UI"
    cat <<'UC'
let previous = monitoring_runtime_config(procd(flash));
assert(previous.path == flash);
let current = monitoring_runtime_config(procd(ram));
assert(current.path == ram, "uses the running process's config argument");
active = true;
inode++;
assert(monitoring_runtime_config(procd(ram)) == null, "staged file reported before reload completed");
active = false;
assert(monitoring_runtime_config(procd(ram)).revision != current.revision, "atomic replacement goes unnoticed");
current = monitoring_runtime_config(procd(ram));
owner++;
assert(monitoring_runtime_config(procd(ram)).revision != current.revision, "core restart goes unnoticed");
lock_on_stat = true;
assert(monitoring_runtime_config(procd(ram)) == null, "reload began while reading the file revision");
active = lock_on_stat = false;
let read_count = length(inspected);
assert(monitoring_runtime_config(procd("/another/config.json")) == null);
assert(length(inspected) == read_count, "read not permitted by LuCI file ACL");
assert(monitoring_runtime_config({}) == null);
print("PASS: active Flash/RAM paths, atomic replacement, reload lock and ACL\n");
UC
} | ucode -
