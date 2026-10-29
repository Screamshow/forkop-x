#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
{
cat <<'UC'
let events=[], reconcile_ok=true, source_ready=true, configured=true;
function object_or_empty(v){return v||{};}
function section_is_subscription_proxy(s){return s.connection_type=='subscription';}
function section_name(s){return s['.name'];}
function source_id(s,n){return s+'-'+n;}
function temp_path(a,b,c){return 'metadata';}
function write_json(a,b){}
function read_json(p){return [];}
function array_or_empty(v){return v||[];}
function write_subscription_metadata(a,b,c,d){}
function unlink_path(p){}
function append_word_once(a,b){return a+' '+b;}
function section_has_non_subscription_connection_sources(s){return false;}
function log_message(a,b){}
let TMP_SUBSCRIPTION_FOLDER='runtime',FORKOP_SECTION_CACHE_DIR='metadata',FORKOP_RUNTIME_CACHE_FORMAT=12;
let connections={subscription_urls:function(s){return ['source'];}};
let filter_selection={
 snapshot:function(s){push(events,'snapshot');return {section:s,descriptors:configured?[{}]:[]};},
 finish:function(s){assert(s.section['.name']=='test');push(events,'finish');return {ok:reconcile_ok};}
};
function ensure_subscription_source_for_prepare(state,section,n,entry,metadata){push(events,'cached-source');return source_ready;}
UC
sed -n '/^function prepare_subscription_cache_section(/,/^}/p' "$ROOT/forkop/files/usr/lib/subscription/cache.uc"
cat <<'UC'
function run(ok,ready){
 events=[];reconcile_ok=ok;source_ready=ready;
 let state={phase:'startup',unavailable_sources:'',startup_blocked_sections:'',startup_blocked:false};
 prepare_subscription_cache_section(state,{'.name':'test',connection_type:'subscription'});
 return state;
}
assert(!run(true,true).startup_blocked);
assert(join(',',events)=='snapshot,cached-source,finish','cached startup bypassed reconciliation');
assert(run(false,true).startup_blocked,'failed binding persistence must block startup');
run(true,false);
assert(join(',',events)=='snapshot,cached-source','unavailable source must not rewrite bindings');
configured=false;
assert(!run(false,true).startup_blocked,'section without filters must not require binding persistence');
assert(join(',',events)=='snapshot,cached-source','section without filters must not write bindings');
print('PASS cached startup reconciles filters, persistence failure blocks startup, unavailable feed preserved\n');
UC
} > "$WORK/startup.uc"
ucode "$WORK/startup.uc"
{
cat <<'UC'
function normalize_component_name(v){return v;}
function as_string(v){return v;}
function acquire_component_lock(){return false;}
function action_fail(){die('busy background action published an error\n');}
UC
sed -n '/^function component_action(/,/^}/p' "$ROOT/forkop/files/usr/lib/components/action.uc"
echo 'component_action("zapret_manager","migrate","");'
} > "$WORK/busy.uc"
rc=0
FORKOP_COMPONENT_BACKGROUND=1 ucode "$WORK/busy.uc" > "$WORK/busy.out" 2>&1 || rc=$?
[ "$rc" = 75 ] && [ ! -s "$WORK/busy.out" ]
echo 'PASS background lock contention returns retry status without error output or cleanup'
