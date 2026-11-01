// Recovery is transactional: work on copies, and require explicit provenance.
// A tag's spelling is never evidence that it came from a subscription.
function copy(value) { return json(sprintf("%J", value)); }
function array(value) { return type(value) == "array" ? value : []; }
function object(value) { return type(value) == "object" ? value : {}; }
function str(value) { return value == null ? "" : "" + value; }

function blamed_index(reason) {
    // Only a config validation path, never a network failure or quoted value.
    let text = trim(replace(str(reason), /\x1b\[[0-9;]*m/g, ""));
    let m = match(text, /^(check: |reload-plan: candidate configuration rejected at )?outbounds\[([0-9]+)\]\./);
    if (m != null) return int(m[2]);
    m = match(text, /^FATAL\[[0-9]+\] initialize outbound\[([0-9]+)\]:/);
    return m == null ? null : int(m[1]);
}

function clean(value, removed) {
    if (type(value) == "array") {
        let result = [];
        for (let item in value)
            if (type(item) != "string" || !removed[item]) push(result, clean(item, removed));
        return result;
    }
    if (type(value) != "object") return value;
    let result = {};
    for (let key, item in value)
        if (!removed[key] && !(type(item) == "string" && removed[item]))
            result[key] = clean(item, removed);
    return result;
}

function cold_retry(result, states) {
    if (result.status == 0 || trim(str(result.output)) != "reload-plan: candidate configuration rejected") return false;
    for (let state in states)
        for (let tag, enabled in object(object(state).subscriptionOutbounds))
            if (enabled === true) return true;
    return false;
}

function recover(config, section_states, reason) {
    let index = blamed_index(reason);
    if (index == null || index >= length(array(config.outbounds))) return null;
    let states = copy(section_states);
    let cfg = copy(config);
    let owned = {};
    for (let state in states)
        for (let tag, enabled in object(state.subscriptionOutbounds))
            if (enabled === true) owned[tag] = true;
    let bad = cfg.outbounds[index];
    let tag = str(bad.tag);
    if (tag == "" || !owned[tag]) return null;
    let removed = {}; removed[tag] = true;
    let changed = true;
    while (changed) {
        changed = false;
        for (let outbound in cfg.outbounds) {
            let name = str(outbound.tag);
            if (removed[name]) continue;
            let unavailable = removed[str(outbound.detour)] === true;
            if (type(outbound.outbounds) == "array") {
                let members = [], lost = false, usable = false;
                for (let member in outbound.outbounds) {
                    if (removed[member]) lost = true;
                    else {
                        push(members, member);
                        for (let candidate in cfg.outbounds)
                            if (candidate.tag == member && candidate.type != "direct" &&
                                candidate.type != "block" && candidate.type != "dns") usable = true;
                    }
                }
                if (lost) {
                    // Do not silently select a direct-only fallback.
                    unavailable = unavailable || !usable;
                    outbound.outbounds = members;
                    if (removed[str(outbound.default)]) outbound.default = members[0];
                }
            }
            if (unavailable) {
                if (!owned[name]) return null;
                removed[name] = true;
                changed = true;
            }
        }
    }
    cfg.outbounds = filter(cfg.outbounds, outbound => !removed[str(outbound.tag)]);
    // References outside subscription groups cannot be repaired by guessing.
    function dangling(value) {
        if (type(value) == "array") {
            for (let item in value) if (dangling(item)) return true;
        }
        if (type(value) == "object") {
            for (let key, item in value) {
                if ((key == "outbound" || key == "detour" || key == "final") && removed[str(item)]) return true;
                if (dangling(item)) return true;
            }
        }
        return false;
    }
    if (dangling(cfg)) return null;
    let cleaned = [];
    for (let state in states) {
        let skipped = array(state.skippedSubscriptionOutbounds);
        for (let name in removed)
            if (object(state.subscriptionOutbounds)[name])
                push(skipped, { tag: name, reason: name == tag ? "core-validation" : "unavailable-dependency" });
        let item = clean(state, removed);
        item.skippedSubscriptionOutbounds = skipped;
        push(cleaned, item);
    }
    return { config: cfg, states: cleaned, removed };
}

return { recover, blamed_index, cold_retry };
