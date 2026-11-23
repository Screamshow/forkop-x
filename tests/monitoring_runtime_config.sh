#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UI="$ROOT/forkop/files/usr/lib/service/ui.uc"

{
    cat <<'UC'
const RELOAD_LOCK_DIR = "/var/run/forkop.reload.lock";
const flash = "/etc/xrust/config.json";
const ram = "/tmp/xrust/config.json";
let xrust = { SERVICE_NAME: "forkop-xrust" };
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
    return { "forkop-xrust": { instances: { client: { running: true, pid: owner,
        command: ["/usr/lib/rust-x/sing-box", "run", "-c", path, "-D", "/usr/share/xrust"] } } } };
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
let custom = "/another/config.json";
assert(monitoring_runtime_config(procd(custom)).path == custom, "active custom path lost");
let read_count = length(inspected);
assert(monitoring_runtime_config(procd("relative/config.json")) == null);
assert(length(inspected) == read_count, "relative path was read");
assert(monitoring_runtime_config({}) == null);
print("PASS: active Flash/RAM/custom paths, atomic replacement and reload lock\n");
UC
} | ucode -
