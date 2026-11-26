#!/bin/sh
set -eu
# Dependencies new to a release (flock in 2.4.1) must be installed before
# Forkop is stopped: afterwards the router can be offline until the new
# release starts, and the dependency download fails the whole update.
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INSTALLER="$ROOT/install.sh"
ACTION="$ROOT/forkop/files/usr/lib/components/action.uc"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

APK_DRY_RUN='(1/3) Installing flock (2.40.2-r1)
(2/3) Installing libsmartcols1 (2.40.2-r1)
(3/3) Upgrading forkop (2.3.7-r1 -> 2.4.4-r1)
OK: 0 MiB in 0 packages'
OPKG_DRY_RUN='Upgrading forkop on root from 2.3.7 to 2.4.4...
Installing flock (2.40.2-1) to root...
Installing luci-app-forkop (2.4.4) to root...'

# --- install.sh ---
sed '/^main "\$@"$/d' "$INSTALLER" >"$work/library.sh"
. "$work/library.sh"
msg() { :; }
warn() { printf '%s\n' "$*" >>"$work/warnings"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP_DIR="$work"
FORKOP_BACKEND_FILE="$work/forkop.pkg"
FORKOP_APP_FILE="$work/luci-app-forkop.pkg"
FORKOP_I18N_FILE="$work/luci-i18n-forkop-ru.pkg"
pkg_install_name() { printf '%s\n' "$1" >>"$work/installed"; }

PKG_IS_APK=1
apk() {
    [ "$1 $2 $3" = "add --simulate --allow-untrusted" ] || fail "apk dry run used unexpected arguments: $*"
    [ "$#" -eq 6 ] || fail 'apk dry run did not include all three release files'
    printf '%s\n' "$APK_DRY_RUN"
}
: >"$work/installed"
preinstall_release_dependencies
[ "$(cat "$work/installed")" = "$(printf 'flock\nlibsmartcols1')" ] ||
  fail "apk: new dependencies not installed before the update: $(tr '\n' ' ' <"$work/installed")"

PKG_IS_APK=0
opkg_with_lock_retry() {
    [ "$1 $2" = "install --noaction" ] || fail "opkg dry run used unexpected arguments: $*"
    printf '%s\n' "$OPKG_DRY_RUN"
}
: >"$work/installed"
preinstall_release_dependencies
[ "$(cat "$work/installed")" = flock ] || fail 'opkg: new dependency flock was not installed before the update'

# A failed dry run (e.g. a conflict removed later) keeps the previous behaviour.
opkg_with_lock_retry() { echo 'Collected errors: conflicts with https-dns-proxy'; return 255; }
: >"$work/installed"
: >"$work/warnings"
preinstall_release_dependencies
[ ! -s "$work/installed" ] || fail 'failed dry run still installed packages'
[ -s "$work/warnings" ] || fail 'failed dry run was not reported'

# Nothing new to install.
opkg_with_lock_retry() { echo 'Upgrading forkop on root from 2.4.3 to 2.4.4...'; }
: >"$work/installed"
preinstall_release_dependencies
[ ! -s "$work/installed" ] || fail 'release packages themselves were installed as dependencies'

# It runs after the storage preflight and before anything stops Forkop.
awk '
  /^install_resolved_forkop_release\(\) \{/ { in_install = 1 }
  in_install && /^}/ { exit }
  in_install && /ensure_flash_space/ && !flash { flash = NR }
  in_install && /preinstall_release_dependencies/ && !pre { pre = NR }
  in_install && /install_backend_package|cleanup_legacy_installation|begin_legacy_migration/ && !change { change = NR }
  END { exit !(flash && pre > flash && change > pre) }
' "$INSTALLER" || fail 'installer does not install new dependencies between the preflight and the first service change'

# --- components/action.uc (update from LuCI) ---
for manager in apk opkg; do
    ucode -e '
let fs = require("fs");
let source = fs.readfile(ARGV[0]);
function extract(start_text) {
    let start = index(source, start_text);
    assert(start >= 0, start_text + " exists");
    let tail = substr(source, start);
    return substr(tail, 0, index(tail, "\n}") + 2);
}
let apk = ARGV[1] == "apk";
let output = apk ? ARGV[2] : ARGV[3];
let code = "let last_logged_output = \"\", installed = [], dry_run_ok = true, dry_run = \"\";\n" +
    "function is_apk() { return " + (apk ? "true" : "false") + "; }\n" +
    "function as_string(v) { return v == null ? \"\" : \"\" + v; }\n" +
    "function command_from_args(args) { return join(\" \", args); }\n" +
    "function updates_log(m, l) {}\n" +
    "function pkg_install_name_command(name) { return \"install \" + name; }\n" +
    "function run_logged(d, command) {\n" +
    "  if (index(command, \"install \") == 0) { push(installed, substr(command, 8)); return true; }\n" +
    "  assert(index(command, " + (apk ? "\"apk add --simulate --allow-untrusted /p/forkop\"" : "\"opkg install --noaction\"") + ") == 0, \"dry run command: \" + command);\n" +
    "  dry_run = command; last_logged_output = " + sprintf("%J", output) + "; return dry_run_ok;\n" +
    "}\n" +
    extract("function array_has(") + "\n" +
    extract("function release_dependencies_to_preinstall(") + "\n" +
    extract("function preinstall_release_dependencies(") + "\n" +
    "assert(preinstall_release_dependencies([ \"/p/forkop\", \"/p/app\", \"\" ]), \"preinstall succeeds\");\n" +
    "assert(index(dry_run, \"/p/app </dev/null\") > 0, \"dry run did not include every release file: \" + dry_run);\n" +
    "assert(join(\",\", installed) == " + (apk ? "\"flock,libsmartcols1\"" : "\"flock\"") + ", \"installed: \" + join(\",\", installed));\n" +
    "installed = []; dry_run_ok = false;\n" +
    "assert(preinstall_release_dependencies([ \"/p/forkop\" ]), \"failed dry run keeps the update going\");\n" +
    "assert(length(installed) == 0, \"failed dry run installed packages\");\n";
let path = "/tmp/forkop-release-dependencies." + fs.readlink("/proc/self") + ".uc";
fs.writefile(path, code);
let status = system([ "ucode", path ]);
fs.unlink(path);
exit(status);
' "$ACTION" "$manager" "$APK_DRY_RUN" "$OPKG_DRY_RUN" || fail "$manager: LuCI update does not preinstall new dependencies"
done
awk '
  /^function install_forkop\(/ { in_fn = 1 }
  in_fn && /forkop_package_preflight_space\(/ && !flash { flash = NR; next }
  in_fn && /forkop_package_preflight_space\(/ { recheck = NR }
  in_fn && /preinstall_release_dependencies/ && !pre { pre = NR }
  in_fn && /pkg_install_files_command\(dependency_files, true\)/ { offline = NR }
  in_fn && /prepare_forkop_runtime_for_package_upgrade/ && !stop { stop = NR }
  in_fn && /^}/ { exit }
  END { exit !(flash && pre > flash && offline > pre && recheck > offline && stop > recheck) }
' "$ACTION" || fail 'LuCI update must check space and offline APK readiness before stopping Forkop'

awk '
  /^function pkg_install_files_command\(/ { in_fn = 1 }
  in_fn && /"apk"/ && /"--no-network"/ { offline = 1 }
  in_fn && /^}/ { exit }
  END { exit !offline }
' "$ACTION" || fail 'LuCI must install the prepared APK files offline'

echo 'New release dependencies are installed before Forkop stops: OK'
