#!/usr/bin/env ucode

let common = require("core.common");
let core_ip = require("core.ip");
let bootstrap_endpoint = require("dns.bootstrap_endpoint");
let runtime_constants = require("xrust.constants");
let runtime_url = require("core.url");
let provider_dns = require("xrust.provider_dns");

let as_string = common.as_string;
let bool_option = common.bool_option;
let list_option = common.list_option;
let object_or_empty = common.object_or_empty;
let option = common.option;
let read_json_file = common.read_json_file;

const DNS_FAILOVER_STATE_FILE = getenv("FORKOP_DNS_FAILOVER_STATE_FILE") || "/var/run/forkop/dns-failover.json";
const DNS_HEALTH_ADDRESS_OVERRIDE = getenv("FORKOP_DNS_HEALTH_ADDRESS");
const DNS_HEALTH_ADDRESS = DNS_HEALTH_ADDRESS_OVERRIDE || "127.0.0.42";
const DNS_HEALTH_PORT_BASE = int(getenv("FORKOP_DNS_HEALTH_PORT_BASE") || "10053");
const DNS_ACTIVE_HEALTH_TAG = "dns-health-active-main-in";
const DNS_HEALTH_SOURCE_MODE = "loopback-source-v1";

function server_list(settings, key, fallback) {
    let result = [];
    for (let value in list_option(settings, key)) {
        value = trim(as_string(value));
        if (value != "")
            push(result, value);
    }
    if (length(result) == 0)
        push(result, fallback);
    return result;
}

function arrays_equal(left, right) {
    if (length(left || []) != length(right || []))
        return false;
    for (let i = 0; i < length(left); i++)
        if (as_string(left[i]) != as_string(right[i]))
            return false;
    return true;
}

function detour_tag(settings) {
    if (bool_option(settings, "dns_use_provider", false))
        return "";
    if (!bool_option(settings, "dns_detour_enabled", false))
        return "";
    let section_name = option(settings, "dns_detour_section", "");
    return section_name == "" ? "" : runtime_constants.outbound_tag(section_name);
}

function state_template(settings) {
    let provider = bool_option(settings, "dns_use_provider", false);
    let routes = provider ? provider_dns.discover() : [];
    let servers = [];
    for (let route in routes)
        push(servers, route.server);
    return {
        version: 1,
        provider,
        provider_routes: routes,
        dns_type: provider ? "udp" : option(settings, "dns_type", "udp"),
        bootstrap_dns_type: bootstrap_endpoint.protocol(settings),
        dns_detour: detour_tag(settings),
        main_servers: provider ? servers : server_list(settings, "dns_server", "77.88.8.8"),
        bootstrap_servers: provider ? servers : server_list(settings, "bootstrap_dns_server", "77.88.8.8"),
        main_index: 0,
        bootstrap_index: 0
    };
}

function state_matches(template, state) {
    state = object_or_empty(state);
    return int(state.version || 0) == 1 &&
        as_string(state.dns_type) == template.dns_type &&
        (state.bootstrap_dns_type || "udp") == (template.bootstrap_dns_type || "udp") &&
        as_string(state.dns_detour) == template.dns_detour &&
        !!state.provider == !!template.provider &&
        sprintf("%J", state.provider_routes || []) == sprintf("%J", template.provider_routes || []) &&
        arrays_equal(state.main_servers, template.main_servers) &&
        arrays_equal(state.bootstrap_servers, template.bootstrap_servers);
}

function bounded_index(value, values) {
    let index_value = int(value || 0);
    return index_value >= 0 && index_value < length(values) ? index_value : 0;
}

function normalize_state(settings, state) {
    let result = state_template(settings);
    if (!state_matches(result, state))
        return result;

    result.main_index = bounded_index(object_or_empty(state).main_index, result.main_servers);
    result.bootstrap_index = bounded_index(object_or_empty(state).bootstrap_index, result.bootstrap_servers);
    return result;
}

function failover_selection(applied, candidate) {
    if (type(applied) != "object" || applied.version != 1 || !state_matches(applied, candidate))
        return null;
    let main = int(candidate.main_index);
    let bootstrap = int(candidate.bootstrap_index);
    if (candidate.main_index == null || candidate.bootstrap_index == null ||
        main != candidate.main_index || bootstrap != candidate.bootstrap_index ||
        main < 0 || main >= length(applied.main_servers) ||
        bootstrap < 0 || bootstrap >= length(applied.bootstrap_servers))
        return null;
    return { ...applied, main_index: main, bootstrap_index: bootstrap };
}

function runtime_state(settings, override_state) {
    let state = override_state;
    if (state == null)
        state = read_json_file(DNS_FAILOVER_STATE_FILE);
    return normalize_state(settings, state);
}

function active_values(settings, override_state) {
    let state = runtime_state(settings, override_state);
    return {
        state,
        main: state.main_servers[state.main_index],
        bootstrap: state.bootstrap_servers[state.bootstrap_index]
    };
}

function doh_ipv6_tls(address) {
    // Xrust 0.0.46 derives the HTTP authority from the TLS name. Keep the
    // bracketed authority separate from the literal used for IP SAN checks.
    return { enabled: true, server_name: "[" + address + "]",
        disable_sni: true, verify_server_name: address };
}

function server_from_options(tag_name, dns_type, dns_server, detour) {
    let server = runtime_url.host(dns_server);
    let port = runtime_url.port(dns_server);
    let result = {
        type: "udp",
        tag: tag_name,
        server,
        server_port: 53
    };

    if (dns_type == "udp") {
        if (port != "")
            result.server_port = int(port, 10);
    }
    else if (dns_type == "dot") {
        result.type = "tls";
        result.server_port = port != "" ? int(port, 10) : 853;
    }
    else if (dns_type == "doh") {
        result.type = "https";
        result.server_port = port != "" ? int(port, 10) : 443;
        let path = runtime_url.path(dns_server);
        if (path != "")
            result.path = path;
        if (core_ip.ip_family(server) == 6)
            result.tls = doh_ipv6_tls(server);
    }
    else {
        return { unsupported: "unsupported dns_type " + dns_type };
    }

    if (!core_ip.valid_ip(server))
        result.domain_resolver = runtime_constants.BOOTSTRAP_DNS_SERVER_TAG;
    if (as_string(detour) != "")
        result.detour = as_string(detour);

    return result;
}

function bootstrap_server(tag_name, dns_type, value) {
    let endpoint = bootstrap_endpoint.parse(value, dns_type, true);
    if (endpoint == null)
        return { unsupported: "invalid Bootstrap DNS address for " + dns_type };

    let server = {
        type: { udp: "udp", doh: "https", dot: "tls" }[dns_type],
        tag: tag_name,
        server: endpoint.address,
        server_port: endpoint.port
    };
    if (dns_type == "doh")
        server.path = endpoint.path;
    if (endpoint.tls_name != "")
        server.tls = { enabled: true, server_name: endpoint.tls_name };
    else if (dns_type == "doh" && core_ip.ip_family(endpoint.address) == 6)
        server.tls = doh_ipv6_tls(endpoint.address);
    return server;
}

function provider_tag(route) {
    return "provider-dns-wan-" + route.device + "-" + sprintf("%x", int(route.mark || 0));
}

function provider_outbound(route) {
    let outbound = { type: "direct", tag: provider_tag(route), bind_interface: route.device };
    if (route.mark > 0)
        outbound.routing_mark = route.mark;
    return outbound;
}

function bind_provider(server, state, index_value) {
    if (!state.provider) return server;
    let route = (state.provider_routes || [])[int(index_value)];
    if (route == null)
        return { unsupported: "No online WAN has usable provider DNS and routing. Check WAN DHCP/PPPoE and mwan3." };
    // DNS dial fields are not implemented by every supported core. A direct
    // outbound detour applies the binding consistently to UDP and TCP retries.
    server.detour = provider_tag(route);
    return server;
}

function server_config_from_state(state) {
    return bind_provider(server_from_options(
        runtime_constants.DNS_SERVER_TAG,
        state.dns_type,
        state.main_servers[state.main_index],
        state.dns_detour
    ), state, state.main_index);
}

function bootstrap_config_from_state(state) {
    return bind_provider(bootstrap_server(runtime_constants.BOOTSTRAP_DNS_SERVER_TAG, state.bootstrap_dns_type || "udp",
        state.bootstrap_servers[state.bootstrap_index]), state, state.bootstrap_index);
}

function server_config(settings, override_state) {
    return server_config_from_state(runtime_state(settings, override_state));
}

function bootstrap_config(settings, override_state) {
    return bootstrap_config_from_state(runtime_state(settings, override_state));
}

function failover_enabled(settings) {
    let state = state_template(settings);
    return state.provider || length(state.main_servers) > 1 || length(state.bootstrap_servers) > 1;
}

function health_tag(kind, index_value, suffix) {
    return "dns-health-" + as_string(kind) + "-" + as_string(index_value + 1) + "-" + as_string(suffix);
}

function health_port(kind, index_value) {
    if (kind == "active")
        return DNS_HEALTH_PORT_BASE + 2000;
    return DNS_HEALTH_PORT_BASE + int(index_value) * 2 + (kind == "bootstrap" ? 1 : 0);
}

function health_probe(kind, index_value, applied) {
    if (kind == "active" || applied?.health_probe_mode != DNS_HEALTH_SOURCE_MODE)
        return { port: health_port(kind, index_value), source: "" };
    let slot = int(index_value) + 1;
    let subnet = kind == "main" ? "127.16." : "127.32.";
    return { port: health_port("active", 0), source: subnet + int(slot / 256) + "." + (slot % 256) };
}

function add_active_health_inbound(result) {
    push(result.inbounds, {
        type: "direct",
        tag: DNS_ACTIVE_HEALTH_TAG,
        listen: DNS_HEALTH_ADDRESS,
        listen_port: health_port("active", 0)
    });
    push(result.rules, {
        action: "route",
        inbound: DNS_ACTIVE_HEALTH_TAG,
        server: runtime_constants.DNS_SERVER_TAG,
        disable_cache: true
    });
    push(result.sniff_inbounds, DNS_ACTIVE_HEALTH_TAG);
}

function add_health_rule(result, kind, index_value, server_tag) {
    let probe = health_probe(kind, index_value, result.state);
    let inbound_tag = probe.source != "" ? DNS_ACTIVE_HEALTH_TAG : health_tag(kind, index_value, "in");
    let rule = {
        action: "route",
        inbound: inbound_tag,
        server: server_tag,
        disable_cache: true
    };
    if (probe.source != "")
        rule.source_ip_cidr = probe.source + "/32";
    else {
        push(result.inbounds, { type: "direct", tag: inbound_tag, listen: DNS_HEALTH_ADDRESS, listen_port: probe.port });
        push(result.sniff_inbounds, inbound_tag);
    }
    push(result.rules, rule);
}

function add_health_candidate(result, kind, index_value, server) {
    let server_tag = health_tag(kind, index_value, "server");
    let dns_server = bind_provider(kind == "main"
        ? server_from_options(server_tag, result.state.dns_type, server, result.state.dns_detour)
        : bootstrap_server(server_tag, result.state.bootstrap_dns_type || "udp", server), result.state, index_value);

    if (dns_server.unsupported) {
        result.unsupported = dns_server.unsupported;
        return;
    }

    push(result.servers, dns_server);
    add_health_rule(result, kind, index_value, server_tag);
}

const NTP_BOOTSTRAP_FALLBACK_TAG = runtime_constants.NTP_DNS_SERVER_TAG + "-bootstrap";

function add_ntp_resolver(result, bootstrap, routes) {
    let members = [];
    let seen = {};
    for (let route in routes) {
        let tag = runtime_constants.NTP_DNS_SERVER_TAG + "-wan-" + as_string(length(members) + 1);
        let detour = provider_tag(route);
        push(result.servers, { type: "udp", tag, server: route.server, server_port: 53, detour });
        push(members, tag);
        if (!seen[detour]) {
            push(result.outbounds, provider_outbound(route));
            seen[detour] = true;
        }
    }
    push(result.servers, {
        type: "udp", tag: NTP_BOOTSTRAP_FALLBACK_TAG, server: bootstrap.server, server_port: 53
    });
    // Plain DNS can resolve NTP names before certificate validation is
    // possible; encrypted Bootstrap can resolve them after time is restored.
    push(members, NTP_BOOTSTRAP_FALLBACK_TAG, bootstrap.tag);
    result.ntp_server = runtime_constants.NTP_DNS_SERVER_TAG;
    push(result.servers, { type: "group", tag: result.ntp_server, servers: members, mode: "stable" });
}

function config_from_state(state, ntp_required) {
    let main = server_config_from_state(state);
    if (main.unsupported)
        return { unsupported: main.unsupported, provider_unavailable: state.provider && length(state.provider_routes) == 0 };

    let bootstrap = bootstrap_config_from_state(state);
    if (bootstrap.unsupported)
        return { unsupported: bootstrap.unsupported };

    let result = {
        state,
        servers: [ bootstrap, main ],
        outbounds: [],
        inbounds: [],
        rules: [],
        sniff_inbounds: [],
        ntp_server: runtime_constants.BOOTSTRAP_DNS_SERVER_TAG
    };
    let seen_provider = {};
    for (let route in state.provider_routes) {
        let tag = provider_tag(route);
        if (seen_provider[tag]) continue;
        seen_provider[tag] = true;
        push(result.outbounds, provider_outbound(route));
    }
    if (ntp_required && bootstrap.type != "udp") {
        state.ntp_wan_routes = provider_dns.discover();
        add_ntp_resolver(result, bootstrap, state.ntp_wan_routes);
    }

    // The standard IPv4 loopback can bind a distinct probe source for every
    // resolver. The single listener stays compatible across hot reloads.
    // Preserve the port layout when an operator overrides the listen address.
    let shared_probe = !DNS_HEALTH_ADDRESS_OVERRIDE &&
        length(state.main_servers) < 65536 && length(state.bootstrap_servers) < 65536;
    state.health_probe_mode = shared_probe ? DNS_HEALTH_SOURCE_MODE : null;
    if (!shared_probe)
        add_active_health_inbound(result);
    for (let kind in [ "main", "bootstrap" ]) {
        let values = kind == "main" ? state.main_servers : state.bootstrap_servers;
        let count = shared_probe ? length(values) : max(8, length(values));
        for (let i = 0; i < count; i++) {
            if (length(values) > 1 && i < length(values))
                add_health_candidate(result, kind, i, values[i]);
            else if (!shared_probe || kind == "bootstrap")
                add_health_rule(result, kind, i, kind == "main"
                    ? runtime_constants.DNS_SERVER_TAG : runtime_constants.BOOTSTRAP_DNS_SERVER_TAG);
        }
    }
    // The canonical probe is the fallback within the shared inbound.
    if (shared_probe)
        add_active_health_inbound(result);

    return result;
}

function config(settings, override_state) {
    return config_from_state(runtime_state(settings, override_state));
}

function health_settings(settings) {
    return {
        interval: option(settings, "dns_check_interval", "10s"),
        recovery_interval: option(settings, "dns_recovery_check_interval", "60s"),
        timeout: option(settings, "dns_check_timeout", "2s"),
        failure_threshold: option(settings, "dns_failover_failure_threshold", "3")
    };
}

function default_domain_resolver(settings) {
    return !bool_option(settings, "dns_use_provider", false) && bool_option(settings, "dns_detour_enabled", false)
        ? runtime_constants.BOOTSTRAP_DNS_SERVER_TAG
        : runtime_constants.DNS_SERVER_TAG;
}

const TUNNEL_DNS_TAG_PREFIX = "native-tunnel-dns:";
const APPLIED_DNS_CACHE_NAME = ".dns-failover.json";

function tunnel_dns_tag(section_name) {
    return TUNNEL_DNS_TAG_PREFIX + section_name;
}

function tunnel_dns_server(main, tag, detour, address, protocol) {
    if (address == "")
        return { ...main, tag, detour };

    let server = server_from_options(tag, protocol, address, detour);
    if (server.unsupported)
        die(server.unsupported);
    // Keep the preset's IP as the dial address and verify the provider's
    // certificate by name without making a bootstrap lookup for the preset.
    let preset_names = {
        "1.1.1.1": "one.one.one.one",
        "8.8.8.8": "dns.google",
        "9.9.9.9": "dns.quad9.net"
    };
    if (protocol != "udp" && preset_names[address])
        server.tls = { enabled: true, server_name: preset_names[address] };
    return server;
}

return {
    APPLIED_DNS_CACHE_NAME,
    DNS_FAILOVER_STATE_FILE,
    DNS_HEALTH_ADDRESS,
    active_values,
    arrays_equal,
    bootstrap_config,
    bootstrap_config_from_state,
    config,
    config_from_state,
    default_domain_resolver,
    detour_tag,
    failover_enabled,
    failover_selection,
    health_port,
    health_probe,
    health_settings,
    normalize_state,
    runtime_state,
    server_config,
    server_config_from_state,
    server_from_options,
    server_list,
    state_matches,
    state_template,
    NTP_BOOTSTRAP_FALLBACK_TAG,
    TUNNEL_DNS_TAG_PREFIX,
    tunnel_dns_tag,
    tunnel_dns_server
};
