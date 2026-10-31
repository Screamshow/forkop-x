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
chmod 0755 "$WORK/bin/nft"
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
