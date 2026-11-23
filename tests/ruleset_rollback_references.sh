#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
CURRENT_LIB=${FORKOP_TEST_LIB:-$ROOT/forkop/files/usr/lib}
FORKOP_XRUST_BIN=${FORKOP_XRUST_BIN:-$(command -v xrust || printf %s /usr/bin/xrust)}
export FORKOP_XRUST_BIN
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat >"$WORK/bin/curl" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  case "$1" in --output) output=$2; shift 2;; *) shift;; esac
done
cp "$TEST_RULESET_PAYLOAD" "$output"
EOF
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"
check() {
    lib=$1
    expected=$2
    core=$FORKOP_XRUST_BIN
    [ "$expected" != old ] || core=sing-box
    mkdir -p "$WORK/$expected-$TEST_RULESET_FORMAT/cache"
    export FORKOP_RULESET_CACHE_DIR="$WORK/$expected-$TEST_RULESET_FORMAT/cache"
    export FORKOP_RULESET_RUNTIME_CACHE_DIR="$WORK/$expected-$TEST_RULESET_FORMAT/runtime"
    export FORKOP_RULESET_RUNTIME_MANIFEST="$WORK/$expected-$TEST_RULESET_FORMAT/runtime.json"
    export FORKOP_PERSISTENT_LIST_CACHE_DIR="$WORK/$expected-$TEST_RULESET_FORMAT/list-cache"
    printf '{"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rule_set":[{"type":"remote","tag":"example","format":"%s","url":"https://fixture.invalid/list"}],"rules":[{"rule_set":"example","outbound":"direct"}],"final":"direct"}}' "$TEST_RULESET_FORMAT" >"$WORK/$expected-$TEST_RULESET_FORMAT/old.json"
    cp "$WORK/$expected-$TEST_RULESET_FORMAT/old.json" "$WORK/$expected-$TEST_RULESET_FORMAT/refreshed.json"
    ucode -L "$lib" "$lib/xrust/ruleset_cache.uc" materialize-config "$WORK/$expected-$TEST_RULESET_FORMAT/old.json" required
    path=$(ucode -e 'let fs=require("fs"); print(json(fs.readfile(ARGV[0])).route.rule_set[0].path);' "$WORK/$expected-$TEST_RULESET_FORMAT/old.json")
    case "$path" in *empty-*) echo 'Fixture unexpectedly used an empty fallback'; exit 1;; esac
    "$core" check -c "$WORK/$expected-$TEST_RULESET_FORMAT/old.json" >"$WORK/$expected-$TEST_RULESET_FORMAT/before.log" 2>&1
    if [ "$expected" = current ]; then
        previous_digest=$(sha256sum "$path")
        TEST_RULESET_PAYLOAD="$TEST_NEW_RULESET_PAYLOAD" ucode -L "$lib" "$lib/xrust/ruleset_cache.uc" refresh
        ucode -L "$lib" "$lib/xrust/ruleset_cache.uc" materialize-config "$WORK/$expected-$TEST_RULESET_FORMAT/refreshed.json" required
        new_path=$(ucode -e 'let fs=require("fs"); print(json(fs.readfile(ARGV[0])).route.rule_set[0].path);' "$WORK/$expected-$TEST_RULESET_FORMAT/refreshed.json")
        [ "$new_path" != "$path" ]
        [ "$(sha256sum "$path")" = "$previous_digest" ]
        "$core" check -c "$WORK/$expected-$TEST_RULESET_FORMAT/old.json"
        "$core" check -c "$WORK/$expected-$TEST_RULESET_FORMAT/refreshed.json"
    fi
    printf '{"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rule_set":[],"rules":[],"final":"direct"}}' >"$WORK/$expected-$TEST_RULESET_FORMAT/candidate.json"
    ucode -L "$lib" "$lib/xrust/ruleset_cache.uc" materialize-config "$WORK/$expected-$TEST_RULESET_FORMAT/candidate.json" required
    if [ "$expected" = old ]; then
        [ ! -e "$path" ] || { echo 'Old version did not reproduce early pruning'; exit 1; }
        if "$core" check -c "$WORK/$expected-$TEST_RULESET_FORMAT/old.json" >"$WORK/$expected-$TEST_RULESET_FORMAT/after.log" 2>&1; then
            echo 'Old rollback config unexpectedly remained usable'; exit 1
        fi
        grep -q 'no such file' "$WORK/$expected-$TEST_RULESET_FORMAT/after.log"
        echo "REPRODUCED ($TEST_RULESET_FORMAT): 2.1.3 staging removes a file required by the previous config"
    else
        [ -s "$path" ]
        "$core" check -c "$WORK/$expected-$TEST_RULESET_FORMAT/old.json" >"$WORK/$expected-$TEST_RULESET_FORMAT/after.log" 2>&1
        FORKOP_SING_BOX_CONFIG_PATH="$WORK/$expected-$TEST_RULESET_FORMAT/candidate.json" ucode -L "$lib" "$lib/xrust/ruleset_cache.uc" prune-applied
        [ ! -e "$path" ]
        [ ! -e "$new_path" ]
        echo "PASS ($TEST_RULESET_FORMAT): current staging preserves rollback references until applied-config cleanup"
    fi
}
printf '{"version":3,"rules":[{"domain_suffix":["rollback-reference.invalid"]}]}' >"$WORK/source.json"
printf '{"version":3,"rules":[{"domain_suffix":["next-generation.invalid"]}]}' >"$WORK/new-source.json"
"$FORKOP_XRUST_BIN" rule-set compile "$WORK/source.json" -o "$WORK/binary.srs" >/dev/null
"$FORKOP_XRUST_BIN" rule-set compile "$WORK/new-source.json" -o "$WORK/new-binary.srs" >/dev/null
for TEST_RULESET_FORMAT in source binary; do
    export TEST_RULESET_FORMAT
    if [ "$TEST_RULESET_FORMAT" = source ]; then
        export TEST_RULESET_PAYLOAD="$WORK/source.json"
        TEST_NEW_RULESET_PAYLOAD="$WORK/new-source.json"
    else
        export TEST_RULESET_PAYLOAD="$WORK/binary.srs"
        TEST_NEW_RULESET_PAYLOAD="$WORK/new-binary.srs"
    fi
    if [ -n "${FORKOP_OLD_TEST_LIB:-}" ]; then
        check "$FORKOP_OLD_TEST_LIB" old
    fi
    check "$CURRENT_LIB" current
done
