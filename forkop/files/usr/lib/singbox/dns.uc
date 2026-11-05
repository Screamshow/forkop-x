#!/usr/bin/env ucode

let common = require("core.common");
let core_ip = require("core.ip");
let runtime_constants = require("singbox.constants");
let runtime_url = require("core.url");
let provider_dns = require("singbox.provider_dns");

let as_string = common.as_string;
let bool_option = common.bool_option;
let list_option = common.list_option;
let object_or_empty = common.object_or_empty;
let option = common.option;
let read_json_file = common.read_json_file;

const DNS_FAILOVER_STATE_FILE = getenv("FORKOP_DNS_FAILOVER_STATE_FILE") || "/var/run/forkop/dns-failover.json";
const DNS_HEALTH_ADDRESS = getenv("FORKOP_DNS_HEALTH_ADDRESS") || "127.0.0.42";
const DNS_HEALTH_PORT_BASE = int(getenv("FORKOP_DNS_HEALTH_PORT_BASE") || "10053");

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

function bootstrap_server(tag_name, value) {
    let server = runtime_url.host(value);
    let port = runtime_url.port(value);
    return {
        type: "udp",
        tag: tag_name,
        server: server != "" ? server : value,
        server_port: port != "" ? int(port, 10) : 53
    };
}

function bind_provider(server, state, index_value) {
    if (!state.provider) return server;
    let route = (state.provider_routes || [])[int(index_value)];
    if (route == null)
        return { unsupported: "No online WAN has usable provider DNS and routing. Check WAN DHCP/PPPoE and mwan3." };
    // DNS dial fields are not implemented by every supported core. A direct
    // outbound detour applies the binding consistently to UDP and TCP retries.
    server.detour = "provider-dns-wan-" + route.interface;
    return server;
}

function server_config(settings, override_state) {
    let active = active_values(settings, override_state);
    return bind_provider(server_from_options(
        runtime_constants.DNS_SERVER_TAG,
        active.state.dns_type,
        active.main,
        active.state.dns_detour
    ), active.state, active.state.main_index);
}

function bootstrap_config(settings, override_state) {
    let active = active_values(settings, override_state);
    return bind_provider(bootstrap_server(runtime_constants.BOOTSTRAP_DNS_SERVER_TAG, active.bootstrap),
        active.state, active.state.bootstrap_index);
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

function add_active_health_inbound(result) {
    let inbound_tag = "dns-health-active-main-in";
    push(result.inbounds, {
        type: "direct",
        tag: inbound_tag,
        listen: DNS_HEALTH_ADDRESS,
        listen_port: health_port("active", 0)
    });
    push(result.rules, {
        action: "route",
        inbound: inbound_tag,
        server: runtime_constants.DNS_SERVER_TAG,
        disable_cache: true
    });
    push(result.sniff_inbounds, inbound_tag);
}

function add_health_candidate(result, kind, index_value, server) {
    let server_tag = health_tag(kind, index_value, "server");
    let inbound_tag = health_tag(kind, index_value, "in");
    let dns_server = bind_provider(kind == "main"
        ? server_from_options(server_tag, result.state.dns_type, server, result.state.dns_detour)
        : bootstrap_server(server_tag, server), result.state, index_value);

    if (dns_server.unsupported) {
        result.unsupported = dns_server.unsupported;
        return;
    }

    push(result.servers, dns_server);
    push(result.inbounds, {
        type: "direct",
        tag: inbound_tag,
        listen: DNS_HEALTH_ADDRESS,
        listen_port: health_port(kind, index_value)
    });
    push(result.rules, {
        action: "route",
        inbound: inbound_tag,
        server: server_tag,
        disable_cache: true
    });
    push(result.sniff_inbounds, inbound_tag);
}

function add_health_slot(result, kind, index_value) {
    let tag = health_tag(kind, index_value, "in");
    push(result.inbounds, { type: "direct", tag,
        listen: DNS_HEALTH_ADDRESS, listen_port: health_port(kind, index_value) });
    push(result.rules, { action: "route", inbound: tag,
        server: kind == "main" ? runtime_constants.DNS_SERVER_TAG : runtime_constants.BOOTSTRAP_DNS_SERVER_TAG,
        disable_cache: true });
    push(result.sniff_inbounds, tag);
}

function config(settings, override_state) {
    let state = runtime_state(settings, override_state);
    let main = server_config(settings, state);
    if (main.unsupported)
        return { unsupported: main.unsupported, provider_unavailable: state.provider && length(state.provider_routes) == 0 };

    let result = {
        state,
        servers: [ bootstrap_config(settings, state), main ],
        outbounds: [],
        inbounds: [],
        rules: [],
        sniff_inbounds: []
    };
    let seen_provider = {};
    for (let route in state.provider_routes) {
        if (seen_provider[route.interface]) continue;
        seen_provider[route.interface] = true;
        let outbound = { type: "direct", tag: "provider-dns-wan-" + route.interface,
            bind_interface: route.device };
        if (route.mark > 0) outbound.routing_mark = route.mark;
        push(result.outbounds, outbound);
    }

    // Reserve loopback health listeners independently of selected DNS mode.
    // Changing listeners requires a cold core restart. Eight slots per kind
    // covers normal dual/multi-WAN lists without adding duplicate resolvers.
    // Larger existing lists remain supported (their capacity changes may restart).
    add_active_health_inbound(result);
    for (let kind in [ "main", "bootstrap" ]) {
        let values = kind == "main" ? state.main_servers : state.bootstrap_servers;
        for (let i = 0; i < max(8, length(values)); i++) {
            if (length(values) > 1 && i < length(values))
                add_health_candidate(result, kind, i, values[i]);
            else
                add_health_slot(result, kind, i);
        }
    }

    return result;
}

function default_domain_resolver(settings) {
    return !bool_option(settings, "dns_use_provider", false) && bool_option(settings, "dns_detour_enabled", false)
        ? runtime_constants.BOOTSTRAP_DNS_SERVER_TAG
        : runtime_constants.DNS_SERVER_TAG;
}

return {
    DNS_FAILOVER_STATE_FILE,
    DNS_HEALTH_ADDRESS,
    active_values,
    arrays_equal,
    bootstrap_config,
    config,
    default_domain_resolver,
    detour_tag,
    failover_enabled,
    health_port,
    normalize_state,
    runtime_state,
    server_config,
    server_from_options,
    server_list,
    state_matches,
    state_template
};
