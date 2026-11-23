let fs = require("fs");
let uci = require("core.uci");
let common = require("core.common");
let process_identity = require("core.process_identity");
let as_string = common.as_string;

function quote(v) { return "'" + replace(as_string(v), /'/g, "'\\''") + "'"; }
function output(command, timeout) {
    let dir = null;
    if (type(fs.mkdtemp) == "function") dir = fs.mkdtemp("/tmp/forkop-dns-readiness.XXXXXX");
    else {
        let pipe = fs.popen("mktemp -d /tmp/forkop-dns-readiness.XXXXXX", "r");
        if (pipe) {
            let name = trim(as_string(pipe.read("all")));
            if (pipe.close() == 0 && match(name, /^\/tmp\/forkop-dns-readiness\.[A-Za-z0-9]+$/)) dir = name;
        }
    }
    if (dir == null) return "";
    let path = dir + "/output";
    let status = system("exec " + command + " >" + quote(path), int(timeout || 1000));
    let data = status == 0 ? as_string(fs.readfile(path)) : "";
    fs.unlink(path);
    fs.rmdir(dir);
    return data;
}
function service_instances() {
    try {
        let data = json(output("ubus call service list '{\"name\":\"dnsmasq\"}' 2>/dev/null"));
        return data.dnsmasq.instances;
    } catch (e) { return null; }
}
function select_processes(candidates) {
    let result = {};
    for (let path, group in candidates) {
        let root = null;
        for (let pid, proc in group) {
            if (group[proc.parent] != null) continue;
            if (root != null) return null; // Independent daemons are ambiguous.
            root = proc;
        }
        if (root == null) return null;
        for (let pid, proc in group) {
            let seen = {};
            while (proc.pid != root.pid) {
                if (seen[proc.pid]) return null;
                seen[proc.pid] = true;
                proc = group[proc.parent];
                if (proc == null) return null;
            }
        }
        // dnsmasq's DHCP script helper inherits its executable and -C argument.
        // Keep the parent daemon; ready() still verifies procd and DNS sockets.
        result[path] = root;
    }
    return result;
}
function process_map() {
    let candidates = {};
    for (let entry in fs.lsdir("/proc") || []) {
        if (match(entry, /^[0-9]+$/) == null || fs.readlink("/proc/" + entry + "/exe") != "/usr/sbin/dnsmasq")
            continue;
        let args = split(as_string(fs.readfile("/proc/" + entry + "/cmdline")), "\u0000");
        let path = "";
        for (let i = 0; i + 1 < length(args); i++)
            if (args[i] == "-C") path = args[i + 1];
        let stat = process_identity.parse_stat(fs.readfile("/proc/" + entry + "/stat"));
        if (path == "" || stat == null || stat.state == "Z") continue;
        if (candidates[path] == null) candidates[path] = {};
        candidates[path][entry] = { pid: entry, parent: stat.parent, identity: entry + ":" + stat.ticks };
    }
    return select_processes(candidates);
}
function values(v) { return type(v) == "array" ? v : (v == null || v == "" ? [] : [as_string(v)]); }
function contains(items, value) { for (let item in items) if (item == value) return true; return false; }
function options(text, key) {
    let result = [];
    for (let line in split(as_string(text), "\n")) {
        line = trim(line);
        if (line == key) push(result, "");
        else if (substr(line, 0, length(key) + 1) == key + "=") push(result, substr(line, length(key) + 1));
    }
    return result;
}
function expected_config(section, text) {
    let port = as_string(section.port == null ? "53" : section.port);
    if (match(port, /^[0-9]+$/) == null || int(port) > 65535) return false;
    let generated_port = options(text, "port");
    if (length(generated_port) > 1 || as_string(generated_port[0] == null ? "53" : generated_port[0]) != port) return false;
    if (sprintf("%J", options(text, "server")) != sprintf("%J", values(section.server))) return false;
    if ((length(options(text, "no-resolv")) > 0) != common.bool_option(section, "noresolv", false)) return false;
    if (section.cachesize != null && sprintf("%J", options(text, "cache-size")) != sprintf("%J", [as_string(section.cachesize)])) return false;
    return true;
}
function plan() {
    let result = [];
    for (let section in uci.section_objects("dhcp", "dnsmasq")) {
        let name = as_string(section[".name"]);
        if (match(name, /^[A-Za-z0-9_]+$/) == null) return null;
        push(result, { name, section, disabled: common.bool_option(section, "disabled", false),
            path: "/var/etc/dnsmasq.conf." + name, port: int(section.port == null ? "53" : section.port) });
    }
    return length(result) > 0 ? result : null;
}
function socket_inodes(pid) {
    let inodes = {};
    let fd_dir = "/proc/" + pid + "/fd";
    for (let fd in fs.lsdir(fd_dir) || []) {
        let m = match(as_string(fs.readlink(fd_dir + "/" + fd)), /^socket:\[([0-9]+)\]$/);
        if (m) inodes[m[1]] = true;
    }
    return inodes;
}
function loopback_sockets(text, listening, wanted_ports) {
    let sockets = {};
    for (let line in split(as_string(text), "\n")) {
        let cols = split(trim(line), /[ \t]+/);
        if (length(cols) < 10 || (listening && cols[3] != "0A")) continue;
        let address = split(cols[1], ":");
        if (length(address) != 2 || (address[0] != "0100007F" && address[0] != "00000000")) continue;
        if (wanted_ports != null && !wanted_ports[address[1]]) continue;
        if (sockets[address[1]] == null) sockets[address[1]] = {};
        sockets[address[1]][cols[9]] = true;
    }
    return sockets;
}
function owns_port(inodes, sockets, port) {
    for (let inode, _ in sockets[sprintf("%04X", port)] || {})
        if (inodes[inode]) return true;
    return false;
}
function owned_loopback_socket(pid, port, table, listening) {
    return owns_port(socket_inodes(pid), loopback_sockets(fs.readfile("/proc/net/" + table), listening), port);
}
function monotonic() { let t = clock(true); return t[0] + t[1] / 1000000000.0; }
function ready(entries, before, old_processes, old_instances, deadline) {
    let instances = service_instances();
    let processes = process_map();
    if (instances == null || processes == null) return false;
    let enabled = {};
    let confirmed = [];
    let udp = null, tcp = null;
    for (let entry in entries) {
        if (monotonic() >= deadline) return false;
        let instance = instances[entry.name];
        let proc = processes[entry.path];
        if (entry.disabled) {
            if (proc != null || (instance != null && instance.running)) return false;
            continue;
        }
        enabled[entry.name] = true;
        let text = fs.readfile(entry.path);
        if (instance == null || !instance.running || proc == null || text == null || !expected_config(entry.section, text)) return false;
        // The procd PID can be the jail wrapper. Bind the real daemon to that
        // instance by its parent, exact executable and -C argument.
        if (as_string(instance.pid) != proc.pid && as_string(instance.pid) != proc.parent) return false;
        let old = old_processes == null ? null : old_processes[entry.path];
        if (before[entry.path] != text && old != null && old.identity == proc.identity) return false;
        if (entry.port != 0) {
            if (udp == null) {
                let wanted_ports = {};
                for (let candidate in entries)
                    if (!candidate.disabled && candidate.port != 0)
                        wanted_ports[sprintf("%04X", candidate.port)] = true;
                udp = loopback_sockets(fs.readfile("/proc/net/udp"), false, wanted_ports);
                tcp = loopback_sockets(fs.readfile("/proc/net/tcp"), true, wanted_ports);
            }
            let inodes = socket_inodes(proc.pid);
            if (!owns_port(inodes, udp, entry.port) || !owns_port(inodes, tcp, entry.port)) return false;
            // CHAOS is answered locally, without depending on WAN or sing-box.
            // REFUSED is also a valid reply when version disclosure is disabled.
            let timeout = int((deadline - monotonic()) * 1000);
            if (timeout < 1) return false;
            let reply = output("dig @127.0.0.1 -p " + entry.port + " version.bind TXT CH +norecurse +time=1 +tries=1 +noall +comments 2>/dev/null", timeout < 1100 ? timeout : 1100);
            if (match(reply, /status: (NOERROR|REFUSED|NXDOMAIN|NOTIMP),/) == null) return false;
        }
        push(confirmed, { path: entry.path, text, identity: proc.identity });
    }
    for (let name, instance in old_instances || {})
        if (!enabled[name] && (instances[name]?.running || processes["/var/etc/dnsmasq.conf." + name] != null)) return false;
    if (length(confirmed) == 0) return true;
    let after = process_map();
    if (after == null) return false;
    for (let item in confirmed)
        if (fs.readfile(item.path) != item.text || after[item.path]?.identity != item.identity) return false;
    return monotonic() < deadline;
}
function wait_ready(entries, before, processes, instances, timeout) {
    let deadline = monotonic() + timeout;
    let confirmed = false;
    while (monotonic() < deadline) {
        let ok = ready(entries, before, processes, instances, deadline);
        if (ok && confirmed) return true;
        confirmed = ok;
        sleep(50);
    }
    return false;
}
function apply(init) {
    let entries = plan();
    let before = {};
    let processes = process_map();
    let instances = service_instances();
    let loopback_supported = true;
    for (let entry in entries || []) {
        if (entry.disabled || entry.port == 0) continue;
        let addresses = values(entry.section.listen_address);
        if (length(addresses) > 0 && !contains(addresses, "127.0.0.1") && !contains(addresses, "0.0.0.0"))
            loopback_supported = false;
        for (let iface in values(entry.section.notinterface))
            if (iface == "lo" || iface == "loopback") loopback_supported = false;
        let interfaces = values(entry.section.interface);
        if (length(interfaces) > 0 && !contains(interfaces, "lo") && !contains(interfaces, "loopback"))
            loopback_supported = false;
    }
    // Unknown init/layout and non-loopback listeners retain the existing
    // synchronous restart contract; do not infer readiness from another DNS.
    if (init != "/etc/init.d/dnsmasq" || entries == null || !loopback_supported)
        return system("[ -x " + quote(init) + " ] && " + quote(init) + " restart", 15000) == 0;
    for (let entry in entries) before[entry.path] = fs.readfile(entry.path);
    if (processes != null && instances != null &&
        system("exec " + quote(init) + " reload", 15000) == 0 && wait_ready(entries, before, processes, instances, 4)) return true;
    system("logger -t forkop 'dnsmasq reload not ready; falling back to restart'");
    return system("exec " + quote(init) + " restart", 15000) == 0 && wait_ready(entries, before, processes, instances, 8);
}
return { apply, expected_config, options, plan, process_map, select_processes, service_instances, owned_loopback_socket, loopback_sockets, owns_port };
