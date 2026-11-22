#!/usr/bin/env ucode

let common = require("core.common");
let ip = require("core.ip");
let url = require("core.url");

const DEFAULT_PORTS = { udp: 53, doh: 443, dot: 853 };

// The preset addresses are dialed directly. These names identify their TLS
// certificates without a DNS lookup during startup.
const PRESET_TLS_NAMES = {
    "1.1.1.1": "cloudflare-dns.com",
    "1.0.0.1": "cloudflare-dns.com",
    "8.8.8.8": "dns.google",
    "8.8.4.4": "dns.google",
    "9.9.9.9": "dns.quad9.net",
    "9.9.9.11": "dns11.quad9.net",
    "77.88.8.8": "common.dot.dns.yandex.net",
    "77.88.8.1": "common.dot.dns.yandex.net"
};

function protocol(settings) {
    let selected = common.option(settings, "dns_type", "udp");
    return common.bool_option(settings, "dns_use_provider", false) ||
        common.option(settings, "bootstrap_dns_legacy_type", "") == selected ? "udp" : selected;
}

function legacy_hostname(value) {
    return length(value) <= 253 && index(value, ".") > 0 &&
        substr(value, length(value) - 1, 1) != "." && match(value, /^[a-zA-Z0-9_.-]+$/) != null;
}

function parse(value, protocol, allow_udp_hostname) {
    let default_port = DEFAULT_PORTS[protocol];
    if (default_port == null)
        return null;

    value = trim(common.as_string(value));
    if (value == "" || match(value, /[[:cntrl:][:space:]]/))
        return null;

    // Older backend configurations could include a scheme. The DNS type
    // setting supplies the protocol for both lists.
    value = replace(value, /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//, "");
    value = split(value, /[?#]/)[0];
    let authority = split(value, "/")[0];
    let address = url.host(authority);
    let port_text = url.port(authority);
    if (!ip.valid_ip(address) && !(protocol == "udp" && allow_udp_hostname && legacy_hostname(address)))
        return null;

    let host = substr(authority, 0, 1) == "[" ? "[" + address + "]" : address;
    if (authority != host + (port_text != "" ? ":" + port_text : ""))
        return null;

    let port = default_port;
    if (port_text != "") {
        if (!match(port_text, /^[0-9]+$/))
            return null;
        port = int(port_text, 10);
        if (port < 1 || port > 65535)
            return null;
    }

    let path = protocol == "doh" ? url.path(value) || "/dns-query" : "";
    let tls_name = protocol == "udp" ? "" : PRESET_TLS_NAMES[address] || "";
    return { address, port, path, tls_name, authority };
}

return { parse, protocol };
