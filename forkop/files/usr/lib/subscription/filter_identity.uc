#!/usr/bin/env ucode

let common = require("core.common");

// Compare the actual connection, not its presentation or position in a feed.
// The canonical key stays in memory; credentials are never used as UI values.
function canonical(value) {
    if (type(value) == "array")
        return map(value, item => canonical(item));
    if (type(value) != "object")
        return value;
    let result = {};
    for (let key in sort(keys(value)))
        result[key] = canonical(value[key]);
    return result;
}

function connection_key(outbound) {
    if (type(outbound) != "object" || !outbound.server ||
        outbound.type == "selector" || outbound.type == "urltest")
        return "";
    let connection = {};
    for (let key, value in outbound) {
        if (key == "tag" || key == "remark" || key == "share_link" ||
            index(key, "__forkop_") == 0)
            continue;
        connection[key] = value;
    }
    return sprintf("%J", canonical(connection));
}

function names(outbound) {
    let result = [];
    for (let name in [ outbound.remark, outbound.tag,
        ...common.array_or_empty(outbound.__forkop_filter_names) ]) {
        if (type(name) == "string" && name != "" && index(result, name) < 0)
            push(result, name);
    }
    return result;
}

function inherit_names(previous, next) {
    let by_connection = {};
    for (let outbound in common.array_or_empty(common.object_or_empty(previous).outbounds)) {
        let key = connection_key(outbound);
        if (key == "")
            continue;
        let known = by_connection[key] || [];
        for (let name in names(outbound))
            if (index(known, name) < 0)
                push(known, name);
        by_connection[key] = known;
    }
    for (let outbound in common.array_or_empty(common.object_or_empty(next).outbounds)) {
        // Never accept alias history supplied by a subscription provider.
        delete outbound.__forkop_filter_names;
        let known = by_connection[connection_key(outbound)];
        if (type(known) == "array" && length(known))
            outbound.__forkop_filter_names = known;
    }
    return next;
}

return { connection_key, names, inherit_names };
