#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
controller="$root/luci-app-forkop/root/usr/share/ucode/luci/controller/forkop.uc"
[ "$#" -gt 0 ] || set -- ucode -
{
    cat <<'UC'
import { popen, readfile, stat } from 'fs';
import * as fs from 'fs';
let dispatched = { readonly: true };
let path;
function ui_runtime_config_reference() { return { path, revision: "test" }; }
UC
    sed -n '/^const UI_READ_MAX_BYTES/p; /^function ui_read_scalar(/,/^}/p; /^function ui_read_match_fields(/,/^}/p; /^function ui_read_route_rule(/,/^}/p; /^function ui_runtime_metadata_source(/,/^}/p; /^function ui_read_runtime_config(/,/^}/p' "$controller"
    cat <<'UC'
let create = popen("mktemp -d /tmp/forkop-metadata.XXXXXX", "r");
let dir = trim(create.read(128));
assert(create.close() == 0 && match(dir, /^\/tmp\/forkop-metadata\.[a-zA-Z0-9]{6}$/));
path = dir + "/custom'quoted.json";
let fail;
try {
    let filler = "x";
    while (length(filler) <= UI_READ_MAX_BYTES) filler += filler;
    let config = { outbounds: [{ type: "vless", password: filler }], route: { rules: [{domain: ["fixture.test"], extra: "private"}] } };
    fs.writefile(path, sprintf("%J", config));
    let result = ui_read_runtime_config("test");
    assert(result.route.rules[0].domain[0] == "fixture.test" && !length(result.outbounds));
    assert(result.route.rules[0].extra == null);
    push(config.outbounds, { type: "urltest", tag: "group", url: "private", outbounds: ["proxy"] });
    fs.writefile(path, sprintf("%J", config));
    result = ui_read_runtime_config("test");
    assert(length(result.outbounds) == 1 && result.outbounds[0].tag == "group" && result.outbounds[0].url == null);
    dispatched.readonly = false;
    assert(ui_read_runtime_config("test").outbounds[0].url == "private");
    config.route.rules[0].domain = [filler];
    fs.writefile(path, sprintf("%J", config));
    result = ui_read_runtime_config("test");
    assert(!length(result.route.rules) && !length(result.outbounds), "Oversized projection did not fall back");
    assert(ui_read_runtime_config("stale") == null);
} catch (e) { fail = e; }
fs.unlink(path);
fs.rmdir(dir);
if (fail) die(fail);
print("PASS: large runtime config, optional URLTest, redaction, bounded output and revision\n");
UC
} | "$@"
