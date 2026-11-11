// This bit is separate from the router-originated TPROXY and bypass marks.
// Direct traffic must never inherit it merely because it passed through a core.
const PROXY_TRANSPORT_MARK = 0x02000000;
const CORE_BYPASS_MARK = 0x08000000;

function protect(outbound) {
    if (index([ "selector", "urltest", "chain", "block", "dns", "tailscale" ], outbound.type) >= 0)
        return;
    // Old Xrust already accepts routing_mark on these objects. It may ignore
    // it until the core is updated; do not break a Forkop-first upgrade.
    outbound.routing_mark = int(outbound.routing_mark || 0) | CORE_BYPASS_MARK | PROXY_TRANSPORT_MARK;
}

function protect_range(config, outbound_start, endpoint_start) {
    for (let i = outbound_start; i < length(config.outbounds || []); i++)
        protect(config.outbounds[i]);
    for (let i = endpoint_start; i < length(config.endpoints || []); i++)
        protect(config.endpoints[i]);
}

return { PROXY_TRANSPORT_MARK, protect_range };
