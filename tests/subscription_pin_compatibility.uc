// ucode -L LIB tests/subscription_pin_compatibility.uc WORK LIB [XRUST_BINARY]
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
function generate(version,output,features){
 let args=["env","TMP_SUBSCRIPTION_FOLDER="+work+"/cache","FORKOP_RUNTIME_STATE_DIR="+work+"/state","TMP_SING_BOX_FOLDER="+work+"/singbox","FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="+work+"/persistent","FORKOP_LIB="+lib,"ucode","-L",lib,lib+"/xrust/generator.uc","generate-config-fixture",work+"/fixture.json",output,"127.0.0.1","0","1","",version,"0","0","0",features||""];
 return system(join(" ",map(args,quote))+" >"+quote(work+"/generation.log")+" 2>&1");
}
write(work+"/cache/probe-subscription-1.json",{outbounds:[node,pinned,chained,{type:"selector",tag:"pinned-group",outbounds:["pinned"]}]});
let cached=fs.readfile(work+"/cache/probe-subscription-1.json");
let output=work+"/generated.json";
expect(generate("0.0.45",output)==0,"mixed subscription failed: "+fs.readfile(work+"/generation.log"));
let config=json(fs.readfile(output));
let nodes=filter(config.outbounds,o=>o.type=="vless");
expect(length(nodes)==3,"native certificate pin or its dependent node was pruned");
expect(length(filter(nodes,o=>o.tls.certificate_sha256!=null))==1,"Xrust certificate pin lost");
if(ARGV[2])expect(run([ARGV[2],"check","-c",output])==0,"native Xrust pin check failed");
expect(fs.readfile(work+"/cache/probe-subscription-1.json")==cached,"generation changed cache");

pinned.tls.verify_server_name="localhost";
write(work+"/cache/probe-subscription-1.json",{outbounds:[node,pinned,chained,{type:"selector",tag:"pinned-group",outbounds:["pinned"]}]});
cached=fs.readfile(work+"/cache/probe-subscription-1.json");
expect(generate("0.0.45",output)==0,"mixed capability fixture failed");
expect(length(filter(json(fs.readfile(output)).outbounds,o=>o.type=="vless"))==1,"incompatible pin/name node or its detour was kept");
expect(generate("0.0.45",output,"tls.verify-name")==0,"advertised verification capability rejected");
nodes=filter(json(fs.readfile(output)).outbounds,o=>o.type=="vless");
expect(length(nodes)==3&&length(filter(nodes,o=>o.tls.verify_server_name=="localhost"))==1,"advertised pin/name verification lost");
expect(fs.readfile(work+"/cache/probe-subscription-1.json")==cached,"capability filter changed cache");

write(work+"/cache/probe-subscription-1.json",{outbounds:[pinned]});
fs.writefile(work+"/kept.json","LAST_KNOWN_GOOD\n");
expect(generate("0.0.45",work+"/kept.json")!=0,"all-incompatible subscription must fail closed");
expect(fs.readfile(work+"/kept.json")=="LAST_KNOWN_GOOD\n","failed generation replaced live config");
delete fixture.section[0].subscription_urls;
fixture.section[0].selector_proxy_links=["vless://00000000-0000-4000-8000-000000000001@127.0.0.1:443?security=tls&pcs=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef&vcn=localhost"];
write(work+"/fixture.json",fixture);
expect(generate("0.0.45",work+"/kept.json")!=0,"manual verification name accepted without feature");
expect(index(fs.readfile(work+"/generation.log"),"requires separate TLS certificate name verification")>=0,"manual verification capability error missing");
expect(fs.readfile(work+"/kept.json")=="LAST_KNOWN_GOOD\n","manual failure replaced config");
print("Xrust pin compatibility: native pins, capability filtering, detours, unchanged cache and last-known-good config passed\n");
