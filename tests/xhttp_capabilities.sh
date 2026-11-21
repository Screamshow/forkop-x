#!/bin/sh
set -eu
ROOT="${FORKOP_TEST_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
ucode -L "$ROOT/forkop/files/usr/lib" -e '
let xrust = require("xrust.binary");
let banner = "xrust version 0.0.45\n";
let output = banner + "Features: transport.xhttp,transport.xhttp.http2\n";
assert(xrust.version_from_output(output) == "0.0.45", "native Xrust version");
assert(xrust.has_feature(output, "transport.xhttp"), "advertised XHTTP capability");
assert(!xrust.has_feature(banner, "transport.xhttp"), "Features line required");
assert(!xrust.has_feature(banner + "Features: transport.xhttp.http2\n", "transport.xhttp"), "whole feature token");
assert(!xrust.has_feature(banner + "Tags: transport.xhttp\n", "transport.xhttp"), "build tag does not advertise a feature");
print("Xrust XHTTP capability checks passed\n");
'
