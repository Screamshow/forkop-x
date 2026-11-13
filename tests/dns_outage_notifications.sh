#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
{
cat <<'UC'
let messages=[];
function log_message(message,level){push(messages,{message,level});}
UC
sed -n '/^function update_dns_outage(/,/^}/p' "$ROOT/forkop/files/usr/lib/singbox/dns_failover.uc"
cat <<'UC'
let state={failures:0,reported:false};
for(let i=0;i<4;i++)update_dns_outage(state,true,3);
update_dns_outage(state,false,3);update_dns_outage(state,false,3);
if(length(messages))die('premature notification\n');
update_dns_outage(state,true,3);
for(let i=0;i<5;i++)update_dns_outage(state,false,3);
if(length(messages)!=1||messages[0].level!='error')die('missing or duplicate outage\n');
update_dns_outage(state,true,3);update_dns_outage(state,true,3);
if(length(messages)!=2||messages[1].level!='info')die('recovery\n');
for(let i=0;i<3;i++)update_dns_outage(state,false,3);
if(length(messages)!=3||messages[2].level!='error')die('new outage\n');
print('DNS outage confirmation, deduplication and recovery passed\n');
UC
} > "$WORK/check.uc"
ucode "$WORK/check.uc"
# Intermediate apply/rollback diagnostics must not create LuCI error cards.
sed -n '/^function dns_failover_hot_apply(/,/^function reload_reason_for_generation(/p' \
 "$ROOT/forkop/files/usr/lib/service/lifecycle.uc" > "$WORK/apply"
if grep -E 'log_message.*"(error|fatal)"' "$WORK/apply"; then exit 1; fi
