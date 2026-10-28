#!/bin/sh
# A Flintnet subscription starts with the provider URLTest groups off, however
# it got there: the one-time upgrade migration covered the subscriptions that
# already existed, and the default covers the ones added afterwards. It is a
# default and not a rule, so a subscription that carries the option keeps what
# it says, and no other host is affected.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB=${FORKOP_LIB:-$ROOT/forkop/files/usr/lib}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/cache"
cat >"$WORK/check.uc" <<'UC'
let fs=require("fs"), work=ARGV[0], lib=ARGV[1];
function expect(ok,why){if(!ok)die(why+"\n");}
function quote(v){return "'"+replace(""+v,/'/g,"'\\''")+"'";}
let uuid="00000000-0000-4000-8000-000000000001";
// The agent Forkop X sends is INCY with its own version; a fixture that
// configures one explicitly uses that shape and not another client's.
let agent="INCY/2.5.0";
function node(tag){return {type:"vless",tag,remark:tag,server:"127.0.0.1",server_port:443,uuid,
 tls:{enabled:true,server_name:"localhost"}};}
// A plain node, a provider balancer and the two technical nodes it owns: a
// real feed carries all three, and the section needs the plain one to stay
// usable once the group and its members are dropped.
let feed={outbounds:[node("Plain Node"),node("Member A"),node("Member B"),
 {type:"urltest",tag:"Provider Balancer",remark:"Provider Balancer",
  outbounds:["Member A","Member B"],__forkop_allow_group:true}]};
let settings={".name":"settings",".type":"settings",dns_server:"1.1.1.1"};

// `option` is "" for a subscription that never carried the setting.
function run(url,option,label){
 for(let suffix in ["url","user_agent","hwid"])
  fs.writefile(work+"/cache/probe-subscription-1."+suffix,suffix=="url"?url:suffix=="user_agent"?agent:"");
 fs.writefile(work+"/cache/probe-subscription-1.json",sprintf("%J",feed));
 let per_url={};
 per_url[url]={user_agent:agent};
 if(option!="")per_url[url].include_urltest_groups=option;
 let section={".name":"probe",".type":"section",enabled:"1",action:"connection",
  subscription_urls:[url],subscription_url_settings:sprintf("%J",per_url)};
 fs.writefile(work+"/fixture.json",sprintf("%J",{settings,section:[section]}));
 let args=["env","TMP_SUBSCRIPTION_FOLDER="+work+"/cache","FORKOP_RUNTIME_STATE_DIR="+work+"/state",
  "TMP_SING_BOX_FOLDER="+work+"/singbox","FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="+work+"/persistent",
  "FORKOP_LIB="+lib,"ucode","-L",lib,lib+"/singbox/generator.uc","generate-config-fixture",
  work+"/fixture.json",work+"/generated.json","127.0.0.1","0","1","","1.14.2-rust-x.0.0.28"];
 let log=work+"/generation.log";
 expect(system(join(" ",map(args,quote))+" >"+quote(log)+" 2>&1")==0,
  label+": generation failed: "+(fs.readfile(log)||""));
 let tags={};
 for(let o in json(fs.readfile(work+"/generated.json")).outbounds)tags[""+o.tag]=""+o.type;
 return tags;
}

function seen(tags,text){for(let tag in keys(tags))if(index(tag,text)>=0)return true;return false;}

let flint="https://sub.flintnet.pro/sub/token";
let other="https://feed.example/test";

// added with no option: imported everywhere, except from Flintnet
let t=run(other,"","other host default");
expect(seen(t,"Provider Balancer"),"another host lost its provider group: "+sprintf("%J",t));
expect(seen(t,"Member "),"another host lost the group's members: "+sprintf("%J",t));
t=run(flint,"","flintnet default");
expect(!seen(t,"Provider Balancer"),
 "a new Flintnet subscription imported the provider group: "+sprintf("%J",t));
expect(!seen(t,"Member "),
 "a new Flintnet subscription kept the group's technical members: "+sprintf("%J",t));
expect(seen(t,"Plain Node"),"a new Flintnet subscription lost its plain nodes: "+sprintf("%J",t));

// the option decides over the default, in both directions
t=run(flint,"1","flintnet opted in");
expect(seen(t,"Provider Balancer"),
 "Flintnet could not turn the provider groups back on: "+sprintf("%J",t));
expect(seen(t,"Member "),"Flintnet opted in but kept its members hidden: "+sprintf("%J",t));
t=run(other,"0","other host opted out");
expect(!seen(t,"Provider Balancer"),
 "another host could not turn the provider groups off: "+sprintf("%J",t));

print("Flintnet provider URLTest groups: off by default on any new subscription, on elsewhere, and the option still decides\n");
UC
ucode -L "$LIB" "$WORK/check.uc" "$WORK" "$LIB"
