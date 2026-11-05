#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
{
cat <<'UC'
const SINGBOX_UC='runtime',HOT_RELOAD_UC='hot',DNS_FAILOVER_UC='dns',CONFIG_NAME='forkop';
let scenario='',calls=[],removed=[];
function as_string(v){return v==null?'':''+v;}
function module_capture(mod,args){
 push(calls,args[0]);
 if(args[0]=='prepare-dns-config')return {status:scenario=='prepare-fail'?1:0,output:(scenario=='unchanged'?'0':'1')+'\tbackup\tstage'};
 return {status:scenario=='plan-fail'?1:0,output:scenario=='cold'?'cold':'hot'};
}
function module_status(mod,args){push(calls,args[0]);return scenario=='apply-fail'?1:0;}
function module_success(mod,args){push(calls,args[0]);return !(scenario=='apply-fail'&&args[0]=='apply') && !(scenario=='commit-fail'&&args[0]=='commit-state') && !(scenario=='rollback-fail'&&args[0]=='restore');}
function wait_dns_failover_state(){push(calls,'verify');return index(['verify-fail','rollback-fail'],scenario)>=0?1:0;}
function config_get(){return 'current';}
function command_success_from_args(args){push(calls,args[0]);return scenario!='copy-fail';}
function remove_file(path){push(removed,path);}
function log_message(){}
UC
sed -n '/^function dns_failover_hot_apply(/,/^}/p' "$ROOT/forkop/files/usr/lib/service/lifecycle.uc"
cat <<'UC'
for(let name in ['ok','unchanged','cold','prepare-fail','plan-fail','copy-fail','apply-fail','verify-fail','commit-fail','rollback-fail']){
 scenario=name;calls=[];removed=[];
 let status=dns_failover_hot_apply('candidate');
 let expected=name=='cold'?3:(index(['ok','unchanged'],name)>=0?0:1);
 if(status!=expected)die(name+': status\n');
 if(index(['apply-fail','verify-fail','commit-fail','rollback-fail'],name)>=0 && index(calls,'restore')<0)die(name+': missing rollback\n');
 if(name=='rollback-fail'&&index(removed,'backup')>=0)die('lost rollback backup\n');
 if(index(['cold','plan-fail','prepare-fail'],name)>=0&&index(calls,'cp')>=0)die('premature publication\n');
 if(name=='unchanged'&&index(calls,'apply')>=0)die('no-op signal\n');
}
print('DNS hot failover success, no-op, cold fallback and failure rollback checks passed\n');
UC
} > "$WORK/check.uc"
ucode "$WORK/check.uc"
