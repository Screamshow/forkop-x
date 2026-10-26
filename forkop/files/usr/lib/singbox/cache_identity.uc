// Use separate physical stores: cache_id alone cannot isolate database formats.
// Preserve old stores for rollback; never delete user-configured cache files.
let common = require("core.common");

function family(version) {
    version = lc(common.as_string(version));
    if (index(version, "-rust-x.") >= 0)
        return "rust-x";
    if (match(version, /-x-[0-9]+[.]/) != null)
        return "x";
    if (index(version, "extended") >= 0)
        return "extended";
    if (index(version, "-lx") >= 0)
        return "lx";
    return "upstream";
}

function path(base, version) {
    base = common.as_string(base);
    // Leave the legacy database to upstream/Tiny. Other implementations get
    // dedicated sibling files, also when the operator configured a custom path.
    let name = family(version);
    return name == "upstream" ? base : base + ".forkop-" + name;
}

return { family, path };
