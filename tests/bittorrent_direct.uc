#!/usr/bin/ucode
// ucode -L <Forkop library> tests/bittorrent_direct.uc
let route = require("singbox.route");
for (let enabled in [false, true]) {
    for (let supported in [false, true]) {
        let config = route.config({ bittorrent_direct: enabled ? "1" : "0" },
            { supports_bittorrent_direct: supported });
        let matches = filter(config.rules, r => r.protocol == "bittorrent");
        assert(length(matches) == (enabled && supported ? 1 : 0), "capability/setting gating");
        let sniff = filter(config.rules, r => r.action == "sniff")[0];
        if (enabled && supported) {
            assert(matches[0].outbound == "direct-out", "must select DIRECT");
            assert(sniff.sniffer[0] == "bittorrent-extended", "extended sniffer before HTTP");
        } else {
            assert(sniff.sniffer == null, "default sniffing unchanged when unavailable");
        }
    }
}
// An absent option upgrades to enabled on a capable Xrust. Explicit 0 above
// must remain disabled; unsupported cores must never receive the extension.
for (let supported in [false, true]) {
    let config = route.config({}, { supports_bittorrent_direct: supported });
    assert(length(filter(config.rules, r => r.protocol == "bittorrent")) == (supported ? 1 : 0),
        "missing setting follows capable-core default");
}
print("PASS: BitTorrent setting/capability gate and route contract\n");
