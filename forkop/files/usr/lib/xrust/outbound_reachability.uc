// Subscription catalogs stay complete; only runtime objects are trimmed.
// Restrict removal to objects generated for sections with configured groups.
function prune(config, candidates) {
    let by_tag = {};
    let live = {};
    let pending = [];
    for (let outbound in config.outbounds || []) {
        by_tag[outbound.tag] = outbound;
        if (!candidates[outbound.tag])
            push(pending, outbound.tag);
    }

    function references(value) {
        if (type(value) == "array") {
            for (let item in value) references(item);
        }
        else if (type(value) == "object") {
            for (let key, item in value) {
                if ((key == "outbound" || match(key, /(^|_)detour$/) != null || key == "default" || key == "final") &&
                    type(item) == "string" && by_tag[item])
                    push(pending, item);
                else if (key == "outbounds" && type(item) == "array") {
                    for (let tag in item)
                        if (type(tag) == "string" && by_tag[tag]) push(pending, tag);
                }
                else references(item);
            }
        }
    }

    // Keep explicit route/DNS/service references, including cross-section ones.
    for (let key, value in config)
        if (key != "outbounds") references(value);
    for (let i = 0; i < length(pending); i++) {
        let tag = pending[i];
        if (live[tag]) continue;
        live[tag] = true;
        references(by_tag[tag]);
    }

    let kept = [];
    for (let outbound in config.outbounds || [])
        if (live[outbound.tag]) push(kept, outbound);
    config.outbounds = kept;
}

return { prune };
