#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
TMP_DIR="$work"
sed -n '/^install_json_helper_path() {/,/^install_json_ucode() {/ { /^install_json_ucode() {/d; p; }' "$ROOT/install.sh" > "$work/functions.sh"
. "$work/functions.sh"
helper="$(install_json_helper_path)"
cat >"$work/catalog.json" <<'EOF'
{"schema":1,"name":"sing-box-x","version":"1.0.0","assets":[{"package":"sing-box-x","format":"ipk","architecture":"x86_64","name":"sing-box-x_1.0.0-2_x86_64.ipk","url":"https://mirror.51343.ru/forkop/sing-box-x/releases/1.0.0/sing-box-x_1.0.0-2_x86_64.ipk","sha256":"77a35e3f96b74439052b71ec14b9591204138f763e770acb51c3b2e6e6f27f15","size":9685283,"installed_size":9860489,"plain_binary_bytes":31133858}]}
EOF
ucode "$helper" core-package-plan sing-box-x x86_64 ipk https://mirror.51343.ru <"$work/catalog.json" >"$work/plan"
[ "$(cut -f4 "$work/plan")" = 9860489 ] || { echo 'UPX memory size used as flash size' >&2; exit 1; }
if ucode "$helper" core-package-plan sing-box-x mipsel_24kc ipk https://mirror.51343.ru <"$work/catalog.json"; then
  echo 'Unsupported architecture accepted' >&2; exit 1
fi
if ucode "$helper" core-package-plan sing-box-x x86_64 apk https://mirror.51343.ru <"$work/catalog.json"; then
  echo 'Wrong package format accepted' >&2; exit 1
fi
sed 's@https://mirror.51343.ru/forkop/sing-box-x/releases/@https://example.com/forkop/sing-box-x/releases/@' "$work/catalog.json" >"$work/wrong-source.json"
if ucode "$helper" core-package-plan sing-box-x x86_64 ipk https://mirror.51343.ru <"$work/wrong-source.json"; then
  echo 'Off-mirror package URL accepted' >&2; exit 1
fi
cat >"$work/rust-x.json" <<'EOF'
{"schema":1,"name":"rust-x","version":"0.0.26","package_revision":1,"assets":[{"package":"rust-x","format":"apk","architecture":"aarch64_cortex-a53","name":"rust-x_0.0.26-r1_aarch64_cortex-a53.apk","url":"https://mirror.51343.ru/forkop/rust-x/releases/0.0.26/rust-x_0.0.26-r1_aarch64_cortex-a53.apk","sha256":"04cae7029b984e2635eb45254f4d4d69285805e8ea34609f0b352df866c86ad3","size":4899361,"installed_size":10222963}]}
EOF
# OpenWrt APK reports aarch64 on filogic and accepts cortex-a53 packages.
ucode "$helper" core-package-plan rust-x aarch64 apk https://mirror.51343.ru <"$work/rust-x.json" >"$work/rust-plan"
[ "$(cut -f1 "$work/rust-plan")" = https://mirror.51343.ru/forkop/rust-x/releases/0.0.26/rust-x_0.0.26-r1_aarch64_cortex-a53.apk ] &&
  [ "$(cut -f3,4 "$work/rust-plan")" = "$(printf '4899361\t10222963')" ] || {
  echo 'Xrust catalog plan is wrong' >&2; exit 1
}
if ucode "$helper" core-package-plan sing-box-x aarch64 apk https://mirror.51343.ru <"$work/rust-x.json"; then
  echo 'Catalog of another core accepted' >&2; exit 1
fi
ucode "$helper" core-package-plan rust-x aarch64_cortex-a73 apk https://mirror.51343.ru <"$work/rust-x.json" >"$work/beam-plan"
cmp "$work/rust-plan" "$work/beam-plan"
for arch in arm_cortex-a7 mipsel_24kc x86_64; do
  if ucode "$helper" core-package-plan rust-x "$arch" apk https://mirror.51343.ru <"$work/rust-x.json"; then
    echo "ARM64 package accepted for $arch" >&2; exit 1
  fi
done
if ucode "$helper" core-package-plan rust-x aarch64_cortex-a73 ipk https://mirror.51343.ru <"$work/rust-x.json"; then
  echo 'APK fallback accepted for IPK' >&2; exit 1
fi
if ucode "$helper" core-package-plan sing-box aarch64 apk https://mirror.51343.ru <"$work/rust-x.json"; then
  echo 'Unknown core package accepted' >&2; exit 1
fi
echo 'Installer core catalogs and flash plan: OK'
sed -n '/^select_sing_box_for_release() {/,/^}/p' "$ROOT/install.sh" >"$work/release-choice.sh"
. "$work/release-choice.sh"
msg() { :; }
fail() { echo "$*" >&2; exit 1; }
choice() {
  SING_BOX_INSTALL_VARIANT="$1"
  FORKOP_RELEASE_TAG="$2"
  select_sing_box_for_release
  [ "$SING_BOX_INSTALL_VARIANT" = "$3" ] || { echo "$1 on $2 chose $SING_BOX_INSTALL_VARIANT, not $3" >&2; exit 1; }
}
choice rust-x 1.16.4 tiny
choice rust-x 2.0.0-canary.1 x
choice rust-x 2.1.9 x
choice rust-x 2.2.0-canary.1 rust-x
choice rust-x 2.4.4 rust-x
choice rust-x 3.0.0 rust-x
choice x 1.16.4 tiny
choice x 2.0.0-canary.1 x
choice "" 2.4.4 ""
echo 'Installer core choice by release: OK'

# Rockchip and MIPS require their exact package architecture for both formats.
for arch in aarch64_generic mipsel_24kc; do
  for format in apk ipk; do
    sed -e "s/aarch64_cortex-a53/$arch/g" -e "s/\"apk\"/\"$format\"/g" -e "s/[.]apk/.$format/g" "$work/rust-x.json" > "$work/platform.json"
    if [ "$format" = ipk ]; then sed -i 's/-r1_/-1_/g' "$work/platform.json"; fi
    ucode "$helper" core-package-plan rust-x "$arch" "$format" https://mirror.51343.ru < "$work/platform.json" > "$work/platform-plan"
    grep -q "$arch" "$work/platform-plan"
  done
done

# Pinning uses the release version and requires an immutable matching archive.
pin() { printf '%s\n' "$1" | ucode "$helper" release-xrust-version; }
for version in 1.14.9-1 2.7.2 2.7.6_rc2 2.7.6-canary.2; do
  [ "$(ucode "$helper" release-before-bridge "$version" 2.7.6)" = 1 ]
done
for version in 2.7.6 2.7.6-r1 2.7.10 2.8.0 3.0.0-canary.1 3.0.0_rc1; do
  [ "$(ucode "$helper" release-before-bridge "$version" 2.7.6)" = 0 ]
done
if ucode "$helper" release-before-bridge unknown 2.7.6; then
  fail 'An unknown installed release was accepted'
fi
[ -z "$(pin '{"tag_name":"2.7.6-canary.1"}')" ]
[ -z "$(pin '{"tag_name":"2.7.6","xrust_version":"0.0.99"}')" ]
[ "$(pin '{"tag_name":"3.0.0","xrust_version":"0.0.26"}')" = 0.0.26 ]
for release in '{"tag_name":"3.0.0"}' \
    '{"tag_name":"3.0.0","xrust_version":26}' \
    '{"tag_name":"3.0.0","xrust_version":"latest"}' \
    '{"tag_name":"3.0.0","xrust_version":"0.0.26-r1"}'; do
  if pin "$release" > /dev/null; then
    fail "Unexpectedly accepted pin in $release"
  fi
done

sed 's/"assets":\[{/"minimum_forkop_major":3,"assets":[{"version":"0.0.26-r1",/' "$work/rust-x.json" > "$work/pinned.json"
sed 's/"minimum_forkop_major":3,//' "$work/pinned.json" > "$work/legacy-pin.json"
if ucode "$helper" core-package-plan rust-x aarch64 apk https://mirror.51343.ru 0.0.26 < "$work/legacy-pin.json"; then
  fail 'Accepted a legacy Xrust package for a fresh 3.x installation'
fi
sed -e 's/0.0.26-r1/0.0.26-1/g' -e 's/"apk"/"ipk"/g' -e 's/[.]apk/.ipk/g' "$work/pinned.json" > "$work/pinned-ipk.json"
ucode "$helper" core-package-plan rust-x aarch64_cortex-a53 ipk https://mirror.51343.ru 0.0.26 < "$work/pinned-ipk.json" > /dev/null
if ucode "$helper" core-package-plan rust-x aarch64 apk https://mirror.51343.ru 0.0.44 < "$work/pinned.json"; then
  fail 'Accepted an archive for a different Xrust release'
fi

sed -e '/^main "\$@"$/d' -e "s@/usr/bin/forkop@$work/forkop@g" \
  -e "s@/etc/rc.d/S98forkop-upgrade-recovery@$work/recovery-hook@g" "$ROOT/install.sh" > "$work/installer.sh"
. "$work/installer.sh"
TMP_DIR="$work"
MIRROR_BASE_URL=https://mirror.51343.ru
FORKOP_XRUST_VERSION=0.0.26
SING_BOX_INSTALL_VARIANT=rust-x
PKG_IS_APK=1
read_openwrt_release_value() { printf '%s\n' aarch64; }
temporary_available_space_kb() { printf '%s\n' 65536; }
http_get() {
  [ "$1" = "$MIRROR_BASE_URL/forkop/rust-x/releases/0.0.26/manifest.json" ] ||
    fail "Unexpected Xrust metadata URL $1"
  cat "$work/pinned.json"
}
prepare_core_package_plan
[ "$core_url" = "$MIRROR_BASE_URL/forkop/rust-x/releases/0.0.26/rust-x_0.0.26-r1_aarch64_cortex-a53.apk" ]

(
  pkg_is_installed() { [ "$1" = rust-x ]; }
  pinned_xrust_installed_version() { printf '%s\n' "$expected_revision"; }
  pinned_xrust_binary_matches() { :; }
  for expected_revision in 0.0.26-r1 0.0.26-1; do
    extension=apk
    [ "$expected_revision" != 0.0.26-1 ] || extension=ipk
    for architecture in x86_64 aarch64_cortex-a53; do
      core_url="$MIRROR_BASE_URL/forkop/rust-x/releases/0.0.26/rust-x_${expected_revision}_$architecture.$extension"
      stage_fresh_pinned_xrust
      [ "$core_package_version" = "$expected_revision" ]
      [ "$core_package_arch" = "$architecture" ]
    done
  done
)

cat > "$work/forkop" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$BACKEND_LOG"
if [ "${OLD_BACKEND:-0}" -eq 1 ]; then
    printf '%s\n' '{"success":false,"message":"Unknown component action"}'
    exit 1
fi
printf '%s\n' '{"success":true}'
SH
chmod +x "$work/forkop"
export BACKEND_LOG="$work/backend.log"
install_selected_sing_box > /dev/null
grep -Fxq 'component_action sing_box install_rust_x 0.0.26' "$BACKEND_LOG"

# Exercise both channel manifests and the archived bridge through main.
# Package/service mutations affect only fixture state in $work.
main_update() (
  PKG_IS_APK="$1"
  installed_before="$2"
  shift 2
  printf '%s\n' "$installed_before" > "$work/installed"
  : > "$BACKEND_LOG"
  check_root() { :; }
  init_tmp_dir() { TMP_DIR="$(mktemp -d "$work/phase.XXXXXX")"; }
  cleanup() { [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"; }
  detect_fetcher() { :; }
  sync_time() { :; }
  check_system() { :; }
  configure_package_mirror() { :; }
  detect_legacy_installation() { :; }
  detect_install_mode() { INSTALL_MODE=update; }
  decide_i18n_installation() { :; }
  select_sing_box_installation() {
    SING_BOX_INSTALL_VARIANT=""
    UPDATE_EXISTING_XRUST=1
  }
  pkg_list_update() { :; }
  ensure_bootstrap_ucode_runtime() { :; }
  installed_forkop_package_version() { cat "$work/installed"; }
  pkg_is_installed() { [ "$1" = "${MOCK_CORE:-rust-x}" ]; }
  prepare_legacy_upgrade_recovery() {
    [ "$(installed_forkop_package_version forkop)" = 2.7.6 ]
    echo recovery-prepare >> "$BACKEND_LOG"
    cat > "$work/recovery-hook" <<'SH'
#!/bin/sh
printf 'recovery-%s\n' "$1" >> "$BACKEND_LOG"
SH
    chmod 700 "$work/recovery-hook"
  }
  http_get() {
    case "${1#"$MIRROR_BASE_URL/forkop/updates/"}" in
      stable.json) tag=3.0.0; pin=',"xrust_version":"0.0.26"' ;;
      canary.json) tag=3.0.1-canary.4; pin=',"xrust_version":"0.0.27"' ;;
      releases/2.7.6/release.json)
        [ "${BRIDGE_FAIL:-}" != missing ] || return 1
        tag=2.7.6; pin=''
        [ "${BRIDGE_FAIL:-}" != wrong-tag ] || tag=2.7.5 ;;
      *) fail "Unexpected request $1" ;;
    esac
    printf 'manifest %s\n' "$tag" >> "$BACKEND_LOG"
    ext=ipk
    [ "$PKG_IS_APK" -eq 0 ] || ext=apk
    printf '{"tag_name":"%s"%s,"assets":[' "$tag" "$pin"
    for pkg in forkop luci-app-forkop luci-i18n-forkop-ru; do
      [ "$pkg" = forkop ] || printf ','
      printf '{"name":"%s_%s.%s","browser_download_url":"/packages/%s_%s.%s","sha256":"%064d"}' \
        "$pkg" "$tag" "$ext" "$pkg" "$tag" "$ext" 0
    done
    printf ']}\n'
  }
  download_forkop_packages() {
    [ "$FORKOP_RELEASE_TAG" = 2.7.6 ] && [ -z "$FORKOP_XRUST_VERSION" ] ||
      fail 'The pinned release cannot use standalone package installation'
  }
  prepare_core_package_plan() { :; }
  confirm_legacy_migration() { :; }
  prepare_current_config_backup() { :; }
  prepare_current_update_rollback() { :; }
  ensure_flash_space() { :; }
  preinstall_release_dependencies() { :; }
  cleanup_legacy_installation() { :; }
  rollback_current_update() {
    if [ "$UPDATE_TRANSACTION_ACTIVE" = 1 ]; then
      printf '%s\n' "$installed_before" > "$work/installed"
      printf 'rollback %s\n' "$installed_before" >> "$BACKEND_LOG"
      UPDATE_ROLLBACK_ATTEMPTED=1
    fi
  }
  install_backend_package() {
    printf '%s\n' "$FORKOP_RELEASE_TAG" > "$work/installed"
    printf 'install %s\n' "$FORKOP_RELEASE_TAG" >> "$BACKEND_LOG"
  }
  install_ui_packages() { [ "${BRIDGE_FAIL:-}" != luci ] || fail 'LuCI package failed'; }
  persist_release_channel() { [ "$FORKOP_CHANNEL" = stable ]; }
  validate_installed_configuration() { :; }
  remove_legacy_backup() { :; }
  post_install() { echo bridge-ready >> "$BACKEND_LOG"; }
  update_existing_xrust() { fail 'The bridge must preserve the installed Xrust version'; }
  main "$@"
)

for apk in 0 1; do
  for channel in stable canary; do
    target=3.0.0
    [ "$channel" = stable ] || target=3.0.1-canary.4
    main_update "$apk" 2.7.2 --channel "$channel" > /dev/null
    printf '%s\n' "manifest $target" 'manifest 2.7.6' 'install 2.7.6' bridge-ready recovery-prepare \
      "component_action forkop install_pinned_xrust $target" recovery-commit > "$work/expected-update.log"
    cmp "$work/expected-update.log" "$BACKEND_LOG"
    main_update "$apk" 2.7.6 --channel "$channel" > /dev/null
    printf '%s\n' "manifest $target" recovery-prepare \
      "component_action forkop install_pinned_xrust $target" recovery-commit > "$work/expected-update.log"
    cmp "$work/expected-update.log" "$BACKEND_LOG"
  done
done
main_update 1 2.7.6_rc2 --channel canary > /dev/null
grep -Fxq 'install 2.7.6' "$BACKEND_LOG"
main_update 1 3.0.0 --channel canary > /dev/null
! grep -Fq 'install 2.7.6' "$BACKEND_LOG"
grep -Fxq 'component_action forkop install_pinned_xrust 3.0.1-canary.4' "$BACKEND_LOG"

for failure in missing wrong-tag luci; do
  if BRIDGE_FAIL="$failure" main_update 1 2.7.2 --channel canary > "$work/bridge-failed" 2>&1; then
    fail "Failed bridge accepted: $failure"
  fi
  [ "$(cat "$work/installed")" = 2.7.2 ]
  ! grep -Fq 'install_pinned_xrust' "$BACKEND_LOG"
done
grep -Fxq 'rollback 2.7.2' "$BACKEND_LOG"
if MOCK_CORE=sing-box-x main_update 0 2.7.2 --channel canary > "$work/no-xrust" 2>&1; then
  fail 'Sing-box installation entered the pinned upgrade'
fi
[ "$(cat "$work/installed")" = 2.7.6 ]
grep -Fq 'Switch to Xrust in LuCI' "$work/no-xrust"
! grep -Fq 'recovery-prepare' "$BACKEND_LOG"
if OLD_BACKEND=1 main_update 0 2.7.6 > "$work/older-backend" 2>&1; then
  fail 'A rejected pinned update was reported as successful'
fi
grep -Fq 'Unknown component action' "$work/older-backend"
grep -Fq 'requires Forkop X 2.7.6 or later' "$work/older-backend"
! grep -Fxq 'recovery-commit' "$BACKEND_LOG"
grep -Fxq 'recovery-commit-restored' "$BACKEND_LOG"

echo 'Installer pinned Xrust selection and two-stage stable/canary upgrade (APK and IPK): OK'

# The same public installer serves 2.7.6 until the selected channel moves to 3.x.
# Run the real main and legacy core dispatch with fixture package managers.
main_stable_276() (
  PKG_IS_APK="$1"
  baseline_mode="$2"
  baseline_core="$3"
  export BACKEND_LOG="$4"
  : > "$BACKEND_LOG"
  check_root() { :; }
  init_tmp_dir() { :; }
  cleanup() { :; }
  detect_fetcher() { :; }
  sync_time() { :; }
  check_system() { :; }
  configure_package_mirror() { :; }
  detect_legacy_installation() { :; }
  detect_install_mode() { INSTALL_MODE="$baseline_mode"; }
  installed_forkop_package_version() { printf '%s\n' "${BASELINE_FORKOP_VERSION:-2.7.5}"; }
  decide_i18n_installation() { :; }
  pkg_list_update() { :; }
  ensure_bootstrap_ucode_runtime() { :; }
  pkg_is_installed() { [ "$1" = "$baseline_core" ]; }
  sing_box_is_present() { [ -n "$baseline_core" ]; }
  resolve_forkop_release() {
    FORKOP_RELEASE_TAG=2.7.6
    FORKOP_PACKAGE_VERSION=2.7.6
    FORKOP_RELEASE_JSON='{"tag_name":"2.7.6"}'
  }
  download_forkop_packages() { :; }
  prepare_core_package_plan() {
    [ -z "$FORKOP_XRUST_VERSION" ] || fail 'Unexpected Xrust pin for 2.7.6'
    if [ -z "$baseline_core" ]; then
      [ "$SING_BOX_INSTALL_VARIANT" = rust-x ] || fail 'Wrong default core for a clean 2.7.6 install'
    else
      [ -z "$SING_BOX_INSTALL_VARIANT" ] || fail '2.7.6 should preserve the existing core variant'
    fi
  }
  stage_fresh_pinned_xrust() { fail '2.7.6 entered the 3.x staging path'; }
  confirm_legacy_migration() { :; }
  prepare_current_config_backup() { :; }
  prepare_current_update_rollback() { :; }
  ensure_flash_space() { :; }
  preinstall_release_dependencies() { :; }
  cleanup_legacy_installation() { :; }
  install_backend_package() { printf '%s\n' 'install forkop 2.7.6' >> "$BACKEND_LOG"; }
  install_ui_packages() { :; }
  persist_release_channel() { :; }
  validate_installed_configuration() { :; }
  remove_legacy_backup() { :; }
  post_install() { :; }
  main
)
for apk in 0 1; do
  main_stable_276 "$apk" clean '' "$work/clean.log" >/dev/null 2>&1
  printf '%s\n' 'install forkop 2.7.6' 'component_action sing_box install_rust_x' > "$work/expected.log"
  cmp "$work/clean.log" "$work/expected.log"
  main_stable_276 "$apk" update rust-x "$work/update.log" >/dev/null 2>&1
  printf '%s\n' 'install forkop 2.7.6' 'component_action sing_box update_rust_x' > "$work/expected.log"
  cmp "$work/update.log" "$work/expected.log"
  main_stable_276 "$apk" update sing-box-x "$work/existing.log" >/dev/null 2>&1
  printf '%s\n' 'install forkop 2.7.6' > "$work/expected.log"
  cmp "$work/existing.log" "$work/expected.log"
  BASELINE_FORKOP_VERSION=3.0.0_rc1 main_stable_276 "$apk" update rust-x "$work/rollback.log" >/dev/null 2>&1
  printf '%s\n' 'component_action forkop install 2.7.6' > "$work/expected.log"
  cmp "$work/rollback.log" "$work/expected.log"
done
echo 'Installer 2.7.6 clean and existing-core dispatch (APK and IPK): OK'

(
  apk() {
    [ "$*" = 'list --installed --manifest rust-x' ] || return 1
    printf '%s\n' 'rust-x 0.0.44-r1'
  }
  opkg() {
    [ "$*" = 'list-installed rust-x' ] || return 1
    printf '%s\n' 'rust-x - 0.0.44-1'
  }
  [ "$(PKG_IS_APK=1 pinned_xrust_installed_version)" = 0.0.44-r1 ]
  [ "$(PKG_IS_APK=0 pinned_xrust_installed_version)" = 0.0.44-1 ]
)
echo 'Installer exact installed Xrust package revision (APK and IPK): OK'
