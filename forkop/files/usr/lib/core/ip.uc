#!/usr/bin/env ucode

let fs = require("fs");

// A local IPv6 TPROXY route needs IPv6 in the kernel and on loopback.
// The optional path permits isolated tests without changing host sysctls.
function ipv6_tproxy_enabled() {
    let root = getenv("FORKOP_IPV6_SYSCTL_DIR") || "/proc/sys/net/ipv6/conf";
    let all = fs.readfile(root + "/all/disable_ipv6");
    let lo = fs.readfile(root + "/lo/disable_ipv6");
    return all != null && lo != null && trim(all) == "0" && trim(lo) == "0";
}

function as_string(value) {
    return value == null ? "" : "" + value;
}

function decimal_text(value, strict) {
    value = as_string(value);
    if (value == "" || match(value, /^[0-9]+$/) == null)
        return false;
    return !strict || length(value) == 1 || substr(value, 0, 1) != "0";
}

function valid_ipv4(value, allow_trailing_dot, strict_decimal) {
    value = as_string(value);
    if (allow_trailing_dot && length(value) > 0 && substr(value, length(value) - 1, 1) == ".")
        value = substr(value, 0, length(value) - 1);

    let parts = split(value, ".");
    if (length(parts) != 4)
        return false;

    for (let part in parts) {
        if (!decimal_text(part, strict_decimal))
            return false;

        let octet = int(part);
        if (octet < 0 || octet > 255)
            return false;
    }

    return true;
}

function valid_ipv4_cidr(value, strict_decimal) {
    value = as_string(value);
    let slash = index(value, "/");
    if (slash <= 0 || index(substr(value, slash + 1), "/") >= 0)
        return false;

    let prefix = substr(value, slash + 1);
    if (!decimal_text(prefix, strict_decimal))
        return false;

    let prefix_number = int(prefix);
    return valid_ipv4(substr(value, 0, slash), false, strict_decimal) && prefix_number >= 0 && prefix_number <= 32;
}

function valid_ipv6_hextet(value) {
    value = as_string(value);
    return value != "" && length(value) <= 4 && match(value, /^[0-9A-Fa-f]+$/) != null;
}

function ipv6_parts_count(parts) {
    let count = 0;

    for (let i = 0; i < length(parts); i++) {
        let part = parts[i];
        if (part == "")
            return -1;

        if (index(part, ".") >= 0) {
            if (i != length(parts) - 1 || !valid_ipv4(part, false, false))
                return -1;
            count += 2;
            continue;
        }

        if (!valid_ipv6_hextet(part))
            return -1;
        count++;
    }

    return count;
}

function valid_ipv6(value) {
    value = as_string(value);
    if (value == "" || index(value, "/") >= 0 || index(value, "%") >= 0)
        return false;

    let marker = index(value, "::");
    if (marker >= 0) {
        if (index(substr(value, marker + 2), "::") >= 0)
            return false;

        let left = substr(value, 0, marker);
        let right = substr(value, marker + 2);
        if (index(left, ".") >= 0)
            return false;
        let left_count = left == "" ? 0 : ipv6_parts_count(split(left, ":"));
        let right_count = right == "" ? 0 : ipv6_parts_count(split(right, ":"));

        return left_count >= 0 && right_count >= 0 && left_count + right_count < 8;
    }

    let count = ipv6_parts_count(split(value, ":"));
    return count == 8;
}

function valid_ipv6_cidr(value) {
    value = as_string(value);
    let slash = index(value, "/");
    if (slash <= 0 || index(substr(value, slash + 1), "/") >= 0)
        return false;

    let prefix = substr(value, slash + 1);
    if (!decimal_text(prefix, false))
        return false;

    let prefix_number = int(prefix);
    return valid_ipv6(substr(value, 0, slash)) && prefix_number >= 0 && prefix_number <= 128;
}

function valid_ip(value) {
    return valid_ipv4(value, false, false) || valid_ipv6(value);
}

function valid_ip_cidr(value) {
    return valid_ipv4_cidr(value, false) || valid_ipv6_cidr(value);
}

function valid_ip_or_cidr(value) {
    return valid_ip(value) || valid_ip_cidr(value);
}

function nft_ip_or_cidr(value) {
    return valid_ipv4(value, true, true) || valid_ipv4_cidr(value, true) || valid_ipv6(value) || valid_ipv6_cidr(value);
}

function ip_family(value) {
    return valid_ipv4(value, false, false) || valid_ipv4_cidr(value, false) ? 4 :
        (valid_ipv6(value) || valid_ipv6_cidr(value) ? 6 : 0);
}

function format_ipv6_tproxy_target(address, port) {
    address = as_string(address);
    if (substr(address, 0, 1) == "[" && substr(address, length(address) - 1, 1) == "]")
        return address + ":" + as_string(port);
    return "[" + address + "]:" + as_string(port);
}

// Discord's community subnet list also contains shared Cloudflare Anycast
// ranges.  They host unrelated services, so routing them as ordinary Discord
// networks can capture large amounts of unrelated traffic (including P2P).
const CLOUDFLARE_SHARED_CIDRS = [
    "104.16.0.0/12", "104.24.0.0/14", "172.64.0.0/13", "162.158.0.0/15",
    "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20", "197.234.240.0/22",
    "198.41.128.0/17", "162.159.0.0/16", "173.245.48.0/20", "103.21.244.0/22",
    "103.22.200.0/22", "103.31.4.0/22", "141.101.64.0/18",
    "2606:4700::/32", "2400:cb00::/32", "2405:b500::/32", "2803:f800::/32",
    "2a06:98c0::/29", "2c0f:f248::/32"
];

function is_cloudflare_shared_cidr(value) {
    value = lc(trim(as_string(value)));
    for (let cidr in CLOUDFLARE_SHARED_CIDRS)
        if (value == lc(cidr))
            return true;
    return false;
}

// Discord voice compatibility, matching Tachyon's shared-Cloudflare policy.
// https://github.com/Dushnilin/tachyon/blob/main/tachyon/files/usr/lib/core/ip.uc
const DISCORD_VOICE_PORTS_NFT = "443,5000-5020,3478,19294-19344,50000-65535";
const DISCORD_VOICE_PORT_RANGES = map(split(DISCORD_VOICE_PORTS_NFT, ","), function(port) {
    return index(port, "-") >= 0 ? replace(port, "-", ":") : port + ":" + port;
});
const DISCORD_MEDIA_PORTS_NFT = "443,1080,2053,2083,2087,2096,8443";
const DISCORD_MEDIA_PORT_RANGES = map(split(DISCORD_MEDIA_PORTS_NFT, ","), function(port) { return port + ":" + port; });

function community_subnet_rules(service, data) {
    let regular = [];
    let shared = [];
    for (let line in split(as_string(data), "\n")) {
        line = trim(replace(line, /\r/g, ""));
        if (!valid_ip_or_cidr(line))
            continue;
        push(service == "discord" && is_cloudflare_shared_cidr(line) ? shared : regular, line);
    }
    let rules = [];
    if (length(regular) > 0)
        push(rules, { ip_cidr: regular });
    if (length(shared) > 0)
        push(rules, { network: "udp", ip_cidr: shared, port_range: DISCORD_VOICE_PORT_RANGES });
    if (length(shared) > 0)
        push(rules, { network: "tcp", ip_cidr: shared, port_range: DISCORD_MEDIA_PORT_RANGES });
    return rules;
}

return {
    ipv6_tproxy_enabled,
    valid_ipv4,
    valid_ipv4_cidr,
    valid_ipv6,
    valid_ipv6_cidr,
    valid_ip,
    valid_ip_cidr,
    valid_ip_or_cidr,
    nft_ip_or_cidr,
    ip_family,
    format_ipv6_tproxy_target,
    CLOUDFLARE_SHARED_CIDRS,
    is_cloudflare_shared_cidr,
    DISCORD_VOICE_PORTS_NFT,
    DISCORD_VOICE_PORT_RANGES,
    DISCORD_MEDIA_PORTS_NFT,
    DISCORD_MEDIA_PORT_RANGES,
    community_subnet_rules
};
