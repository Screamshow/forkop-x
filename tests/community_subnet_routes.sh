#!/bin/sh
set -eu
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cat >"$WORK_DIR/fixture.json" <<'JSON'
{"settings":{"dns_server":"1.1.1.1"},"section":[{".name":"voice",".type":"section","enabled":"1","action":"vpn","interface":"wg0","community_lists":["discord","telegram"],"source_ip_cidr":["192.168.1.10/32"],"excluded_source_ip_cidr":["192.168.1.11/32"],"ports":["3478","443-443","19294-19344"]}]}
JSON
mkdir -p "$WORK_DIR/config.json.rulesets"
ucode -L "$FORKOP_LIB" -e '
let fs = require("fs"); let ip = require("core.ip");
let rules = ip.community_subnet_rules("discord", "#comment\n162.158.0.0/15\n2606:4700::/32\n66.22.192.0/18\ninvalid\n");
if (length(rules) != 3 || rules[1].network != "udp" || rules[2].network != "tcp") die("Discord subnet split failed\n");
if (sprintf("%J", rules[2].port_range) != sprintf("%J", ["443:443","1080:1080","2053:2053","2083:2083","2087:2087","2096:2096","8443:8443"])) die("media ports mismatch\n");
if (index(rules[1].port_range, "443:443") < 0 || index(rules[1].port_range, "3478:3478") < 0) die("voice ports missing\n");
let regular = ip.community_subnet_rules("telegram", "149.154.160.0/20\n");
if (regular[0].network != null) die("ordinary subnet unexpectedly UDP-only\n");
push(rules, regular[0]);
fs.writefile(ARGV[0], sprintf("%J", {version:3,rules}));
' "$WORK_DIR/config.json.rulesets/voice-community-subnets-lists-ruleset.json"
ucode -L "$FORKOP_LIB" "$FORKOP_LIB/xrust/generator.uc" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$WORK_DIR/config.json" "127.0.0.1" "0" "1" "" "1.12.22"
ucode -e '
let fs=require("fs"); let c=json(fs.readfile(ARGV[0])); let found=false;
for (let r in c.route.rules) {
  if (r.type != "logical") continue;
  let base=r.rules[0];
  let tags=type(base.rule_set)=="array" ? base.rule_set : [base.rule_set];
  if (index(tags,"voice-community-subnets-lists-ruleset") < 0) continue;
  if (r.outbound != "voice-out" || base.source_ip_cidr[0] != "192.168.1.10/32") die("section scope lost\n");
  assert(sprintf("%J", base.port) == sprintf("%J", [3478,443]) &&
    sprintf("%J", base.port_range) == sprintf("%J", ["19294:19344"]),
    "equal endpoints must emit a single numeric port");
  if (!r.rules[1].invert) die("excluded source lost\n");
  found=true;
}
if (!found) die("materialized community subnets not routed\n");
// Replace remote domain lists for offline Xrust schema validation.
for (let i,r in c.route.rule_set) if(r.type=="remote") c.route.rule_set[i]={type:"inline",tag:r.tag,rules:[{domain_suffix:["discord.com"]}]};
fs.writefile(ARGV[1],sprintf("%J",c));
' "$WORK_DIR/config.json" "$WORK_DIR/check.json"
"${XRUST_BIN:-xrust}" check -c "$WORK_DIR/check.json"
# Missing, empty and corrupt downloaded lists must fail instead of using
# hardcoded Discord/Cloudflare ranges.
rm "$WORK_DIR/config.json.rulesets/voice-community-subnets-lists-ruleset.json"
for state in missing empty invalid; do
  case "$state" in
    empty) printf '{"version":3,"rules":[]}' > "$WORK_DIR/config.json.rulesets/voice-community-subnets-lists-ruleset.json" ;;
    invalid) printf 'invalid' > "$WORK_DIR/config.json.rulesets/voice-community-subnets-lists-ruleset.json" ;;
  esac
  if ucode -L "$FORKOP_LIB" "$FORKOP_LIB/xrust/generator.uc" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$WORK_DIR/config.json" "127.0.0.1" "0" "1" "" "1.12.22" > "$WORK_DIR/error.log" 2>&1; then
    echo "FAIL: $state Discord subnets accepted" >&2
    exit 1
  fi
  grep -Eq 'subnet ruleset.*(missing|empty|invalid)' "$WORK_DIR/error.log"
done
printf 'Community subnet routing checks passed\n'

# Rebuild from a checked cached source generation, without network or active
# nft mutations. This exercises the updater and managed-file cache lifecycle.
(
mkdir -p "$WORK_DIR/cache" "$WORK_DIR/runtime" "$WORK_DIR/bin"
cat >"$WORK_DIR/uci.state" <<'UCI'
forkop.settings=settings
forkop.voice=section
forkop.voice.enabled=1
forkop.voice.action=vpn
forkop.voice.interface=wg0
forkop.voice.community_lists=discord
UCI
export SUBNETS_DISCORD=https://fixture.test/discord4.lst
export SUBNETS_DISCORD6=https://fixture.test/discord6.lst
export FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export FORKOP_LIB TMP_RULESET_FOLDER="$WORK_DIR/runtime"
export FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/state"
export FORKOP_PERSISTENT_LIST_CACHE_DIR="$WORK_DIR/cache"
export FORKOP_RUNTIME_LIST_GENERATION_DIR="$WORK_DIR/generation"
export FORKOP_LIST_CACHE_LOG_STATE_FILE="$WORK_DIR/cache-log-state"
export FORKOP_LIST_SRS_VALIDATION_DIR="$WORK_DIR/srs-validation"
export FORKOP_NFT_BATCH_FILE="$WORK_DIR/candidate.nft"
export PATH="$WORK_DIR/bin:$PATH"
printf '#!/bin/sh\nexit 99\n' >"$WORK_DIR/bin/curl"
chmod +x "$WORK_DIR/bin/curl"
printf '162.158.0.0/15\n66.22.192.0/18\n' >"$WORK_DIR/cache/source-1"
printf '2606:4700::/32\n' >"$WORK_DIR/cache/source-2"
signature=$(ucode -L "$FORKOP_LIB" "$FORKOP_LIB/service/state.uc" list-update-signature)
ucode -e '
let fs=require("fs"); let files=[];
for(let n=1;n<=2;n++) {
 let p=ARGV[0]+"/source-"+n; let pipe=fs.popen("md5sum "+p,"r"); let md5=split(trim(pipe.read("all"))," ")[0]; pipe.close();
 push(files,{name:"source-"+n,kind:"source",size:fs.stat(p).size,md5,url:ARGV[n+1],source_format:"plain"});
}
fs.writefile(ARGV[0]+"/manifest.json",sprintf("%J",{format:"2",generation:"gen-fixture",signature:ARGV[1],files}));
' "$WORK_DIR/cache" "$signature" "$SUBNETS_DISCORD" "$SUBNETS_DISCORD6"
ucode -L "$FORKOP_LIB" "$FORKOP_LIB/components/updates.uc" apply-list-cache
ucode -e '
let fs=require("fs"); let c=json(fs.readfile(ARGV[0]));
if(length(c.rules)!=5 || c.rules[1].network!="udp" || c.rules[2].network!="tcp" || c.rules[3].network!="udp" || c.rules[4].network!="tcp") die("cached Discord source not materialized\n");
' "$WORK_DIR/runtime/voice-community-subnets-lists-ruleset.json"
grep -Fq '162.158.0.0/15 . 3478' "$WORK_DIR/candidate.nft"
grep -Fq '2606:4700::/32 . 443' "$WORK_DIR/candidate.nft"
grep -Eq 'voice_tcp_ip_ports.*162\.158\.0\.0/15 \. 8443' "$WORK_DIR/candidate.nft"
grep -Eq 'voice_tcp_ip6_ports.*2606:4700::/32 \. 2053' "$WORK_DIR/candidate.nft"
printf 'Community cached-source materialization checks passed\n'
)
