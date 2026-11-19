#!/bin/sh
set -eu

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INSTALLER="$REPO/install.sh"
MIGRATION="$REPO/forkop/files/usr/share/forkop/mirror-migration.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

sh "$INSTALLER" --help | grep -Fq -- '--channel stable|canary' || fail 'installer channel option missing'
grep -Fq 'updates/${FORKOP_CHANNEL}.json' "$INSTALLER" || fail 'installer channel manifest missing'
grep -Fq 'MIRROR_SUPPORTED=1' "$INSTALLER" || fail 'mirror supported discriminator missing'
grep -Fq 'keeping native OpenWrt feeds' "$INSTALLER" || fail 'native fallback missing'
grep -Fq '/forkop/updates/" + forkop_update_channel() + ".json' "$REPO/forkop/files/usr/lib/components/action.uc" || fail 'runtime channel lookup missing'

make_root() {
  root="$1"
  target="$2"
  arch="$3"
  mkdir -p "$root/etc/opkg" "$root/etc/apk/repositories.d" "$root/etc/apk/keys" "$root/bin"
  printf "DISTRIB_TARGET='%s'\nDISTRIB_ARCH='%s'\n" "$target" "$arch" >"$root/etc/openwrt_release"
  printf '%s\n' 'src/gz base https://downloads.openwrt.org/releases/24.10.8/packages/aarch64_cortex-a53/base' >"$root/etc/opkg/distfeeds.conf.pre-forkop-mirror"
  printf '%s\n' 'src/gz base https://mirror.51343.ru/openwrt/releases/24.10.8/packages/aarch64_cortex-a53/base' >"$root/etc/opkg/distfeeds.conf"
  printf '#!/bin/sh\nexit 0\n' >"$root/bin/opkg"
  printf '#!/bin/sh\nexit 0\n' >"$root/bin/uci"
  chmod +x "$root/bin/opkg" "$root/bin/uci"
}

native="$WORK/native"
make_root "$native" x86/64 x86_64
PATH="$native/bin:$PATH" FORKOP_MIGRATION_APK_BIN="$native/bin/missing-apk" FORKOP_MIGRATION_ROOT="$native" sh "$MIGRATION"
grep -Fq 'https://downloads.openwrt.org/releases/24.10.8/' "$native/etc/opkg/distfeeds.conf" ||
  fail 'unsupported target did not restore Forkop backup'
[ ! -e "$native/etc/opkg/distfeeds.conf.pre-forkop-mirror" ] || fail 'restored backup was retained'

mixed="$WORK/mixed"
make_root "$mixed" mediatek/filogic aarch64_cortex-a53
printf '%s\n' 'src/gz vendor https://packages.routerich.ru/24.10/mediatek/filogic/24.10.8/base' >>"$mixed/etc/opkg/distfeeds.conf"
cp "$mixed/etc/opkg/distfeeds.conf" "$WORK/mixed.before"
PATH="$mixed/bin:$PATH" FORKOP_MIGRATION_APK_BIN="$mixed/bin/missing-apk" FORKOP_MIGRATION_ROOT="$mixed" sh "$MIGRATION"
cmp -s "$WORK/mixed.before" "$mixed/etc/opkg/distfeeds.conf" || fail 'postinst overwrote mixed vendor feeds'
[ -f "$mixed/etc/opkg/distfeeds.conf.pre-forkop-mirror" ] || fail 'postinst consumed the backup of edited feeds'

apk_root="$WORK/apk-mixed"
make_root "$apk_root" x86/64 x86_64
printf '#!/bin/sh\nexit 0\n' >"$apk_root/bin/apk"
chmod +x "$apk_root/bin/apk"
apk_feed="$apk_root/etc/apk/repositories.d/forkop.list"
apk_key="$apk_root/etc/apk/keys/forkop-mirror.pem"
mirror_feed='https://mirror.51343.ru/forkop/mirror/current/aarch64_cortex-a53/packages.adb'
printf '%s\n' "$mirror_feed" 'https://vendor.example.invalid/packages.adb' >"$apk_feed"
printf 'fixture key\n' >"$apk_key"
PATH="$apk_root/bin:$PATH" FORKOP_MIGRATION_APK_BIN="$apk_root/bin/apk" FORKOP_MIGRATION_ROOT="$apk_root" sh "$MIGRATION"
grep -Fq 'vendor.example.invalid' "$apk_feed" || fail 'postinst deleted an edited APK feed list'
[ -f "$apk_key" ] || fail 'postinst deleted the key while retaining an edited APK feed list'
printf '%s\n' "$mirror_feed" >"$apk_feed"
PATH="$apk_root/bin:$PATH" FORKOP_MIGRATION_APK_BIN="$apk_root/bin/apk" FORKOP_MIGRATION_ROOT="$apk_root" sh "$MIGRATION"
[ ! -e "$apk_feed" ] && [ ! -e "$apk_key" ] || fail 'postinst retained unchanged Forkop APK artifacts'

supported="$WORK/supported"
make_root "$supported" mediatek/filogic aarch64_cortex-a53
printf 'src/gz base https://downloads.openwrt.org/releases/24.10.8/packages/aarch64_cortex-a53/base\n' >"$supported/etc/opkg/distfeeds.conf"
PATH="$supported/bin:$PATH" FORKOP_MIGRATION_APK_BIN="$supported/bin/missing-apk" FORKOP_MIGRATION_ROOT="$supported" sh "$MIGRATION"
grep -Fq 'https://mirror.51343.ru/openwrt/releases/' "$supported/etc/opkg/distfeeds.conf" || fail 'supported target lost mirror path'

echo 'channel architecture tests passed'
