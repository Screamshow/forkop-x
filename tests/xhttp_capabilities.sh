#!/bin/sh
set -eu
ROOT="${FORKOP_TEST_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
SOURCE="$ROOT/forkop/files/usr/lib/singbox/runtime.uc"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
{
cat <<'UC'
function as_string(v) { return v == null ? "" : "" + v; }
function command_exists(v) { return false; }
function sing_box_marker_is(v) { return false; }
function sing_box_version() { return ""; }
function sing_box_version_output() { return ""; }
UC
sed -n '/^function sing_box_version_is_extended(/,/^}/p; /^function sing_box_is_extended(/,/^}/p; /^function output_has_build_tag(/,/^}/p; /^function output_has_feature(/,/^}/p; /^function sing_box_supports_xhttp(/,/^}/p' "$SOURCE"
cat <<'UC'
for (let version in ["1.14.2", "1.14.2-x-1.0.1", "1.14.2-x-1.0.2", "1.14.2-tiny"])
    assert(!sing_box_supports_xhttp(version, "Tags: with_utls,with_clash_api\n"), "old core capability");
assert(sing_box_supports_xhttp("1.14.1-extended-2.7.2", ""), "legacy Extended");
assert(sing_box_supports_xhttp("1.14.2-x-1.0.3", "Features: transport.xhttp,transport.xhttp.http2\n"), "X capability");
assert(!sing_box_supports_xhttp("1.14.2-x-1.0.3", "Features: transport.xhttp.http2\n"), "whole feature token");
assert(!sing_box_supports_xhttp("1.14.2-x-1.0.3", "Tags: transport.xhttp\n"), "Features line required");
print("XHTTP capability compatibility passed\n");
UC
} > "$work/check.uc"
ucode "$work/check.uc"
