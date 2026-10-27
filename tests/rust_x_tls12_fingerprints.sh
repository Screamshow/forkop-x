#!/bin/sh
# Xrust refuses the android, 360 and qq uTLS profiles: it had the first two
# only as TLS 1.2 ClientHello templates while its client speaks TLS 1.3 only,
# and qq went with them. Those nodes get firefox in their place, and profiles
# Xrust does support are left alone.
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
function log_text(){return fs.readfile(work+"/generation.log")||"";}
function has_log(text){return index(log_text(),text)>=0;}
let uuid="00000000-0000-4000-8000-000000000001";
function node(tag,fp){return {type:"vless",tag,remark:tag,server:"127.0.0.1",server_port:443,uuid,
 tls:{enabled:true,server_name:"localhost",utls:{enabled:true,fingerprint:fp}}};}
let settings={".name":"settings",".type":"settings",dns_server:"1.1.1.1"};
let section={".name":"probe",".type":"section",enabled:"1",action:"connection",subscription_urls:["https://feed.example/test"],subscription_url_settings:'{"https://feed.example/test":{"user_agent":"Happ"}}'};
for(let suffix in ["url","user_agent","hwid"])
 fs.writefile(work+"/cache/probe-subscription-1."+suffix,suffix=="url"?"https://feed.example/test":suffix=="user_agent"?"Happ":"");
fs.writefile(work+"/cache/probe-subscription-1.json",sprintf("%J",{outbounds:[node("Android Node","android"),node("Q360 Node","360"),node("QQ Node","qq"),node("Safari Node","safari")]}));
let cached=fs.readfile(work+"/cache/probe-subscription-1.json");
function generate(fixture,version){
 fs.writefile(work+"/fixture.json",sprintf("%J",fixture));
 let args=["env","TMP_SUBSCRIPTION_FOLDER="+work+"/cache","FORKOP_RUNTIME_STATE_DIR="+work+"/state","TMP_SING_BOX_FOLDER="+work+"/singbox","FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="+work+"/persistent","FORKOP_LIB="+lib,"ucode","-L",lib,lib+"/singbox/generator.uc","generate-config-fixture",work+"/fixture.json",work+"/generated.json","127.0.0.1","0","1","",version];
 expect(system(join(" ",map(args,quote))+" >"+quote(work+"/generation.log")+" 2>&1")==0,version+": generation failed: "+log_text());
 let fps={};
 for(let o in json(fs.readfile(work+"/generated.json")).outbounds)
  if(o.type=="vless")fps[o.tag]=o.tls?.utls?.fingerprint;
 return fps;
}
let fixture={settings,section:[section]};
for(let version in ["1.14.2-rust-x.0.0.26"]){
 let fps=generate(fixture,version);
 expect(fps["Android Node"]=="firefox"&&fps["Q360 Node"]=="firefox"&&fps["QQ Node"]=="firefox",version+": unsupported fingerprint generated: "+sprintf("%J",fps));
 expect(fps["Safari Node"]=="safari",version+": supported fingerprint changed");
 expect(has_log("'Android Node' uses uTLS fingerprint android")&&has_log("'Q360 Node' uses uTLS fingerprint 360")&&has_log("'QQ Node' uses uTLS fingerprint qq"),version+": fingerprint substitution not reported: "+log_text());
 expect(fs.readfile(work+"/cache/probe-subscription-1.json")==cached,version+": subscription cache changed");
}
let go=generate(fixture,"1.14.2-x-1.0.4");
expect(go["Android Node"]=="android"&&go["Q360 Node"]=="360"&&go["QQ Node"]=="qq","Go X lost the android, 360 or qq fingerprint");
expect(!has_log("uses uTLS fingerprint"),"Go X reported a fingerprint substitution");

let manual={settings,section:[{".name":"manual",".type":"section",enabled:"1",action:"connection",
 selector_proxy_links:["vless://"+uuid+"@127.0.0.1:443?security=tls&sni=localhost&fp=android#Manual%20Android"],
 outbound_jsons:[sprintf("%J",node("JSON 360","360"))]}]};
let explicit=generate(manual,"1.14.2-rust-x.0.0.26");
for(let tag in keys(explicit))expect(explicit[tag]=="firefox","explicit "+tag+" keeps an unsupported fingerprint: "+explicit[tag]);
expect(length(keys(explicit))==2,"explicit outbounds missing: "+sprintf("%J",explicit));
expect(has_log("manual outbound 'Manual Android' uses uTLS fingerprint android")&&has_log("JSON outbound 'JSON 360' uses uTLS fingerprint 360"),"explicit substitution not reported: "+log_text());
print("Xrust unsupported fingerprints: subscription, manual and JSON nodes use firefox with a warning; cache and Go X keep android, 360 and qq\n");
UC
ucode -L "$LIB" "$WORK/check.uc" "$WORK" "$LIB"
