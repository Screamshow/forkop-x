#!/bin/sh
# Requires a test OpenWrt VM. Writes only to temporary fixture directories.
set -eu
umask 077
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/forkop/files/usr/lib"
WORK=$(mktemp -d /tmp/forkop-cache-fault.XXXXXX)
mounted=0
child=
cleanup() {
    if [ -n "$child" ]; then
        if tr '\000' '\n' < "/proc/$child/cmdline" | grep -Fxq "$WORK/subscription.uc"; then
            kill -KILL "$child" 2>/dev/null || true
            wait "$child" 2>/dev/null || true
        fi
    fi
    if [ "$mounted" -eq 1 ]; then
        umount "$WORK/fs" || return 1
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
export FORKOP_CACHE_TEST_DIR="$WORK"
mkdir "$WORK/fs"
mount -t tmpfs -o size=1m,mode=0700 tmpfs "$WORK/fs"
mounted=1
mkdir "$WORK/fs/active" "$WORK/fs/backup" "$WORK/cross-backup"
dd if=/dev/zero of="$WORK/fs/backup/list.json" bs=4096 count=80 2>/dev/null
cp "$WORK/fs/backup/list.json" "$WORK/cross-backup/list.json"
printf 'candidate' > "$WORK/fs/active/list.json"
fill() {
    if dd if=/dev/zero of="$WORK/fs/filler" bs=4096 count=1024 2>"$WORK/enospc"; then
        return 1
    fi
    grep -Fiq 'No space left' "$WORK/enospc"
}
fill
{
    cat <<'UC'
let fs = require("fs"), common = require("core.common");
let work = getenv("FORKOP_CACHE_TEST_DIR");
let TMP_RULESET_FOLDER = work + "/fs/active";
let list_ruleset_snapshot_dir = work + "/fs/backup";
let list_change_rollback_dir = work + "/cross-backup";
let as_string = common.as_string;
function command_success_from_args(args) { return system(args) == 0; }
function log_message(message, level) { warn(message, "\n"); }
UC
    sed -n '/^function begin_list_ruleset_snapshot(/,/^}/p' "$LIB/components/updates.uc"
    sed -n '/^function finish_list_ruleset_snapshot(/,/^}/p' "$LIB/components/updates.uc"
    sed -n '/^function finish_list_change_files(/,/^}/p' "$LIB/service/lifecycle.uc"
    cat <<'UC'
if (ARGV[0] == "cross") {
    assert(!finish_list_change_files(true), "cross-device copy accepted ENOSPC");
    assert(fs.readfile(TMP_RULESET_FOLDER + "/list.json") == "candidate");
    assert(fs.stat(list_change_rollback_dir + "/list.json").size == 327680);
} else if (ARGV[0] == "retry-cross") {
    assert(finish_list_change_files(true), "could not retry cross-device restore");
    assert(fs.stat(TMP_RULESET_FOLDER + "/list.json").size == 327680);
    assert(fs.stat(work + "/cross-backup") == null);
} else if (ARGV[0] == "retained") {
    begin_list_ruleset_snapshot();
    assert(list_ruleset_snapshot_dir == "");
    assert(fs.stat(work + "/cross-backup/list.json").size == 327680);
} else {
    finish_list_ruleset_snapshot(false);
    assert(fs.stat(TMP_RULESET_FOLDER + "/list.json").size == 327680);
    assert(fs.stat(work + "/fs/backup") == null);
}
UC
} > "$WORK/lists.uc"
ucode -L "$LIB" "$WORK/lists.uc" cross
FORKOP_LIST_CHANGE_ROLLBACK_DIR="$WORK/cross-backup" ucode -L "$LIB" "$WORK/lists.uc" retained
ucode -L "$LIB" "$WORK/lists.uc" local
cmp "$WORK/fs/active/list.json" "$WORK/cross-backup/list.json"
rm "$WORK/fs/filler" "$WORK/fs/active/list.json"
ucode -L "$LIB" "$WORK/lists.uc" retry-cross
printf '%s\n' 'PASS materialized rulesets on ENOSPC, same-device restore and cross-device preservation'
rm "$WORK/fs/active/list.json"

mkdir "$WORK/runtime" "$WORK/fs/persistent" "$WORK/instrumented" "$WORK/instrumented/subscription"
# Freeze only the fixture writer after its real private write and before rename.
awk '
/^    if \(common.write_private_file\(staged, text\)/ {
    print "    let written = common.write_private_file(staged, text);"
    print "    if (written != null) { fs.writefile(getenv(\"FORKOP_CACHE_TEST_DIR\") + \"/ready\", \"1\"); sleep(20000); }"
    sub(/common.write_private_file\(staged, text\)/, "written")
}
{ print }
' "$LIB/subscription/source_cache.uc" > "$WORK/instrumented/subscription/source_cache.uc"
{
    cat <<'UC'
let fs = require("fs"), common = require("core.common");
let source_cache = require("subscription.source_cache"), parser = require("subscription.parser");
let work = getenv("FORKOP_CACHE_TEST_DIR");
let ram = work + "/runtime";
let FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR = work + "/fs/persistent";
let flash = FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR;
let as_string = common.as_string;
let auto_user_agents = {};
function ensure_dir(path) { if (!fs.stat(path)) fs.mkdir(path, 0700); }
function chmod_path(path, mode) { fs.chmod(path, mode == "700" ? 0700 : 0600); }
function generate_hwid() { return "device-A"; }
function subscription_parser() { return parser; }
UC
    for fn in source_json_path cache_section_is_safe user_agent_supported user_agent_matches_config hwid_matches_config source_cache_profile_matches source_cache_matches_profile restore_persistent_subscription_cache persist_subscription_cache; do
        sed -n "/^function $fn(/,/^}/p" "$LIB/subscription/cache.uc"
    done
    cat <<'UC'
const name = "example-subscription-1";
function record(id) {
    return {
        profile: { url: "https://" + id + ".invalid/", user_agent: "fixture/" + id, hwid: "device-" + id,
            metadata: { label: id, description: "Подписка" } },
        payload: { outbounds: [{ type: "socks", tag: id, server: id + ".invalid", server_port: 1080 }] }
    };
}
function restore(id) {
    let profile = record(id).profile;
    return restore_persistent_subscription_cache(name, ram, flash, profile.url, profile.user_agent, profile.hwid, "");
}
function check(dir, id) {
    let cached = source_cache.read(dir, name);
    let expected = record(id);
    assert(cached.payload?.outbounds[0]?.tag == id, "wrong outbound");
    assert(source_cache.same_profile(cached.profile, expected.profile), "wrong request profile");
    assert(cached.profile.metadata?.label == id && cached.profile.metadata?.description == "Подписка", "wrong metadata");
    assert(fs.stat(source_json_path(dir, name)).mode == 0600, "wrong mode");
}
if (ARGV[0] == "seed")
    assert(persist_subscription_cache(name, record("A")));
else if (ARGV[0] == "full") {
    assert(!persist_subscription_cache(name, record("B")), "full flash write reported success");
    assert(!length(fs.glob(source_json_path(flash, name) + ".pending.*") || []), "failed write leaked a temporary file");
    check(flash, "A");
} else if (ARGV[0] == "interrupt")
    assert(persist_subscription_cache(name, record("B")));
else if (ARGV[0] == "previous") {
    assert(!restore("B"), "unpublished profile was accepted");
    assert(restore("A"), "cannot restore last working subscription");
    check(flash, "A");
    check(ram, "A");
} else if (ARGV[0] == "retry") {
    assert(persist_subscription_cache(name, record("B")));
    check(flash, "B");
    assert(!length(fs.glob(source_json_path(flash, name) + ".pending.*") || []), "retry retained the interrupted writer's file");
    fs.unlink(source_json_path(ram, name));
    assert(!restore("A"), "old profile accepted new nodes");
    assert(restore("B"), "cannot restore committed subscription");
    check(ram, "B");
}
UC
} > "$WORK/subscription.uc"
sub() { ucode -L "$LIB" "$WORK/subscription.uc" "$1"; }
sub seed
fill
sub full
rm "$WORK/fs/filler"
sub previous
ucode -L "$WORK/instrumented" -L "$LIB" "$WORK/subscription.uc" interrupt &
child=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ ! -f "$WORK/ready" ] || break
    sleep 1
done
test -f "$WORK/ready"
tr '\000' '\n' < "/proc/$child/cmdline" | grep -Fxq "$WORK/subscription.uc"
kill -KILL "$child"
wait "$child" 2>/dev/null || true
child=
sub previous
sub retry
printf '%s\n' 'PASS atomic subscription cache on ENOSPC, SIGKILL, offline restore and retry'
