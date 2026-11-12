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
mock_forkop() {
    [ "$*" = 'component_action sing_box install_rust_x' ] || exit 90
    printf '%s\n' '{"success":true}'
    return "${mock_status:-0}"
}
update_existing_xrust > "$work/success"
grep -q '"success":true' "$work/success"
mock_status=1
if (update_existing_xrust > "$work/failure" 2>&1); then
    echo 'Failed core update returned success' >&2
    exit 1
fi
[ -f "$work/post-install" ]
# The final service start must follow the core transaction.
sed -n '/^main() {/,/^}/p' "$ROOT/install.sh" > "$work/main"
core_line=$(grep -n '^        update_existing_xrust$' "$work/main" | cut -d: -f1)
start_line=$(grep -n '^    post_install$' "$work/main" | cut -d: -f1)
[ "$core_line" -lt "$start_line" ]
echo 'Installer existing Xrust selection and failure handling: OK'
