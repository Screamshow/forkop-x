#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let ip = require("core.ip");
let url = require("core.url");
let uci = require("core.uci");
let endpoint = require("dns.bootstrap_endpoint");

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
const CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
const DEFAULT_TIMEOUT = 3;

let has_timeout;

function configured() {
    // Provider mode hides the transport switch. Before Xrust is available,
    // preserve the configured direct UDP fallback without mwan3 route marks.
    let settings = common.object_or_empty(uci.get_all(CONFIG_NAME, "settings"));
    let protocol = endpoint.protocol(settings);
    let values = settings.bootstrap_dns_server;
    if (type(values) != "array")
        values = split(trim(values || ""), /[ \t\r\n]+/);
    return { protocol, servers: filter(values, value => endpoint.parse(value, protocol) != null) };
}

function command_output(args) {
    let quoted = map(args, value => "'" + replace("" + value, /'/g, "'\\''") + "'");
    let pipe = fs.popen(join(" ", quoted) + " 2>/dev/null", "r");
    if (!pipe)
        return "";
    let output = pipe.read("all");
    let status = pipe.close();
    return status == 0 && output != null ? output : "";
}

function query(host, server, protocol, timeout_seconds, query_type) {
    // Ignore .digrc to keep the selected transport and strict TLS settings.
    let args = ["dig", "-r", "+short", "+nosearch", "@" + server.address,
        "-p", server.port, "-q", host, "-t", query_type, "+time=" + timeout_seconds, "+tries=1"];
    if (protocol == "doh")
        push(args, "+https=" + server.path);
    else if (protocol == "dot")
        push(args, "+tls");
    if (protocol != "udp") {
        push(args, "+tls-ca=" + CA_BUNDLE);
        // With an IP destination dig can otherwise verify only the CA chain.
        push(args, "+tls-hostname=" + (server.tls_name || server.address));
    }

    if (has_timeout == null)
        has_timeout = system("command -v timeout >/dev/null 2>&1") == 0;
    if (has_timeout)
        args = ["timeout", "-s", "KILL", timeout_seconds, ...args];
    let family = query_type == "AAAA" ? 6 : 4;
    for (let line in split(command_output(args), "\n")) {
        let address = trim(line);
        if (ip.ip_family(address) == family)
            return address;
    }
    return "";
}

function lookup(host, value, protocol, timeout_seconds, query_type) {
    let server = endpoint.parse(value, protocol);
    let timeout = timeout_seconds == null ? DEFAULT_TIMEOUT : int(timeout_seconds);
    if (server == null || host == "" || timeout <= 0)
        return "";
    let deadline = int(clock(true)[0]) + timeout;
    let address = query(host, server, protocol, timeout, query_type || "A");
    if (address != "" || query_type != null)
        return address;
    let remaining = deadline - int(clock(true)[0]);
    return remaining > 0 ? query(host, server, protocol, remaining, "AAAA") : "";
}

function resolve_url(url_value, settings) {
    let host = url.host(url_value);
    if (host == "" || ip.valid_ip(host))
        return null;
    for (let server in settings.servers) {
        let address = lookup(host, server, settings.protocol);
        if (address != "")
            return {
                host,
                port: url.port(url_value) || (url.scheme(url_value) == "http" ? "80" : "443"),
                address
            };
    }
    return null;
}

return { configured, lookup, resolve_url };
