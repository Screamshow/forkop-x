#!/usr/bin/env ucode

let common = require("core.common");
let connections = require("config.connections");
let core_ip = require("core.ip");
let runtime_constants = require("singbox.constants");

let option = common.option;
let bool_option = common.bool_option;

function as_string(value) {
    return value == null ? "" : "" + value;
}

function bool_value(value) {
    return value === true || value == "1" || value == "true" || value == "yes" || value == "on";
}

function config(settings, runtime) {
    let output_network_interface = option(settings, "output_network_interface", "");
    let mwan3_active = type(runtime) == "object" && bool_value(runtime.mwan3_active);
    let tproxy_inbounds = [ runtime_constants.TPROXY_INBOUND_TAG ];
    if (core_ip.ipv6_tproxy_enabled())
        push(tproxy_inbounds, runtime_constants.TPROXY_INBOUND6_TAG);
    let sniff_inbounds = [ runtime_constants.TPROXY_INBOUND_TAG, runtime_constants.DNS_INBOUND_TAG ];
    if (core_ip.ipv6_tproxy_enabled())
        push(sniff_inbounds, runtime_constants.TPROXY_INBOUND6_TAG);
    if (type(runtime) == "object" && bool_value(runtime.source_aware_dns))
        push(sniff_inbounds, runtime_constants.SOURCE_DNS_INBOUND_TAG);
    if (type(runtime) == "object" && type(runtime.dns_health_inbounds) == "array")
        for (let inbound in runtime.dns_health_inbounds)
            push(sniff_inbounds, inbound);
    let dns_hijack_inbounds = [ runtime_constants.DNS_INBOUND_TAG ];
    if (type(runtime) == "object" && bool_value(runtime.source_aware_dns))
        push(dns_hijack_inbounds, runtime_constants.SOURCE_DNS_INBOUND_TAG);
    if (type(runtime) == "object" && type(runtime.dns_health_inbounds) == "array")
        for (let inbound in runtime.dns_health_inbounds)
            push(dns_hijack_inbounds, inbound);
    let result = {
        rules: [
            // Dedicated DNS listeners must not depend on protocol sniffing.
            { action: "hijack-dns", inbound: dns_hijack_inbounds },
            { action: "sniff", inbound: sniff_inbounds },
            { action: "hijack-dns", port: 53 },
            { action: "hijack-dns", protocol: "dns" }
        ],
        rule_set: [],
        final: runtime_constants.DIRECT_OUTBOUND_TAG,
        auto_detect_interface: output_network_interface == "" && !mwan3_active,
        default_domain_resolver: type(runtime) == "object" && as_string(runtime.default_domain_resolver) != ""
            ? as_string(runtime.default_domain_resolver)
            : runtime_constants.DNS_SERVER_TAG,
        default_mark: runtime_constants.OUTBOUND_MARK
    };

    if (output_network_interface != "")
        result.default_interface = output_network_interface;
    if (bool_option(settings, "disable_quic", true))
        push(result.rules, { action: "reject", inbound: tproxy_inbounds, protocol: "quic" });

    return result;
}

function target(section, outbound_tag_name) {
    let action = option(section, "action", "");
    if (connections.is_connections_action(action))
        return { action: "route", outbound: outbound_tag_name };
    if (action == "bypass")
        return { action: "route", outbound: runtime_constants.BYPASS_OUTBOUND_TAG };
    if (action == "block")
        return { action: "reject" };
    return { unsupported: "unsupported action " + action };
}

// Place immediately before the matching route, so earlier DIRECT rules and
// section ordering keep their meaning. Never broaden a section's matchers.
function quic_rule(settings, section, route_rule) {
    if (bool_option(settings, "disable_quic", true) ||
        !bool_option(settings, "disable_quic_vpn", false) ||
        !connections.is_connections_action(option(section, "action", "")) ||
        route_rule.action != "route")
        return null;
    let matchers = {};
    for (let key, value in route_rule)
        if (key != "action" && key != "outbound")
            matchers[key] = value;
    return {
        type: "logical", mode: "and", action: "reject",
        rules: [ matchers, { protocol: "quic" } ]
    };
}

function has_resolve_matchers(rule) {
    return rule.domain != null || rule.domain_suffix != null || rule.domain_keyword != null ||
        rule.domain_regex != null || rule.rule_set != null;
}

function resolve_rule_for_section(section, route_rule) {
    let action = option(section, "action", "");
    let should_resolve = connections.is_connections_action(action) &&
        bool_option(section, "resolve_real_ip_for_routing", false);

    if (!should_resolve)
        return null;

    if (!has_resolve_matchers(route_rule)) {
        return {
            warning: "Resolve real IP is enabled for '" + section[".name"] + "', but no domain or rule-set matchers found"
        };
    }

    let resolve_rule = {};
    for (let key in [ "inbound", "source_ip_cidr", "domain", "domain_suffix", "domain_keyword", "domain_regex", "rule_set", "port", "port_range" ]) {
        if (route_rule[key] != null)
            resolve_rule[key] = route_rule[key];
    }
    resolve_rule.action = "resolve";
    resolve_rule.server = runtime_constants.DNS_SERVER_TAG;

    return { rule: resolve_rule };
}

return {
    config,
    target,
    quic_rule,
    has_resolve_matchers,
    resolve_rule_for_section
};
