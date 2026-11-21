#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB=${FORKOP_LIB:-$ROOT/forkop/files/usr/lib}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

check_paths() {
    config=$1 cache=$2 expected_config=$3 expected_cache=$4
    printf '{"settings":{"config_path":"%s","cache_path":"%s","config_version":"2.7.6"}}\n' \
        "$config" "$cache" > "$WORK/input.json"
    ucode -L "$LIB" "$LIB/config/migration.uc" migrate-fixture "$WORK/input.json" > "$WORK/output.json"
    ucode -L "$LIB" -e '
        let fs = require("fs");
        let result = json(fs.readfile(ARGV[0]));
        assert(result.config.settings.config_path == ARGV[1], "generated config path");
        assert(result.config.settings.cache_path == ARGV[2], "Xrust cache path");
        if (ARGV[2] != ARGV[3]) {
            assert(result.xrust_cache_copy.from == ARGV[3] + ".forkop-rust-x", "only copy the Xrust database");
            assert(result.xrust_cache_copy.to == ARGV[2] + ".forkop-rust-x", "keep the 2.7.6-compatible cache suffix");
        } else {
            assert(result.xrust_cache_copy == null, "preserve the custom database in place");
        }
        fs.writefile(ARGV[4], sprintf("%J", result.config));
    ' "$WORK/output.json" "$expected_config" "$expected_cache" "$cache" "$WORK/retry.json"
    ucode -L "$LIB" "$LIB/config/migration.uc" migrate-fixture "$WORK/retry.json" > "$WORK/repeat.json"
    ucode -e '
        let result = json(require("fs").readfile(ARGV[0]));
        assert(!result.changed && result.xrust_cache_copy == null, "migration is idempotent");
    ' "$WORK/repeat.json"
}

check_paths /etc/sing-box/config.json /tmp/sing-box/cache.db /etc/xrust/config.json /tmp/xrust/cache.db
check_paths /tmp/sing-box/config.json /usr/share/sing-box/cache.db /tmp/xrust/config.json /usr/share/xrust/cache.db
check_paths '/etc/custom/core config.json' '/tmp/custom/core cache.db' '/etc/custom/core config.json' '/tmp/custom/core cache.db'

printf '%s\n' '{"settings":{"config_version":"2.7.6"}}' > "$WORK/implicit.json"
ucode -L "$LIB" "$LIB/config/migration.uc" migrate-fixture "$WORK/implicit.json" > "$WORK/implicit-result.json"
ucode -e '
    let result = json(require("fs").readfile(ARGV[0]));
    assert(result.config.settings.cache_path == null, "leave omitted cache_path implicit");
    assert(result.xrust_cache_copy.from == "/tmp/sing-box/cache.db.forkop-rust-x");
    assert(result.xrust_cache_copy.to == "/tmp/xrust/cache.db.forkop-rust-x");
' "$WORK/implicit-result.json"

cat > "$WORK/legacy-json.json" <<'JSON'
{"settings":{"config_version":"2.7.6"},"section":[{".name":"proxy",".type":"section","action":"outbound","outbound_json":"{\"type\":\"direct\"}","outbound_detour_enabled":"1","outbound_detour_section":"uplink"}]}
JSON
ucode -L "$LIB" "$LIB/config/migration.uc" migrate-fixture "$WORK/legacy-json.json" podkop > "$WORK/legacy-json-result.json"
ucode -e '
    let result = json(require("fs").readfile(ARGV[0]));
    let outbound = json(result.config.section[0].outbound_jsons[0]);
    assert(outbound.detour == "uplink-out", "preserve legacy outbound detour");
    assert(outbound.tag == "proxy-json-1-out", "assign a stable outbound tag");
' "$WORK/legacy-json-result.json"

# Exercise the package-hook migration with an isolated UCI fixture.
cat > "$WORK/uci-state" <<'UCI'
forkop.settings=settings
forkop.settings.config_path=/etc/sing-box/config.json
forkop.settings.cache_path=/etc/custom/cache.db
forkop.settings.config_version=2.7.6
sing-box.main=sing-box
sing-box.main.conffile=/etc/sing-box/config.json
sing-box.main.workdir=/etc/custom/workdir
UCI
export FORKOP_UCI_STATE_FILE="$WORK/uci-state"
export FORKOP_RUNTIME_STATE_DIR="$WORK/runtime"
export FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK/subscriptions"
export FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK/change.guard"
export TMP_SUBSCRIPTION_FOLDER="$WORK/runtime/subscriptions"
ucode -L "$LIB" "$LIB/config/migration.uc" migrate
grep -Fxq 'forkop.settings.config_path=/etc/xrust/config.json' "$WORK/uci-state"
grep -Fxq 'forkop.settings.cache_path=/etc/custom/cache.db' "$WORK/uci-state"
grep -Fxq 'forkop.settings.xrust_workdir=/etc/custom/workdir' "$WORK/uci-state"
grep -Fxq 'sing-box.main.conffile=/etc/sing-box/config.json' "$WORK/uci-state"
cp "$WORK/uci-state" "$WORK/committed"
ucode -L "$LIB" "$LIB/config/migration.uc" migrate
cmp "$WORK/committed" "$WORK/uci-state"

# Test the actual copy helper with an isolated filesystem, including the
# original remaining available to 2.7.6 and a retry preserving the new store.
{
    printf '%s\n' 'let fs = require("fs"), common = require("core.common");'
    sed -n '/^function prepare_xrust_cache_copy(/,/^}/p' "$LIB/config/migration.uc"
    cat <<'UC'
let source = ARGV[0] + "/old/cache.db.forkop-rust-x";
let target = ARGV[0] + "/new/cache.db.forkop-rust-x";
let move = { from: source, to: target };
assert(prepare_xrust_cache_copy(move) && fs.stat(target) == null, "missing cache is normal");
fs.mkdir(ARGV[0] + "/old");
fs.writefile(source, "original Xrust store");
fs.writefile(ARGV[0] + "/new", "obstruction");
assert(!prepare_xrust_cache_copy(move), "a failed copy must prevent the migration commit");
fs.unlink(ARGV[0] + "/new");
assert(prepare_xrust_cache_copy(move), "migrate the database before updating UCI");
assert(fs.readfile(target) == "original Xrust store", "copy the complete database contents");
assert(fs.readfile(source) == "original Xrust store", "keep the old database for rollback");
fs.writefile(target, "new Xrust store");
assert(prepare_xrust_cache_copy(move) && fs.readfile(target) == "new Xrust store", "retry preserves destination contents");
UC
} > "$WORK/cache-copy.uc"
ucode -L "$LIB" "$WORK/cache-copy.uc" "$WORK"
printf '%s\n' 'Xrust path migration and cache preservation passed'
