// 2.7.6 appends this suffix to the configured path. Keep the same Xrust store
// across upgrades and downgrades, including custom cache paths.
let common = require("core.common");

function path(base) {
    return common.as_string(base) + ".forkop-rust-x";
}

return { path };
