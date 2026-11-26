#!/bin/sh
# OpenWrt integration with isolated UCI, cache, locks and a loopback provider.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
server=
trap 'if [ -n "$server" ]; then kill "$server" 2>/dev/null || :; wait "$server" 2>/dev/null || :; fi; rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

export FORKOP_LIB="$ROOT/forkop/files/usr/lib" FORKOP_BIN="$ROOT/forkop/files/usr/bin/forkop"
export FORKOP_UCI_CONFIG_DIR="$WORK/uci" FORKOP_UCI_SAVE_DIR="$WORK/uci-save"
export FORKOP_RUNTIME_STATE_DIR="$WORK/state" FORKOP_RELOAD_LOCK_DIR="$WORK/reload.lock"
export FORKOP_SUBSCRIPTION_UPDATE_JOB_DIR="$WORK/jobs" FORKOP_STATE_UC="$WORK/state.uc"
export FORKOP_SERVICE_INIT="$WORK/no-service" FORKOP_UI_STATE_DIR="$WORK/ui-state"
export TMP_XRUST_FOLDER="$WORK/xrust" TMP_SING_BOX_FOLDER="$WORK/xrust"
export TMP_SUBSCRIPTION_FOLDER="$WORK/xrust/subscriptions"
export FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK/persistent"
export FORKOP_LIST_UPDATE_PID_FILE="$WORK/list.pid"
mkdir -p "$FORKOP_UCI_CONFIG_DIR" "$FORKOP_UCI_SAVE_DIR" "$WORK/http" "$WORK/batch"
FORKOP_TEST_WORK="$WORK" ucode -L "$FORKOP_LIB" -e '
    let fs = require("fs"), common = require("core.common"), source = require("subscription.source_cache");
    let dir = getenv("FORKOP_TEST_WORK") + "/permissions", path = dir + "/source.json";
    let payload = { outbounds: [{ type: "direct" }] }, profile = { url: "fixture" };
    assert(common.secure_private_dir(dir) && source.publish(path, payload, profile));
    let before = fs.stat(path).ctime;
    system(["sleep", "1"]);
    assert(common.secure_private_dir(dir) && source.publish(path, payload, profile));
    assert(fs.stat(path).ctime == before, "permission checks changed an unchanged source");
    assert(fs.chmod(path, 0644) && source.publish(path, payload, profile));
    assert(fs.stat(path).mode == 0600, "publication did not repair permissive mode");
'
cat >"$FORKOP_STATE_UC" <<'UC'
if (ARGV[0] == "sing-box-service-running")
    exit(1);
exit(system([ "ucode", "-L", getenv("FORKOP_LIB"),
    getenv("FORKOP_LIB") + "/service/state.uc", ...ARGV ]) == 0 ? 0 : 1);
UC

port=${FORKOP_TEST_HTTPS_PORT:-18086}
base="https://localhost:$port"
px5g selfsigned -der -days 2 -newkey rsa:2048 -keyout "$WORK/key.der" -out "$WORK/cert.der" \
    -subj /CN=localhost -addext extendedKeyUsage=serverAuth -addext subjectAltName=DNS:localhost >"$WORK/cert.log" 2>&1
export CURL_CA_BUNDLE="$WORK/ca.pem"
{
    echo '-----BEGIN CERTIFICATE-----'
    base64 "$WORK/cert.der"
    echo '-----END CERTIFICATE-----'
} >"$CURL_CA_BUNDLE"
cat >"$FORKOP_UCI_CONFIG_DIR/forkop" <<EOF
config settings 'settings'
config section 'rule'
    option action 'connection'
    option enabled '1'
    option subscription_update_enabled '1'
    option subscription_update_interval '1h'
config subscription_url 'first'
    option section 'rule'
    option url '$base/first'
config subscription_url 'second'
    option section 'rule'
    option url '$base/second'
EOF
feed() { printf 'vless://01234567-89ab-cdef-0123-456789abcdef@%s:443?security=tls#Fixture\n' "$1" >"$WORK/http/$2"; }
feed node-a.invalid first
feed node-b.invalid second
if curl -fsS --max-time 1 "$base/first" >/dev/null 2>&1; then fail "fixture port in use"; fi
uhttpd -f -s "127.0.0.1:$port" -C "$WORK/cert.der" -K "$WORK/key.der" -h "$WORK/http" >"$WORK/http.log" 2>&1 &
server=$!
for attempt in 1 2 3 4 5; do
    curl -fsS --max-time 1 "$base/first" >/dev/null 2>&1 && break
    sleep 1
done
kill -0 "$server" && curl -fsS --max-time 1 "$base/first" >/dev/null || fail "loopback provider unavailable"

forkop() { ucode "$FORKOP_BIN" "$@"; }
cache() { ucode -L "$FORKOP_LIB" "$FORKOP_LIB/subscription/cache.uc" "$@"; }
hash() { FORKOP_TEST_URL="$1" ucode -L "$FORKOP_LIB" -e 'print(require("xrust.rulesets").hash12(getenv("FORKOP_TEST_URL")));'; }
stamp1="$FORKOP_RUNTIME_STATE_DIR/subscription-update/rule.$(hash "$base/first").timestamp"
stamp2="$FORKOP_RUNTIME_STATE_DIR/subscription-update/rule.$(hash "$base/second").timestamp"
cache1="$TMP_SUBSCRIPTION_FOLDER/rule-subscription-1.json"
cache2="$TMP_SUBSCRIPTION_FOLDER/rule-subscription-2.json"
expect_batch() {
    expected=$(printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4")
    shift 4
    actual=$(cache "$@")
    [ "$actual" = "$expected" ] || fail "expected [$expected], got [$actual]"
}

forkop subscription_update
[ -s "$stamp1" ] && [ -s "$stamp2" ] && [ -s "$cache1" ] && [ -s "$cache2" ] ||
    fail "initial batch did not commit both sources and timestamps"

before=$(sha256sum "$cache1")
cp "$stamp1" "$WORK/initial-stamp"
feed node-c.invalid first
cache prefetch-direct 1 rule 1 "$WORK/batch"
sleep 1
ln "$cache1" "$WORK/snapshot"
chmod 0600 "$cache1"
rm "$WORK/snapshot"
expect_batch 1 0 0 0 update-request 1 rule 1 1 "$WORK/batch"
cmp -s "$stamp1" "$WORK/initial-stamp" || fail "prepared update published timestamp before commit"
cache finish-source-update rollback
[ "$(sha256sum "$cache1")" = "$before" ] && cmp -s "$stamp1" "$WORK/initial-stamp" ||
    fail "rollback did not restore cache and preserve timestamp"
expect_batch 1 0 0 0 update-request 1 rule 1 1 "$WORK/batch"
stamp_dir=$(dirname "$stamp1")
mv "$stamp_dir" "$WORK/stamps"
: >"$stamp_dir"
if cache finish-source-update commit; then fail "failed timestamp publication reported success"; fi
grep -q node-c.invalid "$cache1" || fail "timestamp failure discarded accepted data"
rm "$stamp_dir"
cache finish-source-update rollback
mv "$WORK/stamps/$(basename "$stamp2")" "$stamp2"
grep -q node-c.invalid "$cache1" && ! cmp -s "$stamp1" "$WORK/initial-stamp" ||
    fail "recovery did not finish the accepted cache and timestamp commit"
expect_batch 0 0 0 1 update-request 1 rule 1 1 "$WORK/batch"

cp "$stamp2" "$WORK/second-stamp"
second_before=$(sha256sum "$cache2")
mv "$WORK/http/second" "$WORK/second-body"
feed node-d.invalid first
started=$(forkop subscription_update_async)
job=$(printf '%s' "$started" | jsonfilter -e '@.job_id')
[ -n "$job" ] || fail "async batch did not start"
for attempt in $(seq 1 30); do
    result=$(forkop subscription_update_status "$job")
    [ "$(printf '%s' "$result" | jsonfilter -e '@.running')" = false ] && break
    sleep 1
done
[ "$(printf '%s' "$result" | jsonfilter -e '@.success')" = false ] &&
    [ "$(printf '%s' "$result" | jsonfilter -e '@.exit_code')" = 2 ] &&
    printf '%s' "$result" | grep -q 'partially completed' || fail "partial job reported full success"
grep -q node-d.invalid "$cache1" && [ "$(sha256sum "$cache2")" = "$second_before" ] &&
    cmp -s "$stamp2" "$WORK/second-stamp" || fail "partial update lost accepted data or advanced failed source"
if forkop subscription_update rule 2; then fail "failed download reported success"; fi
cmp -s "$stamp2" "$WORK/second-stamp" || fail "failed targeted update advanced timestamp"
cp "$stamp1" "$WORK/stamp-before-restart"
if ucode -L "$FORKOP_LIB" "$FORKOP_LIB/components/updates.uc" subscription-prepare-only; then
    fail "manual restart preparation accepted a failed download alongside an unchanged source"
fi
cmp -s "$stamp1" "$WORK/stamp-before-restart" || fail "manual restart preparation advanced the schedule"
mv "$WORK/second-body" "$WORK/http/second"

rm -f "$stamp1"
date +%s >"$stamp2"
mkdir "$WORK/due"
cache prefetch-direct 0 '' '' "$WORK/due"
[ -f "$WORK/due/rule-subscription-1.result" ] && [ ! -f "$WORK/due/rule-subscription-2.result" ] ||
    fail "prefetch did not select only the due source"
batch_at=$(cat "$WORK/due/.started-at")
printf '%s\n' "$((batch_at - 3539))" >"$stamp2"
sleep 2
expect_batch 0 0 1 0 update-request 0 '' '' 1 "$WORK/due"
cache finish-source-update commit
[ "$(cat "$stamp2")" = "$((batch_at - 3539))" ] || fail "apply selected a source outside the prefetch window"
rm -f "$stamp2"
forkop subscription_update_if_due
[ -s "$stamp2" ] || fail "scheduled update did not record the accepted source"

# A live owner remains a benign coalesced request. A broken PID path is an error.
ticks=$(ucode -L "$FORKOP_LIB" -e 'print(require("core.worker_identity").start_ticks(ARGV[0]));' "$$")
printf '%s\n%s\n' "$$" "$ticks" >"$FORKOP_LIST_UPDATE_PID_FILE"
forkop list_update || fail "an already active list worker was not coalesced"
rm "$FORKOP_LIST_UPDATE_PID_FILE"
mkdir "$FORKOP_LIST_UPDATE_PID_FILE"
if forkop list_update; then fail "list worker PID registration failure returned success"; fi

echo "PASS: subscription cache revisions, commit/rollback, partial async status, retry timestamps, scheduled boundary and list worker registration"
