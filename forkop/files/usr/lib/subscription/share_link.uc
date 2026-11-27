#!/usr/bin/env ucode

let fs = require("fs");
let xhttp_quic = require("subscription.xhttp_quic");
let common = require("core.common");

let as_string = common.as_string;
let array_or_empty = common.array_or_empty;

function starts_with(value, prefix) {
    value = as_string(value);
    prefix = as_string(prefix);
    return substr(value, 0, length(prefix)) == prefix;
}

function uri_encode(value) {
    value = as_string(value);
    let result = "";
    for (let i = 0; i < length(value); i++) {
        let char = substr(value, i, 1);
        let code = ord(char);
        if ((code >= 48 && code <= 57) ||
            (code >= 65 && code <= 90) ||
            (code >= 97 && code <= 122) ||
            char == "-" || char == "_" || char == "." || char == "~")
            result += char;
        else
            result += sprintf("%%%02X", code);
    }
    return result;
}

function base64_encode(value) {
    let encoded = b64enc(as_string(value));
    while (length(encoded) > 0 && substr(encoded, length(encoded) - 1) == "=")
        encoded = substr(encoded, 0, length(encoded) - 1);
    return encoded;
}

function host_port(server, port) {
    server = as_string(server);
    if (index(server, ":") >= 0 && !starts_with(server, "["))
        server = "[" + server + "]";
    return server + ":" + as_string(port);
}

function hysteria2_server_port_entry(value) {
    value = as_string(value);
    let colon = index(value, ":");
    if (colon < 0)
        return value;

    let start = substr(value, 0, colon);
    let end = substr(value, colon + 1);
    if (start == "" || end == "")
        return "";

    return start == end ? start : (start + "-" + end);
}

function hysteria2_server_ports_uri(outbound) {
    let server_ports = array_or_empty(outbound.server_ports);
    if (length(server_ports) == 0)
        return "";

    let result = [];
    for (let item in server_ports) {
        let port = hysteria2_server_port_entry(item);
        if (port != "")
            push(result, port);
    }

    return join(",", result);
}

function add_query(params, key, value) {
    value = as_string(value);
    if (value != "")
        push(params, uri_encode(key) + "=" + uri_encode(value));
}

function xhttp_xray_range(value) {
    if (type(value) != "object")
        return value;
    return value.from == value.to ? value.from : value.from + "-" + value.to;
}

function xhttp_extra(transport) {
    let extra = {};
    if (type(transport.headers) == "object")
        extra.headers = transport.headers;

    for (let item in [
        ["xPaddingBytes", "x_padding_bytes"],
        ["scMaxEachPostBytes", "sc_max_each_post_bytes"],
        ["scMinPostsIntervalMs", "sc_min_posts_interval_ms"],
        ["scStreamUpServerSecs", "sc_stream_up_server_secs"],
        ["uplinkChunkSize", "uplink_chunk_size"],
        ["sessionIDLength", "session_id_length"]
    ]) {
        if (transport[item[1]] != null)
            extra[item[0]] = xhttp_xray_range(transport[item[1]]);
    }

    for (let item in [
        ["noGRPCHeader", "no_grpc_header"],
        ["uplinkHTTPMethod", "uplink_http_method"],
        ["sessionIDPlacement", "session_placement"],
        ["sessionIDKey", "session_key"],
        ["scMaxBufferedPosts", "sc_max_buffered_posts"],
        ["seqPlacement", "seq_placement"], ["seqKey", "seq_key"],
        ["uplinkDataPlacement", "uplink_data_placement"], ["uplinkDataKey", "uplink_data_key"],
        ["xPaddingObfsMode", "x_padding_obfs_mode"], ["xPaddingKey", "x_padding_key"],
        ["xPaddingHeader", "x_padding_header"], ["xPaddingPlacement", "x_padding_placement"],
        ["xPaddingMethod", "x_padding_method"],
        ["sessionIDTable", "session_id_table"]
    ]) {
        if (transport[item[1]] != null)
            extra[item[0]] = transport[item[1]];
    }

    if (type(transport.xmux) == "object") {
        let xmux = {};
        for (let item in [
            ["maxConcurrency", "max_concurrency"],
            ["maxConnections", "max_connections"],
            ["cMaxReuseTimes", "c_max_reuse_times"],
            ["hMaxRequestTimes", "h_max_request_times"],
            ["hMaxReusableSecs", "h_max_reusable_secs"]
        ]) {
            if (transport.xmux[item[1]] != null)
                xmux[item[0]] = xhttp_xray_range(transport.xmux[item[1]]);
        }
        if (transport.xmux.h_keep_alive_period != null)
            xmux.hKeepAlivePeriod = transport.xmux.h_keep_alive_period;
        if (length(keys(xmux)) > 0)
            extra.xmux = xmux;
    }

    return extra;
}

function tls_values(value) {
    return type(value) == "array" ? value : value == null ? [] : [value];
}

function add_xray_verification_query(params, tls) {
    add_query(params, "pcs", join(",", tls_values(tls.xray_pinned_peer_cert_sha256)));
    add_query(params, "vcn", join(",", tls_values(tls.verify_server_name)));
}

function xhttp_download_stream(download) {
    let transport = download.transport;
    let result = { address: download.server, port: download.server_port, network: "xhttp", security: "none",
        xhttpSettings: { host: transport.host, path: transport.path, extra: xhttp_extra(transport) } };
    let finalmask = xhttp_quic.to_finalmask(transport.quic_params);
    if (finalmask != null)
        result.finalmask = finalmask;
    let tls = download.tls;
    if (type(tls) != "object" || tls.enabled === false)
        return result;
    if (type(tls.reality) == "object" && tls.reality.enabled !== false) {
        result.security = "reality";
        result.realitySettings = { serverName: tls.server_name, fingerprint: tls.utls?.fingerprint,
            password: tls.reality.public_key, shortId: tls.reality.short_id,
            supportX25519MLKEM768: tls.reality.support_x25519mlkem768,
            mldsa65Verify: tls.reality.__forkop_mldsa65_verify };
    }
    else {
        result.security = "tls";
        result.tlsSettings = { serverName: tls.server_name, fingerprint: tls.utls?.fingerprint,
            allowInsecure: tls.insecure, alpn: tls.alpn,
            pinnedPeerCertSha256: join(",", tls_values(tls.xray_pinned_peer_cert_sha256)),
            verifyPeerCertByName: join(",", tls_values(tls.verify_server_name)),
            pinSHA256: tls.certificate_sha256 };
    }
    return result;
}

function add_tls_query(params, outbound, trojan_default_tls) {
    let tls = type(outbound.tls) == "object" ? outbound.tls : null;
    if (!tls || tls.enabled === false) {
        if (trojan_default_tls)
            add_query(params, "security", "tls");
        return;
    }

    let reality = type(tls.reality) == "object" ? tls.reality : null;
    if (reality && reality.enabled !== false) {
        add_query(params, "security", "reality");
        add_query(params, "pbk", reality.public_key);
        add_query(params, "sid", reality.short_id);
        if (type(reality.support_x25519mlkem768) == "bool")
            add_query(params, "support_x25519mlkem768", reality.support_x25519mlkem768 ? "true" : "false");
        if (as_string(reality.__forkop_mldsa65_verify || "") != "")
            add_query(params, "pqv", reality.__forkop_mldsa65_verify);
    }
    else {
        add_query(params, "security", "tls");
    }

    add_query(params, "sni", tls.server_name);
    add_xray_verification_query(params, tls);
    add_query(params, "pinSHA256", join(",", tls_values(tls.certificate_sha256)));
    if (tls.insecure === true)
        add_query(params, "allowInsecure", "1");
    if (type(tls.utls) == "object" && tls.utls.enabled !== false)
        add_query(params, "fp", tls.utls.fingerprint);
    if (type(tls.alpn) == "array" && length(tls.alpn) > 0)
        add_query(params, "alpn", join(",", tls.alpn));
}

function add_transport_query(params, outbound) {
    let transport = type(outbound.transport) == "object" ? outbound.transport : null;
    if (!transport) {
        add_query(params, "type", "tcp");
        return;
    }

    let transport_type = as_string(transport.type);
    add_query(params, "type", transport_type != "" ? transport_type : "tcp");

    if (transport_type == "ws") {
        add_query(params, "path", transport.path);
        if (type(transport.headers) == "object")
            add_query(params, "host", transport.headers.Host || transport.headers.host);
    }
    else if (transport_type == "grpc") {
        add_query(params, "serviceName", transport.service_name);
        if (transport.multi_mode === true)
            add_query(params, "mode", "multi");
    }
    else if (transport_type == "http") {
        add_query(params, "path", transport.path);
        if (type(transport.host) == "array" && length(transport.host) > 0)
            add_query(params, "host", join(",", transport.host));
        else
            add_query(params, "host", transport.host);
    }
    else if (transport_type == "xhttp") {
        add_query(params, "path", transport.path);
        add_query(params, "host", transport.host);
        add_query(params, "mode", transport.mode);
        let finalmask = xhttp_quic.to_finalmask(transport.quic_params);
        if (finalmask != null)
            add_query(params, "fm", sprintf("%J", finalmask));
        let extra = xhttp_extra(transport);
        if (type(transport.download_settings) == "object" && type(transport.download_settings.transport) == "object")
            extra.downloadSettings = xhttp_download_stream(transport.download_settings);
        if (length(keys(extra)) > 0)
            add_query(params, "extra", sprintf("%J", extra));
    }
}

function query_string(params) {
    return length(params) == 0 ? "" : "?" + join("&", params);
}

function fragment(outbound) {
    let tag = as_string(outbound.tag);
    return tag == "" ? "" : "#" + uri_encode(tag);
}

function serialize_vless(outbound) {
    if (as_string(outbound.uuid) == "" || as_string(outbound.server) == "" || outbound.server_port == null)
        return "";
    let params = [];
    add_tls_query(params, outbound, false);
    add_transport_query(params, outbound);
    let encryption = as_string(outbound.encryption);
    if (encryption != "" && encryption != "none")
        add_query(params, "encryption", encryption);
    add_query(params, "flow", outbound.flow);
    add_query(params, "packetEncoding", outbound.packet_encoding);
    return "vless://" + uri_encode(outbound.uuid) + "@" +
        host_port(outbound.server, outbound.server_port) + query_string(params) + fragment(outbound);
}

function serialize_trojan(outbound) {
    if (as_string(outbound.password) == "" || as_string(outbound.server) == "" || outbound.server_port == null)
        return "";
    let params = [];
    add_tls_query(params, outbound, true);
    add_transport_query(params, outbound);
    return "trojan://" + uri_encode(outbound.password) + "@" +
        host_port(outbound.server, outbound.server_port) + query_string(params) + fragment(outbound);
}

function serialize_shadowsocks(outbound) {
    if (as_string(outbound.method) == "" || as_string(outbound.password) == "" ||
        as_string(outbound.server) == "" || outbound.server_port == null)
        return "";
    let userinfo = base64_encode(as_string(outbound.method) + ":" + as_string(outbound.password));
    return userinfo == "" ? "" :
        "ss://" + userinfo + "@" + host_port(outbound.server, outbound.server_port) + fragment(outbound);
}

function serialize_socks(outbound) {
    if (as_string(outbound.server) == "" || outbound.server_port == null)
        return "";

    let scheme = "socks" + as_string(outbound.version || "5");
    let auth = "";
    if (as_string(outbound.username) != "") {
        auth = uri_encode(outbound.username);
        if (as_string(outbound.password) != "")
            auth += ":" + uri_encode(outbound.password);
        auth += "@";
    }

    return scheme + "://" + auth + host_port(outbound.server, outbound.server_port) + fragment(outbound);
}

function certificate_pin_hex(pin) {
    let bytes = b64dec(as_string(pin));
    if (bytes == null || length(bytes) != 32)
        return as_string(pin);
    let hex = "";
    for (let i = 0; i < 32; i++)
        hex += sprintf("%02x", ord(bytes, i));
    return hex;
}

function serialize_hysteria2(outbound) {
    let port = hysteria2_server_ports_uri(outbound);
    if (port == "" && outbound.server_port != null)
        port = as_string(outbound.server_port);

    if (as_string(outbound.password) == "" || as_string(outbound.server) == "" || port == "")
        return "";

    let params = [];
    let tls = type(outbound.tls) == "object" ? outbound.tls : null;
    if (tls) {
        add_query(params, "sni", tls.server_name);
        add_xray_verification_query(params, tls);
        if (tls.insecure === true)
            add_query(params, "insecure", "1");
        if (type(tls.alpn) == "array" && length(tls.alpn) > 0)
            add_query(params, "alpn", join(",", tls.alpn));
        let pins = type(tls.certificate_sha256) == "array" ? tls.certificate_sha256 :
            (tls.certificate_sha256 != null ? [tls.certificate_sha256] : []);
        if (length(pins) > 0)
            add_query(params, "pinSHA256", join(",", map(pins, certificate_pin_hex)));
    }
    if (type(outbound.obfs) == "object") {
        add_query(params, "obfs", outbound.obfs.type);
        add_query(params, "obfs-password", outbound.obfs.password);
    }

    return "hysteria2://" + uri_encode(outbound.password) + "@" +
        host_port(outbound.server, port) + query_string(params) + fragment(outbound);
}

function serialize_vmess(outbound) {
    if (as_string(outbound.uuid) == "" || as_string(outbound.server) == "" || outbound.server_port == null)
        return "";

    let vmess = {
        v: "2",
        ps: as_string(outbound.tag),
        add: as_string(outbound.server),
        port: as_string(outbound.server_port),
        id: as_string(outbound.uuid),
        aid: as_string(outbound.alter_id || 0),
        scy: as_string(outbound.security || "auto"),
        net: "tcp",
        type: "none",
        host: "",
        path: "",
        tls: "",
        sni: ""
    };

    if (type(outbound.tls) == "object" && outbound.tls.enabled !== false) {
        vmess.tls = "tls";
        vmess.sni = as_string(outbound.tls.server_name);
        if (type(outbound.tls.utls) == "object")
            vmess.fp = as_string(outbound.tls.utls.fingerprint);
    }

    if (type(outbound.transport) == "object") {
        vmess.net = as_string(outbound.transport.type || "tcp");
        if (vmess.net == "ws") {
            vmess.path = as_string(outbound.transport.path);
            if (type(outbound.transport.headers) == "object")
                vmess.host = as_string(outbound.transport.headers.Host || outbound.transport.headers.host);
        }
        else if (vmess.net == "grpc") {
            vmess.path = as_string(outbound.transport.service_name);
        }
        else if (vmess.net == "http") {
            vmess.path = as_string(outbound.transport.path);
            if (type(outbound.transport.host) == "array" && length(outbound.transport.host) > 0)
                vmess.host = join(",", outbound.transport.host);
            else
                vmess.host = as_string(outbound.transport.host);
        }
    }

    let encoded = base64_encode(sprintf("%J", vmess));
    return encoded == "" ? "" : "vmess://" + encoded;
}

function serialize_outbound_link(outbound) {
    if (type(outbound) != "object")
        return "";

    let outbound_type = as_string(outbound.type);
    if (outbound_type == "vless")
        return serialize_vless(outbound);
    if (outbound_type == "trojan")
        return serialize_trojan(outbound);
    if (outbound_type == "shadowsocks")
        return serialize_shadowsocks(outbound);
    if (outbound_type == "socks")
        return serialize_socks(outbound);
    if (outbound_type == "hysteria2")
        return serialize_hysteria2(outbound);
    if (outbound_type == "vmess")
        return serialize_vmess(outbound);
    return "";
}

function is_copyable_link(value) {
    value = lc(as_string(value));
    let prefixes = [
        "vless://", "vmess://", "trojan://", "ss://", "ssr://",
        "hysteria2://", "hy2://", "tuic://",
        "socks4://", "socks4a://", "socks5://"
    ];
    for (let prefix in prefixes) {
        if (starts_with(value, prefix))
            return true;
    }
    return false;
}

function populate_subscription_links(subscription) {
    if (type(subscription) != "object" || type(subscription.outbounds) != "array")
        return 0;

    let changed = 0;
    for (let outbound in subscription.outbounds) {
        if (type(outbound) != "object" || is_copyable_link(outbound.share_link))
            continue;

        let link = serialize_outbound_link(outbound);
        if (link == "")
            continue;

        outbound.share_link = link;
        changed++;
    }

    return changed;
}

function populate_subscription_file(path) {
    path = as_string(path);
    let data = fs.readfile(path);
    if (data == null)
        return false;

    let subscription;
    try {
        subscription = json(data);
    }
    catch (e) {
        return false;
    }

    if (populate_subscription_links(subscription) == 0)
        return !!fs.chmod(path, 0600);

    let stamp = clock();
    let tmp_path = sprintf("%s.%d.%d.tmp", path, stamp[0], stamp[1]);
    if (common.write_private_json_file(tmp_path, subscription) == null)
        return false;

    if (!fs.rename(tmp_path, path)) {
        fs.unlink(tmp_path);
        return false;
    }

    return true;
}

function populate_subscription_dir(path) {
    path = as_string(path);
    let ok = true;
    for (let file_path in fs.glob(path + "/*.json"))
        if (!populate_subscription_file(file_path))
            ok = false;

    return ok;
}

return {
    serialize_outbound_link,
    is_copyable_link,
    populate_subscription_links,
    populate_subscription_file,
    populate_subscription_dir
};
