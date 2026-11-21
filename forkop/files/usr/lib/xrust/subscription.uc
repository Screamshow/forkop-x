#!/usr/bin/env ucode

let common = require("core.common");
let subscription_share_link = require("subscription.share_link");
let subscription_parser = require("subscription.parser");
let source_cache = require("subscription.source_cache");

let as_string = common.as_string;
let read_json_file = common.read_json_file;
let array_or_empty = common.array_or_empty;
let object_or_empty = common.object_or_empty;
let object_key_count = common.object_key_count;

const TMP_SUBSCRIPTION_FOLDER = getenv("TMP_SUBSCRIPTION_FOLDER") || "/tmp/xrust/subscriptions";
const FORKOP_RUNTIME_STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const FORKOP_SECTION_CACHE_DIR = getenv("FORKOP_SECTION_CACHE_DIR") || FORKOP_RUNTIME_STATE_DIR + "/section-cache";
const FORKOP_SUBSCRIPTION_METADATA_DIR = getenv("FORKOP_SUBSCRIPTION_METADATA_DIR") || FORKOP_RUNTIME_STATE_DIR + "/subscription-metadata";
const FORKOP_RUNTIME_CACHE_FORMAT = int(getenv("FORKOP_RUNTIME_CACHE_FORMAT") || "12");
const FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR = getenv("FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR") || "/etc/forkop/subscription-cache";

let section_cache_dir = FORKOP_SECTION_CACHE_DIR;

function set_section_cache_dir(path) {
    path = as_string(path);
    if (path != "")
        section_cache_dir = path;
}

function source_id(section_name, index) {
    return section_name + "-subscription-" + index;
}

function section_cache_path(section_name) {
    return section_cache_dir + "/" + section_name + ".json";
}

function legacy_metadata_path(section_name) {
    return FORKOP_SUBSCRIPTION_METADATA_DIR + "/" + section_name + ".json";
}

function trim_string(value) {
    return replace(as_string(value), /^[ \t\r\n]+|[ \t\r\n]+$/g, "");
}

function parse_source_entry(entry) {
    entry = trim_string(entry);
    let delimiter = " | ";
    let delimiter_index = index(entry, delimiter);
    if (delimiter_index < 0)
        return { url: entry, user_agent: "" };

    return {
        url: trim_string(substr(entry, 0, delimiter_index)),
        user_agent: trim_string(substr(entry, delimiter_index + length(delimiter)))
    };
}

function valid_metadata_object(value) {
    return type(value) == "object" && object_key_count(value) > 1;
}

function metadata_items_from_value(value) {
    let result = [];
    if (type(value) == "array") {
        for (let item in value)
            if (valid_metadata_object(item))
                push(result, item);
    }
    else if (valid_metadata_object(value)) {
        push(result, value);
    }
    return result;
}

function metadata_source_index(item) {
    if (type(item) != "object")
        return null;

    let value = item.sourceIndex != null ? item.sourceIndex : item.source_index;
    if (value == null || value == "")
        return null;

    return int(value, 10);
}

function metadata_source_section(item) {
    if (type(item) != "object")
        return "";

    return as_string(item.sourceSection != null ? item.sourceSection : item.source_section);
}

function metadata_items_have_source_markers(items) {
    for (let item in items) {
        if (metadata_source_index(item) != null || metadata_source_section(item) != "")
            return true;
    }
    return false;
}

function metadata_matches_source(item, source_index, source_section, has_source_markers) {
    if (!has_source_markers)
        return false;

    let item_section = metadata_source_section(item);
    let item_index = metadata_source_index(item);

    if (item_section != "")
        return item_section == source_section;

    return item_index == source_index;
}

function read_persistent_source_metadata(source_section, source_entry) {
    let profile = source_cache.read(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR, source_section).profile;
    if (source_entry != null && source_entry != "") {
        let parsed = parse_source_entry(source_entry);
        if (profile.url != parsed.url || profile.user_agent == "" ||
            (parsed.user_agent != "" && profile.user_agent != parsed.user_agent))
            return [];
    }
    return metadata_items_from_value(profile.metadata);
}

function read_section_metadata(section_name, source_section, source_index) {
    let cache = object_or_empty(read_json_file(section_cache_path(section_name)));
    let metadata = metadata_items_from_value(cache.subscriptionMetadata);
    if (length(metadata) == 0)
        metadata = metadata_items_from_value(read_json_file(legacy_metadata_path(section_name)));
    if (length(metadata) == 0) {
        cache = object_or_empty(read_json_file(section_cache_path(source_section)));
        metadata = metadata_items_from_value(cache.subscriptionMetadata);
    }
    if (length(metadata) == 0)
        metadata = metadata_items_from_value(read_json_file(legacy_metadata_path(source_section)));

    let selected = [];
    let has_source_markers = metadata_items_have_source_markers(metadata);
    if (has_source_markers) {
        for (let item in metadata) {
            if (metadata_matches_source(item, source_index, source_section, true))
                push(selected, item);
        }
    }
    else if (source_index > 0 && source_index <= length(metadata)) {
        push(selected, metadata[source_index - 1]);
    }

    return selected;
}

function read_source_metadata(section_name, source_section, source_index, source_entry) {
    let metadata = read_section_metadata(section_name, source_section, source_index);
    if (length(metadata) == 0)
        metadata = read_persistent_source_metadata(source_section, source_entry);

    let result = [];
    for (let item in metadata) {
        item.sourceIndex = source_index;
        item.sourceSection = source_section;
        push(result, item);
    }
    return result;
}

function merge_source_metadata(state, section_name, source_section, source_index, source_entry) {
    if (type(state) != "object")
        return [];
    let items = read_source_metadata(section_name, source_section, source_index, source_entry);
    for (let item in items)
        push(state.subscriptionMetadata, item);
    return items;
}

function remember_outbound_metadata(state, tag_name, display_name, outbound) {
    if (type(state) != "object")
        return;
    state.outboundMetadata.names[tag_name] = display_name;
    let protocol = lc(as_string(outbound.type || ""));
    if (protocol != "")
        state.outboundMetadata.protocols[tag_name] = protocol;

    let transport = lc(as_string(object_or_empty(outbound.transport).type || ""));
    if (transport == "" || transport == "raw")
        transport = "tcp";
    else if (transport == "h2")
        transport = "http";
    state.outboundMetadata.transports[tag_name] = transport;

    let tls = type(outbound.tls) == "object" ? outbound.tls : null;
    let security = "none";
    if (tls != null && tls.enabled !== false) {
        let reality = type(tls.reality) == "object" ? tls.reality : null;
        security = reality != null && reality.enabled !== false ? "reality" : "tls";
    }
    state.outboundMetadata.securities[tag_name] = security;

    let server = as_string(outbound.server || "");
    if (server != "")
        state.servers[tag_name] = server;
}

function remember_source_outbound(state, tag_name, display_name, outbound, source_link, server_description) {
    if (type(state) != "object")
        return;
    remember_outbound_metadata(state, tag_name, display_name, outbound);
    server_description = as_string(server_description);
    if (server_description != "")
        state.outboundMetadata.descriptions[tag_name] = server_description;
    let outbound_type = as_string(outbound.type || "");
    if (outbound_type != "selector" && outbound_type != "urltest") {
        if (subscription_share_link.is_copyable_link(source_link))
            state.links[tag_name] = source_link;
    }
}

function remember_urltest_group(state, tag_name, display_name, outbound) {
    if (type(state) != "object" || as_string(outbound.type || "") != "urltest")
        return;

    let group = {
        displayName: as_string(display_name) != "" ? as_string(display_name) : tag_name,
        outbounds: array_or_empty(outbound.outbounds)
    };

    for (let key in [ "url", "interval", "tolerance", "idle_timeout", "interrupt_exist_connections" ]) {
        if (outbound[key] != null)
            group[key] = outbound[key];
    }

    state.urltestGroups[tag_name] = group;
}

function remember_urltest_group_config(state, tag_name, input_group) {
    if (type(state) != "object")
        return;

    input_group = object_or_empty(input_group);
    let output_group = {
        displayName: as_string(input_group.displayName || "") != "" ? as_string(input_group.displayName) : tag_name,
        outbounds: array_or_empty(input_group.outbounds)
    };

    for (let key in [ "url", "interval", "tolerance", "idle_timeout", "interrupt_exist_connections" ]) {
        if (input_group[key] != null)
            output_group[key] = input_group[key];
    }

    state.urltestGroups[tag_name] = output_group;
}

function resolve_urltest_profile_aliases(state) {
    if (type(state) != "object")
        return;

    let servers = object_or_empty(state.servers);
    let metadata = object_or_empty(state.outboundMetadata);
    let names = object_or_empty(metadata.names);
    let countries = object_or_empty(metadata.countries);
    let descriptions = object_or_empty(metadata.descriptions);
    let aliases = object_or_empty(metadata.aliases);

    for (let _, group in object_or_empty(state.urltestGroups)) {
        let members = {};
        for (let member in array_or_empty(object_or_empty(group).outbounds))
            members[as_string(member)] = true;

        for (let member in keys(members)) {
            if (match(member, /^proxy(-[0-9]+)*$/) == null)
                continue;
            let server = as_string(servers[member] || "");
            if (server == "")
                continue;

            let profile_tag = "";
            for (let candidate, candidate_server in servers) {
                candidate = as_string(candidate);
                if (candidate == member || as_string(candidate_server) != server)
                    continue;
                if (match(candidate, /^proxy(-[0-9]+)*$/) != null)
                    continue;
                profile_tag = candidate;
                break;
            }
            if (profile_tag == "")
                continue;

            aliases[member] = profile_tag;
            names[member] = as_string(names[profile_tag] || profile_tag);
            if (countries[profile_tag] != null)
                countries[member] = countries[profile_tag];
            if (descriptions[profile_tag] != null)
                descriptions[member] = descriptions[profile_tag];
        }
    }

    metadata.names = names;
    metadata.countries = countries;
    metadata.descriptions = descriptions;
    metadata.aliases = aliases;
    state.outboundMetadata = metadata;
}

function remember_priority_group(state, tag_name, group) {
    if (type(state) != "object")
        return;

    state.priorityGroups[tag_name] = object_or_empty(group);
}

function read_source_outbounds(source_section, source_entry, expected_user_agent, expected_hwid) {
    let record = source_cache.read(TMP_SUBSCRIPTION_FOLDER, source_section);
    let parsed = parse_source_entry(source_entry);
    let user_agent = as_string(expected_user_agent) || parsed.user_agent;
    let hwid = as_string(expected_hwid);
    if (record.profile.url != parsed.url ||
        (user_agent != "" && record.profile.user_agent != user_agent) ||
        (hwid != "" && record.profile.hwid != hwid))
        return [];
    return subscription_parser.repair_cached_outbounds(array_or_empty(record.payload?.outbounds));
}

function new_section_state(section_name) {
    return {
        version: FORKOP_RUNTIME_CACHE_FORMAT,
        section: section_name,
        links: {},
        outboundMetadata: {
            names: {},
            filterNames: {},
            countries: {},
            protocols: {},
            transports: {},
            securities: {},
            descriptions: {}
        },
        servers: {},
        urltestCandidateTags: [],
        urltestGroups: {},
        priorityGroups: {},
        subscriptionMetadata: []
    };
}

return {
    set_section_cache_dir,
    source_id,
    section_cache_path,
    merge_source_metadata,
    remember_outbound_metadata,
    remember_source_outbound,
    remember_urltest_group,
    remember_urltest_group_config,
    resolve_urltest_profile_aliases,
    remember_priority_group,
    read_source_outbounds,
    new_section_state
};
