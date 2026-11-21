#!/bin/sh
set -eu
ROOT="${FORKOP_TEST_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
SOURCE="${FORKOP_TEST_SUBSCRIPTION_CACHE:-$ROOT/forkop/files/usr/lib/subscription/cache.uc}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
{
    cat <<'UC'
function as_string(v) { return v == null ? "" : "" + v; }
let constants = { FORKOP_VERSION: ARGV[0] };
UC
    sed -n '/^let forkop_version =/,/^const SUBSCRIPTION_USER_AGENT =/p' "$SOURCE"
    sed -n '/^function user_agent_supported(/,/^}/p' "$SOURCE"
    cat <<'UC'
if (SUBSCRIPTION_USER_AGENT != ARGV[1]) die("Wrong INCY version\n");
if (!user_agent_supported("sing-box/1.14.2-rust-x.0.0.44", SUBSCRIPTION_USER_AGENT))
    die("Existing 2.x subscription cache would be lost\n");
if (user_agent_supported("custom/1", SUBSCRIPTION_USER_AGENT))
    die("Unrelated cache profile accepted\n");
UC
} > "$WORK/check.uc"
ucode "$WORK/check.uc" 3.0.0 INCY/3.0.0
ucode "$WORK/check.uc" 3.0.0-canary.11 INCY/3.0.0
grep -Fq '"User-Agent: " + SUBSCRIPTION_USER_AGENT' "$SOURCE"
if grep -Eq 'get_xrust_compat_version|user_agent_candidates|sing-box/unknown' "$SOURCE"; then
    echo "Legacy subscription request fallback is still present" >&2
    exit 1
fi
echo "Fixed INCY subscription profile and read-only 2.x cache compatibility passed"
