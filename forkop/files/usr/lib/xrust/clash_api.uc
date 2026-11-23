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
    // Read the applied bind, since netifd may already report a different LAN
    // address while the old core still owns the listener.
    let path = trim(split(fs.readfile(xrust.APPLIED_CONFIG_PATH_FILE) || "", "\n")[0]);
    let config = path == "" ? null : common.read_json_file(path);
    let controller = common.as_string(config?.experimental?.clash_api?.external_controller);
    let fields = match(controller, /^([0-9.]+):9090$/);
    if (fields && core_ip.valid_ipv4(fields[1], false, true))
        return fields[1] == "0.0.0.0" ? LOOPBACK : fields[1];
    return listen_address();
}

function latency_args(endpoint, timeout) {
    // The core receives milliseconds. Allow HTTP overhead while keeping
    // curl bounded even if the local controller stops responding.
    let milliseconds = int(timeout);
    if (milliseconds <= 0)
        milliseconds = 5000;
    return [ "curl", "--max-time", common.as_string(int(milliseconds / 1000) + 3), "-G", "-fs", endpoint ];
}

function valid_latency(value) {
    return type(value) == "int" && value > 0;
}

function parse_latency(output, group) {
    let value;
    try { value = json(output); }
    catch (e) { return null; }
    if (type(value) != "object")
        return null;
    if (!group)
        return valid_latency(value.delay) ? value : null;
    for (let _, delay in value)
        if (valid_latency(delay))
            return value;
    return null;
}

return { listen_address, local_request_address, latency_args, parse_latency };
