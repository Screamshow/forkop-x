#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/ubus" <<'SH'
#!/bin/sh
cat "$TEST_PROVIDER_INTERFACES"
SH
chmod +x "$WORK/ubus"
export PATH="$WORK:$PATH"
export TEST_PROVIDER_INTERFACES="$WORK/interfaces.json"
printf '%s\n' '{"interface":[]}' > "$TEST_PROVIDER_INTERFACES"
printf '%s\n' '{"settings":{"dns_use_provider":"1","config_path":"/tmp/sing-box/config.json"},"section":[{".name":"direct","enabled":"1","action":"bypass","domain_suffix":["example.org"]}]}' > "$WORK/fixture.json"
LIB="$ROOT/forkop/files/usr/lib"
generate() {
    ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture \
        "$WORK/fixture.json" "$WORK/generated.json" 127.0.0.1 0 1 "" 1.14.2
}
status=0
generate > "$WORK/generator.log" 2>&1 || status=$?
if [ "$status" -ne 75 ]; then
    cat "$WORK/generator.log" >&2
    exit 1
fi
printf '%s\n' '{"interface":[{"interface":"fixture_wan","l3_device":"eth1","up":true,"route":[{"target":"0.0.0.0","mask":0}],"dns-server":["192.0.2.53"]}]}' > "$TEST_PROVIDER_INTERFACES"
generate
grep -Fq '192.0.2.53' "$WORK/generated.json"
{
cat <<'UC'
let permanent_start_failure=false,startup_config_fingerprint='';
let config_status=75, cleared=0;
let runtime_constants=require('singbox.constants');
const NFT_UC='nft',STATE_UC='state',SUBSCRIPTION_CACHE_UC='cache',UPDATES_UC='updates',SINGBOX_UC='runtime';
function log_message(){}
function validate_start_config(){return 0;}
function external_config_fingerprint(){return 'config';}
function module_status(){return 0;}
function module_success(mod,args){return args[0]!='has-list-update-sources';}
function acquire_start_subscription_update_lock(){return true;}
function prepare_subscription_caches(){return 0;}
function nft_candidate_begin(){return true;}
function nft_rebuild_runtime(){return 0;}
function nft_populate_runtime_sets(){return 0;}
function nft_candidate_finish(){return true;}
function singbox_init_config(){return config_status;}
function clear_start_failure(){cleared++;}
function start_phase_failed(phase,status){return status;}
UC
sed -n '/^function start_main(/,/^}/p' "$ROOT/forkop/files/usr/lib/service/lifecycle.uc"
cat <<'UC'
if(start_main()!=75 || permanent_start_failure || cleared!=1)die('no-WAN startup must remain retryable\n');
config_status=1;
if(start_main()!=1 || !permanent_start_failure || cleared!=1)die('invalid configuration must remain permanent\n');
print('No-WAN startup remains retryable and invalid config still blocks retries\n');
UC
} > "$WORK/check.uc"
ucode -L "$ROOT/forkop/files/usr/lib" "$WORK/check.uc"
