#!/usr/bin/env ucode

let fs = require("fs");
let mark_rules = require("diagnostics.mark_rules");
let core_url = require("core.url");

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

function read_stdin_json() {
    try {
        return json(read_stdin());
    }
    catch (e) {
        return null;
    }
}

function proxy_response_is_retryable_error() {
    let response = read_stdin();
    return index(response, "<html") == 0 || index(response, "403 Forbidden") >= 0;
}

function read_json_file(path) {
    let data = fs.readfile(path);
    if (data == null)
        return null;

    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function write_json_file(path, value) {
    return fs.writefile(path, sprintf("%J", value) + "\n");
}

function parse_json_or_null(value) {
    try {
        return json(as_string(value));
    }
    catch (e) {
        return null;
    }
}

function number_value(value) {
    value = as_string(value);
    return value == "" ? 0 : int(value);
}

function stdin_first_line_last_field() {
    let input = read_stdin();
    if (input == "")
        return;

    let newline = index(input, "\n");
    let line = newline >= 0 ? substr(input, 0, newline) : input;
    let trimmed = trim(line);
    if (trimmed == "") {
        print(line, "\n");
        return;
    }

    let fields = split(trimmed, /[ \t\r\n]+/);
    if (length(fields) > 0 && fields[0] != "")
        print(fields[length(fields) - 1], "\n");
    else
        print("\n");
}

function stdin_first_ipv4_line() {
    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (match(line, /^[0-9]+\./) != null) {
            print(line, "\n");
            return;
        }
    }
}

function stdin_contains(needle) {
    exit(index(read_stdin(), as_string(needle)) >= 0 ? 0 : 1);
}

function uci_show_value(line) {
    let equals = index(as_string(line), "=");
    if (equals < 0)
        return "";

    let value = substr(line, equals + 1);
    let next_equals = index(value, "=");
    if (next_equals >= 0)
        value = substr(value, 0, next_equals);

    return replace(value, /['" ]/g, "");
}

function first_two_dot_fields(value) {
    let parts = split(as_string(value), ".");
    return length(parts) >= 2 ? parts[0] + "." + parts[1] : as_string(value);
}

function whitespace_values(value) {
    let result = [];
    for (let item in split(trim(as_string(value)), /[ \t\r\n]+/))
        if (item != "")
            push(result, item);
    return result;
}

function value_in_list(values, needle) {
    for (let value in values)
        if (as_string(value) == as_string(needle))
            return true;
    return false;
}

function network_endpoint_host_warnings(octets) {
    let cloudflare_octets = whitespace_values(octets);

    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (index(line, "endpoint_host") < 0)
            continue;

        let host = uci_show_value(line);
        if (host == "")
            continue;

        if (host == "engage.cloudflareclient.com") {
            print("engage\t", host, "\n");
            continue;
        }

        if (value_in_list(cloudflare_octets, first_two_dot_fields(host)))
            print("prefix\t", host, "\n");
    }
}

function network_wireguard_route_allowed_peers() {
    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (index(line, "wireguard_") < 0 || index(line, ".route_allowed_ips=") < 0)
            continue;
        if (uci_show_value(line) != "1")
            continue;

        let route_option = index(line, ".route_allowed_ips=");
        if (route_option > 0)
            print(substr(line, 0, route_option), "\n");
    }
}

function wan_config_masked(path) {
    let data = fs.readfile(path);
    let in_wan = false;
    let proto = "";

    if (data == null)
        exit(1);

    let lines = split(as_string(data), "\n");
    for (let i = 0; i < length(lines); i++) {
        let line = lines[i];
        if (i == length(lines) - 1 && line == "" && substr(as_string(data), length(data) - 1) == "\n")
            continue;

        let fields = split(trim(as_string(line)), /[ \t\r\n]+/);
        if (length(fields) > 0 && fields[0] == "config") {
            in_wan = length(fields) >= 3 && fields[1] == "interface" && fields[2] == "'wan'";
            proto = "";
        }

        if (!in_wan)
            continue;

        if (length(fields) >= 3 && fields[0] == "option" && fields[1] == "proto") {
            proto = fields[2];
            print(line, "\n");
        }
        else if (proto == "'static'" && length(fields) >= 2 && fields[0] == "option" &&
            (fields[1] == "ipaddr" || fields[1] == "netmask" || fields[1] == "gateway")) {
            print("        option ", fields[1], " '******'\n");
        }
        else if (proto == "'pppoe'" && length(fields) >= 2 && fields[0] == "option" &&
            (fields[1] == "username" || fields[1] == "password")) {
            print("        option ", fields[1], " '******'\n");
        }
        else if (proto == "'wireguard'" && length(fields) >= 2 && fields[0] == "option" &&
            fields[1] == "private_key") {
            print("        option private_key '******'\n");
        }
        else {
            print(line, "\n");
        }
    }
}

function is_space_char(value) {
    return value == " " || value == "\t" || value == "\r" || value == "\n";
}

function mask_after_token(line, token) {
    let pos = index(line, token);
    return pos < 0 ? line : substr(line, 0, pos) + token + " 'MASKED'";
}

function mask_after_token_space(line, token) {
    let pos = index(line, token);
    if (pos < 0)
        return line;

    let space_pos = pos + length(token);
    if (space_pos >= length(line) || !is_space_char(substr(line, space_pos, 1)))
        return line;

    return substr(line, 0, space_pos + 1) + "'MASKED'";
}

function delete_token_space(line, token) {
    let pos = index(line, token);
    if (pos < 0)
        return false;

    let space_pos = pos + length(token);
    return space_pos < length(line) && is_space_char(substr(line, space_pos, 1));
}

function mask_option_path(line, token) {
    let pos = index(line, token);
    if (pos < 0)
        return line;

    let slash = index(substr(line, pos + length(token)), "/");
    if (slash < 0)
        return line;
    slash += pos + length(token);

    let quote = index(substr(line, slash + 1), "'");
    if (quote < 0)
        return line;
    quote += slash + 1;

    return substr(line, 0, slash) + "/MASKED'" + substr(line, quote + 1);
}

function forkop_config_masked_line(line) {
    line = mask_after_token(line, "option proxy_string");
    line = mask_after_token(line, "option hwid");
    line = mask_after_token(line, "option subscription_url");
    line = mask_after_token(line, "list subscription_urls");
    line = mask_after_token(line, "list urltest_proxy_links");
    line = mask_after_token(line, "list selector_proxy_links");
    line = mask_after_token_space(line, "option outbound_json");
    line = mask_after_token_space(line, "option native_tunnel_profile");
    line = mask_after_token_space(line, "list domain");
    line = mask_after_token_space(line, "list domain_suffix");
    line = mask_after_token_space(line, "list domain_keyword");
    line = mask_after_token_space(line, "list domain_regex");
    line = mask_after_token_space(line, "list ip_cidr");
    line = mask_after_token_space(line, "list source_ip_cidr");
    line = mask_after_token_space(line, "list excluded_source_ip_cidr");
    line = mask_after_token_space(line, "list fully_routed_ips");
    line = mask_after_token(line, "list server_users");
    line = mask_after_token_space(line, "option dns_server");
    line = mask_after_token_space(line, "option bootstrap_dns_server");
    line = mask_after_token_space(line, "list dns_server");
    line = mask_after_token_space(line, "list bootstrap_dns_server");
    line = mask_after_token_space(line, "option listen");
    line = mask_after_token_space(line, "option listen_port");
    line = mask_after_token_space(line, "option public_host");
    line = mask_after_token(line, "option server_uuid");
    line = mask_after_token(line, "option server_username");
    line = mask_after_token(line, "option server_password");
    line = mask_after_token(line, "option mtproto_secret");
    line = mask_after_token_space(line, "option mtproto_faketls");
    line = mask_after_token_space(line, "option mtproto_domain_fronting_ip");
    line = mask_after_token_space(line, "option tls_server_name");
    line = mask_after_token_space(line, "option reality_handshake_server");
    line = mask_after_token_space(line, "option reality_handshake_server_port");
    line = mask_after_token_space(line, "option transport_host");
    line = mask_after_token_space(line, "list transport_hosts");
    line = mask_after_token_space(line, "option tailscale_auth_key");
    line = mask_after_token_space(line, "option tailscale_control_url");
    line = mask_after_token_space(line, "option tailscale_hostname");
    line = mask_after_token_space(line, "list tailscale_advertise_routes");
    line = mask_after_token(line, "option hysteria2_obfs_password");
    line = mask_after_token(line, "option reality_private_key");
    line = mask_after_token(line, "option reality_public_key");
    line = mask_after_token(line, "option reality_short_id");
    line = mask_after_token(line, "list reality_short_id");
    line = mask_after_token_space(line, "option mixed_proxy_username");
    line = mask_after_token_space(line, "option mixed_proxy_password");
    line = mask_after_token_space(line, "option private_key");
    line = mask_after_token_space(line, "option url");
    line = mask_option_path(line, "option dns_server '");
    line = mask_option_path(line, "list dns_server '");
    line = mask_after_token(line, "option yacd_secret_key");

    return line;
}

function forkop_config_masked(path) {
    let data = fs.readfile(path);
    if (data == null)
        exit(1);

    let lines = split(as_string(data), "\n");
    let in_masked_multiline = false;

    for (let i = 0; i < length(lines); i++) {
        let line = as_string(lines[i]);
        if (i == length(lines) - 1 && line == "" && substr(as_string(data), length(data) - 1) == "\n")
            continue;

        if (in_masked_multiline) {
            if (index(line, "'") >= 0)
                in_masked_multiline = false;
            continue;
        }

        if (delete_token_space(line, "option tailscale_ephemeral") ||
            delete_token_space(line, "option tailscale_exit_node") ||
            delete_token_space(line, "option tailscale_exit_node_allow_lan_access"))
            continue;

        let masked = forkop_config_masked_line(line);
        print(masked, "\n");
        if (index(line, "option outbound_json") >= 0) {
            let first_quote = index(line, "'");
            if (first_quote >= 0 && index(substr(line, first_quote + 1), "'") < 0)
                in_masked_multiline = true;
        }
    }
}

function dhcp_dnsmasq_config(path) {
    let data = fs.readfile(path);
    let in_dnsmasq = false;

    if (data == null)
        exit(1);

    let lines = split(as_string(data), "\n");
    for (let i = 0; i < length(lines); i++) {
        let line = lines[i];
        if (i == length(lines) - 1 && line == "" && substr(as_string(data), length(data) - 1) == "\n")
            continue;

        if (match(as_string(line), /^config /) != null) {
            let fields = split(trim(as_string(line)), /[ \t\r\n]+/);
            in_dnsmasq = length(fields) >= 2 && fields[1] == "dnsmasq";
        }

        if (in_dnsmasq)
            print(line, "\n");
    }
}

function flag_is_one(value) {
    return as_string(value) == "1";
}

function flag_is_true(value) {
    return value == true || as_string(value) == "true" || as_string(value) == "1";
}

function object_value(object, key) {
    return type(object) == "object" && object[key] != null ? as_string(object[key]) : "";
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function str_startswith(value, prefix) {
    value = as_string(value);
    prefix = as_string(prefix);
    return substr(value, 0, length(prefix)) == prefix;
}

function str_endswith(value, suffix) {
    value = as_string(value);
    suffix = as_string(suffix);
    return length(value) >= length(suffix) && substr(value, length(value) - length(suffix)) == suffix;
}

function str_remove_suffix(value, suffix) {
    value = as_string(value);
    suffix = as_string(suffix);
    return str_endswith(value, suffix) ? substr(value, 0, length(value) - length(suffix)) : value;
}

function contains(values, needle) {
    needle = as_string(needle);
    for (let value in array_or_empty(values))
        if (as_string(value) == needle)
            return true;
    return false;
}

function nft_line_is_count_element(line) {
    line = trim(as_string(line));
    return line != "" && match(substr(line, 0, 1), /^[0-9]$/) != null;
}

function render_nft_chain_config_blocks() {
    let lines = split(read_stdin(), "\n");

    for (let i = 1; i < length(ARGV); i++) {
        let chain = as_string(ARGV[i]);
        let in_block = false;
        let needle = "chain " + chain + " {";

        for (let line in lines) {
            line = as_string(line);
            if (!in_block && index(line, needle) < 0)
                continue;

            if (!in_block)
                in_block = true;

            if (index(line, "elements") < 0 && !nft_line_is_count_element(line))
                print(line, "\n");

            if (index(line, "}") >= 0)
                in_block = false;
        }
    }
}

function nft_chain_counter_status(mark_only) {
    let rules_exist = 0;
    let counters = 0;

    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (index(line, "counter") < 0 || (mark_only && index(line, "meta mark set ") < 0))
            continue;

        rules_exist = 1;
        if (index(line, "packets 0 bytes 0") < 0)
            counters = 1;
    }

    print(rules_exist, " ", counters, "\n");
}

function print_line(value) {
    print(value, "\n");
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function stdin_json() {
    let value = read_stdin_json();
    if (value == null)
        exit(1);
    write_json(value);
}

function json_error(message) {
    write_json({ error: as_string(message) });
}

function mask_ipv6_line(line) {
    let matched = match(line, /([0-9a-fA-F]+:[0-9a-fA-F]+:[0-9a-fA-F]+):.*/);
    return matched ? matched[1] + ":XXXX:XXXX:XXXX" : line;
}

function render_proxy_response_ip_mask() {
    let response = read_stdin();
    let lines = split(response, "\n");
    let ipv4_lines = [];
    let ipv6_like = false;

    for (let line in lines) {
        let matched = match(line, /^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$/);
        if (matched)
            push(ipv4_lines, "X.X.X." + matched[4]);

        if (match(line, /^[0-9a-fA-F:]*::[0-9a-fA-F:]*$/) || match(line, /^[0-9a-fA-F:]+$/))
            ipv6_like = true;
    }

    if (length(ipv4_lines) > 0) {
        for (let line in ipv4_lines)
            print_line(line);
        return;
    }

    if (ipv6_like) {
        for (let i = 0; i < length(lines); i++) {
            if (i == length(lines) - 1 && lines[i] == "")
                continue;
            print_line(mask_ipv6_line(lines[i]));
        }
        return;
    }

    exit(1);
}

function service_list_instance_running(name) {
    let value = object_or_empty(read_stdin_json());
    let service = object_or_empty(value[as_string(name)]);
    let instances = object_or_empty(service.instances);

    for (let key in instances) {
        let instance = object_or_empty(instances[key]);
        if (flag_is_true(instance.running))
            exit(0);
    }

    exit(1);
}

function repeat_char(char, count) {
    let result = "";
    for (let i = 0; i < count; i++)
        result += char;
    return result;
}

function first_field(value, separator) {
    let marker = index(value, separator);
    return marker < 0 ? value : substr(value, 0, marker);
}

function mask_dns_server(value) {
    value = as_string(value);
    if (str_endswith(value, ".dns.nextdns.io")) {
        let nextdns_id = first_field(value, ".");
        print_line(repeat_char("*", length(nextdns_id)) + ".dns.nextdns.io");
        return;
    }

    if (str_startswith(value, "dns.nextdns.io/")) {
        let path = substr(value, length("dns.nextdns.io/"));
        print_line("dns.nextdns.io/" + repeat_char("*", length(path)));
        return;
    }

    print_line(value);
}

function render_flag_line(value, key, ok_message, fail_message) {
    print_line((flag_is_one(value[key]) ? ok_message : fail_message));
}

function render_global_xrust_check() {
    let value = object_or_empty(read_stdin_json());

    render_flag_line(value, "xrust_installed", "\u2705 Xrust installed", "\u274c Xrust installed");
    render_flag_line(value, "xrust_version_ok", "\u2705 Xrust version recognized", "\u274c Xrust version could not be determined");
    render_flag_line(value, "xrust_service_exist", "\u2705 Xrust service exists", "\u274c Xrust service exists");
    render_flag_line(value, "xrust_autostart_disabled", "\u2705 Xrust standalone autostart disabled", "\u274c Xrust standalone autostart disabled");
    render_flag_line(value, "xrust_process_running", "\u2705 Xrust process running", "\u274c Xrust process running");
    render_flag_line(value, "xrust_ports_listening", "\u2705 Xrust listening ports", "\u274c Xrust listening ports");
}

function render_global_system_info() {
    let value = object_or_empty(read_stdin_json());
    let forkop_version = object_value(value, "forkop_version") || "unknown";
    let luci_app_version = object_value(value, "luci_app_version") || "unknown";
    let xrust_version = object_value(value, "xrust_version") || "unknown";
    let openwrt_version = object_value(value, "openwrt_version") || "unknown";
    let device_model = object_value(value, "device_model") || "unknown";

    print_line("\ud83d\udd73\ufe0f Forkop:   " + forkop_version);
    print_line("\ud83d\udd73\ufe0f LuCI App:      " + luci_app_version);
    print_line("\ud83d\udce6 Xrust:         " + xrust_version);
    print_line("\ud83d\udedc OpenWrt:       " + openwrt_version);
    print_line("\ud83d\udedc Device:        " + device_model);
}

function render_global_fakeip_check() {
    let value = object_or_empty(read_stdin_json());
    let fakeip_address = object_value(value, "IP");

    if (flag_is_true(value.fakeip))
        print_line("\u2705 Xrust FakeIP DNS works: " + fakeip_address);
    else
        print_line("\u274c Xrust FakeIP DNS does NOT work");
}

function render_global_dns_check(dont_touch_dhcp) {
    let value = object_or_empty(read_stdin_json());
    let dns_type = object_value(value, "dns_type") || "unknown";
    let dns_server = object_value(value, "dns_server") || "unknown";
    let bootstrap_dns_server = object_value(value, "bootstrap_dns_server");
    let bootstrap_dns_type = object_value(value, "bootstrap_dns_type") || "udp";
    let dns_position = number_value(value.dns_server_count) > 1
        ? " (priority " + as_string(number_value(value.dns_server_index) + 1) + "/" + as_string(number_value(value.dns_server_count)) + ")"
        : "";
    let bootstrap_position = number_value(value.bootstrap_dns_server_count) > 1
        ? " (priority " + as_string(number_value(value.bootstrap_dns_server_index) + 1) + "/" + as_string(number_value(value.bootstrap_dns_server_count)) + ")"
        : "";
    let dump_dhcp_config = false;

    if (bootstrap_dns_server != "") {
        print_line((flag_is_one(value.bootstrap_dns_status) ? "\u2705 Bootstrap DNS: " : "\u274c Bootstrap DNS: ") + bootstrap_dns_server + " [" + bootstrap_dns_type + "]" + bootstrap_position);
    }

    print_line((flag_is_one(value.dns_status) ? "\u2705 Main DNS: " : "\u274c Main DNS: ") + dns_server + " [" + dns_type + "]" + dns_position);
    print_line(flag_is_one(value.dns_on_router) ? "\u2705 DNS on router" : "\u274c DNS on router");

    if (as_string(dont_touch_dhcp) == "1") {
        print_line("\u26a0\ufe0f dont_touch_dhcp is enabled. \ud83d\udcc4 DHCP config:");
        dump_dhcp_config = true;
    }
    else if (!flag_is_one(value.dhcp_config_status)) {
        print_line("\u274c DHCP configuration differs from template. \ud83d\udcc4 DHCP config:");
        dump_dhcp_config = true;
    }
    else {
        print_line("\u2705 /etc/config/dhcp");
    }

    exit(dump_dhcp_config ? 10 : 0);
}

function render_global_nft_check() {
    let value = read_stdin_json();
    if (type(value) != "object")
        exit(1);

    render_flag_line(value, "table_exist", "\u2705 Table exist", "\u274c Table exist");
    render_flag_line(value, "rules_mangle_exist", "\u2705 Rules mangle exist", "\u274c Rules mangle exist");
    render_flag_line(value, "rules_mangle_counters", "\u2705 Rules mangle counters", "\u26a0\ufe0f  Rules mangle counters");
    render_flag_line(value, "rules_mangle_output_exist", "\u2705 Rules mangle output exist", "\u274c Rules mangle output exist");
    render_flag_line(value, "rules_mangle_output_counters", "\u2705 Rules mangle output counters", "\u26a0\ufe0f  Rules mangle output counters");
    render_flag_line(value, "rules_proxy_exist", "\u2705 Rules proxy exist", "\u274c Rules proxy exist");
    render_flag_line(value, "rules_proxy_counters", "\u2705 Rules proxy counters", "\u26a0\ufe0f  Rules proxy counters");

    if (flag_is_one(value.rules_other_mark_exist))
        print_line("\u26a0\ufe0f  Additional marking rules found:");
    else
        print_line("\u2705 No other marking rules found");
}

function global_nft_other_mark_exists() {
    let value = read_stdin_json();
    exit(type(value) == "object" && flag_is_one(value.rules_other_mark_exist) ? 0 : 1);
}

function nft_ruleset_other_mark_lines(table_name) {
    table_name = as_string(table_name);
    let in_forkop_table = false;
    let family = "";
    let current_table = "";
    let current_chain = "";

    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        let header = match(line, /^table ([^ ]+) ([^ ]+) \{/);
        if (header != null) {
            family = header[1];
            current_table = header[2];
            current_chain = "";
            in_forkop_table = family == "inet" && current_table == table_name;
            continue;
        }
        let chain = match(line, /^\s*chain ([^ ]+) \{/);
        if (chain != null)
            current_chain = chain[1];
        if (mark_rules.is_forkop_mark(family, current_table, current_chain, line))
            continue;

        if (!in_forkop_table && (index(line, "mark set") >= 0 || index(line, "meta mark") >= 0))
            print_line(line);
    }
}

function nft_set_element_count() {
    let value = object_or_empty(read_stdin_json());

    for (let item in array_or_empty(value.nftables)) {
        if (type(item) != "object" || type(item.set) != "object")
            continue;

        print_line(length(array_or_empty(item.set.elem)));
        return;
    }

    print_line("0");
}

function line_contains(line, needle) {
    return index(as_string(line), as_string(needle)) >= 0;
}

function print_lines(lines, start, end) {
    for (let i = start; i < end; i++)
        print_line(lines[i]);
}

function is_udp_unsupported_outbound_log(line) {
    return index(as_string(line), "UDP is not supported by outbound:") >= 0;
}

function is_xrust_log(line) {
    return match(line, /(^|[ \t])xrust\[[0-9]+\]:[ \t]/) != null;
}

function render_matching_log_tail(needle, max_lines) {
    let lines = split(read_stdin(), "\n");
    let filtered = [];
    let udp_http_notice_emitted = false;

    for (let line in lines) {
        if (line == "")
            continue;
        if (needle == "xrust" ? is_xrust_log(line) : line_contains(line, needle))
        {
            if (needle == "sing-box" && is_udp_unsupported_outbound_log(line)) {
                if (!udp_http_notice_emitted) {
                    push(filtered, "UDP traffic through HTTP outbounds is not supported by sing-box; repeated UDP warnings for HTTP outbounds are hidden by Forkop.");
                    udp_http_notice_emitted = true;
                }
                continue;
            }

            push(filtered, line);
        }
    }

    if (length(filtered) == 0)
        exit(1);

    max_lines = int(max_lines || "100", 10) || 100;
    let start = length(filtered) > max_lines ? length(filtered) - max_lines : 0;
    print_lines(filtered, start, length(filtered));
}

function render_forkop_logs() {
    let lines = split(read_stdin(), "\n");
    let filtered = [];
    let start = -1;
    let udp_http_notice_emitted = false;

    for (let line in lines) {
        if (line == "")
            continue;
        if (!line_contains(line, "forkop") && !line_contains(line, "sing-box") && !is_xrust_log(line))
            continue;

        if (line_contains(line, "sing-box") && is_udp_unsupported_outbound_log(line)) {
            if (!udp_http_notice_emitted) {
                push(filtered, "UDP traffic through HTTP outbounds is not supported by sing-box; repeated UDP warnings for HTTP outbounds are hidden by Forkop.");
                udp_http_notice_emitted = true;
            }
            continue;
        }

        if (line_contains(line, "forkop") && line_contains(line, "Starting Forkop"))
            start = length(filtered);

        push(filtered, line);
    }

    if (length(filtered) == 0)
        exit(1);

    if (start >= 0) {
        print_lines(filtered, start, length(filtered));
        return;
    }

    print_line("No 'Starting Forkop' message found, showing last 100 lines");
    start = length(filtered) > 100 ? length(filtered) - 100 : 0;
    print_lines(filtered, start, length(filtered));
}

function file_first_line(path, fallback) {
    let data = fs.readfile(path);
    let result = "";

    if (data != null) {
        let lines = split(as_string(data), "\n");
        if (length(lines) > 0)
            result = str_remove_suffix(as_string(lines[0]), "\r");
    }

    if (result == "")
        result = as_string(fallback);

    print_line(result);
}

let masked_sing_box_keys = {
    auth_key: true,
    control_url: true,
    exit_node: true,
    hostname: true,
    listen: true,
    listen_port: true,
    username: true,
    uuid: true,
    server: true,
    server_name: true,
    secret: true,
    password: true,
    private_key: true,
    pre_shared_key: true,
    header_protection_key: true,
    public_key: true,
    short_id: true,
    fingerprint: true,
    server_port: true,
    server_ports: true,
    advertise_routes: true,
    domain: true,
    domain_suffix: true,
    domain_keyword: true,
    domain_regex: true,
    ip_cidr: true,
    source_ip_cidr: true,
    excluded_source_ip_cidr: true,
    authorization: true,
    "proxy-authorization": true,
    cookie: true,
    "set-cookie": true
};

function mask_sing_box_value(value) {
    if (type(value) == "array") {
        let result = [];
        for (let item in value)
            push(result, mask_sing_box_value(item));
        return result;
    }

    if (type(value) == "object") {
        let result = {};
        for (let key, item in value)
            result[key] = masked_sing_box_keys[lc(key)] ? "MASKED" : mask_sing_box_value(item);
        return result;
    }

    return value;
}

function mask_sing_box_config(path) {
    let config = read_json_file(path);
    write_json(type(config) == "object" ? mask_sing_box_value(config) : "MASKED");
}

function prepare_check_proxy_config(input_path, output_path, cache_path) {
    let config = object_or_empty(read_json_file(input_path));
    config.inbounds = [];
    config.services = [];
    if (type(config.experimental) == "object") {
        if (type(config.experimental.cache_file) == "object")
            config.experimental.cache_file.path = as_string(cache_path);
        delete config.experimental.clash_api;
    }

    if (!write_json_file(output_path, config))
        exit(1);
}

function check_proxy_outbound_tag(config_path, domain) {
    let config = object_or_empty(read_json_file(config_path));
    for (let rule in array_or_empty(config.route && config.route.rules)) {
        if (type(rule) != "object")
            continue;
        if (contains(array_or_empty(rule.domain), domain)) {
            print_line(as_string(rule.outbound || ""));
            return;
        }
    }
}

function http_response_with_status() {
    let lines = split(read_stdin(), "\n");
    let status = length(lines) > 0 ? as_string(lines[length(lines) - 1]) : "";
    let body_lines = length(lines) > 0 ? slice(lines, 0, length(lines) - 1) : [];

    return {
        status_text: status,
        status: int(status || "0", 10) || 0,
        body: join("\n", body_lines)
    };
}

function write_clash_api_error(status, body) {
    let result = {
        success: false,
        http_code: status
    };

    if (body != "")
        result.body = body;

    write_json(result);
    exit(1);
}

function clash_set_group_proxy_result(group_tag, proxy_tag) {
    let response = http_response_with_status();

    if (response.status == 204) {
        write_json({ success: true, group: as_string(group_tag), proxy: as_string(proxy_tag) });
        return;
    }

    if (response.status == 404) {
        write_json({ success: false, error: "group_not_found", message: as_string(group_tag) + " does not exist" });
        exit(1);
    }

    if (response.status == 400) {
        if (line_contains(response.body, "not found"))
            write_json({ success: false, error: "proxy_not_found", message: as_string(proxy_tag) + " not found in group " + as_string(group_tag) });
        else
            write_json({ success: false, error: "bad_request", message: "Invalid request" });
        exit(1);
    }

    write_clash_api_error(response.status, response.body);
}

function clash_close_connection_result(connection_id) {
    let response = http_response_with_status();

    if (response.status == 200 || response.status == 204) {
        write_json({ success: true, connection_id: as_string(connection_id) });
        return;
    }

    if (response.status == 404) {
        write_json({ success: false, error: "connection_not_found", connection_id: as_string(connection_id) });
        exit(1);
    }

    write_clash_api_error(response.status, response.body);
}

function clash_close_all_connections_result() {
    let response = http_response_with_status();

    if (response.status == 200 || response.status == 204) {
        write_json({ success: true });
        return;
    }

    write_clash_api_error(response.status, response.body);
}

function clash_set_group_proxy_payload(proxy_tag) {
    write_json({ name: as_string(proxy_tag) });
}

function clash_proxy_tags_lines(proxy_tags_json) {
    let proxy_tags = parse_json_or_null(proxy_tags_json);
    if (type(proxy_tags) != "array")
        exit(1);

    for (let proxy_tag in proxy_tags) {
        if (type(proxy_tag) != "string" || proxy_tag == "")
            exit(1);
        print(proxy_tag, "\n");
    }
}

function clash_proxy_latencies_result(count, failed) {
    count = int(as_string(count || "0"), 10) || 0;
    failed = int(as_string(failed || "0"), 10) || 0;
    write_json({
        success: count > failed,
        count,
        failed: failed > 0
    });
    if (count <= failed)
        exit(1);
}

function clash_unknown_action() {
    write_json({
        error: "unknown action",
        available: [
            "get_proxies",
            "get_connections",
            "get_proxy_latency",
            "get_proxy_latencies",
            "get_group_latency",
            "set_group_proxy",
            "close_connection",
            "close_all_connections"
        ]
    });
}

let mode = ARGV[0];

if (mode == "proxy-response-ip-mask")
    render_proxy_response_ip_mask();
else if (mode == "url-encode")
    print(core_url.encode(ARGV[1]), "\n");
else if (mode == "stdin-json")
    stdin_json();
else if (mode == "stdin-first-line-last-field")
    stdin_first_line_last_field();
else if (mode == "stdin-first-ipv4-line")
    stdin_first_ipv4_line();
else if (mode == "stdin-contains")
    stdin_contains(ARGV[1]);
else if (mode == "network-endpoint-host-warnings")
    network_endpoint_host_warnings(ARGV[1]);
else if (mode == "network-wireguard-route-allowed-peers")
    network_wireguard_route_allowed_peers();
else if (mode == "wan-config-masked")
    wan_config_masked(ARGV[1]);
else if (mode == "forkop-config-masked")
    forkop_config_masked(ARGV[1]);
else if (mode == "dhcp-dnsmasq-config")
    dhcp_dnsmasq_config(ARGV[1]);
else if (mode == "json-error")
    json_error(ARGV[1]);
else if (mode == "service-list-instance-running")
    service_list_instance_running(ARGV[1]);
else if (mode == "mask-dns-server")
    mask_dns_server(ARGV[1]);
else if (mode == "global-xrust-check")
    render_global_xrust_check();
else if (mode == "global-system-info")
    render_global_system_info();
else if (mode == "global-fakeip-check")
    render_global_fakeip_check();
else if (mode == "global-dns-check")
    render_global_dns_check(ARGV[1]);
else if (mode == "global-nft-check")
    render_global_nft_check();
else if (mode == "global-nft-other-mark-exists")
    global_nft_other_mark_exists();
else if (mode == "nft-ruleset-other-mark-lines")
    nft_ruleset_other_mark_lines(ARGV[1]);
else if (mode == "nft-set-element-count")
    nft_set_element_count();
else if (mode == "nft-chain-config-blocks")
    render_nft_chain_config_blocks();
else if (mode == "nft-chain-counter-status")
    nft_chain_counter_status(ARGV[1] == "mark-only");
else if (mode == "forkop-logs")
    render_forkop_logs();
else if (mode == "matching-log-tail")
    render_matching_log_tail(ARGV[1], ARGV[2]);
else if (mode == "file-first-line")
    file_first_line(ARGV[1], ARGV[2]);
else if (mode == "mask-sing-box-config")
    mask_sing_box_config(ARGV[1]);
else if (mode == "proxy-response-is-retryable-error")
    exit(proxy_response_is_retryable_error() ? 0 : 1);
else if (mode == "prepare-check-proxy-config")
    prepare_check_proxy_config(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "check-proxy-outbound-tag")
    check_proxy_outbound_tag(ARGV[1], ARGV[2]);
else if (mode == "clash-set-group-proxy-result")
    clash_set_group_proxy_result(ARGV[1], ARGV[2]);
else if (mode == "clash-close-connection-result")
    clash_close_connection_result(ARGV[1]);
else if (mode == "clash-close-all-connections-result")
    clash_close_all_connections_result();
else if (mode == "clash-set-group-proxy-payload")
    clash_set_group_proxy_payload(ARGV[1]);
else if (mode == "clash-proxy-tags-lines")
    clash_proxy_tags_lines(ARGV[1]);
else if (mode == "clash-proxy-latencies-result")
    clash_proxy_latencies_result(ARGV[1], ARGV[2]);
else if (mode == "clash-unknown-action")
    clash_unknown_action();
else {
    warn("Usage: diagnostics/status.uc <operation> ...\n");
    exit(1);
}
