#!/bin/sh
set -eu
ROOT="${FORKOP_TEST_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
ucode -L "$ROOT/forkop/files/usr/lib" -e '
let xrust = require("xrust.binary");
let banner = "xrust version 0.0.45\n";
assert(xrust.has_feature(banner + "Features: outbound.trojan\n", "outbound.trojan"));
for (let suffix in ["", "Features: outbound.trojan.udp\n", "Tags: outbound.trojan\n"])
    assert(!xrust.has_feature(banner + suffix, "outbound.trojan"));
print("Xrust Trojan capability checks passed\n");
'
