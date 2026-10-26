#!/bin/sh
# Xrust has no VLESS encryption layer and refuses encryption other than
# "none" at check time. Subscription nodes with it are skipped with a warning,
# a section left without nodes fails instead of falling back to Direct, and
# manual links and JSON outbounds fail with an explicit error.
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
let key="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
let enc="mlkem768x25519plus.native.0rtt."+key;
function node(tag,encryption){let o={type:"vless",tag,remark:tag,server:"127.0.0.1",server_port:443,uuid,
 tls:{enabled:true,server_name:"localhost"}};if(encryption!=null)o.encryption=encryption;return o;}
let settings={".name":"settings",".type":"settings",dns_server:"1.1.1.1"};
let section={".name":"probe",".type":"section",enabled:"1",action:"connection",subscription_urls:["https://feed.example/test"],subscription_url_settings:'{"https://feed.example/test":{"user_agent":"Happ"}}'};
for(let suffix in ["url","user_agent","hwid"])
 fs.writefile(work+"/cache/probe-subscription-1."+suffix,suffix=="url"?"https://feed.example/test":suffix=="user_agent"?"Happ":"");
let output=work+"/generated.json";
function generate(fixture,version){
 fs.writefile(work+"/fixture.json",sprintf("%J",fixture));
 let args=["env","TMP_SUBSCRIPTION_FOLDER="+work+"/cache","FORKOP_RUNTIME_STATE_DIR="+work+"/state","TMP_SING_BOX_FOLDER="+work+"/singbox","FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="+work+"/persistent","FORKOP_LIB="+lib,"ucode","-L",lib,lib+"/singbox/generator.uc","generate-config-fixture",work+"/fixture.json",output,"127.0.0.1","0","1","",version];
 return system(join(" ",map(args,quote))+" >"+quote(work+"/generation.log")+" 2>&1");
}
function vless_tags(){let tags={};for(let o in json(fs.readfile(output)).outbounds)if(o.type=="vless")tags[o.tag]=o.encryption??"";return tags;}
let fixture={settings,section:[section]};
let rust=["1.14.2-rust-x.0.0.26","v0.0.26-rust-x.0"];

// Mixed subscription: absent and "none" stay, the encrypted node is skipped.
fs.writefile(work+"/cache/probe-subscription-1.json",sprintf("%J",{outbounds:[node("Plain",null),node("None","none"),node("Encrypted",enc)]}));
let cached=fs.readfile(work+"/cache/probe-subscription-1.json");
for(let version in rust){
 expect(generate(fixture,version)==0,version+": mixed subscription failed: "+log_text());
 let tags=vless_tags();
 expect(tags["Plain"]!=null&&tags["None"]!=null,version+": nodes without encryption lost: "+sprintf("%J",tags));
 expect(tags["Encrypted"]==null,version+": encrypted VLESS node generated");
 for(let tag in keys(tags))expect(tags[tag]==""||tags[tag]=="none",version+": encryption kept on "+tag);
 expect(has_log("skipped incompatible subscription outbound for rule 'probe': Encrypted (VLESS encryption mlkem768x25519plus is not supported by Xrust)"),version+": skip not reported: "+log_text());
 expect(fs.readfile(work+"/cache/probe-subscription-1.json")==cached,version+": subscription cache changed");
}
// A Go core keeps the node as before.
expect(generate(fixture,"1.14.2-x-1.0.4")==0,"Go X: mixed subscription failed: "+log_text());
expect(vless_tags()["Encrypted"]==enc,"Go X lost the encrypted node");

// Only encrypted nodes: generation fails with the reason and leaves the
// previous configuration in place; nothing falls back to Direct.
fs.writefile(work+"/cache/probe-subscription-1.json",sprintf("%J",{outbounds:[node("Encrypted A",enc),node("Encrypted B","mlkem768x25519plus.xorpub.1rtt."+key)]}));
for(let version in rust){
 fs.writefile(output,"previous configuration\n");
 expect(generate(fixture,version)!=0,version+": a section with only encrypted VLESS nodes was applied");
 expect(has_log("connection section 'probe' has no outbounds compatible with Xrust; skipped subscription outbounds with unsupported protocols: vless encryption (2). Settings were not applied"),version+": empty section reason missing: "+log_text());
 expect(fs.readfile(output)=="previous configuration\n",version+": previous configuration replaced");
}

// Manual link and JSON outbound: explicit error.
let manual={settings,section:[{".name":"manual",".type":"section",enabled:"1",action:"connection",
 selector_proxy_links:["vless://"+uuid+"@127.0.0.1:443?security=tls&sni=localhost&encryption="+enc+"#Manual%20Encrypted"]}]};
expect(generate(manual,"1.14.2-rust-x.0.0.26")!=0,"manual encrypted link was applied");
expect(has_log("manual outbound 'Manual Encrypted' uses VLESS encryption mlkem768x25519plus, which Xrust does not support; use a link with encryption=none"),"manual link error missing: "+log_text());
let json_section={settings,section:[{".name":"json",".type":"section",enabled:"1",action:"connection",
 outbound_jsons:[sprintf("%J",node("JSON Encrypted",enc))]}]};
expect(generate(json_section,"1.14.2-rust-x.0.0.26")!=0,"JSON encrypted outbound was applied");
expect(has_log("JSON outbound 'JSON Encrypted' uses VLESS encryption mlkem768x25519plus"),"JSON outbound error missing: "+log_text());
let plain={settings,section:[{".name":"manual",".type":"section",enabled:"1",action:"connection",
 selector_proxy_links:["vless://"+uuid+"@127.0.0.1:443?security=tls&sni=localhost&encryption=none#Manual%20None"]}]};
expect(generate(plain,"1.14.2-rust-x.0.0.26")==0,"manual link with encryption=none failed: "+log_text());
expect(vless_tags()["Manual None"]!=null||length(keys(vless_tags()))==1,"manual link with encryption=none not generated");
print("Xrust VLESS encryption: subscription nodes skipped with a warning, empty section fails without replacing the config, manual and JSON nodes refused; absent and none keep working; Go X unchanged\n");
UC
ucode -L "$LIB" "$WORK/check.uc" "$WORK" "$LIB"
