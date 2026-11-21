#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Only selected nodes, plus their complete dependency graph, may be removed
# from consideration for pruning. External references must remain valid.
ucode -L "$FORKOP_LIB" -e '
let reachability = require("xrust.outbound_reachability");
let config = {
    outbounds: [
        {tag:"section",type:"selector",outbounds:["chosen","group"]},
        {tag:"group",type:"urltest",outbounds:["chosen"]},
        {tag:"chosen",type:"vless",detour:"chain"},
        {tag:"chain",type:"socks",detour:"cycle"},
        {tag:"cycle",type:"socks",detour:"chain"},
        {tag:"unused-group",type:"urltest",outbounds:["unused"]},
        {tag:"unused",type:"vless"},
        {tag:"other-section",type:"selector",outbounds:["shared"]},
        {tag:"shared",type:"vless"},
        {tag:"dns-detour",type:"vless"},
        {tag:"explicit-route",type:"vless"},
        {tag:"ui-download",type:"vless"}
    ],
    dns:{servers:[{detour:"dns-detour"}]},
    experimental:{clash_api:{external_ui_download_detour:"ui-download"}},
    route:{rules:[{type:"logical",rules:[{outbound:"explicit-route"}]}]}
};
let candidates={};
for(let o in config.outbounds) if(o.tag!="section" && o.tag!="other-section") candidates[o.tag]=true;
reachability.prune(config,candidates);
let live={};for(let o in config.outbounds)live[o.tag]=true;
for(let tag in ["section","group","chosen","chain","cycle","other-section","shared","dns-detour","explicit-route","ui-download"])
    if(!live[tag])die("reachable dependency was pruned: "+tag+"\n");
if(live.unused || live["unused-group"])die("unused server/group remains loaded\n");
'

cat >"$WORK_DIR/catalog.json" <<'JSON'
{"outbounds":[
 {"type":"vless","tag":"One","server":"one.example","server_port":443,"uuid":"00000000-0000-4000-8000-000000000001"},
 {"type":"vless","tag":"Two","server":"two.example","server_port":443,"uuid":"00000000-0000-4000-8000-000000000001"},
 {"type":"urltest","tag":"Provider group","outbounds":["One","Two"],"interval":"3m"}
]}
JSON
ucode -L "$FORKOP_LIB" "$FORKOP_LIB/subscription/parser.uc" normalize-content \
    "$WORK_DIR/catalog.json" "$WORK_DIR/normalized.json"
mkdir -p "$WORK_DIR/subscriptions"
export FORKOP_VERSION=2.3.6
for section in filtered all; do
    cp "$WORK_DIR/normalized.json" "$WORK_DIR/subscriptions/$section-subscription-1.json"
    printf '%s\n' 'https://fixture.example/sub' >"$WORK_DIR/subscriptions/$section-subscription-1.url"
    printf 'INCY/2.3.6' >"$WORK_DIR/subscriptions/$section-subscription-1.user_agent"
done
for chosen in One Two; do
    cat >"$WORK_DIR/fixture.json" <<JSON
{"settings":{".name":"settings",".type":"settings","log_level":"warn"},"section":[
 {".name":"filtered",".type":"section","enabled":"1","action":"connection",
  "subscription_urls":["https://fixture.example/sub"],"urltest_enabled":"1",
  "urltest_filter_mode":"include","urltest_include_outbounds":["$chosen"]},
 {".name":"all",".type":"section","enabled":"1","action":"connection",
  "subscription_urls":["https://fixture.example/sub"]}
]}
JSON
    TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/subscriptions" \
        ucode -L "$FORKOP_LIB" "$FORKOP_LIB/xrust/generator.uc" generate-config-fixture \
        "$WORK_DIR/fixture.json" "$WORK_DIR/$chosen.json" 127.0.0.1
done
ucode -e '
let fs=require("fs");
function closure(config,tag,seen) {
    if(seen[tag])return;seen[tag]=true;
    for(let o in config.outbounds)if(o.tag==tag)for(let member in o.outbounds||[])closure(config,member,seen);
}
for(let chosen in ["One","Two"]) {
    let cfg=json(fs.readfile(ARGV[0]+"/"+chosen+".json"));
    let cache=json(fs.readfile(ARGV[0]+"/"+chosen+".json.section-cache/filtered.json"));
    if(length(cache.urltestCandidateTags)!=2)die("full candidate catalog was lost\n");
    for(let tag in ["One","Two"])
        if(!cache.outboundMetadata.names[tag])die("excluded node unavailable for re-selection\n");
    let live={},filtered={},other={};
    for(let o in cfg.outbounds)live[o.tag]=o;
    closure(cfg,"filtered-out",filtered);closure(cfg,"all-out",other);
    if(!filtered[chosen] || live[chosen].type!="vless")die("filter re-enable did not instantiate the chosen server\n");
    let excluded=chosen=="One"?"Two":"One";
    if(live[excluded] || live["Provider group"])die("unused section server/provider group remains loaded\n");
    let other_leaves=0;
    for(let tag in other)if(live[tag] && live[tag].type=="vless")other_leaves++;
    if(other_leaves!=2)die("other section lost servers from the same subscription\n");
}
' "$WORK_DIR"
printf 'filtered outbound graph, catalog retention and re-enable checks passed\n'

# Priority must retain standby levels, not only its currently selected node.
cat >"$WORK_DIR/priority-catalog.json" <<'JSON'
{"outbounds":[
 {"type":"vless","tag":"One","server":"one.example","server_port":443,"uuid":"00000000-0000-4000-8000-000000000001"},
 {"type":"vless","tag":"Two","server":"two.example","server_port":443,"uuid":"00000000-0000-4000-8000-000000000001"},
 {"type":"vless","tag":"Three","server":"three.example","server_port":443,"uuid":"00000000-0000-4000-8000-000000000001"},
 {"type":"urltest","tag":"Provider group","outbounds":["One","Two","Three"],"interval":"3m"}
]}
JSON
ucode -L "$FORKOP_LIB" "$FORKOP_LIB/subscription/parser.uc" normalize-content \
    "$WORK_DIR/priority-catalog.json" "$WORK_DIR/subscriptions/p-subscription-1.json"
printf '%s\n' 'https://fixture.example/sub' >"$WORK_DIR/subscriptions/p-subscription-1.url"
printf 'INCY/2.3.6' >"$WORK_DIR/subscriptions/p-subscription-1.user_agent"
for mode in Two Three mixed; do
    backup="$mode"
    extra=''
    if [ "$mode" = mixed ]; then
        backup=Two
        extra=',"urltest_enabled":"1","urltest_filter_mode":"include","urltest_include_outbounds":["Three"]'
    fi
    cat >"$WORK_DIR/priority-fixture.json" <<JSON
{"settings":{".name":"settings",".type":"settings","log_level":"warn"},
 "section":[{".name":"p",".type":"section","enabled":"1","action":"connection",
  "subscription_urls":["https://fixture.example/sub"]$extra}],
 "priority_group":[{".name":"pg",".type":"priority_group","section":"p","name":"Failover"}],
 "priority_level":[
  {".name":"primary",".type":"priority_level","group":"pg","name":"Primary","order":"0",
   "filter_mode":"include","include_outbounds":["One"]},
  {".name":"backup",".type":"priority_level","group":"pg","name":"Backup","order":"1",
   "filter_mode":"include","include_outbounds":["$backup"]},
  {".name":"direct",".type":"priority_level","group":"pg","name":"Direct","order":"2","direct":"1"}
 ]}
JSON
    TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/subscriptions" \
        ucode -L "$FORKOP_LIB" "$FORKOP_LIB/xrust/generator.uc" generate-config-fixture \
        "$WORK_DIR/priority-fixture.json" "$WORK_DIR/priority-$mode.json" 127.0.0.1
done
ucode -e '
let fs=require("fs");
for(let mode in ["Two","Three","mixed"]) {
    let cfg=json(fs.readfile(ARGV[0]+"/priority-"+mode+".json"));
    let cache=json(fs.readfile(ARGV[0]+"/priority-"+mode+".json.section-cache/p.json"));
    let live={};for(let o in cfg.outbounds)live[o.tag]=o;
    let backup=mode=="Three"?"Three":"Two";
    let group=live["p-priority-pg-out"];
    if(!group || sprintf("%J",group.outbounds)!=sprintf("%J",["One",backup,"direct-out"]))
        die("Priority order/standby/direct fallback changed\n");
    for(let tag in ["One",backup,"direct-out"])
        if(!live[tag])die("Priority standby or dependency was pruned\n");
    if(live["Provider group"])die("unused provider probes remain in Priority section\n");
    let excluded=backup=="Two"?"Three":"Two";
    if(mode=="mixed") {
        if(!live.Three || !live["p-urltest-out"])die("URLTest/Priority union was not preserved\n");
    }
    else if(live[excluded])die("unused Priority candidate remains loaded\n");
    if(length(cache.urltestCandidateTags)!=3 || !cache.outboundMetadata.names[excluded])
        die("Priority lost full candidate catalog\n");
    let metadata=cache.priorityGroups["p-priority-pg-out"];
    if(!metadata || length(metadata.levels)!=3 || metadata.levels[1].outbounds[0]!=backup)
        die("Priority supervisor lost standby level metadata\n");
}
' "$WORK_DIR"
printf 'Priority standby levels, direct fallback, re-enable and URLTest union checks passed\n'
