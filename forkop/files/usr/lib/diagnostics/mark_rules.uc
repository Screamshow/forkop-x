// Recognize only Forkop native Tailscale's generated mark statements.
function is_native_tailscale_mark(family, table_name, line) {
    if (family != "inet" || table_name != "forkop_native_tailscale")
        return false;
    line = replace(trim(line), /\s+/g, " ");
    // nft folds (x & mask) | value by retaining the bits set by value in mask.
    return line == "iifname \"forkop-tslan\" ct mark set ct mark & 0xff88ffff | 0x00880000" ||
        line == "ct direction reply ct mark & 0x00ff0000 == 0x00880000 meta mark set meta mark & 0xfb88ffff | 0x00880000";
}
return { is_native_tailscale_mark };
