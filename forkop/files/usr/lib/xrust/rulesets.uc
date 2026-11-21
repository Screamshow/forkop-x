#!/usr/bin/env ucode

let constants = require("core.constants");

const SRS_MAIN_URL = constants.SRS_MAIN_URL;
const SRS_ADS_HAGEZI_PRO_URL = constants.SRS_ADS_HAGEZI_PRO_URL;
const SRS_SUPERCELL_URL = constants.SRS_SUPERCELL_URL;
const SRS_GITHUB_URL = constants.SRS_GITHUB_URL;

const COMMUNITY_SERVICES = {
    russia_inside: true,
    russia_outside: true,
    ukraine_inside: true,
    geoblock: true,
    block: true,
    porn: true,
    news: true,
    anime: true,
    youtube: true,
    hdrezka: true,
    tiktok: true,
    google_ai: true,
    google_play: true,
    hodca: true,
    discord: true,
    meta: true,
    twitter: true,
    cloudflare: true,
    cloudfront: true,
    digitalocean: true,
    hetzner: true,
    ovh: true,
    telegram: true,
    roblox: true,
    ads_hagezi_pro: true,
    supercell: true,
    github: true
};

// These community rule-sets contain address matchers in addition to domains.
// sing-box 1.14 requires address rule-sets to be evaluated against a DNS
// response instead of being used as legacy query filters.
const COMMUNITY_MIXED_SERVICES = {
    discord: true,
    meta: true,
    twitter: true,
    cloudflare: true,
    cloudfront: true,
    digitalocean: true,
    hetzner: true,
    ovh: true,
    telegram: true,
    roblox: true
};

function as_string(value) {
    return value == null ? "" : "" + value;
}

function is_community(name) {
    return COMMUNITY_SERVICES[as_string(name)] === true;
}

function community_url(name) {
    name = as_string(name);
    if (name == "ads_hagezi_pro")
        return SRS_ADS_HAGEZI_PRO_URL;
    if (name == "supercell")
        return SRS_SUPERCELL_URL;
    if (name == "github")
        return SRS_GITHUB_URL;
    return SRS_MAIN_URL + "/" + name + ".srs";
}

function community_kind(name) {
    name = as_string(name);
    if (!is_community(name))
        return "unknown";
    return COMMUNITY_MIXED_SERVICES[name] === true ? "mixed" : "domains";
}

function hash12(value) {
    value = as_string(value);
    let first = 2166136261;
    let second = 16777619;

    for (let i = 0; i < length(value); i++) {
        let code = ord(substr(value, i, 1));
        first = (first * 33 + code) % 4294967296;
        second = (second * 131 + code) % 4294967296;
    }

    return sprintf("%06x%06x", first % 16777216, second % 16777216);
}

function file_extension(value) {
    let basename = as_string(value);
    let slash = rindex(basename, "/");
    if (slash >= 0)
        basename = substr(basename, slash + 1);

    let query = index(basename, "?");
    if (query >= 0)
        basename = substr(basename, 0, query);

    let fragment = index(basename, "#");
    if (fragment >= 0)
        basename = substr(basename, 0, fragment);

    let dot = rindex(basename, ".");
    return dot >= 0 ? lc(substr(basename, dot + 1)) : "";
}

function kind_from_reference_hint(reference) {
    reference = lc(as_string(reference));
    let domains = index(reference, "geosite") >= 0 || index(reference, "domain") >= 0 ||
        index(reference, "domains") >= 0 || index(reference, "adguard") >= 0 ||
        index(reference, "adblock") >= 0 || index(reference, "host") >= 0 ||
        index(reference, "filter") >= 0;
    let addresses = index(reference, "geoip") >= 0 || index(reference, "subnet") >= 0 ||
        index(reference, "subnets") >= 0 || index(reference, "cidr") >= 0 ||
        match(reference, /(^|[^a-z])ips?([^a-z]|$)/) != null;
    if (domains && addresses)
        return "mixed";
    if (domains)
        return "domains";
    if (addresses)
        return "subnets";
    return "unknown";
}

function remote_format(reference) {
    return file_extension(reference) == "json" ? "source" : "binary";
}

function module_exports() {
    return {
        is_community,
        community_kind,
        community_url,
        hash12,
        file_extension,
        kind_from_reference_hint,
        remote_format
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

let mode = ARGV[0] || "";

if (mode == "file-extension")
    print(file_extension(ARGV[1]), "\n");
else if (mode == "is-community")
    exit(is_community(ARGV[1]) ? 0 : 1);
else if (mode == "community-kind")
    print(community_kind(ARGV[1]), "\n");
else if (mode == "kind-from-reference-hint")
    print(kind_from_reference_hint(ARGV[1]), "\n");
else if (mode == "remote-format")
    print(remote_format(ARGV[1]), "\n");
else if (mode == "community-url")
    print(community_url(ARGV[1]), "\n");
else {
    warn("Usage: xrust/rulesets.uc <file-extension|is-community|community-kind|kind-from-reference-hint|remote-format|community-url> ...\n");
    exit(1);
}
