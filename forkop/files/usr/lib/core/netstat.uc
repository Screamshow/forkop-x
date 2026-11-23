function netstat_fields(line) {
    line = line == null ? "" : "" + line;
    line = trim(line);
    return line == "" ? [] : split(line, /[ \t\r\n]+/);
}

function netstat_addr_port(addr) {
    addr = addr == null ? "" : "" + addr;
    let colon = rindex(addr, ":");
    return colon >= 0 ? substr(addr, colon + 1) : addr;
}

function netstat_addr_host(addr) {
    addr = addr == null ? "" : "" + addr;
    if (substr(addr, 0, 1) == "[") {
        let end = index(addr, "]");
        return end > 0 ? substr(addr, 1, end - 1) : addr;
    }
    let colon = rindex(addr, ":");
    return colon >= 0 ? substr(addr, 0, colon) : addr;
}

function netstat_addr_matches(addr, listen, port, exact, protocol) {
    listen = listen == null ? "" : "" + listen;
    port = port == null ? "" : "" + port;
    if (netstat_addr_port(addr) != port)
        return false;

    let host = netstat_addr_host(addr);
    if (host == "0:0:0:0:0:0:0:1")
        host = "::1";
    if (exact)
        return host == listen || (host == "*" && listen == (substr(protocol, -1) == "6" ? "::" : "0.0.0.0"));
    return host == listen || host == "*" ||
        (host == "0.0.0.0" && index(listen, ":") < 0) ||
        (host == "::" && index(listen, ":") >= 0);
}

function listen_port_in_use(netstat, listen, port) {
    netstat = netstat == null ? "" : "" + netstat;
    for (let line in split(netstat, "\n")) {
        let fields = netstat_fields(line);
        if (length(fields) < 4 ||
            (index(fields[0], "tcp") != 0 && index(fields[0], "udp") != 0))
            continue;
        if (netstat_addr_matches(fields[3], listen, port))
            return true;
    }
    return false;
}

function socket_port_owned(netstat, protocol, listen, port, pid, exact) {
    netstat = netstat == null ? "" : "" + netstat;
    pid = int(pid || 0);
    if (pid <= 0)
        return false;

    let expected_owner = "" + pid;
    for (let line in split(netstat, "\n")) {
        let fields = netstat_fields(line);
        if (length(fields) < 6 || (fields[0] != protocol && fields[0] != protocol + "6"))
            continue;
        let owner_index = protocol == "tcp" ? 6 : 5;
        if (protocol == "tcp" && (length(fields) < 7 || fields[5] != "LISTEN"))
            continue;
        // BusyBox omits the state column for unconnected UDP sockets.
        if (protocol == "udp" && index(fields[5], "/") < 0 && length(fields) > 6)
            owner_index = 6;
        if (!netstat_addr_matches(fields[3], listen, port, exact, fields[0]))
            continue;

        let slash = index(fields[owner_index], "/");
        if (slash > 0 && substr(fields[owner_index], 0, slash) == expected_owner)
            return true;
    }
    return false;
}

function tcp_listen_port_owned(netstat, listen, port, pid) {
    return socket_port_owned(netstat, "tcp", listen, port, pid);
}

function xrust_standard_ports_owned(netstat, pid, dns_address, tproxy_port, tproxy4_address, tproxy6_address) {
    for (let protocol in [ "tcp", "udp" ]) {
        if (!socket_port_owned(netstat, protocol, dns_address, 53, pid, true) ||
            !socket_port_owned(netstat, protocol, tproxy4_address, tproxy_port, pid, true) ||
            (tproxy6_address != "" && !socket_port_owned(netstat, protocol, tproxy6_address, tproxy_port, pid, true)))
            return false;
    }
    return true;
}

return { xrust_standard_ports_owned, listen_port_in_use, tcp_listen_port_owned, socket_port_owned };
