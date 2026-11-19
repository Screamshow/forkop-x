// ucode -L LIB tests/subscription_certificate_pins.uc WORK
let fs = require("fs");
let parser = require("subscription.parser");
let links = require("subscription.share_link");
let work = ARGV[0];
function expect(ok, message) { if (!ok) die(message + "\n"); }
let hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
let octets = [];
for (let i = 0; i < 64; i += 2) push(octets, uc(substr(hex, i, 2)));
let colon = join(":", octets);
let expected = "ASNFZ4mrze8BI0VniavN7wEjRWeJq83vASNFZ4mrze8=";
let uri = "vless://00000000-0000-4000-8000-000000000001@127.0.0.1:443?security=tls&sni=localhost&pcs=";
function encode(value) {
    let result = "";
    for (let i = 0; i < length(value); i++) result += sprintf("%%%02X", ord(substr(value, i, 1)));
    return result;
}
function normalize(raw) {
    fs.writefile(work + "/input", raw);
    expect(parser.normalize_content_validated(work + "/input", work + "/output"), "normalize");
    return json(fs.readfile(work + "/output")).outbounds[0];
}
for (let pin in [hex, colon, expected]) {
    let node = normalize(uri + encode(pin));
    expect(type(node.tls.xray_pinned_peer_cert_sha256) == "array" && node.tls.xray_pinned_peer_cert_sha256[0] == expected, "URL pin lost or corrupted");
    let exported = links.serialize_outbound_link(node);
    expect(normalize(exported).tls.xray_pinned_peer_cert_sha256[0] == expected, "pin export roundtrip");
    delete node.tls.xray_pinned_peer_cert_sha256;
    node.tls.certificate_sha256 = [expected];
    parser.repair_cached_outbounds([node]);
    expect(node.tls.xray_pinned_peer_cert_sha256[0] == expected && node.tls.certificate_sha256 == null, "cached URI pin migration");
}
let node = normalize(sprintf("%J", { outbounds: [{protocol:"vless", tag:"pinned", settings:{vnext:[{
    address:"127.0.0.1", port:443, users:[{id:"00000000-0000-4000-8000-000000000001"}]
}]}, streamSettings:{network:"tcp", security:"tls", tlsSettings:{serverName:"localhost", pinnedPeerCertSha256:[colon, hex]}}}] }));
expect(length(node.tls.xray_pinned_peer_cert_sha256) == 1 && node.tls.xray_pinned_peer_cert_sha256[0] == expected, "Xray pins and deduplication");
delete node.tls.xray_pinned_peer_cert_sha256;
node.tls.certificate_sha256 = expected;
expect(normalize(links.serialize_outbound_link(node)).tls.certificate_sha256[0] == expected, "native scalar pin export");
expect(normalize(uri + encode(hex + "," + replace(hex, /^01/, "02"))).tls.xray_pinned_peer_cert_sha256[1] != expected, "multiple pins");
expect(normalize(replace(uri, /&pcs=$/, "")).tls.xray_pinned_peer_cert_sha256 == null, "absent pin");
let empty = {};
parser.add_certificate_pins(empty, []);
expect(empty.certificate_sha256 == null, "empty pin array must remain absent");
print("Certificate pins: URL hex/colon/base64, Xray JSON, deduplication, multiple pins, cache repair and export passed\n");
