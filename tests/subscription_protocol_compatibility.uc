// ucode -L LIB tests/subscription_protocol_compatibility.uc WORK LIB [RUST_X_BINARY] [LEGACY_BINARY]
// Xrust is built without vmess, shadowsocks and socks outbounds, and only
// builds declaring the outbound.trojan feature include the Trojan client.
let fs=require("fs"), parser=require("subscription.parser"), work=ARGV[0], lib=ARGV[1], rust_binary=ARGV[2], legacy_binary=ARGV[3];
function expect(ok,why){if(!ok)die(why+"\n");}
function write(path,value){expect(fs.writefile(path,sprintf("%J",value))!=null,"write fixture");}
function quote(v){return "'"+replace(""+v,/'/g,"'\\''")+"'";}
function run(args){return system(join(" ",map(args,quote)));}
function log_text(){return fs.readfile(work+"/generation.log")||"";}
function has_log(text){return index(log_text(),text)>=0;}
function last_log_line(){let lines=filter(split(trim(log_text()),"\n"),function(l){return trim(l)!="";});return length(lines)?lines[length(lines)-1]:"";}
expect(run(["mkdir","-p",work+"/cache"])==0,"mkdir");

let uuid="00000000-0000-4000-8000-000000000001";
let vless={type:"vless",tag:"vless-a",remark:"VLESS A",server:"127.0.0.1",server_port:443,uuid,tls:{enabled:true,server_name:"localhost"}};
let hy2={type:"hysteria2",tag:"hy2-a",remark:"HY2 A",server:"127.0.0.1",server_port:8443,password:"pw",tls:{enabled:true,server_name:"localhost"}};
let trojan={type:"trojan",tag:"trojan-a",remark:"Trojan A",server:"127.0.0.1",server_port:443,password:"pw",tls:{enabled:true,server_name:"localhost"}};
let ss={type:"shadowsocks",tag:"ss-a",remark:"SS A",server:"127.0.0.1",server_port:8388,method:"chacha20-ietf-poly1305",password:"pw"};
let vmess={type:"vmess",tag:"vmess-a",remark:"VMess A",server:"127.0.0.1",server_port:10086,uuid,security:"auto"};
let socks={type:"socks",tag:"socks-a",remark:"SOCKS A",server:"127.0.0.1",server_port:1080,version:"5"};
let chained=json(sprintf("%J",vless));chained.tag="vless-via-trojan";chained.remark="VLESS via Trojan";chained.detour="trojan-a";
let mixed_group={type:"selector",tag:"mixed-group",remark:"Mixed group",outbounds:["trojan-a","vless-a","ss-a"],default:"trojan-a",__forkop_allow_group:true};
let legacy_group={type:"urltest",tag:"legacy-group",remark:"Legacy group",outbounds:["trojan-a","vmess-a"],__forkop_allow_group:true};
let nested_group={type:"selector",tag:"nested-group",remark:"Nested group",outbounds:["legacy-group","socks-a"],__forkop_allow_group:true};
let legacy_nodes=[trojan,ss,vmess,socks];

let settings={".name":"settings",".type":"settings",dns_server:"1.1.1.1"};
let subscription_section={".name":"probe",".type":"section",enabled:"1",action:"connection",subscription_urls:["https://feed.example/test"],subscription_url_settings:'{"https://feed.example/test":{"user_agent":"Happ"}}'};
for(let suffix in ["url","user_agent","hwid"])
 fs.writefile(work+"/cache/probe-subscription-1."+suffix,suffix=="url"?"https://feed.example/test":suffix=="user_agent"?"Happ":"");
// supports_trojan is the generator argument runtime.uc derives from Features.
function generate(fixture,version,output,supports_trojan){
 write(work+"/fixture.json",fixture);
 let args=["env","TMP_SUBSCRIPTION_FOLDER="+work+"/cache","FORKOP_RUNTIME_STATE_DIR="+work+"/state","TMP_SING_BOX_FOLDER="+work+"/singbox","FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="+work+"/persistent","FORKOP_LIB="+lib,"ucode","-L",lib,lib+"/singbox/generator.uc","generate-config-fixture",work+"/fixture.json",output,"127.0.0.1","0","1","",version,supports_trojan||""];
 return system(join(" ",map(args,quote))+" >"+quote(work+"/generation.log")+" 2>&1");
}
function tag_set(config){let tags={};for(let o in config.outbounds)tags[o.tag]=true;return tags;}
// Every outbound reference must point at a generated outbound.
function expect_references_resolve(config,profile){
 let tags=tag_set(config);
 function ref(value,where){if(value!=null&&value!="")expect(tags[value],profile+": "+where+" references missing outbound '"+value+"'");}
 for(let o in config.outbounds){
  ref(o.detour,"detour of "+o.tag);
  ref(o.default,"default of "+o.tag);
  for(let member in o.outbounds||[])ref(member,"member of "+o.tag);
 }
 ref(config.route?.final,"route.final");
 for(let rule in config.route?.rules||[])ref(rule.outbound,"route rule");
 for(let server in config.dns?.servers||[])ref(server.detour,"DNS server detour");
}
function outbounds_of_type(config,types){return filter(config.outbounds,function(o){return index(types,o.type)>=0;});}

// Mixed subscription: compatible nodes stay, unsupported nodes and every
// reference to them are removed, and the cache keeps all nodes.
write(work+"/cache/probe-subscription-1.json",{outbounds:[vless,hy2,trojan,ss,vmess,socks,chained,mixed_group,legacy_group,nested_group]});
let cached=fs.readfile(work+"/cache/probe-subscription-1.json");
let fixture={settings,section:[subscription_section]};
for(let profile in [{version:"1.14.2-rust-x.0.0.26",binary:rust_binary}]){
 let output=work+"/generated.json";
 expect(generate(fixture,profile.version,output)==0,"mixed subscription failed: "+profile.version+": "+log_text());
 let config=json(fs.readfile(output));
 expect(length(outbounds_of_type(config,["trojan","shadowsocks","vmess","socks"]))==0,profile.version+": unsupported protocol generated");
 expect(length(outbounds_of_type(config,["vless"]))==1,profile.version+": compatible VLESS node lost or node with unavailable detour kept");
 expect(length(outbounds_of_type(config,["hysteria2"]))==1,profile.version+": compatible Hysteria2 node lost");
 let tags=tag_set(config);
 expect(!tags["legacy-group"]&&!tags["nested-group"],profile.version+": group without compatible members kept");
 let group=filter(config.outbounds,function(o){return o.tag=="mixed-group";});
 expect(length(group)==1&&length(group[0].outbounds)==1&&group[0].outbounds[0]=="vless-a"&&group[0].default=="vless-a",profile.version+": mixed group not reduced to compatible members");
 expect_references_resolve(config,profile.version);
 for(let item in [["Trojan A","trojan"],["SS A","shadowsocks"],["VMess A","vmess"],["SOCKS A","socks"]])
  expect(has_log("skipped incompatible subscription outbound for rule 'probe': "+item[0]+" (protocol "+item[1]+" is not included in Xrust)"),profile.version+": warning missing for "+item[0]);
 expect(has_log("VLESS via Trojan (detour depends on unavailable outbound 'trojan-a')"),profile.version+": dependent node warning missing");
 if(profile.binary)expect(run([profile.binary,"check","-c",output])==0,profile.version+": real Xrust check failed");
 expect(fs.readfile(work+"/cache/probe-subscription-1.json")==cached,profile.version+": protocol filter changed subscription cache");
}

// Cores built with these protocols keep every node.
expect(generate(fixture,"1.14.2-x-1.0.4",work+"/generated.json")==0,"Go X mixed subscription failed: "+log_text());
let go_config=json(fs.readfile(work+"/generated.json"));
expect(length(outbounds_of_type(go_config,["trojan","shadowsocks","vmess","socks"]))==4,"Go X lost legacy subscription nodes");
expect(!has_log("is not included in Xrust"),"Go X reported an Xrust protocol skip");
expect_references_resolve(go_config,"Go X");
if(legacy_binary)expect(run([legacy_binary,"check","-c",work+"/generated.json"])==0,"real legacy-profile check failed");

// No compatible node: explicit error, no Direct fallback, previous config kept.
write(work+"/cache/probe-subscription-1.json",{outbounds:[trojan,ss,legacy_group]});
fs.writefile(work+"/kept.json","LAST_KNOWN_GOOD\n");
expect(generate(fixture,"1.14.2-rust-x.0.0.26",work+"/kept.json")!=0,"subscription without compatible nodes must fail");
expect(index(last_log_line(),"connection section 'probe' has no outbounds compatible with Xrust; skipped subscription outbounds with unsupported protocols: shadowsocks (1), trojan (1)")>=0,"unclear error for subscription without compatible nodes: "+last_log_line());
expect(fs.readfile(work+"/kept.json")=="LAST_KNOWN_GOOD\n","failed generation replaced live config");

// Manual links and JSON outbounds with unsupported protocols are rejected explicitly.
let manual={settings,section:[{".name":"manual",".type":"section",enabled:"1",action:"connection",selector_proxy_links:[
 "vless://"+uuid+"@127.0.0.1:443?security=tls&sni=localhost#VLESS%20Manual",
 "trojan://pw@127.0.0.1:443?security=tls&sni=localhost#Trojan%20Manual"]}]};
expect(generate(manual,"1.14.2-rust-x.0.0.26",work+"/kept.json")!=0,"manual Trojan link accepted on Xrust");
expect(index(last_log_line(),"manual outbound 'Trojan Manual' uses protocol trojan, which is not included in Xrust")>=0,"unclear manual link error: "+last_log_line());
expect(fs.readfile(work+"/kept.json")=="LAST_KNOWN_GOOD\n","manual failure replaced config");
for(let link in ["ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpwdw@127.0.0.1:8388#SS%20Manual","socks5://127.0.0.1:1080#SOCKS%20Manual"]){
 manual.section[0].selector_proxy_links=[link];
 expect(generate(manual,"1.14.2-rust-x.0.0.26",work+"/kept.json")!=0,"manual link accepted on Xrust: "+link);
 expect(index(last_log_line(),"is not included in Xrust")>=0,"unclear manual link error: "+last_log_line());
}
manual.section[0].selector_proxy_links=["trojan://pw@127.0.0.1:443?security=tls&sni=localhost#Trojan%20Manual"];
expect(generate(manual,"1.14.2-x-1.0.4",work+"/generated.json")==0,"manual Trojan link rejected on Go X: "+log_text());
let json_section={settings,section:[{".name":"jsonout",".type":"section",enabled:"1",action:"connection",outbound_jsons:[sprintf("%J",{type:"vmess",tag:"JSON VMess",server:"127.0.0.1",server_port:10086,uuid})]}]};
expect(generate(json_section,"1.14.2-rust-x.0.0.26",work+"/kept.json")!=0,"JSON VMess outbound accepted on Xrust");
expect(index(last_log_line(),"JSON outbound 'JSON VMess' uses protocol vmess, which is not included in Xrust")>=0,"unclear JSON outbound error: "+last_log_line());
expect(fs.readfile(work+"/kept.json")=="LAST_KNOWN_GOOD\n","JSON outbound failure replaced config");

// Xrust declaring outbound.trojan: Trojan nodes are kept like VLESS ones,
// the other legacy protocols are still skipped.
let trojan_core="1.14.2-rust-x.0.0.28";
write(work+"/cache/probe-subscription-1.json",{outbounds:[vless,hy2,trojan,ss,vmess,socks,chained,mixed_group,legacy_group,nested_group]});
cached=fs.readfile(work+"/cache/probe-subscription-1.json");
expect(generate(fixture,trojan_core,work+"/generated.json","1")==0,"Trojan-capable Xrust mixed subscription failed: "+log_text());
let trojan_config=json(fs.readfile(work+"/generated.json"));
expect(length(outbounds_of_type(trojan_config,["trojan"]))==1,"Trojan-capable Xrust lost the Trojan node");
expect(length(outbounds_of_type(trojan_config,["shadowsocks","vmess","socks"]))==0,"Trojan-capable Xrust generated another legacy protocol");
expect(length(outbounds_of_type(trojan_config,["vless"]))==2,"VLESS node with Trojan detour lost");
let trojan_tags=tag_set(trojan_config);
expect(trojan_tags["legacy-group"]&&trojan_tags["nested-group"],"group with a Trojan member removed");
let trojan_group=filter(trojan_config.outbounds,function(o){return o.tag=="mixed-group";})[0];
expect(trojan_group.default=="trojan-a"&&length(trojan_group.outbounds)==2,"mixed group lost its Trojan member: "+sprintf("%J",trojan_group));
let trojan_out=outbounds_of_type(trojan_config,["trojan"])[0];
expect(trojan_out.password=="pw"&&trojan_out.tls?.enabled===true&&trojan_out.tls?.server_name=="localhost"&&trojan_out.multiplex==null,"Trojan outbound shape changed: "+sprintf("%J",trojan_out));
expect(!has_log("protocol trojan is not included in Xrust")&&!has_log("detour depends on unavailable outbound 'trojan-a'"),"Trojan node reported as skipped");
for(let item in [["SS A","shadowsocks"],["VMess A","vmess"],["SOCKS A","socks"]])
 expect(has_log("skipped incompatible subscription outbound for rule 'probe': "+item[0]+" (protocol "+item[1]+" is not included in Xrust)"),trojan_core+": warning missing for "+item[0]);
expect_references_resolve(trojan_config,trojan_core);
if(rust_binary)expect(run([rust_binary,"check","-c",work+"/generated.json"])==0,trojan_core+": real Xrust check failed");
expect(fs.readfile(work+"/cache/probe-subscription-1.json")==cached,"Trojan-capable run changed subscription cache");
// The same core version without the feature (no argument) keeps refusing Trojan.
expect(generate(fixture,trojan_core,work+"/generated.json")==0,"Xrust without the feature failed: "+log_text());
expect(length(outbounds_of_type(json(fs.readfile(work+"/generated.json")),["trojan"]))==0,"Trojan generated without the outbound.trojan feature");

// URI and Clash YAML subscriptions with REALITY + uTLS Trojan nodes.
let pbk="mweeyHg5N36pJsed1hA2-TlNDkYpjU5JocLkFYIIVCI";
function normalize(raw){fs.writefile(work+"/input",raw);expect(parser.normalize_content_validated(work+"/input",work+"/output"),"normalize failed: "+raw);return json(fs.readfile(work+"/output")).outbounds;}
let uri_nodes=normalize("trojan://pw@127.0.0.1:443?security=reality&sni=www.example.com&fp=firefox&pbk="+pbk+"&sid=0123abcd&type=tcp#URI%20Trojan\n");
let clash_nodes=normalize("proxies:\n  - name: Clash Trojan\n    type: trojan\n    server: 127.0.0.1\n    port: 443\n    password: pw\n    sni: www.example.com\n    client-fingerprint: chrome\n    reality-opts:\n      public-key: "+pbk+"\n      short-id: 0123abcd\n");
expect(length(uri_nodes)==1&&length(clash_nodes)==1,"Trojan subscription nodes not parsed");
write(work+"/cache/probe-subscription-1.json",{outbounds:[uri_nodes[0],clash_nodes[0]]});
expect(generate(fixture,trojan_core,work+"/generated.json","1")==0,"Trojan-only subscription failed on Trojan-capable Xrust: "+log_text());
let parsed_trojan=outbounds_of_type(json(fs.readfile(work+"/generated.json")),["trojan"]);
expect(length(parsed_trojan)==2,"URI or Clash Trojan node lost");
for(let o in parsed_trojan){
 expect(o.tls?.enabled===true&&o.tls?.server_name=="www.example.com"&&o.tls?.utls?.enabled===true&&o.tls?.reality?.enabled===true&&o.tls?.reality?.public_key==pbk&&o.tls?.reality?.short_id=="0123abcd","Trojan subscription node lost REALITY/uTLS: "+sprintf("%J",o));
 expect(o.share_link==null&&o.remark==null&&o.multiplex==null,"internal or unexpected fields in Trojan outbound: "+sprintf("%J",o));
}
if(rust_binary)expect(run([rust_binary,"check","-c",work+"/generated.json"])==0,"real Xrust check failed for REALITY Trojan nodes");
expect(generate(fixture,"1.14.2-rust-x.0.0.27",work+"/kept.json","0")!=0,"Trojan-only subscription accepted on Xrust without the feature");
expect(index(last_log_line(),"skipped subscription outbounds with unsupported protocols: trojan (2)")>=0,"unclear error for Trojan-only subscription: "+last_log_line());
expect(fs.readfile(work+"/kept.json")=="LAST_KNOWN_GOOD\n","failed generation replaced live config");

// Manual Trojan links are accepted, keep REALITY + uTLS, and the message for
// the remaining unsupported protocols names Trojan as usable.
manual.section[0].selector_proxy_links=[
 "vless://"+uuid+"@127.0.0.1:443?security=tls&sni=localhost#VLESS%20Manual",
 "trojan://pw@127.0.0.1:443?security=tls&sni=localhost#Trojan%20Manual",
 "trojan://pw@127.0.0.1:443?security=reality&sni=www.example.com&fp=chrome&pbk="+pbk+"&sid=0123abcd&type=tcp#Trojan%20Reality"];
expect(generate(manual,trojan_core,work+"/generated.json","1")==0,"manual Trojan link rejected on Trojan-capable Xrust: "+log_text());
let manual_trojan={};
for(let o in outbounds_of_type(json(fs.readfile(work+"/generated.json")),["trojan"]))manual_trojan[o.tls?.server_name]=o;
expect(manual_trojan["localhost"]?.password=="pw"&&manual_trojan["localhost"]?.tls?.enabled===true&&manual_trojan["localhost"]?.tls?.reality==null,"manual Trojan TLS link changed: "+sprintf("%J",manual_trojan));
let reality_out=manual_trojan["www.example.com"];
expect(reality_out?.tls?.enabled===true&&reality_out.tls.server_name=="www.example.com"&&reality_out.tls.utls?.enabled===true&&reality_out.tls.utls?.fingerprint=="chrome"&&reality_out.tls.reality?.enabled===true&&reality_out.tls.reality?.public_key==pbk&&reality_out.tls.reality?.short_id=="0123abcd","manual REALITY Trojan link lost its TLS: "+sprintf("%J",reality_out));
if(rust_binary)expect(run([rust_binary,"check","-c",work+"/generated.json"])==0,"real Xrust check failed for manual Trojan links");
manual.section[0].selector_proxy_links=["ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpwdw@127.0.0.1:8388#SS%20Manual"];
expect(generate(manual,trojan_core,work+"/kept.json","1")!=0,"manual Shadowsocks link accepted on Trojan-capable Xrust");
expect(index(last_log_line(),"which is not included in Xrust; remove it or use a VLESS, Trojan or Hysteria2 connection")>=0,"unclear manual link error: "+last_log_line());
manual.section[0].selector_proxy_links=["trojan://pw@127.0.0.1:443?security=tls&sni=localhost#Trojan%20Manual"];
expect(generate(manual,"1.14.2-rust-x.0.0.27",work+"/kept.json","0")!=0,"manual Trojan link accepted on Xrust without the feature");
expect(index(last_log_line(),"manual outbound 'Trojan Manual' uses protocol trojan, which is not included in Xrust; remove it or use a VLESS or Hysteria2 connection")>=0,"old-core manual link error changed: "+last_log_line());
expect(fs.readfile(work+"/kept.json")=="LAST_KNOWN_GOOD\n","manual failure replaced config");

print("Protocol compatibility: Xrust skips unsupported subscription nodes and references, keeps the cache, fails clearly without compatible nodes, rejects manual and JSON outbounds, keeps the last good config; Xrust declaring outbound.trojan keeps Trojan nodes and links; legacy cores keep every node\n");
