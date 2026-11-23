#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB=${FORKOP_LIB:-$ROOT/forkop/files/usr/lib}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/links.txt" <<'URI'
socks5://same:same@equal.example:1080#equal
socks5://lab+one:qa%2Bone@plus.example:1080#plus
socks5://lab%3A%40host:p%2Fq%3Fr%23s%252B@[2001:db8::1]:1080#reserved
URI

ucode -L "$LIB" "$LIB/subscription/parser.uc" normalize-uri-list \
    "$WORK/links.txt" "$WORK/subscription.json"
ucode -e '
    let fs = require("fs"), outbounds = json(fs.readfile(ARGV[0])).outbounds;
    assert(length(outbounds) == 3, "all SOCKS profiles must parse");
    assert(outbounds[0].username == "same" && outbounds[0].password == "same",
        "a password identical to the username must survive");
    assert(outbounds[1].username == "lab+one" && outbounds[1].password == "qa+one",
        "literal and escaped plus must survive");
    let reserved = outbounds[2];
    assert(reserved.server == "2001:db8::1" && reserved.server_port == 1080,
        "split the bracketed authority before decoding");
    assert(reserved.username == "lab:@host" && reserved.password == "p/q?r#s%2B",
        "split credentials at the literal colon and decode each field once");
    let fixture = { settings: { ".name": "settings", ".type": "settings", dns_server: "1.1.1.1" },
        section: [{ ".name": "socks", ".type": "section", enabled: "1", action: "connection",
            selector_proxy_links: [reserved.share_link] }] };
    fs.writefile(ARGV[1], sprintf("%J", fixture));
' "$WORK/subscription.json" "$WORK/fixture.json"
if ucode -L "$LIB" "$LIB/xrust/generator.uc" generate-config-fixture \
    "$WORK/fixture.json" "$WORK/runtime.json" 127.0.0.1 0 1 '' 0.0.46 >"$WORK/result" 2>&1; then
    echo 'The pinned Xrust client must reject the unsupported SOCKS profile' >&2
    exit 1
fi
grep -qi 'uses protocol socks, which is not included in Xrust' "$WORK/result" || {
    cat "$WORK/result" >&2
    exit 1
}

echo 'PASS: SOCKS URI credentials and pinned client capability'
