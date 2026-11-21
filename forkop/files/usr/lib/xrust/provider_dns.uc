#!/usr/bin/env ucode
let fs = require('fs');
let ip = require('core.ip');

function read_json(command) {
    let p = fs.popen(command + ' 2>/dev/null', 'r');
    if (!p) return null;
    let data = p.read('all');
    let status = p.close();
    try { return status == 0 ? json(data) : null; } catch (e) { return null; }
}

function read_rules(family) {
    let args = ' ' + family + ' -j rule show';
    let rules = read_json('/usr/libexec/ip-full' + args);
    if (type(rules) == 'array') return rules;
    rules = read_json('ip' + args);
    return type(rules) == 'array' ? rules : null;
}

// Match installed mwan3 routing rules rather than assuming interface order,
// table numbers or the default mask. No firewall or routing mutation.
function interface_mark(rules, device) {
    for (let incoming in (rules || [])) {
        if (incoming.iif != device || incoming.table == null) continue;
        for (let outgoing in (rules || [])) {
            if (outgoing.table == incoming.table && outgoing.fwmark != null &&
                outgoing.fwmask != null && outgoing.iif == null && outgoing.oif == null)
                return substr('' + outgoing.fwmark, 0, 2) == '0x'
                    ? hex(substr(outgoing.fwmark, 2)) : int(outgoing.fwmark);
        }
    }
    return 0;
}

function select_candidates(dump, rules4, rules6, states) {
    let interfaces = [];
    for (let iface in (dump.interface || [])) {
        let name = iface.interface;
        if (!iface.up || !match(name || '', /^[A-Za-z0-9_.-]+$/) ||
            !match(iface.l3_device || '', /^[A-Za-z0-9_.:@-]+$/)) continue;
        if (states[name] != null && states[name] != 'online') continue;
        let default_route = false;
        for (let route in (iface.route || []))
            if (int(route.mask) == 0 && (route.target == '0.0.0.0' || route.target == '::'))
                default_route = true;
        if (!default_route) continue;
        push(interfaces, iface);
    }
    sort(interfaces, (a, b) => int(a.metric || 0) - int(b.metric || 0) ||
        (a.interface < b.interface ? -1 : (a.interface == b.interface ? 0 : 1)));
    let result = [], seen = {};
    for (let iface in interfaces) {
        for (let server in (iface['dns-server'] || [])) {
            if (!ip.valid_ip(server)) continue;
            let mark = interface_mark(index(server, ':') >= 0 ? rules6 : rules4, iface.l3_device);
            // A tracked interface without its routing table is not ready.
            if (states[iface.interface] != null && mark == 0) continue;
            let key = iface.l3_device + '/' + server;
            if (seen[key]) continue;
            seen[key] = true;
            push(result, { server, interface: iface.interface, device: iface.l3_device, mark });
        }
    }
    return result;
}

function discover() {
    let dump = read_json('ubus call network.interface dump');
    if (type(dump) != 'object') return [];
    let states = {};
    for (let iface in (dump.interface || [])) {
        if (!match(iface.interface || '', /^[A-Za-z0-9_.-]+$/)) continue;
        let state = fs.readfile('/var/run/mwan3/iface_state/' + iface.interface);
        if (state != null) states[iface.interface] = trim(state);
    }
    return select_candidates(dump, read_rules('-4'), read_rules('-6'), states);
}

if (ARGV[0] == 'show') {
    printf('%J\n', { candidates: discover() });
    exit(0);
}
return { discover, select_candidates, interface_mark };
