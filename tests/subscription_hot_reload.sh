#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
{
cat <<'UC'
let LIB_DIR="lib",SECTION_CACHE_DIR="cache",PRIORITY_UC="priority",DNS_FAILOVER_UC="dns";
let RUNTIME_STATE_DIR="state",SUBSCRIPTION_APPLY_ERROR_FILE="state/error";
let subscription_failure_detail=null,plan_mode,fail_apply,fail_restore,fail_commit,fail_workers,calls,active,saved;
function trim(v){return replace(""+(v||""),/^[ \t\r\n]+|[ \t\r\n]+$/g,"");}
function as_string(v){return v==null?"":""+v;}
function ensure_dir(p){return true;}
function command_output_from_args(args){return "work";}
function command_success_from_args(args){push(calls,join(" ",args));return true;}
function log_message(m,l){push(calls,m);}
let fs={chmod:function(p,m){return true;},stat:function(p){return {};},unlink:function(p){saved=null;},rename:function(a,b){return true;}};
let common={write_private_json_file:function(p,v){saved=json(sprintf("%J",v));return 1;}};
function module_capture(args){return {status:plan_mode=="bad"?1:0,output:plan_mode};}
function module_success(args){
 push(calls,join(" ",args));
 if(args[1]=="start-runtime" && active=="new" && fail_workers)return false;
 if(args[1]=="apply")return !fail_apply;
 if(args[1]=="restore"){if(!fail_restore)active="old";return !fail_restore;}
 return true;
}
function xrust_runtime_success(args){push(calls,join(" ",args));if(args[0]=="commit-config-stage"){active="new";return !fail_commit;}return true;}
UC
sed -n '/^function subscription_apply_failure(/,/^}/p' "$ROOT/forkop/files/usr/lib/components/updates.uc"
sed -n '/^function subscription_record_result(/,/^}/p' "$ROOT/forkop/files/usr/lib/components/updates.uc"
sed -n '/^function subscription_hot_transition(/,/^}/p' "$ROOT/forkop/files/usr/lib/components/updates.uc"
cat <<'UC'
function run(plan,apply,restore,commit,want,state,workers){
 plan_mode=plan;fail_apply=apply;fail_restore=restore;fail_commit=commit;calls=[];active="old";saved=null;subscription_failure_detail=null;
 fail_workers=workers||false;
 let result=subscription_hot_transition("config");
 if(plan=="cold"){
  if(result.handled||active!="old"||index(join(" ",calls),"commit-config-stage")>=0)die("cold fallback mutated runtime\n");
  return;
 }
 if(!result.handled||result.ok!=want)die("unexpected hot outcome\n");
 if(state=="previous" && active!="old")die("previous configuration lost\n");
 subscription_record_result(result.ok,"Proxy");
 if(want){if(active!="new"||saved!=null)die("success/alert mismatch\n");}
 else if(saved==null||saved.state!=state||saved.section!="Proxy")die("persistent alert mismatch\n");
 let text=join("\n",calls);
 if(state=="recovery_failed" && index(text,"rm -rf work")>=0)die("recovery backup deleted\n");
 if(index(text,"stop-managed-sing-box-runtime")>=0)die("hot path stopped the core\n");
}
run("cold",false,false,false,false,"");
run("bad",false,false,false,false,"previous");
run("hot",false,false,false,true,"");
run("hot",true,false,false,false,"previous");
run("hot",false,false,true,false,"previous");
run("hot",true,true,false,false,"recovery_failed");
run("hot",false,false,false,false,"previous",true);
print("Subscription hot apply, fallback, rollback and persistent alert checks passed\n");
UC
} > "$WORK/check.uc"
ucode "$WORK/check.uc"
