#!/bin/sh
set -eu
ROOT="${FORKOP_TEST_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
SOURCE="$ROOT/forkop/files/usr/lib/singbox/runtime.uc"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
{
cat <<'UC'
function as_string(v) { return v == null ? "" : "" + v; }
let version_output_calls = 0;
function sing_box_version_output() { version_output_calls++; return "Features: outbound.trojan\n"; }
UC
sed -n '/^function output_has_build_tag(/,/^}/p; /^function output_has_feature(/,/^}/p; /^function sing_box_supports_trojan(/,/^}/p' "$SOURCE"
cat <<'UC'
let new_core = "sing-box version 1.14.2-rust-x.0.0.28\nXrust: 0.0.28; configuration compatibility baseline: 1.14.2\n" +
    "Features: transport.xhttp,transport.xhttp.http1,transport.xhttp.http2,outbound.trojan\nTags: with_utls,with_clash_api,with_tailscale\n";
let old_core = "sing-box version 1.14.2-rust-x.0.0.27\nXrust: 0.0.27; configuration compatibility baseline: 1.14.2\n" +
    "Features: transport.xhttp,transport.xhttp.http1,transport.xhttp.http2\nTags: with_utls,with_clash_api,with_tailscale\n";
assert(sing_box_supports_trojan("1.14.2-rust-x.0.0.28", new_core), "Xrust declaring outbound.trojan");
assert(!sing_box_supports_trojan("1.14.2-rust-x.0.0.27", old_core), "released Xrust without the feature");
assert(!sing_box_supports_trojan("1.14.2-rust-x.0.0.26", ""), "Xrust without Features line");
assert(!sing_box_supports_trojan("1.14.2-rust-x.0.0.28", "Features: outbound.trojan.udp\n"), "whole feature token");
assert(!sing_box_supports_trojan("1.14.2-rust-x.0.0.28", "Tags: outbound.trojan\n"), "Features line required");
for (let version in ["1.14.2", "1.14.2-x-1.0.4", "1.14.1-extended-2.7.2", "1.14.2-tiny", ""])
    assert(sing_box_supports_trojan(version, ""), "other cores keep Trojan: " + version);
assert(version_output_calls == 0, "explicit version output must not run sing-box");
assert(sing_box_supports_trojan("1.14.2-rust-x.0.0.28", null) && version_output_calls == 1, "reads version output on demand");
print("Trojan capability compatibility passed\n");
UC
} > "$work/check.uc"
ucode "$work/check.uc"
