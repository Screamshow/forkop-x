#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sed '/^main "\$@"$/d' "$ROOT/install.sh" > "$work/library.sh"
. "$work/library.sh"
msg() { :; }
warn() { :; }
post_install() { echo restored > "$work/post-install"; }
pkg_is_installed() { [ "$1" = "${installed:-}" ]; }
command_exists() { [ "${manual:-0}" = 1 ]; }
for installed in rust-x sing-box-x sing-box-tiny sing-box-extended sing-box ''; do
    manual=0
    select_sing_box_installation
    if [ "$installed" = rust-x ]; then
        [ "$UPDATE_EXISTING_XRUST" = 1 ]
        [ -z "$SING_BOX_INSTALL_VARIANT" ]
    else
        [ "$UPDATE_EXISTING_XRUST" = 0 ]
        update_existing_xrust
        if [ -z "$installed" ]; then
            [ "$SING_BOX_INSTALL_VARIANT" = rust-x ]
        else
            [ -z "$SING_BOX_INSTALL_VARIANT" ]
        fi
    fi
done
manual=1
select_sing_box_installation
[ -z "$SING_BOX_INSTALL_VARIANT" ]
[ "$UPDATE_EXISTING_XRUST" = 0 ]
# Replace only the executable path to exercise the real component call/error path.
sed -n '/^update_existing_xrust() {/,/^}/p' "$ROOT/install.sh" |
    sed 's#/usr/bin/forkop#mock_forkop#g' > "$work/update.sh"
. "$work/update.sh"
TMP_DIR="$work"
UPDATE_EXISTING_XRUST=1
mock_response='{"success":true}'
mock_forkop() {
    [ "$*" = 'component_action sing_box update_rust_x' ] || exit 90
    printf '%s\n' "$mock_response"
    return "${mock_status:-0}"
}
update_existing_xrust > "$work/success"
grep -q '"success":true' "$work/success"
mock_status=1
mock_response='{"success":false,"kind":"component","component":"sing_box","action":"update_rust_x","message":"Unknown component action"}'
update_existing_xrust > "$work/older-backend"
[ ! -f "$work/post-install" ]
mock_response='{"success":false,"kind":"component","component":"sing_box","action":"update_rust_x","message":"Cannot resolve Xrust from the mirror"}'
if (update_existing_xrust > "$work/failure" 2>&1); then
    echo 'Failed core update returned success' >&2
    exit 1
fi
[ -f "$work/post-install" ]
# The final service start must follow the core transaction.
sed -n '/^install_resolved_forkop_release() {/,/^}/p' "$ROOT/install.sh" > "$work/main"
core_line=$(grep -n '^        update_existing_xrust$' "$work/main" | cut -d: -f1)
start_line=$(grep -n '^    post_install$' "$work/main" | cut -d: -f1)
[ "$core_line" -lt "$start_line" ]

echo 'Installer existing Xrust selection and failure handling: OK'

# The dispatch remains in the published bridge. Pass its source explicitly
# when testing that historical backend alongside the current installer.
[ "$#" -gt 0 ] || exit 0
LEGACY_ACTION_UC="$1"
{
cat <<'UCODE'
let apk, current, latest, comparison, terminal, compared, wanted_version;
function as_string(value) { return value == null ? "" : "" + value; }
function is_apk() { return apk; }
function command_exists(name) { return name == "opkg"; }
function command_output_from_args(args) {
    assert(apk && join(" ", args) == "apk version -t " + current + " " + latest, "APK did not receive exact revisions");
    compared = true;
    return comparison;
}
function command_success_from_args(args) {
    assert(!apk && args[0] == "opkg" && args[1] == "compare-versions" &&
        args[2] == current && args[4] == latest, "opkg did not receive exact revisions");
    compared = true;
    return args[3] == comparison;
}
function installed_package_version(name) { return current; }
function sing_box_runtime_output(mode) { return mode == "variant" ? "rust-x" : "0.0.40-rust-x.0.0.40"; }
function sing_box_runtime_success(mode, args) { return false; }
function resolve_sing_box_x_release(version, rust) {
    assert(rust && version == "", "automatic update did not resolve latest Xrust");
    return { version: latest, build_version: "0.0.40" };
}
function selected_rust_x_release(version) {
    wanted_version = version;
    return { version: latest, build_version: version };
}
function finish(value) { terminal = value; die("case complete"); }
function action_success(component, action, message, from, to, changed, status) {
    assert(from == current && to == latest && changed == 0, "unexpected no-op result");
    finish(status);
}
function action_fail(component, action, message) { finish("error"); }
function stage_sing_box_x_package(release, version) {
    assert(release.version == latest && version == latest, "package stage used another release");
    finish("stage");
}
UCODE
sed -n '/^function compare_versions(/,/^}/p;
        /^function status_from_compare(/,/^}/p;
        /^function install_package_sing_box(/,/^}/p;
        /^function dispatch_sing_box(/,/^}/p' "$LEGACY_ACTION_UC"
cat <<'UCODE'
function check(action, installed, offered, order, expected, expect_comparison, version) {
    current = installed;
    latest = offered;
    comparison = order;
    terminal = "";
    compared = false;
    wanted_version = "";
    try { dispatch_sing_box(action, version); }
    catch (e) { assert(terminal != "", e.message); }
    assert(terminal == expected && compared == expect_comparison, action + ": got " + terminal + " for " + installed + " -> " + offered);
    assert(wanted_version == (action == "install_rust_x" ? version : ""), "selected version leaked into automatic update");
}
for (let is_apk_fixture in [ false, true ]) {
    apk = is_apk_fixture;
    let rev = apk ? "-r" : "-";
    let v2 = "0.0.40" + rev + "2";
    let v10 = "0.0.40" + rev + "10";
    check("update_rust_x", v2, v2, "", "latest", false, "");
    check("update_rust_x", v10, v2, ">", "dev", true, "");
    check("update_rust_x", v2, v10, "<", "stage", true, "");
    check("update_rust_x", v2, v10, "", "error", true, "");
    check("update_rust_x", "", v10, "", "error", false, "");
    check("install_rust_x", v10, "0.0.39" + rev + "1", "", "stage", false, "0.0.39");
}
UCODE
} | ucode -
echo 'Legacy Xrust dispatch and exact package comparisons: OK'
