#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let identity = require("subscription.filter_identity");
let uci = require("core.uci");
let connections = require("config.connections");
const CONFIG = getenv("FORKOP_CONFIG_NAME") || "forkop";
const CACHE = getenv("FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR") || "/etc/forkop/subscription-cache";
const RUNTIME = getenv("TMP_SUBSCRIPTION_FOLDER") || "/tmp/sing-box/subscriptions";

function list(value) {
    return type(value) == "array" ? value : value == null || value == "" ? [] : [ value ];
}

// Private cache only: connection keys contain credentials and must never be
// copied into UCI, generated core config, UI metadata or logs.
function connection(source, outbound) {
    let key = identity.connection_key(outbound);
    return key == "" ? "" : sprintf("%J", [ source, key ]);
}

function path(rule) {
    if (match(rule, /^[A-Za-z0-9_-]+$/) == null)
        die("Invalid filter binding rule\n");
    return CACHE + "/" + rule + ".filter-bindings";
}

function read(rule) {
    return common.object_or_empty(common.read_json_file(path(rule)));
}

function candidates(section) {
    let result = [];
    let index_value = 0;
    for (let source in connections.subscription_urls(section)) {
        index_value++;
        let file = section[".name"] + "-subscription-" + index_value + ".json";
        let feed = common.read_json_file(RUNTIME + "/" + file) || common.read_json_file(CACHE + "/" + file);
        let prefix = connections.subscription_node_prefix(section, source);
        for (let outbound in common.array_or_empty(feed?.outbounds)) {
            let key = connection(source, outbound);
            if (key == "")
                continue;
            let name = outbound.remark || outbound.tag;
            if (!name)
                continue;
            push(result, { name: prefix != "" ? prefix + " " + name : name, key });
        }
    }
    return result;
}

// A provider may change an endpoint address without changing the selected node.
// Keep source, credentials, TLS and transport strict; only server may differ.
function address_profile(key) {
    try {
        let parts = json(key);
        if (type(parts) != "array" || length(parts) != 2)
            return "";
        let outbound = json(parts[1]);
        if (!outbound.server)
            return "";
        outbound.server = "address-migration";
        return connection(parts[0], outbound);
    }
    catch (e) { return ""; }
}

function migrate_address(keys, name, previous, next) {
    // Multiple selected connections or duplicate names are ambiguous. Exact
    // identity matches always win, including a surviving node renamed elsewhere.
    if (length(keys) != 1 || length(filter(next, c => c.key == keys[0])))
        return keys;
    let profile = address_profile(keys[0]);
    if (profile == "")
        return keys;
    let targets = filter(next, c => c.name == name);
    if (length(targets) != 1 || address_profile(targets[0].key) != profile)
        return keys;
    // Do not steal a different existing connection during a rename/removal.
    let old_present = length(filter(previous, c => c.key == keys[0])) > 0;
    if (length(filter(previous, c => c.key == targets[0].key && (old_present || c.name != name))))
        return keys;
    return [ targets[0].key ];
}

// Resolve against the OLD feed before considering any new names. In particular,
// simultaneous A->B / B->A renames must not cascade through string replacements.
function reconcile(values, saved, previous, next) {
    let records = [];
    let names = [];
    for (let name in list(values)) {
        let keys = null;
        for (let record in list(saved))
            if (record.name == name)
                keys = record.keys;
        if (keys == null) {
            keys = [];
            for (let candidate in length(previous) ? previous : next)
                if (candidate.name == name && index(keys, candidate.key) < 0)
                    push(keys, candidate.key);
        }
        keys = migrate_address(keys, name, previous, next);
        let matches = filter(next, candidate => index(keys, candidate.key) >= 0);
        // Keep a tombstone if the selected connection disappears. A new owner
        // of its name must not take over an existing selection.
        let next_names = length(matches) ? map(matches, candidate => candidate.name) : [ name ];
        let missing = filter(keys, key => !length(filter(matches, candidate => candidate.key == key)));
        if (length(matches) && length(missing))
            push(next_names, name);
        if (!length(keys)) {
            // Names may also select manually configured proxies or provider
            // groups. They have no subscription connection to pin here.
            if (index(names, name) < 0)
                push(names, name);
            continue;
        }
        for (let next_name in next_names) {
            let selected_keys = map(filter(matches, candidate => candidate.name == next_name), candidate => candidate.key);
            if (next_name == name)
                selected_keys = [ ...selected_keys, ...missing ];
            let record = null;
            for (let item in records)
                if (item.name == next_name)
                    record = item;
            if (record == null) {
                record = { name: next_name, keys: [] };
                push(records, record);
                push(names, next_name);
            }
            for (let key in selected_keys)
                if (index(record.keys, key) < 0)
                    push(record.keys, key);
        }
    }
    return { names, records };
}

function urltest_key(section, id) {
    return "urltest:" + section[".name"] + ":" + id;
}

function priority_key(id) {
    return "priority:" + id;
}

function descriptors(section) {
    let result = [];
    for (let id in connections.urltests(section)) {
        let settings = connections.urltest_settings(section, id);
        let child = settings[".name"];
        for (let side in [ "include", "exclude" ]) {
            let field = side + "_outbounds";
            let legacy = "urltest_" + field;
            let nested = !child && settings[legacy] != null;
            let values = side == "include" ? connections.urltest_include_outbounds(section, id) :
                connections.urltest_exclude_outbounds(section, id);
            push(result, { key: urltest_key(section, id), side, values,
                owner: child || section[".name"],
                field: child ? (settings[field] != null ? field : settings[legacy] != null ? legacy : field) :
                    nested ? "urltest_settings" : legacy,
                nested: nested ? id : "", nested_field: legacy });
        }
    }
    for (let group in connections.priority_groups(section))
        for (let id in connections.priority_levels(group))
            for (let side in [ "include", "exclude" ]) {
                let child = uci.get_all(CONFIG, id);
                let field = side + "_outbounds";
                if (side == "include" && child?.include_outbounds == null && child?.server_name != null)
                    field = "server_name";
                push(result, { key: priority_key(id), side,
                    values: side == "include" ? connections.priority_level_include_outbounds(group, id) :
                        connections.priority_level_exclude_outbounds(group, id), owner: id, field, nested: "" });
            }
    return result;
}

function snapshot(section) {
    return { section, previous: candidates(section), descriptors: descriptors(section), saved: read(section[".name"]) };
}

function publish(target, value) {
    let text = sprintf("%J\n", value);
    if (fs.readfile(target) == text)
        return true;
    return common.secure_private_dir(CACHE) && common.write_private_file(target + ".new", text) != null &&
        fs.rename(target + ".new", target);
}

function current_values(item) {
    let value = uci.get_all(CONFIG, item.owner)?.[item.field];
    if (item.nested != "") {
        try { value = json(value)[item.nested]?.[item.nested_field]; }
        catch (e) { return []; }
    }
    return list(value);
}

function binding_records(saved, side, values) {
    if (saved?.["_" + side + "_values"] == null ||
        sprintf("%J", saved["_" + side + "_values"]) == sprintf("%J", list(values)))
        return list(saved?.[side]);
    let previous = saved?.["_" + side + "_previous"];
    if (sprintf("%J", previous?.values) == sprintf("%J", list(values)))
        return list(previous.records);
    return [];
}

function finish(before) {
    if (!uci.reload(CONFIG))
        return { ok: false, changed: false };
    let next = candidates(before.section);
    let saved = {};
    let changes = [];
    for (let item in before.descriptors) {
        // A concurrent user edit wins over an in-flight subscription update.
        if (sprintf("%J", current_values(item)) != sprintf("%J", list(item.values)))
            continue;
        let result = reconcile(item.values, binding_records(before.saved[item.key], item.side, item.values), before.previous, next);
        saved[item.key] ||= {};
        saved[item.key][item.side] = result.records;
        saved[item.key]["_" + item.side + "_values"] = result.names;
        if (sprintf("%J", result.names) != sprintf("%J", list(item.values)))
            push(changes, { item, names: result.names });
    }
    let committed_saved = json(sprintf("%J", saved));
    // Stage both versions, keyed by the complete configured name list. This
    // distinguishes swaps as well as simple renames across a failed UCI commit.
    for (let item in before.descriptors) {
        let records = saved[item.key]?.[item.side];
        if (type(records) != "array")
            continue;
        if (sprintf("%J", saved[item.key]["_" + item.side + "_values"]) == sprintf("%J", list(item.values)))
            continue;
        let old = reconcile(item.values, binding_records(before.saved[item.key], item.side, item.values),
            before.previous, before.previous);
        saved[item.key]["_" + item.side + "_previous"] = { values: list(item.values), records: old.records };
    }
    let target = path(before.section[".name"]);
    if (!publish(target, saved))
        return { ok: false, changed: false };
    for (let change in changes) {
        let item = change.item;
        let value = change.names;
        if (item.nested != "") {
            let settings = json(uci.get(CONFIG + "." + item.owner + "." + item.field));
            settings[item.nested] ||= {};
            settings[item.nested][item.nested_field] = value;
            value = sprintf("%J", settings);
        }
        if (!uci.set(CONFIG + "." + item.owner + "." + item.field, value))
            return { ok: false, changed: false };
    }
    if (length(changes) && !uci.commit(CONFIG))
        return { ok: false, changed: false };
    if (!publish(target, committed_saved))
        return { ok: false, changed: false };
    return { ok: true, changed: length(changes) > 0 };
}

function bound_names(saved, side, values) {
    let result = {};
    for (let record in binding_records(saved, side, values))
        result[record.name] = record.keys;
    return result;
}

return { connection, candidates, reconcile, snapshot, finish, read, urltest_key, priority_key, bound_names };
