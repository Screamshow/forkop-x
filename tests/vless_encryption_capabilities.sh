#!/bin/sh
set -eu
ROOT="${FORKOP_TEST_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
SOURCE="$ROOT/forkop/files/usr/lib/singbox/runtime.uc"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
{
echo 'function as_string(v) { return v == null ? "" : "" + v; }'
sed -n '/^function output_has_build_tag(/,/^}/p; /^function output_has_feature(/,/^}/p; /^function sing_box_supports_vless_encryption(/,/^}/p' "$SOURCE"
cat <<'UC'
let version = "1.14.2-rust-x.0.0.33";
assert(sing_box_supports_vless_encryption(version, "Features: outbound.vless.encryption\n"));
for (let output in ["", "Features: transport.xhttp\n", "Features: outbound.vless.encryption.extra\n", "Tags: outbound.vless.encryption\n"])
    assert(!sing_box_supports_vless_encryption(version, output));
for (let other in ["1.14.2", "1.14.2-x-1.0.4", "1.14.1-extended-2.7.2"])
    assert(sing_box_supports_vless_encryption(other, ""));
print("VLESS encryption capability compatibility passed\n");
UC
} > "$work/check.uc"
ucode "$work/check.uc"
