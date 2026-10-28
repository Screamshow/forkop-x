let fs = require("fs");

function start_ticks(stat) {
    let marker = rindex(stat || "", ") ");
    let fields = marker >= 0 ? split(trim(substr(stat, marker + 2)), /\s+/) : [];
    return length(fields) >= 20 ? fields[19] : null;
}

// Sum the verified instances of one procd service. The caller owns `seen`, so a
// pid reached through two service names is counted once across a whole group.
function instances_rss_bytes(instances, proc_root, seen) {
    let total = 0;
    for (let _, instance in instances) {
        let pid = int(instance.pid || 0);
        if (instance.running !== true || pid <= 0 || seen[pid])
            continue;
        let path = proc_root + "/" + pid;
        let before = start_ticks(fs.readfile(path + "/stat"));
        let cmdline = fs.readfile(path + "/cmdline");
        let command = instance.command;
        if (before == null || cmdline == null || type(command) != "array" || !length(command))
            return null;
        let args = split(cmdline, "\x00");
        if (args[length(args) - 1] == "")
            pop(args);
        if (length(args) != length(command))
            return null;
        for (let i = 0; i < length(args); i++) {
            // procd may resolve the interpreter through PATH.
            let actual = i == 0 ? replace(args[i], /^.*\//, "") : args[i];
            let expected = i == 0 ? replace(command[i], /^.*\//, "") : command[i];
            if (actual != expected)
                return null;
        }
        let rss = match(fs.readfile(path + "/status") || "", /VmRSS:[ \t]+([0-9]+)[ \t]+kB/);
        if (rss == null || before != start_ticks(fs.readfile(path + "/stat")))
            return null;
        seen[pid] = true;
        total += int(rss[1]) * 1024;
    }
    return total;
}

function services_rss_bytes(services, service_name, proc_root) {
    if (type(services) != "object" || type(services[service_name]) != "object")
        return null;
    return instances_rss_bytes(services[service_name].instances || {}, proc_root, {});
}

// One figure for several procd services. Forkop's resident memory is spread over
// more than one service -- the native Tailscale runs the very same core binary
// under a service of its own -- so asking about a single name reports a fraction
// of what is actually resident and calls it the total.
//
// A name procd does not know is a component that is not installed: it adds
// nothing and does not spoil the figure. A service procd does know but whose
// instance cannot be verified makes the whole figure unavailable, so a number
// that is known to be short is never shown. When none of the names is known the
// figure is unavailable rather than zero, which is what tells an uninstalled
// core apart from one using no memory.
function services_group_rss_bytes(services, service_names, proc_root) {
    if (type(services) != "object" || type(service_names) != "array")
        return null;

    let total = 0;
    let seen = {};
    let known = false;
    for (let service_name in service_names) {
        if (type(services[service_name]) != "object")
            continue;
        let bytes = instances_rss_bytes(services[service_name].instances || {}, proc_root, seen);
        if (bytes == null)
            return null;
        known = true;
        total += bytes;
    }

    return known ? total : null;
}

// One procd service on its own, for a dashboard row that names it. A name
// procd does not know is a component that is not installed, and the caller
// gets null so it can leave the row out instead of printing a zero. A known
// service with no live instance reports running false with zero bytes, which
// is a stopped service rather than a missing one.
function services_state(services, service_name, proc_root) {
    if (type(services) != "object" || type(services[service_name]) != "object")
        return null;

    let instances = services[service_name].instances || {};
    let running = false;
    for (let _, instance in instances)
        if (instance.running === true && int(instance.pid || 0) > 0)
            running = true;

    return {
        running: running ? 1 : 0,
        memory_rss_bytes: instances_rss_bytes(instances, proc_root, {})
    };
}

function ubus_services(request) {
    let pipe = fs.popen("ubus call service list " + request + " 2>/dev/null", "r");
    if (!pipe)
        return null;
    let output = pipe.read("all");
    let status = pipe.close();
    if (status != 0)
        return null;
    try { return json(output); } catch (e) { return null; }
}

function valid_service_name(service_name) {
    return match(service_name || "", /^[A-Za-z0-9_.-]+$/) != null;
}

// Only count live procd children whose command still matches the registered
// instance. Never infer core identity from its process name or memory usage.
function service_rss_bytes(service_name) {
    if (!valid_service_name(service_name))
        return null;
    return services_rss_bytes(
        ubus_services("'{\"name\":\"" + service_name + "\"}'"), service_name, "/proc");
}

// One unfiltered listing answers for every name at once, which is one shell and
// one ubus round trip instead of one per service.
function service_group_rss_bytes(service_names) {
    if (type(service_names) != "array")
        return null;
    for (let service_name in service_names)
        if (!valid_service_name(service_name))
            return null;
    return services_group_rss_bytes(ubus_services(""), service_names, "/proc");
}


return {
    service_rss_bytes,
    service_group_rss_bytes,
    services_rss_bytes,
    services_group_rss_bytes,
    services_state
};
