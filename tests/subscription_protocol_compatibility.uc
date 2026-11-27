// ucode -L LIB tests/subscription_protocol_compatibility.uc WORK LIB [RUST_X_BINARY]
// Xrust is built without vmess, shadowsocks and socks outbounds, and only
// builds declaring the outbound.trojan feature include the Trojan client.
let fs=require("fs"), parser=require("subscription.parser"), work=ARGV[0], lib=ARGV[1], rust_binary=ARGV[2];
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

let settings={".name":"settings",".type":"settings",dns_server:"1.1.1.1"};
let subscription_section={".name":"probe",".type":"section",enabled:"1",action:"connection",subscription_urls:["https://feed.example/test"],subscription_url_settings:'{"https://feed.example/test":{"user_agent":"Happ"}}'};
for(let suffix in ["url","user_agent","hwid"])
 fs.writefile(work+"/cache/probe-subscription-1."+suffix,suffix=="url"?"https://feed.example/test":suffix=="user_agent"?"Happ":"");
// supports_trojan is the generator argument runtime.uc derives from Features.
function generate(fixture,version,output,supports_trojan,xray_features){
 write(work+"/fixture.json",fixture);
 let args=["env","TMP_SUBSCRIPTION_FOLDER="+work+"/cache","FORKOP_RUNTIME_STATE_DIR="+work+"/state","TMP_SING_BOX_FOLDER="+work+"/singbox","FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="+work+"/persistent","FORKOP_LIB="+lib,"ucode","-L",lib,lib+"/xrust/generator.uc","generate-config-fixture",work+"/fixture.json",output,"127.0.0.1","0","1","",version,supports_trojan||"","0","0",xray_features||""];
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
for(let profile in [{version:"0.0.26",binary:rust_binary}]){
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

expect(generate(fixture,"1.14.2-x-1.0.4",work+"/generated.json")!=0 &&
    has_log("the installed client must be Xrust"), "Go client unexpectedly accepted by 3.x generator");

// No compatible node: explicit error, no Direct fallback, previous config kept.
write(work+"/cache/probe-subscription-1.json",{outbounds:[trojan,ss,legacy_group]});
fs.writefile(work+"/kept.json","LAST_KNOWN_GOOD\n");
expect(generate(fixture,"0.0.26",work+"/kept.json")!=0,"subscription without compatible nodes must fail");
expect(index(last_log_line(),"connection section 'probe' has no outbounds compatible with Xrust; skipped subscription outbounds with unsupported protocols: shadowsocks (1), trojan (1)")>=0,"unclear error for subscription without compatible nodes: "+last_log_line());
expect(fs.readfile(work+"/kept.json")=="LAST_KNOWN_GOOD\n","failed generation replaced live config");

// Manual links and JSON outbounds with unsupported protocols are rejected explicitly.
let manual={settings,section:[{".name":"manual",".type":"section",enabled:"1",action:"connection",selector_proxy_links:[
 "vless://"+uuid+"@127.0.0.1:443?security=tls&sni=localhost#VLESS%20Manual",
 "trojan://pw@127.0.0.1:443?security=tls&sni=localhost#Trojan%20Manual"]}]};
expect(generate(manual,"0.0.26",work+"/kept.json")!=0,"manual Trojan link accepted on Xrust without the feature");
expect(index(last_log_line(),"manual outbound 'Trojan Manual' uses protocol trojan, which is not included in Xrust")>=0,"unclear manual link error: "+last_log_line());
expect(fs.readfile(work+"/kept.json")=="LAST_KNOWN_GOOD\n","manual failure replaced config");
for(let link in ["ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpwdw@127.0.0.1:8388#SS%20Manual","socks5://127.0.0.1:1080#SOCKS%20Manual"]){
 manual.section[0].selector_proxy_links=[link];
 expect(generate(manual,"0.0.26",work+"/kept.json")!=0,"manual link accepted on Xrust: "+link);
 expect(index(last_log_line(),"is not included in Xrust")>=0,"unclear manual link error: "+last_log_line());
}
let json_section={settings,section:[{".name":"jsonout",".type":"section",enabled:"1",action:"connection",outbound_jsons:[sprintf("%J",{type:"vmess",tag:"JSON VMess",server:"127.0.0.1",server_port:10086,uuid})]}]};
expect(generate(json_section,"0.0.26",work+"/kept.json")!=0,"JSON VMess outbound accepted on Xrust");
expect(index(last_log_line(),"JSON outbound 'JSON VMess' uses protocol vmess, which is not included in Xrust")>=0,"unclear JSON outbound error: "+last_log_line());
expect(fs.readfile(work+"/kept.json")=="LAST_KNOWN_GOOD\n","JSON outbound failure replaced config");

// Xrust declaring outbound.trojan: Trojan nodes are kept like VLESS ones,
// the other legacy protocols are still skipped.
let trojan_core="0.0.28";
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
expect(generate(fixture,"0.0.27",work+"/kept.json","0")!=0,"Trojan-only subscription accepted on Xrust without the feature");
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
manual.section[0].selector_proxy_links=["trojan://pw@127.0.0.1:443?sni=localhost#Trojan%20Default"];
expect(generate(manual,trojan_core,work+"/generated.json","1")==0,"manual Trojan link without security rejected: "+log_text());
let default_tls=outbounds_of_type(json(fs.readfile(work+"/generated.json")),["trojan"])[0];
expect(default_tls?.tls?.enabled===true&&default_tls.tls.server_name=="localhost","manual Trojan link without security must default to TLS like subscriptions: "+sprintf("%J",default_tls));

let trojan_literal = "trojan://qa+one%2Btwo@127.0.0.1:443?sni=localhost#Literal";
let trojan_escaped = "trojan://qa%2Bone%2Btwo@127.0.0.1:8443?sni=localhost#Escaped";
let trojan_links = [trojan_literal, trojan_escaped];
let auth_nodes = normalize(join("\n", trojan_links) + "\n");
expect(length(auth_nodes) == 2 && auth_nodes[0].password == "qa+one+two" &&
    auth_nodes[1].password == "qa+one+two", "Trojan passwords in subscriptions must preserve plus");
let cached_trojan = { ...auth_nodes[0], password: "qa one+two", share_link: trojan_literal };
let changed_trojan = { ...cached_trojan, password: "another password" };
parser.repair_cached_outbounds([cached_trojan, changed_trojan]);
expect(cached_trojan.password == "qa+one+two" && changed_trojan.password == "another password",
    "repair a legacy Trojan password without replacing a different credential");
manual.section[0].selector_proxy_links = trojan_links;
expect(generate(manual, trojan_core, work+"/generated.json", "1") == 0, "manual Trojan password fixture failed");
let auth_manual = outbounds_of_type(json(fs.readfile(work+"/generated.json")), ["trojan"]);
expect(length(auth_manual) == 2 && auth_manual[0].password == "qa+one+two" &&
    auth_manual[1].password == "qa+one+two", "manually imported Trojan passwords must preserve plus");

let xray_features = "transport.xhttp.split,transport.grpc.multi,tls.xray-pins,tls.verify-name";
let vless_base = "vless://" + uuid + "@127.0.0.1:8443?";
let download = { address: "127.0.0.2", port: 9443, network: "xhttp", security: "tls",
    tlsSettings: { serverName: "front.example", verifyPeerCertByName: "cert.example" },
    xhttpSettings: { path: "/download", host: "get.example",
        extra: { xPaddingBytes: "300-400", headers: { "X-Download": "yes" }, xmux: { hKeepAlivePeriod: -1 } } } };
let extra = replace(sprintf("%J", { xPaddingBytes: "100-200", downloadSettings: download }), /./g,
    function(c) { return sprintf("%%%02X", ord(c)); });
let ws_default = vless_base + "type=ws&security=none&host=ws.example#ws-default";
let clear_split = vless_base + "type=xhttp&path=%2Fupload&extra=" + extra + "#xhttp-split";
let grpc_multi = "trojan://pw@127.0.0.1:8443?type=grpc&peer=localhost&serviceName=%2Fsvc%2Fmany&mode=multi#grpc-multi";
let pinned_tls = vless_base + "security=tls&sni=localhost&pcs=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef#xray-pin";
let split = normalize(clear_split)[0];
expect(split.tls == null && split.transport.x_padding_bytes == "100-200", "XHTTP uplink must keep cleartext and its own padding");
let inferred_tls = normalize(vless_base + "type=xhttp&sni=front.example&path=%2Fupload#tls-hint")[0];
expect(inferred_tls.tls?.server_name == "front.example", "an explicit XHTTP uplink TLS hint must survive");
let secondary = split.transport.download_settings;
expect(secondary?.server == "127.0.0.2" && secondary.server_port == 9443 && secondary.transport.path == "/download" &&
    secondary.transport.host == "get.example" && secondary.transport.x_padding_bytes == "300-400" &&
    secondary.transport.headers["X-Download"] == "yes" && secondary.transport.xmux.h_keep_alive_period == -1 &&
    secondary.tls.server_name == "front.example" && secondary.tls.verify_server_name[0] == "cert.example", "XHTTP download settings were lost");
let link_serializer = require("subscription.share_link");
let exported_split = normalize(link_serializer.serialize_outbound_link(split))[0];
expect(exported_split.transport.download_settings?.server == "127.0.0.2" &&
    exported_split.transport.download_settings.transport.headers["X-Download"] == "yes" &&
    exported_split.transport.download_settings.transport.xmux.h_keep_alive_period == -1 &&
    exported_split.transport.download_settings.tls.verify_server_name[0] == "cert.example", "XHTTP split export roundtrip");
let legacy_download = { ...download, xhttpSettings: { ...download.xhttpSettings,
    headers: { "X-Download": "legacy" }, extra: { xPaddingBytes: "300-400" } } };
let legacy_extra = replace(sprintf("%J", { downloadSettings: legacy_download }), /./g,
    function(c) { return sprintf("%%%02X", ord(c)); });
let legacy_split = normalize(vless_base + "type=xhttp&extra=" + legacy_extra)[0];
expect(legacy_split.transport.download_settings.transport.headers["X-Download"] == "legacy",
    "old Forkop split share links retain download headers beside extra");
let cached_split = { ...split, share_link: clear_split, transport: { ...split.transport, x_padding_bytes: "9-12" } };
delete cached_split.transport.download_settings;
parser.repair_cached_outbounds([cached_split]);
expect(cached_split.transport.download_settings?.server == "127.0.0.2" &&
    cached_split.transport.x_padding_bytes == "9-12", "cached XHTTP repair overwrote an existing uplink option");
let grpc = normalize(grpc_multi)[0];
expect(grpc.transport.multi_mode === true && grpc.tls.server_name == "localhost", "gRPC multi URI and Trojan peer");
expect(normalize(link_serializer.serialize_outbound_link(grpc))[0].transport.multi_mode === true, "export gRPC multi mode");
manual.section[0].selector_proxy_links = [ws_default, clear_split, grpc_multi, pinned_tls];
expect(generate(manual, trojan_core, work+"/generated.json", "1", xray_features) == 0, "Xray extensions manual fixture failed: " + log_text());
let configured = json(fs.readfile(work+"/generated.json")).outbounds;
let ws = filter(configured, node => node.transport?.type == "ws")[0];
let xhttp = filter(configured, node => node.transport?.type == "xhttp")[0];
let grpc_out = filter(configured, node => node.transport?.type == "grpc")[0];
expect(ws?.transport.path == "/", "manually imported WS should default its path to /");
expect(xhttp?.transport.download_settings?.tls?.verify_server_name[0] == "cert.example", "manual XHTTP split download lost verification name");
expect(grpc_out?.transport.multi_mode === true && grpc_out.tls.server_name == "localhost", "manual Trojan peer or gRPC multi lost");
expect(length(filter(configured, node => length(node.tls?.xray_pinned_peer_cert_sha256 || []) == 1)) == 1,
    "Xray pin missing from the generated TLS configuration");
let xray_binary = getenv("XRUST_XRAY_BINARY");
if (xray_binary)
    expect(run([xray_binary, "check", "-c", work+"/generated.json"]) == 0, "Xrust rejected extended Xray options");
expect(generate(manual, trojan_core, work+"/kept.json", "1") != 0 &&
    index(last_log_line(), "separate XHTTP download connection") >= 0, "old core silently accepted XHTTP split");

let quic_params = {congestion: "reno", keepAlivePeriod: 7, disableGSO: true};
let h3_fm = replace(sprintf("%J", {quicParams: quic_params}), /./g,
    function(c) { return sprintf("%%%02X", ord(c)); });
let h3_uri = vless_base + "type=xhttp&security=tls&sni=front.example&alpn=h3&fm=" + h3_fm + "#XHTTP-H3";
let h3_mixed_uri = replace(h3_uri, "alpn=h3", "alpn=h3%2Ch2");
let h3 = normalize(h3_uri)[0];
expect(length(h3.tls.alpn) == 1 && h3.tls.alpn[0] == "h3", "XHTTP URI must preserve sole h3 ALPN");
expect(h3.transport.quic_params.congestion == "reno" && h3.transport.quic_params.keep_alive_period == 7 &&
    h3.transport.quic_params.disable_gso === true, "XHTTP URI lost finalmask.quicParams");
expect(normalize(h3_mixed_uri)[0].transport.quic_params == null, "H2 URI should ignore H3-only QUIC parameters");
delete h3.share_link;
let h3_export = normalize(link_serializer.serialize_outbound_link(h3))[0];
expect(length(h3_export.tls.alpn) == 1 && h3_export.tls.alpn[0] == "h3", "XHTTP URI export preserves h3");
expect(h3_export.transport.quic_params.keep_alive_period == 7, "XHTTP URI export lost QUIC parameters");
let cached_h3 = { ...h3, share_link: h3_uri, transport: { ...h3.transport } };
delete cached_h3.transport.quic_params;
let cached_h2 = { ...cached_h3, tls: { ...h3.tls, alpn: ["h2"] }, transport: { ...cached_h3.transport } };
parser.repair_cached_outbounds([cached_h3, cached_h2]);
expect(cached_h3.transport.quic_params.keep_alive_period == 7 && cached_h2.transport.quic_params == null,
    "cached QUIC parameters should be restored only for a matching H3 profile");
let h3_json = normalize(sprintf("%J", {outbounds: [{protocol: "vless", tag: "h3-json",
    settings: {vnext: [{address: "127.0.0.1", port: 9443, users: [{id: uuid, encryption: "none"}]}]},
    streamSettings: {network: "xhttp", security: "tls", tlsSettings: {serverName: "front.example", alpn: ["h3"]},
        finalmask: {quicParams: quic_params}, xhttpSettings: {mode: "stream-one", path: "/json"}}}]}))[0];
expect(length(h3_json.tls.alpn) == 1 && h3_json.tls.alpn[0] == "h3", "Xray JSON preserves sole h3 ALPN");
expect(h3_json.transport.quic_params.disable_gso === true, "Xray JSON lost QUIC parameters");
let h3_download = { ...download, tlsSettings: { ...download.tlsSettings, alpn: ["h3"] },
    finalmask: {quicParams: {congestion: "reno", maxIdleTimeout: 19}} };
let h3_extra = replace(sprintf("%J", { downloadSettings: h3_download }), /./g,
    function(c) { return sprintf("%%%02X", ord(c)); });
let h3_split = vless_base + "type=xhttp&path=%2Fuplink&extra=" + h3_extra + "#XHTTP-H3-download";
let h3_split_node = normalize(h3_split)[0];
delete h3_split_node.share_link;
let h3_split_export = normalize(link_serializer.serialize_outbound_link(h3_split_node))[0];
expect(h3_split_export.transport.download_settings.tls.alpn[0] == "h3", "XHTTP split export preserves download h3");
expect(h3_split_export.transport.download_settings.transport.quic_params.max_idle_timeout == 19,
    "XHTTP split export lost independent download QUIC parameters");
let h3_features = xray_features + ",transport.xhttp.http3";
manual.section[0].selector_proxy_links = [h3_uri, h3_split];
expect(generate(manual, trojan_core, work+"/generated.json", "1", h3_features) == 0, "manual h3 fixture failed");
let h3_nodes = outbounds_of_type(json(fs.readfile(work+"/generated.json")), ["vless"]);
expect(length(h3_nodes) == 2 && length(filter(h3_nodes, node => (node.tls?.alpn || [])[0] == "h3")) == 1 &&
    length(filter(h3_nodes, node => (node.transport?.download_settings?.tls?.alpn || [])[0] == "h3")) == 1,
    "manual XHTTP lost h3 on the uplink or download");
expect(length(filter(h3_nodes, node => node.transport?.quic_params?.keep_alive_period == 7)) == 1 &&
    length(filter(h3_nodes, node => node.transport?.download_settings?.transport?.quic_params?.max_idle_timeout == 19)) == 1,
    "manual XHTTP lost the uplink or download QUIC parameters");
if (xray_binary)
    expect(run([xray_binary, "check", "-c", work+"/generated.json"]) == 0, "Xrust rejected XHTTP QUIC parameters");
for (let pair in [[h3_uri, "requires XHTTP over HTTP/3"], [h3_split, "requires HTTP/3 on the XHTTP download connection"]]) {
    manual.section[0].selector_proxy_links = [pair[0]];
    expect(generate(manual, trojan_core, work+"/kept.json", "1", xray_features) != 0 &&
        index(last_log_line(), pair[1]) >= 0, "old core accepted a required h3 endpoint: " + last_log_line());
}
let h3_mask = replace(sprintf("%J", {udp: [{type: "salamander", settings: {}}]}), /./g,
    function(c) { return sprintf("%%%02X", ord(c)); });
let h3_hop = replace(sprintf("%J", {quicParams: {udpHop: {ports: "10000-11000"}}}), /./g,
    function(c) { return sprintf("%%%02X", ord(c)); });
for (let pair in [[h3_mask, "requires unsupported XHTTP HTTP/3 UDP masks"],
                   [h3_hop, "requires unsupported XHTTP HTTP/3 UDP port hopping"],
                   ["%7B%21", "has invalid XHTTP HTTP/3 finalmask settings"]]) {
    manual.section[0].selector_proxy_links = [replace(h3_uri, h3_fm, pair[0])];
    expect(generate(manual, trojan_core, work+"/kept.json", "1", h3_features) != 0 &&
        index(last_log_line(), pair[1]) >= 0, "not reported as unsupported: " + last_log_line());
}

manual.section[0].selector_proxy_links = [h3_mixed_uri];
expect(generate(manual, trojan_core, work+"/generated.json", "1", xray_features) == 0,
    "mixed ALPN should not require the XHTTP h3 feature");
h3_json.tls.alpn = "h3";
write(work+"/cache/probe-subscription-1.json", { outbounds: [vless, h3_json] });
expect(generate(fixture, trojan_core, work+"/generated.json", "1", xray_features) == 0 &&
    has_log("requires XHTTP over HTTP/3"), "older core should skip a required h3 subscription outbound");
let old_h3_nodes = outbounds_of_type(json(fs.readfile(work+"/generated.json")), ["vless"]);
expect(length(old_h3_nodes) == 1 && old_h3_nodes[0].transport == null, "non-XHTTP node should survive older-core filtering");

for (let link in [grpc_multi, replace(grpc_multi, "%2Fsvc%2Fmany", "svc")]) {
    manual.section[0].selector_proxy_links = [link];
    expect(generate(manual, trojan_core, work+"/kept.json", "1") != 0 &&
        index(last_log_line(), "requires gRPC multi mode") >= 0, "old core silently changed gRPC multi to Tun");
}

manual.section[0].selector_proxy_links=["ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpwdw@127.0.0.1:8388#SS%20Manual"];
expect(generate(manual,trojan_core,work+"/kept.json","1")!=0,"manual Shadowsocks link accepted on Trojan-capable Xrust");
expect(index(last_log_line(),"which is not included in Xrust; remove it or use a VLESS, Trojan or Hysteria2 connection")>=0,"unclear manual link error: "+last_log_line());
manual.section[0].selector_proxy_links=["trojan://pw@127.0.0.1:443?security=tls&sni=localhost#Trojan%20Manual"];
expect(generate(manual,"0.0.27",work+"/kept.json","0")!=0,"manual Trojan link accepted on Xrust without the feature");
expect(index(last_log_line(),"manual outbound 'Trojan Manual' uses protocol trojan, which is not included in Xrust; remove it or use a VLESS or Hysteria2 connection")>=0,"old-core manual link error changed: "+last_log_line());
expect(fs.readfile(work+"/kept.json")=="LAST_KNOWN_GOOD\n","manual failure replaced config");

print("Xrust protocol compatibility: legacy core rejected; unsupported nodes and references skipped; advertised Trojan and Xray features retained; last-good config and cache kept\n");
