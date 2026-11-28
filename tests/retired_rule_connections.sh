#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/forkop/files/usr/lib"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/fixture.json" <<'EOF'
{"previous":{"route":{"rule_set":[{"tag":"removed"},{"tag":"keep"}]}},"current":{"route":{"rule_set":[{"tag":"keep"}]}},"connections":[{"id":"1","rulePayload":"rule_set=removed"},{"id":"2","rulePayload":"rule_set=keep"},{"id":"3","rulePayload":"rule_set=removed-extra"},{"id":"4","rulePayload":"rule_set=keep rule_set=removed"},{"id":"bad/path","rulePayload":"rule_set=removed"}]}
EOF
result=$(ucode -L "$LIB" "$LIB/service/hot_reload.uc" connections-fixture "$WORK/fixture.json")
[ "$result" = '[ "1", "4" ]' ]
mkdir "$WORK/bin" "$WORK/auth"
export PATH="$WORK/bin:$PATH" TMPDIR="$WORK/auth" TEST_CALLS="$WORK/calls"
cat > "$WORK/bin/curl" <<'EOF'
#!/bin/sh
for url; do :; done
case "$url" in
    http://127.0.0.1:9090/*) path=${url#http://127.0.0.1:9090} ;;
    *) exit 1 ;;
esac
echo "$path" >> "$TEST_CALLS"
case "$path" in
    /rust-x/applied-config)
        printf '{"schema":1,"ready":true,"hot_reload":true,"generation":1,"config_sha256":"%064d","connection_revalidation":%s}\n' 0 "$CAPABILITY" ;;
    /rust-x/revalidate-connections) echo "$REVALIDATED" ;;
    /connections) echo '{"connections":[{"id":"a","rulePayload":"rule_set=removed"},{"id":"b","rulePayload":"rule_set=keep"}]}' ;;
    /connections/a|/connections/b) ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/curl"
echo '{"route":{"rule_set":[{"tag":"removed"},{"tag":"keep"}]}}' >"$WORK/previous"
echo '{"experimental":{"clash_api":{"external_controller":"0.0.0.0:9090","secret":"test"}},"route":{"rule_set":[{"tag":"keep"}]}}' >"$WORK/current"
close_retired() { ucode -L "$LIB" "$LIB/service/hot_reload.uc" close-retired "$WORK/previous" "$WORK/current"; }
export CAPABILITY=true REVALIDATED='{"closed":3}'
[ "$(close_retired)" = 3 ]
[ "$(tail -1 "$TEST_CALLS")" = /rust-x/revalidate-connections ]
for REVALIDATED in '{"skipped":1}' '{"superseded":true}'; do
    if close_retired; then exit 1; fi
done
export CAPABILITY=false
[ "$(close_retired)" = 1 ]
[ "$(tail -1 "$TEST_CALLS")" = /connections/a ]
before=$(wc -l <"$TEST_CALLS")
echo '{broken' >"$WORK/previous"
if close_retired; then exit 1; fi
[ "$(wc -l <"$TEST_CALLS")" = "$before" ]
[ "$(ucode -L "$LIB" "$LIB/service/hot_reload.uc" close-tag "$WORK/current" keep)" = 1 ]
[ "$(tail -1 "$TEST_CALLS")" = /connections/b ]
[ -z "$(ls -A "$TMPDIR")" ]
echo 'Removed rule connection selection: exact tokens, unrelated rules and safe IDs passed'
