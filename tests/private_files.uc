#!/usr/bin/env ucode
// ucode -L LIB tests/private_files.uc WORK LIB
let fs = require("fs");
let common = require("core.common");
let parser = require("subscription.parser");
let links = require("subscription.share_link");
let work = ARGV[0];
let lib = ARGV[1];
let checks = 0;
function expect(value, message) {
    if (!value) die("FAIL: " + message + "\n");
    checks++;
}
function mode(path, expected) {
    let stat = fs.stat(path);
    expect(stat != null && (stat.mode & 0777) == expected, "permissions: " + path);
}
function quote(value) { return "'" + replace("" + value, /'/g, "'\\''") + "'"; }
function run(args) {
    let env = ["env", "FORKOP_LIB=" + lib,
        "FORKOP_UCI_STATE_FILE=" + work + "/uci.state",
        "FORKOP_UCI_LOG_FILE=" + work + "/uci.log",
        "FORKOP_RUNTIME_STATE_DIR=" + work + "/run",
        "TMP_SING_BOX_FOLDER=" + work + "/sing-box",
        "TMP_SUBSCRIPTION_FOLDER=" + work + "/subscriptions",
        "TMP_RULESET_FOLDER=" + work + "/rulesets",
        "FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR=" + work + "/persistent"];
    let command = map([...env, ...args], quote);
    expect(system(join(" ", command)) == 0, "command: " + args[0]);
}
function runtime(args) { run(["ucode", "-L", lib, lib + "/xrust/runtime.uc", ...args]); }
function cache(args) { run(["ucode", "-L", lib, lib + "/subscription/cache.uc", ...args]); }
function private_json(path, value) {
    expect(common.write_private_json_file(path, value) != null, "write private JSON");
    mode(path, 0600);
}
run(["mkdir", "-p", work]);
fs.chmod(work, 0755);
fs.writefile(work + "/uci.state", "forkop.settings=settings\nforkop.settings.config_path=" + work + "/live.json\n");
private_json(work + "/private.json", { secret: "test-secret" });
fs.chmod(work + "/private.json", 0777);
private_json(work + "/private.json", { secret: "replacement" });
expect(common.write_private_file(work + "/null.json", null) == null, "null content rejected");
expect(fs.stat(work + "/null.json") == null, "null content not published");
expect(common.write_private_json_file(work + "/missing/file.json", {}) == null, "failed creation reported");

let uri = "trojan://test-password@127.0.0.1:443?sni=example.test#probe";
fs.writefile(work + "/input.txt", uri);
run(["ucode", "-L", lib, lib + "/subscription/parser.uc", "normalize-content", work + "/input.txt", work + "/normalized.json"]);
mode(work + "/normalized.json", 0600);
fs.chmod(work + "/normalized.json", 0777);
run(["ucode", "-L", lib, lib + "/subscription/parser.uc", "normalize-content", work + "/input.txt", work + "/normalized.json"]);
mode(work + "/normalized.json", 0600);
run(["ucode", "-L", lib, lib + "/subscription/parser.uc", "normalize-content", work + "/normalized.json", work + "/normalized-again.json"]);
mode(work + "/normalized-again.json", 0600);
let normalized = work + "/normalized-again.json";
fs.chmod(normalized, 0644);
expect(parser.repair_cached_subscription_file(normalized), "cache repair/no-op succeeds");
mode(normalized, 0600);
expect(links.populate_subscription_file(normalized), "share links populated");
fs.chmod(normalized, 0644);
expect(links.populate_subscription_file(normalized), "share links no-op succeeds");
mode(normalized, 0600);

// Existing files are secured even when the cache format has not changed.
for (let dir in ["subscriptions", "persistent", "run/section-cache", "run/subscription-links",
                 "run/subscription-metadata", "run/outbound-metadata"])
    run(["mkdir", "-p", work + "/" + dir]);
fs.writefile(work + "/run/cache-format", "12\n");
fs.writefile(work + "/persistent/cache-format", "9\n");
for (let dir in ["subscriptions", "persistent", "run/section-cache", "run/subscription-links",
                 "run/subscription-metadata", "run/outbound-metadata"]) {
    fs.chmod(work + "/" + dir, 0755);
    fs.writefile(work + "/" + dir + "/old.json", "{}\n");
    fs.chmod(work + "/" + dir + "/old.json", 0644);
}
cache(["ensure-runtime-cache-format"]);
for (let dir in ["subscriptions", "persistent", "run/section-cache", "run/subscription-links",
                 "run/subscription-metadata", "run/outbound-metadata"]) {
    mode(work + "/" + dir, 0700);
    mode(work + "/" + dir + "/old.json", 0600);
}
mode(work, 0755);
private_json(work + "/names.json", { probe: "Test proxy" });
private_json(work + "/countries.json", { probe: "TEST" });
private_json(work + "/servers.json", { probe: "127.0.0.1" });
fs.unlink(work + "/run/section-cache/probe.json");
cache(["write-outbound-metadata", work + "/run/section-cache", "12", "probe",
    work + "/names.json", work + "/countries.json", work + "/servers.json"]);
mode(work + "/run/section-cache/probe.json", 0600);
cache(["get-outbound-metadata", work + "/run/section-cache", "probe", ""]);

private_json(work + "/fixture.json", {
    settings: { ".name": "settings", ".type": "settings", dns_server: "1.1.1.1" },
    section: [{ ".name": "probe", ".type": "section", enabled: "1", action: "connection", selector_proxy_links: [uri] }]
});
run(["ucode", "-L", lib, lib + "/xrust/generator.uc", "generate-config-fixture",
    work + "/fixture.json", work + "/generated.json", "127.0.0.1", "0", "0", "", "1.13.21", "1"]);
mode(work + "/generated.json", 0600);
mode(work + "/generated.json.section-cache", 0700);
mode(work + "/generated.json.section-cache/probe.json", 0600);
run(["sing-box", "check", "-c", work + "/generated.json"]);
mode(work, 0755);
runtime(["publish-section-cache-fixture", work + "/generated.json"]);
mode(work + "/run/section-cache/probe.json", 0600);
mode(work + "/run/section-cache", 0700);

fs.writefile(work + "/live.json", "{\"old\":true}\n");
fs.chmod(work + "/live.json", 0644);
private_json(work + "/stage.json", { new: true });
fs.chmod(work + "/stage.json", 0644);
runtime(["commit-config-stage", work + "/stage.json", work + "/backup.json"]);
mode(work + "/live.json", 0600);
mode(work + "/backup.json", 0600);
expect(json(fs.readfile(work + "/backup.json")).old === true, "backup readable by root");
runtime(["restore-config-stage", work + "/backup.json"]);
mode(work + "/live.json", 0600);
expect(json(fs.readfile(work + "/live.json")).old === true, "restore preserves old content");
private_json(work + "/dns-backup.json", { dns_backup: true });
fs.chmod(work + "/dns-backup.json", 0644);
runtime(["restore-dns-config", work + "/dns-backup.json"]);
mode(work + "/live.json", 0600);
mode(work + "/dns-backup.json", 0600);
expect(json(fs.readfile(work + "/live.json")).dns_backup === true, "DNS backup restore readable by root");
expect(fs.readfile(work + "/dns-backup.json") == fs.readfile(work + "/live.json"),
    "DNS backup remains available until lifecycle confirms restart");
expect(common.write_private_file(work + "/same.json", fs.readfile(work + "/live.json")) != null, "copy unchanged config");
fs.chmod(work + "/live.json", 0644);
runtime(["save-config-file-fixture", work + "/same.json", work + "/live.json"]);
mode(work + "/live.json", 0600);
expect(fs.stat(work + "/same.json") == null, "unchanged stage removed");

// Native sing-box must still be able to read a private config as root.
private_json(work + "/native.json", { outbounds: [{ type: "direct", tag: "direct" }] });
run(["sing-box", "check", "-c", work + "/native.json"]);
print("Private-file regression checks passed: ", checks, " assertions\n");
