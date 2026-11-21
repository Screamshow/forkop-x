#!/bin/sh
set -eu
ROOT="${FORKOP_TEST_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
ucode -L "$ROOT/forkop/files/usr/lib" -e '
let xrust = require("xrust.binary");
let banner = "xrust version 0.0.45\n";
assert(xrust.has_feature(banner + "Features: outbound.vless.encryption\n", "outbound.vless.encryption"));
for (let suffix in ["", "Features: outbound.vless.encryption.extra\n", "Tags: outbound.vless.encryption\n"])
    assert(!xrust.has_feature(banner + suffix, "outbound.vless.encryption"));
print("Xrust VLESS encryption capability checks passed\n");
'
