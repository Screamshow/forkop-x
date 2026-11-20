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
[ -z "$(pin '{"tag_name":"2.7.6-canary.1"}')" ]
[ "$(pin '{"tag_name":"3.0.0","xrust_version":"0.0.26"}')" = 0.0.26 ]
for release in '{"tag_name":"3.0.0"}' \
    '{"tag_name":"3.0.0","xrust_version":26}' \
    '{"tag_name":"3.0.0","xrust_version":"latest"}' \
    '{"tag_name":"3.0.0","xrust_version":"0.0.26-r1"}'; do
  if pin "$release" > /dev/null; then
    fail "Unexpectedly accepted pin in $release"
  fi
done

sed 's/"assets":\[{/"assets":[{"version":"0.0.26-r1",/' "$work/rust-x.json" > "$work/pinned.json"
sed -e 's/0.0.26-r1/0.0.26-1/g' -e 's/"apk"/"ipk"/g' -e 's/[.]apk/.ipk/g' "$work/pinned.json" > "$work/pinned-ipk.json"
ucode "$helper" core-package-plan rust-x aarch64_cortex-a53 ipk https://mirror.51343.ru 0.0.26 < "$work/pinned-ipk.json" > /dev/null
if ucode "$helper" core-package-plan rust-x aarch64 apk https://mirror.51343.ru 0.0.44 < "$work/pinned.json"; then
  fail 'Accepted an archive for a different Xrust release'
fi

sed -e '/^main "\$@"$/d' -e "s@/usr/bin/forkop@$work/forkop@g" "$ROOT/install.sh" > "$work/installer.sh"
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

# Use the actual main dispatch. Stub setup and reject a fallback into the old
# standalone upgrade path when the installed backend lacks the pinned action.
main_update() (
  check_root() { :; }
  init_tmp_dir() { :; }
  cleanup() { :; }
  detect_fetcher() { :; }
  sync_time() { :; }
  check_system() { :; }
  configure_package_mirror() { :; }
  detect_legacy_installation() { :; }
  detect_install_mode() { INSTALL_MODE=update; }
  decide_i18n_installation() { :; }
  select_sing_box_installation() { :; }
  pkg_list_update() { :; }
  ensure_bootstrap_ucode_runtime() { :; }
  resolve_forkop_release() {
    FORKOP_RELEASE_TAG=3.0.0
    FORKOP_RELEASE_JSON='{"tag_name":"3.0.0","xrust_version":"0.0.26"}'
  }
  download_forkop_packages() { fail 'Unexpected standalone package installation'; }
  main
)
main_update > /dev/null
grep -Fxq 'component_action forkop install_pinned_xrust 3.0.0' "$BACKEND_LOG"
if OLD_BACKEND=1 main_update > "$work/older-backend" 2>&1; then
  fail 'An older backend accepted a pinned Forkop upgrade'
fi
grep -Fq 'Unknown component action' "$work/older-backend"
grep -Fq 'requires Forkop X 2.7.6 or later' "$work/older-backend"
! grep -Fq 'Unexpected standalone package installation' "$work/older-backend"

echo 'Installer pinned Xrust selection and upgrade dispatch: OK'
