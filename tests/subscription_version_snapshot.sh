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
    sed -n '/^let forkop_version =/,/^const SUBSCRIPTION_FALLBACK_USER_AGENT =/p' "$SOURCE"
    sed -n '/^function user_agent_supported(/,/^}/p' "$SOURCE"
    cat <<'UC'
if (SUBSCRIPTION_USER_AGENT != ARGV[1]) die("Wrong INCY version\n");
if (SUBSCRIPTION_FALLBACK_USER_AGENT != "sing-box/1.14.2" ||
    !user_agent_supported(SUBSCRIPTION_FALLBACK_USER_AGENT, SUBSCRIPTION_USER_AGENT))
    die("Fallback must use a versioned sing-box profile accepted by the cache\n");
if (!user_agent_supported("sing-box/1.14.2-rust-x.0.0.44", SUBSCRIPTION_USER_AGENT))
    die("Existing 2.x subscription cache would be lost\n");
if (user_agent_supported("custom/1", SUBSCRIPTION_USER_AGENT))
    die("Unrelated cache profile accepted\n");
UC
} > "$WORK/check.uc"
ucode "$WORK/check.uc" 3.0.0 INCY/3.0.0
ucode "$WORK/check.uc" 3.0.0-canary.11 INCY/3.0.0
echo "Versioned INCY and sing-box profiles and 2.x cache compatibility passed"
