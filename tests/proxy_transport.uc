let transport = require("singbox.proxy_transport");
let config = {
    outbounds: [
        {type:"direct",tag:"direct-out"},
        {type:"direct",tag:"bypass-out",routing_mark:0x08000000},
        {type:"vless",tag:"proxy",routing_mark:0x400},
        {type:"direct",tag:"connection-interface",bind_interface:"wg0"},
        {type:"hysteria2",tag:"hy2"},
        {type:"masque",tag:"warp"},
        {type:"selector",tag:"section",outbounds:["proxy","direct-out"]}
    ],
    endpoints:[{type:"wireguard",tag:"awg",routing_mark:0x800}]
};
transport.protect_range(config,2,0,true);
assert(config.outbounds[0].routing_mark == null, "global Direct is not protected");
assert(config.outbounds[1].routing_mark == 0x08000000, "bypass Direct keeps its mark");
assert(config.outbounds[2].routing_mark == 0x0a000400, "proxy preserves custom mark bits");
assert(config.outbounds[3].routing_mark == 0x0a000000, "Connection interface is protected");
assert(config.outbounds[4].routing_mark == 0x0a000000, "HY2 protected");
assert(config.outbounds[5].routing_mark == 0x0a000000, "MASQUE protected");
assert(config.outbounds[6].routing_mark == null, "selector does not add a socket mark");
assert(config.endpoints[0].routing_mark == 0x0a000800, "AWG preserves custom mark bits");
transport.protect_range(config,2,0,true);
assert(config.outbounds[2].routing_mark == 0x0a000400, "idempotent");
let legacy = {outbounds:[{type:"hysteria2"},{type:"masque"}],endpoints:[{type:"wireguard"}]};
transport.protect_range(legacy,0,0);
assert(legacy.endpoints[0].routing_mark == 0x0a000000, "Forkop-first upgrade emits the existing backwards-compatible field");
assert(legacy.outbounds[0].routing_mark == 0x0a000000, "HY2 configuration stays compatible before the core update");
let marks = require("diagnostics.mark_rules");
let own = "meta mark & 0x02000000 != 0x00000000 ct mark set ct mark | 0x02000000";
assert(marks.is_proxy_transport_mark("inet", "forkop_proxy_transport", own), "known transport rule");
assert(!marks.is_proxy_transport_mark("inet", "foreign", own), "foreign table is not hidden");
assert(!marks.is_proxy_transport_mark("inet", "forkop_proxy_transport", replace(own,"0x02000000","0x01000000")), "foreign mark is not hidden");
print("PASS Connection/AWG marked; Direct retained; Forkop-first configuration remains compatible\n");
