#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB="$ROOT/forkop/files/usr/lib"
ucode -L "$LIB" "$ROOT/tests/native_tailscale_marks.uc"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/rules" <<'EOF'
table inet forkop {
 meta mark set 0x1
}
table inet forkop_native_tailscale {
 iifname "forkop-tslan" ct mark set ct mark & 0xff88ffff | 0x00880000
 ct direction reply ct mark & 0x00ff0000 == 0x00880000 meta mark set meta mark & 0xfb88ffff | 0x00880000
 meta mark set 0x1234
}
table inet foreign {
 ct direction reply ct mark & 0x00ff0000 == 0x00880000 meta mark set meta mark & 0xfb88ffff | 0x00880000
}
table inet forkop_extra {
 meta mark set 0x5678
}
EOF
cat > "$WORK/expected" <<'EOF'
 meta mark set 0x1234
 ct direction reply ct mark & 0x00ff0000 == 0x00880000 meta mark set meta mark & 0xfb88ffff | 0x00880000
 meta mark set 0x5678
EOF
ucode -L "$LIB" "$LIB/diagnostics/status.uc" nft-ruleset-other-mark-lines forkop < "$WORK/rules" > "$WORK/actual"
diff -u "$WORK/expected" "$WORK/actual"
echo 'PASS: diagnostic command retains foreign rules and matches table names exactly'
