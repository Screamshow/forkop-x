#!/bin/sh
# Run with ucode available (including an existing OpenWrt test VM).
set -eu
ROOT=${1:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/check.uc" <<'EOF'
function as_string(value) { return value == null ? "" : "" + value; }
let executable = "/usr/lib/rust-x/sing-box";
let cmdline = "";
let fs = { readfile: function(path) { return cmdline; }, readlink: function(path) { return executable; } };
EOF
sed -n '/^function sing_box_exe_path(/,/^}/p; /^function installer_sing_box_process(/,/^}/p' "$ROOT/install.sh" >> "$WORK/check.uc"
cat >> "$WORK/check.uc" <<'EOF'
function check(args, expected) {
    cmdline = join(chr(0), args) + chr(0);
    if (installer_sing_box_process("/proc/123/exe") != expected)
        die("Unexpected process selection: " + join(" ", args) + "\n");
}
check([ executable, "run", "-c", "/etc/sing-box/config.json" ], true);
check([ executable, "tailscale-luci" ], false);
// A similar argument later in argv must not hide a proxy/unknown process.
check([ executable, "run", "tailscale-luci" ], true);
check([ executable, "unknown" ], true);
cmdline = "";
if (!installer_sing_box_process("/proc/123/exe")) die("Unreadable cmdline must remain counted\n");
executable += " (deleted)";
check([ "/usr/lib/rust-x/sing-box", "run" ], true);
check([ "/usr/lib/rust-x/sing-box", "tailscale-luci" ], false);
executable = "/usr/sbin/tailscaled";
check([ executable ], false);
print("PASS: installer proxy/Tailscale process selection\n");
EOF
ucode "$WORK/check.uc"
