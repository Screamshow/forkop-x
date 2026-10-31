#!/usr/bin/env ucode
// Run with: ucode -L LIB tests/reality_xhttp.uc WORK LIB [EXTENDED_BINARY]
let fs = require("fs");
let parser = require("subscription.parser");
let links = require("subscription.share_link");
let work = ARGV[0];
let lib = ARGV[1];
let binary = ARGV[2];
let checks = 0;
function expect(value, message) {
    if (!value) { warn("FAIL: ", message, "\n"); exit(1); }
    checks++;
}
function quote(value) { return "'" + replace("" + value, /'/g, "'\\''") + "'"; }
function run(args) {
    let command = [];
    let isolated = ["env", "FORKOP_LIB=" + lib,
        "FORKOP_RUNTIME_STATE_DIR=" + work + "/runtime-isolated",
        "TMP_SING_BOX_FOLDER=" + work + "/sing-box",
        "TMP_RULESET_FOLDER=" + work + "/rulesets",
        "TMP_SUBSCRIPTION_FOLDER=" + work + "/subscriptions",
        "FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR=" + work + "/persistent-isolated"];
    for (let value in [...isolated, ...args]) push(command, quote(value));
    expect(system(join(" ", command)) == 0, "command " + args[0] + " " + args[1]);
}
function write(path, value) { expect(fs.writefile(path, sprintf("%J", value)) != null, "write fixture"); }
function read(path) { return json(fs.readfile(path)); }
function encode(value) {
    let result = "";
    for (let i = 0; i < length(value); i++) {
        let c = substr(value, i, 1);
        result += match(c, /^[A-Za-z0-9_.~-]$/) ? c : sprintf("%%%02X", ord(c));
    }
    return result;
}
run(["mkdir", "-p", work]);
let base = "vless://00000000-0000-4000-8000-000000000001@127.0.0.1:19443?encryption=none&security=reality&sni=example.test&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&type=xhttp&mode=packet-up";
let number = 0;
function normalize(value) {
    let input = work + "/input" + number + ".json";
    let output = work + "/normalized" + number++ + ".json";
    fs.writefile(input, type(value) == "string" ? value : sprintf("%J", value));
    run(["ucode", "-L", lib, lib + "/subscription/parser.uc", "normalize-content", input, output]);
    return read(output).outbounds[0];
}
function fields(outbound, key, buffered) {
    let t = outbound.transport;
    expect(t.uplink_http_method == "GET", "uplink method");
    expect(t.session_placement == "header", "session placement");
    expect(t.session_key == key, "session key");
    expect(t.sc_max_buffered_posts == buffered, "buffered posts");
    expect(!exists(t, "SessionIDPlacement") && !exists(t, "sessionIDKey"), "canonical names only");
}
function generate(link_values, json_values, version) {
    let output = work + "/generated" + number++ + ".json";
    let fixture = output + ".fixture";
    write(fixture, {
        settings: { ".name": "settings", ".type": "settings", dns_server: "1.1.1.1" },
        section: [{ ".name": "probe", ".type": "section", enabled: "1", action: "connection",
            selector_proxy_links: link_values, outbound_jsons: json_values }]
    });
    run(["ucode", "-L", lib, lib + "/singbox/generator.uc", "generate-config-fixture",
        fixture, output, "127.0.0.1", "0", "1", "", version]);
    return read(output);
}
function vless_outbound(config) {
    for (let o in config.outbounds) if (o.type == "vless") return o;
    expect(false, "VLESS outbound generated");
}
function has_outbound(config, tag) {
    for (let outbound in config.outbounds)
        if (as_string(outbound.tag || "") == tag)
            return true;
    return false;
}

let last;
for (let aliases in [
    ["uplinkHTTPMethod", "SessionIDPlacement", "SessionIDKey"],
    ["uplinkHttpMethod", "sessionIDPlacement", "sessionIDKey"],
    ["uplink_http_method", "session_placement", "session_key"]
]) {
    let extra = {};
    extra[aliases[0]] = "get";
    extra[aliases[1]] = "HEADER";
    extra[aliases[2]] = "X & session=key";
    extra.scMaxBufferedPosts = 17;
    extra.sessionIDTable = "Base62";
    extra.sessionIDLength = "12-20";
    let query = "";
    for (let k, v in extra) query += "&" + k + "=" + encode("" + v);
    fields(normalize(base + query), "X & session=key", 17);
    for (let shape in [extra, {xhttpSettings:{extra}}, {downloadSettings:{xhttpSettings:{extra}}}])
        fields(normalize(base + "&extra=" + encode(sprintf("%J", shape))), "X & session=key", 17);
    last = normalize(base + "&extra=" + encode(sprintf("%J", extra)));
    // Force regeneration instead of retaining the source URI.
    delete last.share_link;
    fields(normalize(links.serialize_outbound_link(last)), "X & session=key", 17);
    let generated = vless_outbound(generate([base + "&extra=" + encode(sprintf("%J", extra))], [], "1.14.1-extended-2.7.2"));
    fields(generated, "X & session=key", 17);
    expect(!exists(generated.tls.reality, "support_x25519mlkem768"), "manual Reality preference stays unspecified");
}
let priority = normalize(base + "&uplinkHTTPMethod=POST&sessionIDPlacement=cookie&scMaxBufferedPosts=0&extra=" +
    encode('{"uplinkHTTPMethod":"GET","SessionIDPlacement":"header","scMaxBufferedPosts":17}'));
expect(priority.transport.uplink_http_method == "POST" && priority.transport.session_placement == "cookie" &&
    priority.transport.sc_max_buffered_posts == 0, "flat query precedence and zero");
let xray = normalize({outbounds:[{protocol:"vless",tag:"xray",settings:{vnext:[{address:"127.0.0.1",port:19443,
    users:[{id:"00000000-0000-4000-8000-000000000001",encryption:"none"}]}]},streamSettings:{network:"xhttp",
    xhttpSettings:{mode:"packet-up",extra:{uplinkHTTPMethod:"GET",SessionIDPlacement:"header",SessionIDKey:"X-Ray",scMaxBufferedPosts:4}}}}]});
fields(xray, "X-Ray", 4);
let invalid = normalize(base + "&uplinkHTTPMethod=INVALID&SessionIDPlacement=invalid&scMaxBufferedPosts=-1");
expect(!exists(invalid.transport,"uplink_http_method") && !exists(invalid.transport,"session_placement") &&
    !exists(invalid.transport,"sc_max_buffered_posts"), "invalid values excluded");
let native = normalize({outbounds:[{type:"vless",tag:"native",server:"127.0.0.1",server_port:19443,
    uuid:"00000000-0000-4000-8000-000000000001",transport:{type:"xhttp",uplinkHTTPMethod:"GET",
    SessionIDPlacement:"header",SessionIDKey:"X-Native",scMaxBufferedPosts:0,sessionIDTable:"bad"}}]});
fields(native, "X-Native", 0);

let cached = normalize(base + "&uplinkHTTPMethod=GET&SessionIDPlacement=header&SessionIDKey=X-Cache&scMaxBufferedPosts=6&support_x25519mlkem768=false");
for (let k in ["uplink_http_method","session_placement","session_key","sc_max_buffered_posts"])
    delete cached.transport[k];
delete cached.tls.reality.support_x25519mlkem768;
cached.filter_identity = "keep-this-identity";
let cache_file = work + "/cache.json";
write(cache_file, {outbounds:[cached]});
expect(parser.repair_cached_subscription_file(cache_file), "cache repair");
let repaired = read(cache_file).outbounds[0];
fields(repaired, "X-Cache", 6);
expect(repaired.filter_identity == "keep-this-identity", "identity retained");
expect(repaired.tls.reality.support_x25519mlkem768 === false, "explicit Reality false recovered");
repaired.transport.session_key = "explicit-key";
parser.repair_cached_outbounds([repaired]);
expect(repaired.transport.session_key == "explicit-key", "explicit cache setting retained");
let original_bytes = fs.readfile(cache_file);
expect(parser.repair_cached_subscription_file(cache_file) && fs.readfile(cache_file) == original_bytes, "cache repair idempotent");
expect(index(links.serialize_outbound_link(repaired), "support_x25519mlkem768=false") >= 0, "false exported");
// Exercise the actual persistent -> runtime restore and cache format upgrade.
let persistent = work + "/persistent";
let runtime = work + "/runtime-cache";
run(["mkdir", "-p", persistent, runtime]);
let source = "probe-subscription-1";
write(persistent + "/" + source + ".json", {outbounds:[cached]});
fs.writefile(persistent + "/" + source + ".url", "https://feed.example/test");
fs.writefile(persistent + "/" + source + ".user_agent", "Happ");
fs.writefile(persistent + "/" + source + ".hwid", "");
fs.unlink(runtime + "/" + source + ".json");
run(["ucode", "-L", lib, lib + "/subscription/cache.uc", "restore-persistent-source",
    source, runtime, persistent, "https://feed.example/test", "Happ", "", "Default"]);
fields(read(runtime + "/" + source + ".json").outbounds[0], "X-Cache", 6);
fields(read(persistent + "/" + source + ".json").outbounds[0], "X-Cache", 6);
fs.writefile(persistent + "/cache-format", "9\n");
fs.writefile(runtime + "/cache-format", "10\n");
run(["env", "FORKOP_RUNTIME_STATE_DIR=" + runtime, "FORKOP_RUNTIME_CACHE_FORMAT_FILE=" + runtime + "/cache-format",
    "FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR=" + persistent,
    "FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE=" + persistent + "/cache-format",
    "TMP_SUBSCRIPTION_FOLDER=" + runtime + "/subscriptions", "TMP_SING_BOX_FOLDER=" + runtime + "/sing-box",
    "FORKOP_SECTION_CACHE_DIR=" + runtime + "/sections", "FORKOP_SUBSCRIPTION_LINKS_DIR=" + runtime + "/links",
    "FORKOP_SUBSCRIPTION_METADATA_DIR=" + runtime + "/metadata", "FORKOP_OUTBOUND_METADATA_DIR=" + runtime + "/outbounds",
    "ucode", "-L", lib, lib + "/subscription/cache.uc", "ensure-runtime-cache-format"]);
expect(fs.readfile(runtime + "/cache-format") == "12\n", "runtime cache format upgraded");
expect(fs.stat(persistent + "/" + source + ".json") != null, "offline persistent cache retained");

// Generation must also recover an old runtime cache without a network refresh.
// Invalid provider XHTTP nodes must be skipped instead of rejecting the whole config.
let broken_xhttp = {
    type: "vless",
    tag: "broken-xhttp",
    server: "127.0.0.1",
    server_port: 19444,
    uuid: "00000000-0000-4000-8000-000000000002",
    transport: {
        type: "xhttp",
        session_id_table: "Base62",
        session_id_length: "4-8"
    }
};
write(runtime + "/" + source + ".json", {outbounds:[cached, broken_xhttp]});
let cached_fixture = work + "/cached.fixture.json";
let cached_config = work + "/cached.generated.json";
write(cached_fixture, {settings:{".name":"settings",".type":"settings",dns_server:"1.1.1.1"},
    section:[{".name":"probe",".type":"section",enabled:"1",action:"connection",
        subscription_urls:["https://feed.example/test"],
        subscription_url_settings:'{"https://feed.example/test":{"user_agent":"Happ"}}'}]});
run(["env", "TMP_SUBSCRIPTION_FOLDER=" + runtime,
    "FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR=" + persistent,
    "FORKOP_RUNTIME_STATE_DIR=" + runtime, "ucode", "-L", lib,
    lib + "/singbox/generator.uc", "generate-config-fixture", cached_fixture, cached_config,
    "127.0.0.1", "0", "1", "", "1.14.1-extended-2.7.2"]);
let cached_result = read(cached_config);
let cached_generated = vless_outbound(cached_result);
fields(cached_generated, "X-Cache", 6);
expect(cached_generated.tls.reality.support_x25519mlkem768 === false,
    "cached explicit false survives final generation");
expect(!has_outbound(cached_result, "broken-xhttp"),
    "invalid Base62 XHTTP subscription outbound skipped");

for (let version in ["1.13.21", "1.14.1", "1.14.1-extended-2.7.1", "unknown", "1.14.1-extended-2.7.2-rc1",
    "1.14.1-extended-2.7.2", "1.14.1-extended-2.7.20", "1.14.1-extended-2.8.0", "1.14.1-extended-3.0.0"]) {
    let o = vless_outbound(generate([base], [], version));
    expect(!exists(o.tls.reality, "support_x25519mlkem768"), "Reality stays unspecified for " + version);
}
for (let value in [false,true]) {
    for (let parameter in ["support_x25519mlkem768", "supportX25519MLKEM768"]) {
        let uri = base + "&" + parameter + "=" + (value ? "true" : "false");
        expect(normalize(uri).tls.reality.support_x25519mlkem768 === value, "explicit subscription URI Reality preference " + parameter);
        let manual = vless_outbound(generate([uri], [], "1.14.1-extended-2.7.2"));
        expect(manual.tls.reality.support_x25519mlkem768 === value, "explicit manual URI Reality preference " + parameter);
    }
    let o = normalize(base + "&support_x25519mlkem768=" + (value ? "true" : "false"));
    delete o.share_link;
    let result = vless_outbound(generate([], [sprintf("%J",o)], "1.14.1-extended-2.7.2"));
    expect(result.tls.reality.support_x25519mlkem768 === value, "explicit JSON Reality preference");
    expect(normalize(links.serialize_outbound_link(o)).tls.reality.support_x25519mlkem768 === value, "Reality preference round trip");
}
let unspecified = normalize(base);
delete unspecified.share_link;
let unspecified_json = vless_outbound(generate([], [sprintf("%J", unspecified)], "1.14.1-extended-2.7.2"));
expect(!exists(unspecified_json.tls.reality, "support_x25519mlkem768"), "JSON Reality preference stays unspecified");
expect(index(links.serialize_outbound_link(unspecified_json), "support_x25519mlkem768") < 0, "unspecified Reality preference is not exported");
let off = normalize(base);
off.tls.reality.enabled = false;
let off_result = vless_outbound(generate([], [sprintf("%J",off)], "1.14.1-extended-2.7.2"));
expect(!exists(off_result.tls.reality,"support_x25519mlkem768"), "disabled Reality excluded");
// Full CDN profiles: import, generated config, export and cache recovery.
for (let extra in [
    {seqKey:"part_index",sessionKey:"token",seqPlacement:"cookie",sessionPlacement:"header",
     uplinkHTTPMethod:"GET",uplinkDataPlacement:"header",uplinkDataKey:"X-Media-Data",
     xPaddingBytes:"96-1040",xPaddingKey:"_t",xPaddingHeader:"X-Media-Token",
     xPaddingMethod:"tokenish",xPaddingPlacement:"queryInHeader",xPaddingObfsMode:true,
     sessionIDTable:"Base62",sessionIDLength:"16-32",uplinkChunkSize:0,scMaxEachPostBytes:32768},
    {seqKey:"offset",sessionKey:"auth",seqPlacement:"query",sessionPlacement:"query",
     uplinkHTTPMethod:"GET",uplinkDataPlacement:"body",uplinkChunkSize:"65536-65536",
     xPaddingBytes:"100-1000",sessionIDLength:"16-32",scMaxBufferedPosts:100,
     scMaxEachPostBytes:"65536-65536",scMinPostsIntervalMs:"60-75",scStreamUpServerSecs:"75-210"}
]) {
    let uri = base + "&extra=" + encode(sprintf("%J",extra));
    let original = normalize(uri);
    expect(original.transport.seq_key == extra.seqKey, "CDN sequence key");
    expect(original.transport.seq_placement == extra.seqPlacement, "CDN sequence placement");
    expect(original.transport.uplink_data_placement == extra.uplinkDataPlacement, "CDN data placement");
    expect(original.transport.session_id_length == "16-32", "CDN session ID length");
    expect(original.transport.uplink_chunk_size == extra.uplinkChunkSize, "CDN chunk size including zero");
    if (extra.xPaddingObfsMode) {
        expect(original.transport.x_padding_obfs_mode === true, "CDN padding obfuscation");
        expect(original.transport.x_padding_method == "tokenish" && original.transport.x_padding_key == "_t" &&
            original.transport.x_padding_header == "X-Media-Token", "CDN padding format");
        expect(original.transport.uplink_data_key == "X-Media-Data" && original.transport.session_id_table == "Base62",
            "CDN header and session alphabet");
    }
    let transport = sprintf("%J",original.transport);
    delete original.share_link;
    expect(sprintf("%J",normalize(links.serialize_outbound_link(original)).transport) == transport, "full CDN export round trip");
    expect(sprintf("%J",vless_outbound(generate([uri],[],"1.14.1-extended-2.7.2")).transport) == transport,
        "full CDN generated transport");
    original.share_link = uri;
    for (let k in ["seq_key","seq_placement","uplink_data_placement","uplink_data_key","uplink_chunk_size",
        "x_padding_obfs_mode","x_padding_method","x_padding_key","x_padding_header","x_padding_placement",
        "session_id_table","session_id_length"])
        delete original.transport[k];
    parser.repair_cached_outbounds([original]);
    let expected_transport = json(transport);
    expect(length(keys(original.transport)) == length(keys(expected_transport)), "CDN cache field count");
    for (let k,v in expected_transport)
        expect(sprintf("%J",original.transport[k]) == sprintf("%J",v), "CDN cache recovered " + k);
    delete original.share_link;
    delete original.remark;
    if (binary) {
        let path = work + "/cdn-check" + number++ + ".json";
        write(path,{outbounds:[original]});
        run([binary,"check","-c",path]);
    }
}
// Check actual Extended decoding with minimal independent configs.
if (binary) {
    for (let o in [last, repaired, xray]) {
        delete o.share_link;
        delete o.remark;
        delete o.filter_identity;
        if (o.tls) o.tls.reality.support_x25519mlkem768 = true;
        let path = work + "/check" + number++ + ".json";
        write(path, {outbounds:[o]});
        run([binary, "check", "-c", path]);
    }
}
print("Reality/xHTTP regression checks passed: ", checks, " assertions\n");
