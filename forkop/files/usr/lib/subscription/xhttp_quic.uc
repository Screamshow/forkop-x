#!/usr/bin/env ucode

let fields = [
    ["congestion", "congestion"],
    ["bbrProfile", "bbr_profile"],
    ["brutalUp", "brutal_up"],
    ["brutalDown", "brutal_down"],
    ["brutalDisableLossCompensation", "brutal_disable_loss_compensation"],
    ["initStreamReceiveWindow", "init_stream_receive_window"],
    ["maxStreamReceiveWindow", "max_stream_receive_window"],
    ["initConnectionReceiveWindow", "init_connection_receive_window"],
    ["maxConnectionReceiveWindow", "max_connection_receive_window"],
    ["maxIdleTimeout", "max_idle_timeout"],
    ["keepAlivePeriod", "keep_alive_period"],
    ["disablePathMTUDiscovery", "disable_path_mtu_discovery"],
    ["disableChromeParrot", "disable_chrome_parrot"],
    ["disableGSO", "disable_gso"],
    ["maxIncomingStreams", "max_incoming_streams"],
    ["disableStatelessReset", "disable_stateless_reset"],
    ["udpHop", "udp_hop"]
];

function translate(value, from_xray) {
    if (type(value) != "object")
        return null;
    let result = {};
    for (let names in fields) {
        let key = names[from_xray ? 0 : 1];
        if (value[key] != null)
            result[names[from_xray ? 1 : 0]] = value[key];
    }
    return length(keys(result)) > 0 ? result : null;
}

function from_finalmask(finalmask) {
    return translate(finalmask?.quicParams, true);
}

function to_finalmask(options) {
    let params = translate(options, false);
    return params == null ? null : { quicParams: params };
}

function uses_h3(tls) {
    return tls?.enabled === true && tls.reality?.enabled !== true &&
        (tls.alpn == "h3" || (type(tls.alpn) == "array" && length(tls.alpn) == 1 && tls.alpn[0] == "h3"));
}

return { from_finalmask, to_finalmask, uses_h3 };
