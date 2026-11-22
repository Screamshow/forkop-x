let common = require("core.common");
let ip = require("core.ip");
let uci = require("core.uci");

function configuration() {
    let config = common.object_or_empty(uci.get_all("system", "ntp"));
    let enabled = common.bool_option(config, "enabled", true);
    let servers = [];
    for (let value in common.list_option(config, "server")) {
        let server = trim(common.as_string(value));
        if (server != "" && index(servers, server) < 0)
            push(servers, server);
    }
    return { enabled, servers };
}

function server_names() {
    let config = configuration();
    return config.enabled ? filter(config.servers, value => !ip.valid_ip(value)) : [];
}

return { configuration, server_names };
