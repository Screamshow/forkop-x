#!/usr/bin/env ucode
let fs = require("fs");
let identity = require("singbox.cache_identity");
let work = ARGV[0];
let lib = ARGV[1];
function expect(value, message) {
    if (!value) { warn("FAIL: ", message, "\n"); exit(1); }
}
function quote(value) { return "'" + replace(value, /'/g, "'\\''") + "'"; }
let base = work + "/custom.db";
let fixture = work + "/fixture.json";
let runtime = work + "/runtime-cache.json";
let uci_state = work + "/uci-cache-state";
fs.writefile(runtime, sprintf("%J", { experimental: { cache_file: { enabled: true, path: base } } }));
fs.writefile(uci_state, "forkop.settings.config_path=" + runtime + "\n");
let probe = fs.popen("env FORKOP_UCI_STATE_FILE=" + quote(uci_state) + " ucode -L " + quote(lib) + " " +
    quote(lib + "/components/action.uc") + " runtime-cache-path-fixture", "r");
let runtime_path = trim(probe.read("all"));
expect(probe.close() == 0 && runtime_path == base, "component action reads runtime cache path (forward reference regression)");
fs.writefile(fixture, sprintf("%J", {
    settings: { ".name": "settings", ".type": "settings", dns_server: "1.1.1.1", cache_path: base },
    section: [{ ".name": "probe", ".type": "section", enabled: "1", action: "connection",
        outbound_jsons: [ '{"type":"direct"}' ] }]
}));
let versions = ["1.14.2", "1.14.2-tiny", "1.14.2-x-1.0.4", "1.14.2-rust-x.0.0.8", "1.14.2-extended-2.7.2"];
let expected = [base, base, base + ".forkop-x", base + ".forkop-rust-x", base + ".forkop-extended"];
fs.writefile(base, "legacy upstream cache");
for (let i = 0; i < length(versions); i++) {
    let output = work + "/config.json";
    let args = ["ucode", "-L", lib, lib + "/singbox/generator.uc", "generate-config-fixture",
        fixture, output, "127.0.0.1", "0", "1", "", versions[i]];
    let command = [];
    for (let arg in args) push(command, quote(arg));
    expect(system(join(" ", command)) == 0, "generate " + versions[i]);
    let cache = json(fs.readfile(output)).experimental.cache_file;
    expect(cache.path == expected[i] && cache.store_fakeip, "generated cache identity " + versions[i]);
}
let x = identity.path(base, versions[2]);
fs.writefile(x, "X cache mapping");
fs.writefile(identity.path(base, versions[3]), "Rust cache mapping");
expect(fs.readfile(identity.path(base, "1.14.2-x-1.0.5")) == "X cache mapping", "update and rollback preserve X store");
expect(fs.readfile(base) == "legacy upstream cache", "legacy file preserved");
expect(identity.path(base, "1.14.2-extended-2.7.2") == identity.path(base, "1.14.2-extended-2.7.2-compressed"), "packing does not change cache identity");
print("PASS: generated cache paths, custom path, family isolation, update/rollback preservation\n");
let rust = identity.path(base, versions[3]);
expect(identity.cleanup_previous(x, rust, false), "failed transition leaves cache");
expect(fs.readfile(x) == "X cache mapping", "rollback cache retained");
expect(identity.cleanup_previous(x, x, true), "same-family update keeps cache");
expect(fs.readfile(x) == "X cache mapping", "active cache retained");
fs.writefile(x + ".operator-backup", "operator file");
expect(identity.cleanup_previous(x, rust, true), "successful transition removes old database");
expect(fs.stat(x) == null, "old database removed");
expect(fs.readfile(rust) == "Rust cache mapping", "new database retained");
expect(fs.readfile(x + ".operator-backup") == "operator file", "adjacent files retained");
let link = work + "/cache-link";
expect(fs.symlink(base, link), "create symlink fixture");
expect(!identity.cleanup_previous(link, rust, true), "symlink rejected");
expect(fs.readfile(base) == "legacy upstream cache", "symlink target retained");
expect(!identity.cleanup_previous(work, rust, true), "directory rejected");
expect(identity.cleanup_previous(x, rust, true), "missing previous file is harmless");
print("PASS: cleanup only after readiness; failure, active cache, adjacent files and symlinks protected\n");
