#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let fixture_uci_data = null;
let subscription_parser_module = null;
let constants_module = null;
let core_url = require("core.url");
let core_ip = require("core.ip");
let rule_config = require("config.rule");
let connections = require("config.connections");

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
const DEFAULT_LATENCY_TEST_URL = "https://www.gstatic.com/generate_204";
const TAILSCALE_FWMARK_MASK = 0x00ff0000;

function as_string(value) {
    return value == null ? "" : "" + value;
}

function read_stdin() {
    let input = fs.open("/dev/stdin", "r");
    if (!input)
        return "";
    let data = input.read("all");
    input.close();
    return data == null ? "" : data;
}

function read_json_file(path) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        return null;

    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function string_starts_with(value, prefix) {
    value = as_string(value);
    prefix = as_string(prefix);
    return substr(value, 0, length(prefix)) == prefix;
}

function string_ends_with(value, suffix) {
    value = as_string(value);
    suffix = as_string(suffix);
    return length(value) >= length(suffix) && substr(value, length(value) - length(suffix)) == suffix;
}

function whitespace_values(value) {
    let result = [];
    for (let item in split(trim(as_string(value)), /[ \t\r\n]+/))
        if (item != "")
            push(result, item);
    return result;
}

function option_list_values(section, key) {
    let value = type(section) == "object" ? section[key] : null;
    if (type(value) == "array")
        return value;
    return whitespace_values(value);
}

function list_has_value(values, needle) {
    needle = as_string(needle);
    if (needle == "")
        return false;

    for (let value in whitespace_values(values))
        if (value == needle)
            return true;

    return false;
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function contains(values, needle) {
    for (let value in array_or_empty(values))
        if (value == needle)
            return true;
    return false;
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

function list_option(section, key) {
    let value = object_or_empty(section)[key];
    if (value == null)
        return [];
    if (type(value) == "array")
        return value;

    value = trim(as_string(value));
    return value == "" ? [] : split(value, " ");
}

function bool_option(section, key, fallback) {
    if (fallback == null)
        fallback = false;

    let value = option(section, key, fallback ? "1" : "0");
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function file_executable(path) {
    let stat = fs.stat(as_string(path));
    if (stat == null || stat.mode == null)
        return false;

    return (int(stat.mode) & 73) != 0;
}

function file_nonempty(path) {
    let stat = fs.stat(as_string(path));
    return stat != null && stat.size != null && stat.size > 0;
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
    return system(command_from_args(args)) == 0;
}

function command_success_from_args(args) {
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function command_output(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";

    return as_string(data);
}

function command_output_from_args(args) {
    return command_output(command_from_args(args));
}

function bounded_command_output_from_args(args, timeout_seconds) {
    timeout_seconds = int(timeout_seconds || 5);
    if (timeout_seconds < 1)
        timeout_seconds = 5;
    let directory = type(fs.mkdtemp) == "function"
        ? fs.mkdtemp("/tmp/forkop-validator-version.XXXXXX")
        : trim(command_output_from_args([ "mktemp", "-d", "/tmp/forkop-validator-version.XXXXXX" ]));
    if (directory == null || directory == "")
        return "";
    let path = directory + "/output";
    // exec makes the bounded child the command itself, not a waiting shell.
    let status = system("exec " + command_from_args(args) +
        " >" + shell_quote(path) + " 2>/dev/null", timeout_seconds * 1000);
    let output = status == 0 ? as_string(fs.readfile(path)) : "";
    fs.unlink(path);
    fs.rmdir(directory);
    return output;
}

function command_exists(name) {
    return system("command -v " + shell_quote(name) + " >/dev/null 2>&1") == 0;
}

function installed_sing_box_version() {
    if (command_exists("apk")) {
        let output = command_output_from_args([ "apk", "list", "--installed" ]);
        for (let line in split(output, "\n")) {
            let matched = match(line, /^sing-box-([^ \r\n]+)-r[0-9]+:/);
            if (matched == null)
                matched = match(line, /^sing-box-tiny-([^ \r\n]+)-r[0-9]+:/);
            if (matched != null)
                return replace(as_string(matched[1]), /_/, "-");
        }
    }

    let output = command_output_from_args([ "opkg", "list-installed", "sing-box" ]);
    let matched = match(output, /^sing-box[ \t]+-[ \t]+([^ \r\n]+)/);
    return matched == null ? "" : as_string(matched[1]);
}

function log_message(message, level) {
    level = as_string(level || "info");
    run_args([ "logger", "-t", "forkop", "[" + level + "] " + as_string(message) ]);
}

function fail_requirement(message, level) {
    log_message(message, level || "error");
    exit(1);
}

function first_line_last_field(data) {
    let newline = index(as_string(data), "\n");
    let line = newline >= 0 ? substr(data, 0, newline) : data;
    let fields = split(trim(as_string(line)), /[ \t\r\n]+/);
    return length(fields) > 0 ? as_string(fields[length(fields) - 1]) : "";
}

function digit_char(value) {
    return match(as_string(value), /^[0-9]$/) != null;
}

function strip_leading_zeroes(value) {
    value = as_string(value);
    let i = 0;
    while (i < length(value) - 1 && substr(value, i, 1) == "0")
        i++;
    return substr(value, i);
}

function version_compare(lhs, rhs) {
    lhs = as_string(lhs);
    rhs = as_string(rhs);

    let li = 0, ri = 0;
    while (li < length(lhs) || ri < length(rhs)) {
        if (li >= length(lhs))
            return substr(rhs, ri, 1) == "~" ? 1 : -1;
        if (ri >= length(rhs))
            return substr(lhs, li, 1) == "~" ? -1 : 1;

        let lc = substr(lhs, li, 1);
        let rc = substr(rhs, ri, 1);
        if (lc == rc) {
            li++;
            ri++;
            continue;
        }

        if (lc == "~" || rc == "~")
            return lc == "~" ? -1 : 1;

        if (digit_char(lc) && digit_char(rc)) {
            let ls = li, rs = ri;
            while (li < length(lhs) && digit_char(substr(lhs, li, 1)))
                li++;
            while (ri < length(rhs) && digit_char(substr(rhs, ri, 1)))
                ri++;

            let lnum = strip_leading_zeroes(substr(lhs, ls, li - ls));
            let rnum = strip_leading_zeroes(substr(rhs, rs, ri - rs));
            if (length(lnum) != length(rnum))
                return length(lnum) < length(rnum) ? -1 : 1;
            if (lnum != rnum)
                return lnum < rnum ? -1 : 1;
            continue;
        }

        return lc < rc ? -1 : 1;
    }

    return 0;
}

function version_at_least(current, required) {
    return version_compare(current, required) >= 0;
}

function constant_value(constants, name) {
    return as_string(object_or_empty(constants)[name]);
}

function stdin_first_line_field(field_index) {
    let data = read_stdin();
    let newline = index(data, "\n");
    let line = newline >= 0 ? substr(data, 0, newline) : data;
    let fields = split(trim(as_string(line)), /[ \t\r\n]+/);

    field_index = int(field_index || 0);
    if (field_index > 0 && field_index <= length(fields))
        print(fields[field_index - 1], "\n");
}

function country_code_valid(value) {
    value = uc(as_string(value));
    return match(value, /^[A-Z][A-Z]$/) != null;
}

function regex_valid(pattern) {
    pattern = as_string(pattern);
    if (pattern == "")
        return true;

    try {
        regexp(pattern);
        return true;
    }
    catch (e) {
        return false;
    }
}

function combined_domain_valid(value) {
    value = trim(as_string(value));
    if (value == "")
        return true;

    let normalized = rule_config.prefixed_domain_kind_value(value);
    if (normalized == null)
        return false;

    return normalized.kind != "domain_regex" || regex_valid(normalized.value);
}

function combined_domain_text_valid(value) {
    for (let item in rule_config.text_list_values(value, "comma-space"))
        if (!combined_domain_valid(item))
            return false;
    return true;
}

function community_service_valid(value, services) {
    return list_has_value(services, value);
}

function remote_reference(value) {
    return string_starts_with(value, "http://") || string_starts_with(value, "https://");
}

function absolute_reference_with_extension(value, first_extension, second_extension) {
    value = as_string(value);
    if (!string_starts_with(value, "/"))
        return false;

    return string_ends_with(value, first_extension) ||
        (second_extension != null && string_ends_with(value, second_extension));
}

function ruleset_reference_valid(reference, community_services) {
    reference = as_string(reference);

    return reference == "" ||
        community_service_valid(reference, community_services) ||
        remote_reference(reference) ||
        absolute_reference_with_extension(reference, ".srs", ".json");
}

function plain_domain_ip_list_reference_valid(reference) {
    reference = as_string(reference);

    return reference == "" ||
        remote_reference(reference) ||
        absolute_reference_with_extension(reference, ".lst", null);
}

function outbound_detour_source_action(action) {
    action = as_string(action);
    return connections.is_connections_action(action);
}

function outbound_detour_target_action(action) {
    action = as_string(action);
    return connections.is_connections_action(action);
}

function outbound_detour_rows_by_section(rows) {
    let by_section = {};

    for (let row in array_or_empty(rows))
        if (row.section != "")
            by_section[row.section] = row;

    return {
        rows: rows,
        by_section: by_section
    };
}

function outbound_detour_chain_reaches_source(by_section, source_section, current_section) {
    let seen = {};

    while (current_section != "") {
        if (current_section == source_section)
            return true;

        if (seen[current_section])
            return false;
        seen[current_section] = true;

        let row = by_section[current_section];
        if (type(row) != "object" || !row.enabled || !outbound_detour_source_action(row.action))
            return false;

        if (!row.detour_enabled)
            return false;

        current_section = row.detour_section;
    }

    return false;
}

function fail_outbound_detour(message) {
    print(message, "\n");
    exit(1);
}

function fail_validation(message) {
    print(message, "\n");
    exit(1);
}

function validate_outbound_detours_rows(rows) {
    let parsed = outbound_detour_rows_by_section(rows);

    for (let row in parsed.rows) {
        if (!row.enabled || !row.detour_enabled)
            continue;

        if (!outbound_detour_source_action(row.action))
            fail_outbound_detour("Outbound cascade is supported only for Connection rules, but rule '" +
                row.section + "' uses action '" + row.action + "'. Aborted.");

        if (row.detour_section == "")
            fail_outbound_detour("Outbound cascade is enabled for rule '" + row.section +
                "', but no intermediate rule is selected. Aborted.");

        if (row.detour_section == row.section)
            fail_outbound_detour("Outbound cascade for rule '" + row.section + "' cannot point to itself. Aborted.");

        let target = parsed.by_section[row.detour_section];
        if (type(target) != "object")
            fail_outbound_detour("Outbound cascade for rule '" + row.section + "' references missing rule '" +
                row.detour_section + "'. Select an enabled Connection rule or disable cascade connection. Aborted.");

        if (!target.enabled)
            fail_outbound_detour("Outbound cascade for rule '" + row.section + "' references disabled rule '" +
                row.detour_section + "'. Select an enabled Connection rule or disable cascade connection. Aborted.");

        if (!outbound_detour_target_action(target.action))
            fail_outbound_detour("Outbound cascade for rule '" + row.section + "' references rule '" +
                row.detour_section + "', but it is not a Connection rule. Select an enabled Connection rule or disable cascade connection. Aborted.");

        if (outbound_detour_chain_reaches_source(parsed.by_section, row.section, row.detour_section))
            fail_outbound_detour("Outbound cascade for rule '" + row.section + "' creates a cycle through '" +
                row.detour_section + "'. Aborted.");

    }
}

function download_section_action_available(action) {
    return connections.is_connections_action(as_string(action));
}

function validate_download_section_rows(target_section, rows) {
    target_section = as_string(target_section);

    if (target_section == "")
        fail_validation("Downloading external resources through a section is enabled, but no download section is selected. Aborted.");

    let found = false;
    let enabled = false;
    let outbound = false;
    let target = null;

    for (let row in array_or_empty(rows)) {
        if (row.section != target_section)
            continue;

        found = true;
        target = row;
        if (!row.enabled)
            continue;

        enabled = true;
        if (download_section_action_available(row.action))
            outbound = true;
    }

    if (!found)
        fail_validation("Downloading external resources through a section references missing rule '" + target_section +
            "'. Select an enabled rule that can provide an outbound or disable the option. Aborted.");

    if (!enabled)
        fail_validation("Downloading external resources through a section references disabled rule '" + target_section +
            "'. Select an enabled rule that can provide an outbound or disable the option. Aborted.");

    if (!outbound)
        fail_validation("Downloading external resources through a section references rule '" + target_section +
            "', but it cannot provide an outbound. Select an enabled Connection rule, or disable the option. Aborted.");

    if (connections.is_connections_action(target.action) && !target.has_sources)
        fail_validation("Downloading external resources through section '" + target_section +
            "' is enabled, but that Connection rule has no proxy source. Add a subscription, manual proxy link, interface, or JSON outbound, or disable download-through-section. Aborted.");
}

function dhcp_has_https_dns_proxy_options(path) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        return null;

    return index(data, "doh_backup_noresolv") >= 0 ||
        index(data, "doh_backup_server") >= 0 ||
        index(data, "doh_server") >= 0;
}

function mwan3_has_enabled_interface_from_sections() {
    for (let section in uci_core.section_objects("mwan3", "interface"))
        if (option(section, "enabled", "0") == "1")
            return true;
    return false;
}

function mwan3_is_active() {
    if (!file_executable("/etc/init.d/mwan3") || !file_nonempty("/etc/config/mwan3"))
        return false;

    if (!mwan3_has_enabled_interface_from_sections())
        return false;

    return command_success_from_args([ "/etc/init.d/mwan3", "status" ]) ||
        command_success_from_args([ "/etc/init.d/mwan3", "enabled" ]);
}

function hex_digit_value(value) {
    let pos = index("0123456789abcdef", lc(as_string(value)));
    return pos >= 0 ? pos : null;
}

function parse_number(value) {
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

function subscription_parser() {
    if (subscription_parser_module == null)
        subscription_parser_module = require("subscription.parser");
    return subscription_parser_module;
}

function runtime_constants() {
    if (constants_module == null)
        constants_module = require("core.constants");
    return constants_module;
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

function use_fixture_cursor(path) {
    fixture_uci_data = object_or_empty(read_json_file(path));
    connections.set_item_sections_from_data(fixture_uci_data);
}

function settings_section() {
    if (fixture_uci_data != null)
        return object_or_empty(fixture_get_section("settings"));
    return object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function sections_by_type(type_name) {
    if (fixture_uci_data != null)
        return fixture_section_list(type_name);

    let result = [];
    for (let section in uci_core.section_objects(CONFIG_NAME, type_name))
        push(result, object_or_empty(section));
    return result;
}

function section_name(section) {
    return option(section, ".name", "");
}

function section_enabled(section) {
    return bool_option(section, "enabled", true);
}

function rule_action(section) {
    return option(section, "action", "");
}

function rule_action_supported(action) {
    return contains([ "connection", "proxy", "outbound", "vpn", "bypass", "block", "dns" ], as_string(action));
}

function duration_to_seconds_value(value) {
    let rest = as_string(value);
    if (rest == "")
        return null;

    let total = 0.0;
    let multipliers = {
        ns: 0.000000001,
        us: 0.000001,
        ms: 0.001,
        s: 1,
        m: 60,
        h: 3600,
        d: 86400
    };

    while (rest != "") {
        let matched = match(rest, /^([0-9]+(\.[0-9]+)?)(ns|us|ms|s|m|h|d)/);
        if (!matched)
            return null;

        let token = as_string(matched[0]);
        let amount = matched[1] * 1;
        let unit = matched[3];
        total += amount * multipliers[unit];
        rest = substr(rest, length(token));
    }

    return total <= 0 ? null : int(total + 0.5);
}

function validate_duration_option(value, label) {
    if (as_string(value) == "")
        return;

    if (duration_to_seconds_value(value) != null)
        return;

    fail_validation("Invalid duration value for " + label + ": " + value + ". Use sing-box duration format like 1d, 12h or 30m. Aborted.");
}

function validate_required_duration_option(value, label) {
    if (as_string(value) == "")
        fail_validation("Missing duration value for " + label + ". Use sing-box duration format like 1d, 12h or 30m. Aborted.");

    validate_duration_option(value, label);
}

function dns_server_value_valid(value) {
    value = trim(as_string(value));
    if (value == "" || match(value, /[ \t\r\n@]/) != null)
        return false;

    let host = core_url.host(value);
    if (host == "")
        return false;

    let port = core_url.port(value);
    if (port != "" && (match(port, /^[0-9]+$/) == null || int(port) < 1 || int(port) > 65535))
        return false;

    if (core_ip.valid_ip(host))
        return true;

    return length(host) <= 253 &&
        index(host, ".") > 0 &&
        substr(host, 0, 1) != "." &&
        substr(host, length(host) - 1, 1) != "." &&
        match(host, /[\/:\[\]]/) == null;
}

function dns_setting_values(settings, key) {
    let values = [];
    for (let value in option_list_values(settings, key)) {
        value = trim(as_string(value));
        if (value != "")
            push(values, value);
    }
    return values;
}

function validate_dns_settings(settings, sections, context) {
    if (bool_option(settings, "whatsapp_real_dns", false)) {
        let has_meta = false;
        for (let section in sections) {
            if (!section_enabled(section) || option(section, "action", "") == "dns" ||
                !contains(connections.community_lists(section), "meta"))
                continue;
            if (length(list_option(section, "source_ip_cidr")) == 0 &&
                option(section, "source_ip_cidr_text", "") == "" &&
                length(list_option(section, "ports")) == 0 && option(section, "ports_text", "") == "")
                has_meta = true;
        }
        if (!has_meta)
            fail_validation("WhatsApp real DNS requires the Meta community list in an enabled routing section without source or port filters. Download its subnet lists before enabling this setting. Aborted.");
    }
    let dns_type = option(settings, "dns_type", "udp");
    if (!contains([ "udp", "dot", "doh" ], dns_type))
        fail_validation("Unsupported DNS protocol type '" + dns_type + "'. Use udp, dot, or doh. Aborted.");

    let dns_strategy = option(settings, "dns_strategy", "prefer_ipv4");
    if (!contains([ "prefer_ipv4", "ipv4_only", "prefer_ipv6", "ipv6_only" ], dns_strategy))
        fail_validation("Unsupported DNS strategy '" + dns_strategy + "'. Use prefer_ipv4, ipv4_only, prefer_ipv6, or ipv6_only. Aborted.");

    let main_servers = dns_setting_values(settings, "dns_server");
    let bootstrap_servers = dns_setting_values(settings, "bootstrap_dns_server");
    if (length(main_servers) == 0)
        fail_validation("At least one main DNS server is required. Aborted.");
    if (length(bootstrap_servers) == 0)
        fail_validation("At least one Bootstrap DNS server is required. Aborted.");
    for (let value in main_servers)
        if (!dns_server_value_valid(value))
            fail_validation("Invalid main DNS server '" + value + "'. Aborted.");
    for (let value in bootstrap_servers) {
        if (!dns_server_value_valid(value))
            fail_validation("Invalid Bootstrap DNS server '" + value + "'. Aborted.");
        if (!core_ip.valid_ip(core_url.host(value)))
            log_message("Bootstrap DNS server '" + value + "' uses a hostname; set an IP address to avoid a startup DNS dependency", "warn");
    }

    if (length(main_servers) > 1 || length(bootstrap_servers) > 1) {
        validate_required_duration_option(option(settings, "dns_check_interval", "10s"), "settings.dns_check_interval");
        validate_required_duration_option(option(settings, "dns_recovery_check_interval", "60s"), "settings.dns_recovery_check_interval");
        validate_required_duration_option(option(settings, "dns_check_timeout", "2s"), "settings.dns_check_timeout");
        if (match(option(settings, "dns_failover_failure_threshold", "3"), /^[1-9][0-9]*$/) == null)
            fail_validation("DNS failover failure threshold must be a positive integer. Aborted.");
    }

    if (!bool_option(settings, "dns_detour_enabled", false))
        return;

    let target_name = option(settings, "dns_detour_section", "");
    if (target_name == "")
        fail_validation("DNS through a section is enabled, but no section is selected. Aborted.");

    let target = null;
    for (let section in sections)
        if (section_name(section) == target_name) {
            target = {
                section: target_name,
                enabled: section_enabled(section),
                action: rule_action(section)
            };
            break;
        }

    if (target == null)
        fail_validation("DNS through a section references missing rule '" + target_name + "'. Aborted.");
    if (!target.enabled)
        fail_validation("DNS through a section references disabled rule '" + target_name + "'. Aborted.");
    if (!download_section_action_available(target.action))
        fail_validation("DNS through a section references rule '" + target_name + "' with unsupported action '" + target.action + "'. Select an enabled Connection or VPN section. Aborted.");
}

function normalize_port_number_value(value) {
    value = trim(as_string(value));
    if (value == "" || match(value, /^[0-9]+$/) == null)
        return null;

    let number = int(value);
    return number >= 1 && number <= 65535 ? number : null;
}

function normalize_port_condition_value(value) {
    value = trim(as_string(value));
    if (value == "")
        return null;

    let dash = index(value, "-");
    if (dash < 0)
        return normalize_port_number_value(value);

    let start = normalize_port_number_value(substr(value, 0, dash));
    let end = normalize_port_number_value(substr(value, dash + 1));
    if (start == null || end == null || start > end)
        return null;

    return start == end ? start : sprintf("%d-%d", start, end);
}

function validate_port_condition_value(value, section) {
    if (normalize_port_condition_value(value) != null)
        return;

    fail_validation("Invalid port condition '" + value + "' in rule '" + section + "'. Use a single port or range like 80 or 1000-2000. Aborted.");
}

function validate_subscription_source_entry_value(entry, section) {
    if (index(as_string(entry), "|") >= 0)
        fail_validation("Invalid subscription URL: Configure User-Agent in the subscription item settings. Aborted.");

    let parsed = subscription_parser().parse_subscription_source_entry(entry);
    if (parsed.valid)
        return;

    fail_validation("Invalid subscription URL: " + parsed.error + ". Aborted.");
}

function valid_http_url(value) {
    value = trim(as_string(value));
    if (value == "" || match(value, /[ \t\r\n]/) != null)
        return false;

    let scheme = lc(core_url.scheme(value));
    if (scheme != "http" && scheme != "https")
        return false;

    return core_url.host(value) != "";
}

function validate_http_url_option(value, label) {
    if (valid_http_url(value))
        return;

    fail_validation("Invalid URL value for " + label + ": " + value + ". Use http:// or https:// URL. Aborted.");
}

function validate_country_code_value(value, section) {
    if (as_string(value) == "" || country_code_valid(value))
        return;

    fail_validation("Invalid country code '" + value + "' in rule '" + section + "'. Aborted.");
}

function validate_urltest_filter_mode_value(value, section) {
    if (as_string(value) == "" || contains([ "disabled", "exclude", "include", "mixed" ], value))
        return;

    fail_validation("Invalid URLTest filter mode '" + value + "' in rule '" + section + "'. Aborted.");
}

function validate_priority_filter_mode_value(value, section, group_id, level_id) {
    if (contains([ "disabled", "exclude", "include", "mixed" ], value))
        return;

    fail_validation("Invalid Priority filter mode '" + value + "' in rule '" + section + "', priority '" + group_id + "', level '" + level_id + "'. Aborted.");
}

function validate_detect_server_country_value(value, section) {
    if (as_string(value) == "" || contains([ "flag_emoji", "country_is" ], value))
        return;

    fail_validation("Invalid server country detection mode '" + value + "' in rule '" + section + "'. Aborted.");
}

function validate_proxy_parameter_value(value, allowed, parameter, section) {
    value = lc(as_string(value));
    if (value == "" || contains(allowed, value))
        return;

    fail_validation("Invalid proxy " + parameter + " '" + value + "' in rule '" + section + "'. Aborted.");
}

function validate_proxy_parameter_filters(protocols, transports, securities, section) {
    for (let value in protocols)
        validate_proxy_parameter_value(value,
            [ "direct", "http", "hysteria2", "shadowsocks", "socks", "trojan", "vless", "vmess" ],
            "protocol", section);
    for (let value in transports)
        validate_proxy_parameter_value(value,
            [ "tcp", "ws", "grpc", "http", "httpupgrade", "xhttp" ],
            "transport", section);
    for (let value in securities)
        validate_proxy_parameter_value(value, [ "none", "tls", "reality" ], "security", section);
}

function validate_urltest_regex_value(value, section) {
    if (as_string(value) == "" || regex_valid(value))
        return;

    fail_validation("Invalid URLTest regular expression '" + value + "' in rule '" + section + "'. Aborted.");
}

function validate_urltest_identifier_value(value, section) {
    value = as_string(value);
    if (value != "" && match(value, /^[A-Za-z0-9_]+$/) != null)
        return;

    fail_validation("Invalid URLTest identifier '" + value + "' in rule '" + section + "'. Use latin letters, digits and underscores. Aborted.");
}

function validate_priority_identifier_value(value, section) {
    value = as_string(value);
    if (value != "" && match(value, /^[A-Za-z0-9_]+$/) != null)
        return;

    fail_validation("Invalid priority identifier '" + value + "' in rule '" + section + "'. Use latin letters, digits and underscores. Aborted.");
}

function validate_urltest_tolerance_value(value, section, urltest_id) {
    value = trim(as_string(value));
    if (match(value, /^[0-9]+$/) != null) {
        let parsed = int(value, 10);
        if (parsed >= 0 && parsed <= 10000)
            return;
    }

    fail_validation("Invalid URLTest tolerance '" + value + "' in rule '" + section + "', URLTest '" + urltest_id + "'. Use a number from 0 to 10000. Aborted.");
}

function validate_priority_level_order(value, section, group_id, level_id) {
    value = trim(as_string(value));
    if (match(value, /^[0-9]+$/) != null)
        return;

    fail_validation("Invalid priority level order '" + value + "' in rule '" + section + "', priority '" + group_id + "', level '" + level_id + "'. Use a non-negative integer. Aborted.");
}

function validate_priority_group(section, group_id) {
    let name = section_name(section);
    validate_priority_identifier_value(group_id, name);

    if (trim(connections.priority_group_display_name(section, group_id)) == "")
        fail_validation("Priority group '" + group_id + "' in rule '" + name + "' has no display name. Aborted.");

    validate_http_url_option(connections.priority_group_health_url(section, group_id), "rule." + name + ".priority." + group_id + ".health_url");
    validate_required_duration_option(connections.priority_group_active_check_interval(section, group_id), "rule." + name + ".priority." + group_id + ".active_check_interval");
    validate_required_duration_option(connections.priority_group_check_timeout(section, group_id), "rule." + name + ".priority." + group_id + ".check_timeout");
    validate_required_duration_option(connections.priority_group_recovery_check_interval(section, group_id), "rule." + name + ".priority." + group_id + ".recovery_check_interval");
    if (connections.priority_group_switch_to_faster_same_priority(section, group_id))
        validate_required_duration_option(connections.priority_group_fastest_check_interval(section, group_id), "rule." + name + ".priority." + group_id + ".fastest_check_interval");

    for (let level_id in connections.priority_levels(group_id)) {
        validate_priority_identifier_value(level_id, name);
        if (trim(connections.priority_level_display_name(group_id, level_id)) == "")
            fail_validation("Priority level '" + level_id + "' in rule '" + name + "', priority '" + group_id + "' has no display name. Aborted.");

        validate_priority_level_order(connections.priority_level_order(group_id, level_id), name, group_id, level_id);
        if (connections.priority_level_direct(group_id, level_id))
            continue;

        let filter_mode = connections.priority_level_filter_mode(group_id, level_id);
        validate_priority_filter_mode_value(filter_mode, name, group_id, level_id);
        if (filter_mode != "disabled")
            validate_detect_server_country_value(connections.priority_level_detect_server_country(group_id, level_id), name);
        if (filter_mode == "include" || filter_mode == "mixed") {
            for (let value in connections.priority_level_include_countries(group_id, level_id))
                validate_country_code_value(value, name);
            for (let value in connections.priority_level_include_regex(group_id, level_id))
                validate_urltest_regex_value(value, name);
            if (connections.priority_level_include_proxy_parameters(group_id, level_id))
                validate_proxy_parameter_filters(
                    connections.priority_level_include_protocols(group_id, level_id),
                    connections.priority_level_include_transports(group_id, level_id),
                    connections.priority_level_include_securities(group_id, level_id),
                    name
                );
        }
        if (filter_mode == "exclude" || filter_mode == "mixed") {
            for (let value in connections.priority_level_exclude_countries(group_id, level_id))
                validate_country_code_value(value, name);
            for (let value in connections.priority_level_exclude_regex(group_id, level_id))
                validate_urltest_regex_value(value, name);
            if (connections.priority_level_exclude_proxy_parameters(group_id, level_id))
                validate_proxy_parameter_filters(
                    connections.priority_level_exclude_protocols(group_id, level_id),
                    connections.priority_level_exclude_transports(group_id, level_id),
                    connections.priority_level_exclude_securities(group_id, level_id),
                    name
                );
        }
    }
}

function validate_combined_domain_value(value, section) {
    if (as_string(value) == "" || combined_domain_valid(value))
        return;

    fail_validation("Invalid domain condition '" + value + "' in rule '" + section + "'. Use plain domains or full:, keyword:, regex: prefixes. Aborted.");
}

function validate_combined_domain_text_value(value, section) {
    if (as_string(value) == "" || combined_domain_text_valid(value))
        return;

    fail_validation("Invalid domain conditions in rule '" + section + "'. Use plain domains or full:, keyword:, regex: prefixes. Aborted.");
}

function validate_service_value(service, context) {
    if (community_service_valid(service, context.community_services))
        return;

    fail_validation("Invalid service in community lists: " + service + ". Check config and LuCI cache. Aborted.");
}

function validate_ruleset_reference_value(reference, context) {
    if (ruleset_reference_valid(reference, context.community_services))
        return;

    fail_validation("Unknown rule set reference '" + reference + "'. Aborted.");
}

function validate_plain_domain_ip_list_reference_value(reference) {
    if (plain_domain_ip_list_reference_valid(reference))
        return;

    fail_validation("Unknown plain list reference '" + reference + "'. Aborted.");
}

function validate_common_rule_references(section, context) {
    for (let value in connections.community_lists(section))
        validate_service_value(value, context);
    for (let value in connections.rule_sets(section))
        validate_ruleset_reference_value(value, context);
    for (let value in connections.rule_sets_with_subnets(section))
        validate_ruleset_reference_value(value, context);
    for (let value in list_option(section, "domain_ip_lists"))
        validate_plain_domain_ip_list_reference_value(value);
}

function outbound_json_object(value) {
    try {
        value = json(as_string(value));
    }
    catch (e) {
        return null;
    }

    return type(value) == "object" ? value : null;
}

function valid_outbound_json(value) {
    value = outbound_json_object(value);
    return value != null && type(value.type) == "string" && trim(as_string(value.type)) != "";
}

function validate_outbound_json_rule(section) {
    let name = section_name(section);
    let outbound_json = option(section, "outbound_json", "");

    if (outbound_json == "")
        fail_validation("JSON outbound rule '" + name + "' has empty outbound_json. Aborted.");

    if (!valid_outbound_json(outbound_json))
        fail_validation("JSON outbound rule '" + name + "' must contain a valid sing-box outbound JSON object with a type field. Aborted.");
}

function validate_outbound_json_values(section) {
    let name = section_name(section);
    let values = connections.outbound_jsons(section);
    let require_user_tag = length(list_option(section, "outbound_jsons")) > 0;
    let tags = {};

    for (let value in values) {
        if (as_string(value) == "")
            fail_validation("Connection rule '" + name + "' has empty JSON outbound. Aborted.");

        if (!valid_outbound_json(value))
            fail_validation("Connection rule '" + name + "' must contain valid sing-box outbound JSON objects with a type field. Aborted.");

        let outbound = outbound_json_object(value);
        let tag_name = trim(as_string(outbound.tag || ""));
        if (tag_name == "" && require_user_tag)
            fail_validation("Connection rule '" + name + "' has JSON outbound without a non-empty tag. Aborted.");
        if (tag_name != "" && tags[tag_name])
            fail_validation("Connection rule '" + name + "' has duplicate JSON outbound tag '" + tag_name + "'. Aborted.");
        if (tag_name != "")
            tags[tag_name] = true;
    }
}

function rule_has_subscription_urls(section) {
    return length(connections.subscription_urls(section)) > 0;
}

function subscription_update_interval_for_source(section, entry) {
    if (!connections.subscription_update_enabled(section, entry))
        return "";
    let value = connections.subscription_update_interval(section, entry);
    return value != "" ? value : "4h";
}

function validate_subscription_request_profile(section, entry) {
    if (connections.subscription_auto_hwid(section, entry))
        return;

    if (connections.subscription_hwid(section, entry) != "")
        return;

    fail_validation("Subscription source in rule '" + section_name(section) + "' has manual HWID enabled but HWID is empty. Fill HWID or enable auto-generation. Aborted.");
}

function dns_action_has_domain_matchers(section) {
    for (let key in [ "domain", "domain_suffix", "domain_keyword", "domain_regex" ])
        if (option(section, key, "") != "" || option(section, key + "_text", "") != "" || length(list_option(section, key)) > 0)
            return true;

    return length(connections.community_lists(section)) > 0 ||
        length(connections.rule_sets(section)) > 0 ||
        length(list_option(section, "domain_ip_lists")) > 0;
}

function validate_dns_action(section, sections, context) {
    let name = section_name(section);
    let dns_type = option(section, "dns_type", "udp");
    if (!contains([ "udp", "dot", "doh" ], dns_type))
        fail_validation("DNS rule '" + name + "' uses unsupported protocol '" + dns_type + "'. Use udp, dot, or doh. Aborted.");
    let dns_server = option(section, "dns_server", "");
    if (!dns_server_value_valid(dns_server))
        fail_validation("DNS rule '" + name + "' has an invalid DNS server '" + dns_server + "'. Aborted.");
    if (length(connections.rule_sets_with_subnets(section)) > 0)
        fail_validation("DNS rule '" + name + "' can use domain-only rule sets, but subnet extraction is enabled. Disable 'Include IP addresses and subnets'. Aborted.");
    if (!dns_action_has_domain_matchers(section) && length(list_option(section, "fully_routed_ips")) == 0)
        fail_validation("DNS rule '" + name + "' must contain at least one domain condition or domain rule set. Aborted.");
    if (!bool_option(section, "dns_detour_enabled", false))
        return;

    let target_name = option(section, "dns_detour_section", "");
    if (target_name == "")
        fail_validation("DNS rule '" + name + "' routes DNS through a section, but no section is selected. Aborted.");
    if (target_name == name)
        fail_validation("DNS rule '" + name + "' cannot use itself as a DNS detour. Aborted.");

    let target = null;
    for (let candidate in sections)
        if (section_name(candidate) == target_name) {
            target = candidate;
            break;
        }
    if (target == null)
        fail_validation("DNS rule '" + name + "' references missing detour section '" + target_name + "'. Aborted.");
    if (!section_enabled(target))
        fail_validation("DNS rule '" + name + "' references disabled detour section '" + target_name + "'. Aborted.");
    if (!download_section_action_available(rule_action(target)))
        fail_validation("DNS rule '" + name + "' references detour section '" + target_name + "' with unsupported action '" + rule_action(target) + "'. Select an enabled Connection or VPN section. Aborted.");
}

function validate_rule(section, sections, context) {
    if (!section_enabled(section))
        return;

    let name = section_name(section);
    let action = rule_action(section);
    if (action == "")
        fail_validation("Enabled rule '" + name + "' has no action. Aborted.");
    if (!rule_action_supported(action))
        fail_validation("Enabled rule '" + name + "' uses unsupported action '" + action + "'. Aborted.");

    if (action != "dns")
        for (let value in list_option(section, "ports"))
            validate_port_condition_value(value, name);

    if (action == "dns")
        validate_dns_action(section, sections, context);

    if (connections.is_connections_action(action)) {

        for (let urltest_id in connections.urltests(section)) {
            validate_urltest_identifier_value(urltest_id, name);

            let urltest_filter_mode = connections.urltest_filter_mode(section, urltest_id);
            validate_urltest_filter_mode_value(urltest_filter_mode, name);
            if (contains([ "exclude", "include", "mixed" ], urltest_filter_mode))
                validate_detect_server_country_value(connections.urltest_detect_server_country(section, urltest_id), name);

            validate_required_duration_option(connections.urltest_check_interval(section, urltest_id), "rule." + name + ".urltest." + urltest_id + ".urltest_check_interval");
            validate_urltest_tolerance_value(connections.urltest_tolerance(section, urltest_id), name, urltest_id);
            validate_http_url_option(connections.urltest_testing_url(section, urltest_id), "rule." + name + ".urltest." + urltest_id + ".testing_url");
            let idle_timeout = connections.urltest_idle_timeout(section, urltest_id);
            if (idle_timeout != "")
                validate_required_duration_option(idle_timeout, "rule." + name + ".urltest." + urltest_id + ".idle_timeout");

            if (contains([ "include", "mixed" ], urltest_filter_mode)) {
                for (let value in connections.urltest_include_regex(section, urltest_id))
                    validate_urltest_regex_value(value, name);
                for (let value in connections.urltest_include_countries(section, urltest_id))
                    validate_country_code_value(value, name);
                if (connections.urltest_include_proxy_parameters(section, urltest_id))
                    validate_proxy_parameter_filters(
                        connections.urltest_include_protocols(section, urltest_id),
                        connections.urltest_include_transports(section, urltest_id),
                        connections.urltest_include_securities(section, urltest_id),
                        name
                    );
            }
            if (contains([ "exclude", "mixed" ], urltest_filter_mode)) {
                for (let value in connections.urltest_exclude_countries(section, urltest_id))
                    validate_country_code_value(value, name);
                for (let value in connections.urltest_exclude_regex(section, urltest_id))
                    validate_urltest_regex_value(value, name);
                if (connections.urltest_exclude_proxy_parameters(section, urltest_id))
                    validate_proxy_parameter_filters(
                        connections.urltest_exclude_protocols(section, urltest_id),
                        connections.urltest_exclude_transports(section, urltest_id),
                        connections.urltest_exclude_securities(section, urltest_id),
                        name
                    );
            }
        }

        for (let group_id in connections.priority_groups(section))
            validate_priority_group(section, group_id);

        if (rule_has_subscription_urls(section)) {
            for (let value in connections.subscription_urls(section)) {
                validate_subscription_source_entry_value(value, name);
                validate_subscription_request_profile(section, value);
                for (let regex in connections.subscription_exclude_regex(section, value))
                    validate_urltest_regex_value(regex, name);
                let subscription_update_interval = subscription_update_interval_for_source(section, value);
                if (subscription_update_interval != "")
                    validate_required_duration_option(subscription_update_interval, "rule." + name + ".subscription_update_interval");
            }
        }

        validate_outbound_json_values(section);
    }

    if (action == "outbound")
        validate_outbound_json_rule(section);

    validate_combined_domain_text_value(option(section, "domain", ""), name);
    for (let value in list_option(section, "domain_suffix"))
        validate_combined_domain_value(value, name);
    validate_combined_domain_text_value(option(section, "domain_suffix_text", ""), name);
    validate_common_rule_references(section, context);
}

function download_via_proxy_option_for_purpose(purpose) {
    purpose = as_string(purpose || "lists");
    if (purpose == "lists")
        return "download_lists_via_proxy";
    if (purpose == "components")
        return "download_components_via_proxy";
    return "";
}

function download_via_proxy_section_option_for_purpose(purpose) {
    purpose = as_string(purpose || "lists");
    if (purpose == "lists")
        return "download_lists_via_proxy_section";
    if (purpose == "components")
        return "download_components_via_proxy_section";
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

function basic_rows_from_sections(sections) {
    let rows = [];
    for (let section in sections) {
        push(rows, {
            section: section_name(section),
            enabled: section_enabled(section),
            action: rule_action(section),
            has_sources: connections.has_connection_sources(section)
        });
    }
    return rows;
}

function detour_rows_from_sections(sections) {
    let rows = [];
    for (let section in sections) {
        push(rows, {
            section: section_name(section),
            enabled: section_enabled(section),
            action: rule_action(section),
            detour_enabled: bool_option(section, "outbound_detour_enabled", false),
            detour_section: option(section, "outbound_detour_section", "")
        });
    }
    return rows;
}

function validate_subscription_download_sections(sections, context) {
    let rows = basic_rows_from_sections(sections);

    for (let section in sections) {
        section = object_or_empty(section);
        if (!section_enabled(section))
            continue;

        let name = section_name(section);
        for (let entry in connections.subscription_urls(section)) {
            let target = connections.subscription_download_section(section, entry);
            if (target == "")
                continue;

            if (target == name)
                fail_validation("Subscription source in rule '" + name + "' cannot be downloaded through the same rule. Select another rule or disable download-through-section. Aborted.");

            validate_download_section_rows(target, rows);
        }
    }
}

function validate_list_update_settings(settings) {
    if (!bool_option(settings, "list_update_enabled", true))
        return;

    let update_interval = option(settings, "update_interval", "1d");
    if (update_interval == "")
        update_interval = "1d";
    validate_required_duration_option(update_interval, "settings.update_interval");
}

function validate_runtime_mark_ranges_context(context) {
    let fakeip_mark = parse_number(context.nft_fakeip_mark);
    let outbound_mark = parse_number(context.nft_outbound_mark);
    let router_mark = parse_number(context.nft_router_mark);

    if (fakeip_mark == null || outbound_mark == null || router_mark == null)
        fail_validation("Forkop marks contain invalid numeric constants. Aborted.");
    if ((fakeip_mark & TAILSCALE_FWMARK_MASK) != 0)
        fail_validation("FakeIP mark overlaps Tailscale fwmark mask 0x00ff0000. Aborted.");
    if ((outbound_mark & TAILSCALE_FWMARK_MASK) != 0)
        fail_validation("Outbound mark overlaps Tailscale fwmark mask 0x00ff0000. Aborted.");
    if ((router_mark & TAILSCALE_FWMARK_MASK) != 0)
        fail_validation("Router mark overlaps Tailscale fwmark mask 0x00ff0000. Aborted.");
    if (fakeip_mark == outbound_mark)
        fail_validation("FakeIP mark and outbound mark are the same value. Aborted.");
    // The source-check rule reads the FakeIP mark alone, so a shared bit would
    // send the router's own rerouting lookup to the main table.
    if ((router_mark & (fakeip_mark | outbound_mark)) != 0)
        fail_validation("Router mark shares bits with the FakeIP or outbound mark. Aborted.");
}

function validate_runtime_config(context) {
    let settings = settings_section();
    let sections = sections_by_type("section");

    validate_runtime_mark_ranges_context(context);
    validate_dns_settings(settings, sections, context);
    validate_list_update_settings(settings);
    validate_http_url_option(option(settings, "latency_test_url", DEFAULT_LATENCY_TEST_URL) || DEFAULT_LATENCY_TEST_URL, "settings.latency_test_url");
    for (let value in list_option(settings, "subscription_exclude_regex", []))
        validate_urltest_regex_value(value, "settings");

    if (download_via_proxy_enabled(settings, "lists")) {
        validate_download_section_rows(
            download_via_proxy_section(settings, "lists"),
            basic_rows_from_sections(sections)
        );
    }
    if (download_via_proxy_enabled(settings, "components")) {
        validate_download_section_rows(
            download_via_proxy_section(settings, "components"),
            basic_rows_from_sections(sections)
        );
    }

    validate_outbound_detours_rows(detour_rows_from_sections(sections));
    validate_subscription_download_sections(sections, context);

    for (let section in sections)
        validate_rule(section, sections, context);
}

function context_from_runtime() {
    let constants = object_or_empty(runtime_constants());

    return {
        constants,
        community_services: constant_value(constants, "COMMUNITY_SERVICES"),
        nft_fakeip_mark: constant_value(constants, "NFT_FAKEIP_MARK"),
        nft_outbound_mark: constant_value(constants, "NFT_OUTBOUND_MARK"),
        nft_router_mark: constant_value(constants, "NFT_ROUTER_MARK"),
        sing_box_required_version: constant_value(constants, "SB_REQUIRED_VERSION"),
        sing_box_variant_state_file: constant_value(constants, "SB_VARIANT_STATE_FILE"),
        sing_box_version_state_file: constant_value(constants, "SB_VERSION_STATE_FILE"),
        sing_box_managed_service_marker: constant_value(constants, "SB_MANAGED_SERVICE_MARKER")
    };
}

function sing_box_variant_marker(ctx, value) {
    let path = as_string(ctx.sing_box_variant_state_file);
    if (path == "")
        path = "/etc/forkop/sing-box-variant";

    let data = fs.readfile(path);
    return trim(as_string(data)) == as_string(value);
}

function sing_box_compressed_marker_set(ctx) {
    return sing_box_variant_marker(ctx, "extended-compressed");
}

function sing_box_version_state(ctx) {
    let path = as_string(ctx.sing_box_version_state_file);
    if (path == "")
        path = "/etc/forkop/sing-box-version";

    let data = fs.readfile(path);
    if (data == null)
        return "";

    let newline = index(data, "\n");
    return newline >= 0 ? substr(data, 0, newline) : as_string(data);
}

function managed_sing_box_service_script(marker) {
    marker = as_string(marker);
    if (marker == "")
        marker = "Forkop managed sing-box service for binary variants";

    return "#!/bin/sh /etc/rc.common\n" +
        "# " + marker + "\n" +
        "\n" +
        "USE_PROCD=1\n" +
        "START=99\n" +
        "PROG=\"/usr/bin/sing-box\"\n" +
        "\n" +
        "start_service() {\n" +
        "    config_load \"sing-box\"\n" +
        "    local enabled config_file working_directory\n" +
        "    local log_stderr\n" +
        "\n" +
        "    config_get_bool enabled \"main\" \"enabled\" \"0\"\n" +
        "    [ \"$enabled\" -eq \"1\" ] || return 0\n" +
        "\n" +
        "    config_get config_file \"main\" \"conffile\" \"/etc/sing-box/config.json\"\n" +
        "    config_get working_directory \"main\" \"workdir\" \"/usr/share/sing-box\"\n" +
        "    mkdir -p \"$working_directory\" || return 1\n" +
        "    config_get_bool log_stderr \"main\" \"log_stderr\" \"1\"\n" +
        "\n" +
        "    procd_open_instance\n" +
        "    procd_set_param command \"$PROG\" run -c \"$config_file\" -D \"$working_directory\"\n" +
        "    procd_set_param stderr \"$log_stderr\"\n" +
        "    procd_set_param limits core=\"unlimited\"\n" +
        "    procd_set_param limits nofile=\"1000000 1000000\"\n" +
        "    procd_set_param respawn\n" +
        "    procd_close_instance\n" +
        "}\n" +
        "\n" +
        "service_triggers() {\n" +
        "    procd_add_reload_trigger \"sing-box\"\n" +
        "}\n";
}

function install_managed_sing_box_service_script(ctx) {
    let stamp = clock();
    let tmp_file = sprintf("/etc/init.d/sing-box.forkop.%d.%d", stamp[0], stamp[1]);

    if (!fs.writefile(tmp_file, managed_sing_box_service_script(ctx.sing_box_managed_service_marker)))
        return false;

    if (!run_args([ "chmod", "0755", tmp_file ]) || !run_args([ "mv", "-f", tmp_file, "/etc/init.d/sing-box" ])) {
        fs.unlink(tmp_file);
        return false;
    }

    return true;
}

function service_exists(service) {
    return file_executable("/etc/init.d/" + as_string(service));
}

// Forkop no longer installs sing-box-extended. A build placed by hand in
// /usr/bin/sing-box, or kept from a legacy installation, is the unpackaged
// (compressed) variant: record it and give it Forkop's managed service when
// it has none or only another tool's binary-variant service. A service the
// user wrote is left as it is.
function adopt_unpackaged_extended_sing_box(ctx, version) {
    if (sing_box_compressed_marker_set(ctx) || !command_exists("sing-box") ||
        index(as_string(version), "extended") < 0)
        return;
    let service = as_string(fs.readfile("/etc/init.d/sing-box") || "");
    let foreign_managed = index(service, "managed sing-box service for binary variants") >= 0 &&
        index(service, as_string(ctx.sing_box_managed_service_marker)) < 0;
    if (service_exists("sing-box") && !foreign_managed)
        return;
    let lib = getenv("FORKOP_LIB") || "/usr/lib/forkop";
    for (let name in [ "rust-x", "sing-box-x", "sing-box-extended", "sing-box-tiny", "sing-box" ])
        if (run_args([ "ucode", "-L", lib, lib + "/core/packages.uc", "installed", name ]))
            return;

    let marker = as_string(ctx.sing_box_variant_state_file) || "/etc/forkop/sing-box-variant";
    let version_file = as_string(ctx.sing_box_version_state_file) || "/etc/forkop/sing-box-version";
    if (!run_args([ "mkdir", "-p", replace(marker, /\/[^\/]*$/, ""), replace(version_file, /\/[^\/]*$/, "") ]) ||
        !fs.writefile(version_file, as_string(version) + "\n") ||
        !fs.writefile(marker, "extended-compressed\n"))
        return;
    if (foreign_managed)
        fs.unlink("/etc/init.d/sing-box");
    log_message("Using the manually installed sing-box-extended binary " + as_string(version) + " with the Forkop managed service", "info");
}

function has_outbound_section(ctx) {
    for (let section in sections_by_type("section")) {
        if (!section_enabled(section))
            continue;

        if (length(connections.connection_urls(section)) > 0 ||
            length(connections.subscription_urls(section)) > 0 ||
            length(connections.outbound_jsons(section)) > 0 ||
            length(connections.interfaces(section)) > 0)
            return true;
    }

    return false;
}

function has_discord_cloudflare_overlap() {
    let discord = false;
    let cloudflare = false;

    for (let section in sections_by_type("section")) {
        if (!section_enabled(section))
            continue;
        for (let service in connections.community_lists(section)) {
            service = lc(as_string(service));
            if (service == "discord")
                discord = true;
            else if (service == "cloudflare")
                cloudflare = true;
        }
    }

    return discord && cloudflare;
}

function check_runtime_requirements() {
    log_message("Checking required packages and runtime settings", "info");

    let ctx = context_from_runtime();

    // Advisory only: Cloudflare is intentionally broad, but combining it
    // with Discord makes the overlap easy to miss when sections differ.
    if (has_discord_cloudflare_overlap())
        log_message("[routing-warning] discord-cloudflare-overlap: Discord and Cloudflare built-in lists are enabled together; broad Cloudflare ranges may route unrelated traffic, including torrents, through a proxy or VPN depending on section order", "warn");

    if (!command_exists("nft"))
        fail_requirement("Required nftables executable 'nft' is missing. Install package 'nftables-json' and start Forkop again. Aborted.", "error");

    let sing_box_version_output = command_exists("sing-box") ? bounded_command_output_from_args([ "sing-box", "version" ], 5) : "";
    let sing_box_version = sing_box_compressed_marker_set(ctx) ? sing_box_version_state(ctx) : first_line_last_field(sing_box_version_output);
    if (sing_box_version == "")
        sing_box_version = installed_sing_box_version();

    if (sing_box_version == "") {
        if (!command_exists("sing-box") || !sing_box_compressed_marker_set(ctx))
            fail_requirement("Package 'sing-box' is not installed. Aborted.", "error");
    }
    else if (!version_at_least(sing_box_version, ctx.sing_box_required_version)) {
        fail_requirement("Package 'sing-box' version (" + sing_box_version + ") is lower than the required minimum (" + ctx.sing_box_required_version + "). Update sing-box: opkg update && opkg remove sing-box && opkg install sing-box. Aborted.", "error");
    }

    adopt_unpackaged_extended_sing_box(ctx, sing_box_version);
    if (!service_exists("sing-box") && sing_box_compressed_marker_set(ctx))
        install_managed_sing_box_service_script(ctx);

    if (!service_exists("sing-box"))
        fail_requirement("Service 'sing-box' is missing. Install a sing-box package or place a sing-box-extended binary in /usr/bin/sing-box. Aborted.", "error");


    if (dhcp_has_https_dns_proxy_options("/etc/config/dhcp") === true)
        log_message("https-dns-proxy is enabled in DHCP config. Disable it or edit /etc/config/dhcp before starting Forkop.", "error");

    if (has_outbound_section(ctx))
        log_message("Proxy outbound configuration found", "debug");
    else
        log_message("No proxy outbound sections found. Forkop will use direct and/or provider-only routing.", "warn");

}

function context_override_value(overrides, defaults, key) {
    let value = object_or_empty(overrides)[key];
    if (value != null)
        return as_string(value);
    return as_string(object_or_empty(defaults)[key]);
}

function context_from_json(value, defaults) {
    try {
        value = json(as_string(value));
    }
    catch (e) {
        value = {};
    }

    value = object_or_empty(value);
    defaults = object_or_empty(defaults);

    return {
        community_services: context_override_value(value, defaults, "community_services"),
        nft_fakeip_mark: context_override_value(value, defaults, "nft_fakeip_mark"),
        nft_outbound_mark: context_override_value(value, defaults, "nft_outbound_mark"),
        nft_router_mark: context_override_value(value, defaults, "nft_router_mark")
    };
}

let mode = ARGV[0] || "";

if (mode == "stdin-first-line-field")
    stdin_first_line_field(ARGV[1]);
else if (mode == "mwan3-is-active")
    exit(mwan3_is_active() ? 0 : 1);
else if (mode == "check-requirements")
    check_runtime_requirements();
else if (mode == "validate-runtime")
    validate_runtime_config(context_from_runtime());
else if (mode == "validate-runtime-fixture") {
    use_fixture_cursor(ARGV[1]);
    validate_runtime_config(context_from_json(ARGV[2], context_from_runtime()));
}
else {
    warn("Usage: config/validator.uc <operation> ...\n");
    exit(1);
}
