#!/usr/bin/env ucode
// ucode -L LIB tests/clash_api_auth.uc WORK LIB
// Router-side Clash API calls must send the Bearer token exactly when the
// generated config carries a secret. A fake curl plays the controller: it
// answers 401 unless the request carries the generated secret.
let fs = require("fs");
let work = ARGV[0];
let lib = ARGV[1];
let checks = 0, failures = 0;
function expect(value, message) {
    checks++;
    if (value) return true;
    print("FAIL: ", message, "\n");
    failures++;
    return false;
}
function quote(value) { return "'" + replace("" + value, /'/g, "'\\''") + "'"; }

// The secret the generator writes, from its own clash_api_config.
let source = fs.readfile(lib + "/xrust/generator.uc");
let start = index(source, "function clash_api_config(");
if (!expect(start >= 0, "generator clash_api_config exists"))
    die("generator clash_api_config not found\n");
let tail = substr(source, start);
let generator_code = substr(tail, 0, index(tail, "\n}") + 2);
function generated_secret(settings) {
    let path = work + "/generated.uc";
    fs.writefile(path, 'let common = require("core.common");\n' +
        'let as_string = common.as_string, option = common.option, bool_option = common.bool_option;\n' +
        generator_code + '\n' +
        'let api = clash_api_config(' + sprintf("%J", settings) + ', "127.0.0.1");\n' +
        'print(api.secret == null ? "" : api.secret);\n');
    let pipe = fs.popen("ucode -L " + quote(lib) + " " + quote(path), "r");
    let output = pipe.read("all");
    if (!expect(pipe.close() == 0, "generator function runs"))
        die("cannot evaluate the generator\n");
    return output;
}

system("mkdir -p " + quote(work + "/bin"));
fs.writefile(work + "/bin/curl", '#!/bin/sh\n' +
    'printf "%s\\n" "$@" > "$CLASH_TEST_WORK/curl.args"\n' +
    'secret=$(cat "$CLASH_TEST_WORK/secret")\n' +
    'if [ -n "$secret" ] && ! grep -qxF "Authorization: Bearer $secret" "$CLASH_TEST_WORK/curl.args"; then\n' +
    '    printf \'{"message":"Unauthorized"}\'\n' +
    '    exit 0\n' +
    'fi\n' +
    'printf \'{"proxies":{"GLOBAL":{"type":"Selector"}}}\'\n');
fs.chmod(work + "/bin/curl", 0755);

function runtime(args) {
    let env = ["env", "PATH=" + work + "/bin:" + getenv("PATH"),
        "CLASH_TEST_WORK=" + work,
        "FORKOP_LIB=" + lib,
        "FORKOP_UCI_STATE_FILE=" + work + "/uci.state",
        "FORKOP_RUNTIME_STATE_DIR=" + work + "/run"];
    let command = map([...env, "ucode", "-L", lib, lib + "/diagnostics/runtime.uc", ...args], quote);
    return system(join(" ", command) + " >/dev/null 2>&1");
}

let cases = [
    { name: "dashboard off", enable_yacd: "0", wan: "0", key: "s3cret" },
    { name: "dashboard off, WAN flag left on", enable_yacd: "0", wan: "1", key: "s3cret" },
    { name: "dashboard with secret, LAN only", enable_yacd: "1", wan: "0", key: "s3cret" },
    { name: "dashboard with secret and WAN access", enable_yacd: "1", wan: "1", key: "s3cret" },
    { name: "dashboard without secret, WAN access", enable_yacd: "1", wan: "1", key: "" },
    { name: "dashboard without secret, LAN only", enable_yacd: "1", wan: "0", key: "" }
];
for (let c in cases) {
    let settings = { enable_yacd: c.enable_yacd, enable_yacd_wan_access: c.wan, yacd_secret_key: c.key };
    let secret = generated_secret(settings);
    fs.writefile(work + "/secret", secret);
    fs.writefile(work + "/uci.state", "forkop.settings=settings\n" +
        "forkop.settings.service_listen_address=127.0.0.1\n" +
        "forkop.settings.enable_yacd=" + c.enable_yacd + "\n" +
        "forkop.settings.enable_yacd_wan_access=" + c.wan + "\n" +
        "forkop.settings.yacd_secret_key=" + c.key + "\n");
    fs.unlink(work + "/curl.args");
    expect(runtime(["clash-api-ready"]) == 0, c.name + ": readiness probe is authorized");
    let args = fs.readfile(work + "/curl.args") || "";
    expect((index(args, "Authorization:") >= 0) == (secret != ""),
        c.name + ": token sent exactly when the generated config has a secret");
    expect(runtime(["clash-api", "get_proxies"]) == 0, c.name + ": get_proxies runs");
    args = fs.readfile(work + "/curl.args") || "";
    expect((index(args, "Authorization:") >= 0) == (secret != ""),
        c.name + ": get_proxies token matches the generated secret");
}
if (failures > 0)
    die(sprintf("clash API auth: %d of %d checks failed\n", failures, checks));
print("clash API auth checks passed: ", checks, "\n");
