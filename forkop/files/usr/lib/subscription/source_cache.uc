let fs = require("fs");
let common = require("core.common");

function first_line(path) {
    return split(fs.readfile(path) || "", "\n", 2)[0];
}

function read(dir, source, keep_text) {
    let base = dir + "/" + source;
    let text = keep_text ? fs.readfile(base + ".json") : null;
    let payload = null;
    if (keep_text) {
        try { payload = text == null ? null : json(text); } catch (e) {}
    }
    else
        payload = common.read_json_file(base + ".json");
    let profile = payload?.__forkop_source_cache;
    if (type(profile) == "object")
        return { payload, profile, text };

    // Existing installations can restore their flat caches offline.
    return {
        payload,
        text,
        profile: {
            url: first_line(base + ".url"),
            user_agent: first_line(base + ".user_agent"),
            hwid: first_line(base + ".hwid"),
            metadata: common.read_json_file(base + ".metadata.json")
        }
    };
}

function same_profile(a, b) {
    return a.url == b.url && a.user_agent == b.user_agent && a.hwid == b.hwid;
}

function publish(path, payload, profile, previous_text) {
    if (type(payload) != "object" || type(payload.outbounds) != "array" || !length(payload.outbounds))
        return false;

    payload.__forkop_source_cache = profile;
    let text = sprintf("%J\n", payload);
    if ((previous_text ?? fs.readfile(path)) == text)
        return fs.stat(path)?.mode == 0600 || !!fs.chmod(path, 0600);

    // Recover space consumed by a writer that died before its rename.
    let prefix = path + ".pending.";
    let pid = split(fs.readfile("/proc/self/stat") || "", " ")[0];
    if (match(pid, /^[1-9][0-9]*$/) == null)
        return false;
    for (let leftover in fs.glob(prefix + "*") || []) {
        let owner = substr(leftover, length(prefix));
        if (match(owner, /^[1-9][0-9]*$/) != null && (owner == pid || fs.stat("/proc/" + owner) == null))
            fs.unlink(leftover);
    }
    let staged = prefix + pid;
    if (common.write_private_file(staged, text) == null || !fs.rename(staged, path)) {
        fs.unlink(staged);
        return false;
    }
    return true;
}

return { read, same_profile, publish };
