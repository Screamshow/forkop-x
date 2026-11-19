#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d /tmp/forkop-installer-backup.XXXXXX)"
trap 'rm -rf "$work"' EXIT
fail() { printf '%s\n' "$1" >&2; exit 1; }
msg() { :; }
# Exercise the standalone installer's actual backup implementation without
# running installation or writing to /etc.
sed -n '/^prepare_current_config_backup() {/,/^}/p' "$ROOT/install.sh" > "$work/functions.sh"
. "$work/functions.sh"
export FORKOP_INSTALLER_CONFIG_DIR="$work/config"
export FORKOP_INSTALLER_BACKUP_DIR="$work/backups"
mkdir -p "$work/config" "$work/backups"
INSTALL_MODE=clean
prepare_current_config_backup
[ ! -e "$work/backups/configuration.tar.gz" ] || fail 'clean install created a backup'
INSTALL_MODE=legacy
prepare_current_config_backup
[ ! -e "$work/backups/configuration.tar.gz" ] || fail 'legacy path replaced current backup'
INSTALL_MODE=update
printf 'original\n' > "$work/config/forkop"
printf old > "$work/backups/before-1.14.7-canary.3-123.tar.gz"
printf keep > "$work/backups/user-copy.tar.gz"
prepare_current_config_backup
[ "$(tar -xOzf "$work/backups/configuration.tar.gz" forkop)" = original ] || fail 'incorrect backup'
[ ! -e "$work/backups/before-1.14.7-canary.3-123.tar.gz" ] || fail 'obsolete backup survived'
[ -e "$work/backups/user-copy.tar.gz" ] || fail 'user backup deleted'
[ "$(ls -l "$work/backups/configuration.tar.gz" | awk '{print $1}')" = -rw------- ] || fail 'insecure backup'
printf 'updated\n' > "$work/config/forkop"
prepare_current_config_backup
[ "$(tar -xOzf "$work/backups/configuration.tar.gz" forkop)" = updated ] || fail 'backup not replaced'
before="$(sha256sum "$work/backups/configuration.tar.gz")"
rm "$work/config/forkop"
if (prepare_current_config_backup); then fail 'accepted missing configuration'; fi
[ "$(sha256sum "$work/backups/configuration.tar.gz")" = "$before" ] || fail 'failed backup destroyed previous copy'
[ "$(find "$work/backups" -name '.configuration.*' | wc -l)" = 0 ] || fail 'temporary archive leaked'
# Both LuCI update variants must reach the common backup after preflight.
ucode -e 'let fs = require("fs"); let s = fs.readfile(ARGV[0]);
let a = index(s, "function install_forkop(");
let start = index(s, "    capture_forkop_running_state();", a);
let backup = index(s, "    forkop_configuration_backup = save_forkop_configuration_backup", a);
let mutation = index(s, "    if (!stop_old_sing_box_before_forkop_upgrade())", a);
if (!(start > a && backup > start && mutation > backup)) exit(1);' \
  "$ROOT/forkop/files/usr/lib/components/action.uc" || fail 'common LuCI backup missing before mutation'

# Exercise both package-manager paths with the real rollback orchestration.
# Package operations, service control and UCI restoration are confined to stubs.
{
cat <<'UCODE'
const SERVICE_INIT = "/fixture/forkop";
const translation = "luci-i18n-forkop-ru", previous = "2.7.4", target = "2.7.5";
let forkop_package_init = "/fixture/init", forkop_configuration_backup = "/fixture/backup";
let forkop_package_version_reader = "/fixture/packages.uc";
let forkop_was_enabled = true, forkop_was_running = true;
let apk, packages, events, fault;
function read_installed_package_version(name, reader) {
    assert(reader == forkop_package_version_reader, "reader can be overwritten by package install");
    if (fault == "query" && name == translation)
        return { state: "error", error: "fixture database failure" };
    return packages[name] ? { state: "found", version: packages[name] } : { state: "missing" };
}
function forkop_release_version(version) { return version; }
function selected_forkop_release(version) { return { tag_name: version }; }
function stage_forkop_release_archive(release, name, version) {
    return { name, version, path: "/rollback/" + name };
}
function stage_repository_package() { die("unexpected repository fallback"); }
function is_apk() { return apk; }
function command_env() { return ""; }
function command_from_args(args) { return join(" ", args); }
function pkg_restore_file_command(path) { return path; }
function run_logged(description, command) {
    if (index(description, "Removing translation") == 0) {
        assert(index(command, (apk ? "apk del --no-network " : "opkg remove ") + translation) == 0, "wrong removal command");
        push(events, "remove translation");
        if (fault == "remove")
            return false;
        delete packages[translation];
        return true;
    }
    for (let name in [ "forkop", "luci-app-forkop", translation ]) {
        if (index(command, "/rollback/" + name) < 0)
            continue;
        if (fault == "backend" && name == "forkop")
            return false;
        packages[name] = previous;
    }
    return true;
}
function updates_log() {}
function stop_forkop_for_package_restore() { push(events, "stop"); return true; }
function restore_forkop_configuration_backup() { push(events, "uci"); return fault != "uci"; }
function command_success_from_args(args) { push(events, args[1]); return true; }
function file_exists() { return true; }
function wait_for_forkop_restore() { return index(events, "start") >= 0; }
UCODE
sed -n '/^function stage_forkop_rollback_packages(/,/^}/p;
        /^function remove_new_forkop_translation(/,/^}/p;
        /^function restore_forkop_packages(/,/^}/p' "$ROOT/forkop/files/usr/lib/components/action.uc"
cat <<'UCODE'
for (let format in [ "APK", "IPK" ]) {
    apk = format == "APK";
    fault = "";
    packages = { forkop: previous, "luci-app-forkop": previous };
    let absent_translation = stage_forkop_rollback_packages();
    assert(length(absent_translation) == 2, "missing optional package was not distinguished");
    fault = "query";
    assert(stage_forkop_rollback_packages() == null, "failed translation query was treated as missing");

    for (let failure in [ "", "backend", "uci", "remove", "query" ]) {
        packages = { forkop: target, "luci-app-forkop": target, "luci-i18n-forkop-ru": target };
        events = [];
        fault = failure;
        assert(restore_forkop_packages(absent_translation) == (failure == ""), "incorrect rollback outcome: " + format + "/" + failure);
        assert(index(events, "stop") >= 0, "partial restore did not confirm stopped state");
        assert((index(events, "start") >= 0) == (failure == ""), "start escaped rollback checks: " + format + "/" + failure);
        if (failure == "")
            assert(packages[translation] == null && events[0] == "remove translation", "extra translation was retained");
    }

    fault = "";
    packages = { forkop: previous, "luci-app-forkop": previous, "luci-i18n-forkop-ru": previous };
    let installed_translation = stage_forkop_rollback_packages();
    packages[translation] = target;
    events = [];
    forkop_was_running = false;
    assert(restore_forkop_packages(installed_translation), "installed translation was not restored");
    assert(packages[translation] == previous && index(events, "remove translation") < 0 && index(events, "start") < 0,
        "rollback changed stopped state or removed an existing translation");
    forkop_was_running = true;
}
UCODE
} | ucode -
printf 'Installer configuration backup checks passed\n'
