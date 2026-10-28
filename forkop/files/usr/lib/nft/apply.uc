#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let core_ip = require("core.ip");
let uci_core = require("core.uci");
let rule_config = require("config.rule");
let domain_config = require("config.domain");
let connections = require("config.connections");
let routing_rulesets = require("routing.rulesets");
let runtime_constants = require("singbox.constants");
const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
const DNS_SOURCE_SET = "forkop_dns_sources";
const DNS_SOURCE6_SET = "forkop_dns_sources6";
const NFT_BATCH_FILE = getenv("FORKOP_NFT_BATCH_FILE") || "";
// Test-only candidate failure injection. Empty in production.
const NFT_CANDIDATE_FAIL_PHASE = getenv("FORKOP_NFT_CANDIDATE_FAIL_PHASE") || "";
const NFT_TRANSITION_GUARD_CHAIN = "forkop_transition_guard";
// A reply packet answers a connection the other side opened, or one the core
// already holds. Marked and handed to TPROXY it finds no socket of its own,
// so the connection dies; download traffic stops walking the chain here too.
const REPLY_RETURN = [ "ct", "direction", "reply", "return" ];
// What the router itself sends to the core. The default mirrors
// core/constants.uc: a mark of its own keeps the source-check rule at
// priority 103 away from the rerouting lookup of a locally generated packet.
const ROUTER_MARK = getenv("NFT_ROUTER_MARK") || "0x10000000";
// The rule that answers the kernel's source check, before the TPROXY rules at
// 105. Upstream puts it at 104; here that priority belongs to the Tailscale
// exit-node LAN rule, whose own setup refuses to run beside a foreign 104.
const SOURCE_CHECK_PRIORITY = "103";
const RT_TABLES_FILE = getenv("FORKOP_RT_TABLES_FILE") || "/etc/iproute2/rt_tables";

const IPV6_TPROXY_ENABLED = core_ip.ipv6_tproxy_enabled();

let common_read_json_file = common.read_json_file;
let list_option = common.list_option;
let bool_option = common.bool_option;

function as_string(value) {
    return value == null ? "" : "" + value;
}

function arg_bool(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes";
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function option(section, key, fallback) {
    if (fallback == null)
        fallback = "";

    let value = object_or_empty(section)[key];
    if (value == null)
        return fallback;
    if (type(value) == "array")
        return join(" ", value);
    return as_string(value);
}

function uci_section(section_name) {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, section_name));
}

function uci_sections(type_name) {
    return uci_core.section_objects(CONFIG_NAME, type_name);
}

function uci_settings() {
    return uci_section("settings");
}

function write_compact_string_array(values) {
    print("[");
    for (let i = 0; i < length(values); i++) {
        if (i > 0)
            print(",");
        print(sprintf("%J", as_string(values[i])));
    }
    print("]\n");
}

function write_text_file(path, text) {
    let result = fs.writefile(path, as_string(text));
    if (result == null)
        return false;
    if (type(result) == "boolean" && !result)
        return false;
    return true;
}

function file_executable(path) {
    let stat = fs.stat(as_string(path));
    if (stat == null || stat.mode == null)
        return false;

    return (int(stat.mode) & 73) != 0;
}

function unlink_file(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];

    for (let arg in args)
        push(parts, shell_quote(arg));

    return join(" ", parts);
}

function run_args(args) {
    // nft -f submits a complete file as one netlink transaction. Candidate
    // preparation records mutations instead of exposing partial live state.
    if (NFT_BATCH_FILE != "" && length(args) > 2 && args[0] == "nft" &&
        (args[1] == "add" || args[1] == "insert" || args[1] == "delete" || args[1] == "flush")) {
        if (NFT_CANDIDATE_FAIL_PHASE == "prepare")
            return false;
        let words = [];
        for (let i = 1; i < length(args); i++)
            push(words, args[i]);
        let line = join(" ", words);
        return fs.writefile(NFT_BATCH_FILE, (fs.readfile(NFT_BATCH_FILE) || "") + line + "\n") != null;
    }
    return system(command_from_args(args)) == 0;
}

function run_args_quiet(args) {
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function command_output_from_args(args) {
    let pipe = fs.popen(command_from_args(args), "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";

    return as_string(data);
}

function command_output_quiet_from_args(args) {
    let pipe = fs.popen(command_from_args(args) + " 2>/dev/null", "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";

    return as_string(data);
}

function log_debug(message) {
    run_args([ "logger", "-t", "forkop", "[debug] " + as_string(message) ]);
}

function log_info(message) {
    run_args([ "logger", "-t", "forkop", "[info] " + as_string(message) ]);
}

function log_fatal(message) {
    run_args([ "logger", "-t", "forkop", "[fatal] " + as_string(message) ]);
}

function strip_list_comment(line) {
    line = replace(as_string(line), /[[:space:]]*\/\/.*$/, "");
    return replace(line, /[[:space:]]*#.*$/, "");
}

function print_csv(values) {
    for (let i = 0; i < length(values); i++) {
        if (i > 0)
            print(",");
        print(as_string(values[i]));
    }
    if (length(values) > 0)
        print("\n");
}

function text_list_values(value, separator_mode) {
    let result = [];
    separator_mode = as_string(separator_mode);

    for (let line in split(as_string(value), "\n")) {
        line = strip_list_comment(line);
        line = separator_mode == "comma-space"
            ? replace(line, /[ ,]/g, "\n")
            : replace(line, /,/g, "\n");

        for (let item in split(line, "\n")) {
            item = trim(replace(item, /\r/g, ""));
            if (item != "")
                push(result, item);
        }
    }

    return result;
}

function text_list_to_csv(value, separator_mode) {
    print_csv(text_list_values(value, separator_mode));
}

function csv_to_json_array(value) {
    value = as_string(value);
    if (value == "") {
        print("[]\n");
        return;
    }

    write_compact_string_array(split(value, ","));
}

function nft_ip_or_cidr(value) {
    return core_ip.nft_ip_or_cidr(value);
}

function domain_subnet_line_values(data) {
    let result = [];

    for (let line in split(as_string(data), "\n")) {
        line = trim(replace(strip_list_comment(line), /\r/g, ""));
        if (line != "")
            push(result, line);
    }

    return result;
}

function normalize_domain_subnet_value(value, kind) {
    kind = as_string(kind);
    if (kind == "domains")
        return domain_config.suffix_to_ascii(value);
    if (kind == "subnets")
        return core_ip.valid_ip_or_cidr(value) ? value : null;

    exit(1);
}

function rule_condition_csv_value(key, kind, text_mode, conditions_text_mode, text_value, list_value, combined_text_value, combined_list_value) {
    return rule_config.rule_condition_csv_value(key, kind, text_mode, conditions_text_mode, text_value, list_value, combined_text_value, combined_list_value);
}

function split_domain_subnet_file(path, domains_path, subnets_path) {
    let data = fs.readfile(path);
    if (data == null)
        exit(1);

    let domains = [];
    let subnets = [];

    for (let value in domain_subnet_line_values(data)) {
        let domain = normalize_domain_subnet_value(value, "domains");
        if (domain != null)
            push(domains, domain);
        else if (core_ip.valid_ip_or_cidr(value))
            push(subnets, value);
    }

    if (!write_text_file(domains_path, length(domains) > 0 ? join("\n", domains) + "\n" : ""))
        exit(1);
    if (!write_text_file(subnets_path, length(subnets) > 0 ? join("\n", subnets) + "\n" : ""))
        exit(1);
}

function normalize_port_number_value(value) {
    return rule_config.normalize_port_number_value(value);
}

function normalize_port_condition_value(value) {
    return rule_config.normalize_port_condition_value(value);
}

function normalize_port_range_value(value) {
    return rule_config.normalize_port_range_value(value);
}

function rule_ports_csv_value(list_values, text_value) {
    return rule_config.rule_ports_csv_value(list_values, text_value);
}

function rule_port_values(csv) {
    let result = [];

    for (let item in split(as_string(csv), ",")) {
        if (index(item, "-") >= 0)
            continue;

        let port = normalize_port_number_value(item);
        if (port != null)
            push(result, port);
    }

    return result;
}

function rule_port_ranges(csv) {
    let result = [];

    for (let item in split(as_string(csv), ",")) {
        if (index(item, "-") < 0)
            continue;

        let range = normalize_port_range_value(item);
        if (range != null)
            push(result, range);
    }

    return result;
}

function nft_create_table(name) {
    return run_args([ "nft", "add", "table", "inet", name ]);
}

function nft_create_set(table, name, definition) {
    return run_args([ "nft", "add", "set", "inet", table, name, definition ]);
}

function nft_create_ipv4_set(table, name) {
    return nft_create_set(table, name, "{ type ipv4_addr; flags interval; auto-merge; }");
}

function nft_create_ipv6_set(table, name) {
    return nft_create_set(table, name, "{ type ipv6_addr; flags interval; auto-merge; }");
}

function nft_create_inet_service_set(table, name) {
    return nft_create_set(table, name, "{ type inet_service; flags interval; auto-merge; }");
}

function nft_create_ipv4_port_set(table, name) {
    return nft_create_set(table, name, "{ type ipv4_addr . inet_service; flags interval; auto-merge; }");
}

function nft_create_ipv6_port_set(table, name) {
    return nft_create_set(table, name, "{ type ipv6_addr . inet_service; flags interval; auto-merge; }");
}

function nft_create_ifname_set(table, name) {
    return nft_create_set(table, name, "{ type ifname; flags interval; }");
}

function nft_add_set_elements(table, set_name, elements) {
    return run_args([ "nft", "add", "element", "inet", table, set_name, "{ " + as_string(elements) + " }" ]);
}

function whitespace_values(value) {
    let result = [];

    for (let item in split(replace(as_string(value), /[[:space:]]+/g, " "), " ")) {
        item = trim(item);
        if (item != "")
            push(result, item);
    }

    return result;
}

function nft_create_chain(table, name, definition) {
    return run_args([ "nft", "add", "chain", "inet", table, name, definition ]);
}

function nft_add_rule(table, chain, args) {
    // All family-specific IPv6 interception rules use the ip6 expression,
    // including priority rules and the IPv6 TPROXY target.
    if (!IPV6_TPROXY_ENABLED && index(args, "ip6") >= 0)
        return true;
    let command = [ "nft", "add", "rule", "inet", table, chain ];
    for (let arg in args)
        push(command, arg);
    return run_args(command);
}

function nft_insert_rule(table, chain, args) {
    if (!IPV6_TPROXY_ENABLED && index(args, "ip6") >= 0)
        return true;
    let command = [ "nft", "insert", "rule", "inet", table, chain ];
    for (let arg in args)
        push(command, arg);
    return run_args(command);
}

let LOCALV4_RANGES = [
    "0.0.0.0/8",
    "10.0.0.0/8",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.0.0.0/24",
    "192.0.2.0/24",
    "192.88.99.0/24",
    "192.168.0.0/16",
    "198.51.100.0/24",
    "203.0.113.0/24",
    "224.0.0.0/4",
    "240.0.0.0-255.255.255.255"
];

let LOCALV6_RANGES = [
    "::/128",
    "::1/128",
    "64:ff9b::/96",
    "100::/64",
    "2001:db8::/32",
    "fc00::/7",
    "fe80::/10",
    "ff00::/8"
];

function default_arg(value, fallback) {
    value = as_string(value);
    return value == "" ? fallback : value;
}

function combined_domain_condition_text(section) {
    if (type(object_or_empty(section)["domain"]) != "array") {
        let value = option(section, "domain", "");
        if (value != "")
            return value;
    }

    return option(section, "domain_suffix_text", "");
}

function section_rule_condition_csv(section, key, kind) {
    return rule_condition_csv_value(
        key,
        kind,
        option(section, key + "_text_mode", "0"),
        option(section, "conditions_text_mode", "0"),
        option(section, key + "_text", ""),
        option(section, key, ""),
        combined_domain_condition_text(section),
        option(section, "domain_suffix", "")
    );
}

function section_rule_ports_csv(section) {
    return rule_ports_csv_value(option(section, "ports", ""), option(section, "ports_text", ""));
}

function section_option_nonempty(section, key) {
    return option(section, key, "") != "";
}

function section_has_destination_matchers(section) {
    return section_rule_condition_csv(section, "domain", "domains") != "" ||
        section_rule_condition_csv(section, "domain_suffix", "domains") != "" ||
        section_rule_condition_csv(section, "domain_keyword", "generic") != "" ||
        section_rule_condition_csv(section, "domain_regex", "generic") != "" ||
        section_rule_condition_csv(section, "ip_cidr", "subnets") != "" ||
        length(connections.community_lists(section)) > 0 ||
        length(connections.rule_sets(section)) > 0 ||
        length(connections.rule_sets_with_subnets(section)) > 0 ||
        section_option_nonempty(section, "domain_ip_lists");
}

function section_action(section) {
    return option(section, "action", "");
}

function action_captures_traffic(action) {
    return action == "connection" || action == "proxy" || action == "outbound" || action == "vpn" ||
        action == "block";
}

function section_priority_action(section) {
    let action = section_action(section);
    if (action == "bypass")
        return "bypass";
    if (action_captures_traffic(action))
        return "capture";
    return "";
}

function section_priority_prefix(section) {
    return "forkop_rule_" + as_string(section[".name"]);
}

function section_priority_sets(section) {
    let prefix = section_priority_prefix(section);
    return {
        subnets: prefix + "_subnets",
        subnets6: prefix + "_subnets6",
        ports: prefix + "_ports",
        ip_ports: prefix + "_ip_ports",
        ip6_ports: prefix + "_ip6_ports",
        udp_ip_ports: prefix + "_udp_ip_ports",
        udp_ip6_ports: prefix + "_udp_ip6_ports",
        tcp_ip_ports: prefix + "_tcp_ip_ports",
        tcp_ip6_ports: prefix + "_tcp_ip6_ports",
        sources: prefix + "_sources",
        sources6: prefix + "_sources6",
        excluded_sources: prefix + "_excluded_sources",
        excluded_sources6: prefix + "_excluded_sources6",
        fully_sources: prefix + "_fully_sources",
        fully_sources6: prefix + "_fully_sources6"
    };
}

function section_source_ip_values(section) {
    return section_rule_condition_csv(section, "source_ip_cidr", "subnets");
}

function section_has_source_ip_matchers(section) {
    return section_source_ip_values(section) != "";
}

function section_excluded_source_ip_values(section) {
    return section_rule_condition_csv(section, "excluded_source_ip_cidr", "subnets");
}

function section_has_excluded_source_ip_matchers(section) {
    return section_excluded_source_ip_values(section) != "";
}

function section_has_fully_routed_ips(section) {
    return length(list_option(section, "fully_routed_ips")) > 0;
}

function section_has_subnet_update_sources(section) {
    return rule_config.has_community_subnet_list(connections.community_lists_value(section)) ||
        option(section, "remote_subnet_lists", "") != "" ||
        length(connections.rule_sets_with_subnets(section)) > 0 ||
        option(section, "domain_ip_lists", "") != "";
}

function section_has_nft_ip_matchers(section) {
    return section_rule_condition_csv(section, "ip_cidr", "subnets") != "" ||
        section_has_subnet_update_sources(section);
}

function section_has_nft_port_only_matchers(section) {
    return section_rule_ports_csv(section) != "" && !section_has_destination_matchers(section);
}

function section_priority_needs_plain_ip_rules(section) {
    return section_has_nft_ip_matchers(section) && section_rule_ports_csv(section) == "";
}

function section_priority_needs_ip_port_rules(section) {
    return section_has_nft_ip_matchers(section) &&
        (section_rule_ports_csv(section) != "" || length(connections.rule_sets_with_subnets(section)) > 0);
}

function section_priority_needs_udp_ip_port_rules(section) {
    if (length(connections.rule_sets_with_subnets(section)) > 0)
        return true;
    if (!bool_option(section, "community_subnets", true))
        return false;
    for (let community in connections.community_lists(section))
        if (as_string(community) == "discord")
            return true;
    return false;
}

function section_needs_priority_sets(section) {
    return section_priority_action(section) != "" &&
        (section_has_fully_routed_ips(section) || section_has_nft_ip_matchers(section) || section_has_nft_port_only_matchers(section));
}

function nft_create_priority_chains(table) {
    return nft_create_chain(table, "priority_rules", "{ }") &&
        nft_create_chain(table, "priority_output_rules", "{ }") &&
        nft_add_rule(table, "priority_output_rules", [ "meta", "mark", "!=", "0", "return" ]);
}

function nft_create_priority_sets(table, sets) {
    return nft_create_ipv4_set(table, sets.subnets) &&
        nft_create_ipv6_set(table, sets.subnets6) &&
        nft_create_inet_service_set(table, sets.ports) &&
        nft_create_ipv4_port_set(table, sets.ip_ports) &&
        nft_create_ipv6_port_set(table, sets.ip6_ports) &&
        nft_create_ipv4_port_set(table, sets.udp_ip_ports) &&
        nft_create_ipv6_port_set(table, sets.udp_ip6_ports) &&
        nft_create_ipv4_port_set(table, sets.tcp_ip_ports) &&
        nft_create_ipv6_port_set(table, sets.tcp_ip6_ports) &&
        nft_create_ipv4_set(table, sets.sources) &&
        nft_create_ipv6_set(table, sets.sources6) &&
        nft_create_ipv4_set(table, sets.excluded_sources) &&
        nft_create_ipv6_set(table, sets.excluded_sources6) &&
        nft_create_ipv4_set(table, sets.fully_sources) &&
        nft_create_ipv6_set(table, sets.fully_sources6);
}

function nft_priority_verdict_args(priority_action, mark) {
    if (priority_action == "bypass")
        return [ "counter", "accept" ];
    return [ "meta", "l4proto", "{ tcp, udp }", "meta", "mark", "set", mark, "counter", "accept" ];
}

function append_array(target, additions) {
    for (let item in additions)
        push(target, item);
    return target;
}

function nft_source_match_args(section, family, sets) {
    let args = [];
    if (section_has_source_ip_matchers(section))
        append_array(args, family == 6
            ? [ "ip6", "saddr", "@" + as_string(sets.sources6) ]
            : [ "ip", "saddr", "@" + as_string(sets.sources) ]);
    if (section_has_excluded_source_ip_matchers(section))
        append_array(args, family == 6
            ? [ "ip6", "saddr", "!=", "@" + as_string(sets.excluded_sources6) ]
            : [ "ip", "saddr", "!=", "@" + as_string(sets.excluded_sources) ]);
    return args;
}

function nft_priority_rule_args(section, family, local_set, match_args, mark) {
    let sets = section_priority_sets(section);
    let args = [];
    if (family == 4)
        append_array(args, nft_source_match_args(section, 4, sets));
    else
        append_array(args, nft_source_match_args(section, 6, sets));
    append_array(args, [ family == 6 ? "ip6" : "ip", "daddr", "!=", "@" + as_string(local_set) ]);
    append_array(args, match_args);
    append_array(args, nft_priority_verdict_args(section_priority_action(section), mark));
    return args;
}

function nft_priority_prerouting_args(section, family, interface_set, local_set, match_args, mark) {
    // priority_rules is reached only after mangle's client-interface guard.
    return nft_priority_rule_args(section, family, local_set, match_args, mark);
}

function nft_add_priority_rule_pair(table, chain, section, interface_set, localv4_set, localv6_set, match4, match6, mark) {
    if (chain == "priority_rules") {
        return nft_add_rule(table, chain, nft_priority_prerouting_args(section, 4, interface_set, localv4_set, match4, mark)) &&
            nft_add_rule(table, chain, nft_priority_prerouting_args(section, 6, interface_set, localv6_set, match6, mark));
    }

    // priority_output_rules only ever sees what the router itself sends.
    return nft_add_rule(table, chain, nft_priority_rule_args(section, 4, localv4_set, match4, ROUTER_MARK)) &&
        nft_add_rule(table, chain, nft_priority_rule_args(section, 6, localv6_set, match6, ROUTER_MARK));
}

function nft_fully_routed_priority_args(section, family, interface_set, local_set, fakeip_range, protocol, mark) {
    let sets = section_priority_sets(section);
    let ip_key = family == 6 ? "ip6" : "ip";
    let source_set = family == 6 ? sets.fully_sources6 : sets.fully_sources;
    let args = [
        ip_key, "saddr", "@" + as_string(source_set),
        ip_key, "daddr", "!=", "@" + as_string(local_set)
    ];

    if (section_has_excluded_source_ip_matchers(section))
        append_array(args, [ ip_key, "saddr", "!=", "@" + as_string(family == 6 ? sets.excluded_sources6 : sets.excluded_sources) ]);

    if (section_priority_action(section) == "bypass")
        append_array(args, [ ip_key, "daddr", "!=", fakeip_range ]);
    if (as_string(protocol) != "")
        append_array(args, [ "meta", "l4proto", protocol ]);
    append_array(args, nft_priority_verdict_args(section_priority_action(section), mark));
    return args;
}

function nft_add_fully_routed_priority_rules(table, section, interface_set, localv4_set, localv6_set, mark, fakeip_range, fakeip6_range) {
    if (!section_has_fully_routed_ips(section))
        return true;

    if (section_priority_action(section) == "bypass") {
        return nft_add_rule(table, "priority_rules", nft_fully_routed_priority_args(section, 4, interface_set, localv4_set, fakeip_range, "", mark)) &&
            nft_add_rule(table, "priority_rules", nft_fully_routed_priority_args(section, 6, interface_set, localv6_set, fakeip6_range, "", mark));
    }

    return nft_add_rule(table, "priority_rules", nft_fully_routed_priority_args(section, 4, interface_set, localv4_set, fakeip_range, "tcp", mark)) &&
        nft_add_rule(table, "priority_rules", nft_fully_routed_priority_args(section, 4, interface_set, localv4_set, fakeip_range, "udp", mark)) &&
        nft_add_rule(table, "priority_rules", nft_fully_routed_priority_args(section, 6, interface_set, localv6_set, fakeip6_range, "tcp", mark)) &&
        nft_add_rule(table, "priority_rules", nft_fully_routed_priority_args(section, 6, interface_set, localv6_set, fakeip6_range, "udp", mark));
}

function nft_add_section_priority_rules(table, section, interface_set, localv4_set, localv6_set, mark, fakeip_range, fakeip6_range) {
    if (!section_needs_priority_sets(section))
        return true;

    fakeip_range = default_arg(fakeip_range, "198.18.0.0/15");
    fakeip6_range = default_arg(fakeip6_range, "fc00::/18");

    let sets = section_priority_sets(section);
    if (!nft_create_priority_sets(table, sets))
        return false;

    if (!nft_add_fully_routed_priority_rules(table, section, interface_set, localv4_set, localv6_set, mark, fakeip_range, fakeip6_range))
        return false;

    let needs_plain_ip_rules = section_priority_needs_plain_ip_rules(section);
    let needs_ip_port_rules = section_priority_needs_ip_port_rules(section);
    let needs_udp_ip_port_rules = section_priority_needs_udp_ip_port_rules(section);
    let has_port_only_matchers = section_has_nft_port_only_matchers(section);
    let match_ip4 = [ "ip", "daddr", "@" + as_string(sets.subnets) ];
    let match_ip6 = [ "ip6", "daddr", "@" + as_string(sets.subnets6) ];
    let match_ip_port4_tcp = [ "ip", "daddr", ".", "tcp", "dport", "@" + as_string(sets.ip_ports) ];
    let match_ip_port4_udp = [ "ip", "daddr", ".", "udp", "dport", "@" + as_string(sets.ip_ports) ];
    let match_ip_port6_tcp = [ "ip6", "daddr", ".", "tcp", "dport", "@" + as_string(sets.ip6_ports) ];
    let match_ip_port6_udp = [ "ip6", "daddr", ".", "udp", "dport", "@" + as_string(sets.ip6_ports) ];
    let match_udp_ip_port4 = [ "ip", "daddr", ".", "udp", "dport", "@" + as_string(sets.udp_ip_ports) ];
    let match_udp_ip_port6 = [ "ip6", "daddr", ".", "udp", "dport", "@" + as_string(sets.udp_ip6_ports) ];
    let match_tcp_ip_port4 = [ "ip", "daddr", ".", "tcp", "dport", "@" + as_string(sets.tcp_ip_ports) ];
    let match_tcp_ip_port6 = [ "ip6", "daddr", ".", "tcp", "dport", "@" + as_string(sets.tcp_ip6_ports) ];
    let match_port4_tcp = [ "tcp", "dport", "@" + as_string(sets.ports) ];
    let match_port4_udp = [ "udp", "dport", "@" + as_string(sets.ports) ];
    let match_port6_tcp = [ "tcp", "dport", "@" + as_string(sets.ports) ];
    let match_port6_udp = [ "udp", "dport", "@" + as_string(sets.ports) ];

    if (needs_plain_ip_rules &&
        (!nft_add_priority_rule_pair(table, "priority_rules", section, interface_set, localv4_set, localv6_set, match_ip4, match_ip6, mark) ||
            !nft_add_priority_rule_pair(table, "priority_output_rules", section, interface_set, localv4_set, localv6_set, match_ip4, match_ip6, mark)))
        return false;

    if (needs_ip_port_rules &&
        (!nft_add_priority_rule_pair(table, "priority_rules", section, interface_set, localv4_set, localv6_set, match_ip_port4_tcp, match_ip_port6_tcp, mark) ||
            !nft_add_priority_rule_pair(table, "priority_rules", section, interface_set, localv4_set, localv6_set, match_ip_port4_udp, match_ip_port6_udp, mark) ||
            !nft_add_priority_rule_pair(table, "priority_output_rules", section, interface_set, localv4_set, localv6_set, match_ip_port4_tcp, match_ip_port6_tcp, mark) ||
            !nft_add_priority_rule_pair(table, "priority_output_rules", section, interface_set, localv4_set, localv6_set, match_ip_port4_udp, match_ip_port6_udp, mark)))
        return false;

    if (needs_udp_ip_port_rules &&
        (!nft_add_priority_rule_pair(table, "priority_rules", section, interface_set, localv4_set, localv6_set, match_udp_ip_port4, match_udp_ip_port6, mark) ||
            !nft_add_priority_rule_pair(table, "priority_output_rules", section, interface_set, localv4_set, localv6_set, match_udp_ip_port4, match_udp_ip_port6, mark)))
        return false;

    if (needs_udp_ip_port_rules &&
        (!nft_add_priority_rule_pair(table, "priority_rules", section, interface_set, localv4_set, localv6_set, match_tcp_ip_port4, match_tcp_ip_port6, mark) ||
            !nft_add_priority_rule_pair(table, "priority_output_rules", section, interface_set, localv4_set, localv6_set, match_tcp_ip_port4, match_tcp_ip_port6, mark)))
        return false;

    if (has_port_only_matchers &&
        (!nft_add_priority_rule_pair(table, "priority_rules", section, interface_set, localv4_set, localv6_set, match_port4_tcp, match_port6_tcp, mark) ||
            !nft_add_priority_rule_pair(table, "priority_rules", section, interface_set, localv4_set, localv6_set, match_port4_udp, match_port6_udp, mark) ||
            !nft_add_priority_rule_pair(table, "priority_output_rules", section, interface_set, localv4_set, localv6_set, match_port4_tcp, match_port6_tcp, mark) ||
            !nft_add_priority_rule_pair(table, "priority_output_rules", section, interface_set, localv4_set, localv6_set, match_port4_udp, match_port6_udp, mark)))
        return false;

    return true;
}

function nft_add_section_priority_rules_from_sections(sections, table, interface_set, localv4_set, localv6_set, mark, fakeip_range, fakeip6_range) {
    localv6_set = default_arg(localv6_set, "localv6");
    for (let section in sections) {
        section = object_or_empty(section);
        if (!bool_option(section, "enabled", true))
            continue;
        if (!nft_add_section_priority_rules(table, section, interface_set, localv4_set, localv6_set, mark, fakeip_range, fakeip6_range))
            return false;
    }
    return true;
}

function hex_digit_value(value) {
    let pos = index("0123456789abcdef", lc(as_string(value)));
    return pos >= 0 ? pos : null;
}

function parse_mark_number(value) {
    value = lc(trim(as_string(value)));
    if (value == "")
        return null;

    if (substr(value, 0, 2) == "0x") {
        value = substr(value, 2);
        if (value == "")
            return null;

        let result = 0;
        for (let i = 0; i < length(value); i++) {
            let digit = hex_digit_value(substr(value, i, 1));
            if (digit == null)
                return null;
            result = result * 16 + digit;
        }
        return result;
    }

    return match(value, /^[0-9]+$/) == null ? null : int(value);
}

function mark_union_hex(first, second) {
    let left = parse_mark_number(first);
    let right = parse_mark_number(second);
    if (left == null || right == null)
        return "";

    return sprintf("0x%08x", left | right);
}

function nft_create_runtime_base(table, localv4_set, common_set, port_set, ip_port_set, interface_set, source_interfaces, fakeip_mark, outbound_mark, fakeip_range, tproxy_port, exclude_ntp, localv6_set, common6_set, ip_port6_set, fakeip6_range, tproxy6_address) {
    localv6_set = default_arg(localv6_set, "localv6");
    common6_set = default_arg(common6_set, "forkop_subnets6");
    ip_port6_set = default_arg(ip_port6_set, "forkop_ip6_ports");
    fakeip6_range = default_arg(fakeip6_range, "fc00::/18");
    tproxy6_address = default_arg(tproxy6_address, "::1");
    let capture_mask = mark_union_hex(fakeip_mark, ROUTER_MARK);
    if (capture_mask == "")
        return false;

    if (!nft_create_table(table) ||
        !nft_create_ipv4_set(table, localv4_set) ||
        !nft_add_set_elements(table, localv4_set, join(",", LOCALV4_RANGES)) ||
        !nft_create_ipv6_set(table, localv6_set) ||
        !nft_add_set_elements(table, localv6_set, join(",", LOCALV6_RANGES)) ||
        !nft_create_ipv4_set(table, common_set) ||
        !nft_create_ipv6_set(table, common6_set) ||
        !nft_create_inet_service_set(table, port_set) ||
        !nft_create_ipv4_port_set(table, ip_port_set) ||
        !nft_create_ipv6_port_set(table, ip_port6_set) ||
        !nft_create_ipv4_set(table, DNS_SOURCE_SET) ||
        !nft_create_ipv6_set(table, DNS_SOURCE6_SET) ||
        !nft_create_ifname_set(table, interface_set))
        return false;

    for (let interface in whitespace_values(source_interfaces))
        if (!nft_add_set_elements(table, interface_set, interface))
            return false;

    // Native Rust X exit clients use the same classifiers as LAN clients.
    // Rebuild membership with each nft candidate; never persist it in UCI.
    if (fs.stat('/etc/forkop-tailscale/enabled') && fs.stat('/etc/forkop-tailscale/exit-enabled') &&
        trim(fs.readfile('/etc/forkop/sing-box-variant') || '') == 'rust-x' &&
        !nft_add_set_elements(table, interface_set, 'forkop-tslan'))
        return false;

    if (!nft_create_chain(table, "dns_redirect", "{ type nat hook prerouting priority -101; policy accept; }") ||
        !nft_create_chain(table, "mangle", "{ type filter hook prerouting priority -149; policy accept; }") ||
        !nft_create_chain(table, "mangle_output", "{ type route hook output priority -150; policy accept; }") ||
        !nft_create_priority_chains(table) ||
        !nft_create_chain(table, "proxy", "{ type filter hook prerouting priority -100; policy accept; }"))
        return false;

    if (!nft_add_rule(table, "dns_redirect", [ "iifname", "@" + as_string(interface_set), "ip", "saddr", "@" + DNS_SOURCE_SET, "tcp", "dport", "53", "counter", "redirect", "to", ":" + as_string(runtime_constants.SOURCE_DNS_INBOUND_PORT) ]) ||
        !nft_add_rule(table, "dns_redirect", [ "iifname", "@" + as_string(interface_set), "ip", "saddr", "@" + DNS_SOURCE_SET, "udp", "dport", "53", "counter", "redirect", "to", ":" + as_string(runtime_constants.SOURCE_DNS_INBOUND_PORT) ]) ||
        !nft_add_rule(table, "dns_redirect", [ "iifname", "@" + as_string(interface_set), "ip6", "saddr", "@" + DNS_SOURCE6_SET, "tcp", "dport", "53", "counter", "redirect", "to", ":" + as_string(runtime_constants.SOURCE_DNS_INBOUND_PORT) ]) ||
        !nft_add_rule(table, "dns_redirect", [ "iifname", "@" + as_string(interface_set), "ip6", "saddr", "@" + DNS_SOURCE6_SET, "udp", "dport", "53", "counter", "redirect", "to", ":" + as_string(runtime_constants.SOURCE_DNS_INBOUND_PORT) ]) ||
        // Every prerouting classifier below is limited to client interfaces.
        // Skip WAN replies before walking the section and destination sets.
        !nft_add_rule(table, "mangle", [ "iifname", "!=", "@" + as_string(interface_set), "return" ]) ||
        !nft_add_rule(table, "mangle", [ "ct", "status", "dnat", "return" ]) ||
        // A fully routed LAN device answering an inbound connection, and every
        // reply of a connection opened towards the LAN, arrive here.
        !nft_add_rule(table, "mangle", REPLY_RETURN) ||
        !nft_add_rule(table, "mangle", [ "ip", "daddr", "@" + as_string(localv4_set), "return" ]) ||
        !nft_add_rule(table, "mangle", [ "ip6", "daddr", "@" + as_string(localv6_set), "ip6", "daddr", "!=", fakeip6_range, "return" ]) ||
        !nft_add_rule(table, "mangle", [ "jump", "priority_rules" ]) ||
        // The common classifiers all select the same mark. Stop after the
        // first match; later hooks (including TPROXY) still run normally.
        !nft_add_rule(table, "mangle", [ "ip", "daddr", fakeip_range, "meta", "l4proto", "tcp", "meta", "mark", "set", fakeip_mark, "counter", "return" ]) ||
        !nft_add_rule(table, "mangle", [ "ip", "daddr", fakeip_range, "meta", "l4proto", "udp", "meta", "mark", "set", fakeip_mark, "counter", "return" ]) ||
        !nft_add_rule(table, "mangle", [ "ip6", "daddr", fakeip6_range, "meta", "l4proto", "tcp", "meta", "mark", "set", fakeip_mark, "counter", "return" ]) ||
        !nft_add_rule(table, "mangle", [ "ip6", "daddr", fakeip6_range, "meta", "l4proto", "udp", "meta", "mark", "set", fakeip_mark, "counter", "return" ]) ||
        // Keep marked router-originated packets eligible for TPROXY as well.
        // They arrive on loopback carrying the router mark, a LAN client's own
        // packet the FakeIP mark; both reach the same inbound.
        // Direct packets need no protocol/family-specific interception checks.
        !nft_add_rule(table, "proxy", [ "meta", "mark", "&", capture_mask, "==", "0", "return" ]) ||
        !nft_add_rule(table, "proxy", [ "meta", "mark", "&", capture_mask, "!=", "0", "meta", "l4proto", "tcp", "tproxy", "ip", "to", ":" + as_string(tproxy_port), "counter" ]) ||
        !nft_add_rule(table, "proxy", [ "meta", "mark", "&", capture_mask, "!=", "0", "meta", "l4proto", "udp", "tproxy", "ip", "to", ":" + as_string(tproxy_port), "counter" ]) ||
        !nft_add_rule(table, "proxy", [ "meta", "mark", "&", capture_mask, "!=", "0", "meta", "l4proto", "tcp", "tproxy", "ip6", "to", core_ip.format_ipv6_tproxy_target(tproxy6_address, tproxy_port), "counter" ]) ||
        !nft_add_rule(table, "proxy", [ "meta", "mark", "&", capture_mask, "!=", "0", "meta", "l4proto", "udp", "tproxy", "ip6", "to", core_ip.format_ipv6_tproxy_target(tproxy6_address, tproxy_port), "counter" ]) ||
        // A server on the router answering over WAN, and the core's own replies
        // to a client it captured, leave through this chain in the reply
        // direction; only what the router itself opens may be classified.
        !nft_add_rule(table, "mangle_output", REPLY_RETURN) ||
        !nft_add_rule(table, "mangle_output", [ "ip", "daddr", "@" + as_string(localv4_set), "return" ]) ||
        !nft_add_rule(table, "mangle_output", [ "ip6", "daddr", "@" + as_string(localv6_set), "ip6", "daddr", "!=", fakeip6_range, "return" ]) ||
        !nft_add_rule(table, "mangle_output", [ "meta", "mark", "&", outbound_mark, "==", outbound_mark, "counter", "return" ]) ||
        !nft_add_rule(table, "mangle_output", [ "jump", "priority_output_rules" ]))
        return false;

    if (arg_bool(exclude_ntp) && !nft_insert_rule(table, "mangle", [ "udp", "dport", "123", "return" ]))
        return false;

    return true;
}

function nft_add_direct_quic_rules(table, interface_set, localv4_set, localv6_set, fakeip_mark, enabled) {
    if (!arg_bool(enabled))
        return true;
    // Forward runs after prerouting classification/TPROXY. Restrict this to
    // Forkop client interfaces and preserve local services and port forwards.
    // Test our mark bit, not mark==0: mwan3 may mark direct WAN traffic too.
    return nft_create_chain(table, "quic_forward", "{ type filter hook forward priority -1; policy accept; }") &&
        nft_add_rule(table, "quic_forward", [ "iifname", "!=", "@" + as_string(interface_set), "return" ]) &&
        nft_add_rule(table, "quic_forward", [ "ct", "status", "dnat", "return" ]) &&
        nft_add_rule(table, "quic_forward", [ "ip", "daddr", "@" + as_string(localv4_set), "return" ]) &&
        nft_add_rule(table, "quic_forward", [ "ip6", "daddr", "@" + as_string(localv6_set), "return" ]) &&
        nft_add_rule(table, "quic_forward", [ "iifname", "@" + as_string(interface_set), "meta", "mark", "&", fakeip_mark, "==", "0", "udp", "dport", "443", "counter", "reject", "with", "icmpx", "type", "port-unreachable" ]);
}

function nft_create_runtime_base_from_uci(table, localv4_set, common_set, port_set, ip_port_set, interface_set, fakeip_mark, outbound_mark, fakeip_range, tproxy_port, localv6_set, common6_set, ip_port6_set, fakeip6_range, tproxy6_address) {
    let settings = uci_settings();

    return nft_create_runtime_base(
        table,
        localv4_set,
        common_set,
        port_set,
        ip_port_set,
        interface_set,
        option(settings, "source_network_interfaces", "br-lan"),
        fakeip_mark,
        outbound_mark,
        fakeip_range,
        tproxy_port,
        option(settings, "exclude_ntp", "0"),
        localv6_set,
        common6_set,
        ip_port6_set,
        fakeip6_range,
        tproxy6_address
    ) && nft_add_direct_quic_rules(table, interface_set, localv4_set,
        default_arg(localv6_set, "localv6"), fakeip_mark,
        bool_option(settings, "disable_quic", true) ? "1" : "0");
}

// fakeip_mark stays in the signature for the callers; what leaves this chain is
// the router's own traffic, and it carries the router mark.
function nft_create_runtime_output_rules(table, localv4_set, common_set, port_set, ip_port_set, fakeip_mark, fakeip_range, localv6_set, common6_set, ip_port6_set, fakeip6_range) {
    // Provider queues precede this common tail; only its own matches return.
    localv6_set = default_arg(localv6_set, "localv6");
    common6_set = default_arg(common6_set, "forkop_subnets6");
    ip_port6_set = default_arg(ip_port6_set, "forkop_ip6_ports");
    fakeip6_range = default_arg(fakeip6_range, "fc00::/18");

    return (
        nft_add_rule(table, "mangle_output", [ "ip", "daddr", fakeip_range, "meta", "l4proto", "tcp", "meta", "mark", "set", ROUTER_MARK, "counter", "return" ]) &&
        nft_add_rule(table, "mangle_output", [ "ip", "daddr", fakeip_range, "meta", "l4proto", "udp", "meta", "mark", "set", ROUTER_MARK, "counter", "return" ]) &&
        nft_add_rule(table, "mangle_output", [ "ip6", "daddr", fakeip6_range, "meta", "l4proto", "tcp", "meta", "mark", "set", ROUTER_MARK, "counter", "return" ]) &&
        nft_add_rule(table, "mangle_output", [ "ip6", "daddr", fakeip6_range, "meta", "l4proto", "udp", "meta", "mark", "set", ROUTER_MARK, "counter", "return" ])
    );
}

function nft_write_chunk(chunks, chunk) {
    if (length(chunk) > 0)
        push(chunks, "" + length(chunk) + "\t" + join(",", chunk));
}

function nft_push_chunk_value(chunks, chunk, value, chunk_size) {
    push(chunk, value);
    if (length(chunk) < chunk_size)
        return chunk;

    nft_write_chunk(chunks, chunk);
    return [];
}

function nft_invalid(invalid, value, message) {
    push(invalid, as_string(value) + "\t" + message);
}

function nft_trimmed_lines(path) {
    let data = fs.readfile(path);
    if (data == null)
        exit(1);

    let result = [];
    for (let line in split(as_string(data), "\n")) {
        line = trim(replace(as_string(line), /\r/g, ""));
        if (line != "")
            push(result, line);
    }

    return result;
}

function nft_chunk_size(value) {
    value = int(value || 5000);
    return value > 0 ? value : 5000;
}

function nft_csv_values(csv) {
    let result = [];

    for (let item in split(as_string(csv), ",")) {
        item = trim(replace(as_string(item), /\r/g, ""));
        if (item != "")
            push(result, item);
    }

    return result;
}

function nft_build_chunks_from_values(values, kind, ports_csv, chunk_size_text, family_filter) {
    let chunk_size = nft_chunk_size(chunk_size_text);
    let chunks = [];
    let invalid = [];
    let chunk = [];
    let ports = split(as_string(ports_csv), ",");
    family_filter = int(family_filter || 0);

    for (let line in values) {
        if (kind == "ports") {
            let port = normalize_port_condition_value(line);
            if (port == null) {
                nft_invalid(invalid, line, "is not a valid port or port range");
                continue;
            }
            chunk = nft_push_chunk_value(chunks, chunk, port, chunk_size);
            continue;
        }

        if (kind == "ip-ports") {
            let separator = index(line, " . ");
            let last_separator = rindex(line, " . ");
            if (separator < 0 || last_separator < 0) {
                nft_invalid(invalid, line, "is not an IP/CIDR and port nft tuple");
                continue;
            }

            let ip = substr(line, 0, separator);
            let port = substr(line, last_separator + 3);
            let original_port = port;
            if (!nft_ip_or_cidr(ip)) {
                nft_invalid(invalid, ip, "is not IP or CIDR");
                continue;
            }

            if (family_filter != 0 && core_ip.ip_family(ip) != family_filter)
                continue;

            port = normalize_port_condition_value(port);
            if (port == null) {
                nft_invalid(invalid, original_port, "is not a valid port or port range");
                continue;
            }

            chunk = nft_push_chunk_value(chunks, chunk, ip + " . " + port, chunk_size);
            continue;
        }

        if (!nft_ip_or_cidr(line)) {
            nft_invalid(invalid, line, "is not IP or CIDR");
            continue;
        }

        if (family_filter != 0 && core_ip.ip_family(line) != family_filter)
            continue;

        if (kind == "ip-port-from-ip") {
            for (let port in ports) {
                if (port == "")
                    continue;

                let normalized = normalize_port_condition_value(port);
                if (normalized == null) {
                    nft_invalid(invalid, port, "is not a valid port or port range");
                    continue;
                }

                chunk = nft_push_chunk_value(chunks, chunk, line + " . " + normalized, chunk_size);
            }
        }
        else if (kind == "ips") {
            chunk = nft_push_chunk_value(chunks, chunk, line, chunk_size);
        }
        else {
            exit(1);
        }
    }

    nft_write_chunk(chunks, chunk);

    return {
        chunks: chunks,
        invalid: invalid
    };
}

function nft_log_invalid_elements(invalid) {
    for (let item in invalid) {
        let separator = index(item, "\t");
        if (separator < 0)
            continue;

        let value = substr(item, 0, separator);
        let message = substr(item, separator + 1);
        if (value != "")
            log_debug("'" + value + "' " + message);
    }
}

function nft_add_chunks_to_set(table, set_name, chunks, invalid) {
    nft_log_invalid_elements(invalid);

    for (let item in chunks) {
        let separator = index(item, "\t");
        if (separator < 0)
            continue;

        let count = substr(item, 0, separator);
        let elements = substr(item, separator + 1);
        if (elements == "")
            continue;

        log_debug("Adding " + count + " elements to nft set " + set_name);
        if (!nft_add_set_elements(table, set_name, elements))
            return false;
    }

    return true;
}

function nft_add_file_chunks_to_set(path, table, set_name, kind, ports_csv, chunk_size_text, family_filter) {
    let prepared = nft_build_chunks_from_values(nft_trimmed_lines(path), kind, ports_csv, chunk_size_text, family_filter);
    return nft_add_chunks_to_set(table, set_name, prepared.chunks, prepared.invalid);
}

function nft_add_csv_chunks_to_set(csv, table, set_name, kind, ports_csv, chunk_size_text, family_filter) {
    let prepared = nft_build_chunks_from_values(nft_csv_values(csv), kind, ports_csv, chunk_size_text, family_filter);
    return nft_add_chunks_to_set(table, set_name, prepared.chunks, prepared.invalid);
}

function nft_add_file_chunks_to_family_sets(path, table, ipv4_set, ipv6_set, kind, ports_csv, chunk_size_text) {
    return nft_add_file_chunks_to_set(path, table, ipv4_set, kind, ports_csv, chunk_size_text, 4) &&
        nft_add_file_chunks_to_set(path, table, ipv6_set, kind, ports_csv, chunk_size_text, 6);
}

function nft_add_csv_chunks_to_family_sets(csv, table, ipv4_set, ipv6_set, kind, ports_csv, chunk_size_text) {
    return nft_add_csv_chunks_to_set(csv, table, ipv4_set, kind, ports_csv, chunk_size_text, 4) &&
        nft_add_csv_chunks_to_set(csv, table, ipv6_set, kind, ports_csv, chunk_size_text, 6);
}

function nft_add_inline_ip_cidr_matchers(csv, ports_csv, table, common_set, ip_port_set, chunk_size_text, common6_set, ip_port6_set) {
    if (as_string(csv) == "")
        return true;

    if (as_string(ports_csv) != "")
        return nft_add_csv_chunks_to_family_sets(csv, table, ip_port_set, default_arg(ip_port6_set, "forkop_ip6_ports"), "ip-port-from-ip", ports_csv, chunk_size_text);

    return nft_add_csv_chunks_to_family_sets(csv, table, common_set, default_arg(common6_set, "forkop_subnets6"), "ips", "", chunk_size_text);
}

function normalized_fields(line) {
    line = trim(replace(as_string(line), /\r/g, ""));
    line = replace(line, /[[:space:]]+/g, " ");
    return line == "" ? [] : split(line, " ");
}

function rule_line_has_lookup_table(fields, table) {
    table = as_string(table);

    for (let i = 0; i + 1 < length(fields); i++)
        if (fields[i] == "lookup" && fields[i + 1] == table)
            return true;

    return false;
}

function rule_line_has_fwmark(fields, expected_mark) {
    for (let i = 0; i + 1 < length(fields); i++) {
        if (fields[i] != "fwmark")
            continue;

        let parts = split(fields[i + 1], "/");
        if (length(parts) != 2)
            continue;

        if (parse_mark_number(parts[0]) == expected_mark && parse_mark_number(parts[1]) == expected_mark)
            return true;
    }

    return false;
}

// Mark and table have to meet on one line: the source-check rule carries the
// same mark towards the main table, and a second marking rule the same table.
function has_tproxy_marking_rule_text(rule_list, table, mark) {
    let expected_mark = parse_mark_number(mark);

    if (expected_mark == null)
        return false;

    for (let line in split(as_string(rule_list), "\n")) {
        let fields = normalized_fields(line);
        if (length(fields) == 0)
            continue;

        if (rule_line_has_lookup_table(fields, table) && rule_line_has_fwmark(fields, expected_mark))
            return true;
    }

    return false;
}

// "103: from all fwmark 0x4000000/0x4000000 iif lo lookup main", as iproute2 prints it
function has_source_check_rule_text(rule_list, mark) {
    let expected_mark = parse_mark_number(mark);

    if (expected_mark == null)
        return false;

    for (let line in split(as_string(rule_list), "\n")) {
        let fields = normalized_fields(line);
        let position = index(fields, "iif");
        if (length(fields) == 0 || fields[0] != SOURCE_CHECK_PRIORITY + ":")
            continue;

        if (position > 0 && fields[position + 1] == "lo" && rule_line_has_fwmark(fields, expected_mark) &&
            rule_line_has_lookup_table(fields, "main"))
            return true;
    }

    return false;
}

function has_local_default_route_text(route_list, family) {
    family = int(family || 4);

    for (let line in split(as_string(route_list), "\n")) {
        line = trim(replace(as_string(line), /\r/g, ""));
        line = replace(line, /[[:space:]]+/g, " ");
        if (family == 4 && index(line, "local default dev lo scope host") >= 0)
            return true;
        if (family == 6 && (index(line, "local ::") >= 0 || index(line, "local default") >= 0) && index(line, " dev lo") >= 0)
            return true;
    }

    return false;
}

function rt_table_has_entry(text, table_id, table_name) {
    table_id = as_string(table_id);
    table_name = as_string(table_name);

    for (let line in split(as_string(text), "\n")) {
        let fields = normalized_fields(line);
        if (length(fields) >= 2 && fields[0] == table_id && fields[1] == table_name)
            return true;
    }

    return false;
}

function ensure_rt_table_entry(path, table_id, table_name) {
    let data = fs.readfile(path);
    if (data != null && rt_table_has_entry(data, table_id, table_name))
        return true;

    data = data == null ? "" : as_string(data);
    if (data != "" && substr(data, length(data) - 1, 1) != "\n")
        data += "\n";

    return write_text_file(path, data + as_string(table_id) + " " + as_string(table_name) + "\n");
}

function tproxy_route4_present(table) {
    return has_local_default_route_text(command_output_quiet_from_args([ "ip", "route", "list", "table", table ]), 4);
}

function tproxy_route6_present(table) {
    return has_local_default_route_text(command_output_quiet_from_args([ "ip", "-6", "route", "list", "table", table ]), 6);
}

function tproxy_route_present(table) {
    return tproxy_route4_present(table) && (!IPV6_TPROXY_ENABLED || tproxy_route6_present(table));
}

function source_check_rule4_present(mark) {
    return has_source_check_rule_text(command_output_from_args([ "ip", "-4", "rule", "list", "priority", SOURCE_CHECK_PRIORITY ]), mark);
}

function tproxy_marking_rule4_present(table, mark) {
    return has_tproxy_marking_rule_text(command_output_from_args([ "ip", "-4", "rule", "list" ]), table, mark);
}

function tproxy_marking_rule6_present(table, mark) {
    return has_tproxy_marking_rule_text(command_output_from_args([ "ip", "-6", "rule", "list" ]), table, mark);
}

function tproxy_marking_rule_present(table, mark) {
    return tproxy_marking_rule4_present(table, mark) && (!IPV6_TPROXY_ENABLED || tproxy_marking_rule6_present(table, mark));
}

function tproxy_route_rule_present(table, mark) {
    return tproxy_route_present(table) && tproxy_marking_rule_present(table, mark);
}

function ensure_ip_rule(present, argv, message) {
    if (present())
        return true;

    if (!run_args(argv) && !present()) {
        log_fatal(message);
        return false;
    }

    return true;
}

function ensure_tproxy_route_rule(table, mark, rt_tables_path) {
    rt_tables_path = as_string(rt_tables_path || RT_TABLES_FILE);
    let mask = as_string(mark) + "/" + as_string(mark);
    let router_mask = ROUTER_MARK + "/" + ROUTER_MARK;

    if (!ensure_rt_table_entry(rt_tables_path, "105", table)) {
        log_fatal("Failed to update route table registry. Aborted.");
        return false;
    }

    if (!tproxy_route4_present(table)) {
        log_debug("Added IPv4 TPROXY route");
        if (!run_args([ "ip", "route", "add", "local", "0.0.0.0/0", "dev", "lo", "table", table ]) && !tproxy_route4_present(table)) {
            log_fatal("Failed to add IPv4 route for tproxy. Aborted.");
            return false;
        }
    }
    else {
        log_debug("IPv4 TPROXY route already exists");
    }

    if (!IPV6_TPROXY_ENABLED) {
        log_info("IPv6 is disabled or unavailable on loopback; skipping IPv6 TPROXY setup");
    }
    else if (!tproxy_route6_present(table)) {
        log_debug("Added IPv6 TPROXY route");
        if (!run_args([ "ip", "-6", "route", "add", "local", "::/0", "dev", "lo", "table", table ]) && !tproxy_route6_present(table)) {
            log_fatal("Failed to add IPv6 route for tproxy. Aborted.");
            return false;
        }
    }
    else {
        log_debug("IPv6 TPROXY route already exists");
    }

    if (!tproxy_marking_rule4_present(table, mark)) {
        log_debug("Creating IPv4 TPROXY marking rule");
        if (!run_args([ "ip", "-4", "rule", "add", "fwmark", mask, "table", table, "priority", "105" ]) && !tproxy_marking_rule4_present(table, mark)) {
            log_fatal("Failed to create IPv4 marking rule. Aborted.");
            return false;
        }
    }
    else {
        log_debug("IPv4 TPROXY marking rule already exists");
    }

    if (!ensure_ip_rule(() => tproxy_marking_rule4_present(table, ROUTER_MARK),
        [ "ip", "-4", "rule", "add", "fwmark", router_mask, "table", table, "priority", "105" ],
        "Failed to create IPv4 marking rule for router traffic. Aborted."))
        return false;

    // With src_valid_mark on -- tailscaled in netfilter mode turns it on -- the kernel
    // checks the source of a packet it routes to itself with a lookup from lo carrying
    // the packet's mark. Rule 105 would answer it from the Forkop table, whose local
    // default route makes the client's address one of the router's, and the packet dies
    // as a martian source. The main table answers it instead. Rerouting what the router
    // itself sends is a lookup from lo as well, which is why it carries its own mark.
    if (!ensure_ip_rule(() => source_check_rule4_present(mark),
        [ "ip", "-4", "rule", "add", "iif", "lo", "fwmark", mask, "lookup", "main", "priority", SOURCE_CHECK_PRIORITY ],
        "Failed to create the IPv4 source-check routing rule. Aborted."))
        return false;

    if (IPV6_TPROXY_ENABLED && !tproxy_marking_rule6_present(table, mark)) {
        log_debug("Creating IPv6 TPROXY marking rule");
        if (!run_args([ "ip", "-6", "rule", "add", "fwmark", mask, "table", table, "priority", "105" ]) && !tproxy_marking_rule6_present(table, mark)) {
            log_fatal("Failed to create IPv6 marking rule. Aborted.");
            return false;
        }
    }
    else if (IPV6_TPROXY_ENABLED) {
        log_debug("IPv6 TPROXY marking rule already exists");
    }

    // IPv6 has no source check of its own, so it needs no source-check rule.
    if (IPV6_TPROXY_ENABLED && !ensure_ip_rule(() => tproxy_marking_rule6_present(table, ROUTER_MARK),
        [ "ip", "-6", "rule", "add", "fwmark", router_mask, "table", table, "priority", "105" ],
        "Failed to create IPv6 marking rule for router traffic. Aborted."))
        return false;

    return true;
}

function ensure_bridge_netfilter_disabled() {
    if (index(command_output_from_args([ "lsmod" ]), "br_netfilter") < 0)
        return true;

    if (trim(command_output_from_args([ "sysctl", "-n", "net.bridge.bridge-nf-call-iptables" ])) != "1")
        return true;

    log_debug("br_netfilter is enabled; disabling it for transparent proxy routing");
    return run_args([ "sysctl", "-w", "net.bridge.bridge-nf-call-iptables=0" ]) &&
        run_args([ "sysctl", "-w", "net.bridge.bridge-nf-call-ip6tables=0" ]);
}

function filter_community_subnet_lists_value(value) {
    return rule_config.filter_community_subnet_lists_value(value);
}

function signature_add_value(body, key, value) {
    return body + "[" + as_string(key) + "]\n" + as_string(value) + "\n";
}

function signature_hash(body) {
    let path = trim(command_output_from_args([ "mktemp" ]));
    if (path == "")
        return "";

    if (!write_text_file(path, body)) {
        unlink_file(path);
        return "";
    }

    let hash_line = command_output_from_args([ "md5sum", path ]);
    unlink_file(path);
    hash_line = trim(hash_line);

    return length(hash_line) >= 32 ? substr(hash_line, 0, 32) : "";
}

function nft_rule_signature_body(body, section) {
    let section_name = as_string(section[".name"]);

    if (section_name == "" || !bool_option(section, "enabled", true))
        return body;

    let action = option(section, "action", "");
    body = signature_add_value(body, "rule." + section_name + ".action", action);
    if (action == "dns") {
        body = signature_add_value(body, "rule." + section_name + ".source_ip_cidr", section_rule_condition_csv(section, "source_ip_cidr", "subnets"));
        let excluded_sources = section_rule_condition_csv(section, "excluded_source_ip_cidr", "subnets");
        if (excluded_sources != "")
            body = signature_add_value(body, "rule." + section_name + ".excluded_source_ip_cidr", excluded_sources);
        body = signature_add_value(body, "rule." + section_name + ".source_aware_dns", connections.has_dns_matchers(section) ? "1" : "0");
        body = signature_add_value(body, "rule." + section_name + ".fully_routed_ips", option(section, "fully_routed_ips", ""));
        return body;
    }
    body = signature_add_value(body, "rule." + section_name + ".ip_cidr", section_rule_condition_csv(section, "ip_cidr", "subnets"));
    body = signature_add_value(body, "rule." + section_name + ".source_ip_cidr", section_rule_condition_csv(section, "source_ip_cidr", "subnets"));
    let excluded_sources = section_rule_condition_csv(section, "excluded_source_ip_cidr", "subnets");
    if (excluded_sources != "")
        body = signature_add_value(body, "rule." + section_name + ".excluded_source_ip_cidr", excluded_sources);
    body = signature_add_value(body, "rule." + section_name + ".source_aware_dns", connections.has_dns_matchers(section) ? "1" : "0");
    body = signature_add_value(body, "rule." + section_name + ".ports", section_rule_ports_csv(section));
    body = signature_add_value(body, "rule." + section_name + ".fully_routed_ips", option(section, "fully_routed_ips", ""));
    body = signature_add_value(body, "rule." + section_name + ".community_subnet_lists", filter_community_subnet_lists_value(connections.community_lists_value(section)));
    body = signature_add_value(body, "rule." + section_name + ".remote_subnet_lists", option(section, "remote_subnet_lists", ""));
    body = signature_add_value(body, "rule." + section_name + ".rule_set_with_subnets", connections.rule_sets_with_subnets_value(section));
    body = signature_add_value(body, "rule." + section_name + ".domain_ip_lists", option(section, "domain_ip_lists", ""));

    return body;
}

function nft_runtime_signature_from_settings_and_sections(settings, sections) {
    let body = "";

    body = signature_add_value(body, "runtime.ipv6_tproxy", IPV6_TPROXY_ENABLED ? "1" : "0");

    body = signature_add_value(body, "settings.source_network_interfaces", option(settings, "source_network_interfaces", "br-lan"));
    body = signature_add_value(body, "settings.exclude_ntp", bool_option(settings, "exclude_ntp", false) ? "1" : "0");
    body = signature_add_value(body, "settings.disable_quic", bool_option(settings, "disable_quic", true) ? "1" : "0");

    for (let section in sections)
        body = nft_rule_signature_body(body, object_or_empty(section));

    return signature_hash(body);
}

function print_nft_runtime_signature_from_settings_and_sections(settings, sections) {
    let hash = nft_runtime_signature_from_settings_and_sections(settings, sections);
    if (hash == "")
        return false;

    print(hash, "\n");
    return true;
}

function word_set(value) {
    let result = {};
    for (let item in whitespace_values(value))
        result[item] = true;
    return result;
}

function fixture_section_list(data, type_name) {
    let value = object_or_empty(data)[type_name];
    if (type(value) == "array")
        return value;
    if (type(value) == "object")
        return [ value ];

    let plural = object_or_empty(data)[type_name + "s"];
    return type(plural) == "array" ? plural : [];
}

function section_by_name(sections, section_name) {
    section_name = as_string(section_name);
    for (let section in sections)
        if (as_string(section[".name"]) == section_name)
            return section;
    return null;
}

function nft_create_full_runtime_from_uci(rt_table, table, localv4_set, common_set, port_set, ip_port_set, interface_set, fakeip_mark, outbound_mark, fakeip_range, tproxy_port, localv6_set, common6_set, ip_port6_set, fakeip6_range, tproxy6_address) {
    log_debug("Building nftables runtime model");

    return ensure_tproxy_route_rule(rt_table, fakeip_mark) &&
        nft_create_runtime_base_from_uci(table, localv4_set, common_set, port_set, ip_port_set, interface_set, fakeip_mark, outbound_mark, fakeip_range, tproxy_port, localv6_set, common6_set, ip_port6_set, fakeip6_range, tproxy6_address) &&
        nft_add_section_priority_rules_from_sections(uci_sections("section"), table, interface_set, localv4_set, localv6_set, fakeip_mark, fakeip_range, fakeip6_range) &&
        nft_create_runtime_output_rules(table, localv4_set, common_set, port_set, ip_port_set, fakeip_mark, fakeip_range, localv6_set, common6_set, ip_port6_set, fakeip6_range);
}

function nft_table_present(table) {
    return run_args_quiet([ "nft", "list", "table", "inet", table ]);
}

function nft_delete_table(table) {
    return run_args([ "nft", "delete", "table", "inet", table ]);
}

function nft_validate_candidate_batch(path) {
    path = as_string(path);
    let stat = fs.stat(path);
    if (path == "" || stat == null || int(stat.size || 0) <= 0)
        return false;
    if (NFT_CANDIDATE_FAIL_PHASE == "check")
        return false;
    return run_args([ "nft", "-c", "-f", path ]);
}

function nft_commit_candidate_batch(path) {
    path = as_string(path);
    let stat = fs.stat(path);
    if (path == "" || stat == null || int(stat.size || 0) <= 0)
        return false;
    if (NFT_CANDIDATE_FAIL_PHASE == "apply")
        return false;
    return run_args([ "nft", "-f", path ]);
}

function nft_apply_candidate_batch(path) {
    // Backward-compatible one-shot candidate application for paths which do
    // not also transition sing-box. Cross-component transitions validate via
    // nft_validate_candidate_batch() before any live state changes, then call
    // nft_commit_candidate_batch() only after sing-box is ready.
    return nft_validate_candidate_batch(path) && nft_commit_candidate_batch(path);
}

function guard_drop_rule(table, mark) {
    return "add rule inet " + as_string(table) + " " + NFT_TRANSITION_GUARD_CHAIN +
        " meta mark & " + as_string(mark) + " == " + as_string(mark) + " counter drop\n";
}

function nft_transition_guard_batch(table, mark, remove) {
    let path = trim(command_output_from_args([ "mktemp" ]));
    if (path == "")
        return false;

    // The router's own classified traffic carries the router mark and reaches
    // this hook on loopback: it has to fail closed with the LAN's.
    let data = remove
        ? "delete chain inet " + as_string(table) + " " + NFT_TRANSITION_GUARD_CHAIN + "\n"
        : "add chain inet " + as_string(table) + " " + NFT_TRANSITION_GUARD_CHAIN +
            " { type filter hook prerouting priority -101; policy accept; }\n" +
            guard_drop_rule(table, mark) + guard_drop_rule(table, ROUTER_MARK);
    let ok = fs.writefile(path, data) != null && run_args([ "nft", "-c", "-f", path ]) &&
        run_args([ "nft", "-f", path ]);
    fs.unlink(path);
    return ok;
}

function nft_transition_guard_present(table) {
    return run_args_quiet([ "nft", "list", "chain", "inet", table, NFT_TRANSITION_GUARD_CHAIN ]);
}

function nft_install_transition_guard(table, mark) {
    // This hook is after mangle marking (-149) but before TPROXY (-100).
    // During a cross-component transition it drops only traffic Forkop has
    // classified as protected, preventing a new config/table mismatch from
    // reaching route.final/direct.
    if (run_args_quiet([ "nft", "list", "chain", "inet", table, NFT_TRANSITION_GUARD_CHAIN ]))
        return false;
    return nft_transition_guard_batch(table, mark, false);
}

function nft_remove_transition_guard(table, mark) {
    if (!run_args_quiet([ "nft", "list", "chain", "inet", table, NFT_TRANSITION_GUARD_CHAIN ]))
        return true;
    return nft_transition_guard_batch(table, mark, true);
}

function nft_rebuild_runtime_from_uci(rt_table, table, localv4_set, common_set, port_set, ip_port_set, interface_set, fakeip_mark, outbound_mark, fakeip_range, tproxy_port, localv6_set, common6_set, ip_port6_set, fakeip6_range, tproxy6_address) {
    log_debug("Applying nftables runtime rules");

    if (nft_table_present(table) && !nft_delete_table(table))
        return false;

    return nft_create_full_runtime_from_uci(rt_table, table, localv4_set, common_set, port_set, ip_port_set, interface_set, fakeip_mark, outbound_mark, fakeip_range, tproxy_port, localv6_set, common6_set, ip_port6_set, fakeip6_range, tproxy6_address);
}

function fixture_section(path, section_name) {
    let data = object_or_empty(common_read_json_file(path));
    connections.set_item_sections_from_data(data);
    return section_by_name(fixture_section_list(data, "section"), section_name);
}

function fixture_settings(data) {
    return object_or_empty(object_or_empty(data).settings);
}

function nft_runtime_signature_from_fixture(path) {
    let data = object_or_empty(common_read_json_file(path));
    connections.set_item_sections_from_data(data);
    return print_nft_runtime_signature_from_settings_and_sections(fixture_settings(data), fixture_section_list(data, "section"));
}

function nft_add_section_source_matchers(section, table, chunk_size_text) {
    let source_values = section_source_ip_values(section);
    if (source_values == "")
        return true;

    let sets = section_priority_sets(section);
    return nft_add_csv_chunks_to_family_sets(source_values, table, sets.sources, sets.sources6, "ips", "", chunk_size_text);
}

function nft_add_section_excluded_source_matchers(section, table, chunk_size_text) {
    let source_values = section_excluded_source_ip_values(section);
    if (source_values == "")
        return true;

    let sets = section_priority_sets(section);
    return nft_add_csv_chunks_to_family_sets(source_values, table, sets.excluded_sources, sets.excluded_sources6, "ips", "", chunk_size_text);
}

function nft_add_section_fully_routed_sources(section, table, chunk_size_text) {
    let seen = {};
    let values = [];
    for (let source_ip in list_option(section, "fully_routed_ips")) {
        source_ip = as_string(source_ip);
        if (source_ip == "" || seen[source_ip])
            continue;
        seen[source_ip] = true;
        push(values, source_ip);
    }

    if (length(values) == 0)
        return true;

    let sets = section_priority_sets(section);
    return nft_add_csv_chunks_to_family_sets(join(",", values), table, sets.fully_sources, sets.fully_sources6, "ips", "", chunk_size_text);
}

function source_aware_dns_values(sections, deferred_sections) {
    let seen = {};
    let values = [];

    for (let section in sections) {
        if (!bool_option(section, "enabled", true) ||
            deferred_sections[as_string(section[".name"])])
            continue;

        let action = section_action(section);

        if (connections.has_dns_matchers(section)) {
            for (let value in nft_csv_values(section_source_ip_values(section))) {
                if (!seen[value]) {
                    seen[value] = true;
                    push(values, value);
                }
            }
        }

        if (connections.has_dns_matchers(section) || section_has_fully_routed_ips(section)) {
            for (let value in nft_csv_values(section_excluded_source_ip_values(section))) {
                if (!seen[value]) {
                    seen[value] = true;
                    push(values, value);
                }
            }
        }

        if (action == "bypass" || action == "dns") {
            for (let value in list_option(section, "fully_routed_ips")) {
                value = trim(as_string(value));
                if (value != "" && !seen[value]) {
                    seen[value] = true;
                    push(values, value);
                }
            }
        }
    }

    return values;
}

function nft_add_source_aware_dns_sources(sections, deferred_sections, table) {
    let values = source_aware_dns_values(sections, deferred_sections);
    if (length(values) == 0)
        return true;

    return nft_add_csv_chunks_to_family_sets(
        join(",", values),
        table,
        DNS_SOURCE_SET,
        DNS_SOURCE6_SET,
        "ips",
        "",
        5000
    );
}

function nft_populate_runtime_set_for_section(section, deferred_sections, table, common_set, port_set, ip_port_set, common6_set, ip_port6_set) {
    if (!bool_option(section, "enabled", true))
        return true;
    if (section_action(section) == "dns")
        return true;

    let ports = section_rule_ports_csv(section);
    let ip_values = section_rule_condition_csv(section, "ip_cidr", "subnets");
    let sets = section_priority_sets(section);

    if (section_needs_priority_sets(section) && !nft_add_section_source_matchers(section, table, 5000))
        return false;
    if (section_needs_priority_sets(section) && !nft_add_section_excluded_source_matchers(section, table, 5000))
        return false;

    if (deferred_sections[as_string(section[".name"])])
        return true;

    if (section_needs_priority_sets(section)) {
        if (!nft_add_section_fully_routed_sources(section, table, 5000))
            return false;

        if (!nft_add_inline_ip_cidr_matchers(ip_values, ports, table, sets.subnets, sets.ip_ports, 5000, sets.subnets6, sets.ip6_ports))
            return false;

        if (ports != "" && !section_has_destination_matchers(section) &&
            !nft_add_set_elements(table, sets.ports, ports))
            return false;
    }

    return true;
}

function nft_add_subnet_file_for_section(section, filepath, table, common_set, ip_port_set, chunk_size_text, common6_set, ip_port6_set) {
    let ports = section_rule_ports_csv(section);
    let sets = section_priority_sets(section);

    if (!section_needs_priority_sets(section))
        return true;

    if (ports != "")
        return nft_add_file_chunks_to_family_sets(filepath, table, sets.ip_ports, sets.ip6_ports, "ip-port-from-ip", ports, chunk_size_text);

    return nft_add_file_chunks_to_family_sets(filepath, table, sets.subnets, sets.subnets6, "ips", "", chunk_size_text);
}

function nft_community_subnet_lines(path, service, filter_mode) {
    let data = fs.readfile(path);
    if (data == null)
        return [];

    let result = [];
    for (let line in split(as_string(data), "\n")) {
        line = trim(replace(as_string(line), /\r/g, ""));
        if (line == "" || substr(line, 0, 1) == "#")
            continue;

        let shared_cloudflare = core_ip.is_cloudflare_shared_cidr(line);
        if (filter_mode == "only_cloudflare") {
            if (as_string(service) == "discord" && shared_cloudflare)
                push(result, line);
        }
        else if (filter_mode == "exclude_cloudflare") {
            if (as_string(service) != "discord" || !shared_cloudflare)
                push(result, line);
        }
        else {
            push(result, line);
        }
    }
    return result;
}

function nft_add_values_to_family_sets(values, table, ipv4_set, ipv6_set, kind, ports_csv, chunk_size_text) {
    let prepared4 = nft_build_chunks_from_values(values, kind, ports_csv, chunk_size_text, 4);
    let ok4 = nft_add_chunks_to_set(table, ipv4_set, prepared4.chunks, prepared4.invalid);
    let prepared6 = nft_build_chunks_from_values(values, kind, ports_csv, chunk_size_text, 6);
    let ok6 = nft_add_chunks_to_set(table, ipv6_set, prepared6.chunks, prepared6.invalid);
    return ok4 && ok6;
}

function file_nonempty(path) {
    let stat = fs.stat(as_string(path));
    return stat != null && int(stat.size) > 0;
}

function nft_add_extracted_ruleset_subnets(unscoped_path, scoped_path, label, table, common_set, ip_port_set, chunk_size_text, common6_set, ip_port6_set) {
    let has_entries = false;

    if (file_nonempty(unscoped_path)) {
        if (!nft_add_file_chunks_to_family_sets(unscoped_path, table, common_set, default_arg(common6_set, "forkop_subnets6"), "ips", "", chunk_size_text))
            return false;
        has_entries = true;
    }

    if (file_nonempty(scoped_path)) {
        if (!nft_add_file_chunks_to_family_sets(scoped_path, table, ip_port_set, default_arg(ip_port6_set, "forkop_ip6_ports"), "ip-ports", "", chunk_size_text))
            return false;
        has_entries = true;
    }

    if (!has_entries)
        run_args([ "logger", "-t", "forkop", "[warn] " + as_string(label) + " has no ip_cidr entries for nftables" ]);

    return true;
}

function nft_add_json_ruleset_subnets_for_section(section, json_path, label, table, common_set, ip_port_set, unscoped_path, scoped_path, chunk_size_text, common6_set, ip_port6_set) {
    let ports = section_rule_ports_csv(section);
    let sets = section_priority_sets(section);

    if (!section_needs_priority_sets(section))
        return true;

    routing_rulesets.extract_ip_cidr_nft_protocol_elements(
        json_path,
        unscoped_path,
        scoped_path,
        sprintf("%J", rule_port_values(ports)),
        sprintf("%J", rule_port_ranges(ports))
    );

    let has_shared = file_nonempty(unscoped_path) || file_nonempty(scoped_path);
    let has_transport = file_nonempty(scoped_path + ".tcp") || file_nonempty(scoped_path + ".udp");
    if ((has_shared || !has_transport) &&
        !nft_add_extracted_ruleset_subnets(unscoped_path, scoped_path, label, table, sets.subnets, sets.ip_ports, chunk_size_text, sets.subnets6, sets.ip6_ports))
        return false;
    if (file_nonempty(scoped_path + ".tcp") &&
        !nft_add_file_chunks_to_family_sets(scoped_path + ".tcp", table, sets.tcp_ip_ports, sets.tcp_ip6_ports, "ip-ports", "", chunk_size_text))
        return false;
    return !file_nonempty(scoped_path + ".udp") ||
        nft_add_file_chunks_to_family_sets(scoped_path + ".udp", table, sets.udp_ip_ports, sets.udp_ip6_ports, "ip-ports", "", chunk_size_text);
}

function nft_add_community_subnet_file_for_section(section, service, filepath, table, common_set, ip_port_set, interface_set, discord_set, mark, chunk_size_text, common6_set, ip_port6_set, discord6_set) {
    let ports = section_rule_ports_csv(section);
    let sets = section_priority_sets(section);

    if (!section_needs_priority_sets(section))
        return true;

    // Explicit section ports remain authoritative for every community subnet.
    if (ports != "" && !section_has_destination_matchers(section))
        return nft_add_values_to_family_sets(
            nft_community_subnet_lines(filepath, service, "all"),
            table, sets.ip_ports, sets.ip6_ports, "ip-port-from-ip", ports, chunk_size_text
        );

    let regular = nft_community_subnet_lines(filepath, service, "exclude_cloudflare");
    let ok = length(regular) == 0 || nft_add_values_to_family_sets(
        regular, table, sets.subnets, sets.subnets6, "ips", "", chunk_size_text
    );

    // Keep Discord voice working on shared Cloudflare Anycast without turning
    // the entire provider network into a catch-all route.
    if (as_string(service) == "discord") {
        let shared = nft_community_subnet_lines(filepath, service, "only_cloudflare");
        if (length(shared) > 0)
            ok = nft_add_values_to_family_sets(
                shared, table, sets.udp_ip_ports, sets.udp_ip6_ports, "ip-port-from-ip",
                core_ip.DISCORD_VOICE_PORTS_NFT, chunk_size_text
            ) && ok;
        if (length(shared) > 0)
            ok = nft_add_values_to_family_sets(
                shared, table, sets.tcp_ip_ports, sets.tcp_ip6_ports, "ip-port-from-ip",
                core_ip.DISCORD_MEDIA_PORTS_NFT, chunk_size_text
            ) && ok;
    }

    return ok;
}

function nft_add_subnet_file_for_uci_section(section_name, filepath, table, common_set, ip_port_set, chunk_size_text, common6_set, ip_port6_set) {
    return nft_add_subnet_file_for_section(uci_section(section_name), filepath, table, common_set, ip_port_set, chunk_size_text, common6_set, ip_port6_set);
}

function nft_add_json_ruleset_subnets_for_uci_section(section_name, json_path, label, table, common_set, ip_port_set, unscoped_path, scoped_path, chunk_size_text, common6_set, ip_port6_set) {
    return nft_add_json_ruleset_subnets_for_section(uci_section(section_name), json_path, label, table, common_set, ip_port_set, unscoped_path, scoped_path, chunk_size_text, common6_set, ip_port6_set);
}

function nft_add_community_subnet_file_for_uci_section(section_name, service, filepath, table, common_set, ip_port_set, interface_set, discord_set, mark, chunk_size_text, common6_set, ip_port6_set, discord6_set) {
    return nft_add_community_subnet_file_for_section(uci_section(section_name), service, filepath, table, common_set, ip_port_set, interface_set, discord_set, mark, chunk_size_text, common6_set, ip_port6_set, discord6_set);
}

function nft_add_json_ruleset_subnets_for_fixture_section(fixture_path, section_name, json_path, label, table, common_set, ip_port_set, unscoped_path, scoped_path, chunk_size_text, common6_set, ip_port6_set) {
    return nft_add_json_ruleset_subnets_for_section(fixture_section(fixture_path, section_name), json_path, label, table, common_set, ip_port_set, unscoped_path, scoped_path, chunk_size_text, common6_set, ip_port6_set);
}

function nft_add_community_subnet_file_for_fixture_section(fixture_path, section_name, service, filepath, table, common_set, ip_port_set, interface_set, discord_set, mark, chunk_size_text, common6_set, ip_port6_set, discord6_set) {
    return nft_add_community_subnet_file_for_section(fixture_section(fixture_path, section_name), service, filepath, table, common_set, ip_port_set, interface_set, discord_set, mark, chunk_size_text, common6_set, ip_port6_set, discord6_set);
}

function nft_populate_runtime_sets_from_sections(sections, populate_enabled, deferred_section_names, table, common_set, port_set, ip_port_set, interface_set, localv4_set, mark, common6_set, ip_port6_set, localv6_set) {
    if (!arg_bool(populate_enabled))
        return true;

    let deferred_sections = word_set(deferred_section_names);

    if (!nft_add_source_aware_dns_sources(sections, deferred_sections, table))
        return false;

    for (let section in sections)
        if (!nft_populate_runtime_set_for_section(section, deferred_sections, table, common_set, port_set, ip_port_set, common6_set, ip_port6_set))
            return false;

    return true;
}

function nft_populate_runtime_sets_from_uci(populate_enabled, deferred_section_names, table, common_set, port_set, ip_port_set, interface_set, localv4_set, mark, common6_set, ip_port6_set, localv6_set) {
    if (!arg_bool(populate_enabled))
        return true;

    return nft_populate_runtime_sets_from_sections(uci_sections("section"), populate_enabled, deferred_section_names, table, common_set, port_set, ip_port_set, interface_set, localv4_set, mark, common6_set, ip_port6_set, localv6_set);
}

let mode = ARGV[0] || "";

if (mode == "text-list-to-csv")
    text_list_to_csv(ARGV[1], ARGV[2]);
else if (mode == "csv-to-json-array")
    csv_to_json_array(ARGV[1]);
else if (mode == "split-domain-subnet-file")
    split_domain_subnet_file(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "nft-create-runtime-base")
    exit(nft_create_runtime_base(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12], ARGV[13], ARGV[14], ARGV[15], ARGV[16], ARGV[17]) ? 0 : 1);
else if (mode == "nft-create-runtime-output-rules")
    exit(nft_create_runtime_output_rules(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11]) ? 0 : 1);
else if (mode == "nft-add-section-priority-rules-fixture")
    exit(nft_add_section_priority_rules_from_sections(fixture_section_list(object_or_empty(common_read_json_file(ARGV[1])), "section"), ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8]) ? 0 : 1);
else if (mode == "nft-rebuild-runtime-from-uci")
    exit(nft_rebuild_runtime_from_uci(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12], ARGV[13], ARGV[14], ARGV[15], ARGV[16]) ? 0 : 1);
else if (mode == "nft-apply-candidate-batch")
    exit(nft_apply_candidate_batch(ARGV[1]) ? 0 : 1);
else if (mode == "nft-add-file-chunks-to-set")
    exit(nft_add_file_chunks_to_set(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5] || "", ARGV[6]) ? 0 : 1);
else if (mode == "nft-add-subnet-file-for-uci-section")
    exit(nft_add_subnet_file_for_uci_section(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8]) ? 0 : 1);
else if (mode == "nft-add-json-ruleset-subnets-for-uci-section")
    exit(nft_add_json_ruleset_subnets_for_uci_section(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11]) ? 0 : 1);
else if (mode == "nft-add-community-subnet-file-for-uci-section")
    exit(nft_add_community_subnet_file_for_uci_section(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12], ARGV[13]) ? 0 : 1);
else if (mode == "nft-add-json-ruleset-subnets-for-section-fixture")
    exit(nft_add_json_ruleset_subnets_for_fixture_section(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12]) ? 0 : 1);
else if (mode == "nft-add-community-subnet-file-for-section-fixture")
    exit(nft_add_community_subnet_file_for_fixture_section(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12], ARGV[13], ARGV[14]) ? 0 : 1);
else if (mode == "nft-populate-runtime-sets-from-uci")
    exit(nft_populate_runtime_sets_from_uci(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12]) ? 0 : 1);
else if (mode == "nft-add-direct-quic-rules-fixture")
    exit(nft_add_direct_quic_rules(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6]) ? 0 : 1);
else if (mode == "nft-runtime-signature-fixture")
    exit(nft_runtime_signature_from_fixture(ARGV[1]) ? 0 : 1);
else if (mode == "ensure-tproxy-route-rule")
    exit(ensure_tproxy_route_rule(ARGV[1], ARGV[2], ARGV[3]) ? 0 : 1);
else if (mode == "tproxy-route4-present")
    exit(tproxy_route4_present(ARGV[1]) ? 0 : 1);
else if (mode == "tproxy-route6-present")
    exit(tproxy_route6_present(ARGV[1]) ? 0 : 1);
else if (mode == "source-check-rule4-present")
    exit(source_check_rule4_present(ARGV[1]) ? 0 : 1);
else if (mode == "tproxy-marking-rule4-present")
    exit(tproxy_marking_rule4_present(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "tproxy-marking-rule6-present")
    exit(tproxy_marking_rule6_present(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "tproxy-route-rule-present")
    exit(tproxy_route_rule_present(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "nft-validate-candidate-batch")
    exit(nft_validate_candidate_batch(ARGV[1]) ? 0 : 1);
else if (mode == "nft-commit-candidate-batch")
    exit(nft_commit_candidate_batch(ARGV[1]) ? 0 : 1);
else if (mode == "transition-guard-present")
    exit(nft_transition_guard_present(ARGV[1]) ? 0 : 1);
else if (mode == "install-transition-guard")
    exit(nft_install_transition_guard(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "remove-transition-guard")
    exit(nft_remove_transition_guard(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "ensure-bridge-netfilter-disabled")
    exit(ensure_bridge_netfilter_disabled() ? 0 : 1);
else {
    warn("Usage: nft/apply.uc <operation> ...\n");
    exit(1);
}
