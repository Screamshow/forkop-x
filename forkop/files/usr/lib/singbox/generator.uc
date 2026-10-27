#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let core_ip = require("core.ip");
let uci_core = require("core.uci");
let runtime_constants = require("singbox.constants");
let cache_identity = require("singbox.cache_identity");
let filter_selection = require("subscription.filter_selection");
// Keep private connection identities out of outboundMetadata/UI caches.
let subscription_filter_connections = {};
let runtime_country = require("singbox.country");
let runtime_dns = require("singbox.dns");
let runtime_route = require("singbox.route");
let runtime_rulesets = require("singbox.rulesets");
let runtime_subscription = require("singbox.subscription");
let runtime_url = require("core.url");
let runtime_urltest = require("singbox.urltest");
let outbound_reachability = require("singbox.outbound_reachability");
let source_rulesets = require("routing.rulesets");
let rule_config = require("config.rule");
let connections = require("config.connections");
// one definition of the host, shared with the default it decides
let flintnet_subscription_source = connections.flintnet_subscription_source;
let urltest_override = require("config.urltest_override");
let subscription_share_link = require("subscription.share_link");
let subscription_parser = require("subscription.parser");
const IPV6_TPROXY_ENABLED = core_ip.ipv6_tproxy_enabled();
let uci = null;
let fixture_uci_data = null;
let runtime_settings_cache = null;
let runtime_ruleset_folder = runtime_constants.TMP_RULESET_FOLDER;
let runtime_supports_xhttp = true;
let runtime_supports_certificate_pins = false;
let runtime_supports_dns_response_matching = false;
let runtime_supports_legacy_protocols = true;
let runtime_supports_trojan = true;
let runtime_supports_all_fingerprints = true;
let runtime_supports_vless_encryption = true;
let runtime_supports_reality_mldsa65 = true;
let runtime_skipped_protocol_outbounds = {};
let runtime_prunable_outbounds = {};

let as_string = common.as_string;
let read_json_file = common.read_json_file;
let read_stdin = common.read_stdin;
let read_stdin_json = common.read_stdin_json;
let write_json = common.write_json;
let csv_to_json_array = common.csv_to_json_array;
let write_json_file = common.write_private_json_file;
let strip_internal_fields = common.strip_internal_fields;
let array_or_empty = common.array_or_empty;
let object_or_empty = common.object_or_empty;
let option = common.option;
let list_option = common.list_option;
let bool_option = common.bool_option;
let int_option = common.int_option;
let url_decode = runtime_url.decode;
let url_scheme = runtime_url.scheme;
let url_fragment = runtime_url.fragment;
let url_strip_fragment_value = runtime_url.strip_fragment;
let url_host = runtime_url.host;
let url_port = runtime_url.port;
let url_userinfo = runtime_url.userinfo;
let url_query_params = runtime_url.query_params;

const CONFIG_NAME = "forkop";

function parent_dir(path) {
    path = as_string(path);
    let slash = rindex(path, "/");
    return slash <= 0 ? "" : substr(path, 0, slash);
}

function ensure_dir(path) {
    path = as_string(path);
    if (path == "" || path == "/")
        return true;
    if (fs.stat(path) != null)
        return true;

    let parent = parent_dir(path);
    if (parent != "" && !ensure_dir(parent))
        return false;

    return fs.mkdir(path, 0755) || fs.stat(path) != null;
}

function ensure_parent_dir(path) {
    return ensure_dir(parent_dir(path));
}

function atomic_write_json_file(path, value) {
    let stamp = clock();
    let tmp_path = sprintf("%s.%d.%d.tmp", path, stamp[0], stamp[1]);

    if (!ensure_parent_dir(path) || !common.secure_private_dir(parent_dir(path)))
        return false;
    if (!write_json_file(tmp_path, value))
        return false;
    if (!fs.rename(tmp_path, path)) {
        fs.unlink(tmp_path);
        return false;
    }
    return true;
}

function fixture_section_list(type_name) {
    let value = object_or_empty(fixture_uci_data)[type_name];
    if (type(value) == "array")
        return value;
    if (type(value) == "object")
        return [ value ];

    let plural = object_or_empty(fixture_uci_data)[type_name + "s"];
    return type(plural) == "array" ? plural : [];
}

function fixture_get_section(section_name) {
    let fixture = object_or_empty(fixture_uci_data);
    if (section_name == "settings" && type(fixture.settings) == "object")
        return fixture.settings;

    for (let type_name in [ "settings", "server", "section", "subscription_url", "section_interface", "urltest", "priority_group", "priority_level" ]) {
        for (let section in fixture_section_list(type_name)) {
            if (as_string(section[".name"]) == section_name)
                return section;
        }
    }

    return {};
}

function fixture_cursor(path) {
    fixture_uci_data = object_or_empty(read_json_file(path));
    connections.set_item_sections_from_data(fixture_uci_data);
    return {
        load: function(_config_name) {
            return true;
        },
        get_all: function(_config_name, section_name) {
            return fixture_get_section(section_name);
        },
        foreach: function(_config_name, type_name, callback) {
            for (let section in fixture_section_list(type_name))
                callback(section);
        }
    };
}

function use_fixture_cursor(path) {
    uci = fixture_cursor(path);
    runtime_settings_cache = null;
}

function runtime_uci_cursor() {
    return {
        load: function(package_name) {
            return uci_core.load(package_name);
        },
        get_all: function(package_name, section_name) {
            return uci_core.get_all(package_name, section_name);
        },
        foreach: function(package_name, type_name, callback) {
            for (let section in uci_core.section_objects(package_name, type_name))
                callback(section);
        }
    };
}

function uci_cursor() {
    if (uci == null)
        uci = runtime_uci_cursor();
    return uci;
}

function runtime_generate_unsupported(reason) {
    warn(reason, "\n");
    exit(2);
}

function valid_section_name(name) {
    return match(name, /^[A-Za-z0-9_]+$/);
}

function section_enabled(section) {
    return bool_option(section, "enabled", true);
}

function runtime_settings() {
    if (runtime_settings_cache == null)
        runtime_settings_cache = object_or_empty(uci_cursor().get_all(CONFIG_NAME, "settings"));
    return runtime_settings_cache;
}

function settings_update_interval() {
    let settings = runtime_settings();
    if (!bool_option(settings, "list_update_enabled", true))
        return "";

    let update_interval = option(settings, "update_interval", "1d");
    return update_interval != "" ? update_interval : "1d";
}

function remote_ruleset_update_interval() {
    let update_interval = settings_update_interval();
    return update_interval != "" ? update_interval : runtime_constants.DISABLED_UPDATE_INTERVAL;
}

function internal_flag(value) {
    return value === true || value == 1 || value == "1" || value == "true" || value == "yes";
}

function subscription_group_outbound(outbound) {
    if (type(outbound) != "object")
        return false;
    let t = as_string(outbound.type);
    return (t == "selector" || t == "urltest") && internal_flag(outbound.__forkop_allow_group);
}

function subscription_urltest_group_outbound(outbound) {
    if (type(outbound) != "object")
        return false;
    return as_string(outbound.type || "") == "urltest" && internal_flag(outbound.__forkop_allow_group);
}

let provider_urltest_start_seed = "";

function urltest_start_seed() {
    if (provider_urltest_start_seed == "")
        provider_urltest_start_seed = trim(as_string(
            getenv("FORKOP_URLTEST_START_SEED") || fs.readfile("/proc/sys/kernel/random/uuid")
        ));
    return provider_urltest_start_seed;
}

function subscription_outbound_tag(outbound) {
    return type(outbound) == "object" ? as_string(outbound.tag || "") : "";
}

function subscription_urltest_group_member(outbound, refs) {
    let tag_name = subscription_outbound_tag(outbound);
    return tag_name != "" && object_or_empty(object_or_empty(refs).urltest)[tag_name] === true;
}

function subscription_visibility_refs(outbounds) {
    let refs = {
        urltest: {},
        detour: {}
    };

    for (let outbound in array_or_empty(outbounds)) {
        if (type(outbound) != "object")
            continue;

        // Provider URLTest groups do not consistently carry Forkop's internal
        // allow-group marker. Any URLTest inbound from a subscription owns its
        // listed members, which must not also become standalone dashboard rows.
        if (as_string(outbound.type || "") == "urltest") {
            for (let tag_name in array_or_empty(outbound.outbounds)) {
                tag_name = as_string(tag_name);
                if (tag_name != "")
                    refs.urltest[tag_name] = true;
            }
        }

        let detour = as_string(outbound.detour || "");
        if (detour != "")
            refs.detour[detour] = true;
    }

    return refs;
}

function subscription_hidden_outbound(outbound, refs, hide_urltest_group_outbounds, hide_detour_outbounds) {
    if (type(outbound) != "object")
        return false;

    let tag_name = subscription_outbound_tag(outbound);
    let urltest_refs = object_or_empty(object_or_empty(refs).urltest);
    let detour_refs = object_or_empty(object_or_empty(refs).detour);
    let hidden_by_urltest = tag_name != "" && urltest_refs[tag_name];
    let hidden_by_detour = tag_name != "" && detour_refs[tag_name];

    if (hidden_by_urltest && hide_urltest_group_outbounds !== false)
        return true;
    if (hidden_by_detour && hide_detour_outbounds !== false)
        return true;
    return internal_flag(outbound.__forkop_hidden) && !hidden_by_urltest && !hidden_by_detour;
}

function tag(base, postfix) {
    return runtime_constants.tag(base, postfix);
}

function outbound_tag(section_name) {
    return runtime_constants.outbound_tag(section_name);
}

function download_via_proxy_section_option_for_purpose(purpose) {
    purpose = as_string(purpose || "lists");
    if (purpose == "lists")
        return "download_lists_via_proxy_section";
    if (purpose == "components")
        return "download_components_via_proxy_section";
    return "";
}

function download_via_proxy_option_for_purpose(purpose) {
    purpose = as_string(purpose || "lists");
    if (purpose == "lists")
        return "download_lists_via_proxy";
    if (purpose == "components")
        return "download_components_via_proxy";
    return "";
}

function download_via_proxy_section(settings, purpose) {
    let enabled_option = download_via_proxy_option_for_purpose(purpose);
    if (enabled_option == "" || !bool_option(settings, enabled_option, false))
        return "";

    let section_option = download_via_proxy_section_option_for_purpose(purpose);
    let configured = section_option != "" ? option(settings, section_option, "") : "";
    if (configured != "")
        return configured;

    return option(settings, "download_lists_via_proxy_section", "");
}

function download_via_proxy_enabled(settings, purpose) {
    let enabled_option = download_via_proxy_option_for_purpose(purpose);
    return enabled_option != "" && bool_option(settings, enabled_option, false);
}

function download_via_proxy_any_enabled(settings, sections) {
    return download_via_proxy_enabled(settings, "lists") ||
        download_via_proxy_enabled(settings, "components") ||
        length(connections.subscription_download_targets(sections || [])) > 0;
}

function download_detour_tag(settings, purpose) {
    let section_name = download_via_proxy_section(settings, purpose);
    return section_name == "" ? "" : outbound_tag(section_name);
}

function ruleset_tag(section_name, name, kind) {
    kind = as_string(kind);
    return kind == ""
        ? section_name + "-" + name + "-ruleset"
        : section_name + "-" + name + "-" + kind + "-ruleset";
}

function ruleset_registered(config, tag_name) {
    for (let rule_set in array_or_empty(config.route && config.route.rule_set)) {
        if (type(rule_set) == "object" && rule_set.tag == tag_name)
            return true;
    }
    return false;
}

function ensure_custom_ruleset(config, reference) {
    let tag_name;
    let kind = runtime_rulesets.kind_from_reference_hint(reference);

    if (runtime_rulesets.is_community(reference)) {
        tag_name = "builtin-" + reference + "-ruleset";
        kind = runtime_rulesets.community_kind(reference);
        if (!ruleset_registered(config, tag_name)) {
            let rule_set = {
                type: "remote",
                tag: tag_name,
                format: "binary",
                url: runtime_rulesets.community_url(reference)
            };
            let detour = download_detour_tag(runtime_settings());
            if (detour != "")
                rule_set.download_detour = detour;
            rule_set.update_interval = remote_ruleset_update_interval();
            push(config.route.rule_set, rule_set);
        }
        return { tag: tag_name, kind };
    }

    tag_name = "inline-custom-" + runtime_rulesets.hash12(reference) + "-ruleset";
    if (kind == "unknown")
        kind = "domains";
    if (ruleset_registered(config, tag_name))
        return { tag: tag_name, kind };

    let extension = runtime_rulesets.file_extension(reference);
    if (substr(reference, 0, 1) == "/") {
        if (extension != "srs" && extension != "json")
            runtime_generate_unsupported("local rule_set extension is not supported by sing-box config generation");
        push(config.route.rule_set, {
            type: "local",
            tag: tag_name,
            format: extension == "json" ? "source" : "binary",
            path: reference
        });
    }
    else if (substr(reference, 0, 7) == "http://" || substr(reference, 0, 8) == "https://") {
        let rule_set = {
            type: "remote",
            tag: tag_name,
            format: runtime_rulesets.remote_format(reference),
            url: reference
        };
        let detour = download_detour_tag(runtime_settings());
        if (detour != "")
            rule_set.download_detour = detour;
        rule_set.update_interval = remote_ruleset_update_interval();
        push(config.route.rule_set, rule_set);
    }
    else {
        runtime_generate_unsupported("rule_set reference is not supported by sing-box config generation");
    }

    return { tag: tag_name, kind };
}

function clash_api_config(settings, service_address) {
    let controller = as_string(service_address || "");
    if (bool_option(settings, "enable_yacd", false) && bool_option(settings, "enable_yacd_wan_access", false))
        controller = "0.0.0.0";
    else if (controller == "")
        controller = "127.0.0.1";

    let result = {
        external_controller: controller + ":9090"
    };
    if (bool_option(settings, "enable_yacd", false)) {
        result.external_ui = "ui";
        let secret = common.clash_api_secret(settings);
        if (secret != "")
            result.secret = secret;
    }
    return result;
}

function cli_bool(value) {
    return value === true || value == "1" || value == "true" || value == "yes" || value == "on";
}

function tproxy_inbound_matcher() {
    return IPV6_TPROXY_ENABLED
        ? [ runtime_constants.TPROXY_INBOUND_TAG, runtime_constants.TPROXY_INBOUND6_TAG ]
        : [ runtime_constants.TPROXY_INBOUND_TAG ];
}

function source_dns_inbound_matcher() {
    return [ runtime_constants.SOURCE_DNS_INBOUND_TAG ];
}

// The names sysntpd dials, from /etc/config/system. A router without a clock of
// its own boots months in the past, and DNS over TLS or HTTPS then refuses the
// server's certificate as not yet valid: the names get no address, sysntpd never
// sets the clock, and the next boot repeats it. Addresses need no lookup, and
// nothing is collected while sysntpd is off.
function ntp_server_names() {
    let ntp = object_or_empty(uci_core.get_all("system", "ntp"));
    if (!bool_option(ntp, "enabled", true))
        return [];

    let names = [];
    let seen = {};
    for (let value in list_option(ntp, "server")) {
        value = trim(as_string(value));
        if (value == "" || seen[value] || core_ip.valid_ip(value))
            continue;
        seen[value] = true;
        push(names, value);
    }
    return names;
}

function base_config(settings, service_address, runtime_context) {
    let log_level = option(settings, "log_level", "warn");
    let rewrite_ttl = int_option(settings, "dns_rewrite_ttl", "60");
    let cache_path = cache_identity.path(option(settings, "cache_path", "/tmp/sing-box/cache.db"), object_or_empty(runtime_context).core_version);
    let dns_config = runtime_dns.config(settings);
    if (dns_config.unsupported)
        runtime_generate_unsupported(dns_config.unsupported);

    let dns_rules = [];
    for (let rule in dns_config.rules)
        push(dns_rules, rule);
    for (let rule in [
        { action: "predefined", query_type: "HTTPS", rcode: "NOERROR" },
        { action: "reject", domain_suffix: "use-application-dns.net" },
        {
            action: "route",
            server: runtime_constants.FAKEIP_DNS_SERVER_TAG,
            query_type: [ "A", "AAAA" ],
            rewrite_ttl,
            domain: [ runtime_constants.FAKEIP_TEST_DOMAIN, runtime_constants.CHECK_PROXY_IP_DOMAIN ]
        }
    ])
        push(dns_rules, rule);

    // The router's own lookups share dns-in with the clients dnsmasq forwards,
    // so the rule cannot be narrowed to one listener. It stands ahead of the
    // sections, so a FakeIP address cannot reach sysntpd either; the bootstrap
    // servers are plain and answer with a clock months behind.
    let ntp_servers = ntp_server_names();
    if (length(ntp_servers) > 0)
        push(dns_rules, {
            action: "route",
            server: runtime_constants.BOOTSTRAP_DNS_SERVER_TAG,
            domain: ntp_servers
        });

    let dns_servers = [];
    for (let server in dns_config.servers)
        push(dns_servers, server);
    push(dns_servers, {
        type: "fakeip",
        tag: runtime_constants.FAKEIP_DNS_SERVER_TAG,
        inet4_range: runtime_constants.FAKEIP_INET4_RANGE,
        inet6_range: runtime_constants.FAKEIP_INET6_RANGE
    });

    runtime_context = object_or_empty(runtime_context);
    let inbounds = [
        { type: "tproxy", tag: runtime_constants.TPROXY_INBOUND_TAG, listen: runtime_constants.TPROXY_INBOUND_ADDRESS, listen_port: runtime_constants.TPROXY_INBOUND_PORT, tcp_fast_open: true, udp_fragment: true }
    ];
    if (IPV6_TPROXY_ENABLED)
        push(inbounds, { type: "tproxy", tag: runtime_constants.TPROXY_INBOUND6_TAG, listen: runtime_constants.TPROXY_INBOUND6_ADDRESS, listen_port: runtime_constants.TPROXY_INBOUND_PORT, tcp_fast_open: true, udp_fragment: true });
    push(inbounds, { type: "direct", tag: runtime_constants.DNS_INBOUND_TAG, listen: runtime_constants.DNS_INBOUND_ADDRESS, listen_port: runtime_constants.DNS_INBOUND_PORT });
    if (runtime_context.source_aware_dns)
        push(inbounds, { type: "direct", tag: runtime_constants.SOURCE_DNS_INBOUND_TAG, listen: runtime_constants.SOURCE_DNS_INBOUND_ADDRESS, listen_port: runtime_constants.SOURCE_DNS_INBOUND_PORT });
    for (let inbound in dns_config.inbounds)
        push(inbounds, inbound);

    runtime_context.dns_health_inbounds = dns_config.sniff_inbounds;
    runtime_context.default_domain_resolver = runtime_dns.default_domain_resolver(settings);

    return {
        log: {
            disabled: false,
            level: log_level,
            timestamp: false
        },
        dns: {
            servers: dns_servers,
            rules: dns_rules,
            final: runtime_constants.DNS_SERVER_TAG,
            strategy: option(settings, "dns_strategy", "prefer_ipv4"),
            independent_cache: true
        },
        ntp: {},
        certificate: {},
        endpoints: [],
        inbounds,
        outbounds: [
            { type: "direct", tag: runtime_constants.DIRECT_OUTBOUND_TAG },
            { type: "direct", tag: runtime_constants.BYPASS_OUTBOUND_TAG }
        ],
        route: runtime_route.config(settings, runtime_context),
        services: [],
        experimental: {
            cache_file: {
                enabled: true,
                path: cache_path,
                store_fakeip: true
            },
            clash_api: clash_api_config(settings, service_address)
        }
    };
}

function supported_subscription_outbound(outbound) {
    if (type(outbound) != "object")
        return false;
    let t = as_string(outbound.type);
    if (subscription_group_outbound(outbound))
        return true;
    if (t == "direct" || t == "selector" || t == "urltest" || t == "dns" || t == "block")
        return false;
    return t == "vless" || t == "vmess" || t == "trojan" || t == "shadowsocks" ||
        t == "socks" || t == "hysteria2";
}

function outbound_uses_xhttp(outbound) {
    return type(outbound) == "object" && type(outbound.transport) == "object" &&
        lc(as_string(outbound.transport.type || "")) == "xhttp";
}

function outbound_uses_certificate_pins(outbound) {
    let tls = object_or_empty(object_or_empty(outbound).tls);
    let value = tls.certificate_sha256;
    return type(value) == "array" ? length(value) > 0 : as_string(value) != "";
}

// Mirrors the outbound types rejected by the Xrust profile without the
// legacy-protocols build feature (xrust core-config validate()). Newer Xrust
// builds declare their Trojan client with the outbound.trojan feature.
const RUST_X_EXCLUDED_OUTBOUND_TYPES = {
    naive: true, vmess: true, trojan: true, shadowsocks: true, tuic: true,
    anytls: true, snell: true, shadowtls: true, fptn: true, openvpn: true,
    "openvpn-client": true, socks: true
};

function rust_x_core_version(version) {
    // Both the packaged wrapper and the bare binary report "-rust-x.".
    return match(as_string(version), /-rust-x\./) != null;
}

function outbound_excluded_protocol(outbound) {
    if (runtime_supports_legacy_protocols || type(outbound) != "object")
        return "";
    let t = lc(as_string(outbound.type || ""));
    if (t == "trojan" && runtime_supports_trojan)
        return "";
    return RUST_X_EXCLUDED_OUTBOUND_TYPES[t] ? t : "";
}

// Xrust has no VLESS encryption layer and refuses any encryption other than
// "none" at check time; such a node would otherwise run as plain VLESS.
function outbound_unsupported_vless_encryption(outbound) {
    if (runtime_supports_vless_encryption || type(outbound) != "object" ||
        lc(as_string(outbound.type || "")) != "vless")
        return "";
    let encryption = as_string(outbound.encryption || "");
    if (encryption == "" || encryption == "none")
        return "";
    return split(encryption, ".")[0];
}

// REALITY ML-DSA-65 verification (pqv) is a Forkop-side marker: Xrust has no
// ML-DSA verification, so such nodes are refused there; for the other cores
// the marker is removed and their configuration is unchanged.
function outbound_uses_reality_mldsa65(outbound) {
    return type(outbound) == "object" && type(outbound.tls) == "object" &&
        type(outbound.tls.reality) == "object" &&
        as_string(outbound.tls.reality.__forkop_mldsa65_verify || "") != "";
}

function without_reality_mldsa65_marker(outbound) {
    if (type(outbound) != "object" || type(outbound.tls) != "object" ||
        type(outbound.tls.reality) != "object" || !exists(outbound.tls.reality, "__forkop_mldsa65_verify"))
        return outbound;
    let reality = {};
    for (let key, value in outbound.tls.reality)
        if (key != "__forkop_mldsa65_verify")
            reality[key] = value;
    let tls = {};
    for (let key, value in outbound.tls)
        tls[key] = value;
    tls.reality = reality;
    let copy = {};
    for (let key, value in outbound)
        copy[key] = value;
    copy.tls = tls;
    return copy;
}

function remember_skipped_protocol_outbound(section_name, protocol) {
    section_name = as_string(section_name);
    let counts = runtime_skipped_protocol_outbounds[section_name] || {};
    counts[protocol] = (counts[protocol] || 0) + 1;
    runtime_skipped_protocol_outbounds[section_name] = counts;
}

function skipped_protocol_summary(section_name) {
    let counts = runtime_skipped_protocol_outbounds[as_string(section_name)];
    if (type(counts) != "object")
        return "";
    let parts = [];
    for (let protocol in sort(keys(counts)))
        push(parts, protocol + " (" + counts[protocol] + ")");
    return join(", ", parts);
}

// Xrust refuses these uTLS profiles: it had android and 360 only as TLS 1.2
// ClientHellos while its client speaks TLS 1.3 only, and qq went with them.
// A node that names one is rejected by its check, so put firefox in its
// place: of the profiles Xrust keeps, firefox is the one verified byte for
// byte against the reference, and its own `random` resolves to it too.
const XRUST_UNSUPPORTED_FINGERPRINTS = { android: true, "360": true, qq: true };
const XRUST_FINGERPRINT_REPLACEMENT = "firefox";

function use_supported_utls_fingerprint(outbound, source, name) {
    if (runtime_supports_all_fingerprints || type(outbound) != "object" ||
        type(outbound.tls) != "object" || type(outbound.tls.utls) != "object" ||
        outbound.tls.utls.enabled === false)
        return;
    let fingerprint = lc(as_string(outbound.tls.utls.fingerprint || ""));
    if (!XRUST_UNSUPPORTED_FINGERPRINTS[fingerprint])
        return;
    // Replace the nested objects: subscription copies share them with the cache.
    let tls = {};
    for (let key, value in outbound.tls)
        tls[key] = value;
    let utls = {};
    for (let key, value in outbound.tls.utls)
        utls[key] = value;
    utls.fingerprint = XRUST_FINGERPRINT_REPLACEMENT;
    tls.utls = utls;
    outbound.tls = tls;
    warn(as_string(source), " '", as_string(name), "' uses uTLS fingerprint ", fingerprint,
        ", which Xrust does not support; using ", XRUST_FINGERPRINT_REPLACEMENT, "\n");
}

function ensure_explicit_outbound_supported(outbound, source, name) {
    use_supported_utls_fingerprint(outbound, source, name);
    let excluded = outbound_excluded_protocol(outbound);
    if (excluded != "")
        runtime_generate_unsupported(as_string(source) + " '" + as_string(name) + "' uses protocol " + excluded + ", which is not included in Xrust; remove it or use a " + (runtime_supports_trojan ? "VLESS, Trojan" : "VLESS") + " or Hysteria2 connection");
    let encryption = outbound_unsupported_vless_encryption(outbound);
    if (encryption != "")
        runtime_generate_unsupported(as_string(source) + " '" + as_string(name) + "' uses VLESS encryption " + encryption + ", which Xrust does not support; use a link with encryption=none");
    if (!runtime_supports_reality_mldsa65 && outbound_uses_reality_mldsa65(outbound))
        runtime_generate_unsupported(as_string(source) + " '" + as_string(name) + "' requires REALITY ML-DSA-65 verification (pqv), which Xrust does not support; remove pqv only if you accept the server without it");
    if (!runtime_supports_certificate_pins && outbound_uses_certificate_pins(outbound))
        runtime_generate_unsupported(as_string(source) + " '" + as_string(name) + "' requires TLS certificate SHA-256 pinning; use Xrust or a core with verified certificate_sha256 support");
    if (!runtime_supports_xhttp && outbound_uses_xhttp(outbound))
        runtime_generate_unsupported(as_string(source) + " '" + as_string(name) + "' uses XHTTP transport, but installed sing-box does not advertise XHTTP support");
}

function subscription_outbound_display_name(outbound) {
    return type(outbound) == "object"
        ? as_string(outbound.remark || outbound.tag || "unknown")
        : "unknown";
}

function add_subscription_reference(refs, value) {
    value = as_string(value);
    if (value != "")
        refs[value] = true;
}

function subscription_reference_set(outbounds) {
    let refs = {};
    for (let outbound in array_or_empty(outbounds)) {
        if (type(outbound) != "object")
            continue;
        add_subscription_reference(refs, outbound.tag);
        add_subscription_reference(refs, outbound.remark);
    }
    return refs;
}

function subscription_reference_available(reference, source_refs, retained_refs) {
    reference = as_string(reference);
    return reference == "" || !source_refs[reference] || retained_refs[reference];
}

function subscription_group_has_retained_member(outbound, retained_refs) {
    for (let reference in array_or_empty(outbound.outbounds))
        if (retained_refs[as_string(reference)])
            return true;
    return false;
}

function warn_skipped_subscription_outbound(section_name, outbound, reason) {
    warn("skipped incompatible subscription outbound for rule '", section_name, "': ",
        subscription_outbound_display_name(outbound), " (", reason, ")\n");
}

function compatible_subscription_outbounds(outbounds, section_name) {
    let source_refs = subscription_reference_set(outbounds);
    let retained = [];
    for (let outbound in array_or_empty(outbounds)) {
        if (!supported_subscription_outbound(outbound))
            continue;
        let excluded = outbound_excluded_protocol(outbound);
        if (excluded != "") {
            warn_skipped_subscription_outbound(section_name, outbound, "protocol " + excluded + " is not included in Xrust");
            remember_skipped_protocol_outbound(section_name, excluded);
            continue;
        }
        let encryption = outbound_unsupported_vless_encryption(outbound);
        if (encryption != "") {
            warn_skipped_subscription_outbound(section_name, outbound, "VLESS encryption " + encryption + " is not supported by Xrust");
            remember_skipped_protocol_outbound(section_name, "vless encryption");
            continue;
        }
        if (!runtime_supports_reality_mldsa65 && outbound_uses_reality_mldsa65(outbound)) {
            warn_skipped_subscription_outbound(section_name, outbound, "REALITY ML-DSA-65 verification (pqv) is not supported by Xrust");
            remember_skipped_protocol_outbound(section_name, "reality pqv");
            continue;
        }
        if (!runtime_supports_certificate_pins && outbound_uses_certificate_pins(outbound)) {
            warn_skipped_subscription_outbound(section_name, outbound, "TLS certificate SHA-256 pinning requires Xrust; pin retained in subscription cache");
            continue;
        }
        if (!runtime_supports_xhttp && outbound_uses_xhttp(outbound)) {
            warn_skipped_subscription_outbound(section_name, outbound, "installed sing-box does not advertise XHTTP support");
            continue;
        }
        push(retained, outbound);
    }

    while (true) {
        let retained_refs = subscription_reference_set(retained);
        let next = [];
        let changed = false;
        for (let outbound in retained) {
            let detour = as_string(outbound.detour || "");
            if (!subscription_reference_available(detour, source_refs, retained_refs)) {
                warn_skipped_subscription_outbound(section_name, outbound,
                    "detour depends on unavailable outbound '" + detour + "'");
                changed = true;
                continue;
            }
            if (subscription_group_outbound(outbound) &&
                !subscription_group_has_retained_member(outbound, retained_refs)) {
                warn_skipped_subscription_outbound(section_name, outbound, "group has no compatible outbounds");
                changed = true;
                continue;
            }
            push(next, outbound);
        }
        retained = next;
        if (!changed)
            return retained;
    }
}

function subscription_exclude_regex_outbounds(outbounds, regexes) {
    regexes = array_or_empty(regexes);
    if (length(regexes) == 0)
        return array_or_empty(outbounds);

    let tags = [];
    let names = {};
    for (let outbound in array_or_empty(outbounds)) {
        if (type(outbound) != "object")
            continue;
        let tag_name = as_string(outbound.tag || "");
        if (tag_name == "")
            continue;
        push(tags, tag_name);
        names[tag_name] = subscription_outbound_display_name(outbound);
    }

    let excluded = {};
    for (let tag_name in tags) {
        for (let pattern in regexes) {
            try {
                if (match(names[tag_name], regexp(as_string(pattern))) != null) {
                    excluded[tag_name] = true;
                    break;
                }
            }
            catch (e) {
            }
        }
    }
    if (length(keys(excluded)) == 0)
        return array_or_empty(outbounds);

    let result = [];
    for (let outbound in array_or_empty(outbounds)) {
        let tag_name = type(outbound) == "object" ? as_string(outbound.tag || "") : "";
        if (!excluded[tag_name])
            push(result, outbound);
    }
    return result;
}

function global_subscription_exclude_regex() {
    return list_option(runtime_settings(), "subscription_exclude_regex", []);
}

function effective_subscription_exclude_regex(section, source_entry) {
    let result = [];
    let seen = {};
    for (let pattern in global_subscription_exclude_regex()) {
        pattern = as_string(pattern);
        if (pattern != "" && !seen[pattern]) {
            seen[pattern] = true;
            push(result, pattern);
        }
    }
    // Keep legacy per-source rules effective for configurations created before
    // the global setting was introduced. New policy belongs in settings.
    for (let pattern in connections.subscription_exclude_regex(section, source_entry)) {
        pattern = as_string(pattern);
        if (pattern != "" && !seen[pattern]) {
            seen[pattern] = true;
            push(result, pattern);
        }
    }
    return result;
}

function copy_subscription_outbound(outbound, new_tag) {
    let copy = {};
    for (let key, value in outbound) {
        if (key != "tag" && key != "remark" && key != "share_link" &&
            key != "__forkop_hidden" && key != "__forkop_allow_group" &&
            key != "__forkop_description" && key != "__forkop_filter_names")
            copy[key] = value;
    }
    if (as_string(copy.type || "") == "hysteria2" &&
        type(copy.tls) == "object" &&
        copy.tls.utls != null) {
        let tls = {};
        for (let key, value in copy.tls) {
            if (key != "utls")
                tls[key] = value;
        }
        copy.tls = tls;
    }
    copy.tag = new_tag;
    return without_reality_mldsa65_marker(copy);
}

function string_array_contains(values, needle) {
    for (let value in array_or_empty(values))
        if (as_string(value) == as_string(needle))
            return true;
    return false;
}

function rewrite_subscription_outbound_references(outbounds, tag_map, source_refs) {
    for (let outbound in outbounds) {
        if (type(outbound) != "object")
            continue;

        let detour = as_string(outbound.detour || "");
        if (detour != "" && tag_map[detour])
            outbound.detour = tag_map[detour];
        else if (detour != "" && source_refs[detour])
            delete outbound.detour;

        if (type(outbound.outbounds) == "array") {
            let rewritten = [];
            for (let tag_name in outbound.outbounds) {
                tag_name = as_string(tag_name);
                if (tag_map[tag_name])
                    push(rewritten, tag_map[tag_name]);
            }
            outbound.outbounds = rewritten;

            if (as_string(outbound.type || "") == "urltest") {
                delete outbound.default;
            }
            else {
                let default_tag = as_string(outbound.default || "");
                if (default_tag != "" && tag_map[default_tag])
                    default_tag = tag_map[default_tag];
                if (default_tag == "" || !string_array_contains(rewritten, default_tag))
                    default_tag = length(rewritten) > 0 ? rewritten[0] : "";
                if (default_tag != "")
                    outbound.default = default_tag;
                else
                    delete outbound.default;
            }
        }
    }
}

function subscription_skip_summary(skipped) {
    let parts = [];
    for (let t in sort(keys(skipped)))
        push(parts, skipped[t] + "x " + t);
    return join("; ", parts);
}

function reportable_skipped_subscription_type(t) {
    return t != "direct" && t != "selector" && t != "urltest" && t != "dns" && t != "block";
}

function urltest_leaf_candidate_outbound(outbound) {
    if (type(outbound) != "object")
        return false;

    let t = lc(as_string(outbound.type || ""));
    return t != "selector" && t != "urltest" && t != "dns" && t != "block";
}

function unique_tag(base, taken) {
    base = as_string(base);
    if (base == "")
        base = "server";
    if (!taken[base])
        return base;
    for (let i = 1; i < 100000; i++) {
        let candidate = base + "-" + i;
        if (!taken[candidate])
            return candidate;
    }
    return base + "-overflow";
}

function reserved_runtime_tag_set(outbounds) {
    let result = {};
    for (let tag_name in keys(object_or_empty(runtime_constants.RESERVED_TAGS)))
        result[tag_name] = true;

    for (let outbound in array_or_empty(outbounds)) {
        if (type(outbound) != "object")
            continue;

        let tag_name = as_string(outbound.tag || "");
        if (tag_name != "")
            result[tag_name] = true;
    }
    return result;
}

function assert_unique_outbound_tags(config) {
    let seen = {};
    for (let outbound in array_or_empty(config.outbounds)) {
        if (type(outbound) != "object")
            runtime_generate_unsupported("generated sing-box outbound is not an object");

        let tag_name = as_string(outbound.tag || "");
        if (tag_name == "")
            runtime_generate_unsupported("generated sing-box outbound has an empty tag");
        if (seen[tag_name])
            runtime_generate_unsupported("generated sing-box config has duplicate outbound tag '" + tag_name + "'");
        seen[tag_name] = true;
    }
}

function add_subscription_source_with_state(config, section, source_index, source_entry, taken, selector_tags, urltest_candidate_tags, state, show_metadata, include_urltest_groups, hide_urltest_group_outbounds, hide_detour_outbounds, node_prefix) {
    let section_name = section[".name"];
    let source_section = runtime_subscription.source_id(section_name, source_index);
    if (!runtime_subscription.source_cache_is_current(
        source_section,
        source_entry,
        connections.subscription_user_agent(section, source_entry),
        connections.subscription_hwid(section, source_entry)
    ))
        return 0;

    let source_outbounds = runtime_subscription.read_source_outbounds(source_section);
    source_outbounds = subscription_exclude_regex_outbounds(
        source_outbounds,
        effective_subscription_exclude_regex(section, source_entry)
    );
    if (length(source_outbounds) == 0)
        return 0;

    let skipped = {};
    for (let outbound in source_outbounds) {
        if (supported_subscription_outbound(outbound))
            continue;
        let t = type(outbound) == "object" ? as_string(outbound.type || "missing-type") : "non-object";
        if (reportable_skipped_subscription_type(t))
            skipped[t] = (skipped[t] || 0) + 1;
    }
    let outbounds = compatible_subscription_outbounds(source_outbounds, section_name);

    if (show_metadata !== false)
        runtime_subscription.merge_source_metadata(state, section_name, source_section, source_index, source_entry);
    let visibility_refs = subscription_visibility_refs(outbounds);
    if (include_urltest_groups === false)
        hide_urltest_group_outbounds = false;
    let exclude_flintnet_urltest_members =
        include_urltest_groups === false && flintnet_subscription_source(source_entry);
    node_prefix = trim(as_string(node_prefix));
    let prepared = [];
    let display_names = [];
    let source_links = [];
    let group_flags = [];
    let hidden_flags = [];
    let outbound_descriptions = [];
    let outbound_filter_names = [];
    let tag_map = {};
    for (let i = 0; i < length(outbounds); i++) {
        let outbound = outbounds[i];
        if (include_urltest_groups === false && subscription_urltest_group_outbound(outbound))
            continue;
        if (exclude_flintnet_urltest_members && subscription_urltest_group_member(outbound, visibility_refs))
            continue;
        let display_name = as_string(outbound.remark || outbound.tag || ("server-" + (i + 1)));
        let base = as_string(outbound.tag || outbound.remark || ("server-" + (i + 1)));
        if (node_prefix != "") {
            display_name = node_prefix + " " + display_name;
            base = display_name;
        }
        let new_tag = unique_tag(base, taken);
        subscription_filter_connections[new_tag] = filter_selection.connection(source_entry, outbound);
        taken[new_tag] = true;
        tag_map[base] = new_tag;
        if (as_string(outbound.tag || "") != "")
            tag_map[as_string(outbound.tag)] = new_tag;
        if (as_string(outbound.remark || "") != "")
            tag_map[as_string(outbound.remark)] = new_tag;
        let prepared_outbound = copy_subscription_outbound(outbound, new_tag);
        use_supported_utls_fingerprint(prepared_outbound, "subscription outbound for rule '" + section_name + "'", display_name);
        push(prepared, prepared_outbound);
        push(display_names, display_name);
        let source_link = as_string(outbound.share_link || "");
        if (!subscription_share_link.is_copyable_link(source_link))
            source_link = subscription_share_link.serialize_outbound_link(outbound);
        push(source_links, source_link);
        push(group_flags, subscription_group_outbound(outbound));
        push(hidden_flags, subscription_hidden_outbound(outbound, visibility_refs, hide_urltest_group_outbounds, hide_detour_outbounds));
        push(outbound_descriptions, as_string(outbound.__forkop_description || ""));
        push(outbound_filter_names, map(array_or_empty(outbound.__forkop_filter_names),
            name => node_prefix != "" ? node_prefix + " " + name : name));
    }

    if (length(keys(skipped)) > 0)
        warn("skipped unsupported subscription outbounds for rule '", section_name, "': ", subscription_skip_summary(skipped), "\n");

    rewrite_subscription_outbound_references(prepared, tag_map, subscription_reference_set(source_outbounds));
    for (let i = 0; i < length(prepared); i++) {
        let outbound = prepared[i];
        if (group_flags[i] === true && as_string(outbound.type || "") == "urltest")
            outbound.outbounds = runtime_urltest.rotate_start(outbound.outbounds, urltest_start_seed(), outbound.tag);
        if (as_string(outbound.type || "") == "urltest")
            urltest_override.apply(outbound, section_name, as_string(outbound.tag || ""));
    }
    let added = 0;
    for (let i = 0; i < length(prepared); i++) {
        let outbound = prepared[i];
        let is_group = group_flags[i] === true;
        if (is_group && length(array_or_empty(outbound.outbounds)) == 0) {
            warn("skipped empty subscription group for rule '", section_name, "': ", as_string(display_names[i] || outbound.tag || "unknown"), "\n");
            continue;
        }

        push(config.outbounds, outbound);
        added++;
        if (!is_group)
            push(urltest_candidate_tags, outbound.tag);
        runtime_subscription.remember_source_outbound(
            state,
            outbound.tag,
            display_names[i],
            outbound,
            source_links[i],
            outbound_descriptions[i]
        );
        state.outboundMetadata.filterNames[outbound.tag] = outbound_filter_names[i];
        if (hidden_flags[i] !== true) {
            push(selector_tags, outbound.tag);
            runtime_subscription.remember_urltest_group(state, outbound.tag, display_names[i], outbound);
        }
    }
    return added;
}

function duration_to_seconds(value) {
    value = as_string(value);
    if (value == "")
        return null;
    if (match(value, /^[0-9]+$/) != null)
        return int(value, 10);

    let suffix = substr(value, length(value) - 1);
    let number = substr(value, 0, length(value) - 1);
    if (match(number, /^[0-9]+$/) == null)
        return null;

    let multiplier = null;
    if (suffix == "s")
        multiplier = 1;
    else if (suffix == "m")
        multiplier = 60;
    else if (suffix == "h")
        multiplier = 3600;
    else if (suffix == "d")
        multiplier = 86400;

    return multiplier == null ? null : int(number, 10) * multiplier;
}

function urltest_check_interval(section, urltest_id) {
    let interval = connections.urltest_check_interval(section, urltest_id);
    return interval != "" ? interval : "3m";
}

function legacy_urltest_idle_timeout(section, urltest_id) {
    if (urltest_id != "urltest")
        return "";

    let settings = connections.urltest_settings(section, urltest_id);
    if (type(settings) == "object" && as_string(settings[".type"] || "") == "urltest")
        return "";

    let interval = urltest_check_interval(section, urltest_id);
    let interval_seconds = duration_to_seconds(interval);
    let default_idle_seconds = duration_to_seconds(runtime_constants.URLTEST_DEFAULT_IDLE_TIMEOUT);
    return interval_seconds != null && interval_seconds > default_idle_seconds ? interval : "";
}

function urltest_idle_timeout(section, urltest_id) {
    let configured = connections.urltest_idle_timeout(section, urltest_id);
    return configured != "" ? configured : legacy_urltest_idle_timeout(section, urltest_id);
}

function supported_urltest_filter_mode(mode) {
    return mode == "include" || mode == "exclude" || mode == "mixed";
}

function filter_mode_uses_include(mode) {
    return mode == "include" || mode == "mixed";
}

function filter_mode_uses_exclude(mode) {
    return mode == "exclude" || mode == "mixed";
}

function configured_country_filter(mode, include_countries, exclude_countries) {
    return (filter_mode_uses_include(mode) && length(array_or_empty(include_countries)) > 0) ||
        (filter_mode_uses_exclude(mode) && length(array_or_empty(exclude_countries)) > 0);
}

function section_needs_country_is(section) {
    for (let urltest_id in connections.urltests(section)) {
        let mode = connections.urltest_filter_mode(section, urltest_id);
        if (connections.urltest_detect_server_country(section, urltest_id) == "country_is" &&
            configured_country_filter(
                mode,
                connections.urltest_include_countries(section, urltest_id),
                connections.urltest_exclude_countries(section, urltest_id)
            ))
            return true;
    }

    for (let group_id in connections.priority_groups(section)) {
        for (let level_id in connections.priority_levels(group_id)) {
            if (connections.priority_level_direct(group_id, level_id))
                continue;
            let mode = connections.priority_level_filter_mode(group_id, level_id);
            if (connections.priority_level_detect_server_country(group_id, level_id) == "country_is" &&
                configured_country_filter(
                    mode,
                    connections.priority_level_include_countries(group_id, level_id),
                    connections.priority_level_exclude_countries(group_id, level_id)
                ))
                return true;
        }
    }
    return false;
}

function section_has_direct_priority_level(section) {
    for (let group_id in connections.priority_groups(section))
        for (let level_id in connections.priority_levels(group_id))
            if (connections.priority_level_direct(group_id, level_id))
                return true;
    return false;
}

function urltest_country_metadata(section, urltest_id, state) {
    let metadata = object_or_empty(object_or_empty(state.outboundMetadata).countries);
    let detect_method = connections.urltest_detect_server_country(section, urltest_id);
    if (detect_method == "flag_emoji")
        return runtime_urltest.countries_from_flag_names(object_or_empty(object_or_empty(state.outboundMetadata).names));
    return metadata;
}

function array_contains(values, needle) {
    for (let value in array_or_empty(values)) {
        if (value == needle)
            return true;
    }
    return false;
}

function unique_string_array(values) {
    let result = [];
    let seen = {};
    for (let value in array_or_empty(values)) {
        value = as_string(value);
        if (value == "" || seen[value])
            continue;
        seen[value] = true;
        push(result, value);
    }
    return result;
}

function object_keys_set(values) {
    let result = {};
    for (let value in array_or_empty(values))
        result[value] = true;
    return result;
}

function tag_display_name(tag, names) {
    let name = as_string(object_or_empty(names)[tag] || "");
    return name != "" ? name : tag;
}

function regex_match_set(tags, names, regexes) {
    return object_keys_set(runtime_urltest.regex_matching_tag_array(tags, names, regexes));
}

function tag_name_filter_matches(tag, names, name_filter, regex_set, metadata, current_names) {
    let name = tag_display_name(tag, names);
    if (regex_set[tag])
        return true;
    let bindings = object_or_empty(object_or_empty(metadata).selectionBindings);
    for (let selected in array_or_empty(name_filter)) {
        if (type(bindings[selected]) == "array") {
            if (array_contains(bindings[selected], subscription_filter_connections[tag]))
                return true;
        }
        else if (selected == name)
            return true;
    }
    for (let previous_name in array_or_empty(object_or_empty(object_or_empty(metadata).filterNames)[tag]))
        if (bindings[previous_name] == null && !current_names[previous_name] && array_contains(name_filter, previous_name))
            return true;
    return false;
}

function tag_country_filter_matches(tag, countries, country_filter) {
    let country = uc(as_string(object_or_empty(countries)[tag] || ""));
    return country != "" && array_contains(country_filter, country);
}

function tag_attribute_filter_matches(tag, metadata, selected_values) {
    selected_values = array_or_empty(selected_values);
    if (length(selected_values) == 0)
        return true;

    let value = lc(as_string(object_or_empty(metadata)[tag] || ""));
    if (value == "")
        return false;
    for (let selected in selected_values)
        if (lc(as_string(selected)) == value)
            return true;
    return false;
}

function proxy_parameter_filter_matches_all(tag, metadata, protocols, transports, securities) {
    metadata = object_or_empty(metadata);
    return tag_attribute_filter_matches(tag, metadata.protocols, protocols) &&
        tag_attribute_filter_matches(tag, metadata.transports, transports) &&
        tag_attribute_filter_matches(tag, metadata.securities, securities);
}

function proxy_parameter_filter_matches_any(tag, metadata, protocols, transports, securities) {
    metadata = object_or_empty(metadata);
    return (length(array_or_empty(protocols)) > 0 &&
            tag_attribute_filter_matches(tag, metadata.protocols, protocols)) ||
        (length(array_or_empty(transports)) > 0 &&
            tag_attribute_filter_matches(tag, metadata.transports, transports)) ||
        (length(array_or_empty(securities)) > 0 &&
            tag_attribute_filter_matches(tag, metadata.securities, securities));
}

function name_or_country_filter_configured(name_filter, regexes, country_filter) {
    return length(array_or_empty(name_filter)) > 0 ||
        length(array_or_empty(regexes)) > 0 ||
        length(array_or_empty(country_filter)) > 0;
}

function urltest_all_candidate_outbounds(urltest_candidate_tags) {
    return unique_string_array(urltest_candidate_tags);
}

function deduplicate_alias_outbounds(outbounds, metadata) {
    let aliases = object_or_empty(object_or_empty(metadata).aliases);
    let seen = {};
    let result = [];
    for (let tag in array_or_empty(outbounds)) {
        let identity = as_string(aliases[tag] || tag);
        if (seen[identity])
            continue;
        seen[identity] = true;
        push(result, tag);
    }
    return result;
}

function urltest_matching_candidate_outbounds(urltest_candidate_tags, names, countries, name_filter, regexes, country_filter,
    metadata, proxy_parameters_enabled, proxy_parameters_operator, protocols, transports, securities, additional_matches) {
    names = object_or_empty(names);
    countries = object_or_empty(countries);
    country_filter = runtime_urltest.normalized_country_list(country_filter);

    let regex_set = regex_match_set(urltest_candidate_tags, names, regexes);
    let base_filter_configured = name_or_country_filter_configured(name_filter, regexes, country_filter);
    let additional_set = object_keys_set(additional_matches);
    // A reused name selects its current owner; history only rescues missing names.
    let current_names = {};
    for (let candidate in array_or_empty(urltest_candidate_tags))
        current_names[tag_display_name(candidate, names)] = true;
    let result = [];

    for (let tag in array_or_empty(urltest_candidate_tags)) {
        let base_matches = tag_name_filter_matches(tag, names, name_filter, regex_set, metadata, current_names) ||
            tag_country_filter_matches(tag, countries, country_filter);
        let matches = additional_set[tag] || base_matches;
        if (proxy_parameters_enabled && proxy_parameters_operator == "or") {
            matches = additional_set[tag] || base_matches || proxy_parameter_filter_matches_any(
                tag, metadata, protocols, transports, securities
            );
        }
        else if (proxy_parameters_enabled) {
            if (!base_filter_configured)
                base_matches = true;
            matches = additional_set[tag] ||
                (base_matches && proxy_parameter_filter_matches_all(
                    tag, metadata, protocols, transports, securities
                ));
        }

        if (matches)
            push(result, tag);
    }

    return unique_string_array(result);
}

function urltest_exclude_outbounds(all_outbounds, excluded_outbounds) {
    let excluded = object_keys_set(excluded_outbounds);
    let result = [];
    for (let tag in array_or_empty(all_outbounds)) {
        if (!excluded[tag])
            push(result, tag);
    }
    return result;
}

function filter_candidate_outbounds(filter_mode, urltest_candidate_tags, names, countries, metadata,
    include_names, include_regex, include_countries,
    include_proxy_parameters, include_protocols, include_transports, include_securities,
    exclude_names, exclude_regex, exclude_countries,
    exclude_proxy_parameters, exclude_protocols, exclude_transports, exclude_securities,
    include_additional_matches, exclude_additional_matches) {
    let all_outbounds = urltest_all_candidate_outbounds(urltest_candidate_tags);
    if (filter_mode == "" || filter_mode == "disabled")
        return deduplicate_alias_outbounds(all_outbounds, metadata);
    if (!supported_urltest_filter_mode(filter_mode))
        return deduplicate_alias_outbounds(all_outbounds, metadata);

    let include_outbounds = urltest_matching_candidate_outbounds(
        urltest_candidate_tags,
        names,
        countries,
        include_names,
        include_regex,
        include_countries,
        { ...object_or_empty(metadata), selectionBindings: object_or_empty(metadata).includeBindings },
        include_proxy_parameters,
        "and",
        include_protocols,
        include_transports,
        include_securities,
        include_additional_matches
    );
    let exclude_outbounds = urltest_matching_candidate_outbounds(
        urltest_candidate_tags,
        names,
        countries,
        exclude_names,
        exclude_regex,
        exclude_countries,
        { ...object_or_empty(metadata), selectionBindings: object_or_empty(metadata).excludeBindings },
        exclude_proxy_parameters,
        "or",
        exclude_protocols,
        exclude_transports,
        exclude_securities,
        exclude_additional_matches
    );

    if (filter_mode == "include")
        return deduplicate_alias_outbounds(include_outbounds, metadata);
    if (filter_mode == "exclude")
        return deduplicate_alias_outbounds(urltest_exclude_outbounds(all_outbounds, exclude_outbounds), metadata);
    if (filter_mode == "mixed")
        return deduplicate_alias_outbounds(urltest_exclude_outbounds(include_outbounds, exclude_outbounds), metadata);
    return deduplicate_alias_outbounds(all_outbounds, metadata);
}

function urltest_filtered_outbounds(section, urltest_id, urltest_candidate_tags, state) {
    let saved = filter_selection.read(section[".name"])[filter_selection.urltest_key(section, urltest_id)];
    return filter_candidate_outbounds(
        connections.urltest_filter_mode(section, urltest_id),
        urltest_candidate_tags,
        object_or_empty(object_or_empty(state.outboundMetadata).names),
        urltest_country_metadata(section, urltest_id, state),
        { ...object_or_empty(state.outboundMetadata),
            includeBindings: filter_selection.bound_names(saved, "include", connections.urltest_include_outbounds(section, urltest_id)),
            excludeBindings: filter_selection.bound_names(saved, "exclude", connections.urltest_exclude_outbounds(section, urltest_id)) },
        connections.urltest_include_outbounds(section, urltest_id),
        connections.urltest_include_regex(section, urltest_id),
        connections.urltest_include_countries(section, urltest_id),
        connections.urltest_include_proxy_parameters(section, urltest_id),
        connections.urltest_include_protocols(section, urltest_id),
        connections.urltest_include_transports(section, urltest_id),
        connections.urltest_include_securities(section, urltest_id),
        connections.urltest_exclude_outbounds(section, urltest_id),
        connections.urltest_exclude_regex(section, urltest_id),
        connections.urltest_exclude_countries(section, urltest_id),
        connections.urltest_exclude_proxy_parameters(section, urltest_id),
        connections.urltest_exclude_protocols(section, urltest_id),
        connections.urltest_exclude_transports(section, urltest_id),
        connections.urltest_exclude_securities(section, urltest_id)
    );
}

function priority_level_country_metadata(group_id, level_id, state) {
    let metadata = object_or_empty(object_or_empty(state.outboundMetadata).countries);
    let detect_method = connections.priority_level_detect_server_country(group_id, level_id);
    if (detect_method == "flag_emoji")
        return runtime_urltest.countries_from_flag_names(object_or_empty(object_or_empty(state.outboundMetadata).names));
    return metadata;
}

function priority_level_filtered_outbounds(group_id, level_id, urltest_candidate_tags, state) {
    if (connections.priority_level_direct(group_id, level_id))
        return [ runtime_constants.DIRECT_OUTBOUND_TAG ];

    let owner = uci_core.get(CONFIG_NAME + "." + group_id + ".section");
    let saved = owner ? filter_selection.read(owner)[filter_selection.priority_key(level_id)] : null;
    return filter_candidate_outbounds(
        connections.priority_level_filter_mode(group_id, level_id),
        urltest_candidate_tags,
        object_or_empty(object_or_empty(state.outboundMetadata).names),
        priority_level_country_metadata(group_id, level_id, state),
        { ...object_or_empty(state.outboundMetadata),
            includeBindings: filter_selection.bound_names(saved, "include", connections.priority_level_include_outbounds(group_id, level_id)),
            excludeBindings: filter_selection.bound_names(saved, "exclude", connections.priority_level_exclude_outbounds(group_id, level_id)) },
        connections.priority_level_include_outbounds(group_id, level_id),
        connections.priority_level_include_regex(group_id, level_id),
        connections.priority_level_include_countries(group_id, level_id),
        connections.priority_level_include_proxy_parameters(group_id, level_id),
        connections.priority_level_include_protocols(group_id, level_id),
        connections.priority_level_include_transports(group_id, level_id),
        connections.priority_level_include_securities(group_id, level_id),
        connections.priority_level_exclude_outbounds(group_id, level_id),
        connections.priority_level_exclude_regex(group_id, level_id),
        connections.priority_level_exclude_countries(group_id, level_id),
        connections.priority_level_exclude_proxy_parameters(group_id, level_id),
        connections.priority_level_exclude_protocols(group_id, level_id),
        connections.priority_level_exclude_transports(group_id, level_id),
        connections.priority_level_exclude_securities(group_id, level_id)
    );
}

function remember_group_outbounds(group_outbounds, group_name, outbounds) {
    let combined = array_or_empty(group_outbounds[group_name]);
    for (let tag_name in array_or_empty(outbounds))
        push(combined, tag_name);
    group_outbounds[group_name] = unique_string_array(combined);
}

function grouped_selector_outbounds(section, selector_tags, group_outbounds, state) {
    let configured_groups = [
        ...connections.urltests(section),
        ...connections.priority_groups(section)
    ];
    if (length(configured_groups) == 0)
        return selector_tags;

    let selected = [];
    for (let group_name in keys(object_or_empty(group_outbounds)))
        for (let tag_name in array_or_empty(group_outbounds[group_name]))
            push(selected, tag_name);

    return unique_string_array(selected);
}

function priority_levels_with_outbounds(group_id, urltest_candidate_tags, state) {
    let result = [];
    let assigned = {};

    for (let level_id in connections.priority_levels(group_id)) {
        let outbounds = [];
        for (let tag_name in priority_level_filtered_outbounds(group_id, level_id, urltest_candidate_tags, state)) {
            if (!assigned[tag_name]) {
                assigned[tag_name] = true;
                push(outbounds, tag_name);
            }
        }

        push(result, {
            id: level_id,
            displayName: connections.priority_level_display_name(group_id, level_id),
            order: int(connections.priority_level_order(group_id, level_id), 10),
            direct: connections.priority_level_direct(group_id, level_id),
            filter_mode: connections.priority_level_filter_mode(group_id, level_id),
            detect_server_country: connections.priority_level_detect_server_country(group_id, level_id),
            outbounds
        });
    }

    return result;
}

function priority_group_outbounds(levels) {
    let result = [];
    let seen = {};
    for (let level in array_or_empty(levels)) {
        for (let tag_name in array_or_empty(level.outbounds)) {
            tag_name = as_string(tag_name);
            if (tag_name != "" && !seen[tag_name]) {
                seen[tag_name] = true;
                push(result, tag_name);
            }
        }
    }
    return result;
}

function urltest_outbound_tag(section_name, urltest_id) {
    urltest_id = as_string(urltest_id);
    return urltest_id == "urltest"
        ? outbound_tag(section_name + "-urltest")
        : outbound_tag(section_name + "-urltest-" + urltest_id);
}

function priority_outbound_tag(section_name, group_id) {
    return outbound_tag(section_name + "-priority-" + as_string(group_id));
}

function add_urltest_outbound(config, section, urltest_id, urltest_candidate_tags, state) {
    let section_name = section[".name"];
    let urltest_outbounds = urltest_filtered_outbounds(section, urltest_id, urltest_candidate_tags, state);
    let urltest_tag = urltest_outbound_tag(section_name, urltest_id);
    let display_name = connections.urltest_display_name(section, urltest_id);
    let urltest_outbound = {
        type: "urltest",
        tag: urltest_tag,
        outbounds: urltest_outbounds,
        url: connections.urltest_testing_url(section, urltest_id),
        interval: urltest_check_interval(section, urltest_id),
        tolerance: int(connections.urltest_tolerance(section, urltest_id), 10),
        interrupt_exist_connections: connections.urltest_interrupt_exist_connections(section, urltest_id)
    };
    let idle_timeout = urltest_idle_timeout(section, urltest_id);
    if (idle_timeout != "")
        urltest_outbound.idle_timeout = idle_timeout;
    urltest_override.apply(urltest_outbound, section_name, urltest_tag);

    runtime_subscription.remember_outbound_metadata(state, urltest_tag, display_name, urltest_outbound);
    runtime_subscription.remember_urltest_group_config(state, urltest_tag, {
        displayName: display_name,
        outbounds: urltest_outbounds,
        url: urltest_outbound.url,
        interval: urltest_outbound.interval,
        tolerance: urltest_outbound.tolerance,
        idle_timeout: urltest_outbound.idle_timeout,
        interrupt_exist_connections: urltest_outbound.interrupt_exist_connections
    });

    if (length(urltest_outbounds) == 0)
        runtime_generate_unsupported("URLTest group '" + display_name + "' in rule '" + section_name + "' has no usable proxy outbounds after filtering");

    push(config.outbounds, urltest_outbound);
    return {
        tag: urltest_tag,
        outbounds: urltest_outbounds
    };
}

function add_priority_group_outbound(config, section, group_id, urltest_candidate_tags, state) {
    let section_name = section[".name"];
    let levels = priority_levels_with_outbounds(group_id, urltest_candidate_tags, state);
    let outbounds = priority_group_outbounds(levels);
    let priority_tag = priority_outbound_tag(section_name, group_id);
    let display_name = connections.priority_group_display_name(section, group_id);
    let outbound = {
        type: "selector",
        tag: priority_tag,
        outbounds,
        default: outbounds[0],
        interrupt_exist_connections: connections.priority_group_interrupt_exist_connections(section, group_id)
    };

    runtime_subscription.remember_outbound_metadata(state, priority_tag, display_name, outbound);
    runtime_subscription.remember_priority_group(state, priority_tag, {
        id: group_id,
        tag: priority_tag,
        section: section_name,
        displayName: display_name,
        health_url: connections.priority_group_health_url(section, group_id),
        active_check_interval: connections.priority_group_active_check_interval(section, group_id),
        check_timeout: connections.priority_group_check_timeout(section, group_id),
        recovery_check_interval: connections.priority_group_recovery_check_interval(section, group_id),
        pick_fastest: connections.priority_group_pick_fastest(section, group_id),
        switch_to_faster_same_priority: connections.priority_group_switch_to_faster_same_priority(section, group_id),
        fastest_check_interval: connections.priority_group_fastest_check_interval(section, group_id),
        interrupt_exist_connections: connections.priority_group_interrupt_exist_connections(section, group_id),
        pin_dashboard: connections.priority_group_pin_dashboard(section, group_id),
        outbounds,
        levels
    });

    if (length(outbounds) == 0)
        runtime_generate_unsupported("Priority group '" + display_name + "' in rule '" + section_name + "' has no usable proxy outbounds after filtering");

    push(config.outbounds, outbound);
    return {
        tag: priority_tag,
        outbounds
    };
}

function add_proxy_selector(config, section, selector_tags, urltest_candidate_tags, state) {
    let section_name = section[".name"];
    let selector_tag = outbound_tag(section_name);
    let selector_outbounds = selector_tags;
    let selector_default = selector_tags[0];
    let urltest_tags = [];
    let priority_tags = [];
    let group_outbounds = {};

    for (let urltest_id in connections.urltests(section)) {
        let urltest = add_urltest_outbound(config, section, urltest_id, urltest_candidate_tags, state);
        remember_group_outbounds(
            group_outbounds,
            connections.urltest_display_name(section, urltest_id),
            urltest.outbounds
        );
        if (urltest.tag == "")
            continue;

        push(urltest_tags, urltest.tag);
    }

    for (let group_id in connections.priority_groups(section)) {
        let priority = add_priority_group_outbound(config, section, group_id, urltest_candidate_tags, state);
        remember_group_outbounds(
            group_outbounds,
            connections.priority_group_display_name(section, group_id),
            priority.outbounds
        );
        if (priority.tag == "")
            continue;

        push(priority_tags, priority.tag);
    }

    selector_outbounds = grouped_selector_outbounds(section, selector_tags, group_outbounds, state);
    selector_default = selector_outbounds[0];
    if (length(urltest_tags) > 0 || length(priority_tags) > 0) {
        for (let tag in urltest_tags)
            push(selector_outbounds, tag);
        for (let tag in priority_tags)
            push(selector_outbounds, tag);
        selector_default = length(urltest_tags) > 0 ? urltest_tags[0] : priority_tags[0];
    }

    if (length(selector_outbounds) == 0)
        runtime_generate_unsupported("configured URLTest and Priority groups produced no usable outbounds");

    push(config.outbounds, {
        type: "selector",
        tag: selector_tag,
        outbounds: selector_outbounds,
        default: selector_default,
        interrupt_exist_connections: true
    });
}

function outbound_detour_tag_for_section(section) {
    if (!bool_option(section, "outbound_detour_enabled", false))
        return "";

    let detour_section = option(section, "outbound_detour_section", "");
    return detour_section == "" ? "" : outbound_tag(detour_section);
}

function apply_section_detour_to_connection_outbounds(config, start_index, detour_tag) {
    if (detour_tag == "")
        return;

    let outbounds = array_or_empty(config.outbounds);
    for (let i = int(start_index || 0); i < length(outbounds); i++) {
        let outbound = outbounds[i];
        if (type(outbound) != "object")
            continue;

        let outbound_type = lc(as_string(outbound.type || ""));
        if (outbound_type == "" ||
            outbound_type == "selector" ||
            outbound_type == "urltest" || outbound_type == "dns" ||
            outbound_type == "block")
            continue;

        // Preserve subscription chains: only their terminal dial outbound receives the section detour.
        if (as_string(outbound.detour || "") == "")
            outbound.detour = detour_tag;
    }
}

function mixed_proxy_enabled_action(action) {
    return action == "connection" || action == "proxy" || action == "outbound" || action == "vpn" ||
        action == "zapret" || action == "zapret2";
}

function add_mixed_proxy_for_section(config, section, service_address) {
    if (!bool_option(section, "mixed_proxy_enabled", false))
        return;

    let action = option(section, "action", "");
    if (!mixed_proxy_enabled_action(action))
        runtime_generate_unsupported("mixed proxy inbound is not supported for action " + action);

    let listen_port_value = option(section, "mixed_proxy_port", "");
    if (match(listen_port_value, /^[0-9]+$/) == null)
        runtime_generate_unsupported("mixed proxy port is invalid");
    let listen_port = int(listen_port_value, 10);
    if (listen_port < 1 || listen_port > 65535)
        runtime_generate_unsupported("mixed proxy port is invalid");

    let listen = as_string(service_address || "");
    if (listen == "")
        runtime_generate_unsupported("mixed proxy listen address is not set");

    let inbound = {
        type: "mixed",
        tag: runtime_constants.inbound_tag(section[".name"] + "-mixed"),
        listen,
        listen_port
    };

    if (bool_option(section, "mixed_proxy_auth_enabled", false)) {
        let username = option(section, "mixed_proxy_username", "");
        let password = option(section, "mixed_proxy_password", "");
        if (username == "" || password == "")
            runtime_generate_unsupported("mixed proxy authentication is enabled but username or password is empty");
        inbound.users = [{ username, password }];
    }
    push(config.inbounds, inbound);
    push(config.route.rules, {
        action: "route",
        inbound: inbound.tag,
        outbound: runtime_constants.outbound_tag(section[".name"])
    });
}

function add_service_mixed_proxy_inbound(config, tag_name, listen_port, outbound) {
    push(config.inbounds, {
        type: "mixed",
        tag: tag_name,
        listen: runtime_constants.SERVICE_MIXED_INBOUND_ADDRESS,
        listen_port
    });
    push(config.route.rules, {
        action: "route",
        inbound: tag_name,
        outbound
    });
}

function service_mixed_proxy_inbound_tag_for_purpose(purpose) {
    return as_string(purpose || "lists") == "components"
        ? runtime_constants.inbound_tag("service-components")
        : runtime_constants.SERVICE_MIXED_INBOUND_TAG;
}

function service_mixed_proxy_port_for_purpose(purpose) {
    return runtime_constants.SERVICE_MIXED_INBOUND_PORT +
        (as_string(purpose || "lists") == "components" ? 1 : 0);
}

function add_global_download_service_mixed_proxy(config, settings, purpose) {
    let outbound = download_detour_tag(settings, purpose);
    if (outbound == "")
        return;

    add_service_mixed_proxy_inbound(
        config,
        service_mixed_proxy_inbound_tag_for_purpose(purpose),
        service_mixed_proxy_port_for_purpose(purpose),
        outbound
    );
}

function add_subscription_download_service_mixed_proxies(config, sections) {
    for (let target in connections.subscription_download_targets(sections)) {
        let port = connections.subscription_download_target_port(sections, target, runtime_constants.SERVICE_MIXED_INBOUND_PORT);
        if (port <= 0)
            runtime_generate_unsupported("subscription download proxy port could not be resolved");

        add_service_mixed_proxy_inbound(
            config,
            runtime_constants.inbound_tag("service-subscription-" + target),
            port,
            outbound_tag(target)
        );
    }
}

function add_service_mixed_proxy(config, settings, sections) {
    if (!download_via_proxy_any_enabled(settings, sections))
        return;

    add_global_download_service_mixed_proxy(config, settings, "lists");
    add_global_download_service_mixed_proxy(config, settings, "components");
    add_subscription_download_service_mixed_proxies(config, sections);

    if (download_via_proxy_enabled(settings, "lists") && download_detour_tag(settings, "lists") == "")
        runtime_generate_unsupported("download lists via proxy section is not set");
    if (download_via_proxy_enabled(settings, "components") && download_detour_tag(settings, "components") == "")
        runtime_generate_unsupported("download components via proxy section is not set");
}

/*
 * This proxy is intentionally routed only by its inbound tag. Destination
 * domains, IP ranges and rule sets must never be able to move its traffic to a
 * VPN outbound. Keep the compact 1.14-compatible route rule shape used by the
 * other service inbounds.
 */
function add_direct_proxy(config, settings, service_address) {
    if (!bool_option(settings, "direct_proxy_enabled", false))
        return;

    let listen = as_string(service_address || "");
    if (listen == "")
        runtime_generate_unsupported("direct proxy listen address is not set");

    let port_value = option(settings, "direct_proxy_port", as_string(runtime_constants.DIRECT_PROXY_DEFAULT_PORT));
    if (match(port_value, /^[0-9]+$/) == null)
        runtime_generate_unsupported("direct proxy port is invalid");
    let listen_port = int(port_value, 10);
    if (listen_port < 1 || listen_port > 65535)
        runtime_generate_unsupported("direct proxy port is invalid");

    push(config.inbounds, {
        type: "mixed",
        tag: runtime_constants.DIRECT_PROXY_INBOUND_TAG,
        listen,
        listen_port
    });
    push(config.outbounds, {
        type: "direct",
        tag: runtime_constants.DIRECT_PROXY_OUTBOUND_TAG,
        routing_mark: runtime_constants.OUTBOUND_MARK
    });
    push(config.route.rules, {
        action: "route",
        inbound: runtime_constants.DIRECT_PROXY_INBOUND_TAG,
        outbound: runtime_constants.DIRECT_PROXY_OUTBOUND_TAG
    });
}

function parse_port(value) {
    value = as_string(value);
    if (match(value, /^[0-9]+$/) == null)
        return null;
    let port = int(value, 10);
    return port >= 1 && port <= 65535 ? port : null;
}

function bool_query(value) {
    return value == "1" || value == "true";
}

function base64_decode_value(value) {
    value = replace(as_string(value), /[\r\n\t ]/g, "");
    value = replace(replace(value, /-/g, "+"), /_/g, "/");
    while (length(value) % 4 != 0)
        value += "=";
    try {
        return b64dec(value);
    }
    catch (e) {
        return null;
    }
}

function shadowsocks_userinfo_valid(value) {
    value = as_string(value);
    let first = index(value, ":");
    if (first <= 0 || first >= length(value) - 1)
        return false;
    let rest = substr(value, first + 1);
    let second = index(rest, ":");
    return second < 0 || index(substr(rest, second + 1), ":") < 0;
}

function split_host_port(value) {
    value = as_string(value);
    if (substr(value, 0, 1) == "[") {
        let close = index(value, "]");
        if (close > 0 && substr(value, close + 1, 1) == ":")
            return [ substr(value, 1, close - 1), substr(value, close + 2) ];
    }

    let colon = rindex(value, ":");
    if (colon < 0)
        return [ "", "" ];
    return [ substr(value, 0, colon), substr(value, colon + 1) ];
}

function tls_alpn_array(value, transport) {
    value = as_string(value);
    transport = lc(as_string(transport));
    if (value == "" && transport == "xhttp")
        return [ "h2", "http/1.1" ];
    if (value != "" && (transport == "ws" || transport == "httpupgrade"))
        return [ "http/1.1" ];
    return value == "" ? [] : split(value, ",");
}

function apply_link_tls(outbound, scheme, query) {
    query = object_or_empty(query);
    let security = as_string(query.security || "");
    // Trojan runs over TLS: a link without security= means TLS, as in the
    // subscription parser and in the links Forkop writes itself.
    if (security == "" && (scheme == "hysteria2" || scheme == "hy2" || scheme == "trojan"))
        security = "tls";

    if (security == "" || security == "none")
        return;
    if (security != "tls" && security != "reality") {
        warn("unknown manual proxy link security '", security, "' ignored\n");
        return;
    }

    let tls = { enabled: true };
    // Hysteria2 links carry the whole-certificate pin as pinSHA256.
    let pins = as_string(query.pcs || "");
    if ((scheme == "hysteria2" || scheme == "hy2") && as_string(query.pinSHA256 || "") != "")
        pins = pins != "" ? pins + "," + as_string(query.pinSHA256) : as_string(query.pinSHA256);
    subscription_parser.add_certificate_pins(tls, pins);
    if (as_string(query.sni || "") != "")
        tls.server_name = as_string(query.sni);
    if (bool_query(query.allowInsecure || query.insecure || ""))
        tls.insecure = true;

    let alpn = tls_alpn_array(query.alpn, query.type);
    if (length(alpn) > 0)
        tls.alpn = alpn;

    if (scheme != "hysteria2" && scheme != "hy2" && as_string(query.fp || "") != "") {
        tls.utls = {
            enabled: true,
            fingerprint: as_string(query.fp)
        };
    }
    if (security == "reality") {
        tls.reality = {
            enabled: true,
            public_key: as_string(query.pbk || ""),
            short_id: as_string(query.sid || "")
        };
        let preference = query.support_x25519mlkem768;
        if (preference == null)
            preference = query.supportX25519MLKEM768;
        if (preference != null)
            tls.reality.support_x25519mlkem768 = bool_query(preference);
        if (as_string(query.pqv || "") != "")
            tls.reality.__forkop_mldsa65_verify = as_string(query.pqv);
    }
    outbound.tls = tls;
}

function csv_array(value) {
    value = as_string(value);
    if (value == "")
        return [];
    let result = [];
    for (let item in split(value, ",")) {
        item = trim(as_string(item));
        if (item != "")
            push(result, item);
    }
    return result;
}

function optional_query_string(object, key, value) {
    value = as_string(value);
    if (value != "")
        object[key] = value;
}

function optional_query_number(object, key, value) {
    value = as_string(value);
    if (value != "" && match(value, /^[0-9]+$/) != null)
        object[key] = int(value, 10);
}

function apply_link_transport(outbound, query) {
    let transport = lc(as_string(object_or_empty(query).type || ""));
    if (transport == "" || transport == "tcp" || transport == "raw")
        return;

    if (transport == "h2")
        transport = "http";

    let result = { type: transport };
    if (transport == "http") {
        optional_query_string(result, "path", query.path);
        let hosts = csv_array(query.host);
        if (length(hosts) > 0)
            result.host = hosts;
    }
    else if (transport == "ws") {
        result.path = as_string(query.path || "");
        if (as_string(query.host || "") != "")
            result.headers = { Host: as_string(query.host) };
        optional_query_number(result, "max_early_data", query.ed);
    }
    else if (transport == "grpc") {
        optional_query_string(result, "service_name", query.serviceName);
    }
    else if (transport == "httpupgrade") {
        optional_query_string(result, "path", query.path);
        optional_query_string(result, "host", query.host);
    }
    else if (transport == "xhttp") {
        let mode = as_string(query.mode || "auto");
        if (mode != "auto" && mode != "packet-up" && mode != "stream-up" && mode != "stream-one")
            mode = "auto";
        result.mode = mode;
        result.path = as_string(query.path || "") != "" ? as_string(query.path) : "/";
        result.x_padding_bytes = "100-1000";
        result.no_grpc_header = false;
        result.sc_max_each_post_bytes = 1000000;
        result.sc_min_posts_interval_ms = 30;
        optional_query_string(result, "host", as_string(query.host || "") != "" ? query.host : query.sni);
        subscription_parser.xhttp_apply_query_settings(result, query);
    }
    else {
        warn("unknown manual proxy link transport '", transport, "' ignored\n");
        return;
    }

    outbound.transport = result;
}

function manual_socks_outbound(link, tag_name) {
    let scheme = url_scheme(link);
    let host = url_host(link);
    let port = parse_port(url_port(link));
    if (host == "" || port == null)
        runtime_generate_unsupported("manual SOCKS proxy link is invalid");

    let outbound = {
        type: "socks",
        tag: tag_name,
        server: host,
        server_port: port,
        version: scheme == "socks4" || scheme == "socks4a" ? "4" : "5"
    };
    if (scheme == "socks5") {
        let userinfo = url_userinfo(link);
        if (userinfo != "") {
            let colon = index(userinfo, ":");
            outbound.username = colon >= 0 ? substr(userinfo, 0, colon) : userinfo;
            if (colon >= 0)
                outbound.password = substr(userinfo, colon + 1);
        }
    }
    return outbound;
}

function manual_shadowsocks_outbound(link, tag_name) {
    let raw = url_strip_fragment_value(url_decode(link));
    let body = substr(raw, 5);
    let question = index(body, "?");
    let query_string = "";
    if (question >= 0) {
        query_string = substr(body, question + 1);
        body = substr(body, 0, question);
    }

    let at = rindex(body, "@");
    let userinfo = "";
    let hostport = "";
    if (at >= 0) {
        userinfo = substr(body, 0, at);
        hostport = substr(body, at + 1);
    }
    else {
        let decoded = base64_decode_value(body);
        if (decoded == null)
            runtime_generate_unsupported("manual Shadowsocks proxy link is invalid");
        at = rindex(decoded, "@");
        if (at < 0)
            runtime_generate_unsupported("manual Shadowsocks proxy link is invalid");
        userinfo = substr(decoded, 0, at);
        hostport = substr(decoded, at + 1);
    }

    userinfo = url_decode(userinfo);
    if (!shadowsocks_userinfo_valid(userinfo)) {
        let decoded = base64_decode_value(userinfo);
        if (decoded == null)
            runtime_generate_unsupported("manual Shadowsocks proxy link is invalid");
        userinfo = decoded;
    }

    let cred_colon = index(userinfo, ":");
    let host_port = split_host_port(hostport);
    let port = parse_port(host_port[1]);
    if (cred_colon <= 0 || host_port[0] == "" || port == null)
        runtime_generate_unsupported("manual Shadowsocks proxy link is invalid");

    let outbound = {
        type: "shadowsocks",
        tag: tag_name,
        server: host_port[0],
        server_port: port,
        method: substr(userinfo, 0, cred_colon),
        password: substr(userinfo, cred_colon + 1)
    };
    let query = url_query_params("ss://placeholder/?" + query_string);
    if (as_string(query.plugin || "") != "")
        outbound.plugin = as_string(query.plugin);
    if (as_string(query["plugin-opts"] || "") != "")
        outbound.plugin_opts = as_string(query["plugin-opts"]);
    return outbound;
}

function manual_vless_outbound(link, tag_name) {
    let query = url_query_params(link);

    let host = url_host(link);
    let port = parse_port(url_port(link));
    let uuid = url_userinfo(link);
    if (host == "" || port == null || uuid == "")
        runtime_generate_unsupported("manual VLESS proxy link is invalid");

    let outbound = {
        type: "vless",
        tag: tag_name,
        server: host,
        server_port: port,
        uuid
    };
    let flow = as_string(query.flow || "");
    if (flow != "")
        outbound.flow = flow;
    let encryption = as_string(query.encryption || "");
    if (encryption != "" && encryption != "none")
        outbound.encryption = encryption;
    let packet_encoding = as_string(query.packetEncoding || "");
    if (packet_encoding == "xudp" || packet_encoding == "packetaddr")
        outbound.packet_encoding = packet_encoding;
    apply_link_tls(outbound, "vless", query);
    apply_link_transport(outbound, query);
    return outbound;
}

function vmess_json_value(value) {
    return value == null ? "" : as_string(value);
}

function manual_vmess_outbound(link, tag_name) {
    let encoded = substr(url_strip_fragment_value(link), 8);
    let decoded = base64_decode_value(encoded);
    if (decoded == null)
        runtime_generate_unsupported("manual VMess proxy link is invalid");

    if (index(decoded, "\r") >= 0 || index(decoded, "\n") >= 0)
        decoded = replace(decoded, /[\r\n]/g, "");
    decoded = trim(decoded);

    let vmess;
    try {
        vmess = json(decoded);
    }
    catch (e) {
        runtime_generate_unsupported("manual VMess proxy link is invalid");
    }
    if (type(vmess) != "object")
        runtime_generate_unsupported("manual VMess proxy link is invalid");

    let host = vmess_json_value(vmess.add);
    let port = parse_port(vmess_json_value(vmess.port));
    let uuid = vmess_json_value(vmess.id);
    if (host == "" || port == null || uuid == "")
        runtime_generate_unsupported("manual VMess proxy link is invalid");

    let outbound = {
        type: "vmess",
        tag: tag_name,
        server: host,
        server_port: port,
        uuid,
        security: vmess_json_value(vmess.scy) != "" ? vmess_json_value(vmess.scy) : "auto"
    };

    if (vmess_json_value(vmess.aid) != "")
        outbound.alter_id = int(vmess.aid || 0);

    let network = lc(vmess_json_value(vmess.net));
    if (vmess.tls === true || vmess.tls == "tls" || vmess.tls == "true") {
        let tls = { enabled: true };
        optional_query_string(tls, "server_name", vmess_json_value(vmess.sni));
        let alpn = tls_alpn_array(vmess_json_value(vmess.alpn), network);
        if (length(alpn) > 0)
            tls.alpn = alpn;
        if (vmess_json_value(vmess.fp) != "") {
            tls.utls = {
                enabled: true,
                fingerprint: vmess_json_value(vmess.fp)
            };
        }
        outbound.tls = tls;
    }

    if (network == "ws") {
        outbound.transport = {
            type: "ws",
            path: vmess_json_value(vmess.path) != "" ? vmess_json_value(vmess.path) : "/"
        };
        if (vmess_json_value(vmess.host) != "")
            outbound.transport.headers = { Host: vmess_json_value(vmess.host) };
    }
    else if (network == "grpc") {
        outbound.transport = { type: "grpc" };
        optional_query_string(outbound.transport, "service_name", vmess_json_value(vmess.path));
    }
    else if (network == "http" || network == "h2") {
        outbound.transport = { type: "http" };
        optional_query_string(outbound.transport, "path", vmess_json_value(vmess.path));
        let hosts = csv_array(vmess_json_value(vmess.host));
        if (length(hosts) > 0)
            outbound.transport.host = hosts;
    }

    return outbound;
}

function manual_trojan_outbound(link, tag_name) {
    let query = url_query_params(link);

    let host = url_host(link);
    let port = parse_port(url_port(link));
    let password = url_userinfo(link);
    if (host == "" || port == null || password == "")
        runtime_generate_unsupported("manual Trojan proxy link is invalid");

    let outbound = {
        type: "trojan",
        tag: tag_name,
        server: host,
        server_port: port,
        password
    };
    apply_link_tls(outbound, "trojan", query);
    apply_link_transport(outbound, query);
    return outbound;
}

function manual_hysteria2_outbound(link, tag_name) {
    let query = url_query_params(link);
    let host = url_host(link);
    let port = parse_port(as_string(query.mport || "") != "" ? query.mport : url_port(link));
    let password = url_userinfo(link);
    if (host == "" || port == null || password == "")
        runtime_generate_unsupported("manual Hysteria2 proxy link is invalid");

    let outbound = {
        type: "hysteria2",
        tag: tag_name,
        server: host,
        server_port: port,
        password
    };
    if (as_string(query.obfs || "") != "")
        outbound.obfs = { type: as_string(query.obfs), password: as_string(query["obfs-password"] || "") };
    if (as_string(query.upmbps || "") != "")
        outbound.up_mbps = int(query.upmbps, 10);
    if (as_string(query.downmbps || "") != "")
        outbound.down_mbps = int(query.downmbps, 10);
    apply_link_tls(outbound, url_scheme(link), query);
    return outbound;
}

function manual_link_outbound(link, tag_name) {
    let scheme = url_scheme(link);
    if (scheme == "vmess")
        return manual_vmess_outbound(link, tag_name);

    // Decode query values individually: decoding the whole URI turns an
    // encoded '&' inside xHTTP extra/session keys into a query separator.
    link = url_strip_fragment_value(scheme == "vless" || scheme == "trojan" ? link : url_decode(link));
    scheme = url_scheme(link);
    if (scheme == "socks4" || scheme == "socks4a" || scheme == "socks5")
        return manual_socks_outbound(link, tag_name);
    if (scheme == "ss")
        return manual_shadowsocks_outbound(link, tag_name);
    if (scheme == "vless")
        return manual_vless_outbound(link, tag_name);
    if (scheme == "trojan")
        return manual_trojan_outbound(link, tag_name);
    if (scheme == "hysteria2" || scheme == "hy2")
        return manual_hysteria2_outbound(link, tag_name);
    runtime_generate_unsupported("manual proxy link scheme is not supported by sing-box config generation yet");
}

function add_manual_proxy_link(config, state, section_name, manual_index, link, taken, selector_tags, urltest_candidate_tags) {
    let tag_name = outbound_tag(section_name + "-" + manual_index);
    if (taken[tag_name])
        tag_name = unique_tag(tag_name, taken);
    taken[tag_name] = true;

    let outbound = manual_link_outbound(link, tag_name);
    let display_name = url_fragment(link);
    if (display_name == "")
        display_name = tag_name;
    ensure_explicit_outbound_supported(outbound, "manual outbound", display_name);
    outbound = without_reality_mldsa65_marker(outbound);
    push(config.outbounds, outbound);
    push(selector_tags, tag_name);
    push(urltest_candidate_tags, tag_name);

    state.links[tag_name] = as_string(link);
    runtime_subscription.remember_outbound_metadata(state, tag_name, display_name, outbound);
    return tag_name;
}

function connection_item_tag(section_name, kind, item_index) {
    return outbound_tag(section_name + "-" + as_string(kind) + "-" + item_index);
}

function add_connection_manual_links(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    let section_name = section[".name"];
    let manual_links = connections.connection_urls(section);
    for (let i = 0; i < length(manual_links); i++) {
        let link = manual_links[i];
        add_manual_proxy_link(
            config,
            state,
            section_name,
            i + 1,
            link,
            taken,
            selector_tags,
            urltest_candidate_tags
        );
    }
}

function add_connection_subscriptions(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    let subscription_urls = connections.subscription_urls(section);

    for (let i = 0; i < length(subscription_urls); i++)
        add_subscription_source_with_state(
            config,
            section,
            i + 1,
            subscription_urls[i],
            taken,
            selector_tags,
            urltest_candidate_tags,
            state,
            connections.subscription_dashboard_metadata_enabled(section, subscription_urls[i]),
            connections.subscription_include_urltest_groups(section, subscription_urls[i]),
            connections.subscription_hide_urltest_group_outbounds(section, subscription_urls[i]),
            connections.subscription_hide_detour_outbounds(section, subscription_urls[i]),
            connections.subscription_node_prefix(section, subscription_urls[i])
        );
}

function add_interface_connection_outbound(config, state, section, interface_index, interface_name, taken, selector_tags, urltest_candidate_tags) {
    let section_name = section[".name"];
    let tag_name = connection_item_tag(section_name, "interface", interface_index);
    if (taken[tag_name])
        tag_name = unique_tag(tag_name, taken);
    taken[tag_name] = true;

    let domain_resolver = "";
    if (connections.interface_domain_resolver_enabled(section, interface_name)) {
        domain_resolver = runtime_constants.domain_resolver_tag(section_name + "-interface-" + interface_index);
        let dns_server = runtime_dns.server_from_options(
            domain_resolver,
            connections.interface_domain_resolver_dns_type(section, interface_name),
            connections.interface_domain_resolver_dns_server(section, interface_name),
            tag_name
        );
        if (dns_server.unsupported)
            runtime_generate_unsupported(dns_server.unsupported);
        push(config.dns.servers, dns_server);
    }

    let outbound = {
        type: "direct",
        tag: tag_name,
        bind_interface: interface_name,
        domain_resolver,
        routing_mark: runtime_constants.OUTBOUND_MARK
    };
    if (domain_resolver == "")
        delete outbound.domain_resolver;

    push(config.outbounds, outbound);
    push(selector_tags, tag_name);
    push(urltest_candidate_tags, tag_name);
    runtime_subscription.remember_outbound_metadata(state, tag_name, interface_name, outbound);
}

function add_connection_interfaces(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    let items = connections.interfaces(section);
    for (let i = 0; i < length(items); i++)
        add_interface_connection_outbound(config, state, section, i + 1, items[i], taken, selector_tags, urltest_candidate_tags);
}

function parse_outbound_json(value) {
    try {
        value = json(as_string(value));
    }
    catch (e) {
        return null;
    }

    return type(value) == "object" ? value : null;
}

function rewrite_json_outbound_references(outbounds, tag_map) {
    for (let outbound in array_or_empty(outbounds)) {
        if (type(outbound) != "object")
            continue;

        for (let key in [ "detour", "default" ]) {
            let reference = as_string(outbound[key] || "");
            if (reference != "" && tag_map[reference])
                outbound[key] = tag_map[reference];
        }

        if (type(outbound.outbounds) == "array") {
            let rewritten = [];
            for (let tag_name in outbound.outbounds) {
                tag_name = as_string(tag_name);
                if (tag_name != "")
                    push(rewritten, as_string(tag_map[tag_name] || tag_name));
            }
            outbound.outbounds = rewritten;
        }
    }
}

function prepare_json_connection_outbounds(section, taken) {
    let items = connections.outbound_jsons(section);
    let prepared = [];
    let outbounds = [];
    let tag_map = {};
    let legacy_tags = [];

    for (let i = 0; i < length(items); i++) {
        let outbound = parse_outbound_json(items[i]);
        if (outbound == null)
            runtime_generate_unsupported("JSON outbound is invalid");

        let display_name = trim(as_string(outbound.tag || ""));
        let legacy_tag = connection_item_tag(section[".name"], "json", i + 1);
        let base = display_name != "" ? display_name : legacy_tag;
        let tag_name = unique_tag(base, taken);
        ensure_explicit_outbound_supported(outbound, "JSON outbound", display_name != "" ? display_name : legacy_tag);
        taken[tag_name] = true;
        if (display_name != "" && !tag_map[display_name])
            tag_map[display_name] = tag_name;
        push(legacy_tags, [ legacy_tag, tag_name ]);

        outbound.tag = tag_name;
        push(outbounds, outbound);
        push(prepared, {
            outbound,
            displayName: display_name != "" ? display_name : "JSON outbound " + (i + 1)
        });
    }

    for (let entry in legacy_tags)
        if (!tag_map[entry[0]])
            tag_map[entry[0]] = entry[1];

    rewrite_json_outbound_references(outbounds, tag_map);
    return prepared;
}

function add_connection_json_outbounds(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    for (let item in prepare_json_connection_outbounds(section, taken)) {
        let outbound = item.outbound;
        let tag_name = outbound.tag;
        push(config.outbounds, outbound);
        push(selector_tags, tag_name);
        if (urltest_leaf_candidate_outbound(outbound))
            push(urltest_candidate_tags, tag_name);
        runtime_subscription.remember_outbound_metadata(state, tag_name, item.displayName, outbound);
        runtime_subscription.remember_urltest_group(state, tag_name, item.displayName, outbound);
    }
}

function add_connections_outbound(config, section, taken) {
    let section_name = section[".name"];
    let selector_tags = [];
    let urltest_candidate_tags = [];
    let state = runtime_subscription.new_section_state(section_name);
    let cascade_start = length(array_or_empty(config.outbounds));

    add_connection_manual_links(config, state, section, taken, selector_tags, urltest_candidate_tags);
    add_connection_subscriptions(config, state, section, taken, selector_tags, urltest_candidate_tags);
    // Apply before interface and JSON items are added: those source kinds are intentionally excluded.
    apply_section_detour_to_connection_outbounds(
        config,
        cascade_start,
        outbound_detour_tag_for_section(section)
    );
    add_connection_interfaces(config, state, section, taken, selector_tags, urltest_candidate_tags);
    add_connection_json_outbounds(config, state, section, taken, selector_tags, urltest_candidate_tags);

    if (length(selector_tags) == 0) {
        let skipped_protocols = skipped_protocol_summary(section_name);
        if (skipped_protocols != "")
            runtime_generate_unsupported("connection section '" + section_name + "' has no outbounds compatible with Xrust; skipped subscription outbounds with unsupported protocols: " + skipped_protocols + ". Settings were not applied");
        runtime_generate_unsupported("connection section has no usable outbounds");
    }

    if (section_needs_country_is(section)) {
        let previous_state = read_json_file(runtime_subscription.section_cache_path(section_name));
        state.outboundMetadata.countries = runtime_country.detect(
            state.servers,
            previous_state,
            option(runtime_settings(), "bootstrap_dns_server", "77.88.8.8")
        );
    }
    if (section_has_direct_priority_level(section))
        state.outboundMetadata.names[runtime_constants.DIRECT_OUTBOUND_TAG] = "Direct";

    state.urltestCandidateTags = unique_string_array(urltest_candidate_tags);
    runtime_subscription.resolve_urltest_profile_aliases(state);
    add_proxy_selector(config, section, selector_tags, urltest_candidate_tags, state);
    if (length(connections.urltests(section)) > 0 || length(connections.priority_groups(section)) > 0) {
        // Keep the section selector as a root. Dependencies are resolved after
        // all sections/routes are built, so shared detours cannot be dropped.
        for (let i = cascade_start; i < length(config.outbounds); i++) {
            let tag = config.outbounds[i].tag;
            if (tag != outbound_tag(section_name))
                runtime_prunable_outbounds[tag] = true;
        }
    }
    if (!atomic_write_json_file(runtime_subscription.section_cache_path(section_name), state))
        runtime_generate_unsupported("failed to write section cache for " + section_name);
}

function enabled_action_index(sections, target_section, action_name) {
    let index = 0;
    for (let section in sections) {
        if (option(section, "action", "") != action_name)
            continue;
        index++;
        if (section[".name"] == target_section[".name"])
            return index;
    }
    return 0;
}

function add_zapret_outbound(config, section, sections) {
    let index = enabled_action_index(sections, section, "zapret");
    if (index <= 0)
        runtime_generate_unsupported("unable to resolve Zapret index for " + section[".name"]);
    push(config.outbounds, {
        type: "direct",
        tag: outbound_tag(section[".name"]),
        routing_mark: runtime_constants.ZAPRET_ROUTE_MARK_BASE + index
    });
}

function add_zapret2_outbound(config, section, sections) {
    let index = enabled_action_index(sections, section, "zapret2");
    if (index <= 0)
        runtime_generate_unsupported("unable to resolve Zapret2 index for " + section[".name"]);
    push(config.outbounds, {
        type: "direct",
        tag: outbound_tag(section[".name"]),
        routing_mark: runtime_constants.ZAPRET2_ROUTE_MARK_BASE + index
    });
}

function ensure_community_ruleset(config, section_name, community) {
    if (!runtime_rulesets.is_community(community))
        runtime_generate_unsupported("unknown community list " + community);

    let tag_name = ruleset_tag(section_name, community, "community");
    if (!ruleset_registered(config, tag_name)) {
        let rule_set = {
            type: "remote",
            tag: tag_name,
            format: "binary",
            url: runtime_rulesets.community_url(community),
            update_interval: remote_ruleset_update_interval()
        };
        let detour = download_detour_tag(runtime_settings(), "lists");
        if (detour != "")
            rule_set.download_detour = detour;
        push(config.route.rule_set, rule_set);
    }
    return {
        tag: tag_name,
        // Discord's mixed set carries domains and UDP voice addresses. DNS
        // must select its domains before resolution, never shared edge IPs.
        kind: community == "discord" ? "domains" : runtime_rulesets.community_kind(community)
    };
}

function domain_ip_list_ruleset_tag(section_name) {
    return ruleset_tag(section_name, "lists", "");
}

function domain_ip_list_ruleset_path(section_name) {
    return runtime_ruleset_folder + "/" + domain_ip_list_ruleset_tag(section_name) + ".json";
}

function remote_list_ruleset_tag(section_name, kind) {
    return ruleset_tag(section_name, "remote", kind);
}

function remote_list_ruleset_path(section_name, kind) {
    return runtime_ruleset_folder + "/" + remote_list_ruleset_tag(section_name, kind) + ".json";
}

function remote_list_is_singbox_managed(reference) {
    let extension = runtime_rulesets.file_extension(reference);
    return extension == "json" || extension == "srs";
}

function ensure_materialized_remote_list_ruleset(config, section_name, kind) {
    let tag_name = remote_list_ruleset_tag(section_name, kind);
    let path = remote_list_ruleset_path(section_name, kind);
    let ruleset = read_json_file(path);

    // Plain remote lists are downloaded and converted into this source rule-set
    // by the transactional list generation.  Never publish an nft interception
    // without the corresponding sing-box matcher: a missing or malformed
    // materialized file is a generation/configuration failure, not an empty
    // matcher that could fall through to final/direct.
    if (type(ruleset) != "object" || type(ruleset.rules) != "array")
        runtime_generate_unsupported("remote " + kind + " ruleset for '" + section_name + "' is missing or invalid");

    if (!ruleset_registered(config, tag_name)) {
        push(config.route.rule_set, {
            type: "local",
            tag: tag_name,
            format: "source",
            path
        });
    }
    return tag_name;
}

function add_remote_list_rulesets(config, section, option_name, kind, route_tags, dns_tags) {
    let section_name = as_string(section[".name"]);
    let has_materialized_source = false;

    for (let reference in list_option(section, option_name)) {
        reference = as_string(reference);
        if (reference == "")
            continue;

        if (!remote_list_is_singbox_managed(reference)) {
            has_materialized_source = true;
            continue;
        }

        let ensured = ensure_custom_ruleset(config, reference);
        push(route_tags, ensured.tag);
        if (kind == "domains" && dns_tags != null)
            push(dns_tags, ensured.tag);
    }

    if (!has_materialized_source)
        return;

    let tag_name = ensure_materialized_remote_list_ruleset(config, section_name, kind);
    push(route_tags, tag_name);
    if (kind == "domains" && dns_tags != null)
        push(dns_tags, tag_name);
}

function reference_is_local(reference) {
    return substr(as_string(reference), 0, 1) == "/";
}

function source_file_exists(path) {
    return fs.readfile(path) != null;
}

function rebuild_local_domain_ip_list_ruleset(section_name, references, domains_only) {
    let ruleset_path = domain_ip_list_ruleset_path(section_name);
    let has_local = false;

    for (let reference in references) {
        if (reference_is_local(reference)) {
            has_local = true;
            break;
        }
    }

    if (!has_local)
        return;

    fs.unlink(ruleset_path);
    source_rulesets.create_source(ruleset_path);

    for (let reference in references) {
        reference = as_string(reference);
        if (!reference_is_local(reference))
            continue;
        if (!source_file_exists(reference)) {
            warn("local domain/IP list not found: ", reference, "\n");
            continue;
        }

        source_rulesets.import_plain_list(reference, ruleset_path, "domain_suffix", "domains", "5000");
        if (!domains_only)
            source_rulesets.import_plain_list(reference, ruleset_path, "ip_cidr", "subnets", "5000");
    }
}

function add_domain_ip_list_ruleset(config, section_name, rule_set_tags, dns_query_tags, dns_response_tags, references, domains_only) {
    if (length(references) == 0)
        return;

    rebuild_local_domain_ip_list_ruleset(section_name, references, domains_only);

    let ruleset_path = domain_ip_list_ruleset_path(section_name);
    if (!source_rulesets.has_rules(ruleset_path))
        return;

    let tag_name = domain_ip_list_ruleset_tag(section_name);
    if (!ruleset_registered(config, tag_name)) {
        push(config.route.rule_set, {
            type: "local",
            tag: tag_name,
            format: "source",
            path: ruleset_path
        });
    }

    if (!domains_only)
        push(rule_set_tags, tag_name);
    let has_domains = source_rulesets.has_domain_matchers(ruleset_path);
    let has_addresses = source_rulesets.has_ip_matchers(ruleset_path);
    if (runtime_supports_dns_response_matching && has_addresses)
        push(dns_response_tags, tag_name);
    else if (has_domains)
        push(dns_query_tags, tag_name);
}

function legacy_condition_values(section, key) {
    let raw_values = object_or_empty(section)[key];
    let list_values = type(raw_values) == "array"
        ? raw_values
        : [];
    let option_text_values = type(raw_values) == "array" || key == "domain"
        ? []
        : rule_config.text_list_values(raw_values, "comma-space");
    let text_value = option(section, key + "_text", "");
    let text_values = rule_config.text_list_values(text_value, "comma-space");

    if (bool_option(section, key + "_text_mode", false) || bool_option(section, "conditions_text_mode", false))
        return text_values;
    if (length(list_values) > 0)
        return list_values;
    if (length(option_text_values) > 0)
        return option_text_values;
    return text_values;
}

function combined_domain_source_values(section) {
    let values = [];
    if (type(object_or_empty(section)["domain"]) != "array") {
        for (let value in rule_config.text_list_values(option(section, "domain", ""), "comma-space"))
            if (as_string(value) != "")
                push(values, as_string(value));
    }
    for (let value in rule_config.text_list_values(option(section, "domain_suffix_text", ""), "comma-space"))
        if (as_string(value) != "")
            push(values, as_string(value));
    for (let value in list_option(section, "domain_suffix"))
        if (as_string(value) != "")
            push(values, as_string(value));
    return values;
}

function domain_suffix_condition_value_kind(value) {
    return rule_config.prefixed_domain_kind_value(value);
}

function domain_conditions(section) {
    let result = {
        domain: [],
        domain_suffix: [],
        domain_keyword: [],
        domain_regex: []
    };

    for (let key in [ "domain", "domain_keyword", "domain_regex" ]) {
        for (let value in legacy_condition_values(section, key)) {
            let normalized = rule_config.domain_value_for_key(value, key);
            if (normalized != null)
                push(result[key], normalized);
        }
    }

    for (let value in combined_domain_source_values(section)) {
        let normalized = domain_suffix_condition_value_kind(value);
        if (normalized != null)
            push(result[normalized.kind], normalized.value);
    }

    return result;
}

function add_domain_array(rule, key, values) {
    if (length(values) > 0)
        rule[key] = values;
}

function push_dns_matcher_rule(config, rule) {
    // FakeIP synthesizes addresses only. Other record types must reach a resolver.
    if (rule.server == runtime_constants.FAKEIP_DNS_SERVER_TAG) {
        if (bool_option(runtime_settings(), "whatsapp_real_dns", false)) {
            // Preserve section ordering, source exclusions and explicit DNS actions.
            // Skip only FakeIP synthesis; unmatched queries use dns.final.
            let matchers = {};
            for (let key, value in rule)
                if (key != "action" && key != "server" && key != "rewrite_ttl")
                    matchers[key] = value;
            rule = {
                type: "logical",
                mode: "and",
                rules: [ matchers, {
                    domain_suffix: [ "whatsapp.com", "whatsapp.net", "whatsapp.biz", "wa.me" ],
                    invert: true
                } ],
                action: rule.action,
                server: rule.server,
                rewrite_ttl: rule.rewrite_ttl
            };
        }
        if (rule.type == "logical")
            push(rule.rules, { query_type: [ "A", "AAAA" ] });
        else
            rule.query_type = [ "A", "AAAA" ];
    }
    push(config.dns.rules, rule);
}

function section_dns_server(section) {
    // Domain-only bypass still needs to enter sing-box so its direct route is
    // visible in the connection monitor. Source-aware bypass is handled by
    // add_source_aware_bypass_dns_rules() and fully-routed devices keep their
    // real-address DNS path in add_fully_routed_ips_rules().
    return runtime_constants.FAKEIP_DNS_SERVER_TAG;
}

function single_or_array(values) {
    return length(values) == 1 ? values[0] : values;
}

function copy_dns_matchers(matchers) {
    let copy = {};
    for (let key, value in matchers)
        copy[key] = value;
    return copy;
}

function excluded_source_ip_cidr(section) {
    return legacy_condition_values(section, "excluded_source_ip_cidr");
}

function exclude_sources_from_matchers(matchers, section) {
    let excluded = excluded_source_ip_cidr(section);
    if (length(excluded) == 0)
        return matchers;

    // An unconditional DNS evaluate has no query matchers. Keep only the
    // exclusion instead of placing an empty child in a logical AND rule.
    let exclusion = {
        source_ip_cidr: single_or_array(excluded),
        invert: true
    };
    if (length(matchers) == 0)
        return exclusion;

    return {
        type: "logical",
        mode: "and",
        rules: [
            matchers,
            exclusion
        ]
    };
}

function exclude_sources_from_route_rule(rule, section) {
    let excluded = excluded_source_ip_cidr(section);
    if (length(excluded) == 0)
        return rule;

    let matchers = {};
    let result = {};
    for (let key, value in rule) {
        if (key == "action" || key == "outbound")
            result[key] = value;
        else
            matchers[key] = value;
    }
    let wrapped = exclude_sources_from_matchers(matchers, section);
    for (let key, value in wrapped)
        result[key] = value;
    return result;
}

function add_source_dns_matchers(rule, source_ip_cidr) {
    if (length(source_ip_cidr) == 0)
        return;

    rule.inbound = source_dns_inbound_matcher();
    rule.source_ip_cidr = single_or_array(source_ip_cidr);
}

function add_source_aware_bypass_dns_rules(config, matchers, rewrite_ttl) {
    if (runtime_supports_dns_response_matching) {
        // sing-box 1.14 response matching must inspect the response from the
        // same path that will be returned. Evaluate dnsmasq first, then
        // respond with that accepted non-FakeIP answer below.
        let evaluate = copy_dns_matchers(matchers);
        evaluate.action = "evaluate";
        evaluate.server = runtime_constants.DNSMASQ_DNS_SERVER_TAG;
        push_dns_matcher_rule(config, evaluate);
    }

    let fakeip_matcher = {
        ip_cidr: [ runtime_constants.FAKEIP_INET4_RANGE, runtime_constants.FAKEIP_INET6_RANGE ],
        invert: true
    };
    if (runtime_supports_dns_response_matching)
        fakeip_matcher.match_response = true;

    let filtered_dnsmasq = {
        type: "logical",
        mode: "and",
        rules: [
            copy_dns_matchers(matchers),
            fakeip_matcher
        ]
    };
    if (runtime_supports_dns_response_matching) {
        filtered_dnsmasq.action = "respond";
    }
    else {
        filtered_dnsmasq.action = "route";
        filtered_dnsmasq.server = runtime_constants.DNSMASQ_DNS_SERVER_TAG;
        filtered_dnsmasq.rewrite_ttl = rewrite_ttl;
    }
    push_dns_matcher_rule(config, filtered_dnsmasq);

    let fallback = copy_dns_matchers(matchers);
    fallback.action = "route";
    fallback.server = runtime_constants.DNS_SERVER_TAG;
    fallback.query_type = [ "A", "AAAA" ];
    fallback.rewrite_ttl = rewrite_ttl;
    push_dns_matcher_rule(config, fallback);
}

function add_section_dns_matcher_rule(config, section, matchers, rewrite_ttl) {
    let source_ip_cidr = legacy_condition_values(section, "source_ip_cidr");
    add_source_dns_matchers(matchers, source_ip_cidr);
    matchers = exclude_sources_from_matchers(matchers, section);

    if (option(section, "action", "") == "bypass" && length(source_ip_cidr) > 0) {
        add_source_aware_bypass_dns_rules(config, matchers, rewrite_ttl);
        return;
    }

    matchers.action = "route";
    matchers.server = section_dns_server(section);
    matchers.rewrite_ttl = rewrite_ttl;
    push_dns_matcher_rule(config, matchers);
}

function append_unique(values, additions) {
    let seen = {};
    for (let value in values)
        seen[value] = true;
    for (let value in additions) {
        if (!seen[value]) {
            seen[value] = true;
            push(values, value);
        }
    }
}

function add_response_ruleset_dns_rule(config, section, tags, rewrite_ttl, server_tag) {
    if (length(tags) == 0)
        return;

    let source_ip_cidr = legacy_condition_values(section, "source_ip_cidr");
    let evaluate = {};
    add_source_dns_matchers(evaluate, source_ip_cidr);
    evaluate = exclude_sources_from_matchers(evaluate, section);
    evaluate.action = "evaluate";
    evaluate.server = runtime_constants.DNS_SERVER_TAG;
    push_dns_matcher_rule(config, evaluate);

    let response = {
        rule_set: single_or_array(tags),
        match_response: true
    };
    add_source_dns_matchers(response, source_ip_cidr);
    response = exclude_sources_from_matchers(response, section);
    response.action = "route";
    response.server = server_tag;
    response.rewrite_ttl = rewrite_ttl;
    push_dns_matcher_rule(config, response);
}

function add_section_ruleset_dns_rules(config, section, query_tags, response_tags, rewrite_ttl, server_tag) {
    if (!runtime_supports_dns_response_matching) {
        append_unique(query_tags, response_tags);
        if (length(query_tags) > 0) {
            if (server_tag == section_dns_server(section))
                add_section_dns_matcher_rule(config, section, { rule_set: single_or_array(query_tags) }, rewrite_ttl);
            else {
                let legacy = { rule_set: single_or_array(query_tags), action: "route", server: server_tag, rewrite_ttl };
                add_source_dns_matchers(legacy, legacy_condition_values(section, "source_ip_cidr"));
                push_dns_matcher_rule(config, exclude_sources_from_matchers(legacy, section));
            }
        }
        return;
    }

    if (length(query_tags) > 0) {
        if (server_tag == section_dns_server(section))
            add_section_dns_matcher_rule(config, section, { rule_set: single_or_array(query_tags) }, rewrite_ttl);
        else {
            let query = { rule_set: single_or_array(query_tags), action: "route", server: server_tag, rewrite_ttl };
            add_source_dns_matchers(query, legacy_condition_values(section, "source_ip_cidr"));
            push_dns_matcher_rule(config, exclude_sources_from_matchers(query, section));
        }
    }
    add_response_ruleset_dns_rule(config, section, response_tags, rewrite_ttl, server_tag);
}

function source_aware_dns_sources(sections) {
    let seen = {};
    let values = [];

    for (let section in sections) {
        let action = option(section, "action", "");
        let candidates = [];
        if (connections.has_dns_matchers(section))
            for (let value in legacy_condition_values(section, "source_ip_cidr"))
                push(candidates, value);
        if (connections.has_dns_matchers(section) || length(list_option(section, "fully_routed_ips")) > 0)
            for (let value in excluded_source_ip_cidr(section))
                push(candidates, value);
        if (action == "bypass" || action == "dns")
            for (let value in list_option(section, "fully_routed_ips"))
                push(candidates, value);

        for (let value in candidates) {
            value = trim(as_string(value));
            if (value != "" && !seen[value]) {
                seen[value] = true;
                push(values, value);
            }
        }
    }

    return values;
}

function add_source_aware_dns_support(config, source_ip_cidr) {
    if (length(source_ip_cidr) == 0)
        return;

    push(config.dns.servers, {
        type: "udp",
        tag: runtime_constants.DNSMASQ_DNS_SERVER_TAG,
        server: "127.0.0.1",
        server_port: 53
    });
}

function add_source_aware_dns_fallback(config, source_ip_cidr) {
    if (length(source_ip_cidr) == 0)
        return;

    let rule = {
        action: "route",
        server: runtime_constants.DNSMASQ_DNS_SERVER_TAG,
        rewrite_ttl: int_option(runtime_settings(), "dns_rewrite_ttl", "60")
    };
    add_source_dns_matchers(rule, source_ip_cidr);
    push_dns_matcher_rule(config, rule);
}

function dns_action_server_tag(section_name) {
    return runtime_constants.tag(section_name, "dns-server");
}

function dns_action_detour_tag(section) {
    if (!bool_option(section, "dns_detour_enabled", false))
        return "";
    let target_section = option(section, "dns_detour_section", "");
    return target_section == "" ? "" : outbound_tag(target_section);
}

function add_dns_server_for_section(config, section) {
    let server = runtime_dns.server_from_options(
        dns_action_server_tag(section[".name"]),
        option(section, "dns_type", "udp"),
        option(section, "dns_server", ""),
        dns_action_detour_tag(section)
    );
    if (server.unsupported)
        runtime_generate_unsupported(server.unsupported);
    push(config.dns.servers, server);
}

function add_dns_action_rules_for_section(config, section) {
    let domains = domain_conditions(section);
    let domain = domains.domain;
    let domain_suffix = domains.domain_suffix;
    let domain_keyword = domains.domain_keyword;
    let domain_regex = domains.domain_regex;
    let dns_query_rule_set_tags = [];
    let dns_response_rule_set_tags = [];
    let section_name = section[".name"];
    let source_ip_cidr = legacy_condition_values(section, "source_ip_cidr");
    let fully_routed_ips = list_option(section, "fully_routed_ips");

    for (let community in connections.community_lists(section)) {
        let ensured = ensure_community_ruleset(config, section_name, as_string(community));
        push(ensured.kind == "domains" ? dns_query_rule_set_tags : dns_response_rule_set_tags, ensured.tag);
    }
    for (let reference in connections.rule_sets(section)) {
        let ensured = ensure_custom_ruleset(config, as_string(reference));
        if (ensured.kind == "domains")
            push(dns_query_rule_set_tags, ensured.tag);
        else
            push(dns_response_rule_set_tags, ensured.tag);
    }
    add_remote_list_rulesets(
        config,
        section,
        "remote_domain_lists",
        "domains",
        dns_query_rule_set_tags,
        dns_query_rule_set_tags
    );
    add_domain_ip_list_ruleset(
        config,
        section_name,
        [],
        dns_query_rule_set_tags,
        dns_response_rule_set_tags,
        list_option(section, "domain_ip_lists"),
        true
    );

    let rewrite_ttl = int_option(runtime_settings(), "dns_rewrite_ttl", "60");
    let server_tag = dns_action_server_tag(section_name);
    let has_inline_domains = length(domain) > 0 || length(domain_suffix) > 0 ||
        length(domain_keyword) > 0 || length(domain_regex) > 0;

    if (length(fully_routed_ips) > 0) {
        let dns_rule = {
            action: "route",
            server: server_tag,
            rewrite_ttl
        };
        add_source_dns_matchers(dns_rule, fully_routed_ips);
        dns_rule = exclude_sources_from_matchers(dns_rule, section);
        push_dns_matcher_rule(config, dns_rule);
    }
    if (has_inline_domains) {
        let dns_rule = {
            action: "route",
            server: server_tag,
            rewrite_ttl
        };
        add_domain_array(dns_rule, "domain", domain);
        add_domain_array(dns_rule, "domain_suffix", domain_suffix);
        add_domain_array(dns_rule, "domain_keyword", domain_keyword);
        add_domain_array(dns_rule, "domain_regex", domain_regex);
        add_source_dns_matchers(dns_rule, source_ip_cidr);
        dns_rule = exclude_sources_from_matchers(dns_rule, section);
        push_dns_matcher_rule(config, dns_rule);
    }
    add_section_ruleset_dns_rules(config, section, dns_query_rule_set_tags, dns_response_rule_set_tags, rewrite_ttl, server_tag);
    if (!has_inline_domains && length(dns_query_rule_set_tags) == 0 && length(dns_response_rule_set_tags) == 0 && length(fully_routed_ips) == 0)
        runtime_generate_unsupported("DNS action '" + section_name + "' has no domain matchers");
}

function normalize_port_number_value(value) {
    return rule_config.normalize_port_number_value(value);
}

function add_port_matchers(rule, section) {
    let values = [];
    for (let value in list_option(section, "ports"))
        push(values, value);
    for (let value in rule_config.text_list_values(option(section, "ports_text", ""), "comma-space"))
        push(values, value);

    let ports = [];
    let port_ranges = [];
    let seen = {};
    for (let value in values) {
        value = trim(as_string(value));
        if (value == "" || seen[value])
            continue;
        seen[value] = true;

        let dash = index(value, "-");
        if (dash < 0) {
            let port = normalize_port_number_value(value);
            if (port != null)
                push(ports, port);
            continue;
        }

        let start = normalize_port_number_value(substr(value, 0, dash));
        let end = normalize_port_number_value(substr(value, dash + 1));
        if (start != null && end != null && start <= end)
            push(port_ranges, start == end ? as_string(start) : sprintf("%d:%d", start, end));
    }

    if (length(ports) > 0)
        rule.port = ports;
    if (length(port_ranges) > 0)
        rule.port_range = port_ranges;
}

function add_fully_routed_ips_rules(config, section) {
    let source_ip_cidr = list_option(section, "fully_routed_ips");
    if (length(source_ip_cidr) == 0)
        return;

    if (option(section, "action", "") == "bypass") {
        let dns_matchers = {};
        add_source_dns_matchers(dns_matchers, source_ip_cidr);
        add_source_aware_bypass_dns_rules(
            config,
            dns_matchers,
            int_option(runtime_settings(), "dns_rewrite_ttl", "60")
        );
    }

    let target = runtime_route.target(section, outbound_tag(section[".name"]));
    if (target.unsupported)
        runtime_generate_unsupported(target.unsupported);

    let route_rule = {
        action: target.action,
        inbound: tproxy_inbound_matcher()
    };
    if (target.outbound)
        route_rule.outbound = target.outbound;
    route_rule.source_ip_cidr = single_or_array(source_ip_cidr);
    let quic_rule = runtime_route.quic_rule(runtime_settings(), section, route_rule);
    if (quic_rule != null)
        push(config.route.rules, exclude_sources_from_route_rule(quic_rule, section));
    push(config.route.rules, exclude_sources_from_route_rule(route_rule, section));
}

function push_section_route_rule(config, section, route_rule) {
    let resolve = runtime_route.resolve_rule_for_section(section, route_rule);
    if (type(resolve) == "object" && resolve.warning)
        warn(resolve.warning, "\n");
    else if (type(resolve) == "object" && resolve.rule)
        push(config.route.rules, exclude_sources_from_route_rule(resolve.rule, section));
    let quic_rule = runtime_route.quic_rule(runtime_settings(), section, route_rule);
    if (quic_rule != null)
        push(config.route.rules, exclude_sources_from_route_rule(quic_rule, section));
    push(config.route.rules, exclude_sources_from_route_rule(route_rule, section));
}

function add_combined_route_for_section(config, section) {
    let domains = domain_conditions(section);
    let domain = domains.domain;
    let domain_suffix = domains.domain_suffix;
    let domain_keyword = domains.domain_keyword;
    let domain_regex = domains.domain_regex;
    let ip_cidr = legacy_condition_values(section, "ip_cidr");
    let source_ip_cidr = legacy_condition_values(section, "source_ip_cidr");
    let rule_set_tags = [];
    let dns_query_rule_set_tags = [];
    let dns_response_rule_set_tags = [];
    let section_name = section[".name"];

    add_fully_routed_ips_rules(config, section);

    for (let community in connections.community_lists(section)) {
        let ensured = ensure_community_ruleset(config, section_name, as_string(community));
        push(rule_set_tags, ensured.tag);
        push(ensured.kind == "domains" ? dns_query_rule_set_tags : dns_response_rule_set_tags, ensured.tag);
    }
    if (length(connections.community_lists(section)) > 0) {
        let subnet_tag = section_name + "-community-subnets-lists-ruleset";
        let subnet_path = runtime_ruleset_folder + "/" + subnet_tag + ".json";
        let subnets = read_json_file(subnet_path);
        if (bool_option(runtime_settings(), "whatsapp_real_dns", false) &&
            index(connections.community_lists(section), "meta") >= 0 &&
            (type(subnets) != "object" || type(subnets.rules) != "array" || length(subnets.rules) == 0))
            runtime_generate_unsupported("WhatsApp real DNS requires downloaded Meta subnet rules for '" + section_name + "'");
        if (type(subnets) == "object" && type(subnets.rules) == "array") {
            if (length(subnets.rules) == 0 && index(connections.community_lists(section), "discord") >= 0)
                runtime_generate_unsupported("Discord subnet ruleset for '" + section_name + "' is empty; download the lists before starting");
            if (length(subnets.rules) > 0) {
                push(config.route.rule_set, { type: "local", tag: subnet_tag, format: "source", path: subnet_path });
                push(rule_set_tags, subnet_tag);
            }
        }
        else if (fs.stat(subnet_path) != null)
            runtime_generate_unsupported("community subnet ruleset for '" + section_name + "' is invalid");
        else if (index(connections.community_lists(section), "discord") >= 0)
            runtime_generate_unsupported("Discord subnet ruleset for '" + section_name + "' is missing; download the lists before starting");
    }
    for (let reference in connections.rule_sets(section)) {
        let ensured = ensure_custom_ruleset(config, as_string(reference));
        push(rule_set_tags, ensured.tag);
        if (ensured.kind == "domains")
            push(dns_query_rule_set_tags, ensured.tag);
        else
            push(dns_response_rule_set_tags, ensured.tag);
    }
    for (let reference in connections.rule_sets_with_subnets(section)) {
        let ensured = ensure_custom_ruleset(config, as_string(reference));
        push(rule_set_tags, ensured.tag);
        if (ensured.kind == "domains")
            push(dns_query_rule_set_tags, ensured.tag);
        else
            push(dns_response_rule_set_tags, ensured.tag);
    }
    add_remote_list_rulesets(
        config,
        section,
        "remote_domain_lists",
        "domains",
        rule_set_tags,
        dns_query_rule_set_tags
    );
    add_remote_list_rulesets(
        config,
        section,
        "remote_subnet_lists",
        "subnets",
        rule_set_tags,
        null
    );
    add_domain_ip_list_ruleset(
        config,
        section_name,
        rule_set_tags,
        dns_query_rule_set_tags,
        dns_response_rule_set_tags,
        list_option(section, "domain_ip_lists"),
        false
    );

    let target = runtime_route.target(section, outbound_tag(section_name));
    if (target.unsupported)
        runtime_generate_unsupported(target.unsupported);
    let route_rule = {
        action: target.action,
        inbound: tproxy_inbound_matcher()
    };
    if (target.outbound)
        route_rule.outbound = target.outbound;
    add_domain_array(route_rule, "domain", domain);
    add_domain_array(route_rule, "domain_suffix", domain_suffix);
    add_domain_array(route_rule, "domain_keyword", domain_keyword);
    add_domain_array(route_rule, "domain_regex", domain_regex);
    if (length(ip_cidr) > 0)
        route_rule.ip_cidr = ip_cidr;
    if (length(source_ip_cidr) > 0)
        route_rule.source_ip_cidr = source_ip_cidr;
    add_port_matchers(route_rule, section);
    let has_route_matchers = route_rule.domain != null || route_rule.domain_suffix != null ||
        route_rule.domain_keyword != null || route_rule.domain_regex != null ||
        route_rule.ip_cidr != null || (length(rule_set_tags) == 0 &&
        (route_rule.port != null || route_rule.port_range != null));
    if (has_route_matchers)
        push_section_route_rule(config, section, route_rule);

    if (length(rule_set_tags) > 0) {
        // Since sing-box 1.14 a rule-set containing more than one rule is an
        // independent matcher.  Combining it with inline domain fields makes
        // the two matchers an AND expression, while Forkop sections define
        // inline domains and lists as alternatives.  Keep shared device and
        // port filters, but emit the rule-set alternative as its own rule.
        let rule_set_rule = {
            action: target.action,
            inbound: tproxy_inbound_matcher(),
            rule_set: null
        };
        if (target.outbound)
            rule_set_rule.outbound = target.outbound;
        if (length(source_ip_cidr) > 0)
            rule_set_rule.source_ip_cidr = source_ip_cidr;
        add_port_matchers(rule_set_rule, section);
        // Separate equivalent alternatives so Clash connection metadata names
        // the actual matching list instead of every list in the section.
        for (let tag_name in rule_set_tags) {
            let alternative = {};
            for (let key, value in rule_set_rule)
                alternative[key] = value;
            alternative.rule_set = tag_name;
            push_section_route_rule(config, section, alternative);
        }
    }

    let rewrite_ttl = int_option(runtime_settings(), "dns_rewrite_ttl", "60");
    if (length(domain) > 0 || length(domain_suffix) > 0 || length(domain_keyword) > 0 || length(domain_regex) > 0) {
        let dns_rule = {};
        add_domain_array(dns_rule, "domain", domain);
        add_domain_array(dns_rule, "domain_suffix", domain_suffix);
        add_domain_array(dns_rule, "domain_keyword", domain_keyword);
        add_domain_array(dns_rule, "domain_regex", domain_regex);
        add_section_dns_matcher_rule(config, section, dns_rule, rewrite_ttl);
    }
    add_section_ruleset_dns_rules(
        config,
        section,
        dns_query_rule_set_tags,
        dns_response_rule_set_tags,
        rewrite_ttl,
        section_dns_server(section)
    );
}

function unsupported_matcher_key(section) {
    let unsupported_options = [
        "subnet", "subnet_text",
        "local_domain_lists", "local_subnet_lists"
    ];
    for (let key in unsupported_options) {
        if (length(list_option(section, key)) > 0 || option(section, key, "") != "")
            return key;
    }
    return "";
}

function add_outbound_for_section(config, section, taken, sections) {
    let action = option(section, "action", "");
    let section_name = section[".name"];
    if (!valid_section_name(section_name))
        runtime_generate_unsupported("section name is not safe for sing-box config generation");
    let unsupported_matcher = unsupported_matcher_key(section);
    if (unsupported_matcher != "")
        runtime_generate_unsupported("section has unsupported matcher " + unsupported_matcher);

    if (connections.is_connections_action(action))
        add_connections_outbound(config, section, taken);
    else if (action == "zapret")
        add_zapret_outbound(config, section, sections);
    else if (action == "zapret2")
        add_zapret2_outbound(config, section, sections);
    else if (action == "bypass") {
        /* route-only action */
    }
    else if (action == "block") {
        /* route-only action */
    }
    else if (action == "dns") {
        add_dns_server_for_section(config, section);
    }
    else {
        runtime_generate_unsupported("unsupported action " + action);
    }
}

function reserve_section_outbound_tags(sections, taken) {
    for (let section in sections) {
        let action = option(section, "action", "");
        if (connections.is_connections_action(action) ||
            action == "zapret" || action == "zapret2")
            taken[outbound_tag(section[".name"])] = true;

        if (!connections.is_connections_action(action))
            continue;

        for (let urltest_id in connections.urltests(section))
            taken[urltest_outbound_tag(section[".name"], urltest_id)] = true;
        for (let group_id in connections.priority_groups(section))
            taken[priority_outbound_tag(section[".name"], group_id)] = true;
    }
}

function add_route_for_section(config, section) {
    if (option(section, "action", "") == "dns")
        add_dns_action_rules_for_section(config, section);
    else
        add_combined_route_for_section(config, section);
}

function service_route_check_section(sections) {
    for (let section in sections) {
        let action = option(section, "action", "");
        // Public-IP comparison is meaningful only for a remote proxy/VPN.
        // DPI bypass providers keep the direct public IP, which made a valid
        // FakeIP setup look inconclusive whenever one preceded a connection.
        if (connections.is_connections_action(action))
            return section;
    }

    return null;
}

function add_service_route_rules(config, sections) {
    let first = service_route_check_section(sections);
    if (first != null) {
        push(config.route.rules, {
            action: "route",
            inbound: tproxy_inbound_matcher(),
            outbound: outbound_tag(first[".name"]),
            domain: runtime_constants.CHECK_PROXY_IP_DOMAIN
        });
    }
    push(config.route.rules, {
        action: "route-options",
        domain: runtime_constants.FAKEIP_TEST_DOMAIN,
        override_port: 8443
    });
}

function deferred_section_set(value) {
    let result = {};
    for (let name in split(trim(as_string(value)), /[ \t\r\n]+/)) {
        name = as_string(name);
        if (name != "")
            result[name] = true;
    }
    return result;
}

function enabled_sections(deferred_sections) {
    let deferred = deferred_section_set(deferred_sections);
    let result = [];
    uci_cursor().foreach(CONFIG_NAME, "section", function(section) {
        if (section_enabled(section) && !deferred[as_string(section[".name"])])
            push(result, section);
    });
    return result;
}

function generate_config(output_path, service_address, mwan3_active, supports_xhttp, deferred_sections, sing_box_version, supports_trojan) {
    runtime_prunable_outbounds = {};
    runtime_skipped_protocol_outbounds = {};
    // Verified for Xrust; Go X 1.0.4 and Extended 2.7.2 do not support this
    // whole-certificate pin. Never substitute an SPKI pin or remove the pin.
    runtime_supports_certificate_pins = rust_x_core_version(sing_box_version);
    // Xrust is built without vmess, shadowsocks and socks outbounds; only
    // builds declaring outbound.trojan include the Trojan client.
    runtime_supports_legacy_protocols = !rust_x_core_version(sing_box_version);
    runtime_supports_trojan = cli_bool(supports_trojan);
    runtime_supports_all_fingerprints = !rust_x_core_version(sing_box_version);
    runtime_supports_vless_encryption = !rust_x_core_version(sing_box_version);
    runtime_supports_reality_mldsa65 = !rust_x_core_version(sing_box_version);
    runtime_supports_xhttp = supports_xhttp == null || as_string(supports_xhttp) == ""
        ? true
        : cli_bool(supports_xhttp);
    let cursor = uci_cursor();
    cursor.load(CONFIG_NAME);
    runtime_settings_cache = object_or_empty(cursor.get_all(CONFIG_NAME, "settings"));
    let settings = runtime_settings_cache;

    let sections = enabled_sections(deferred_sections);
    if (length(sections) == 0 && trim(as_string(deferred_sections)) == "")
        runtime_generate_unsupported("no enabled sections");

    let bootstrap_lists = getenv("FORKOP_LIFECYCLE_LIST_BOOTSTRAP") == "1";
    let source_aware_dns = bootstrap_lists ? [] : source_aware_dns_sources(sections);
    let config = base_config(settings, service_address, {
        core_version: sing_box_version,
        mwan3_active: cli_bool(mwan3_active),
        source_aware_dns: length(source_aware_dns) > 0
    });
    if (bool_option(settings, "whatsapp_real_dns", false))
        config.dns.reverse_mapping = true;
    let version_parts = match(as_string(sing_box_version), /^v?([0-9]+)\.([0-9]+)\./);
    runtime_supports_dns_response_matching = version_parts != null &&
        (int(version_parts[1]) > 1 || (int(version_parts[1]) == 1 && int(version_parts[2]) >= 14));
    if (version_parts != null && (int(version_parts[1]) > 1 ||
        (int(version_parts[1]) == 1 && int(version_parts[2]) >= 14)))
        delete config.dns.independent_cache;
    add_source_aware_dns_support(config, source_aware_dns);
    let taken = reserved_runtime_tag_set(config.outbounds);
    reserve_section_outbound_tags(sections, taken);
    for (let section in sections)
        add_outbound_for_section(config, section, taken, sections);
    if (bootstrap_lists) {
        // Only the selected connection is exposed locally. No list-dependent
        // routes, traffic interception, DNS listener or shared runtime cache.
        config.inbounds = [];
        config.route.rules = [];
        delete config.route.rule_set;
        config.dns.rules = [];
        delete config.experimental;
        let target = download_detour_tag(settings, "lists");
        let found = false;
        for (let outbound in config.outbounds)
            if (outbound.tag == target)
                found = true;
        if (target == "" || !found)
            runtime_generate_unsupported("list download section has no usable connection");
        add_global_download_service_mixed_proxy(config, settings, "lists");
    }
    else {
        add_direct_proxy(config, settings, service_address);
        add_service_route_rules(config, sections);
        for (let section in sections)
            add_route_for_section(config, section);
        add_source_aware_dns_fallback(config, source_aware_dns);
        add_service_mixed_proxy(config, settings, sections);
        for (let section in sections)
            add_mixed_proxy_for_section(config, section, service_address);
    }

    assert_unique_outbound_tags(config);
    outbound_reachability.prune(config, runtime_prunable_outbounds);
    strip_internal_fields(config);
    if (!write_json_file(output_path, config)) {
        warn("failed to write ", output_path, "\n");
        exit(1);
    }
}

function generate_config_fixture(fixture_path, output_path, service_address, mwan3_active, supports_xhttp, deferred_sections, sing_box_version, supports_trojan) {
    use_fixture_cursor(fixture_path);
    runtime_subscription.set_section_cache_dir(output_path + ".section-cache");
    runtime_ruleset_folder = output_path + ".rulesets";
    generate_config(output_path, service_address, mwan3_active, supports_xhttp, deferred_sections, sing_box_version, supports_trojan);
}

function stdin_contains(needle) {
    return index(read_stdin(), as_string(needle)) >= 0;
}

function ip_addr_first_inet4() {
    for (let line in split(read_stdin(), "\n")) {
        let fields = split(trim(as_string(line)), /[ \t]+/);
        if (length(fields) < 2 || fields[0] != "inet")
            continue;

        let slash = index(fields[1], "/");
        print(slash >= 0 ? substr(fields[1], 0, slash) : fields[1], "\n");
        return;
    }
}

function stdin_first_field() {
    let data = read_stdin();
    let newline = index(data, "\n");
    let line = newline >= 0 ? substr(data, 0, newline) : data;
    let fields = split(trim(as_string(line)), /[ \t\r\n]+/);

    if (length(fields) > 0 && fields[0] != "")
        print(fields[0], "\n");
}

function normalized_country_list() {
    write_json(runtime_urltest.normalized_country_list(read_stdin_json()));
}

function service_route_check_section_fixture() {
    let section = service_route_check_section(array_or_empty(read_stdin_json()));
    if (section != null)
        print(as_string(section[".name"]), "\n");
}

let mode = ARGV[0] || "";

if (mode == "generate-config")
    generate_config(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5] || "", ARGV[6] || "", ARGV[7] || "");
else if (mode == "generate-config-fixture")
    generate_config_fixture(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6] || "", ARGV[7] || "", ARGV[8] || "");
else if (mode == "stdin-contains")
    exit(stdin_contains(ARGV[1]) ? 0 : 1);
else if (mode == "csv-to-json-array")
    csv_to_json_array(ARGV[1]);
else if (mode == "ip-addr-first-inet4")
    ip_addr_first_inet4();
else if (mode == "stdin-first-field")
    stdin_first_field();
else if (mode == "service-route-check-section-fixture")
    service_route_check_section_fixture();
else {
    warn("Usage: singbox/generator.uc <operation> ...\n");
    exit(1);
}
