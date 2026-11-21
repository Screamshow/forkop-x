#!/usr/bin/env bash
set -euo pipefail

# TorrServer Direct marks TorrServer sockets to bypass Forkop. FakeIP answers
# (listed domains such as trackers) only work through sing-box, so the rule
# must leave FakeIP destinations unmarked while peers by real IP stay direct.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
SOURCE="$LIB/torrserver/direct.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK/bin"
cat >"$WORK/bin/nft" <<'SH'
#!/usr/bin/env bash
# Fake nft: keep the applied ruleset and list it the way nft prints it.
case "$1" in
  -f) cp "$2" "$NFT_WORK/applied.nft" ;;
  list)
    if [ "$2" = tables ]; then
      printf 'table inet ForkopTorrServerDirect\n'
      exit 0
    fi
    if { [ "$2" = chain ] || [ "$2" = table ]; } && [ "$4" != ForkopTorrServerDirect ]; then
      exit 1
    fi
    [ -f "$NFT_WORK/listing" ] && { cat "$NFT_WORK/listing"; exit 0; }
    [ -f "$NFT_WORK/applied.nft" ] || exit 1
    printf 'table inet ForkopTorrServerDirect {\n\tchain output {\n\t\ttype route hook output priority mangle - 1; policy accept;\n'
    sed -n 's/^add rule inet ForkopTorrServerDirect output /\t\t/p' "$NFT_WORK/applied.nft" |
      sed 's/ counter / counter packets 0 bytes 0 /'
    printf '\t}\n}\n'
    ;;
  delete) rm -f "$NFT_WORK/applied.nft" ;;
esac
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/curl"
chmod 0755 "$WORK/bin/nft" "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH" NFT_WORK="$WORK"

# Load the module functions without its command dispatch.
{
  sed '/^let mode = ARGV\[0\]/,$d' "$SOURCE"
  cat <<'UC'
let info = { available: 1, cgroup: "/services/torrserver/instance1" };
assert(apply_rule(info), "rule was not applied");
let lines = filter(split(fs.readfile(ARGV[0] + "/applied.nft"), "\n"), l => l != "");
let v4 = -1, v6 = -1, mark = -1;
for (let i = 0; i < length(lines); i++) {
    if (lines[i] == "add rule inet ForkopTorrServerDirect output ip daddr 198.18.0.0/15 return") v4 = i;
    if (lines[i] == "add rule inet ForkopTorrServerDirect output ip6 daddr 2001:2::/112 return") v6 = i;
    if (index(lines[i], "socket cgroupv2 level 2 \"services/torrserver\" meta mark set 0x08000000") >= 0) mark = i;
}
assert(v4 >= 0 && v6 >= 0, "FakeIP destinations are not excluded");
assert(mark >= 0, "TorrServer bypass mark rule is missing");
assert(v4 < mark && v6 < mark, "FakeIP exclusions must precede the bypass mark");
assert(active(info), "applied rule is not recognised as active");

let marks = require("diagnostics.mark_rules");
let table = "ForkopTorrServerDirect";
let rule = replace(substr(lines[mark], length("add rule inet " + table + " output ")),
    " counter ", " counter packets 27 bytes 9412 ");
assert(marks.is_forkop_mark("inet", table, "output", rule), "generated rule must be recognised");
assert(marks.is_forkop_mark("inet", table, "output", replace(rule, "0x08000000", "0x8000000")),
    "nft may omit the leading zero");
assert(!marks.is_forkop_mark("ip", table, "output", rule), "other family must remain visible");
assert(!marks.is_forkop_mark("inet", "foreign", "output", rule), "other table must remain visible");
assert(!marks.is_forkop_mark("inet", table, "prerouting", rule), "other chain must remain visible");
for (let foreign in [ replace(rule, "0x08000000", "0x01000000"), replace(rule, "level 2", "level 1"),
    replace(rule, "Forkop TorrServer Direct", "Foreign"), rule + " drop" ])
    assert(!marks.is_forkop_mark("inet", table, "output", foreign), "changed rule must remain visible");

// A rule from an older version (no FakeIP exclusions) must be replaced.
fs.writefile(ARGV[0] + "/listing",
    "table inet ForkopTorrServerDirect {\n\tchain output {\n" +
    "\t\ttype route hook output priority mangle - 1; policy accept;\n" +
    "\t\tsocket cgroupv2 level 2 \"services/torrserver\" meta mark set 0x08000000 counter packets 0 bytes 0 comment \"Forkop TorrServer Direct\"\n" +
    "\t}\n}\n");
assert(!active(info), "old rule without FakeIP exclusions counts as active");
print("TorrServer Direct FakeIP checks passed\n");
UC
} >"$WORK/test.uc"

ucode -L "$LIB" "$WORK/test.uc" "$WORK" || fail "TorrServer Direct FakeIP regression"

rm "$WORK/listing"
nft list ruleset >"$WORK/generated"
check_other_mark_flag() {
  FORKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/diagnostics/runtime.uc" check-nft-rules |
    ucode -e 'let result = json(require("fs").readfile("/dev/stdin")); exit(result.rules_other_mark_exist == int(ARGV[0]) ? 0 : 1);' "$1"
}
other_mark_lines() {
  ucode -L "$LIB" "$LIB/diagnostics/status.uc" nft-ruleset-other-mark-lines ForkopTable <"$1"
}

check_other_mark_flag 0 || fail "stock TorrServer Direct rule triggered a warning"
[ -z "$(other_mark_lines "$WORK/generated")" ] || fail "stock TorrServer Direct rule appeared in the report"

sed '/meta mark set/p; s/meta mark set 0x08000000/meta mark set 0x01000000/' "$WORK/generated" >"$WORK/listing"
check_other_mark_flag 1 || fail "another mark in the TorrServer Direct table was ignored"
[ "$(other_mark_lines "$WORK/listing" | sed 's/^[[:space:]]*//')" = \
  'socket cgroupv2 level 2 "services/torrserver" meta mark set 0x01000000 counter packets 0 bytes 0 comment "Forkop TorrServer Direct"' ] ||
  fail "report did not isolate the foreign mark"
printf 'TorrServer Direct diagnosis checks passed\n'
