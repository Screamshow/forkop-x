#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"

cleanup_test() {
  rm -rf "$WORK_DIR"
}
trap cleanup_test EXIT

fail_test() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

sed \
  -e '/^main "\$@"$/d' \
  -e 's#\[ -f /etc/openwrt_release \]#\[ -f "$FORKOP_TEST_RELEASE_FILE" \]#' \
  "$ROOT_DIR/install.sh" > "$WORK_DIR/install-library.sh"
# shellcheck disable=SC1090
. "$WORK_DIR/install-library.sh"

FORKOP_TEST_RELEASE_FILE="$WORK_DIR/openwrt_release"
touch "$FORKOP_TEST_RELEASE_FILE"

read_openwrt_release_value() {
  case "$1" in
    DISTRIB_ID) printf '%s\n' "${TEST_ID:-OpenWrt}" ;;
    DISTRIB_REVISION) printf '%s\n' "${TEST_REVISION:-}" ;;
    DISTRIB_RELEASE) printf '%s\n' "$TEST_RELEASE" ;;
    DISTRIB_TARGET) printf '%s\n' "$TEST_TARGET" ;;
    DISTRIB_ARCH) printf '%s\n' "$TEST_ARCH" ;;
  esac
}

expect_supported() {
  TEST_RELEASE="$1"
  PKG_IS_APK="$2"
  TEST_TARGET="${3:-mediatek/filogic}"
  TEST_ARCH="${4:-aarch64_cortex-a53}"
  check_system >/dev/null ||
    fail_test "expected supported platform: $TEST_RELEASE apk=$PKG_IS_APK $TEST_TARGET $TEST_ARCH"
}

expect_native_fallback() {
  TEST_RELEASE="$1"
  PKG_IS_APK="$2"
  TEST_TARGET="$3"
  TEST_ARCH="$4"
  MIRROR_SUPPORTED=0
  check_system >/dev/null ||
    fail_test "expected native fallback platform: $TEST_RELEASE apk=$PKG_IS_APK $TEST_TARGET $TEST_ARCH"
  [ "$MIRROR_SUPPORTED" -eq 0 ] ||
    fail_test "unsupported mirror target was classified as full mirror: $TEST_TARGET $TEST_ARCH"
}

expect_rejected() {
  TEST_RELEASE="$1"
  PKG_IS_APK="$2"
  TEST_TARGET="${3:-mediatek/filogic}"
  TEST_ARCH="${4:-aarch64_cortex-a53}"
  if (check_system >/dev/null 2>&1); then
    fail_test "expected rejected platform: $TEST_RELEASE apk=$PKG_IS_APK $TEST_TARGET $TEST_ARCH"
  fi
}

for release in 24.10.0 24.10.4 24.10.5 24.10.7 24.10.99; do
  expect_supported "$release" 0
done
expect_supported 25.12.5 1

expect_rejected 23.05.5 0
expect_rejected 24.09.9 0
expect_rejected 24.10.4 1
expect_rejected 25.12.5 0
expect_native_fallback 24.10.4 0 ramips/mt7621 mipsel_24kc
expect_native_fallback 24.10.4 0 mediatek/filogic mipsel_24kc
expect_native_fallback 25.12.5 1 x86/64 x86_64

TEST_ID='Beam WRT'
TEST_REVISION=r20260929-d958caf
FORKOP_CHANNEL=canary
expect_native_fallback 1.5.0 1 qualcommbe/ipq95xx aarch64_cortex-a73
expect_rejected 1.5.0 0 qualcommbe/ipq95xx aarch64_cortex-a73
expect_rejected 1.5.0 1 mediatek/filogic aarch64_cortex-a73
TEST_REVISION=unknown
expect_rejected 1.5.0 1 qualcommbe/ipq95xx aarch64_cortex-a73
TEST_REVISION=r20260929-d958caf
FORKOP_CHANNEL=stable
expect_rejected 1.5.0 1 qualcommbe/ipq95xx aarch64_cortex-a73
TEST_ID=OpenWrt
TEST_REVISION=''

interactive_terminal_available() { return 1; }
SING_BOX_INSTALL_VARIANT=""
sing_box_is_present() { return 1; }
select_sing_box_installation >/dev/null
[ "$SING_BOX_INSTALL_VARIANT" = "rust-x" ] ||
  fail_test "fresh non-interactive installation must select Xrust"

SING_BOX_INSTALL_VARIANT="sentinel"
sing_box_is_present() { return 0; }
select_sing_box_installation >/dev/null
[ -z "$SING_BOX_INSTALL_VARIANT" ] ||
  fail_test "upgrade must preserve the installed sing-box variant"

# Real archives with producer metadata unrelated to extracted file sizes.
mkdir -p "$WORK_DIR/payload/usr/share" "$WORK_DIR/package"
printf x >"$WORK_DIR/payload/usr/share/backend"
tar -czf "$WORK_DIR/package/data.tar.gz" -C "$WORK_DIR/payload" .
tar -czf "$WORK_DIR/backend.ipk" -C "$WORK_DIR/package" .
FORKOP_BACKEND_FILE="$WORK_DIR/backend.ipk"
FORKOP_APP_FILE="$WORK_DIR/backend.ipk"
FORKOP_I18N_FILE=""
TMP_DIR="$WORK_DIR"
PKG_IS_APK=0
calculated_space="$(forkop_install_required_space_kb)"
[ "$calculated_space" -eq 258 ] ||
  fail_test "installer must use actual payloads plus 256 KiB, without multipliers"
printf 'Installer compatibility matrix passed\n'
