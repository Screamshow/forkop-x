#!/bin/sh
# Isolated loopback traffic test on the existing OpenWrt VMware VMs.
# Default: Extended 2.7.2 + Xray 26.9.8, with explicit hybrid Reality.
# Classic: FORKOP_REALITY_CLASSIC=1, FORKOP_REALITY_PREFERENCE= and an older
# Xray binary via FORKOP_TEST_XRAY; FORKOP_TEST_SING_BOX may select native core.
set -eu
umask 077
ROOT=${FORKOP_PROTOCOL_TEST_ROOT:-/tmp/forkop-protocol-review}
SB=${FORKOP_TEST_SING_BOX:-$ROOT/sing-box-1.14.1-extended-2.7.2-linux-amd64-musl/sing-box}
XRAY=${FORKOP_TEST_XRAY:-$ROOT/xray/xray}
export FORKOP_REALITY_PREFERENCE=${FORKOP_REALITY_PREFERENCE-true}
LIB="$ROOT/lib"
LAB="$ROOT/traffic"
export FORKOP_RUNTIME_STATE_DIR="$LAB/runtime"
export TMP_SING_BOX_FOLDER="$LAB/sing-box"
export TMP_RULESET_FOLDER="$LAB/rulesets"
export TMP_SUBSCRIPTION_FOLDER="$LAB/subscriptions"
export FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$LAB/persistent"
mkdir -p "$LAB/www"
if command -v apk >/dev/null; then apk list --installed > "$LAB/packages.before";
else opkg list-installed > "$LAB/packages.before"; fi
sha256sum /etc/config/forkop > "$LAB/config.before"
/etc/init.d/forkop status > "$LAB/service.before"
/etc/init.d/forkop enabled && echo 1 > "$LAB/enabled.before" || echo 0 > "$LAB/enabled.before"
printf 'Forkop-Reality-xHTTP-OK\n' > "$LAB/www/index.html"
chmod -R a+rX "$LAB/www"
"$SB" generate tls-keypair example.test > "$LAB/tls-keypair.txt"
"$XRAY" x25519 > "$LAB/reality-keypair.txt"
cat > "$LAB/build.uc" <<'EOF'
let fs=require("fs");
let root=ARGV[0];
let keys=fs.readfile(root+"/reality-keypair.txt");
function key(label) {
    for(let line in split(keys,"\n"))
        if(substr(line,0,length(label))==label) return trim(substr(line,length(label)));
    die("missing test key");
}
let private_key=key(index(keys,"PrivateKey:") >= 0 ? "PrivateKey:" : "Private key:");
let public_key=key(index(keys,"Password (PublicKey):") >= 0 ? "Password (PublicKey):" : "Public key:");
let pem=fs.readfile(root+"/tls-keypair.txt");
function block(label) {
    let begin="-----BEGIN "+label+"-----";
    let end="-----END "+label+"-----";
    let a=index(pem,begin),b=index(pem,end);
    if(a<0||b<0) die("missing test certificate");
    return substr(pem,a,b+length(end)-a);
}
function write(name,value) {fs.writefile(root+"/"+name,sprintf("%J",value));}
let uuid="00000000-0000-4000-8000-000000000001";
let profile=getenv("FORKOP_XHTTP_PROFILE") || "v1";
let extra_settings=profile=="v2" ? {
    uplinkHTTPMethod:"GET",sessionPlacement:"query",sessionKey:"auth",seqPlacement:"query",seqKey:"offset",
    uplinkDataPlacement:"body",uplinkChunkSize:"65536-65536",sessionIDLength:"16-32",
    xPaddingBytes:"100-1000",scMaxBufferedPosts:9,scMaxEachPostBytes:65536,
    scMinPostsIntervalMs:"60-75",scStreamUpServerSecs:"75-210"
} : {
    uplinkHTTPMethod:"GET",sessionPlacement:"header",sessionKey:"X-Probe-Session",
    seqPlacement:"cookie",seqKey:"part_index",uplinkDataPlacement:"header",uplinkDataKey:"X-Media-Data",
    xPaddingBytes:"96-1040",xPaddingObfsMode:true,xPaddingKey:"_t",xPaddingHeader:"X-Media-Token",
    xPaddingPlacement:"queryInHeader",xPaddingMethod:"tokenish",sessionIDTable:"Base62",
    sessionIDLength:"16-32",uplinkChunkSize:0,scMaxEachPostBytes:32768,scMaxBufferedPosts:9
};
extra_settings.sessionIDPlacement=extra_settings.sessionPlacement;
extra_settings.sessionIDKey=extra_settings.sessionKey;
write("destination.json",{log:{level:"debug"},inbounds:[{type:"http",listen:"127.0.0.1",listen_port:18443,
    tls:{enabled:true,certificate:[block("CERTIFICATE")],key:[block("PRIVATE KEY")]}}],outbounds:[{type:"direct"}]});
let classic=getenv("FORKOP_REALITY_CLASSIC")=="1";
let direct={protocol:"freedom",tag:"direct"};
if(!classic) direct.settings={finalRules:[{action:"allow",ip:["127.0.0.1"],port:18090}]};
write("server.json",{log:{loglevel:"debug"},inbounds:[{listen:"127.0.0.1",port:19443,protocol:"vless",
    settings:{clients:[{id:uuid}],decryption:"none"},streamSettings:{network:classic?"tcp":"xhttp",security:"reality",
        realitySettings:{show:true,target:"127.0.0.1:18443",serverNames:["example.test"],privateKey:private_key,shortIds:["0123456789abcdef"]},
        xhttpSettings:{path:"/probe",mode:"packet-up",extra:extra_settings}}}],outbounds:[direct]});
let extra="";let extra_json=sprintf("%J",extra_settings);
for(let i=0;i<length(extra_json);i++)extra+=sprintf("%%%02X",ord(substr(extra_json,i,1)));
let link="vless://"+uuid+"@127.0.0.1:19443?encryption=none&type=xhttp&mode=packet-up&security=reality&pbk="+
    public_key+"&sid=0123456789abcdef&sni=example.test&fp=chrome&path=%2Fprobe&extra="+extra;
if(classic) link=replace(link,"type=xhttp","type=tcp");
let reality_preference = getenv("FORKOP_REALITY_PREFERENCE") || "";
if (reality_preference == "true" || reality_preference == "false")
    link += "&support_x25519mlkem768=" + reality_preference;
write("fixture.json",{settings:{".name":"settings",".type":"settings",dns_server:"1.1.1.1"},section:[{
    ".name":"probe",".type":"section",enabled:"1",action:"connection",selector_proxy_links:[link]}]});
EOF
ucode "$LAB/build.uc" "$LAB"
FORKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/xrust/generator.uc" generate-config-fixture \
    "$LAB/fixture.json" "$LAB/generated.json" 127.0.0.1 0 1 '' 1.14.1-extended-2.7.2
cat > "$LAB/client.uc" <<'EOF'
let fs=require("fs");let root=ARGV[0];let c=json(fs.readfile(root+"/generated.json"));
let outbound;
for(let o in c.outbounds) if(o.type=="vless") outbound=o;
let preference=getenv("FORKOP_REALITY_PREFERENCE") || "";
if(outbound==null) die("VLESS outbound missing");
if(preference=="") {
    if(exists(outbound.tls.reality,"support_x25519mlkem768")) die("Reality preference was forced");
}
else if(outbound.tls.reality.support_x25519mlkem768!==(preference=="true")) die("Explicit Reality preference changed");
if(getenv("FORKOP_REALITY_CLASSIC")!="1" && (outbound.transport.uplink_http_method!="GET"||
    outbound.transport.seq_key!=(getenv("FORKOP_XHTTP_PROFILE")=="v2"?"offset":"part_index")||
    outbound.transport.sc_max_buffered_posts!=9)) die("generated fields missing");
outbound.tag="proxy";
fs.writefile(root+"/client.json",sprintf("%J",{log:{level:"debug"},inbounds:[{type:"socks",listen:"127.0.0.1",listen_port:19444}],
    outbounds:[outbound],route:{final:"proxy"}}));
EOF
ucode "$LAB/client.uc" "$LAB"
"$SB" check -c "$LAB/destination.json"
"$SB" check -c "$LAB/client.json"
"$XRAY" run -test -config "$LAB/server.json" > "$LAB/server-check.log" 2>&1
PIDS=""
cleanup() { for pid in $PIDS; do kill "$pid" 2>/dev/null || true; done; for pid in $PIDS; do wait "$pid" 2>/dev/null || true; done; PIDS=""; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
uhttpd -f -p 127.0.0.1:18090 -h "$LAB/www" > "$LAB/http.log" 2>&1 & PIDS="$PIDS $!"
"$SB" run -c "$LAB/destination.json" > "$LAB/destination.log" 2>&1 & PIDS="$PIDS $!"
"$XRAY" run -config "$LAB/server.json" > "$LAB/server.log" 2>&1 & PIDS="$PIDS $!"
"$SB" run -c "$LAB/client.json" > "$LAB/client.log" 2>&1 & PIDS="$PIDS $!"
sleep 2
for pid in $PIDS; do kill -0 "$pid"; done
curl -fsS --max-time 20 --noproxy '' --socks5-hostname 127.0.0.1:19444 http://127.0.0.1:18090/ > "$LAB/result.txt"
grep -q '^Forkop-Reality-xHTTP-OK$' "$LAB/result.txt"
if [ "${FORKOP_REALITY_PREFERENCE:-}" = true ] && [ "${FORKOP_REALITY_CLASSIC:-}" != 1 ]; then
    grep -q 'is using X25519MLKEM768.*true' "$LAB/server.log"
fi
cleanup
if command -v apk >/dev/null; then apk list --installed > "$LAB/packages.after";
else opkg list-installed > "$LAB/packages.after"; fi
sha256sum /etc/config/forkop > "$LAB/config.after"
/etc/init.d/forkop status > "$LAB/service.after"
/etc/init.d/forkop enabled && echo 1 > "$LAB/enabled.after" || echo 0 > "$LAB/enabled.after"
for state in packages config service enabled; do cmp "$LAB/$state.before" "$LAB/$state.after"; done
echo "Reality traffic passed (classic=${FORKOP_REALITY_CLASSIC:-0}, preference=${FORKOP_REALITY_PREFERENCE:-unspecified}, profile=${FORKOP_XHTTP_PROFILE:-v1}); original VM state unchanged"
