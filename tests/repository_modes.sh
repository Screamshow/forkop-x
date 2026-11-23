#!/bin/sh
set -eu

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INSTALLER="$REPO/install.sh"
MIGRATION="$REPO/forkop/files/usr/share/forkop/mirror-migration.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Exercise the installer's resolver without invoking its main workflow.
sed -e '/^main "\$@"$/d' -e 's#\[ -f /etc/openwrt_release \]#false#' "$INSTALLER" >"$WORK/installer-lib"
# shellcheck disable=SC1090
. "$WORK/installer-lib"
MIRROR_SUPPORTED=1
PKG_IS_APK=0
OPKG_DISTFEEDS_FILE="$WORK/distfeeds"
printf 'src/gz base https://downloads.openwrt.org/releases/24.10.8/packages/aarch64_cortex-a53/base\n' >"$OPKG_DISTFEEDS_FILE"
resolve_repository_mode
[ "$REPOSITORY_MODE" = full-mirror ] || fail 'vanilla Filogic/opkg was not full-mirror'
printf 'src/gz routerich https://packages.routerich.ru/releases/base\n' >"$OPKG_DISTFEEDS_FILE"
resolve_repository_mode
[ "$REPOSITORY_MODE" = native-feeds ] || fail 'Routerich/opkg was not native-feeds'
printf 'src/gz glinet https://fw.gl-inet.com/packages/base\n' >"$OPKG_DISTFEEDS_FILE"
resolve_repository_mode
[ "$REPOSITORY_MODE" = native-feeds ] || fail 'GL.iNet/opkg was not native-feeds'

PKG_IS_APK=1
APK_REPOSITORIES_FILE="$WORK/repositories"
APK_DISTFEEDS_FILE="$WORK/apk-distfeeds"
printf 'https://downloads.openwrt.org/releases/25.12.5/targets/mediatek/filogic/packages.adb\n' >"$APK_REPOSITORIES_FILE"
printf 'https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/base/packages.adb\n' >"$APK_DISTFEEDS_FILE"
resolve_repository_mode
[ "$REPOSITORY_MODE" = full-mirror ] || fail 'vanilla Filogic/APK was not full-mirror'
printf 'https://downloads.gl-inet.com/releases/packages.adb\n' >"$APK_DISTFEEDS_FILE"
resolve_repository_mode
[ "$REPOSITORY_MODE" = native-feeds ] || fail 'GL.iNet/APK was not native-feeds'

make_root() {
  root="$1" target="$2" arch="$3"
  mkdir -p "$root/etc/opkg" "$root/etc/apk/repositories.d" "$root/etc/apk/keys" "$root/bin"
  printf "DISTRIB_TARGET='%s'\nDISTRIB_ARCH='%s'\n" "$target" "$arch" >"$root/etc/openwrt_release"
  printf '#!/bin/sh\nexit 0\n' >"$root/bin/uci"
  chmod +x "$root/bin/uci"
}
run_opkg_migration() {
  root="$1"
  printf '#!/bin/sh\nexit 0\n' >"$root/bin/opkg"
  chmod +x "$root/bin/opkg"
  PATH="$root/bin:$PATH" FORKOP_MIGRATION_APK_BIN="$root/bin/missing-apk" FORKOP_MIGRATION_ROOT="$root" sh "$MIGRATION"
}
run_apk_migration() {
  root="$1"
  cat >"$root/bin/apk" <<'SH'
#!/bin/sh
exit 0
SH
cat >"$root/bin/curl" <<'SH'
#!/bin/sh
[ "${TEST_KEY_UNAVAILABLE:-0}" = 0 ] || exit 22
out=""
while [ "$#" -gt 0 ]; do
  [ "$1" = -o ] && { out="$2"; shift 2; continue; }
  shift
done
printf '%s\n%s\n%s\n' '-----BEGIN PUBLIC KEY-----' test '-----END PUBLIC KEY-----' > "$out"
SH
  chmod +x "$root/bin/apk" "$root/bin/curl"
  PATH="$root/bin:$PATH" FORKOP_MIGRATION_ROOT="$root" sh "$MIGRATION"
}

vanilla="$WORK/vanilla"
make_root "$vanilla" mediatek/filogic aarch64_cortex-a53
printf 'src/gz base https://downloads.openwrt.org/releases/24.10.8/packages/aarch64_cortex-a53/base\n' >"$vanilla/etc/opkg/distfeeds.conf"
run_opkg_migration "$vanilla"
grep -Fq 'https://mirror.51343.ru/openwrt/releases/' "$vanilla/etc/opkg/distfeeds.conf" || fail 'vanilla Filogic migration lost full mirror'

routerich="$WORK/routerich"
make_root "$routerich" mediatek/filogic aarch64_cortex-a53
printf 'src/gz routerich https://packages.routerich.ru/releases/base\n' >"$routerich/etc/opkg/distfeeds.conf"
router_hash="$(sha256sum "$routerich/etc/opkg/distfeeds.conf" | awk '{print $1}')"
run_opkg_migration "$routerich"
[ "$router_hash" = "$(sha256sum "$routerich/etc/opkg/distfeeds.conf" | awk '{print $1}')" ] || fail 'Routerich migration rewrote vendor feeds'
run_opkg_migration "$routerich"
[ "$router_hash" = "$(sha256sum "$routerich/etc/opkg/distfeeds.conf" | awk '{print $1}')" ] || fail 'Routerich reinstall rewrote vendor feeds'

glinet="$WORK/glinet"
make_root "$glinet" mediatek/filogic aarch64_cortex-a53
printf 'src/gz glinet https://fw.gl-inet.com/packages/base\n' >"$glinet/etc/opkg/distfeeds.conf"
glinet_hash="$(sha256sum "$glinet/etc/opkg/distfeeds.conf" | awk '{print $1}')"
run_opkg_migration "$glinet"
[ "$glinet_hash" = "$(sha256sum "$glinet/etc/opkg/distfeeds.conf" | awk '{print $1}')" ] || fail 'GL.iNet migration rewrote vendor feeds'

apk_vanilla="$WORK/apk-vanilla"
make_root "$apk_vanilla" mediatek/filogic aarch64_cortex-a53
printf 'https://downloads.openwrt.org/releases/25.12.5/targets/mediatek/filogic/packages.adb\n' >"$apk_vanilla/etc/apk/repositories"
printf 'https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/base/packages.adb\n' >"$apk_vanilla/etc/apk/repositories.d/distfeeds.list"
run_apk_migration "$apk_vanilla"
grep -Fq 'https://mirror.51343.ru/openwrt/releases/' "$apk_vanilla/etc/apk/repositories" || fail 'vanilla Filogic/APK migration lost full mirror'
grep -Fqx 'https://mirror.51343.ru/forkop/mirror/current/aarch64_cortex-a53/packages.adb' "$apk_vanilla/etc/apk/repositories.d/forkop.list" || fail 'full mirror APK feed missing'

custom="$WORK/apk-custom"
make_root "$custom" mediatek/filogic aarch64_cortex-a53
printf 'https://downloads.openwrt.org/releases/25.12.5/targets/mediatek/filogic/packages.adb\n' >"$custom/etc/apk/repositories"
printf 'https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/base/packages.adb\n' >"$custom/etc/apk/repositories.d/distfeeds.list"
cat >"$custom/bin/uci" <<'SH'
#!/bin/sh
case "$2:$3" in
  get:forkop.settings.mirror_base_url) echo https://mirror.example.test ;;
  set:forkop.settings.mirror_base_url=https://mirror.example.test) : ;;
  set:*) exit 1 ;;
  commit:forkop) [ "${TEST_COMMIT_FAILURE:-0}" = 0 ] ;;
esac
SH
cp "$custom/etc/apk/repositories" "$custom/original"
cp "$custom/etc/apk/repositories.d/distfeeds.list" "$custom/original-distfeeds"
if TEST_KEY_UNAVAILABLE=1 run_apk_migration "$custom"; then fail 'missing mirror key was accepted'; fi
cmp "$custom/original" "$custom/etc/apk/repositories"
cmp "$custom/original-distfeeds" "$custom/etc/apk/repositories.d/distfeeds.list"
[ ! -e "$custom/etc/apk/repositories.d/forkop.list" ] || fail 'missing key published an APK repository'
if TEST_COMMIT_FAILURE=1 run_apk_migration "$custom"; then fail 'failed UCI commit was ignored'; fi
cmp "$custom/original" "$custom/etc/apk/repositories"
cmp "$custom/original-distfeeds" "$custom/etc/apk/repositories.d/distfeeds.list"
[ ! -e "$custom/etc/apk/repositories.d/forkop.list" ] || fail 'failed UCI commit left the new repository active'
[ ! -e "$custom/etc/apk/keys/forkop-mirror.pem" ] || fail 'failed UCI commit left the new key installed'
run_apk_migration "$custom"
grep -Fq 'https://mirror.example.test/openwrt/releases/' "$custom/etc/apk/repositories" || fail 'configured mirror was overwritten'
grep -Fq 'https://mirror.example.test/forkop/mirror/current/' "$custom/etc/apk/repositories.d/forkop.list" ||
  fail 'configured mirror was not applied to the Forkop feed'

freifunk="$WORK/freifunk"
make_root "$freifunk" mediatek/filogic aarch64_cortex-a53
printf 'src/gz openwrt_packages https://mirror.berlin.freifunk.net/downloads.openwrt.org/releases/24.10.2/packages/aarch64_cortex-a53/packages\n' >"$freifunk/etc/opkg/distfeeds.conf"
run_opkg_migration "$freifunk"
grep -Fqx 'src/gz openwrt_packages https://mirror.51343.ru/openwrt/releases/24.10.2/packages/aarch64_cortex-a53/packages' "$freifunk/etc/opkg/distfeeds.conf" ||
  fail 'mirror with a /downloads.openwrt.org/releases path was not redirected'

unknown="$WORK/unknown"
make_root "$unknown" mediatek/filogic aarch64_cortex-a53
printf '%s\n' 'src/gz openwrt_core https://downloads.openwrt.org/releases/24.10.7/targets/mediatek/filogic/packages' \
  'src/gz openwrt_base https://mirror.example.net/openwrt/releases/stable/aarch64_cortex-a53/base' >"$unknown/etc/opkg/distfeeds.conf"
unknown_hash="$(sha256sum "$unknown/etc/opkg/distfeeds.conf" | awk '{print $1}')"
run_opkg_migration "$unknown" || fail 'unknown feed layout failed the package migration'
[ "$unknown_hash" = "$(sha256sum "$unknown/etc/opkg/distfeeds.conf" | awk '{print $1}')" ] || fail 'unknown feed layout was partially rewritten'
[ ! -e "$unknown/etc/opkg/distfeeds.conf.pre-forkop-mirror" ] || fail 'unknown feed layout left a recovery copy'

apk_glinet="$WORK/apk-glinet"
make_root "$apk_glinet" mediatek/filogic aarch64_cortex-a53
printf 'https://downloads.gl-inet.com/releases/packages.adb\n' >"$apk_glinet/etc/apk/repositories"
printf 'https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/base/packages.adb\n' >"$apk_glinet/etc/apk/repositories.d/distfeeds.list"
apk_glinet_hash="$(sha256sum "$apk_glinet/etc/apk/repositories" | awk '{print $1}')"
run_apk_migration "$apk_glinet"
[ "$apk_glinet_hash" = "$(sha256sum "$apk_glinet/etc/apk/repositories" | awk '{print $1}')" ] || fail 'GL.iNet/APK migration rewrote vendor feed'
[ ! -e "$apk_glinet/etc/apk/repositories.d/forkop.list" ] || fail 'GL.iNet/APK received Forkop APK feed'

x86="$WORK/x86"
make_root "$x86" x86/64 x86_64
printf 'native x86 feed\n' >"$x86/etc/opkg/distfeeds.conf"
x86_hash="$(sha256sum "$x86/etc/opkg/distfeeds.conf" | awk '{print $1}')"
run_opkg_migration "$x86"
[ "$x86_hash" = "$(sha256sum "$x86/etc/opkg/distfeeds.conf" | awk '{print $1}')" ] || fail 'x86 migration rewrote native feeds'

printf 'repository mode checks passed\n'
