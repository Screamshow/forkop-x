// Recognize only Forkop native Tailscale's generated mark statements.
function is_native_tailscale_mark(family, table_name, line) {
    if (family != "inet" || table_name != "forkop_native_tailscale")
        return false;
    line = replace(trim(line), /\s+/g, " ");
    // nft folds (x & mask) | value by retaining the bits set by value in mask.
    return line == "iifname \"forkop-tslan\" ct mark set ct mark & 0xff88ffff | 0x00880000" ||
        line == "ct direction reply ct mark & 0x00ff0000 == 0x00880000 meta mark set meta mark & 0xfb88ffff | 0x00880000";
}
function is_proxy_transport_mark(family, table_name, line) {
    if (family != "inet" || table_name != "forkop_proxy_transport") return false;
    line = replace(trim(line), /\s+/g, " ");
    return line == "meta mark & 0x02000000 != 0x00000000 ct mark set ct mark | 0x02000000" ||
        line == "ct direction original meta mark & 0x08000000 != 0x00000000 meta mark & 0x02000000 == 0x00000000 ct mark set ct mark & 0xfdffffff" ||
        match(line, /^meta mark & 0x02000000 != 0x00000000 counter packets [0-9]+ bytes [0-9]+ drop comment "Forkop proxy transport upgrade hold"$/) != null;
}

function is_torrserver_direct_mark(family, table_name, chain_name, line) {
    if (family != "inet" || table_name != "ForkopTorrServerDirect" || chain_name != "output")
        return false;
    line = replace(trim(line), /\s+/g, " ");
    let rule = match(line, /^socket cgroupv2 level ([0-9]+) "([A-Za-z0-9_.@:-]+(\/[A-Za-z0-9_.@:-]+)+)" meta mark set 0x0?8000000 counter packets [0-9]+ bytes [0-9]+ comment "Forkop TorrServer Direct"$/);
    return rule != null && int(rule[1]) == length(split(rule[2], "/"));
}

function is_forkop_mark(family, table_name, chain_name, line) {
    return is_native_tailscale_mark(family, table_name, line) ||
        is_proxy_transport_mark(family, table_name, line) ||
        is_torrserver_direct_mark(family, table_name, chain_name, line);
}

return { is_native_tailscale_mark, is_proxy_transport_mark, is_forkop_mark };
