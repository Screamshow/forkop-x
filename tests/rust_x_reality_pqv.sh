#!/bin/sh
# REALITY ML-DSA-65 server verification (pqv / mldsa65Verify) must not be
# dropped silently. Xrust has no ML-DSA verification: subscription nodes with
# it are skipped with a warning, a section left without nodes fails, and a
# manual link fails. Other cores get the same configuration as before.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB=${FORKOP_LIB:-$ROOT/forkop/files/usr/lib}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/cache"
cat >"$WORK/check.uc" <<'UC'
let fs=require("fs"), links=require("subscription.share_link"), parser=require("subscription.parser");
let work=ARGV[0], lib=ARGV[1];
function expect(ok,why){if(!ok)die(why+"\n");}
function quote(v){return "'"+replace(""+v,/'/g,"'\\''")+"'";}
function log_text(){return fs.readfile(work+"/generation.log")||"";}
function has_log(text){return index(log_text(),text)>=0;}
function normalize(raw){fs.writefile(work+"/input",raw);expect(parser.normalize_content_validated(work+"/input",work+"/output"),"normalize failed");return json(fs.readfile(work+"/output")).outbounds;}
let uuid="00000000-0000-4000-8000-000000000001";
let pbk="mweeyHg5N36pJsed1hA2-TlNDkYpjU5JocLkFYIIVCI";
let pqv="AAAAqpqvTestValue";
function link(name,with_pqv){return "vless://"+uuid+"@127.0.0.1:443?security=reality&sni=www.example.com&fp=chrome&pbk="+pbk+"&sid=0123abcd&type=tcp&flow=xtls-rprx-vision"+(with_pqv?"&pqv="+pqv:"")+"#"+name;}

// Import keeps pqv (subscription link, export, Xray JSON) instead of dropping it.
let parsed=normalize(link("PQV",true)+"\n");
expect(parsed[0].tls.reality.__forkop_mldsa65_verify==pqv,"subscription parser dropped pqv: "+sprintf("%J",parsed[0].tls));
let n=parsed[0]; delete n.share_link;
expect(index(links.serialize_outbound_link(n),"pqv="+pqv)>=0,"exported link lost pqv");
let xray=normalize(sprintf("%J",{outbounds:[{protocol:"vless",tag:"x",settings:{vnext:[{address:"127.0.0.1",port:443,users:[{id:uuid,flow:"xtls-rprx-vision",encryption:"none"}]}]},
 streamSettings:{network:"tcp",security:"reality",realitySettings:{serverName:"www.example.com",publicKey:pbk,shortId:"0123abcd",fingerprint:"chrome",mldsa65Verify:pqv}}}]}));
expect(xray[0].tls.reality.__forkop_mldsa65_verify==pqv,"Xray JSON mldsa65Verify dropped");

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
function vless_remarks(){let r={};for(let o in json(fs.readfile(output)).outbounds)if(o.type=="vless")r[o.tag]=o;return r;}
let fixture={settings,section:[section]};
let rust=["1.14.2-rust-x.0.0.26","v0.0.26-rust-x.0"];
let plain=normalize(link("Plain",false)+"\n")[0], with_pqv=normalize(link("PQV",true)+"\n")[0];

// Mixed subscription on Xrust: the pqv node is skipped with a warning.
fs.writefile(work+"/cache/probe-subscription-1.json",sprintf("%J",{outbounds:[plain,with_pqv]}));
let cached=fs.readfile(work+"/cache/probe-subscription-1.json");
for(let version in rust){
 expect(generate(fixture,version)==0,version+": mixed subscription failed: "+log_text());
 expect(length(keys(vless_remarks()))==1,version+": pqv node generated: "+sprintf("%J",keys(vless_remarks())));
 expect(has_log("skipped incompatible subscription outbound for rule 'probe': PQV (REALITY ML-DSA-65 verification (pqv) is not supported by Xrust)"),version+": skip not reported: "+log_text());
 expect(index(fs.readfile(output),"mldsa65")<0,version+": marker reached the configuration");
 expect(fs.readfile(work+"/cache/probe-subscription-1.json")==cached,version+": subscription cache changed");
}
// Other cores: both nodes, no marker, the same outbound as without pqv.
expect(generate(fixture,"1.14.2-x-1.0.4")==0,"Go X: mixed subscription failed: "+log_text());
let go=vless_remarks();
expect(length(keys(go))==2,"Go X lost a node");
expect(index(fs.readfile(output),"mldsa65")<0,"Go X configuration carries the marker");
let shapes=map(values(go),function(o){let c=json(sprintf("%J",o));delete c.tag;return sprintf("%J",c);});
expect(shapes[0]==shapes[1],"Go X outbound differs with pqv: "+join(" | ",shapes));

// Only pqv nodes on Xrust: fails with the reason, previous configuration kept.
fs.writefile(work+"/cache/probe-subscription-1.json",sprintf("%J",{outbounds:[with_pqv]}));
for(let version in rust){
 fs.writefile(output,"previous configuration\n");
 expect(generate(fixture,version)!=0,version+": a section with only pqv nodes was applied");
 expect(has_log("has no outbounds compatible with Xrust; skipped subscription outbounds with unsupported protocols: reality pqv (1). Settings were not applied"),version+": empty section reason missing: "+log_text());
 expect(fs.readfile(output)=="previous configuration\n",version+": previous configuration replaced");
}

// Manual link: explicit error on Xrust, unchanged on other cores.
let manual={settings,section:[{".name":"manual",".type":"section",enabled:"1",action:"connection",selector_proxy_links:[link("Manual%20PQV",true)]}]};
expect(generate(manual,"1.14.2-rust-x.0.0.26")!=0,"manual pqv link was applied on Xrust");
expect(has_log("manual outbound 'Manual PQV' requires REALITY ML-DSA-65 verification (pqv), which Xrust does not support"),"manual link error missing: "+log_text());
expect(generate(manual,"1.14.2-x-1.0.4")==0,"Go X: manual pqv link failed: "+log_text());
expect(index(fs.readfile(output),"mldsa65")<0,"Go X manual configuration carries the marker");
let plain_manual={settings,section:[{".name":"manual",".type":"section",enabled:"1",action:"connection",selector_proxy_links:[link("Manual%20Plain",false)]}]};
expect(generate(plain_manual,"1.14.2-rust-x.0.0.26")==0,"manual link without pqv failed on Xrust: "+log_text());
print("REALITY pqv: kept on import and export, refused on Xrust (subscription skip with warning, empty section fails, manual link error); other cores unchanged\n");
UC
ucode -L "$LIB" "$WORK/check.uc" "$WORK" "$LIB"
