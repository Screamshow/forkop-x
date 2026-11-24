#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/forkop/files/usr/lib"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
normalize() { ucode -L "$LIB" "$LIB/subscription/parser.uc" normalize-content-validated "$1" "$2"; }

base='vless://00000000-0000-4000-8000-000000000001@node.example:443?security=reality&sni=site.example'
printf '%s\n' "$base&pbk=bad#Broken" "$base&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA#Healthy" > "$WORK/mixed"
normalize "$WORK/mixed" "$WORK/out"
ucode -e 'let v=json(require("fs").readfile(ARGV[0])); assert(v.skipped==1 && length(v.outbounds)==1 && v.outbounds[0].tag=="Healthy");' "$WORK/out"
printf '%s\n' "$base&pbk=bad#Broken" > "$WORK/invalid"
if normalize "$WORK/invalid" "$WORK/out"; then exit 1; fi
[ ! -e "$WORK/out" ]
printf '%s\n' '{"outbounds":[{"tag":"broken","type":"vless","detour":"relay","tls":{"reality":{"public_key":"bad"}}},{"tag":"relay","type":"vless","server":"relay.example","uuid":"00000000-0000-4000-8000-000000000001"}]}' > "$WORK/invalid-chain"
if normalize "$WORK/invalid-chain" "$WORK/out"; then exit 1; fi
[ ! -e "$WORK/out" ]

cat > "$WORK/graph" <<'JSON'
{"outbounds":[
 {"type":"selector","tag":"mixed","outbounds":["outer","healthy"],"default":"outer"},
 {"type":"urltest","tag":"empty","outbounds":["broken"]},
 {"type":"vless","tag":"outer","detour":"inner"},
 {"type":"vless","tag":"inner","detour":"empty"},
 {"type":"vless","tag":"broken","tls":{"reality":{"enabled":true,"public_key":"bad"}}},
 {"type":"vless","tag":"healthy","server":"node.example","server_port":443,"uuid":"00000000-0000-4000-8000-000000000001"},
 {"type":"urltest","tag":"provider","outbounds":["broken","healthy"]}
]}
JSON
normalize "$WORK/graph" "$WORK/nodes.json"
ucode -e '
let v=json(require("fs").readfile(ARGV[0]));
assert(v.skipped==4 && length(v.outbounds)==3, "invalid detour and empty-group dependents must be removed");
assert(v.outbounds[0].tag=="mixed" && v.outbounds[0].default==null && v.outbounds[1].tag=="healthy");
for(let group in [v.outbounds[0],v.outbounds[2]])
    assert(length(group.outbounds)==1 && group.outbounds[0]=="healthy", "stale group member");
' "$WORK/nodes.json"

mkdir "$WORK/subscriptions"
cp "$WORK/nodes.json" "$WORK/subscriptions/demo-subscription-1.json"
printf '%s\n' 'https://fixture.example/sub' > "$WORK/subscriptions/demo-subscription-1.url"
printf 'INCY/2.3.6' > "$WORK/subscriptions/demo-subscription-1.user_agent"
printf '%s\n' '{"settings":{"dns_server":"1.1.1.1"},"section":[{".type":"section",".name":"demo","enabled":"1","action":"connection","subscription_urls":["https://fixture.example/sub"]}]}' > "$WORK/fixture.json"
FORKOP_VERSION=2.3.6 TMP_SUBSCRIPTION_FOLDER="$WORK/subscriptions" \
    ucode -L "$LIB" "$LIB/xrust/generator.uc" generate-config-fixture "$WORK/fixture.json" "$WORK/config.json" 127.0.0.1
ucode -e 'let c=json(require("fs").readfile(ARGV[0])); assert(length(filter(c.outbounds,o=>o.server=="node.example"))==1);' "$WORK/config.json"
if [ -n "${FORKOP_XRUST_BIN:-}" ]; then "$FORKOP_XRUST_BIN" check -c "$WORK/config.json"; fi
printf 'REALITY subscription filtering and dependent group generation passed\n'
