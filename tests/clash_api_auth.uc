#!/usr/bin/env ucode
// ucode -L LIB tests/clash_api_auth.uc WORK LIB
let fs = require("fs");
let work = ARGV[0], lib = ARGV[1];
let source_path = work + "/legacy.json";
let migrated_path = work + "/migrated.json";
let generated_path = work + "/xrust.json";

function expect(value, message) {
    if (!value) die(message + "\n");
}

function quote(value) {
    return "'" + replace("" + value, /'/g, "'\\''") + "'";
}

function call(module, args) {
    let command = [ "env", "FORKOP_LIB=" + lib, "ucode", "-L", lib, lib + "/" + module, ...args ];
    let pipe = fs.popen(join(" ", map(command, quote)), "r");
    let output = pipe.read("all");
    expect(pipe.close() == 0, "failed " + module + " " + args[0]);
    return output;
}

let fixture = {
    settings: { ".name":"settings", ".type":"settings", enable_yacd:"1", enable_yacd_wan_access:"1",
        yacd_secret_key:"legacy-test-key", dns_server:"1.1.1.1", log_level:"error",
        subscription_exclude_regex:["archive"] },
    section: [{ ".name":"vpn", ".type":"section", enabled:"1", action:"connection",
        outbound_jsons:["{\"type\":\"direct\",\"tag\":\"local-test\"}"], domain_suffix:["fixture.test"] }]
};
fs.writefile(source_path, sprintf("%J", fixture));
let result = json(call("config/migration.uc", [ "migrate-fixture", source_path ]));
expect(result.config.settings.enable_yacd == "1", "local YACD must stay enabled on upgrade");
expect(result.config.settings.enable_yacd_wan_access == null, "legacy WAN flag survived migration");
expect(result.config.settings.yacd_secret_key == null, "legacy WAN key survived migration");
expect(result.config.settings.log_level == "error" &&
    result.config.settings.subscription_exclude_regex[0] == "archive" &&
    result.config.section[0].domain_suffix[0] == "fixture.test", "unrelated configuration changed");
fs.writefile(migrated_path, sprintf("%J", result.config));
let repeated = json(call("config/migration.uc", [ "migrate-fixture", migrated_path ]));
expect(repeated.changed == false, "migration must be idempotent");

function check_controller(path, address, expected, local_ui) {
    call("xrust/generator.uc", [ "generate-config-fixture", path, generated_path, address,
        "0", "1", "", "0.0.45" ]);
    let api = json(fs.readfile(generated_path)).experimental.clash_api;
    expect(api.external_controller == expected + ":9090", "unexpected Clash API binding for " + address);
    expect(api.external_ui == (local_ui ? "ui" : null), "local YACD toggle was ignored");
    expect(api.secret == null, "retired key leaked into generated configuration");
}

check_controller(source_path, "192.0.2.1", "192.0.2.1", true);
check_controller(migrated_path, "192.0.2.1", "192.0.2.1", true);
for (let address in [ "", "0.0.0.0", "::", "[::]" ])
    check_controller(source_path, address, "127.0.0.1", true);
fixture.settings.enable_yacd = "0";
fs.writefile(source_path, sprintf("%J", fixture));
check_controller(source_path, "192.0.2.1", "192.0.2.1", false);
print("PASS: legacy YACD migration, local toggle and Clash API binding\n");
