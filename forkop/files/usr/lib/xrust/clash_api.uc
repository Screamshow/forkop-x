let fs = require("fs");
let common = require("core.common");
let core_ip = require("core.ip");
let xrust = require("xrust.binary");

const LOOPBACK = "127.0.0.1";

function lan_address() {
    let pipe = fs.popen("ubus -t 2 call network.interface.lan status 2>/dev/null", "r");
    if (!pipe)
        return null;

    let output = pipe.read("all");
    if (pipe.close() != 0)
        return null;

    try {
        let status = json(output);
        let address = status["ipv4-address"]?.[0]?.address;
        if (status.up === true && core_ip.valid_ipv4(address, false, true) &&
            address != "0.0.0.0" && status.l3_device)
            return address;
    }
    catch (e) {}
    return null;
}

function listen_address() {
    // Only netifd's logical LAN may expose the unauthenticated local API.
    return lan_address() || LOOPBACK;
}

function local_request_address() {
    let address = listen_address();
    if (address == LOOPBACK)
        return LOOPBACK;

    // LAN may have come up since generation. Honor the published loopback
    // binding until Xrust is restarted, without trusting an arbitrary host
    // from an older configuration.
    let path = trim(split(fs.readfile(xrust.APPLIED_CONFIG_PATH_FILE) || "", "\n")[0]);
    let config = path == "" ? null : common.read_json_file(path);
    let controller = config?.experimental?.clash_api?.external_controller;
    return controller == LOOPBACK + ":9090" ? LOOPBACK : address;
}

return { listen_address, local_request_address };
