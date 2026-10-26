// ucode -L LIB tests/subscription_pin_compatibility.uc WORK LIB [GO_X] [RUST_X]
let fs=require("fs"), work=ARGV[0], lib=ARGV[1];
function expect(ok,why){if(!ok)die(why+"\n");}
function write(path,value){expect(fs.writefile(path,sprintf("%J",value))!=null,"write fixture");}
function quote(v){return "'"+replace(""+v,/'/g,"'\\''")+"'";}
function run(args){return system(join(" ",map(args,quote)));}
expect(run(["mkdir","-p",work+"/cache"])==0,"mkdir");
let node={type:"vless",tag:"plain",server:"127.0.0.1",server_port:443,uuid:"00000000-0000-4000-8000-000000000001",tls:{enabled:true,server_name:"localhost"}};
let pinned=json(sprintf("%J",node));pinned.tag="pinned";pinned.tls.certificate_sha256=["ASNFZ4mrze8BI0VniavN7wEjRWeJq83vASNFZ4mrze8="];
let chained=json(sprintf("%J",node));chained.tag="chained";chained.detour="pinned";
let fixture={settings:{".name":"settings",".type":"settings",dns_server:"1.1.1.1"},section:[{".name":"probe",".type":"section",enabled:"1",action:"connection",subscription_urls:["https://feed.example/test"],subscription_url_settings:'{"https://feed.example/test":{"user_agent":"Happ"}}'}]};
write(work+"/fixture.json",fixture);
for(let suffix in ["url","user_agent","hwid"])
 fs.writefile(work+"/cache/probe-subscription-1."+suffix,suffix=="url"?"https://feed.example/test":suffix=="user_agent"?"Happ":"");
function generate(version,output){
 let args=["env","TMP_SUBSCRIPTION_FOLDER="+work+"/cache","FORKOP_RUNTIME_STATE_DIR="+work+"/state","TMP_SING_BOX_FOLDER="+work+"/singbox","FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="+work+"/persistent","FORKOP_LIB="+lib,"ucode","-L",lib,lib+"/singbox/generator.uc","generate-config-fixture",work+"/fixture.json",output,"127.0.0.1","0","1","",version];
 return system(join(" ",map(args,quote))+" >"+quote(work+"/generation.log")+" 2>&1");
}
write(work+"/cache/probe-subscription-1.json",{outbounds:[node,pinned,chained,{type:"selector",tag:"pinned-group",outbounds:["pinned"]}]});
let cached=fs.readfile(work+"/cache/probe-subscription-1.json");
for(let profile in [{version:"1.14.2-x-1.0.4",binary:ARGV[2]},{version:"1.14.1-extended-2.7.2"},{version:"1.14.2-rust-x.0.0.22",binary:ARGV[3]}]){
 let output=work+"/generated.json";
 expect(generate(profile.version,output)==0,"mixed subscription failed: "+profile.version+": "+fs.readfile(work+"/generation.log"));
 let config=json(fs.readfile(output));let nodes=filter(config.outbounds,function(o){return o.type=="vless";});
 let rust=index(profile.version,"rust-x")>=0;
 expect(length(nodes)==(rust?3:1),"incompatible nodes or detour not pruned");
 if(!rust)expect(index(fs.readfile(work+"/generation.log"),"pin retained in subscription cache")>=0,"pin warning missing");
 else expect(length(filter(nodes,function(o){return o.tls.certificate_sha256!=null;}))==1,"Rust X pin lost");
 if(profile.binary)expect(run([profile.binary,"check","-c",output])==0,"real core check: "+profile.version);
 expect(fs.readfile(work+"/cache/probe-subscription-1.json")==cached,"capability filter changed cache");
}
write(work+"/cache/probe-subscription-1.json",{outbounds:[pinned]});
fs.writefile(work+"/kept.json","LAST_KNOWN_GOOD\n");
expect(generate("1.14.2-x-1.0.4",work+"/kept.json")!=0,"all-pinned subscription must fail closed");
expect(fs.readfile(work+"/kept.json")=="LAST_KNOWN_GOOD\n","failed generation replaced live config");
delete fixture.section[0].subscription_urls;
fixture.section[0].selector_proxy_links=["vless://00000000-0000-4000-8000-000000000001@127.0.0.1:443?security=tls&pcs=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"];
write(work+"/fixture.json",fixture);
expect(generate("1.14.2-x-1.0.4",work+"/kept.json")!=0,"manual pinned link accepted on incompatible core");
expect(index(fs.readfile(work+"/generation.log"),"requires TLS certificate SHA-256 pinning")>=0,"manual pin capability error missing");
expect(fs.readfile(work+"/kept.json")=="LAST_KNOWN_GOOD\n","manual failure replaced config");
print("Pin compatibility: Go X/Extended filter, dependent routes, Rust X retention, unchanged cache, explicit manual failure and last-known-good config passed\n");
